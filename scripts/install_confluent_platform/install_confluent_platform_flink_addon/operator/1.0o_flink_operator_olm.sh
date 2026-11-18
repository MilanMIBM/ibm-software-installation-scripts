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
# Confluent Platform for Apache Flink (operator mode) - Flink operator step
# ------------------------------------------------------------------------------
# Installs or reuses, through OLM:
#   - cp-fko (Confluent's Flink Kubernetes operator) in PROJECT_CONFLUENT_FLINK
#     (FLINK_OPERATOR_SOURCE=olm; "existing" only checks that one watches it)
#   - Confluent for Kubernetes in FLINK_CFK_NAMESPACE when the CMF resources
#     are CFK CRs (FLINK_CMF_RESOURCE_MODE=cfk) and no CFK watches it yet, with
#     ENABLE_CMF_DAY2_OPS=true on its Subscription
# Guards (plan C2-C4, C10): a Helm Flink operator watching the namespace, the
# community flink-kubernetes-operator, or a cp-fko of another version on the
# cluster stops the step ([BLOCKED], exit 2). The CMF chart and the cp-fko
# channel must be a known pair (CMF 2.5 - stable-v1.16, CMF 2.4 - stable-v1.15).
#
# Steps:
#   [1/4] versions (--autoselect-latest: newest compatible set)
#   [2/4] targets and the CMF / cp-fko pairing
#   [3/4] detect / install per namespace
#   [4/4] Subscription env (ENABLE_CMF_DAY2_OPS)
#
# Runs first in full_installprocess-confluent_flink.sh when the Flink operator
# source is not helm. With FLINK_OPERATOR_SOURCE=helm it does nothing.
#
# Options:
#   --dry-run             render and server-dry-run everything, change nothing
#   --autoselect-latest   choose the newest compatible operator set (new installs only)
#   --persist             with --autoselect-latest: save the chosen set to the vars file
#   -h, --help            this text
#
# Exit status: 0 ok, 1 error, 2 blocked (a guard or conflict needs a decision).
# ==============================================================================

usage() { sed -n '/^# Confluent Platform for Apache Flink (operator mode)/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

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

if ! cf_flink_is_olm; then
    echo "[INFO] FLINK_OPERATOR_SOURCE=helm - the operator step does nothing."
    exit 0
fi
if ${PERSIST} && ! ${AUTOSELECT}; then
    echo "[ERROR] --persist needs --autoselect-latest." >&2
    exit 1
fi

cfo_entry flink

FLINK_NS="${PROJECT_CONFLUENT_FLINK}"
CFK_NS="${FLINK_CFK_NAMESPACE:-${FLINK_NS}}"
SOURCE="$(cf_flink_operator_source)"
CMF_MODE="$(cf_flink_cmf_resource_mode)"

_dr=""
if [[ "${DRY_RUN}" == true ]]; then _dr=" - DRY RUN"; fi
echo "=============================================================================="
echo "[INFO] Confluent Flink operator (cp-fko via OLM)${_dr}"
echo "[INFO] Flink namespace ${FLINK_NS}, operator source ${SOURCE}, CMF resources ${CMF_MODE} (CFK namespace ${CFK_NS})"
echo "=============================================================================="

# ------------------------------------------------------------------------------
echo "[1/4] Versions"
if ${AUTOSELECT}; then
    if ${PERSIST}; then cfo_autoselect_latest --persist; else cfo_autoselect_latest; fi
fi
_pair="$(_cfo_config_py fko-for-cmf "${FLINK_CMF_CHART_VERSION}")" || {
    echo "[ERROR] FLINK_CMF_CHART_VERSION=${FLINK_CMF_CHART_VERSION} has no cp-fko pairing in the version catalog." >&2
    exit 1
}
_cfo_pkg_settings "${CFO_PKG_FKO}"
echo "  CMF ${FLINK_CMF_CHART_VERSION} pairs with cp-fko ${_pair%% *} (${_pair#* })"
echo "  ${_CFO_P_NAME}: channel ${_CFO_P_CHANNEL}, CSV ${_CFO_P_CSV:-<channel head>}, approval ${_CFO_P_APPROVAL}"
if [[ "${_CFO_P_CHANNEL}" != "${_pair%% *}" ]]; then
    # cfo_check_config refuses a set FLINK_OLM_CHANNEL that breaks the pair; this catches a derived one.
    echo "[ERROR] cp-fko channel ${_CFO_P_CHANNEL} does not match CMF ${FLINK_CMF_CHART_VERSION} (needs ${_pair%% *}; plan O7)." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
echo "[2/4] Targets"
typeset -A PKGS_OF=()
typeset -a ORDER=()
_add() {   # <ns> <pkg>
    if [[ -z "${PKGS_OF[$1]+x}" ]]; then ORDER+=("$1"); PKGS_OF[$1]="$2"; else PKGS_OF[$1]+=" $2"; fi
}
# cp-fko first in the Flink namespace (olm installs, existing only detects - cfo_ensure_operators handles both)
_add "${FLINK_NS}" "${CFO_PKG_FKO}"
if [[ "${CMF_MODE}" == cfk ]]; then
    _cfo_pkg_settings "${CFO_PKG_CFK}"
    cfo_detect "${_CFO_P_NAME}" "${CFK_NS}"
    case "${CFO_RESULT}" in
        reuse) echo "  CFK already watches ${CFK_NS} (${CFO_NS}/${CFO_CSV}) - reusing it" ;;
        *)     _add "${CFK_NS}" "${CFO_PKG_CFK}" ;;
    esac
