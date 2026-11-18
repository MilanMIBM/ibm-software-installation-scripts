#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${SCRIPT_DIR}/../../src/helpers/common_helpers.sh"
source "${SCRIPT_DIR}/../../src/helpers/version_resolver.sh"

# ==============================================================================
# Confluent Platform - template the sizing block in confluent_vars.sh
# ------------------------------------------------------------------------------
# Applies a t-shirt size to configs/confluent_platform_config/confluent_vars.sh, adding the sizing
# variables if absent and overwriting them if already present. Individual values
# can be overridden with flags, which always win over the size preset.
#
#   ./0_confluent_prepare_template_config.sh                  # defaults to small
#   ./0_confluent_prepare_template_config.sh --size medium --partitions 12
#   ./0_confluent_prepare_template_config.sh --size xsmall --regenerate-cluster-id
#   ./0_confluent_prepare_template_config.sh --size large --dry-run
#   ./0_confluent_prepare_template_config.sh --deploy-mode scripts
#
# Deploy mode (CONFLUENT_DEPLOY_MODE): a new file gets "operator" (Confluent for
# Kubernetes through OLM) unless --deploy-mode scripts is given; an existing file
# keeps its value, and switching it needs --switch-deploy-mode (a fresh install,
# plan O19). Operator mode also writes the operator settings and a second managed
# block (KRaft controllers, operator-mode storage). Scripts mode writes nothing
# else new. Plan: .claude/plans/confluent-operator-install-mode/.
#
# Deliberately does NOT source the config or contact the cluster: it is a pure
# file-rewriting step that runs before 1.0_confluent_prep.sh.
# ==============================================================================

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"

# Multi-cluster: --target-cluster NAME writes into that cluster's folder; flat configs/ stays the default.
if [[ -f "${REPO_ROOT}/src/helpers/multi_cluster_generator_args.sh" ]]; then
    source "${REPO_ROOT}/src/helpers/multi_cluster_generator_args.sh"
    # Flat files this generator reads or rewrites: one pointing at a cluster with its own folder sends the write there.
    MCM_GENERATOR_URL_FILES=(confluent_platform_config/confluent_vars.sh cp4d_config/cpd_vars.sh)
    mcm_generator_setup "$@" || exit 1
    set -- "${reply[@]}"
else
    mcm_generator_register() { :; }
fi
VARS_FILE="${CONFIGS_ROOT:-${REPO_ROOT}/configs}/confluent_platform_config/confluent_vars.sh"

usage() {
    cat <<'USAGE'
Usage: 0_confluent_prepare_template_config.sh [--size <xsmall|small|medium|large>] [overrides]

Sizes (--size defaults to "small" when omitted):
  xsmall   1 broker,  RF=1  - demo / cp-all-in-one parity. NOT fault tolerant.
  small    3 brokers, RF=3  - smallest production-usable shape, ~5-10 topics.
           This is the default.
  medium   3 brokers, RF=3  - heavier throughput, more partitions and storage.
  large    5 brokers, RF=3  - multi-team / high partition count.

Overrides (any of these beat the size preset):
  --brokers N               CONFLUENT_BROKER_REPLICAS
  --replication-factor N    CONFLUENT_REPLICATION_FACTOR
  --partitions N            CONFLUENT_PARTITIONS
  --storage SIZE            CONFLUENT_BROKER_STORAGE_SIZE        (e.g. 200Gi)
  --storage-class NAME      CONFLUENT_STORAGE_CLASS
  --broker-cpu-request V    --broker-cpu-limit V
  --broker-mem-request V    --broker-mem-limit V
  --component-cpu-request V --component-cpu-limit V
  --component-mem-request V --component-mem-limit V
  --cluster-id ID           CONFLUENT_CLUSTER_ID (22 chars, base64url)
  --overwrite-cluster-id B  true = discard the existing id and generate a fresh
                            one; false (default) = keep whatever is configured
  --regenerate-cluster-id   shorthand for --overwrite-cluster-id true
  --dry-run                 print the resulting block without writing
  --target-cluster NAME     Use configs/clusters/NAME (mode on, or a cluster with its folder)
  -h, --help                this message

Deploy mode:
  --deploy-mode MODE        scripts | operator (CONFLUENT_DEPLOY_MODE). New file:
                            operator. Existing file: keeps its value.
  --switch-deploy-mode      allow --deploy-mode to change an existing file's mode
                            (a fresh install: scripts -> operator needs
                            x.8_confluent_wipe_scripts_mode.sh first)

Operator mode only (ignored with a warning in scripts mode):
  --sasl-impl IMPL          plain (default, native CFK) | scram (configOverrides,
                            outside Confluent Support)
  --tls-source SRC          repo (default, repo-made certificates) | cfk
  --approval MODE           Manual (default) | Automatic InstallPlan approval
  --kraft-replicas N        CONFLUENT_KRAFT_REPLICAS (odd, >= 1)
  --kraft-storage SIZE      CONFLUENT_KRAFT_STORAGE_SIZE (e.g. 20Gi)

Cluster id: by default the id already in confluent_vars.sh is preserved, and one
is generated only when none is present. The id is baked into the broker's
formatted log dir, so overwriting it while reusing the broker PVCs stops the
broker from starting - ask for it explicitly when you mean it.

Sizing note: the sizes set only the shape of the cluster (brokers, replication,
partitions, storage, resources). Component toggles, ports, images and routes are
left untouched.
USAGE
}

# ------------------------------------------------------------------------------
# Size presets
# ------------------------------------------------------------------------------
# Chosen so that every size except xsmall survives the loss of one broker:
# RF=3 with min.insync.replicas=2 is the standard durable Kafka configuration.
apply_size() {
    case "$1" in
        xsmall)
            # cp-all-in-one parity. Single broker: no redundancy, demo only.
            BROKERS=1;  RF=1; PARTITIONS=1;  STORAGE="20Gi"
            B_CPU_REQ="500m"; B_MEM_REQ="2Gi"; B_CPU_LIM="2";  B_MEM_LIM="4Gi"
            C_CPU_REQ="250m"; C_MEM_REQ="1Gi"; C_CPU_LIM="1";  C_MEM_LIM="2Gi"
            ;;
        small)
            # Smallest shape that tolerates a broker failure. Sized for a
            # production POC running roughly 5-10 topics at modest throughput.
            BROKERS=3;  RF=3; PARTITIONS=3;  STORAGE="100Gi"
            B_CPU_REQ="1";    B_MEM_REQ="4Gi"; B_CPU_LIM="2";  B_MEM_LIM="8Gi"
            C_CPU_REQ="500m"; C_MEM_REQ="2Gi"; C_CPU_LIM="1";  C_MEM_LIM="4Gi"
            ;;
        medium)
            BROKERS=3;  RF=3; PARTITIONS=12; STORAGE="500Gi"
            B_CPU_REQ="2";    B_MEM_REQ="8Gi";  B_CPU_LIM="4"; B_MEM_LIM="16Gi"
            C_CPU_REQ="1";    C_MEM_REQ="4Gi";  C_CPU_LIM="2"; C_MEM_LIM="8Gi"
            ;;
        large)
            BROKERS=5;  RF=3; PARTITIONS=24; STORAGE="1Ti"
            B_CPU_REQ="4";    B_MEM_REQ="16Gi"; B_CPU_LIM="8"; B_MEM_LIM="32Gi"
            C_CPU_REQ="2";    C_MEM_REQ="8Gi";  C_CPU_LIM="4"; C_MEM_LIM="16Gi"
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
# Default size when --size is omitted: the smallest shape that tolerates a
# broker failure, so an unqualified run does not silently produce a demo-only
# single-broker cluster.
SIZE="small"
DRY_RUN=false
REGEN_ID=false
STORAGE_CLASS_OVERRIDE=""
CLUSTER_ID_OVERRIDE=""
typeset -A OVERRIDE
DEPLOY_MODE_FLAG=""
SWITCH_DEPLOY_MODE=false
typeset -A OPERATOR_FLAG KRAFT_FLAG

# Accepts true/false/yes/no/1/0 for boolean-style flags.
_parse_bool() {
    case "${2:l}" in
        true|yes|1)  echo true ;;
        false|no|0)  echo false ;;
        *) echo "[ERROR] $1 expects true or false, got '$2'." >&2; exit 1 ;;
    esac
}

