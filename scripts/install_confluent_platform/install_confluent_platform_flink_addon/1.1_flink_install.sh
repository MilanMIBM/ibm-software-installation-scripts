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
# Confluent Platform for Apache Flink - install
# ------------------------------------------------------------------------------
# Installs, in order:
#   1. flink-kubernetes-operator   the Apache Flink Kubernetes Operator. Owns
#                                  the FlinkDeployment/FlinkSessionJob CRDs and
#                                  turns them into JobManager/TaskManager pods.
#   2. confluent-manager-for-apache-flink (CMF)
#                                  the REST control plane. Holds environments,
#                                  catalogs, compute pools and secrets, and
#                                  writes FlinkDeployments for the operator to
#                                  pick up. This is what "confluent flink" talks to.
#   3. a CMF environment           bound to this namespace, carrying the
#                                  checkpoint configuration every job inherits.
#   4. a default compute pool      the template for SQL statement clusters.
#
# Steps 3 and 4 need the confluent CLI; the Helm parts do not.
#
# This installs Flink ONLY. It does not touch, require or configure a Kafka
# cluster - attaching one is x.4_flink_connect_kafka.sh, so Flink works as an
# add-on to an existing Confluent installation and equally on its own.
#
# Safe to re-run: helm upgrade --install is idempotent, and the CMF resources
# are created only when absent.
#
# Usage:
#   ./1.1_flink_install.sh [--skip-operator] [--skip-cmf] [--skip-resources]
#        [--no-status] [--dry-run]
#
#   --skip-operator    leave the Flink operator alone (already installed, or
#                      managed via OperatorHub)
#   --skip-cmf         leave CMF alone
#   --skip-resources   install the charts but do not create the environment
#                      or compute pool
#   --no-status        skip the closing status report
#   --dry-run          render the charts and print the commands, change nothing
# ==============================================================================

SKIP_OPERATOR=false
SKIP_CMF=false
SKIP_RESOURCES=false
NO_STATUS=false
DRY_RUN=false

while (( $# > 0 )); do
    case "$1" in
        --skip-operator)  SKIP_OPERATOR=true; shift ;;
        --skip-cmf)       SKIP_CMF=true; shift ;;
        --skip-resources) SKIP_RESOURCES=true; shift ;;
        --no-status)      NO_STATUS=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '19,47p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_FLINK}"

if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[ERROR] Project '${NS}' does not exist. Run 1.0_flink_prep.sh first." >&2
    exit 1
fi
oc project "${NS}" >/dev/null

# Rendered manifests and generated resource files are collected here so a
# failure leaves them inspectable, exactly as 1.1_confluent_install.sh does.
MANIFEST_DIR="${SCRIPT_DIR}/flink_vars/rendered"
mkdir -p "${MANIFEST_DIR}"

echo "=============================================================================="
echo " Confluent Platform for Apache Flink -> project '${NS}'"
echo "=============================================================================="
echo "  operator chart  ${FLINK_OPERATOR_CHART_VERSION}"
echo "  CMF chart       ${FLINK_CMF_CHART_VERSION}"
echo "  state backend   ${FLINK_STATE_BACKEND}"
echo ""

# ==============================================================================
# 1. Flink Kubernetes Operator
# ==============================================================================
# podSecurityContext is nulled because the chart hard-codes runAsUser/runAsGroup
# 9999, which OpenShift's admission rejects outright. Nulling it lets the pod
# take the uid OpenShift assigns; combined with the anyuid SCC granted in prep,
# the container's own 9999 is honoured. This is the setting Confluent's
# OpenShift install page calls for, and without it the operator never schedules.
#
# watchNamespaces is set to this namespace only. The chart's default is
# cluster-wide, which would make the operator claim FlinkDeployments in every
# project on the cluster - unacceptable on a shared cluster, and it also
# requires cluster-scoped RBAC that a namespace admin may not have.
_operator_args=(
    "${FLINK_OPERATOR_RELEASE_NAME}"
    "${FLINK_HELM_REPO_NAME}/flink-kubernetes-operator"
    --namespace "${NS}"
    --version "${FLINK_OPERATOR_CHART_VERSION}"
    --set "podSecurityContext.runAsUser=null"
    --set "podSecurityContext.runAsGroup=null"
    --set "watchNamespaces={${NS}}"
    --set "operatorServiceAccount.create=false"
    --set "operatorServiceAccount.name=flink-operator"
    --set "jobServiceAccount.create=false"
    --set "jobServiceAccount.name=flink"
    --wait --timeout "${FLINK_ROLLOUT_TIMEOUT}"
)

