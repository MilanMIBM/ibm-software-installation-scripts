#!/bin/zsh
# =============================================================================
# swhub_control_center_api_helpers.sh - Control Center clusters, accounts, instances
# -----------------------------------------------------------------------------
# IBM documents these tasks as web client steps only. The calls below are the ones
# the web client makes, taken from the zen-core and zen-core-api images (zen 6.10.8).
# They are not a published API, so a later release can change them. "Account" in the
# web client is "resource group" in the API, and "instance" is "namespace".
#
# Must be SOURCED, after env_bootstrap.sh. Bodies holding secrets go through
# swhcc_api_secret, so they never show up in the process list.
# =============================================================================

source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/cpd_api_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_helpers.sh"

SWHCC_PLATFORM="/zen-data/v1/management/platform"
SWHCC_WATCHDOG="/zen-watchdog/v1/adminhubmon"

# Sign in to Control Center with the login 1.3 saved.
swhcc_api_login() {
    h_missing_vars CONTROL_CENTER_URL CONTROL_CENTER_USERNAME CONTROL_CENTER_PASSWORD \
        || h_die "Not set: ${REPLY}. Run 1.3_swhub_control_center_get_instance_details.sh first."
    cpdapi_login "${CONTROL_CENTER_URL}" "${CONTROL_CENTER_USERNAME}" password "${CONTROL_CENTER_PASSWORD}" \
        || h_die "Could not sign in to ${CONTROL_CENTER_URL} as ${CONTROL_CENTER_USERNAME} (HTTP ${API_CODE})."
}

swhcc_api_ok() { [[ "${API_CODE:-}" == 2* ]]; }

# The API's own error text, for messages.
swhcc_api_error() {
    local detail
    detail="$(print -r -- "${API_BODY:-}" | jq -r '[.errors[]? | .message // .code] | join("; ")' 2>/dev/null || true)"
    print -r -- "HTTP ${API_CODE:-?}${detail:+: ${detail}}"
}

# cpdapi with the body in a private file: curl reads it as --data @file.
swhcc_api_secret() {   # <method> <path> <json>
    local body; body="$(mktemp)"
    print -r -- "$3" > "${body}"
    cpdapi "$1" "$2" "@${body}"
    rm -f "${body}"
}

# --- Clusters -----------------------------------------------------------------

# Facts about the cluster oc is logged in to: SWHCC_API_ENDPOINT, SWHCC_OAUTH_ENDPOINT,
# SWHCC_CLUSTER_NAME (CONTROL_CLUSTER_DISPLAY_NAME, else the name in the API address).
swhcc_cluster_facts() {
    SWHCC_API_ENDPOINT="$(oc whoami --show-server)"
    SWHCC_API_ENDPOINT="${SWHCC_API_ENDPOINT%/}"
    SWHCC_OAUTH_ENDPOINT="https://$(oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}')"
    local host="${${SWHCC_API_ENDPOINT#https://}%%:*}"
    host="${host#api.}"
    SWHCC_CLUSTER_NAME="${CONTROL_CLUSTER_DISPLAY_NAME:-${host%%.*}}"
}

# Sets SWHCC_CLUSTER_ID and SWHCC_CLUSTER_STATUS; fails when it is not registered.
swhcc_find_cluster() {   # <api endpoint>
    SWHCC_CLUSTER_ID=""; SWHCC_CLUSTER_STATUS=""
    cpdapi GET "${SWHCC_PLATFORM}/clusters?include_unverified=true"
    swhcc_api_ok || h_die "Could not list clusters ($(swhcc_api_error))."
    local found
    found="$(print -r -- "${API_BODY}" | jq -r --arg url "$1" \
        '[.clusters[]? | select((.cluster_connection.api_endpoint // "" | rtrimstr("/")) == $url)][0]
         | if . == null then "" else "\(.cluster_id) \(.verification_status // "")" end')"
    [[ -n "${found}" ]] || return 1
    SWHCC_CLUSTER_ID="${found%% *}"
    SWHCC_CLUSTER_STATUS="${found#* }"
}