while (( $# > 0 )); do
    case "$1" in
        --size)                   h_need_value "$1" "${2:-}"; SIZE="$2"; shift 2 ;;
        --brokers)                h_need_value "$1" "${2:-}"; OVERRIDE[BROKERS]="$2"; shift 2 ;;
        --replication-factor)     h_need_value "$1" "${2:-}"; OVERRIDE[RF]="$2"; shift 2 ;;
        --partitions)             h_need_value "$1" "${2:-}"; OVERRIDE[PARTITIONS]="$2"; shift 2 ;;
        --storage)                h_need_value "$1" "${2:-}"; OVERRIDE[STORAGE]="$2"; shift 2 ;;
        --storage-class)          h_need_value "$1" "${2:-}"; STORAGE_CLASS_OVERRIDE="$2"; shift 2 ;;
        --broker-cpu-request)     h_need_value "$1" "${2:-}"; OVERRIDE[B_CPU_REQ]="$2"; shift 2 ;;
        --broker-cpu-limit)       h_need_value "$1" "${2:-}"; OVERRIDE[B_CPU_LIM]="$2"; shift 2 ;;
        --broker-mem-request)     h_need_value "$1" "${2:-}"; OVERRIDE[B_MEM_REQ]="$2"; shift 2 ;;
        --broker-mem-limit)       h_need_value "$1" "${2:-}"; OVERRIDE[B_MEM_LIM]="$2"; shift 2 ;;
        --component-cpu-request)  h_need_value "$1" "${2:-}"; OVERRIDE[C_CPU_REQ]="$2"; shift 2 ;;
        --component-cpu-limit)    h_need_value "$1" "${2:-}"; OVERRIDE[C_CPU_LIM]="$2"; shift 2 ;;
        --component-mem-request)  h_need_value "$1" "${2:-}"; OVERRIDE[C_MEM_REQ]="$2"; shift 2 ;;
        --component-mem-limit)    h_need_value "$1" "${2:-}"; OVERRIDE[C_MEM_LIM]="$2"; shift 2 ;;
        --cluster-id)             h_need_value "$1" "${2:-}"; CLUSTER_ID_OVERRIDE="$2"; shift 2 ;;
        --overwrite-cluster-id)   h_need_value "$1" "${2:-}"; REGEN_ID="$(_parse_bool "$1" "$2")"; shift 2 ;;
        --regenerate-cluster-id)  REGEN_ID=true; shift ;;
        --dry-run)                DRY_RUN=true; shift ;;
        --deploy-mode)            h_need_value "$1" "${2:-}"; DEPLOY_MODE_FLAG="$2"; shift 2 ;;
        --switch-deploy-mode)     SWITCH_DEPLOY_MODE=true; shift ;;
        --sasl-impl)              h_need_value "$1" "${2:-}"; OPERATOR_FLAG[CONFLUENT_OPERATOR_SASL_IMPL]="$2"; shift 2 ;;
        --tls-source)             h_need_value "$1" "${2:-}"; OPERATOR_FLAG[CONFLUENT_OPERATOR_TLS_SOURCE]="$2"; shift 2 ;;
        --approval)               h_need_value "$1" "${2:-}"; OPERATOR_FLAG[CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL]="$2"; shift 2 ;;
        --kraft-replicas)         h_need_value "$1" "${2:-}"; KRAFT_FLAG[CONFLUENT_KRAFT_REPLICAS]="$2"; shift 2 ;;
        --kraft-storage)          h_need_value "$1" "${2:-}"; KRAFT_FLAG[CONFLUENT_KRAFT_STORAGE_SIZE]="$2"; shift 2 ;;
        -h|--help)                usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

# ------------------------------------------------------------------------------
# Deploy mode (CONFLUENT_DEPLOY_MODE), decided before anything is written:
#   --deploy-mode given           -> that value
#   no file yet                   -> operator
#   the file has the line         -> its value (scripts, else operator)
#   the file has no line, no flag -> undecided: nothing about the mode is written,
#                                    and no operator-mode setting either (the file
#                                    may belong to a live scripts-mode install)
# A file in one mode is switched only with --switch-deploy-mode (plan O19).
# ------------------------------------------------------------------------------
_resolve_mode() {   # <raw value> -> scripts | operator (trimmed, case-insensitive)
    local v="${(L)1}"
    v="${v//[[:space:]]/}"
    [[ "${v}" == scripts ]] && print -r -- scripts || print -r -- operator
}

if [[ -n "${DEPLOY_MODE_FLAG}" ]]; then
    DEPLOY_MODE_FLAG="${(L)DEPLOY_MODE_FLAG}"
    [[ "${DEPLOY_MODE_FLAG}" == (scripts|operator) ]] || {
        echo "[ERROR] --deploy-mode expects scripts or operator, got '${DEPLOY_MODE_FLAG}'." >&2; exit 1; }
fi
if $SWITCH_DEPLOY_MODE && [[ -z "${DEPLOY_MODE_FLAG}" ]]; then
    echo "[ERROR] --switch-deploy-mode needs --deploy-mode scripts|operator." >&2
    exit 1
fi

# Value of `export NAME=...` in the vars file, as the shell reads it when sourced:
# "double" or 'single' quoted, or bare up to the first blank; the last line wins.
# Empty when absent.
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

_MODE_LINE_PRESENT=false
_MODE_LINE_VALUE=""
if [[ -f "${VARS_FILE}" ]] && _file_has CONFLUENT_DEPLOY_MODE; then
    _MODE_LINE_PRESENT=true
    _MODE_LINE_VALUE="$(_file_value CONFLUENT_DEPLOY_MODE)"
fi

DEPLOY_MODE=""
DEPLOY_MODE_SWITCH_FROM=""
if [[ -n "${DEPLOY_MODE_FLAG}" ]]; then
    DEPLOY_MODE="${DEPLOY_MODE_FLAG}"
    if $_MODE_LINE_PRESENT && [[ "$(_resolve_mode "${_MODE_LINE_VALUE}")" != "${DEPLOY_MODE}" ]]; then
        if ! $SWITCH_DEPLOY_MODE; then
            echo "[ERROR] ${VARS_FILE} is in $(_resolve_mode "${_MODE_LINE_VALUE}") mode; switching to ${DEPLOY_MODE} needs --switch-deploy-mode (a fresh install, plan O19)" >&2
            exit 1
        fi
        DEPLOY_MODE_SWITCH_FROM="$(_resolve_mode "${_MODE_LINE_VALUE}")"
    fi
elif [[ ! -f "${VARS_FILE}" ]]; then
    DEPLOY_MODE=operator
elif $_MODE_LINE_PRESENT; then
    DEPLOY_MODE="$(_resolve_mode "${_MODE_LINE_VALUE}")"
fi

# Operator-mode flags: validated and canonicalised up front; ignored (with a
# warning) in scripts mode, where nothing reads them.
for _k in "${(@k)OPERATOR_FLAG}"; do
    _v="${OPERATOR_FLAG[$_k]}"
    case "${_k}" in
        CONFLUENT_OPERATOR_SASL_IMPL)
            _v="${(L)_v}"; [[ "${_v}" == (plain|scram) ]] || {
                echo "[ERROR] --sasl-impl expects plain or scram, got '${OPERATOR_FLAG[$_k]}'." >&2; exit 1; } ;;
        CONFLUENT_OPERATOR_TLS_SOURCE)
            _v="${(L)_v}"; [[ "${_v}" == (repo|cfk) ]] || {
                echo "[ERROR] --tls-source expects repo or cfk, got '${OPERATOR_FLAG[$_k]}'." >&2; exit 1; } ;;
        CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL)
            case "${(L)_v}" in
                manual)    _v=Manual ;;
                automatic) _v=Automatic ;;
                *) echo "[ERROR] --approval expects Manual or Automatic, got '${_v}'." >&2; exit 1 ;;
            esac ;;
    esac
    OPERATOR_FLAG[$_k]="${_v}"
done
if [[ -n "${KRAFT_FLAG[CONFLUENT_KRAFT_REPLICAS]:-}" ]]; then
    _v="${KRAFT_FLAG[CONFLUENT_KRAFT_REPLICAS]}"
    [[ "${_v}" =~ ^[0-9]+$ ]] && (( _v >= 1 && _v % 2 == 1 )) || {
        echo "[ERROR] --kraft-replicas expects an odd integer >= 1, got '${_v}'." >&2; exit 1; }
fi
if [[ -n "${KRAFT_FLAG[CONFLUENT_KRAFT_STORAGE_SIZE]:-}" ]]; then
    [[ "${KRAFT_FLAG[CONFLUENT_KRAFT_STORAGE_SIZE]}" =~ ^[0-9]+(Mi|Gi|Ti)$ ]] || {
        echo "[ERROR] --kraft-storage '${KRAFT_FLAG[CONFLUENT_KRAFT_STORAGE_SIZE]}' must look like 10Gi / 1Ti." >&2; exit 1; }
