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
# Confluent Platform - remove the Metadata Service (MDS) / RBAC
# ------------------------------------------------------------------------------
# Turns MDS and the RBAC authorizer back off and restarts the brokers without
# them. "confluent login" stops working; SASL authentication is NOT affected, so
# Kafka clients carry on with their SCRAM credentials.
#
# By default the identity provider (OpenLDAP / Keycloak) and the MDS secrets are
# LEFT IN PLACE, so re-enabling MDS later reuses the same accounts and token
# keypair. --purge removes them too.
#
# DISRUPTIVE: every broker restarts. Topic data is preserved.
#
# Usage:
#   ./x.4_confluent_remove_mds.sh [--purge] [--yes] [--dry-run] [--no-status]
#
#   --purge      also delete the identity provider and the MDS/LDAP/Keycloak
#                secrets (accounts and role bindings are lost)
#   --yes        skip the confirmation prompt
#   --dry-run    report what would change, change nothing
#   --no-status  skip the closing status report
# ==============================================================================

PURGE=false
ASSUME_YES=true
DRY_RUN=false
RUN_STATUS=true

while (( $# > 0 )); do
    case "$1" in
        --purge)     PURGE=true; shift ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --no-status) RUN_STATUS=false; shift ;;
        -h|--help)   sed -n '16,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

INSTALL="${SCRIPT_DIR}/1.1_confluent_install.sh"
STATUS="${SCRIPT_DIR}/1.2_confluent_status.sh"
USER_STORE="${SCRIPT_DIR}/x.4_confluent_user_store.sh"
[[ -f "${INSTALL}" ]] || { echo "[ERROR] Not found: ${INSTALL}" >&2; exit 1; }

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_MDS_SECRET:=confluent-mds}"
: "${CONFLUENT_LDAP_SECRET:=confluent-ldap}"
: "${CONFLUENT_KEYCLOAK_SECRET:=confluent-keycloak}"

oc get namespace "${NS}" &>/dev/null || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }

_current="$(oc get sts broker -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAFKA_CONFLUENT_METADATA_SERVER_LISTENERS")].value}' 2>/dev/null || true)"
[[ -n "${_current}" ]] && _state="enabled (${_current})" || _state="not enabled"

echo "=============================================================================="
echo " Removing MDS / RBAC - project '${NS}'"
echo "=============================================================================="
echo "  current : ${_state}"
echo "  target  : MDS off, RBAC authorizer off"
if $PURGE; then
    echo "  purge   : YES - identity provider and secrets will be deleted"
else
    echo "  purge   : no - identity provider and secrets are kept for re-enabling"
fi
echo "  restarts: all ${CONFLUENT_BROKER_REPLICAS:-?} brokers (topic data is kept)"
echo ""

if [[ -z "${_current}" ]] && ! $PURGE; then
    echo "[INFO] MDS is not enabled; nothing to do."
    exit 0
fi

if $DRY_RUN; then
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi

if ! $ASSUME_YES; then
    echo "This removes RBAC. 'confluent login' will stop working."
    $PURGE && echo "--purge ALSO DELETES all MDS accounts and role bindings permanently."
    printf "Continue? [y/N] "
    read -r _reply
    case "${_reply}" in y|Y|yes|YES) ;; *) echo "[INFO] Aborted."; exit 0 ;; esac
    echo ""
fi

# ------------------------------------------------------------------------------
# Step 1 - reconfigure and restart without MDS
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo " Step 1/3: disable MDS on the brokers"
echo "------------------------------------------------------------------------------"

export CONFLUENT_MDS_ENABLED="false"
"${INSTALL}"

# ------------------------------------------------------------------------------
# Step 2 - the MDS route
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 2/3: remove the MDS route"
echo "------------------------------------------------------------------------------"
oc delete route mds -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
echo "[INFO] Route 'mds' removed (if it existed)."

# ------------------------------------------------------------------------------
# Step 3 - optional purge
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 3/3: identity provider"
echo "------------------------------------------------------------------------------"

if $PURGE; then
    [[ -x "${USER_STORE}" ]] && "${USER_STORE}" --delete --yes || true
    for _s in "${CONFLUENT_MDS_SECRET}" "${CONFLUENT_LDAP_SECRET}" "${CONFLUENT_KEYCLOAK_SECRET}"; do
        oc delete secret "${_s}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
        echo "[INFO] Deleted secret '${_s}' (if it existed)."
    done

    # Older runs of x.4_confluent_add_mds.sh wrote a separate credentials file.
    # It is no longer generated (confluent_instance_details.sh carries these
    # now), so remove any leftover rather than leave stale credentials behind.
    REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
    rm -f "${REPO_ROOT}/cp4d_config/confluent_cli_login.sh"
else
    echo "[INFO] Identity provider and secrets kept."
    echo "[INFO] Re-enable with: x.4_confluent_add_mds.sh"
    echo "[INFO] Delete them with: $(basename $0) --purge"
fi

# Refresh the details file so CONFLUENT_MDS_URL/USER/PASS go back to empty.
DETAILS_SCRIPT="${SCRIPT_DIR}/1.3_confluent_get_instance_details.sh"
if [[ -x "${DETAILS_SCRIPT}" ]]; then
    echo ""
    echo "[INFO] Refreshing cp4d_config/confluent_instance_details.sh..."
    "${DETAILS_SCRIPT}" >/dev/null 2>&1 || echo "[WARN] Could not refresh the details file."
fi

echo ""
echo "[INFO] MDS removed. Kafka SASL authentication is unchanged."

if [[ "${RUN_STATUS}" == "true" && -f "${STATUS}" ]]; then
    echo ""
    "${STATUS}" || echo "[WARN] Status reported one or more components not ready (see above)."
fi
