#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${SCRIPT_DIR}/../../../src/helpers/common_helpers.sh"
source "${SCRIPT_DIR}/../../../src/helpers/version_resolver.sh"

# ==============================================================================
# Confluent Platform for Apache Flink - template the sizing block
# ------------------------------------------------------------------------------
# Adds (or rewrites) the Flink block in configs/confluent_platform_config/confluent_vars.sh. Mirrors
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
# Operator mode (plan .claude/plans/confluent-operator-install-mode/): the Flink
# operator source follows the platform's CONFLUENT_DEPLOY_MODE (missing = operator)
# unless --operator-source names one. A source other than helm (cp-fko through
# OLM) adds the Flink operator settings once and, for a first run, pins CMF 2.5.0
# with its cp-fko channel. The helm source writes exactly what it always did.
#
# Why the variables land in confluent_vars.sh rather than a file of their own:
# source_env_setup.sh sources every configs/*/*.sh, and the Flink scripts need
# the Kafka values (bootstrap, SASL secret, namespace) from that same file to
# wire the catalog. Keeping them together means one ENV_TARGET and one backup.
# ==============================================================================

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"

# Multi-cluster: --target-cluster NAME writes into that cluster's folder; flat configs/ stays the default.
if [[ -f "${REPO_ROOT}/src/helpers/multi_cluster_generator_args.sh" ]]; then
    source "${REPO_ROOT}/src/helpers/multi_cluster_generator_args.sh"
    # Flat files this generator reads or rewrites: one pointing at a cluster with its own folder sends the write there.
    MCM_GENERATOR_URL_FILES=(confluent_platform_config/confluent_vars.sh)
    mcm_generator_setup "$@" || exit 1
    set -- "${reply[@]}"
else
    mcm_generator_register() { :; }
fi
VARS_FILE="${CONFIGS_ROOT:-${REPO_ROOT}/configs}/confluent_platform_config/confluent_vars.sh"

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
  --target-cluster NAME     Use configs/clusters/NAME (mode on, or a cluster with its folder)
  -h, --help                this message

Flink operator mode:
  --operator-source SRC     helm | olm | existing (FLINK_OPERATOR_SOURCE). Without
                            it the Flink scripts follow the platform mode: olm when
                            CONFLUENT_DEPLOY_MODE is operator (or missing), else helm.
  --cmf-resource-mode MODE  cli | cfk (FLINK_CMF_RESOURCE_MODE). Without it: cfk
                            when the operator source is not helm, else cli.

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
OPERATOR_SOURCE_FLAG=""
CMF_RESOURCE_MODE_FLAG=""

while (( $# > 0 )); do
    case "$1" in
        --size)               h_need_value "$1" "${2:-}"; SIZE="$2"; shift 2 ;;
        --cmf-cpu-request)    h_need_value "$1" "${2:-}"; OVERRIDE[CMF_CPU_REQ]="$2"; shift 2 ;;
        --cmf-cpu-limit)      h_need_value "$1" "${2:-}"; OVERRIDE[CMF_CPU_LIM]="$2"; shift 2 ;;
        --cmf-mem-request)    h_need_value "$1" "${2:-}"; OVERRIDE[CMF_MEM_REQ]="$2"; shift 2 ;;
        --cmf-mem-limit)      h_need_value "$1" "${2:-}"; OVERRIDE[CMF_MEM_LIM]="$2"; shift 2 ;;
        --jobmanager-cpu)     h_need_value "$1" "${2:-}"; OVERRIDE[JM_CPU]="$2"; shift 2 ;;
        --jobmanager-memory)  h_need_value "$1" "${2:-}"; OVERRIDE[JM_MEM]="$2"; shift 2 ;;
        --taskmanager-cpu)    h_need_value "$1" "${2:-}"; OVERRIDE[TM_CPU]="$2"; shift 2 ;;
        --taskmanager-memory) h_need_value "$1" "${2:-}"; OVERRIDE[TM_MEM]="$2"; shift 2 ;;
        --task-slots)         h_need_value "$1" "${2:-}"; OVERRIDE[SLOTS]="$2"; shift 2 ;;
        --storage)            h_need_value "$1" "${2:-}"; OVERRIDE[CMF_STORAGE]="$2"; shift 2 ;;
        --storage-class)      h_need_value "$1" "${2:-}"; STORAGE_CLASS_OVERRIDE="$2"; shift 2 ;;
        --namespace)          h_need_value "$1" "${2:-}"; NAMESPACE_OVERRIDE="$2"; shift 2 ;;
        --dry-run)            DRY_RUN=true; shift ;;
        --operator-source)    h_need_value "$1" "${2:-}"; OPERATOR_SOURCE_FLAG="${(L)2}"; shift 2 ;;
        --cmf-resource-mode)  h_need_value "$1" "${2:-}"; CMF_RESOURCE_MODE_FLAG="${(L)2}"; shift 2 ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

