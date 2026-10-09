#!/bin/zsh
# ==============================================================================
# confluent_sasl_helpers.sh - Kafka SASL settings shared by the Confluent scripts
# ------------------------------------------------------------------------------
# Sourced, not executed:
#
#     source "${_CP4D_REPO_ROOT}/scripts/install_confluent_platform/confluent_sasl_helpers.sh"
#
# CONFLUENT_SASL_MECHANISM names one mechanism or a comma-separated list of
# PLAIN, SCRAM-SHA-256 and SCRAM-SHA-512. The brokers enable every mechanism
# listed. Everything that connects as a client (inter-broker traffic, the
# platform components, the generated client properties) uses the strongest one,
# because sasl.mechanism.inter.broker.protocol takes exactly one value and it
# must be among sasl.enabled.mechanisms.
#
# The mechanisms keep credentials in different places, and the scripts handle
# both automatically:
#   SCRAM-*  credentials live in Kafka metadata and are registered with
#            kafka-configs, so they can change without a broker restart.
#   PLAIN    credentials live in the broker's listener JAAS as user_<name>
#            entries, rendered from the SASL secret on every install. A
#            credential change therefore rolls the brokers.
# ==============================================================================

: "${CONFLUENT_SASL_MECHANISM:=SCRAM-SHA-512}"
: "${CONFLUENT_SASL_SECURITY_PROTOCOL:=SASL_PLAINTEXT}"

# Validates CONFLUENT_SASL_MECHANISM and sets:
#   CONFLUENT_SASL_MECHANISMS        de-duplicated comma list (sasl.enabled.mechanisms)
#   CONFLUENT_SASL_CLIENT_MECHANISM  strongest of them (inter-broker, components, clients)
#   CONFLUENT_SASL_SCRAM_MECHANISMS  space-separated SCRAM subset (registered via kafka-configs)
# All three are derived on every run and overwrite any value already in the
# environment, so they do not belong in confluent_vars.sh.
confluent_sasl_resolve() {
    local _m
    local -a _list
    for _m in ${(s:,:)CONFLUENT_SASL_MECHANISM}; do
        _m="${${_m//[[:space:]]/}:u}"
        [[ -z "${_m}" ]] && continue
        case "${_m}" in
            PLAIN|SCRAM-SHA-256|SCRAM-SHA-512) ;;
            # Kafka's name for SASL/PLAIN is just PLAIN. SASL_PLAIN reaches the
            # brokers as an unknown mechanism and every client fails with
            # "Failed to create SaslClient with mechanism SASL_PLAIN".
            SASL_PLAIN)
                echo "[ERROR] 'SASL_PLAIN' is not a Kafka SASL mechanism; use 'PLAIN' in CONFLUENT_SASL_MECHANISM." >&2
                return 1 ;;
            *)
                echo "[ERROR] Unsupported SASL mechanism '${_m}' in CONFLUENT_SASL_MECHANISM." >&2
                echo "[ERROR] Use PLAIN, SCRAM-SHA-256 and/or SCRAM-SHA-512, comma-separated." >&2
                return 1 ;;
        esac
        (( ${_list[(Ie)${_m}]} )) || _list+=("${_m}")
    done
    if (( ${#_list[@]} == 0 )); then
        echo "[ERROR] CONFLUENT_SASL_MECHANISM is empty." >&2
        return 1
    fi

    CONFLUENT_SASL_MECHANISMS="${(j:,:)_list}"
    CONFLUENT_SASL_SCRAM_MECHANISMS="${(j: :)${(@M)_list:#SCRAM-*}}"
    CONFLUENT_SASL_CLIENT_MECHANISM=""
    for _m in SCRAM-SHA-512 SCRAM-SHA-256 PLAIN; do
        if (( ${_list[(Ie)${_m}]} )); then
            CONFLUENT_SASL_CLIENT_MECHANISM="${_m}"
            break
        fi
    done
    # Unreachable while the case above and this preference order list the same
    # mechanisms. Guarded because an unset value surfaces later, under set -u,
    # as "CONFLUENT_SASL_CLIENT_MECHANISM: parameter not set", which reads as
    # a missing setting and invites exporting one by hand.
    if [[ -z "${CONFLUENT_SASL_CLIENT_MECHANISM}" ]]; then
        echo "[ERROR] No usable client mechanism in '${CONFLUENT_SASL_MECHANISMS}'." >&2
        return 1
    fi
}

# Only SASL_PLAINTEXT can be served today: the internal listeners have no
# keystore (TLS exists only on the EXTERNAL listener, see x.4), and PLAINTEXT/SSL
# carry no SASL at all, which contradicts CONFLUENT_SASL_ENABLED=true.
confluent_sasl_check_protocol() {
    case "${CONFLUENT_SASL_SECURITY_PROTOCOL}" in
        SASL_PLAINTEXT) ;;
        SSL|SASL_SSL)
            echo "[ERROR] CONFLUENT_SASL_SECURITY_PROTOCOL=${CONFLUENT_SASL_SECURITY_PROTOCOL} needs TLS on the internal" >&2
            echo "[ERROR] listeners, which this stack does not provision. Use SASL_PLAINTEXT." >&2
            return 1 ;;
        PLAINTEXT)
            echo "[ERROR] CONFLUENT_SASL_SECURITY_PROTOCOL=PLAINTEXT disables SASL. Set CONFLUENT_SASL_ENABLED=false instead." >&2
            return 1 ;;
        *)
            echo "[ERROR] CONFLUENT_SASL_SECURITY_PROTOCOL must be one of PLAINTEXT, SSL, SASL_PLAINTEXT, SASL_SSL (got '${CONFLUENT_SASL_SECURITY_PROTOCOL}')." >&2
            return 1 ;;
    esac
}

