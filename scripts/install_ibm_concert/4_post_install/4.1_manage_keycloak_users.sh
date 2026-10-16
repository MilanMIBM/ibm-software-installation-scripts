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
# 4.1 Concert users in Keycloak (idempotent)
# ------------------------------------------------------------------------------
# Users come from configs/concert_config/concert_users.txt, one per line:
#     username:password:role[:email]        role = Admin | User
# --from-htpasswd adds every user from configs/openshift_config/htpasswd_credentials.txt
# (written by src/utilities/redhat_openshift_utils/set_htpasswd_users.sh) with
# role User, so the same people get OpenShift and Concert logins.
#
# Each user is created with IBM's kc-usermgmt; an existing user gets the
# password and role from the file instead. Runs in the runner against the
# Hub's in-cluster Keycloak URL. The users file reaches the runner as a Secret.
# ==============================================================================

concert_product_enabled hub || concert_die "The Hub is remote - manage users on the Hub cluster."

USERS_FILE="${CONCERT_CONFIG_DIR}/concert_users.txt"
HTPASSWD_FILE="${_CP4D_REPO_ROOT}/configs/openshift_config/htpasswd_credentials.txt"
FROM_HTPASSWD=false
for _arg in "$@"; do
    case "${_arg}" in
        --from-htpasswd) FROM_HTPASSWD=true ;;
        --users-file=*)  USERS_FILE="${_arg#*=}" ;;
        *) concert_die "Unknown argument: ${_arg} (--from-htpasswd, --users-file=<path>)" ;;
    esac
done

STAGE="$(concert_private_tmpdir)"
trap 'rm -rf "${STAGE}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
LIST="${STAGE}/concert-users.txt"
: > "${LIST}"
[[ -f "${USERS_FILE}" ]] && grep -vE '^[[:space:]]*(#|$)' "${USERS_FILE}" >> "${LIST}"
if ${FROM_HTPASSWD}; then
    [[ -f "${HTPASSWD_FILE}" ]] || concert_die "${HTPASSWD_FILE} not found - run set_htpasswd_users.sh first."
    grep -vE '^[[:space:]]*(#|$)' "${HTPASSWD_FILE}" | awk -F: 'NF >= 2 {print $1 ":" $2 ":User"}' >> "${LIST}"
fi
[[ -s "${LIST}" ]] || concert_die "No users: create ${USERS_FILE} (username:password:role[:email]) or use --from-htpasswd."
concert_info "$(wc -l < "${LIST}" | tr -d ' ') user(s) to reconcile."

eval "${OC_LOGIN}"

export KC_URL="https://ibm-solis-hub-gw-svc.${PROJECT_CONCERT_HUB}.svc.cluster.local:11443/sys/internal/kc"
export KC_NS="${PROJECT_CONCERT_HUB}"

concert_run --name kc-users --timeout 1800 --env KC_URL --env KC_NS --file "${LIST}" -- __shell__ '
set -u
K=concert-hub/bin/kc-usermgmt
rc=0
while IFS=: read -r u p r e; do
    [ -n "${u}" ] || continue
    r="${r:-User}"
    if "${K}" add-user --kc-url="${KC_URL}" --namespace="${KC_NS}" --username="${u}" --password="${p}" --role="${r}" ${e:+--email="${e}"} >/tmp/kc.out 2>&1; then
        echo "created  ${u} (${r})"
    elif "${K}" update-password --kc-url="${KC_URL}" --namespace="${KC_NS}" --username="${u}" --password="${p}" >/tmp/kc.out 2>&1 \
         && "${K}" update-role --kc-url="${KC_URL}" --namespace="${KC_NS}" --username="${u}" --role="${r}" >/tmp/kc.out 2>&1; then
        echo "updated  ${u} (${r})"
    else
        echo "FAILED   ${u}:"; sed "s/^/    /" /tmp/kc.out; rc=1
    fi
done < /config/files/concert-users.txt
exit ${rc}'
