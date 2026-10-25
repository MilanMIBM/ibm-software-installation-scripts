#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Adds a username/password login (HTPasswd identity provider) to the cluster,
# next to the existing "IBM ID" button, and creates one account per user below.
# Meant for TechZone clusters where IBMid login fails with CSIAG0137E for some
# people: that check happens in TechZone's IBM Verify tenant, outside the
# cluster, so nothing in OpenShift can fix it. This login bypasses Verify.
#
# Usernames are the person's email, the same name their IBMid login would give
# them. That way set_cluster_access_groups.sh works for both logins without
# changes: list the same email there and the person gets the same access.
#
# New accounts start with no rights. Access comes from set_cluster_access_groups.sh
# (or 'oc adm policy ...'), not from this script.
#
# If something else owns the cluster's login providers (a GitOps tool such as
# ArgoCD that puts back its own list), a provider added here is soon removed.
# Enable an HTPasswd provider there instead and set HTPASSWD_IDP_NAME to its
# name, e.g. in cpd_vars.sh. A provider that already exists is never changed:
# only the users in the secret it points at are, and users who already exist
# through another login are linked to it, so 'claim' doesn't refuse them.
#
# Logs in like the other scripts, with OC_LOGIN from cpd_vars.sh (skipped when
# oc is already logged in to OCP_URL). Passing --token or --username logs in
# with those instead, against --server, else OCP_URL, else the current server.
# With neither, the current oc session is used. Needs a cluster-admin
# (kubeadmin is fine; the users never see it).
#
# Safe to re-run: existing users keep their password and only new users get
# one. Passwords are printed once and saved to CREDENTIALS_FILE; the cluster
# only stores bcrypt hashes, so they cannot be read back from it. Use --reset
# to issue a new one.
#
#   set_htpasswd_users.sh --token sha256~... [--server https://api.<cluster>:6443]
#   set_htpasswd_users.sh -u kubeadmin [-p <password>] [--server ...]
#                                            log in with these instead of OC_LOGIN;
#                                            without -p, oc asks for the password
#   set_htpasswd_users.sh                    add missing users, keep the rest
#   set_htpasswd_users.sh --reset a@b.com    new password for that user (repeatable)
#   set_htpasswd_users.sh --reset-all        new password for everyone listed
#   set_htpasswd_users.sh --prune            also remove accounts this script made
#                                            (in CREDENTIALS_FILE) that are no longer listed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"

# --- Edit these ---------------------------------------------------------------
# Text on the login button. Changing it after users have logged in orphans their
# identities, so pick it once per cluster. Also settable from the environment;
# for a provider that already exists, the secret it uses is read from the cluster.
IDP_NAME="${HTPASSWD_IDP_NAME:-local-users}"
SECRET_NAME="${HTPASSWD_SECRET_NAME:-local-users-htpasswd}"

HTPASSWD_USERS=(
    # "user1@ibm.com"
    # "user2@example.com"
)
# ------------------------------------------------------------------------------

# configs/ is gitignored, so the plain-text passwords never get committed.
CREDENTIALS_FILE="${REPO_ROOT}/configs/openshift_config/htpasswd_credentials.txt"

PRUNE=false
RESET_ALL=false
RESET_USERS=()
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset)       RESET_USERS+=("${2:?--reset needs a username}"); shift 2 ;;
        --reset-all)   RESET_ALL=true; shift ;;
        --prune)       PRUNE=true; shift ;;
        --server)      LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)       LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username) LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password) LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)     sed -n '9,48p' "$0"; exit 0 ;;
        *)             echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done

for _tool in oc htpasswd openssl jq; do
    if ! command -v "${_tool}" &>/dev/null; then
        echo "[ERROR] '${_tool}' is not installed." >&2
        exit 1
    fi
done
unset _tool

# --- Log in ---------------------------------------------------------------------
ocu_login
echo "[INFO] Logged in as:   $(oc whoami)"
ocu_require_cluster_admin
ocu_warn_roks_oauth

for _u in "${HTPASSWD_USERS[@]}" "${RESET_USERS[@]}"; do
    if [[ "${_u}" == *:* || "${_u}" == *[[:space:]]* ]]; then
        echo "[ERROR] Invalid username '${_u}': no ':' or whitespace allowed." >&2
        exit 1
    fi
done
for _u in "${RESET_USERS[@]}"; do
    if (( ! ${HTPASSWD_USERS[(Ie)${_u}]} )); then
        echo "[ERROR] --reset '${_u}' is not in HTPASSWD_USERS." >&2
        exit 1
    fi
done
unset _u

