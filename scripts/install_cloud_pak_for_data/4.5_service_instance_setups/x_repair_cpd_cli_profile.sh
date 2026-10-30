#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# x_repair_cpd_cli_profile.sh - make the cpd-cli profile point at THIS cluster
# -----------------------------------------------------------------------------
# Checks the profile first and changes nothing when it is healthy:
#   ok           profile URL = the live `cpd` route and an authenticated call works
#   missing      no such profile                         -> repaired
#   stale        profile URL is another cluster           -> repaired
#   auth-failed  URL right, but the call is refused       -> repaired
# Repair = `cpd-cli config users set` + `cpd-cli config profiles set` (the
# 4.2_cpd_profile.sh commands) with the URL taken from the live route, never from
# a possibly stale CPD_URL, and the API key CPD_APIKEY (cpd-cli accepts no
# password). If CPD_APIKEY does not authenticate against the live URL it stops and
# points at 3.3.1_get_instance_creds.sh; it never mints a new key (that would
# silently invalidate the old one).
#
# Never runs `cpd-cli manage` (that recreates the olm-utils container); logs in
# with OC_LOGIN only. The service-instance manager TUI calls this script.
#
# Usage:
#   ./x_repair_cpd_cli_profile.sh              # check, repair only if needed
#   ./x_repair_cpd_cli_profile.sh --check      # check only; exit 0 ok, 10 missing/stale, 11 auth-failed
#   ./x_repair_cpd_cli_profile.sh --profile NAME
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

CHECK_ONLY=false
PROFILE="${CPD_PROFILE_NAME:-${CPD_USERNAME:-cpadmin}-profile}"
while (( $# )); do
    case "$1" in
        --check) CHECK_ONLY=true ;;
        --profile) h_need_value "$1" "${2:-}"; PROFILE="$2"; shift ;;
        -h|--help) sed -n '5,28p' "$0"; exit 0 ;;
        *) h_die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

h_missing_vars PROJECT_CPD_INST_OPERANDS || h_die "not set: ${REPLY} (cpd_vars.sh)"
CPDCONFIG="${CPDCONFIG:-${HOME}/.cpd-cli/config}"

if ! oc whoami >/dev/null 2>&1; then
    [[ -n "${OC_LOGIN:-}" ]] || h_die "not logged in to the cluster and OC_LOGIN is not set"
    eval "${OC_LOGIN}" >/dev/null
fi
LIVE_HOST="$(oc get route cpd -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "${LIVE_HOST}" ]] || h_die "no route 'cpd' in ${PROJECT_CPD_INST_OPERANDS}; is Software Hub installed?"
LIVE_URL="https://${LIVE_HOST}"

# The profile's url / user from the cpd-cli config (YAML; no secrets read).
profile_field() {   # <field: url|user>
    [[ -f "${CPDCONFIG}" ]] || return 0
    awk -v want="${PROFILE}" -v field="$1" '
        /^profiles:/ { inp = 1; next }
        inp && /^[a-z]/ { inp = 0 }
        inp && $1 == "-" && $2 == "name:" { cur = $3; next }
        inp && cur == want && $1 == field ":" { print $2; exit }
    ' "${CPDCONFIG}"
}

STATE=""
check_profile() {
    local url
    url="$(profile_field url)"
    if [[ -z "${url}" ]]; then STATE=missing; return 10; fi
    if [[ "${url%/}" != "${LIVE_URL}" ]]; then STATE=stale; return 10; fi
    if ! cpd-cli service-instance list --profile="${PROFILE}" --exclude-user-count -o json >/dev/null 2>&1; then
        STATE=auth-failed; return 11
    fi
    STATE=ok
    return 0
}

rc=0; check_profile || rc=$?
case "${STATE}" in
    ok)          h_info "profile ${PROFILE}: ok (${LIVE_URL})"; exit 0 ;;
    missing)     h_warn "profile ${PROFILE}: missing" ;;
    stale)       h_warn "profile ${PROFILE}: stale (points at $(profile_field url), cluster is ${LIVE_URL})" ;;
    auth-failed) h_warn "profile ${PROFILE}: the cluster refuses its credentials" ;;
esac
${CHECK_ONLY} && exit "${rc}"

# --- repair -------------------------------------------------------------------
h_missing_vars CPD_USERNAME CPD_APIKEY || h_die "not set: ${REPLY} (run 3_install_softwarehub/3.3.1_get_instance_creds.sh)"
# The key goes to curl on stdin (printf is a builtin), never on a command line.
code="$(printf '{"username":"%s","api_key":"%s"}' "${CPD_USERNAME}" "${CPD_APIKEY}" \
    | curl -sk -o /dev/null -w '%{http_code}' -X POST "${LIVE_URL}/icp4d-api/v1/authorize" \
        -H 'Content-Type: application/json' --data @- || true)"
if [[ "${code}" != "200" ]]; then
    h_die "CPD_APIKEY for ${CPD_USERNAME} does not authenticate against ${LIVE_URL} (HTTP ${code}). Refresh it with 3_install_softwarehub/3.3.1_get_instance_creds.sh, then re-run this script."
fi

USER_ENTRY="$(profile_field user)"
USER_ENTRY="${USER_ENTRY:-${CPD_USERNAME}}"
h_info "repairing profile ${PROFILE}: user entry ${USER_ENTRY}, url ${LIVE_URL}"
if ! out="$(cpd-cli config users set "${USER_ENTRY}" --username="${CPD_USERNAME}" --apikey="${CPD_APIKEY}" 2>&1)"; then
    h_die "cpd-cli config users set failed: ${out//${CPD_APIKEY}/****}"
fi
if ! out="$(cpd-cli config profiles set "${PROFILE}" --user="${USER_ENTRY}" --url="${LIVE_URL}" 2>&1)"; then
    h_die "cpd-cli config profiles set failed: ${out}"
fi

rc=0; check_profile || rc=$?
if [[ "${STATE}" == ok ]]; then
    h_info "profile ${PROFILE}: repaired (${LIVE_URL})"
    exit 0
fi
h_die "profile ${PROFILE}: still ${STATE} after the repair"