fi
if [[ "${DEPLOY_MODE}" != operator ]] && (( ${#OPERATOR_FLAG} + ${#KRAFT_FLAG} > 0 )); then
    echo "[WARN] --sasl-impl, --tls-source, --approval and --kraft-* apply to operator mode only - ignored (CONFLUENT_DEPLOY_MODE=${DEPLOY_MODE:-not set in the file})." >&2
fi

# ------------------------------------------------------------------------------
# Create the config if it does not exist yet.
#
# configs/confluent_platform_config/ is gitignored, so a fresh clone has no confluent_vars.sh at all.
# Nothing here needs to be seeded by hand: the backfill sections below add every
# cluster, platform and sizing variable the install scripts require, so an empty
# stub is enough to turn the first run into a complete config. Only the shebang
# and header are written, because the file is sourced, not executed.
# ------------------------------------------------------------------------------
if [[ ! -f "${VARS_FILE}" ]]; then
    if $DRY_RUN; then
        echo "[INFO] --dry-run: would create ${VARS_FILE} (does not exist)."
        # Everything downstream greps the file; give it an empty one in the
        # scratch space so the dry run reports a true "all variables missing".
        VARS_FILE="$(mktemp)"
    else
        mkdir -p "$(dirname "${VARS_FILE}")"
        cat > "${VARS_FILE}" <<EOF
#!/bin/zsh
# ==============================================================================
# Confluent Platform configuration - created by $(basename $0)
# on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ==============================================================================
# Sourced (never executed) by the confluent_install scripts, which run with
# ENV_TARGET=confluent so that THIS file is the only config in scope.
#
# Re-running the templating script backfills any variable that is missing and
# leaves every value already present untouched, so edits here survive.
EOF
        echo "[INFO] Created ${VARS_FILE##*/} - it did not exist."
    fi
fi

# ------------------------------------------------------------------------------
# Backfill the cluster foundation (OpenShift login, project, storage classes).
#
# Every confluent script defaults to ENV_TARGET=confluent, and source_env_setup.sh
# honours that by sourcing ONLY confluent_vars.sh - cpd_vars.sh is never loaded.
# So the cluster-level names the scripts rely on (OC_LOGIN, PROJECT_CONFLUENT_SERVER,
# STG_CLASS_BLOCK, ...) have to live in this file; they cannot be inherited.
#
# They must also be written as literals, not as ${OCP_URL}-style references to
# cpd_vars.sh, for the same reason: nothing else is in scope to resolve them.
# cpd_vars.sh is therefore read HERE, at template time, purely to seed the values.
#
# These are prepended, not appended: CONFLUENT_STORAGE_CLASS="${STG_CLASS_BLOCK}"
# and CONFLUENT_AUTH_USERNAME="${OCP_USERNAME}" expand when the file is sourced,
# so their definitions must already be in scope by the time those lines are read.
#
# Anything already present is left untouched - a value edited here survives.
# ------------------------------------------------------------------------------
CPD_VARS_FILE="${CONFIGS_ROOT:-${REPO_ROOT}/configs}/cp4d_config/cpd_vars.sh"

# Pull a literal value out of cpd_vars.sh without sourcing it (it has side
# effects: it sources .env and shells out for IMAGE_PULL_CREDENTIALS).
_seed_from_cpd() {
    [[ -f "${CPD_VARS_FILE}" ]] || return 0
    grep -oE "^export $1=\"[^\"]*\"" "${CPD_VARS_FILE}" 2>/dev/null | head -1 | cut -d'"' -f2 || true
}

_seed_ocp_url="$(_seed_from_cpd OCP_URL)"
_seed_ocp_user="$(_seed_from_cpd OCP_USERNAME)"
_seed_ocp_pass="$(_seed_from_cpd OCP_PASSWORD)"
_seed_stg_block="$(_seed_from_cpd STG_CLASS_BLOCK)"
_seed_stg_file="$(_seed_from_cpd STG_CLASS_FILE)"

_cluster_defaults=(
    "OCP_URL|${_seed_ocp_url}|# ---- Cluster -----------------------------------------------------------------
# The confluent scripts run with ENV_TARGET=confluent, which loads THIS file and
# nothing else - cpd_vars.sh is not in scope. These are seeded from cpd_vars.sh
# the first time this script runs and are then owned here; point them at a
# different cluster freely, re-runs preserve whatever is set."
    "OCP_USERNAME|${_seed_ocp_user}|"
    "OCP_PASSWORD|${_seed_ocp_pass}|"
    'SERVER_ARGUMENTS|--server=${OCP_URL}|'
    'LOGIN_ARGUMENTS|--username=${OCP_USERNAME} --password=${OCP_PASSWORD}|'
    'OC_LOGIN|oc login ${SERVER_ARGUMENTS} ${LOGIN_ARGUMENTS}|# Every script runs eval "${OC_LOGIN}" before touching the cluster.'
    'PROJECT_CONFLUENT_SERVER|confluent|# ---- Projects ----------------------------------------------------------------
# The project the whole cp-all-in-one stack installs into. The Flink scripts
# derive their own project from this one (${PROJECT_CONFLUENT_SERVER}-flink).'
    "STG_CLASS_BLOCK|${_seed_stg_block}|# ---- Storage -----------------------------------------------------------------
# RWO for the broker PVCs (CONFLUENT_STORAGE_CLASS references this), RWX for the
# Flink checkpoint PVC (FLINK_STATE_STORAGE_CLASS references this)."
    "STG_CLASS_FILE|${_seed_stg_file}|"
)

_cluster_backfill=""
_cluster_names=()
for _entry in "${_cluster_defaults[@]}"; do
    _name="${_entry%%|*}"
    _rest="${_entry#*|}"
    _value="${_rest%%|*}"
    _comment="${_rest#*|}"

    grep -qE "^export ${_name}=" "${VARS_FILE}" && continue

    _cluster_names+=("${_name}")
    [[ -n "${_comment}" ]] && _cluster_backfill+=$'\n'"${_comment}"
    _cluster_backfill+=$'\n'"export ${_name}=\"${_value}\""
done

if [[ -n "${_cluster_backfill}" ]] && ! $DRY_RUN; then
    _cluster_header="# ------------------------------------------------------------------------------
# Cluster foundation - added by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ------------------------------------------------------------------------------
# NOT managed on re-runs - edit these freely, they will be preserved.
# Must stay above the Confluent settings below, which reference them.${_cluster_backfill}"

    _prepend_file="$(mktemp)"
    printf '%s\n\n' "${_cluster_header}" > "${_prepend_file}"
    cat "${VARS_FILE}" >> "${_prepend_file}"
    mv "${_prepend_file}" "${VARS_FILE}"

    echo "[INFO] Added ${#_cluster_names[@]} missing cluster variable(s) to the top of ${VARS_FILE##*/}:"
    printf '         %s\n' "${_cluster_names[@]}"
    for _n in "${_cluster_names[@]}"; do
        case "${_n}" in
            OCP_URL|OCP_USERNAME|OCP_PASSWORD|STG_CLASS_BLOCK|STG_CLASS_FILE)
                [[ -z "$(_seed_from_cpd "${_n}")" ]] && \
                    echo "[WARN] ${_n} was written empty - cpd_vars.sh had no value to seed it from. Set it in ${VARS_FILE##*/}." ;;
        esac
    done
elif [[ -n "${_cluster_backfill}" ]]; then
    echo "[INFO] --dry-run: would add ${#_cluster_names[@]} missing cluster variable(s) to the top:"
    printf '         %s\n' "${_cluster_names[@]}"
fi

# ------------------------------------------------------------------------------
# Backfill the non-sizing Confluent Platform settings.
#
# This script owns only the sizing block, but the install scripts also need the
# platform settings (version, registry, images, component toggles, ports,
# routes, timeouts). A config that never had them - or lost them - would fail in
# 1.0_confluent_prep.sh with "Missing required variables". Any of these that is
# absent is appended once, with its default; values already present are left
# exactly as they are, so hand edits survive.
# ------------------------------------------------------------------------------
# Version and image defaults come from src/helpers/version_catalog.json (the
# literals these entries carried before, when it cannot be read).
_cat_version="$(vr_catalog confluent/version)"
_cat_connect="$(vr_catalog confluent/connect_image)"
_cat_ldap="$(vr_catalog confluent/ldap_image)"
_cat_keycloak="$(vr_catalog confluent/keycloak_image)"
_cat_c3="$(vr_catalog confluent/c3_version)"
_platform_defaults=(
    "CONFLUENT_VERSION|${_cat_version}|"'# ---- Images ------------------------------------------------------------------
# Tag applied to every confluentinc/cp-* image. "latest" tracks the newest but rely on a named versiion like 8.2.0
# published build; pin a version (7.5.0, 8.0.0, ...) for a reproducible install.'
    'CONFLUENT_REGISTRY|docker.io/confluentinc|# Registry the cp-* images are pulled from. Override for an air-gapped mirror.'
    "CONFLUENT_CONNECT_IMAGE|${_cat_connect}|"'# The Connect image ships from a separate org with the datagen connector baked
# in. It publishes NO "latest" tag - every tag is <datagen-version>-<cp-version>
# - so it is pinned independently of CONFLUENT_VERSION and bumped by hand.
#
# There is no "fuller" stock alternative to switch to: per the Confluent image
# reference, cp-server-connect and cp-server-connect-base are identical (as are
# the cp-kafka-connect pair), and none of them bundle any connector - only
# confluent-hub-client. They differed in the 6.x/7.x era; they no longer do, and
# the -base names are deprecated in CP 8.3.0 for removal in 8.4.0. Verified on
# 8.2.0: /usr/share/confluent-hub-components is empty and only the platform
# libs sit in /usr/share/java.
#
# To ship extra connectors, build a derived image - there is no supported
# runtime install hook:
#   FROM confluentinc/cp-server-connect:<CONFLUENT_VERSION>
#   RUN confluent-hub install --no-prompt confluentinc/kafka-connect-datagen:0.6.7
#   RUN confluent-hub install --no-prompt confluentinc/kafka-connect-jdbc:latest
# push it to your registry and point this variable at it. CONNECT_PLUGIN_PATH
# already covers /usr/share/confluent-hub-components, so nothing else changes.'
    'CONFLUENT_REGISTRY_USER||# Optional credentials for CONFLUENT_REGISTRY. Empty user = anonymous pull.'
    'CONFLUENT_REGISTRY_PASSWORD||'
    'CONFLUENT_PULL_SECRET|confluent-registry|'
    'CONFLUENT_INSTALL_SCHEMA_REGISTRY|true|# ---- Component toggles -------------------------------------------------------
# The broker is always installed. Set any of these to "false" to skip.'
    'CONFLUENT_INSTALL_CONNECT|true|'
    'CONFLUENT_INSTALL_KSQLDB|true|'
    'CONFLUENT_INSTALL_REST_PROXY|true|'
    'CONFLUENT_INSTALL_CONTROL_CENTER|true|'
    'DO_ICEBERG_WATSONX_SETUP|false|# Optional Iceberg sink integration with an existing watsonx.data/COS catalog.
# Configure configs/confluent_platform_config/iceberg_watsonx_setup.sh first.
# The integration utility can also be run separately after both platforms exist.'
    'ICEBERG_WATSONX_CONFIG_FILE|${CONFLUENT_CONFIG_DIR}/iceberg_watsonx_setup.sh|'
    'CONFLUENT_MONITORING_NETWORK_POLICY|true|# Restricts Prometheus/Alertmanager ingress to the Confluent pods. They run
# unauthenticated (as upstream does), so set this to "false" only if something
# outside the namespace must scrape them.'
    'CONFLUENT_BROKER_INTERNAL_PORT|29092|# ---- Ports (upstream cp-all-in-one compose defaults) -------------------------'
    'CONFLUENT_BROKER_CONTROLLER_PORT|29093|'
    'CONFLUENT_BROKER_EXTERNAL_PORT|9092|'
    'CONFLUENT_SCHEMA_REGISTRY_PORT|8081|'
    'CONFLUENT_CONNECT_PORT|8083|'
    'CONFLUENT_KSQLDB_PORT|8088|'
    'CONFLUENT_REST_PROXY_PORT|8082|'
    'CONFLUENT_CONTROL_CENTER_PORT|9021|'
    'CONFLUENT_CREATE_ROUTES|true|# ---- Routes ------------------------------------------------------------------
# Expose the HTTP endpoints of the installed components as OpenShift routes.'
    'CONFLUENT_ROUTE_DOMAIN||# Leave empty to use the cluster'"'"'s default apps domain.'
    'CONFLUENT_ROLLOUT_TIMEOUT|600s|# ---- Waits -------------------------------------------------------------------'
    'CONFLUENT_AUTH_ENABLED|true|# ---- Web UI authentication ---------------------------------------------------
# openshift = the Control Center route sits behind an oauth-proxy sidecar and
#             the cluster login (no password to distribute).
# basic     = an nginx sidecar terminates HTTP basic auth using the credentials
#             below. Only this mode reads AUTH_USERNAME/AUTH_PASSWORD.'
    'CONFLUENT_AUTH_MODE|openshift|'
    'CONFLUENT_AUTH_SECRET|confluent-auth|'
    'CONFLUENT_AUTH_USERNAME|${OCP_USERNAME}|# Basic-mode credentials. Username defaults to the OpenShift login user.
# Leave the password empty to have one generated and stored in the secret above;
# it is then reused on every later run, so redeploys keep the same credentials.'
    'CONFLUENT_AUTH_PASSWORD||'
    'CONFLUENT_AUTH_PASSWORD_LENGTH|24|'
    'CONFLUENT_SASL_ENABLED|true|# ---- Kafka client authentication (SASL) --------------------------------------
# Independent of the web-UI auth above: this secures the Kafka wire protocol.
# Enabling it makes the brokers reject unauthenticated clients.'
    'CONFLUENT_SASL_PROTOCOL|SASL_PLAINTEXT|# In-cluster listeners, inter-broker traffic and every platform component.
# SASL_PLAINTEXT = authenticated, unencrypted on the pod network.
# SASL_SSL       = also TLS-encrypted, with a CA generated into
#                  CONFLUENT_INTERNAL_TLS_SECRET (clients must trust it).'
    'CONFLUENT_SASL_MECHANISM|SCRAM-SHA-512|# SCRAM-SHA-512 | SCRAM-SHA-256 | PLAIN - what broker-to-broker traffic and
# the platform components use. SCRAM users can be added at runtime; PLAIN rolls
# the brokers on every change and belongs on SASL_SSL.'
    'CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS|PLAIN,SCRAM-SHA-512|# Comma-separated: every mechanism in-cluster clients may use (PLAIN,
# SCRAM-SHA-512, SCRAM-SHA-256). CONFLUENT_SASL_MECHANISM is always accepted too.
# Known client limit: StreamSets (watsonx.data) connects to the internal
# bootstrap with PLAIN only - SCRAM-SHA-512 failed there - so keep PLAIN in
# this list while it is used. Not yet recorded whether StreamSets accepts the
# internal listener with CONFLUENT_SASL_PROTOCOL=SASL_SSL.'
    'CONFLUENT_SASL_ADMIN_USER|confluent-admin|'
    'CONFLUENT_SASL_CLIENTS|app-client|# Comma-separated. One credential is minted per name, valid for every mechanism.'
    'CONFLUENT_SASL_SECRET|confluent-sasl|'
    'CONFLUENT_INTERNAL_TLS_SECRET|confluent-kafka-internal-tls|# CONFLUENT_SASL_PROTOCOL=SASL_SSL only: the in-cluster CA and broker keystore.'
    'CONFLUENT_INTERNAL_CERT_VALIDITY_DAYS|825|'
    'CONFLUENT_MDS_ENABLED|true|# ---- Metadata Service (MDS) / RBAC -------------------------------------------
# MDS is embedded in the cp-server broker image, so enabling it adds no new
# Confluent component - it opens an HTTP listener on the brokers and turns on
# the RBAC authorizer. This is what makes \"confluent login --url\" work.
#
# COMMERCIAL FEATURE: MDS/RBAC is licensed. With no license key the brokers run
# it on the built-in 30-day trial and then stop honouring it. Set
# CONFLUENT_LICENSE_KEY before relying on this beyond evaluation.
#
# Requires CONFLUENT_SASL_ENABLED=true: MDS issues tokens for principals that
# must already be able to authenticate to Kafka.
# Provisioned by x.4_confluent_add_mds.sh, removed by x.4_confluent_remove_mds.sh.'
    'CONFLUENT_MDS_PORT|8090|'
    'CONFLUENT_MDS_USER_STORE|LDAP|# LDAP   = bundled OpenLDAP (default; Confluent'"'"'s best-supported MDS store).
# OAUTH  = bundled Keycloak, or an external OIDC provider when
#          CONFLUENT_MDS_OAUTH_JWKS_URL is set. Enables SSO/device-code login.'
    'CONFLUENT_MDS_SECRET|confluent-mds|# Holds the MDS token-signing keypair and the super-user password.'
    'CONFLUENT_MDS_SUPER_USER|mds-admin|# Bootstrap super user: holds SystemAdmin on the Kafka cluster and is the
# account you use for the first \"confluent login\".'
    'CONFLUENT_MDS_USERS|kafka-admin,kafka-user|# Comma-separated. Created in the user store with a generated password each.'
    'CONFLUENT_LICENSE_KEY||# Confluent commercial license. Empty = 30-day trial for MDS/RBAC and C3.'
    "CONFLUENT_LDAP_IMAGE|${_cat_ldap}|"'# ---- Bundled OpenLDAP (CONFLUENT_MDS_USER_STORE=LDAP) ------------------------'
    'CONFLUENT_LDAP_PORT|1389|'
    'CONFLUENT_LDAP_DOMAIN|confluent.io|# Base DN is derived from this: confluent.io -> dc=confluent,dc=io'
    'CONFLUENT_LDAP_ADMIN_USER|admin|'
    'CONFLUENT_LDAP_SECRET|confluent-ldap|'
    "CONFLUENT_KEYCLOAK_IMAGE|${_cat_keycloak}|"'# ---- Bundled Keycloak (CONFLUENT_MDS_USER_STORE=OAUTH) -----------------------
# Ignored when CONFLUENT_MDS_OAUTH_JWKS_URL points at an external provider.'
    'CONFLUENT_KEYCLOAK_PORT|8080|'
    'CONFLUENT_KEYCLOAK_REALM|confluent|'
    'CONFLUENT_KEYCLOAK_CLIENT_ID|confluent-cli|'
    'CONFLUENT_KEYCLOAK_ADMIN_USER|admin|'
    'CONFLUENT_KEYCLOAK_SECRET|confluent-keycloak|'
    'CONFLUENT_MDS_OAUTH_JWKS_URL||# Set these to use an EXTERNAL OIDC provider instead of the bundled Keycloak.'
    'CONFLUENT_MDS_OAUTH_ISSUER||'
    'CONFLUENT_MDS_OAUTH_AUDIENCE|Confluent|'
    'CONFLUENT_MDS_OAUTH_SUB_CLAIM|preferred_username|'
    'CONFLUENT_MDS_OAUTH_GROUPS_CLAIM|groups|'
    'CONFLUENT_MDS_OAUTH_DEVICE_AUTH_URL||# Device-authorization endpoint; enables \"confluent login --no-browser\".'
    'CONFLUENT_EXTERNAL_KAFKA_ENABLED|true|# ---- External Kafka access (passthrough routes + SASL_SSL) -------------------
# Adds an EXTERNAL listener advertised on per-broker TLS passthrough routes, so
# Kafka clients anywhere can reach the right partition leader over port 443.
# The OpenShift router selects the broker by TLS SNI.
#
# Requires CONFLUENT_SASL_ENABLED=true - this listener is internet-facing, so it
# is always SASL_SSL (encrypted), whatever CONFLUENT_SASL_PROTOCOL says.
# Provisioned by x.4_confluent_add_external_access.sh.'
    'CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS|PLAIN,SCRAM-SHA-512|# Comma-separated: PLAIN, SCRAM-SHA-512, SCRAM-SHA-256. The first is what the
# generated client files use; the same users and passwords work for all of them.'
    'CONFLUENT_EXTERNAL_KAFKA_PORT|9094|# Container port for the EXTERNAL listener; advertised on 443 via the routes.'
    'CONFLUENT_EXTERNAL_TLS_SECRET|confluent-kafka-tls|# Holds the generated CA plus the per-broker keystore/truststore.'
    'CONFLUENT_EXTERNAL_CERT_VALIDITY_DAYS|825|'
    "CONFLUENT_C3_VERSION|${_cat_c3}|"'# ---- Control Center / monitoring ---------------------------------------------
# C3 next-gen and its Prometheus/Alertmanager ship on their own version line,
# separate from CONFLUENT_VERSION. All three must match.'
    'CONFLUENT_PROMETHEUS_PORT|9090|'
    'CONFLUENT_ALERTMANAGER_PORT|9093|'
    'CONFLUENT_BROKER_JMX_PORT|9101|'
)

_backfill=""
_backfilled_names=()
for _entry in "${_platform_defaults[@]}"; do
    _name="${_entry%%|*}"
    _rest="${_entry#*|}"
    _value="${_rest%%|*}"
    _comment="${_rest#*|}"

    grep -qE "^export ${_name}=" "${VARS_FILE}" && continue

    _backfilled_names+=("${_name}")
    [[ -n "${_comment}" ]] && _backfill+=$'\n'"${_comment}"
    # Preserve caller overrides when nested install scripts reload this file.
    case "${_name}" in
        *_ENABLED|DO_ICEBERG_WATSONX_SETUP|ICEBERG_WATSONX_CONFIG_FILE)
            _backfill+=$'\n'"export ${_name}=\"\${${_name}:-${_value}}\"" ;;
        *)
            _backfill+=$'\n'"export ${_name}=\"${_value}\"" ;;
    esac
