#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ==============================================================================
# Confluent Platform for Apache Flink - template the sizing block
# ------------------------------------------------------------------------------
# Adds (or rewrites) the Flink block in cp4d_config/confluent_vars.sh. Mirrors
# 0_confluent_prepare_template_config.sh one directory up: a managed block that
# is overwritten on every run, with flags that beat the size preset.
#
#   ./0_flink_prepare_template_config.sh                    # defaults to small
#   ./0_flink_prepare_template_config.sh --size medium
#   ./0_flink_prepare_template_config.sh --size large --dry-run
#
# Deliberately does NOT source the config or contact the cluster: it is a pure
# file-rewriting step that runs before 1.0_flink_prep.sh.
#
# Why the variables land in confluent_vars.sh rather than a file of their own:
# source_env_setup.sh sources every cp4d_config/*.sh, and the Flink scripts need
# the Kafka values (bootstrap, SASL secret, namespace) from that same file to
# wire the catalog. Keeping them together means one ENV_TARGET and one backup.
# ==============================================================================

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/confluent_vars.sh"

usage() {
    cat <<'USAGE'
Usage: 0_flink_prepare_template_config.sh [--size <xsmall|small|medium|large>] [overrides]

Sizes (--size defaults to "small" when omitted). These size the CMF control
plane and the DEFAULT compute pool; individual Flink jobs request their own
TaskManager resources on top of that.

  xsmall   CMF 0.5/1Gi, pool JM 0.5cpu/1Gi + TM 0.5cpu/1Gi, 1 TM slot.
           Demo only - a single small job at a time.
  small    CMF 1/2Gi, pool JM 0.5cpu/1Gi + TM 1cpu/2Gi, 2 slots. Default.
  medium   CMF 2/4Gi, pool JM 1cpu/2Gi + TM 2cpu/4Gi, 4 slots.
  large    CMF 4/8Gi, pool JM 2cpu/4Gi + TM 4cpu/8Gi, 8 slots.

Overrides (any of these beat the size preset):
  --cmf-cpu-request V       --cmf-cpu-limit V
  --cmf-mem-request V       --cmf-mem-limit V
  --jobmanager-cpu V        --jobmanager-memory V     (e.g. 2048m)
  --taskmanager-cpu V       --taskmanager-memory V
  --task-slots N            slots per TaskManager
  --storage SIZE            CMF metadata volume size (e.g. 20Gi)
  --storage-class NAME      FLINK_CMF_STORAGE_CLASS
  --namespace NAME          project Flink is installed into
  --dry-run                 print the resulting block without writing
  -h, --help                this message

Namespace note: by default Flink installs into its OWN project
(<confluent project>-flink) so it can be added and removed without touching the
Kafka cluster. Point --namespace at the Confluent project to co-locate them.

CMF holds its metadata (environments, catalogs, secrets) in a SQLite file on a
PersistentVolume. Losing that volume loses the registered environments, not the
running jobs - the FlinkDeployments live in Kubernetes and keep running.
USAGE
}

