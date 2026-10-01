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
# Confluent Platform for Apache Flink - attach a Kafka cluster
# ------------------------------------------------------------------------------
# THIS is the script that makes Flink an add-on rather than a separate product.
# The install puts Flink on the cluster knowing nothing about Kafka; this
# registers a Kafka cluster with CMF so Flink SQL can read and write its topics.
#
# What it creates in CMF:
#   Secret                  the SASL credentials, held by CMF rather than
#                           written into the catalog.
#   KafkaCatalog            the Flink SQL catalog. Carries only the Schema
#                           Registry connection.
#   KafkaDatabase           the Kafka cluster itself, registered under that
#                           catalog. Each topic becomes a TABLE in it.
#                           Created over the REST API: confluent CLI v4.74 has
#                           no "flink database" command yet.
#   EnvironmentSecretMapping  binds the secret to the connectionSecretId for
#                           this environment.
#
# After it runs:
#   SELECT * FROM `cp-kafka`.`cp-cluster`.`my-topic`;
#
# Discovery: with no flags it reads the Confluent installation in
# PROJECT_CONFLUENT_SERVER - bootstrap address, SASL mechanism, the admin
# credential from the SASL secret and the Schema Registry endpoint. Every one of
# those can be overridden, and --bootstrap alone is enough to point Flink at a
# Kafka cluster this repo did not install.
#
# Network: when Flink and Kafka are in different projects, a Kubernetes
# NetworkPolicy in the Confluent project may block the traffic. This script
# detects that and offers to open it with --allow-network.
#
# Usage:
#   ./x.4_flink_connect_kafka.sh [options]
#
#   --bootstrap HOST:PORT     Kafka bootstrap (default: discovered)
#   --schema-registry URL     Schema Registry URL (default: discovered)
#   --sasl-user NAME          SASL username (default: CONFLUENT_SASL_ADMIN_USER)
#   --sasl-password PASS      SASL password (default: read from the secret)
#   --no-sasl                 connect as PLAINTEXT with no credentials
#   --no-schema-registry      register the cluster without Schema Registry
#   --catalog NAME            catalog name (default: FLINK_CATALOG)
#   --database NAME           database name for this cluster (default: FLINK_KAFKA_DATABASE)
#   --allow-network           add a NetworkPolicy in the Confluent project
#                             permitting the Flink namespace to reach Kafka
#   --replace                 delete and recreate an existing catalog
#   --test                    after wiring it up, verify by listing the tables
#   --dry-run                 print the resources, create nothing
# ==============================================================================

BOOTSTRAP=""
SR_URL=""
SASL_USER=""
SASL_PASSWORD=""
USE_SASL=true
USE_SR=true
CATALOG="${FLINK_CATALOG}"
DATABASE="${FLINK_KAFKA_DATABASE}"
ALLOW_NETWORK=false
REPLACE=false
RUN_TEST=false
# Set when --test finds the catalog already present: creation is then skipped
# and the script goes straight to the verification statement.
CATALOG_EXISTS=false
DRY_RUN=false

_need_value() {
    [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }
}

while (( $# > 0 )); do
    case "$1" in
        --bootstrap)           _need_value "$1" "${2:-}"; BOOTSTRAP="$2"; shift 2 ;;
        --schema-registry)     _need_value "$1" "${2:-}"; SR_URL="$2"; shift 2 ;;
        --sasl-user)           _need_value "$1" "${2:-}"; SASL_USER="$2"; shift 2 ;;
        --sasl-password)       _need_value "$1" "${2:-}"; SASL_PASSWORD="$2"; shift 2 ;;
        --no-sasl)             USE_SASL=false; shift ;;
        --no-schema-registry)  USE_SR=false; shift ;;
        --catalog)             _need_value "$1" "${2:-}"; CATALOG="$2"; shift 2 ;;
        --database)            _need_value "$1" "${2:-}"; DATABASE="$2"; shift 2 ;;
        --allow-network)       ALLOW_NETWORK=true; shift ;;
        --replace)             REPLACE=true; shift ;;
        --test)                RUN_TEST=true; shift ;;
        --dry-run)             DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '19,61p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

