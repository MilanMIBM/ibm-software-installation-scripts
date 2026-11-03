#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Writes a template for Kubecost custom pricing: one set of monthly prices for
# the whole cluster (CPU, RAM, GPU, storage, network egress, and spot prices),
# no product key needed. Fill it in and apply it with
# apply_kubecost_custom_pricing.sh. For per-node-type prices use CSV pricing
# (csv_pricing/generate_kubecost_csv_pricing_template.sh, Enterprise).
#
#   configs/kubecost_config/<namespace>/<instance>-custom-pricing.conf
#
# Values already set on the instance are filled in; the cluster's totals are
# listed in the comments to help work out the prices. An existing file is
# kept unless --force (then the old one is saved as .bak).
#
#   generate_kubecost_custom_pricing_template.sh <kubecost name> [options]
#     -n, --namespace <ns>         default: the namespace holding that Kubecost CR
#     -o, --output <file>          default configs/kubecost_config/<ns>/<instance>-custom-pricing.conf
#     --force                      overwrite an existing file
#     --server/--token/-u/-p       log in first (see ocu_login); otherwise OC_LOGIN
#                                  from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Writes a template for Kubecost custom/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

CR_NAME=""
NAMESPACE=""
OUTPUT=""
FORCE=false
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)  NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        -o|--output)     OUTPUT="${2:?$1 needs a value}"; shift 2 ;;
        --force)         FORCE=true; shift ;;
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
CR_JSON="$(oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null)" \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
OUTPUT="${OUTPUT:-${KC_CONFIG_DIR}/${NAMESPACE}/${CR_NAME}-custom-pricing.conf}"

if [[ -f "${OUTPUT}" && "${FORCE}" != true ]]; then
    echo "[OK] ${OUTPUT#${_CP4D_REPO_ROOT}/} already exists; kept (--force regenerates it)."
    echo "Apply it: apply_kubecost_custom_pricing.sh ${CR_NAME}"
    exit 0
fi

NODES="$(kc_node_profiles)"
TOTALS="$(jq -r '"\(length) nodes, \([.[].cores] | add) cores, \([.[].memGiB] | add) GiB RAM, \([.[].gpus] | add) GPUs"' <<<"${NODES}")"
PV_GIB="$(oc get pv -o json | jq '[.items[].spec.capacity.storage // "0"
    | if test("Ti$") then (rtrimstr("Ti") | tonumber * 1024) elif test("Gi$") then (rtrimstr("Gi") | tonumber)
      elif test("Mi$") then (rtrimstr("Mi") | tonumber / 1024) else 0 end] | add // 0 | round')"
CURRENCY="$(jq -r '.spec.kubecostProductConfigs.currencyCode // "USD"' <<<"${CR_JSON}")"
CURRENT="$(jq -c '.spec.finopsagent.agent.kubecost.customPrices // {}' <<<"${CR_JSON}")"
cur() { jq -r --arg k "$1" '.[$k] // "" | tostring' <<<"${CURRENT}"; }

if [[ -f "${OUTPUT}" ]]; then
    cp -p "${OUTPUT}" "${OUTPUT}.$(date -u +%Y%m%dT%H%M%SZ).bak"
fi
cat <<EOF | _kc_write_private "${OUTPUT}"
# Kubecost custom pricing for ${CR_NAME} (${NAMESPACE})
# Cluster $(oc whoami --show-server): ${TOTALS}, ${PV_GIB} GiB of PVs
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by ${SCRIPT_FILE:t}; apply with apply_kubecost_custom_pricing.sh ${CR_NAME}
#
# One price per resource for the whole cluster, in ${CURRENCY}, PER MONTH
# (hourly x 730). Leave a value empty to keep Kubecost's default for it.
# Free feature (no product key). Prices per node type: CSV pricing.
#
# Example: to cost a node of 32 cores / 126 GiB at 1000/month with 70% on CPU:
#   CPU = 700 / 32 = 21.875   RAM = 300 / 126 = 2.381
#
# Kubecost docs examples in comments.

# Per CPU core per month (example 28.0)
CPU=$(cur CPU)
# Per CPU core per month on spot/preemptible nodes (example 4.86)
spotCPU=$(cur spotCPU)
# Per GB of RAM per month (example 3.09)
RAM=$(cur RAM)
# Per GB of RAM per month on spot nodes (example 0.65)
spotRAM=$(cur spotRAM)
# Per GPU per month (example 693.50)
GPU=$(cur GPU)
# Per GPU per month on spot nodes (example 225.0)
spotGPU=$(cur spotGPU)
# Per GB of persistent storage per month (example 0.04)
storage=$(cur storage)
# Per GB of network egress within a zone (example 0.01)
zoneNetworkEgress=$(cur zoneNetworkEgress)
# Per GB of network egress across zones in a region (example 0.01)
regionNetworkEgress=$(cur regionNetworkEgress)
# Per GB of network egress to the internet (example 0.12)
internetNetworkEgress=$(cur internetNetworkEgress)
EOF
echo "[OK] Template: ${OUTPUT#${_CP4D_REPO_ROOT}/}"
echo "     Cluster: ${TOTALS}, ${PV_GIB} GiB of PVs; prices are monthly in ${CURRENCY}."
echo "Fill it in, then apply: apply_kubecost_custom_pricing.sh ${CR_NAME}"
