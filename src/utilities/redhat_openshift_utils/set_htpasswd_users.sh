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
# Users come from HTPASSWD_USERS below plus any given with -u (comma-separated,
# repeatable). Each new user gets a generated password: 12 characters when -u
# is used, else 16; --password-length overrides both.
#
# Safe to re-run: existing users keep their password and only new users get
# one. Passwords are printed once and saved to the credentials file; the cluster
# only stores bcrypt hashes, so they cannot be read back from it. Use --reset
# to issue a new one.
#
#   set_htpasswd_users.sh                    add missing users, keep the rest
#   set_htpasswd_users.sh -u a@b.com,c@d.com add these users too (comma-separated,
#                                            repeatable), 12-character passwords
#   set_htpasswd_users.sh --reset a@b.com    new password for that user (repeatable)
#   set_htpasswd_users.sh --reset-all        new password for everyone listed
#   set_htpasswd_users.sh --prune            also remove accounts this script made
#                                            (in the credentials file) that are no longer listed
#
# Settings (defaults in brackets; each keeps today's behaviour unless given):
#   -s, --secret-name <name>       htpasswd secret in openshift-config
#                                  [$HTPASSWD_SECRET_NAME, else local-users-htpasswd]
#   -i, --idp-name <name>          login provider / button text
#                                  [$HTPASSWD_IDP_NAME, else local-users]
#   -m, --mapping-method <m>       add|claim|lookup|generate, for a NEW provider only;
#                                  an existing one keeps its own [add]
#   -c, --credentials-file <path>  where plain-text passwords are kept
#                                  [configs/openshift_config/htpasswd_credentials.txt]
#   -l, --password-length <n>      generated password length, 8-128 [12 with -u, else 16]
#       --bcrypt-cost <n>          bcrypt cost for the hashes, 4-17 [10]
#       --rollout-timeout <sec>    how long to wait for the login pods [300]
#       --no-wait                  don't wait for the login pods to roll out
#       --no-print-passwords       keep new passwords out of the output; they are
#                                  only in the credentials file
#       --secret-only              only write the htpasswd secret and the credentials
#                                  file: no OAuth change, no identity linking or
#                                  deletion, no rollout wait. Add the provider later
#                                  by re-running without it.
#       --idp-only                 only add the login provider to OAuth, pointing at
#                                  the existing secret (made by --secret-only or an
#                                  earlier run); links existing users, waits for
#                                  the rollout. Secret and credentials file untouched.
#       --remove-idp               only remove the login provider from OAuth and wait
#                                  for the rollout. Secret, credentials file, users
#                                  and identities are kept, so --idp-only (or a
#                                  normal run) brings the same logins back.
#   --secret-only, --idp-only and --remove-idp can't be combined, and --idp-only /
#   --remove-idp take no -u, --reset, --reset-all or --prune.
#
# Cluster login (instead of OC_LOGIN):
#   --token sha256~... [--server https://api.<cluster>:6443]
#   --username kubeadmin [-p <password>] [--server ...]
#                                  without -p, oc asks for the password
#                                  (-u is the user list, not the login name)

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
CREDENTIALS_FILE="${CONFIGS_ROOT:-${REPO_ROOT}/configs}/openshift_config/htpasswd_credentials.txt"

# mappingMethod for a provider this script creates (see "Current state" below).
MAPPING_METHOD="add"

PRUNE=false
RESET_ALL=false
RESET_USERS=()
CLI_USERS=()
PASSWORD_LENGTH=""
BCRYPT_COST=10
ROLLOUT_TIMEOUT=300
WAIT_ROLLOUT=true
PRINT_PASSWORDS=true
SECRET_ONLY=false
IDP_ONLY=false
REMOVE_IDP=false
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--users)
            # Comma-separated, whitespace ignored (not allowed in names), repeatable.
            for _u in "${(@s:,:)${2:?--users needs a comma-separated list of usernames}}"; do
                _u="${_u//[[:space:]]/}"
                [[ -n "${_u}" ]] && CLI_USERS+=("${_u}")
            done
            unset _u
            shift 2 ;;
        -s|--secret-name)      SECRET_NAME="${2:?--secret-name needs a name}"; shift 2 ;;
        -i|--idp-name)         IDP_NAME="${2:?--idp-name needs a name}"; shift 2 ;;
        -m|--mapping-method)   MAPPING_METHOD="${2:?--mapping-method needs add|claim|lookup|generate}"; shift 2 ;;
        -c|--credentials-file) CREDENTIALS_FILE="${2:?--credentials-file needs a path}"; shift 2 ;;
        -l|--password-length)  PASSWORD_LENGTH="${2:?--password-length needs a number}"; shift 2 ;;
        --bcrypt-cost)         BCRYPT_COST="${2:?--bcrypt-cost needs a number}"; shift 2 ;;
        --rollout-timeout)     ROLLOUT_TIMEOUT="${2:?--rollout-timeout needs seconds}"; shift 2 ;;
        --no-wait)             WAIT_ROLLOUT=false; shift ;;
        --no-print-passwords)  PRINT_PASSWORDS=false; shift ;;
        --secret-only)         SECRET_ONLY=true; shift ;;
        --idp-only)            IDP_ONLY=true; shift ;;
        --remove-idp)          REMOVE_IDP=true; shift ;;
        --reset)       RESET_USERS+=("${2:?--reset needs a username}"); shift 2 ;;
        --reset-all)   RESET_ALL=true; shift ;;
        --prune)       PRUNE=true; shift ;;
        --server)      LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)       LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        --username)    LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password) LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        # The comment header from line 9 up to the first non-comment line.
        -h|--help)     awk 'NR >= 9 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *)             echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done

