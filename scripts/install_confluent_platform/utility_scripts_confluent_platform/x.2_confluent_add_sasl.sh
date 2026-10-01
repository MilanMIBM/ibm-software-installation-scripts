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
# Turns on SASL/SCRAM-SHA-512 on the broker listeners and mints per-client
# credentials. This is a DIFFERENT axis from the web UI auth in the other x.2
# scripts: those protect Control Center, this protects the Kafka protocol, which
# is otherwise open to anyone who can reach port 29092.
#
# SCRAM rather than PLAIN: SCRAM stores credentials in Kafka's own metadata, so
# clients can be added and revoked with kafka-configs at runtime. SASL/PLAIN
# keeps them in a static JAAS file that requires a rolling broker restart for
# every change.
#
# Listener layout after this runs:
#   CONTROLLER  (29093) PLAINTEXT      - KRaft quorum, never leaves the pod network
#   PLAINTEXT   (29092) SASL_PLAINTEXT - platform components and in-cluster apps
#   PLAINTEXT_HOST (9092) SASL_PLAINTEXT - same, via the broker Service
#
# TLS is deliberately NOT enabled here: it needs a cert lifecycle (cert-manager
# or a CA) that this stack has no opinion about. SASL_PLAINTEXT authenticates
# clients but does not encrypt, so credentials cross the pod network in the
# SCRAM handshake (which is challenge-response, so the password itself is never
# sent in the clear). Adequate inside a cluster; add TLS before exposing Kafka
# outside one.
#
# DISRUPTIVE: every broker restarts, and every component is reconfigured. Topic
# data is preserved.
#
# Usage:
#   ./x.2_confluent_add_sasl.sh [--clients a,b,c] [--rotate] [--disable]
#                               [--yes] [--dry-run] [--no-status]
#
#   --clients a,b,c  application client names to provision (default: from
#                    CONFLUENT_SASL_CLIENTS)
#   --rotate         regenerate all SASL passwords
#   --disable        revert the listeners to PLAINTEXT and drop the credentials
#   --yes            skip the confirmation prompt
#   --dry-run        report what would change, change nothing
#   --no-status      skip the closing status report
# ==============================================================================

ROTATE=false
DISABLE=false
ASSUME_YES=true
DRY_RUN=false
RUN_STATUS=true
CLIENTS_OVERRIDE=""

_need_value() { [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }; }

while (( $# > 0 )); do
    case "$1" in
        --clients)   _need_value "$1" "${2:-}"; CLIENTS_OVERRIDE="$2"; shift 2 ;;
        --rotate)    ROTATE=true; shift ;;
        --disable)   DISABLE=true; shift ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --no-status) RUN_STATUS=false; shift ;;
        -h|--help)   sed -n '16,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

if $DISABLE && { $ROTATE || [[ -n "${CLIENTS_OVERRIDE}" ]]; }; then
    echo "[ERROR] --disable cannot be combined with --rotate or --clients." >&2
    exit 1
fi

INSTALL="${SCRIPT_DIR}/1.1_confluent_install.sh"
STATUS="${SCRIPT_DIR}/1.2_confluent_status.sh"
[[ -f "${INSTALL}" ]] || { echo "[ERROR] Not found: ${INSTALL}" >&2; exit 1; }

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_SASL_MECHANISM:=SCRAM-SHA-512}"
: "${CONFLUENT_SASL_ADMIN_USER:=confluent-admin}"
: "${CONFLUENT_SASL_SECRET:=confluent-sasl}"
: "${CONFLUENT_SASL_CLIENTS:=app-client}"
: "${CONFLUENT_BROKER_INTERNAL_PORT:=29092}"
[[ -n "${CLIENTS_OVERRIDE}" ]] && CONFLUENT_SASL_CLIENTS="${CLIENTS_OVERRIDE}"

oc get namespace "${NS}" &>/dev/null || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }

_current="$(oc get sts broker -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAFKA_LISTENER_SECURITY_PROTOCOL_MAP")].value}' 2>/dev/null || true)"
case "${_current}" in
    *SASL*) _state="SASL enabled (${CONFLUENT_SASL_MECHANISM})" ;;
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
    echo "  target  : SASL_PLAINTEXT / ${CONFLUENT_SASL_MECHANISM}"
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

gen_pw() { LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9._~-' | cut -c1-24; }

if $DISABLE; then
    export CONFLUENT_SASL_ENABLED="false"
    echo "[INFO] SASL will be disabled; credentials in secret '${CONFLUENT_SASL_SECRET}' are left in place"
    echo "[INFO] so they can be reused if you re-enable it. Delete the secret to discard them."
else
    export CONFLUENT_SASL_ENABLED="true"

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
    # cluster will not form. Written over the still-PLAINTEXT listener.
    echo "[INFO] Registering SCRAM credentials in Kafka..."
    for _u in "${(@k)_pw}"; do
        if oc exec broker-0 -n "${NS}" -- kafka-configs \
              --bootstrap-server "localhost:${CONFLUENT_BROKER_INTERNAL_PORT}" \
              --alter --add-config "${CONFLUENT_SASL_MECHANISM}=[password=${_pw[$_u]}]" \
              --entity-type users --entity-name "${_u}" >/dev/null 2>&1; then
            echo "[INFO]   registered ${_u}"
        else
            echo "[ERROR] Failed to register SCRAM credential for '${_u}'." >&2
            echo "[ERROR] Brokers are still PLAINTEXT and unchanged; nothing was broken." >&2
            exit 1
        fi
    done
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
    REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
    OUT="${REPO_ROOT}/cp4d_config/confluent_sasl_clients.properties"
    _admin_pw="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" -o jsonpath="{.data.${CONFLUENT_SASL_ADMIN_USER}}" | base64 --decode)"

    {
        echo "# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "# Kafka client properties for the SASL-enabled cluster in '${NS}'."
        echo "# One block per client - copy the one you need into your client config."
        echo ""
        for _u in ${=_client_list}; do
            _p="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" -o jsonpath="{.data.${_u}}" 2>/dev/null | base64 --decode || true)"
            [[ -z "${_p}" ]] && continue
            echo "# ---- ${_u} ----"
            echo "# bootstrap.servers=broker-headless.${NS}.svc.cluster.local:${CONFLUENT_BROKER_INTERNAL_PORT}"
            echo "# security.protocol=SASL_PLAINTEXT"
            echo "# sasl.mechanism=${CONFLUENT_SASL_MECHANISM}"
            echo "# sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${_u}\" password=\"${_p}\";"
            echo ""
        done
    } > "${OUT}"
    chmod 600 "${OUT}"

    echo "[INFO] Client properties written to ${OUT##*/} (mode 600)."
    echo ""
    echo "  bootstrap.servers=broker-headless.${NS}.svc.cluster.local:${CONFLUENT_BROKER_INTERNAL_PORT}"
    echo "  security.protocol=SASL_PLAINTEXT"
    echo "  sasl.mechanism=${CONFLUENT_SASL_MECHANISM}"
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
