#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# No env_bootstrap here: the config this script writes is what the other
# scripts load, so it may not exist yet. Find the repo root the same way.
REPO_ROOT="${SCRIPT_DIR}"; while [[ "${REPO_ROOT}" != "/" && ! -f "${REPO_ROOT}/env_bootstrap.sh" ]]; do REPO_ROOT="$(dirname "${REPO_ROOT}")"; done
source "${REPO_ROOT}/src/helpers/version_resolver.sh"

usage() {
    cat <<'EOF'
Write configs/datastax_mc_config/datastax_mc_vars.sh for the standalone DataStax
Mission Control install (independent of Cloud Pak for Data).

  0.0_generate_datastax_mc_config.sh --empty   [options]
  0.0_generate_datastax_mc_config.sh --from-cpd [CPD_VARS_FILE] [options]

Modes:
  --empty               Defaults everywhere; cluster login and IBM entitlement key
                        left blank for you to fill in.
  --from-cpd [FILE]     Take the cluster login (OCP_URL, OCP_USERNAME/OCP_PASSWORD
                        or OCP_TOKEN), IBM_ENTITLEMENT_KEY and STG_CLASS_BLOCK from
                        a CP4D config (default configs/cp4d_config/cpd_vars.sh).
                        Nothing else from CP4D is used, and the two configs stay
                        independent afterwards.

Options:
  --namespace NS        Mission Control namespace (default: mission-control)
  --plane control|data  Which plane this cluster runs (default: control)
  --admin-email EMAIL   Dex static admin login (default: admin@example.com)
  --out FILE            Write somewhere else (default:
                        configs/datastax_mc_config/datastax_mc_vars.sh)
  --force               Overwrite an existing file (a timestamped .bak is kept)
  -h, --help            Show this help

The admin password and the in-cluster MinIO credentials are generated randomly.
Review the file afterwards: storage class, observability storage (minio or s3)
and the SCC mode are the settings most likely to need a change.
EOF
}

MODE=""
CPD_FILE="${REPO_ROOT}/configs/cp4d_config/cpd_vars.sh"
OUT_FILE="${REPO_ROOT}/configs/datastax_mc_config/datastax_mc_vars.sh"
NAMESPACE="mission-control"
RELEASE="mission-control"
PLANE="control"
ADMIN_EMAIL="admin@example.com"
FORCE=false

while (( $# )); do
    case "$1" in
        --empty)       MODE=empty; shift ;;
        --from-cpd)
            MODE=cpd; shift
            if [[ $# -gt 0 && "$1" != -* ]]; then CPD_FILE="$1"; shift; fi ;;
        --namespace)   NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
        --plane)       PLANE="${2:?--plane needs control or data}"; shift 2 ;;
        --admin-email) ADMIN_EMAIL="${2:?--admin-email needs a value}"; shift 2 ;;
        --out)         OUT_FILE="${2:?--out needs a path}"; shift 2 ;;
        --force)       FORCE=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ -n "${MODE}" ]] || { echo "[ERROR] Pick --empty or --from-cpd." >&2; usage >&2; exit 1; }
[[ "${PLANE}" == (control|data) ]] || { echo "[ERROR] --plane must be control or data." >&2; exit 1; }

if [[ -f "${OUT_FILE}" ]] && ! ${FORCE}; then
    echo "[ERROR] ${OUT_FILE} already exists. Re-run with --force to replace it (a .bak copy is kept)." >&2
    exit 1
fi