if [[ -n "${OPERATOR_SOURCE_FLAG}" && "${OPERATOR_SOURCE_FLAG}" != (helm|olm|existing) ]]; then
    echo "[ERROR] --operator-source expects helm, olm or existing, got '${OPERATOR_SOURCE_FLAG}'." >&2
    exit 1
fi
if [[ -n "${CMF_RESOURCE_MODE_FLAG}" && "${CMF_RESOURCE_MODE_FLAG}" != (cli|cfk) ]]; then
    echo "[ERROR] --cmf-resource-mode expects cli or cfk, got '${CMF_RESOURCE_MODE_FLAG}'." >&2
    exit 1
fi

apply_size "${SIZE}"
for _k in "${(@k)OVERRIDE}"; do
    eval "${_k}=\"\${OVERRIDE[${_k}]}\""
done

if [[ ! -f "${VARS_FILE}" ]]; then
    echo "[ERROR] ${VARS_FILE} not found. Run the Confluent scripts' own" >&2
    echo "[ERROR] 0_confluent_prepare_template_config.sh first." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Flink operator source (contract §2.1 / §5.2): --operator-source, else the
# file's FLINK_OPERATOR_SOURCE, else the platform mode (olm in operator mode).
# The platform mode is read from the file by grep; a missing line means operator.
# ------------------------------------------------------------------------------
# Value of `export NAME=...` as the shell reads it when sourced: "double" or
# 'single' quoted, or bare up to the first blank; the last line wins. Empty when absent.
_file_value() {
    local line
    line="$(grep -E "^export $1=" "${VARS_FILE}" 2>/dev/null | tail -1)" || true
    line="${line#export $1=}"
    case "${line}" in
        \"*) line="${line#\"}"; line="${line%%\"*}" ;;
        \'*) line="${line#\'}"; line="${line%%\'*}" ;;
        *)   line="${line%%[[:space:]]*}" ;;
    esac
    print -r -- "${line}"
}
_file_has()   { grep -qE "^export $1=" "${VARS_FILE}" 2>/dev/null; }

_PLATFORM_MODE_MISSING=false
if _file_has CONFLUENT_DEPLOY_MODE; then
    _pm="$(_file_value CONFLUENT_DEPLOY_MODE)"
    _pm="${(L)_pm//[[:space:]]/}"
    [[ "${_pm}" == scripts ]] && PLATFORM_MODE=scripts || PLATFORM_MODE=operator
else
    PLATFORM_MODE=operator
    _PLATFORM_MODE_MISSING=true
fi
_fs="${OPERATOR_SOURCE_FLAG:-$(_file_value FLINK_OPERATOR_SOURCE)}"
_fs="${(L)_fs//[[:space:]]/}"
case "${_fs}" in
    helm|olm|existing) FLINK_SOURCE="${_fs}" ;;
    "")                [[ "${PLATFORM_MODE}" == operator ]] && FLINK_SOURCE=olm || FLINK_SOURCE=helm ;;
    *)                 FLINK_SOURCE=olm
                       echo "[WARN] FLINK_OPERATOR_SOURCE='${_fs}' is not helm|olm|existing - using olm" >&2 ;;