# Register the cluster from swhcc_cluster_facts unless it already is, then set
# SWHCC_CLUSTER_ID and SWHCC_CLUSTER_STATUS. The client is the one from step 1.4.
swhcc_ensure_cluster() {   # [description]
    swhcc_find_cluster "${SWHCC_API_ENDPOINT}" && return 0
    h_missing_vars CONTROL_OAUTH_CLIENT_ID CONTROL_OAUTH_SECRET || h_die "Not set: ${REPLY}."
    local body
    body="$(NAME="${SWHCC_CLUSTER_NAME}" DESC="${1:-}" API="${SWHCC_API_ENDPOINT}" OAUTH="${SWHCC_OAUTH_ENDPOINT}" \
        jq -n '{cluster_name: env.NAME, description: env.DESC,
                cluster_connection: {api_endpoint: env.API, oauth_endpoint: env.OAUTH},
                cluster_credentials: {client_id: env.CONTROL_OAUTH_CLIENT_ID, client_secret: env.CONTROL_OAUTH_SECRET}}')"
    h_info "Registering cluster '${SWHCC_CLUSTER_NAME}' (${SWHCC_API_ENDPOINT})"
    swhcc_api_secret POST "${SWHCC_PLATFORM}/clusters?validate=true" "${body}"
    swhcc_api_ok || h_die "Control Center rejected the cluster ($(swhcc_api_error)). Check the OAuth client from step 1.4."
    # The web client validates, then saves; validating alone may already record it.
    if ! swhcc_find_cluster "${SWHCC_API_ENDPOINT}"; then
        swhcc_api_secret POST "${SWHCC_PLATFORM}/clusters" "${body}"
        swhcc_api_ok || h_die "Could not register the cluster ($(swhcc_api_error))."
        swhcc_find_cluster "${SWHCC_API_ENDPOINT}" || h_die "The cluster was accepted but is not listed."
    fi
}

swhcc_cluster_verified() {
    swhcc_find_cluster "${SWHCC_API_ENDPOINT}" && [[ "${SWHCC_CLUSTER_STATUS}" == verified ]]
}

# The browser step: the OAuth client uses grantMethod: prompt, so a person has to
# approve the cluster-reader access. Sets REPLY to the page to open.
swhcc_cluster_oauth_url() {   # <cluster id>
    local invoker host
    invoker="$(cpdapi_urlencode 'clusters?action=register')"
    host="$(cpdapi_urlencode "${CONTROL_CENTER_URL%/}")"
    cpdapi GET "${SWHCC_PLATFORM}/clusters/$1/oauth-authz-endpoints?invoker_uri=${invoker}&swh_host=${host}"
    swhcc_api_ok || h_die "Could not get the OAuth page ($(swhcc_api_error))."
    REPLY="$(print -r -- "${API_BODY}" | jq -r '.oauth_authz_url // empty')"
    [[ -n "${REPLY}" ]] || h_die "Control Center returned no OAuth page."
}

# Print the browser step, then wait for it. Fails if nobody approves in time.
swhcc_wait_cluster_verified() {   # <timeout seconds>
    swhcc_cluster_verified && return 0
    swhcc_cluster_oauth_url "${SWHCC_CLUSTER_ID}"
    h_info "One manual step: approve Control Center's read access to this cluster."
    h_info "  1. Sign in to ${CONTROL_CENTER_URL} in your browser."
    h_info "  2. In that browser, open: ${REPLY}"
    h_info "  3. Log in to OpenShift and click 'Allow selected permissions'."
    (( $1 > 0 )) || return 1
    h_wait_for "$1" "the cluster to be verified" swhcc_cluster_verified
}

# Worker allocatable capacity: SWHCC_CPU (whole cores), SWHCC_MEMORY_GI (whole Gi).
swhcc_worker_capacity() {
    local totals
    totals="$(oc get nodes -l node-role.kubernetes.io/worker -o json | python3 -c '
import json, sys
UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "K": 10**3, "M": 10**6, "G": 10**9, "T": 10**12}
def cores(v): return float(v[:-1]) / 1000 if v.endswith("m") else float(v)
def size(v):
    for unit, factor in UNITS.items():
        if v.endswith(unit): return float(v[:-len(unit)]) * factor
    return float(v)
nodes = [n["status"]["allocatable"] for n in json.load(sys.stdin)["items"]]
print(int(sum(cores(n["cpu"]) for n in nodes)), int(sum(size(n["memory"]) for n in nodes) / 2**30))')"
    SWHCC_CPU="${totals%% *}"
    SWHCC_MEMORY_GI="${totals##* }"
}