# --- Values taken from CP4D --------------------------------------------------
OCP_URL="" OCP_USERNAME="" OCP_PASSWORD="" OCP_TOKEN="" IBM_ENTITLEMENT_KEY="" STORAGE_CLASS=""
if [[ "${MODE}" == cpd ]]; then
    [[ -f "${CPD_FILE}" ]] || { echo "[ERROR] CP4D config not found: ${CPD_FILE}" >&2; exit 1; }
    # Source it in a subshell so nothing else from CP4D leaks into this run;
    # values come back NUL-separated so any character survives.
    _cpd=("${(@0)$(
        set +u
        source "${CPD_FILE}" >/dev/null 2>&1
        print -rn -- "${OCP_URL:-}"$'\0'"${OCP_USERNAME:-}"$'\0'"${OCP_PASSWORD:-}"$'\0'"${OCP_TOKEN:-}"$'\0'"${IBM_ENTITLEMENT_KEY:-}"$'\0'"${STG_CLASS_BLOCK:-}"
    )}")
    OCP_URL="${_cpd[1]:-}" OCP_USERNAME="${_cpd[2]:-}" OCP_PASSWORD="${_cpd[3]:-}"
    OCP_TOKEN="${_cpd[4]:-}" IBM_ENTITLEMENT_KEY="${_cpd[5]:-}" STORAGE_CLASS="${_cpd[6]:-}"
    unset _cpd
    _taken=()
    for _v in OCP_URL OCP_USERNAME OCP_PASSWORD OCP_TOKEN IBM_ENTITLEMENT_KEY; do
        [[ -n "${(P)_v}" ]] && _taken+=("${_v}")
    done
    [[ -n "${STORAGE_CLASS}" ]] && _taken+=("STG_CLASS_BLOCK -> MC_STORAGE_CLASS")
    echo "[INFO] Taken from ${CPD_FILE#${REPO_ROOT}/}: ${(j:, :)_taken:-nothing}"
    [[ -z "${OCP_URL}" ]] && echo "[WARN] OCP_URL was empty in the CP4D config - fill it in by hand." >&2
    [[ -z "${IBM_ENTITLEMENT_KEY}" ]] && echo "[WARN] IBM_ENTITLEMENT_KEY was empty in the CP4D config - fill it in by hand." >&2
    unset _taken _v
fi

# No `tr </dev/urandom | head` here: under pipefail its SIGPIPE ends the script.
random_password() {
    python3 -c 'import secrets, string, sys; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "${1:-24}"
}
ADMIN_PASSWORD="$(random_password 20)"
MINIO_PASSWORD="$(random_password 32)"

# Single-quoted shell literal for any value (passwords may hold $ " ' etc.).
q() { print -r -- "${(qq)1}"; }

# --- Write -------------------------------------------------------------------
mkdir -p "${OUT_FILE:h}"
if [[ -f "${OUT_FILE}" ]]; then
    _bak="${OUT_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    cp -p "${OUT_FILE}" "${_bak}"
    echo "[INFO] Previous file kept as ${_bak:t}"
fi

_tmp="$(mktemp "${OUT_FILE:h}/.datastax_mc_vars.XXXXXX")"
chmod 600 "${_tmp}"
cat > "${_tmp}" <<EOF
#!/bin/zsh
# ==============================================================================
# DataStax Mission Control (standalone) configuration
# Generated by 0.0_generate_datastax_mc_config.sh --${MODE/cpd/from-cpd} on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# ==============================================================================
# Sourced (never executed) by scripts/install_datastax_mc_standalone/*, which run
# with ENV_TARGET=datastax_mc. Everything below is skipped otherwise, so CP4D
# scripts that source every configs/*/*.sh never pick up this cluster login.
#
#   Interactive shell:  source s_env.sh datastax_mc
#
# Independent of Cloud Pak for Data: nothing here is read from cpd_vars.sh at
# run time, even when this file was generated from it.
[[ "\${ENV_TARGET:-}" == datastax_mc || "\${ENV_TARGET:-}" == *datastax_mc_vars.sh ]] || return 0

# ------------------------------------------------------------------------------
# Cluster login (OCP_TOKEN wins over username/password when set)
# ------------------------------------------------------------------------------
export OCP_URL=$(q "${OCP_URL}")
export OCP_USERNAME=$(q "${OCP_USERNAME}")
export OCP_PASSWORD=$(q "${OCP_PASSWORD}")
export OCP_TOKEN=$(q "${OCP_TOKEN}")
export SERVER_ARGUMENTS="--server=\${OCP_URL}"
# Single quotes: the credentials are expanded when OC_LOGIN is eval'd, so a
# password containing \$ ' or " still logs in.
if [[ -n "\${OCP_TOKEN}" ]]; then
    export LOGIN_ARGUMENTS='--token="\${OCP_TOKEN}"'
else
    export LOGIN_ARGUMENTS='--username="\${OCP_USERNAME}" --password="\${OCP_PASSWORD}"'
