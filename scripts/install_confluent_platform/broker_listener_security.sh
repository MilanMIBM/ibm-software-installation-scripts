#!/bin/bash
# ==============================================================================
# Confluent Platform - broker listener security (runs INSIDE each broker pod)
# ------------------------------------------------------------------------------
# Shipped to the brokers as the broker-listener-security ConfigMap by
# 1.1_confluent_install.sh, and run between /etc/confluent/docker/configure and
# /etc/confluent/docker/ensure. Not meant to be run on a workstation.
#
# Appends the listener-scoped SASL and TLS settings to kafka.properties:
#
#   listener.name.<l>.sasl.enabled.mechanisms=<mechanisms>
#   listener.name.<l>.<mechanism>.sasl.jaas.config=<login module> required ...;
#   listener.name.<l>.ssl.keystore.* / ssl.truststore.*      (TLS listeners)
#
# They are built here rather than passed as KAFKA_* environment variables for
# two reasons. The JAAS entries carry passwords, which would otherwise sit in
# plain text in the StatefulSet spec. And SASL/PLAIN validates clients against a
# static user_<name>="<password>" list in the JAAS entry itself, which is only
# known from the mounted credentials secret, one file per user.
#
# Inputs (environment):
#   BROKER_SASL_ADMIN_USER  the broker's own principal; its credential is the
#                           client side of inter-broker authentication
#   BROKER_SASL_LISTENERS   space-separated <listener>:<MECH[,MECH...]>, e.g.
#                           "plaintext:SCRAM-SHA-512 external:PLAIN"
#   BROKER_TLS_LISTENERS    space-separated listener names that use the
#                           in-cluster keystore (empty = none)
#   BROKER_SASL_DIR         mounted credentials secret (/etc/confluent/sasl)
#   BROKER_TLS_DIR          mounted in-cluster TLS secret (/etc/confluent/internal-tls)
# ==============================================================================

set -euo pipefail

props="${1:?usage: $0 <kafka.properties>}"
sasl_dir="${BROKER_SASL_DIR:-/etc/confluent/sasl}"
tls_dir="${BROKER_TLS_DIR:-/etc/confluent/internal-tls}"
admin="${BROKER_SASL_ADMIN_USER:?BROKER_SASL_ADMIN_USER is not set}"

# Values land inside a double-quoted JAAS option in a .properties file, where a
# quote ends the option early and a backslash is an escape character.
read_secret() {
    local value
    value="$(cat "$1")"
    if [[ "${value}" == *[\"\\]* ]]; then
        echo "[ERROR] ${1##*/} contains a quote or backslash, which a JAAS option cannot carry." >&2
        echo "[ERROR] Rotate it with x.2_confluent_add_sasl.sh --rotate." >&2
        exit 1
    fi
    printf '%s' "${value}"
}

if [[ ! -f "${sasl_dir}/${admin}" ]]; then
    echo "[ERROR] No credential for the admin user '${admin}' in ${sasl_dir}." >&2
    exit 1
fi
admin_pw="$(read_secret "${sasl_dir}/${admin}")"

# The secret volume also holds ..data and timestamped directories; the glob
# skips them because they start with a dot.
plain_users=""
for f in "${sasl_dir}"/*; do
    [[ -f "${f}" ]] || continue
    plain_users+=" user_${f##*/}=\"$(read_secret "${f}")\""
done

{
    for entry in ${BROKER_SASL_LISTENERS:-}; do
        listener="${entry%%:*}"
        mechanisms="${entry#*:}"
        echo "listener.name.${listener}.sasl.enabled.mechanisms=${mechanisms}"
        IFS=, read -r -a mech_list <<< "${mechanisms}"
        for mech in "${mech_list[@]}"; do
            case "${mech}" in
                PLAIN)
                    # username/password: this broker's identity when the
                    # listener is used inter-broker. user_*: who may log in.
                    echo "listener.name.${listener}.plain.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${admin}\" password=\"${admin_pw}\"${plain_users};"
                    ;;
                SCRAM-SHA-256|SCRAM-SHA-512)
                    # SCRAM checks clients against the credentials stored in
                    # the metadata log; only the broker's own identity is here.
                    echo "listener.name.${listener}.${mech,,}.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${admin}\" password=\"${admin_pw}\";"
                    ;;
                *)
                    echo "[ERROR] Unsupported SASL mechanism '${mech}' on listener ${listener}." >&2
                    exit 1
                    ;;
            esac
        done
    done

    if [[ -n "${BROKER_TLS_LISTENERS:-}" ]]; then
        store_pw="$(read_secret "${tls_dir}/storePassword")"
        for listener in ${BROKER_TLS_LISTENERS}; do
            echo "listener.name.${listener}.ssl.keystore.type=PKCS12"
            echo "listener.name.${listener}.ssl.keystore.location=${tls_dir}/keystore.p12"
            echo "listener.name.${listener}.ssl.keystore.password=${store_pw}"
            echo "listener.name.${listener}.ssl.key.password=${store_pw}"
            echo "listener.name.${listener}.ssl.truststore.type=PEM"
            echo "listener.name.${listener}.ssl.truststore.location=${tls_dir}/ca.crt"
        done
    fi
} >> "${props}"

# A ready-made admin client config for the kafka-* tools run inside this pod,
# matching the inter-broker listener (always the first BROKER_SASL_LISTENERS
# entry), so in-pod commands work whatever protocol and mechanism are set:
#   kafka-topics --bootstrap-server localhost:29092 \
#       --command-config /etc/kafka/client.properties --list
first="${BROKER_SASL_LISTENERS%% *}"
mech="${first#*:}"
mech="${mech%%,*}"
protocol="SASL_PLAINTEXT"
[[ " ${BROKER_TLS_LISTENERS:-} " == *" ${first%%:*} "* ]] && protocol="SASL_SSL"
if [[ "${mech}" == "PLAIN" ]]; then
    module="org.apache.kafka.common.security.plain.PlainLoginModule"
else
    module="org.apache.kafka.common.security.scram.ScramLoginModule"
fi
client_props="$(dirname "${props}")/client.properties"
(
    umask 077
    {
        echo "security.protocol=${protocol}"
        echo "sasl.mechanism=${mech}"
        echo "sasl.jaas.config=${module} required username=\"${admin}\" password=\"${admin_pw}\";"
        if [[ "${protocol}" == "SASL_SSL" ]]; then
            echo "ssl.truststore.type=PEM"
            echo "ssl.truststore.location=${tls_dir}/ca.crt"
        fi
    } > "${client_props}"
)

echo "[INFO] Listener security applied: ${BROKER_SASL_LISTENERS:-none}${BROKER_TLS_LISTENERS:+ (TLS: ${BROKER_TLS_LISTENERS})}"