if ! command -v confluent &>/dev/null; then
    echo "[ERROR] The confluent CLI is required. Install it with:" >&2
    echo "[ERROR]   brew install confluentinc/tap/cli" >&2
    exit 1
fi

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_FLINK}"
KAFKA_NS="${PROJECT_CONFLUENT_SERVER}"

# --dry-run only renders the resources, so it stays useful before Flink is
# installed - which is exactly when someone wants to see what this would create.
if ! oc get namespace "${NS}" &>/dev/null; then
    if [[ "${DRY_RUN}" != "true" ]]; then
        echo "[ERROR] Flink project '${NS}' does not exist. Run the install first." >&2
        exit 1
    fi
    echo "[WARN] Flink project '${NS}' does not exist - rendering anyway (--dry-run)."
fi

RESOURCE_DIR="${SCRIPT_DIR}/flink_vars/rendered"
mkdir -p "${RESOURCE_DIR}"

# ==============================================================================
# Discover the Kafka cluster
# ==============================================================================
_discovered=false

if [[ -z "${BOOTSTRAP}" ]]; then
    if ! oc get statefulset broker -n "${KAFKA_NS}" &>/dev/null; then
        echo "[ERROR] No Confluent cluster found in project '${KAFKA_NS}', and no" >&2
        echo "[ERROR] --bootstrap was given. Either install the Confluent Platform" >&2
        echo "[ERROR] first, or point this at an existing cluster:" >&2
        echo "[ERROR]   ./x.4_flink_connect_kafka.sh --bootstrap kafka.example.com:9092" >&2
        exit 1
    fi
    _discovered=true

    # The headless service resolves to every broker, which is what a bootstrap
    # address should be: the client discovers the rest of the cluster from
    # whichever broker answers. Fully qualified because Flink runs in a
    # different namespace, where the short name does not resolve.
    BOOTSTRAP="broker-headless.${KAFKA_NS}.svc.cluster.local:${CONFLUENT_BROKER_INTERNAL_PORT}"
    echo "[INFO] Discovered Kafka cluster in '${KAFKA_NS}'."
fi

if [[ "${USE_SR}" == "true" && -z "${SR_URL}" ]]; then
    if oc get service schema-registry -n "${KAFKA_NS}" &>/dev/null; then
        SR_URL="http://schema-registry.${KAFKA_NS}.svc.cluster.local:${CONFLUENT_SCHEMA_REGISTRY_PORT}"
    else
        echo "[WARN] No Schema Registry service found in '${KAFKA_NS}'."
        echo "[WARN] Continuing without one: topics will only be readable as raw"
        echo "[WARN] bytes/JSON, not as Avro/Protobuf tables."
        USE_SR=false
    fi
fi

# ------------------------------------------------------------------------------
# SASL credentials
# ------------------------------------------------------------------------------
# Read from the secret x.2_confluent_add_sasl.sh writes, keyed by username. The
# admin credential is used because the catalog needs to list every topic; a
# narrower principal works if it has DESCRIBE on the topics Flink should see.
if [[ "${USE_SASL}" == "true" ]]; then
    if [[ "${_discovered}" == "true" && "${CONFLUENT_SASL_ENABLED:-false}" != "true" ]]; then
        echo "[INFO] The discovered cluster has SASL disabled - connecting as PLAINTEXT."
        USE_SASL=false
    fi
fi

if [[ "${USE_SASL}" == "true" ]]; then
    [[ -z "${SASL_USER}" ]] && SASL_USER="${CONFLUENT_SASL_ADMIN_USER}"

    if [[ -z "${SASL_PASSWORD}" ]]; then
        SASL_PASSWORD="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${KAFKA_NS}" \
            -o jsonpath="{.data.${SASL_USER}}" 2>/dev/null | base64 --decode || true)"
        if [[ -z "${SASL_PASSWORD}" ]]; then
            echo "[ERROR] No password for '${SASL_USER}' in secret '${CONFLUENT_SASL_SECRET}'" >&2
            echo "[ERROR] (project ${KAFKA_NS}). Pass --sasl-password, or --no-sasl if the" >&2
            echo "[ERROR] cluster does not require authentication." >&2
            exit 1
        fi
        echo "[INFO] Read the '${SASL_USER}' credential from secret '${CONFLUENT_SASL_SECRET}'."
    fi