# An air-gapped mirror only changes the registry prefix; the image path inside
# the chart stays the same.
if [[ -n "${FLINK_IMAGE_REGISTRY:-}" ]]; then
    _operator_args+=(--set "image.repository=${FLINK_IMAGE_REGISTRY}/cp-flink-kubernetes-operator")
fi
if [[ -n "${CONFLUENT_REGISTRY_USER:-}" ]]; then
    _operator_args+=(--set "imagePullSecrets[0].name=${CONFLUENT_PULL_SECRET}")
fi

if [[ "${SKIP_OPERATOR}" == "true" ]]; then
    echo "[INFO] --skip-operator: leaving the Flink operator alone."
elif [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY-RUN] helm upgrade --install ${_operator_args[*]}"
    helm template "${_operator_args[@]:0:2}" --namespace "${NS}" \
        --version "${FLINK_OPERATOR_CHART_VERSION}" \
        > "${MANIFEST_DIR}/flink-operator.yaml" 2>/dev/null || true
    echo "  [DRY-RUN] rendered to ${MANIFEST_DIR}/flink-operator.yaml"
else
    echo "[INFO] Installing the Flink Kubernetes Operator..."
    # Rendered before applying so the manifest is on disk even if helm fails.
    helm template "${_operator_args[@]}" > "${MANIFEST_DIR}/flink-operator.yaml" 2>/dev/null || true
    helm upgrade --install "${_operator_args[@]}"
    echo "[INFO] Flink operator installed (manifest: ${MANIFEST_DIR}/flink-operator.yaml)."
fi

# ==============================================================================
# 2. Confluent Manager for Apache Flink
# ==============================================================================
# securityContext: exactly ONE field is removed - runAsNonRoot. uid and fsGroup
# 1001 are deliberately KEPT. Both other combinations fail on OpenShift:
#
#   Chart default (uid 1001 + fsGroup 1001 + runAsNonRoot: true)
#     The cp-cmf image declares its user by NAME (appuser), not as a numeric
#     uid, so with runAsNonRoot set the kubelet cannot prove the user is not
#     root and never starts the container:
#       Error: container has runAsNonRoot and image has non-numeric user
#       (appuser), cannot verify user is non-root
#     The pod sits in CreateContainerConfigError with 0 restarts.
#
#   podSecurity.enabled=false (drop the block entirely)
#     The container starts, then dies in a crash loop. Without fsGroup the CMF
#     PVC stays root-owned while the container runs as appuser, so SQLite
#     cannot create its database on the volume mounted at /app/local:
#       java.sql.SQLException: opening db: 'local/cmf.db': Permission denied
#
# Keeping uid 1001 (permitted by the anyuid grant in 1.0_flink_prep.sh) with
# fsGroup 1001 (which makes the volume group-writable) satisfies both.
#
# encryption.enabled=false matches the quickstart. CMF encrypts the secrets it
# stores (Kafka credentials for catalogs) with a key from a Kubernetes secret
# when this is on; turning it on later re-encrypts, so it is left to a
# deliberate decision rather than defaulted here.
#
# database.type stays "local" - SQLite on the PVC below. That is the supported
# single-instance configuration; point cmf.database at PostgreSQL for HA.
_cmf_args=(
    "${FLINK_CMF_RELEASE_NAME}"
    "${FLINK_HELM_REPO_NAME}/confluent-manager-for-apache-flink"
    --namespace "${NS}"
    --version "${FLINK_CMF_CHART_VERSION}"
    --set "encryption.enabled=false"
    --set "podSecurity.securityContext.runAsNonRoot=null"
    --set "serviceAccount.create=false"
    --set "serviceAccount.name=confluent-manager-for-apache-flink"
    --set "persistence.create=true"
    --set "persistence.dataVolumeCapacity=${FLINK_CMF_STORAGE_SIZE}"
    --set "persistence.storageClassName=${FLINK_CMF_STORAGE_CLASS}"
    --set "resources.requests.cpu=${FLINK_CMF_CPU_REQUEST}"
    --set "resources.requests.memory=${FLINK_CMF_MEM_REQUEST}"
    --set "resources.limits.cpu=${FLINK_CMF_CPU_LIMIT}"
    --set "resources.limits.memory=${FLINK_CMF_MEM_LIMIT}"
    --set "watchNamespaces={${NS}}"
    --wait --timeout "${FLINK_ROLLOUT_TIMEOUT}"
)

