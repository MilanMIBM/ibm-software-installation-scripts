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
# 2.3 Helm charts and plain files (--phase=mirror|save|load)
# ------------------------------------------------------------------------------
# charts  pulled from their OCI registry or HTTP Helm repo and pushed to the
#         registry as OCI artifacts: oci://<push root>/<path>/... (1.0 shows the
#         exact place, e.g. oci://<root>/datastax-mc/mission-control-helm/mission-control)
# files   downloads that are not images (connector ZIPs, manifests) into
#         registry_mirror_workspace/<path>/files/ - the installs read them there
#   mirror  pull + push / download to the workspace
#   save    pull / download into <bundle>/<path>/{charts,files}
#   load    push from the bundle / copy the files into the workspace
# Helm uses a private registry config here (your ~/.config/helm is not touched).
# ==============================================================================

preg_parse_phase_args "$@"
preg_resolve_registry
PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
WS="${MIRROR_WORKSPACE}"
BUNDLE="$(preg_bundle_dir)"
PUSH="$(preg_push_root)"
RUN="$(preg_private_tmpdir)"
trap 'rm -rf "${RUN}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

HREG="${RUN}/helm-registry.json"
tls=()
if preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}"; then tls=(--insecure-skip-tls-verify)
elif [[ -n "${MIRROR_REGISTRY_CA_FILE:-}" ]]; then tls=(--ca-file "${MIRROR_REGISTRY_CA_FILE}"); fi
logged_in=false
helm_login() {
    ${logged_in} && return 0
    preg_require_vars MIRROR_REGISTRY_PUSH_USER MIRROR_REGISTRY_PUSH_PASSWORD
    print -r -- "${MIRROR_REGISTRY_PUSH_PASSWORD}" | helm registry login "$(preg_registry_host "${PUSH}")" \
        -u "${MIRROR_REGISTRY_PUSH_USER}" --password-stdin --registry-config "${HREG}" "${tls[@]}" >/dev/null
    logged_in=true
}

problems=0 charts=0 files=0
for c in "${WS}"/*/charts.tsv(N); do
    rp="${c:h:t}"
    while IFS=$'\t' read -r src chart ver rel_dir _rest; do
        [[ -n "${src}" ]] || continue
        [[ "${PHASE}" == save ]] && dir="${BUNDLE}/${rp}/charts" || dir="${WS}/${rp}/charts"
        [[ "${PHASE}" == load ]] && dir="${BUNDLE}/${rp}/charts"
        mkdir -p "${dir}"
        tgz="${dir}/${chart}-${ver}.tgz"
        if [[ "${PHASE}" != load && ! -s "${tgz}" ]]; then
            if [[ "${src}" == oci://* ]]; then
                helm pull "${src}" --version "${ver}" -d "${dir}" >/dev/null
            else
                helm pull "${chart}" --repo "${src}" --version "${ver}" -d "${dir}" >/dev/null
            fi
        fi
        [[ -s "${tgz}" ]] || { preg_warn "chart ${chart} ${ver}: ${tgz} missing"; problems=$((problems + 1)); continue; }
        if [[ "${PHASE}" != save ]]; then
            helm_login
            if helm push "${tgz}" "oci://${PUSH}/${rel_dir}" --registry-config "${HREG}" "${tls[@]}" >"${RUN}/push.log" 2>&1; then
                preg_info "chart ${chart} ${ver} -> oci://${PUSH}/${rel_dir}/${chart}"
                # same ledger as 2.1 (x_prune_registry_paths.sh)
                mkdir -p "${WS}/inventory"
                { cat "${WS}/inventory/ledger.txt" 2>/dev/null; print -r -- "${PUSH}/${rel_dir}/${chart}:${ver}"; } | sort -u > "${RUN}/ledger"
                mv "${RUN}/ledger" "${WS}/inventory/ledger.txt"
            else
                preg_warn "chart ${chart} ${ver}: push failed: $(tail -1 "${RUN}/push.log")"
                problems=$((problems + 1)); continue
            fi
        else
            preg_info "chart ${chart} ${ver} -> ${tgz#${BUNDLE}/}"
        fi
        charts=$((charts + 1))
    done < "${c}"
done

for f in "${WS}"/*/files.tsv(N); do
    rp="${f:h:t}"
    while IFS=$'\t' read -r url dest _rest; do
        [[ -n "${url}" ]] || continue
        out="${WS}/${rp}/files/${dest}"
        [[ "${PHASE}" == save ]] && out="${BUNDLE}/${rp}/files/${dest}"
        mkdir -p "${out:h}"
        if [[ "${PHASE}" == load ]]; then
            src="${BUNDLE}/${rp}/files/${dest}"
            [[ -f "${src}" ]] || { preg_warn "file ${dest}: not in the bundle"; problems=$((problems + 1)); continue; }
            cp "${src}" "${out}"
        elif [[ ! -s "${out}" ]]; then
            curl -fSL --retry 3 -o "${out}.part" "${url}" 2>"${RUN}/curl.err" && mv "${out}.part" "${out}" \
                || { preg_warn "file ${url}: $(tail -1 "${RUN}/curl.err")"; problems=$((problems + 1)); continue; }
        fi
        preg_info "file ${dest} -> ${out#${_CP4D_REPO_ROOT}/}"
        files=$((files + 1))
    done < "${f}"
done

preg_info "Charts: ${charts}   files: ${files}"
(( problems == 0 )) || preg_die "${problems} chart/file problem(s)."
