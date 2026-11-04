#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Switches a Kubecost instance's CSV pricing (Enterprise Custom Pricing) to
# UI management: pricing CSVs are then uploaded in the Kubecost UI (Settings >
# Enterprise Custom Pricing) instead of coming from Helm. Sets
# enterpriseCustomPricing enabled with no configMapName / location.URI, which
# is how the chart hands the CSV over to the UI. The uploaded CSV is kept on
# the aggregator's persistent config volume.
#
# A Helm-managed CSV on the instance (the ConfigMap the CR names, e.g. from
# apply_kubecost_csv_pricing.sh) is deleted from the cluster once the operator
# has rolled the change out. Local files in configs/kubecost_config are not
# touched; if none of them holds the deleted CSV, a copy is saved first so it
# can be uploaded. Node labels (kubecost.pricing/profile) are kept, so the
# same CSV works when uploaded.
#
# Needs a product key linked to the instance: per the Kubecost docs, CSV
# pricing without a valid key locks the application. Without one this script
# warns and stops, unless --force.
#
# Back to Helm management: apply_kubecost_csv_pricing.sh <instance> -f <csv>.
#
#   enable_kubecost_csv_pricing_ui.sh [<kubecost name>] [options]
#     -n, --namespace <ns>          default: the namespace holding that Kubecost CR
#   No name: KUBECOST_INSTANCE_NAME from configs/kubecost_config/kubecost_vars.sh,
#   else the only instance on the cluster (asks which one when there are several)
#     --no-retroactive              apply prices from now on only (default: kept as set,
#                                   else also to history)
#     --keep-configmap              don't delete the Helm CSV ConfigMap
#     --force                       switch even without a linked product key
#     --dry-run                     show what would change
#     --no-wait                     don't wait for the aggregator to restart
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

usage() { sed -n '/^# Switches a Kubecost instance/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }
rel() { print -r -- "${1#${_CP4D_REPO_ROOT}/}"; }

CR_NAME=""
NAMESPACE=""
RETROACTIVE=""
KEEP_CONFIGMAP=false
FORCE=false
DRY_RUN=false
WAIT=true
TIMEOUT=600
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)    NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        --no-retroactive)  RETROACTIVE=false; shift ;;
        --keep-configmap)  KEEP_CONFIGMAP=true; shift ;;
        --force)           FORCE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --no-wait)         WAIT=false; shift ;;
        --timeout)         TIMEOUT="${2:?$1 needs a value}"; shift 2 ;;
        --server)          LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)           LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)     LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)     LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        -*)                echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                 [[ -z "${CR_NAME}" ]] || die "Unexpected argument: $1"; CR_NAME="$1"; shift ;;
    esac
done
[[ "${TIMEOUT}" == <-> ]] || die "--timeout needs a number of seconds."

ocu_login
kc_resolve_instance || exit 1
CR_JSON="$(oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null)" \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
echo "[INFO] Kubecost instance: ${NAMESPACE}/${CR_NAME}"

AGGREGATOR="statefulset/${CR_NAME}-aggregator"
CURRENT_ECP="$(jq -c '.spec.enterpriseCustomPricing // {}' <<<"${CR_JSON}")"
HELM_CM="$(jq -r '.configMapName // ""' <<<"${CURRENT_ECP}")"
HELM_URI="$(jq -r '.location.URI // ""' <<<"${CURRENT_ECP}")"
ENABLED="$(jq -r '.enabled // false' <<<"${CURRENT_ECP}")"
RETROACTIVE="${RETROACTIVE:-$(jq -r '.applyRetroactively // true' <<<"${CURRENT_ECP}")}"

if [[ "${ENABLED}" != true ]]; then
    echo "[INFO] CSV pricing is off now."
elif [[ -n "${HELM_CM}${HELM_URI}" ]]; then
    echo "[INFO] CSV pricing now comes from Helm: ConfigMap ${HELM_CM:-none}, ${HELM_URI:-no URI}."
