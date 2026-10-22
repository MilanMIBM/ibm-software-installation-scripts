#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"
mc_require_config
# MC_IMAGE_SOURCE=private|local: written by the private registry mirroring track
# (configs/datastax_mc_config/registry_overrides.sh) - the images come from the
# registry MC_PRIVATE_REGISTRY_HOST, not from cp.icr.io.
PRIVATE_SOURCE=false
[[ "${MC_IMAGE_SOURCE:-entitled}" == (private|local) ]] && PRIVATE_SOURCE=true
if ${PRIVATE_SOURCE}; then
    mc_require_vars MC_PRIVATE_REGISTRY_HOST MC_PRIVATE_REGISTRY_USER MC_PRIVATE_REGISTRY_PASSWORD MC_PULL_SECRET_NAME
else
    mc_require_vars IBM_ENTITLEMENT_KEY MC_PULL_SECRET_NAME
fi

# ==============================================================================
# 1.2 Namespace and image pull secrets
# ------------------------------------------------------------------------------
#  - Namespace MC_NAMESPACE (left as-is when it exists).
#  - MC_PULL_SECRET_NAME in it: user 'cp' + IBM_ENTITLEMENT_KEY for cp.icr.io
#    (and icr.io). "<release>-registry" is the chart's default pull secret name.
#  - MC_GLOBAL_PULL_SECRET=true: the same credentials in the cluster-wide pull
#    secret, via the shared cpd-cli-free utility. The OpenShift values disable
#    Mission Control's own pull secret copying into project namespaces, so the
#    database pods' cp.icr.io images are pulled with these. The Machine Config
#    Operator rolls the change out to the nodes.
# The key never goes on a command line: it is written to a private temp file.
# ==============================================================================

eval "${OC_LOGIN}"

cp4d_ensure_namespace "${MC_NAMESPACE}"

_work="$(mktemp -d)"
chmod 700 "${_work}"
trap 'rm -rf "${_work}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

if ${PRIVATE_SOURCE}; then
    MC_USER="${MC_PRIVATE_REGISTRY_USER}" MC_KEY="${MC_PRIVATE_REGISTRY_PASSWORD}" MC_HOSTS="${MC_PRIVATE_REGISTRY_HOST}" \
        python3 - "${_work}/dockerconfig.json" <<'PY'
import base64, json, os, sys
u, p = os.environ["MC_USER"], os.environ["MC_KEY"]
entry = {"username": u, "password": p, "auth": base64.b64encode(f"{u}:{p}".encode()).decode()}
with open(sys.argv[1], "w") as f:
    json.dump({"auths": {h: entry for h in os.environ["MC_HOSTS"].split()}}, f)
PY
    _hosts="${MC_PRIVATE_REGISTRY_HOST}"
else
    MC_KEY="${IBM_ENTITLEMENT_KEY}" python3 - "${_work}/dockerconfig.json" <<'PY'
import base64, json, os, sys
auth = base64.b64encode(("cp:" + os.environ["MC_KEY"]).encode()).decode()
entry = {"username": "cp", "password": os.environ["MC_KEY"], "auth": auth}
with open(sys.argv[1], "w") as f:
    json.dump({"auths": {"cp.icr.io": entry, "icr.io": entry}}, f)
PY
    _hosts="cp.icr.io, icr.io"
fi

oc create secret generic "${MC_PULL_SECRET_NAME}" -n "${MC_NAMESPACE}" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="${_work}/dockerconfig.json" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
mc_info "Pull secret ${MC_NAMESPACE}/${MC_PULL_SECRET_NAME} applied (${_hosts})."

if ${PRIVATE_SOURCE}; then
    mc_info "MC_IMAGE_SOURCE=${MC_IMAGE_SOURCE}: the cluster-wide pull secret holds the registry already (private_registry_mirroring 3.1)."
elif mc_is_true "${MC_GLOBAL_PULL_SECRET:-true}"; then
    "${_CP4D_REPO_ROOT}/src/utilities/redhat_openshift_utils/set_global_pull_secret.sh" \
        --config-dir "${MC_CONFIG_DIR}" --skip-private --no-distribute
else
    mc_info "MC_GLOBAL_PULL_SECRET=false - cluster-wide pull secret left alone."
    mc_warn "Database pods in Mission Control projects then need cp.icr.io credentials some other way."
fi
