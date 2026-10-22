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
# 0.1 Detect the registry (read-only report)
# ------------------------------------------------------------------------------
#   - image source: local private registry (air-gapped) or cloud private registry,
#     from the registry host (src/helpers/registry_classifier.py)
#   - push root: where this workstation pushes (ICR private endpoint -> public one
#     when MIRROR_REGISTRY_PUSH_FROM=local)
#   - reachability of the internet (cp.icr.io) and of the registry, TLS trust,
#     push credentials (checked against the registry's token service)
#   - the phase the mirroring steps would pick with MIRROR_PHASE=auto
#
#   ./0.1_detect_registry.sh           report
#   ./0.1_detect_registry.sh --write   also pin MIRROR_IMAGE_SOURCE (when auto)
#                                      in the mirror config
# ==============================================================================

WRITE=false
for _a in "$@"; do
    case "${_a}" in
        --write) WRITE=true ;;
        -h|--help) sed -n '/^# 0.1/,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done

row() { printf '  %-22s %s\n' "$1" "$2"; }
problems=()

PULL_ROOT="$(preg_pull_root)"
verdict="$(preg_classifier classify "${PULL_ROOT}" --local-state "$(preg_local_state_file)")"
class="${verdict%%$'\t'*}" reason="${verdict#*$'\t'}"
SOURCE="${MIRROR_IMAGE_SOURCE:-auto}"
[[ "${SOURCE}" == auto ]] && RESOLVED="${class}" || RESOLVED="${SOURCE}"
PUSH_ROOT="$(preg_push_root)"

print -r -- "Registry"
row "config" "${MIRROR_CONFIG_FILE_PATH#${_CP4D_REPO_ROOT}/}"
row "pull root (cluster)" "${PULL_ROOT}"
row "push root (here)" "${PUSH_ROOT}$([[ "${PUSH_ROOT}" != "${PULL_ROOT}" ]] && print -rn -- "   (derived, MIRROR_REGISTRY_PUSH_FROM=${MIRROR_REGISTRY_PUSH_FROM:-local})")"
row "classified as" "${class} - ${reason}"
row "image source" "${RESOLVED}$([[ "${SOURCE}" == auto ]] && print -rn -- ' (MIRROR_IMAGE_SOURCE=auto)' || print -rn -- " (set: MIRROR_IMAGE_SOURCE=${SOURCE})")"
if [[ "${SOURCE}" != auto && "${class}" != unknown && "${class}" != "${SOURCE}" ]]; then
    preg_warn "MIRROR_IMAGE_SOURCE=${SOURCE} but the host looks ${class} (${reason}) - check the setting."
fi
[[ "${RESOLVED}" == unknown ]] && problems+=("cannot classify ${PULL_ROOT}: set MIRROR_IMAGE_SOURCE=private or local")

print -r -- ""
print -r -- "Reachability from this machine"
net=false
preg_probe_internet && net=true
row "internet (cp.icr.io)" "$(${net} && print -rn -- reachable || print -rn -- 'NOT reachable')"

probe() {   # <label> <root>
    local code ca="${MIRROR_REGISTRY_CA_FILE:-}"
    code="$(preg_probe_registry "$2")"
    if [[ "${code}" == 000 && -n "${ca}" ]]; then
        code="$(preg_probe_registry "$2" "${ca}")"
        [[ "${code}" != 000 ]] && code="${code} (trusted via MIRROR_REGISTRY_CA_FILE only)"
    fi
    if [[ "${code}" == 000 ]]; then
        local k
        k="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "https://$(preg_registry_host "$2")/v2/" 2>/dev/null || true)"
        [[ "${k}" != 000 && -n "${k}" ]] && code="${k} (TLS NOT trusted - set MIRROR_REGISTRY_CA_FILE)"
    fi
    row "$1" "$([[ "${code}" == 000 ]] && print -rn -- 'NOT reachable' || print -rn -- "HTTP ${code}")"
    print -r -- "${code}" > "${TMP_DIR}/$1.code"
}
TMP_DIR="$(preg_private_tmpdir)"
trap 'rm -rf "${TMP_DIR}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
probe "push root" "${PUSH_ROOT}"
[[ "${PUSH_ROOT}" != "${PULL_ROOT}" ]] && probe "pull root" "${PULL_ROOT}"
push_code="$(< "${TMP_DIR}/push root.code")"
reg=false
[[ "${push_code}" == (200|401)* ]] && reg=true

