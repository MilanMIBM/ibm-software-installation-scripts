#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ==============================================================================
# Confluent Platform - template the sizing block in confluent_vars.sh
# ------------------------------------------------------------------------------
# Applies a t-shirt size to cp4d_config/confluent_vars.sh, adding the sizing
# variables if absent and overwriting them if already present. Individual values
# can be overridden with flags, which always win over the size preset.
#
#   ./0_confluent_prepare_template_config.sh                  # defaults to small
#   ./0_confluent_prepare_template_config.sh --size medium --partitions 12
#   ./0_confluent_prepare_template_config.sh --size xsmall --regenerate-cluster-id
#   ./0_confluent_prepare_template_config.sh --size large --dry-run
#
# Deliberately does NOT source the config or contact the cluster: it is a pure
# file-rewriting step that runs before 1.0_confluent_prep.sh.
# ==============================================================================

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/confluent_vars.sh"

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
  -h, --help                this message

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

# A flag's value must exist and must not itself look like a flag, otherwise
# "--brokers --dry-run" would silently consume the next option as a value.
_need_value() {
    [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }
}

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
        --size)                   _need_value "$1" "${2:-}"; SIZE="$2"; shift 2 ;;
        --brokers)                _need_value "$1" "${2:-}"; OVERRIDE[BROKERS]="$2"; shift 2 ;;
        --replication-factor)     _need_value "$1" "${2:-}"; OVERRIDE[RF]="$2"; shift 2 ;;
        --partitions)             _need_value "$1" "${2:-}"; OVERRIDE[PARTITIONS]="$2"; shift 2 ;;
        --storage)                _need_value "$1" "${2:-}"; OVERRIDE[STORAGE]="$2"; shift 2 ;;
        --storage-class)          _need_value "$1" "${2:-}"; STORAGE_CLASS_OVERRIDE="$2"; shift 2 ;;
        --broker-cpu-request)     _need_value "$1" "${2:-}"; OVERRIDE[B_CPU_REQ]="$2"; shift 2 ;;
        --broker-cpu-limit)       _need_value "$1" "${2:-}"; OVERRIDE[B_CPU_LIM]="$2"; shift 2 ;;
        --broker-mem-request)     _need_value "$1" "${2:-}"; OVERRIDE[B_MEM_REQ]="$2"; shift 2 ;;
        --broker-mem-limit)       _need_value "$1" "${2:-}"; OVERRIDE[B_MEM_LIM]="$2"; shift 2 ;;
        --component-cpu-request)  _need_value "$1" "${2:-}"; OVERRIDE[C_CPU_REQ]="$2"; shift 2 ;;
        --component-cpu-limit)    _need_value "$1" "${2:-}"; OVERRIDE[C_CPU_LIM]="$2"; shift 2 ;;
        --component-mem-request)  _need_value "$1" "${2:-}"; OVERRIDE[C_MEM_REQ]="$2"; shift 2 ;;
        --component-mem-limit)    _need_value "$1" "${2:-}"; OVERRIDE[C_MEM_LIM]="$2"; shift 2 ;;
        --cluster-id)             _need_value "$1" "${2:-}"; CLUSTER_ID_OVERRIDE="$2"; shift 2 ;;
        --overwrite-cluster-id)   _need_value "$1" "${2:-}"; REGEN_ID="$(_parse_bool "$1" "$2")"; shift 2 ;;
        --regenerate-cluster-id)  REGEN_ID=true; shift ;;
        --dry-run)                DRY_RUN=true; shift ;;
        -h|--help)                usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

# ------------------------------------------------------------------------------
# Create the config if it does not exist yet.
#
# cp4d_config/ is gitignored, so a fresh clone has no confluent_vars.sh at all.
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
CPD_VARS_FILE="${REPO_ROOT}/cp4d_config/cpd_vars.sh"

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
_platform_defaults=(
    'CONFLUENT_VERSION|8.2.0|# ---- Images ------------------------------------------------------------------
# Tag applied to every confluentinc/cp-* image. "latest" tracks the newest but rely on a named versiion like 8.2.0
# published build; pin a version (7.5.0, 8.0.0, ...) for a reproducible install.'
    'CONFLUENT_REGISTRY|docker.io/confluentinc|# Registry the cp-* images are pulled from. Override for an air-gapped mirror.'
    'CONFLUENT_CONNECT_IMAGE|docker.io/cnfldemos/cp-server-connect-datagen:0.6.4-7.6.0|# The Connect image ships from a separate org with the datagen connector baked
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
    'CONFLUENT_SASL_ENABLED|true|# ---- Kafka client authentication (SASL/SCRAM) --------------------------------
# Independent of the web-UI auth above: this secures the Kafka wire protocol.
# Enabling it makes the brokers reject unauthenticated clients.'
    'CONFLUENT_SASL_MECHANISM|SCRAM-SHA-512|'
    'CONFLUENT_SASL_ADMIN_USER|confluent-admin|'
    'CONFLUENT_SASL_CLIENTS|app-client|# Comma-separated. One SCRAM credential is minted per name.'
    'CONFLUENT_SASL_SECRET|confluent-sasl|'
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
    'CONFLUENT_LDAP_IMAGE|docker.io/bitnamilegacy/openldap:2.6.10|# ---- Bundled OpenLDAP (CONFLUENT_MDS_USER_STORE=LDAP) ------------------------'
    'CONFLUENT_LDAP_PORT|1389|'
    'CONFLUENT_LDAP_DOMAIN|confluent.io|# Base DN is derived from this: confluent.io -> dc=confluent,dc=io'
    'CONFLUENT_LDAP_ADMIN_USER|admin|'
    'CONFLUENT_LDAP_SECRET|confluent-ldap|'
    'CONFLUENT_KEYCLOAK_IMAGE|quay.io/keycloak/keycloak:26.0|# ---- Bundled Keycloak (CONFLUENT_MDS_USER_STORE=OAUTH) -----------------------
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
# is SASL_SSL (encrypted) rather than the SASL_PLAINTEXT used inside the cluster.
# Provisioned by x.4_confluent_add_external_access.sh.'
    'CONFLUENT_EXTERNAL_KAFKA_PORT|9094|# Container port for the EXTERNAL listener; advertised on 443 via the routes.'
    'CONFLUENT_EXTERNAL_TLS_SECRET|confluent-kafka-tls|# Holds the generated CA plus the per-broker keystore/truststore.'
    'CONFLUENT_EXTERNAL_CERT_VALIDITY_DAYS|825|'
    'CONFLUENT_C3_VERSION|2.5.0|# ---- Control Center / monitoring ---------------------------------------------
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
    # Feature toggles are written as ${VAR:-default} so that a parent script can
    # export a different value and have it survive: x.2/x.4 flip these on and
    # then invoke 1.1_confluent_install.sh, which re-sources this file. A plain
    # assignment would silently overwrite the export and the feature would look
    # like it applied while changing nothing.
    case "${_name}" in
        *_ENABLED)
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
echo ""
echo "[INFO] Next: src/scripts/confluent_install/1.0_confluent_prep.sh"
