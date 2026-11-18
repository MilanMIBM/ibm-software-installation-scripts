#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_helpers.sh"

# ==============================================================================
# Confluent Platform for Apache Flink - collect instance details
# ------------------------------------------------------------------------------
# Discovers the live Flink endpoints and writes them to
# configs/confluent_platform_config/confluent_flink_instance_details.sh, mirroring how
# 1.3_confluent_get_instance_details.sh writes confluent_instance_details.sh.
#
# The generated file is picked up automatically on the next run of any script in
# this repo, because source_env_setup.sh sources every *.sh in configs/*/.
# ==============================================================================

eval "${OC_LOGIN}"
cf_operator_guard flink || exit $?

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
FLINK_CMF_EXTERNAL_URL="$(cf_route_url "${NS}" cmf)"

# ------------------------------------------------------------------------------
# Deployed versions, read from the running images rather than the config, so the
# file records what is actually running.
# ------------------------------------------------------------------------------
_cmf_image="$(oc get deployment confluent-manager-for-apache-flink -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
FLINK_CMF_DEPLOYED_VERSION="${_cmf_image##*:}"

if cf_flink_operator_mode; then
    source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"
    export CFO_OWNER_ID="${CFO_OWNER_ID:-$(cfo_owner_id)}"
fi
if cf_flink_is_olm; then
    # Operator mode (H22): cp-fko's image is pinned by digest, so the version is the CSV's spec.version.
    FLINK_OPERATOR_DEPLOYED_SOURCE="$(cf_flink_operator_source)"
    FLINK_OPERATOR_DEPLOYED_NAMESPACE="" FLINK_OPERATOR_DEPLOYED_CSV="" FLINK_OPERATOR_DEPLOYED_CHANNEL=""
    FLINK_OPERATOR_DEPLOYED_VERSION=""
    _f13_rc=0
    cfo_detect "${FLINK_OLM_PACKAGE:-${CFO_PKG_FKO}}" "${NS}" >/dev/null || _f13_rc=$?
    if (( _f13_rc != 0 )); then
        echo "[WARN] Cannot read the OLM objects - the cp-fko details stay empty." >&2
    elif [[ "${CFO_RESULT}" == reuse ]]; then
        FLINK_OPERATOR_DEPLOYED_NAMESPACE="${CFO_NS}"
        FLINK_OPERATOR_DEPLOYED_CSV="${CFO_CSV}"
        FLINK_OPERATOR_DEPLOYED_CHANNEL="${CFO_CHANNEL}"
        FLINK_OPERATOR_DEPLOYED_VERSION="$(oc get clusterserviceversions.operators.coreos.com "${CFO_CSV}" -n "${CFO_NS}" \
            -o jsonpath='{.spec.version}' 2>/dev/null || true)"
        : "${FLINK_OPERATOR_DEPLOYED_VERSION:=${CFO_VERSION}}"
    else
        echo "[WARN] No cp-fko watches '${NS}' (${CFO_RESULT}${CFO_REASON:+: ${CFO_REASON}})." >&2
    fi
    unset _f13_rc
else
    _op_image="$(oc get deployment flink-kubernetes-operator -n "${NS}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    FLINK_OPERATOR_DEPLOYED_VERSION="${_op_image##*:}"
fi
if cf_flink_operator_mode; then
    FLINK_CMF_RESTCLASS_DEPLOYED=""
    if [[ "$(cf_flink_cmf_resource_mode)" == cfk ]]; then
        _rc_name="$(oc get cmfrestclasses.platform.confluent.io "${FLINK_CMF_RESTCLASS_NAME:-default}" \
            -n "${FLINK_CFK_NAMESPACE:-${NS}}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
        [[ -n "${_rc_name}" ]] && FLINK_CMF_RESTCLASS_DEPLOYED="${FLINK_CFK_NAMESPACE:-${NS}}/${_rc_name}"
        unset _rc_name
    fi