fi

# ------------------------------------------------------------------------------
# Security protocol
# ------------------------------------------------------------------------------
# The internal listener is SASL_PLAINTEXT: it carries credentials but is not
# encrypted, which is what the brokers offer inside the cluster. Traffic stays
# on the pod network. An external bootstrap over the passthrough routes would be
# SASL_SSL instead - detected here by the :443 the routes advertise.
if [[ "${USE_SASL}" == "true" ]]; then
    if [[ "${BOOTSTRAP}" == *:443 ]]; then
        SECURITY_PROTOCOL="SASL_SSL"
    else
        SECURITY_PROTOCOL="SASL_PLAINTEXT"
    fi
else
    SECURITY_PROTOCOL="PLAINTEXT"
fi

echo ""
echo "=============================================================================="
echo " Attaching Kafka to Flink"
echo "=============================================================================="
printf '  %-22s %s\n' \
    "catalog"           "${CATALOG}" \
    "database"          "${DATABASE}" \
    "bootstrap"         "${BOOTSTRAP}" \
    "security protocol" "${SECURITY_PROTOCOL}"
[[ "${USE_SASL}" == "true" ]] && printf '  %-22s %s\n' \
    "SASL mechanism"    "${CONFLUENT_SASL_MECHANISM}" \
    "SASL user"         "${SASL_USER}"
[[ "${USE_SR}" == "true" ]] && printf '  %-22s %s\n' "schema registry" "${SR_URL}"
echo ""

# ==============================================================================
# NetworkPolicy
# ==============================================================================
# The Confluent install can restrict ingress to its own pods. Flink lives in
# another namespace, so its connections are dropped - and the symptom is a
# catalog that creates cleanly and then times out on every query, which is a
# genuinely difficult thing to diagnose after the fact.
if [[ "${_discovered}" == "true" && "${NS}" != "${KAFKA_NS}" ]]; then
    _policies="$(oc get networkpolicy -n "${KAFKA_NS}" -o name 2>/dev/null | wc -l | tr -d ' ')"
    if (( _policies > 0 )); then
        if [[ "${ALLOW_NETWORK}" == "true" ]]; then
            if [[ "${DRY_RUN}" == "true" ]]; then
                echo "  [DRY-RUN] oc apply networkpolicy/allow-flink -n ${KAFKA_NS}"
            else
                # Selects the Flink namespace by label. The kubernetes.io/metadata.name
                # label is set automatically on every namespace, so nothing has to be
                # labelled by hand.
                #
                # EVERY rule below the first is required, and none may be dropped.
                # podSelector: {} in the spec selects every pod in the Confluent
                # namespace, and in Kubernetes the moment any NetworkPolicy selects
                # a pod, all ingress that is not explicitly allowed becomes DENIED.
                # A policy with only the Flink rule therefore silently cuts off:
                #
                #   broker-to-broker    the KRaft quorum loses its heartbeats, no
                #                       controller is elected, and Schema Registry
                #                       fails to write to _schemas with
                #                       "error code: 50001"
                #   the OpenShift router  EVERY route in the namespace stops
                #                       answering - Control Center's oauth login
                #                       page included - and times out with no
                #                       response at all rather than an error
                #   cluster monitoring  Prometheus can no longer scrape the pods
                #
                # In all three cases the pods stay "Running", which makes this very
                # easy to misread as a fault in whatever stopped working.
                oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-flink
  namespace: ${KAFKA_NS}
  labels:
    app.kubernetes.io/part-of: confluent
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    # Flink, from its own namespace.
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${NS}
    # Everything already inside this namespace: brokers to each other, and the
    # components to the brokers.
    - from:
        - podSelector: {}
    # The OpenShift router, so the routes keep working. The label is the
    # standard one OpenShift puts on openshift-ingress for exactly this.
    - from:
        - namespaceSelector:
            matchLabels:
              policy-group.network.openshift.io/ingress: ""
    # Cluster monitoring, so Prometheus can still scrape.
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: monitoring
EOF
                echo "[INFO] NetworkPolicy 'allow-flink' added to '${KAFKA_NS}'."
            fi
        else
            echo "[WARN] ${_policies} NetworkPolicy object(s) exist in '${KAFKA_NS}'. If they"
            echo "[WARN] restrict ingress, Flink's connections from '${NS}' will be dropped"
            echo "[WARN] and every query will time out. Re-run with --allow-network to add"
            echo "[WARN] a policy permitting this namespace."
            echo ""
        fi
    fi