# Push credentials: a real login against the registry's token service, into a
# throwaway auth file (nothing is stored).
if ${reg} && [[ -n "${MIRROR_REGISTRY_PUSH_USER:-}" && -n "${MIRROR_REGISTRY_PUSH_PASSWORD:-}" ]]; then
    login_args=(--authfile "${TMP_DIR}/auth.json" -u "${MIRROR_REGISTRY_PUSH_USER}" --password-stdin)
    [[ "${push_code}" == *"NOT trusted"* || "${push_code}" == *"CA_FILE only"* ]] && login_args+=(--tls-verify=false)
    if print -r -- "${MIRROR_REGISTRY_PUSH_PASSWORD}" | skopeo login "${login_args[@]}" "$(preg_registry_host "${PUSH_ROOT}")" >/dev/null 2>"${TMP_DIR}/login.err"; then
        row "push credentials" "accepted (${MIRROR_REGISTRY_PUSH_USER})"
    else
        row "push credentials" "REJECTED: $(tail -1 "${TMP_DIR}/login.err" | cut -c1-120)"
        problems+=("push credentials rejected by $(preg_registry_host "${PUSH_ROOT}")")
    fi
elif ${reg}; then
    row "push credentials" "not set (MIRROR_REGISTRY_PUSH_USER / _PASSWORD)"
    problems+=("push credentials are empty")
fi

print -r -- ""
print -r -- "Phase with MIRROR_PHASE=auto"
if ${net} && ${reg}; then sug=mirror; why="direct: this machine reaches both"
elif ${net}; then sug=save; why="stop-over, internet side: build the bundle here"
elif ${reg}; then sug=load; why="stop-over, inside: load a bundle into the registry"
else sug=none; why="nothing reachable"; problems+=("neither the internet nor the registry is reachable"); fi
row "suggested" "${sug} (${why})"
if [[ "${sug}" == (save|load) && "${MIRROR_TRANSPORT:-direct}" != stopover ]]; then
    preg_warn "That phase needs MIRROR_TRANSPORT=stopover in the mirror config."
fi
if [[ "${RESOLVED}" == private && "${PULL_ROOT%%/*}" == private.*icr.io && "${MIRROR_REGISTRY_PUSH_FROM:-local}" == cloud ]] && ! ${reg}; then
    preg_warn "ICR private endpoints are reachable only from inside IBM Cloud - MIRROR_REGISTRY_PUSH_FROM=local pushes through the public endpoint."
fi

if ${WRITE} && [[ "${SOURCE}" == auto && "${RESOLVED}" == (private|local) ]]; then
    _f="${MIRROR_CONFIG_FILE_PATH}"
    _tmp="$(mktemp "${_f:h}/.registry_mirror_vars.XXXXXX")"
    sed -E "s|^(export MIRROR_IMAGE_SOURCE=).*$|\\1\"${RESOLVED}\"|" "${_f}" > "${_tmp}"
    chmod 600 "${_tmp}"
    mv "${_tmp}" "${_f}"
    preg_info "Pinned MIRROR_IMAGE_SOURCE=\"${RESOLVED}\" in ${_f#${_CP4D_REPO_ROOT}/}"
fi

if (( ${#problems} )); then
    print -r -- ""
    for p in "${problems[@]}"; do preg_warn "${p}"; done
    exit 1
fi
