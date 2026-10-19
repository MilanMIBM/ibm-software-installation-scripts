#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Writes a restore target cluster config to restore_target_configs/<name>_vars.sh
# (gitignored, owner-only): the cluster to restore a Software Hub backup onto.
#
# The file has the same shape as cpd_vars.sh (OCP_URL, OC_LOGIN, CPDM_OC_LOGIN,
# PROJECT_*), so besides the --target option of the scripts in this folder, any
# other script in the repo can be pointed at the target cluster with it, e.g. to
# set up the global pull secret there before restoring:
#
#     ENV_TARGET=<path to the file> ./scripts/install_cloud_pak_for_data/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh
#     source s_env.sh <path to the file>      # log your shell in to the target
#
# A tenant restore recreates the instance in the namespaces it was backed up
# from, so the project names default to the ones in the loaded source config
# (cpd_vars.sh, or ENV_TARGET). Registry, version and storage class settings are
# copied from it too, unless --no-copy-source.
#
# Run with no options, it writes a template named target-<6 hex chars>: cluster
# URL and login empty, project names and copied settings from the source config,
# every field explained in the file; fill it in by hand. Options fill in what
# they name. --interactive asks for the rest instead (tokens/passwords without echo).
#
#   1.2_generate_restore_target_config.sh [options]
#     --name <name>               config name (file: <name>_vars.sh; default target-<id>)
#     --server <url>              target API URL, e.g. https://api.<cluster>:6443
#     --token <token>             log in with a token, or:
#     --username <user> [--password <pw>]
#     --oadp-project <ns>         OADP project on the target (default: source OADP_PROJECT, else oadp-operator)
#     --operators-ns <ns>         default: source PROJECT_CPD_INST_OPERATORS
#     --operands-ns <ns>          default: source PROJECT_CPD_INST_OPERANDS
#     --scheduler-ns <ns>         default: source PROJECT_SCHEDULING_SERVICE
#     --license-ns <ns>           default: source PROJECT_LICENSE_SERVICE
#     --no-copy-source            do not copy registry/version/storage settings from the source config
#     -i, --interactive           ask for the values not given as options
#     --force                     overwrite an existing config with that name
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Repo root only for now: the env is loaded after the options are parsed,
# because --target decides which config to load.
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; unset _b
source "${REPO_ROOT}/src/helpers/oadp_br_helpers.sh"

CFG_NAME=""
T_SERVER=""
T_TOKEN=""
T_USERNAME=""
T_PASSWORD=""
T_OADP_PROJECT=""
T_OPERATORS=""
T_OPERANDS=""
T_SCHEDULER=""
T_LICENSE=""
COPY_SOURCE=true
OADP_INTERACTIVE=false
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)           CFG_NAME="${2:?--name needs a value}"; shift 2 ;;
        --server)         T_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)          T_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        --username)       T_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        --password)       T_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        --oadp-project)   T_OADP_PROJECT="${2:?--oadp-project needs a namespace}"; shift 2 ;;
        --operators-ns)   T_OPERATORS="${2:?--operators-ns needs a namespace}"; shift 2 ;;
        --operands-ns)    T_OPERANDS="${2:?--operands-ns needs a namespace}"; shift 2 ;;
        --scheduler-ns)   T_SCHEDULER="${2:?--scheduler-ns needs a namespace}"; shift 2 ;;
        --license-ns)     T_LICENSE="${2:?--license-ns needs a namespace}"; shift 2 ;;
        --no-copy-source) COPY_SOURCE=false; shift ;;
        -i|--interactive) OADP_INTERACTIVE=true; shift ;;
        --force)          FORCE=true; shift ;;
        -h|--help)        oadp_usage "$0"; exit 0 ;;
        *)                echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done
if [[ -n "${T_TOKEN}" && -n "${T_USERNAME}" ]]; then
    echo "[ERROR] Pass either --token or --username, not both." >&2
    exit 1
fi

# Source config: defaults for the project names, and the settings copied below.
# --- Env load (repo root found above) ---
source "${REPO_ROOT}/env_bootstrap.sh"

