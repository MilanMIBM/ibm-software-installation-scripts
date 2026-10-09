#!/bin/zsh
# ==============================================================================
# Confluent Platform - Kafka listener security helpers (sourced, never executed)
# ------------------------------------------------------------------------------
# The one place that turns the security settings in confluent_vars.sh into
# broker, component and client configuration, so the installer, the x.* scripts
# and the Flink add-on cannot drift apart on how a mechanism is spelled.
#
#   CONFLUENT_SASL_PROTOCOL       SASL_PLAINTEXT | SASL_SSL
#       The in-cluster listeners (PLAINTEXT and PLAINTEXT_HOST by name). SASL_SSL
#       adds TLS from a private CA this file generates, so credentials are also
#       encrypted on the pod network.
#   CONFLUENT_SASL_MECHANISM      SCRAM-SHA-512 | SCRAM-SHA-256 | PLAIN
#       The mechanism the platform itself uses: inter-broker traffic and every
#       platform component. Also what the generated in-cluster client files use.
#   CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS   comma list, default PLAIN,SCRAM-SHA-512
#       Every mechanism the in-cluster listeners accept, so in-cluster clients
#       (CPD connections, applications) may use any of them. The platform's own
#       CONFLUENT_SASL_MECHANISM is always accepted, listed or not.
#   CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS   comma list, default PLAIN,SCRAM-SHA-512
#       The mechanisms the EXTERNAL listener accepts. The first is what the
#       generated client files use. The EXTERNAL listener is always SASL_SSL:
#       the passthrough routes pick the broker from the TLS SNI hostname, so a
#       non-TLS protocol could not be routed at all.
#
# SCRAM vs PLAIN (https://docs.confluent.io/platform/current/security/authentication/sasl/overview.html):
#   SCRAM credentials live in the KRaft metadata log and are added or rotated
#   with kafka-configs while the brokers run; the password never crosses the
#   wire. PLAIN sends the password itself and validates it against a static
#   user list in the broker's JAAS config, so adding a user restarts the
#   brokers - Confluent requires TLS underneath it, which the EXTERNAL listener
#   always has and the internal ones have with CONFLUENT_SASL_PROTOCOL=SASL_SSL.
#
# Every user in CONFLUENT_SASL_SECRET is valid for every mechanism: the same
# name and password authenticate over SCRAM and over PLAIN.
# ==============================================================================

: "${CONFLUENT_SASL_PROTOCOL:=SASL_PLAINTEXT}"
: "${CONFLUENT_SASL_MECHANISM:=SCRAM-SHA-512}"
: "${CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS:=PLAIN,SCRAM-SHA-512}"
: "${CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS:=PLAIN,SCRAM-SHA-512}"
: "${CONFLUENT_INTERNAL_TLS_SECRET:=confluent-kafka-internal-tls}"
: "${CONFLUENT_INTERNAL_CERT_VALIDITY_DAYS:=825}"

# Where the brokers and components find the in-cluster CA when SASL_SSL is on.
CONFLUENT_BROKER_TLS_DIR="/etc/confluent/internal-tls"
CONFLUENT_KAFKA_CA_MOUNT="/etc/confluent/kafka-ca"

# Spaces are tolerated in the lists ("PLAIN, SCRAM-SHA-512") and dropped here.
CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS="${CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS//[[:space:]]/}"
CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS="${CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS//[[:space:]]/}"

# ------------------------------------------------------------------------------
# kafka_security_validate - fail fast on a value the brokers would reject later.
# ------------------------------------------------------------------------------
kafka_security_validate() {
    local ok=true m
    case "${CONFLUENT_SASL_PROTOCOL}" in
        SASL_PLAINTEXT|SASL_SSL) ;;
        *)  echo "[ERROR] CONFLUENT_SASL_PROTOCOL='${CONFLUENT_SASL_PROTOCOL}' - expected SASL_PLAINTEXT or SASL_SSL." >&2
            ok=false ;;
    esac
    if ! kafka_is_mechanism "${CONFLUENT_SASL_MECHANISM}"; then
        echo "[ERROR] CONFLUENT_SASL_MECHANISM='${CONFLUENT_SASL_MECHANISM}' - expected SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN." >&2
        ok=false
    fi
    local var
    for var in CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS; do
        if [[ -z "${(P)var}" ]]; then
            echo "[ERROR] ${var} is empty - list at least one mechanism." >&2
            ok=false
        fi
        for m in ${(s:,:)${(P)var}}; do
            if ! kafka_is_mechanism "${m}"; then
                echo "[ERROR] ${var} contains '${m}' - expected SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN." >&2
                ok=false
            fi
        done
    done
    if [[ ",${CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS}," != *",${CONFLUENT_SASL_MECHANISM},"* ]]; then
        echo "[INFO] CONFLUENT_SASL_MECHANISM=${CONFLUENT_SASL_MECHANISM} is not in CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS;"
        echo "[INFO] the in-cluster listeners accept it anyway (broker-to-broker traffic and the components use it)."
    fi
    if [[ "${CONFLUENT_SASL_PROTOCOL}" == "SASL_PLAINTEXT" && ",$(kafka_internal_mechanisms)," == *",PLAIN,"* ]]; then
        # PLAIN sends the password itself; Confluent recommends it only over TLS.
        echo "[WARN] In-cluster PLAIN runs unencrypted (SASL_PLAINTEXT): set CONFLUENT_SASL_PROTOCOL=SASL_SSL to protect PLAIN passwords on the pod network."
    fi
    $ok
}

