#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: source confluent_vars.sh LAST so its cluster/storage values
# win over the CP4D ones defined in cpd_vars.sh. Override to point these
# scripts at a different config:  ENV_TARGET=<name|path> ./<script>.sh
: "${ENV_TARGET:=confluent}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform - add or refresh web UI authentication
# ------------------------------------------------------------------------------
# Applies basic auth to a platform that is already running, without a
# destructive reinstall. Use it to:
#   - add authentication to a stack installed before auth existed (or with
#     CONFLUENT_AUTH_ENABLED=false)
#   - rotate the password on a stack that already has it
#   - remove authentication again (--disable)
#
# Only Control Center, Prometheus and Alertmanager carry auth configuration, so
# only those three are redeployed. The broker, Schema Registry, Connect, ksqlDB
# and REST Proxy are left untouched - no Kafka data is affected and no topic
# downtime is incurred.
#
# The manifests themselves are NOT duplicated here: this script sets the auth
# variables and re-runs 1.0_confluent_prep.sh + 1.1_confluent_install.sh with
# the non-monitoring components switched off, so there is only ever one
# definition of each manifest to keep correct.
#
# Usage:
#   ./x.2_confluent_add_auth.sh [--rotate] [--password <pw>] [--username <user>]
#                               [--disable] [--yes] [--dry-run] [--no-status]
#
#   --rotate         generate a new password, replacing the stored one
#   --password <pw>  set this exact password instead of generating one
#   --username <u>   set the username (default: CONFLUENT_AUTH_USERNAME)
#   --disable        remove authentication and redeploy the UIs open
#   --yes            skip the --disable confirmation prompt
#   --dry-run        report what would change, change nothing
#   --no-status      skip the closing status report
#
# With no flags it enables auth using the existing stored password when there is
# one, generating a password only if none exists. That makes a bare re-run
# idempotent and safe, so it runs straight through without asking; only
# --disable stops to confirm.
# ==============================================================================

ROTATE=false
DISABLE=false
ASSUME_YES=false
DRY_RUN=false
RUN_STATUS=true
PW_OVERRIDE=""
USER_OVERRIDE=""

_need_value() {
    [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }
}

while (( $# > 0 )); do
    case "$1" in
        --rotate)      ROTATE=true; shift ;;
        --disable)     DISABLE=true; shift ;;
        --password)    _need_value "$1" "${2:-}"; PW_OVERRIDE="$2"; shift 2 ;;
        --username)    _need_value "$1" "${2:-}"; USER_OVERRIDE="$2"; shift 2 ;;
        --yes|-y)      ASSUME_YES=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --no-status)   RUN_STATUS=false; shift ;;
        -h|--help)     sed -n '19,53p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

if $DISABLE && { $ROTATE || [[ -n "${PW_OVERRIDE}" ]]; }; then
    echo "[ERROR] --disable cannot be combined with --rotate or --password." >&2
    exit 1
fi
if $ROTATE && [[ -n "${PW_OVERRIDE}" ]]; then
    echo "[ERROR] --rotate and --password are mutually exclusive: one generates a" >&2
    echo "[ERROR] password, the other sets it explicitly." >&2
    exit 1
fi

PREP="${SCRIPT_DIR}/1.0_confluent_prep.sh"
INSTALL="${SCRIPT_DIR}/1.1_confluent_install.sh"
STATUS="${SCRIPT_DIR}/1.2_confluent_status.sh"
for _s in "${PREP}" "${INSTALL}"; do
    [[ -f "${_s}" ]] || { echo "[ERROR] Required script not found: ${_s}" >&2; exit 1; }
done

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_AUTH_SECRET:=confluent-auth}"

if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[ERROR] Project '${NS}' does not exist - nothing to reconfigure." >&2
    echo "[ERROR] Run 1.0_confluent_prep.sh and 1.1_confluent_install.sh first." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Work out the current state so the summary can report an accurate transition.
# ------------------------------------------------------------------------------
_current_user="$(oc get secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode || true)"
_c3_method="$(oc get deployment control-center -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CONTROL_CENTER_REST_AUTHENTICATION_METHOD")].value}' 2>/dev/null || true)"

if [[ "${_c3_method}" == "BASIC" ]]; then
    _current_state="enabled (user '${_current_user}')"
elif [[ -n "${_current_user}" ]]; then
    _current_state="credentials stored but NOT applied to the running components"
else
    _current_state="disabled - the web UIs are open"
fi

if $DISABLE; then
    _target_state="disabled"
elif $ROTATE; then
    _target_state="enabled with a NEW generated password"
elif [[ -n "${PW_OVERRIDE}" ]]; then
    _target_state="enabled with the supplied password"
elif [[ -n "${_current_user}" ]]; then
    _target_state="enabled, reusing the stored password"
else
    _target_state="enabled with a newly generated password"
fi

# Which of the three actually exist, so the plan reflects reality.
_targets=()
for _d in control-center prometheus alertmanager; do
    oc get deployment "${_d}" -n "${NS}" &>/dev/null && _targets+=("${_d}")
done

