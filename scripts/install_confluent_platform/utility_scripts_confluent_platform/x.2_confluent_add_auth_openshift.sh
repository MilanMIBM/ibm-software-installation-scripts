#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: source confluent_vars.sh LAST so its cluster/storage values
# win over the CP4D ones defined in cpd_vars.sh. Override to point these
# scripts at a different config:  ENV_TARGET=<name|path> ./<script>.sh
: "${ENV_TARGET:=confluent}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform - OpenShift-backed authentication for the web UIs
# ------------------------------------------------------------------------------
# Replaces the htpasswd basic-auth gateway with an openshift/oauth-proxy sidecar,
# so Control Center is behind the cluster's own login page and users sign in with
# their OpenShift accounts. No external IdP, no LDAP server, no Keycloak.
#
# Why a proxy rather than C3's own SSO:
#   C3's confluent.controlcenter.auth.sso.mode requires OIDC, and OIDC requires
#   RBAC, which requires MDS, which in turn authenticates against LDAP or an
#   OIDC IdP - so C3's native SSO cannot be made self-contained. OpenShift's
#   OAuth server is OAuth2 but NOT OIDC (its metadata has no jwks_uri, no
#   userinfo_endpoint and it issues no id_token), so C3 cannot consume it
#   directly either. oauth-proxy speaks OpenShift's OAuth dialect natively and
#   bridges exactly that gap.
#
# Access control is delegated to OpenShift RBAC: the proxy is configured to
# admit only users who can 'get' the C3 service in this namespace, so granting
# or revoking UI access is an oc policy change, not a password handout.
#
# This is one of two mutually exclusive UI auth modes. Running it tears down the
# basic-auth gateway; run x.2_confluent_add_auth.sh to switch back.
#
# Usage:
#   ./x.2_confluent_add_auth_openshift.sh [--disable] [--yes] [--dry-run] [--no-status]
#
#   --disable    remove OpenShift auth and redeploy the UI unprotected
#   --yes        skip the --disable confirmation prompt
#   --dry-run    report what would change, change nothing
#   --no-status  skip the closing status report
# ==============================================================================

DISABLE=false
ASSUME_YES=false
DRY_RUN=false
RUN_STATUS=true

while (( $# > 0 )); do
    case "$1" in
        --disable)   DISABLE=true; shift ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --no-status) RUN_STATUS=false; shift ;;
        -h|--help)   sed -n '19,49p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

INSTALL="${SCRIPT_DIR}/1.1_confluent_install.sh"
STATUS="${SCRIPT_DIR}/1.2_confluent_status.sh"
[[ -f "${INSTALL}" ]] || { echo "[ERROR] Not found: ${INSTALL}" >&2; exit 1; }

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
SA="confluent"
: "${CONFLUENT_AUTH_SECRET:=confluent-auth}"
: "${CONFLUENT_CONTROL_CENTER_PORT:=9021}"
: "${CONFLUENT_C3_GATEWAY_PORT:=8443}"

if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[ERROR] Project '${NS}' does not exist. Install the platform first." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Report the transition
# ------------------------------------------------------------------------------
_current_mode="$(oc get deployment control-center -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || true)"
case "${_current_mode}" in
    *oauth-proxy*)   _current="OpenShift auth (oauth-proxy)" ;;
    *auth-gateway*)  _current="basic auth (nginx htpasswd)" ;;
    *)               _current="none - UI is unprotected" ;;
esac

echo "=============================================================================="
echo " Confluent web UI authentication - project '${NS}'"
echo "=============================================================================="
echo "  current : ${_current}"
if $DISABLE; then
    echo "  target  : disabled (UI unprotected)"
else
    echo "  target  : OpenShift login via oauth-proxy"
    echo "  access  : any user who can 'get services' in ${NS}"
fi
echo "  affects : control-center only (Kafka and its clients are untouched)"
echo ""

if $DRY_RUN; then
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi

if $DISABLE && ! $ASSUME_YES; then
    echo "This REMOVES authentication: the Control Center UI becomes publicly reachable."
    printf "Continue? [y/N] "
    read -r _reply
    case "${_reply}" in y|Y|yes|YES) ;; *) echo "[INFO] Aborted."; exit 0 ;; esac
    echo ""
fi

