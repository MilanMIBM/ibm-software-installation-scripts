#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Links a Kubecost Enterprise product key to a Kubecost instance (a 'Kubecost'
# CR): sets kubecostProductConfigs.productKey to the product key Secret and
# waits for the operator to roll it out.
#
# Secret (default name kubecost-product-key, in the instance's namespace):
#   - a key given (--key or --key-file): the Secret is created, or updated if
#     it holds another key (via create_kubecost_product_key_secret.sh)
#   - no key given: the Secret's key is used. Without the Secret, KUBECOST_PRODUCT_KEY
#     from configs/kubecost_config/kubecost_vars.sh, else the key in
#     configs/kubecost_config/<namespace>/<secret>-productkey.json is used to
#     create it.
# The key is kept in that local file: written when missing or when a key is
# given; when it differs from the cluster's Secret, that is reported and the
# file kept. The instance details (login URL etc.) are saved next to it
# (<instance>-instance_details.sh).
# An inline key or mount path in the CR is replaced by the Secret reference.
# When the CR already points at the Secret and only the key changed, the
# aggregator is restarted so it reads the new key.
#
#   link_kubecost_product_key.sh [<kubecost name>] [options]
#     -n, --namespace <ns>        default: the namespace holding that Kubecost CR
#   No name: KUBECOST_INSTANCE_NAME from configs/kubecost_config/kubecost_vars.sh,
#   else the only instance on the cluster (asks which one when there are several)
#     -s, --secret-name <name>    default KUBECOST_PRODUCT_KEY_SECRET (kubecost_vars.sh),
#                                 else kubecost-product-key
#     -k, --key <key>             product key
#     -f, --key-file <file>       file with {"key": "..."} (productkey.json) or the bare
#                                 key; '-' reads it from stdin
#     --dry-run                   show what would change, change nothing
#     --no-wait                   don't wait for the operator to roll it out
#     --timeout <seconds>         wait at most this long (default 600)
#     --server/--token/-u/-p      log in first (see ocu_login); otherwise OC_LOGIN
#                                 from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Links/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

CREATE_SCRIPT="${SCRIPT_DIR}/create_kubecost_product_key_secret.sh"

CR_NAME=""
NAMESPACE=""
SECRET_NAME="${KUBECOST_PRODUCT_KEY_SECRET:-kubecost-product-key}"
PRODUCT_KEY=""
KEY_FILE=""
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
        -s|--secret-name)  SECRET_NAME="${2:?$1 needs a value}"; shift 2 ;;
        -k|--key)          PRODUCT_KEY="${2:?$1 needs a value}"; shift 2 ;;
        -f|--key-file)     KEY_FILE="${2:?$1 needs a path}"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --no-wait)         WAIT=false; shift ;;
        --timeout)         TIMEOUT="${2:?$1 needs a value}"; shift 2 ;;
        --server)          LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)           LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)     LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)     LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        -*)                echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            [[ -z "${CR_NAME}" ]] || die "Unexpected argument: $1"
            CR_NAME="$1"; shift ;;
    esac
done

[[ "${TIMEOUT}" == <-> ]] || die "--timeout needs a number of seconds."
[[ -z "${PRODUCT_KEY}" || -z "${KEY_FILE}" ]] || die "Pass --key or --key-file, not both."
if [[ -n "${KEY_FILE}" ]]; then
    PRODUCT_KEY="$(kc_read_key_file "${KEY_FILE}")" || exit 1
    [[ -n "${PRODUCT_KEY}" ]] || die "Key file '${KEY_FILE}' holds no key."
fi
PRODUCT_KEY="${PRODUCT_KEY//[[:space:]]/}"

ocu_login

kc_resolve_instance || exit 1
CR_JSON="$(oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null)" \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
echo "[INFO] Kubecost instance: ${NAMESPACE}/${CR_NAME}"

# --- Secret --------------------------------------------------------------------
# Key currently in the Secret ("" if there is no Secret or no productkey.json).
current_key="$(oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null \
    | jq -r '.data["productkey.json"] // empty | @base64d | fromjson? | .key // empty' || true)"
secret_exists=false
oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null && secret_exists=true

# Creates/updates the Secret (and the local key file) with PRODUCT_KEY through
# create_kubecost_product_key_secret.sh. The key goes in on stdin, so it never
# shows in the process list; only its result lines are kept.
KEY_CHANGED=false
apply_key_secret() {
    local -a args=(-n "${NAMESPACE}" -s "${SECRET_NAME}" --key-file -)
    local rc=0 out
    [[ "${DRY_RUN}" == true ]] && args+=(--dry-run)
    out="$(print -rn -- "${PRODUCT_KEY}" | "${CREATE_SCRIPT}" "${args[@]}" 2>&1)" || rc=$?
    grep -E '^\[(OK|ERROR|WARN|DRY-RUN)\]' <<<"${out}" || true
    (( rc == 0 )) || die "Could not create Secret '${SECRET_NAME}'."
    KEY_CHANGED=true
}

if [[ -n "${PRODUCT_KEY}" ]]; then
    if [[ "${PRODUCT_KEY}" == "${current_key}" ]]; then
        echo "[INFO] Secret '${SECRET_NAME}' already holds this key."
        [[ "${DRY_RUN}" == true ]] || kc_save_product_key_file "${NAMESPACE}" "${SECRET_NAME}" "${PRODUCT_KEY}" true
    else
        if [[ "${secret_exists}" == true ]]; then
            echo "[INFO] Secret '${SECRET_NAME}' exists; its key will be replaced."
        else
            echo "[INFO] Secret '${SECRET_NAME}' does not exist; it will be created."
        fi
        apply_key_secret
    fi
