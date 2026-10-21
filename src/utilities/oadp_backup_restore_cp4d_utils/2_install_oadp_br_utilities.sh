#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Installs what 'cpd-cli oadp tenant-backup' / 'tenant-restore' need on a cluster,
# with cpd-cli, pointed at the S3 bucket from a bucket config:
#
#   1. the OADP project and the Red Hat OADP operator (OLM subscription on the
#      catalog's default channel; see the note at that step for why not cpd-cli)
#   2. the object storage credentials secret and the DataProtectionApplication
#      (cpd-cli oadp dpa create, node agent with kopia, IBM velero plugins, whose
#      images are checked against the registry, with a fallback for a missing
#      tag, and pulled onto the workers first), then waits for the backup
#      storage location to be Available
#   3. cpdbr-tenant in the instance's operators project (cpd-cli oadp install --component=cpdbr-tenant)
#   4. the Backup Restore Orchestration service (cpd-cli manage install-components --components=br_orchestration)
#   5. optionally cpdbr-agent (--with-agent)
#
# Source cluster: run without --target; uses the normal env (cpd_vars.sh, or
# ENV_TARGET). Restore target: pass --target <name>; only that config is loaded.
#
# Steps 3-4 depend on whether Software Hub is already on the cluster (an ibmcpd
# CR in PROJECT_CPD_INST_OPERANDS):
#   installed     - full cpdbr-tenant (upgraded in place when it exists) + br_orchestration
#   not installed - cpdbr-tenant cluster roles only (--rbac-only): what an empty
#                   restore target needs before 'tenant-restore'. Re-run after
#                   the restore to get the full install, so the restored
#                   instance can be backed up itself.
# --full / --rbac-only override the detection.
#
# Safe to re-run. An existing DPA is kept (its bucket is checked against the
# bucket config) unless --recreate-dpa. OADP_PROJECT (default oadp-operator),
# OADP_DPA_NAME (cpd-dpa), OADP_OPERATOR_CHANNEL (the catalog's default),
# OADP_IMAGE_PREPULL_MINUTES (30), OADP_PLUGIN_IMAGE_FALLBACK (true) and
# OADP_<PLUGIN>_PLUGIN_IMAGE (see step 2) can be set in the loaded config.
#
#   2_install_oadp_br_utilities.sh [options]
#     --bucket <name|path>        bucket config (optional when there is only one)
#     --target <name|path>        restore target config; omit for the source cluster
#     --full | --rbac-only        force the cpdbr-tenant mode (see above)
#     --with-agent                also install cpdbr-agent (disk usage reporting)
#     --recreate-dpa              delete the DPA(s) in OADP_PROJECT and create a new one
#     --skip-oadp-operator        OADP is installed some other way; only check its CSV
#     --skip-br-orchestration     do not install the br_orchestration component
#     --skip-image-prepull        do not pull the velero plugin images onto the workers before the DPA
#     --no-plugin-image-fallback  use cpd-cli's plugin images even when the registry lacks their tag
#                                 (by default such an image is swapped for the newest earlier tag in
#                                 the same release line, e.g. 5.4.0.7 -> 5.4.0.6, in a new or the
#                                 existing DPA). OADP_PLUGIN_IMAGE_FALLBACK=false in the config does
#                                 the same; --plugin-image-fallback turns it back on.
#     --upgrade                  reinstall br_orchestration even when its CR exists
#     --snapshot-move-data        turn on the snapshot data mover, so online backups upload their CSI
#                                 snapshots to the bucket (DPA defaultSnapshotMoveData), and label one
#                                 VolumeSnapshotClass per CSI driver the instance uses for Velero.
#                                 Prints which instance volumes can be snapshotted at all; does not
#                                 change offline backups. OADP_SNAPSHOT_MOVE_DATA=true in the config
#                                 does the same (and survives --recreate-dpa).
#     --no-snapshot-move-data     turn it off again
#     --resources <preset>        CPU/memory requests for Velero, the node agents and the OADP operator
#                                 (limits stay at the defaults: Velero 1 CPU/4Gi, node agent 1/32Gi,
#                                 operator 1/512Mi):
#                                   minimal  Velero 100m/154Mi, node agent 50m/154Mi, operator 50m/77Mi
#                                   small    40% below medium: 600m/154Mi, 300m/154Mi, 300m/77Mi (default)
#                                   medium   the cpd-cli / OADP defaults: 1/256Mi, 500m/256Mi, 500m/128Mi
#                                 A new DPA and subscription always get the preset. An existing one is
#                                 only changed when --resources or OADP_RESOURCE_PRESET (config) is given,
#                                 and not while a Velero backup or restore runs: the change restarts Velero.
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Repo root only for now: the env is loaded after the options are parsed,
# because --target decides which config to load.
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; unset _b
source "${REPO_ROOT}/src/helpers/oadp_br_helpers.sh"

SECONDS=0
_cred_dir=""
trap '[[ -n "${_cred_dir}" ]] && rm -rf "${_cred_dir}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

