#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# This script lives in scripts/install_ibm_concert/0_x_full_quick_install_script/,
# so the numbered step folders are one level up.
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CP4D_ROOT="${_CP4D_REPO_ROOT}/scripts/install_cloud_pak_for_data"

h_steps_parse --strict "$@"

# ---------------------------------------------------------------------------
# Step toggles - true runs a step, false skips it. "auto" (the default for
# the conditional ones) runs it only when the config needs it; each of those
# scripts also checks for itself and exits early when it has nothing to do.
# Override any of these at runtime, e.g.:
#   DO_PREFLIGHT=false DO_SETUP=false ./full_concert_installprocess.sh
# Or pick steps by name: --from <step> resumes there, --skip <step>[,...] leaves
# steps out, --list-steps shows the plan.
# Offline (mirrored/airgap) mirroring is not chained here: run 1.1-1.3 first,
# on the right side of the air gap.
# ---------------------------------------------------------------------------
DO_INSTALL_OC="${DO_INSTALL_OC:-false}"                       # 0.0 oc for macOS (CP4D script, reused)
DO_FETCH_INSTALLER="${DO_FETCH_INSTALLER:-true}"              # 0.1 download + extract IBM's installer
DO_PREPARE_RUNNER="${DO_PREPARE_RUNNER:-true}"                # 0.2 runner (in-cluster Job by default)
DO_GLOBAL_PULL_SECRET="${DO_GLOBAL_PULL_SECRET:-false}"       # 1.0 optional global pull secret
DO_APPLY_MIRROR_CONFIG="${DO_APPLY_MIRROR_CONFIG:-auto}"      # 1.3 offline: IDMS/CatalogSources
DO_FAAS_REGISTRY="${DO_FAAS_REGISTRY:-auto}"                  # 1.4 only when FaaS is on
DO_PREFLIGHT="${DO_PREFLIGHT:-true}"                          # 2.0 preflight
DO_WORKER_CAPACITY="${DO_WORKER_CAPACITY:-true}"              # 2.0.1 report (changes only with CONCERT_AUTOSCALE_APPLY=true)
DO_CREATE_PROJECTS="${DO_CREATE_PROJECTS:-true}"              # 2.1 projects
DO_SERVICE_MESH="${DO_SERVICE_MESH:-auto}"                    # 2.2 only when Workflows Istio is on
DO_DATASTORES="${DO_DATASTORES:-true}"                        # 2.3 provision data stores
DO_DATASTORE_SECRETS="${DO_DATASTORE_SECRETS:-true}"          # 2.4 IBM data store secrets
DO_INSTALL_CONCERT="${DO_INSTALL_CONCERT:-auto}"              # 3.x render, setup, wait, details (auto: something for IBM's installer)
DO_INSTALL_OPTIMIZE="${DO_INSTALL_OPTIMIZE:-auto}"            # 5.x Optimize / Turbonomic (auto: CONCERT_INSTALL_OPTIMIZE)
DO_ADMIN_PASSWORD="${DO_ADMIN_PASSWORD:-auto}"                # 4.0 only when CONCERT_ADMIN_NEW_PASSWORD is set
DO_KEYCLOAK_USERS="${DO_KEYCLOAK_USERS:-auto}"                # 4.1 only when concert_users.txt exists