fi
export OC_LOGIN="oc login \${SERVER_ARGUMENTS} \${LOGIN_ARGUMENTS}"

# ------------------------------------------------------------------------------
# IBM entitled registry (cp.icr.io) - https://myibm.ibm.com/products-services/containerlibrary
# ------------------------------------------------------------------------------
export IBM_ENTITLEMENT_KEY=$(q "${IBM_ENTITLEMENT_KEY}")
# Pull secret in the Mission Control namespace. "<release>-registry" is the
# chart's default name, so no values override is needed for it.
export MC_PULL_SECRET_NAME="${RELEASE}-registry"
# Also add cp.icr.io / icr.io to the cluster-wide pull secret. The OpenShift
# values set disablePullSecretsGeneration=true, so Mission Control does not copy
# its pull secret into project namespaces - database pods (HCD/DSE images from
# cp.icr.io) rely on the global pull secret instead.
export MC_GLOBAL_PULL_SECRET="true"

# ------------------------------------------------------------------------------
# Mission Control release
# ------------------------------------------------------------------------------
# Chart: oci://icr.io/mission-control-helm/mission-control
export MC_VERSION="1.21.2"
# Fixed: DataStax's OpenShift values hard-code service names for this release
# (and a data plane must use the same name as its control plane anyway).
export MC_RELEASE_NAME="${RELEASE}"
export MC_NAMESPACE="${NAMESPACE}"
# control: full control plane (UI, Dex, Loki, Mimir, Vector aggregator)
# data:    data plane only; ships its telemetry to MC_VECTOR_AGGREGATOR_URL
export MC_PLANE="${PLANE}"
# Helm 3.14.0 - 3.18.x is supported. A helm on PATH in that range is used;
# otherwise this version is downloaded into datastax_mc_workspace/tools/.
export MC_HELM_VERSION="$(vr_catalog helm/pinned_version)"
export MC_HELM_TIMEOUT="15m"
# Your own values files (space-separated paths), applied after the generated ones
export MC_EXTRA_VALUES_FILES=""

# ------------------------------------------------------------------------------
# Security Context Constraints
# ------------------------------------------------------------------------------
# nonroot-v2    grant nonroot-v2 to the Mission Control service accounts (DataStax default)
# restricted-v2 render DataStax's null-UID overrides for the operators, Dex, UI
#               and the Vector aggregator; Loki, Mimir, MinIO and
#               kube-state-metrics pin their UIDs and keep nonroot-v2
# custom        apply DataStax's example "mission-control" SCC (allowHostNetwork: true)
# Caveat (chart 1.21.2): the chart itself grants anyuid (SCC priority 10) to most
# of its service accounts, and OpenShift picks a higher-priority SCC first, so
# with restricted-v2 or custom most pods are still admitted under anyuid.
# 2.3_mission_control_status.sh shows the SCC each pod actually got.
export MC_SCC_MODE="nonroot-v2"

# ------------------------------------------------------------------------------
# Platform nodes
# ------------------------------------------------------------------------------
# Every Mission Control component is pinned to nodes labelled
# mission-control.datastax.com/role=platform.
#   all-workers  label every worker node (fine for small/shared clusters)
#   existing     label nothing; at least one node must already carry the label
#   <n1,n2,...>  label exactly these nodes
export MC_PLATFORM_NODES="all-workers"

# ------------------------------------------------------------------------------
# Projects (namespaces that hold database clusters)
# ------------------------------------------------------------------------------
# HCD/DSE/Cassandra pods run as UID/GID 999, which OpenShift's default
# restricted-v2 SCC rejects, so every project needs nonroot-v2 for its service
# accounts (3.1_prepare_mc_projects.sh).
# Auto-prepare: an in-cluster reconciler in MC_NAMESPACE that does this for
# every project as soon as it appears - created in the UI or by 3.1 --create.
export MC_PROJECT_AUTO_PREPARE="true"
# Project created at install (control plane only); empty = none
export MC_BASE_PROJECT="hcd"
export MC_BASE_PROJECT_NAME="HCD"