# Client-side sasl.jaas.config for one user.
#   confluent_sasl_client_jaas <mechanism> <user> <password>
confluent_sasl_client_jaas() {
    local _module="org.apache.kafka.common.security.scram.ScramLoginModule"
    [[ "$1" == "PLAIN" ]] && _module="org.apache.kafka.common.security.plain.PlainLoginModule"
    print -r -- "${_module} required username=\"$2\" password=\"$3\";"
}

# Broker-side listener sasl.jaas.config for one mechanism. SCRAM only needs the
# credential the broker itself presents inter-broker; PLAIN also carries every
# accepted user as a user_<name> entry, since that is where PLAIN looks them up.
#   confluent_sasl_broker_jaas <mechanism> <admin user> <admin password> [<user>=<password> ...]
confluent_sasl_broker_jaas() {
    local _mech="$1" _user="$2" _pw="$3" _kv
    shift 3
    if [[ "${_mech}" != "PLAIN" ]]; then
        confluent_sasl_client_jaas "${_mech}" "${_user}" "${_pw}"
        return
    fi
    local _out="org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${_user}\" password=\"${_pw}\""
    for _kv in "$@"; do
        _out+=" user_${_kv%%=*}=\"${_kv#*=}\""
    done
    print -r -- "${_out};"
}

# kafka-configs --add-config value registering one password under every enabled
# SCRAM mechanism, e.g. SCRAM-SHA-256=[password=x],SCRAM-SHA-512=[password=x].
# Empty when no SCRAM mechanism is enabled (PLAIN only: nothing to register).
#   confluent_sasl_scram_config <password>
confluent_sasl_scram_config() {
    local _m
    local -a _parts
    for _m in ${=CONFLUENT_SASL_SCRAM_MECHANISMS}; do
        _parts+=("${_m}=[password=$1]")
    done
    print -r -- "${(j:,:)_parts}"
}

# Runs kafka-configs inside broker-0 against its internal listener. When that
# listener already requires SASL (e.g. adding SCRAM next to a running PLAIN
# cluster), an unauthenticated call is refused, so the admin credential is
# presented with whatever mechanism the running broker uses. Before SASL is on
# the listener is PLAINTEXT and the call goes through unauthenticated as before.
# The client config travels on stdin so the password stays out of the argv.
#   confluent_sasl_kafka_configs <namespace> <port> <admin user> <admin password> <kafka-configs args...>
confluent_sasl_kafka_configs() {
    local _ns="$1" _port="$2" _user="$3" _pw="$4" _map _proto _mech _props=""
    shift 4
    _map="$(oc get pod broker-0 -n "${_ns}" \
        -o jsonpath='{.spec.containers[0].env[?(@.name=="KAFKA_LISTENER_SECURITY_PROTOCOL_MAP")].value}' 2>/dev/null || true)"
    _proto="${${_map#*,PLAINTEXT:}%%,*}"
    if [[ "${_proto}" == SASL_* ]]; then
        _mech="$(oc get pod broker-0 -n "${_ns}" \
            -o jsonpath='{.spec.containers[0].env[?(@.name=="KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL")].value}' 2>/dev/null || true)"
        _props="security.protocol=${_proto}
sasl.mechanism=${_mech}
sasl.jaas.config=$(confluent_sasl_client_jaas "${_mech}" "${_user}" "${_pw}")"
    fi
    oc exec -i broker-0 -n "${_ns}" -- sh -c \
        'f="/tmp/.kafka-configs-$$.properties"; cat > "$f"; kafka-configs --bootstrap-server "localhost:$0" --command-config "$f" "$@"; rc=$?; rm -f "$f"; exit $rc' \
        "${_port}" "$@" <<< "${_props}"
}

# Commented-out client settings for one user, one sasl.mechanism +
# sasl.jaas.config pair per enabled mechanism (the client mechanism first). The
# two lines must change together: a PLAIN mechanism with the SCRAM login module,
# or the reverse, fails to authenticate. Pass a mechanism to leave out the pair
# already written as live settings above.
#   confluent_sasl_client_alternatives <user> <password> [<mechanism to skip>]
confluent_sasl_client_alternatives() {
    local _m
    local -a _order
    _order=(${(s:,:)CONFLUENT_SASL_MECHANISMS})
    _order=("${CONFLUENT_SASL_CLIENT_MECHANISM}" ${_order:#${CONFLUENT_SASL_CLIENT_MECHANISM}})
    for _m in "${_order[@]}"; do
        [[ "${_m}" == "${3:-}" ]] && continue
        print -r -- "# ${1} / ${_m}"
        print -r -- "# sasl.mechanism=${_m}"
        print -r -- "# sasl.jaas.config=$(confluent_sasl_client_jaas "${_m}" "$1" "$2")"
    done
}
