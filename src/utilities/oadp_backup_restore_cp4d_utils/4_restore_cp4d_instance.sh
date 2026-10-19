#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Restores a tenant backup from the S3 bucket onto a cluster with
# 'cpd-cli oadp tenant-restore create --from-tenant-backup'.
#
# Target cluster: --target <name> (a config from 1.2_generate_restore_target_config.sh).
# Same cluster as the backup: --same-cluster (uses the normal env). One of the
# two is required, so a restore never lands on a cluster by default.
#
# Before running it against another cluster:
#   - the target needs 2_install_oadp_br_utilities.sh --target <name> with the
#     SAME bucket config, so its OADP sees the backups in the bucket
#   - the backup must be an offline one (3_backup_cp4d_instance.sh default);
#     online backups keep volume data in the source cluster's snapshots
#   - cluster-wide prerequisites the instance relied on (global pull secret,
#     cert-manager, License Service, scheduler, storage classes with the same
#     names, node settings) should be in place - the repo's step 1/2 scripts can
#     be run against the target with ENV_TARGET=<target config path>
#
# The instance is recreated in the namespaces it was backed up from. If they
# already exist on the target the restore refuses, unless --force.
# Arguments after '--' are passed to tenant-restore create unchanged.
#
#   4_restore_cp4d_instance.sh (--target <name|path> | --same-cluster) --backup <name> [options] [-- <args>]
#     --backup <name>             tenant backup to restore (see --list)
#     --name <name>               restore name (default restore-<timestamp>)
#     --bucket <name|path>        bucket config to check the DPA against (optional when there is only one)
#     --force                     allow the instance namespaces to exist already (tenant-restore --force)
#     --sync-timeout <minutes>    how long to wait for the backup to sync from the bucket (default 10)
#     --timeout <duration>        wait limit when br_orchestration runs the restore (default 6h)
#     --health-timeout <minutes>  how long to wait for the restored workloads to be ready (default 30, 0 = skip)
#     --yes                       do not ask for confirmation
#     --list                      list the tenant backups this cluster sees, then exit
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Repo root only for now: the env is loaded after the options are parsed,
# because --target decides which config to load.
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; unset _b
source "${REPO_ROOT}/src/helpers/oadp_br_helpers.sh"

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

TARGET=""
SAME_CLUSTER=false
BACKUP_NAME=""
RESTORE_NAME=""
BUCKET=""
FORCE=false
SYNC_TIMEOUT_MIN=10
WAIT_TIMEOUT=6h
HEALTH_TIMEOUT=30
ASSUME_YES=false
LIST_ONLY=false
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)       TARGET="${2:?--target needs a config name or path}"; shift 2 ;;
        --same-cluster) SAME_CLUSTER=true; shift ;;
        --backup)       BACKUP_NAME="${2:?--backup needs a tenant backup name}"; shift 2 ;;
        --name)         RESTORE_NAME="${2:?--name needs a value}"; shift 2 ;;
        --bucket)       BUCKET="${2:?--bucket needs a config name or path}"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        --sync-timeout) SYNC_TIMEOUT_MIN="${2:?--sync-timeout needs minutes}"; shift 2 ;;
        --timeout)      WAIT_TIMEOUT="${2:?--timeout needs a duration}"; shift 2 ;;
        --health-timeout) HEALTH_TIMEOUT="${2:?--health-timeout needs minutes}"; shift 2 ;;
        --yes)          ASSUME_YES=true; shift ;;
        --list)         LIST_ONLY=true; shift ;;
        --)             shift; EXTRA_ARGS=("$@"); break ;;
        -h|--help)      oadp_usage "$0"; exit 0 ;;
        *)              echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done
if [[ -n "${TARGET}" && "${SAME_CLUSTER}" == "true" ]]; then
    echo "[ERROR] Pass either --target or --same-cluster, not both." >&2
    exit 1
elif [[ -z "${TARGET}" && "${SAME_CLUSTER}" != "true" ]]; then
    echo "[ERROR] Pass --target <restore target config> or --same-cluster." >&2
    exit 1
fi
if [[ "${LIST_ONLY}" != "true" && -z "${BACKUP_NAME}" ]]; then
    echo "[ERROR] --backup is required (use --list to see the backups the cluster has)." >&2
    exit 1
fi
if [[ "${HEALTH_TIMEOUT}" != <-> ]]; then
    echo "[ERROR] --health-timeout must be a number of minutes (got '${HEALTH_TIMEOUT}')." >&2
    exit 1
fi

if [[ -n "${TARGET}" ]]; then
    ENV_TARGET="$(oadp_resolve_config "${TARGET_CONFIG_DIR}" "${TARGET_CONFIG_SUFFIX}" target "${TARGET}" 1.2_generate_restore_target_config.sh)"
    export ENV_TARGET