# ------------------------------------------------------------------------------
# Admin login (Dex static password). The bcrypt hash is computed at install.
# ------------------------------------------------------------------------------
export MC_ADMIN_EMAIL=$(q "${ADMIN_EMAIL}")
export MC_ADMIN_PASSWORD=$(q "${ADMIN_PASSWORD}")
# Optional: external URL of the UI, needed only with OIDC providers. Left empty,
# the passthrough Route that 2.2 creates is used as is.
export MC_UI_BASE_URL=""
export MC_UI_ROUTE_NAME="${RELEASE}-ui"

# ------------------------------------------------------------------------------
# Storage
# ------------------------------------------------------------------------------
# Block (RWO) storage class for the Vector aggregator, Mimir, Loki and MinIO
export MC_STORAGE_CLASS=$(q "${STORAGE_CLASS}")
export MC_VECTOR_VOLUME_SIZE="10Gi"

# ------------------------------------------------------------------------------
# Observability storage (control plane only)
# ------------------------------------------------------------------------------
# minio  in-cluster MinIO from the chart (no external dependency; dev/test)
# s3     an S3-compatible service: AWS S3, IBM COS, ODF/NooBaa, ...
export MC_OBSERVABILITY_STORE="minio"
export MC_LOGS_RETENTION="7d"
export MC_METRICS_RETENTION="7d"
export MC_METRICS_ALERTS_VOLUME_SIZE="1Gi"
export MC_METRICS_COMPACTOR_VOLUME_SIZE="5Gi"
export MC_METRICS_INGESTER_VOLUME_SIZE="10Gi"
export MC_METRICS_STORE_GATEWAY_VOLUME_SIZE="5Gi"
export MC_LOKI_VOLUME_SIZE="10Gi"
export MC_LOGS_BUCKET="loki-chunks"
export MC_METRICS_BUCKET="mimir-tsdb"
# minio mode
export MC_MINIO_ROOT_USER="mc-minio-admin"
export MC_MINIO_ROOT_PASSWORD=$(q "${MINIO_PASSWORD}")
export MC_MINIO_VOLUME_SIZE="20Gi"
# s3 mode. MC_S3_ENDPOINT is host[:port] without a scheme; empty means
# s3.<MC_S3_REGION>.amazonaws.com. MC_S3_INSECURE=true talks plain HTTP.
export MC_S3_ENDPOINT=""
export MC_S3_REGION="us-east-1"
export MC_S3_ACCESS_KEY_ID=""
export MC_S3_SECRET_ACCESS_KEY=""
export MC_S3_INSECURE="false"
export MC_S3_FORCE_PATH_STYLE="false"
# Secret holding the S3 (or MinIO) credentials for Loki and Mimir
export MC_S3_SECRET_NAME="${RELEASE}-observability-s3"

# ------------------------------------------------------------------------------
# Data plane only
# ------------------------------------------------------------------------------
# Vector aggregator address on the control plane, e.g.
# https://<control-plane-aggregator-host>:443 or <host>:6000
export MC_VECTOR_AGGREGATOR_URL=""

# ------------------------------------------------------------------------------
# cert-manager (OpenShift cert-manager Operator)
# ------------------------------------------------------------------------------
# Adds --enable-certificate-owner-ref to the operator so deleting a Certificate
# also deletes its secret (the OpenShift operator does not do this by default).
export MC_CERT_MANAGER_OWNER_REF="true"
EOF
mv "${_tmp}" "${OUT_FILE}"

echo "[INFO] Wrote ${OUT_FILE#${REPO_ROOT}/}"
echo "[INFO] Admin login: ${ADMIN_EMAIL} (password in MC_ADMIN_PASSWORD)"
[[ -z "${STORAGE_CLASS}" ]] && echo "[WARN] MC_STORAGE_CLASS is empty - set it before installing (oc get storageclass)." >&2
if [[ "${MODE}" == empty ]]; then
    echo "[INFO] Fill in OCP_URL, the login (OCP_USERNAME/OCP_PASSWORD or OCP_TOKEN), IBM_ENTITLEMENT_KEY and MC_STORAGE_CLASS."
fi
echo "[INFO] Next: scripts/install_datastax_mc_standalone/0_x_full_quick_install_script/full_datastax_mc_installprocess.sh"