esac
_cm="${CMF_RESOURCE_MODE_FLAG:-$(_file_value FLINK_CMF_RESOURCE_MODE)}"
_cm="${(L)_cm//[[:space:]]/}"
case "${_cm}" in
    cli|cfk) CMF_RESOURCE_MODE="${_cm}" ;;
    *)       [[ "${FLINK_SOURCE}" != helm ]] && CMF_RESOURCE_MODE=cfk || CMF_RESOURCE_MODE=cli ;;
esac
unset _pm _fs _cm
if [[ "${FLINK_SOURCE}" != helm ]] && $_PLATFORM_MODE_MISSING && [[ -z "${OPERATOR_SOURCE_FLAG}" ]]; then
    echo "[WARN] ${VARS_FILE##*/} has no CONFLUENT_DEPLOY_MODE - treating the platform as operator mode, so Flink uses cp-fko through OLM. Pass --operator-source helm (or set CONFLUENT_DEPLOY_MODE=\"scripts\") to keep the Helm operator." >&2
fi
_cat_or() { vr_catalog "$1" 2>/dev/null || print -r -- "$2"; }

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
# Re-run install_confluent_platform_flink_addon/0_flink_prepare_template_config.sh to change these;
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

if [[ "${DRY_RUN}" == "true" ]] && [[ "${FLINK_SOURCE}" != helm || -n "${OPERATOR_SOURCE_FLAG}${CMF_RESOURCE_MODE_FLAG}" ]]; then
    echo "[INFO] --dry-run: Flink operator source ${FLINK_SOURCE}, CMF resource mode ${CMF_RESOURCE_MODE}."
    if [[ "${FLINK_SOURCE}" != helm ]] && ! _file_has FLINK_OLM_PACKAGE; then
        echo "[INFO] --dry-run: would add the Flink operator settings (FLINK_OLM_*, FLINK_CFK_NAMESPACE, ...) to ${VARS_FILE##*/}."
    fi
    if [[ "${FLINK_SOURCE}" != helm ]] && ! _file_has FLINK_CMF_CHART_VERSION; then
        echo "[INFO] --dry-run: the static Flink settings would pin CMF $(_cat_or confluent/operator/cmf_chart 2.5.0) (operator mode)."
    fi
fi
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
_STATIC_EXISTED=true
if ! grep -q '^export FLINK_CMF_CHART_VERSION=' "${VARS_FILE}"; then
    _STATIC_EXISTED=false
    # @@<path>@@ marks a value from src/helpers/version_catalog.json, filled in below.
    _static="$(cat <<'STATIC'

# ------------------------------------------------------------------------------
# Confluent Platform for Apache Flink - added by install_confluent_platform_flink_addon/0_flink_prepare_template_config.sh
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
export FLINK_CMF_CHART_VERSION="@@flink/cmf_chart_version@@"
export FLINK_OPERATOR_CHART_VERSION="@@flink/operator_chart_version@@"
export FLINK_CMF_RELEASE_NAME="cmf"
export FLINK_OPERATOR_RELEASE_NAME="cp-flink-kubernetes-operator"

# ---- Images -------------------------------------------------------------------
# Override for an air-gapped mirror. Empty = whatever the chart ships with.
export FLINK_IMAGE_REGISTRY=""
# Runtime image for JAR applications (confluent flink application create).
export FLINK_APPLICATION_IMAGE="@@flink/application_image@@"
# Runtime image for SQL statements. MUST be a cp-flink-sql image - CMF rejects
# a compute pool that names anything else. Shared pools need cp7 or newer.
export FLINK_SQL_IMAGE="@@flink/sql_image@@"
# Flink API version the images implement. cp-flink 2.x = v2_0, cp-flink-sql
# 1.19 = v1_19. These are not interchangeable: the operator validates them.
export FLINK_APPLICATION_VERSION="v2_0"
export FLINK_SQL_VERSION="v1_19"

