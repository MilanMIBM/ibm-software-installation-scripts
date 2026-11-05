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
Find every Software Hub instance on the cluster and add it to Control Center. Runs at
the end of the sub-install when AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES is true.
Safe to re-run: what is already registered is left alone.

  autodetect_instances.sh [--dry-run] [--account NAME] [--rotate-api-keys]

In order: registers and verifies the cluster, creates the account, makes everyone with
Control Center access an administrator of it, then validates and adds each instance. Instances that are not Completed, or
have no route, are skipped with a warning.

Options:
  --dry-run          Only show what was detected; changes nothing
  --account NAME     Account for the instances (default:
                     CONTROL_AUTODETECT_ACCOUNT_NAME)
  --rotate-api-keys  Generate a new API key for instances with no known key. This
                     revokes that admin's current key, so anything using it stops
                     working. Same as CONTROL_AUTODETECT_ROTATE_API_KEYS=true.

The instance in cpd_vars.sh uses CPD_APIKEY from cpd_instance_details.sh. Without
--rotate-api-keys, any other instance is skipped and named for register_instance.sh.
USAGE
}

DRY_RUN=false
ACCOUNT="${CONTROL_AUTODETECT_ACCOUNT_NAME:-software-hub-instances}"
ROTATE="${CONTROL_AUTODETECT_ROTATE_API_KEYS:-false}"
while (( $# )); do
    case "$1" in
        --dry-run)         DRY_RUN=true; shift ;;
        --account)         h_need_value "$1" "${2:-}"; ACCOUNT="$2"; shift 2 ;;
        --rotate-api-keys) ROTATE=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) usage >&2; h_die "Unknown option: $1" ;;
    esac
done

# The instances run on the Software Hub cluster, whichever cluster Control Center is on.
eval "${OC_LOGIN:-${CONTROL_OC_LOGIN}}"
[[ -f "${ENV_TARGET_FILE:h:h}/cpd_instance_details.sh" ]] && source "${ENV_TARGET_FILE:h:h}/cpd_instance_details.sh"

# A new key for an instance's admin. Runs in a subshell, so the Control Center session
# in this one survives; prints the key on stdout, and nothing when it fails.
rotated_key() {   # <project> <url>
    local user password
    user="$(oc get secret ibm-iam-bindinfo-platform-auth-idp-credentials -n "$1" -o jsonpath='{.data.admin_username}' 2>/dev/null | base64 -d || true)"
    password="$(oc get secret ibm-iam-bindinfo-platform-auth-idp-credentials -n "$1" -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d || true)"
    if [[ -z "${password}" ]]; then
        user=admin
        password="$(oc get secret admin-user-details -n "$1" -o jsonpath='{.data.initial_admin_password}' 2>/dev/null | base64 -d || true)"
    fi
    [[ -n "${password}" ]] || return 1
    cpdapi_login "$2" "${user}" password "${password}" || return 1
    cpdapi GET "/usermgmt/v1/user/apiKey"
    swhcc_api_ok || return 1
    print -r -- "${user}"$'\t'"$(print -r -- "${API_BODY}" | jq -r '.apiKey // empty')"
}

# Track an instance against what it has reserved, rounded up. This is what fills in
# the account page; it limits nothing. Runs for new and registered instances alike.
apply_instance_quota() {   # <project> <instance id>
    [[ "${CONTROL_AUTODETECT_INSTANCE_QUOTA:-reserved}" == reserved ]] || return 0
    swhcc_reserved_capacity "$1"
    h_info "'$1' quota: ${SWHCC_CPU} vCPU, ${SWHCC_MEMORY_GI} Gi memory"
    swhcc_set_instance_quota "$2" "${SWHCC_CPU}" "${SWHCC_MEMORY_GI}"
    swhcc_api_ok || h_warn "Could not set the quota for '$1' ($(swhcc_api_error))."
}

DETECTED=("${(@f)$(swhcc_detect_instances)}")
[[ -n "${DETECTED[1]:-}" ]] || { h_info "No Software Hub instances found on this cluster."; exit 0; }

h_info "Detected ${#DETECTED} Software Hub instance(s):"
for line in "${DETECTED[@]}"; do
    h_info "  ${line//$'\t'/  }"
done
if [[ "${DRY_RUN}" == true ]]; then
    h_info "Dry run: nothing changed."
    exit 0
fi

swhcc_api_login
swhcc_cluster_facts
swhcc_ensure_cluster "Added by autodetect_instances.sh"
if ! swhcc_wait_cluster_verified "${CONTROL_AUTODETECT_VERIFY_WAIT_SECONDS:-600}"; then
    h_error "The cluster is not verified yet. Finish the approval above, then re-run this script."
    exit 1
fi

# By default the accounts split the whole cluster, so Control Center shows usage,
# requests and limits as a share of it: the other account gets what non-Software Hub
# workloads have reserved, and this one the rest. reserved sizes this one to the
# instances instead. Explicit CPU and memory values win over both.
OTHER_ACCOUNT="${CONTROL_AUTODETECT_OTHER_ACCOUNT_NAME-other-reserved-workloads}"
OTHER_ID=""; OTHER_CPU=0; OTHER_MEMORY=0; GPU=0
SWHCC_ACCOUNT_ID=""; swhcc_find_account "${ACCOUNT}" || true
ACCOUNT_ID="${SWHCC_ACCOUNT_ID}"
if [[ -n "${OTHER_ACCOUNT}" ]]; then
    SWHCC_ACCOUNT_ID=""; swhcc_find_account "${OTHER_ACCOUNT}" || true
    OTHER_ID="${SWHCC_ACCOUNT_ID}"
    swhcc_other_reserved_capacity
    OTHER_CPU="${SWHCC_OTHER_CPU}"; OTHER_MEMORY="${SWHCC_OTHER_MEMORY_GI}"
