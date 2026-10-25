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
# 2.3.1 CloudNativePG operator (only when PostgreSQL is provisioned)
# ------------------------------------------------------------------------------
# Installed cluster-wide into openshift-operators. The catalog that carries the
# package differs by OpenShift release (certified-operators on 4.21, earlier
# community-operators), so CONCERT_DS_PG_OPERATOR_SOURCE is used when it has
# cloudnative-pg and otherwise the catalog that does is picked, with a warning.
# Idempotent via operator_install_helpers.sh (CSV phase + channel reconcile);
# a Subscription on the wrong catalog is corrected by the re-apply.
# ==============================================================================

if ! concert_ds_server_provisioned POSTGRES; then
    concert_info "PostgreSQL is not provisioned by these scripts - skipping the CloudNativePG operator."
    exit 0
fi

eval "${OC_LOGIN}"

SOURCE="${CONCERT_DS_PG_OPERATOR_SOURCE:-certified-operators}"
CARRIED_BY="$(oc get packagemanifest -n openshift-marketplace --field-selector metadata.name=cloudnative-pg \
    -o jsonpath='{range .items[*]}{.status.catalogSource}{"\n"}{end}' 2>/dev/null || true)"
if [[ -z "${CARRIED_BY}" ]]; then
    concert_die "No catalog in openshift-marketplace offers cloudnative-pg (offline: run 1.2/1.3)."
elif ! (( ${${(f)CARRIED_BY}[(Ie)${SOURCE}]} )); then
    concert_warn "CatalogSource ${SOURCE} does not offer cloudnative-pg; using ${${(f)CARRIED_BY}[1]} (set CONCERT_DS_PG_OPERATOR_SOURCE to silence this)."
    SOURCE="${${(f)CARRIED_BY}[1]}"
fi

# CONCERT_DS_PG_OPERATOR_CHANNEL if the catalog offers it, else the catalog's
# default channel; as given (or stable-v1) when the catalog cannot be read.
concert_install_operator openshift-operators cloudnative-pg \
    "$(vr_operator_channel cloudnative-pg "${CONCERT_DS_PG_OPERATOR_CHANNEL:-}")" \
    "${SOURCE}" \
    'cloudnative-pg\.' all

concert_wait_for 300 "CRD clusters.postgresql.cnpg.io" oc get crd clusters.postgresql.cnpg.io
concert_info "CloudNativePG operator ready."
