#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Creates (or updates) the Secret holding a Kubecost Enterprise product key, so
# the Kubecost CR can reference it instead of carrying the key in plain text:
#
#   spec:
#     kubecostProductConfigs:
#       productKey:
#         enabled: true
#         secretname: kubecost-product-key
#
# The chart mounts the Secret's 'productkey.json' entry into the aggregator; the
# file must be {"key": "<product key>"}. See
# https://www.ibm.com/docs/en/kubecost/self-hosted/3.x?topic=configuration-adding-product-key
#
# The key is also saved to configs/kubecost_config/<namespace>/<secret>-productkey.json
# (gitignored, owner-only), so the key in use can be looked up later.
#
# The Secret has to be in the namespace of the Kubecost CR, which is the
# namespace the operator watches. Without -n, KUBECOST_OPERATOR_NAMESPACE from
# configs/kubecost_config/kubecost_vars.sh is used, else the namespace of the
# Kubecost operator on the cluster (found by its Deployment, else its OLM
# Subscription); if there is more than one, pass -n.
#
#   create_kubecost_product_key_secret.sh <key> [options]
#   create_kubecost_product_key_secret.sh [options]       KUBECOST_PRODUCT_KEY from kubecost_vars.sh,
#                                                         else asks for the key (no echo)
#     -k, --key <key>             product key (or as the first argument)
#     -f, --key-file <file>       file with {"key": "..."} (productkey.json) or the bare
#                                 key; '-' reads it from stdin
#     -s, --secret-name <name>    default KUBECOST_PRODUCT_KEY_SECRET (kubecost_vars.sh),
#                                 else kubecost-product-key
#     -n, --namespace <ns>        default: KUBECOST_OPERATOR_NAMESPACE (kubecost_vars.sh),
#                                 else the Kubecost operator's namespace
#     --dry-run                   print the Secret (key masked), change nothing
#     --server/--token/-u/-p      log in first (see ocu_login); otherwise OC_LOGIN
#                                 from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Creates/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }

PRODUCT_KEY=""
KEY_FILE=""
SECRET_NAME="${KUBECOST_PRODUCT_KEY_SECRET:-kubecost-product-key}"
NAMESPACE=""
DRY_RUN=false
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--key)          PRODUCT_KEY="${2:?--key needs a value}"; shift 2 ;;
        -f|--key-file)     KEY_FILE="${2:?--key-file needs a path}"; shift 2 ;;
        -s|--secret-name)  SECRET_NAME="${2:?--secret-name needs a value}"; shift 2 ;;
        -n|--namespace)    NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --server)          LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)           LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)     LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)     LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        -*)                echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [[ -n "${PRODUCT_KEY}" ]]; then
                echo "[ERROR] Unexpected argument: $1 (the key was already given)" >&2; exit 1
            fi
            PRODUCT_KEY="$1"; shift ;;
    esac
done

if [[ -n "${KEY_FILE}" ]]; then
    if [[ -n "${PRODUCT_KEY}" ]]; then
        echo "[ERROR] Pass the key or --key-file, not both." >&2; exit 1
    fi
    PRODUCT_KEY="$(kc_read_key_file "${KEY_FILE}")" || exit 1
fi
if [[ -z "${PRODUCT_KEY}" && -n "${KUBECOST_PRODUCT_KEY:-}" ]]; then
    PRODUCT_KEY="${KUBECOST_PRODUCT_KEY}"
    echo "[INFO] No key given; using KUBECOST_PRODUCT_KEY from ${KC_VARS_FILE} (${PRODUCT_KEY[1,4]}****)."
fi
if [[ -z "${PRODUCT_KEY}" ]]; then
    if [[ ! -t 0 ]]; then
        echo "[ERROR] No product key given. Pass it as an argument, --key or --key-file." >&2
        exit 1
    fi
    echo -n "Kubecost product key: "
    read -rs PRODUCT_KEY
    echo
fi
# Pasted keys often carry a trailing newline or spaces.
PRODUCT_KEY="${PRODUCT_KEY//[[:space:]]/}"
if [[ -z "${PRODUCT_KEY}" ]]; then
    echo "[ERROR] The product key is empty." >&2
    exit 1
fi

ocu_login

# --- Namespace ---------------------------------------------------------------
# The operator's Deployment carries app.kubernetes.io/name=kubecost-operator;
# an OLM install also has a Subscription to the kubecost-operator package.
find_operator_namespaces() {
    {
        oc get deployments -A -l app.kubernetes.io/name=kubecost-operator \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null || true
        oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null \
            | jq -r '.items[] | select(.spec.name | test("kubecost"; "i")) | .metadata.namespace' 2>/dev/null || true
    } | sed '/^$/d' | sort -u
}

if [[ -z "${NAMESPACE}" && -n "${KUBECOST_OPERATOR_NAMESPACE:-}" ]]; then
    if oc get namespace "${KUBECOST_OPERATOR_NAMESPACE}" &>/dev/null; then
        NAMESPACE="${KUBECOST_OPERATOR_NAMESPACE}"
        echo "[INFO] Namespace from KUBECOST_OPERATOR_NAMESPACE (${KC_VARS_FILE}): '${NAMESPACE}'."
    else
        echo "[WARN] KUBECOST_OPERATOR_NAMESPACE='${KUBECOST_OPERATOR_NAMESPACE}' (${KC_VARS_FILE}) does not exist; looking for the operator." >&2
    fi
fi
if [[ -z "${NAMESPACE}" ]]; then
    found=("${(@f)$(find_operator_namespaces)}")
    found=(${found:#})
    case ${#found[@]} in
        0)  echo "[ERROR] No Kubecost operator found on the cluster. Pass -n <namespace>." >&2
            exit 1 ;;
        1)  NAMESPACE="${found[1]}"
            echo "[INFO] Kubecost operator found in namespace '${NAMESPACE}'." ;;
        *)  echo "[ERROR] Kubecost operators found in several namespaces: ${found[*]}" >&2
            echo "[ERROR] Pass -n <namespace> (the namespace of your Kubecost CR)." >&2
            exit 1 ;;
    esac
elif ! oc get namespace "${NAMESPACE}" &>/dev/null; then
    echo "[ERROR] Namespace '${NAMESPACE}' does not exist." >&2
    exit 1
fi

# --- Secret ------------------------------------------------------------------
# jq builds the JSON so a key with quotes or backslashes still ends up valid.
KEY_JSON="$(jq -cn --arg k "${PRODUCT_KEY}" '{key: $k}')"

render_secret() {
    print -rn -- "$1" | oc create secret generic "${SECRET_NAME}" -n "${NAMESPACE}" \
        --from-file=productkey.json=/dev/stdin --dry-run=client -o yaml
}

if [[ "${DRY_RUN}" == true ]]; then
    masked="${PRODUCT_KEY[1,4]}****"
    echo "[DRY-RUN] Would apply (key masked as ${masked}):"
    render_secret "$(jq -cn --arg k "${masked}" '{key: $k}')"
else
    action="created"
    oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null && action="updated"
    render_secret "${KEY_JSON}" | oc apply -f - >/dev/null
    echo "[OK] Secret '${SECRET_NAME}' ${action} in namespace '${NAMESPACE}'."
    kc_save_product_key_file "${NAMESPACE}" "${SECRET_NAME}" "${PRODUCT_KEY}" true
fi

cat <<EOF

Reference it from your Kubecost CR in '${NAMESPACE}':

  spec:
    kubecostProductConfigs:
      productKey:
        enabled: true
        secretname: ${SECRET_NAME}
EOF