oadp_prompt CFG_NAME "Config name" "target-$(oadp_short_id)"
if [[ ! "${CFG_NAME}" =~ '^[A-Za-z0-9][A-Za-z0-9_.-]*$' ]]; then
    echo "[ERROR] Config name may only contain letters, digits, '.', '_' and '-' (got '${CFG_NAME}')." >&2
    exit 1
fi
OUT_FILE="${TARGET_CONFIG_DIR}/${CFG_NAME}${TARGET_CONFIG_SUFFIX}"
if [[ -f "${OUT_FILE}" && "${FORCE}" != "true" ]]; then
    echo "[ERROR] ${OUT_FILE} already exists. Pass --force to overwrite it." >&2
    exit 1
fi

oadp_prompt T_SERVER "Target cluster API URL (https://api.<cluster>:6443)"
T_SERVER="${T_SERVER%/}"
if [[ -n "${T_SERVER}" && "${T_SERVER}" == "${OCP_URL:-}" ]]; then
    echo "[WARN] ${T_SERVER} is the source cluster from the loaded config. That is only right for a same-cluster restore."
fi

if [[ "${OADP_INTERACTIVE}" == "true" && -z "${T_TOKEN}${T_USERNAME}" ]]; then
    LOGIN_KIND=""
    oadp_prompt LOGIN_KIND "Log in with a 'token' or 'password'" "token"
    case "${LOGIN_KIND}" in
        token)    oadp_prompt T_TOKEN "Token (sha256~...)" "" secret ;;
        password) oadp_prompt T_USERNAME "Username" "kubeadmin" ;;
        *)        echo "[ERROR] Answer 'token' or 'password'." >&2; exit 1 ;;
    esac
fi
[[ -n "${T_USERNAME}" ]] && oadp_prompt T_PASSWORD "Password for ${T_USERNAME}" "" secret

oadp_prompt T_OADP_PROJECT "OADP project on the target" "${OADP_PROJECT}"
oadp_prompt T_OPERATORS "Operators project (must match the backup)" "${PROJECT_CPD_INST_OPERATORS:-}"
oadp_prompt T_OPERANDS "Operands project (must match the backup)" "${PROJECT_CPD_INST_OPERANDS:-}"
oadp_prompt T_SCHEDULER "Scheduling service project" "${PROJECT_SCHEDULING_SERVICE:-cpd-scheduler}"
oadp_prompt T_LICENSE "License service project" "${PROJECT_LICENSE_SERVICE:-cpd-license}"

# Settings copied from the source config so the repo's other scripts (pull
# secret, cpd-cli manage, ...) work against the target with this file alone.
COPY_VARS=(
    OPENSHIFT_TYPE IMAGE_ARCH
    PROJECT_IBM_EVENTS PROJECT_PRIVILEGED_MONITORING_SERVICE
    STG_CLASS_BLOCK STG_CLASS_FILE
    IBM_ENTITLEMENT_KEY
    PRIVATE_REGISTRY_LOCATION PRIVATE_REGISTRY_PUSH_USER PRIVATE_REGISTRY_PUSH_PASSWORD
    PRIVATE_REGISTRY_PULL_USER PRIVATE_REGISTRY_PULL_PASSWORD
    IMAGE_PULL_SECRET IMAGE_PULL_CREDENTIALS IMAGE_PULL_PREFIX IMAGE_PUSH_CREDENTIALS IMAGE_PUSH_PREFIX
    VERSION PATCH_ID OLM_UTILS_IMAGE CPD_ADMIN_USERNAME
    SOFTWARE_HUB CPD_COMPONENTS COMPLETE_COMPONENT_LIST
)