fi
swhcc_cluster_capacity "${SWHCC_CLUSTER_ID}" "${ACCOUNT_ID}" "${OTHER_ID}"
HELD_CPU="${SWHCC_FIRST_CPU}"; HELD_MEMORY="${SWHCC_FIRST_MEMORY_GI}"
if [[ "${CONTROL_AUTODETECT_ACCOUNT_ALLOCATION:-cluster}" == reserved ]]; then
    swhcc_reserved_capacity "${DETECTED[@]%%$'\t'*}"
else
    GPU="${SWHCC_GPU}"
    SWHCC_CPU=$(( SWHCC_CPU - OTHER_CPU ))
    SWHCC_MEMORY_GI=$(( SWHCC_MEMORY_GI - OTHER_MEMORY ))
fi
CPU="${CONTROL_AUTODETECT_ACCOUNT_CPU:-${SWHCC_CPU}}"
MEMORY="${CONTROL_AUTODETECT_ACCOUNT_MEMORY_GI:-${SWHCC_MEMORY_GI}}"
(( CPU >= 0 && MEMORY >= 0 )) || h_die "Other workloads have reserved more than the cluster has left."

# Shrink first and grow last, so the accounts never add up to more than the cluster.
if [[ -n "${ACCOUNT_ID}" ]]; then
    swhcc_allocate "${ACCOUNT_ID}" "${SWHCC_CLUSTER_ID}" $(( CPU < HELD_CPU ? CPU : HELD_CPU )) \
        $(( MEMORY < HELD_MEMORY ? MEMORY : HELD_MEMORY )) "${GPU}"
fi
if [[ -n "${OTHER_ACCOUNT}" ]]; then
    swhcc_ensure_account "${OTHER_ACCOUNT}" "Reserved by workloads outside Software Hub, such as storage and monitoring" \
        "${SWHCC_CLUSTER_ID}" "${OTHER_CPU}" "${OTHER_MEMORY}" 0 OTHER_WL
    OTHER_ID="${SWHCC_ACCOUNT_ID}"
    h_info "Account '${OTHER_ACCOUNT}' allocation: ${OTHER_CPU} vCPU, ${OTHER_MEMORY} Gi memory"
    swhcc_allocate "${OTHER_ID}" "${SWHCC_CLUSTER_ID}" "${OTHER_CPU}" "${OTHER_MEMORY}" 0
fi
swhcc_ensure_account "${ACCOUNT}" "Software Hub instances found by autodetect_instances.sh" \
    "${SWHCC_CLUSTER_ID}" "${CPU}" "${MEMORY}" "${GPU}"
ACCOUNT_ID="${SWHCC_ACCOUNT_ID}"
h_info "Account '${ACCOUNT}' allocation: ${CPU} vCPU, ${MEMORY} Gi memory, ${GPU} GPU"
swhcc_allocate "${ACCOUNT_ID}" "${SWHCC_CLUSTER_ID}" "${CPU}" "${MEMORY}" "${GPU}"
swhcc_ensure_instance_rights
for account_id in "${ACCOUNT_ID}" "${OTHER_ID}"; do
    [[ -z "${account_id}" ]] || swhcc_sync_account_admins "${account_id}" \
        || h_warn "Some users or groups could not be made account administrators."
done

added=0; present=0; skipped=0; failed=0
for line in "${DETECTED[@]}"; do
    IFS=$'\t' read -r project version zen_status url <<< "${line}"
    if [[ -z "${url}" || "${zen_status}" != Completed ]]; then
        h_warn "Skipping '${project}': status ${zen_status}, route ${url:-missing}."
        (( ++skipped )); continue
    fi
    if swhcc_find_instance "${url}"; then
        h_info "'${project}' is already registered."
        apply_instance_quota "${project}" "${REPLY}"
        (( ++present )); continue
    fi

    user=""; key=""
    if [[ "${url}" == "${CPD_URL%/}" && -n "${CPD_APIKEY:-}" ]]; then
        user="${CPD_USERNAME:-cpadmin}"; key="${CPD_APIKEY}"
    elif h_is_true "${ROTATE}"; then
        h_warn "Generating a new API key for '${project}': its admin's current key stops working."
        credentials="$(rotated_key "${project}" "${url}" || true)"
        user="${credentials%%$'\t'*}"; key="${credentials#*$'\t'}"
    fi
    if [[ -z "${key}" ]]; then
        h_warn "Skipping '${project}': no API key known. Add it with:"
        h_warn "  register_instance.sh --url ${url} --account ${ACCOUNT} --username <user> --api-key-env <VAR>"
        (( ++skipped )); continue
    fi

    if swhcc_register_instance "${project}" "${url}" "${user}" "${key}" "${ACCOUNT_ID}"; then
        h_info "Added '${project}' to account '${ACCOUNT}'."
        swhcc_find_instance "${url}" && apply_instance_quota "${project}" "${REPLY}"
        (( ++added ))
    else
        (( ++failed ))
    fi
done

h_info "Instances: ${added} added, ${present} already registered, ${skipped} skipped, ${failed} failed."
(( failed == 0 ))
