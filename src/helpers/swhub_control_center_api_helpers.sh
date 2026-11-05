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
    detail="$(print -r -- "${API_BODY:-}" | jq -r '([.errors[]? | .message // .code] | join("; ")) as $errors
        | if $errors != "" then $errors else (.message // .exception // "") end' 2>/dev/null || true)"
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

# The OpenShift authorize page for this cluster. Sets REPLY.
swhcc_cluster_oauth_url() {   # <cluster id>
    local invoker host
    invoker="$(cpdapi_urlencode 'clusters?action=register')"
    # A bare host: Control Center adds https:// itself when it builds the redirect URI.
    host="${${CONTROL_CENTER_URL%/}#https://}"
    host="$(cpdapi_urlencode "${host}")"
    cpdapi GET "${SWHCC_PLATFORM}/clusters/$1/oauth-authz-endpoints?invoker_uri=${invoker}&swh_host=${host}"
    swhcc_api_ok || h_die "Could not get the OAuth page ($(swhcc_api_error))."
    REPLY="$(print -r -- "${API_BODY}" | jq -r '.oauth_authz_url // empty')"
    [[ -n "${REPLY}" ]] || h_die "Control Center returned no OAuth page."
}

# One attempt at an OAuth code the way oc login does. Prints the redirect location.
swhcc_oauth_challenge() {   # <authorize url> <user> <escaped password>
    print -r -- "user = \"$2:$3\"" \
        | curl -sk -K - -H 'X-CSRF-Token: 1' -o /dev/null -D - "$1" \
        | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | tail -1
}

# Verify or refresh the cluster platform to platform, with no browser: get an OAuth
# code the way oc login does, using the cluster login in the config, then hand it to
# Control Center, which reads the capacity with it. Needs a username and password; a
# token-only login cannot do this.
# The client normally suits people: prompt asks each user once and remembers it, and
# respondWithChallenges stays off because it rejects browsers, which would break the
# Refresh data button. So it only changes for the seconds this takes. OpenShift takes
# a moment to pick up the change, hence the retries.
swhcc_cluster_auto_verify() {   # <cluster id>
    local user="${OCP_USERNAME:-${CONTROL_OCP_USERNAME:-}}" password="${OCP_PASSWORD:-${CONTROL_OCP_PASSWORD:-}}"
    [[ -n "${user}" && -n "${password}" ]] || { h_warn "No cluster username and password in the config."; return 1; }
    swhcc_cluster_oauth_url "$1"
    local authorize="${REPLY}" location parsed code state try
    password="${password//\\/\\\\}"
    password="${password//\"/\\\"}"
    oc patch oauthclient "${CONTROL_OAUTH_CLIENT_ID}" --type=merge -p '{"respondWithChallenges":true,"grantMethod":"auto"}' >/dev/null \
        || { h_warn "Could not update OAuth client ${CONTROL_OAUTH_CLIENT_ID}."; return 1; }
    for try in 1 2 3 4 5 6; do
        location="$(swhcc_oauth_challenge "${authorize}" "${user}" "${password}" || true)"
        [[ "${location}" == *"code="* ]] && break
        sleep 2
    done
    oc patch oauthclient "${CONTROL_OAUTH_CLIENT_ID}" --type=merge -p '{"respondWithChallenges":false,"grantMethod":"prompt"}' >/dev/null \
        || h_warn "Could not restore OAuth client ${CONTROL_OAUTH_CLIENT_ID}; re-run step 1.4 or browser refreshes fail."
    parsed="$(print -r -- "${location}" | python3 -c '
import sys, urllib.parse
query = urllib.parse.parse_qs(urllib.parse.urlsplit(sys.stdin.read().strip()).query)
print(query.get("code", [""])[0], query.get("state", [""])[0])')"
    code="${parsed%% *}"; state="${parsed#* }"
    if [[ -z "${code}" ]]; then
        h_warn "OpenShift returned no code for ${user}."
        return 1
    fi
    local host="${${CONTROL_CENTER_URL%/}#https://}"
    swhcc_api_secret PUT "${SWHCC_PLATFORM}/clusters/$1/capacities" \
        "$(CODE="${code}" STATE="${state}" HOST="${host}" jq -n '{code: env.CODE, state: env.STATE, swh_host: env.HOST}')"
    if ! swhcc_api_ok; then
        h_warn "Control Center did not accept the code ($(swhcc_api_error))."
        return 1
    fi
    h_info "Cluster capacity refreshed as ${user}."
}

# Verify the cluster without a person when the config allows it. Otherwise print the
# page to approve by hand and wait for it. Fails if that does not happen in time.
swhcc_wait_cluster_verified() {   # <timeout seconds>
    swhcc_cluster_verified && return 0
    swhcc_cluster_auto_verify "${SWHCC_CLUSTER_ID}" && swhcc_cluster_verified && return 0
    swhcc_cluster_oauth_url "${SWHCC_CLUSTER_ID}"
    h_info "Could not verify the cluster automatically, so this needs a browser:"
    h_info "  1. Sign in to ${CONTROL_CENTER_URL}."
    h_info "  2. In that browser, open: ${REPLY}"
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

# The cluster as Control Center sees it, less what accounts other than the given ones
# hold: SWHCC_CPU, SWHCC_MEMORY_GI and SWHCC_GPU, rounded up. These are its own capacity
# figures, not OpenShift's allocatable ones, so accounts can fill the whole cluster.
# SWHCC_FIRST_CPU and SWHCC_FIRST_MEMORY_GI are what the first account holds now.
swhcc_cluster_capacity() {   # <cluster id> [account id]...
    local cluster="$1" free account held totals
    shift
    cpdapi GET "${SWHCC_WATCHDOG}/cluster/resources"
    swhcc_api_ok || h_die "Could not read the cluster capacity ($(swhcc_api_error))."
    free="$(print -r -- "${API_BODY}" | jq -c --arg id "${cluster}" '[.requestObj.Resources[] | select(.ClusterID == $id)][0].Resources // empty')"
    [[ -n "${free}" ]] || h_die "Control Center reports no capacity for cluster ${cluster}."
    read -r SWHCC_CPU SWHCC_MEMORY_GI SWHCC_GPU <<< "$(print -r -- "${free}" \
        | jq -r '[.CPU, .Memory, .GPU] | map(.AvailableCapacity | ceil) | join(" ")')"
    SWHCC_FIRST_CPU=0; SWHCC_FIRST_MEMORY_GI=0
    local first=true
    for account in "$@"; do
        if [[ -n "${account}" ]]; then
            cpdapi GET "${SWHCC_WATCHDOG}/resource_group/resources/policies/${account}"
            swhcc_api_ok || h_die "Could not read an account's allocation ($(swhcc_api_error))."
            held="$(print -r -- "${API_BODY}" | jq -r --arg id "${cluster}" \
                '[.requestObj.Resources[]? | select(.ClusterID == $id)][0].Resources // {}
                 | [.CPU, .Memory, .GPU] | map([.Allocated // 0, 0] | max | ceil) | join(" ")')"
            totals=(${=held})
            SWHCC_CPU=$(( SWHCC_CPU + totals[1] ))
            SWHCC_MEMORY_GI=$(( SWHCC_MEMORY_GI + totals[2] ))
            SWHCC_GPU=$(( SWHCC_GPU + totals[3] ))
            [[ "${first}" == true ]] && { SWHCC_FIRST_CPU="${totals[1]}"; SWHCC_FIRST_MEMORY_GI="${totals[2]}"; }
        fi
        first=false
    done
}

# Reads a JSON array of pods. Prints the CPU requests, memory requests (Gi), CPU limits
# and memory limits (Gi) of the running and pending ones, unrounded.
swhcc_sum_resources() {
    python3 -c '
import json, sys
UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "K": 10**3, "M": 10**6, "G": 10**9, "T": 10**12, "m": 1e-3}
def quantity(value):
    for unit, factor in UNITS.items():
        if value.endswith(unit):
            return float(value[:-len(unit)]) * factor
    return float(value)
total = {"requests": {"cpu": 0.0, "memory": 0.0}, "limits": {"cpu": 0.0, "memory": 0.0}}
for pod in json.load(sys.stdin):
    if pod["status"].get("phase") not in ("Running", "Pending"):
        continue
    for container in pod["spec"]["containers"]:
        for kind in total:
            values = container.get("resources", {}).get(kind, {})
            for resource in ("cpu", "memory"):
                total[kind][resource] += quantity(values.get(resource, "0"))
print("%.6f %.6f %.6f %.6f" % (total["requests"]["cpu"], total["requests"]["memory"] / 2**30,
                               total["limits"]["cpu"], total["limits"]["memory"] / 2**30))'
}

# A number divided by an optional factor, rounded up to a whole number.
swhcc_ceil() {   # <number> [divide by]
    awk -v x="$1" -v d="${2:-1}" 'BEGIN { y = x / d; r = int(y); if (y > r + 1e-9) r++; print r }'
}

# Quotas for instances sharing an account. Reads "id requests_cpu requests_memory
# limits_cpu limits_memory" lines and prints "id cpu memory_gi". Each quota is at least
# requests / headroom, so requests stay under the instance's 95% alert line and new pods
# fit if enforcement is ever turned on. It grows to the instance's limits, and at most
# to its share of the account by limits. Warns on stderr when the floors alone do not
# fit the account.
swhcc_plan_quotas() {   # <account cpu> <account memory gi> <headroom>
    python3 -c '
import math, sys
cap = [float(sys.argv[1]), float(sys.argv[2])]
headroom = float(sys.argv[3])
rows = [line.split() for line in sys.stdin if line.strip()]
quota = {row[0]: [0, 0] for row in rows}
for k, name in ((0, "vCPU"), (1, "memory")):
    requests = [float(row[1 + k]) for row in rows]
    limits = [float(row[3 + k]) for row in rows]
    floors = [math.ceil(r / headroom - 1e-9) for r in requests]
    ceilings = [max(math.ceil(l - 1e-9), f) for l, f in zip(limits, floors)]
    total = sum(limits)
    shares = [math.floor(cap[k] * l / total) if total else f for l, f in zip(limits, floors)]
    for row, f, c, s in zip(rows, floors, ceilings, shares):
        quota[row[0]][k] = max(f, min(c, s))
    if sum(floors) > cap[k]:
        print(f"The instances need {sum(floors)} {name} of quota but the account holds {cap[k]:g}.", file=sys.stderr)
for row in rows:
    print(row[0], *quota[row[0]])' "$@"
}

# Projects that belong to the Software Hub instances, one per line: anything with a
# ZenService or CommonService, plus the configured instance and shared component
# projects. Control Center runs a ZenService and CommonService of its own, but is not
# an instance, so its projects count as other workloads.
swhcc_instance_projects() {
    local -a projects=("${(@f)$( { oc get zenservice -A -o json; oc get commonservice -A -o json; } \
        | jq -r '.items[].metadata.namespace')}")
    projects+=("${PROJECT_CPD_INST_OPERATORS:-}" "${PROJECT_CPD_INST_OPERANDS:-}" "${PROJECT_LICENSE_SERVICE:-}"
               "${PROJECT_SCHEDULING_SERVICE:-}" "${PROJECT_IBM_EVENTS:-}" "${PROJECT_PRIVILEGED_MONITORING_SERVICE:-}")
    local -a control_center=("${CONTROL_PROJECT_OPERATORS:-}" "${CONTROL_PROJECT_OPERANDS:-}")
    print -rl -- ${${projects:#}:|control_center} | sort -u
}

# What everything outside the Software Hub instances has reserved on the workers: storage,
# monitoring, third-party agents and Control Center itself. Sets SWHCC_OTHER_CPU and
# SWHCC_OTHER_MEMORY_GI. Masters are left out because Control Center's cluster capacity
# only counts workers.
swhcc_other_reserved_capacity() {
    local -a software_hub=("${(@f)$(swhcc_instance_projects)}")
    local masters
    masters="$(oc get nodes -l '!node-role.kubernetes.io/worker' -o json | jq -c '[.items[].metadata.name]')"
    local -a values=(${=$(oc get pods -A -o json \
        | jq --argjson masters "${masters}" '$ARGS.positional as $skip | [.items[]
            | select((.metadata.namespace | IN($skip[])) | not)
            | select((.spec.nodeName // "") as $node | ($masters | index($node)) == null)]' --args ${software_hub:#} \
        | swhcc_sum_resources)})
    # Requests / 0.95, so a quota set to this allocation leaves room under the alert line.
    SWHCC_OTHER_CPU="$(swhcc_ceil "${values[1]}" 0.95)"
    SWHCC_OTHER_MEMORY_GI="$(swhcc_ceil "${values[2]}" 0.95)"
}

# What the instances have reserved, rounded up: SWHCC_CPU and SWHCC_MEMORY_GI. This
# matches the requests Control Center reports for an instance, and works before it has
# collected any metrics. SWHCC_RESOURCES holds the unrounded requests and limits, as
# swhcc_sum_resources prints them. Operator projects are not part of that figure.
swhcc_reserved_capacity() {   # <project>...
    local project
    SWHCC_RESOURCES="$(for project in "$@"; do oc get pods -n "${project}" -o json; done | jq -s '[.[].items[]]' | swhcc_sum_resources)"
    local -a values=(${=SWHCC_RESOURCES})
    SWHCC_CPU="$(swhcc_ceil "${values[1]}")"
    SWHCC_MEMORY_GI="$(swhcc_ceil "${values[2]}")"
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

# Give the account resources on a cluster, or change them. CPU in cores, memory in Gi.
swhcc_allocate() {   # <account id> <cluster id> <cpu> <memory gi> <gpu>
    local body
    body="$(jq -n --arg account "$1" --arg cluster "$2" --argjson cpu "$3" --argjson memory "$4" --argjson gpu "$5" \
        '[{ClusterID: $cluster, ResourceGroupID: $account, Allocated: true, CPUValue: $cpu, MemoryValue: $memory, GPUValue: $gpu, PolicyType: "limit"}]')"
    cpdapi POST "${SWHCC_WATCHDOG}/resource_group/resources/policies" "${body}"
    swhcc_api_ok || h_die "Could not allocate resources to the account ($(swhcc_api_error))."
}

# Create the account if needed, administered by the signed-in user, and make sure it
# has the cluster. An account that already has the cluster keeps its allocation.
swhcc_ensure_account() {   # <name> <description> <cluster id> <cpu> <memory gi> <gpu> [workload kind]
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
        body="$(jq -n --arg name "$1" --arg desc "$2" --arg cluster "$3" --argjson user "${user}" --arg kind "${7:-SW_CORE_WL}" \
            '{resource_group_name: $name, description: $desc, clusters: [$cluster],
              members: {users: [$user]}, workload_kind: $kind}')"
        h_info "Creating account '$1'"
        cpdapi POST "${SWHCC_PLATFORM}/resource_groups" "${body}"
        swhcc_api_ok || h_die "Could not create account '$1' ($(swhcc_api_error))."
        SWHCC_ACCOUNT_ID="$(print -r -- "${API_BODY}" | jq -r '.resource_group_id // empty')"
        [[ -n "${SWHCC_ACCOUNT_ID}" ]] || swhcc_find_account "$1" || h_die "Account '$1' was accepted but is not listed."
    fi
    h_info "Allocating $4 vCPU, $5 Gi memory and $6 GPU to account '$1'"
    swhcc_allocate "${SWHCC_ACCOUNT_ID}" "$3" "$4" "$5" "$6"
}

# Make everyone with Control Center access an administrator of the account: the
# account administrator role, plus membership of this account. Users with no role and
# groups with no role, such as the system All Users group, have no access to pass on.
# Fails if any of them could not be updated.
swhcc_sync_account_admins() {   # <account id>
    local account="$1" role=zen_resource_group_admin_role failed=0 offset=0 page user uid group id name
    local -a users=() lines=()
    while :; do
        cpdapi GET "/usermgmt/v2/usermgmt/users?offset=${offset}&limit=100"
        swhcc_api_ok || h_die "Could not list users ($(swhcc_api_error))."
        lines=("${(@f)$(print -r -- "${API_BODY}" | jq -r '.[] | select((.user_roles // []) | length > 0) | "\(.uid)\t\(.username)"')}")
        users+=(${lines:#})
        page="$(print -r -- "${API_BODY}" | jq 'length')"
        (( page == 100 )) || break
        (( offset += 100 ))
    done

    cpdapi GET "${SWHCC_PLATFORM}/resource_groups/${account}/members?member_type=USER&limit=100"
    swhcc_api_ok || h_die "Could not list the account members ($(swhcc_api_error))."
    local members=" $(print -r -- "${API_BODY}" | jq -r '[.user_members.users[]?.uid] | join(" ")') "

    for user in "${users[@]}"; do
        uid="${user%%$'\t'*}"; name="${user#*$'\t'}"
        swhcc_grant_roles "${name}" "${role}" || (( ++failed ))
        [[ "${members}" == *" ${uid} "* ]] && continue
        h_info "${name}: adding to the account"
        cpdapi POST "${SWHCC_PLATFORM}/resource_groups/${account}/members" \
            "$(jq -n --arg uid "${uid}" --arg name "${name}" '{users: [{uid: $uid, username: $name}]}')"
        swhcc_api_ok || { h_error "${name}: could not add to the account ($(swhcc_api_error))."; (( ++failed )); }
    done

    cpdapi GET "/usermgmt/v4/groups?limit=100"
    swhcc_api_ok || h_die "Could not list groups ($(swhcc_api_error))."
    lines=("${(@f)$(print -r -- "${API_BODY}" | jq -r '(.results // [])[] | select((.roles // []) | length > 0) | "\(.group_id)\t\(.name)"')}")
    for group in ${lines:#}; do
        id="${group%%$'\t'*}"; name="${group#*$'\t'}"
        h_info "Group ${name}: making it an account administrator"
        cpdapi PATCH "/usermgmt/v2/groups/${id}" "$(jq -n --arg role "${role}" '{add_role_identifiers: [$role]}')"
        swhcc_api_ok || { h_error "Group ${name}: could not add the role ($(swhcc_api_error))."; (( ++failed )); }
        cpdapi POST "${SWHCC_PLATFORM}/resource_groups/${account}/members" \
            "$(jq -n --arg id "${id}" --arg name "${name}" '{groups: [{group_id: $id, group_name: $name}]}')"
        # 409: it is already a member.
        swhcc_api_ok || [[ "${API_CODE}" == 409 ]] \
            || { h_error "Group ${name}: could not add to the account ($(swhcc_api_error))."; (( ++failed )); }
    done
    (( failed == 0 ))
}

# --- Private routes -------------------------------------------------------------

# True when zen-core-api resolves the host to a private address, which Control Center
# refuses for instance URLs.
swhcc_route_is_private() {   # <host>
    local pod address
    pod="$(oc get pods -n "${CONTROL_PROJECT_OPERANDS}" -o name --field-selector=status.phase=Running | grep '/zen-core-api-' | head -1 || true)"
    [[ -n "${pod}" ]] || h_die "No running zen-core-api pod in ${CONTROL_PROJECT_OPERANDS}."
    address="$(oc exec -n "${CONTROL_PROJECT_OPERANDS}" -c zen-core-api-container "${pod}" -- getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 {print $1}')"
    [[ "${address}" == (10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*) ]]
}

swhcc_remove_route_mapping() {
    h_info "Removing the route mapping from zen-core-api"
    oc patch deployment zen-core-api -n "${CONTROL_PROJECT_OPERANDS}" --type=merge \
        -p '{"spec":{"template":{"spec":{"hostAliases":null}}}}' >/dev/null
    oc rollout status deployment/zen-core-api -n "${CONTROL_PROJECT_OPERANDS}" --timeout=300s
}

# Run a command while zen-core-api resolves the hosts to a public IP, then always remove
# the mapping. Unsupported by IBM, and restarts Control Center's API twice. The command
# runs in a subshell, so variables it sets do not come back.
swhcc_with_route_mapping() {   # <public ip> <host>... -- <command>...
    local ip="$1" rc=0
    shift
    local -a hosts=()
    while (( $# )) && [[ "$1" != -- ]]; do hosts+=("$1"); shift; done
    shift
    [[ "${ip}" != (10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|) ]] \
        || h_die "'${ip}' is not a public address, so mapping to it would not help."
    h_info "Mapping ${#hosts} route(s) to ${ip} on zen-core-api"
    oc patch deployment zen-core-api -n "${CONTROL_PROJECT_OPERANDS}" --type=merge \
        -p "$(jq -cn --arg ip "${ip}" '{spec: {template: {spec: {hostAliases: [{ip: $ip, hostnames: $ARGS.positional}]}}}}' --args "${hosts[@]}")" >/dev/null
    trap 'swhcc_remove_route_mapping; exit 130' INT TERM
    { oc rollout status deployment/zen-core-api -n "${CONTROL_PROJECT_OPERANDS}" --timeout=300s && ( "$@" ); } || rc=$?
    trap - INT TERM
    swhcc_remove_route_mapping
    return "${rc}"
}

# --- Instances ----------------------------------------------------------------

# Registering an instance needs manage_namespaces, which zen_administrator_role does
# not include. Give the signed-in user the account administrator role, and sign in
# again so the token carries it.
swhcc_ensure_instance_rights() {
    swhcc_grant_roles "${CONTROL_CENTER_USERNAME}" zen_resource_group_admin_role \
        || h_die "Could not give ${CONTROL_CENTER_USERNAME} the account administrator role."
    swhcc_api_login
}

# Sets REPLY to the registered instance's ID; fails when it is not registered.
swhcc_find_instance() {   # <url>
    cpdapi GET "${SWHCC_PLATFORM}/namespaces?limit=1000"
    swhcc_api_ok || h_die "Could not list instances ($(swhcc_api_error))."
    REPLY="$(print -r -- "${API_BODY}" | jq -r --arg url "${1%/}" \
        '[.namespaces[]? | select((.instance_connection.url // "" | rtrimstr("/")) == $url)][0].namespace_id // empty')"
    [[ -n "${REPLY}" ]]
}

# An instance quota, in cores and Gi; -1 is unlimited. Control Center's account page
# shows the sum of these as "allocated", so unlimited instances show as 0 there. It
# only tracks usage: Enforce stays false, so nothing is limited.
# PolicyType request: the instance measures the quota against requests, which is what
# swhcc_plan_quotas sizes it for. The web client sends limit, which measures limits and
# alerts as soon as they overcommit (290 vCPU of limits against a 139 quota here).
swhcc_set_instance_quota() {   # <instance id> <cpu> <memory gi>
    cpdapi POST "${SWHCC_WATCHDOG}/instance/resources/policies" \
        "$(jq -n --arg id "$1" --argjson cpu "$2" --argjson memory "$3" '{InstanceID: $id, ID: "platform",
            Enforce: false, EnforcementSupported: false, Enable: true, Alert: false, Policies: {Quota: {
                CPU: {Maximum: $cpu, Warning: -1, Unit: "c"}, Memory: {Maximum: $memory, Warning: -1, Unit: "Gi"},
                GPU: {Maximum: -1, Warning: -1, Unit: "GPU"}, PolicyType: "request"}}}')"
}

# Validate, save, then set the unlimited quota the web client sets by default. The
# web client removes the instance when that last call fails, so this does too.
swhcc_register_instance() {   # <display name> <url> <username> <api key> <account id> [workload kind]
    local project="${${${2#https://}%%.*}#cpd-}" check body id
    check="$(NAME="${project}" URL="$2" USER_NAME="$3" KEY="$4" ACCOUNT="$5" \
        jq -n '{namespace_name: env.NAME, resource_group_id: env.ACCOUNT, instance_connection: {url: env.URL},
                instance_credentials: {api_key: env.KEY, username: env.USER_NAME}}')"
    swhcc_api_secret POST "${SWHCC_PLATFORM}/namespaces?validate=true" "${check}"
    if ! swhcc_api_ok; then
        h_error "Control Center rejected '$1' ($(swhcc_api_error))."
        [[ "${API_BODY}" == *"private IP"* ]] && h_warn "This route resolves to a private address inside the cluster: see x_debug_register_private_route_instances.sh in optional_install_swhub_control_center/."
        return 1
    fi
    body="$(NAME="$1" URL="$2" USER_NAME="$3" KEY="$4" ACCOUNT="$5" KIND="${6:-SW_CORE_WL}" \
        jq -n '{namespace_name: env.NAME, resource_group_id: env.ACCOUNT,
                instance_connection: {url: env.URL, username: env.USER_NAME},
                instance_credentials: {api_key: env.KEY, username: env.USER_NAME}, workload_kind: env.KIND}')"
    swhcc_api_secret POST "${SWHCC_PLATFORM}/namespaces" "${body}"
    if ! swhcc_api_ok; then
        h_error "Could not save '$1' ($(swhcc_api_error))."
        return 1
    fi
    id="$(print -r -- "${API_BODY}" | jq -r '.namespace_id // empty')"
    swhcc_set_instance_quota "${id}" -1 -1
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
        cpdapi PUT "${user_path}" "$(jq -n --arg user "${user}" '{username: $user, user_roles: $ARGS.positional}' --args ${current:#} "${missing[@]}")"
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
    cpdapi PUT "${user_path}" "$(jq -n --arg user "${user}" '{username: $user, user_roles: $ARGS.positional}' --args "${keep[@]}")"
    swhcc_api_ok || { h_error "${user}: could not remove the roles ($(swhcc_api_error))."; return 1; }
}
