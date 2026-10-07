#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Adds username/password accounts for service IDs (non-human users that apps,
# pipelines or agents act as) through their own HTPasswd identity provider that
# is NOT shown on the login page, and adds them to IBM Software Hub so they can
# sign in there and generate an API key like any other user.
# set_htpasswd_users.sh is the visible counterpart for people.
#
# Hidden, not disabled. OpenShift has no "hidden" flag for identity providers,
# so the login page is swapped for a copy of the cluster's own page that skips
# this provider. Logging in still works:
#   CLI      oc login -u <user> -p <password>   (checked against every password
#            provider, shown or not)
#   Browser  on the "Log in with" page, add &idp=<IDP_NAME> to the address and
#            press Enter. Works for the OpenShift console and for Software Hub's
#            "OpenShift authentication".
# The copy is taken fresh on every run; re-run after an OpenShift upgrade so the
# page picks up the new look.
#
# Adds to the cluster's login setup, never replaces it: other identity providers
# are left untouched and this one is appended. If an HTPasswd provider of this
# name already exists, its settings (secret, mappingMethod, ...) are kept as they
# are and the users are merged into the secret it already uses: accounts already
# in it keep their password, and ones not listed here stay unless --prune is
# given. If a custom login page is already in place, the filter is added to that
# page instead of replacing it. If the page then breaks or still shows the
# provider, the page change and a provider added in this run are rolled back.
#
# A new provider gets mappingMethod 'claim': a service ID never attaches to a
# person's account, so a name another login already uses is refused. Use names
# like 'svc-<app>'.
#
# Software Hub must use IAM with OpenShift authentication (ROKS_ENABLED in the
# platform-auth-idp configmap). Its URL and the cpadmin login are read from this
# cluster. New users get SOFTWAREHUB_ROLES; after that their roles are managed
# in Software Hub and left alone here.
#
# Software Hub's /icp4d-api/v1/authorize (username/password -> bearer token, used
# by generate_service_id_cpd_apikeys.sh) only checks a password against OpenShift
# when the username starts with IAM's roksUserPrefix ("IAM#" by default). With
# CLEAR_ROKS_USER_PREFIX the prefix is set to empty on the IAM Authentication CR,
# as IBM's docs describe, so plain names like these work. That applies to every
# OpenShift user and restarts the IAM pods (sign-in is down for a few minutes).
#
# Users are the names in SERVICE_ID_USERS, or the names given on the command
# line instead. With no names at all, GENERATED_USER_COUNT users are generated
# from GENERATED_USER_TEMPLATE, '{id}' becoming 6 random digits:
# cpd_service_id_481902, ... Generated users already in the cluster count
# toward that number, so a re-run only adds the missing ones.
# --count generates users alongside listed names too.
#
# Logs in like the other scripts, with OC_LOGIN from cpd_vars.sh (skipped when
# oc is already logged in to OCP_URL). Passing --token or --username logs in
# with those instead, against --server, else OCP_URL, else the current server.
# With neither, the current oc session is used. Needs a cluster-admin.
#
# Safe to re-run: existing users keep their password and only new users get
# one. Passwords are printed once and saved to CREDENTIALS_FILE; the cluster
# only stores bcrypt hashes, so they cannot be read back from it. A user whose
# password is missing from that file, or doesn't match the cluster, gets a new
# one. Use --reset to issue a new one anyway.
#
#   set_service_id_user_proxies.sh --token sha256~... [--server https://api.<cluster>:6443]
#   set_service_id_user_proxies.sh -u kubeadmin [-p <password>] [--server ...]
#                                                     log in with these instead of OC_LOGIN;
#                                                     without -p, oc asks for the password
#   set_service_id_user_proxies.sh                    SERVICE_ID_USERS, or 3 generated users if empty
#   set_service_id_user_proxies.sh svc-a svc-b        these users instead of SERVICE_ID_USERS
#   set_service_id_user_proxies.sh --count 5          generate users until there are 5
#   set_service_id_user_proxies.sh --template 'wxo_svc_{id}'
#                                                     name generated users like this
#   set_service_id_user_proxies.sh --reset svc-a      new password for that user (repeatable)
#   set_service_id_user_proxies.sh --reset-all        new password for everyone listed
#   set_service_id_user_proxies.sh --prune            also remove accounts no longer listed,
#                                                     from OpenShift and Software Hub

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b

# --- Edit these ---------------------------------------------------------------
# Changing IDP_NAME after users have logged in orphans their identities, so pick
# it once per cluster. Letters, digits, '.', '_' and '-' only. Secret names
# can't contain '_', hence the dashes below.
IDP_NAME="service_id_user_proxies"
SECRET_NAME="service-id-user-proxies-htpasswd"
# Holds the login page copy, unless the cluster already has its own custom page.
LOGIN_PAGE_SECRET="login-provider-selection"

# Leave empty to generate users instead (see below).
SERVICE_ID_USERS=(
    # "svc-wxo-agent"
    # "svc-etl-pipeline"
)

# Generated users, made when no names are given here or on the command line, or
# when --count is passed. '{id}' (exactly once) becomes 6 random digits.
# Also settable from the environment, or with --count / --template.
GENERATED_USER_COUNT="${GENERATED_USER_COUNT:-3}"
# (The inner quotes matter: zsh would otherwise end the ${...} at the '}' of '{id}'.)
GENERATED_USER_TEMPLATE="${GENERATED_USER_TEMPLATE:-"cpd_service_id_{id}"}"

