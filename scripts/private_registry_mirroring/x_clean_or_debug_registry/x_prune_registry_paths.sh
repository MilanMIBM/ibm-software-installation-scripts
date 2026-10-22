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
# x Prune images this track pushed that are no longer in the inventory
# ------------------------------------------------------------------------------
# 2.1 keeps inventory/ledger.txt: every image reference it ever pushed. This
# deletes (registry API, skopeo delete - works without registry management
# rights, e.g. an ICR service ID) ledger entries that:
#   default    are no longer targets of the current inventory (after a selection
#              or a shared declaration changed and 1.0 + 2.1 ran again)
#   --all      every ledger entry (optionally only below --path P): removes
#              what this track mirrored, e.g. after a test
# Only references this track pushed are ever touched. cpd-cli / Concert 1.1
# content is not in the ledger (use IBM's tooling or the registry UI for it).
# Registries may keep deleted images in a trash / need garbage collection.
#
#   ./x_prune_registry_paths.sh [--all] [--path P] [--yes]   (without --yes: list only)
# ==============================================================================

ALL=false ONLY="" YES=false
while (( $# )); do
    case "$1" in
        --all) ALL=true; shift ;;
        --path) ONLY="${2:?--path needs a registry path}"; shift 2 ;;
        --yes) YES=true; shift ;;
        *) preg_die "Unknown argument: $1" ;;
    esac
done
preg_resolve_registry
WS="${MIRROR_WORKSPACE}"
PUSH="$(preg_push_root)"
LEDGER="${WS}/inventory/ledger.txt"
[[ -s "${LEDGER}" ]] || { preg_info "Nothing in ${LEDGER#${_CP4D_REPO_ROOT}/} - nothing pushed by 2.1 yet."; exit 0; }

RUN="$(preg_private_tmpdir)"
trap 'rm -rf "${RUN}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
: > "${RUN}/current"
for t in "${WS}"/*/targets.tsv(N); do
    preg_engine mapping --workspace "${WS}" --path "${t:h:t}" --phase targets --root "${PUSH}" >> "${RUN}/current"
done
for c in "${WS}"/*/charts.tsv(N); do
    awk -F'\t' -v p="${PUSH}" 'NF >= 4 { print p "/" $4 "/" $2 ":" $3 }' "${c}" >> "${RUN}/current"
done
sort -u -o "${RUN}/current" "${RUN}/current"
if ${ALL}; then cp "${LEDGER}" "${RUN}/candidates"
else comm -23 "${LEDGER}" "${RUN}/current" > "${RUN}/candidates"; fi
[[ -n "${ONLY}" ]] && { grep -F "${PUSH}/${ONLY}/" "${RUN}/candidates" > "${RUN}/c2" || true; mv "${RUN}/c2" "${RUN}/candidates"; }

n="$(grep -c . "${RUN}/candidates" || true)"
(( n )) || { preg_info "Nothing to prune."; exit 0; }
preg_info "${n} image reference(s) to delete:"
sed 's/^/  /' "${RUN}/candidates"
${YES} || { preg_info "List only - re-run with --yes to delete."; exit 0; }

preg_write_authfile "${RUN}/auth.json" push
opts=(--authfile "${RUN}/auth.json" ${(z)$(preg_skopeo_target_opts)})
deleted=()
while IFS= read -r ref; do
    if skopeo delete "${opts[@]}" "docker://${ref}" 2>"${RUN}/err"; then
        preg_info "deleted ${ref}"; deleted+=("${ref}")
    elif grep -q -i -E 'manifest unknown|not found|404' "${RUN}/err"; then
        preg_info "already gone ${ref}"; deleted+=("${ref}")
    else
        preg_warn "could not delete ${ref}: $(tail -1 "${RUN}/err")"
    fi
done < "${RUN}/candidates"
print -rl -- "${deleted[@]}" | sort -u > "${RUN}/deleted"
comm -23 "${LEDGER}" "${RUN}/deleted" > "${RUN}/ledger" && mv "${RUN}/ledger" "${LEDGER}"
preg_info "Deleted ${#deleted} of ${n}; ledger updated."