mkdir -p "${TARGET_CONFIG_DIR}"
chmod 700 "${TARGET_CONFIG_DIR}"
umask 077
{
    print -r -- "#==============================================================================="
    print -r -- "# Restore target cluster: ${CFG_NAME}"
    print -r -- "# Generated by $(basename "$0") on $(date '+%Y-%m-%d %H:%M:%S')"
    print -r -- "# Contains cluster credentials - keep it out of git (it is gitignored)."
    print -r -- "#==============================================================================="
    print -r -- ""
    print -r -- "export OADP_RESTORE_TARGET_NAME=${(qq)CFG_NAME}"
    print -r -- ""
    print -r -- "# ------------------------------------------------------------------------------"
    print -r -- "# Cluster"
    print -r -- "# ------------------------------------------------------------------------------"
    print -r -- ""
    print -r -- "# Target API URL, e.g. https://api.<cluster>:6443"
    print -r -- "export OCP_URL=${(qq)T_SERVER}"
    print -r -- "# Log in with a token (oc whoami -t), or leave it empty and set username + password."
    print -r -- "# Needs cluster-admin."
    print -r -- "export OCP_TOKEN=${(qq)T_TOKEN}"
    print -r -- "export OCP_USERNAME=${(qq)T_USERNAME}"
    print -r -- "export OCP_PASSWORD=${(qq)T_PASSWORD}"
    print -r -- 'if [ -n "${OCP_TOKEN}" ]; then'
    print -r -- '    export LOGIN_ARGUMENTS="--token=${OCP_TOKEN}"'
    print -r -- 'else'
    print -r -- '    export LOGIN_ARGUMENTS="--username=${OCP_USERNAME} --password=${OCP_PASSWORD}"'
    print -r -- 'fi'
    print -r -- 'export SERVER_ARGUMENTS="--server=${OCP_URL}"'
    print -r -- 'export OC_LOGIN="oc login ${SERVER_ARGUMENTS} ${LOGIN_ARGUMENTS}"'
    print -r -- 'export CPDM_OC_LOGIN="cpd-cli manage login-to-ocp ${SERVER_ARGUMENTS} ${LOGIN_ARGUMENTS}"'
    print -r -- ""
    print -r -- "# ------------------------------------------------------------------------------"
    print -r -- "# Projects (a tenant restore recreates the instance in the backed-up namespaces)"
    print -r -- "# ------------------------------------------------------------------------------"
    print -r -- ""
    print -r -- "export OADP_PROJECT=${(qq)T_OADP_PROJECT}"
    print -r -- "export PROJECT_CPD_INST_OPERATORS=${(qq)T_OPERATORS}"
    print -r -- "export PROJECT_CPD_INST_OPERANDS=${(qq)T_OPERANDS}"
    print -r -- "export PROJECT_SCHEDULING_SERVICE=${(qq)T_SCHEDULER}"
    print -r -- "export PROJECT_LICENSE_SERVICE=${(qq)T_LICENSE}"
    if [[ "${COPY_SOURCE}" == "true" ]]; then
        print -r -- ""
        print -r -- "# ------------------------------------------------------------------------------"
        print -r -- "# Copied from the source config (${ENV_TARGET_FILE:-${CONFIG_DIR}/cpd_vars.sh})"
        print -r -- "# Storage class names must exist on this cluster too, or the restored PVCs stay Pending."
        print -r -- "# ------------------------------------------------------------------------------"
        print -r -- ""
        for _v in "${COPY_VARS[@]}"; do
            [[ -n "${(P)_v:-}" ]] && print -r -- "export ${_v}=${(qq)${(P)_v}}"
        done
    fi
} > "${OUT_FILE}"
# 700, not 600: env_bootstrap.sh chmods every .sh +x, and re-runs that prep while any is not.
chmod 700 "${OUT_FILE}"

echo "[OK] Wrote ${OUT_FILE}"
# Read the values back from the file itself, under the names it uses.
(
    source "${OUT_FILE}"
    TODO_VARS=(OCP_URL PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS)
    if [[ -n "${OCP_USERNAME}" ]]; then TODO_VARS+=(OCP_PASSWORD); else TODO_VARS+=(OCP_TOKEN); fi
    oadp_report_empty "${OUT_FILE}" "${TODO_VARS[@]}" \
        || { [[ -z "${OCP_TOKEN}${OCP_USERNAME}" ]] && echo "         (or OCP_USERNAME + OCP_PASSWORD instead of OCP_TOKEN)"; }
) || true
echo "[INFO] Check the login with: source ${REPO_ROOT}/s_env.sh ${OUT_FILE}"
echo "[INFO] Next: ${SCRIPT_DIR}/2_install_oadp_br_utilities.sh --target ${CFG_NAME}"
