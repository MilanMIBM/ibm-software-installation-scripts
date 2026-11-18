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
# Confluent Platform (operator mode) - OLM operator upgrades
# ------------------------------------------------------------------------------
# Looks after the OLM Subscriptions of CFK (confluent-for-kubernetes) and cp-fko
# that operator mode installed (label confluent.ibm-scripts/installed-by).
#
#   --check (default)   per Subscription: installed CSV, channel, approval,
#                       pending InstallPlan; plus the newest compatible set
#                       from the catalogs (--autoselect-latest report)
#   --set-approval X    Manual | Automatic on our Subscriptions (others only with
#                       CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING=true);
#                       --persist saves it to the vars file
#   --channel CH        move to another channel, and/or
#   --approve           approve the pending upgrade InstallPlan:
#       [1/5] annotate our CFK CRs platform.confluent.io/block-reconcile=true
#       [2/5] patch the channel / approve the plan. OLM puts every Subscription
#             of a namespace into one InstallPlan (V23): when the plan also
#             upgrades the other operator, a [WARN] names it and the script asks
#             (--yes skips the question; --dry-run prints it and stops)
#       [3/5] wait for the new CSV
#       [4/5] CFK: spec.image.init of our CRs to the new init tag; persist
#             CONFLUENT_OPERATOR_INIT_IMAGE
#       [5/5] remove the annotation and wait for the rolls
#
# Scope: CFK by default, --flink for cp-fko, --all for both. A cp-fko channel
# that does not match FLINK_CMF_CHART_VERSION (the CMF/FKO pair) is refused.
#
# Usage:
#   ./x.7_confluent_operator_upgrade.sh [--check] [--flink | --all]
#        [--set-approval Manual|Automatic [--persist]]
#        [--channel CH] [--approve] [--yes] [--dry-run]
#
# Exit status: 0 ok, 1 error, 2 blocked.
# ==============================================================================

usage() { sed -n '/^# Confluent Platform (operator mode) - OLM operator upgrades/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

MODE_CHECK=false
SCOPE=platform
SET_APPROVAL=""
PERSIST=false
CHANNEL=""
APPROVE=false
ASSUME_YES=false
DRY_RUN=false

while (( $# > 0 )); do
    case "$1" in
        --check)        MODE_CHECK=true; shift ;;
        --flink)        SCOPE=flink; shift ;;
        --all)          SCOPE=all; shift ;;
        --set-approval) h_need_value "$1" "${2:-}"; SET_APPROVAL="$2"; shift 2 ;;
        --persist)      PERSIST=true; shift ;;
        --channel)      h_need_value "$1" "${2:-}"; CHANNEL="$2"; shift 2 ;;
        --approve)      APPROVE=true; shift ;;
        --yes|-y)       ASSUME_YES=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

if ! cf_is_operator_mode; then
    echo "[ERROR] x.7 manages OLM operators - operator mode only." >&2
    exit 1
fi
if [[ -n "${SET_APPROVAL}" ]]; then
    case "${SET_APPROVAL:l}" in
        manual)    SET_APPROVAL=Manual ;;
        automatic) SET_APPROVAL=Automatic ;;
        *) echo "[ERROR] --set-approval takes Manual or Automatic (got '${SET_APPROVAL}')." >&2; exit 1 ;;
    esac
fi
if [[ -n "${SET_APPROVAL}" ]] && { [[ -n "${CHANNEL}" ]] || ${APPROVE}; }; then
    echo "[ERROR] --set-approval cannot be combined with --channel or --approve." >&2
    exit 1
fi
if ${PERSIST} && [[ -z "${SET_APPROVAL}" ]]; then
    echo "[ERROR] --persist goes with --set-approval." >&2
    exit 1
fi
# CONTRACT-DEVIATION (approved 2026-11-18): --channel with --all is refused - a channel belongs to one
# package (CFK and cp-fko have different channel names), so one value cannot move both.
if [[ -n "${CHANNEL}" && "${SCOPE}" == all ]]; then
    echo "[ERROR] --channel names one package's channel: use it with the default scope (CFK) or --flink." >&2
    exit 1
