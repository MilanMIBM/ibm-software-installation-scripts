#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Generates a Software Hub (Zen) API key for each service ID in CREDENTIALS_FILE,
# the username:password file written by set_service_id_user_proxies.sh. Each user
# signs in with its own password (/icp4d-api/v1/authorize) and then asks for a
# new key for itself (/usermgmt/v1/user/apiKey).
#
# Every run makes NEW keys: Software Hub revokes a user's old key when a new one
# is generated, so anything still using the old key stops working. The key is
# written under the user's line, replacing the one from an earlier run, and the
# Software Hub URL once at the top:
#
#   # Software Hub API keys below are for https://cpd-<ns>.apps.<cluster>
#
#   cpd_service_id_481902:<password>
#   # Software Hub API key for cpd_service_id_481902 (generated <date>)
#   apikey=<api key>
#
#   cpd_service_id_209818:<password>
#   ...
#
# Every user in the file is tried; a failed sign-in is retried a few times (IAM
# may still be restarting). The file is updated after each key, so a failure
# halfway loses nothing. A user whose key could not be generated keeps the old one.
#
# To call the APIs with a key, send 'Authorization: ZenApiKey <token>', where
# <token> is base64 of '<username>:<api key>' (printed at the end), or swap it
# for a bearer token: POST /icp4d-api/v1/authorize {"username", "api_key"}.
#
# Each API call's HTTP status and response is printed (bearer tokens shortened),
# so a failure shows what the API said. -q/--quiet prints only the outcome per
# user; -v/--verbose turns the responses back on (the default).
#
# With STORE_APIKEYS_IN_VAULT=true (the default; --no-vault turns it off) the new
# keys are also stored in the Software Hub internal vault by
# softwarehub_utils/store_cpd_apikeys_in_vault.sh: by default as a 'key' secret
# '<username>-apikey' owned by the user, with the admin as a member.
# VAULT_SECRET_FORMATS (key, credentials, generic) and VAULT_SECRET_OWNER (user,
# admin) change that; see that script. If it is not there, this step is skipped
# with a warning; if it fails, the keys are still in CREDENTIALS_FILE and the
# warning shows how to store them later.
#
# Software Hub URL, first found of: --cpd-url, the URL recorded in
# CREDENTIALS_FILE by an earlier run, the 'cpd' route of the Software Hub on the
# cluster oc is logged in to, CPD_URL from cpd_instance_details.sh.
#
#   generate_service_id_cpd_apikeys.sh                     every user in the file
#   generate_service_id_cpd_apikeys.sh svc-a svc-b         only these users
#   generate_service_id_cpd_apikeys.sh --cpd-url https://cpd-<ns>.apps.<cluster>
#   generate_service_id_cpd_apikeys.sh -q                  no API responses, outcomes only
#   generate_service_id_cpd_apikeys.sh --no-vault          don't store the keys in the vault

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b

# Written by set_service_id_user_proxies.sh. configs/ is gitignored.
# SERVICE_ID_CREDENTIALS_FILE in the environment points it elsewhere.
CREDENTIALS_FILE="${SERVICE_ID_CREDENTIALS_FILE:-${REPO_ROOT}/configs/openshift_config/service_id_credentials.txt}"
# Start of the comment above each key; also how an earlier run's key is found.
KEY_COMMENT="# Software Hub API key for"
# Start of the line at the top that holds the Software Hub URL.
URL_COMMENT="# Software Hub API keys below are for"
# Sign-in attempts per user, SIGNIN_RETRY_DELAY seconds apart.
SIGNIN_ATTEMPTS=2
SIGNIN_RETRY_DELAY=5
# Also store the new keys in the Software Hub internal vault, with this script.
STORE_APIKEYS_IN_VAULT="${STORE_APIKEYS_IN_VAULT:-true}"
VAULT_SCRIPT="${REPO_ROOT}/src/utilities/softwarehub_utils/store_cpd_apikeys_in_vault.sh"

SH_URL=""
VERBOSE=true
CLI_USERS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpd-url)    SH_URL="${2:?--cpd-url needs the Software Hub URL}"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -q|--quiet)   VERBOSE=false; shift ;;
        --no-vault)   STORE_APIKEYS_IN_VAULT=false; shift ;;
        -h|--help)    sed -n '9,57p' "$0"; exit 0 ;;
        -*)           echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
        *)            CLI_USERS+=("$1"); shift ;;
    esac
done

for _tool in jq curl base64; do
    if ! command -v "${_tool}" &>/dev/null; then
        echo "[ERROR] '${_tool}' is not installed." >&2
        exit 1
    fi
done
unset _tool

if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
    echo "[ERROR] ${CREDENTIALS_FILE} not found. Run set_service_id_user_proxies.sh first." >&2
    exit 1
fi

