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
# 2.5 Build the transfer bundle (stop-over, internet side - after the save phases)
# ------------------------------------------------------------------------------
# Run after 2.0 - 2.3 --phase=save. Completes <bundle> (MIRROR_BUNDLE_DIR):
#   <path>/{images,charts,files}  written by the save phases (per install + shared)
#   shared/oc-mirror, shared/imageset-config.yaml       (2.2)
#   inventory/ + <path>/{targets,charts,files}.tsv, native.jsonl   (1.0's mapping)
#   cpd/cpd-cli-work/   cpd-cli's work dir: CASE packages, patch metadata, the
#                       stop-over registry storage (registry-storage/), the saved
#                       olm-utils tar - WITHOUT its secrets (.airgap/secrets,
#                       global_pull_secret.cfg, .olm-utils, cp4d_config copies)
#   concert/airgap/     Concert 1.1's save output (when selected)
#   tools/<platform>-<arch>/   inside-workstation tools (0.2 --for-inside)
#   repo/repo.tar.gz    this repository's tracked files (working tree)
#   config/registry_mirror_vars.sh   the mirror config with every secret blanked
#   bundle-manifest.json, SHA256SUMS, README.txt
# No credentials are bundled unless --include-configs (configs/, with secrets).
#
#   ./2.5_build_transfer_bundle.sh [--include-configs] [--skip-tools]
# ==============================================================================

INCLUDE_CONFIGS=false SKIP_TOOLS=false
for _a in "$@"; do
    case "${_a}" in
        --include-configs) INCLUDE_CONFIGS=true ;;
        --skip-tools) SKIP_TOOLS=true ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done
[[ "${MIRROR_TRANSPORT:-direct}" == stopover ]] || preg_die "MIRROR_TRANSPORT is not stopover - a bundle is only for the stop-over transport."
WS="${MIRROR_WORKSPACE}"
BUNDLE="$(preg_bundle_dir)"
mkdir -p "${BUNDLE}"
[[ -f "${WS}/inventory/inventory.json" ]] || preg_die "No inventory - run 1.0 first."
preg_info "Bundle: ${BUNDLE}"

# --- Mapping (so the inside runs the load phases without re-mapping) --------------------
mkdir -p "${BUNDLE}/inventory"
cp "${WS}/inventory/inventory.json" "${WS}/inventory/report.txt" "${BUNDLE}/inventory/"
for d in "${WS}"/*(N/); do
    rp="${d:t}"
    [[ "${rp}" == (inventory|tools|local-registry|bundle|.run|.certs) ]] && continue
    for f in targets.tsv charts.tsv files.tsv native.jsonl imageset-config.yaml; do
        [[ -f "${d}/${f}" ]] && { mkdir -p "${BUNDLE}/${rp}"; cp "${d}/${f}" "${BUNDLE}/${rp}/"; }
    done
done

# --- cpd-cli work dir (cpd selected with native content) -------------------------------------
CPD_PATH="$(preg_install_path cpd 2>/dev/null || true)"
if [[ -n "${CPD_PATH}" && -s "${WS}/${CPD_PATH}/native.jsonl" ]]; then
    WORK="${HOME}/cpd-cli/work"
    [[ -d "${WORK}" ]] || preg_die "cpd-cli work dir not found: ${WORK}"
    preg_info "Copying cpd-cli's work dir (without secrets) -> ${CPD_PATH}/cpd-cli-work"
    mkdir -p "${BUNDLE}/${CPD_PATH}/cpd-cli-work"
    preg_rsync "cpd-cli work dir -> bundle" -a --delete \
        --exclude '.airgap/secrets/' --exclude 'global_pull_secret.cfg' --exclude '.olm-utils/' \
        --exclude 'cp4d_config/' --exclude 'olm-utils-ansible-log/' --exclude '*.log' --exclude '.DS_Store' \
        "${WORK}/" "${BUNDLE}/${CPD_PATH}/cpd-cli-work/"
fi

# --- oc-mirror archive: only the mirror_*.tar files travel ---------------------------------
# Its working-dir (the unpacked catalogs, GBs) is rebuilt from the archive by the
# load phase (disk-to-mirror), so it is left out of the bundle.
SHARED="$(preg_install_path shared)"
if [[ -d "${BUNDLE}/${SHARED}/oc-mirror/working-dir" ]]; then
    rm -rf "${BUNDLE}/${SHARED}/oc-mirror/working-dir"
    preg_info "Left oc-mirror's working-dir out (rebuilt from the archive when loading)"
fi

# --- Tools for the inside workstation ------------------------------------------------------
if ! ${SKIP_TOOLS}; then
    zsh "${SCRIPT_DIR:h}/0_initial_setup/0.2_fetch_mirror_tools.sh" --for-inside
fi

# --- Repository + config without secrets --------------------------------------------------
mkdir -p "${BUNDLE}/repo" "${BUNDLE}/config"
( cd "${_CP4D_REPO_ROOT}" && git ls-files -z | tar --null -T - -czf "${BUNDLE}/repo/repo.tar.gz" )
preg_python -I - "${MIRROR_CONFIG_FILE_PATH}" "${BUNDLE}/config/registry_mirror_vars.sh" <<'PY'
import re, sys
secret = re.compile(r'^(export\s+[A-Z0-9_]*(PASSWORD|_KEY|TOKEN)\s*=).*$')
out = [secret.sub(r'\1""   # blanked by 2.5 - set it on the inside', l) if not l.lstrip().startswith("#") else l
       for l in open(sys.argv[1]).read().splitlines()]
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY
if ${INCLUDE_CONFIGS}; then
    preg_warn "--include-configs: configs/ WITH credentials goes into the bundle."
    ( cd "${_CP4D_REPO_ROOT}" && tar -czf "${BUNDLE}/config/configs-with-secrets.tar.gz" configs )
    chmod 600 "${BUNDLE}/config/configs-with-secrets.tar.gz"
fi

cat > "${BUNDLE}/README.txt" <<EOF
Private registry mirroring - transfer bundle (written $(date -u +%Y-%m-%dT%H:%M:%SZ))

Inside the disconnected network, on the workstation that reaches the registry:
  1. mkdir ibm-software-installation-scripts && tar -xzf repo/repo.tar.gz -C ibm-software-installation-scripts
  2. Put config/registry_mirror_vars.sh into configs/registry_mirror_config/ and fill in
     the blanked credentials (registry push/pull user + password).
  3. MIRROR_BUNDLE_DIR=$(print -r -- "${BUNDLE}") (or wherever this bundle is now) then:
       scripts/private_registry_mirroring/2_download_and_mirror/2.6_restore_transfer_bundle.sh
       scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh --phase=load
Installs: ${MIRROR_INSTALLS:-}
EOF

preg_info "Writing checksums (can take a while for large bundles)"
preg_engine bundle-manifest write --dir "${BUNDLE}" \
    --meta "installs=${MIRROR_INSTALLS:-}" --meta "registry_root=$(preg_pull_root 2>/dev/null || true)" \
    --meta "ocp_minor=${MIRROR_OCP_MINOR:-}" --meta "inside_platform=${MIRROR_INSIDE_PLATFORM:-linux}" \
    --meta "inventory_sha256=$(preg_sha256 "${WS}/inventory/inventory.json")"
preg_info "Bundle ready: ${BUNDLE} - move it (USB, scp/sftp, or this machine) and follow README.txt"
