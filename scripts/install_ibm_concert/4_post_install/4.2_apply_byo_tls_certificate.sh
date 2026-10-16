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
# 4.2 Bring-your-own TLS certificate for the Hub / Keycloak
# ------------------------------------------------------------------------------
# Wraps IBM's concert-hub/bin/kc-tls-attach-k8s <namespace> [<kc_host>] [<kc_crt>]
# in the runner:
#   ./4.2_apply_byo_tls_certificate.sh <certificate file> [<hostname>]
# Without a hostname IBM uses the current Hub route host.
#
# For a certificate on the Hub route at install time, set CONCERT_OCP_ROUTE_CERT
# (and CONCERT_OCP_ROUTE_HOSTNAME + a DNS record) instead - 3.0/3.2 pass it to
# the installer. IBM's "Bring your own TLS certificate (OCP)" page has the
# details (not yet verified on a cluster).
# ==============================================================================

CERT="${1:-}"
HOST="${2:-}"
[[ -n "${CERT}" && -f "${CERT}" ]] || concert_die "Usage: $0 <certificate file> [<hostname>]"
concert_product_enabled hub || concert_die "The Hub is remote - run this on the Hub cluster."

eval "${OC_LOGIN}"

args=("${PROJECT_CONCERT_HUB}")
if [[ -n "${HOST}" ]]; then
    args+=("${HOST}" "$(concert_run_file_path "${CERT}")")
else
    HOST="$(oc get route "${CONCERT_OCP_ROUTE_NAME:-solis-hub}" -n "${PROJECT_CONCERT_HUB}" -o jsonpath='{.spec.host}')"
    [[ -n "${HOST}" ]] || concert_die "Could not read the Hub route host - pass it as the second argument."
    args+=("${HOST}" "$(concert_run_file_path "${CERT}")")
fi

concert_run --name kc-tls --timeout 900 --file "${CERT}" -- concert-hub/bin/kc-tls-attach-k8s "${args[@]}"
concert_info "Certificate attached for ${HOST}."