fi

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
VARS_FILE="${CONFIGS_ROOT:-${REPO_ROOT}/configs}/confluent_platform_config/confluent_flink_instance_details.sh"
mkdir -p "$(dirname "${VARS_FILE}")"

cat > "${VARS_FILE}" <<EOF
# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Live endpoints of the Confluent Platform for Apache Flink stack in '${NS}'.
# Regenerate with: scripts/install_confluent_platform/install_confluent_platform_flink_addon/$(basename $0)

export FLINK_NAMESPACE="${NS}"
export FLINK_CMF_DEPLOYED_VERSION="${FLINK_CMF_DEPLOYED_VERSION}"
export FLINK_OPERATOR_DEPLOYED_VERSION="${FLINK_OPERATOR_DEPLOYED_VERSION}"

# --- CMF endpoint -------------------------------------------------------------
# In-cluster: what workloads on the cluster should use.
export FLINK_CMF_INTERNAL_URL="${FLINK_CMF_INTERNAL_URL}"
# External route (FLINK_CREATE_ROUTES, true by default). The CMF REST API ships
# without authentication - protect the route with x.2_flink_add_auth_openshift.sh.
# Empty when FLINK_CREATE_ROUTES is false; with no route, reach it with
#   oc port-forward svc/${FLINK_CMF_SERVICE} ${FLINK_CMF_LOCAL_PORT}:${FLINK_CMF_PORT} -n ${NS}
# which is what the x.* scripts do automatically.
export FLINK_CMF_EXTERNAL_URL="${FLINK_CMF_EXTERNAL_URL}"

# --- CMF resources ------------------------------------------------------------
# Comma-separated, as discovered at the time this file was written.
export FLINK_ENVIRONMENTS="${FLINK_ENVIRONMENTS}"
export FLINK_COMPUTE_POOLS="${FLINK_COMPUTE_POOLS}"
export FLINK_CATALOGS="${FLINK_CATALOGS}"
EOF

# Operator mode only (H22): *_DEPLOYED* names, never a config var name (source_env_setup.sh sources this
# file after confluent_vars.sh, so FLINK_OPERATOR_SOURCE here would override the user's setting).
if cf_flink_operator_mode; then
    cat >> "${VARS_FILE}" <<EOF

# --- Operator mode ------------------------------------------------------------
# How the Flink operator runs (helm | olm | existing) and, for OLM, its CSV.
export FLINK_OPERATOR_DEPLOYED_SOURCE="${FLINK_OPERATOR_DEPLOYED_SOURCE:-helm}"
export FLINK_OPERATOR_DEPLOYED_NAMESPACE="${FLINK_OPERATOR_DEPLOYED_NAMESPACE:-}"
export FLINK_OPERATOR_DEPLOYED_CSV="${FLINK_OPERATOR_DEPLOYED_CSV:-}"
export FLINK_OPERATOR_DEPLOYED_CHANNEL="${FLINK_OPERATOR_DEPLOYED_CHANNEL:-}"
# <namespace>/<name> of the CMFRestClass CFK uses (FLINK_CMF_RESOURCE_MODE=cfk), empty otherwise.
export FLINK_CMF_RESTCLASS_DEPLOYED="${FLINK_CMF_RESTCLASS_DEPLOYED}"
EOF
fi

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
if cf_flink_operator_mode; then
    printf '  %-30s %s\n' \
        "operator source"    "${FLINK_OPERATOR_DEPLOYED_SOURCE:-helm}" \
        "operator CSV"       "${FLINK_OPERATOR_DEPLOYED_CSV:-(none)}${FLINK_OPERATOR_DEPLOYED_NAMESPACE:+ in ${FLINK_OPERATOR_DEPLOYED_NAMESPACE}}" \
        "operator channel"   "${FLINK_OPERATOR_DEPLOYED_CHANNEL:-(none)}" \
        "CMFRestClass"       "${FLINK_CMF_RESTCLASS_DEPLOYED:-(none)}"
fi
echo ""
