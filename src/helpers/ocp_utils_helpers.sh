#!/bin/zsh
# =============================================================================
# ocp_utils_helpers.sh - shared functions for src/utilities/redhat_openshift_utils
# -----------------------------------------------------------------------------
# How scripts use it (after the env_bootstrap line):
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
#
# Sections:
#   - login: --server/--token/--username/--password flags, else OC_LOGIN
#   - pull secrets: source secret checks and a namespace-independent copy
#   - htpasswd identity providers (set_htpasswd_users.sh and
#     set_service_id_user_proxies.sh both write one), working on the caller's
#     globals:
#       in      IDP_NAME, SECRET_NAME, PRUNE
#       state   OAUTH_JSON, IDP_EXISTS, IDP_MAPPING, CURRENT_LINES (user ->
#               htpasswd line in the cluster), SAVED_PASSWORDS (user -> plain
#               password from the credentials file)
#       result  NEW_LINES, ISSUED, REMOVED
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _OCU_HELPERS_LOADED.
#   - Both htpasswd scripts may share one secret, and each keeps any account it
#     has no saved password for, so they never remove each other's users.
# =============================================================================

[[ -n "${_OCU_HELPERS_LOADED:-}" ]] && return 0
_OCU_HELPERS_LOADED=1

# =============================================================================
# Login
# =============================================================================
# Credentials on the command line (LOGIN_TOKEN or LOGIN_USERNAME, with
# LOGIN_SERVER / LOGIN_PASSWORD) win. Otherwise OC_LOGIN from cpd_vars.sh, which
# skips the login when oc is already logged in to OCP_URL. Without either, the
# current oc session is used as is. Prints the target cluster.
ocu_login() {
    if [[ -n "${LOGIN_TOKEN:-}" && -n "${LOGIN_USERNAME:-}" ]]; then
        echo "[ERROR] Pass either --token or --username, not both." >&2
        exit 1
    elif [[ -z "${LOGIN_TOKEN:-}${LOGIN_USERNAME:-}" && -n "${LOGIN_SERVER:-}${LOGIN_PASSWORD:-}" ]]; then
        echo "[ERROR] --server and --password need --token or --username." >&2
        exit 1
    fi
    if [[ -n "${LOGIN_TOKEN:-}${LOGIN_USERNAME:-}" ]]; then
        local -a login=(oc login)
        local server="${LOGIN_SERVER:-${OCP_URL:-}}"
        [[ -n "${server}" ]] && login+=(--server="${server}")
        if [[ -n "${LOGIN_TOKEN:-}" ]]; then
            login+=(--token="${LOGIN_TOKEN}")
        else
            login+=(--username="${LOGIN_USERNAME}")
            # Without --password, oc asks for it.
            [[ -n "${LOGIN_PASSWORD:-}" ]] && login+=(--password="${LOGIN_PASSWORD}")
        fi
        "${login[@]}"
    elif [[ -n "${OC_LOGIN:-}" ]]; then
        eval "${OC_LOGIN}"
    elif ! oc whoami &>/dev/null; then
        echo "[ERROR] Not logged in. Set OC_LOGIN in cpd_vars.sh, or pass --token or --username." >&2
        exit 1
    fi
    echo "[INFO] Target cluster: $(oc whoami --show-server 2>/dev/null || echo unknown)"
}