# ------------------------------------------------------------------------------
# Size presets
# ------------------------------------------------------------------------------
# The compute-pool numbers are per-pool DEFAULTS, applied to every Flink cluster
# CMF starts for a SQL statement. A pool is one JobManager plus N TaskManagers,
# so the memory figure is what each of those pods requests - not a total budget.
apply_size() {
    case "$1" in
        xsmall)
            CMF_CPU_REQ="500m"; CMF_MEM_REQ="1Gi"; CMF_CPU_LIM="1"; CMF_MEM_LIM="2Gi"
            JM_CPU="0.5"; JM_MEM="1024m"; TM_CPU="0.5"; TM_MEM="1024m"; SLOTS=1
            CMF_STORAGE="10Gi"
            ;;
        small)
            CMF_CPU_REQ="1"; CMF_MEM_REQ="2Gi"; CMF_CPU_LIM="2"; CMF_MEM_LIM="4Gi"
            JM_CPU="0.5"; JM_MEM="1024m"; TM_CPU="1.0"; TM_MEM="2048m"; SLOTS=2
            CMF_STORAGE="10Gi"
            ;;
        medium)
            CMF_CPU_REQ="2"; CMF_MEM_REQ="4Gi"; CMF_CPU_LIM="4"; CMF_MEM_LIM="8Gi"
            JM_CPU="1.0"; JM_MEM="2048m"; TM_CPU="2.0"; TM_MEM="4096m"; SLOTS=4
            CMF_STORAGE="20Gi"
            ;;
        large)
            CMF_CPU_REQ="4"; CMF_MEM_REQ="8Gi"; CMF_CPU_LIM="8"; CMF_MEM_LIM="16Gi"
            JM_CPU="2.0"; JM_MEM="4096m"; TM_CPU="4.0"; TM_MEM="8192m"; SLOTS=8
            CMF_STORAGE="50Gi"
            ;;
        *)
            echo "[ERROR] Unknown size '$1'. Expected one of: xsmall, small, medium, large." >&2
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
SIZE="small"
DRY_RUN=false
STORAGE_CLASS_OVERRIDE=""
NAMESPACE_OVERRIDE=""
typeset -A OVERRIDE

_need_value() {
    [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }
}

while (( $# > 0 )); do
    case "$1" in
        --size)               _need_value "$1" "${2:-}"; SIZE="$2"; shift 2 ;;
        --cmf-cpu-request)    _need_value "$1" "${2:-}"; OVERRIDE[CMF_CPU_REQ]="$2"; shift 2 ;;
        --cmf-cpu-limit)      _need_value "$1" "${2:-}"; OVERRIDE[CMF_CPU_LIM]="$2"; shift 2 ;;
        --cmf-mem-request)    _need_value "$1" "${2:-}"; OVERRIDE[CMF_MEM_REQ]="$2"; shift 2 ;;
        --cmf-mem-limit)      _need_value "$1" "${2:-}"; OVERRIDE[CMF_MEM_LIM]="$2"; shift 2 ;;
        --jobmanager-cpu)     _need_value "$1" "${2:-}"; OVERRIDE[JM_CPU]="$2"; shift 2 ;;
        --jobmanager-memory)  _need_value "$1" "${2:-}"; OVERRIDE[JM_MEM]="$2"; shift 2 ;;
        --taskmanager-cpu)    _need_value "$1" "${2:-}"; OVERRIDE[TM_CPU]="$2"; shift 2 ;;
        --taskmanager-memory) _need_value "$1" "${2:-}"; OVERRIDE[TM_MEM]="$2"; shift 2 ;;
        --task-slots)         _need_value "$1" "${2:-}"; OVERRIDE[SLOTS]="$2"; shift 2 ;;
        --storage)            _need_value "$1" "${2:-}"; OVERRIDE[CMF_STORAGE]="$2"; shift 2 ;;
        --storage-class)      _need_value "$1" "${2:-}"; STORAGE_CLASS_OVERRIDE="$2"; shift 2 ;;
        --namespace)          _need_value "$1" "${2:-}"; NAMESPACE_OVERRIDE="$2"; shift 2 ;;
        --dry-run)            DRY_RUN=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

apply_size "${SIZE}"
for _k in "${(@k)OVERRIDE}"; do
    eval "${_k}=\"\${OVERRIDE[${_k}]}\""
done

if [[ ! -f "${VARS_FILE}" ]]; then
    echo "[ERROR] ${VARS_FILE} not found. Run the Confluent scripts' own" >&2
    echo "[ERROR] 0_confluent_prepare_template_config.sh first." >&2
    exit 1
fi

# The storage class is written as a reference to STG_CLASS_BLOCK unless the
# caller names one, so it keeps tracking the cluster's block storage the way
# CONFLUENT_STORAGE_CLASS does. Flink's CMF volume is RWO, same as the brokers'.
if [[ -n "${STORAGE_CLASS_OVERRIDE}" ]]; then
    STORAGE_CLASS_LITERAL="${STORAGE_CLASS_OVERRIDE}"
else
    STORAGE_CLASS_LITERAL="\${STG_CLASS_BLOCK}"
