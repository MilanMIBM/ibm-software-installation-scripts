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
# Confluent Platform (operator mode) - external Kafka access
# ------------------------------------------------------------------------------
# Makes the Kafka protocol reachable from outside the cluster. In operator mode
# CFK does the routing: the Kafka CR's external listener gets
# externalAccess.type=route, and CFK creates one passthrough Route for the
# bootstrap and one per broker:
#
#   <CONFLUENT_EXTERNAL_KAFKA_BOOTSTRAP_PREFIX>.<domain>:443   (bootstrap)
#   <CONFLUENT_EXTERNAL_KAFKA_BROKER_PREFIX><N>.<domain>:443   (broker N)
#
# The external listener is SASL_SSL. Its certificate (secret
# CONFLUENT_EXTERNAL_TLS_SECRET, keys ca.crt fullchain.pem privkey.pem
# cacerts.pem) carries those host names as SANs; this script generates a private
# CA for it, or stores your own with --cert-path/--key-path.
#
# Requires CONFLUENT_SASL_ENABLED=true.
#
# DISRUPTIVE: CFK rolls every broker. Topic data is preserved.
#
# Usage:
#   ./x.4_confluent_add_external_access.sh [--disable] [--rotate] [--yes]
#        [--dry-run] [--no-status] [--cert-path P --key-path P]
#        [--client-config-only]
#
#   --client-config-only  only rewrite confluent_external_client.properties and
#                the CA file from the live cluster (external access must be on)
#   --disable    remove the external listener (CFK removes its routes)
#   --rotate     regenerate the CA and the listener certificate
#   --cert-path  use an existing PEM certificate (chain) instead of generating one
#   --key-path   its private key (required with --cert-path)
#   --yes        skip the confirmation prompt (default)
#   --dry-run    report what would change, change nothing
#   --no-status  skip the closing status report
#
# Exit status: 0 ok, 1 error, 2 blocked (scripts-mode install in the namespace).
# ==============================================================================

usage() { sed -n '/^# Confluent Platform (operator mode) - external Kafka access/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

DISABLE=false
ROTATE=false
ASSUME_YES=true
DRY_RUN=false
RUN_STATUS=true
CERT_PATH=""
KEY_PATH=""
CLIENT_CONFIG_ONLY=false

while (( $# > 0 )); do
    case "$1" in
        --disable)   DISABLE=true; shift ;;
        --rotate)    ROTATE=true; shift ;;
        --cert-path) h_need_value "$1" "${2:-}"; CERT_PATH="$2"; shift 2 ;;
        --key-path)  h_need_value "$1" "${2:-}"; KEY_PATH="$2"; shift 2 ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --no-status) RUN_STATUS=false; shift ;;
        --client-config-only) CLIENT_CONFIG_ONLY=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

if $CLIENT_CONFIG_ONLY && { $DISABLE || $ROTATE || [[ -n "${CERT_PATH}" ]]; }; then
    echo "[ERROR] --client-config-only cannot be combined with --disable, --rotate or --cert-path." >&2
    exit 1
fi
if [[ -n "${CERT_PATH}" && -z "${KEY_PATH}" ]] || [[ -z "${CERT_PATH}" && -n "${KEY_PATH}" ]]; then
    echo "[ERROR] --cert-path and --key-path must be given together." >&2
    exit 1
fi
export DRY_RUN

cfo_entry platform

INSTALL="${CF_PLATFORM_DIR}/1.1_confluent_install.sh"
STATUS="${CF_PLATFORM_DIR}/1.2_confluent_status.sh"
NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_EXTERNAL_TLS_SECRET:=confluent-kafka-tls}"
: "${CONFLUENT_BROKER_REPLICAS:=3}"
: "${CONFLUENT_SASL_ENABLED:=false}"
: "${CONFLUENT_SASL_SECRET:=confluent-sasl}"
: "${CONFLUENT_SASL_CLIENTS:=app-client}"
: "${CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS:=PLAIN}"

[[ -n "$(oc get namespace "${NS}" -o name 2>/dev/null || true)" ]] || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }

source "${CF_PLATFORM_DIR}/confluent_kafka_security.sh"
_ext_mech="$(kafka_external_primary_mechanism)"

_domain="$(cfo_route_domain)"
[[ -n "${_domain}" ]] || { echo "[ERROR] No route domain (CONFLUENT_ROUTE_DOMAIN, ingresses.config/cluster)." >&2; exit 1; }
_cfo_external_hosts "${_domain}"
typeset -a _hosts=("${(@s:,:)REPLY}")

_live="$(cf_live_security "${NS}")"
if [[ "${_live##* }" != "-" && -n "${_live}" ]]; then
    _state="enabled"