ocu_require_cluster_admin() {
    if [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" != "yes" ]]; then
        echo "[ERROR] The current user is not a cluster-admin." >&2
        exit 1
    fi
}

# ROKS (Red Hat OpenShift on IBM Cloud) manages its own OAuth config and may
# undo or reject extra identity providers. TechZone's VMware clusters are fine.
ocu_warn_roks_oauth() {
    if [[ "$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || true)" == "IBMCloud" ]]; then
        echo "[WARN] Platform is IBMCloud (ROKS). Extra identity providers may not stick here."
    fi
}

# =============================================================================
# Pull secrets
# =============================================================================
# Linking a non-pull secret with --for=pull is accepted by oc but the kubelet
# never uses it, so the failure would only show up as ImagePullBackOff much
# later. Say so now.
ocu_warn_non_pull_secret() {   # <secret> <namespace>
    local type
    type="$(oc get secret "$1" -n "$2" -o jsonpath='{.type}' 2>/dev/null || echo '')"
    if [[ "${type}" != "kubernetes.io/dockerconfigjson" && "${type}" != "kubernetes.io/dockercfg" ]]; then
        echo "[WARN] Secret '$1' has type '${type:-<none>}', not a docker"
        echo "[WARN] config secret. Linking it for pull will not make image pulls work."
    fi
}

# The secret as JSON without its namespace and server-set metadata, ready to
# `oc apply -n <other namespace>`.
ocu_secret_copy_json() {   # <secret> <namespace>
    oc get secret "$1" -n "$2" -o json \
        | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.ownerReferences)'
}

# =============================================================================
# htpasswd identity providers
# =============================================================================
# Reads the OAuth CR into OAUTH_JSON and the provider named IDP_NAME. An existing
# provider is used as it is: IDP_EXISTS=true, its mappingMethod in IDP_MAPPING
# and the secret it points at in SECRET_NAME, so a provider managed elsewhere
# keeps its settings and its users are merged rather than replaced.
htpw_read_idp() {   # <mappingMethod for a new provider>
    local idp secret
    OAUTH_JSON="$(oc get oauth cluster -o json)"
    IDP_EXISTS=false
    IDP_MAPPING="$1"
    idp="$(jq -c --arg n "${IDP_NAME}" \
        '.spec.identityProviders // [] | map(select(.name == $n)) | first // empty' <<< "${OAUTH_JSON}")"
    [[ -n "${idp}" ]] || return 0
    IDP_EXISTS=true
    if [[ "$(jq -r '.type' <<< "${idp}")" != HTPasswd ]]; then
        echo "[ERROR] Identity provider '${IDP_NAME}' exists but is not of type HTPasswd." >&2
        exit 1
    fi
    IDP_MAPPING="$(jq -r '.mappingMethod // "claim"' <<< "${idp}")"
    secret="$(jq -r '.htpasswd.fileData.name' <<< "${idp}")"
    if [[ "${secret}" != "${SECRET_NAME}" ]]; then
        echo "[INFO] '${IDP_NAME}' already uses secret '${secret}', updating that one."
        SECRET_NAME="${secret}"
    fi
}

# CURRENT_LINES: user -> htpasswd line, as stored in the cluster today.
htpw_read_lines() {
    typeset -gA CURRENT_LINES
    CURRENT_LINES=()
    oc get secret "${SECRET_NAME}" -n openshift-config &>/dev/null || return 0
    local line
    for line in ${(f)"$(oc get secret "${SECRET_NAME}" -n openshift-config \
                           -o jsonpath='{.data.htpasswd}' | base64 -d)"}; do
        [[ -z "${line}" ]] && continue
        CURRENT_LINES[${line%%:*}]="${line}"
    done
}

htpw_new_password() {
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16
}

# A new password for <user>: bcrypt line in NEW_LINES, plain text in
# SAVED_PASSWORDS, name added to ISSUED.
htpw_issue() {   # <user>
    local pw
    pw="$(htpw_new_password)"
    NEW_LINES[$1]="$(htpasswd -nbB -C 10 "$1" "${pw}" | head -n 1)"
    SAVED_PASSWORDS[$1]="${pw}"
    ISSUED+=("$1")
}