done

if [[ -n "${_backfill}" ]] && ! $DRY_RUN; then
    {
        echo ""
        echo "# ------------------------------------------------------------------------------"
        echo "# Confluent Platform - added by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "# ------------------------------------------------------------------------------"
        echo "# Topology from https://github.com/confluentinc/cp-all-in-one (KRaft variant)."
        echo "# These are NOT managed on re-runs - edit them freely, they will be preserved."
        printf '%s\n' "${_backfill}"
    } >> "${VARS_FILE}"
    echo "[INFO] Added ${#_backfilled_names[@]} missing platform variable(s) to ${VARS_FILE##*/}:"
    printf '         %s\n' "${_backfilled_names[@]}"
elif [[ -n "${_backfill}" ]]; then
    echo "[INFO] --dry-run: would add ${#_backfilled_names[@]} missing platform variable(s):"
    printf '         %s\n' "${_backfilled_names[@]}"
fi

# ------------------------------------------------------------------------------
# Deploy mode line (plan O2, contract §5.2 / §7.3). Kept apart from the platform
# defaults above: it is decided up front, and it is the only line a scripts-mode
# run adds to a file that lacks it.
# ------------------------------------------------------------------------------
# _file_value / _file_has are defined with the deploy-mode decision above.
# Rewrite every `export NAME=...` line in place as export NAME="value"
# (cf_persist_var semantics; the values here are generated, never secrets).
# Written in place like the splices below, so the file keeps its mode (the
# config holds OCP_PASSWORD) and a symlinked config stays a symlink.
_file_set() {   # <name> <value>
    python3 - "${VARS_FILE}" "$1" "$2" <<'PY'
import re, sys
path, name, value = sys.argv[1:4]
text = open(path).read()
pattern = re.compile(r"^export " + re.escape(name) + r"=.*$", re.M)
text = pattern.sub(lambda _: f'export {name}="{value}"', text)
with open(path, "w") as fh:
    fh.write(text)
PY
}