# ---- cert-manager -------------------------------------------------------------
# The Flink operator's admission webhook needs cert-manager. 1.0_flink_prep.sh
# installs it only if it is absent, and never removes it - other operators on
# the cluster are likely to depend on it too.
export FLINK_CERT_MANAGER_VERSION="@@flink/cert_manager_version@@"
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
)"
    # Operator source (not helm): CMF 2.5.0 and its SQL image (contract §2.5).
    if [[ "${FLINK_SOURCE}" != helm ]]; then
        _key=flink/cmf_chart_version
        _static="${_static//@@${_key}@@/$(_cat_or confluent/operator/cmf_chart 2.5.0)}"
        _key=flink/sql_image
        _static="${_static//@@${_key}@@/$(_cat_or confluent/operator/flink_sql_image confluentinc/cp-flink-sql:1.19-cmf2.5-cp1)}"
    fi
    for _key in flink/cmf_chart_version flink/operator_chart_version flink/application_image \
                flink/sql_image flink/cert_manager_version; do
        _static="${_static//@@${_key}@@/$(vr_catalog "${_key}")}"
    done
    print -r -- "${_static}" >> "${VARS_FILE}"
    unset _static _key
    echo "[INFO] Wrote the static Flink settings (versions, names, storage backend)."
fi

# ------------------------------------------------------------------------------
# Flink operator settings (contract §2.5): written once when the operator source
# is not helm, outside the managed block, so edits survive. FLINK_OPERATOR_SOURCE
# and FLINK_CMF_RESOURCE_MODE are written only when given as flags: without them
# the Flink scripts follow the platform mode (plan 15.1 item 4).
# ------------------------------------------------------------------------------
# CONTRACT-DEVIATION: the guard is FLINK_OLM_PACKAGE, not FLINK_OPERATOR_SOURCE -
# FLINK_OPERATOR_SOURCE stays unwritten when it follows the platform mode, so a
# guard on it would append the block again on every run.
# Written in place, so the file keeps its mode (it holds OCP_PASSWORD) and a
# symlinked config stays a symlink.
_file_set() {   # <name> <value>: rewrite every export NAME=... line in place
    python3 - "${VARS_FILE}" "$1" "$2" <<'PYSET'
import re, sys
path, name, value = sys.argv[1:4]
text = open(path).read()
text = re.compile(r"^export " + re.escape(name) + r"=.*$", re.M).sub(lambda _: f'export {name}="{value}"', text)
with open(path, "w") as fh:
    fh.write(text)
PYSET
}
typeset -A _FLINK_MODE_SET
[[ -n "${OPERATOR_SOURCE_FLAG}" ]] && _FLINK_MODE_SET[FLINK_OPERATOR_SOURCE]="${OPERATOR_SOURCE_FLAG}"
[[ -n "${CMF_RESOURCE_MODE_FLAG}" ]] && _FLINK_MODE_SET[FLINK_CMF_RESOURCE_MODE]="${CMF_RESOURCE_MODE_FLAG}"

if [[ "${FLINK_SOURCE}" != helm ]] && ! _file_has FLINK_OLM_PACKAGE; then
    _cmf_version="$(_file_value FLINK_CMF_CHART_VERSION)"
    _fko_channel="" _fko_csv=""
    if _fko="$(_vr_python "${REPO_ROOT}/src/helpers/confluent_operator_config.py" fko-for-cmf "${_cmf_version}" 2>/dev/null)" \
            && [[ -n "${_fko}" ]]; then
        read -r _fko_channel _fko_csv <<< "${_fko}"
    else
        echo "[WARN] FLINK_CMF_CHART_VERSION=${_cmf_version} has no cp-fko pairing in the version catalog - FLINK_OLM_CHANNEL and FLINK_OLM_STARTING_CSV are written empty; set them by hand." >&2
    fi
    _olm_block="$(cat <<EOF

