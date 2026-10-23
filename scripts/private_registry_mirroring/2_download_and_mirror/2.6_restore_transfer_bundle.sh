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
# 2.6 Restore the transfer bundle (stop-over, INSIDE the disconnected network)
# ------------------------------------------------------------------------------
#   1. verifies the checksums (--quick: sizes/presence only)
#   2. restores 1.0's mapping into registry_mirror_workspace/ (load phases and
#      3.x read it there)
#   3. tools: oc, helm, oc-mirror from tools/<platform>-<arch>/ into
#      registry_mirror_workspace/tools/bin (add it to PATH; nothing system-wide);
#      cpd-cli into ~/cpd-cli when it is missing; a .venv from the wheelhouse
#      when the repo has none
#   4. cpd: cpd-cli's work dir (CASE packages, patch metadata, stop-over registry
#      storage) into ~/cpd-cli/work, IBM's chmod/chown, restart-container, and
#      the saved olm-utils image loaded
# Then run the load phases: 2.0 - 2.4 --phase=load (or the wrapper --phase=load).
#
#   MIRROR_BUNDLE_DIR=/path/to/bundle ./2.6_restore_transfer_bundle.sh [--quick]
# ==============================================================================

QUICK=()
[[ "${1:-}" == --quick ]] && QUICK=(--quick)
BUNDLE="$(preg_bundle_dir)"
WS="${MIRROR_WORKSPACE}"
[[ -f "${BUNDLE}/bundle-manifest.json" ]] || preg_die "No bundle at ${BUNDLE} (set MIRROR_BUNDLE_DIR)."

preg_info "Verifying ${BUNDLE}"
preg_engine bundle-manifest verify --dir "${BUNDLE}" "${QUICK[@]}" || preg_die "The bundle is incomplete or changed - copy it again."