else
    _state="not enabled - Kafka is cluster-internal only"
fi

echo "=============================================================================="
echo " External Kafka access (operator mode) - project '${NS}'"
echo "=============================================================================="
echo "  current : ${_state}"
if $DISABLE; then
    echo "  target  : removed"
else
    echo "  target  : SASL_SSL external listener on CFK passthrough routes"
    echo "  auth    : ${CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS}"
    echo "  brokers : ${CONFLUENT_BROKER_REPLICAS}"
    for _h in "${_hosts[@]}"; do echo "            ${_h}:443"; done
fi
if $CLIENT_CONFIG_ONLY; then
    echo "  restarts: none (--client-config-only: local client files only)"
else
    echo "  restarts: CFK rolls all ${CONFLUENT_BROKER_REPLICAS} brokers (topic data is kept)"
fi
echo ""

if ! $DISABLE && [[ "${CONFLUENT_SASL_ENABLED}" != "true" ]]; then
    echo "[ERROR] External access requires Kafka authentication, but CONFLUENT_SASL_ENABLED" >&2
    echo "[ERROR] is not 'true'. Run this first:" >&2
    echo "[ERROR]   ${CF_PLATFORM_DIR}/utility_scripts_confluent_platform/x.2_confluent_add_sasl.sh" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Client configuration (the writer block of the scripts-mode x.4, bootstrap from
# the CFK bootstrap route; duplication with the original accepted)
# ------------------------------------------------------------------------------
write_client_config() {
    REPO_ROOT="${_CP4D_REPO_ROOT}"
    OUT="${CONFIGS_ROOT:-${REPO_ROOT}/configs}/confluent_platform_config/confluent_external_client.properties"
    CA_OUT="${CONFIGS_ROOT:-${REPO_ROOT}/configs}/confluent_platform_config/confluent_kafka_ca.crt"
    mkdir -p "$(dirname "${OUT}")"

    _bootstrap="$(cf_external_bootstrap "${NS}")"
    [[ -n "${_bootstrap}" ]] || _bootstrap="${_hosts[1]}:443"

    _first_client="${CONFLUENT_SASL_CLIENTS%%,*}"
    _first_pw="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" \
        -o jsonpath="{.data.${_first_client}}" 2>/dev/null | base64 --decode || true)"

    {
        echo "# Written by $(basename "${ZSH_ARGZERO}") on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "# Kafka client properties for EXTERNAL access to the cluster in '${NS}' (operator mode)."
        echo "#"
        echo "#   kafka-topics --bootstrap-server ${_bootstrap} \\"
        echo "#     --command-config configs/confluent_platform_config/confluent_external_client.properties --list"
        echo ""
        echo "bootstrap.servers=${_bootstrap}"
        if [[ -n "${_first_pw}" ]]; then
            kafka_client_properties SASL_SSL "${_ext_mech}" "${_first_client}" "${_first_pw}" "${CA_OUT}"
        else
            kafka_client_properties SASL_SSL "${_ext_mech}" "<user>" "<password>" "${CA_OUT}" \
                | sed 's/^sasl.jaas.config=/# sasl.jaas.config=/'
        fi
        for _m in ${(s:,:)CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS}; do
            [[ "${_m}" == "${_ext_mech}" ]] && continue
            echo ""
            echo "# Also accepted - swap these two lines in to use ${_m}:"
            echo "# sasl.mechanism=${_m}"
            echo "# sasl.jaas.config=$(kafka_client_jaas "${_m}" "${_first_client}" "${_first_pw:-<password>}")"
        done
    } > "${OUT}"
    chmod 600 "${OUT}"

    # The properties file points at this CA, so write it from the live secret too.
    _ca_pem="$(cf_ca_pem "${NS}" external 2>/dev/null || true)"
    if [[ -n "${_ca_pem}" ]]; then
        print -r -- "${_ca_pem}" > "${CA_OUT}"
        chmod 644 "${CA_OUT}"
    else
        echo "[WARN] No ca.crt in secret '${CONFLUENT_EXTERNAL_TLS_SECRET}'; keeping the existing CA file, if any."
    fi

    echo "[INFO] Client properties written to ${OUT##*/} (mode 600)."
    echo "[INFO] CA certificate at ${CA_OUT##*/}."
    echo ""
    echo "  bootstrap.servers=${_bootstrap}"
    echo "  security.protocol=SASL_SSL"
    echo "  sasl.mechanism=${_ext_mech}"
    echo ""
    echo "  Test it from here:"
    echo "    kafka-topics --bootstrap-server ${_bootstrap} \\"
    echo "      --command-config ${OUT#${REPO_ROOT}/} --list"
    echo ""
    echo "  Remove external access:  $(basename "${ZSH_ARGZERO}") --disable"
}

