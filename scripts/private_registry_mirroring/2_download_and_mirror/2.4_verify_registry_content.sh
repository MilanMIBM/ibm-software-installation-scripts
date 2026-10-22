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
export PREG_SKIP_REGISTRY_OVERRIDES=1   # hooks read the installs' own settings, not 3.5's overrides

# ==============================================================================
# 2.4 Verify what is in the registry (read-only, push side)
# ------------------------------------------------------------------------------
#   images    every target of every <path>/targets.tsv (skopeo, concurrently)
#   charts    helm show chart oci://<push root>/<path>/...
#   catalogs  the filtered index images under <root>/shared/redhat/...
#   native    installs/<id>.sh verify-registry (cpd: cpd-cli list-images
#             --target_registry, no level=fatal)
# Summary: inventory/verified-<date>.json. Exits 1 on anything missing.
#
#   ./2.4_verify_registry_content.sh [--skip-native]
# ==============================================================================

SKIP_NATIVE=false
[[ "${1:-}" == --skip-native ]] && SKIP_NATIVE=true
preg_resolve_registry
WS="${MIRROR_WORKSPACE}"
PUSH="$(preg_push_root)"
RUN="$(preg_private_tmpdir)"
trap 'rm -rf "${RUN}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
preg_write_authfile "${RUN}/auth.json" push
cert_args=()
d="$(preg_cert_dir)"; [[ -n "${d}" ]] && cert_args=(--cert-dir "${d}")
preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}" && cert_args=(--tls-verify-false)
problems=0
OUT="${WS}/inventory/verified-$(date +%Y%m%d-%H%M%S).json"

# --- Images ----------------------------------------------------------------------------
: > "${RUN}/refs"
for t in "${WS}"/*/targets.tsv(N); do
    preg_engine mapping --workspace "${WS}" --path "${t:h:t}" --phase targets --root "${PUSH}" >> "${RUN}/refs"
done
if [[ -s "${RUN}/refs" ]]; then
    preg_info "Checking $(grep -c . "${RUN}/refs") image(s) in ${PUSH}"
    preg_engine inspect --refs-file "${RUN}/refs" --authfile "${RUN}/auth.json" "${cert_args[@]}" --out "${OUT}" || problems=$((problems + 1))
fi

# --- Catalog indexes -------------------------------------------------------------------------
SHARED="$(preg_install_path shared)"
ISC="${WS}/${SHARED}/imageset-config.yaml"
if [[ -f "${ISC}" ]]; then
    : > "${RUN}/cat"
    for img in $(awk '/catalog:/ { print $3 }' "${ISC}"); do
        # registry.redhat.io/redhat/redhat-operator-index:v4.20 -> <push>/shared/redhat/redhat-operator-index:v4.20
        print -r -- "${PUSH}/${SHARED}/${img#*/}" >> "${RUN}/cat"
    done
    preg_info "Checking $(grep -c . "${RUN}/cat") catalog index image(s)"
    preg_engine inspect --refs-file "${RUN}/cat" --authfile "${RUN}/auth.json" "${cert_args[@]}" || problems=$((problems + 1))
fi

# --- Charts ----------------------------------------------------------------------------
HREG="${RUN}/helm-registry.json"
tls=()
if preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}"; then tls=(--insecure-skip-tls-verify)
elif [[ -n "${MIRROR_REGISTRY_CA_FILE:-}" ]]; then tls=(--ca-file "${MIRROR_REGISTRY_CA_FILE}"); fi
if [[ -n "$(cat "${WS}"/*/charts.tsv(N) 2>/dev/null)" ]]; then
    print -r -- "${MIRROR_REGISTRY_PUSH_PASSWORD:-}" | helm registry login "$(preg_registry_host "${PUSH}")" \
        -u "${MIRROR_REGISTRY_PUSH_USER:-}" --password-stdin --registry-config "${HREG}" "${tls[@]}" >/dev/null
    for c in "${WS}"/*/charts.tsv(N); do
        while IFS=$'\t' read -r _src chart ver rel_dir _rest; do
            [[ -n "${chart}" ]] || continue
            if helm show chart "oci://${PUSH}/${rel_dir}/${chart}" --version "${ver}" --registry-config "${HREG}" "${tls[@]}" >/dev/null 2>&1; then
                preg_info "chart OK      oci://${PUSH}/${rel_dir}/${chart}:${ver}"
            else
                preg_warn "chart MISSING oci://${PUSH}/${rel_dir}/${chart}:${ver}"
                problems=$((problems + 1))
            fi
        done < "${c}"
    done
fi

# --- Install-native content --------------------------------------------------------------
if ! ${SKIP_NATIVE}; then
    for id in "${(@f)$(preg_installs)}"; do
        [[ -n "${id}" ]] || continue
        [[ -s "${WS}/$(preg_install_path "${id}")/native.jsonl" ]] || continue
        preg_run_hook 2_download_and_mirror "${id}" verify-registry || problems=$((problems + 1))
    done
fi

[[ -f "${OUT}" ]] && preg_info "Summary: ${OUT#${_CP4D_REPO_ROOT}/}"
(( problems == 0 )) || preg_die "${problems} verification group(s) failed."
preg_info "Registry content verified."