fi
printf '  %-32s %s\n' NAMESPACE PACKAGES
for _ns in "${ORDER[@]}"; do
    # CFK before cp-fko inside one namespace (one InstallPlan batch)
    _p=(${=PKGS_OF[$_ns]})
    _sorted=()
    (( ${_p[(Ie)${CFO_PKG_CFK}]} )) && _sorted+=("${CFO_PKG_CFK}")
    (( ${_p[(Ie)${CFO_PKG_FKO}]} )) && _sorted+=("${CFO_PKG_FKO}")
    PKGS_OF[$_ns]="${_sorted[*]}"
    printf '  %-32s %s\n' "${_ns}" "${PKGS_OF[$_ns]}"
done

# ------------------------------------------------------------------------------
echo "[3/4] Operators per namespace"
BLOCKED=0
_i=0
for _ns in "${ORDER[@]}"; do
    (( _i += 1 ))
    _pkgs=(${=PKGS_OF[$_ns]})
    echo "--- [${_i}/${#ORDER}] ${_ns}: ${_pkgs[*]}"
    _rc=0
    cfo_ensure_operators "${_ns}" "${_pkgs[@]}" || _rc=$?
    case "${_rc}" in
        0) ;;
        2) BLOCKED=1 ;;
        *) echo "[ERROR] Operators for ${_ns} failed (exit ${_rc})." >&2; cfo_print_summary; exit "${_rc}" ;;
    esac
done

# ------------------------------------------------------------------------------
echo "[4/4] Subscription env"
if [[ "${CMF_MODE}" == cfk ]] && (( ! BLOCKED )); then
    _rc=0
    cfo_ensure_cfk_env "${CFK_NS}" || _rc=$?
    case "${_rc}" in
        0) ;;
        2) BLOCKED=1 ;;
        *) echo "[ERROR] Subscription env for ${CFK_NS} failed (exit ${_rc})." >&2; cfo_print_summary; exit "${_rc}" ;;
    esac
else
    echo "  (CMF resources through the CLI - nothing to set)"
fi

cfo_print_summary
if (( BLOCKED )); then
    echo "[ERROR] The Flink operator step is BLOCKED (see the [BLOCKED] lines above)." >&2
    exit "${CFO_RC_BLOCKED}"
fi
echo "[INFO] Flink operator ready. Next: 1.0_flink_prep.sh, then 1.1_flink_install.sh."