if [[ -n "${FLINK_IMAGE_REGISTRY:-}" ]]; then
    _cmf_args+=(--set "image.repository=${FLINK_IMAGE_REGISTRY}")
fi
if [[ -n "${CONFLUENT_REGISTRY_USER:-}" ]]; then
    _cmf_args+=(--set "imagePullSecretRef=${CONFLUENT_PULL_SECRET}")
fi
if [[ -n "${FLINK_LICENSE_KEY:-}" ]]; then
    _cmf_args+=(--set "license.secretRef=${FLINK_LICENSE_SECRET}")
fi

if [[ "${SKIP_CMF}" == "true" ]]; then
    echo "[INFO] --skip-cmf: leaving CMF alone."
elif [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY-RUN] helm upgrade --install ${_cmf_args[*]}"
    helm template "${_cmf_args[@]}" > "${MANIFEST_DIR}/cmf.yaml" 2>/dev/null || true
    echo "  [DRY-RUN] rendered to ${MANIFEST_DIR}/cmf.yaml"
else
    echo "[INFO] Installing Confluent Manager for Apache Flink..."
    helm template "${_cmf_args[@]}" > "${MANIFEST_DIR}/cmf.yaml" 2>/dev/null || true
    helm upgrade --install "${_cmf_args[@]}"
    echo "[INFO] CMF installed (manifest: ${MANIFEST_DIR}/cmf.yaml)."

    # ------------------------------------------------------------------------
    # Relax the liveness probe.
    #
    # The chart ships a TCP liveness probe with timeoutSeconds: 1. CMF is a
    # Spring Boot app on a JVM, and a GC pause or a burst of reconciliation
    # work is enough to miss a 1-second TCP accept. The kubelet then SIGTERMs
    # a perfectly healthy process - the logs show a clean
    # SpringApplicationShutdownHook sequence and exit code 2, with no error,
    # which reads like a crash but is not one.
    #
    # The chart exposes no probe values, so this is a post-install patch.
    # 5s timeout with a 30s period keeps the probe useful while surviving a
    # normal pause.
    if oc get deployment confluent-manager-for-apache-flink -n "${NS}" &>/dev/null; then
        oc patch deployment confluent-manager-for-apache-flink -n "${NS}" --type=json -p='[
          {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/timeoutSeconds","value":5},
          {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/periodSeconds","value":30}
        ]' >/dev/null 2>&1 \
            && echo "[INFO] Liveness probe relaxed to 5s timeout / 30s period." \
            || echo "[WARN] Could not patch the CMF liveness probe - it may restart under load."
        oc rollout status deployment/confluent-manager-for-apache-flink \
            -n "${NS}" --timeout="${FLINK_ROLLOUT_TIMEOUT}" >/dev/null 2>&1 || true
    fi
fi

# ------------------------------------------------------------------------------
# Route to CMF
# ------------------------------------------------------------------------------
# Off by default and warned about, because the CMF REST API as this script
# installs it has NO authentication: anyone who can reach the route can create,
# modify and delete Flink jobs. In-cluster it is reachable only from this
# namespace; a route puts it on the public ingress.
#
# Once x.2_flink_add_auth_openshift.sh has put the route behind the OpenShift
# login, that script owns it: applying the plain route below would point it
# straight back at CMF, and the helm upgrade above may have dropped the sidecar.
# Its cookie secret is the marker that auth is enabled.
if [[ "${DRY_RUN}" != "true" ]] \
        && oc get secret "${FLINK_AUTH_SECRET:-cmf-oauth}" -n "${NS}" &>/dev/null; then
    echo "[INFO] OpenShift auth is enabled for the CMF route - re-applying it."
    "${SCRIPT_DIR}/x.2_flink_add_auth_openshift.sh" --no-status
elif [[ "${FLINK_CREATE_ROUTES}" == "true" && "${DRY_RUN}" != "true" ]]; then
    _host_line=""
    [[ -n "${CONFLUENT_ROUTE_DOMAIN:-}" ]] && _host_line="  host: cmf-${NS}.${CONFLUENT_ROUTE_DOMAIN}"
    oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: cmf
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: confluent-flink
spec:
${_host_line}
  to:
    kind: Service
    name: ${FLINK_CMF_SERVICE}
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
    echo "[WARN] Route 'cmf' created. The CMF REST API is UNAUTHENTICATED - anyone"
    echo "[WARN] who can reach this URL can create and delete Flink jobs. Run"
    echo "[WARN] ./x.2_flink_add_auth_openshift.sh to put it behind the OpenShift"
    echo "[WARN] login, or set FLINK_CREATE_ROUTES=false and use the port-forward"
    echo "[WARN] the x.* scripts open automatically."
elif [[ "${FLINK_CREATE_ROUTES}" != "true" ]]; then
    echo "[INFO] FLINK_CREATE_ROUTES=false - CMF stays in-cluster (the x.* scripts"
    echo "[INFO] port-forward to it on demand)."
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    echo ""
    echo "[INFO] --dry-run complete. Manifests rendered to ${MANIFEST_DIR}."
    exit 0
fi

# ==============================================================================
# 3-4. CMF resources: environment + compute pool
# ==============================================================================
if [[ "${SKIP_RESOURCES}" == "true" ]]; then
    echo "[INFO] --skip-resources: environment and compute pool not created."
    echo "[INFO] Install complete."
    exit 0
fi

if ! command -v confluent &>/dev/null; then
    echo "[WARN] The confluent CLI is not on PATH, so the environment and compute"
    echo "[WARN] pool were not created. Install it and re-run this script, or run"
    echo "[WARN] it with --skip-resources to silence this."
    exit 0
fi

# ------------------------------------------------------------------------------
# CMF connection: prefer the route, otherwise a port-forward for this run only.
# ------------------------------------------------------------------------------
source "${SCRIPT_DIR}/flink_cmf_connect.sh"
cmf_connect

# ------------------------------------------------------------------------------
# Environment
# ------------------------------------------------------------------------------
# An environment binds a name to a Kubernetes namespace and carries the Flink
# configuration that every application and statement in it inherits - which is
# where the checkpoint settings belong, so no individual job has to repeat them.
_defaults_file="${MANIFEST_DIR}/environment-defaults.json"

# Checkpointing is configured per state backend. These keys are plain Flink
# configuration, passed through by CMF to every FlinkDeployment it writes.
case "${FLINK_STATE_BACKEND}" in
    pvc)
        # The claim is mounted into every pod through a pod template. The
        # operator merges this template into the JobManager and TaskManager
        # pods it creates, which is the only way to get a volume into pods
        # this script never writes itself.
        #
        # Built in a single python pass with the values arriving through the
        # environment. Composing this from shell fragments does not work: a
        # JSON fragment interpolated into a python string literal terminates it
        # on its own first quote.
        _INTERVAL="${FLINK_CHECKPOINT_INTERVAL}" _SLOTS="${FLINK_TASK_SLOTS}" \
        _PVC="${FLINK_STATE_PVC_NAME}" \
        python3 - > "${_defaults_file}" <<'PY'
