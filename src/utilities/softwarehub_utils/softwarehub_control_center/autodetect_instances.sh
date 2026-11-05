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

In order: registers the cluster, waits for the one browser approval, creates the
account, then validates and adds each instance. Instances that are not Completed, or
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

CPU="${CONTROL_AUTODETECT_ACCOUNT_CPU:-}"
MEMORY="${CONTROL_AUTODETECT_ACCOUNT_MEMORY_GI:-}"
if [[ -z "${CPU}" || -z "${MEMORY}" ]]; then
    swhcc_worker_capacity
    : "${CPU:=${SWHCC_CPU}}"
    : "${MEMORY:=${SWHCC_MEMORY_GI}}"
fi
swhcc_ensure_account "${ACCOUNT}" "Software Hub instances found by autodetect_instances.sh" \
    "${SWHCC_CLUSTER_ID}" "${CPU}" "${MEMORY}" 0
ACCOUNT_ID="${SWHCC_ACCOUNT_ID}"

added=0; present=0; skipped=0; failed=0
for line in "${DETECTED[@]}"; do
    IFS=$'\t' read -r project version zen_status url <<< "${line}"
    if [[ -z "${url}" || "${zen_status}" != Completed ]]; then
        h_warn "Skipping '${project}': status ${zen_status}, route ${url:-missing}."
        (( ++skipped )); continue
    fi
    if swhcc_find_instance "${url}"; then
        h_info "'${project}' is already registered."
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
        (( ++added ))
    else
        (( ++failed ))
    fi
done

h_info "Instances: ${added} added, ${present} already registered, ${skipped} skipped, ${failed} failed."
(( failed == 0 ))
