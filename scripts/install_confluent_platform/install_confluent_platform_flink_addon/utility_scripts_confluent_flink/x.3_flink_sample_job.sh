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
# Confluent Platform for Apache Flink - sample jobs
# ------------------------------------------------------------------------------
# Runs a job end to end, which is the fastest way to prove the installation
# actually works rather than merely being present.
#
# Two kinds, because CMF runs two quite different things:
#
#   --application  a packaged JAR. Submits the upstream Flink example
#                  (a self-contained number cruncher) as a FlinkApplication.
#                  Needs NO Kafka - it is the right smoke test for a standalone
#                  Flink install. This is the default.
#
#   --sql          a Flink SQL statement running on the compute pool. Needs a
#                  catalog, so run x.4_flink_connect_kafka.sh first. Reads and
#                  writes real Kafka topics, so it proves the whole chain.
#
# Usage:
#   ./x.3_flink_sample_job.sh [--application|--sql] [options]
#
#   --application        submit the JAR example (default)
#   --sql                run the Kafka SQL example
#   --name NAME          name for the job (default: flink-sample)
#   --topic NAME         topic the SQL example writes to (default: flink-sample-out)
#   --delete             delete the sample job instead of creating it
#   --logs               follow the job's logs after submitting
#   --dry-run            print the resource, submit nothing
# ==============================================================================

MODE="application"
JOB_NAME="flink-sample"
TOPIC="flink-sample-out"
DELETE=false
FOLLOW_LOGS=false
DRY_RUN=false

_need_value() {
    [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }
}

while (( $# > 0 )); do
    case "$1" in
        --application) MODE="application"; shift ;;
        --sql)         MODE="sql"; shift ;;
        --name)        _need_value "$1" "${2:-}"; JOB_NAME="$2"; shift 2 ;;
        --topic)       _need_value "$1" "${2:-}"; TOPIC="$2"; shift 2 ;;
        --delete)      DELETE=true; shift ;;
        --logs)        FOLLOW_LOGS=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '19,42p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

if ! command -v confluent &>/dev/null; then
    echo "[ERROR] The confluent CLI is required for this script." >&2
    exit 1
fi

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_FLINK}"
# --dry-run only renders the job spec, so it stays useful before Flink exists.
if ! oc get namespace "${NS}" &>/dev/null; then
    if [[ "${DRY_RUN}" != "true" ]]; then
        echo "[ERROR] Project '${NS}' does not exist. Run the install first." >&2
        exit 1
    fi
    echo "[WARN] Project '${NS}' does not exist - rendering anyway (--dry-run)."
fi

RESOURCE_DIR="${SCRIPT_DIR}/flink_vars/rendered"
mkdir -p "${RESOURCE_DIR}"

if [[ "${DRY_RUN}" != "true" ]]; then
    source "${SCRIPT_DIR}/flink_cmf_connect.sh"
    cmf_connect
fi

