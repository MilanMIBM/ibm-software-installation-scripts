#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config

# ==============================================================================
# 0.4 Red Hat pull secret from a cluster
# ------------------------------------------------------------------------------
# Copies the Red Hat entries (registry.redhat.io, quay.io, ...) of a cluster's
# openshift-config/pull-secret into MIRROR_REDHAT_PULL_SECRET_FILE
# (configs/registry_mirror_config/redhat-pull-secret.json, mode 600), the file
# oc-mirror and the Red Hat image pulls use. Every OpenShift cluster was installed
# with one, so no console.redhat.com download is needed.
#
# Cluster: MIRROR_OC_LOGIN, else MIRROR_CLUSTER_FROM, else the first selected
# install whose config has OC_LOGIN (cpd first) - the same login as segment 3.
#
#   ./0.4_fetch_redhat_pull_secret.sh [--current] [--all] [--force]
#     --current  use the current oc session instead of logging in
#     --all      keep every registry of the cluster secret, not only Red Hat's
#     --force    replace an existing file
# ==============================================================================

CURRENT=false ALL=false FORCE=false
for _a in "$@"; do
    case "${_a}" in
        --current) CURRENT=true ;;
        --all) ALL=true ;;
        --force) FORCE=true ;;
        *) preg_die "Unknown argument: ${_a} (--current, --all, --force)" ;;
    esac
done
preg_require_vars MIRROR_REDHAT_PULL_SECRET_FILE
OUT="${MIRROR_REDHAT_PULL_SECRET_FILE}"

if [[ -s "${OUT}" ]] && ! ${FORCE}; then
    preg_info "Have ${OUT} (--force to replace it)"
    exit 0
fi

${CURRENT} || preg_cluster_login
oc whoami >/dev/null 2>&1 || preg_die "Not logged in to a cluster (oc whoami failed)."
preg_info "Reading openshift-config/pull-secret from $(oc whoami --show-server)"

mkdir -p "${OUT:h}"
TMP="$(mktemp "${OUT:h}/.redhat-pull-secret.XXXXXX")"
trap 'rm -f "${TMP}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
chmod 600 "${TMP}"

# The secret goes through stdin only, never argv.
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
    | preg_python -I -c '
import base64, json, sys
keep_all = sys.argv[2] == "true"
redhat = ("cloud.openshift.com", "quay.io", "registry.redhat.io",
          "registry.connect.redhat.com", "registry.access.redhat.com")
auths = json.loads(base64.b64decode(sys.stdin.read())).get("auths", {})
kept = {h: v for h, v in auths.items() if keep_all or h in redhat}
if "registry.redhat.io" not in kept:
    sys.exit("[ERROR] The cluster pull secret has no registry.redhat.io entry - "
             "download yours from https://console.redhat.com/openshift/install/pull-secret")
with open(sys.argv[1], "w") as f:
    json.dump({"auths": kept}, f, indent=2)
print("[INFO] Registries: " + ", ".join(sorted(kept)))
' "${TMP}" "${ALL}"

mv "${TMP}" "${OUT}"
preg_info "Wrote ${OUT} (mode 600)"