_deploy_mode_snippet() {   # <value>
    cat <<EOF
# ---- Deploy mode ---------------------------------------------------------------
# scripts  = the repo renders and applies raw manifests (StatefulSet broker, Deployments, ...).
# operator = Confluent for Kubernetes (CFK) and cp-fko, installed through OLM, run the platform.
# Unset or any other value means operator; a scripts-mode install in the namespace then stops every script.
export CONFLUENT_DEPLOY_MODE="$1"
EOF
}

if [[ -z "${DEPLOY_MODE}" ]]; then
    echo "[WARN] ${VARS_FILE} has no CONFLUENT_DEPLOY_MODE - the scripts treat it as operator mode. Run with --deploy-mode scripts to keep a scripts-mode install, or --deploy-mode operator." >&2
elif ! $_MODE_LINE_PRESENT; then
    if $DRY_RUN; then
        echo "[INFO] --dry-run: would write CONFLUENT_DEPLOY_MODE=\"${DEPLOY_MODE}\" to ${VARS_FILE##*/}."
    else
        printf '\n%s\n' "$(_deploy_mode_snippet "${DEPLOY_MODE}")" >> "${VARS_FILE}"
        echo "[INFO] CONFLUENT_DEPLOY_MODE=\"${DEPLOY_MODE}\" written to ${VARS_FILE##*/}."
    fi
elif [[ -n "${DEPLOY_MODE_SWITCH_FROM}" ]]; then
    if $DRY_RUN; then
        echo "[INFO] --dry-run: would switch CONFLUENT_DEPLOY_MODE ${DEPLOY_MODE_SWITCH_FROM} -> ${DEPLOY_MODE} in ${VARS_FILE##*/}."
    else
        _file_set CONFLUENT_DEPLOY_MODE "${DEPLOY_MODE}"
        echo "[INFO] CONFLUENT_DEPLOY_MODE: ${DEPLOY_MODE_SWITCH_FROM} -> ${DEPLOY_MODE} saved to ${VARS_FILE##*/}."
    fi
    if [[ "${DEPLOY_MODE}" == operator ]]; then
        echo "[INFO] Switching to operator mode is a fresh install (plan O19): remove the scripts-mode install first with"
        echo "       scripts/install_confluent_platform/utility_scripts_confluent_platform/x.8_confluent_wipe_scripts_mode.sh (--keep-data keeps the PVCs);"
        echo "       until then every operator-mode script stops at the scripts-mode guard."
    else
        echo "[INFO] Switching to scripts mode is a fresh install (plan O19): remove the operator-mode install first with"
        echo "       scripts/install_confluent_platform/utility_scripts_confluent_platform/x.0_confluent_uninstall.sh run in operator mode"
        echo "       (before this switch; add --delete-data --remove-operator for a clean namespace). The operator settings stay in the file, unused."
    fi
fi