BUCKET=""
TARGET=""
TENANT_MODE=""
WITH_AGENT=false
RECREATE_DPA=false
SKIP_OADP_OPERATOR=false
SKIP_BR_ORCHESTRATION=false
SKIP_IMAGE_PREPULL=false
# Empty: OADP_PLUGIN_IMAGE_FALLBACK from the config, else true (picked up after the env load).
PLUGIN_IMAGE_FALLBACK=""
UPGRADE=false
# Empty: leave the DPA's setting alone. OADP_SNAPSHOT_MOVE_DATA in the loaded
# config only applies when the env is loaded, so it is picked up further down.
SNAPSHOT_MOVE_DATA=""
# Empty: OADP_RESOURCE_PRESET from the config, else small (picked up after the env load).
RESOURCE_PRESET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket)                BUCKET="${2:?--bucket needs a config name or path}"; shift 2 ;;
        --target)                TARGET="${2:?--target needs a config name or path}"; shift 2 ;;
        --full)                  TENANT_MODE=full; shift ;;
        --rbac-only)             TENANT_MODE=rbac-only; shift ;;
        --with-agent)            WITH_AGENT=true; shift ;;
        --recreate-dpa)          RECREATE_DPA=true; shift ;;
        --skip-oadp-operator)    SKIP_OADP_OPERATOR=true; shift ;;
        --skip-br-orchestration) SKIP_BR_ORCHESTRATION=true; shift ;;
        --skip-image-prepull)    SKIP_IMAGE_PREPULL=true; shift ;;
        --plugin-image-fallback)    PLUGIN_IMAGE_FALLBACK=true; shift ;;
        --no-plugin-image-fallback) PLUGIN_IMAGE_FALLBACK=false; shift ;;
        --upgrade)               UPGRADE=true; shift ;;
        --snapshot-move-data)    SNAPSHOT_MOVE_DATA=true; shift ;;
        --no-snapshot-move-data) SNAPSHOT_MOVE_DATA=false; shift ;;
        --resources)             RESOURCE_PRESET="${2:?--resources needs minimal, small or medium}"; shift 2 ;;
        -h|--help)               oadp_usage "$0"; exit 0 ;;
        *)                       echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done

BUCKET_FILE="$(oadp_resolve_config "${BUCKET_CONFIG_DIR}" "${BUCKET_CONFIG_SUFFIX}" bucket "${BUCKET}" 1.1_generate_backup_bucket_config.sh)"
if [[ -n "${TARGET}" ]]; then
    ENV_TARGET="$(oadp_resolve_config "${TARGET_CONFIG_DIR}" "${TARGET_CONFIG_SUFFIX}" target "${TARGET}" 1.2_generate_restore_target_config.sh)"
    export ENV_TARGET
fi

# --- Env load (repo root found above) ---
source "${REPO_ROOT}/env_bootstrap.sh"
[[ -n "${TARGET}" ]] && oadp_require_target_login

oadp_load_bucket "${BUCKET_FILE}"
oadp_require_vars OCP_URL OC_LOGIN OADP_PROJECT PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS
[[ -z "${SNAPSHOT_MOVE_DATA}" ]] && SNAPSHOT_MOVE_DATA="${OADP_SNAPSHOT_MOVE_DATA:-}"
if [[ -n "${SNAPSHOT_MOVE_DATA}" && "${SNAPSHOT_MOVE_DATA}" != "true" && "${SNAPSHOT_MOVE_DATA}" != "false" ]]; then
    echo "[ERROR] OADP_SNAPSHOT_MOVE_DATA must be true or false (got '${SNAPSHOT_MOVE_DATA}')." >&2
    exit 1
fi
[[ -z "${PLUGIN_IMAGE_FALLBACK}" ]] && PLUGIN_IMAGE_FALLBACK="${OADP_PLUGIN_IMAGE_FALLBACK:-true}"
if [[ "${PLUGIN_IMAGE_FALLBACK}" != "true" && "${PLUGIN_IMAGE_FALLBACK}" != "false" ]]; then
    echo "[ERROR] OADP_PLUGIN_IMAGE_FALLBACK must be true or false (got '${PLUGIN_IMAGE_FALLBACK}')." >&2
    exit 1
fi
# Given explicitly (option or config), the preset is also applied to an existing
# DPA/subscription; the default only goes into ones created here.
RESOURCE_PRESET_EXPLICIT=true
[[ -z "${RESOURCE_PRESET}" ]] && RESOURCE_PRESET="${OADP_RESOURCE_PRESET:-}"
[[ -z "${RESOURCE_PRESET}" ]] && { RESOURCE_PRESET=small; RESOURCE_PRESET_EXPLICIT=false; }
typeset -A RES
case "${RESOURCE_PRESET}" in
    minimal) RES=(velero_cpu 100m velero_mem 154Mi agent_cpu 50m  agent_mem 154Mi operator_cpu 50m  operator_mem 77Mi) ;;
    small)   RES=(velero_cpu 600m velero_mem 154Mi agent_cpu 300m agent_mem 154Mi operator_cpu 300m operator_mem 77Mi) ;;
    medium)  RES=(velero_cpu 1    velero_mem 256Mi agent_cpu 500m agent_mem 256Mi operator_cpu 500m operator_mem 128Mi) ;;
    *)       echo "[ERROR] --resources / OADP_RESOURCE_PRESET must be minimal, small or medium (got '${RESOURCE_PRESET}')." >&2; exit 1 ;;
