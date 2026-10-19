#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Backs up the Software Hub instance from the loaded config (cpd_vars.sh, or
# ENV_TARGET) to the S3 bucket with 'cpd-cli oadp tenant-backup create'. Needs
# 2_install_oadp_br_utilities.sh run against this cluster first.
#
# Mode:
#   offline (default) - works on any storage. The instance is quiesced (scaled
#                       down) for the whole backup and volume data is copied into
#                       the bucket file by file (kopia). tenant-backup scales it
#                       back up at the end, also when the backup fails. The only
#                       mode the OADP utility restores on ANOTHER cluster.
#   online            - no scale-down: services checkpoint themselves and the
#                       volumes are CSI-snapshotted. Only possible when EVERY
#                       instance volume is on a CSI driver with a
#                       VolumeSnapshotClass - checked first, whatever the storage
#                       (NFS and other non-CSI volumes rule it out). With the
#                       snapshot data mover on (2_install_oadp_br_utilities.sh
#                       --snapshot-move-data) the snapshot contents are uploaded to
#                       the bucket; without it they stay in this cluster's storage
#                       and only a same-cluster restore can use them. IBM documents
#                       online restores to a different cluster only with IBM
#                       Fusion, NetApp Trident protect or Portworx: test a
#                       data-mover backup with a real restore before relying on it.
#
# Afterwards (both modes, also when the backup failed) the script checks that
# every Deployment, StatefulSet and EDB cluster in the instance projects is back
# to the replica count recorded before the backup, and ready. If not, --recover
# runs the backup post-hooks (which scale the instance back up) and checks again.
#
# Prechecks, backup hooks and end-of-backup validation are run by tenant-backup
# itself. Arguments after '--' are passed to it unchanged (see
# 'cpd-cli oadp tenant-backup create --help').
#
#   3_backup_cp4d_instance.sh [options] [-- <tenant-backup create args>]
#     --bucket <name|path>        bucket config to check the DPA against (optional when there is only one)
#     --name <name>               backup name (default cpd-<operands ns>-<mode>-<timestamp>)
#     --mode offline|online       default offline
#     --ttl <duration>            how long Velero keeps the backup, e.g. 720h (cpd-cli default 8760h)
#     --storage-location <bsl>    backup storage location (default: the DPA's default one)
#     --timeout <duration>        wait limit when br_orchestration runs the backup (default 6h)
#     --health-timeout <minutes>  how long to wait for the instance to be back afterwards (default 30, 0 = skip)
#     --yes                       do not ask before an offline backup takes the instance down
#     --list                      list the tenant backups this cluster sees, then exit
#     --recover                   no backup: run the backup post-hooks to scale the instance back
#                                 up after an interrupted backup, then check it (compares with the
#                                 replica counts recorded by the last backup of this instance)
#     --scale-always              with --recover: unquiesce by scaling up (post-hooks --scale-always)
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Repo root only for now: the env is loaded after the options are parsed,
# because --target decides which config to load.
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; unset _b
source "${REPO_ROOT}/src/helpers/oadp_br_helpers.sh"

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

BUCKET=""
BACKUP_NAME=""
MODE=offline
TTL=""
STORAGE_LOCATION=""
WAIT_TIMEOUT=6h
HEALTH_TIMEOUT=30
ASSUME_YES=false
LIST_ONLY=false
RECOVER=false
SCALE_ALWAYS=false
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket)           BUCKET="${2:?--bucket needs a config name or path}"; shift 2 ;;
        --name)             BACKUP_NAME="${2:?--name needs a value}"; shift 2 ;;
        --mode)             MODE="${2:?--mode needs offline or online}"; shift 2 ;;
        --ttl)              TTL="${2:?--ttl needs a duration}"; shift 2 ;;
        --storage-location) STORAGE_LOCATION="${2:?--storage-location needs a name}"; shift 2 ;;
        --timeout)          WAIT_TIMEOUT="${2:?--timeout needs a duration}"; shift 2 ;;
        --health-timeout)   HEALTH_TIMEOUT="${2:?--health-timeout needs minutes}"; shift 2 ;;
        --yes)              ASSUME_YES=true; shift ;;
        --list)             LIST_ONLY=true; shift ;;
        --recover)          RECOVER=true; shift ;;
        --scale-always)     SCALE_ALWAYS=true; shift ;;
        --)                 shift; EXTRA_ARGS=("$@"); break ;;
        -h|--help)          oadp_usage "$0"; exit 0 ;;
        *)                  echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done
