#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# No env_bootstrap here: the config this script writes is what the other
# scripts load, so it may not exist yet. Find the repo root the same way.
REPO_ROOT="${SCRIPT_DIR}"; while [[ "${REPO_ROOT}" != "/" && ! -f "${REPO_ROOT}/env_bootstrap.sh" ]]; do REPO_ROOT="$(dirname "${REPO_ROOT}")"; done

usage() {
    cat <<'USAGE'
Write configs/cp4d_config/swhub_control_center/swhub_control_center_vars.sh for the
optional Software Hub Control Center sub-install.

  0_swhub_control_center_generate_config.sh                  --from-cpd when
                                                             cpd_vars.sh exists,
                                                             else --empty
  0_swhub_control_center_generate_config.sh --from-cpd [FILE] [options]
  0_swhub_control_center_generate_config.sh --empty [options]

Modes:
  --from-cpd [FILE]     Derive it from a CP4D config (default configs/cp4d_config/
                        cpd_vars.sh). The new file sources cpd_vars.sh, so the
                        cluster login, storage, version and patch stay in step
                        with it. Needs FILE to sit one folder above the output.
  --empty               No cpd_vars.sh: recommended values, with the cluster login
                        left blank to fill in. Implies --cluster different.

Options:
  --cluster same|different  Where Control Center runs relative to the instances
                            (default: same with --from-cpd)
  --operators-project NS    Default: PROJECT_SW_HUB_CONTROL_CENTER_OPERATORS, else
                            cpd-swhub-center
  --operands-project NS     Default: PROJECT_SW_HUB_CONTROL_CENTER_OPERANDS, else
                            cpd-swhub-center-operands
  --premium-tag TAG         Premium olm-utils tag without the architecture
                            (default: VERSION, the tag that tracks the newest patch)
  --oauth-client-id ID      Default: ibm-software-hub-cc
  --no-autodetect           Set AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES to false
  --cluster-display-name N  Name shown in Control Center (default: the name in the
                            API address)
  --account-name NAME       Account for auto-detected instances (default:
                            software-hub-instances)
  --account-cpu CORES       vCPU for that account (default: all worker capacity)
  --account-memory-gi GI    Memory for that account (default: all worker capacity)
  --rotate-api-keys         Let auto-detect generate new API keys, which revokes the
                            current ones (default: off)
  --verify-wait SECONDS     How long to wait for the browser approval (default: 600)
  --no-cluster-admins       Set CONTROL_ADD_CLUSTER_ADMINS to false
  --admin-users LIST        Give the roles to these users (comma-separated) instead
                            of the cluster-admins
  --admin-roles LIST        Roles to give, comma-separated (default:
                            zen_administrator_role)
  --admin-exclude-users L   Cluster-admins to leave out, comma-separated
  --out FILE                Write somewhere else
  --force                   Overwrite an existing file (a timestamped .bak is kept)
  --dry-run                 Print the file instead of writing it
  -h, --help                Show this help

The OAuth client secret is generated, and kept when an existing file is rewritten.
To run the sub-install at the end of the main install, also set
INSTALL_SWHUB_CONTROL_CENTER="true" in cpd_vars.sh.
USAGE
}

MODE=""
CPD_FILE="${REPO_ROOT}/configs/cp4d_config/cpd_vars.sh"
OUT_FILE="${REPO_ROOT}/configs/cp4d_config/swhub_control_center/swhub_control_center_vars.sh"
CLUSTER_MODE=""
OPERATORS_PROJECT=""
OPERANDS_PROJECT=""
PREMIUM_TAG=""
OAUTH_CLIENT_ID=""
AUTODETECT=true
CLUSTER_DISPLAY_NAME=""
ACCOUNT_NAME=""
ACCOUNT_CPU=""
ACCOUNT_MEMORY_GI=""
ROTATE_API_KEYS=false
VERIFY_WAIT=""
CLUSTER_ADMINS=true
ADMIN_USERS=""
ADMIN_ROLES=""
ADMIN_EXCLUDE_USERS=""
FORCE=false
DRY_RUN=false

need_value() { [[ -n "${2:-}" ]] || { echo "[ERROR] $1 needs a value" >&2; exit 1; }; }