fi

# The namespace defaults to the Confluent project with a -flink suffix, written
# as a reference so renaming the Confluent project carries Flink along with it.
if [[ -n "${NAMESPACE_OVERRIDE}" ]]; then
    NAMESPACE_LITERAL="${NAMESPACE_OVERRIDE}"
else
    NAMESPACE_LITERAL="\${PROJECT_CONFLUENT_SERVER}-flink"
fi

# ------------------------------------------------------------------------------
# Build the managed block
# ------------------------------------------------------------------------------
BEGIN_MARKER="# >>> confluent flink (managed by flink_install/0_flink_prepare_template_config.sh) >>>"
END_MARKER="# <<< confluent flink (managed by flink_install/0_flink_prepare_template_config.sh) <<<"

BLOCK="$(cat <<EOF
${BEGIN_MARKER}
# Size: ${SIZE} - written $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Re-run flink_install/0_flink_prepare_template_config.sh to change these;
# edits inside this block are overwritten. Everything Flink-related that is NOT
# sizing (versions, toggles, names) lives outside the block and is preserved.

# ---- Project -----------------------------------------------------------------
# Flink installs into its own project by default so it can be added to, and
# removed from, an existing Confluent installation without touching it.
export PROJECT_CONFLUENT_FLINK="${NAMESPACE_LITERAL}"

# ---- CMF control plane sizing ------------------------------------------------
export FLINK_CMF_CPU_REQUEST="${CMF_CPU_REQ}"
export FLINK_CMF_MEM_REQUEST="${CMF_MEM_REQ}"
export FLINK_CMF_CPU_LIMIT="${CMF_CPU_LIM}"
export FLINK_CMF_MEM_LIMIT="${CMF_MEM_LIM}"

# ---- CMF metadata storage ----------------------------------------------------
# Holds the SQLite database of environments, catalogs, secrets and pools.
export FLINK_CMF_STORAGE_CLASS="${STORAGE_CLASS_LITERAL}"
export FLINK_CMF_STORAGE_SIZE="${CMF_STORAGE}"