# ------------------------------------------------------------------------------
# Operator mode only: the operator settings (written once, then preserved), the
# SASL forcing of plan O9 (CFK components authenticate with PLAIN), and notes.
# ------------------------------------------------------------------------------
if [[ "${DEPLOY_MODE}" == operator ]]; then
    _cat_or() { vr_catalog "$1" 2>/dev/null || print -r -- "$2"; }
    _cat_cfk_channel="$(_cat_or confluent/operator/cfk_channel 3.4)"
    _cat_cfk_csv="$(_cat_or confluent/operator/cfk_csv confluent-for-kubernetes.v3.4.0)"
    _cat_cfk_init_tag="$(_cat_or confluent/operator/cfk_init_tag 3.4.0)"
    _operator_defaults=(
        'CONFLUENT_OPERATOR_SOURCE|olm|# ---- Operators (OLM) ----------------------------------------------------------
# olm = this repo installs Confluent for Kubernetes through OLM (Subscription in
# each target namespace, OwnNamespace OperatorGroup); existing = only reuse one.'
        'CONFLUENT_OPERATOR_PACKAGE|confluent-for-kubernetes|'
        'CONFLUENT_OPERATOR_SUBSCRIPTION_NAME|confluent-for-kubernetes|'
        "CONFLUENT_OPERATOR_CHANNEL|${_cat_cfk_channel}|"
        "CONFLUENT_OPERATOR_STARTING_CSV|${_cat_cfk_csv}|# Empty = the channel head."
        'CONFLUENT_OPERATOR_CATALOG_SOURCE|certified-operators|# Air-gapped: the mirrored CatalogSource (private_registry_mirroring, content "operators").'
        'CONFLUENT_OPERATOR_CATALOG_SOURCE_NAMESPACE|openshift-marketplace|'
        "CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL|${OPERATOR_FLAG[CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL]:-Manual}|# Manual = the scripts approve only the InstallPlan they asked for; upgrades go
# through x.7_confluent_operator_upgrade.sh. Automatic = OLM applies minor bumps,
# which roll the cluster."
        'CONFLUENT_OPERATOR_INSTALL_IN_PLATFORM_NS|true|# Where operators are installed: the platform namespace, the Flink namespace,
# extra namespaces (space-separated) and per-namespace package lists
# (ns=pkg[,pkg] ns2=pkg; a named namespace replaces its derived set).'
        'CONFLUENT_OPERATOR_INSTALL_IN_FLINK_NS|true|'
        'CONFLUENT_OPERATOR_EXTRA_NAMESPACES||'
        'CONFLUENT_OPERATOR_PACKAGES_PER_NS||'
        'CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING|false|# true = the scripts may patch spec.config.env of a Subscription they did not create.'
        'CONFLUENT_OPERATOR_RESTRICT_CROSS_NS_RESTCLASS|false|'
        'CONFLUENT_OPERATOR_IMAGE_SOURCE|tags|# tags = CONFLUENT_VERSION / CONFLUENT_C3_VERSION image tags; csv = the operator CSV digests.'
        "CONFLUENT_OPERATOR_INIT_IMAGE|\${CONFLUENT_REGISTRY}/confluent-init-container:${_cat_cfk_init_tag}|"
        "CONFLUENT_OPERATOR_TLS_SOURCE|${OPERATOR_FLAG[CONFLUENT_OPERATOR_TLS_SOURCE]:-repo}|# ---- Security --------------------------------------------------------------
# repo = the scripts generate the certificates (as scripts mode does); cfk = CFK
# auto-generates the in-cluster certificates (the external route cert stays repo-made)."
        "CONFLUENT_OPERATOR_SASL_IMPL|${OPERATOR_FLAG[CONFLUENT_OPERATOR_SASL_IMPL]:-plain}|# plain = native CFK SASL/PLAIN (supported by Confluent Support).
# scram = SCRAM through Kafka configOverrides: documented by Confluent but outside
# Confluent Support. Either way CONFLUENT_SASL_MECHANISM is PLAIN in operator mode."
        'CONFLUENT_CONNECTOR_MANAGEMENT|rest|# rest = connectors through the Connect REST API (as today); cr = Connector CRs.'
        'CONFLUENT_AUTO_CREATE_TOPICS|true|# ---- Kafka / network ---------------------------------------------------------'
        'CONFLUENT_OPERATOR_NETWORK_POLICIES|true|# NetworkPolicy cfk-kafka-listeners in front of the Kafka listeners.'
        'CONFLUENT_EXTERNAL_KAFKA_BOOTSTRAP_PREFIX|kafka-${PROJECT_CONFLUENT_SERVER}|# External route hosts: <bootstrap prefix>.<domain>, <broker prefix><N>.<domain>.'
        'CONFLUENT_EXTERNAL_KAFKA_BROKER_PREFIX|kafka-${PROJECT_CONFLUENT_SERVER}-b|'
        'CONFLUENT_OPERATOR_CSV_TIMEOUT|600|# ---- Waits (seconds) ---------------------------------------------------------'
        'CONFLUENT_OPERATOR_INSTALLPLAN_TIMEOUT|300|'
        'CONFLUENT_OPERATOR_KAFKA_TIMEOUT|900|'
        'CONFLUENT_OPERATOR_COMPONENT_TIMEOUT|600|'
        'CONFLUENT_OPERATOR_CONNECT_TIMEOUT|900|'
        'CONFLUENT_CONNECT_PLUGINS_PVC|connect-plugins|# ---- Connect plugins from local files (x.3_confluent_add_connector.sh) --------'
        'CONFLUENT_CONNECT_PLUGINS_PVC_SIZE|5Gi|'
        'CONFLUENT_CONNECT_PLUGINS_LOADER_IMAGE|registry.access.redhat.com/ubi9/ubi:latest|'
    )

    _operator_backfill=""
    _operator_names=()
    for _entry in "${_operator_defaults[@]}"; do
        _name="${_entry%%|*}"
        _rest="${_entry#*|}"
        _value="${_rest%%|*}"
        _comment="${_rest#*|}"

        _file_has "${_name}" && continue

        _operator_names+=("${_name}")
        [[ -n "${_comment}" ]] && _operator_backfill+=$'\n'"${_comment}"
        _operator_backfill+=$'\n'"export ${_name}=\"${_value}\""
    done

    if [[ -n "${_operator_backfill}" ]] && ! $DRY_RUN; then
        {
            echo ""
            echo "# ------------------------------------------------------------------------------"
            echo "# Confluent operator mode - added by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            echo "# ------------------------------------------------------------------------------"
            echo "# Read only when CONFLUENT_DEPLOY_MODE=operator. NOT managed on re-runs - edit"
            echo "# them freely; --approval, --sasl-impl and --tls-source rewrite their own line."
            printf '%s\n' "${_operator_backfill}"
        } >> "${VARS_FILE}"
        echo "[INFO] Added ${#_operator_names[@]} missing operator-mode variable(s) to ${VARS_FILE##*/}:"
        printf '         %s\n' "${_operator_names[@]}"
    elif [[ -n "${_operator_backfill}" ]]; then
        echo "[INFO] --dry-run: would add ${#_operator_names[@]} missing operator-mode variable(s):"
        printf '         %s\n' "${_operator_names[@]}"
    fi

    # Flags given for settings that were already in the file rewrite their line.
    for _k in CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL CONFLUENT_OPERATOR_TLS_SOURCE CONFLUENT_OPERATOR_SASL_IMPL; do
        [[ -n "${OPERATOR_FLAG[$_k]:-}" ]] || continue
        _file_has "${_k}" || continue
        _old="$(_file_value "${_k}")"
        [[ "${_old}" == "${OPERATOR_FLAG[$_k]}" ]] && continue
        if $DRY_RUN; then
            echo "[INFO] --dry-run: would set ${_k}: ${_old} -> ${OPERATOR_FLAG[$_k]}"
        else
            _file_set "${_k}" "${OPERATOR_FLAG[$_k]}"
            echo "[INFO] ${_k}: ${_old} -> ${OPERATOR_FLAG[$_k]}"
        fi
    done

    # The SASL implementation now in effect (flag, else the file, else plain).
    _sasl_impl="${OPERATOR_FLAG[CONFLUENT_OPERATOR_SASL_IMPL]:-$(_file_value CONFLUENT_OPERATOR_SASL_IMPL)}"
    _sasl_impl="${(L)${_sasl_impl:-plain}}"
    [[ "${_sasl_impl}" == (plain|scram) ]] || _sasl_impl=plain

    # Plan O9: CFK components authenticate with native PLAIN only, and with impl
    # plain the listeners accept PLAIN only.
    _drop_scram() {   # <comma list> -> the list without SCRAM-*; PLAIN when empty
        local -a kept=()
        local m
        for m in ${(s:,:)1}; do
            m="${m//[[:space:]]/}"
            [[ -z "${m}" || "${(U)m}" == SCRAM-* ]] && continue
            kept+=("${m}")
        done
        (( ${#kept} )) || kept=(PLAIN)
        print -r -- "${(j:,:)kept}"
    }
    _force_line() {   # <name> <new value>
        local old
        _file_has "$1" || return 0
        old="$(_file_value "$1")"
        [[ "${old}" == "$2" ]] && return 0
        if $DRY_RUN; then
            echo "[INFO] --dry-run: would set $1: ${old} -> $2 (operator mode, plan O9)"
        else
            _file_set "$1" "$2"
            echo "[INFO] $1: ${old} -> $2 (operator mode, plan O9)"
        fi
    }
    _force_line CONFLUENT_SASL_MECHANISM PLAIN
    if [[ "${_sasl_impl}" == plain ]]; then
        for _k in CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS; do
            _file_has "${_k}" && _force_line "${_k}" "$(_drop_scram "$(_file_value "${_k}")")"
        done
    else
        echo "[WARN] CONFLUENT_OPERATOR_SASL_IMPL=scram: SCRAM through configOverrides is documented by Confluent but outside Confluent Support" >&2
        printf '         %s\n' \
            "https://docs.confluent.io/operator/current/co-authenticate-overview.html" \
            "https://docs.confluent.io/operator/current/co-configure-misc.html#co-config-overrides" \
            "https://docs.confluent.io/operator/current/co-authenticate-kafka.html" \
            "https://docs.confluent.io/platform/current/security/authentication/sasl/scram/overview.html" >&2
    fi

    if [[ -z "$(_file_value CONFLUENT_LICENSE_KEY)" ]]; then
        echo "[WARN] No CONFLUENT_LICENSE_KEY - Confluent Platform runs on the 30-day trial license." >&2
    fi
fi

apply_size "${SIZE}"

# Flags beat the preset.
for _k in "${(@k)OVERRIDE}"; do
    case "${_k}" in
        BROKERS)    BROKERS="${OVERRIDE[$_k]}" ;;
        RF)         RF="${OVERRIDE[$_k]}" ;;
        PARTITIONS) PARTITIONS="${OVERRIDE[$_k]}" ;;
        STORAGE)    STORAGE="${OVERRIDE[$_k]}" ;;
        B_CPU_REQ)  B_CPU_REQ="${OVERRIDE[$_k]}" ;;
        B_CPU_LIM)  B_CPU_LIM="${OVERRIDE[$_k]}" ;;
        B_MEM_REQ)  B_MEM_REQ="${OVERRIDE[$_k]}" ;;
        B_MEM_LIM)  B_MEM_LIM="${OVERRIDE[$_k]}" ;;
        C_CPU_REQ)  C_CPU_REQ="${OVERRIDE[$_k]}" ;;
        C_CPU_LIM)  C_CPU_LIM="${OVERRIDE[$_k]}" ;;
        C_MEM_REQ)  C_MEM_REQ="${OVERRIDE[$_k]}" ;;
        C_MEM_LIM)  C_MEM_LIM="${OVERRIDE[$_k]}" ;;
    esac
