#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"   # loads common, confluent, operator_install, version_resolver helpers

# ==============================================================================
# Confluent Platform (operator mode) - Metadata Service (MDS) / RBAC  [phase 5]
# ------------------------------------------------------------------------------
# PHASE 5, UNVERIFIED (V5 secret key names, V21 KRaft controller RBAC): the
# shapes follow the CFK docs and the feature-parity matrix (I16/I17) but have
# not run on a cluster yet.
#
# Turns on MDS in the Kafka CR (spec.services.mds, authorization rbac) through
# 1.1_confluent_install.sh, then the RBAC objects CFK needs:
#   [1/5] identity provider: x.4_confluent_user_store.sh (LDAP or OAUTH/Keycloak;
#         in operator mode it also creates the CFK component principals)
#   [2/5] secrets: MDS token keypair (confluent-mds-cfk-token: mdsTokenKeyPair.pem,
#         mdsPublicKey.pem), LDAP bind (confluent-ldap-cfk-bind: ldap.txt), the
#         KafkaRestClass bearer credential (confluent-mds-cfk-client: bearer.txt)
#   [3/5] OAUTH: the JWKS and issuer URLs from the Keycloak route (unless
#         CONFLUENT_MDS_OAUTH_JWKS_URL / _ISSUER are set)
#   [4/5] CONFLUENT_MDS_ENABLED=true, re-run 1.1 (CFO_MDS_HANDOFF=1): CFK rolls
#         Kafka; KafkaRestClass default + ConfluentRolebinding mds-super-systemadmin
#   [5/5] wait for the role binding (.status.state CREATED), refresh the details
#
# COMMERCIAL FEATURE: without CONFLUENT_LICENSE_KEY it runs on the 30-day trial.
# DISRUPTIVE: CFK rolls every broker. Topic data is preserved.
#
# Usage:
#   ./x.4_confluent_add_mds.sh [--store LDAP|OAUTH] [--rotate] [--yes]
#                              [--dry-run] [--no-status] [--skip-user-store]
#
#   --store X          override CONFLUENT_MDS_USER_STORE for this run
#   --rotate           regenerate the MDS token keypair and all passwords
#   --skip-user-store  do not deploy/refresh the identity provider
#   --yes              skip the confirmation prompt (default)
#   --dry-run          report what would change, change nothing
#   --no-status        skip the closing status report
#
# Exit status: 0 ok, 1 error, 2 blocked (scripts-mode install in the namespace).
# ==============================================================================

usage() { sed -n '/^# Confluent Platform (operator mode) - Metadata Service/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

ROTATE=false
ASSUME_YES=true
DRY_RUN=false
RUN_STATUS=true
SKIP_USER_STORE=false
STORE_OVERRIDE=""

while (( $# > 0 )); do
    case "$1" in
        --store)            h_need_value "$1" "${2:-}"; STORE_OVERRIDE="${2:u}"; shift 2 ;;
        --rotate)           ROTATE=true; shift ;;
        --skip-user-store)  SKIP_USER_STORE=true; shift ;;
        --yes|-y)           ASSUME_YES=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        --no-status)        RUN_STATUS=false; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done
export DRY_RUN

cfo_entry platform

INSTALL="${CF_PLATFORM_DIR}/1.1_confluent_install.sh"
STATUS="${CF_PLATFORM_DIR}/1.2_confluent_status.sh"
USER_STORE="${CF_PLATFORM_DIR}/utility_scripts_confluent_platform/x.4_confluent_user_store.sh"
DETAILS_SCRIPT="${CF_PLATFORM_DIR}/1.3_confluent_get_instance_details.sh"
NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_MDS_SUPER_USER:=mds-admin}"
: "${CONFLUENT_MDS_USER_STORE:=LDAP}"
: "${CONFLUENT_SASL_ENABLED:=false}"
: "${CONFLUENT_SASL_SECRET:=confluent-sasl}"
: "${CONFLUENT_SASL_ADMIN_USER:=confluent-admin}"
: "${CONFLUENT_SASL_CLIENTS:=app-client}"
: "${CONFLUENT_LDAP_SECRET:=confluent-ldap}"
: "${CONFLUENT_LDAP_DOMAIN:=confluent.io}"
: "${CONFLUENT_LDAP_ADMIN_USER:=admin}"
: "${CONFLUENT_KEYCLOAK_SECRET:=confluent-keycloak}"
: "${CONFLUENT_KEYCLOAK_REALM:=confluent}"
: "${CONFLUENT_MDS_OAUTH_JWKS_URL:=}"
: "${CONFLUENT_MDS_OAUTH_ISSUER:=}"

