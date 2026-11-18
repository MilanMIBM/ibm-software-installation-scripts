#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"   # loads common, confluent, operator_install, version_resolver helpers

# ==============================================================================
# Confluent Platform - report or set the deploy mode (CONFLUENT_DEPLOY_MODE)
# ------------------------------------------------------------------------------
# Works in either mode and never stops at the scripts-mode guard: it is the tool
# that answers the guard. It reports
#   - the config file (ENV_TARGET_FILE) and its CONFLUENT_DEPLOY_MODE line,
#   - the mode the scripts resolve from it (unset or invalid = operator),
#   - what the Confluent project holds (read-only, after the login): a
#     scripts-mode install (statefulset/broker or the scripts' Deployments,
#     the same check as the operator-mode guard) and/or a CFK Kafka CR.
# With --set it writes CONFLUENT_DEPLOY_MODE into the config file after a
# confirmation. Switching modes on a live install is a fresh install (plan O19):
#   scripts -> operator: wipe the scripts-mode objects first with
#                        x.8_confluent_wipe_scripts_mode.sh (--keep-data keeps PVCs)
#   operator -> scripts: remove the CFK install first with x.0_confluent_uninstall.sh
#                        (operator mode, --delete-data --remove-operator)
#
# Usage:
#   ./x.9_confluent_set_deploy_mode.sh                     # report only
#   ./x.9_confluent_set_deploy_mode.sh --set scripts       # keep a scripts-mode install
#   ./x.9_confluent_set_deploy_mode.sh --set operator --yes
#   ./x.9_confluent_set_deploy_mode.sh --set scripts --dry-run
#   ./x.9_confluent_set_deploy_mode.sh --set scripts --all-clusters   # one run per cluster
#
#   --set MODE    scripts | operator - write CONFLUENT_DEPLOY_MODE to the config file
#   --yes         skip the confirmation prompt
#   --dry-run     report what would change, change nothing
#   -h, --help    this message
#
# Multi-cluster: one run per cluster; --all-clusters / --target-clusters fan out
# (policy allow, src/helpers/multi_cluster_helpers.sh).
# ==============================================================================

SET_MODE=""
ASSUME_YES=false
DRY_RUN=false

while (( $# > 0 )); do
    case "$1" in
        --set)       h_need_value "$1" "${2:-}"; SET_MODE="${(L)2}"; shift 2 ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        -h|--help)   sed -n '16,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

if [[ -n "${SET_MODE}" && "${SET_MODE}" != (scripts|operator) ]]; then
    echo "[ERROR] --set expects scripts or operator, got '${SET_MODE}'." >&2
    exit 1
fi

VARS_FILE="${ENV_TARGET_FILE:-}"
if [[ -z "${VARS_FILE}" || ! -f "${VARS_FILE}" ]]; then
    echo "[ERROR] No Confluent config file is loaded (ENV_TARGET_FILE='${VARS_FILE}')." >&2
    echo "        Create it with scripts/install_confluent_platform/0_confluent_prepare_template_config.sh or the notebook." >&2
    exit 1
fi
NS="${PROJECT_CONFLUENT_SERVER:-}"
[[ -n "${NS}" ]] || { echo "[ERROR] PROJECT_CONFLUENT_SERVER is not set in ${VARS_FILE}." >&2; exit 1; }

# ------------------------------------------------------------------------------
# [1/3] The config file
# ------------------------------------------------------------------------------
echo "[1/3] Config"
_line="$(grep -E '^export CONFLUENT_DEPLOY_MODE=' "${VARS_FILE}" | tail -1 || true)"
if [[ -n "${_line}" ]]; then
    # As the shell reads it: "double" or 'single' quoted, or bare up to the first blank.
    _file_value="${_line#*=}"
    case "${_file_value}" in
        \"*) _file_value="${_file_value#\"}"; _file_value="${_file_value%%\"*}" ;;
        \'*) _file_value="${_file_value#\'}"; _file_value="${_file_value%%\'*}" ;;
        *)   _file_value="${_file_value%%[[:space:]]*}" ;;
    esac
    _file_state="CONFLUENT_DEPLOY_MODE=\"${_file_value}\""
else
    _file_value=""
    _file_state="no CONFLUENT_DEPLOY_MODE line"
fi
CURRENT_MODE="$(cf_resolve_deploy_mode)"
printf '  %-22s %s\n' \
    "file"          "${VARS_FILE}" \
    "line"          "${_file_state}" \
    "resolved mode" "${CURRENT_MODE}$([[ -z "${_file_value}" ]] && print -r -- ' (unset means operator)')"

# ------------------------------------------------------------------------------
# [2/3] What the project holds (read-only)
# ------------------------------------------------------------------------------
echo "[2/3] Project ${NS} (read-only)"
eval "${OC_LOGIN}"

