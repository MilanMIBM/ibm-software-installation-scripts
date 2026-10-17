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
# 5.3 Turbonomic administrator and license (IBM's Optimize step 2, first half)
# ------------------------------------------------------------------------------
# IBM's Optimize page creates the administrator ("the installation doesn't
# create one") and adds the license in Turbonomic's UI before the Concert
# patch. This does the same through Turbonomic's REST API, over an
# `oc port-forward` to its nginx, so nothing is exposed before an admin exists:
#   POST /api/v3/login       200 -> the administrator exists already
#   POST /api/v3/initAdmin   first run (the call IBM's data access layer page
#                            uses to initialise TurboLite)
#   POST /api/v3/licenses    multipart "file" (Turbonomic API reference)
# Each license file is added once: its SHA-256 is recorded on the Xl.
#
#   ./5.3_initialize_turbonomic.sh [--license=<file>]
#
# Run it before 5.4 (the wrapper does): IBM adds the license while Turbonomic
# is still plain, and 5.4 turns on Concert's header authentication for the API.
# The password goes to curl on stdin, never on a command line.
# ==============================================================================

LICENSE_ARG=""
for _arg in "$@"; do
    case "${_arg}" in
        --license=*) LICENSE_ARG="${_arg#*=}" ;;
        *) concert_die "Unknown argument: ${_arg}" ;;
    esac
done

concert_product_enabled optimize || { concert_info "Optimize is not selected - nothing to do."; exit 0; }
concert_require_vars CONCERT_OPTIMIZE_ADMIN_USERNAME CONCERT_OPTIMIZE_ADMIN_PASSWORD
LICENSE="$(concert_optimize_license_path "${LICENSE_ARG}")"
[[ -z "${LICENSE}" || -f "${LICENSE}" ]] || concert_die "License file not found: ${LICENSE}"

eval "${OC_LOGIN}"
NS="$(concert_optimize_namespace)"
USER_NAME="${CONCERT_OPTIMIZE_ADMIN_USERNAME}"
oc get service nginx -n "${NS}" >/dev/null 2>&1 \
    || concert_die "No Turbonomic nginx service in ${NS} - run 5.2_deploy_turbonomic.sh first."

# --- Private API endpoint ---------------------------------------------------------
STAGE="$(concert_private_tmpdir)"
PF_PID=""
trap '[[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null; rm -rf "${STAGE}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
oc port-forward -n "${NS}" service/nginx "${PORT}:443" >"${STAGE}/port-forward.log" 2>&1 &
PF_PID=$!
API="https://127.0.0.1:${PORT}/api/v3"
concert_wait_for 90 "port-forward to ${NS}/nginx" curl -sk -o /dev/null --max-time 5 "https://127.0.0.1:${PORT}/" \
    || concert_die "Port-forward failed: $(<"${STAGE}/port-forward.log")"

# _login [<cookie jar>]: HTTP status of a login as the configured administrator
_login() {
    local -a jar=()
    [[ -n "${1:-}" ]] && jar=(-c "$1")
    print -rn -- "${CONCERT_OPTIMIZE_ADMIN_PASSWORD}" | curl -sk --max-time 30 -o /dev/null -w '%{http_code}' "${jar[@]}" \
        --data-urlencode "username=${USER_NAME}" --data-urlencode password@- "${API}/login" || true
}

# --- Administrator ----------------------------------------------------------------
if [[ "$(_login)" == 200 ]]; then
    concert_info "Turbonomic administrator ${USER_NAME} exists; the configured password works."
else
    concert_info "Creating the Turbonomic administrator ${USER_NAME} (initAdmin)"
    init_code="$(print -rn -- "${CONCERT_OPTIMIZE_ADMIN_PASSWORD}" | curl -sk --max-time 60 -o "${STAGE}/init.out" -w '%{http_code}' \
        --data-urlencode "username=${USER_NAME}" --data-urlencode password@- "${API}/initAdmin" || true)"
    login_code=""
    for _try in 1 2 3 4 5 6; do
        login_code="$(_login)"
        [[ "${login_code}" == 200 ]] && break
        sleep 10
    done
    if [[ "${login_code}" != 200 ]]; then
        concert_die "Could not create or log in as ${USER_NAME} (initAdmin HTTP ${init_code}, login HTTP ${login_code}): $(head -c 300 "${STAGE}/init.out" 2>/dev/null). If Turbonomic already has an administrator with another password, set CONCERT_OPTIMIZE_ADMIN_PASSWORD to it."
    fi
    concert_info "Administrator ${USER_NAME} created."
fi

# --- License ----------------------------------------------------------------------
if [[ -z "${LICENSE}" ]]; then
    concert_warn "No Turbonomic license (CONCERT_OPTIMIZE_LICENSE_FILE or --license=) - Optimize stays unlicensed until you run: ./5.3_initialize_turbonomic.sh --license=<file>"
    concert_info "Next: 5.4_enable_concert_gateway.sh"
    exit 0
fi

LICENSE_SHA="$(concert_sha256 "${LICENSE}")"
if [[ -z "${LICENSE_ARG}" && "$(concert_optimize_xl_annotation "${CONCERT_OPTIMIZE_LICENSE_ANNOTATION}")" == "${LICENSE_SHA}" ]]; then
    concert_info "License ${LICENSE:t} was added before - skipping (pass --license=<file> to add it again)."
    concert_info "Next: 5.4_enable_concert_gateway.sh"
    exit 0
fi

JAR="${STAGE}/cookies"
[[ "$(_login "${JAR}")" == 200 ]] || concert_die "Login as ${USER_NAME} failed - cannot add the license."
code="$(curl -sk --max-time 120 -b "${JAR}" -o "${STAGE}/license.out" -w '%{http_code}' -F "file=@${LICENSE}" "${API}/licenses" || true)"
[[ "${code}" == 200 ]] || concert_die "Adding license ${LICENSE:t} failed (HTTP ${code}): $(head -c 400 "${STAGE}/license.out" 2>/dev/null)"
oc annotate xl "${CONCERT_OPTIMIZE_XL}" -n "${NS}" "${CONCERT_OPTIMIZE_LICENSE_ANNOTATION}=${LICENSE_SHA}" --overwrite >/dev/null
concert_info "License ${LICENSE:t} added."

summary="$(curl -sk --max-time 30 -b "${JAR}" "${API}/licenses/summary" || true)"
[[ -n "${summary}" ]] && concert_info "License summary: ${summary[1,400]}"
concert_info "Next: 5.4_enable_concert_gateway.sh"