[[ -n "${STORE_OVERRIDE}" ]] && CONFLUENT_MDS_USER_STORE="${STORE_OVERRIDE}"
_store="${CONFLUENT_MDS_USER_STORE:u}"
export CONFLUENT_MDS_USER_STORE="${_store}"
case "${_store}" in
    LDAP|OAUTH) ;;
    *) echo "[ERROR] --store / CONFLUENT_MDS_USER_STORE must be LDAP or OAUTH (got '${_store}')." >&2; exit 1 ;;
esac

[[ -n "$(oc get namespace "${NS}" -o name 2>/dev/null || true)" ]] || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }

# MDS needs authenticated principals: SASL is a prerequisite (as the scripts-mode x.4).
if [[ "${CONFLUENT_SASL_ENABLED}" != "true" ]]; then
    echo "[INFO] MDS requires Kafka authentication; enabling SASL as part of this run."
    export CONFLUENT_SASL_ENABLED="true"
fi

_kafka_res="$(cfo_resource Kafka)"
_mds_live="$(oc get "${_kafka_res}" "${CF_KAFKA_CR}" -n "${NS}" -o jsonpath='{.spec.authorization.type}' 2>/dev/null || true)"
[[ "${_mds_live}" == rbac ]] && _state="enabled (authorization rbac)" || _state="not enabled"

echo "=============================================================================="
echo " Metadata Service (MDS) / RBAC (operator mode, phase 5) - project '${NS}'"
echo "=============================================================================="
echo "  current   : ${_state}"
echo "  target    : MDS in the Kafka CR, user store ${_store}"
echo "  super user: ${CONFLUENT_MDS_SUPER_USER}"
echo "  restarts  : CFK rolls all ${CONFLUENT_BROKER_REPLICAS:-?} brokers (topic data is kept)"
echo "[INFO] MDS/RBAC in operator mode is phase 5 (unverified: V5, V21)"
[[ -n "${CONFLUENT_LICENSE_KEY:-}" ]] || cfo_license_warning
echo ""

if ! $ASSUME_YES && ! $DRY_RUN; then
    echo "This rolls every broker and turns on the RBAC authorizer."
    cf_continue_or_abort
fi

_owner="$(cfo_owner_id)"
WORK="$(_cfo_mktemp)"
trap 'rm -rf "${WORK}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

# _secret_key <secret> <key> > file - one key of a secret, decoded (never on stdout of the script).
_secret_key() {
    oc get secret "$1" -n "${NS}" -o "jsonpath={.data.${2//./\\.}}" 2>/dev/null | base64 --decode 2>/dev/null || true
}

# ------------------------------------------------------------------------------
echo "[1/5] Identity provider (${_store})"
if $SKIP_USER_STORE; then
    echo "[INFO] --skip-user-store: leaving the identity provider untouched."
else
    _us_args=()
    $ROTATE && _us_args+=(--rotate)
    $DRY_RUN && _us_args+=(--dry-run)
    _rc=0
    CONFLUENT_MDS_USER_STORE="${_store}" zsh "${USER_STORE}" "${_us_args[@]}" || _rc=$?
    (( _rc == 0 )) || { echo "[ERROR] x.4_confluent_user_store.sh exited ${_rc}." >&2; exit "${_rc}"; }
fi