done

# ------------------------------------------------------------------------------
# Cluster id resolution, in priority order:
#   1. --cluster-id <id>              use exactly this value
#   2. --overwrite-cluster-id true    generate a fresh one, discarding the old
#      (or --regenerate-cluster-id)
#   3. an id already in the file      keep it
#   4. nothing there                  generate one
#
# Keeping the existing id by default matters: the id is baked into the broker's
# formatted log dir, so changing it against reused PVCs makes the broker refuse
# to start. Regeneration has to be asked for explicitly.
# ------------------------------------------------------------------------------
gen_cluster_id() {
    python3 -c "import base64,uuid;print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip('='))"
}

_existing_id="$(grep -oE '^export CONFLUENT_CLUSTER_ID="[^"]*"' "${VARS_FILE}" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"

if [[ -n "${CLUSTER_ID_OVERRIDE}" ]]; then
    CLUSTER_ID="${CLUSTER_ID_OVERRIDE}"
    CLUSTER_ID_ORIGIN="set explicitly via --cluster-id"
elif [[ "${REGEN_ID}" == "true" ]]; then
    CLUSTER_ID="$(gen_cluster_id)"
    CLUSTER_ID_ORIGIN="regenerated (overwrite requested)"
    [[ -n "${_existing_id}" ]] && \
        echo "[WARN] Overwriting cluster id ${_existing_id} - brokers with already-formatted storage will not start against the new id."
elif [[ -n "${_existing_id}" ]]; then
    CLUSTER_ID="${_existing_id}"
    CLUSTER_ID_ORIGIN="kept from existing config"
else
    CLUSTER_ID="$(gen_cluster_id)"
    CLUSTER_ID_ORIGIN="generated (none present)"
fi

if [[ ! "${CLUSTER_ID}" =~ ^[A-Za-z0-9_-]{22}$ ]]; then
    echo "[ERROR] Cluster id '${CLUSTER_ID}' is invalid: must be 22 chars of [A-Za-z0-9_-]" \
         "(a base64url-encoded 16-byte UUID)." >&2
    exit 1
fi

# Preserve the configured storage class unless overridden. The default in the
# shipped file references ${STG_CLASS_BLOCK}, which must survive as a literal so
# it keeps tracking cpd_vars.sh.
if [[ -n "${STORAGE_CLASS_OVERRIDE}" ]]; then
    STORAGE_CLASS_LITERAL="${STORAGE_CLASS_OVERRIDE}"
else
    STORAGE_CLASS_LITERAL="$(grep -oE '^export CONFLUENT_STORAGE_CLASS="[^"]*"' "${VARS_FILE}" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    STORAGE_CLASS_LITERAL="${STORAGE_CLASS_LITERAL:-\${STG_CLASS_BLOCK\}}"
fi

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------
for _n in BROKERS RF PARTITIONS; do
    [[ "${(P)_n}" =~ ^[0-9]+$ ]] || { echo "[ERROR] ${_n} must be an integer, got '${(P)_n}'." >&2; exit 1; }
    (( ${(P)_n} > 0 )) || { echo "[ERROR] ${_n} must be greater than zero." >&2; exit 1; }
done

if (( RF > BROKERS )); then
    echo "[ERROR] Replication factor (${RF}) cannot exceed broker count (${BROKERS})." >&2
    exit 1
fi

[[ "${STORAGE}" =~ ^[0-9]+(Mi|Gi|Ti)$ ]] || {
    echo "[ERROR] Storage size '${STORAGE}' must look like 100Gi / 1Ti." >&2; exit 1; }

# min.insync.replicas: 2 whenever replication allows it, else 1.
if (( RF >= 3 )); then MIN_ISR=2; else MIN_ISR=1; fi

if (( BROKERS == 1 )); then
    echo "[WARN] A single broker has no redundancy - suitable for demos only."
elif (( RF < 3 )); then
    echo "[WARN] Replication factor ${RF} does not tolerate a broker failure; RF=3 is recommended for production."
fi

# ------------------------------------------------------------------------------
# Render the managed block
# ------------------------------------------------------------------------------
BEGIN_MARKER="# >>> confluent sizing (managed by 0_confluent_prepare_template_config.sh) >>>"
END_MARKER="# <<< confluent sizing (managed by 0_confluent_prepare_template_config.sh) <<<"

BLOCK="$(cat <<EOF
${BEGIN_MARKER}
# Size: ${SIZE} - written $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Re-run the script to change these; edits inside this block are overwritten.

# ---- Cluster sizing ----------------------------------------------------------
export CONFLUENT_BROKER_REPLICAS="${BROKERS}"
export CONFLUENT_REPLICATION_FACTOR="${RF}"
export CONFLUENT_MIN_INSYNC_REPLICAS="${MIN_ISR}"
export CONFLUENT_PARTITIONS="${PARTITIONS}"

# KRaft cluster id: 22 chars of [A-Za-z0-9_-] (base64url-encoded 16-byte UUID).
# Must stay stable across reinstalls that reuse the broker PVCs.
export CONFLUENT_CLUSTER_ID="${CLUSTER_ID}"

# ---- Storage -----------------------------------------------------------------
export CONFLUENT_STORAGE_CLASS="${STORAGE_CLASS_LITERAL}"
export CONFLUENT_BROKER_STORAGE_SIZE="${STORAGE}"

# ---- Resource requests / limits ----------------------------------------------
export CONFLUENT_BROKER_CPU_REQUEST="${B_CPU_REQ}"
export CONFLUENT_BROKER_MEM_REQUEST="${B_MEM_REQ}"
export CONFLUENT_BROKER_CPU_LIMIT="${B_CPU_LIM}"
export CONFLUENT_BROKER_MEM_LIMIT="${B_MEM_LIM}"

# Applied to every non-broker component.
export CONFLUENT_COMPONENT_CPU_REQUEST="${C_CPU_REQ}"
export CONFLUENT_COMPONENT_MEM_REQUEST="${C_MEM_REQ}"
export CONFLUENT_COMPONENT_CPU_LIMIT="${C_CPU_LIM}"
export CONFLUENT_COMPONENT_MEM_LIMIT="${C_MEM_LIM}"
${END_MARKER}
EOF
)"

# ------------------------------------------------------------------------------
# Operator mode: the second managed block (KRaft controllers and the storage of
# the operator-only stateful components). It follows --size like the sizing
# block; the presets live once in src/helpers/confluent_operator_config.py.
# ------------------------------------------------------------------------------
OP_BEGIN_MARKER="# >>> confluent operator (managed by 0_confluent_prepare_template_config.sh) >>>"
OP_END_MARKER="# <<< confluent operator (managed by 0_confluent_prepare_template_config.sh) <<<"
OP_BLOCK=""
typeset -a KRAFT_NAMES
typeset -A KRAFT
if [[ "${DEPLOY_MODE}" == operator ]]; then
    if ! _kraft_lines="$(_vr_python "${REPO_ROOT}/src/helpers/confluent_operator_config.py" kraft-preset "${SIZE}")" \
            || [[ -z "${_kraft_lines}" ]]; then
        echo "[ERROR] Could not read the KRaft preset for size '${SIZE}' from src/helpers/confluent_operator_config.py." >&2
        exit 1
    fi
    for _line in "${(@f)_kraft_lines}"; do
        [[ "${_line}" =~ '^([A-Z0-9_]+)="([^"]*)"$' ]] || continue
        KRAFT_NAMES+=("${match[1]}")
        KRAFT[${match[1]}]="${match[2]}"
    done
    for _k in "${(@k)KRAFT_FLAG}"; do
        (( ${KRAFT_NAMES[(Ie)${_k}]} )) || KRAFT_NAMES+=("${_k}")
        KRAFT[${_k}]="${KRAFT_FLAG[$_k]}"
    done
    if [[ "${KRAFT[CONFLUENT_KRAFT_REPLICAS]:-}" == 1 ]]; then
        echo "[WARN] A single KRaft controller has no redundancy - suitable for demos only." >&2
    fi

    OP_BLOCK="${OP_BEGIN_MARKER}"$'\n'"# Size: ${SIZE} - written $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    OP_BLOCK+=$'\n'"# Re-run the script to change these; edits inside this block are overwritten."
    OP_BLOCK+=$'\n'"# Read only when CONFLUENT_DEPLOY_MODE=operator."
    OP_BLOCK+=$'\n'
    OP_BLOCK+=$'\n'"# ---- KRaft controllers and operator-mode storage ------------------------------"
    OP_BLOCK+=$'\n'"# CFK runs the KRaft quorum as its own KRaftController pods (odd count)."
    for _k in "${KRAFT_NAMES[@]}"; do
        OP_BLOCK+=$'\n'"export ${_k}=\"${KRAFT[$_k]}\""
    done
    OP_BLOCK+=$'\n'"${OP_END_MARKER}"

    if $DRY_RUN; then
        echo ""
        echo "[INFO] --dry-run: ${VARS_FILE##*/} would receive the operator block:"
        echo ""
        echo "${OP_BLOCK}"
    fi
elif [[ "${DEPLOY_MODE_SWITCH_FROM}" == operator ]] && $DRY_RUN \
        && grep -qF "${OP_BEGIN_MARKER}" "${VARS_FILE}" 2>/dev/null; then
    echo "[INFO] --dry-run: would remove the operator managed block from ${VARS_FILE##*/}."
fi

if $DRY_RUN; then
    echo ""
    echo "[INFO] --dry-run: ${VARS_FILE##*/} would receive:"
    echo ""
    echo "${BLOCK}"
    exit 0
fi

# ------------------------------------------------------------------------------
# Splice the block into the file.
#
# Three cases, in order:
#   1. a managed block already exists -> replace it in place
#   2. no managed block, but the original hand-written sizing lines exist
#      -> drop those lines and insert the block where they started
#   3. neither -> append
# ------------------------------------------------------------------------------
cp "${VARS_FILE}" "${VARS_FILE}.bak"

BLOCK_FILE="$(mktemp)"
printf '%s\n' "${BLOCK}" > "${BLOCK_FILE}"

python3 - "${VARS_FILE}" "${BLOCK_FILE}" "${BEGIN_MARKER}" "${END_MARKER}" <<'PY'
import re, sys

vars_path, block_path, begin, end = sys.argv[1:5]
text = open(vars_path).read()
block = open(block_path).read().rstrip("\n")

# Case 1: replace an existing managed block.
pattern = re.compile(
    re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
if pattern.search(text):
    text = pattern.sub(lambda _: block, text, count=1)
    open(vars_path, "w").write(text)
    print("replaced")
    sys.exit(0)

# Case 2: remove the original hand-written sizing lines and their section
# headers, then insert the block at the position the first one occupied.
managed_vars = [
    "CONFLUENT_BROKER_REPLICAS", "CONFLUENT_REPLICATION_FACTOR",
    "CONFLUENT_MIN_INSYNC_REPLICAS", "CONFLUENT_PARTITIONS",
    "CONFLUENT_CLUSTER_ID", "CONFLUENT_STORAGE_CLASS",
    "CONFLUENT_BROKER_STORAGE_SIZE",
    "CONFLUENT_BROKER_CPU_REQUEST", "CONFLUENT_BROKER_MEM_REQUEST",
    "CONFLUENT_BROKER_CPU_LIMIT", "CONFLUENT_BROKER_MEM_LIMIT",
    "CONFLUENT_COMPONENT_CPU_REQUEST", "CONFLUENT_COMPONENT_MEM_REQUEST",
    "CONFLUENT_COMPONENT_CPU_LIMIT", "CONFLUENT_COMPONENT_MEM_LIMIT",
]
var_re = re.compile(r"^export (" + "|".join(managed_vars) + r")=")
# Section headers and comments that belonged to the replaced lines.
drop_headers = ("# ---- Cluster sizing", "# ---- Storage",
                "# ---- Resource requests / limits")

lines = text.split("\n")

# A header alone must never anchor the insert. "# ---- Storage" also introduces
# the cluster foundation block at the top of the file, and anchoring on it put
# the sizing block ABOVE the STG_CLASS_BLOCK definition that
# CONFLUENT_STORAGE_CLASS="${STG_CLASS_BLOCK}" expands from - which silently
# resolves to an empty storage class when the file is sourced. Only a managed
# variable marks the position; a header is dropped solely when one follows it.
def introduces_managed_var(start):
    for line in lines[start + 1:]:
        if var_re.match(line):
            return True
        # A blank line or a new section ends the header's reach.
        if not line.strip() or line.startswith("# ----"):
            return False
        if line.startswith("#"):
            continue
        return False
    return False

out, insert_at, dropping_comment = [], None, False
for idx, line in enumerate(lines):
    if var_re.match(line):
        if insert_at is None:
            insert_at = len(out)
        dropping_comment = False
        continue
    if line.startswith(drop_headers) and introduces_managed_var(idx):
        if insert_at is None:
            insert_at = len(out)
        dropping_comment = True
        continue
    # Drop comment lines that directly preceded//followed a managed var.
    if dropping_comment and (line.startswith("#") or not line.strip()):
        if line.strip() and line.startswith("#"):
            continue
        if not line.strip():
            dropping_comment = False
            continue
    dropping_comment = False
    out.append(line)

if insert_at is None:
    # Case 3: nothing to replace, append at end.
    text = text.rstrip("\n") + "\n\n" + block + "\n"
    open(vars_path, "w").write(text)
    print("appended")
else:
    out[insert_at:insert_at] = block.split("\n") + [""]
    open(vars_path, "w").write("\n".join(out))
    print("migrated")
PY

rm -f "${BLOCK_FILE}"

# Operator mode: splice the operator block (replace in place, else append after
# the sizing block). A switch to scripts mode removes it; the operator settings
# section stays (nothing reads it in scripts mode).
if [[ -n "${OP_BLOCK}" || "${DEPLOY_MODE_SWITCH_FROM}" == operator ]]; then
    OP_BLOCK_FILE="$(mktemp)"
    printf '%s\n' "${OP_BLOCK}" > "${OP_BLOCK_FILE}"
    _op_result="$(python3 - "${VARS_FILE}" "${OP_BLOCK_FILE}" "${OP_BEGIN_MARKER}" "${OP_END_MARKER}" <<'PY'
import re, sys

vars_path, block_path, begin, end = sys.argv[1:5]
text = open(vars_path).read()
block = open(block_path).read().rstrip("\n")
pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
if not block:
    # Remove the block together with the blank line in front of it.
    new = re.sub(r"\n*" + pattern.pattern + r"\n?", "\n", text, count=1, flags=re.DOTALL)
    if new != text:
        open(vars_path, "w").write(new.rstrip("\n") + "\n")
        print("removed")
    else:
        print("absent")
elif pattern.search(text):
    # A lambda, so backslashes in the block are never read as group references.
    open(vars_path, "w").write(pattern.sub(lambda _: block, text, count=1))
    print("replaced")
else:
    open(vars_path, "w").write(text.rstrip("\n") + "\n\n" + block + "\n")
    print("appended")
PY
)"
    rm -f "${OP_BLOCK_FILE}"
    [[ "${_op_result}" == removed ]] && echo "[INFO] Removed the operator managed block (scripts mode)."
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
echo "[INFO] Applied size '${SIZE}' to ${VARS_FILE##*/} (backup: ${VARS_FILE##*/}.bak)"
printf '  %-34s %s\n' \
    "brokers"              "${BROKERS}" \
    "replication factor"   "${RF}" \
    "min in-sync replicas" "${MIN_ISR}" \
    "default partitions"   "${PARTITIONS}" \
    "storage per broker"   "${STORAGE}" \
    "broker cpu/mem req"   "${B_CPU_REQ} / ${B_MEM_REQ}" \
    "broker cpu/mem limit" "${B_CPU_LIM} / ${B_MEM_LIM}" \
    "cluster id"           "${CLUSTER_ID} (${CLUSTER_ID_ORIGIN})"
if [[ -n "${OP_BLOCK}" ]]; then
    printf '  %-34s %s\n' \
        "deploy mode"            "operator (CFK through OLM)" \
        "KRaft controllers"      "${KRAFT[CONFLUENT_KRAFT_REPLICAS]:-?}" \
        "KRaft storage"          "${KRAFT[CONFLUENT_KRAFT_STORAGE_SIZE]:-?}" \
        "KRaft cpu/mem req"      "${KRAFT[CONFLUENT_KRAFT_CPU_REQUEST]:-?} / ${KRAFT[CONFLUENT_KRAFT_MEM_REQUEST]:-?}" \
        "KRaft cpu/mem limit"    "${KRAFT[CONFLUENT_KRAFT_CPU_LIMIT]:-?} / ${KRAFT[CONFLUENT_KRAFT_MEM_LIMIT]:-?}"
fi
echo ""
echo "[INFO] Next: scripts/install_confluent_platform/1.0_confluent_prep.sh"
mcm_generator_register "${VARS_FILE}"