fi
ecp_status="$(kc_ecp_status "${CR_NAME}" "${NAMESPACE}")"
[[ -n "${ecp_status}" ]] && echo "[INFO] Aggregator: $(jq -r '"source \(.source // "-"), spec \(.spec.uri // "-"), valid \(.spec.valid // "-")"' <<<"${ecp_status}")"

# --- Product key ---------------------------------------------------------------
kc_product_key_status "${CR_JSON}" "${NAMESPACE}"
if [[ "${KC_KEY_LINKED}" != true ]]; then
    echo "[WARN] CSV pricing (Enterprise Custom Pricing) is a Kubecost Enterprise feature, and no product key is"
    echo "[WARN] linked to '${CR_NAME}' (${KC_KEY_SOURCE}). Per the Kubecost docs, enabling it without a valid"
    echo "[WARN] key locks the application. Link one first: product_key/link_kubecost_product_key.sh ${CR_NAME} -k <key>"
    [[ "${FORCE}" == true ]] || die "Stopped. --force switches it anyway."
    echo "[WARN] --force: switching anyway."
else
    echo "[INFO] Product key: ${KC_KEY_SOURCE}"
fi

# --- The Helm CSV --------------------------------------------------------------
CM_JSON=""
CM_CSV=""
if [[ -n "${HELM_CM}" ]]; then
    CM_JSON="$(oc get configmap "${HELM_CM}" -n "${NAMESPACE}" -o json 2>/dev/null || true)"
    [[ -n "${CM_JSON}" ]] && CM_CSV="$(jq -r '.data // {} | to_entries[0].value // ""' <<<"${CM_JSON}")"
fi
# Local CSVs for this instance, and which (if any) holds the Helm CSV.
LOCAL_CSVS=("${KC_CONFIG_DIR}/${NAMESPACE}/${CR_NAME}"*.csv(N))
MATCH=""
if [[ -n "${CM_CSV}" ]]; then
    for f in "${LOCAL_CSVS[@]}"; do
        [[ "$(tr -d '\r' < "${f}" | sed '/^[[:space:]]*$/d')" == "$(print -r -- "${CM_CSV}" | tr -d '\r' | sed '/^[[:space:]]*$/d')" ]] \
            && { MATCH="${f}"; break; }
    done
    if [[ -n "${MATCH}" ]]; then
        echo "[INFO] The Helm CSV (ConfigMap ${HELM_CM}) is the same as $(rel "${MATCH}")."
    else
        echo "[INFO] The Helm CSV (ConfigMap ${HELM_CM}) matches no file in $(rel "${KC_CONFIG_DIR}/${NAMESPACE}")/; a copy is saved before it goes."
    fi
fi

# --- Change --------------------------------------------------------------------
DESIRED="$(jq -cn --argjson r "${RETROACTIVE}" '{enabled: true, configMapName: "", location: {URI: ""}, applyRetroactively: $r}')"
PATCH="$(jq -cn --argjson e "${DESIRED}" '{spec: {enterpriseCustomPricing: $e}}')"
CR_CHANGED=true
[[ "$(jq -cS --argjson d "${DESIRED}" '. * $d' <<<"${CURRENT_ECP}")" == "$(jq -cS . <<<"${CURRENT_ECP}")" ]] && CR_CHANGED=false
DELETE_CM=false
[[ -n "${CM_JSON}" && "${KEEP_CONFIGMAP}" != true ]] && DELETE_CM=true

if [[ "${DRY_RUN}" == true ]]; then
    if [[ "${CR_CHANGED}" == true ]]; then
        echo "[DRY-RUN] Would merge-patch ${KC_RESOURCE}/${CR_NAME}: $(jq -c . <<<"${PATCH}")"
    else
        echo "[DRY-RUN] The CR already hands CSV pricing to the UI."
    fi
    [[ -n "${CM_CSV}" && -z "${MATCH}" && "${DELETE_CM}" == true ]] \
        && echo "[DRY-RUN] Would save the Helm CSV to $(rel "${KC_CONFIG_DIR}/${NAMESPACE}/${CR_NAME}-pricing-from-helm-<time>.csv")"
    [[ "${DELETE_CM}" == true ]] && echo "[DRY-RUN] Would delete ConfigMap ${HELM_CM} after the rollout (local files untouched)."
    exit 0
fi

if [[ "${CR_CHANGED}" == false && "${DELETE_CM}" == false ]]; then
    echo "[OK] '${CR_NAME}' already takes its pricing CSV from the UI."
else
    if [[ -n "${CM_CSV}" && -z "${MATCH}" && "${DELETE_CM}" == true ]]; then
        saved="${KC_CONFIG_DIR}/${NAMESPACE}/${CR_NAME}-pricing-from-helm-$(date -u +%Y%m%dT%H%M%SZ).csv"
        print -r -- "${CM_CSV}" | _kc_write_private "${saved}"
        echo "[OK] Helm CSV saved to $(rel "${saved}")"
        LOCAL_CSVS+=("${saved}")
    fi
    if [[ "${CR_CHANGED}" == true ]]; then
        start_rev="$(kc_release_revision "${CR_NAME}" "${NAMESPACE}")"
        start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        oc patch "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" --type merge -p "${PATCH}" >/dev/null
        echo "[OK] Kubecost CR updated: enterpriseCustomPricing $(jq -c . <<<"${DESIRED}")"
        # Always wait for the release: the aggregator must stop mounting the
        # ConfigMap before it can go.
        kc_wait_for_release "${CR_NAME}" "${NAMESPACE}" "${start_rev}" "${start_ts}" "${TIMEOUT}" || exit 1
    fi
    if [[ "${DELETE_CM}" == true ]]; then
        if oc get "${AGGREGATOR}" -n "${NAMESPACE}" -o json \
                | jq -e --arg cm "${HELM_CM}" '[.spec.template.spec.volumes[]? | select(.configMap.name == $cm)] | length > 0' >/dev/null; then
            echo "[WARN] ${AGGREGATOR} still mounts ConfigMap ${HELM_CM}; kept. Delete it later: oc delete configmap ${HELM_CM} -n ${NAMESPACE}"
        else
            oc delete configmap "${HELM_CM}" -n "${NAMESPACE}" --ignore-not-found >/dev/null
            echo "[OK] Helm CSV ConfigMap ${HELM_CM} deleted (local files untouched)."
        fi
    fi
    if [[ "${WAIT}" == true && "${CR_CHANGED}" == true ]]; then
        echo "[INFO] Waiting for ${AGGREGATOR} (up to ${TIMEOUT}s)..."
        oc rollout status "${AGGREGATOR}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s" 2>&1 | sed 's/^/  /' \
            || die "${AGGREGATOR} did not become ready."
        # The API answers a little after the pod is ready.
        ecp_status="" elapsed=0
        while (( elapsed < 60 )); do
            ecp_status="$(kc_ecp_status "${CR_NAME}" "${NAMESPACE}")"
            [[ -n "${ecp_status}" ]] && break
            sleep 5; (( elapsed += 5 ))
            echo "  [${elapsed}/60s] waiting for the aggregator API"
        done
        if [[ -n "${ecp_status}" ]]; then
            echo "[INFO] Aggregator: $(jq -r '"source \(.source // "-"), spec \(.spec.uri // "none uploaded yet"), valid \(.spec.valid // "-")"' <<<"${ecp_status}")"
        fi
    fi
fi

kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
url="$(oc get route "$(kc_fullname "${CR_JSON}" "${CR_NAME}")-route" -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
echo "[OK] Upload the pricing CSV in the UI: ${url:+https://${url} > }Settings > Enterprise Custom Pricing."
if (( ${#LOCAL_CSVS[@]} > 0 )); then
    echo "     Local CSVs for '${CR_NAME}':"
    for f in "${LOCAL_CSVS[@]}"; do print -r -- "       $(rel "${f}")$([[ "${f}" == "${MATCH}" ]] && echo "  (was in Helm)")"; done
fi
echo "     Back to Helm management: apply_kubecost_csv_pricing.sh ${CR_NAME} -f <csv>"