# --- 2. mapping ---------------------------------------------------------------------------------
mkdir -p "${WS}/inventory"
cp "${BUNDLE}/inventory/"* "${WS}/inventory/"
for d in "${BUNDLE}"/*(N/); do
    rp="${d:t}"
    [[ "${rp}" == (inventory|tools|repo|config) ]] && continue
    for f in targets.tsv charts.tsv files.tsv native.jsonl imageset-config.yaml; do
        [[ -f "${d}/${f}" ]] && { mkdir -p "${WS}/${rp}"; cp "${d}/${f}" "${WS}/${rp}/"; }
    done
done
preg_info "Mapping restored into ${WS#${_CP4D_REPO_ROOT}/}"

# --- 3. tools ------------------------------------------------------------------------------------
case "$(uname -s)" in Darwin) plat=darwin ;; *) plat=linux ;; esac
arch="$(uname -m)"; [[ "${arch}" == (x86_64|amd64) ]] && arch=amd64 || arch=arm64
TD="${BUNDLE}/tools/${plat}-${arch}"
BIN="$(preg_tools_dir)/bin"
mkdir -p "${BIN}"
if [[ -d "${TD}" ]]; then
    [[ -f "${TD}/openshift-client.tar.gz" ]] && tar -xzf "${TD}/openshift-client.tar.gz" -C "${BIN}" oc kubectl 2>/dev/null || true
    [[ -f "${TD}/helm.tar.gz" ]] && tar -xzf "${TD}/helm.tar.gz" -C "${BIN}" --strip-components=1 "${plat}-${arch}/helm" 2>/dev/null || true
    if [[ -f "${TD}/oc-mirror.tar.gz" ]]; then
        ocm="$(preg_oc_mirror_binary)"
        mkdir -p "${ocm:h}"
        tar -xzf "${TD}/oc-mirror.tar.gz" -C "${ocm:h}" oc-mirror
        chmod +x "${ocm}"
    fi
    if [[ -f "${TD}/tools-image.tar" ]] && command -v podman >/dev/null 2>&1; then
        podman load -i "${TD}/tools-image.tar" >/dev/null
    fi
    preg_info "Tools in ${BIN#${_CP4D_REPO_ROOT}/}: $(ls "${BIN}" | xargs) - export PATH=\"${BIN}:\$PATH\""
    if ! command -v cpd-cli >/dev/null 2>&1 && [[ ! -x "${HOME}/cpd-cli/cpd-cli" ]]; then
        for t in "${TD}"/cpd-cli-*.tgz(N); do
            mkdir -p "${HOME}/cpd-cli"
            tar -xzf "${t}" -C "${HOME}/cpd-cli" --strip-components=1
            preg_info "cpd-cli installed into ~/cpd-cli (add it to PATH)"
        done
    fi
    if [[ ! -x "${_CP4D_REPO_ROOT}/.venv/bin/python" && -d "${TD}/wheelhouse" ]]; then
        python3 -m venv "${_CP4D_REPO_ROOT}/.venv"
        "${_CP4D_REPO_ROOT}/.venv/bin/pip" install --quiet --no-index --find-links "${TD}/wheelhouse" pyyaml jinja2
        preg_info "Created .venv with PyYAML + Jinja2 from the wheelhouse"
    fi
else
    preg_warn "No tools for ${plat}-${arch} in the bundle (MIRROR_INSIDE_PLATFORM on the internet side) - install oc, helm, skopeo, podman yourself."
fi
command -v skopeo >/dev/null 2>&1 || preg_warn "skopeo is not installed - install it from the OS repositories (dnf install skopeo)."

# --- 4. cpd-cli work dir ---------------------------------------------------------------------------
CPD_PATH="$(preg_install_path cpd 2>/dev/null || true)"
if [[ -n "${CPD_PATH}" && -d "${BUNDLE}/${CPD_PATH}/cpd-cli-work" ]]; then
    WORK="${HOME}/cpd-cli/work"
    mkdir -p "${WORK}"
    preg_info "Restoring cpd-cli's work dir -> ${WORK}"
    preg_rsync "bundle -> cpd-cli work dir" -a "${BUNDLE}/${CPD_PATH}/cpd-cli-work/" "${WORK}/"
    # IBM: chown -R 1001 ./work; chmod -R 775 ./work; cpd-cli manage restart-container
    chmod -R 775 "${WORK}"
    if [[ "$(uname -s)" == Linux ]]; then
        chown -R 1001 "${WORK}" 2>/dev/null || sudo -n chown -R 1001 "${WORK}" 2>/dev/null \
            || preg_warn "Could not chown ${WORK} to 1001 - run: sudo chown -R 1001 ${WORK}"
    fi
    if command -v cpd-cli >/dev/null 2>&1 || [[ -x "${HOME}/cpd-cli/cpd-cli" ]]; then
        export PATH="${HOME}/cpd-cli:${PATH}"
        for tar in "${WORK}"/offline/*olm-utils*.tar.gz(N); do
            ref="$(tar -xOzf "${tar}" manifest.json 2>/dev/null | preg_python -c 'import json,sys; print((json.load(sys.stdin)[0].get("RepoTags") or [""])[0])' 2>/dev/null || true)"
            if [[ -n "${ref}" ]] && ! podman image exists "${ref}" 2>/dev/null; then
                preg_info "Loading ${ref}"
                cpd-cli manage load-image --source-image="${ref}"
            fi
        done
        # Offline: start the container from the image just loaded (cpd-cli would
        # otherwise try to pull its default image).
        OLM_UTILS_IMAGE="${ref:-${OLM_UTILS_IMAGE:-}}" cpd-cli manage restart-container >/dev/null \
            && preg_info "cpd-cli container restarted on the restored work dir${ref:+ (${ref})}"
    else
        preg_warn "cpd-cli not installed - restore it, then: cpd-cli manage restart-container"
    fi
fi

preg_info "Restored. Next: the load phases (2.0 - 2.4 --phase=load), then 3_configure_cluster/."