fi
if [[ -z "${SET_APPROVAL}${CHANNEL}" ]] && ! ${APPROVE}; then MODE_CHECK=true; fi
export DRY_RUN

case "${SCOPE}" in
    platform) PKGS=("${CFO_PKG_CFK}") ;;
    flink)    PKGS=("${CFO_PKG_FKO}") ;;
    all)      PKGS=("${CFO_PKG_CFK}" "${CFO_PKG_FKO}") ;;
esac

# cp-fko channel lock (CMF/FKO pair, plan O7 / C10)
if [[ -n "${CHANNEL}" && "${SCOPE}" == flink ]]; then
    _pair="$(_cfo_config_py fko-for-cmf "${FLINK_CMF_CHART_VERSION:-}" 2>/dev/null || true)"
    if [[ -z "${_pair}" ]]; then
        echo "[ERROR] Cannot tell the cp-fko channel for FLINK_CMF_CHART_VERSION='${FLINK_CMF_CHART_VERSION:-}'." >&2
        exit 1
    fi
    if [[ "${CHANNEL}" != "${_pair%% *}" ]]; then
        echo "[ERROR] cp-fko channel ${CHANNEL} breaks the CMF/FKO pair: CMF ${FLINK_CMF_CHART_VERSION} needs ${_pair%% *}." >&2
        echo "[ERROR] Change FLINK_CMF_CHART_VERSION first (and upgrade CMF), then move cp-fko." >&2
        exit 1
    fi
fi

# Checks and guard for the packages in scope only: a CFK upgrade does not need a valid Flink config.
cfo_entry "${SCOPE}"

_owner="${CFO_OWNER_ID}"
_cfo_int "${CONFLUENT_OPERATOR_INSTALLPLAN_TIMEOUT:-}" 300; T_PLAN="${REPLY}"
_cfo_int "${CONFLUENT_OPERATOR_CSV_TIMEOUT:-}" 600; T_CSV="${REPLY}"
_cfo_int "${CONFLUENT_OPERATOR_KAFKA_TIMEOUT:-}" 900; T_KAFKA="${REPLY}"
_cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600; T_COMPONENT="${REPLY}"
WORK="$(_cfo_mktemp)"
trap 'rm -rf "${WORK}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

# ------------------------------------------------------------------------------
# Our Subscriptions in scope: lines "<ns>|<sub>|<pkg>|<owned>|<channel>|<approval>|<installed>|<current>|<state>|<plan>"
# ------------------------------------------------------------------------------
_targets="$(cfo_plan_targets all)" || { echo "[ERROR] Cannot work out the operator namespaces." >&2; exit 1; }
typeset -a NAMESPACES=()
for _t in ${(f)_targets}; do (( ${NAMESPACES[(Ie)${_t%% *}]} )) || NAMESPACES+=("${_t%% *}"); done

typeset -a SUBS=()
for _ns in "${NAMESPACES[@]}"; do
    _cfo_json "${WORK}/subs.json" get subscriptions.operators.coreos.com -n "${_ns}" \
        || { echo "[ERROR] Cannot read the Subscriptions in ${_ns}." >&2; exit 1; }
    for _pkg in "${PKGS[@]}"; do
        _cfo_pkg_settings "${_pkg}"
        _rows="$(cfo_python -c 'import json, sys
d = json.load(open(sys.argv[1]))
ns, pkg, owner = sys.argv[2], sys.argv[3], sys.argv[4]
for s in d.get("items") or []:
    spec, st, m = s.get("spec") or {}, s.get("status") or {}, s.get("metadata") or {}
    if spec.get("name") != pkg:
        continue
    owned = (m.get("labels") or {}).get("confluent.ibm-scripts/installed-by") == owner
    plan = (st.get("installPlanRef") or {}).get("name", "")
    print("|".join([ns, m.get("name", ""), pkg, "true" if owned else "false", spec.get("channel", ""),
                    spec.get("installPlanApproval", ""), st.get("installedCSV", ""), st.get("currentCSV", ""),
                    st.get("state", ""), plan]))' "${WORK}/subs.json" "${_ns}" "${_CFO_P_NAME}" "${_owner}")"
        for _r in ${(f)_rows}; do SUBS+=("${_r}"); done
    done