import json, os
print(json.dumps({"spec": {
    "flinkConfiguration": {
        "state.backend.type": "rocksdb",
        "state.checkpoints.dir": "file:///flink-state/checkpoints",
        "state.savepoints.dir": "file:///flink-state/savepoints",
        "execution.checkpointing.interval": os.environ["_INTERVAL"],
        "execution.checkpointing.mode": "EXACTLY_ONCE",
        "kubernetes.operator.savepoint.history.max.age": "72h",
        "taskmanager.numberOfTaskSlots": os.environ["_SLOTS"],
    },
    "podTemplate": {
        "apiVersion": "v1",
        "kind": "Pod",
        "spec": {
            "containers": [{
                "name": "flink-main-container",
                "volumeMounts": [{"name": "flink-state", "mountPath": "/flink-state"}],
            }],
            "volumes": [{
                "name": "flink-state",
                "persistentVolumeClaim": {"claimName": os.environ["_PVC"]},
            }],
        },
    },
}}, indent=2))
PY
        ;;
    s3)
        # s3p:// is the Presto filesystem shipped in the cp-flink image; it is
        # the one Confluent supports for checkpoints.
        _BUCKET="${FLINK_S3_BUCKET}" _INTERVAL="${FLINK_CHECKPOINT_INTERVAL}" \
        _ENDPOINT="${FLINK_S3_ENDPOINT}" _PATHSTYLE="${FLINK_S3_PATH_STYLE_ACCESS}" \
        _SLOTS="${FLINK_TASK_SLOTS}" _S3SECRET="${FLINK_S3_SECRET}" \
        python3 - > "${_defaults_file}" <<'PY'
