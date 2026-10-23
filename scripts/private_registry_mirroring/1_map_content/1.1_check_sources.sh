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
# 1.1 Check the sources (internet side, read-only)
# ------------------------------------------------------------------------------
# Is everything 1.0 mapped reachable with the source credentials?
#   images  skopeo inspect each source (cp.icr.io with the entitlement key,
#           registry.redhat.io with the Red Hat pull secret, Docker Hub, ...)
#   charts  helm show chart
#   files   HTTP HEAD
#   native  installs/<id>.sh check (cpd: cpd-cli manage list-images
#           --inspect_source_registry=true, IBM's own source check; only when
#           MIRROR_CPD_INSPECT_SOURCE_REGISTRY=true)
# Prints AUTH / MISSING / TLS / NETWORK problems and exits 1 when there are any.
#
#   ./1.1_check_sources.sh [--skip-native]
# ==============================================================================

SKIP_NATIVE=false
[[ "${1:-}" == --skip-native ]] && SKIP_NATIVE=true
WS="${MIRROR_WORKSPACE}"
[[ -f "${WS}/inventory/inventory.json" ]] || preg_die "No inventory - run 1.0_build_inventory.sh first."

RUN="$(preg_private_tmpdir)"
trap 'rm -rf "${RUN}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
AUTH="${RUN}/auth.json"
# Source registries only; the push side does not matter here.
preg_write_authfile "${AUTH}" none --sources
[[ -f "${MIRROR_REDHAT_PULL_SECRET_FILE:-}" ]] || preg_warn "No Red Hat pull secret (${MIRROR_REDHAT_PULL_SECRET_FILE:-unset}) - registry.redhat.io sources will fail."
[[ -n "${MIRROR_IBM_ENTITLEMENT_KEY:-}" ]] || preg_warn "MIRROR_IBM_ENTITLEMENT_KEY is empty - cp.icr.io sources will fail."

problems=0

# --- Images ----------------------------------------------------------------------------
: > "${RUN}/refs"
for t in "${WS}"/*/targets.tsv(N); do cut -f1 "${t}" >> "${RUN}/refs"; done
sort -u -o "${RUN}/refs" "${RUN}/refs"
n="$(grep -c . "${RUN}/refs" || true)"
if (( n )); then
    preg_info "Checking ${n} source image(s)"
    preg_engine inspect --refs-file "${RUN}/refs" --authfile "${AUTH}" --out "${WS}/inventory/check-sources.json" || problems=$((problems + 1))
fi

# --- Charts ----------------------------------------------------------------------------
for c in "${WS}"/*/charts.tsv(N); do
    while IFS=$'\t' read -r src chart ver _rest; do
        [[ -n "${src}" ]] || continue
        if [[ "${src}" == oci://* ]]; then args=("${src}" --version "${ver}")
        else args=("${chart}" --repo "${src}" --version "${ver}"); fi
        if helm show chart "${args[@]}" >/dev/null 2>"${RUN}/helm.err"; then
            preg_info "chart OK      ${chart} ${ver}"
        else
            preg_warn "chart FAILED  ${chart} ${ver}: $(tail -1 "${RUN}/helm.err" | cut -c1-160)"
            problems=$((problems + 1))
        fi
    done < "${c}"
done

# --- Files -----------------------------------------------------------------------------
for f in "${WS}"/*/files.tsv(N); do
    while IFS=$'\t' read -r url dest _rest; do
        [[ -n "${url}" ]] || continue
        code="$(curl -sIL -o /dev/null -m 20 -w '%{http_code}' "${url}" 2>/dev/null || true)"
        if [[ "${code}" == 200 ]]; then
            preg_info "file OK       ${dest}"
        else
            preg_warn "file FAILED   ${url} (HTTP ${code:-000})"
            problems=$((problems + 1))
        fi
    done < "${f}"
done

# --- Install-native checks -------------------------------------------------------------
if ! ${SKIP_NATIVE}; then
    for id in "${(@f)$(preg_installs)}"; do
        [[ -n "${id}" ]] || continue
        nat="${WS}/$(preg_install_path "${id}")/native.jsonl"
        [[ -s "${nat}" ]] || continue
        preg_run_hook 1_map_content "${id}" check || problems=$((problems + 1))
    done
fi

(( problems == 0 )) || preg_die "${problems} problem group(s) - fix credentials/sources before mirroring."
preg_info "All sources reachable."
