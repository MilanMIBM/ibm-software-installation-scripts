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
# x List what is in the registry, per install path (read-only)
# ------------------------------------------------------------------------------
# Every repository 1.0 mapped (and chart 2.3 pushed), grouped by registry path,
# with the tags the registry actually has. Uses the registry API with the push
# credentials (works where a catalog listing is not allowed, e.g. ICR service IDs).
#
#   ./x_list_registry_content.sh [--path P]
# ==============================================================================

ONLY=""
[[ "${1:-}" == --path ]] && ONLY="${2:?--path needs a registry path}"
preg_resolve_registry
WS="${MIRROR_WORKSPACE}"
PUSH="$(preg_push_root)"
RUN="$(preg_private_tmpdir)"
trap 'rm -rf "${RUN}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
preg_write_authfile "${RUN}/auth.json" push
opts=(--authfile "${RUN}/auth.json" ${(z)$(preg_skopeo_target_opts)})

for d in "${WS}"/*(N/); do
    rp="${d:t}"
    [[ -z "${ONLY}" || "${ONLY}" == "${rp}" ]] || continue
    repos=()
    [[ -s "${d}/targets.tsv" ]] && repos+=("${(@f)$(cut -f4 "${d}/targets.tsv" | sort -u)}")
    [[ -s "${d}/charts.tsv" ]] && repos+=("${(@f)$(awk -F'\t' '{ print $4 "/" $2 }' "${d}/charts.tsv" | sort -u)}")
    (( ${#repos} )) || continue
    print -r -- "== ${PUSH}/${rp}"
    for r in "${repos[@]}"; do
        tags="$(skopeo list-tags "${opts[@]}" "docker://${PUSH}/${r}" 2>/dev/null \
            | preg_python -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("Tags") or []))' 2>/dev/null || true)"
        printf '   %-70s %s\n' "${r#${rp}/}" "${tags:-(not in the registry)}"
    done
done
