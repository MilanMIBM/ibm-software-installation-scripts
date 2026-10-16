#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 3.2 Run IBM's installer (bin/setup) in the runner
# ------------------------------------------------------------------------------
# Installs/reconciles Hub -> (ITOM) -> Concert -> Data Apps -> Workflows in one
# run (IBM: 15-30 min). Re-running with the same params.ini is IBM's
# reconcile/upgrade path, so this step is safe to repeat.
#
# Before it starts, it refuses to run when a store configured as external has
# no secret yet: IBM would silently fall back to its built-in store, and that
# choice cannot be changed after the first install.
#
# Secrets go in as environment variables (setup reads DEFAULT_ADMIN_USERNAME,
# DEFAULT_ADMIN_PASSWORD and REG_PASS from the environment), never as flags.
# Success = exit 0 AND IBM's "DEPLOYMENT SUCCESSFUL" line. The full stream is
# also saved to concert_workspace/logs/.
# ==============================================================================

PARAMS="${CONCERT_CONFIG_DIR}/params.ini"
OVR="${CONCERT_CONFIG_DIR}/workflows-override-values.yaml"
[[ -f "${PARAMS}" ]] || concert_die "Run 3.0_render_params_ini.sh first."
[[ "${PARAMS}" -nt "${CONCERT_CONFIG_DIR}/concert_vars.sh" ]] \
    || concert_die "params.ini is older than concert_vars.sh - re-run 3.0_render_params_ini.sh."

eval "${OC_LOGIN}"

# --- Guard: external stores must be in place before the first install -------------
missing=()
_need() { oc get secret "$2" -n "$1" >/dev/null 2>&1 || missing+=("$1/$2"); }
_need_key() { [[ -n "$(oc get secret "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null)" ]] || missing+=("$1/$2 ($3)"); }
concert_ds_consumer_active KEYCLOAK           && _need "${PROJECT_CONCERT_HUB}" app-cfg-byo-secret
if concert_ds_consumer_active CONCERT_DB; then
    _need "${PROJECT_CONCERT}" concert-appdb-creds
    _need "${PROJECT_CONCERT}" concert-configdb-creds
fi
if concert_ds_consumer_active CONCERT_S3; then
    _need "${PROJECT_CONCERT}" concert-lzbucket-creds
    _need "${PROJECT_CONCERT}" concert-elbucket-creds
fi
concert_ds_consumer_active CONCERT_NEO4J      && _need "${PROJECT_CONCERT}" concert-neo4j-creds
concert_ds_consumer_active DATAAPPS_DB        && _need "${PROJECT_CONCERT_DATAAPPS}" dataapps-database-creds
concert_ds_consumer_active DATAAPPS_REDIS     && _need "${PROJECT_CONCERT_DATAAPPS}" dataapps-redis-creds
concert_ds_consumer_active WORKFLOWS_MYSQL    && _need_key "${PROJECT_CONCERT_WORKFLOWS}" cw-secrets MYSQLDB_HOST
concert_ds_consumer_active WORKFLOWS_POSTGRES && _need_key "${PROJECT_CONCERT_WORKFLOWS}" cw-secrets POSTGRESQL_HOST
concert_ds_consumer_active WORKFLOWS_S3       && _need_key "${PROJECT_CONCERT_WORKFLOWS}" cw-secrets CW_HOST
concert_ds_consumer_active WORKFLOWS_RABBITMQ && _need_key "${PROJECT_CONCERT_WORKFLOWS}" cw-secrets RABBITMQ_HOST
if (( ${#missing} )); then
    concert_error "External data store secrets missing: ${missing[*]}"
    concert_die "Run 2_prepare_cluster/2.3*/2.4 first - without them IBM installs its built-in stores, permanently."
fi

if concert_product_enabled istio; then
    oc get istio default >/dev/null 2>&1 || concert_die "Workflows Istio is on but no Istio control plane exists - run 2.2 first."
fi
if concert_product_enabled faas; then
    route="$(concert_workflows_address)"
    oc get image.config.openshift.io cluster -o json | jq -e --arg r "${route}" '.spec.registrySources.insecureRegistries // [] | index($r)' >/dev/null \
        || concert_die "FaaS is on but ${route} is not an insecure registry - run 1_registry_access_and_mirroring/1.4 first."
fi

# --- Run ------------------------------------------------------------------------
files=(--file "${PARAMS}")
[[ -f "${OVR}" ]] && files+=(--file "${OVR}")
[[ -n "${CONCERT_OCP_ROUTE_CERT:-}" ]] && concert_local_hub_enabled && files+=(--file "${CONCERT_OCP_ROUTE_CERT}")

mkdir -p "${CONCERT_WORKSPACE}/logs"
LOG="${CONCERT_WORKSPACE}/logs/setup-$(date +%Y%m%d-%H%M%S).log"
concert_info "Running IBM's installer (log copy: ${LOG})"

set +e
concert_run --name setup \
    --env DEFAULT_ADMIN_USERNAME=CONCERT_ADMIN_USERNAME \
    --env DEFAULT_ADMIN_PASSWORD=CONCERT_ADMIN_PASSWORD \
    --env REG_PASS=CONCERT_REGISTRY_PASSWORD \
    --env WATSONX_API_PASSWORD=CONCERT_WATSONX_API_PASSWORD \
    --env WATSONX_API_KEY=CONCERT_WATSONX_API_KEY \
    --env LLM_API_KEY=CONCERT_LLM_API_KEY \
    --env SECURECODER_MEND_USER_KEY=CONCERT_SECURECODER_MEND_USER_KEY \
    --env SECURECODER_MEND_API_KEY=CONCERT_SECURECODER_MEND_API_KEY \
    "${files[@]}" -- bin/setup --license_acceptance=y 2>&1 | tee "${LOG}"
rc=${pipestatus[1]}
set -e

if (( rc == 0 )) && grep -q 'DEPLOYMENT SUCCESSFUL' "${LOG}"; then
    concert_info "IBM Concert installer finished: DEPLOYMENT SUCCESSFUL."
    concert_info "Next: 3.3_concert_status.sh and 3.4_get_instance_details.sh"
else
    concert_error "IBM's installer failed (exit ${rc}). IBM's detailed log: logs/product_install_logs_<timestamp>.log in the installer dir"
    concert_error "(cluster runner: x_clean_or_debug_concert/x_fetch_installer_logs.sh copies it here)."
    exit 1
fi
