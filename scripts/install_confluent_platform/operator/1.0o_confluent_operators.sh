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
# Confluent Platform (operator mode) - operators step
# ------------------------------------------------------------------------------
# Installs or reuses the operators the platform runs on, through OLM:
#   - Confluent for Kubernetes (CFK, package confluent-for-kubernetes)
#   - cp-fko (Confluent's Flink Kubernetes operator) when the Flink add-on is
#     configured with FLINK_OPERATOR_SOURCE=olm (the operator-mode default)
# One OwnNamespace install per target namespace (plan 15.4): the platform
# namespace, the Flink namespace and CONFLUENT_OPERATOR_EXTRA_NAMESPACES, or
# what CONFLUENT_OPERATOR_PACKAGES_PER_NS says. An operator that already
# watches a namespace is reused; a conflicting one stops the step ([BLOCKED],
# exit 2) - other OperatorGroups and Subscriptions are never edited.
#
# Steps:
#   [1/4] versions (--autoselect-latest: newest compatible set from the catalogs)
#   [2/4] the operator targets
#   [3/4] detect / install per namespace (OLM; Manual approval by default)
#   [4/4] Subscription env (ENABLE_CMF_DAY2_OPS for the Flink CMF resources)
#
# Runs first in full_installprocess-confluent_platform.sh in operator mode.
# In scripts mode (CONFLUENT_DEPLOY_MODE=scripts) it does nothing.
#
# Options:
#   --dry-run             render and server-dry-run everything, change nothing
#   --autoselect-latest   choose the newest compatible operator set (new installs only)
#   --persist             with --autoselect-latest: save the chosen set to the vars file
#   -h, --help            this text
#
# Exit status: 0 ok, 1 error, 2 blocked (a guard or conflict needs a decision).
# ==============================================================================

usage() { sed -n '/^# Confluent Platform (operator mode)/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

DRY_RUN=false
AUTOSELECT=false
[[ -n "${CFO_AUTOSELECT_LATEST:-}" ]] && AUTOSELECT=true
PERSIST=false
[[ -n "${CFO_AUTOSELECT_PERSIST:-}" ]] && PERSIST=true

while (( $# > 0 )); do
    case "$1" in
        --dry-run)           DRY_RUN=true; shift ;;
        --autoselect-latest) AUTOSELECT=true; shift ;;
        --persist)           PERSIST=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done
export DRY_RUN

if ! cf_is_operator_mode; then
    echo "[INFO] CONFLUENT_DEPLOY_MODE=scripts - the operators step does nothing."
    exit 0
fi
if ${PERSIST} && ! ${AUTOSELECT}; then
    echo "[ERROR] --persist needs --autoselect-latest." >&2
    exit 1
fi

cfo_entry all

echo "=============================================================================="
_dr=""
if [[ "${DRY_RUN}" == true ]]; then _dr=" - DRY RUN"; fi
echo "[INFO] Confluent operators (OLM)${_dr}"
echo "[INFO] Owner label: ${CFO_LABEL_OWNER_KEY}=${CFO_OWNER_ID}"
echo "=============================================================================="

# ------------------------------------------------------------------------------
echo "[1/4] Versions"
if ${AUTOSELECT}; then
    if ${PERSIST}; then cfo_autoselect_latest --persist; else cfo_autoselect_latest; fi
else
    _cfo_pkg_settings "${CFO_PKG_CFK}"
    echo "  ${_CFO_P_NAME}: channel ${_CFO_P_CHANNEL}, CSV ${_CFO_P_CSV:-<channel head>}, approval ${_CFO_P_APPROVAL}"
    if cf_flink_configured && [[ "$(cf_flink_operator_source)" == olm ]]; then
        _cfo_pkg_settings "${CFO_PKG_FKO}"
        echo "  ${_CFO_P_NAME}: channel ${_CFO_P_CHANNEL}, CSV ${_CFO_P_CSV:-<channel head>}, approval ${_CFO_P_APPROVAL} (CMF ${FLINK_CMF_CHART_VERSION})"
    fi
fi

# ------------------------------------------------------------------------------
echo "[2/4] Operator targets"
TARGETS="$(cfo_plan_targets all)"
if [[ -z "${TARGETS}" ]]; then
    echo "[INFO] No operator targets (CONFLUENT_OPERATOR_INSTALL_IN_PLATFORM_NS / _FLINK_NS are false and nothing else is listed)."
    exit 0
fi
printf '  %-32s %s\n' NAMESPACE PACKAGES
for _t in "${(@f)TARGETS}"; do
    printf '  %-32s %s\n' "${_t%% *}" "${_t#* }"
done

# ------------------------------------------------------------------------------
echo "[3/4] Operators per namespace"
BLOCKED=0
typeset -a CFK_NAMESPACES=()
_i=0
_n=${#${(@f)TARGETS}}
for _t in "${(@f)TARGETS}"; do
    (( _i += 1 ))
    _ns="${_t%% *}"
    _pkgs=(${=_t#* })
    echo "--- [${_i}/${_n}] ${_ns}: ${_pkgs[*]}"
    _rc=0
    cfo_ensure_operators "${_ns}" "${_pkgs[@]}" || _rc=$?
    case "${_rc}" in
        0) (( ${_pkgs[(Ie)${CFO_PKG_CFK}]} )) && CFK_NAMESPACES+=("${_ns}") ;;
        2) BLOCKED=1 ;;
        *) echo "[ERROR] Operators for ${_ns} failed (exit ${_rc})." >&2; cfo_print_summary; exit "${_rc}" ;;
    esac
done

# ------------------------------------------------------------------------------
echo "[4/4] Subscription env"
_cfk_ns="${FLINK_CFK_NAMESPACE:-${PROJECT_CONFLUENT_FLINK:-}}"
if cf_flink_configured && [[ -n "${_cfk_ns}" ]] && (( ! ${CFK_NAMESPACES[(Ie)${_cfk_ns}]} )); then
    CFK_NAMESPACES+=("${_cfk_ns}")
fi
for _ns in "${CFK_NAMESPACES[@]}"; do
    _rc=0
    cfo_ensure_cfk_env "${_ns}" || _rc=$?
    case "${_rc}" in
        0) ;;
        2) BLOCKED=1 ;;
        *) echo "[ERROR] Subscription env for ${_ns} failed (exit ${_rc})." >&2; cfo_print_summary; exit "${_rc}" ;;
    esac
done
(( ${#CFK_NAMESPACES} )) || echo "  (no CFK namespace to configure)"

cfo_print_summary
if (( BLOCKED )); then
    echo "[ERROR] One or more operators are BLOCKED (see the [BLOCKED] lines above)." >&2
    exit "${CFO_RC_BLOCKED}"
fi
echo "[INFO] Operators ready. Next: 1.0_confluent_prep.sh, then 1.1_confluent_install.sh."