# ------------------------------------------------------------------------------
# Step 1 - OpenShift OAuth plumbing
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo " Step 1/2: OpenShift OAuth resources"
echo "------------------------------------------------------------------------------"

if $DISABLE; then
    export CONFLUENT_AUTH_ENABLED="false"
    export CONFLUENT_AUTH_MODE="none"
    oc delete secret "${CONFLUENT_AUTH_SECRET}-oauth" -n "${NS}" --ignore-not-found >/dev/null
    oc annotate serviceaccount "${SA}" -n "${NS}" \
        serviceaccounts.openshift.io/oauth-redirectreference.c3- >/dev/null 2>&1 || true
    echo "[INFO] Removed OpenShift OAuth resources."
else
    export CONFLUENT_AUTH_ENABLED="true"
    export CONFLUENT_AUTH_MODE="openshift"

    # The service account doubles as the OAuth client. The redirect reference
    # tells the OAuth server which route is allowed to receive the callback;
    # without it the login round-trip is rejected as an unregistered client.
    _route_host="$(oc get route control-center -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    if [[ -z "${_route_host}" ]]; then
        echo "[ERROR] Route 'control-center' not found in ${NS}." >&2
        echo "[ERROR] OpenShift auth needs the route to exist so the OAuth callback can be registered." >&2
        echo "[ERROR] Set CONFLUENT_CREATE_ROUTES=true and run 1.1_confluent_install.sh first." >&2
        exit 1
    fi

    oc annotate serviceaccount "${SA}" -n "${NS}" --overwrite \
        "serviceaccounts.openshift.io/oauth-redirectreference.c3={\"kind\":\"OAuthRedirectReference\",\"apiVersion\":\"v1\",\"reference\":{\"kind\":\"Route\",\"name\":\"control-center\"}}" >/dev/null
    echo "[INFO] Annotated serviceaccount/${SA} as an OAuth client for route control-center."

    # Cookie secret encrypts the proxy's session cookie. Generated once and
    # reused, so existing sessions survive a redeploy.
    _cookie="$(oc get secret "${CONFLUENT_AUTH_SECRET}-oauth" -n "${NS}" \
        -o jsonpath='{.data.cookie-secret}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
    if [[ -z "${_cookie}" ]]; then
        # oauth-proxy requires exactly 16, 24 or 32 bytes for AES.
        _cookie="$(LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32)"
        echo "[INFO] Generated a new session cookie secret."
    else
        echo "[INFO] Reusing the existing session cookie secret."
    fi
    oc create secret generic "${CONFLUENT_AUTH_SECRET}-oauth" \
        --from-literal=cookie-secret="${_cookie}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null

    # The proxy verifies the user's token against the API server, so it needs
    # permission to create TokenReviews and SubjectAccessReviews.
    oc adm policy add-cluster-role-to-user auth-delegator -z "${SA}" -n "${NS}" >/dev/null 2>&1 \
        || echo "[WARN] Could not grant the auth-delegator cluster role; the proxy may fail to verify tokens."

    echo "[INFO] Login URL will be https://${_route_host}"
fi

# ------------------------------------------------------------------------------
# Step 2 - redeploy Control Center
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 2/2: redeploy Control Center"
echo "------------------------------------------------------------------------------"

# Confine the install to the monitoring stack; the other components carry no UI
# auth configuration and re-applying them is unnecessary work.
export CONFLUENT_INSTALL_SCHEMA_REGISTRY="false"
export CONFLUENT_INSTALL_CONNECT="false"
export CONFLUENT_INSTALL_KSQLDB="false"
export CONFLUENT_INSTALL_REST_PROXY="false"
export CONFLUENT_INSTALL_CONTROL_CENTER="true"

"${INSTALL}"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================================="
if $DISABLE; then
    echo "[WARN] Control Center is now UNAUTHENTICATED."
else
    _host="$(oc get route control-center -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    echo "[INFO] Control Center now uses OpenShift login: https://${_host}"
    echo "[INFO] Sign in with any OpenShift account that can read services in ${NS}."
    echo "[INFO] Grant another user access with:"
    echo "[INFO]   oc policy add-role-to-user view <username> -n ${NS}"
fi
echo "=============================================================================="

if [[ "${RUN_STATUS}" == "true" && -f "${STATUS}" ]]; then
    echo ""
    "${STATUS}" || echo "[WARN] Status reported one or more components not ready (see above)."
fi
