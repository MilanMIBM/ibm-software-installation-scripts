#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_api_helpers.sh"

usage() {
    cat <<'USAGE'
Give OpenShift cluster-admins, or a list of users, roles in Control Center.

  toggle_cluster_admins.sh [on|off|status] [--users LIST] [--roles LIST] [--dry-run]

With no argument it follows CONTROL_ADD_CLUSTER_ADMINS, as the full install does:
it grants when true and does nothing when false.

  on       Grant the roles. Without --users, also saves CONTROL_ADD_CLUSTER_ADMINS="true".
  off      Remove the roles, keeping users and their other roles. Without --users,
           also saves CONTROL_ADD_CLUSTER_ADMINS="false".
  status   Show who is covered and what roles they have. Changes nothing.

Options:
  --users LIST  Exactly these users, comma-separated (default: CONTROL_ADMIN_USERS,
                else every cluster-admin on the Control Center cluster)
  --roles LIST  Roles, comma-separated (default: CONTROL_ADMIN_ROLES, else
                zen_administrator_role,zen_resource_group_admin_role)
  --dry-run     Show what would change

Cluster-admins come from the role bindings, directly or through OpenShift groups, so
every identity provider counts, including people who have not signed in yet.
Control Center's sign-in user is never changed.
USAGE
}

ACTION=""; USERS_ARG=""; ROLES_ARG=""; DRY_RUN=false
while (( $# )); do
    case "$1" in
        on|off|status) ACTION="$1"; shift ;;
        --users)       h_need_value "$1" "${2:-}"; USERS_ARG="$2"; shift 2 ;;
        --roles)       h_need_value "$1" "${2:-}"; ROLES_ARG="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) usage >&2; h_die "Unknown option: $1" ;;
    esac
done

if [[ -z "${ACTION}" ]]; then
    if ! h_is_true "${CONTROL_ADD_CLUSTER_ADMINS:-true}"; then
        h_info "CONTROL_ADD_CLUSTER_ADMINS is off - nothing to do."
        exit 0
    fi
    ACTION=on
    SAVE=false
else
    [[ -z "${USERS_ARG}" && "${ACTION}" != status ]] && SAVE=true || SAVE=false
fi

ROLES=(${(s:,:)${${ROLES_ARG:-${CONTROL_ADMIN_ROLES:-zen_administrator_role,zen_resource_group_admin_role}}// /}})
(( ${#ROLES} )) || h_die "No roles given."

swhcc_oc_login
swhcc_api_login
swhcc_check_roles "${ROLES[@]}"

SPECIFIC="${USERS_ARG:-${CONTROL_ADMIN_USERS:-}}"
if [[ -n "${SPECIFIC}" ]]; then
    USERS=(${(s:,:)${SPECIFIC// /}})
    SOURCE="the listed users"
else
    USERS=("${(@f)$(swhcc_cluster_admin_users)}")
    USERS=(${USERS:#})
    SOURCE="OpenShift cluster-admins"
fi
EXCLUDED=(${(s:,:)${${CONTROL_ADMIN_EXCLUDE_USERS:-}// /}} "${CONTROL_CENTER_USERNAME}")
USERS=(${USERS:|EXCLUDED})

h_info "${ACTION}: ${#USERS} of ${SOURCE}, roles ${(j:, :)ROLES}"
[[ "${DRY_RUN}" == true ]] && h_info "Dry run: nothing changes."

if [[ "${ACTION}" == status ]]; then
    for user in "${USERS[@]}"; do
        cpdapi GET "/usermgmt/v1/user/$(cpdapi_urlencode "${user}")"
        if swhcc_api_ok; then
            h_info "  ${user}: $(print -r -- "${API_BODY}" | jq -r '(.user_roles // []) | join(", ")')"
        else
            h_info "  ${user}: not in Control Center (HTTP ${API_CODE})"
        fi
    done
    exit 0
fi

[[ "${ACTION}" == on ]] && swhcc_warn_openshift_auth

failed=0
for user in "${USERS[@]}"; do
    if [[ "${ACTION}" == on ]]; then
        swhcc_grant_roles "${user}" "${ROLES[@]}" || (( ++failed ))
    else
        swhcc_revoke_roles "${user}" "${ROLES[@]}" || (( ++failed ))
    fi
done

(( failed == 0 )) || h_die "${failed} user(s) could not be updated."

if [[ "${SAVE}" == true && "${DRY_RUN}" != true ]]; then
    [[ "${ACTION}" == on ]] && VALUE=true || VALUE=false
    if grep -q '^export CONTROL_ADD_CLUSTER_ADMINS=' "${ENV_TARGET_FILE}"; then
        VALUE="${VALUE}" perl -pi -e 's/^export CONTROL_ADD_CLUSTER_ADMINS=.*/export CONTROL_ADD_CLUSTER_ADMINS="$ENV{VALUE}"/' "${ENV_TARGET_FILE}"
    else
        print -r -- "export CONTROL_ADD_CLUSTER_ADMINS=\"${VALUE}\"" >> "${ENV_TARGET_FILE}"
    fi
    h_info "CONTROL_ADD_CLUSTER_ADMINS is now \"${VALUE}\" in ${ENV_TARGET_FILE}"
fi

h_info "Done."