while (( $# )); do
    case "$1" in
        --from-cpd)
            MODE=from-cpd
            if [[ -n "${2:-}" && "${2}" != --* ]]; then CPD_FILE="$2"; shift; fi
            shift ;;
        --empty)             MODE=empty; shift ;;
        --cluster)           need_value "$1" "${2:-}"; CLUSTER_MODE="$2"; shift 2 ;;
        --operators-project) need_value "$1" "${2:-}"; OPERATORS_PROJECT="$2"; shift 2 ;;
        --operands-project)  need_value "$1" "${2:-}"; OPERANDS_PROJECT="$2"; shift 2 ;;
        --premium-tag)       need_value "$1" "${2:-}"; PREMIUM_TAG="$2"; shift 2 ;;
        --oauth-client-id)   need_value "$1" "${2:-}"; OAUTH_CLIENT_ID="$2"; shift 2 ;;
        --out)               need_value "$1" "${2:-}"; OUT_FILE="$2"; shift 2 ;;
        --no-autodetect)     AUTODETECT=false; shift ;;
        --cluster-display-name) need_value "$1" "${2:-}"; CLUSTER_DISPLAY_NAME="$2"; shift 2 ;;
        --account-name)      need_value "$1" "${2:-}"; ACCOUNT_NAME="$2"; shift 2 ;;
        --account-cpu)       need_value "$1" "${2:-}"; ACCOUNT_CPU="$2"; shift 2 ;;
        --account-memory-gi) need_value "$1" "${2:-}"; ACCOUNT_MEMORY_GI="$2"; shift 2 ;;
        --rotate-api-keys)   ROTATE_API_KEYS=true; shift ;;
        --verify-wait)       need_value "$1" "${2:-}"; VERIFY_WAIT="$2"; shift 2 ;;
        --no-cluster-admins) CLUSTER_ADMINS=false; shift ;;
        --admin-users)       need_value "$1" "${2:-}"; ADMIN_USERS="$2"; shift 2 ;;
        --admin-roles)       need_value "$1" "${2:-}"; ADMIN_ROLES="$2"; shift 2 ;;
        --admin-exclude-users) need_value "$1" "${2:-}"; ADMIN_EXCLUDE_USERS="$2"; shift 2 ;;
        --force)             FORCE=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "${MODE}" ]]; then
    [[ -f "${CPD_FILE}" ]] && MODE=from-cpd || MODE=empty
fi
[[ "${CLUSTER_MODE}" == (|same|different) ]] || { echo "[ERROR] --cluster must be same or different" >&2; exit 1; }

if [[ -f "${OUT_FILE}" && "${FORCE}" != true && "${DRY_RUN}" != true ]]; then
    echo "[ERROR] ${OUT_FILE} already exists. Use --force to rewrite it (a .bak is kept)." >&2
    exit 1
fi

# Read one value from cpd_vars.sh in a child shell, so nothing leaks into this one.
cpd_value() { zsh -c 'source "$1" >/dev/null 2>&1; print -r -- "${(P)2:-}"' _ "${CPD_FILE}" "$1"; }

args=()
VERSION_VALUE="5.4.0"; PATCH_VALUE=""
if [[ "${MODE}" == from-cpd ]]; then
    [[ -f "${CPD_FILE}" ]] || { echo "[ERROR] ${CPD_FILE} not found. Use --empty, or generate it first." >&2; exit 1; }
    [[ "${CPD_FILE:A:h}" == "${OUT_FILE:A:h:h}" ]] \
        || { echo "[ERROR] The generated file sources ../cpd_vars.sh, so ${CPD_FILE} must sit one folder above ${OUT_FILE}." >&2; exit 1; }
    : "${CLUSTER_MODE:=same}"
    VERSION_VALUE="$(cpd_value VERSION)"
    PATCH_VALUE="$(cpd_value PATCH_ID)"
    : "${OPERATORS_PROJECT:=$(cpd_value PROJECT_SW_HUB_CONTROL_CENTER_OPERATORS)}"
    : "${OPERANDS_PROJECT:=$(cpd_value PROJECT_SW_HUB_CONTROL_CENTER_OPERANDS)}"
    args+=(--set has_cpd_vars=true)
