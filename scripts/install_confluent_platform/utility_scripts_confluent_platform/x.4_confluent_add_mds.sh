#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform - Metadata Service (MDS) / RBAC
# ------------------------------------------------------------------------------
# Enables MDS, which is what makes "confluent login --url ..." work against this
# cluster from anywhere.
#
# MDS is NOT a separate component: it is embedded in the cp-server broker image
# this stack already runs (the confluent-metadata-service and confluent-security
# jars are in the image). Enabling it opens an HTTP listener on the brokers,
# turns on the ConfluentServerAuthorizer, and points MDS at a user store.
#
# What it gives you:
#   - "confluent login --url https://<mds route>" from any machine
#   - RBAC role bindings instead of all-or-nothing SASL super users
#   - a single identity for CLI, Control Center and the REST components
#
# User store, from CONFLUENT_MDS_USER_STORE (see x.4_confluent_user_store.sh):
#   LDAP   bundled OpenLDAP. Supports headless "confluent login -u u -p p".
#   OAUTH  bundled Keycloak, or an external OIDC provider when
#          CONFLUENT_MDS_OAUTH_JWKS_URL is set. Supports SSO / device code.
#
# ------------------------------------------------------------------------------
# COMMERCIAL FEATURE. MDS and RBAC are licensed Confluent features. With no
# CONFLUENT_LICENSE_KEY the brokers run them under the built-in 30-day trial and
# stop honouring them when it expires. This script warns but proceeds.
# ------------------------------------------------------------------------------
#
# Requires CONFLUENT_SASL_ENABLED=true: MDS issues tokens to principals that
# must already be able to authenticate to Kafka. Run x.2_confluent_add_sasl.sh
# first.
#
# DISRUPTIVE: every broker restarts. Topic data is preserved.
#
# Usage:
#   ./x.4_confluent_add_mds.sh [--store LDAP|OAUTH] [--rotate] [--yes]
#                              [--dry-run] [--no-status] [--skip-user-store]
#
#   --store X          override CONFLUENT_MDS_USER_STORE for this run
#   --rotate           regenerate the MDS token keypair and all passwords
#   --skip-user-store  do not deploy/refresh the identity provider
#   --yes              skip the confirmation prompt
#   --dry-run          report what would change, change nothing
#   --no-status        skip the closing status report
# ==============================================================================

ROTATE=false
ASSUME_YES=true
DRY_RUN=false
RUN_STATUS=true
SKIP_USER_STORE=false
STORE_OVERRIDE=""

_need_value() { [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }; }

while (( $# > 0 )); do
    case "$1" in
        --store)            _need_value "$1" "${2:-}"; STORE_OVERRIDE="${2:u}"; shift 2 ;;
        --rotate)           ROTATE=true; shift ;;
        --skip-user-store)  SKIP_USER_STORE=true; shift ;;
        --yes|-y)           ASSUME_YES=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        --no-status)        RUN_STATUS=false; shift ;;
        -h|--help)          sed -n '16,56p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

INSTALL="${SCRIPT_DIR}/1.1_confluent_install.sh"
STATUS="${SCRIPT_DIR}/1.2_confluent_status.sh"
USER_STORE="${SCRIPT_DIR}/x.4_confluent_user_store.sh"
[[ -f "${INSTALL}" ]] || { echo "[ERROR] Not found: ${INSTALL}" >&2; exit 1; }

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_MDS_PORT:=8090}"
: "${CONFLUENT_MDS_SECRET:=confluent-mds}"
: "${CONFLUENT_MDS_SUPER_USER:=mds-admin}"
: "${CONFLUENT_MDS_USERS:=kafka-admin,kafka-user}"
: "${CONFLUENT_MDS_USER_STORE:=LDAP}"
: "${CONFLUENT_SASL_ENABLED:=false}"
: "${CONFLUENT_SASL_ADMIN_USER:=confluent-admin}"
: "${CONFLUENT_LICENSE_KEY:=}"
: "${CONFLUENT_CREATE_ROUTES:=true}"
: "${CONFLUENT_MDS_OAUTH_JWKS_URL:=}"
: "${CONFLUENT_LDAP_SECRET:=confluent-ldap}"
: "${CONFLUENT_KEYCLOAK_SECRET:=confluent-keycloak}"

if [[ -n "${STORE_OVERRIDE}" ]]; then CONFLUENT_MDS_USER_STORE="${STORE_OVERRIDE}"; fi
_store="${CONFLUENT_MDS_USER_STORE:u}"
export CONFLUENT_MDS_USER_STORE="${_store}"