# --- Accounts -----------------------------------------------------------------

# Sets SWHCC_ACCOUNT_ID and SWHCC_ACCOUNT_CLUSTERS; fails when there is none by that name.
swhcc_find_account() {   # <name>
    SWHCC_ACCOUNT_ID=""; SWHCC_ACCOUNT_CLUSTERS=""
    cpdapi GET "${SWHCC_PLATFORM}/resource_groups?include_clusters=true&resource_group_name=$(cpdapi_urlencode "$1")"
    swhcc_api_ok || h_die "Could not list accounts ($(swhcc_api_error))."
    SWHCC_ACCOUNT_ID="$(print -r -- "${API_BODY}" | jq -r --arg name "$1" \
        '[.resource_groups[]? | select(.resource_group_name == $name)][0].resource_group_id // empty')"
    [[ -n "${SWHCC_ACCOUNT_ID}" ]] || return 1
    SWHCC_ACCOUNT_CLUSTERS="$(print -r -- "${API_BODY}" | jq -r --arg name "$1" \
        '[.resource_groups[]? | select(.resource_group_name == $name)][0].clusters // [] | map(.cluster_id) | join(" ")')"
}

# Give the account resources on a cluster. CPU in cores, memory in Gi.
swhcc_allocate() {   # <account id> <cluster id> <cpu> <memory gi> <gpu>
    local body
    body="$(jq -n --arg account "$1" --arg cluster "$2" --argjson cpu "$3" --argjson memory "$4" --argjson gpu "$5" \
        '[{ClusterID: $cluster, ResourceGroupID: $account, CPUValue: $cpu, MemoryValue: $memory, GPUValue: $gpu, PolicyType: "limit"}]')"
    cpdapi POST "${SWHCC_WATCHDOG}/resource_group/resources/policies" "${body}"
    swhcc_api_ok || h_die "Could not allocate resources to the account ($(swhcc_api_error))."
}

# Create the account if needed, administered by the signed-in user, and make sure it
# has the cluster. An account that already has the cluster keeps its allocation.
swhcc_ensure_account() {   # <name> <description> <cluster id> <cpu> <memory gi> <gpu>
    if swhcc_find_account "$1"; then
        (( ${${(s: :)SWHCC_ACCOUNT_CLUSTERS}[(Ie)$3]} )) && { h_info "Account '$1' already has this cluster."; return 0; }
        cpdapi PUT "${SWHCC_PLATFORM}/resource_groups/${SWHCC_ACCOUNT_ID}/clusters" \
            "$(jq -n --arg id "$3" '{add_clusters: [$id]}')"
        swhcc_api_ok || h_die "Could not add the cluster to account '$1' ($(swhcc_api_error))."
    else
        local user body
        user="$(print -r -- "${CPDAPI_TOKEN}" | python3 -c '
import base64, json, sys
part = sys.stdin.read().split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
print(json.dumps({"uid": str(claims["uid"]), "username": claims["username"]}))')"
        body="$(jq -n --arg name "$1" --arg desc "$2" --arg cluster "$3" --argjson user "${user}" \
            '{resource_group_name: $name, description: $desc, clusters: [$cluster],
              members: {users: [$user]}, workload_kind: "SW_CORE_WL"}')"
        h_info "Creating account '$1'"
        cpdapi POST "${SWHCC_PLATFORM}/resource_groups" "${body}"
        swhcc_api_ok || h_die "Could not create account '$1' ($(swhcc_api_error))."
        SWHCC_ACCOUNT_ID="$(print -r -- "${API_BODY}" | jq -r '.resource_group_id // empty')"
        [[ -n "${SWHCC_ACCOUNT_ID}" ]] || swhcc_find_account "$1" || h_die "Account '$1' was accepted but is not listed."
    fi
    h_info "Allocating $4 vCPU, $5 Gi memory and $6 GPU to account '$1'"
    swhcc_allocate "${SWHCC_ACCOUNT_ID}" "$3" "$4" "$5" "$6"
}

# --- Instances ----------------------------------------------------------------