esac
# The OADP operator's own limits; a subscription resources override replaces
# requests and limits together, so they are restated.
OPERATOR_RESOURCES_JSON="{\"requests\":{\"cpu\":\"${RES[operator_cpu]}\",\"memory\":\"${RES[operator_mem]}\"},\"limits\":{\"cpu\":\"1\",\"memory\":\"512Mi\"}}"

oadp_registry_flags
LOG_FILE="$(oadp_log_file install-${${OCP_URL#*://api.}%%[.:]*})"
echo "[INFO] cpd-cli output is also written to ${LOG_FILE}"

eval "${OC_LOGIN}"
oadp_check_cluster
cpd-cli oadp version 2>&1 | tee -a "${LOG_FILE}"

if [[ -z "${TENANT_MODE}" ]]; then
    if oc get ibmcpd ibmcpd-cr -n "${PROJECT_CPD_INST_OPERANDS}" >/dev/null 2>&1; then
        TENANT_MODE=full
        echo "[INFO] Software Hub found in ${PROJECT_CPD_INST_OPERANDS}: full cpdbr-tenant install"
    else
        TENANT_MODE=rbac-only
        echo "[INFO] No Software Hub in ${PROJECT_CPD_INST_OPERANDS}: cpdbr-tenant cluster roles only (restore target prep)"
    fi
fi

# ------------------------------------------------------------------------------
# 1. OADP project + operator
# ------------------------------------------------------------------------------
if oc get namespace "${OADP_PROJECT}" >/dev/null 2>&1; then
    echo "[SKIP] Project ${OADP_PROJECT} exists"
else
    oc new-project "${OADP_PROJECT}" >/dev/null
    echo "[OK] Created project ${OADP_PROJECT}"
fi
# IBM's OADP setup clears the project's node selector so the node agent
# daemonset can run on every worker.
oc annotate namespace "${OADP_PROJECT}" openshift.io/node-selector="" --overwrite >/dev/null

# The operator is subscribed to through OLM here, not with
# 'cpd-cli oadp install --component=oadp-operator': that component subscribes
# to stable-<x.y> of its built-in --oadp-version (v1.4.4 in cpd-cli 14.4), and
# newer OpenShift catalogs no longer carry OADP 1.4 (4.21 only has 'stable' ->
# 1.5.x), so its subscription never resolves (ConstraintsNotSatisfiable). The
# catalog's default channel is the OADP release Red Hat ships for this
# OpenShift version; OADP_OPERATOR_CHANNEL overrides it.
source "${REPO_ROOT}/scripts/operator_install_helpers.sh"
OADP_PACKAGE=redhat-oadp-operator
OADP_SUBSCRIPTION=redhat-oadp-operator
OADP_CSV_PREFIX='oadp-operator\.'
SUB_CREATED=false

if [[ "$(cp4d_csv_phase "${OADP_PROJECT}" "${OADP_CSV_PREFIX}")" == "Succeeded" ]]; then
    echo "[SKIP] OADP operator already installed in ${OADP_PROJECT}"
elif [[ "${SKIP_OADP_OPERATOR}" == "true" ]]; then
    echo "[ERROR] --skip-oadp-operator given, but no Succeeded oadp-operator CSV in ${OADP_PROJECT}." >&2
    exit 1
else
    _channels="$(oc get packagemanifest "${OADP_PACKAGE}" -n openshift-marketplace \
        -o jsonpath='{.status.channels[*].name}' 2>/dev/null || true)"
    if [[ -z "${_channels}" ]]; then
        echo "[ERROR] Package ${OADP_PACKAGE} not found in openshift-marketplace (on a disconnected cluster, mirror the Red Hat operator catalog first)." >&2
        exit 1
    fi
    OADP_CHANNEL="${OADP_OPERATOR_CHANNEL:-$(oc get packagemanifest "${OADP_PACKAGE}" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')}"
    if (( ! ${${(s: :)_channels}[(Ie)${OADP_CHANNEL}]} )); then
        echo "[ERROR] Channel '${OADP_CHANNEL}' is not in this cluster's ${OADP_PACKAGE} catalog (available: ${_channels})." >&2
        exit 1
    fi
    echo "[INFO] Installing the OADP operator (${OADP_PACKAGE}, channel ${OADP_CHANNEL}) into ${OADP_PROJECT}"
    cp4d_ensure_operatorgroup "${OADP_PROJECT}" oadp-operatorgroup "${OADP_PROJECT}"

    _sub_channel="$(oc get subscriptions.operators.coreos.com "${OADP_SUBSCRIPTION}" -n "${OADP_PROJECT}" -o jsonpath='{.spec.channel}' 2>/dev/null || true)"
    _sub_start="$(oc get subscriptions.operators.coreos.com "${OADP_SUBSCRIPTION}" -n "${OADP_PROJECT}" -o jsonpath='{.spec.startingCSV}' 2>/dev/null || true)"
    if [[ -z "${_sub_channel}" ]]; then
        # medium is the operator's own default: no override then.
        _sub_config=""
        [[ "${RESOURCE_PRESET}" != "medium" ]] && _sub_config="  config: {\"resources\": ${OPERATOR_RESOURCES_JSON}}"
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OADP_SUBSCRIPTION}
  namespace: ${OADP_PROJECT}