case "${_store}" in
    LDAP|OAUTH) ;;
    *) echo "[ERROR] --store / CONFLUENT_MDS_USER_STORE must be LDAP or OAUTH (got '${_store}')." >&2; exit 1 ;;
esac

oc get namespace "${NS}" &>/dev/null || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------
# MDS hands out tokens for principals that must already be able to authenticate
# to Kafka. Without SASL there are no such principals, and the RBAC authorizer
# would deny everything, so refuse rather than produce a broken cluster.
# SASL is a prerequisite, not an independent choice, so enable it rather than
# refusing and making the user run a second script by hand. The installer does
# the same, and x.2_confluent_add_sasl.sh remains available to configure SASL on
# its own. The SASL secret is created here if it does not exist yet, because the
# installer reads the admin credential back from it.
if [[ "${CONFLUENT_SASL_ENABLED}" != "true" ]]; then
    echo "[INFO] MDS requires Kafka authentication; enabling SASL as part of this run."
    export CONFLUENT_SASL_ENABLED="true"
fi

# The installer reads the SASL admin credential back from this secret and exits
# if it is absent, so create it when missing. Only the secret is created here:
# x.2_confluent_add_sasl.sh runs the installer itself, and calling it would add
# an extra full install - exactly the repetition this flow avoids. The installer
# registers the SCRAM users in Kafka as part of its deferred second pass.
: "${CONFLUENT_SASL_SECRET:=confluent-sasl}"
: "${CONFLUENT_SASL_CLIENTS:=app-client}"

if ! oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" &>/dev/null; then
    echo "[INFO] No SASL credentials yet; generating secret '${CONFLUENT_SASL_SECRET}'."
    _sasl_args=()
    for _u in "${CONFLUENT_SASL_ADMIN_USER}" ${=${CONFLUENT_SASL_CLIENTS}//,/ }; do
        _sasl_args+=(--from-literal="${_u}=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)")
    done
    oc create secret generic "${CONFLUENT_SASL_SECRET}" "${_sasl_args[@]}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null \
        || { echo "[ERROR] Could not create the SASL secret." >&2; exit 1; }
    echo "[INFO] Credentials stored in secret '${CONFLUENT_SASL_SECRET}'."
fi

_current="$(oc get sts broker -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAFKA_CONFLUENT_METADATA_SERVER_LISTENERS")].value}' 2>/dev/null || true)"
[[ -n "${_current}" ]] && _state="enabled (${_current})" || _state="not enabled"

echo "=============================================================================="
echo " Metadata Service (MDS) / RBAC - project '${NS}'"
echo "=============================================================================="
echo "  current   : ${_state}"
echo "  target    : MDS on port ${CONFLUENT_MDS_PORT}, user store ${_store}"
echo "  super user: ${CONFLUENT_MDS_SUPER_USER}"
echo "  restarts  : all ${CONFLUENT_BROKER_REPLICAS:-?} brokers (topic data is kept)"
echo ""

# ------------------------------------------------------------------------------
# Licensing
# ------------------------------------------------------------------------------
if [[ -z "${CONFLUENT_LICENSE_KEY}" ]]; then
    echo "------------------------------------------------------------------------------"
    echo " LICENSE WARNING"
    echo "------------------------------------------------------------------------------"
    echo "[WARN] MDS and RBAC are COMMERCIAL Confluent Platform features and no"
    echo "[WARN] CONFLUENT_LICENSE_KEY is set."
    echo "[WARN]"
    echo "[WARN] The brokers will run them under the built-in 30-DAY TRIAL, which starts"
    echo "[WARN] when the cluster first uses the feature. When it expires the brokers"
    echo "[WARN] stop honouring MDS and logins begin to fail."
    echo "[WARN]"
    echo "[WARN] For anything beyond evaluation, set CONFLUENT_LICENSE_KEY in"
    echo "[WARN] cp4d_config/confluent_vars.sh and re-run this script."
    echo "------------------------------------------------------------------------------"
    echo ""
else
    echo "[INFO] Using the configured Confluent license key."
fi

if $DRY_RUN; then
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi

if ! $ASSUME_YES; then
    echo "This restarts every broker and turns on the RBAC authorizer."
    echo "Existing SASL clients keep working; the super user retains full access."
    printf "Continue? [y/N] "
    read -r _reply
    case "${_reply}" in y|Y|yes|YES) ;; *) echo "[INFO] Aborted."; exit 0 ;; esac
    echo ""
fi

# ------------------------------------------------------------------------------
# Step 1 - identity provider
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo " Step 1/4: identity provider (${_store})"
echo "------------------------------------------------------------------------------"