# ---- Default compute pool ----------------------------------------------------
# Applied to every Flink cluster CMF starts for a SQL statement. Per-pod, not a
# total: a pool is one JobManager plus as many TaskManagers as parallelism needs.
export FLINK_JOBMANAGER_CPU="${JM_CPU}"
export FLINK_JOBMANAGER_MEMORY="${JM_MEM}"
export FLINK_TASKMANAGER_CPU="${TM_CPU}"
export FLINK_TASKMANAGER_MEMORY="${TM_MEM}"
export FLINK_TASK_SLOTS="${SLOTS}"
${END_MARKER}
EOF
)"

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[INFO] --dry-run: the following block would be written to ${VARS_FILE##*/}"
    echo ""
    printf '%s\n' "${BLOCK}"
    exit 0
fi

# ------------------------------------------------------------------------------
# Splice the block in, replacing any previous one
# ------------------------------------------------------------------------------
cp "${VARS_FILE}" "${VARS_FILE}.bak"

BLOCK_FILE="$(mktemp)"
printf '%s\n' "${BLOCK}" > "${BLOCK_FILE}"

python3 - "${VARS_FILE}" "${BLOCK_FILE}" "${BEGIN_MARKER}" "${END_MARKER}" <<'PY'
import re, sys

vars_path, block_path, begin, end = sys.argv[1:5]
text = open(vars_path).read()
block = open(block_path).read().rstrip("\n")

pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
if pattern.search(text):
    # A lambda, not the string itself: a replacement containing backslashes or
    # \1-style sequences would otherwise be interpreted as a group reference.
    text = pattern.sub(lambda _: block, text, count=1)
    open(vars_path, "w").write(text)
    print("replaced")
else:
    # Appended at the very end, deliberately AFTER the sizing block: the Flink
    # defaults reference PROJECT_CONFLUENT_SERVER and STG_CLASS_BLOCK, so they
    # have to be expanded once those are already defined.
    text = text.rstrip("\n") + "\n\n" + block + "\n"
    open(vars_path, "w").write(text)
    print("appended")
PY

rm -f "${BLOCK_FILE}"

# ------------------------------------------------------------------------------
# The non-sizing Flink settings: written ONCE, on the first run, outside the
# managed block so later edits survive. Same treatment the Confluent component
# toggles get - the block above owns only what --size controls.
# ------------------------------------------------------------------------------
if ! grep -q '^export FLINK_CMF_CHART_VERSION=' "${VARS_FILE}"; then
    cat >> "${VARS_FILE}" <<'STATIC'

# ------------------------------------------------------------------------------
# Confluent Platform for Apache Flink - added by flink_install/0_flink_prepare_template_config.sh
# ------------------------------------------------------------------------------
# NOT managed on re-runs - edit these freely, they will be preserved.
#
# Flink is delivered as two Helm charts rather than the plain Deployments the
# rest of this stack uses, because that is the only distribution Confluent
# publishes for it:
#
#   flink-kubernetes-operator          the Apache Flink Kubernetes Operator,
#                                      owns the FlinkDeployment CRDs and starts
#                                      the JobManager/TaskManager pods.
#   confluent-manager-for-apache-flink CMF - the REST control plane that the
#                                      "confluent flink" CLI talks to. It holds
#                                      environments, catalogs and compute pools
#                                      and translates them into FlinkDeployments.
#
# Both come from https://packages.confluent.io/helm.

# ---- Helm ---------------------------------------------------------------------
export FLINK_HELM_REPO_NAME="confluentinc"
export FLINK_HELM_REPO_URL="https://packages.confluent.io/helm"
# Pinned exactly rather than with a "~x.y.z" range: a range silently upgrades
# the control plane on the next run, which is not what an install script should
# do. Bump these by hand after reading the CMF upgrade notes.
export FLINK_CMF_CHART_VERSION="2.4.2"
export FLINK_OPERATOR_CHART_VERSION="1.150.3"
export FLINK_CMF_RELEASE_NAME="cmf"
export FLINK_OPERATOR_RELEASE_NAME="cp-flink-kubernetes-operator"

# ---- Images -------------------------------------------------------------------
# Override for an air-gapped mirror. Empty = whatever the chart ships with.
export FLINK_IMAGE_REGISTRY=""
# Runtime image for JAR applications (confluent flink application create).
export FLINK_APPLICATION_IMAGE="confluentinc/cp-flink:2.0.2-cp3"
# Runtime image for SQL statements. MUST be a cp-flink-sql image - CMF rejects
# a compute pool that names anything else. Shared pools need cp7 or newer.
export FLINK_SQL_IMAGE="confluentinc/cp-flink-sql:1.19-cp11"
# Flink API version the images implement. cp-flink 2.x = v2_0, cp-flink-sql
# 1.19 = v1_19. These are not interchangeable: the operator validates them.
export FLINK_APPLICATION_VERSION="v2_0"
export FLINK_SQL_VERSION="v1_19"

# ---- cert-manager -------------------------------------------------------------
# The Flink operator's admission webhook needs cert-manager. 1.0_flink_prep.sh
# installs it only if it is absent, and never removes it - other operators on
# the cluster are likely to depend on it too.
export FLINK_CERT_MANAGER_VERSION="v1.18.2"
export FLINK_CERT_MANAGER_NAMESPACE="cert-manager"

# ---- CMF endpoint -------------------------------------------------------------
# The chart's service is cmf-service:80 -> container 8080.
export FLINK_CMF_SERVICE="cmf-service"
export FLINK_CMF_PORT="80"
# Expose CMF as an OpenShift route. The CMF REST API is UNAUTHENTICATED as the
# chart ships it (authentication.type is unset), so the route is created only
# when this is true, and 1.1 warns when it is.
export FLINK_CREATE_ROUTES="true"
# Local port used by "oc port-forward" when no route exists. The x.* scripts
# prefer the route and fall back to this.
export FLINK_CMF_LOCAL_PORT="8080"

# ---- Environment / pool / catalog names ---------------------------------------
# A CMF "environment" maps to one Kubernetes namespace and carries the defaults
# every application in it inherits.
export FLINK_ENVIRONMENT="cp-env"
export FLINK_COMPUTE_POOL="cp-pool"
# The catalog is what makes the Kafka cluster visible to Flink SQL as a set of
# tables. Created by x.4_flink_connect_kafka.sh, not by the install.
export FLINK_CATALOG="cp-kafka"
# Database name the Kafka cluster appears under inside that catalog.
export FLINK_KAFKA_DATABASE="cp-cluster"
# CMF secret holding the SASL/SR credentials the catalog connects with.
export FLINK_KAFKA_SECRET="cp-kafka-credentials"

# ---- Job checkpoint / savepoint storage ---------------------------------------
# Flink needs durable shared storage for checkpoints; without it a job cannot
# recover and savepoints are impossible. Three options:
#
#   pvc  - an RWX PersistentVolumeClaim mounted into every Flink pod. Needs a
#          ReadWriteMany storage class (STG_CLASS_FILE). This is the default
#          because it works on any cluster with file storage and no cloud
#          credentials. Not suitable for large state or high throughput.
#   s3   - an S3-compatible bucket. Set the FLINK_S3_* values below.
#   none - no checkpointing. Jobs run but cannot recover from failure and
#          "confluent flink application stop --savepoint" will not work.
export FLINK_STATE_BACKEND="pvc"
export FLINK_STATE_STORAGE_CLASS="${STG_CLASS_FILE}"
export FLINK_STATE_STORAGE_SIZE="50Gi"
export FLINK_STATE_PVC_NAME="flink-state"
# Checkpoint interval. Shorter = less replay after a failure, more I/O.
export FLINK_CHECKPOINT_INTERVAL="60s"

# S3 checkpoint storage (FLINK_STATE_BACKEND=s3). The bucket must already exist.
export FLINK_S3_BUCKET=""
export FLINK_S3_ENDPOINT=""
export FLINK_S3_ACCESS_KEY=""
export FLINK_S3_SECRET_KEY=""
export FLINK_S3_PATH_STYLE_ACCESS="true"
export FLINK_S3_SECRET="flink-s3-credentials"

# ---- Confluent licence --------------------------------------------------------
# CMF is a commercial component. Empty = the built-in 30-day trial. This falls
# back to CONFLUENT_LICENSE_KEY so one licence covers the whole platform.
export FLINK_LICENSE_KEY="${CONFLUENT_LICENSE_KEY:-}"
export FLINK_LICENSE_SECRET="flink-license"

# ---- Waits --------------------------------------------------------------------
export FLINK_ROLLOUT_TIMEOUT="600s"
STATIC
    echo "[INFO] Wrote the static Flink settings (versions, names, storage backend)."
fi

# ------------------------------------------------------------------------------
# Verify the rewritten file is still valid shell before leaving it in place.
# ------------------------------------------------------------------------------
if ! zsh -n "${VARS_FILE}" 2>/dev/null; then
    echo "[ERROR] Rewritten ${VARS_FILE##*/} is not valid shell - restoring backup." >&2
    mv "${VARS_FILE}.bak" "${VARS_FILE}"
    exit 1
fi

echo ""
echo "[INFO] Applied Flink size '${SIZE}' to ${VARS_FILE##*/} (backup: ${VARS_FILE##*/}.bak)"
printf '  %-30s %s\n' \
    "CMF cpu/mem request"  "${CMF_CPU_REQ} / ${CMF_MEM_REQ}" \
    "CMF cpu/mem limit"    "${CMF_CPU_LIM} / ${CMF_MEM_LIM}" \
    "CMF metadata volume"  "${CMF_STORAGE}" \
    "JobManager cpu/mem"   "${JM_CPU} / ${JM_MEM}" \
    "TaskManager cpu/mem"  "${TM_CPU} / ${TM_MEM}" \
    "task slots"           "${SLOTS}"
echo ""
echo "[INFO] Next: flink_install/1.0_flink_prep.sh"
