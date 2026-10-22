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
# 2.2 Mirror the operator catalogs (shared; --phase=mirror|save|load)
# ------------------------------------------------------------------------------
# ONE oc-mirror v2 run for the union of every install's operators
# (<shared>/imageset-config.yaml from 1.0) into <root>/shared - separate runs
# would overwrite each other's filtered catalog indexes. Channel heads only;
# every architecture (oc-mirror v2 has no operator arch filter).
#   mirror  -> docker://<push root>/shared
#   save    -> file://<bundle>/shared/oc-mirror      (mirror-to-disk)
#   load    file://<bundle>/shared/oc-mirror -> docker://<push root>/shared
# oc-mirror is Linux-only: native on Linux, in a UBI container on macOS (0.2).
# The generated IDMS/ITMS/CatalogSources are applied by 3.4.
# ==============================================================================

preg_parse_phase_args "$@"
preg_resolve_registry
PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
WS="${MIRROR_WORKSPACE}"
SHARED="$(preg_install_path shared)"
BUNDLE="$(preg_bundle_dir)"
PUSH="$(preg_push_root)"
OCWS="${WS}/${SHARED}/oc-mirror"
ISC="${WS}/${SHARED}/imageset-config.yaml"
[[ "${PHASE}" == load && -f "${BUNDLE}/${SHARED}/imageset-config.yaml" ]] && ISC="${BUNDLE}/${SHARED}/imageset-config.yaml"
mkdir -p "${OCWS}"

if [[ ! -f "${ISC}" ]]; then
    preg_info "No operators selected - nothing for oc-mirror."
    print -r -- none > "${WS}/${SHARED}/last-cluster-resources"
    exit 0
fi
preg_info "Phase: ${PHASE}   catalogs: $(grep -c 'catalog:' "${ISC}")   packages: $(grep -c '^    - name:' "${ISC}")"

# The auth file must sit inside a directory the oc-mirror container mounts.
AUTH="${OCWS}/.auth.json"
trap 'rm -f "${AUTH}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
case "${PHASE}" in
    save) preg_write_authfile "${AUTH}" none --sources ;;
    load) preg_write_authfile "${AUTH}" push ;;
    *)    preg_write_authfile "${AUTH}" push --sources ;;
esac
[[ "${PHASE}" == load || -f "${MIRROR_REDHAT_PULL_SECRET_FILE:-}" ]] || preg_die "Red Hat pull secret not found (${MIRROR_REDHAT_PULL_SECRET_FILE:-MIRROR_REDHAT_PULL_SECRET_FILE unset}) - catalogs come from registry.redhat.io."

tls=()
[[ "${PHASE}" != save && -n "$(preg_oc_insecure)" ]] && tls=(--dest-tls-verify=false)
case "${PHASE}" in
    mirror)
        preg_oc_mirror "${OCWS}" --v2 -c "${ISC}" --workspace "file://${OCWS}" "docker://${PUSH}/${SHARED}" \
            --authfile "${AUTH}" "${tls[@]}"
        RES="${OCWS}/working-dir/cluster-resources" ;;
    save)
        mkdir -p "${BUNDLE}/${SHARED}"
        cp "${ISC}" "${BUNDLE}/${SHARED}/imageset-config.yaml"
        preg_oc_mirror "${OCWS}" --v2 -c "${ISC}" "file://${BUNDLE}/${SHARED}/oc-mirror" --authfile "${AUTH}"
        preg_info "Saved to ${BUNDLE}/${SHARED}/oc-mirror"
        exit 0 ;;
    load)
        [[ -d "${BUNDLE}/${SHARED}/oc-mirror" ]] || preg_die "No ${BUNDLE}/${SHARED}/oc-mirror (save phase output)."
        preg_oc_mirror "${OCWS}" --v2 -c "${ISC}" --from "file://${BUNDLE}/${SHARED}/oc-mirror" "docker://${PUSH}/${SHARED}" \
            --authfile "${AUTH}" "${tls[@]}"
        RES="${BUNDLE}/${SHARED}/oc-mirror/working-dir/cluster-resources" ;;
esac
[[ -d "${RES}" ]] || preg_die "oc-mirror wrote no cluster-resources (${RES})."
print -r -- "${RES}" > "${WS}/${SHARED}/last-cluster-resources"
preg_info "Cluster resources: ${RES} - applied by 3_configure_cluster/3.4_apply_operator_catalogs.sh"