elif [[ -z "${current_key}" ]]; then
    kc_product_key_file "${NAMESPACE}" "${SECRET_NAME}"; local_file="${REPLY}"
    key_from="${local_file#${_CP4D_REPO_ROOT}/}"
    if [[ -n "${KUBECOST_PRODUCT_KEY:-}" ]]; then
        PRODUCT_KEY="${KUBECOST_PRODUCT_KEY//[[:space:]]/}"; key_from="KUBECOST_PRODUCT_KEY (${KC_VARS_FILE})"
    elif [[ -f "${local_file}" ]]; then
        PRODUCT_KEY="$(kc_read_key_file "${local_file}")"
    fi
    if [[ -z "${PRODUCT_KEY}" ]]; then
        if [[ "${secret_exists}" == true ]]; then
            die "Secret '${SECRET_NAME}' in '${NAMESPACE}' has no productkey.json with a 'key' field, and no KUBECOST_PRODUCT_KEY or ${local_file#${_CP4D_REPO_ROOT}/}. Pass --key or --key-file."
        fi
        die "No Secret '${SECRET_NAME}' in '${NAMESPACE}', no KUBECOST_PRODUCT_KEY and no ${local_file#${_CP4D_REPO_ROOT}/}. Pass --key or --key-file to create it, or -s <existing secret>."
    fi
    echo "[INFO] Secret '${SECRET_NAME}' $([[ "${secret_exists}" == true ]] && echo "has no key" || echo "does not exist"); using the key in ${key_from} (${PRODUCT_KEY[1,4]}****)."
    apply_key_secret
else
    echo "[INFO] Using the key in Secret '${SECRET_NAME}' (${current_key[1,4]}****)."
    if [[ -n "${KUBECOST_PRODUCT_KEY:-}" && "${KUBECOST_PRODUCT_KEY//[[:space:]]/}" != "${current_key}" ]]; then
        echo "[WARN] KUBECOST_PRODUCT_KEY (${KC_VARS_FILE}, ${KUBECOST_PRODUCT_KEY[1,4]}****) differs from the Secret's key; kept the Secret's."
        echo "[WARN]   to use the config's key: print -rn -- \"\$KUBECOST_PRODUCT_KEY\" | ${0:t} ${CR_NAME} -f -   (after: source s_env.sh kubecost)"
    fi
    [[ "${DRY_RUN}" == true ]] || kc_save_product_key_file "${NAMESPACE}" "${SECRET_NAME}" "${current_key}" false
fi

# --- CR ------------------------------------------------------------------------
pk="$(jq -c '.spec.kubecostProductConfigs.productKey // {}' <<<"${CR_JSON}")"
ALREADY_LINKED=false
jq -e --arg s "${SECRET_NAME}" '.enabled == true and .secretname == $s
    and ((.key // "") == "") and ((.mountPath // "") == "")' <<<"${pk}" >/dev/null && ALREADY_LINKED=true
[[ -n "$(jq -r '.key // ""' <<<"${pk}")" ]] && echo "[INFO] The CR's inline key will be removed in favour of the Secret."
[[ -n "$(jq -r '.mountPath // ""' <<<"${pk}")" ]] && echo "[INFO] The CR's productKey.mountPath will be removed in favour of the Secret."

# null removes a field in a merge patch.
PATCH="$(jq -cn --arg s "${SECRET_NAME}" \
    '{spec: {kubecostProductConfigs: {productKey: {enabled: true, secretname: $s, key: null, mountPath: null}}}}')"
AGGREGATOR="statefulset/${CR_NAME}-aggregator"

if [[ "${DRY_RUN}" == true ]]; then
    if [[ "${ALREADY_LINKED}" == true ]]; then
        echo "[DRY-RUN] '${CR_NAME}' already uses Secret '${SECRET_NAME}'; the CR would not change."
        [[ "${KEY_CHANGED}" == true ]] && echo "[DRY-RUN] Would restart ${AGGREGATOR} to load the new key."
    else
        echo "[DRY-RUN] Would merge-patch ${KC_RESOURCE}/${CR_NAME} -n ${NAMESPACE}:"
        jq . <<<"${PATCH}"
    fi
    exit 0
fi

if [[ "${ALREADY_LINKED}" == true ]]; then
    echo "[OK] '${CR_NAME}' already uses Secret '${SECRET_NAME}'."
    if [[ "${KEY_CHANGED}" == true ]]; then
        # The CR is unchanged, so the operator does nothing; the aggregator
        # only reads the key at start.
        oc rollout restart "${AGGREGATOR}" -n "${NAMESPACE}" >/dev/null
        echo "[OK] Restarted ${AGGREGATOR} to load the new key."
    fi
else
    START_REV="$(kc_release_revision "${CR_NAME}" "${NAMESPACE}")"
    START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    oc patch "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" --type merge -p "${PATCH}" >/dev/null
    echo "[OK] '${CR_NAME}' now uses product key Secret '${SECRET_NAME}'."
    if [[ "${WAIT}" == true ]]; then
        kc_wait_for_release "${CR_NAME}" "${NAMESPACE}" "${START_REV}" "${START_TS}" "${TIMEOUT}" || exit 1
    fi
fi

if [[ "${WAIT}" == true && ( "${ALREADY_LINKED}" == false || "${KEY_CHANGED}" == true ) ]]; then
    echo "[INFO] Waiting for ${AGGREGATOR} (up to ${TIMEOUT}s)..."
    oc rollout status "${AGGREGATOR}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s" 2>&1 | sed 's/^/  /' \
        || die "${AGGREGATOR} did not become ready."
    echo "[OK] Product key linked to '${CR_NAME}'."
fi

kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false
echo "[OK] Details saved to ${REPLY#${_CP4D_REPO_ROOT}/}"