spec:
  channel: ${OADP_CHANNEL}
  installPlanApproval: Automatic
  name: ${OADP_PACKAGE}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
${_sub_config}
EOF
        SUB_CREATED=true
    elif [[ "${_sub_channel}" != "${OADP_CHANNEL}" || -n "${_sub_start}" ]]; then
        # The subscription exists but installed no CSV (checked above) - e.g. one
        # cpd-cli made on stable-1.4 with startingCSV pinned to v1.4.4. Nothing
        # runs from it, so repointing it is safe; the pin would hold it on 1.4.
        echo "[INFO] Repointing subscription ${OADP_SUBSCRIPTION} from '${_sub_channel}'${_sub_start:+ (startingCSV ${_sub_start})} to '${OADP_CHANNEL}'"
        _patch="[{\"op\":\"replace\",\"path\":\"/spec/channel\",\"value\":\"${OADP_CHANNEL}\"}"
        [[ -n "${_sub_start}" ]] && _patch+=",{\"op\":\"remove\",\"path\":\"/spec/startingCSV\"}"
        oc patch subscriptions.operators.coreos.com "${OADP_SUBSCRIPTION}" -n "${OADP_PROJECT}" --type=json -p "${_patch}]"
    fi

    echo "[INFO] Waiting up to 10m for the OADP operator CSV to succeed..."
    cp4d_wait_for_csv "${OADP_PROJECT}" "${OADP_CSV_PREFIX}" 600
    echo "[OK] OADP operator installed: $(oc get subscriptions.operators.coreos.com "${OADP_SUBSCRIPTION}" -n "${OADP_PROJECT}" -o jsonpath='{.status.installedCSV}')"
fi

# Resource preset on an existing operator subscription (only when asked for).
# OLM rolls the operator's controller; Velero and running backups are not touched.
if [[ "${RESOURCE_PRESET_EXPLICIT}" == "true" && "${SUB_CREATED}" != "true" ]]; then
    _sub="$(oc get subscriptions.operators.coreos.com -n "${OADP_PROJECT}" \
        -o jsonpath="{range .items[?(@.spec.name=='${OADP_PACKAGE}')]}{.metadata.name}{end}" 2>/dev/null || true)"
    if [[ -z "${_sub}" ]]; then
        echo "[WARN] No ${OADP_PACKAGE} subscription in ${OADP_PROJECT}; the operator keeps its resources"
    elif [[ "${RESOURCE_PRESET}" == "medium" ]]; then
        if [[ -n "$(oc get subscriptions.operators.coreos.com "${_sub}" -n "${OADP_PROJECT}" -o jsonpath='{.spec.config.resources}')" ]]; then
            oc patch subscriptions.operators.coreos.com "${_sub}" -n "${OADP_PROJECT}" --type=json \
                -p '[{"op":"remove","path":"/spec/config/resources"}]' >/dev/null
            echo "[OK] OADP operator back to its default resources (medium)"
        fi
    else
        oc patch subscriptions.operators.coreos.com "${_sub}" -n "${OADP_PROJECT}" --type=merge \
            -p "{\"spec\":{\"config\":{\"resources\":${OPERATOR_RESOURCES_JSON}}}}" >/dev/null
        echo "[OK] OADP operator resources: ${RESOURCE_PRESET} (requests ${RES[operator_cpu]} CPU / ${RES[operator_mem]})"
    fi
fi

for _ in {1..30}; do
    oc get crd dataprotectionapplications.oadp.openshift.io >/dev/null 2>&1 && break
    sleep 10
done
oc wait --for=condition=Established crd/dataprotectionapplications.oadp.openshift.io --timeout=5m >/dev/null

