#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 4.6 Concert API key (C_API_KEY) -> CONCERT_API_KEY in concert_instance_details.sh
# ------------------------------------------------------------------------------
#   ./4.6_generate_api_key.sh [--no-test] [--force] [--keep-server-key]
#
#   --no-test          skip the authentication test (or CONCERT_API_KEY_TEST=false)
#   --force            generate a new key even if the stored one still works
#   --keep-server-key  never revoke a key the user already has on the server
#                      (stop instead; the UI allows one key per user)
#
# IBM documents the key only as a UI action ("API key" icon -> Generate API
# key). This does the same calls as the UI, as CONCERT_UI_USERNAME /
# CONCERT_UI_PASSWORD from concert_instance_details.sh (3.4):
#   1. login: Hub SSO (/platform_hub/core/api/v1/sso, which needs a Referer)
#      -> Keycloak concert-realm login form -> /exchange, which sets the
#      ibm-platform-session cookie
#   2. GET/DELETE/POST /concert/core/api/v1/apikey (one key per user; the
#      secret is only returned by the POST)
# Use the key with: -H "Authorization: C_API_KEY ${CONCERT_API_KEY}"
#                   -H "InstanceId: 0000-0000-0000-0000"  (always, for OCP)
# CONCERT_AUTH_CALL holds a complete example call (curl with the endpoint and
# both headers, values filled in): copy it, or run it with eval "${CONCERT_AUTH_CALL}".
#
# Idempotent: a stored CONCERT_API_KEY that Concert still accepts is kept and
# nothing is generated. Only the "export CONCERT_API_KEY=" and
# "export CONCERT_AUTH_CALL=" lines of concert_instance_details.sh are replaced
# (or appended); the rest of the file is left as is, and 3.4 carries both lines
# over when it rewrites the file.
# A key that already exists on the server but is not stored here cannot be
# read back, so it is revoked and replaced (unless --keep-server-key).
# ==============================================================================

# $0 inside a zsh function is the function name, so take the path here.
SELF="$0"
usage() { sed -n '/^#   \.\/4\.6/,/^#                      (stop instead/p' "${SELF}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

DO_TEST=true FORCE=false KEEP_SERVER_KEY=false
concert_is_true "${CONCERT_API_KEY_TEST:-true}" || DO_TEST=false
for _arg in "$@"; do
    case "${_arg}" in
        --no-test)         DO_TEST=false ;;
        --force)           FORCE=true ;;
        --keep-server-key) KEEP_SERVER_KEY=true ;;
        -h|--help)         usage 0 ;;
        *)                 concert_error "Unknown argument: ${_arg}"; usage 1 ;;
    esac
done

OUT="${CONCERT_CONFIG_DIR}/concert_instance_details.sh"
[[ -f "${OUT}" ]] || concert_die "${OUT} not found - run 3_install_concert/3.4_get_instance_details.sh first."
# Fresh values (and the currently stored CONCERT_API_KEY, if any) from the file itself.
source "${OUT}"
concert_require_vars CONCERT_URL CONCERT_UI_USERNAME CONCERT_UI_PASSWORD
CONCERT_URL="${CONCERT_URL%/}"
INSTANCE_ID="0000-0000-0000-0000"

TMP="$(concert_private_tmpdir)"
JAR="${TMP}/cookies" PAGE="${TMP}/page.html" BODY="${TMP}/body"
trap 'rm -rf -- "${TMP:?}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

# _key_status <key>: HTTP status of an API call made with the key. 200 = valid,
# 401/403 = rejected. A malformed key makes Concert 3.1.0 answer 502 (rojacore
# panics in ValidateApikey), so anything else is "could not tell".
# The key goes to curl via stdin (-H @-), not argv.
_key_status() {
    print -r -- "Authorization: C_API_KEY $1"$'\n'"InstanceId: ${INSTANCE_ID}" \
        | curl -sk --max-time 30 -o /dev/null -w '%{http_code}' -H @- \
            "${CONCERT_URL}/concert/core/api/v2/applications" || true
}