kafka_is_mechanism() {
    case "$1" in
        PLAIN|SCRAM-SHA-256|SCRAM-SHA-512) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# kafka_internal_mechanisms - what the in-cluster listeners accept, as a comma
# list: CONFLUENT_SASL_MECHANISM first (broker_listener_security.sh reads the
# first entry as the inter-broker mechanism), then the rest of
# CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS without repeats.
# ------------------------------------------------------------------------------
kafka_internal_mechanisms() {
    local -aU list
    list=("${CONFLUENT_SASL_MECHANISM}" ${(s:,:)CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS})
    print -r -- "${(j:,:)list}"
}

# The mechanism written into generated external client files.
kafka_external_primary_mechanism() {
    print -r -- "${CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS%%,*}"
}

# ------------------------------------------------------------------------------
# kafka_login_module <mechanism> - the JAAS login module class for a mechanism.
# ------------------------------------------------------------------------------
kafka_login_module() {
    case "$1" in
        PLAIN) print -r -- "org.apache.kafka.common.security.plain.PlainLoginModule" ;;
        *)     print -r -- "org.apache.kafka.common.security.scram.ScramLoginModule" ;;
    esac
}

# ------------------------------------------------------------------------------
# kafka_client_jaas <mechanism> <user> <password> - a client sasl.jaas.config.
# ------------------------------------------------------------------------------
kafka_client_jaas() {
    print -r -- "$(kafka_login_module "$1") required username=\"$2\" password=\"$3\";"
}

# ------------------------------------------------------------------------------
# kafka_client_properties <protocol> <mechanism> <user> <password> [truststore]
# Prints the Kafka client properties for one credential. The truststore is a
# PEM CA file, only emitted for SASL_SSL.
# ------------------------------------------------------------------------------
kafka_client_properties() {
    local protocol="$1" mechanism="$2" user="$3" password="$4" truststore="${5:-}"
    print -r -- "security.protocol=${protocol}"
    print -r -- "sasl.mechanism=${mechanism}"
    print -r -- "sasl.jaas.config=$(kafka_client_jaas "${mechanism}" "${user}" "${password}")"
    if [[ "${protocol}" == "SASL_SSL" && -n "${truststore}" ]]; then
        print -r -- "ssl.truststore.type=PEM"
        print -r -- "ssl.truststore.location=${truststore}"
    fi
}

# ------------------------------------------------------------------------------
# kafka_scram_mechanisms_in_use - the SCRAM mechanisms some listener accepts.
# SCRAM-SHA-256 and SCRAM-SHA-512 credentials are stored separately, so each one
# in use needs its own registration.
# ------------------------------------------------------------------------------
kafka_scram_mechanisms_in_use() {
    local -aU mechs
    local m
    for m in ${(s:,:)$(kafka_internal_mechanisms)}; do
        [[ "${m}" == SCRAM-* ]] && mechs+=("${m}")
    done
    if [[ "${CONFLUENT_EXTERNAL_KAFKA_ENABLED:-false}" == "true" ]]; then
        for m in ${(s:,:)CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS}; do
            [[ "${m}" == SCRAM-* ]] && mechs+=("${m}")
        done
    fi
    print -r -- "${mechs[*]}"
}

# ------------------------------------------------------------------------------
# kafka_secret_credentials <ns> - every user=password pair in the SASL secret.
# ------------------------------------------------------------------------------
kafka_secret_credentials() {
    local ns="$1" line
    oc get secret "${CONFLUENT_SASL_SECRET}" -n "${ns}" \
        -o go-template='{{range $k, $v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null \
    | while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        print -r -- "${line%%=*}=$(print -r -- "${line#*=}" | base64 --decode)"
    done
}