fi

# ==============================================================================
# Broker transaction timeout
# ==============================================================================
# Flink's exactly-once Kafka sink asks for a 1 hour transaction timeout, and a
# broker capping it lower rejects the producer. The statement then sits in
# PENDING forever while the write task restart-loops, and nothing CMF reports
# points at the broker - so check it here, where the message can be useful.
if [[ "${_discovered}" == "true" && "${DRY_RUN}" != "true" ]]; then
    _txn_max="$(oc get statefulset broker -n "${KAFKA_NS}" \
        -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="KAFKA_TRANSACTION_MAX_TIMEOUT_MS")]}{.value}{end}' 2>/dev/null || true)"
    # Empty means the broker default of 900000 (15 minutes).
    if (( ${_txn_max:-900000} < 3600000 )); then
        echo "[WARN] The brokers cap transaction.max.timeout.ms at ${_txn_max:-900000}ms."
        echo "[WARN] Flink's exactly-once sink requests 3600000ms, so every INSERT INTO"
        echo "[WARN] will hang in PENDING with the write task failing on:"
        echo "[WARN]   The transaction timeout is larger than the maximum value allowed"
        echo "[WARN]   by the broker (as configured by transaction.max.timeout.ms)"
        echo "[WARN] Reading topics is unaffected. To fix, redeploy the brokers with"
        echo "[WARN] KAFKA_TRANSACTION_MAX_TIMEOUT_MS=3600000 (already set in the current"
        echo "[WARN] 1.1_confluent_install.sh):"
        echo "[WARN]   ../1.1_confluent_install.sh"
        echo ""
    fi
fi

# ==============================================================================
# CMF connection
# ==============================================================================
if [[ "${DRY_RUN}" != "true" ]]; then
    source "${SCRIPT_DIR}/flink_cmf_connect.sh"
    cmf_connect
fi

# ==============================================================================
# 1. Secret
# ==============================================================================
# The credentials live in a CMF Secret rather than inline in the catalog, so the
# catalog can be read back, exported and version-controlled without leaking the
# password. connectionSecretId in the catalog is the placeholder the mapping
# below resolves.
SECRET_FILE="${RESOURCE_DIR}/kafka-secret.json"
SECRET_ID="${FLINK_KAFKA_SECRET}"

# Built with python's json module rather than string interpolation: the JAAS
# config is a quoted string INSIDE a JSON string, and hand-escaping that is
# exactly the kind of thing that silently produces a broken catalog.
#
# The password is passed through the environment, never interpolated into the
# heredoc: a password containing a quote, backslash or $ would otherwise break
# the generated python, and would show up in a shell trace.
_SASL_USER="${SASL_USER}" _SASL_PW="${SASL_PASSWORD}" _USE_SASL="${USE_SASL}" \
_SASL_MECH="${CONFLUENT_SASL_MECHANISM}" _SECRET_ID="${SECRET_ID}" \
python3 - > "${SECRET_FILE}" <<'PY'
import json, os

data = {}
if os.environ["_USE_SASL"] == "true":
    # SCRAM and PLAIN take different login modules. json.dumps supplies the
    # quoting for the username and password, which is what JAAS expects.
    module = ("org.apache.kafka.common.security.scram.ScramLoginModule"
              if os.environ["_SASL_MECH"].startswith("SCRAM")
              else "org.apache.kafka.common.security.plain.PlainLoginModule")
    data["sasl.jaas.config"] = "{} required username={} password={};".format(
        module,
        json.dumps(os.environ["_SASL_USER"]),
        json.dumps(os.environ["_SASL_PW"]),
    )