# Accounts in the secret that are not among this run's users (the array named
# <users var>). Those without a saved password weren't made by this script and
# may belong to another one sharing the secret, so they are always kept. The
# others are removed with PRUNE=true (into REMOVED, saved password and any
# SAVED_EXTRAS dropped), else kept with a warning.
htpw_keep_others() {   # <users var> <how the warning names that list>
    local u others=0
    local -a run_users=("${(@P)1}")
    for u in "${(@k)CURRENT_LINES}"; do
        (( ${run_users[(Ie)${u}]} )) && continue
        if [[ -z "${SAVED_PASSWORDS[${u}]+x}" ]]; then
            NEW_LINES[${u}]="${CURRENT_LINES[${u}]}"
            (( ++others ))
        elif [[ "${PRUNE}" == true ]]; then
            REMOVED+=("${u}")
            unset "SAVED_PASSWORDS[${u}]"
            (( ${+SAVED_EXTRAS} )) && unset "SAVED_EXTRAS[${u}]"
        else
            echo "[WARN] '${u}' is in the cluster but not $2; kept. Use --prune to remove."
            NEW_LINES[${u}]="${CURRENT_LINES[${u}]}"
        fi
    done
    (( others > 0 )) && echo "[INFO] ${others} other account(s) in the secret, not made by this script, left as is."
    return 0
}

# Writes <htpasswd file> into openshift-config/SECRET_NAME.
htpw_apply_secret() {   # <htpasswd file>
    oc create secret generic "${SECRET_NAME}" -n openshift-config \
        --from-file=htpasswd="$1" --dry-run=client -o yaml | oc apply -f - >/dev/null
    echo "[INFO] Secret openshift-config/${SECRET_NAME} holds ${#NEW_LINES} user(s)."
}

# Appends the IDP_NAME provider (mappingMethod IDP_MAPPING) unless it exists.
# A JSON patch adds it, so the existing providers are never re-sent or touched.
htpw_add_idp() {
    if [[ "${IDP_EXISTS}" == true ]]; then
        echo "[INFO] Identity provider '${IDP_NAME}' already exists, left as is."
        return 0
    fi
    if [[ -n "$(jq -r '.metadata.annotations["argocd.argoproj.io/tracking-id"] // empty' <<< "${OAUTH_JSON}")" ]]; then
        echo "[WARN] ArgoCD manages the OAuth config and may remove '${IDP_NAME}' again. If it does, enable an"
        echo "       HTPasswd provider where ArgoCD's config comes from and use its name here."
    fi
    local new_idp
    new_idp="$(jq -cn --arg n "${IDP_NAME}" --arg m "${IDP_MAPPING}" --arg s "${SECRET_NAME}" \
        '{name: $n, mappingMethod: $m, type: "HTPasswd", htpasswd: {fileData: {name: $s}}}')"
    if [[ "$(jq -r '.spec.identityProviders | type' <<< "${OAUTH_JSON}")" == array ]]; then
        oc patch oauth cluster --type=json \
            -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${new_idp}}]" >/dev/null
        echo "[INFO] Added identity provider '${IDP_NAME}'. Existing providers kept:"
        jq -r '.spec.identityProviders[].name | "         - " + .' <<< "${OAUTH_JSON}"
    else
        oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":[${new_idp}]}}" >/dev/null
        echo "[INFO] No identity providers yet, created the list with '${IDP_NAME}'."
    fi
}

# Deletes the REMOVED users' identities in IDP_NAME, and the user itself when
# that was their only login (an IBMid user stays).
htpw_remove_users() {
    local u
    for u in "${REMOVED[@]}"; do
        oc delete identity "${IDP_NAME}:${u}" --ignore-not-found
        if [[ -z "$(oc get user "${u}" -o jsonpath='{.identities[*]}' 2>/dev/null)" ]]; then
            oc delete user "${u}" --ignore-not-found
        fi
        echo "[INFO] Removed '${u}'."
    done
}

# Waits for the authentication operator to roll the OAuth change out to the
# login pods.
htpw_wait_auth_rollout() {
    local i
    echo "[INFO] Waiting for the authentication operator to roll out (up to ~5 min)..."
    for i in {1..15}; do
        [[ "$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" == True ]] && break
        sleep 2
    done
    oc wait co/authentication --for=condition=Progressing=False --timeout=300s >/dev/null \
        || echo "[WARN] Still rolling out. Check with: oc get co authentication"
}