if $SKIP_USER_STORE; then
    echo "[INFO] --skip-user-store: leaving the identity provider untouched."
else
    _us_args=()
    $ROTATE && _us_args+=(--rotate)
    CONFLUENT_MDS_USER_STORE="${_store}" "${USER_STORE}" "${_us_args[@]}"
fi

# ------------------------------------------------------------------------------
# Step 2 - MDS token keypair
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 2/4: MDS token signing keypair"
echo "------------------------------------------------------------------------------"

# MDS signs the tokens it issues with an RSA keypair. Every component that
# validates a token needs the public key, so both halves live in one secret and
# are mounted into the brokers. Regenerating the pair invalidates outstanding
# tokens, so it is only done on first run or --rotate.
_have_key="$(oc get secret "${CONFLUENT_MDS_SECRET}" -n "${NS}" -o jsonpath='{.data.tokenKeypair\.pem}' 2>/dev/null || true)"

if [[ -z "${_have_key}" || "${ROTATE}" == "true" ]]; then
    # No trap here: an EXIT trap would replace the timer trap installed at the
    # top of the script. The directory is removed explicitly below, and mktemp
    # puts it under TMPDIR, so a hard failure leaks nothing that matters.
    _tmp="$(mktemp -d)"
    openssl genrsa -out "${_tmp}/tokenKeypair.pem" 2048 2>/dev/null
    openssl rsa -in "${_tmp}/tokenKeypair.pem" -outform PEM -pubout \
        -out "${_tmp}/public.pem" 2>/dev/null
    oc create secret generic "${CONFLUENT_MDS_SECRET}" \
        --from-file=tokenKeypair.pem="${_tmp}/tokenKeypair.pem" \
        --from-file=public.pem="${_tmp}/public.pem" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null
    rm -rf "${_tmp}"
    echo "[INFO] Generated a new MDS token keypair in secret '${CONFLUENT_MDS_SECRET}'."
else
    echo "[INFO] Reusing the existing MDS token keypair (--rotate to replace it)."
fi

# ------------------------------------------------------------------------------
# Step 3 - reconfigure and restart the platform
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 3/4: enable MDS on the brokers"
echo "------------------------------------------------------------------------------"

# The installer is re-run rather than the StatefulSet being patched in place.
# Enabling MDS is not an env-only change: it also adds the token-keypair volume
# and its mount, the MDS container port, the port on the broker service, and an
# export of KAFKA_CONFLUENT_METADATA_SERVER_ADVERTISED_LISTENERS into the
# container's startup command (it must carry each pod's own FQDN, which a static
# env value cannot). Reproducing all five with oc patch would duplicate the
# installer's logic and drift from it, so the installer stays the single place
# that knows how a broker is shaped.
#
# This is not a reinstall: oc apply only rewrites the objects whose spec changed,
# and only the brokers restart. Topic data lives on the PVCs and is untouched.
export CONFLUENT_MDS_ENABLED="true"
"${INSTALL}"

# Confirm the StatefulSet actually carries the MDS settings before waiting on a
# listener that may never come up. The installer can exit 0 having skipped the
# MDS block (a shell error inside a rendered section, or MDS deferred to a
# second pass), and without this the script proceeds to poll a port that was
# never opened and blames a five-minute timeout on the brokers "settling".
_sts_env="$(oc get sts broker -n "${NS}" \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"

_missing=()
for _k in KAFKA_AUTHORIZER_CLASS_NAME \
          KAFKA_CONFLUENT_AUTHORIZER_AUTHORITY_NAME \
          KAFKA_CONFLUENT_METADATA_SERVER_LISTENERS; do
    grep -qx "${_k}" <<< "${_sts_env}" || _missing+=("${_k}")
done