# ------------------------------------------------------------------------------
echo "[2/5] MDS secrets for CFK"
_labels=("${CFO_LABEL_PART_OF}" "${CFO_LABEL_OWNER_KEY}=${_owner}")
if [[ -z "$(oc get secret "${CFO_MDS_TOKEN_SECRET}" -n "${NS}" -o name 2>/dev/null || true)" ]] || $ROTATE; then
    if $DRY_RUN; then
        echo "  [DRY-RUN] secret/${CFO_MDS_TOKEN_SECRET} keys: mdsTokenKeyPair.pem,mdsPublicKey.pem (new RSA keypair)"
    else
        ( umask 077
          openssl genrsa -out "${WORK}/mdsTokenKeyPair.pem" 2048 2>/dev/null \
            && openssl rsa -in "${WORK}/mdsTokenKeyPair.pem" -outform PEM -pubout -out "${WORK}/mdsPublicKey.pem" 2>/dev/null ) \
            || { echo "[ERROR] Generating the MDS token keypair failed." >&2; exit 1; }
        cfo_secret_apply "${NS}" "${CFO_MDS_TOKEN_SECRET}" "${_labels[@]}" -- \
            "mdsTokenKeyPair.pem=${WORK}/mdsTokenKeyPair.pem" "mdsPublicKey.pem=${WORK}/mdsPublicKey.pem" \
            || { echo "[ERROR] Storing ${CFO_MDS_TOKEN_SECRET} failed." >&2; exit 1; }
        rm -f "${WORK}/mdsTokenKeyPair.pem" "${WORK}/mdsPublicKey.pem"
        echo "[INFO] MDS token keypair stored in ${CFO_MDS_TOKEN_SECRET}."
    fi
else
    echo "[INFO] Reusing the MDS token keypair in ${CFO_MDS_TOKEN_SECRET} (--rotate to replace it)."
fi
if $DRY_RUN; then
    [[ "${_store}" == LDAP ]] && echo "  [DRY-RUN] secret/${CFO_MDS_LDAP_SECRET} keys: ldap.txt (bind ${CONFLUENT_LDAP_ADMIN_USER} from ${CONFLUENT_LDAP_SECRET})"
    echo "  [DRY-RUN] secret/${CFO_MDS_CLIENT_SECRET} keys: bearer.txt (${CONFLUENT_MDS_SUPER_USER})"
else
    _base_dn="dc=${CONFLUENT_LDAP_DOMAIN//./,dc=}"
    _rc=0
    (
        umask 077
        if [[ "${_store}" == LDAP ]]; then
            _pw="$(_secret_key "${CONFLUENT_LDAP_SECRET}" "${CONFLUENT_LDAP_ADMIN_USER}")"
            [[ -n "${_pw}" ]] || { echo "[ERROR] ${CONFLUENT_LDAP_SECRET} has no ${CONFLUENT_LDAP_ADMIN_USER} password (run x.4_confluent_user_store.sh)." >&2; exit 1; }
            printf 'username=cn=%s,%s\npassword=%s\n' "${CONFLUENT_LDAP_ADMIN_USER}" "${_base_dn}" "${_pw}" > "${WORK}/ldap.txt"
            _su="$(_secret_key "${CONFLUENT_LDAP_SECRET}" "${CONFLUENT_MDS_SUPER_USER}")"
        else
            _su="$(_secret_key "${CONFLUENT_KEYCLOAK_SECRET}" "${CONFLUENT_MDS_SUPER_USER}")"
        fi
        [[ -n "${_su}" ]] || { echo "[ERROR] No password for ${CONFLUENT_MDS_SUPER_USER} in the user store secret." >&2; exit 1; }
        printf 'username=%s\npassword=%s\n' "${CONFLUENT_MDS_SUPER_USER}" "${_su}" > "${WORK}/bearer.txt"
    ) || _rc=$?
    (( _rc == 0 )) || exit 1
    if [[ "${_store}" == LDAP ]]; then
        cfo_secret_apply "${NS}" "${CFO_MDS_LDAP_SECRET}" "${_labels[@]}" -- "ldap.txt=${WORK}/ldap.txt" \
            || { echo "[ERROR] Storing ${CFO_MDS_LDAP_SECRET} failed." >&2; exit 1; }
    fi
    cfo_secret_apply "${NS}" "${CFO_MDS_CLIENT_SECRET}" "${_labels[@]}" -- "bearer.txt=${WORK}/bearer.txt" \
        || { echo "[ERROR] Storing ${CFO_MDS_CLIENT_SECRET} failed." >&2; exit 1; }
    rm -f "${WORK}/ldap.txt" "${WORK}/bearer.txt"
    if [[ "${_store}" == LDAP ]]; then
        echo "[INFO] CFK MDS secrets ${CFO_MDS_LDAP_SECRET} and ${CFO_MDS_CLIENT_SECRET} written."
    else
        echo "[INFO] CFK MDS secret ${CFO_MDS_CLIENT_SECRET} written."
    fi
fi