import json, os
bucket = os.environ["_BUCKET"]
secret = os.environ["_S3SECRET"]
print(json.dumps({"spec": {
    "flinkConfiguration": {
        "state.backend.type": "rocksdb",
        "state.checkpoints.dir": "s3p://{}/checkpoints".format(bucket),
        "state.savepoints.dir": "s3p://{}/savepoints".format(bucket),
        "execution.checkpointing.interval": os.environ["_INTERVAL"],
        "execution.checkpointing.mode": "EXACTLY_ONCE",
        "s3.endpoint": os.environ["_ENDPOINT"],
        "s3.path.style.access": os.environ["_PATHSTYLE"],
        "taskmanager.numberOfTaskSlots": os.environ["_SLOTS"],
    },
    "podTemplate": {
        "apiVersion": "v1",
        "kind": "Pod",
        "spec": {
            "containers": [{
                "name": "flink-main-container",
                "env": [
                    {"name": "S3_ACCESS_KEY", "valueFrom": {"secretKeyRef": {
                        "name": secret, "key": "accesskey"}}},
                    {"name": "S3_SECRET_KEY", "valueFrom": {"secretKeyRef": {
                        "name": secret, "key": "secretkey"}}},
                ],
            }],
        },
    },
}}, indent=2))
PY
        ;;
    none)
        _SLOTS="${FLINK_TASK_SLOTS}" python3 - > "${_defaults_file}" <<'PY'
import json, os
print(json.dumps({"spec": {
    "flinkConfiguration": {
        "taskmanager.numberOfTaskSlots": os.environ["_SLOTS"],
    },
}}, indent=2))
PY
        ;;
esac

if confluent flink environment describe "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" &>/dev/null; then
    echo "[INFO] Environment '${FLINK_ENVIRONMENT}' already exists - updating its defaults."
    confluent flink environment update "${FLINK_ENVIRONMENT}" \
        --defaults "${_defaults_file}" --url "${CMF_URL}" >/dev/null
else
    echo "[INFO] Creating environment '${FLINK_ENVIRONMENT}' -> namespace ${NS}..."
    confluent flink environment create "${FLINK_ENVIRONMENT}" \
        --kubernetes-namespace "${NS}" \
        --defaults "${_defaults_file}" \
        --url "${CMF_URL}" >/dev/null
fi
echo "[INFO] Environment ready (defaults: ${_defaults_file})."