REGISTER_IN_SOFTWAREHUB=true
# Roles for users added to Software Hub. zen_user_role ("User") is enough to
# sign in and generate an API key; add service-specific roles as needed.
SOFTWAREHUB_ROLES=(zen_user_role)
# Namespace of the Software Hub instance. Empty finds it when there is just one.
SOFTWAREHUB_NAMESPACE=""
# Clear IAM's roksUserPrefix so service IDs can get a bearer token (and so an API
# key) with their username/password. See the note at the top.
CLEAR_ROKS_USER_PREFIX=true
# ------------------------------------------------------------------------------

# configs/ is gitignored, so the plain-text passwords never get committed.
CREDENTIALS_FILE="${REPO_ROOT}/configs/openshift_config/service_id_credentials.txt"

PRUNE=false
RESET_ALL=false
RESET_USERS=()
GENERATE=false
CLI_USERS=()
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --count)       GENERATED_USER_COUNT="${2:?--count needs a number}"; GENERATE=true; shift 2 ;;
        --template)    GENERATED_USER_TEMPLATE="${2:?--template needs a name template}"; shift 2 ;;
        --reset)       RESET_USERS+=("${2:?--reset needs a username}"); shift 2 ;;
        --reset-all)   RESET_ALL=true; shift ;;
        --prune)       PRUNE=true; shift ;;
        --server)      LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)       LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username) LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password) LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)     sed -n '9,81p' "$0"; exit 0 ;;
        -*)            echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
        *)             CLI_USERS+=("$1"); shift ;;
    esac
done