echo "=============================================================================="
echo " Confluent web UI authentication - project '${NS}'"
echo "=============================================================================="
echo "  current : ${_current_state}"
echo "  target  : ${_target_state}"
if (( ${#_targets[@]} == 0 )); then
    echo ""
    echo "[WARN] None of control-center / prometheus / alertmanager are deployed."
    echo "[WARN] Credentials will be provisioned, but there is nothing to redeploy."
    if [[ "${CONFLUENT_INSTALL_CONTROL_CENTER}" != "true" ]]; then
        echo "[WARN] CONFLUENT_INSTALL_CONTROL_CENTER is '${CONFLUENT_INSTALL_CONTROL_CENTER:-unset}'."
    fi
else
    echo "  redeploy: ${_targets[*]}"
fi
echo "  untouched: broker, schema-registry, connect, ksqldb-server, rest-proxy"
echo ""

if $DRY_RUN; then
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi

# Adding or rotating credentials only restarts the three web components - Kafka
# and its data are untouched - so it runs without confirmation. Use --dry-run to
# preview. Only --disable prompts, since that strips protection from endpoints
# that are reachable from outside the cluster.
if $DISABLE && ! $ASSUME_YES; then
    echo "This REMOVES authentication: the web UIs will be publicly reachable."
    printf "Continue? [y/N] "
    read -r _reply
    case "${_reply}" in
        y|Y|yes|YES) ;;
        *) echo "[INFO] Aborted."; exit 0 ;;
    esac
    echo ""
else
    echo "[INFO] Redeploying the listed components (brief web UI downtime; Kafka is unaffected)."
    echo ""
fi

# ------------------------------------------------------------------------------
# Step 1 - credentials
# ------------------------------------------------------------------------------
# 1.0_confluent_prep.sh owns credential provisioning; it is re-run here rather
# than duplicating the generation and bcrypt hashing logic. It is idempotent for
# everything else it does (namespace, service account, SCC, pull secret).
echo "------------------------------------------------------------------------------"
echo " Step 1/2: credentials"
echo "------------------------------------------------------------------------------"

_prep_args=()
if $DISABLE; then
    export CONFLUENT_AUTH_ENABLED="false"
else
    export CONFLUENT_AUTH_ENABLED="true"
    [[ -n "${USER_OVERRIDE}" ]] && export CONFLUENT_AUTH_USERNAME="${USER_OVERRIDE}"
    if [[ -n "${PW_OVERRIDE}" ]]; then
        export CONFLUENT_AUTH_PASSWORD="${PW_OVERRIDE}"
    elif $ROTATE; then
        # Clear any pinned password so prep generates one, and tell it to
        # discard the stored value.
        export CONFLUENT_AUTH_PASSWORD=""
        _prep_args+=(--regenerate-password)
    fi
fi

"${PREP}" "${_prep_args[@]}"

if $DISABLE; then
    # prep leaves the secrets alone when auth is off; remove them so the
    # cluster does not keep credentials that nothing uses.
    oc delete secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" --ignore-not-found >/dev/null
    oc delete secret "${CONFLUENT_AUTH_SECRET}-c3" -n "${NS}" --ignore-not-found >/dev/null
    echo "[INFO] Removed stored basic-auth secrets."
fi

# ------------------------------------------------------------------------------
# Step 2 - redeploy only the components that carry auth configuration
# ------------------------------------------------------------------------------
# The component gates in 1.1 are environment-driven, so switching the others off
# for this invocation confines the work to the monitoring stack. The broker
# StatefulSet and the shared services are still re-applied, but nothing in them
# changes, so those applies are no-ops.
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 2/2: redeploy web components"
echo "------------------------------------------------------------------------------"

if (( ${#_targets[@]} == 0 )) && [[ "${CONFLUENT_INSTALL_CONTROL_CENTER}" != "true" ]]; then
    echo "[INFO] Control Center is not enabled - nothing to redeploy."
else
    export CONFLUENT_INSTALL_SCHEMA_REGISTRY="false"
    export CONFLUENT_INSTALL_CONNECT="false"
    export CONFLUENT_INSTALL_KSQLDB="false"
    export CONFLUENT_INSTALL_REST_PROXY="false"
    export CONFLUENT_INSTALL_CONTROL_CENTER="true"

    "${INSTALL}"

    # A ConfigMap change does not restart a running pod on its own: Prometheus
    # and Alertmanager read the web config from the seeded emptyDir at startup,
    # so they must be restarted for new credentials to take effect. C3 is
    # restarted by its own spec change, but is included for the rotate case
    # where only the mounted secret changed.
    echo ""
    for _d in "${_targets[@]}"; do
        oc rollout restart "deployment/${_d}" -n "${NS}" >/dev/null
        echo "[INFO] Restarted deployment/${_d}."
    done
    for _d in "${_targets[@]}"; do
        oc rollout status "deployment/${_d}" -n "${NS}" --timeout="${CONFLUENT_ROLLOUT_TIMEOUT:-600s}"
    done
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================================="
if $DISABLE; then
    echo "[WARN] Authentication is now DISABLED - the web UIs are open."
else
    _final_user="$(oc get secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode || true)"
    echo "[INFO] Authentication is enabled - user '${_final_user}'."
    echo "[INFO] Password:"
    echo "[INFO]   oc get secret ${CONFLUENT_AUTH_SECRET} -n ${NS} -o jsonpath='{.data.password}' | base64 --decode"
    echo ""
    echo "[INFO] Refresh cp4d_config/confluent_instance_details.sh with the new"
    echo "[INFO] credentials by running 1.3_confluent_get_instance_details.sh."
fi
echo "=============================================================================="

if [[ "${RUN_STATUS}" == "true" && -f "${STATUS}" ]]; then
    echo ""
    "${STATUS}" || echo "[WARN] Status reported one or more components not ready (see above)."
fi