# ------------------------------------------------------------------------------
# Compute pool
# ------------------------------------------------------------------------------
# A compute pool is the template for the Flink cluster CMF starts to run a SQL
# statement. Applications submitted as JARs do not use it - they carry their own
# cluster spec - so this exists for the SQL path.
#
# The image MUST be a cp-flink-sql build; CMF validates it and rejects anything
# else. SHARED lets several statements land on one cluster, which is what makes
# a small pool usable for more than a single query.
_pool_file="${MANIFEST_DIR}/compute-pool.json"
_NAME="${FLINK_COMPUTE_POOL}" _VER="${FLINK_SQL_VERSION}" _IMAGE="${FLINK_SQL_IMAGE}" \
_SLOTS="${FLINK_TASK_SLOTS}" _JMCPU="${FLINK_JOBMANAGER_CPU}" _JMMEM="${FLINK_JOBMANAGER_MEMORY}" \
_TMCPU="${FLINK_TASKMANAGER_CPU}" _TMMEM="${FLINK_TASKMANAGER_MEMORY}" \
_INTERVAL="${FLINK_CHECKPOINT_INTERVAL}" _BACKEND="${FLINK_STATE_BACKEND}" \
_BUCKET="${FLINK_S3_BUCKET:-}" _PVC="${FLINK_STATE_PVC_NAME}" \
python3 - > "${_pool_file}" <<'PY'
import json, os

# Checkpointing has to be declared HERE, on the pool, not only on the
# environment: the environment's defaults apply to FlinkApplications, and a SQL
# statement does not inherit them. Without it every INSERT is refused up front:
#   Flink deployment requires checkpointing to be enabled for INSERT INTO
#   queries. Please set 'execution.checkpointing.interval' in the Flink
#   configuration of the Statement or ComputePool.
# SELECT still works, so a pool missing this looks healthy until the first write.
flink_config = {
    "taskmanager.numberOfTaskSlots": os.environ["_SLOTS"],
    "execution.checkpointing.interval": os.environ["_INTERVAL"],
    # Flink's exactly-once Kafka sink opens a transaction per checkpoint and
    # asks for a 1 hour timeout by default. Kafka refuses anything above its
    # own transaction.max.timeout.ms, which defaults to 15 minutes, and the
    # write task then fails in a restart loop:
    #   KafkaException: Unexpected error in InitProducerIdResponse; The
    #   transaction timeout is larger than the maximum value allowed by the
    #   broker (as configured by transaction.max.timeout.ms).
    # The statement just sits in PENDING while this repeats, with nothing in
    # CMF pointing at the cause.
    #
    # This CANNOT be fixed from the Flink side: CMF accepts no transaction
    # timeout among its table options, and neither
    # "properties.transaction.timeout.ms" nor
    # "table.exec.sink.transaction-timeout" has any effect as a pool-level
    # config (both were tried; the producer still asks for an hour). The
    # broker must therefore permit it - 1.1_confluent_install.sh sets
    # KAFKA_TRANSACTION_MAX_TIMEOUT_MS=3600000 for exactly this reason.
    # x.4_flink_connect_kafka.sh checks the live brokers and warns when the
    # cluster predates that change.
}
# Where the checkpoints go. Omitted for the "none" backend, which leaves the
# interval set (satisfying the check above) with Flink's in-memory default.
if os.environ["_BACKEND"] == "pvc":
    flink_config["state.checkpoints.dir"] = "file:///flink-state/checkpoints"
    flink_config["state.savepoints.dir"] = "file:///flink-state/savepoints"
elif os.environ["_BACKEND"] == "s3":
    bucket = os.environ["_BUCKET"]
    flink_config["state.checkpoints.dir"] = "s3p://{}/checkpoints".format(bucket)
    flink_config["state.savepoints.dir"] = "s3p://{}/savepoints".format(bucket)

