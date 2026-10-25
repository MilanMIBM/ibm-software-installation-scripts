#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
_cfg="${SCRIPT_DIR:h:h:h}/configs/registry_mirror_config/registry_mirror_vars.sh"
if [[ -z "${MIRROR_CONFIG_FILE:-}" && ! -f "${_cfg}" ]]; then
    echo "[ERROR] No mirror config yet: ${_cfg}" >&2
    echo "[ERROR] Create it first: ${SCRIPT_DIR:h}/0_initial_setup/0.0_generate_mirror_config.sh --prefill-from-installs" >&2
    exit 1
fi
unset _cfg
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config

# ==============================================================================
# Private registry mirroring - the whole track in order
# ------------------------------------------------------------------------------
#   ./full_registry_mirror_process.sh [--phase=mirror|save|load] [--cluster-only]
#                                     [--no-cluster] [--dry-run]
#                                     [--inspect-source-registry]
#
#   mirror (direct)       0.1 0.2 0.4 | 1.0 1.1 | 2.0 2.1 2.2 2.3 2.4 | 3.0 - 3.6
#   save (stop-over, out) 0.2 0.4 | 1.0 1.1 | 2.0 2.1 2.2 2.3 (save) 2.5
#   load (stop-over, in)  2.6 | 2.0 2.1 2.2 2.3 (load) 2.4 | 3.0 - 3.6
#   --cluster-only        3.0 - 3.6 (the CP4D install wrapper calls this)
#   --no-cluster          stop after segment 2
#   --dry-run             map (1.0) and show segment 3 without changing the cluster;
#                         nothing is mirrored
#   --inspect-source-registry  have cpd-cli inspect every IBM source image (1.1 and
#                         2.0); same as MIRROR_CPD_INSPECT_SOURCE_REGISTRY=true
# Phase: --phase=, else MIRROR_PHASE, else detected (what is reachable from here).
# Skip any step with DO_<STEP>=false, e.g.  DO_CHECK=false ./full_registry_mirror_process.sh
# ==============================================================================

preg_parse_phase_args "$@"
CLUSTER_ONLY=false NO_CLUSTER=false DRY=false
for _a in "${PREG_ARGS[@]}"; do
    case "${_a}" in
        --cluster-only) CLUSTER_ONLY=true ;;
        --no-cluster) NO_CLUSTER=true ;;
        --dry-run) DRY=true ;;
        --inspect-source-registry) export MIRROR_CPD_INSPECT_SOURCE_REGISTRY=true ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done

DO_DETECT="${DO_DETECT:-true}"            # 0.1 detect the registry
DO_TOOLS="${DO_TOOLS:-true}"              # 0.2 tools (oc-mirror, ...)
DO_RH_SECRET="${DO_RH_SECRET:-true}"      # 0.4 Red Hat pull secret from the cluster (when missing)
DO_MAP="${DO_MAP:-true}"                  # 1.0 build the inventory
DO_CHECK="${DO_CHECK:-true}"              # 1.1 check the sources
DO_ESTIMATE="${DO_ESTIMATE:-false}"       # 1.2 estimate the size
DO_NATIVE="${DO_NATIVE:-true}"            # 2.0 install-native content (cpd-cli, Concert 1.1)
DO_IMAGES="${DO_IMAGES:-true}"            # 2.1 images
DO_CATALOGS="${DO_CATALOGS:-true}"        # 2.2 operator catalogs (oc-mirror)
DO_CHARTS="${DO_CHARTS:-true}"            # 2.3 charts + files
DO_VERIFY="${DO_VERIFY:-true}"            # 2.4 verify the registry
DO_BUNDLE="${DO_BUNDLE:-true}"            # 2.5 build the bundle (save)
DO_RESTORE="${DO_RESTORE:-true}"          # 2.6 restore the bundle (load)
DO_PREFLIGHT="${DO_PREFLIGHT:-true}"      # 3.0 cluster preflight
DO_PULL_SECRET="${DO_PULL_SECRET:-true}"  # 3.1 global pull secret
DO_CA="${DO_CA:-true}"                    # 3.2 CA trust
DO_MIRROR_SETS="${DO_MIRROR_SETS:-true}"  # 3.3 image mirror sets
DO_OP_CATALOGS="${DO_OP_CATALOGS:-true}"  # 3.4 operator catalogs
DO_TAP="${DO_TAP:-true}"                  # 3.5 point the installs at the registry
DO_VERIFY_CLUSTER="${DO_VERIFY_CLUSTER:-true}"   # 3.6 verify cluster pulls

T="${SCRIPT_DIR:h}"
run() {   # <DO value> <label> <script> [args...]
    local on="$1" label="$2" script="$3"
    shift 3
    h_run_step "${on}" "${label}" zsh "${T}/${script}" "$@"
}