print(json.dumps({
    "apiVersion": "cmf.confluent.io/v1",
    "kind": "Secret",
    "metadata": {"name": os.environ["_SECRET_ID"]},
    "spec": {"data": data},
}, indent=2))
PY
chmod 600 "${SECRET_FILE}"

# ==============================================================================
# 2. KafkaCatalog
# ==============================================================================
CATALOG_FILE="${RESOURCE_DIR}/kafka-catalog.json"

# The catalog carries ONLY the Schema Registry. As of CMF 2.4 the Kafka cluster
# is a separate KafkaDatabase resource, posted to the catalog's /databases
# sub-resource below; putting it in spec.kafkaClusters here is rejected outright:
#   Please do not configure kafkaClusters in the Catalog spec [...] This field
#   is no longer supported. Use the dedicated KafkaDatabase resource instead.
_CATALOG="${CATALOG}" _USE_SR="${USE_SR}" _SR_URL="${SR_URL}" \
python3 - > "${CATALOG_FILE}" <<'PY'
import json, os

spec = {}
if os.environ["_USE_SR"] == "true":
    # No connectionSecretId here: the Schema Registry installed by these
    # scripts is unauthenticated inside the cluster (the basic-auth sidecar
    # sits on the route, not the service). Pointing it at the Kafka secret
    # would hand it a sasl.jaas.config it cannot use. Add a secret with
    # basic.auth.user.info if you front SR with authentication.
    spec["srInstance"] = {
        "connectionConfig": {"schema.registry.url": os.environ["_SR_URL"]},
    }

print(json.dumps({
    "apiVersion": "cmf.confluent.io/v1",
    "kind": "KafkaCatalog",
    "metadata": {"name": os.environ["_CATALOG"]},
    "spec": spec,
}, indent=2))
PY

# ==============================================================================
# 2b. KafkaDatabase - the Kafka cluster itself
# ==============================================================================
DATABASE_FILE="${RESOURCE_DIR}/kafka-database.json"
_DATABASE="${DATABASE}" _BOOTSTRAP="${BOOTSTRAP}" _PROTOCOL="${SECURITY_PROTOCOL}" \
_ENVIRONMENT="${FLINK_ENVIRONMENT}" \
_USE_SASL="${USE_SASL}" _SASL_MECH="${CONFLUENT_SASL_MECHANISM}" _SECRET_ID="${SECRET_ID}" \
python3 - > "${DATABASE_FILE}" <<'PY'
import json, os

conn = {"bootstrap.servers": os.environ["_BOOTSTRAP"]}
if os.environ["_PROTOCOL"] != "PLAINTEXT":
    conn["security.protocol"] = os.environ["_PROTOCOL"]
if os.environ["_USE_SASL"] == "true":
    conn["sasl.mechanism"] = os.environ["_SASL_MECH"]

cluster = {"connectionConfig": conn}
# Only reference the secret when there is something in it. A database whose
# connectionSecretId names an empty secret fails to resolve at query time.
if os.environ["_USE_SASL"] == "true":
    cluster["connectionSecretId"] = os.environ["_SECRET_ID"]

print(json.dumps({
    "apiVersion": "cmf.confluent.io/v1",
    "kind": "KafkaDatabase",
    "metadata": {"name": os.environ["_DATABASE"]},
    "spec": {
        "kafkaCluster": cluster,
        # Environments allowed to run DDL (CREATE/DROP TABLE) against this
        # database - i.e. to create and delete Kafka topics through Flink SQL.
        # It defaults to EMPTY, and an environment missing from it can read
        # existing topics but nothing more:
        #   This environment does not have CREATE TABLE permissions for
        #   database <name>. Cannot create table <name>.<table>.
        # Reading is governed separately (status.environmentsWithAccess), so
        # leaving this empty produces a catalog that looks fully working right
        # up until the first CREATE TABLE.
        "ddlEnvironments": [os.environ["_ENVIRONMENT"]],
    },
}, indent=2))
PY

