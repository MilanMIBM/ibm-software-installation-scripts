#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Sets the currency a Kubecost instance shows costs in
# (kubecostProductConfigs.currencyCode). Display only: Kubecost does not
# convert amounts, so custom and CSV prices must be entered in this currency.
#
# Presets (the currencies Kubecost officially supports):
#   USD AUD BRL CAD CHF CNY DKK EUR GBP IDR INR JPY NOK PLN SEK
# Without a currency on a terminal, a numbered menu of the presets is shown.
#
#   set_kubecost_currency.sh <kubecost name> [<currency>] [options]
#     -n, --namespace <ns>     default: the namespace holding that Kubecost CR
#     --list                   list the presets and the instance's current currency
#     --allow-unsupported      accept a 3-letter code that is not a preset
#     --dry-run                show the change, change nothing
#     --no-wait                don't wait for the operator to roll it out
#     --timeout <seconds>      wait at most this long (default 600)
#     --server/--token/-u/-p   log in first (see ocu_login); otherwise OC_LOGIN
#                              from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Sets the currency/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# Officially supported by Kubecost (chart values.yaml, kubecostProductConfigs.currencyCode).
PRESETS=(USD AUD BRL CAD CHF CNY DKK EUR GBP IDR INR JPY NOK PLN SEK)
typeset -A PRESET_NAMES=(
    USD "US dollar"        AUD "Australian dollar" BRL "Brazilian real"   CAD "Canadian dollar"
    CHF "Swiss franc"      CNY "Chinese yuan"      DKK "Danish krone"     EUR "Euro"
    GBP "Pound sterling"   IDR "Indonesian rupiah" INR "Indian rupee"     JPY "Japanese yen"
    NOK "Norwegian krone"  PLN "Polish zloty"      SEK "Swedish krona"
)

CR_NAME=""
CURRENCY=""
NAMESPACE=""
LIST=false
ALLOW_UNSUPPORTED=false
DRY_RUN=false
WAIT=true
TIMEOUT=600
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)       NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        --list)               LIST=true; shift ;;
        --allow-unsupported)  ALLOW_UNSUPPORTED=true; shift ;;
        --dry-run)            DRY_RUN=true; shift ;;
        --no-wait)            WAIT=false; shift ;;
        --timeout)            TIMEOUT="${2:?$1 needs a value}"; shift 2 ;;
        --server)             LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)              LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)        LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)        LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)            usage; exit 0 ;;
        -*)                   echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [[ -z "${CR_NAME}" ]]; then CR_NAME="$1"
            elif [[ -z "${CURRENCY}" ]]; then CURRENCY="${1:u}"
            else die "Unexpected argument: $1"; fi
            shift ;;
    esac
done
[[ -n "${CR_NAME}" ]] || { usage >&2; die "Name the Kubecost instance (the Kubecost CR)."; }
[[ "${TIMEOUT}" == <-> ]] || die "--timeout needs a number of seconds."

ocu_login
[[ -n "${NAMESPACE}" ]] || NAMESPACE="$(kc_find_instance_namespace "${CR_NAME}")" || exit 1
CR_JSON="$(oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null)" \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
CURRENT="$(jq -r '.spec.kubecostProductConfigs.currencyCode // "USD"' <<<"${CR_JSON}")"
echo "[INFO] Kubecost instance: ${NAMESPACE}/${CR_NAME} (currency now ${CURRENT})"

print_presets() {
    local i=0 c
    for c in "${PRESETS[@]}"; do
        (( ++i ))
        printf '  %2d) %s  %s%s\n' "${i}" "${c}" "${PRESET_NAMES[${c}]}" "$([[ "${c}" == "${CURRENT}" ]] && echo "  (current)")"
    done
}

if [[ "${LIST}" == true ]]; then
    print_presets
    exit 0
fi

if [[ -z "${CURRENCY}" ]]; then
    [[ -t 0 ]] || die "Name the currency (one of: ${PRESETS[*]})."
    print_presets
    echo -n "Currency [number or code]: "
    read -r answer
    answer="${answer//[[:space:]]/}"
    if [[ "${answer}" == <-> ]] && (( answer >= 1 && answer <= ${#PRESETS[@]} )); then
        CURRENCY="${PRESETS[${answer}]}"
    else
        CURRENCY="${answer:u}"
    fi
fi

[[ "${CURRENCY}" =~ '^[A-Z]{3}$' ]] || die "'${CURRENCY}' is not a 3-letter currency code."
if (( ! ${PRESETS[(Ie)${CURRENCY}]} )); then
    [[ "${ALLOW_UNSUPPORTED}" == true ]] \
        || die "${CURRENCY} is not one Kubecost officially supports (${PRESETS[*]}); --allow-unsupported sets it anyway."
    echo "[WARN] ${CURRENCY} is not officially supported by Kubecost; setting it anyway."
fi

if [[ "${CURRENCY}" == "${CURRENT}" ]]; then
    echo "[OK] '${CR_NAME}' already shows costs in ${CURRENCY}."
    exit 0
fi

PATCH="$(jq -cn --arg c "${CURRENCY}" '{spec: {kubecostProductConfigs: {currencyCode: $c}}}')"
if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY-RUN] Would change the currency ${CURRENT} -> ${CURRENCY}: $(jq -c . <<<"${PATCH}")"
    exit 0
fi

START_REV="$(kc_release_revision "${CR_NAME}" "${NAMESPACE}")"
START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc patch "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" --type merge -p "${PATCH}" >/dev/null
echo "[OK] Currency ${CURRENT} -> ${CURRENCY} set on '${CR_NAME}'."
echo "[INFO] Display only: amounts are not converted. Enter custom/CSV prices in ${CURRENCY}."

if [[ "${WAIT}" == true ]]; then
    kc_wait_for_release "${CR_NAME}" "${NAMESPACE}" "${START_REV}" "${START_TS}" "${TIMEOUT}" || exit 1
    # The aggregator gets it as DISPLAY_CURRENCY, the frontend in its config;
    # both roll on their own.
    for w in "statefulset/${CR_NAME}-aggregator" "deployment/${CR_NAME}-frontend"; do
        echo "[INFO] Waiting for ${w}..."
        oc rollout status "${w}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s" 2>&1 | sed 's/^/  /' \
            || die "${w} did not become ready."
    done
fi

kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
echo "[OK] Done."