cluster_segment() {
    local d=()
    ${DRY} && d=(--dry-run)
    run "${DO_PREFLIGHT}"      "3.0 cluster preflight"               3_configure_cluster/3.0_registry_cluster_preflight.sh
    run "${DO_PULL_SECRET}"    "3.1 global pull secret"              3_configure_cluster/3.1_global_pull_secret.sh "${d[@]}"
    run "${DO_CA}"             "3.2 trust the registry CA"           3_configure_cluster/3.2_trust_registry_ca.sh "${d[@]}"
    run "${DO_MIRROR_SETS}"    "3.3 image mirror sets"               3_configure_cluster/3.3_apply_mirror_sets.sh "${d[@]}"
    run "${DO_OP_CATALOGS}"    "3.4 operator catalogs"               3_configure_cluster/3.4_apply_operator_catalogs.sh "${d[@]}"
    run "${DO_TAP}"            "3.5 point the installs at the registry" 3_configure_cluster/3.5_point_installs_at_registry.sh "${d[@]}"
    ${DRY} || run "${DO_VERIFY_CLUSTER}" "3.6 verify cluster pulls"   3_configure_cluster/3.6_verify_cluster_pulls.sh
}

if ${CLUSTER_ONLY}; then
    cluster_segment
    exit 0
fi

if ${DRY}; then
    run "${DO_MAP}" "1.0 build the inventory" 1_map_content/1.0_build_inventory.sh
    ${NO_CLUSTER} || cluster_segment
    exit 0
fi

PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
print -r -- "Phase: ${PHASE}"
case "${PHASE}" in
    mirror)
        run "${DO_DETECT}"   "0.1 detect the registry"      0_initial_setup/0.1_detect_registry.sh
        run "${DO_TOOLS}"    "0.2 tools"                     0_initial_setup/0.2_fetch_mirror_tools.sh
        run "${DO_RH_SECRET}" "0.4 Red Hat pull secret"      0_initial_setup/0.4_fetch_redhat_pull_secret.sh
        run "${DO_MAP}"      "1.0 build the inventory"       1_map_content/1.0_build_inventory.sh
        run "${DO_CHECK}"    "1.1 check the sources"         1_map_content/1.1_check_sources.sh
        run "${DO_ESTIMATE}" "1.2 estimate the size"         1_map_content/1.2_estimate_size.sh
        for s in "${DO_NATIVE}:2.0 install-native content:2_download_and_mirror/2.0_mirror_native_content.sh" \
                 "${DO_IMAGES}:2.1 images:2_download_and_mirror/2.1_mirror_images.sh" \
                 "${DO_CATALOGS}:2.2 operator catalogs:2_download_and_mirror/2.2_mirror_operator_catalogs.sh" \
                 "${DO_CHARTS}:2.3 charts and files:2_download_and_mirror/2.3_mirror_charts_and_files.sh"; do
            run "${s%%:*}" "${${s#*:}%%:*}" "${s##*:}" --phase=mirror
        done
        run "${DO_VERIFY}"   "2.4 verify the registry"       2_download_and_mirror/2.4_verify_registry_content.sh
        ${NO_CLUSTER} || cluster_segment
        ;;
    save)
        run "${DO_TOOLS}"    "0.2 tools"                     0_initial_setup/0.2_fetch_mirror_tools.sh
        run "${DO_RH_SECRET}" "0.4 Red Hat pull secret"      0_initial_setup/0.4_fetch_redhat_pull_secret.sh
        run "${DO_MAP}"      "1.0 build the inventory"       1_map_content/1.0_build_inventory.sh
        run "${DO_CHECK}"    "1.1 check the sources"         1_map_content/1.1_check_sources.sh
        run "${DO_ESTIMATE}" "1.2 estimate the size"         1_map_content/1.2_estimate_size.sh
        for s in "${DO_NATIVE}:2.0 install-native content:2_download_and_mirror/2.0_mirror_native_content.sh" \
                 "${DO_IMAGES}:2.1 images:2_download_and_mirror/2.1_mirror_images.sh" \
                 "${DO_CATALOGS}:2.2 operator catalogs:2_download_and_mirror/2.2_mirror_operator_catalogs.sh" \
                 "${DO_CHARTS}:2.3 charts and files:2_download_and_mirror/2.3_mirror_charts_and_files.sh"; do
            run "${s%%:*}" "${${s#*:}%%:*}" "${s##*:}" --phase=save
        done
        run "${DO_BUNDLE}"   "2.5 build the transfer bundle" 2_download_and_mirror/2.5_build_transfer_bundle.sh
        ;;
    load)
        run "${DO_RESTORE}"  "2.6 restore the transfer bundle" 2_download_and_mirror/2.6_restore_transfer_bundle.sh
        for s in "${DO_NATIVE}:2.0 install-native content:2_download_and_mirror/2.0_mirror_native_content.sh" \
                 "${DO_IMAGES}:2.1 images:2_download_and_mirror/2.1_mirror_images.sh" \
                 "${DO_CATALOGS}:2.2 operator catalogs:2_download_and_mirror/2.2_mirror_operator_catalogs.sh" \
                 "${DO_CHARTS}:2.3 charts and files:2_download_and_mirror/2.3_mirror_charts_and_files.sh"; do
            run "${s%%:*}" "${${s#*:}%%:*}" "${s##*:}" --phase=load
        done
        run "${DO_VERIFY}"   "2.4 verify the registry"       2_download_and_mirror/2.4_verify_registry_content.sh
        ${NO_CLUSTER} || cluster_segment
        ;;
esac