# -u used to be the login username; catch old 'set_htpasswd_users.sh -u kubeadmin'.
if (( ${CLI_USERS[(Ie)kubeadmin]} )); then
    echo "[ERROR] -u is now the list of htpasswd users. To log in as kubeadmin use --username kubeadmin." >&2
    exit 1
fi

_modes=0
for _m in SECRET_ONLY IDP_ONLY REMOVE_IDP; do [[ "${(P)_m}" == true ]] && (( ++_modes )); done
if (( _modes > 1 )); then
    echo "[ERROR] Use only one of --secret-only, --idp-only, --remove-idp." >&2; exit 1
fi
unset _m _modes
if [[ "${IDP_ONLY}" == true || "${REMOVE_IDP}" == true ]] \
    && { (( ${#CLI_USERS} + ${#RESET_USERS} > 0 )) || [[ "${PRUNE}" == true || "${RESET_ALL}" == true ]]; }; then
    echo "[ERROR] --idp-only and --remove-idp don't change users; drop -u, --reset, --reset-all and --prune." >&2
    exit 1
fi
HTPASSWD_USERS+=("${CLI_USERS[@]}")
HTPASSWD_USERS=("${(@u)HTPASSWD_USERS}")

[[ -n "${PASSWORD_LENGTH}" ]] || { (( ${#CLI_USERS} > 0 )) && PASSWORD_LENGTH=12 || PASSWORD_LENGTH=16; }
_bad_num() { [[ "$1" != <-> ]] || (( $1 < $2 || $1 > $3 )); }
if _bad_num "${PASSWORD_LENGTH}" 8 128; then
    echo "[ERROR] --password-length must be a number from 8 to 128." >&2; exit 1
fi
if _bad_num "${BCRYPT_COST}" 4 17; then
    echo "[ERROR] --bcrypt-cost must be a number from 4 to 17." >&2; exit 1
fi
if _bad_num "${ROLLOUT_TIMEOUT}" 1 86400; then
    echo "[ERROR] --rollout-timeout must be a number of seconds (1-86400)." >&2; exit 1
fi
unfunction _bad_num
case "${MAPPING_METHOD}" in
    add|claim|lookup|generate) ;;
    *) echo "[ERROR] --mapping-method must be add, claim, lookup or generate." >&2; exit 1 ;;
esac
if [[ -z "${SECRET_NAME}" || -z "${IDP_NAME}" ]]; then
    echo "[ERROR] --secret-name and --idp-name can't be empty." >&2; exit 1
fi
# Read by htpw_issue / htpw_wait_auth_rollout in ocp_utils_helpers.sh.
HTPW_PASSWORD_LENGTH="${PASSWORD_LENGTH}"
HTPW_BCRYPT_COST="${BCRYPT_COST}"
HTPW_ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT}"

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
        echo "[ERROR] --reset '${_u}' is not in HTPASSWD_USERS or -u." >&2
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
htpw_read_idp "${MAPPING_METHOD}"
htpw_read_lines

# --- Link existing users (function) -------------------------------------------
link_existing_users() {
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
}

wait_for_rollout() {
    if [[ "${WAIT_ROLLOUT}" == true ]]; then
        htpw_wait_auth_rollout
    else
        echo "[INFO] Not waiting for the rollout (--no-wait). Check with: oc get co authentication"
    fi
}

# --- --remove-idp: take the provider out of OAuth, nothing else ----------------
if [[ "${REMOVE_IDP}" == true ]]; then
    if [[ "${IDP_EXISTS}" != true ]]; then
        echo "[INFO] No identity provider '${IDP_NAME}' in OAuth; nothing to remove."
        exit 0
    fi
    _idx="$(jq --arg n "${IDP_NAME}" '.spec.identityProviders | map(.name) | index($n)' <<< "${OAUTH_JSON}")"
    _left="$(jq --arg n "${IDP_NAME}" '[.spec.identityProviders[] | select(.name != $n)] | length' <<< "${OAUTH_JSON}")"
    (( _left == 0 )) && echo "[WARN] '${IDP_NAME}' is the only provider; afterwards only kubeadmin / tokens can log in."
    # 'test' first, so a concurrent change to the list can't make us drop the wrong entry.
    oc patch oauth cluster --type=json -p "[
        {\"op\":\"test\",\"path\":\"/spec/identityProviders/${_idx}/name\",\"value\":$(jq -Rn --arg n "${IDP_NAME}" '$n')},
        {\"op\":\"remove\",\"path\":\"/spec/identityProviders/${_idx}\"}]" >/dev/null
    echo "[INFO] Removed identity provider '${IDP_NAME}'. Kept: secret openshift-config/${SECRET_NAME},"
    echo "       ${CREDENTIALS_FILE}, and its users/identities (re-add with --idp-only)."
    if [[ -n "$(jq -r '.metadata.annotations["argocd.argoproj.io/tracking-id"] // empty' <<< "${OAUTH_JSON}")" ]]; then
        echo "[WARN] ArgoCD manages the OAuth config and may put '${IDP_NAME}' back."
    fi
    unset _idx _left
    wait_for_rollout
    exit 0
fi

# --- --idp-only: add the provider for the users already in the secret ----------
if [[ "${IDP_ONLY}" == true ]]; then
    if (( ${#CURRENT_LINES} == 0 )); then
        echo "[ERROR] Secret openshift-config/${SECRET_NAME} is missing or empty. Create it first" >&2
        echo "        (--secret-only, or a normal run)." >&2
        exit 1
    fi
    typeset -A NEW_LINES
    NEW_LINES=("${(@kv)CURRENT_LINES}")
    htpw_add_idp
    link_existing_users
    wait_for_rollout
    echo "[INFO] ---"
    echo "[INFO] Console: $(oc whoami --show-console 2>/dev/null || echo unknown)"
    echo "[INFO] Users pick '${IDP_NAME}' on the login page (${#NEW_LINES} account(s) in ${SECRET_NAME})."
    echo "[INFO] Passwords are in ${CREDENTIALS_FILE}."
    exit 0
fi

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
htpw_keep_others HTPASSWD_USERS "in HTPASSWD_USERS or -u"

_tmp="$(mktemp)"
trap 'rm -f "${_tmp}"' EXIT
for _u in "${(@ko)NEW_LINES}"; do
    print -r -- "${NEW_LINES[${_u}]}" >> "${_tmp}"
done
unset _u

if [[ ! -s "${_tmp}" ]]; then
    echo "[ERROR] No users to write. Add at least one to HTPASSWD_USERS or pass -u." >&2
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

if [[ "${SECRET_ONLY}" == true ]]; then
    echo "[INFO] --secret-only: secret openshift-config/${SECRET_NAME} and ${CREDENTIALS_FILE} written."
    if [[ "${IDP_EXISTS}" == true ]]; then
        echo "[WARN] Provider '${IDP_NAME}' already uses this secret, so the authentication operator"
        echo "       rolls the login pods out on its own to pick up the change."
    else
        echo "[INFO] OAuth not changed: no '${IDP_NAME}' login yet. Re-run without --secret-only to add it."
    fi
    (( ${#REMOVED} > 0 )) && echo "[INFO] Pruned from the secret (their OpenShift users/identities kept): ${REMOVED[*]}"
    (( ${#ISSUED} > 0 )) && [[ "${PRINT_PASSWORDS}" == true ]] && {
        echo "[INFO] New passwords (also in ${CREDENTIALS_FILE}):"
        for _u in "${ISSUED[@]}"; do
            printf '         %-40s %s\n' "${_u}" "${SAVED_PASSWORDS[${_u}]}"
        done
    }
    exit 0
fi

# --- Identity provider ----------------------------------------------------------
htpw_add_idp

# --- Remove pruned accounts -----------------------------------------------------
htpw_remove_users

# --- Link existing users --------------------------------------------------------
link_existing_users

# --- Wait for the login pods to pick it up -------------------------------------
wait_for_rollout

# --- Summary --------------------------------------------------------------------
echo "[INFO] ---"
echo "[INFO] Console: $(oc whoami --show-console 2>/dev/null || echo unknown)"
echo "[INFO] Users pick '${IDP_NAME}' on the login page."
if (( ${#ISSUED} > 0 )) && [[ "${PRINT_PASSWORDS}" != true ]]; then
    echo "[INFO] ${#ISSUED} new password(s) saved to ${CREDENTIALS_FILE}."
elif (( ${#ISSUED} > 0 )); then
    echo "[INFO] New passwords (also in ${CREDENTIALS_FILE}):"
    for _u in "${ISSUED[@]}"; do
        printf '         %-40s %s\n' "${_u}" "${SAVED_PASSWORDS[${_u}]}"
    done
else
    echo "[INFO] No new passwords issued. Existing ones are in ${CREDENTIALS_FILE}."
fi
echo "[INFO] Grant access with set_cluster_access_groups.sh (same usernames)."