# Sets REPLY to the registered instance's ID; fails when it is not registered.
swhcc_find_instance() {   # <url>
    cpdapi GET "${SWHCC_PLATFORM}/namespaces?limit=1000"
    swhcc_api_ok || h_die "Could not list instances ($(swhcc_api_error))."
    REPLY="$(print -r -- "${API_BODY}" | jq -r --arg url "${1%/}" \
        '[.namespaces[]? | select((.instance_connection.url // "" | rtrimstr("/")) == $url)][0].namespace_id // empty')"
    [[ -n "${REPLY}" ]]
}

# Validate, save, then set the unlimited quota the web client sets by default. The
# web client removes the instance when that last call fails, so this does too.
swhcc_register_instance() {   # <display name> <url> <username> <api key> <account id>
    local project="${${${2#https://}%%.*}#cpd-}" check body id quota
    check="$(NAME="${project}" URL="$2" USER_NAME="$3" KEY="$4" ACCOUNT="$5" \
        jq -n '{namespace_name: env.NAME, resource_group_id: env.ACCOUNT, instance_connection: {url: env.URL},
                instance_credentials: {api_key: env.KEY, username: env.USER_NAME}}')"
    swhcc_api_secret POST "${SWHCC_PLATFORM}/namespaces?validate=true" "${check}"
    if ! swhcc_api_ok; then
        h_error "Control Center rejected '$1' ($(swhcc_api_error))."
        return 1
    fi
    body="$(NAME="$1" URL="$2" USER_NAME="$3" KEY="$4" ACCOUNT="$5" \
        jq -n '{namespace_name: env.NAME, resource_group_id: env.ACCOUNT,
                instance_connection: {url: env.URL, username: env.USER_NAME},
                instance_credentials: {api_key: env.KEY, username: env.USER_NAME}, workload_kind: "SW_CORE_WL"}')"
    swhcc_api_secret POST "${SWHCC_PLATFORM}/namespaces" "${body}"
    if ! swhcc_api_ok; then
        h_error "Could not save '$1' ($(swhcc_api_error))."
        return 1
    fi
    id="$(print -r -- "${API_BODY}" | jq -r '.namespace_id // empty')"
    quota="$(jq -n --arg id "${id}" '{InstanceID: $id, ID: "platform", Enforce: false, EnforcementSupported: false,
        Enable: true, Alert: false, Policies: {Quota: {
            CPU: {Maximum: -1, Warning: -1, Unit: "c"}, Memory: {Maximum: -1, Warning: -1, Unit: "Gi"},
            GPU: {Maximum: -1, Warning: -1, Unit: "GPU"}, PolicyType: "limit"}}}')"
    cpdapi POST "${SWHCC_WATCHDOG}/instance/resources/policies" "${quota}"
    if ! swhcc_api_ok; then
        h_error "Could not set the quota for '$1' ($(swhcc_api_error)); removing it again."
        cpdapi DELETE "${SWHCC_PLATFORM}/namespaces/${id}"
        return 1
    fi
}

