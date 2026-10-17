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
# 5.2 Deploy Turbonomic (IBM's Optimize step 1)
# ------------------------------------------------------------------------------
# Creates the Xl custom resource in its standalone form: a plain Turbonomic,
# with the version, storage, security context, database size and probes it
# keeps later, but no Concert gateway or Concert API authentication yet. IBM's
# Optimize page creates the administrator (5.3) on that plain Turbonomic and
# only then switches it to Concert mode (5.4).
#
# Once 5.4 has switched the Xl to Concert mode this step leaves it alone - 5.4
# owns it from then on (re-run 5.4 to apply config changes).
# Turbonomic's own sizing guidance: 4 vCPU / 32 GB at least; the database
# volume is CONCERT_OPTIMIZE_DB_STORAGE_SIZE (IBM's chart default 500Gi).
# ==============================================================================

concert_product_enabled optimize || { concert_info "Optimize is not selected - nothing to do."; exit 0; }

eval "${OC_LOGIN}"
NS="$(concert_optimize_namespace)"
oc get deployment t8c-operator -n "${NS}" >/dev/null 2>&1 \
    || concert_die "No t8c-operator in ${NS} - run 5.1_install_turbonomic_operator.sh first."

mode="$(concert_optimize_xl_annotation "${CONCERT_OPTIMIZE_MODE_ANNOTATION}")"
if [[ "${mode}" == concert ]]; then
    concert_info "Xl ${NS}/${CONCERT_OPTIMIZE_XL} is already in Concert mode (5.4) - nothing to do here."
    exit 0
fi

FSGROUP=""
if [[ "${CONCERT_OPTIMIZE_SCC:-restricted}" != anyuid ]]; then
    FSGROUP="$(concert_optimize_fsgroup)" \
        || concert_die "Namespace ${NS} has no UID range annotation - set CONCERT_OPTIMIZE_SCC=anyuid and re-run 5.1."
fi

STAGE="$(concert_private_tmpdir)"
trap 'rm -rf "${STAGE}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
HASH="$(concert_optimize_render_cr standalone "${STAGE}/xl.json" "${FSGROUP}")"
cp "${STAGE}/xl.json" "${CONCERT_CONFIG_DIR}/optimize-xl-standalone.json"

oc apply -f "${STAGE}/xl.json" >/dev/null
concert_info "Xl ${NS}/${CONCERT_OPTIMIZE_XL} applied (standalone, Turbonomic ${CONCERT_OPTIMIZE_VERSION}, spec ${HASH}; copy in configs/concert_config/optimize-xl-standalone.json)."

concert_optimize_wait_xl_deployed 1800
# The components 5.3 talks to (initAdmin via nginx -> api -> auth).
concert_optimize_wait_deployments 2700 db consul kafka auth api nginx
concert_info "Turbonomic is up. Next: 5.3_initialize_turbonomic.sh (administrator and license)"