# ------------------------------------------------------------------------------
# kafka_pod_internal_security <ns> <pod> - "<protocol> <mechanism>" a running
# broker actually uses on the inter-broker listener, read from its own spec
# (not the StatefulSet's, which may already describe the next rollout).
# The mechanism is "-" when the listener has none.
# ------------------------------------------------------------------------------
kafka_pod_internal_security() {
    local ns="$1" pod="$2" map mech proto="" entry
    map="$(oc get pod "${pod}" -n "${ns}" \
        -o jsonpath='{.spec.containers[0].env[?(@.name=="KAFKA_LISTENER_SECURITY_PROTOCOL_MAP")].value}' 2>/dev/null || true)"
    mech="$(oc get pod "${pod}" -n "${ns}" \
        -o jsonpath='{.spec.containers[0].env[?(@.name=="KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL")].value}' 2>/dev/null || true)"
    # PLAINTEXT_HOST:... does not match PLAINTEXT:*, so this picks the
    # inter-broker listener only.
    for entry in ${(s:,:)map}; do
        [[ "${entry}" == PLAINTEXT:* ]] && proto="${entry#PLAINTEXT:}"
    done
    [[ "${proto:-PLAINTEXT}" == "PLAINTEXT" ]] && mech=""
    print -r -- "${proto:-PLAINTEXT} ${mech:--}"
}

# ------------------------------------------------------------------------------
# kafka_pod_listener_mechanisms <ns> <pod> <listener> - the comma list of
# mechanisms a running broker accepts on one listener (plaintext, external),
# read from its BROKER_SASL_LISTENERS. Empty when the listener has no SASL.
# ------------------------------------------------------------------------------
kafka_pod_listener_mechanisms() {
    local ns="$1" pod="$2" listener="$3" entries entry
    entries="$(oc get pod "${pod}" -n "${ns}" \
        -o jsonpath='{.spec.containers[0].env[?(@.name=="BROKER_SASL_LISTENERS")].value}' 2>/dev/null || true)"
    for entry in ${=entries}; do
        [[ "${entry%%:*}" == "${listener}" ]] && { print -r -- "${entry#*:}"; return 0; }
    done
    return 0
}

