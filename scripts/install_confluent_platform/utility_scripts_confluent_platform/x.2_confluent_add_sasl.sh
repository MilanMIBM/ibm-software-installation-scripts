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
# Confluent Platform - SASL authentication for Kafka clients
# ------------------------------------------------------------------------------
# Turns on SASL on the broker listeners and mints per-client credentials. This
# is a DIFFERENT axis from the web UI auth in the other x.2 scripts: those
# protect Control Center, this protects the Kafka protocol, which is otherwise
# open to anyone who can reach port 29092.
#
# What is configured comes from confluent_vars.sh (or the flags below):
#   CONFLUENT_SASL_PROTOCOL    SASL_PLAINTEXT (default) | SASL_SSL
#   CONFLUENT_SASL_MECHANISM   SCRAM-SHA-512 (default) | SCRAM-SHA-256 | PLAIN
#   CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS   EXTERNAL listener, default PLAIN
#
# SCRAM stores credentials in Kafka's own metadata, so clients are added and
# revoked with kafka-configs while the brokers run, and the password never
# crosses the wire. PLAIN validates against a static user list built from the
# credentials secret when each broker starts, so adding a client rolls the
# brokers, and the password is sent as-is - use it with SASL_SSL.
#
# Listener layout after this runs:
#   CONTROLLER  (29093) PLAINTEXT  - KRaft quorum, never leaves the pod network
#   PLAINTEXT   (29092) <protocol> - platform components and in-cluster apps
#   PLAINTEXT_HOST (9092) <protocol> - same, via the broker Service
#
# SASL_PLAINTEXT authenticates but does not encrypt; SCRAM's challenge-response
# keeps the password itself off the wire, PLAIN does not. SASL_SSL adds TLS from
# a private CA generated into CONFLUENT_INTERNAL_TLS_SECRET; clients trust it
# via configs/confluent_platform_config/confluent_kafka_internal_ca.crt.
#
# DISRUPTIVE: every broker restarts, and every component is reconfigured. Topic
# data is preserved.
#
# Usage:
#   ./x.2_confluent_add_sasl.sh [--clients a,b,c] [--rotate] [--disable]
#                               [--protocol P] [--mechanism M]
#                               [--external-mechanisms M[,M]] [--rotate-tls]
#                               [--yes] [--dry-run] [--no-status]
#
#   --clients a,b,c          application client names to provision (default:
#                            from CONFLUENT_SASL_CLIENTS)
#   --rotate                 regenerate all SASL passwords
#   --disable                revert the listeners to PLAINTEXT, keep the credentials
#   --protocol P             in-cluster protocol: SASL_PLAINTEXT or SASL_SSL
#   --mechanism M            in-cluster mechanism: SCRAM-SHA-512, SCRAM-SHA-256, PLAIN
#   --external-mechanisms L  EXTERNAL listener mechanisms, comma-separated
#   --rotate-tls             regenerate the in-cluster CA and broker certificate
#   --yes                    skip the confirmation prompt
#   --dry-run                report what would change, change nothing
#   --no-status              skip the closing status report
#
# --protocol/--mechanism/--external-mechanisms are written back to
# confluent_vars.sh. They have to be: 1.1_confluent_install.sh re-reads that
# file, and a later run that reverted the mechanism would lock every client out.
# ==============================================================================

ROTATE=false
DISABLE=false
ASSUME_YES=true
DRY_RUN=false
RUN_STATUS=true
CLIENTS_OVERRIDE=""
ROTATE_TLS=false
# Security settings given as flags; persisted to confluent_vars.sh below.
typeset -A _SET

_need_value() { [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }; }

while (( $# > 0 )); do
    case "$1" in
        --clients)   _need_value "$1" "${2:-}"; CLIENTS_OVERRIDE="$2"; shift 2 ;;
        --rotate)    ROTATE=true; shift ;;
        --disable)   DISABLE=true; shift ;;
        --protocol)  _need_value "$1" "${2:-}"; _SET[CONFLUENT_SASL_PROTOCOL]="$2"; shift 2 ;;
        --mechanism) _need_value "$1" "${2:-}"; _SET[CONFLUENT_SASL_MECHANISM]="$2"; shift 2 ;;
        --external-mechanisms)
                     _need_value "$1" "${2:-}"; _SET[CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS]="$2"; shift 2 ;;
        --rotate-tls) ROTATE_TLS=true; shift ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --no-status) RUN_STATUS=false; shift ;;
        -h|--help)   sed -n '16,66p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

if $DISABLE && { $ROTATE || [[ -n "${CLIENTS_OVERRIDE}" ]]; }; then
    echo "[ERROR] --disable cannot be combined with --rotate or --clients." >&2
    exit 1
fi