# ==============================================================================
# Delete
# ==============================================================================
if [[ "${DELETE}" == "true" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[INFO] --dry-run: would delete the ${MODE} job '${JOB_NAME}' from"
        echo "[INFO] environment '${FLINK_ENVIRONMENT}'. Nothing was deleted."
        exit 0
    fi
    if [[ "${MODE}" == "sql" ]]; then
        echo "[INFO] Deleting statement '${JOB_NAME}'..."
        confluent flink statement delete "${JOB_NAME}" \
            --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" --force 2>/dev/null \
            || confluent flink statement delete "${JOB_NAME}" \
                --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}"
    else
        echo "[INFO] Deleting application '${JOB_NAME}'..."
        confluent flink application delete "${JOB_NAME}" \
            --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" --force 2>/dev/null \
            || confluent flink application delete "${JOB_NAME}" \
                --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}"
    fi
    echo "[INFO] Deleted."
    exit 0
fi

# ==============================================================================
# JAR application
# ==============================================================================
if [[ "${MODE}" == "application" ]]; then
    APP_FILE="${RESOURCE_DIR}/sample-application.json"

    # local:///opt/flink/examples/... is a path INSIDE the cp-flink image, not
    # on the machine running this script. The StateMachine example ships in
    # every Flink image and generates its own input, so it needs no external
    # system at all - which is exactly what a smoke test should need.
    #
    # serviceAccount must be 'flink': that is the account the operator chart
    # creates and grants the RBAC a JobManager needs to create TaskManager pods.
    # The default 'default' account cannot, and the job fails with a Forbidden
    # that points nowhere useful.
    _NAME="${JOB_NAME}" _IMAGE="${FLINK_APPLICATION_IMAGE}" \
    _VER="${FLINK_APPLICATION_VERSION}" _SLOTS="${FLINK_TASK_SLOTS}" \
    _JMCPU="${FLINK_JOBMANAGER_CPU}" _JMMEM="${FLINK_JOBMANAGER_MEMORY}" \
    _TMCPU="${FLINK_TASKMANAGER_CPU}" _TMMEM="${FLINK_TASKMANAGER_MEMORY}" \
    python3 - > "${APP_FILE}" <<'PY'
import json, os
print(json.dumps({
    "apiVersion": "cmf.confluent.io/v1",
    "kind": "FlinkApplication",
    "metadata": {"name": os.environ["_NAME"]},
    "spec": {
        "image": os.environ["_IMAGE"],
        "flinkVersion": os.environ["_VER"],
        "flinkConfiguration": {
            "taskmanager.numberOfTaskSlots": os.environ["_SLOTS"],
        },
        "serviceAccount": "flink",
        "jobManager": {"resource": {
            "cpu": float(os.environ["_JMCPU"]),
            "memory": os.environ["_JMMEM"],
        }},
        "taskManager": {"resource": {
            "cpu": float(os.environ["_TMCPU"]),
            "memory": os.environ["_TMMEM"],
        }},
        "job": {
            "jarURI": "local:///opt/flink/examples/streaming/StateMachineExample.jar",
            "parallelism": 1,
            # stateless: the job has no prior state to restore, which is the
            # only correct value for a first submission. savepoint/last-state
            # here would make the operator look for a checkpoint that does not
            # exist yet.
            "upgradeMode": "stateless",
            "state": "running",
        },
    },
}, indent=2))
PY

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[INFO] --dry-run: would submit this FlinkApplication."
        cat "${APP_FILE}"
        exit 0
    fi

    if confluent flink application describe "${JOB_NAME}" \
            --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" &>/dev/null; then
        echo "[INFO] Application '${JOB_NAME}' already exists - updating it."
    fi

    echo "[INFO] Submitting application '${JOB_NAME}'..."
    confluent flink application create "${APP_FILE}" \
        --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" >/dev/null
    echo "[INFO] Submitted (spec: ${APP_FILE})."

    # The CLI returns as soon as CMF accepts the resource; the operator then
    # has to create the JobManager, which has to start, which has to bring up
    # TaskManagers. Waiting here is what turns "accepted" into "actually ran".
    echo "[INFO] Waiting for the job to start..."
    _waited=0
    _state=""
    while (( _waited < 300 )); do
        _state="$(confluent flink application describe "${JOB_NAME}" \
            --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" -o json 2>/dev/null \
            | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
    s = d.get("status", {})
    print(s.get("jobStatus", {}).get("state") or s.get("state") or "")
except Exception:
    print("")' 2>/dev/null || true)"
        [[ "${_state}" == "RUNNING" ]] && break
        if [[ "${_state}" == "FAILED" || "${_state}" == "RECONCILING_FAILED" ]]; then
            echo "[ERROR] The job reached state ${_state}." >&2
            break
        fi
        sleep 5; _waited=$(( _waited + 5 ))
    done

    if [[ "${_state}" == "RUNNING" ]]; then
        echo "[INFO] Job is RUNNING after ${_waited}s."
    else
        echo "[WARN] Job state after ${_waited}s: ${_state:-unknown}."
        echo "[WARN] Inspect it with:"
        echo "[WARN]   oc get flinkdeployment ${JOB_NAME} -n ${NS} -o yaml"
        echo "[WARN]   oc logs -n ${NS} -l app=${JOB_NAME} --tail=100"
    fi

    echo ""
    echo "[INFO] Flink web UI for this job:"
    echo "[INFO]   confluent flink application web-ui-forward ${JOB_NAME} \\"
    echo "[INFO]       --environment ${FLINK_ENVIRONMENT} --port 8090 --url ${CMF_URL}"
    echo "[INFO]   then open http://localhost:8090"

# ==============================================================================
# SQL statement
# ==============================================================================
else
    # A catalog is what makes Kafka topics visible as tables, so without one
    # there is nothing for this example to write to. Skipped under --dry-run,
    # which never connects to CMF and so has no URL to ask.
    if [[ "${DRY_RUN}" != "true" ]] \
            && ! confluent flink catalog describe "${FLINK_CATALOG}" --url "${CMF_URL}" &>/dev/null; then
        echo "[ERROR] Catalog '${FLINK_CATALOG}' does not exist, so there is no Kafka" >&2
        echo "[ERROR] cluster for this example to use. Attach one first:" >&2
        echo "[ERROR]   ./x.4_flink_connect_kafka.sh" >&2
        exit 1
    fi

    # Two statements: one creates the table (which creates the Kafka topic),
    # the other fills it from the built-in datagen source. Splitting them means
    # a failure says which half broke.
    # DISTRIBUTED INTO n BUCKETS sets the topic's partition count. The older
    # 'kafka.partitions' WITH option is rejected outright by CMF 2.4:
    #   The 'kafka.partitions' option is not supported anymore. Use the
    #   DISTRIBUTED INTO n BUCKETS clause instead.
    #
    # Replication factor is NOT settable here - 'kafka.replication.factor' is
    # not in CMF's supported option list and the statement fails if it is
    # given. The topic takes the broker's default.replication.factor, which
    # the Confluent install already sets from CONFLUENT_REPLICATION_FACTOR.
    _create_sql="CREATE TABLE IF NOT EXISTS \`${FLINK_CATALOG}\`.\`${FLINK_KAFKA_DATABASE}\`.\`${TOPIC}\` (
  id BIGINT,
  ts TIMESTAMP(3),
  value_str STRING
) DISTRIBUTED INTO ${CONFLUENT_PARTITIONS:-3} BUCKETS
WITH (
  'value.format' = 'json-registry'
);"

    # Rows come from Apache Flink's built-in sequence generator. Two things
    # this deliberately avoids:
    #
    #   datagen(rows_per_second => 5) as a TABLE function is Confluent Cloud
    #   only - in CMF it fails with "No match found for function signature".
    #
    #   A CREATE TEMPORARY TABLE ... ; INSERT INTO ... pair is two statements,
    #   and CMF accepts exactly one per submission:
    #     Statement compilation failed: only single statement supported
    #
    # So the rows are written with a plain VALUES list. It is a bounded job:
    # it inserts these rows, reaches COMPLETED and stops, which is what makes
    # it a usable smoke test rather than something to remember to shut down.
    #
    # INSERT INTO also requires checkpointing to be configured on the compute
    # pool; 1.1_flink_install.sh sets that. Without it CMF refuses the
    # statement at validation time with "Flink deployment requires
    # checkpointing to be enabled for INSERT INTO queries".
    _insert_sql="INSERT INTO \`${FLINK_CATALOG}\`.\`${FLINK_KAFKA_DATABASE}\`.\`${TOPIC}\`
VALUES
  (1, CURRENT_TIMESTAMP, 'sample-1'),
  (2, CURRENT_TIMESTAMP, 'sample-2'),
  (3, CURRENT_TIMESTAMP, 'sample-3'),
  (4, CURRENT_TIMESTAMP, 'sample-4'),
  (5, CURRENT_TIMESTAMP, 'sample-5');"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[INFO] --dry-run: would run these statements."
        echo ""
        echo "--- create table -----------------------------------------------------------"
        echo "${_create_sql}"
        echo ""
        echo "--- insert -----------------------------------------------------------------"
        echo "${_insert_sql}"
        exit 0
    fi

    # A SHARED pool refuses statements until its Flink cluster is up. It can be
    # PENDING for a minute after creation, or after the pool pod is restarted.
    _pool_phase="$(confluent flink compute-pool describe "${FLINK_COMPUTE_POOL}" \
        --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" -o json 2>/dev/null \
        | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("status", {}).get("phase", ""))