# ------------------------------------------------------------------------------
# 2. Credentials secret + DataProtectionApplication
# ------------------------------------------------------------------------------
# Velero reads AWS-style credentials from the 'cloud' key. Written to a private
# temp file so the keys never appear on a command line.
_cred_dir="$(mktemp -d)"
( umask 077; printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' \
    "${OADP_S3_ACCESS_KEY_ID}" "${OADP_S3_SECRET_ACCESS_KEY}" > "${_cred_dir}/cloud" )
oc create secret generic "${OADP_CREDENTIALS_SECRET}" -n "${OADP_PROJECT}" \
    --from-file=cloud="${_cred_dir}/cloud" --dry-run=client -o yaml | oc apply -f - >/dev/null
rm -rf "${_cred_dir}"; _cred_dir=""
echo "[OK] Secret ${OADP_CREDENTIALS_SECRET} in ${OADP_PROJECT} holds the bucket credentials"

EXISTING_DPAS=("${(@f)$(oc get dataprotectionapplications.oadp.openshift.io -n "${OADP_PROJECT}" -o name 2>/dev/null)}")
EXISTING_DPAS=("${(@)EXISTING_DPAS:#}")
if (( ${#EXISTING_DPAS} )) && [[ "${RECREATE_DPA}" == "true" ]]; then
    echo "[INFO] --recreate-dpa: deleting ${EXISTING_DPAS[*]} (backups in the bucket are not touched)"
    oc delete "${EXISTING_DPAS[@]}" -n "${OADP_PROJECT}" --wait=true
    EXISTING_DPAS=()
fi

if (( ${#EXISTING_DPAS} )); then
    echo "[SKIP] DPA already present: ${EXISTING_DPAS[*]} (use --recreate-dpa to replace it)"
    PLUGIN_IMAGES=(${=$(oc get dataprotectionapplications.oadp.openshift.io -n "${OADP_PROJECT}" \
        -o jsonpath='{range .items[*]}{.spec.configuration.velero.customPlugins[*].image}{" "}{end}')})
    PLUGIN_IMAGES=("${(@u)PLUGIN_IMAGES}")
    EXPLICIT_PLUGIN_IMAGES=()
else
    BSL_CONFIG="region=${OADP_S3_REGION},s3ForcePathStyle=${OADP_S3_FORCE_PATH_STYLE}"
    [[ -n "${OADP_S3_URL}" ]] && BSL_CONFIG+=",s3Url=${OADP_S3_URL}"
    DPA_FLAGS=(
        --namespace="${OADP_PROJECT}"
        --provider=aws
        --bucket="${OADP_BUCKET_NAME}"
        --prefix="${OADP_BUCKET_PREFIX}"
        --config="${BSL_CONFIG}"
        --credential="${OADP_CREDENTIALS_SECRET}=cloud"
        --enable-node-agent
        --uploader-type=kopia
        # Offline backups copy volume data file by file; large volumes need longer than the 4h default.
        --node-agent-timeout="${OADP_NODE_AGENT_TIMEOUT:-72h}"
        # Resource preset (requests only; cpd-cli's default limits stay).
        --velero-pod-cpu-request="${RES[velero_cpu]}"
        --velero-pod-mem-request="${RES[velero_mem]}"
        --node-agent-pod-cpu-request="${RES[agent_cpu]}"
        --node-agent-pod-mem-request="${RES[agent_mem]}"
    )
    [[ -n "${OADP_S3_CACERT_FILE:-}" ]] && DPA_FLAGS+=(--cacert="${OADP_S3_CACERT_FILE}")
    # OADP_CPDBR_VELERO_PLUGIN_IMAGE, OADP_SWHUB_VELERO_PLUGIN_IMAGE,
    # OADP_CPFS_OADP_PLUGIN_IMAGE and OADP_DB2U_VELERO_PLUGIN_IMAGE replace
    # cpd-cli's built-in plugin images (they are tagged with the cpd-cli version,
    # which the registry does not always carry: cpd-cli 5.4.0.7 asks for
    # db2u-velero-plugin:5.4.0.7, but icr.io stops at 5.4.0.6). Images set
    # this way are used as given, never swapped by the fallback below.
    EXPLICIT_PLUGIN_IMAGES=()
    for _p in cpdbr-velero swhub-velero cpfs-oadp db2u-velero; do
        _v="OADP_${${_p:u}//-/_}_PLUGIN_IMAGE"
        [[ -n "${(P)_v:-}" ]] || continue
        DPA_FLAGS+=(--${_p}-plugin-image="${(P)_v}")
        EXPLICIT_PLUGIN_IMAGES+=("${(P)_v}")
    done
    # The plugins the DPA will reference, as <name>=<image>, from cpd-cli
    # itself. If the dry run fails, the real create below fails the same way,
    # on screen.
    PLUGIN_SPECS=(${=$(cpd-cli oadp dpa create "${OADP_DPA_NAME}" "${DPA_FLAGS[@]}" "${OADP_REGISTRY_FLAGS[@]}" --dry-run 2>>"${LOG_FILE}" \
        | oc create --dry-run=client -f - -o jsonpath='{range .spec.configuration.velero.customPlugins[*]}{.name}{"="}{.image}{" "}{end}' || true)})
    PLUGIN_IMAGES=("${(@)PLUGIN_SPECS#*=}")
fi

# Plugin image fallback (on by default): a plugin image whose tag the registry
# does not have is swapped for the newest earlier tag of the same release line
# (db2u-velero-plugin:5.4.0.7 -> :5.4.0.6). A new DPA is created with the
# swapped images; an existing one has them patched in, which rolls velero.
if [[ "${PLUGIN_IMAGE_FALLBACK}" == "true" ]]; then
    oadp_find_image_fallbacks "${(@)PLUGIN_IMAGES:|EXPLICIT_PLUGIN_IMAGES}"
    if (( ${#OADP_IMAGE_FALLBACKS} )); then
        if (( ${#EXISTING_DPAS} )); then
            for _dpa in "${EXISTING_DPAS[@]}"; do
                _imgs=(${=$(oc get "${_dpa}" -n "${OADP_PROJECT}" -o jsonpath='{.spec.configuration.velero.customPlugins[*].image}')})
                for (( _i = 1; _i <= ${#_imgs}; _i++ )); do
                    _new="${OADP_IMAGE_FALLBACKS[${_imgs[_i]}]:-}"
                    [[ -n "${_new}" ]] || continue
                    oc patch "${_dpa}" -n "${OADP_PROJECT}" --type=json \
                        -p "[{\"op\":\"replace\",\"path\":\"/spec/configuration/velero/customPlugins/$(( _i - 1 ))/image\",\"value\":\"${_new}\"}]" >/dev/null
                    echo "[OK] ${_dpa}: plugin image ${_imgs[_i]} -> ${_new}"
                done
            done
        else
            for _s in "${PLUGIN_SPECS[@]}"; do
                _new="${OADP_IMAGE_FALLBACKS[${_s#*=}]:-}"
                [[ -n "${_new}" ]] && DPA_FLAGS+=(--${_s%%=*}-image="${_new}")
            done
        fi
        for (( _i = 1; _i <= ${#PLUGIN_IMAGES}; _i++ )); do
            PLUGIN_IMAGES[_i]="${OADP_IMAGE_FALLBACKS[${PLUGIN_IMAGES[_i]}]:-${PLUGIN_IMAGES[_i]}}"
        done
    fi
fi

# Velero's pod pulls each plugin image in turn as an init container, and from
# icr.io that can outlast 'dpa create --wait'. Pulling them onto the workers
# first, in parallel, leaves that wait with nothing to download, and an image
# that does not exist fails here, by name, not as a velero pod stuck in
# ImagePullBackOff.
if [[ "${SKIP_IMAGE_PREPULL}" == "true" ]]; then
    echo "[SKIP] Velero plugin image pre-pull (--skip-image-prepull)"
elif ! oadp_prepull_images $(( ${OADP_IMAGE_PREPULL_MINUTES:-30} * 60 )) "${PLUGIN_IMAGES[@]}"; then
    echo "[ERROR] Point the failing plugin at an image that exists in the config, e.g." >&2
    echo "[ERROR]   OADP_DB2U_VELERO_PLUGIN_IMAGE=icr.io/db2u/db2u-velero-plugin:5.4.0.6" >&2
    (( ${#EXISTING_DPAS} )) && echo "[ERROR] and re-run with --recreate-dpa (an existing DPA keeps the images it was created with)." >&2
    exit 1
fi

if (( ! ${#EXISTING_DPAS} )); then
    echo "[INFO] Creating DPA ${OADP_DPA_NAME} for s3://${OADP_BUCKET_NAME}/${OADP_BUCKET_PREFIX}"
    cpd-cli oadp dpa create "${OADP_DPA_NAME}" "${DPA_FLAGS[@]}" "${OADP_REGISTRY_FLAGS[@]}" \
        --wait --wait-timeout=15m --log-level=debug --verbose 2>&1 | tee -a "${LOG_FILE}"
fi

# Resource preset on an existing DPA (only when asked for). Changing it restarts
# Velero and the node agents, which would break a backup or restore in flight.
if (( ${#EXISTING_DPAS} )) && [[ "${RESOURCE_PRESET_EXPLICIT}" == "true" ]]; then
    _want="${RES[velero_cpu]} ${RES[velero_mem]} ${RES[agent_cpu]} ${RES[agent_mem]}"
    _active=(${(f)"$(oc get backups.velero.io,restores.velero.io -n "${OADP_PROJECT}" \
        -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
        | awk '$2 ~ /^(New|InProgress|WaitingForPluginOperations|Finalizing)/ {print $1}' || true)"})
    for _dpa in "${EXISTING_DPAS[@]}"; do
        _have="$(oc get "${_dpa}" -n "${OADP_PROJECT}" -o jsonpath='{.spec.configuration.velero.podConfig.resourceAllocations.requests.cpu}{" "}{.spec.configuration.velero.podConfig.resourceAllocations.requests.memory}{" "}{.spec.configuration.nodeAgent.podConfig.resourceAllocations.requests.cpu}{" "}{.spec.configuration.nodeAgent.podConfig.resourceAllocations.requests.memory}')"
        if [[ "${_have}" == "${_want}" ]]; then
            echo "[SKIP] ${_dpa} already has the ${RESOURCE_PRESET} resource preset"
        elif (( ${#_active} )); then
            echo "[WARN] Not applying the ${RESOURCE_PRESET} preset to ${_dpa}: it restarts Velero, and ${_active[*]} is still running."
            echo "[WARN] Re-run with --resources ${RESOURCE_PRESET} once it has finished."
        else
            oc patch "${_dpa}" -n "${OADP_PROJECT}" --type=merge -p "{\"spec\":{\"configuration\":{
                \"velero\":{\"podConfig\":{\"resourceAllocations\":{\"requests\":{\"cpu\":\"${RES[velero_cpu]}\",\"memory\":\"${RES[velero_mem]}\"}}}},
                \"nodeAgent\":{\"podConfig\":{\"resourceAllocations\":{\"requests\":{\"cpu\":\"${RES[agent_cpu]}\",\"memory\":\"${RES[agent_mem]}\"}}}}}}}" >/dev/null
            echo "[OK] ${_dpa}: ${RESOURCE_PRESET} resource preset (Velero ${RES[velero_cpu]}/${RES[velero_mem]}, node agent ${RES[agent_cpu]}/${RES[agent_mem]}); Velero restarts"
        fi
    done
elif (( ${#EXISTING_DPAS} )); then
    echo "[INFO] Existing DPA keeps its resources; pass --resources minimal|small|medium to change them"
fi

# Snapshot data mover (opt-in): makes online backups upload their CSI snapshot
# contents to the bucket instead of leaving them in the cluster's storage.
# Offline backups take no snapshots, so this does not change them.
if [[ -n "${SNAPSHOT_MOVE_DATA}" ]]; then
    if [[ "${SNAPSHOT_MOVE_DATA}" == "true" ]]; then
        echo "[INFO] Instance volumes and their CSI snapshot support:"
        oadp_storage_report "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}"
        # Velero picks the snapshot class per CSI driver by this label. Only
        # drivers without a labeled class get one, so an existing choice stays.
        for _c in "${OADP_UNLABELED_SNAPCLASSES[@]}"; do
            oc label volumesnapshotclasses.snapshot.storage.k8s.io "${_c}" velero.io/csi-volumesnapshot-class=true >/dev/null
            echo "[OK] Labeled VolumeSnapshotClass ${_c} for Velero"
        done
        if (( OADP_NO_SNAPSHOT_PVS )); then
            echo "[WARN] ${OADP_NO_SNAPSHOT_PVS} of ${OADP_INSTANCE_PVS} instance volume(s) cannot be CSI-snapshotted, so online backups"
            echo "[WARN] of this instance stay unavailable; offline backups work on any storage."
        fi
    fi
    for _dpa in ${(f)"$(oc get dataprotectionapplications.oadp.openshift.io -n "${OADP_PROJECT}" -o name)"}; do
        oc patch "${_dpa}" -n "${OADP_PROJECT}" --type=merge \
            -p "{\"spec\":{\"configuration\":{\"velero\":{\"defaultSnapshotMoveData\":${SNAPSHOT_MOVE_DATA}}}}}" >/dev/null
        echo "[OK] ${_dpa}: defaultSnapshotMoveData=${SNAPSHOT_MOVE_DATA}"
    done
fi

oadp_check_bsl 60
oadp_set_client_namespace

# ------------------------------------------------------------------------------
# 3. cpdbr-tenant
# ------------------------------------------------------------------------------
TENANT_FLAGS=(
    --component=cpdbr-tenant
    --namespace="${OADP_PROJECT}"
    --tenant-operator-namespace="${PROJECT_CPD_INST_OPERATORS}"
)
# Recipes are IBM Fusion resources; with plain OADP there is nothing to apply them to.
if ! oc get crd recipes.spp-data-protection.isf.ibm.com >/dev/null 2>&1; then
    TENANT_FLAGS+=(--skip-recipes=true)
fi
[[ -n "${PROJECT_SCHEDULING_SERVICE:-}" ]] && TENANT_FLAGS+=(--cpd-scheduler-namespace="${PROJECT_SCHEDULING_SERVICE}")
[[ -n "${OADP_IMAGE_PREFIX:-}" ]] && TENANT_FLAGS+=(--image-prefix="${OADP_IMAGE_PREFIX}")

TENANT_POD_SELECTOR="component=cpdbr-tenant,icpdsupport/app=br-service"
if [[ "${TENANT_MODE}" == "rbac-only" ]]; then
    echo "[INFO] Installing cpdbr-tenant cluster roles and bindings (--rbac-only)"
    cpd-cli oadp install "${TENANT_FLAGS[@]}" --rbac-only=true "${OADP_REGISTRY_FLAGS[@]}" --log-level=debug --verbose 2>&1 | tee -a "${LOG_FILE}"
else
    if [[ -n "$(oc get pods -n "${PROJECT_CPD_INST_OPERATORS}" -l "${TENANT_POD_SELECTOR}" -o name 2>/dev/null)" ]]; then
        echo "[INFO] cpdbr-tenant exists in ${PROJECT_CPD_INST_OPERATORS}: upgrading it to this cpd-cli's version"
        TENANT_FLAGS+=(--upgrade=true)
    else
        echo "[INFO] Installing cpdbr-tenant into ${PROJECT_CPD_INST_OPERATORS}"
    fi
    cpd-cli oadp install "${TENANT_FLAGS[@]}" "${OADP_REGISTRY_FLAGS[@]}" --log-level=debug --verbose 2>&1 | tee -a "${LOG_FILE}"
    # oc wait fails right away while no pod matches, so wait for one to exist first.
    for _ in {1..30}; do
        [[ -n "$(oc get pods -n "${PROJECT_CPD_INST_OPERATORS}" -l "${TENANT_POD_SELECTOR}" -o name 2>/dev/null)" ]] && break
        sleep 10
    done
    oc wait pod -n "${PROJECT_CPD_INST_OPERATORS}" -l "${TENANT_POD_SELECTOR}" --for=condition=Ready --timeout=10m
    echo "[OK] cpdbr-tenant is running:"
    oc get pods -n "${PROJECT_CPD_INST_OPERATORS}" -l "${TENANT_POD_SELECTOR}" \
        -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,IMAGE:.spec.containers[0].image'
fi

# ------------------------------------------------------------------------------
# 4. Backup Restore Orchestration (br_orchestration)
# ------------------------------------------------------------------------------
br_cr_exists() {
    local ns
    for ns in "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}"; do
        [[ -n "$(oc get backuprestoreorchestrations.bros.ibm.com -n "${ns}" -o name 2>/dev/null)" ]] && return 0
    done
    return 1
}

if [[ "${TENANT_MODE}" != "full" ]]; then
    echo "[SKIP] br_orchestration: installed into the instance's projects, so only once Software Hub is there"
elif [[ "${SKIP_BR_ORCHESTRATION}" == "true" ]]; then
    echo "[SKIP] br_orchestration (--skip-br-orchestration)"
elif br_cr_exists && [[ "${UPGRADE}" != "true" ]]; then
    echo "[SKIP] br_orchestration already installed (--upgrade to reinstall)"
else
    oadp_require_vars VERSION CPDM_OC_LOGIN
    eval "${CPDM_OC_LOGIN}"
    BR_FLAGS=(
        --license_acceptance=true
        --components=br_orchestration
        --release="${VERSION}"
        --operator_ns="${PROJECT_CPD_INST_OPERATORS}"
        --instance_ns="${PROJECT_CPD_INST_OPERANDS}"
        --upgrade="${UPGRADE}"
    )
    [[ -n "${IMAGE_PULL_PREFIX:-}" ]] && BR_FLAGS+=(--image_pull_prefix="${IMAGE_PULL_PREFIX}")
    [[ -n "${IMAGE_PULL_SECRET:-}" ]] && BR_FLAGS+=(--image_pull_secret="${IMAGE_PULL_SECRET}")
    [[ -n "${STG_CLASS_BLOCK:-}" ]] && BR_FLAGS+=(--block_storage_class="${STG_CLASS_BLOCK}")
    [[ -n "${STG_CLASS_FILE:-}" ]] && BR_FLAGS+=(--file_storage_class="${STG_CLASS_FILE}")
    [[ -n "${PATCH_ID:-}" ]] && BR_FLAGS+=(--patch_id="${PATCH_ID}")
    echo "[INFO] Installing br_orchestration"
    cpd-cli manage install-components "${BR_FLAGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
fi

# ------------------------------------------------------------------------------
# 5. cpdbr-agent (optional)
# ------------------------------------------------------------------------------
if [[ "${WITH_AGENT}" == "true" ]]; then
    AGENT_FLAGS=(--component=cpdbr-agent --namespace="${OADP_PROJECT}" --cpd-namespace="${PROJECT_CPD_INST_OPERANDS}")
    oc get daemonset cpdbr-agent -n "${OADP_PROJECT}" >/dev/null 2>&1 && AGENT_FLAGS+=(--upgrade=true)
    echo "[INFO] Installing cpdbr-agent"
    cpd-cli oadp install "${AGENT_FLAGS[@]}" "${OADP_REGISTRY_FLAGS[@]}" --log-level=debug --verbose 2>&1 | tee -a "${LOG_FILE}"
fi

echo ""
cpd-cli oadp backup-location list
echo ""
echo "[OK] OADP backup/restore utilities ready on ${OCP_URL} (cpdbr-tenant: ${TENANT_MODE})"
if [[ -n "${TARGET}" ]]; then
    echo "[INFO] Backups in the bucket show up here within a minute: cpd-cli oadp tenant-backup list"
    echo "[INFO] Next: ${SCRIPT_DIR}/4_restore_cp4d_instance.sh --target ${TARGET} --list"
else
    echo "[INFO] Next: ${SCRIPT_DIR}/3_backup_cp4d_instance.sh --bucket ${OADP_BUCKET_CONFIG_NAME:-${BUCKET_FILE:t}}"
fi