cluster_spec = {
    "flinkVersion": os.environ["_VER"],
    "image": os.environ["_IMAGE"],
    "flinkConfiguration": flink_config,
    # cpu is a NUMBER in the CMF schema, not a string, so it is cast rather
    # than passed straight through.
    "jobManager": {"resource": {
        "cpu": float(os.environ["_JMCPU"]),
        "memory": os.environ["_JMMEM"],
    }},
    "taskManager": {"resource": {
        "cpu": float(os.environ["_TMCPU"]),
        "memory": os.environ["_TMMEM"],
    }},
}

# The checkpoint volume has to be mounted into the pods the pool starts, or the
# file:// paths above point at a container-local directory that vanishes with
# the pod - and every TaskManager writes to a different one.
#
# NOTE the shape: no apiVersion/kind here, unlike the environment defaults
# where they are required. The ComputePool schema rejects them:
#   'podTemplate' contains unexpected field(s): {apiVersion=v1, kind=Pod}
if os.environ["_BACKEND"] == "pvc":
    cluster_spec["podTemplate"] = {
        "spec": {
            "containers": [{
                "name": "flink-main-container",
                "volumeMounts": [{"name": "flink-state", "mountPath": "/flink-state"}],
            }],
            "volumes": [{
                "name": "flink-state",
                "persistentVolumeClaim": {"claimName": os.environ["_PVC"]},
            }],
        },
    }

print(json.dumps({
    "apiVersion": "cmf.confluent.io/v1",
    "kind": "ComputePool",
    "metadata": {"name": os.environ["_NAME"]},
    "spec": {
        "type": "SHARED",
        "clusterSpec": cluster_spec,
    },
}, indent=2))
PY

if confluent flink compute-pool describe "${FLINK_COMPUTE_POOL}" \
        --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" &>/dev/null; then
    echo "[INFO] Compute pool '${FLINK_COMPUTE_POOL}' already exists - leaving it."
    echo "[INFO] spec.type is immutable; delete the pool to change it."
else
    echo "[INFO] Creating compute pool '${FLINK_COMPUTE_POOL}'..."
    confluent flink compute-pool create "${_pool_file}" \
        --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" >/dev/null
    echo "[INFO] Compute pool created (spec: ${_pool_file})."

    # A SHARED pool starts a real Flink cluster, and statements are refused
    # until it is up:
    #   Cannot deploy statement on shared compute pool 'cp-pool' because it is
    #   not in RUNNING phase (current: PENDING).
    # Waiting here means the next script in the sequence just works.
    echo "[INFO] Waiting for the compute pool to reach RUNNING..."
    _waited=0
    while (( _waited < 300 )); do
        _pool_phase="$(confluent flink compute-pool describe "${FLINK_COMPUTE_POOL}" \
            --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" -o json 2>/dev/null \
            | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("status", {}).get("phase", ""))
except Exception:
    print("")' 2>/dev/null || true)"
        [[ "${_pool_phase}" == "RUNNING" ]] && break
        sleep 5; _waited=$(( _waited + 5 ))
    done
    if [[ "${_pool_phase}" == "RUNNING" ]]; then
        echo "[INFO] Compute pool RUNNING after ${_waited}s."
    else
        echo "[WARN] Compute pool is '${_pool_phase:-unknown}' after ${_waited}s."
        echo "[WARN] Statements will be refused until it reaches RUNNING. Check:"
        echo "[WARN]   oc get pods -n ${NS} -l app=${FLINK_COMPUTE_POOL}"
    fi
fi

# ==============================================================================
# Status
# ==============================================================================
if [[ "${NO_STATUS}" != "true" ]]; then
    echo ""
    "${SCRIPT_DIR}/1.2_flink_status.sh" || true
fi

echo ""
echo "[INFO] Install complete."
echo ""
if oc get statefulset broker -n "${PROJECT_CONFLUENT_SERVER}" &>/dev/null; then
    echo "[INFO] Next: ./x.4_flink_connect_kafka.sh   attach the Confluent cluster"
    echo "[INFO]       ./x.3_flink_sample_job.sh      run a sample job end to end"
else
    echo "[INFO] Next: ./x.4_flink_connect_kafka.sh --bootstrap <host:port>"
    echo "[INFO]       attaches a Kafka cluster so Flink SQL can read and write topics."
fi