# ------------------------------------------------------------------------------
# Confluent Flink operator mode - added by install_confluent_platform_flink_addon/$(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ------------------------------------------------------------------------------
# Read when the Flink operator source is not helm: cp-fko (Confluent's Flink
# Kubernetes Operator) through OLM in PROJECT_CONFLUENT_FLINK. NOT managed on
# re-runs - edit freely.
EOF
)"
    for _k in FLINK_OPERATOR_SOURCE FLINK_CMF_RESOURCE_MODE; do
        [[ -n "${_FLINK_MODE_SET[$_k]:-}" ]] && _olm_block+=$'\n'"export ${_k}=\"${_FLINK_MODE_SET[$_k]}\""
    done
    _olm_block+=$'\n'"$(cat <<EOF
# CMF/FKO lock: the channel must be the cp-fko line FLINK_CMF_CHART_VERSION needs.
export FLINK_OLM_PACKAGE="cp-fko"
export FLINK_OLM_SUBSCRIPTION_NAME="cp-fko"
export FLINK_OLM_CHANNEL="${_fko_channel}"
export FLINK_OLM_STARTING_CSV="${_fko_csv}"
export FLINK_OLM_CATALOG_SOURCE="certified-operators"
export FLINK_OLM_CATALOG_SOURCE_NAMESPACE="openshift-marketplace"
# Manual = the scripts approve only the InstallPlan they asked for.
export FLINK_OLM_INSTALL_PLAN_APPROVAL="Manual"
# CMF resources as CFK custom resources (CMFRestClass, FlinkEnvironment) live here.
export FLINK_CFK_NAMESPACE="\${PROJECT_CONFLUENT_FLINK}"
export FLINK_CMF_RESTCLASS_NAME="default"
# Seconds to wait for a FlinkEnvironment to go after CMF deleted it.
export FLINK_ENVIRONMENT_DELETE_WAIT="60"
EOF
)"
    print -r -- "${_olm_block}" >> "${VARS_FILE}"
    echo "[INFO] Wrote the Flink operator settings (cp-fko ${_fko_channel:-<channel unset>} through OLM)."
    _FLINK_MODE_SET=()
    unset _olm_block _fko _cmf_version
fi

# Flags for settings outside a fresh block: rewrite the line, else append it.
for _k in FLINK_OPERATOR_SOURCE FLINK_CMF_RESOURCE_MODE; do
    [[ -n "${_FLINK_MODE_SET[$_k]:-}" ]] || continue
    if _file_has "${_k}"; then
        _old="$(_file_value "${_k}")"
        [[ "${_old}" == "${_FLINK_MODE_SET[$_k]}" ]] && continue
        _file_set "${_k}" "${_FLINK_MODE_SET[$_k]}"
        echo "[INFO] ${_k}: ${_old} -> ${_FLINK_MODE_SET[$_k]}"
    else
        printf '\nexport %s="%s"\n' "${_k}" "${_FLINK_MODE_SET[$_k]}" >> "${VARS_FILE}"
        echo "[INFO] ${_k}=${_FLINK_MODE_SET[$_k]} saved to ${VARS_FILE##*/}."
    fi
done

if [[ "${FLINK_SOURCE}" != helm ]] && $_STATIC_EXISTED && [[ "$(_file_value FLINK_CMF_CHART_VERSION)" == 2.4.* ]]; then
    echo "[WARN] CMF 2.4.x pairs with cp-fko stable-v1.15; a cluster whose cp-fko is 1.16 refuses it (plan C10) - consider FLINK_CMF_CHART_VERSION=2.5.0" >&2
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
echo "[INFO] Next: install_confluent_platform_flink_addon/1.0_flink_prep.sh"
mcm_generator_register "${VARS_FILE}"