except Exception:
    print("")' 2>/dev/null || true)"
    if [[ "${_pool_phase}" != "RUNNING" ]]; then
        echo "[INFO] Compute pool is ${_pool_phase:-unknown}; waiting for RUNNING..."
        _waited=0
        while (( _waited < 300 )) && [[ "${_pool_phase}" != "RUNNING" ]]; do
            sleep 5; _waited=$(( _waited + 5 ))
            _pool_phase="$(confluent flink compute-pool describe "${FLINK_COMPUTE_POOL}" \
                --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" -o json 2>/dev/null \
                | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("status", {}).get("phase", ""))
except Exception:
    print("")' 2>/dev/null || true)"
        done
        if [[ "${_pool_phase}" != "RUNNING" ]]; then
            echo "[ERROR] Compute pool '${FLINK_COMPUTE_POOL}' is still ${_pool_phase:-unknown}" >&2
            echo "[ERROR] after ${_waited}s. Statements cannot run. Check:" >&2
            echo "[ERROR]   oc get pods -n ${NS} -l app=${FLINK_COMPUTE_POOL}" >&2
            exit 1
        fi
        echo "[INFO] Compute pool RUNNING after ${_waited}s."
    fi

    echo "[INFO] Creating table '${TOPIC}' (this also creates the Kafka topic)..."
    # An old attempt left in FAILED blocks the name; names are unique per env.
    confluent flink statement delete "${JOB_NAME}-ddl" --environment "${FLINK_ENVIRONMENT}" \
        --url "${CMF_URL}" --force &>/dev/null || true

    confluent flink statement create "${JOB_NAME}-ddl" \
        --sql "${_create_sql}" \
        --environment "${FLINK_ENVIRONMENT}" \
        --compute-pool "${FLINK_COMPUTE_POOL}" \
        --url "${CMF_URL}" --wait 2>&1 | sed 's/^/  /' || true

    # The CLI's exit status is NOT trustworthy here for two reasons: piping to
    # sed replaces it with sed's, and --wait returns 0 for a statement that
    # reached a terminal FAILED phase. Ask CMF what actually happened.
    _ddl_phase="$(confluent flink statement describe "${JOB_NAME}-ddl" \
        --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" -o json 2>/dev/null \
        | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("status", {}).get("phase", ""))