# Software Hub instances on the cluster oc is logged in to, without Control Center
# itself (it runs on zen too), as "project<TAB>version<TAB>status<TAB>url" lines.
swhcc_detect_instances() {
    local project version zen_status host
    oc get zenservice -A -o json | jq -r '.items[]
        | [.metadata.namespace, (.status.currentVersion // "?"), (.status.zenStatus // "?")] | @tsv' \
    | while IFS=$'\t' read -r project version zen_status; do
        [[ "${project}" != "${CONTROL_PROJECT_OPERANDS:-}" ]] || continue
        host="$(oc get route cpd -n "${project}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
        print -r -- "${project}"$'\t'"${version}"$'\t'"${zen_status}"$'\t'"${host:+https://${host}}"
    done
}

# --- Users --------------------------------------------------------------------

# Everyone bound to cluster-admin, one per line: directly or through an OpenShift
# group, from any identity provider. Reads the bindings rather than 'oc get users',
# which only lists people who have signed in at least once. Service accounts and
# system: users are left out.
swhcc_cluster_admin_users() {
    { oc get clusterrolebindings -o json; oc get groups -o json; } | jq -rs '
        ((.[1].items // []) | map({key: .metadata.name, value: (.users // [])}) | from_entries) as $groups
        | [.[0].items[] | select(.roleRef.kind == "ClusterRole" and .roleRef.name == "cluster-admin")
           | .subjects[]?
           | if .kind == "User" then .name elif .kind == "Group" then ($groups[.name] // [])[] else empty end]
        | unique[] | select(startswith("system:") | not)'
}

# Warn when OpenShift users cannot sign in to this Control Center yet.
swhcc_warn_openshift_auth() {
    local enabled
    enabled="$(oc get configmap platform-auth-idp -n "${CONTROL_PROJECT_OPERANDS}" -o jsonpath='{.data.ROKS_ENABLED}' 2>/dev/null || true)"
    [[ "${enabled}" == true ]] && return 0
    h_warn "OpenShift authentication is not on for this Control Center (ROKS_ENABLED=${enabled:-unknown})."
    h_warn "The roles are still set, but these users cannot sign in with OpenShift until it is, or until"
    h_warn "they come from an identity provider connected to Control Center."
}

# Fail unless Control Center defines every role.
swhcc_check_roles() {   # <role>...
    cpdapi GET "/usermgmt/v1/roles"
    swhcc_api_ok || h_die "Could not list the roles ($(swhcc_api_error))."
    local known role
    known=" $(print -r -- "${API_BODY}" | jq -r '[.rows[]?.id] | join(" ")') "
    for role in "$@"; do
        [[ "${known}" == *" ${role} "* ]] || h_die "Control Center has no role '${role}'. It has:${known}"
    done
}

# Add roles, keeping the ones the user has. A user missing from Control Center is
# created, so they have the roles the first time they sign in. DRY_RUN=true only reports.
swhcc_grant_roles() {   # <user> <role>...
    local user="$1" user_path; shift
    user_path="/usermgmt/v1/user/$(cpdapi_urlencode "${user}")"
    cpdapi GET "${user_path}"
    if [[ "${API_CODE}" == 404 ]]; then
        h_info "${user}: not in Control Center yet, adding with ${(j:, :)@}"
        [[ "${DRY_RUN:-false}" == true ]] && return 0
        cpdapi POST "/usermgmt/v1/user" "$(jq -n --arg user "${user}" '$ARGS.positional as $roles
            | {username: $user, displayName: $user, email: $user, authenticator: "external", user_roles: $roles}' --args "$@")"
    elif swhcc_api_ok; then
        local -a wanted=("$@") current missing
        current=("${(@f)$(print -r -- "${API_BODY}" | jq -r '.user_roles[]?')}")
        missing=(${wanted:|current})
        if (( ! ${#missing} )); then
            h_info "${user}: already has ${(j:, :)@}"
            return 0
        fi
        h_info "${user}: adding ${(j:, :)missing}"
        [[ "${DRY_RUN:-false}" == true ]] && return 0
        cpdapi PUT "${user_path}" "$(jq -n '{user_roles: $ARGS.positional}' --args ${current:#} "${missing[@]}")"
    fi
    swhcc_api_ok || { h_error "${user}: could not set roles ($(swhcc_api_error))."; return 1; }
}

# Remove roles and keep the rest. The user record stays.
swhcc_revoke_roles() {   # <user> <role>...
    local user="$1" user_path; shift
    user_path="/usermgmt/v1/user/$(cpdapi_urlencode "${user}")"
    cpdapi GET "${user_path}"
    [[ "${API_CODE}" == 404 ]] && { h_info "${user}: not in Control Center."; return 0; }
    swhcc_api_ok || { h_error "${user}: could not read the user ($(swhcc_api_error))."; return 1; }
    local -a unwanted=("$@") current keep
    current=("${(@f)$(print -r -- "${API_BODY}" | jq -r '.user_roles[]?')}")
    current=(${current:#})
    keep=(${current:|unwanted})
    if (( ${#keep} == ${#current} )); then
        h_info "${user}: has none of ${(j:, :)@}"
        return 0
    fi
    h_info "${user}: removing ${(j:, :)@}"
    [[ "${DRY_RUN:-false}" == true ]] && return 0
    cpdapi PUT "${user_path}" "$(jq -n '{user_roles: $ARGS.positional}' --args "${keep[@]}")"
    swhcc_api_ok || { h_error "${user}: could not remove the roles ($(swhcc_api_error))."; return 1; }
}