# ==============================================================================
# 3. EnvironmentSecretMapping
# ==============================================================================
MAPPING_FILE="${RESOURCE_DIR}/kafka-secret-mapping.json"
_SECRET_ID="${SECRET_ID}" python3 - > "${MAPPING_FILE}" <<'PY'
import json, os
print(json.dumps({
    "apiVersion": "cmf.confluent.io/v1",
    "kind": "EnvironmentSecretMapping",
    "metadata": {"name": os.environ["_SECRET_ID"]},
    "spec": {"secretName": os.environ["_SECRET_ID"]},
}, indent=2))
PY

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[INFO] --dry-run: the following resources would be created."
    echo ""
    echo "--- Secret (credentials redacted) ------------------------------------------"
    python3 -c "
import json
d = json.load(open('${SECRET_FILE}'))
d['spec']['data'] = {k: '***' for k in d['spec']['data']}
print(json.dumps(d, indent=2))"
    echo ""
    echo "--- KafkaCatalog -----------------------------------------------------------"
    cat "${CATALOG_FILE}"
    echo ""
    echo "--- KafkaDatabase ----------------------------------------------------------"
    cat "${DATABASE_FILE}"
    echo ""
    echo "--- EnvironmentSecretMapping -----------------------------------------------"
    cat "${MAPPING_FILE}"
    echo ""
    echo "[INFO] --dry-run complete. Nothing was created."
    exit 0
fi

