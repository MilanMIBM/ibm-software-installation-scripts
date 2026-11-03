#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Writes the optional-features config of a Kubecost instance, filled in from
# what the instance runs now (its effective Helm values and the Secrets the
# features use):
#
#   configs/kubecost_config/<namespace>/<instance>-features.yaml
#
# Network costs, alerts (+ SMTP), budgets, saved reports, data retention,
# carbon estimates, cost events audit, cost allocation (shared namespaces,
# overhead, idle, label mapping, savings profiles), teams, Turbonomic,
# plugins, federated storage and Actions. Each section has its own
# "enabled:"; edit the file, then apply it with apply_kubecost_features.sh.
#
# An existing file is kept unless --force (then the old one is saved as
# .bak), so edits not applied yet are not lost.
#
#   generate_kubecost_features_config.sh <kubecost name> [options]
#     -n, --namespace <ns>         default: the namespace holding that Kubecost CR
#     -o, --output <file>          default configs/kubecost_config/<ns>/<instance>-features.yaml
#     --force                      overwrite an existing file (pull the cluster's settings again)
#     --stdout                     print it instead of writing a file
#     --server/--token/-u/-p       log in first (see ocu_login); otherwise OC_LOGIN
#                                  from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Writes the optional-features config/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

CR_NAME=""
NAMESPACE=""
OUTPUT=""
FORCE=false
STDOUT=false
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)  NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        -o|--output)     OUTPUT="${2:?$1 needs a value}"; shift 2 ;;
        --force)         FORCE=true; shift ;;
        --stdout)        STDOUT=true; shift ;;
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

ocu_login
[[ -n "${NAMESPACE}" ]] || NAMESPACE="$(kc_find_instance_namespace "${CR_NAME}")" || exit 1
oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" &>/dev/null \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
kc_features_file "${NAMESPACE}" "${CR_NAME}"
OUTPUT="${OUTPUT:-${REPLY}}"

if [[ "${STDOUT}" != true && -f "${OUTPUT}" && "${FORCE}" != true ]]; then
    echo "[OK] ${OUTPUT#${_CP4D_REPO_ROOT}/} already exists; kept (--force pulls the cluster's settings again)."
    echo "Apply it: apply_kubecost_features.sh ${CR_NAME}"
    exit 0
fi

CTX="$(mktemp "${${TMPDIR:-/tmp}%/}/kc-features-ctx.XXXXXX")"
trap 'rm -f "${CTX}"' EXIT
kc_features_context "${CR_NAME}" "${NAMESPACE}" "${CTX}"
CONTENT="$(kc_python generate --ctx "${CTX}")" || die "Could not generate the features config."

if [[ "${STDOUT}" == true ]]; then
    print -r -- "${CONTENT}"
    exit 0
fi
[[ -f "${OUTPUT}" ]] && cp -p "${OUTPUT}" "${OUTPUT}.$(date -u +%Y%m%dT%H%M%SZ).bak"
print -r -- "${CONTENT}" | _kc_write_private "${OUTPUT}"
echo "[OK] Features config: ${OUTPUT#${_CP4D_REPO_ROOT}/}"
# What is on now, from the file just written.
kc_python plan --ctx "${CTX}" --file "${OUTPUT}" \
    | jq -r '.summary[]? | "     \(.feature): \(.state)"' || true
echo "Edit it, then apply: apply_kubecost_features.sh ${CR_NAME} [--dry-run]"