else
    [[ "${CLUSTER_MODE}" != same ]] || { echo "[ERROR] --cluster same needs cpd_vars.sh; use --from-cpd." >&2; exit 1; }
    CLUSTER_MODE=different
    args+=(--set has_cpd_vars=false --set "version=${VERSION_VALUE}")
fi
args+=(--set "cluster_mode=${CLUSTER_MODE}" --set "patch_id=${PATCH_VALUE}" --set "autodetect=${AUTODETECT}")

# The release tag tracks the newest patch; the numbered patch tags stop early.
: "${PREMIUM_TAG:=${VERSION_VALUE}}"
[[ -n "${PREMIUM_TAG}" ]]       && args+=(--set "premium_tag=${PREMIUM_TAG}")
[[ -n "${OPERATORS_PROJECT}" ]] && args+=(--set "operators_project=${OPERATORS_PROJECT}")
[[ -n "${OPERANDS_PROJECT}" ]]  && args+=(--set "operands_project=${OPERANDS_PROJECT}")
[[ -n "${OAUTH_CLIENT_ID}" ]]   && args+=(--set "oauth_client_id=${OAUTH_CLIENT_ID}")
[[ -n "${CLUSTER_DISPLAY_NAME}" ]] && args+=(--set "cluster_display_name=${CLUSTER_DISPLAY_NAME}")
[[ -n "${ACCOUNT_NAME}" ]]      && args+=(--set "account_name=${ACCOUNT_NAME}")
[[ -n "${ACCOUNT_CPU}" ]]       && args+=(--set "account_cpu=${ACCOUNT_CPU}")
[[ -n "${ACCOUNT_MEMORY_GI}" ]] && args+=(--set "account_memory_gi=${ACCOUNT_MEMORY_GI}")
[[ -n "${VERIFY_WAIT}" ]]       && args+=(--set "verify_wait_seconds=${VERIFY_WAIT}")
[[ -n "${ADMIN_USERS}" ]]       && args+=(--set "admin_users=${ADMIN_USERS}")
[[ -n "${ADMIN_ROLES}" ]]       && args+=(--set "admin_roles=${ADMIN_ROLES}")
[[ -n "${ADMIN_EXCLUDE_USERS}" ]] && args+=(--set "admin_exclude_users=${ADMIN_EXCLUDE_USERS}")
args+=(--set "rotate_api_keys=${ROTATE_API_KEYS}" --set "add_cluster_admins=${CLUSTER_ADMINS}")

# Keep the OAuth secret of an existing file: the client on the cluster holds it.
OAUTH_SECRET=""
if [[ -f "${OUT_FILE}" ]]; then
    OAUTH_SECRET="$(sed -n 's/^export CONTROL_OAUTH_SECRET="\(.*\)"$/\1/p' "${OUT_FILE}" | tail -1)"
fi
[[ -n "${OAUTH_SECRET}" ]] || OAUTH_SECRET="$(LC_ALL=C openssl rand -hex 16)"
args+=(--set "oauth_secret=${OAUTH_SECRET}")

python_bin=python3
[[ -x "${REPO_ROOT}/.venv/bin/python" ]] && python_bin="${REPO_ROOT}/.venv/bin/python"
render=("${python_bin}" "${REPO_ROOT}/src/helpers/swhub_control_center_config_render.py" "${args[@]}")

if [[ "${DRY_RUN}" == true ]]; then
    "${render[@]}"
    exit 0
fi

if [[ -f "${OUT_FILE}" ]]; then
    cp -p "${OUT_FILE}" "${OUT_FILE}.$(date +%Y%m%d-%H%M%S).bak"
fi
"${render[@]}" --out "${OUT_FILE}"
echo "[INFO] Wrote ${OUT_FILE} (${MODE}, cluster: ${CLUSTER_MODE})"
[[ "${MODE}" == empty ]] && echo "[INFO] Fill in the cluster login and IBM_ENTITLEMENT_KEY before installing."
echo "[INFO] Next: ${SCRIPT_DIR}/full_installprocess-swhub_control_center.sh"
