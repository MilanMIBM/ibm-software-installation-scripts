#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Applies Kubecost custom pricing (one set of monthly prices for the whole
# cluster; no product key needed) to an instance: sets
# finopsagent.agent.kubecost.customPrices in the Kubecost CR, which the
# operator renders into the pricing-configs ConfigMap that Kubecost reads.
# Make the file with generate_kubecost_custom_pricing_template.sh.
#
# CSV pricing, when also on, prices the assets it matches; custom pricing
# covers the rest.
#
#   apply_kubecost_custom_pricing.sh <kubecost name> [options]
#     -n, --namespace <ns>          default: the namespace holding that Kubecost CR
#     -f, --file <conf>             default configs/kubecost_config/<ns>/<instance>-custom-pricing.conf
#     --disable                     turn custom pricing off (prices are kept in the CR)
#     --restart                     also restart the pods that read pricing-configs
#                                   (they pick changes up by themselves normally)
#     --dry-run                     check the file and show the change
#     --no-wait                     don't wait for the operator to roll it out
#     --timeout <seconds>           wait at most this long (default 600)
#     --server/--token/-u/-p        log in first (see ocu_login); otherwise OC_LOGIN
#                                   from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Applies Kubecost custom pricing/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

FIELDS=(CPU spotCPU RAM spotRAM GPU spotGPU storage zoneNetworkEgress regionNetworkEgress internetNetworkEgress)

CR_NAME=""
NAMESPACE=""
CONF_FILE=""
DISABLE=false
RESTART=false
DRY_RUN=false
WAIT=true
TIMEOUT=600
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)  NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        -f|--file)       CONF_FILE="${2:?$1 needs a value}"; shift 2 ;;
        --disable)       DISABLE=true; shift ;;
        --restart)       RESTART=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --no-wait)       WAIT=false; shift ;;
        --timeout)       TIMEOUT="${2:?$1 needs a value}"; shift 2 ;;
        --server)        LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)         LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)   LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)   LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)               [[ -z "${CR_NAME}" ]] || die "Unexpected argument: $1"; CR_NAME="$1"; shift ;;
    esac
done
[[ -n "${CR_NAME}" ]] || { usage >&2; die "Name the Kubecost instance (the Kubecost CR)."; }
[[ "${TIMEOUT}" == <-> ]] || die "--timeout needs a number of seconds."

ocu_login
[[ -n "${NAMESPACE}" ]] || NAMESPACE="$(kc_find_instance_namespace "${CR_NAME}")" || exit 1
CR_JSON="$(oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null)" \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
echo "[INFO] Kubecost instance: ${NAMESPACE}/${CR_NAME}"
CURRENT="$(jq -c '.spec.finopsagent.agent.kubecost.customPrices // {}' <<<"${CR_JSON}")"

# --- Desired prices ----------------------------------------------------------------
if [[ "${DISABLE}" == true ]]; then
    if [[ "$(jq -r '.enabled // false' <<<"${CURRENT}")" != true ]]; then
        echo "[OK] Custom pricing is already off on '${CR_NAME}'."
        exit 0
    fi
    DESIRED="$(jq -c '. + {enabled: false}' <<<"${CURRENT}")"
