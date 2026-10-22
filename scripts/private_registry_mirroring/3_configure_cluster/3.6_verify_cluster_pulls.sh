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
# 3.6 Verify that the cluster pulls through the registry
# ------------------------------------------------------------------------------
# On one worker (oc debug node ... chroot /host crictl pull), pulls one probe
# image per registry path BY ITS SOURCE NAME (docker.io/..., registry.redhat.io/...,
# cp.icr.io/...): it only succeeds when the mirror set, the pull secret and the CA
# trust work together. A probe is removed again unless it was already on the node.
# Then installs/<id>.sh verify-cluster (e.g. pods' images under <root>/<path>).
#
#   ./3.6_verify_cluster_pulls.sh [--current] [--all]   (--all: every image, not one per path)
# ==============================================================================

CURRENT=false ALL=false
for _a in "$@"; do
    case "${_a}" in
        --current) CURRENT=true ;;
        --all) ALL=true ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done
preg_resolve_registry
WS="${MIRROR_WORKSPACE}"
${CURRENT} || preg_cluster_login

probes=()
for t in "${WS}"/*/targets.tsv(N); do
    [[ -s "${t}" ]] || continue
    if ${ALL}; then probes+=("${(@f)$(cut -f1 "${t}")}")
    else probes+=("$(head -1 "${t}" | cut -f1)"); fi
done
problems=0
if (( ${#probes} )); then
    node="$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${node}" ]] || node="$(oc get nodes -o jsonpath='{.items[0].metadata.name}')"
    preg_info "Pulling ${#probes} probe image(s) by source name on ${node}"
    script='rc=0; for i in "$@"; do had=$(crictl images -q "$i" 2>/dev/null); if crictl pull "$i" >/dev/null 2>/tmp/e; then echo "OK      $i"; [ -z "$had" ] && crictl rmi "$i" >/dev/null 2>&1; else echo "FAILED  $i: $(tail -1 /tmp/e)"; rc=1; fi; done; exit $rc'
    oc debug "node/${node}" --quiet -- chroot /host bash -c "${script}" _ "${probes[@]}" 2>/dev/null | sed 's/^/  /' || problems=$((problems + 1))
else
    preg_info "No images in the inventory to probe."
fi

for id in "${(@f)$(preg_installs)}"; do
    [[ -n "${id}" ]] || continue
    preg_run_hook 3_configure_cluster "${id}" verify-cluster || problems=$((problems + 1))
done

(( problems == 0 )) || preg_die "Some pulls failed - check 3.1 (pull secret), 3.2 (CA), 3.3/3.4 (mirror sets) and 2.4 (content)."
preg_info "The cluster pulls through $(preg_pull_root)."