fi
BUCKET_FILE=""
_bucket_files=("${BUCKET_CONFIG_DIR}"/*"${BUCKET_CONFIG_SUFFIX}"(N))
if [[ -n "${BUCKET}" ]] || (( ${#_bucket_files} )); then
    BUCKET_FILE="$(oadp_resolve_config "${BUCKET_CONFIG_DIR}" "${BUCKET_CONFIG_SUFFIX}" bucket "${BUCKET}" 1.1_generate_backup_bucket_config.sh)"
fi

# --- Env load (repo root found above) ---
source "${REPO_ROOT}/env_bootstrap.sh"
[[ -n "${TARGET}" ]] && oadp_require_target_login

[[ -n "${BUCKET_FILE}" ]] && oadp_load_bucket "${BUCKET_FILE}"
oadp_require_vars OCP_URL OC_LOGIN OADP_PROJECT PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS
oadp_registry_flags

eval "${OC_LOGIN}"
oadp_check_cluster
oadp_set_client_namespace
oadp_check_bsl 6

if [[ "${LIST_ONLY}" == "true" ]]; then
    cpd-cli oadp tenant-backup list --namespace="${OADP_PROJECT}"
    exit 0
fi

# Velero syncs backups from the bucket into the cluster about once a minute, so
# a backup taken on another cluster can take a moment to appear here.
backup_visible() {
    cpd-cli oadp tenant-backup list --namespace="${OADP_PROJECT}" 2>/dev/null | grep -qw -- "${BACKUP_NAME}"
}
if ! backup_visible; then
    echo "[INFO] Waiting up to ${SYNC_TIMEOUT_MIN}m for tenant backup ${BACKUP_NAME} to sync from the bucket..."
    for (( i = 0; i < SYNC_TIMEOUT_MIN * 4; i++ )); do
        sleep 15
        backup_visible && break
    done
fi
if ! backup_visible; then
    echo "[ERROR] Tenant backup ${BACKUP_NAME} is not visible on ${OCP_URL}. Backups this cluster sees:" >&2
    cpd-cli oadp tenant-backup list --namespace="${OADP_PROJECT}" >&2 || true
    exit 1
fi
echo "[OK] Tenant backup ${BACKUP_NAME} is visible on this cluster"

EXISTING_NS=()
for ns in "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}"; do
    oc get namespace "${ns}" >/dev/null 2>&1 && EXISTING_NS+=("${ns}")
done
if (( ${#EXISTING_NS} )) && [[ "${FORCE}" != "true" ]]; then
    echo "[ERROR] ${EXISTING_NS[*]} already exist(s) on ${OCP_URL}. tenant-restore recreates the instance there;" >&2
    echo "[ERROR] delete the old instance first, or pass --force to restore into the existing namespaces." >&2
    exit 1
fi

[[ -z "${RESTORE_NAME}" ]] && RESTORE_NAME="restore-$(date +%Y%m%d-%H%M%S)"
RESTORE_NAME="${(L)RESTORE_NAME}"
if [[ ! "${RESTORE_NAME}" =~ '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || ${#RESTORE_NAME} -gt 63 ]]; then
    echo "[ERROR] Restore name '${RESTORE_NAME}' must be lowercase letters, digits and '-', at most 63 characters." >&2
    exit 1
fi

echo ""
echo "  Cluster:   ${OCP_URL}${TARGET:+ (target config: ${ENV_TARGET:t})}"
echo "  Backup:    ${BACKUP_NAME}"
echo "  Restore:   ${RESTORE_NAME}"
echo "  Instance:  ${PROJECT_CPD_INST_OPERATORS} (operators) / ${PROJECT_CPD_INST_OPERANDS} (operands)"
(( ${#EXISTING_NS} )) && echo "  --force:   restoring into existing ${EXISTING_NS[*]}"
echo ""
oadp_confirm "This restores Software Hub onto ${OCP_URL}."

RESTORE_FLAGS=(
    --from-tenant-backup="${BACKUP_NAME}"
    --namespace="${OADP_PROJECT}"
)
[[ "${FORCE}" == "true" ]] && RESTORE_FLAGS+=(--force)
[[ -n "${OADP_S3_CACERT_FILE:-}" ]] && RESTORE_FLAGS+=(--cacert="${OADP_S3_CACERT_FILE}")

LOG_FILE="$(oadp_log_file "${RESTORE_NAME}")"
START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[INFO] cpd-cli output is also written to ${LOG_FILE}"
echo "[INFO] Starting tenant restore ${RESTORE_NAME} from ${BACKUP_NAME}"
cpd-cli oadp tenant-restore create "${RESTORE_NAME}" "${RESTORE_FLAGS[@]}" "${OADP_REGISTRY_FLAGS[@]}" \
    "${EXTRA_ARGS[@]}" --log-level=debug --verbose 2>&1 | tee -a "${LOG_FILE}"

oadp_wait_for_br_cr tenantrestores "${RESTORE_NAME}" "${WAIT_TIMEOUT}" 2>&1 | tee -a "${LOG_FILE}"

echo ""
cpd-cli oadp tenant-restore status "${RESTORE_NAME}" --namespace="${OADP_PROJECT}" --details 2>&1 | tee -a "${LOG_FILE}"
echo ""
# Backups taken with the snapshot data mover come back through DataDownloads
# (snapshot contents pulled from the bucket); other backups create none.
oadp_datamover_report datadownloads "${START_TS}" > >(tee -a "${LOG_FILE}") \
    || echo "[WARN] Some snapshot downloads failed: oc get datadownloads.velero.io -n ${OADP_PROJECT}"
if (( HEALTH_TIMEOUT > 0 )); then
    oadp_check_workloads "${HEALTH_TIMEOUT}" "" "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}" \
        || echo "[WARN] Not every restored workload is ready yet; the operators may still be reconciling. Re-check later."
fi
echo ""
echo "[OK] Tenant restore ${RESTORE_NAME} finished (details above, log: ${LOG_FILE})"
echo "[INFO] Logs: cpd-cli oadp tenant-restore log ${RESTORE_NAME}"
echo "[INFO] Check the instance: oc get ibmcpd -n ${PROJECT_CPD_INST_OPERANDS}; cpd-cli manage get-cr-status --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}"
if [[ -n "${TARGET}" ]]; then
    echo "[INFO] To back up the restored instance from here, finish the OADP setup on this cluster:"
    echo "[INFO]   ${SCRIPT_DIR}/2_install_oadp_br_utilities.sh --target ${TARGET} --full"
fi