SCRIPTS_INSTALL=false
OPERATOR_INSTALL=false
if oc get namespace "${NS}" &>/dev/null; then
    # The guard's own check, with its banner silenced: here a hit is information.
    # The guard looks only in operator mode, so it runs in a subshell that says operator.
    _guard_rc=0
    ( CONFLUENT_DEPLOY_MODE=operator CFO_BANNER_FILE=""; cfo_guard_scripts_install platform ) 2>/dev/null || _guard_rc=$?
    (( _guard_rc == 0 || _guard_rc == 2 )) || echo "  [WARN] Could not read ${NS} completely (guard check exit ${_guard_rc})." >&2
    (( _guard_rc == 2 )) && SCRIPTS_INSTALL=true
    if [[ -n "$(oc get kafkas.platform.confluent.io -n "${NS}" -o name 2>/dev/null || true)" ]]; then
        OPERATOR_INSTALL=true
    fi
    printf '  %-22s %s\n' \
        "scripts-mode install" "$($SCRIPTS_INSTALL && print -r -- yes || print -r -- no)" \
        "CFK Kafka CR"         "$($OPERATOR_INSTALL && print -r -- yes || print -r -- no)"
else
    echo "  project ${NS} does not exist - nothing installed yet."
fi

_verdict() {   # <mode>
    case "$1" in
        operator)
            if $SCRIPTS_INSTALL; then
                echo "  [WARN] operator mode with a scripts-mode install in ${NS}: every operator-mode script stops at the guard." >&2
                echo "         Keep it: --set scripts. Replace it: x.8_confluent_wipe_scripts_mode.sh, then re-run the installer." >&2
            else
                echo "  [INFO] operator mode fits what ${NS} holds."
            fi ;;
        scripts)
            if $OPERATOR_INSTALL; then
                echo "  [WARN] scripts mode with a CFK Kafka CR in ${NS}: the scripts-mode installer would deploy a second Kafka next to it." >&2
                echo "         Remove the operator install first (x.0_confluent_uninstall.sh in operator mode), or keep --set operator." >&2
            else
                echo "  [INFO] scripts mode fits what ${NS} holds."
            fi ;;
    esac
}
_verdict "${CURRENT_MODE}"

# ------------------------------------------------------------------------------
# [3/3] Set the mode (only with --set)
# ------------------------------------------------------------------------------
if [[ -z "${SET_MODE}" ]]; then
    echo "[3/3] Nothing to set (report only; use --set scripts|operator)."
    exit 0
fi
echo "[3/3] Set CONFLUENT_DEPLOY_MODE=${SET_MODE}"
if [[ "${_file_value}" == "${SET_MODE}" ]]; then
    echo "  [INFO] ${VARS_FILE##*/} already says CONFLUENT_DEPLOY_MODE=\"${SET_MODE}\" - nothing to change."
    exit 0
fi
SCRIPTS_INSTALL_NOTE=""
[[ "${SET_MODE}" == operator ]] && $SCRIPTS_INSTALL && SCRIPTS_INSTALL_NOTE=" (the scripts-mode install in ${NS} then blocks every operator-mode script until x.8 wipes it)"
[[ "${SET_MODE}" == scripts ]] && $OPERATOR_INSTALL && SCRIPTS_INSTALL_NOTE=" (a CFK install is running in ${NS}; scripts mode does not manage it)"
_verdict "${SET_MODE}"

if $DRY_RUN; then
    cf_dry_run "set CONFLUENT_DEPLOY_MODE=\"${SET_MODE}\" in ${VARS_FILE}${SCRIPTS_INSTALL_NOTE}"
    exit 0
fi
if ! $ASSUME_YES; then
    h_confirm "Write CONFLUENT_DEPLOY_MODE=\"${SET_MODE}\" to ${VARS_FILE##*/}${SCRIPTS_INSTALL_NOTE}?" || {
        echo "[INFO] Nothing changed."; exit 0; }
fi

if [[ -n "${_line}" ]]; then
    cf_persist_var "${VARS_FILE}" CONFLUENT_DEPLOY_MODE "${SET_MODE}"
else
    # The same commented snippet the generators write (contract §7.3).
    cat >> "${VARS_FILE}" <<EOF

# ---- Deploy mode ---------------------------------------------------------------
# scripts  = the repo renders and applies raw manifests (StatefulSet broker, Deployments, ...).
# operator = Confluent for Kubernetes (CFK) and cp-fko, installed through OLM, run the platform.
# Unset or any other value means operator; a scripts-mode install in the namespace then stops every script.
export CONFLUENT_DEPLOY_MODE="${SET_MODE}"
EOF
    echo "[INFO] CONFLUENT_DEPLOY_MODE=${SET_MODE} saved to ${VARS_FILE##*/}."
fi
