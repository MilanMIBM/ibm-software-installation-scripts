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
source "${_CP4D_REPO_ROOT}/src/helpers/progress_panel_helpers.sh"
preg_require_config

# ==============================================================================
# 2.1 Mirror the images (--phase=mirror|save|load, default MIRROR_PHASE)
# ------------------------------------------------------------------------------
# Every <path>/targets.tsv from 1.0 (each install's own path and shared) with
# `oc image mirror` - native on macOS and Linux, manifest lists and every
# architecture kept, so digest references stay valid:
#   mirror  source -> <push root>/<path>/...
#   save    source -> <bundle>/<path>/images  (--dir)
#   load    <bundle>/<path>/images -> <push root>/<path>/...  (--from-dir)
# Credentials: one host-level auth file (target + sources) in a private tmpdir.
# One progress row per path while oc runs (progress_panel_helpers.sh).
#
#   ./2.1_mirror_images.sh [--phase=...] [--path P]   (--path: one registry path only)
# ==============================================================================

preg_parse_phase_args "$@"
ONLY=""
set -- "${PREG_ARGS[@]}"
while (( $# )); do
    case "$1" in
        --path) ONLY="${2:?--path needs a registry path}"; shift 2 ;;
        *) preg_die "Unknown argument: $1" ;;
    esac
done
preg_resolve_registry
PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
WS="${MIRROR_WORKSPACE}"
BUNDLE="$(preg_bundle_dir)"
PUSH="$(preg_push_root)"
preg_info "Phase: ${PHASE}   push root: ${PUSH}"

RUN="$(preg_private_tmpdir)"
trap 'rm -rf "${RUN}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
if [[ "${PHASE}" == save ]]; then
    preg_write_authfile "${RUN}/auth.json" none --sources
elif [[ "${PHASE}" == load ]]; then
    preg_write_authfile "${RUN}/auth.json" push
else
    preg_write_authfile "${RUN}/auth.json" push --sources
fi

# oc image mirror's log: one "sha256:<digest> <target>:<tag>" line per mapping
# line pushed, "uploading: / mounted: <repo> <blob> <size>" per layer.
LOG="" TOTAL=0
oc_probe() {
    PPANEL_TOTAL="${TOTAL}" PPANEL_DETAIL="planning"
    [[ -s "${LOG}" ]] || return 0
    local -a v=("${(@ps:\t:)$(awk '
/^sha256:[0-9a-f]+ [^ ]+:[^\/ ]+$/ { if (!($2 in seen)) { seen[$2] = 1; p++ }; n = split($2, a, "/"); last = "pushed " a[n]; next }
/^info: Planning completed/       { pl = 1; next }
/^info: Mirroring completed/      { last = "finishing"; next }
/^(uploading|mounted|skipped): /  { n = split($2, a, "/"); last = substr($1, 1, length($1) - 1) " " a[n] ($4 != "" ? " " $4 : "") }
END { printf "%d\t%d\t%s", p, pl, last }' "${LOG}")}")
    PPANEL_DONE="${v[1]}"
    (( v[2] )) && PPANEL_DETAIL="${v[3]:-copying}"
    return 0
}

failed=() done_paths=()
for t in "${WS}"/*/targets.tsv(N); do
    rp="${t:h:t}"
    [[ -z "${ONLY}" || "${ONLY}" == "${rp}" ]] || continue
    [[ -s "${t}" ]] || continue
    n="$(grep -c . "${t}")"
    map="${RUN}/mapping.${rp}.txt"
    preg_engine mapping --workspace "${WS}" --path "${rp}" --phase "${PHASE}" --root "${PUSH}" > "${map}"
    args=(-a "${RUN}/auth.json" -f "${map}" --keep-manifest-list=true --filter-by-os='.*'
          --max-per-registry="${MIRROR_PARALLEL:-4}" --skip-multiple-scopes=true --continue-on-error=false)
    [[ "${PHASE}" != save ]] && args+=(${(z)$(preg_oc_insecure)})
    case "${PHASE}" in
        save) mkdir -p "${BUNDLE}/${rp}/images"; args+=(--dir="${BUNDLE}/${rp}/images") ;;
        load) [[ -d "${BUNDLE}/${rp}/images" ]] || { preg_warn "${rp}: ${BUNDLE}/${rp}/images missing - skipped"; failed+=("${rp}"); continue; }
              args+=(--from-dir="${BUNDLE}/${rp}/images") ;;
    esac
    preg_info "== <root>/${rp}: ${n} image(s)"
    LOG="${RUN}/oc.${rp}.log" TOTAL="$(grep -c . "${map}" || true)"
    ppanel_watch_start -p oc_probe -t "<root>/${rp}" -u images
    oc image mirror "${args[@]}" > "${LOG}" 2>&1 || true
    ppanel_watch_stop
    grep -E '^(info: Mirroring completed|error|F[0-9]{4}|W[0-9]{4})' "${LOG}" || true
    if grep -q -E '^(error:|F[0-9]{4})' "${RUN}/oc.${rp}.log" || ! grep -q 'info: Mirroring completed' "${RUN}/oc.${rp}.log"; then
        cp "${RUN}/oc.${rp}.log" "${WS}/${rp}/mirror-${PHASE}.log"
        failed+=("${rp}")
        preg_warn "${rp}: oc image mirror failed - log: ${WS#${_CP4D_REPO_ROOT}/}/${rp}/mirror-${PHASE}.log"
        continue
    fi
    done_paths+=("${rp}")
    if [[ "${PHASE}" != save ]]; then
        # What is in the registry now, plus a cumulative ledger of everything this
        # track ever pushed (x_prune_registry_paths.sh deletes what dropped out).
        preg_engine mapping --workspace "${WS}" --path "${rp}" --phase targets --root "${PUSH}" > "${WS}/${rp}/mirrored.txt"
        # (a missing ledger must not fail the pipeline under pipefail)
        { cat "${WS}/${rp}/mirrored.txt"; [[ -f "${WS}/inventory/ledger.txt" ]] && cat "${WS}/inventory/ledger.txt"; : ; } | sort -u > "${RUN}/ledger"
        mv "${RUN}/ledger" "${WS}/inventory/ledger.txt"
    fi
done

(( ${#done_paths} + ${#failed} )) || preg_info "No images in the inventory (run 1.0 first, or nothing selected)."
(( ${#done_paths} )) && preg_info "Done: ${done_paths[*]}"
(( ${#failed} == 0 )) || preg_die "Failed: ${failed[*]} - fix and re-run (already copied blobs are skipped)."