# ==============================================================================
# Apply
# ==============================================================================
# An existing catalog is left alone unless --replace: recreating one that
# statements already reference breaks them, so it is not something to do
# implicitly on a re-run.
if confluent flink catalog describe "${CATALOG}" --url "${CMF_URL}" &>/dev/null; then
    if [[ "${REPLACE}" == "true" ]]; then
        echo "[INFO] Deleting the existing catalog '${CATALOG}' (--replace)..."
        # The databases go first: a catalog that still has one attached cannot
        # be deleted. They are a sub-resource with no CLI command, so this is
        # the REST API again.
        for _db in $(curl -s "${CMF_URL}/cmf/api/v1/catalogs/kafka/${CATALOG}/databases" 2>/dev/null \
                | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
    print(" ".join(i["metadata"]["name"] for i in d.get("items", [])))
except Exception:
    pass' 2>/dev/null); do
            curl -s -X DELETE "${CMF_URL}/cmf/api/v1/catalogs/kafka/${CATALOG}/databases/${_db}" -o /dev/null
            echo "[INFO]   removed database '${_db}'."
        done
        confluent flink catalog delete "${CATALOG}" --url "${CMF_URL}" --force >/dev/null
    elif [[ "${RUN_TEST}" == "true" ]]; then
        # --test is a verification request, not a creation request: skip
        # straight to exercising the catalog that is already there.
        echo "[INFO] Catalog '${CATALOG}' already exists - verifying it (--test)."
        CATALOG_EXISTS=true
    else
        echo "[INFO] Catalog '${CATALOG}' already exists - leaving it in place."
        echo "[INFO] Re-run with --replace to recreate it against these settings,"
        echo "[INFO] or with --test to verify the one that is there."
        echo ""
        echo "[INFO] Nothing to do."
        exit 0
    fi
fi

if [[ "${CATALOG_EXISTS}" == "true" ]]; then
    echo "[INFO] Skipping creation - the catalog and database are already registered."
else

# Only when there are credentials to hold. With --no-sasl the secret would be
# empty and nothing references it, so creating it is pure noise.
if [[ "${USE_SASL}" == "true" ]]; then
    echo "[INFO] Creating CMF secret '${SECRET_ID}'..."
    if confluent flink secret describe "${SECRET_ID}" --url "${CMF_URL}" &>/dev/null; then
        confluent flink secret update "${SECRET_FILE}" --url "${CMF_URL}" >/dev/null 2>&1 \
            || confluent flink secret create "${SECRET_FILE}" --url "${CMF_URL}" >/dev/null
    else
        confluent flink secret create "${SECRET_FILE}" --url "${CMF_URL}" >/dev/null
    fi

    echo "[INFO] Mapping the secret into environment '${FLINK_ENVIRONMENT}'..."
    confluent flink secret-mapping create "${MAPPING_FILE}" \
        --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" >/dev/null 2>&1 \
        || echo "[INFO] Secret mapping already present."
else
    echo "[INFO] --no-sasl: no credentials, so no CMF secret is created."
fi

echo "[INFO] Creating catalog '${CATALOG}'..."
confluent flink catalog create "${CATALOG_FILE}" --url "${CMF_URL}" >/dev/null

# The KafkaDatabase goes in over the REST API rather than the CLI: confluent
# CLI v4.74 has no "flink database" command, so the resource CMF 2.4 requires
# cannot be created any other way. Swap this for the CLI once it catches up.
echo "[INFO] Registering Kafka cluster as database '${DATABASE}'..."
_db_endpoint="${CMF_URL}/cmf/api/v1/catalogs/kafka/${CATALOG}/databases"
_db_response="$(curl -sS -X POST "${_db_endpoint}" \
    -H 'Content-Type: application/json' --data-binary "@${DATABASE_FILE}" \
    -w '\n%{http_code}' 2>&1)"
_db_code="${_db_response##*$'\n'}"
_db_body="${_db_response%$'\n'*}"

if [[ "${_db_code}" != "200" && "${_db_code}" != "201" ]]; then
    echo "[ERROR] Failed to register the database (HTTP ${_db_code}):" >&2
    echo "${_db_body}" | sed 's/^/[ERROR]   /' >&2
    echo "[ERROR] The catalog '${CATALOG}' exists but has no Kafka cluster attached." >&2
    echo "[ERROR] Fix the cause and re-run with --replace." >&2
    exit 1
fi

fi

echo ""
echo "[INFO] Kafka attached. Flink SQL now sees the topics as tables:"
echo ""
echo "    SELECT * FROM \`${CATALOG}\`.\`${DATABASE}\`.\`<topic>\`;"
echo ""

# ==============================================================================
# Verify
# ==============================================================================
# Creating a catalog only records the configuration; CMF does not connect to
# Kafka until a statement runs. --test forces that round trip, so a wrong
# bootstrap or a blocked NetworkPolicy surfaces now rather than in someone's
# first query.
if [[ "${RUN_TEST}" == "true" ]]; then
    echo "[INFO] Verifying by listing the tables in ${CATALOG}.${DATABASE}..."
    _stmt="flink-conn-test-$(date +%s)"
    if confluent flink statement create "${_stmt}" \
            --sql "SHOW TABLES IN \`${CATALOG}\`.\`${DATABASE}\`;" \
            --environment "${FLINK_ENVIRONMENT}" \
            --compute-pool "${FLINK_COMPUTE_POOL}" \
            --url "${CMF_URL}" --wait >/dev/null 2>&1; then
        echo "[INFO] Connection verified. Tables visible to Flink:"
        confluent flink statement describe "${_stmt}" --url "${CMF_URL}" \
            --environment "${FLINK_ENVIRONMENT}" 2>/dev/null | sed 's/^/  /' || true
        confluent flink statement delete "${_stmt}" --environment "${FLINK_ENVIRONMENT}" \
            --url "${CMF_URL}" --force &>/dev/null || true
    else
        echo "[WARN] The test statement did not complete. The catalog is registered, but"
        echo "[WARN] Flink could not reach Kafka. Check, in order:"
        echo "[WARN]   1. NetworkPolicy   re-run with --allow-network"
        echo "[WARN]   2. bootstrap       ${BOOTSTRAP} must resolve from '${NS}'"
        echo "[WARN]   3. credentials     '${SASL_USER}' must have DESCRIBE on the topics"
        echo "[WARN] Then:  confluent flink statement list --environment ${FLINK_ENVIRONMENT} --url <cmf>"
        confluent flink statement delete "${_stmt}" --environment "${FLINK_ENVIRONMENT}" \
            --url "${CMF_URL}" --force &>/dev/null || true
    fi
else
    echo "[INFO] The catalog is registered but not yet exercised - CMF does not"
    echo "[INFO] connect to Kafka until a statement runs. Verify with:"
    echo "[INFO]   ./x.4_flink_connect_kafka.sh --test"
    echo "[INFO]   ./x.3_flink_sample_job.sh"
fi