else
    CONF_FILE="${CONF_FILE:-${KC_CONFIG_DIR}/${NAMESPACE}/${CR_NAME}-custom-pricing.conf}"
    [[ -r "${CONF_FILE}" ]] || die "No file at ${CONF_FILE#${_CP4D_REPO_ROOT}/}. Make one with generate_kubecost_custom_pricing_template.sh ${CR_NAME}."
    echo "[INFO] Prices: ${CONF_FILE#${_CP4D_REPO_ROOT}/}"
    typeset -A PRICES
    errors=()
    n=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        (( ++n ))
        line="${line%%$'\r'}"
        [[ "${line}" =~ '^[[:space:]]*(#|$)' ]] && continue
        [[ "${line}" == *=* ]] || { errors+=("line ${n}: expected NAME=value"); continue; }
        key="${${line%%=*}//[[:space:]]/}"
        value="${${line#*=}//[[:space:]]/}"
        (( ${FIELDS[(Ie)${key}]} )) || { errors+=("line ${n}: unknown field '${key}' (fields: ${FIELDS[*]})"); continue; }
        [[ -z "${value}" || "${value}" =~ '^[0-9]+(\.[0-9]+)?$' ]] \
            || { errors+=("line ${n}: ${key} '${value}' is not a number"); continue; }
        PRICES[${key}]="${value}"
    done < "${CONF_FILE}"
    (( ${#errors[@]} == 0 )) || { echo "[ERROR] ${CONF_FILE:t}:" >&2; printf '  %s\n' "${errors[@]}" >&2; exit 1; }
    set_count=0
    for f in "${FIELDS[@]}"; do [[ -n "${PRICES[${f}]:-}" ]] && (( ++set_count )); done
    (( set_count > 0 )) || die "${CONF_FILE:t} has no prices filled in."

    # Every field is written: "" clears one set earlier (the chart skips empty ones).
    jq_args=()
    for f in "${FIELDS[@]}"; do jq_args+=(--arg "${f}" "${PRICES[${f}]:-}"); done
    DESIRED="$(jq -cn "${jq_args[@]}" '{enabled: true} + $ARGS.named')"
    echo "[OK] ${set_count} price(s): $(jq -r '[to_entries[] | select(.key != "enabled" and .value != "") | "\(.key)=\(.value)"] | join(" ")' <<<"${DESIRED}")"
    if [[ "$(jq -r '.spec.enterpriseCustomPricing.enabled // false' <<<"${CR_JSON}")" == true ]]; then
        echo "[INFO] CSV pricing is also on: it prices the assets it matches, these prices cover the rest."
    fi
fi

PATCH="$(jq -cn --argjson p "${DESIRED}" '{spec: {finopsagent: {agent: {kubecost: {customPrices: $p}}}}}')"
if [[ "$(jq -cS . <<<"${CURRENT}")" == "$(jq -cS . <<<"${DESIRED}")" ]]; then
    echo "[OK] '${CR_NAME}' already has these prices; nothing to change."
    [[ "${DRY_RUN}" == true ]] && exit 0
    kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
    exit 0
fi
if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY-RUN] Would merge-patch ${KC_RESOURCE}/${CR_NAME} -n ${NAMESPACE}:"
    jq . <<<"${PATCH}"
    exit 0
fi

START_REV="$(kc_release_revision "${CR_NAME}" "${NAMESPACE}")"
START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc patch "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" --type merge -p "${PATCH}" >/dev/null
echo "[OK] Custom pricing $([[ "${DISABLE}" == true ]] && echo "turned off" || echo "set") on '${CR_NAME}'."

if [[ "${WAIT}" == true ]]; then
    kc_wait_for_release "${CR_NAME}" "${NAMESPACE}" "${START_REV}" "${START_TS}" "${TIMEOUT}" || exit 1
    cm="$(oc get configmap pricing-configs -n "${NAMESPACE}" -o json 2>/dev/null | jq -c '.data // {}' || echo '{}')"
    echo "[INFO] pricing-configs now: $(jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ") | if . == "" then "(empty)" else . end' <<<"${cm}")"
    if [[ "${RESTART}" == true ]]; then
        for w in "statefulset/${CR_NAME}-aggregator" "deployment/${CR_NAME}-cloud-cost" "deployment/${CR_NAME}-local-store"; do
            oc get "${w}" -n "${NAMESPACE}" &>/dev/null || continue
            oc rollout restart "${w}" -n "${NAMESPACE}" >/dev/null
            echo "[INFO] Restarted ${w}; waiting..."
            oc rollout status "${w}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s" 2>&1 | sed 's/^/  /' || die "${w} did not become ready."
        done
    fi
fi

kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
echo "[OK] Done. Check it in the UI under Settings > Pricing."