if $CLIENT_CONFIG_ONLY; then
    if [[ "${_state}" != "enabled" ]]; then
        echo "[ERROR] External access is not enabled; run this script without --client-config-only first." >&2
        exit 1
    fi
    if $DRY_RUN; then
        echo "[INFO] --dry-run: would rewrite confluent_external_client.properties and confluent_kafka_ca.crt only."
        exit 0
    fi
    # Describe what the brokers run (the Kafka CR), not what the vars say.
    _live_ext="${_live##* }"
    if [[ -n "${_live_ext}" && "${_live_ext}" != "-" ]]; then
        CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS="${_live_ext}"
        _ext_mech="$(kafka_external_primary_mechanism)"
    fi
    write_client_config
    exit 0
fi

if ! $ASSUME_YES && ! $DRY_RUN; then
    if $DISABLE; then
        echo "External Kafka clients will lose access. In-cluster clients are unaffected."
    else
        echo "This exposes Kafka on the cluster's public ingress, protected by SASL over TLS."
    fi
    cf_continue_or_abort
fi

# ------------------------------------------------------------------------------
# Disable
# ------------------------------------------------------------------------------
if $DISABLE; then
    echo "------------------------------------------------------------------------------"
    echo " Step 1/1: remove the external listener (CFK removes its routes)"
    echo "------------------------------------------------------------------------------"
    if $DRY_RUN; then
        echo "  [DRY-RUN] CONFLUENT_EXTERNAL_KAFKA_ENABLED=false ${INSTALL:t} --dry-run"
        CONFLUENT_EXTERNAL_KAFKA_ENABLED=false zsh "${INSTALL}" --dry-run
        exit 0
    fi
    export CONFLUENT_EXTERNAL_KAFKA_ENABLED="false"
    zsh "${INSTALL}"
    echo ""
    echo "[INFO] External access removed. The TLS secret '${CONFLUENT_EXTERNAL_TLS_SECRET}' is kept"
    echo "[INFO] so re-enabling reuses the same CA. Delete it to discard the certificates."
    cf_closing_status "${RUN_STATUS}" "${STATUS}"
    exit 0
fi

# ------------------------------------------------------------------------------
# Step 1 - certificate
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo " Step 1/3: TLS certificate (SANs for the CFK routes)"
echo "------------------------------------------------------------------------------"
if [[ -n "${CERT_PATH}" ]]; then
    [[ -f "${CERT_PATH}" ]] || { echo "[ERROR] No such file: ${CERT_PATH}" >&2; exit 1; }
    [[ -f "${KEY_PATH}"  ]] || { echo "[ERROR] No such file: ${KEY_PATH}" >&2; exit 1; }
    echo "[INFO] Using the supplied certificate (without a separate CA it is also what clients trust)."
    _rc=0
    _owner="$(cfo_owner_id)"
    cfo_secret_apply "${NS}" "${CONFLUENT_EXTERNAL_TLS_SECRET}" "${CFO_LABEL_PART_OF}" "${CFO_LABEL_OWNER_KEY}=${_owner}" -- \
        "ca.crt=${CERT_PATH}" "fullchain.pem=${CERT_PATH}" "privkey.pem=${KEY_PATH}" "cacerts.pem=${CERT_PATH}" || _rc=$?
    (( _rc == 0 )) || { echo "[ERROR] Storing the supplied certificate failed." >&2; exit 1; }
else
    _rc=0
    if $ROTATE; then
        cfo_tls_ensure_external_cert "${NS}" "${_domain}" --rotate || _rc=$?
    else
        cfo_tls_ensure_external_cert "${NS}" "${_domain}" || _rc=$?
    fi
    (( _rc == 0 )) || { echo "[ERROR] Preparing the external TLS secret failed." >&2; exit 1; }
fi

# ------------------------------------------------------------------------------
# Step 2 - reconfigure (CFK adds the listener and its routes, then rolls)
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 2/3: add the external listener"
echo "------------------------------------------------------------------------------"
if $DRY_RUN; then
    CONFLUENT_EXTERNAL_KAFKA_ENABLED=true zsh "${INSTALL}" --dry-run
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi
export CONFLUENT_EXTERNAL_KAFKA_ENABLED="true"
zsh "${INSTALL}"

# ------------------------------------------------------------------------------
# Step 3 - client configuration
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 3/3: client configuration"
echo "------------------------------------------------------------------------------"
write_client_config

cf_closing_status "${RUN_STATUS}" "${STATUS}"
