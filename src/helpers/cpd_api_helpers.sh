#!/bin/zsh
# =============================================================================
# cpd_api_helpers.sh - Software Hub (Cloud Pak for Data) REST calls
# -----------------------------------------------------------------------------
# How scripts use it (after the env_bootstrap line):
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/cpd_api_helpers.sh"
#     cpdapi_login "${CPD_URL}" "${CPD_USERNAME}" api_key "${CPD_APIKEY}" \
#         || { echo "[ERROR] ..." >&2; exit 1; }
#     cpdapi GET "/v2/projects?name=$(cpdapi_urlencode "${name}")"
#     [[ "${API_CODE}" == 200 ]] && print -r -- "${API_BODY}"
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _CPDAPI_HELPERS_LOADED.
#   - curl -k throughout: Software Hub routes usually carry self-signed certs.
#   - The sign-in secret reaches python and curl through the environment and
#     stdin, so it never shows up in the process list. Functions print no
#     errors of their own; callers word them.
# =============================================================================

[[ -n "${_CPDAPI_HELPERS_LOADED:-}" ]] && return 0
_CPDAPI_HELPERS_LOADED=1

CPDAPI_BASE=""
CPDAPI_TOKEN=""

# cpdapi_authorize <base url> <user> <api_key|password> <secret>
# POST /icp4d-api/v1/authorize. Sets API_CODE ("000" when unreachable) and API_BODY.
cpdapi_authorize() {
    local _resp
    _resp="$(CPDAPI_U="$2" CPDAPI_K="$3" CPDAPI_S="$4" python3 -c 'import json, os
print(json.dumps({"username": os.environ["CPDAPI_U"], os.environ["CPDAPI_K"]: os.environ["CPDAPI_S"]}))' \
        | curl -sk -X POST "${1%/}/icp4d-api/v1/authorize" -H 'Content-Type: application/json' \
            --data @- -w $'\n%{http_code}' || true)"
    API_CODE="${_resp##*$'\n'}"
    API_BODY="${_resp%$'\n'*}"
}

# cpdapi_login <base url> <user> <api_key|password> <secret>
# Signs in for cpdapi: sets CPDAPI_BASE and the bearer token CPDAPI_TOKEN.
# Fails when no token comes back.
cpdapi_login() {
    CPDAPI_BASE="${1%/}"
    cpdapi_authorize "$@"
    CPDAPI_TOKEN="$(print -r -- "${API_BODY}" \
        | python3 -c 'import sys, json; print(json.load(sys.stdin).get("token", ""))' 2>/dev/null || true)"
    [[ -n "${CPDAPI_TOKEN}" ]]
}

# cpdapi <method> <path> [json body] -> API_CODE, API_BODY
cpdapi() {
    local -a _args=(-sk -X "$1" -H "Authorization: Bearer ${CPDAPI_TOKEN}" -H 'Accept: application/json' -w $'\n%{http_code}')
    (( $# >= 3 )) && _args+=(-H 'Content-Type: application/json' --data "$3")
    local _resp
    _resp="$(curl "${_args[@]}" "${CPDAPI_BASE}$2" || true)"
    API_CODE="${_resp##*$'\n'}"
    API_BODY="${_resp%$'\n'*}"
}

# One path segment or query value, percent-encoded ("/" included).
cpdapi_urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