if [[ "${MODE}" != "offline" && "${MODE}" != "online" ]]; then
    echo "[ERROR] --mode must be offline or online (got '${MODE}')." >&2
    exit 1
fi
if [[ "${HEALTH_TIMEOUT}" != <-> ]]; then
    echo "[ERROR] --health-timeout must be a number of minutes (got '${HEALTH_TIMEOUT}')." >&2
    exit 1
fi
if [[ "${SCALE_ALWAYS}" == "true" && "${RECOVER}" != "true" ]]; then
    echo "[ERROR] --scale-always only goes with --recover." >&2
    exit 1
fi

# The bucket config is only used to check the DPA; without any config, skip that check.
BUCKET_FILE=""
_bucket_files=("${BUCKET_CONFIG_DIR}"/*"${BUCKET_CONFIG_SUFFIX}"(N))
if [[ -n "${BUCKET}" ]] || (( ${#_bucket_files} )); then
    BUCKET_FILE="$(oadp_resolve_config "${BUCKET_CONFIG_DIR}" "${BUCKET_CONFIG_SUFFIX}" bucket "${BUCKET}" 1.1_generate_backup_bucket_config.sh)"
fi

# --- Env load (repo root found above) ---
source "${REPO_ROOT}/env_bootstrap.sh"

[[ -n "${BUCKET_FILE}" ]] && oadp_load_bucket "${BUCKET_FILE}"
oadp_require_vars OCP_URL OC_LOGIN OADP_PROJECT PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS
oadp_registry_flags
INSTANCE_NS=("${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}")

eval "${OC_LOGIN}"
oadp_check_cluster
oadp_set_client_namespace

if [[ "${LIST_ONLY}" == "true" ]]; then
    cpd-cli oadp tenant-backup list --namespace="${OADP_PROJECT}"
    exit 0
fi

# Replica counts are recorded per instance before each backup; --recover compares
# with the newest one.
WORKLOAD_SNAPSHOT_GLOB="${OADP_LOG_DIR}/workloads-${PROJECT_CPD_INST_OPERANDS}-"

# Print what is still down and how to put it back by hand.
report_not_back() {
    if (( ${#OADP_RESCALE_CMDS} )); then
        echo "[INFO] To put the recorded replica counts back by hand (the operators take over from there):"
        print -rl -- "${OADP_RESCALE_CMDS[@]}" | sed 's/^/         /'
    fi
}

# ------------------------------------------------------------------------------
# --recover: scale the instance back up after an interrupted offline backup
# ------------------------------------------------------------------------------
if [[ "${RECOVER}" == "true" ]]; then
    _snaps=(${WORKLOAD_SNAPSHOT_GLOB}*.txt(Nom))
    SNAP="${_snaps[1]:-}"
    if [[ -n "${SNAP}" ]]; then
        echo "[INFO] Comparing with the replica counts recorded in ${SNAP}"
    else
        echo "[WARN] No recorded replica counts for ${PROJECT_CPD_INST_OPERANDS} in ${OADP_LOG_DIR}; checking readiness only."
    fi
    LOG_FILE="$(oadp_log_file "recover-${PROJECT_CPD_INST_OPERANDS}")"
    POSTHOOK_FLAGS=(
        --namespace="${OADP_PROJECT}"
        --tenant-operator-namespace="${PROJECT_CPD_INST_OPERATORS}"
        --cpd-namespace="${PROJECT_CPD_INST_OPERANDS}"
    )
    [[ "${SCALE_ALWAYS}" == "true" ]] && POSTHOOK_FLAGS+=(--scale-always)
    echo "[INFO] Running the backup post-hooks (unquiesce) for ${PROJECT_CPD_INST_OPERANDS} - log: ${LOG_FILE}"
    if ! cpd-cli oadp backup posthooks "${POSTHOOK_FLAGS[@]}" "${OADP_REGISTRY_FLAGS[@]}" \
            --log-level=debug --verbose 2>&1 | tee -a "${LOG_FILE}"; then
        echo "[WARN] The post-hooks reported an error (see the log); checking the workloads anyway."
    fi
    if oadp_check_workloads "${HEALTH_TIMEOUT}" "${SNAP}" "${INSTANCE_NS[@]}"; then
        exit 0
    fi
    report_not_back
    [[ "${SCALE_ALWAYS}" != "true" ]] && echo "[INFO] Or retry with: $0 --recover --scale-always"
    exit 1
fi

# ------------------------------------------------------------------------------
# Backup
# ------------------------------------------------------------------------------
oadp_check_bsl 6
if [[ -z "$(oc get pods -n "${PROJECT_CPD_INST_OPERATORS}" -l component=cpdbr-tenant,icpdsupport/app=br-service \
        --field-selector=status.phase=Running -o name 2>/dev/null)" ]]; then
    echo "[ERROR] No running cpdbr-tenant pod in ${PROJECT_CPD_INST_OPERATORS}. Run 2_install_oadp_br_utilities.sh first." >&2
    exit 1
fi

[[ -z "${BACKUP_NAME}" ]] && BACKUP_NAME="cpd-${PROJECT_CPD_INST_OPERANDS}-${MODE}-$(date +%Y%m%d-%H%M%S)"
BACKUP_NAME="${(L)BACKUP_NAME}"
if [[ ! "${BACKUP_NAME}" =~ '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || ${#BACKUP_NAME} -gt 63 ]]; then
    echo "[ERROR] Backup name '${BACKUP_NAME}' must be lowercase letters, digits and '-', at most 63 characters." >&2
    exit 1
fi

MOVE_DATA=false
if [[ "${MODE}" == "online" ]]; then
    # An online backup snapshots volumes instead of stopping the instance, so it
    # is only complete when every volume can be snapshotted.
    echo "[INFO] Instance volumes and their CSI snapshot support:"
    oadp_storage_report "${INSTANCE_NS[@]}"
    if (( OADP_NO_SNAPSHOT_PVS )); then
        echo "[ERROR] ${OADP_NO_SNAPSHOT_PVS} of ${OADP_INSTANCE_PVS} volume(s) cannot be CSI-snapshotted (see above), so an online" >&2
        echo "[ERROR] backup of this instance would not be complete. Use --mode offline, which works on any storage." >&2
        exit 1
    fi
    if (( ${#OADP_UNLABELED_SNAPCLASSES} )); then
        echo "[ERROR] Velero only uses snapshot classes labeled velero.io/csi-volumesnapshot-class=true; none is for: ${OADP_UNLABELED_SNAPCLASSES[*]}." >&2
        echo "[ERROR] Run 2_install_oadp_br_utilities.sh --snapshot-move-data (labels them), or label them yourself:" >&2
        for _c in "${OADP_UNLABELED_SNAPCLASSES[@]}"; do
            echo "          oc label volumesnapshotclass ${_c} velero.io/csi-volumesnapshot-class=true" >&2
        done
        exit 1
    fi
    if oadp_dpa_moves_snapshot_data; then
        MOVE_DATA=true
    fi
fi

echo ""
echo "  Cluster:   ${OCP_URL}"
echo "  Instance:  ${PROJECT_CPD_INST_OPERATORS} (operators) / ${PROJECT_CPD_INST_OPERANDS} (operands)"
_mode_note="${MODE}"
[[ "${MOVE_DATA}" == "true" ]] && _mode_note+=", snapshot data uploaded to the bucket"
echo "  Backup:    ${BACKUP_NAME} (${_mode_note})"
echo ""
if [[ "${MODE}" == "offline" ]]; then
    oadp_confirm "An offline backup scales the instance down until the backup finishes, then back up."
elif [[ "${MOVE_DATA}" == "true" ]]; then
    echo "[INFO] Online backup with the snapshot data mover: no scale-down, and the snapshot contents are"
    echo "[INFO] uploaded to the bucket. Cross-cluster restores of online backups are not IBM-documented"
    echo "[INFO] for the OADP utility - verify with a test restore."
else
    echo "[WARN] Online backup without the snapshot data mover: volume data stays in CSI snapshots on this"
    echo "[WARN] cluster, so only a same-cluster restore can use it. To upload it to the bucket, run"
    echo "[WARN] 2_install_oadp_br_utilities.sh --snapshot-move-data first."
fi

CREATE_FLAGS=(
    --namespace="${OADP_PROJECT}"
    --tenant-operator-namespace="${PROJECT_CPD_INST_OPERATORS}"
    --mode="${MODE}"
)
[[ -n "${TTL}" ]] && CREATE_FLAGS+=(--ttl="${TTL}")
[[ -n "${STORAGE_LOCATION}" ]] && CREATE_FLAGS+=(--storage-location="${STORAGE_LOCATION}")
[[ -n "${OADP_S3_CACERT_FILE:-}" ]] && CREATE_FLAGS+=(--cacert-file="${OADP_S3_CACERT_FILE}")

LOG_FILE="$(oadp_log_file "${BACKUP_NAME}")"
SNAP="${WORKLOAD_SNAPSHOT_GLOB}${BACKUP_NAME}.txt"
oadp_workload_snapshot "${SNAP}" "${INSTANCE_NS[@]}"
START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "[INFO] cpd-cli output is also written to ${LOG_FILE}"
echo "[INFO] Starting tenant backup ${BACKUP_NAME}"
# Failures are recorded rather than fatal: the instance check below must run
# either way, since a failed offline backup is the case that can leave it down.
BACKUP_OK=true
if ! cpd-cli oadp tenant-backup create "${BACKUP_NAME}" "${CREATE_FLAGS[@]}" "${OADP_REGISTRY_FLAGS[@]}" \
        "${EXTRA_ARGS[@]}" --log-level=debug --verbose 2>&1 | tee -a "${LOG_FILE}"; then
    BACKUP_OK=false
    echo "[ERROR] tenant-backup create failed (log: ${LOG_FILE})." >&2
elif ! oadp_wait_for_br_cr tenantbackups "${BACKUP_NAME}" "${WAIT_TIMEOUT}" 2>&1 | tee -a "${LOG_FILE}"; then
    BACKUP_OK=false
    echo "[ERROR] Waiting for tenantbackups/${BACKUP_NAME} failed (log: ${LOG_FILE})." >&2
fi

echo ""
cpd-cli oadp tenant-backup status "${BACKUP_NAME}" --namespace="${OADP_PROJECT}" --details 2>&1 | tee -a "${LOG_FILE}" || true
echo ""

if [[ "${MOVE_DATA}" == "true" ]]; then
    # Process substitution, not a pipe: the function must run in this shell to set OADP_DM_TOTAL.
    if ! oadp_datamover_report datauploads "${START_TS}" > >(tee -a "${LOG_FILE}"); then
        BACKUP_OK=false
        echo "[ERROR] Some snapshot uploads failed: oc get datauploads.velero.io -n ${OADP_PROJECT}" >&2
    elif (( OADP_DM_TOTAL == 0 )); then
        echo "[WARN] No snapshot uploads were created: the volume data may not have reached the bucket."
    fi
fi

INSTANCE_OK=true
if (( HEALTH_TIMEOUT > 0 )); then
    if ! oadp_check_workloads "${HEALTH_TIMEOUT}" "${SNAP}" "${INSTANCE_NS[@]}"; then
        INSTANCE_OK=false
        echo "[WARN] The instance is not fully back. Scale it back up with: $0 --recover"
        report_not_back
    fi
fi

echo ""
if [[ "${BACKUP_OK}" == "true" ]]; then
    echo "[OK] Tenant backup ${BACKUP_NAME} finished (details above, log: ${LOG_FILE})"
    echo "[INFO] Logs:    cpd-cli oadp tenant-backup log ${BACKUP_NAME}"
    echo "[INFO] Restore: ${SCRIPT_DIR}/4_restore_cp4d_instance.sh --target <target config> --backup ${BACKUP_NAME}"
else
    echo "[ERROR] Tenant backup ${BACKUP_NAME} did not complete (log: ${LOG_FILE}; cpd-cli oadp tenant-backup log ${BACKUP_NAME})" >&2
fi
[[ "${BACKUP_OK}" == "true" && "${INSTANCE_OK}" == "true" ]]