[[ "${DO_APPLY_MIRROR_CONFIG}" == auto ]] && { [[ "${CONCERT_IMAGE_SOURCE}" != entitled ]] && DO_APPLY_MIRROR_CONFIG=true || DO_APPLY_MIRROR_CONFIG=false; }
[[ "${DO_FAAS_REGISTRY}" == auto ]] && { concert_product_enabled faas && DO_FAAS_REGISTRY=true || DO_FAAS_REGISTRY=false; }
[[ "${DO_SERVICE_MESH}" == auto ]] && { concert_product_enabled istio && DO_SERVICE_MESH=true || DO_SERVICE_MESH=false; }
# Remote Hub + Optimize only: nothing for IBM's installer to do
[[ "${DO_INSTALL_CONCERT}" == auto ]] && { [[ -n "$(concert_selected_products)" ]] && DO_INSTALL_CONCERT=true || DO_INSTALL_CONCERT=false; }
[[ "${DO_INSTALL_OPTIMIZE}" == auto ]] && { concert_product_enabled optimize && DO_INSTALL_OPTIMIZE=true || DO_INSTALL_OPTIMIZE=false; }
[[ "${DO_ADMIN_PASSWORD}" == auto ]] && { [[ -n "${CONCERT_ADMIN_NEW_PASSWORD:-}" ]] && DO_ADMIN_PASSWORD=true || DO_ADMIN_PASSWORD=false; }
[[ "${DO_KEYCLOAK_USERS}" == auto ]] && { [[ -f "${CONCERT_CONFIG_DIR}/concert_users.txt" ]] && DO_KEYCLOAK_USERS=true || DO_KEYCLOAK_USERS=false; }

h_step oc                "${DO_INSTALL_OC}"          "0.0 install oc (macOS, CP4D script)" \
    "${CP4D_ROOT}/0_initial_setup/0.1_install_oc-MAC-ONLY.sh"
h_step fetch-installer   "${DO_FETCH_INSTALLER}"     "0.1 fetch IBM Concert installer" \
    "${SCRIPTS_ROOT}/0_initial_setup/0.1_fetch_concert_installer.sh"
h_step runner            "${DO_PREPARE_RUNNER}"      "0.2 prepare installer runner" \
    "${SCRIPTS_ROOT}/0_initial_setup/0.2_prepare_installer_runner.sh"

h_step pull-secret       "${DO_GLOBAL_PULL_SECRET}"  "1.0 global pull secret (optional)" \
    "${SCRIPTS_ROOT}/1_registry_access_and_mirroring/1.0_set_up_global_pull_credential_concert.sh"
h_step mirror-config     "${DO_APPLY_MIRROR_CONFIG}" "1.3 apply mirror configuration" \
    "${SCRIPTS_ROOT}/1_registry_access_and_mirroring/1.3_apply_datastore_mirror_config.sh"
h_step faas-registry     "${DO_FAAS_REGISTRY}"       "1.4 FaaS insecure registry" \
    "${SCRIPTS_ROOT}/1_registry_access_and_mirroring/1.4_set_up_faas_insecure_registry.sh"

h_step preflight         "${DO_PREFLIGHT}"           "2.0 cluster preflight" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.0_cluster_preflight.sh"
h_step worker-capacity   "${DO_WORKER_CAPACITY}"     "2.0.1 worker capacity" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.0.1_ensure_worker_capacity.sh"
h_step projects          "${DO_CREATE_PROJECTS}"     "2.1 create projects" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.1_create_projects.sh"
h_step service-mesh      "${DO_SERVICE_MESH}"        "2.2 Service Mesh + Istio for Workflows" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.2_install_service_mesh_for_workflows.sh"
h_step datastores        "${DO_DATASTORES}"          "2.3 provision data stores" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.3_provision_datastores/2.3_full_step_2.3_provision_datastores.sh"
h_step datastore-secrets "${DO_DATASTORE_SECRETS}"   "2.4 data store secrets" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.4_create_datastore_secrets.sh"

h_step concert           "${DO_INSTALL_CONCERT}"     "3 install IBM Concert" \
    "${SCRIPTS_ROOT}/3_install_concert/3_full_step_3_installprocess-concert.sh"
h_step optimize          "${DO_INSTALL_OPTIMIZE}"    "5 install Concert Optimize (Turbonomic)" \
    "${SCRIPTS_ROOT}/5_install_optimize/5_full_step_5_install_optimize.sh"

h_step admin-password    "${DO_ADMIN_PASSWORD}"      "4.0 rotate admin password" \
    "${SCRIPTS_ROOT}/4_post_install/4.0_change_admin_password.sh"
h_step keycloak-users    "${DO_KEYCLOAK_USERS}"      "4.1 Keycloak users" \
    "${SCRIPTS_ROOT}/4_post_install/4.1_manage_keycloak_users.sh"

h_steps_plan
h_steps_run