done

if (( ${#SUBS} == 0 )); then
    echo "[INFO] No ${PKGS[*]} Subscription in ${NAMESPACES[*]:-the operator namespaces} - nothing to manage."
    exit 0
fi

_print_subs() {
    printf '  %-24s %-26s %-6s %-12s %-10s %-38s %-38s %s\n' NAMESPACE SUBSCRIPTION OURS CHANNEL APPROVAL INSTALLED CURRENT PENDING-PLAN
    local row
    for row in "${SUBS[@]}"; do
        local -a f=("${(@s:|:)row}")
        local pending="-"
        if [[ -n "${f[10]}" ]]; then
            local appr
            appr="$(oc get installplans.operators.coreos.com "${f[10]}" -n "${f[1]}" -o jsonpath='{.spec.approved}' 2>/dev/null || true)"
            [[ "${appr}" == false ]] && pending="${f[10]}"
        fi
        printf '  %-24s %-26s %-6s %-12s %-10s %-38s %-38s %s\n' "${f[1]}" "${f[2]}" "${f[4]}" "${f[5]:--}" "${f[6]:--}" \
            "${f[7]:--}" "${f[8]:--}" "${pending}"
    done
}

# ------------------------------------------------------------------------------
# --check
# ------------------------------------------------------------------------------
if ${MODE_CHECK}; then
    echo "=============================================================================="
    echo " Confluent operators (OLM) - check"
    echo "=============================================================================="
    _print_subs
    echo ""
    cfo_autoselect_latest || echo "[WARN] The catalog report failed (see above)." >&2
    exit 0
fi

# ------------------------------------------------------------------------------
# --set-approval
# ------------------------------------------------------------------------------
if [[ -n "${SET_APPROVAL}" ]]; then
    echo "[INFO] installPlanApproval -> ${SET_APPROVAL}"
    _blocked=0
    _patch="{\"spec\":{\"installPlanApproval\":\"${SET_APPROVAL}\"}}"
    for _row in "${SUBS[@]}"; do
        _f=("${(@s:|:)_row}")
        if [[ "${_f[6]}" == "${SET_APPROVAL}" ]]; then
            echo "[INFO] Subscription ${_f[2]} in ${_f[1]} is already ${SET_APPROVAL}."
            continue
        fi
        if [[ "${_f[4]}" != true ]] && ! h_is_true "${CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING:-false}"; then
            _cfo_vars_file
            cfo_banner "Subscription ${_f[2]} in ${_f[1]} is not ours - its approval is left as ${_f[6]}" \
                "found: Subscription/${_f[2]} in ${_f[1]}" \
                "Choose one:" \
                "  1. change it yourself: oc patch subscriptions.operators.coreos.com ${_f[2]} -n ${_f[1]} --type=merge -p '${_patch}'" \
                "  2. let the scripts patch it: set CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING=\"true\" in ${REPLY}"
            _blocked=1
            continue
        fi
        cf_dry_run oc patch subscriptions.operators.coreos.com "${_f[2]}" -n "${_f[1]}" --type=merge -p "${_patch}" \
            || { echo "[ERROR] Patching Subscription ${_f[2]} in ${_f[1]} failed." >&2; exit 1; }
        [[ "${DRY_RUN}" == true ]] || echo "[INFO] Subscription ${_f[2]} in ${_f[1]}: installPlanApproval ${SET_APPROVAL}."
    done
    [[ "${SET_APPROVAL}" == Automatic ]] && echo "[WARN] Automatic approval: OLM applies minor bumps on its own and rolls the cluster without block-reconcile." >&2
    if ${PERSIST}; then
        _cfo_vars_file
        for _pkg in "${PKGS[@]}"; do
            _var=CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL
            [[ "${_pkg}" == "${CFO_PKG_FKO}" ]] && _var=FLINK_OLM_INSTALL_PLAN_APPROVAL
            if [[ "${DRY_RUN}" == true ]]; then
                echo "  [DRY-RUN] persist ${_var}=${SET_APPROVAL} in ${REPLY:t}"
            else
                cf_persist_var "${REPLY}" "${_var}" "${SET_APPROVAL}" || exit 1
            fi
        done
    fi
    (( _blocked == 0 )) || exit "${CFO_RC_BLOCKED}"
    exit 0
fi

# ------------------------------------------------------------------------------
# --channel / --approve (plan 4.4 flow)
# ------------------------------------------------------------------------------
typeset -a OURS=()
for _row in "${SUBS[@]}"; do
    _f=("${(@s:|:)_row}")
    if [[ "${_f[4]}" == true ]]; then
        OURS+=("${_row}")
    else
        echo "[INFO] Subscription ${_f[2]} in ${_f[1]} is not ours - not upgraded here."
    fi
done
(( ${#OURS} )) || { echo "[ERROR] None of the ${PKGS[*]} Subscriptions is ours (${CFO_LABEL_OWNER_KEY}=${_owner})." >&2; exit 1; }

_has_cfk=false
(( ${PKGS[(Ie)${CFO_PKG_CFK}]} )) && _has_cfk=true

# CFK CRs we own, per namespace watched by one of our CFK Subscriptions: "<ns> <Kind>/<name>"
typeset -a CRS=()
if ${_has_cfk}; then
    for _row in "${OURS[@]}"; do
        _f=("${(@s:|:)_row}")
        [[ "${_f[3]}" == "${CFO_PKG_CFK}" || "${_f[3]}" == "${CONFLUENT_OPERATOR_PACKAGE:-}" ]] || continue
        _rc=0
        _list="$(cfo_list_crs "${_f[1]}")" || _rc=$?
        (( _rc == 0 )) || { echo "[ERROR] Cannot list the CFK CRs in ${_f[1]} - nothing changed." >&2; exit 1; }
        for _l in ${(f)_list}; do
            [[ "${_l##* }" == true ]] && CRS+=("${_f[1]} ${_l% *}")
        done
    done
fi

_annotate() {   # <on|off>
    local c ns ref res
    for c in "${CRS[@]}"; do
        ns="${c%% *}" ref="${c#* }" res="$(cfo_resource "${ref%%/*}")"
        if [[ "$1" == on ]]; then
            cf_dry_run oc annotate "${res}" "${ref#*/}" -n "${ns}" "${CFO_ANNOT_BLOCK_RECONCILE}=true" --overwrite || return 1
        else
            cf_dry_run oc annotate "${res}" "${ref#*/}" -n "${ns}" "${CFO_ANNOT_BLOCK_RECONCILE}-" || return 1
        fi
    done
}

echo "=============================================================================="
_dr=""; [[ "${DRY_RUN}" == true ]] && _dr=" - DRY RUN"
echo " Confluent operators (OLM) - upgrade${_dr}"
echo "=============================================================================="
_print_subs
echo ""

echo "[1/5] Block reconcile on our CFK CRs (${#CRS})"
if (( ${#CRS} )); then
    _annotate on || { echo "[ERROR] Annotating the CRs failed - nothing upgraded; check the annotations by hand." >&2; exit 1; }
else
    echo "  (none)"
fi

# Remove the annotation on any later failure, so no CR stays frozen.
_unblock_and_exit() {
    local rc="$1"
    if (( ${#CRS} )); then
        echo "[INFO] Removing ${CFO_ANNOT_BLOCK_RECONCILE} again after the failure."
        _annotate off || echo "[WARN] Could not remove ${CFO_ANNOT_BLOCK_RECONCILE} from every CR - remove it by hand." >&2
    fi
    exit "${rc}"
}

echo "[2/5] Channel / InstallPlan"
typeset -a NEW_CSVS=()       # "<ns>|<pkg>|<csv>"
for _row in "${OURS[@]}"; do
    _f=("${(@s:|:)_row}")
    _ns="${_f[1]}" _sub="${_f[2]}" _pkg="${_f[3]}"
    if [[ -n "${CHANNEL}" && "${_f[5]}" != "${CHANNEL}" ]]; then
        if [[ "${DRY_RUN}" == true ]]; then
            echo "  [DRY-RUN] oc patch subscriptions.operators.coreos.com ${_sub} -n ${_ns} --type=merge -p '{\"spec\":{\"channel\":\"${CHANNEL}\"}}'"
        else
            _res="$(cp4d_reconcile_subscription_channel "${_ns}" "${_sub}" "${CHANNEL}")" || {
                echo "[ERROR] ${_sub} in ${_ns}: channel ${_f[5]} -> ${CHANNEL} is not an in-place upgrade (${_res})." >&2
                _unblock_and_exit 1; }
            echo "[INFO] ${_sub} in ${_ns}: channel ${_f[5]} -> ${CHANNEL} (${_res})."
        fi
    elif [[ -n "${CHANNEL}" ]]; then
        echo "[INFO] ${_sub} in ${_ns} is already on channel ${CHANNEL}."
    fi
    ${APPROVE} || continue
    # The pending plan (after a channel change OLM creates a new one; wait for it).
    _plan="" _e=0
    while true; do
        _pr="$(oc get subscriptions.operators.coreos.com "${_sub}" -n "${_ns}" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)"
        _appr=""
        [[ -n "${_pr}" ]] && _appr="$(oc get installplans.operators.coreos.com "${_pr}" -n "${_ns}" -o jsonpath='{.spec.approved}' 2>/dev/null || true)"
        if [[ -n "${_pr}" && "${_appr}" == false ]]; then _plan="${_pr}"; break; fi
        echo "  [${_e}s/${T_PLAN}s] ${_sub}: no pending InstallPlan yet${_pr:+ (${_pr} approved=${_appr:-?})}"
        if [[ "${DRY_RUN}" == true || -z "${CHANNEL}" ]] || (( _e >= T_PLAN )); then break; fi
        sleep "${CFO_POLL_INTERVAL}"
        _e=$(( _e + CFO_POLL_INTERVAL ))
    done
    if [[ -z "${_plan}" ]]; then
        echo "[INFO] ${_sub} in ${_ns}: no InstallPlan waits for approval - nothing to approve."
        continue
    fi
    _rc=0
    cfo_installplan_other_csvs "${_ns}" "${_plan}" "${_pkg}" || _rc=$?
    (( _rc == 0 )) || { echo "[ERROR] InstallPlan ${_plan} in ${_ns} cannot be read - not approved." >&2; _unblock_and_exit 1; }
    if (( ${#CFO_PLAN_OTHERS} )); then
        if [[ "${DRY_RUN}" == true ]]; then
            echo "  [DRY-RUN] stop: InstallPlan ${_plan} also upgrades ${(j:, :)CFO_PLAN_OTHERS} - review it, then re-run without --dry-run."
            _unblock_and_exit 0
        fi
        if ! ${ASSUME_YES} && ! h_confirm "Approve InstallPlan ${_plan} anyway (it upgrades ${(j:, :)CFO_PLAN_OTHERS} too)?"; then
            echo "[INFO] Aborted - InstallPlan ${_plan} not approved."
            _unblock_and_exit 0
        fi
    fi
    # The CSV of our package that the plan installs.
    _cfo_json "${WORK}/plan.json" get installplans.operators.coreos.com "${_plan}" -n "${_ns}" || _unblock_and_exit 1
    _csv="$(cfo_python -c 'import json, sys
p = json.load(open(sys.argv[1]))
for c in (p.get("spec") or {}).get("clusterServiceVersionNames") or []:
    if c.startswith(sys.argv[2] + ".v"):
        print(c); break' "${WORK}/plan.json" "${_pkg}")"
    cf_dry_run oc patch installplans.operators.coreos.com "${_plan}" -n "${_ns}" --type=merge -p '{"spec":{"approved":true}}' \
        || { echo "[ERROR] Approving InstallPlan ${_plan} failed." >&2; _unblock_and_exit 1; }
    [[ "${DRY_RUN}" == true ]] || echo "[INFO] InstallPlan ${_plan} in ${_ns} approved (${_csv:-?})."
    [[ -n "${_csv}" ]] && NEW_CSVS+=("${_ns}|${_pkg}|${_csv}")
done

echo "[3/5] New CSVs (${#NEW_CSVS})"
if [[ "${DRY_RUN}" != true ]]; then
    for _n in "${NEW_CSVS[@]}"; do
        _f=("${(@s:|:)_n}")
        cfo_wait_csv "${_f[1]}" "${_f[3]}" "${T_CSV}" || _unblock_and_exit 1
    done
fi

echo "[4/5] CFK init container image"
for _n in "${NEW_CSVS[@]}"; do
    _f=("${(@s:|:)_n}")
    [[ "${_f[2]}" == "${CFO_PKG_CFK}" ]] || continue
    _ver="${_f[3]#*.v}"
    _cur="${CONFLUENT_OPERATOR_INIT_IMAGE:-${CONFLUENT_REGISTRY:-confluentinc}/confluent-init-container:$(cfo_catalog confluent/operator/cfk_init_tag 3.4.0)}"
    # Repository without tag or digest (a registry port, host:5000/..., is not a tag).
    _base="${_cur%@*}"
    [[ "${_base##*/}" == *:* ]] && _base="${_base%:*}"
    _new="${_base}:${_ver}"
    if [[ "${_cur}" == "${_new}" ]]; then
        echo "[INFO] Init image already ${_new}."
        continue
    fi
    echo "[INFO] Init image ${_cur} -> ${_new}"
    for _c in "${CRS[@]}"; do
        [[ "${_c%% *}" == "${_f[1]}" ]] || continue
        _ref="${_c#* }"
        # Only the component CRs have spec.image (KafkaTopic, Connector, ... would reject the field).
        [[ "${_ref%%/*}" == (Kafka|KRaftController|SchemaRegistry|Connect|KsqlDB|KafkaRestProxy|ControlCenter) ]] || continue
        cf_dry_run oc patch "$(cfo_resource "${_ref%%/*}")" "${_ref#*/}" -n "${_f[1]}" --type=merge \
            -p "{\"spec\":{\"image\":{\"init\":\"${_new}\"}}}" || { echo "[ERROR] Patching ${_ref} failed." >&2; _unblock_and_exit 1; }
    done
    # Keep the literal ${CONFLUENT_REGISTRY} reference the generators write (contract 2.2), so a later
    # registry change (mirroring) still reaches the init image.
    _persist="${_new}"
    if [[ -n "${CONFLUENT_REGISTRY:-}" && "${_new}" == "${CONFLUENT_REGISTRY}/"* ]]; then
        _persist='${CONFLUENT_REGISTRY}/'"${_new#${CONFLUENT_REGISTRY}/}"
    fi
    _cfo_vars_file
    if [[ "${DRY_RUN}" == true ]]; then
        echo "  [DRY-RUN] persist CONFLUENT_OPERATOR_INIT_IMAGE=${_persist} in ${REPLY:t}"
    else
        cf_persist_var "${REPLY}" CONFLUENT_OPERATOR_INIT_IMAGE "${_persist}" || _unblock_and_exit 1
        export CONFLUENT_OPERATOR_INIT_IMAGE="${_new}"
    fi
done

echo "[5/5] Unblock reconcile and wait"
if (( ${#CRS} )); then
    _annotate off || { echo "[ERROR] Removing ${CFO_ANNOT_BLOCK_RECONCILE} failed - remove it by hand." >&2; exit 1; }
    if [[ "${DRY_RUN}" != true ]]; then
        for _c in "${CRS[@]}"; do
            _ref="${_c#* }"
            case "${_ref%%/*}" in
                Kafka|KRaftController) cfo_wait_roll "${_c%% *}" "${_ref}" "${T_KAFKA}" || exit 1 ;;
                Connect|SchemaRegistry|KsqlDB|KafkaRestProxy|ControlCenter)
                                       cfo_wait_crs "${_c%% *}" "${T_COMPONENT}" "${_ref}" || exit 1 ;;
            esac
        done
    fi
else
    echo "  (nothing was blocked)"
fi
[[ "${DRY_RUN}" == true ]] && echo "[INFO] --dry-run: no changes made."
echo "[INFO] Done."