# --- Read the credentials file ---------------------------------------------------
# A user line is 'name:password'; comments and 'apikey=' lines are not.
is_user_line() { [[ -n "$1" && "$1" != \#* && "$1" != apikey=* && "$1" == *:* ]]; }

typeset -A PASSWORDS
FILE_USERS=()
_recorded_url=""
while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if is_user_line "${_line}"; then
        PASSWORDS[${_line%%:*}]="${_line#*:}"
        FILE_USERS+=("${_line%%:*}")
    elif [[ "${_line}" == "${URL_COMMENT} "* && "${_line}" =~ '(https?://[^ )]+)' ]]; then
        _recorded_url="${match[1]}"
    fi
done < "${CREDENTIALS_FILE}"
unset _line

if (( ${#CLI_USERS} > 0 )); then
    for _u in "${CLI_USERS[@]}"; do
        if [[ -z "${PASSWORDS[${_u}]+x}" ]]; then
            echo "[ERROR] '${_u}' is not in ${CREDENTIALS_FILE}." >&2
            exit 1
        fi
    done
    unset _u
    USERS=("${CLI_USERS[@]}")
else
    USERS=("${FILE_USERS[@]}")
fi
if (( ${#USERS} == 0 )); then
    echo "[ERROR] No users in ${CREDENTIALS_FILE}." >&2
    exit 1
fi

# --- Software Hub URL --------------------------------------------------------------
cluster_url() {
    local -a found
    oc whoami &>/dev/null || return 0
    found=(${(f)"$(oc get zenservice -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null || true)"})
    (( ${#found} == 1 )) || return 0
    local host
    host="$(oc get route cpd -n "${found[1]}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && print -r -- "https://${host}"
    return 0
}

if [[ -n "${SH_URL}" ]]; then
    _source="--cpd-url"
elif [[ -n "${_recorded_url}" ]]; then
    SH_URL="${_recorded_url}"; _source="recorded in the credentials file"
elif command -v oc &>/dev/null && SH_URL="$(cluster_url)" && [[ -n "${SH_URL}" ]]; then
    _source="route on $(oc whoami --show-server)"
elif [[ -n "${CPD_URL:-}" ]]; then
    SH_URL="${CPD_URL}"; _source="CPD_URL"
else
    echo "[ERROR] No Software Hub URL. Pass --cpd-url, log in with oc, or set CPD_URL." >&2
    exit 1
fi
SH_URL="${SH_URL%/}"
[[ "${SH_URL}" == http* ]] || SH_URL="https://${SH_URL}"
echo "[INFO] Software Hub: ${SH_URL} (${_source})"
unset _source _recorded_url

# --- Write a key into the file -------------------------------------------------------
# Rewrites the file with the user's old key lines (if any) swapped for the new
# ones, the Software Hub URL once at the top and a blank line between users.
# Other lines are kept, each with the user it was under.
save_key() {
    local user="$1" key="$2" line cur="" tmp
    local -a lines head order
    local -A block
    lines=("${(@f)"$(<"${CREDENTIALS_FILE}")"}")
    for line in "${lines[@]}"; do
        [[ -z "${line//[[:space:]]/}" || "${line}" == "${URL_COMMENT} "* ]] && continue
        if is_user_line "${line}"; then
            cur="${line%%:*}"
            order+=("${cur}")
            block[${cur}]="${line}"$'\n'
        elif [[ -z "${cur}" ]]; then
            head+=("${line}")
        elif [[ "${cur}" == "${user}" && ( "${line}" == apikey=* || "${line}" == "${KEY_COMMENT} "* ) ]]; then
            continue
        else
            block[${cur}]+="${line}"$'\n'
        fi
    done
    block[${user}]+="${KEY_COMMENT} ${user} (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))"$'\n'"apikey=${key}"$'\n'

    tmp="$(mktemp "${CREDENTIALS_FILE}.XXXXXX")"
    chmod 600 "${tmp}"
    {
        (( ${#head} > 0 )) && print -rl -- "${head[@]}"
        print -r -- "${URL_COMMENT} ${SH_URL}"
        for cur in "${order[@]}"; do
            print
            print -rn -- "${block[${cur}]}"
        done
    } > "${tmp}"
    mv "${tmp}" "${CREDENTIALS_FILE}"
}

# The response for an error line, unless show_response already printed it.
error_body() {
    [[ "${VERBOSE}" == true ]] && print -r -- ", response above." || print -r -- ": ${1%$'\n'*}"
}

# Usage: show_response USER WHAT RESPONSE, RESPONSE being the body, a newline and
# the HTTP status (curl -w '\n%{http_code}'). With VERBOSE, prints both to
# stderr, bearer tokens shortened. Goes to stderr because sign_in's stdout is
# the token.
show_response() {
    [[ "${VERBOSE}" == true ]] || return 0
    local code="${3##*$'\n'}" body="${3%$'\n'*}" shown
    [[ "${code}" == 000 ]] && body="(no response: could not reach ${SH_URL}, or it timed out)"
    shown="$(jq --indent 2 'if type == "object" then with_entries(
            if (.key == "token" or .key == "accessToken") and (.value | type) == "string"
            then .value = .value[0:12] + "... (\(.value | length) chars)" else . end) else . end' \
        <<< "${body}" 2>/dev/null || print -r -- "${body[1,2000]}")"
    echo "[API]  '$1' $2: HTTP ${code}" >&2
    print -r -- "${shown}" | sed 's/^/         /' >&2
}

# Usage: sign_in USER. Prints the bearer token, or returns 1 after printing the
# last error to stderr.
sign_in() {
    local resp token i
    for (( i = 1; i <= SIGNIN_ATTEMPTS; i++ )); do
        # The password goes in on stdin, so it never shows up in the process list.
        resp="$(jq -cn --arg u "$1" --arg p "${PASSWORDS[$1]}" '{username: $u, password: $p}' \
            | curl -k -s --max-time 60 -X POST "${SH_URL}/icp4d-api/v1/authorize" \
                -H "Content-Type: application/json" --data @- -w '\n%{http_code}' || true)"
        show_response "$1" "sign-in (attempt ${i}/${SIGNIN_ATTEMPTS})" "${resp}"
        token="$(jq -r '.token // .accessToken // empty' <<< "${resp%$'\n'*}" 2>/dev/null || true)"
        if [[ -n "${token}" ]]; then
            print -r -- "${token}"
            return 0
        fi
        if (( i < SIGNIN_ATTEMPTS )); then
            echo "[WARN] '$1': sign-in failed (HTTP ${resp##*$'\n'}), retrying in ${SIGNIN_RETRY_DELAY}s (${i}/${SIGNIN_ATTEMPTS})..." >&2
            sleep "${SIGNIN_RETRY_DELAY}"
        fi
    done
    echo "[ERROR] '$1': sign-in failed (HTTP ${resp##*$'\n'})$(error_body "${resp}")" >&2
    return 1
}

# --- Generate the keys ---------------------------------------------------------------
typeset -A NEW_KEYS
FAILED=()
for _u in "${USERS[@]}"; do
    if ! _token="$(sign_in "${_u}")"; then
        FAILED+=("${_u}")
        continue
    fi

    # The bearer token goes in through a config on stdin, for the same reason.
    _resp="$(print -r -- "header = \"Authorization: Bearer ${_token}\"" \
        | curl -k -s --max-time 60 -K - -X GET "${SH_URL}/usermgmt/v1/user/apiKey" \
            -H "Accept: application/json" -w '\n%{http_code}' || true)"
    show_response "${_u}" "API key" "${_resp}"
    _key="$(jq -r '.apiKey // empty' <<< "${_resp%$'\n'*}" 2>/dev/null || true)"
    if [[ -z "${_key}" ]]; then
        echo "[ERROR] '${_u}': API key request failed (HTTP ${_resp##*$'\n'})$(error_body "${_resp}")" >&2
        FAILED+=("${_u}")
        continue
    fi

    save_key "${_u}" "${_key}"
    NEW_KEYS[${_u}]="${_key}"
    echo "[INFO] '${_u}': new API key generated (any older key is now revoked)."
done
unset _u _resp _token _key

# --- Summary -------------------------------------------------------------------------
if (( ${#NEW_KEYS} > 0 )); then
    echo "[INFO] ---"
    echo "[INFO] New API keys (also in ${CREDENTIALS_FILE}):"
    for _u in "${USERS[@]}"; do
        [[ -n "${NEW_KEYS[${_u}]:-}" ]] || continue
        echo "         ${_u}"
        echo "           API key            ${NEW_KEYS[${_u}]}"
        echo "           ZenApiKey token    $(printf '%s' "${_u}:${NEW_KEYS[${_u}]}" | base64 | tr -d '\n')"
    done
    echo "[INFO] Use as: curl -k \"${SH_URL}/usermgmt/v1/user/currentUserInfo\" -H \"Authorization: ZenApiKey <token>\""
    unset _u
fi

# --- Store the keys in the vault -------------------------------------------------------
if (( ${#NEW_KEYS} > 0 )) && [[ "${STORE_APIKEYS_IN_VAULT:l}" == true ]]; then
    if [[ ! -f "${VAULT_SCRIPT}" ]]; then
        echo "[WARN] STORE_APIKEYS_IN_VAULT is on but ${VAULT_SCRIPT} is not there; the keys are not stored in the vault." >&2
    else
        _vault_args=(--cpd-url "${SH_URL}")
        [[ "${VERBOSE}" == true ]] || _vault_args+=(-q)
        echo "[INFO] ---"
        echo "[INFO] Storing the new API keys in the Software Hub vault..."
        # 'user:key:password' lines go in on stdin, so they stay out of the process list.
        if ! for _u in "${(k)NEW_KEYS[@]}"; do print -r -- "${_u}:${NEW_KEYS[${_u}]}:${PASSWORDS[${_u}]}"; done \
                | zsh "${VAULT_SCRIPT}" "${_vault_args[@]}"; then
            echo "[WARN] Not every key could be stored in the vault (see above). They are in ${CREDENTIALS_FILE};" >&2
            echo "       store them later with: ${VAULT_SCRIPT} --from-credentials-file --cpd-url ${SH_URL} ${(k)NEW_KEYS[*]}" >&2
        fi
        unset _u _vault_args
    fi
fi

if (( ${#FAILED} > 0 )); then
    echo "[ERROR] No new API key for: ${FAILED[*]} (their old key, if any, is kept in the file)." >&2
    exit 1
fi