# _login: browser login as CONCERT_UI_USERNAME; leaves the session cookie in JAR.
_login() {
    local ref="${CONCERT_URL}/concert/" action
    curl -sk --max-time 60 -L -c "${JAR}" -b "${JAR}" -H "Referer: ${ref}" -o "${PAGE}" \
        -G --data-urlencode "return_uri=${ref}" "${CONCERT_URL}/platform_hub/core/api/v1/sso" \
        || { concert_error "Could not reach the Hub login (${CONCERT_URL}/platform_hub/core/api/v1/sso)."; return 1; }
    action="$(grep -m1 -o 'action="[^"]*login-actions/authenticate[^"]*"' "${PAGE}" || true)"
    action="${${action#action=\"}%\"}"
    action="${action//&amp;/&}"
    [[ -n "${action}" ]] || { concert_error "The Hub SSO did not return the Keycloak login form."; return 1; }
    # Password via stdin, not argv.
    print -rn -- "${CONCERT_UI_PASSWORD}" | curl -sk --max-time 60 -L -c "${JAR}" -b "${JAR}" \
        -H "Referer: ${ref}" -o "${PAGE}" \
        --data-urlencode "username=${CONCERT_UI_USERNAME}" --data-urlencode password@- \
        --data-urlencode credentialId= "${action}" \
        || { concert_error "The Keycloak login request failed."; return 1; }
    grep -q $'\tibm-platform-session\t' "${JAR}" && return 0
    if grep -q 'kc-form-login' "${PAGE}"; then
        concert_error "Keycloak rejected ${CONCERT_UI_USERNAME} / CONCERT_UI_PASSWORD (run 3.4 to refresh it)."
    else
        concert_error "Keycloak did not finish the login for ${CONCERT_UI_USERNAME} (pending required action, e.g. password update or OTP? Log in once in the UI)."
    fi
    return 1
}

# _apikey <GET|POST|DELETE>: calls the UI's API key endpoint; body in BODY, prints the status.
_apikey() {
    local -a data=()
    [[ "$1" == POST ]] && data=(--data '')
    curl -sk --max-time 60 -b "${JAR}" -X "$1" "${data[@]}" -o "${BODY}" -w '%{http_code}' \
        "${CONCERT_URL}/concert/core/api/v1/apikey" || true
}

# _set_export_line <VAR> <line>: replaces the first "export <VAR>=" line of OUT
# (drops duplicates) or appends <line>; every other line stays byte for byte.
# Written via a temp file + rename, mode 700 like 3.4. No-op if unchanged.
_set_export_line() {
    _CONCERT_VAR="$1" _CONCERT_LINE="$2" python3 -I - "${OUT}" <<'PY'
import os, re, sys
path, new = sys.argv[1], os.environ["_CONCERT_LINE"] + "\n"
with open(path) as f:
    lines = f.read().splitlines(keepends=True)
pat = re.compile(r"^\s*export\s+" + re.escape(os.environ["_CONCERT_VAR"]) + "=")
out, done = [], False
for line in lines:
    if pat.match(line):
        if not done:
            out.append(new)
            done = True
        continue
    out.append(line)
if not done:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append(new)
if out == lines:
    sys.exit(0)
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o700)
with os.fdopen(fd, "w") as f:
    f.writelines(out)
os.chmod(tmp, 0o700)
os.replace(tmp, path)
PY
}

_write_key_line() {   # <key>
    _set_export_line CONCERT_API_KEY "export CONCERT_API_KEY=${(qq)1}  # C_API_KEY of ${CONCERT_UI_USERNAME}, from 4.6 on $(date -u +%Y-%m-%dT%H:%M:%SZ); send with InstanceId: ${INSTANCE_ID}"
}

# _write_auth_call_line <key>: CONCERT_AUTH_CALL, a ready-to-run example call
# (IBM's usage example endpoint). Each argument is double-quoted with $ " \ `
# escaped, so eval "${CONCERT_AUTH_CALL}" passes the values through unchanged.
_write_auth_call_line() {
    local call="curl -k --request GET --url ${(qqq):-${CONCERT_URL}/concert/core/api/v2/applications}"
    call+=" --header ${(qqq):-InstanceId: ${INSTANCE_ID}} --header ${(qqq):-Authorization: C_API_KEY $1}"
    _set_export_line CONCERT_AUTH_CALL "export CONCERT_AUTH_CALL=${(qq)call}"
}