except Exception:
    print("")' 2>/dev/null || true)"

    if [[ "${_ddl_phase}" != "COMPLETED" ]]; then
        echo "[ERROR] CREATE TABLE did not complete (phase: ${_ddl_phase:-unknown})." >&2
        confluent flink statement describe "${JOB_NAME}-ddl" \
            --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" 2>/dev/null \
            | grep -i 'detail' | sed 's/^/[ERROR]   /' >&2 || true
        echo "[ERROR] Common causes:" >&2
        echo "[ERROR]   - the environment lacks DDL rights on the database. Re-run" >&2
        echo "[ERROR]     ./x.4_flink_connect_kafka.sh --replace to set ddlEnvironments." >&2
        echo "[ERROR]   - the catalog cannot reach Kafka. Check with" >&2
        echo "[ERROR]     ./x.4_flink_connect_kafka.sh --test" >&2
        exit 1
    fi
    echo "[INFO] Table created."

    echo "[INFO] Starting the INSERT job '${JOB_NAME}'..."
    # Statement names are unique per environment and a FAILED one still holds
    # its name, so a re-run after any failure hits
    #   Statement 'flink-sample' already exists in environment 'cp-env'.
    confluent flink statement delete "${JOB_NAME}" --environment "${FLINK_ENVIRONMENT}" \
        --url "${CMF_URL}" --force &>/dev/null || true

    confluent flink statement create "${JOB_NAME}" \
        --sql "${_insert_sql}" \
        --environment "${FLINK_ENVIRONMENT}" \
        --compute-pool "${FLINK_COMPUTE_POOL}" \
        --url "${CMF_URL}" 2>&1 | sed 's/^/  /'

    echo ""
    echo "[INFO] Statement submitted. It writes 5 rows to topic '${TOPIC}' and"
    echo "[INFO] then completes - it is a bounded job, not a running stream."
    echo "[INFO] Check it:"
    echo "[INFO]   confluent flink statement describe ${JOB_NAME} --environment ${FLINK_ENVIRONMENT} --url ${CMF_URL}"
    echo "[INFO] Read the topic back:"
    echo "[INFO]   oc exec -n ${PROJECT_CONFLUENT_SERVER} broker-0 -- \\"
    echo "[INFO]     kafka-console-consumer --bootstrap-server localhost:${CONFLUENT_BROKER_INTERNAL_PORT} \\"
    echo "[INFO]     --topic ${TOPIC} --from-beginning --max-messages 5"
    echo "[INFO] Stop it:"
    echo "[INFO]   ./x.3_flink_sample_job.sh --sql --delete"
fi

# ------------------------------------------------------------------------------
# Logs
# ------------------------------------------------------------------------------
if [[ "${FOLLOW_LOGS}" == "true" ]]; then
    echo ""
    echo "[INFO] Following job logs (Ctrl-C to stop)..."
    oc logs -n "${NS}" -l "app=${JOB_NAME}" --tail=50 -f 2>/dev/null || \
        echo "[WARN] No pods matched app=${JOB_NAME} - the job may not have started yet."
fi
