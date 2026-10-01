#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform for Apache Flink - collect instance details
# ------------------------------------------------------------------------------
# Discovers the live Flink endpoints and writes them to
# cp4d_config/confluent_flink_instance_details.sh, mirroring how
# 1.3_confluent_get_instance_details.sh writes confluent_instance_details.sh.
#
# The generated file is picked up automatically on the next run of any script in
# this repo, because source_env_setup.sh sources every *.sh in cp4d_config/.
# ==============================================================================

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_FLINK}"

if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[ERROR] Project '${NS}' does not exist. Run the install scripts first." >&2
    exit 1
fi

echo "[INFO] Collecting Flink endpoints from project '${NS}'..."

# ------------------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------------------
FLINK_CMF_INTERNAL_URL=""
if oc get service "${FLINK_CMF_SERVICE}" -n "${NS}" &>/dev/null; then
    FLINK_CMF_INTERNAL_URL="http://${FLINK_CMF_SERVICE}.${NS}.svc.cluster.local:${FLINK_CMF_PORT}"
fi

# The trailing 'return 0' matters for the same reason it does in the Confluent
# details script: without it a missing route makes the [[ ]] the function's exit
# status, and under `set -e` the caller dies mid-heredoc, silently truncating
# the generated file.
route_url() {
    local name="$1" host
    host="$(oc get route "${name}" -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && echo "https://${host}"
    return 0
}
FLINK_CMF_EXTERNAL_URL="$(route_url cmf)"

# ------------------------------------------------------------------------------
# Deployed versions, read from the running images rather than the config, so the
# file records what is actually running.
# ------------------------------------------------------------------------------
_cmf_image="$(oc get deployment confluent-manager-for-apache-flink -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
FLINK_CMF_DEPLOYED_VERSION="${_cmf_image##*:}"

_op_image="$(oc get deployment flink-kubernetes-operator -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
FLINK_OPERATOR_DEPLOYED_VERSION="${_op_image##*:}"

# ------------------------------------------------------------------------------
# CMF resources. Best effort: CMF may be down, or the CLI absent, and neither
# should stop the endpoint file from being written.
# ------------------------------------------------------------------------------
FLINK_ENVIRONMENTS=""
FLINK_CATALOGS=""
FLINK_COMPUTE_POOLS=""

if command -v confluent &>/dev/null && oc get deployment confluent-manager-for-apache-flink -n "${NS}" &>/dev/null; then
    if source "${SCRIPT_DIR}/flink_cmf_connect.sh" && cmf_connect &>/dev/null; then
        # -o json then a name extraction: the human output is a table whose
        # column layout is not a stable interface.
        FLINK_ENVIRONMENTS="$(confluent flink environment list --url "${CMF_URL}" -o json 2>/dev/null \
            | python3 -c 'import sys,json;print(",".join(e.get("name","") for e in json.load(sys.stdin)))' 2>/dev/null || true)"
        FLINK_CATALOGS="$(confluent flink catalog list --url "${CMF_URL}" -o json 2>/dev/null \
            | python3 -c 'import sys,json;print(",".join(e.get("name","") for e in json.load(sys.stdin)))' 2>/dev/null || true)"
        FLINK_COMPUTE_POOLS="$(confluent flink compute-pool list --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" -o json 2>/dev/null \
            | python3 -c 'import sys,json;print(",".join(e.get("name","") for e in json.load(sys.stdin)))' 2>/dev/null || true)"
    else
        echo "[WARN] CMF is not reachable - the resource lists will be empty."
    fi
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/confluent_flink_instance_details.sh"

cat > "${VARS_FILE}" <<EOF
# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Live endpoints of the Confluent Platform for Apache Flink stack in '${NS}'.
# Regenerate with: src/scripts/confluent_install/flink_install/$(basename $0)

export FLINK_NAMESPACE="${NS}"
export FLINK_CMF_DEPLOYED_VERSION="${FLINK_CMF_DEPLOYED_VERSION}"
export FLINK_OPERATOR_DEPLOYED_VERSION="${FLINK_OPERATOR_DEPLOYED_VERSION}"

# --- CMF endpoint -------------------------------------------------------------
# In-cluster: what workloads on the cluster should use.
export FLINK_CMF_INTERNAL_URL="${FLINK_CMF_INTERNAL_URL}"
# External route. Empty when FLINK_CREATE_ROUTES is false, which is the default:
# the CMF REST API ships without authentication. With no route, reach it with
#   oc port-forward svc/${FLINK_CMF_SERVICE} ${FLINK_CMF_LOCAL_PORT}:${FLINK_CMF_PORT} -n ${NS}
# which is what the x.* scripts do automatically.
export FLINK_CMF_EXTERNAL_URL="${FLINK_CMF_EXTERNAL_URL}"

# --- CMF resources ------------------------------------------------------------
# Comma-separated, as discovered at the time this file was written.
export FLINK_ENVIRONMENTS="${FLINK_ENVIRONMENTS}"
export FLINK_COMPUTE_POOLS="${FLINK_COMPUTE_POOLS}"
export FLINK_CATALOGS="${FLINK_CATALOGS}"
EOF

chmod 600 "${VARS_FILE}"

echo "[INFO] Wrote ${VARS_FILE}"
echo ""
printf '  %-30s %s\n' \
    "namespace"          "${NS}" \
    "CMF version"        "${FLINK_CMF_DEPLOYED_VERSION:-(not installed)}" \
    "operator version"   "${FLINK_OPERATOR_DEPLOYED_VERSION:-(not installed)}" \
    "CMF (in-cluster)"   "${FLINK_CMF_INTERNAL_URL:-(none)}" \
    "CMF (route)"        "${FLINK_CMF_EXTERNAL_URL:-(none - port-forward)}" \
    "environments"       "${FLINK_ENVIRONMENTS:-(none)}" \
    "compute pools"      "${FLINK_COMPUTE_POOLS:-(none)}" \
    "catalogs"           "${FLINK_CATALOGS:-(none - run x.4_flink_connect_kafka.sh)}"
echo ""