# ------------------------------------------------------------------------------
echo "[3/5] OAUTH endpoints"
if [[ "${_store}" == OAUTH ]]; then
    if [[ -z "${CONFLUENT_MDS_OAUTH_JWKS_URL}" || -z "${CONFLUENT_MDS_OAUTH_ISSUER}" ]]; then
        # Same derivation as the scripts-mode 1.1: the bundled Keycloak's route.
        _kc_host="$(oc get route keycloak -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
        if [[ -z "${_kc_host}" ]]; then
            if $DRY_RUN; then
                _kc_host="keycloak-${NS}.$(cfo_route_domain)"
                echo "  [DRY-RUN] no keycloak route yet; assuming ${_kc_host}"
            else
                echo "[ERROR] MDS user store is OAUTH but neither CONFLUENT_MDS_OAUTH_JWKS_URL nor a" >&2
                echo "[ERROR] Keycloak route exists. Run x.4_confluent_user_store.sh first." >&2
                exit 1
            fi
        fi
        _kc_base="https://${_kc_host}/realms/${CONFLUENT_KEYCLOAK_REALM}"
        [[ -n "${CONFLUENT_MDS_OAUTH_JWKS_URL}" ]] || CONFLUENT_MDS_OAUTH_JWKS_URL="${_kc_base}/protocol/openid-connect/certs"
        [[ -n "${CONFLUENT_MDS_OAUTH_ISSUER}" ]] || CONFLUENT_MDS_OAUTH_ISSUER="${_kc_base}"
    fi
    export CONFLUENT_MDS_OAUTH_JWKS_URL CONFLUENT_MDS_OAUTH_ISSUER
    echo "[INFO] JWKS   : ${CONFLUENT_MDS_OAUTH_JWKS_URL}"
    echo "[INFO] issuer : ${CONFLUENT_MDS_OAUTH_ISSUER}"
else
    echo "[INFO] LDAP user store - no OAUTH endpoints."
fi

# ------------------------------------------------------------------------------
echo "[4/5] Enable MDS (1.1_confluent_install.sh)"
export CONFLUENT_MDS_ENABLED="true"
export CFO_MDS_HANDOFF=1
_rc=0
if $DRY_RUN; then
    zsh "${INSTALL}" --dry-run || _rc=$?
    (( _rc == 0 )) || { echo "[ERROR] ${INSTALL:t} --dry-run exited ${_rc}." >&2; exit "${_rc}"; }
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi
zsh "${INSTALL}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] ${INSTALL:t} exited ${_rc}; MDS is not confirmed." >&2; exit "${_rc}"; }

# 1.1 applies the platform set, KafkaRestClass (stage 2) and ConfluentRolebinding (stage 5) included. Render and
# apply them here too, so a 1.1 that skipped the MDS stages (handoff guard) still leaves them in place.
_cfo_render_root
_rc=0
cfo_render platform "${REPLY}/cfk" '{"super_user": "'"${CONFLUENT_MDS_SUPER_USER}"'"}' || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] Rendering the MDS objects failed." >&2; exit 1; }
for _stage in 2 5; do
    cfo_apply_manifest "${CFO_MANIFEST}" "${_stage}" || { echo "[ERROR] Applying stage ${_stage} (MDS objects) failed." >&2; exit 1; }
done

# ------------------------------------------------------------------------------
echo "[5/5] Role binding"
_cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600
_rc=0
cfo_wait_status_field "${NS}" "ConfluentRolebinding/mds-super-systemadmin" '{.status.state}' CREATED "${REPLY}" || _rc=$?
if (( _rc != 0 )); then
    echo "[WARN] The ConfluentRolebinding is not CREATED yet (phase 5, V21): check" >&2
    echo "[WARN]   oc get confluentrolebindings.platform.confluent.io -n ${NS} -o yaml" >&2
fi

if [[ -f "${DETAILS_SCRIPT}" ]]; then
    echo "[INFO] Refreshing configs/confluent_platform_config/confluent_instance_details.sh..."
    zsh "${DETAILS_SCRIPT}" >/dev/null 2>&1 || echo "[WARN] Could not refresh the details file."
fi

echo ""
echo "  Connect the CLI from any machine:"
echo "    source scripts/install_confluent_platform/confluent_cli_login.sh"
echo "  Remove MDS again:  x.4_confluent_remove_mds.sh"
cf_closing_status "${RUN_STATUS}" "${STATUS}"