if (( ${#_missing[@]} > 0 )); then
    echo "[ERROR] The broker StatefulSet is missing required MDS settings:" >&2
    for _k in "${_missing[@]}"; do echo "[ERROR]   ${_k}" >&2; done
    echo "[ERROR]" >&2
    echo "[ERROR] MDS was NOT enabled. The brokers are unchanged and still running," >&2
    echo "[ERROR] so nothing is broken - but re-running this script will not help" >&2
    echo "[ERROR] until the installer renders these. Check its output above for an" >&2
    echo "[ERROR] error such as 'command not found' from inside 1.1_confluent_install.sh." >&2
    exit 1
fi
echo "[INFO] Verified: the broker StatefulSet carries the MDS configuration."

# The rollout must finish before MDS can answer. Without this the script polls
# while the old pods are still terminating and reports a false timeout.
echo "[INFO] Waiting for the broker rollout to finish..."
oc rollout status statefulset/broker -n "${NS}" \
    --timeout="${CONFLUENT_ROLLOUT_TIMEOUT:-600s}" \
    || echo "[WARN] The broker rollout did not complete in time; continuing to the checks below."

# ------------------------------------------------------------------------------
# Step 4 - role bindings and client details
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 4/4: role bindings and CLI details"
echo "------------------------------------------------------------------------------"

MDS_INTERNAL="http://broker:${CONFLUENT_MDS_PORT}"

# Wait for MDS to answer before binding roles: the brokers have just restarted
# and the listener comes up after the broker itself is ready.
echo "[INFO] Waiting for MDS to accept requests..."
# Any HTTP response means the listener is serving. -sf is deliberately NOT used:
# with authentication.method=BASIC the unauthenticated probe gets 401, which
# curl -f turns into a failure, so the loop would always run out the full five
# minutes even on a perfectly healthy MDS. Treat 200/401/403 alike as "up".
_ok=false
for _i in $(seq 1 60); do
    _code="$(oc exec broker-0 -n "${NS}" -- bash -c \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
         http://localhost:${CONFLUENT_MDS_PORT}/security/1.0/features" 2>/dev/null || true)"
    case "${_code}" in
        200|401|403) _ok=true; break ;;
    esac
    sleep 5
done

if ! $_ok; then
    echo "[WARN] MDS did not respond within 5 minutes. The brokers may still be settling."
    echo "[WARN] Check:  oc logs broker-0 -n ${NS} | grep -i metadata"
else
    echo "[INFO] MDS is up."
fi

_super_pw=""
case "${_store}" in
    LDAP)  _super_pw="$(oc get secret "${CONFLUENT_LDAP_SECRET}" -n "${NS}" -o jsonpath="{.data.${CONFLUENT_MDS_SUPER_USER}}" 2>/dev/null | base64 --decode || true)" ;;
    OAUTH) _super_pw="$(oc get secret "${CONFLUENT_KEYCLOAK_SECRET}" -n "${NS}" -o jsonpath="{.data.${CONFLUENT_MDS_SUPER_USER}}" 2>/dev/null | base64 --decode || true)" ;;
esac

# The Kafka cluster id MDS scopes role bindings to. Read from the running
# cluster rather than assumed, so it stays correct after a reinstall.
# /v1/metadata/id is authenticated under BASIC, so the super user's credentials
# are passed; kafka-storage's stored id is the fallback when MDS is not
# answering yet, since it is the same value and needs no HTTP at all.
_kafka_id="$(oc exec broker-0 -n "${NS}" -- bash -c \
    "curl -s --max-time 10 -u '${CONFLUENT_MDS_SUPER_USER}:${_super_pw}' \
     http://localhost:${CONFLUENT_MDS_PORT}/v1/metadata/id" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"

if [[ -z "${_kafka_id}" ]]; then
    _kafka_id="$(oc exec broker-0 -n "${NS}" -- bash -c \
        "cat /var/lib/kafka/data/logs/meta.properties 2>/dev/null" 2>/dev/null \
        | sed -n 's/^cluster\.id=//p' | tr -d '\r' || true)"
fi