# --- 1. Keep a stored key that still works --------------------------------------
STORED_KEY="${CONCERT_API_KEY:-}"
if [[ -n "${STORED_KEY}" ]] && ! ${FORCE}; then
    if ! ${DO_TEST}; then
        _write_auth_call_line "${STORED_KEY}"
        concert_info "CONCERT_API_KEY is already set in ${OUT} (not tested: --no-test) - keeping it. Use --force for a new key."
        exit 0
    fi
    code="$(_key_status "${STORED_KEY}")"
    case "${code}" in
        200)     _write_auth_call_line "${STORED_KEY}"
                 concert_info "Stored CONCERT_API_KEY authenticates (HTTP 200) - keeping it. Use --force for a new key."
                 exit 0 ;;
        401|403) concert_warn "Stored CONCERT_API_KEY is rejected (HTTP ${code}) - generating a new one." ;;
        *)       concert_die "Could not check the stored CONCERT_API_KEY (HTTP ${code}) - leaving it unchanged. Check Concert, or use --force." ;;
    esac
fi

# --- 2. Log in and (re)generate ---------------------------------------------------
concert_info "Logging in to ${CONCERT_URL} as ${CONCERT_UI_USERNAME} ..."
_login || concert_die "Login failed - no API key generated."

code="$(_apikey GET)"
# Seen: 200 {"created_on":<epoch>} when the user has a key. With no key it may
# be 200 without created_on, or 404 - both mean nothing to revoke.
[[ "${code}" == (200|404) ]] || concert_die "Could not read the API key state (GET /concert/core/api/v1/apikey -> HTTP ${code}): $(head -c 300 "${BODY}")"
if [[ "${code}" == 200 ]] && grep -q '"created_on"' "${BODY}"; then
    ${KEEP_SERVER_KEY} && concert_die "${CONCERT_UI_USERNAME} already has an API key on the server and --keep-server-key is set - not revoking it."
    concert_warn "${CONCERT_UI_USERNAME} already has an API key on the server; revoking it (its secret cannot be read back, anything still using it stops working)."
    code="$(_apikey DELETE)"
    [[ "${code}" == 2?? ]] || concert_die "Could not revoke the existing API key (HTTP ${code}): $(head -c 300 "${BODY}")"
fi

code="$(_apikey POST)"
[[ "${code}" == 2?? ]] || concert_die "Could not generate an API key (HTTP ${code}): $(head -c 300 "${BODY}")"
# The UI shows the response body as the key: a bare or JSON-quoted string;
# an object with a key field is accepted too in case a release changes that.
NEW_KEY="$(python3 -I -c '
import json, sys
b = sys.stdin.read().strip()
try:
    d = json.loads(b)
except ValueError:
    d = b
if isinstance(d, dict):
    d = next((d[k] for k in ("api_key", "apikey", "apiKey", "key", "secret", "value") if isinstance(d.get(k), str)), "")
print(d.strip() if isinstance(d, str) else "", end="")' < "${BODY}")"
[[ -n "${NEW_KEY}" && "${NEW_KEY}" != *[[:space:]]* ]] \
    || concert_die "The API key response was empty or not recognised (the server may now hold a new key; re-run this script)."

_write_key_line "${NEW_KEY}"
_write_auth_call_line "${NEW_KEY}"
concert_info "Wrote CONCERT_API_KEY (for ${CONCERT_UI_USERNAME}) and CONCERT_AUTH_CALL to ${OUT}"

# --- 3. Status: authenticate with the new key -------------------------------------
if ${DO_TEST}; then
    for _try in 1 2 3; do
        code="$(_key_status "${NEW_KEY}")"
        [[ "${code}" == 200 ]] && break
        (( _try < 3 )) && sleep 5
    done
    if [[ "${code}" == 200 ]]; then
        concert_info "API key authenticates: GET /concert/core/api/v2/applications -> HTTP 200"
    else
        concert_die "The new API key did not authenticate (GET /concert/core/api/v2/applications -> HTTP ${code}). It is saved; re-run this script to test it again."
    fi
else
    concert_info "Authentication test skipped (--no-test / CONCERT_API_KEY_TEST=false)."
fi