INSTALL="${SCRIPT_DIR}/../1.1_confluent_install.sh"
STATUS="${SCRIPT_DIR}/../1.2_confluent_status.sh"
[[ -f "${INSTALL}" ]] || { echo "[ERROR] Not found: ${INSTALL}" >&2; exit 1; }

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_SASL_ADMIN_USER:=confluent-admin}"
: "${CONFLUENT_SASL_SECRET:=confluent-sasl}"
: "${CONFLUENT_SASL_CLIENTS:=app-client}"
: "${CONFLUENT_BROKER_INTERNAL_PORT:=29092}"
[[ -n "${CLIENTS_OVERRIDE}" ]] && CONFLUENT_SASL_CLIENTS="${CLIENTS_OVERRIDE}"
for _k in "${(@k)_SET}"; do typeset -gx "${_k}=${_SET[$_k]}"; done
source "${SCRIPT_DIR}/../confluent_kafka_security.sh"
if ! $DISABLE; then
    kafka_security_validate || exit 1
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/configs/confluent_platform_config/confluent_vars.sh"

# persist_var <name> <value> - rewrite (or append) one export in confluent_vars.sh.
persist_var() {
    local name="$1" value="$2"
    [[ -f "${VARS_FILE}" ]] || return 0
    if grep -qE "^export ${name}=" "${VARS_FILE}"; then
        # Values are validated above to [A-Z0-9_,-], so they are sed-safe.
        sed -i.bak -E "s|^export ${name}=.*|export ${name}=\"${value}\"|" "${VARS_FILE}"
        rm -f "${VARS_FILE}.bak"
    else
        printf '\nexport %s="%s"\n' "${name}" "${value}" >> "${VARS_FILE}"
    fi
    echo "[INFO] ${name}=${value} saved to ${VARS_FILE##*/}."
}

oc get namespace "${NS}" &>/dev/null || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }

_current="$(oc get sts broker -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAFKA_LISTENER_SECURITY_PROTOCOL_MAP")].value}' 2>/dev/null || true)"
case "${_current}" in
    *SASL*) read -r _live_proto _live_mech <<< "$(kafka_pod_internal_security "${NS}" broker-0)"
            _state="SASL enabled (${_live_proto} / ${_live_mech})" ;;
    *)      _state="PLAINTEXT - Kafka is open to anyone who can reach it" ;;
esac

_client_list="${CONFLUENT_SASL_CLIENTS//,/ }"

echo "=============================================================================="
echo " Kafka client authentication (SASL) - project '${NS}'"
echo "=============================================================================="
echo "  current : ${_state}"
if $DISABLE; then
    echo "  target  : PLAINTEXT (authentication removed)"
else
    echo "  target  : ${CONFLUENT_SASL_PROTOCOL} / ${CONFLUENT_SASL_MECHANISM} in-cluster"
    echo "            SASL_SSL / ${CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS} on the EXTERNAL listener (when enabled)"
    echo "  admin   : ${CONFLUENT_SASL_ADMIN_USER} (used by the platform components)"
    echo "  clients : ${_client_list}"
fi
echo "  restarts: all ${CONFLUENT_BROKER_REPLICAS:-?} brokers and every component (topic data is kept)"
echo ""

if $DRY_RUN; then
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi


if ! $ASSUME_YES; then
    if $DISABLE; then
        echo "This REMOVES Kafka authentication: any client that can reach the brokers may connect."
    else
        echo "This restarts every broker and component. Clients using the old settings will fail until reconfigured."
    fi
    printf "Continue? [y/N] "
    read -r _reply
    case "${_reply}" in y|Y|yes|YES) ;; *) echo "[INFO] Aborted."; exit 0 ;; esac
    echo ""
fi

# ------------------------------------------------------------------------------
# Step 1 - credentials
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo " Step 1/3: credentials"
echo "------------------------------------------------------------------------------"

for _k in "${(@ok)_SET}"; do persist_var "${_k}" "${(P)_k}"; done