# Names on the command line replace SERVICE_ID_USERS for this run. With no
# names at all, users are generated.
(( ${#CLI_USERS} > 0 )) && SERVICE_ID_USERS=("${CLI_USERS[@]}")
(( ${#SERVICE_ID_USERS} == 0 )) && GENERATE=true

for _tool in oc htpasswd openssl jq curl python3; do
    if ! command -v "${_tool}" &>/dev/null; then
        echo "[ERROR] '${_tool}' is not installed." >&2
        exit 1
    fi
done
unset _tool

# --- Log in ---------------------------------------------------------------------
# Credentials on the command line win. Otherwise OC_LOGIN from cpd_vars.sh, which
# skips the login when oc is already logged in to OCP_URL. Without either, the
# current oc session is used as is.
if [[ -n "${LOGIN_TOKEN}" && -n "${LOGIN_USERNAME}" ]]; then
    echo "[ERROR] Pass either --token or --username, not both." >&2
    exit 1
elif [[ -z "${LOGIN_TOKEN}${LOGIN_USERNAME}" && -n "${LOGIN_SERVER}${LOGIN_PASSWORD}" ]]; then
    echo "[ERROR] --server and --password need --token or --username." >&2
    exit 1
fi
if [[ -n "${LOGIN_TOKEN}${LOGIN_USERNAME}" ]]; then
    _login=(oc login)
    _server="${LOGIN_SERVER:-${OCP_URL:-}}"
    [[ -n "${_server}" ]] && _login+=(--server="${_server}")
    if [[ -n "${LOGIN_TOKEN}" ]]; then
        _login+=(--token="${LOGIN_TOKEN}")
    else
        _login+=(--username="${LOGIN_USERNAME}")
        # Without --password, oc asks for it.
        [[ -n "${LOGIN_PASSWORD}" ]] && _login+=(--password="${LOGIN_PASSWORD}")
    fi
    "${_login[@]}"
    unset _login _server
elif [[ -n "${OC_LOGIN:-}" ]]; then
    eval "${OC_LOGIN}"
elif ! oc whoami &>/dev/null; then
    echo "[ERROR] Not logged in. Set OC_LOGIN in cpd_vars.sh, or pass --token or --username." >&2
    exit 1
fi

echo "[INFO] Target cluster: $(oc whoami --show-server)"
echo "[INFO] Logged in as:   $(oc whoami)"

if [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" != "yes" ]]; then
    echo "[ERROR] The current user is not a cluster-admin." >&2
    exit 1
fi

# ROKS (Red Hat OpenShift on IBM Cloud) manages its own OAuth config and may
# undo or reject extra identity providers. TechZone's VMware clusters are fine.
_platform="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || true)"
if [[ "${_platform}" == "IBMCloud" ]]; then
    echo "[WARN] Platform is IBMCloud (ROKS). Extra identity providers may not stick here."
fi
unset _platform

_name_re='^[A-Za-z0-9._-]+$'
if [[ ! "${IDP_NAME}" =~ ${_name_re} ]]; then
    echo "[ERROR] Invalid IDP_NAME '${IDP_NAME}': letters, digits, '.', '_' and '-' only." >&2
    exit 1
fi
unset _name_re
for _u in "${SERVICE_ID_USERS[@]}" "${RESET_USERS[@]}"; do
    if [[ "${_u}" == *:* || "${_u}" == *[[:space:]]* ]]; then
        echo "[ERROR] Invalid username '${_u}': no ':' or whitespace allowed." >&2
        exit 1
    fi
done
unset _u
if [[ "${GENERATE}" == true ]]; then
    if [[ -z "${GENERATED_USER_COUNT}" || "${GENERATED_USER_COUNT}" == *[^0-9]* ]]; then
        echo "[ERROR] Invalid count '${GENERATED_USER_COUNT}': a whole number is needed." >&2
        exit 1
    fi
    if [[ "${GENERATED_USER_TEMPLATE}" != *"{id}"* || "${GENERATED_USER_TEMPLATE/\{id\}/}" == *[{}]* \
        || "${GENERATED_USER_TEMPLATE}" == *:* || "${GENERATED_USER_TEMPLATE}" == *[[:space:]]* ]]; then
        echo "[ERROR] Invalid template '${GENERATED_USER_TEMPLATE}': needs '{id}' exactly once, no other braces, ':' or whitespace." >&2
        exit 1
    fi
fi

uri() { jq -rn --arg s "$1" '$s | @uri'; }

# --- Current state ------------------------------------------------------------
OAUTH_JSON="$(oc get oauth cluster -o json)"

IDP_EXISTS=false
IDP_MAPPING="claim"
_idp="$(jq -c --arg n "${IDP_NAME}" \
    '.spec.identityProviders // [] | map(select(.name == $n)) | first // empty' <<< "${OAUTH_JSON}")"
if [[ -n "${_idp}" ]]; then
    IDP_EXISTS=true
    if [[ "$(jq -r '.type' <<< "${_idp}")" != HTPasswd ]]; then
        echo "[ERROR] Identity provider '${IDP_NAME}' exists but is not of type HTPasswd." >&2
        exit 1
    fi
    # Its settings are kept. Use the secret it already points at, so the users in
    # it are merged with this run's users rather than replaced.
    IDP_MAPPING="$(jq -r '.mappingMethod // "claim"' <<< "${_idp}")"
    _secret="$(jq -r '.htpasswd.fileData.name' <<< "${_idp}")"
    if [[ "${_secret}" != "${SECRET_NAME}" ]]; then
        echo "[INFO] '${IDP_NAME}' already uses secret '${_secret}', updating that one."
        SECRET_NAME="${_secret}"
    fi
fi
unset _idp _secret

# user -> htpasswd line, as stored in the cluster today.
typeset -A CURRENT_LINES
if oc get secret "${SECRET_NAME}" -n openshift-config &>/dev/null; then
    for _line in ${(f)"$(oc get secret "${SECRET_NAME}" -n openshift-config \
                            -o jsonpath='{.data.htpasswd}' | base64 -d)"}; do
        [[ -z "${_line}" ]] && continue
        CURRENT_LINES[${_line%%:*}]="${_line}"
    done
    unset _line
fi

# user -> plain-text password, from earlier runs. Lines under a user (the API
# key written by generate_service_id_cpd_apikeys.sh and its comment) are kept
# with that user in SAVED_EXTRAS, and that script's Software Hub URL line at the
# top in SAVED_URL_LINE.
typeset -A SAVED_PASSWORDS SAVED_EXTRAS
SAVED_URL_LINE=""
if [[ -f "${CREDENTIALS_FILE}" ]]; then
    _cur=""
    while IFS= read -r _line; do
        [[ -z "${_line//[[:space:]]/}" ]] && continue
        if [[ -z "${_cur}" && "${_line}" == "# Software Hub API keys below are for "* ]]; then
            SAVED_URL_LINE="${_line}"
            continue
        fi
        if [[ "${_line}" == \#* || "${_line}" == apikey=* ]]; then
            [[ -n "${_cur}" ]] && SAVED_EXTRAS[${_cur}]+="${_line}"$'\n'
            continue
        fi
        _cur="${_line%%:*}"
        SAVED_PASSWORDS[${_cur}]="${_line#*:}"
    done < "${CREDENTIALS_FILE}"
    unset _line _cur
fi

# --- Generated users ------------------------------------------------------------
# Users in the cluster that fit the template count toward GENERATED_USER_COUNT
# and are kept, so re-runs only top up. More than the count are never removed.
if [[ "${GENERATE}" == true ]]; then
    _prefix="${GENERATED_USER_TEMPLATE%%\{id\}*}"
    _suffix="${GENERATED_USER_TEMPLATE#*\{id\}}"
    _generated=()
    for _u in "${(@ko)CURRENT_LINES}"; do
        (( ${SERVICE_ID_USERS[(Ie)${_u}]} )) && continue
        [[ "${_u}" == "${_prefix}"*"${_suffix}" ]] || continue
        _id="${${_u#"${_prefix}"}%"${_suffix}"}"
        if [[ ${#_id} -eq 6 && "${_id}" != *[^0-9]* ]]; then
            _generated+=("${_u}")
        fi
    done
    _existing=${#_generated}
    while (( ${#_generated} < GENERATED_USER_COUNT )); do
        # 4 random bytes as a number, cut to 6 digits with leading zeros kept.
        _u="${_prefix}$(printf '%06d' $(( 0x$(openssl rand -hex 4) % 1000000 )))${_suffix}"
        if [[ -z "${CURRENT_LINES[${_u}]:-}" ]] && (( ! ${_generated[(Ie)${_u}]} )) \
            && (( ! ${SERVICE_ID_USERS[(Ie)${_u}]} )); then
            _generated+=("${_u}")
        fi
    done
    echo "[INFO] Generated users (${GENERATED_USER_TEMPLATE}): ${_existing} already there, $(( ${#_generated} - _existing )) new."
    SERVICE_ID_USERS+=("${_generated[@]}")
    unset _prefix _suffix _generated _existing _u _id
fi

for _u in "${RESET_USERS[@]}"; do
    if (( ! ${SERVICE_ID_USERS[(Ie)${_u}]} )); then
        echo "[ERROR] --reset '${_u}' is not one of this run's users." >&2
        exit 1
    fi
done
unset _u

# 'claim' refuses a first login whose user name belongs to another login (e.g. a
# person's IBMid), so catch that before anything is changed. Users who already
# log in through this provider are fine.
if [[ "${IDP_MAPPING}" == claim ]]; then
    _taken=(${(f)"$(oc get users -o json | jq -r --arg p "${IDP_NAME}:" '
        .items[] | select(.metadata.name | IN($ARGS.positional[]))
        | select(.identities // [] | length > 0 and (any(startswith($p)) | not))
        | .metadata.name' \
        --args "${SERVICE_ID_USERS[@]}")"})
    if (( ${#_taken} > 0 )); then
        echo "[ERROR] Already used by another login, pick other names: ${_taken[*]}" >&2
        exit 1
    fi
    unset _taken
fi

# --- Build the new htpasswd file -----------------------------------------------
# Nothing on the cluster changes until both the users and the login page are ready.
new_password() {
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16
}

typeset -A NEW_LINES
ISSUED=()
for _u in "${SERVICE_ID_USERS[@]}"; do
    if [[ -n "${CURRENT_LINES[${_u}]:-}" && "${RESET_ALL}" != true ]] \
        && (( ! ${RESET_USERS[(Ie)${_u}]} )); then
        # The cluster only has the hash, so a password missing from the file
        # (file deleted, or the user made elsewhere) or not matching the hash
        # can only be replaced.
        if [[ -z "${SAVED_PASSWORDS[${_u}]:-}" ]]; then
            echo "[WARN] '${_u}' has no saved password in ${CREDENTIALS_FILE}; issuing a new one."
        elif ! htpasswd -vb =(print -r -- "${CURRENT_LINES[${_u}]}") "${_u}" "${SAVED_PASSWORDS[${_u}]}" &>/dev/null; then
            echo "[WARN] The saved password for '${_u}' does not match the cluster; issuing a new one."
        else
            NEW_LINES[${_u}]="${CURRENT_LINES[${_u}]}"
            continue
        fi
    fi
    _pw="$(new_password)"
    NEW_LINES[${_u}]="$(htpasswd -nbB -C 10 "${_u}" "${_pw}" | head -n 1)"
    SAVED_PASSWORDS[${_u}]="${_pw}"
    ISSUED+=("${_u}")
done
unset _u _pw

REMOVED=()
for _u in "${(@k)CURRENT_LINES}"; do
    (( ${SERVICE_ID_USERS[(Ie)${_u}]} )) && continue
    if [[ "${PRUNE}" == true ]]; then
        REMOVED+=("${_u}")
        unset "SAVED_PASSWORDS[${_u}]" "SAVED_EXTRAS[${_u}]"
    else
        echo "[WARN] '${_u}' is in the cluster but not among this run's users; kept. Use --prune to remove."
        NEW_LINES[${_u}]="${CURRENT_LINES[${_u}]}"
    fi
done
unset _u

_tmpdir="$(mktemp -d)"
trap 'rm -rf "${_tmpdir}"' EXIT
for _u in "${(@ko)NEW_LINES}"; do
    print -r -- "${NEW_LINES[${_u}]}" >> "${_tmpdir}/htpasswd"
done
unset _u

if [[ ! -s "${_tmpdir}/htpasswd" ]]; then
    echo "[ERROR] No users to write. List some in SERVICE_ID_USERS or on the command line, or use a --count above 0." >&2
    exit 1
fi

# --- Build the login page -------------------------------------------------------
_page_ref="$(jq -r '.spec.templates.providerSelection.name // ""' <<< "${OAUTH_JSON}")"
_page_secret="${_page_ref:-${LOGIN_PAGE_SECRET}}"
oc get secret "${_page_secret}" -n openshift-config -o jsonpath='{.data.providers\.html}' 2>/dev/null \
    | base64 -d > "${_tmpdir}/page.old.html" || true

if [[ -z "${_page_ref}" || "${_page_ref}" == "${LOGIN_PAGE_SECRET}" ]]; then
    # The page OpenShift shows by default, kept current by the authentication operator.
    oc get secret v4-0-config-system-ocp-branding-template -n openshift-authentication \
        -o jsonpath='{.data.providers\.html}' 2>/dev/null | base64 -d > "${_tmpdir}/page.src.html" || true
    if [[ ! -s "${_tmpdir}/page.src.html" ]]; then
        echo "[WARN] Default login page not found, starting from OpenShift's plain one."
        oc adm create-provider-selection-template > "${_tmpdir}/page.src.html"
    fi
else
    echo "[INFO] The cluster already uses custom login page '${_page_ref}', adding the filter to it."
    cp "${_tmpdir}/page.old.html" "${_tmpdir}/page.src.html"
fi

# Puts '{{ if eq $provider.Name "<IDP_NAME>" }}{{ continue }}{{ end }}' at the top
# of each loop over .Providers ({{ continue }} needs OpenShift 4.11 or later).
# Prints: <loops found> <filters added>.
_result="$(python3 - "${IDP_NAME}" "${_tmpdir}/page.src.html" "${_tmpdir}/page.new.html" <<'PY'
import re, sys

idp, src, dst = sys.argv[1:]
with open(src, encoding="utf-8", newline="") as f:
    html = f.read()

loop = re.compile(r"\{\{-?\s*range\s+(?:(?:\$\w+\s*,\s*)?(\$\w+)\s*:=\s*)?\.Providers\s*-?\}\}")
found = added = 0

def add_filter(m):
    global found, added
    found += 1
    skip = '{{ if eq %s.Name "%s" }}{{ continue }}{{ end }}' % (m.group(1) or "", idp)
    if html.startswith(skip, m.end()):
        return m.group(0)
    added += 1
    return m.group(0) + skip

with open(dst, "w", encoding="utf-8", newline="") as f:
    f.write(loop.sub(add_filter, html))
print(found, added)
PY
)"
read -r _loops _added <<< "${_result}"
if (( _loops == 0 )); then
    echo "[ERROR] No loop over .Providers in login page '${_page_secret}', can't hide '${IDP_NAME}'. Nothing was changed." >&2
    exit 1
fi
unset _result _loops _added

# --- Apply the users --------------------------------------------------------------
oc create secret generic "${SECRET_NAME}" -n openshift-config \
    --from-file=htpasswd="${_tmpdir}/htpasswd" --dry-run=client -o yaml | oc apply -f - >/dev/null
echo "[INFO] Secret openshift-config/${SECRET_NAME} holds ${#NEW_LINES} user(s)."

# Save before touching OAuth, so a failure below never loses issued passwords.
mkdir -p "$(dirname "${CREDENTIALS_FILE}")"
{
    echo "# username:password for the hidden '${IDP_NAME}' login on $(oc whoami --show-server)"
    [[ -n "${SAVED_URL_LINE}" ]] && print -r -- "${SAVED_URL_LINE}"
    for _u in "${(@ko)SAVED_PASSWORDS}"; do
        print
        print -r -- "${_u}:${SAVED_PASSWORDS[${_u}]}"
        print -rn -- "${SAVED_EXTRAS[${_u}]:-}"
    done
} > "${CREDENTIALS_FILE}"
chmod 600 "${CREDENTIALS_FILE}"
unset _u

# --- Hide it from the login page --------------------------------------------------
# Set before the provider is added, so the page never shows it. Only the
# providers.html key is written, so a custom secret that also holds the login or
# error page keeps them.
put_login_page() {
    if oc get secret "${_page_secret}" -n openshift-config &>/dev/null; then
        jq -n --rawfile h "$1" '{data: {"providers.html": ($h | @base64)}}' > "${_tmpdir}/page.patch.json"
        oc patch secret "${_page_secret}" -n openshift-config --type=merge \
            --patch-file="${_tmpdir}/page.patch.json" >/dev/null
    else
        oc create secret generic "${_page_secret}" -n openshift-config \
            --from-file=providers.html="$1" >/dev/null
    fi
}

if cmp -s "${_tmpdir}/page.new.html" "${_tmpdir}/page.old.html"; then
    echo "[INFO] Login page '${_page_secret}' already hides '${IDP_NAME}'."
else
    put_login_page "${_tmpdir}/page.new.html"
    echo "[INFO] Login page '${_page_secret}' updated to hide '${IDP_NAME}'."
fi
if [[ -z "${_page_ref}" ]]; then
    # Merge patch on this one key; custom login and error pages, if any, are kept.
    oc patch oauth cluster --type=merge \
        -p "{\"spec\":{\"templates\":{\"providerSelection\":{\"name\":\"${_page_secret}\"}}}}" >/dev/null
    echo "[INFO] OAuth now uses '${_page_secret}' as its login page."
fi

# --- Identity provider ----------------------------------------------------------
# Appended with a JSON patch, so the existing providers are never re-sent or touched.
if [[ "${IDP_EXISTS}" == true ]]; then
    echo "[INFO] Identity provider '${IDP_NAME}' already exists, left as is."
else
    _new_idp="$(jq -cn --arg n "${IDP_NAME}" --arg m "${IDP_MAPPING}" --arg s "${SECRET_NAME}" \
        '{name: $n, mappingMethod: $m, type: "HTPasswd", htpasswd: {fileData: {name: $s}}}')"
    if [[ "$(jq -r '.spec.identityProviders | type' <<< "${OAUTH_JSON}")" == array ]]; then
        oc patch oauth cluster --type=json \
            -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${_new_idp}}]" >/dev/null
        echo "[INFO] Added identity provider '${IDP_NAME}'. Existing providers kept:"
        jq -r '.spec.identityProviders[].name | "         - " + .' <<< "${OAUTH_JSON}"
    else
        oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":[${_new_idp}]}}" >/dev/null
        echo "[INFO] No identity providers yet, created the list with '${IDP_NAME}'."
    fi
    unset _new_idp
fi

# --- Remove pruned accounts -----------------------------------------------------
for _u in "${REMOVED[@]}"; do
    oc delete identity "${IDP_NAME}:${_u}" --ignore-not-found
    # Only delete the user if this was their only login.
    if [[ -z "$(oc get user "${_u}" -o jsonpath='{.identities[*]}' 2>/dev/null)" ]]; then
        oc delete user "${_u}" --ignore-not-found
    fi
    echo "[INFO] Removed '${_u}'."
done
unset _u

# --- OpenShift User objects -----------------------------------------------------
# Software Hub's IAM only checks a password against OpenShift when an OpenShift
# User of that name already exists; otherwise it checks only its own registry
# and the sign-in fails ("principal name ... is not found"). OpenShift makes the
# User at the first login, which a service ID may never do, so the User, its
# Identity in this provider and the mapping between them are made here, the same
# objects a first login would make.
_created=0
for _u in "${SERVICE_ID_USERS[@]}"; do
    _id="${IDP_NAME}:${_u}"
    if ! oc get user "${_u}" &>/dev/null; then
        oc create user "${_u}" >/dev/null
        (( ++_created ))
    fi
    oc get identity "${_id}" &>/dev/null || oc create identity "${_id}" >/dev/null
    if [[ "$(oc get identity "${_id}" -o jsonpath='{.user.name}')" != "${_u}" ]]; then
        oc create useridentitymapping "${_id}" "${_u}" >/dev/null
    fi
done
echo "[INFO] OpenShift User objects: ${_created} created, $(( ${#SERVICE_ID_USERS} - _created )) already there."
unset _u _id _created

# --- Wait for the login pods to pick it up -------------------------------------
echo "[INFO] Waiting for the authentication operator to roll out (up to ~5 min)..."
for _i in {1..15}; do
    [[ "$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" == True ]] && break
    sleep 2
done
oc wait co/authentication --for=condition=Progressing=False --timeout=300s >/dev/null \
    || echo "[WARN] Still rolling out. Check with: oc get co authentication"
unset _i

# --- Check the login page ---------------------------------------------------------
# If the page errors or still lists the provider, undo the page change (and the
# provider, if this run added it) so nobody is locked out of the browser login.
rollback() {
    if [[ -z "${_page_ref}" ]]; then
        oc patch oauth cluster --type=json \
            -p '[{"op":"remove","path":"/spec/templates/providerSelection"}]' >/dev/null
    elif [[ -s "${_tmpdir}/page.old.html" ]]; then
        put_login_page "${_tmpdir}/page.old.html"
    fi
    [[ "${IDP_EXISTS}" == true ]] && return 0
    local i
    i="$(oc get oauth cluster -o json | jq --arg n "${IDP_NAME}" '.spec.identityProviders // [] | map(.name) | index($n)')"
    [[ "${i}" == null ]] && return 0
    # 'test' makes sure the entry at that index is still ours before removing it.
    jq -cn --argjson i "${i}" --arg n "${IDP_NAME}" \
        '[{op: "test", path: "/spec/identityProviders/\($i)/name", value: $n},
          {op: "remove", path: "/spec/identityProviders/\($i)"}]' > "${_tmpdir}/rollback.json"
    oc patch oauth cluster --type=json --patch-file="${_tmpdir}/rollback.json" >/dev/null
}

OAUTH_HOST="$(oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}')"
IDP_URI="$(uri "${IDP_NAME}")"
# The console's "Display token" flow. Shows the login page; with &idp= it goes
# straight to that provider's form and ends on a page with an OpenShift API token.
TOKEN_LOGIN_URL="https://${OAUTH_HOST}/oauth/authorize?client_id=openshift-browser-client&response_type=code&redirect_uri=$(uri "https://${OAUTH_HOST}/oauth/token/display")"

_code="$(curl -sk -o "${_tmpdir}/live.html" -w '%{http_code}' "${TOKEN_LOGIN_URL}" || true)"
_direct="$(curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' "${TOKEN_LOGIN_URL}&idp=${IDP_URI}" || true)"
if [[ "${_code}" == 000 ]]; then
    echo "[WARN] Can't reach https://${OAUTH_HOST} from here, check the login page yourself."
elif [[ "${_code}" == [45]* ]] \
    || grep -qF -e "idp=${IDP_URI}&" -e "idp=${IDP_URI}\"" "${_tmpdir}/live.html"; then
    echo "[ERROR] Login page check failed (HTTP ${_code}, or '${IDP_NAME}' still listed). Rolling back..." >&2
    rollback
    echo "[ERROR] Rolled back the login page and any provider added in this run. The secret and" >&2
    echo "        ${CREDENTIALS_FILE} are kept. Details: oc get co authentication" >&2
    exit 1
elif [[ "${_direct}" == "302 "*"/login/${IDP_URI}?"* ]]; then
    echo "[INFO] Login page renders without '${IDP_NAME}', and its direct login answers."
else
    echo "[WARN] Login page is fine, but '${IDP_NAME}' is not answering yet (HTTP ${_direct%% *}). Check: oc get co authentication"
fi
unset _code _direct

# --- Software Hub ---------------------------------------------------------------
# Adds users through the usermgmt API as the IAM admin, the same way
# grant_softwarehub_admin_to_ocp_admins.sh does. Everything is read from this
# cluster: configs/cp4d_config/cpd_instance_details.sh may be for another one.
SH_URL=""
SH_TOKEN=""
SH_FAILED=()

# Usage: sh_api METHOD PATH [JSON_BODY]. Sets API_CODE and API_BODY.
sh_api() {
    local _resp _data=()
    [[ -n "${3:-}" ]] && _data=(-d "$3")
    _resp="$(curl -k -s -X "$1" "${SH_URL}$2" \
        -H "Authorization: Bearer ${SH_TOKEN}" \
        -H "Content-Type: application/json" \
        "${_data[@]}" \
        -w '\n%{http_code}' || true)"
    API_CODE="${_resp##*$'\n'}"
    API_BODY="${_resp%$'\n'*}"
}

# IAM reads the prefix from ROKS_USER_PREFIX in the platform-auth-idp configmap,
# which its operator writes from the Authentication CR. The CR is patched, then
# this waits for the configmap and for the IAM pods to restart with it.
IAM_DEPLOYMENTS=(platform-auth-service platform-identity-provider platform-identity-management)
clear_roks_user_prefix() {
    local ns="$1" prefix cr d i
    local -a old_pods
    prefix="$(oc get configmap platform-auth-idp -n "${ns}" -o jsonpath='{.data.ROKS_USER_PREFIX}' 2>/dev/null || true)"
    if [[ -z "${prefix}" ]]; then
        echo "[INFO] Software Hub: roksUserPrefix is already empty."
        return 0
    elif [[ "${CLEAR_ROKS_USER_PREFIX}" != true ]]; then
        echo "[WARN] Software Hub: roksUserPrefix is '${prefix}', so service IDs can't get a bearer token"
        echo "       or API key with their password. Set CLEAR_ROKS_USER_PREFIX=true to clear it."
        return 0
    fi

    cr="$(oc get authentications.operator.ibm.com -n "${ns}" -o name 2>/dev/null | head -n 1 || true)"
    if [[ -z "${cr}" ]]; then
        echo "[WARN] Software Hub: no IAM Authentication CR in '${ns}', roksUserPrefix ('${prefix}') left as is."
        return 0
    fi
    old_pods=(${(f)"$(oc get pods -n "${ns}" -o name 2>/dev/null | grep -E "/($(IFS='|'; print -r -- "${IAM_DEPLOYMENTS[*]}"))-" || true)"})

    oc patch "${cr}" -n "${ns}" --type=merge -p '{"spec":{"config":{"roksUserPrefix":""}}}' >/dev/null
    echo "[INFO] Software Hub: roksUserPrefix was '${prefix}', cleared on ${cr#*/}. Waiting for IAM (up to ~10 min)..."

    for i in {1..60}; do
        [[ -z "$(oc get configmap platform-auth-idp -n "${ns}" -o jsonpath='{.data.ROKS_USER_PREFIX}')" ]] && break
        sleep 10
    done
    if [[ -n "$(oc get configmap platform-auth-idp -n "${ns}" -o jsonpath='{.data.ROKS_USER_PREFIX}')" ]]; then
        echo "[WARN] Software Hub: the IAM operator has not updated platform-auth-idp yet. Check: oc get ${cr} -n ${ns} -o yaml"
        return 0
    fi

    # The operator restarts the pods itself; if it hasn't after 3 minutes, do it here.
    for i in {1..18}; do
        (( ${#old_pods} == 0 )) && break
        oc get "${old_pods[@]}" -n "${ns}" -o name &>/dev/null || break
        sleep 10
    done
    if (( ${#old_pods} > 0 )) && oc get "${old_pods[@]}" -n "${ns}" -o name &>/dev/null; then
        for d in "${IAM_DEPLOYMENTS[@]}"; do
            oc rollout restart "deployment/${d}" -n "${ns}" >/dev/null 2>&1 || true
        done
    fi
    for d in "${IAM_DEPLOYMENTS[@]}"; do
        oc get "deployment/${d}" -n "${ns}" &>/dev/null || continue
        oc rollout status "deployment/${d}" -n "${ns}" --timeout=300s >/dev/null \
            || echo "[WARN] Software Hub: ${d} is not ready yet. Check: oc get pods -n ${ns}"
    done
    echo "[INFO] Software Hub: IAM restarted with an empty roksUserPrefix."
}

register_in_softwarehub() {
    local ns="${SOFTWAREHUB_NAMESPACE}" roks admin _u _body
    local -a found
    if [[ -z "${ns}" ]]; then
        found=(${(f)"$(oc get zenservice -A \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null || true)"})
        if (( ${#found} == 0 )); then
            echo "[INFO] No Software Hub instance on this cluster, skipping Software Hub."
            return 0
        elif (( ${#found} > 1 )); then
            echo "[WARN] Several Software Hub instances (${found[*]}). Set SOFTWAREHUB_NAMESPACE; skipping Software Hub."
            return 0
        fi
        ns="${found[1]}"
    fi

    if [[ "$(oc get zenservice -n "${ns}" -o jsonpath='{.items[0].spec.iamIntegration}' 2>/dev/null || true)" != true ]]; then
        echo "[WARN] Software Hub in '${ns}' does not use IAM, so it can't take OpenShift logins. Skipping Software Hub."
        return 0
    fi
    roks="$(oc get configmap platform-auth-idp -n "${ns}" -o jsonpath='{.data.ROKS_ENABLED}' 2>/dev/null || true)"
    if [[ "${roks}" != true ]]; then
        echo "[WARN] Software Hub has OpenShift authentication off (ROKS_ENABLED='${roks}' in ${ns}/platform-auth-idp). Skipping Software Hub."
        return 0
    fi

    clear_roks_user_prefix "${ns}"

    SH_URL="https://$(oc get route cpd -n "${ns}" -o jsonpath='{.spec.host}')"
    admin="$(oc get secret platform-auth-idp-credentials -n "${ns}" -o jsonpath='{.data.admin_username}' | base64 -d)"
    # The password goes in on stdin, so it never shows up in the process list.
    SH_TOKEN="$(oc get secret platform-auth-idp-credentials -n "${ns}" -o jsonpath='{.data.admin_password}' \
        | base64 -d | jq -Rc --arg u "${admin}" '{username: $u, password: .}' \
        | curl -k -s -X POST "${SH_URL}/icp4d-api/v1/authorize" -H "Content-Type: application/json" --data @- \
        | jq -r '.token // empty' 2>/dev/null || true)"
    if [[ -z "${SH_TOKEN}" ]]; then
        echo "[ERROR] Could not sign in to Software Hub at ${SH_URL} as ${admin}." >&2
        SH_FAILED+=("(sign-in)")
        return 0
    fi
    echo "[INFO] Software Hub: ${SH_URL} (namespace ${ns})"

    for _u in "${SERVICE_ID_USERS[@]}"; do
        sh_api GET "/usermgmt/v1/user/$(uri "${_u}")"
        if [[ "${API_CODE}" == 200 ]]; then
            echo "[INFO] Software Hub: '${_u}' already added, roles left as is."
            continue
        elif [[ "${API_CODE}" != 404 ]]; then
            echo "[ERROR] Software Hub: could not look up '${_u}' (HTTP ${API_CODE}): ${API_BODY}" >&2
            SH_FAILED+=("${_u}")
            continue
        fi
        # Same shape as the records Software Hub creates for OpenShift logins.
        _body="$(jq -cn --arg u "${_u}" \
            '{username: $u, displayName: $u, authenticator: "external", user_roles: $ARGS.positional}
             + (if $u | contains("@") then {email: $u} else {} end)' \
            --args "${SOFTWAREHUB_ROLES[@]}")"
        sh_api POST "/usermgmt/v1/user" "${_body}"
        if [[ "${API_CODE}" == 2* ]]; then
            echo "[INFO] Software Hub: added '${_u}' with ${SOFTWAREHUB_ROLES[*]}."
        else
            echo "[ERROR] Software Hub: adding '${_u}' failed (HTTP ${API_CODE}): ${API_BODY}" >&2
            SH_FAILED+=("${_u}")
        fi
    done

    # A pruned service ID loses its Software Hub account too, so its API key stops working.
    for _u in "${REMOVED[@]}"; do
        sh_api DELETE "/icp4d-api/v1/users/$(uri "${_u}")"
        if [[ "${API_CODE}" == 2* || "${API_CODE}" == 404 ]]; then
            echo "[INFO] Software Hub: removed '${_u}'."
        else
            echo "[ERROR] Software Hub: removing '${_u}' failed (HTTP ${API_CODE}): ${API_BODY}" >&2
            SH_FAILED+=("${_u}")
        fi
    done
}

if [[ "${REGISTER_IN_SOFTWAREHUB}" == true ]]; then
    register_in_softwarehub
fi

# --- Summary --------------------------------------------------------------------
echo "[INFO] ---"
echo "[INFO] '${IDP_NAME}' is not on the login page. Sign in as a service ID with:"
echo "         CLI      oc login $(oc whoami --show-server) -u <user> -p <password>"
echo "         Browser  on the \"Log in with\" page, add &idp=${IDP_URI} to the address"
echo "                  (OpenShift console, or Software Hub > OpenShift authentication)"
echo "         Token    ${TOKEN_LOGIN_URL}&idp=${IDP_URI}"
if [[ -n "${SH_URL}" ]]; then
    echo "[INFO] API keys: run generate_service_id_cpd_apikeys.sh, or sign in at ${SH_URL} as above,"
    echo "                 then Profile and settings > API key > Generate new key."
fi
if (( ${#ISSUED} > 0 )); then
    echo "[INFO] New passwords (also in ${CREDENTIALS_FILE}):"
    for _u in "${ISSUED[@]}"; do
        printf '         %-40s %s\n' "${_u}" "${SAVED_PASSWORDS[${_u}]}"
    done
else
    echo "[INFO] No new passwords issued. Existing ones are in ${CREDENTIALS_FILE}."
fi
echo "[INFO] OpenShift rights, if needed: oc adm policy ... (new accounts start with none)."

if (( ${#SH_FAILED} > 0 )); then
    echo "[ERROR] Software Hub access could not be set for: ${SH_FAILED[*]}" >&2
    exit 1
fi