if $_ok && [[ -n "${_kafka_id}" && -n "${_super_pw}" ]]; then
    echo "[INFO] Kafka cluster id: ${_kafka_id}"
    echo "[INFO] Granting SystemAdmin to '${CONFLUENT_MDS_SUPER_USER}'..."
    # The body is the cluster map at the TOP LEVEL, not wrapped in a "scope"
    # key. Wrapping it (or adding "clusterName": null beside it) makes MDS
    # reject the request with
    #   400 Invalid Scope : Scope is empty. Check format.
    # which reads like a credentials problem but is purely the body shape.
    # Verified against CP 8.2 MDS: this form returns 204 and the binding shows
    # up under .../lookup/principals/User:<user>/roleNames.
    # -f is NOT used: it discards the response body, and MDS explains exactly
    # what it disliked there. Capture body and status so a failure is diagnosed
    # rather than guessed at.
    _grant_out="$(oc exec broker-0 -n "${NS}" -- bash -c "
        curl -s -w '\nHTTP=%{http_code}' -X POST \
          -u '${CONFLUENT_MDS_SUPER_USER}:${_super_pw}' \
          -H 'Content-Type: application/json' \
          --max-time 30 \
          -d '{\"clusters\":{\"kafka-cluster\":\"${_kafka_id}\"}}' \
          'http://localhost:${CONFLUENT_MDS_PORT}/security/1.0/principals/User:${CONFLUENT_MDS_SUPER_USER}/roles/SystemAdmin'
        " 2>/dev/null || true)"
    _grant_code="${_grant_out##*HTTP=}"
    _grant_body="${_grant_out%$'\n'HTTP=*}"

    case "${_grant_code}" in
        20*)
            # 204 only says the write was accepted. Read the binding back, so a
            # silent no-op cannot be reported as success.
            _roles="$(oc exec broker-0 -n "${NS}" -- bash -c "
                curl -s --max-time 30 \
                  -u '${CONFLUENT_MDS_SUPER_USER}:${_super_pw}' \
                  -H 'Content-Type: application/json' \
                  -d '{\"clusters\":{\"kafka-cluster\":\"${_kafka_id}\"}}' \
                  'http://localhost:${CONFLUENT_MDS_PORT}/security/1.0/lookup/principals/User:${CONFLUENT_MDS_SUPER_USER}/roleNames'
                " 2>/dev/null || true)"
            if [[ "${_roles}" == *SystemAdmin* ]]; then
                echo "[INFO]   granted and verified: ${CONFLUENT_MDS_SUPER_USER} holds SystemAdmin."
            else
                echo "[WARN]   MDS accepted the grant (HTTP ${_grant_code}) but the binding does not"
                echo "[WARN]   read back. Roles returned: ${_roles:-<none>}"
            fi
            ;;
        401|403)
            echo "[WARN]   MDS rejected the credentials for '${CONFLUENT_MDS_SUPER_USER}' (HTTP ${_grant_code})."
            echo "[WARN]   The account exists in the secret but MDS cannot authenticate it against"
            echo "[WARN]   the ${_store} user store. Re-run x.4_confluent_user_store.sh."
            ;;
        *)
            echo "[WARN]   could not grant SystemAdmin (HTTP ${_grant_code:-no response})."
            [[ -n "${_grant_body}" ]] && echo "[WARN]   MDS said: ${_grant_body}"
            echo "[WARN]   Grant manually with:"
            echo "[WARN]     confluent iam rbac role-binding create --principal User:${CONFLUENT_MDS_SUPER_USER} \\"
            echo "[WARN]       --role SystemAdmin --kafka-cluster ${_kafka_id}"
            ;;
    esac
else
    _kafka_id="${_kafka_id:-<cluster-id>}"
fi

# ------------------------------------------------------------------------------
# Refresh the instance details so the CLI helper can pick everything up
# ------------------------------------------------------------------------------
# Credentials are NOT written here. 1.3_confluent_get_instance_details.sh reads
# them back from the cluster into cp4d_config/confluent_instance_details.sh,
# which is the single source the confluent_cli_login.sh helper consumes. That
# keeps one generated file rather than two that can disagree.
DETAILS_SCRIPT="${SCRIPT_DIR}/1.3_confluent_get_instance_details.sh"
MDS_HOST=""
if [[ "${CONFLUENT_CREATE_ROUTES}" == "true" ]]; then
    MDS_HOST="$(oc get route mds -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
fi
MDS_URL="${MDS_HOST:+https://${MDS_HOST}}"

if [[ -x "${DETAILS_SCRIPT}" ]]; then
    echo "[INFO] Refreshing cp4d_config/confluent_instance_details.sh..."
    "${DETAILS_SCRIPT}" >/dev/null 2>&1 || echo "[WARN] Could not refresh the details file."
fi

echo ""
echo "  Connect the CLI from any machine (installs it if missing):"
echo ""
echo "    source src/scripts/confluent_install/confluent_cli_login.sh"
echo ""
if [[ -z "${MDS_URL}" ]]; then
    echo "  No MDS route (CONFLUENT_CREATE_ROUTES=false), so port-forward first:"
    echo "    oc -n ${NS} port-forward svc/broker ${CONFLUENT_MDS_PORT}:${CONFLUENT_MDS_PORT}"
    echo "    confluent login --url http://localhost:${CONFLUENT_MDS_PORT}"
    echo ""
fi
echo "  Then:"
echo "    confluent iam rbac role-binding list --principal User:${CONFLUENT_MDS_SUPER_USER} \\"
echo "      --kafka-cluster ${_kafka_id}"
echo ""
echo "  Grant another user access to a topic:"
echo "    confluent iam rbac role-binding create --principal User:kafka-user \\"
echo "      --role ResourceOwner --resource Topic:my-topic --kafka-cluster ${_kafka_id}"
echo ""
echo "  Remove MDS again:  x.4_confluent_remove_mds.sh"

if [[ "${RUN_STATUS}" == "true" && -f "${STATUS}" ]]; then
    echo ""
    "${STATUS}" || echo "[WARN] Status reported one or more components not ready (see above)."
fi