# --- Current state ------------------------------------------------------------
# mappingMethod 'add' for a new provider: if an OpenShift user with this name
# already exists (e.g. from an IBMid login), the password login attaches to that
# same user instead of failing. The reverse only works if the IBM ID provider
# also uses 'add'; with its usual 'claim', someone who logs in here first cannot
# later use IBM ID.
htpw_read_idp add
htpw_read_lines

# user -> plain-text password, from earlier runs.
typeset -A SAVED_PASSWORDS
if [[ -f "${CREDENTIALS_FILE}" ]]; then
    while IFS= read -r _line; do
        [[ -z "${_line}" || "${_line}" == \#* ]] && continue
        SAVED_PASSWORDS[${_line%%:*}]="${_line#*:}"
    done < "${CREDENTIALS_FILE}"
    unset _line
fi

# --- Build the new htpasswd file -----------------------------------------------
typeset -A NEW_LINES
ISSUED=()
for _u in "${HTPASSWD_USERS[@]}"; do
    if [[ -n "${CURRENT_LINES[${_u}]:-}" && "${RESET_ALL}" != true ]] \
        && (( ! ${RESET_USERS[(Ie)${_u}]} )); then
        NEW_LINES[${_u}]="${CURRENT_LINES[${_u}]}"
        continue
    fi
    htpw_issue "${_u}"
done
unset _u

REMOVED=()
htpw_keep_others HTPASSWD_USERS "in HTPASSWD_USERS"

_tmp="$(mktemp)"
trap 'rm -f "${_tmp}"' EXIT
for _u in "${(@ko)NEW_LINES}"; do
    print -r -- "${NEW_LINES[${_u}]}" >> "${_tmp}"
done
unset _u

if [[ ! -s "${_tmp}" ]]; then
    echo "[ERROR] No users to write. Add at least one to HTPASSWD_USERS." >&2
    exit 1
fi

htpw_apply_secret "${_tmp}"

# Save before touching OAuth, so a failure below never loses issued passwords.
mkdir -p "$(dirname "${CREDENTIALS_FILE}")"
{
    echo "# username:password for the '${IDP_NAME}' login on $(oc whoami --show-server)"
    for _u in "${(@ko)SAVED_PASSWORDS}"; do
        print -r -- "${_u}:${SAVED_PASSWORDS[${_u}]}"
    done
} > "${CREDENTIALS_FILE}"
chmod 600 "${CREDENTIALS_FILE}"
unset _u

# --- Identity provider ----------------------------------------------------------
htpw_add_idp

# --- Remove pruned accounts -----------------------------------------------------
htpw_remove_users

# --- Link existing users --------------------------------------------------------
# With mappingMethod 'claim' a first login is refused when an OpenShift user of
# that name already exists through another login (an IBMid login, or an older
# password provider), so those users are linked here, as 'add' does at login.
if [[ "${IDP_MAPPING}" == claim ]]; then
    _linked=0
    for _u in "${(@ko)NEW_LINES}"; do
        _id="${IDP_NAME}:${_u}"
        oc get user "${_u}" &>/dev/null || continue
        [[ "$(oc get identity "${_id}" -o jsonpath='{.user.name}' 2>/dev/null)" == "${_u}" ]] && continue
        oc get identity "${_id}" &>/dev/null || oc create identity "${_id}" >/dev/null
        if oc create useridentitymapping "${_id}" "${_u}" >/dev/null; then
            (( ++_linked ))
        else
            echo "[WARN] Could not link '${_u}' to the '${IDP_NAME}' login; their first login may be refused."
        fi
    done
    (( _linked > 0 )) && echo "[INFO] Linked ${_linked} existing user(s) to the '${IDP_NAME}' login."
    unset _u _id _linked
fi

# --- Wait for the login pods to pick it up -------------------------------------
htpw_wait_auth_rollout

# --- Summary --------------------------------------------------------------------
echo "[INFO] ---"
echo "[INFO] Console: $(oc whoami --show-console 2>/dev/null || echo unknown)"
echo "[INFO] Users pick '${IDP_NAME}' on the login page."
if (( ${#ISSUED} > 0 )); then
    echo "[INFO] New passwords (also in ${CREDENTIALS_FILE}):"
    for _u in "${ISSUED[@]}"; do
        printf '         %-40s %s\n' "${_u}" "${SAVED_PASSWORDS[${_u}]}"
    done
else
    echo "[INFO] No new passwords issued. Existing ones are in ${CREDENTIALS_FILE}."
fi
echo "[INFO] Grant access with set_cluster_access_groups.sh (same usernames)."