# ------------------------------------------------------------------------------
# kafka_register_scram_users <ns> <admin-auth-password> <user=password>...
# Writes SCRAM credentials for every SCRAM mechanism in use. It authenticates
# with whatever the running brokers currently expect: nothing on a PLAINTEXT
# cluster, otherwise the admin credential over the live protocol and mechanism -
# which is what lets clients be added to a cluster that is already SASL-only.
# The admin password is passed separately so a rotation can authenticate with
# the old one. Returns 0 with nothing to do when no listener uses SCRAM.
# ------------------------------------------------------------------------------
kafka_register_scram_users() {
    local ns="$1" auth_pw="$2"; shift 2
    local -a mechs cfg_arg
    mechs=(${=$(kafka_scram_mechanisms_in_use)})
    (( ${#mechs} )) || return 0

    local live_proto live_mech
    read -r live_proto live_mech <<< "$(kafka_pod_internal_security "${ns}" broker-0)"
    cfg_arg=()
    if [[ "${live_proto}" == SASL_* ]]; then
        local truststore=""
        [[ "${live_proto}" == "SASL_SSL" ]] && truststore="${CONFLUENT_BROKER_TLS_DIR}/ca.crt"
        # Piped over stdin rather than passed as an argument, so the admin
        # password never appears in a process list.
        kafka_client_properties "${live_proto}" "${live_mech}" \
                "${CONFLUENT_SASL_ADMIN_USER}" "${auth_pw}" "${truststore}" \
            | oc exec -i broker-0 -n "${ns}" -- sh -c 'umask 077; cat > /tmp/.kafka-admin.properties' \
            || return 1
        cfg_arg=(--command-config /tmp/.kafka-admin.properties)
    fi

    local pair user pw config m rc=0
    for pair in "$@"; do
        user="${pair%%=*}"; pw="${pair#*=}"
        [[ -z "${pw}" ]] && continue
        config=""
        for m in "${mechs[@]}"; do config+="${config:+,}${m}=[password=${pw}]"; done
        if oc exec broker-0 -n "${ns}" -- kafka-configs \
                --bootstrap-server "localhost:${CONFLUENT_BROKER_INTERNAL_PORT}" "${cfg_arg[@]}" \
                --alter --add-config "${config}" \
                --entity-type users --entity-name "${user}" >/dev/null 2>&1; then
            echo "[INFO]   registered ${user} (${(j:, :)mechs})"
        else
            echo "[ERROR] Failed to register SCRAM credentials for '${user}'." >&2
            rc=1
            break
        fi
    done
    (( ${#cfg_arg} )) && oc exec broker-0 -n "${ns}" -- rm -f /tmp/.kafka-admin.properties >/dev/null 2>&1
    return ${rc}
}

# ------------------------------------------------------------------------------
# kafka_ensure_internal_tls <ns> [force] - the in-cluster CA and broker keystore
# for CONFLUENT_SASL_PROTOCOL=SASL_SSL. Generated once and reused, so redeploys
# keep the same CA and clients that already trust it carry on working. "force"
# replaces it (rotation).
#
# Unlike the EXTERNAL listener's certificate this needs no running broker: the
# keystore is PKCS12, which openssl writes and the JVM reads directly, so it is
# available on the very first install.
# ------------------------------------------------------------------------------
kafka_ensure_internal_tls() {
    local ns="$1" force="${2:-false}" secret="${CONFLUENT_INTERNAL_TLS_SECRET}"
    if [[ "${force}" != "true" ]] \
       && [[ -n "$(oc get secret "${secret}" -n "${ns}" -o jsonpath='{.data.keystore\.p12}' 2>/dev/null)" ]]; then
        return 0
    fi
    if ! command -v openssl &>/dev/null; then
        echo "[ERROR] openssl is required to generate the in-cluster Kafka certificates." >&2
        return 1
    fi

    echo "[INFO] Generating the in-cluster Kafka CA and broker certificate..."
    local tmp; tmp="$(mktemp -d)"

    # Every name an in-cluster client can dial: the short and qualified Service
    # names (bootstrap), the per-pod names the PLAINTEXT listener advertises
    # (wildcard), and localhost for the tools run inside a broker pod.
    local san="DNS:localhost" svc
    for svc in broker broker-headless; do
        san+=",DNS:${svc},DNS:${svc}.${ns},DNS:${svc}.${ns}.svc,DNS:${svc}.${ns}.svc.cluster.local"
    done
    san+=",DNS:*.broker-headless.${ns}.svc,DNS:*.broker-headless.${ns}.svc.cluster.local"

    local store_pw
    store_pw="$(LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"

    # X.509 caps a CN at 64 characters, so it is a fixed label; clients check
    # the SAN list, not the CN.
    if openssl req -new -x509 -nodes -days "${CONFLUENT_INTERNAL_CERT_VALIDITY_DAYS}" \
            -subj "/CN=Confluent Kafka internal CA/O=cp4d-installation-scripts" \
            -keyout "${tmp}/ca.key" -out "${tmp}/ca.crt" 2>/dev/null \
       && openssl req -new -nodes \
            -subj "/CN=confluent-kafka-internal/O=cp4d-installation-scripts" \
            -keyout "${tmp}/server.key" -out "${tmp}/server.csr" 2>/dev/null \
       && printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\n' "${san}" > "${tmp}/ext.cnf" \
       && openssl x509 -req -in "${tmp}/server.csr" \
            -CA "${tmp}/ca.crt" -CAkey "${tmp}/ca.key" -CAcreateserial \
            -out "${tmp}/server.crt" -days "${CONFLUENT_INTERNAL_CERT_VALIDITY_DAYS}" \
            -extfile "${tmp}/ext.cnf" 2>/dev/null \
       && openssl pkcs12 -export \
            -in "${tmp}/server.crt" -inkey "${tmp}/server.key" -certfile "${tmp}/ca.crt" \
            -name broker -out "${tmp}/keystore.p12" -passout "pass:${store_pw}" 2>/dev/null; then
        # The CA private key is not stored: nothing re-signs with it, and
        # rotation regenerates the whole chain.
        oc create secret generic "${secret}" \
            --from-file=ca.crt="${tmp}/ca.crt" \
            --from-file=keystore.p12="${tmp}/keystore.p12" \
            --from-literal=storePassword="${store_pw}" \
            -n "${ns}" --dry-run=client -o yaml | oc apply -f - >/dev/null
        rm -rf "${tmp}"
        echo "[INFO] In-cluster TLS material stored in secret '${secret}'."
    else
        rm -rf "${tmp}"
        echo "[ERROR] Generating the in-cluster Kafka certificates failed." >&2
        return 1
    fi
}

# ------------------------------------------------------------------------------
# kafka_hash - a short, stable digest of stdin, for pod-template annotations
# that roll a workload when the credentials or certificates behind it change.
# ------------------------------------------------------------------------------
kafka_hash() {
    if command -v sha256sum &>/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-16
}