gen_pw() { LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9._~-' | cut -c1-24; }

if $DISABLE; then
    export CONFLUENT_SASL_ENABLED="false"
    echo "[INFO] SASL will be disabled; credentials in secret '${CONFLUENT_SASL_SECRET}' are left in place"
    echo "[INFO] so they can be reused if you re-enable it. Delete the secret to discard them."
else
    export CONFLUENT_SASL_ENABLED="true"

    # The admin password the RUNNING cluster knows, captured before a rotation
    # overwrites the secret: registering the new SCRAM credentials has to
    # authenticate with the old one.
    _auth_pw="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" \
        -o jsonpath="{.data.${CONFLUENT_SASL_ADMIN_USER}}" 2>/dev/null | base64 --decode 2>/dev/null || true)"

    # Reuse stored passwords unless rotating, so existing clients keep working.
    typeset -A _pw
    for _u in "${CONFLUENT_SASL_ADMIN_USER}" ${=_client_list}; do
        _existing="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" \
            -o jsonpath="{.data.${_u}}" 2>/dev/null | base64 --decode 2>/dev/null || true)"
        if [[ -n "${_existing}" ]] && ! $ROTATE; then
            _pw[$_u]="${_existing}"
        else
            _pw[$_u]="$(gen_pw)"
        fi
    done

    _args=()
    for _u in "${(@k)_pw}"; do _args+=(--from-literal="${_u}=${_pw[$_u]}"); done
    oc create secret generic "${CONFLUENT_SASL_SECRET}" "${_args[@]}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null
    echo "[INFO] Credentials stored in secret '${CONFLUENT_SASL_SECRET}'."

    # SCRAM credentials live in Kafka metadata. They must exist BEFORE the
    # brokers restart into SASL, or the components cannot authenticate and the
    # cluster will not form. Written over whatever the brokers currently speak
    # (PLAINTEXT on a first enable, the live SASL listener when adding clients).
    # Nothing to do when no listener uses SCRAM: PLAIN reads the secret itself.
    if [[ -n "$(kafka_scram_mechanisms_in_use)" ]]; then
        echo "[INFO] Registering SCRAM credentials in Kafka..."
        _pairs=()
        for _u in "${(@k)_pw}"; do _pairs+=("${_u}=${_pw[$_u]}"); done
        if ! kafka_register_scram_users "${NS}" "${_auth_pw:-${_pw[${CONFLUENT_SASL_ADMIN_USER}]}}" "${_pairs[@]}"; then
            echo "[ERROR] The brokers are unchanged; nothing was broken." >&2
            exit 1
        fi
    fi

    if [[ "${CONFLUENT_SASL_PROTOCOL}" == "SASL_SSL" ]]; then
        kafka_ensure_internal_tls "${NS}" "${ROTATE_TLS}" || exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Step 2 - reconfigure and restart the platform
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 2/3: reconfigure brokers and components"
echo "------------------------------------------------------------------------------"

"${INSTALL}"

# ------------------------------------------------------------------------------
# Step 3 - client connection details
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 3/3: client configuration"
echo "------------------------------------------------------------------------------"

if $DISABLE; then
    echo "[WARN] Kafka now accepts unauthenticated connections."
else
    OUT="${REPO_ROOT}/configs/confluent_platform_config/confluent_sasl_clients.properties"
    mkdir -p "$(dirname "${OUT}")"
    _admin_pw="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" -o jsonpath="{.data.${CONFLUENT_SASL_ADMIN_USER}}" | base64 --decode)"

    _truststore=""
    if [[ "${CONFLUENT_SASL_PROTOCOL}" == "SASL_SSL" ]]; then
        _ca_out="${REPO_ROOT}/configs/confluent_platform_config/confluent_kafka_internal_ca.crt"
        oc get secret "${CONFLUENT_INTERNAL_TLS_SECRET}" -n "${NS}" \
            -o jsonpath='{.data.ca\.crt}' | base64 --decode > "${_ca_out}"
        _truststore="${_ca_out}"
    fi

    {
        echo "# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "# Kafka client properties for the SASL-enabled cluster in '${NS}'."
        echo "# One block per client - copy the one you need into your client config."
        echo "# In-cluster listener: ${CONFLUENT_SASL_PROTOCOL} / ${CONFLUENT_SASL_MECHANISM}."
        echo ""
        for _u in ${=_client_list}; do
            _p="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" -o jsonpath="{.data.${_u}}" 2>/dev/null | base64 --decode || true)"
            [[ -z "${_p}" ]] && continue
            echo "# ---- ${_u} ----"
            echo "# bootstrap.servers=broker-headless.${NS}.svc.cluster.local:${CONFLUENT_BROKER_INTERNAL_PORT}"
            kafka_client_properties "${CONFLUENT_SASL_PROTOCOL}" "${CONFLUENT_SASL_MECHANISM}" \
                "${_u}" "${_p}" "${_truststore:+/path/to/confluent_kafka_internal_ca.crt}" | sed 's/^/# /'
            echo ""
        done
    } > "${OUT}"
    chmod 600 "${OUT}"

    echo "[INFO] Client properties written to ${OUT##*/} (mode 600)."
    echo ""
    echo "  bootstrap.servers=broker-headless.${NS}.svc.cluster.local:${CONFLUENT_BROKER_INTERNAL_PORT}"
    echo "  security.protocol=${CONFLUENT_SASL_PROTOCOL}"
    echo "  sasl.mechanism=${CONFLUENT_SASL_MECHANISM}"
    [[ -n "${_truststore}" ]] && echo "  ssl.truststore.type=PEM  (CA: ${_truststore#${REPO_ROOT}/})"
    echo ""
    echo "  Read a client's password with:"
    echo "    oc get secret ${CONFLUENT_SASL_SECRET} -n ${NS} -o jsonpath='{.data.<client>}' | base64 --decode"
    echo ""
    echo "  Add a client later:  $(basename $0) --clients existing,new"
fi

if [[ "${RUN_STATUS}" == "true" && -f "${STATUS}" ]]; then
    echo ""
    "${STATUS}" || echo "[WARN] Status reported one or more components not ready (see above)."
fi
