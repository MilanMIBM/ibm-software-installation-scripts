#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Shows how to reach Kubecost instances: UI URL, login mode, who is admin,
# credentials (OIDC client secret, API master key) and the product key. Read
# from the cluster and saved to
#   configs/kubecost_config/<namespace>/<instance>-instance_details.sh
# (source it to get KUBECOST_* variables). A product key kept in a
# Secret is also saved to <secret>-productkey.json there when that file is
# missing; when the file holds another key, that is reported and the file kept
# (--update-key-file takes the cluster's key).
#
# Secrets are masked on screen unless --show-secrets; the saved files always
# hold them (gitignored, owner-only).
#
#   get_kubecost_instance_details.sh [<kubecost name> ...] [options]
#                                     no name: every Kubecost instance on the cluster
#     -n, --namespace <ns>            only instances in this namespace
#     --update-key-file               overwrite a local product key file that differs
#     --show-secrets                  print secrets in full
#     --offline                       show the saved files, don't ask the cluster
#     --server/--token/-u/-p          log in first (see ocu_login); otherwise OC_LOGIN
#                                     from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Shows how/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

NAMES=()
NAMESPACE=""
UPDATE_KEY_FILE=false
SHOW_SECRETS=false
OFFLINE=false
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)    NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        --update-key-file) UPDATE_KEY_FILE=true; shift ;;
        --show-secrets)    SHOW_SECRETS=true; shift ;;
        --offline)         OFFLINE=true; shift ;;
        --server)          LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)           LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)     LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)     LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        -*)                echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                 NAMES+=("$1"); shift ;;
    esac
done

# Prints a details file as "NAME  value", secrets masked unless --show-secrets.
show_details() {   # <file>
    local line name value
    echo
    echo "== ${1#${_CP4D_REPO_ROOT}/}"
    sed -n 's/^# //p' "$1" | head -1 | sed 's/^/   /'
    while IFS= read -r line; do
        [[ "${line}" == export\ * ]] || continue
        line="${line#export }"
        name="${line%%=*}"
        value="${(Q)line#*=}"
        if [[ "${SHOW_SECRETS}" != true && -n "${value}" \
              && "${name}" == *(_OIDC_CLIENT_SECRET|_PRODUCT_KEY|_API_MASTER_KEY|_POSTGRES_PASSWORD) ]]; then
            value="${value[1,4]}**** (--show-secrets)"
        fi
        printf '   %-44s %s\n' "${name}" "${value:--}"
    done < "$1"
}

# --- Offline: saved files only ---------------------------------------------------
if [[ "${OFFLINE}" == true ]]; then
    files=("${KC_CONFIG_DIR}"/${NAMESPACE:-*}/*-instance_details.sh(N))
    if (( ${#NAMES[@]} > 0 )); then
        files=(${(M)files:#*/(${(j:|:)~NAMES})-instance_details.sh})
    fi
    (( ${#files[@]} > 0 )) || die "No saved Kubecost instance details under ${KC_CONFIG_DIR#${_CP4D_REPO_ROOT}/}."
    for f in "${files[@]}"; do show_details "${f}"; done
    exit 0
fi

ocu_login

# --- Instances --------------------------------------------------------------------
# "<namespace>\t<name>" for each instance to show.
instances=("${(@f)$(oc get "${KC_RESOURCE}" -A -o json | jq -r --arg ns "${NAMESPACE}" \
    --args '.items[] | select($ns == "" or .metadata.namespace == $ns)
            | select(($ARGS.positional | length) == 0 or (.metadata.name | IN($ARGS.positional[])))
            | "\(.metadata.namespace)\t\(.metadata.name)"' "${NAMES[@]}")}")
instances=(${instances:#})
if (( ${#instances[@]} == 0 )); then
    echo "[ERROR] No matching Kubecost instance. Instances on the cluster:" >&2
    oc get "${KC_RESOURCE}" -A 2>&1 | sed 's/^/  /' >&2
    exit 1
fi
for n in "${NAMES[@]}"; do
    (( ${#${(M)instances:#*$'\t'${n}}} > 0 )) || die "No Kubecost instance named '${n}'${NAMESPACE:+ in ${NAMESPACE}}."
done

for entry in "${instances[@]}"; do
    ns="${entry%%$'\t'*}"; cr="${entry#*$'\t'}"
    kc_save_instance_details "${cr}" "${ns}" "${UPDATE_KEY_FILE}"
    show_details "${REPLY}"
done
