#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Creates guest accounts named guestuser_<4 character id> on the cluster's
# htpasswd login. What they can do comes from a template (--template): each one
# has its own group, in OpenShift and in Software Hub, and sets the group's
# cluster-wide role, monitoring view, editable namespaces, own namespace, Kubecost
# UI access and Software Hub role. No template can give access to the cluster's existing Secrets.
#
#   guest-admin   read the whole cluster, edit all installed software, admin in
#                 its own namespace, Kubecost UI, Software Hub Administrator
#                 without vault management (the default)
#   cp4d-editor   editor in CP4D through a Software Hub role (projects, spaces,
#                 catalogs, service instances), viewer of Software Hub and
#                 OpenShift, Kubecost UI
#   cp4d-advanced-editor
#                 cp4d-editor plus managing CP4D projects, spaces, catalogs and
#                 service instances; same OpenShift and Kubecost access
#
# Templates are in guest_user_templates/; guest-admin.sh explains each setting.
# RBAC can't filter Secrets by who made them, so a group's own Secrets live in
# its own namespace. In Software Hub, a role without manage_vaults_and_secrets
# sees only vault secrets its users own or that are shared with them or a group.
#
# What 'edit without Secrets' removes from the stock role: Secrets, pod exec /
# attach / port-forward / proxy, debug containers, service account tokens and
# impersonation, builds, image streams, pipelines, operator subscriptions and the
# Kubecost CR (its extraObjects can create anything). A ValidatingAdmissionPolicy
# then stops guests from running a pod in those namespaces that uses a Secret, a
# PVC or a non-default service account. They can still scale and restart any
# workload, but can't change the pod spec of one that uses those things.
#
# Not closed, so don't treat this as protection against a hostile guest:
#   - RBAC can't hide fields. Values that an operator put in a pod's plain env
#     can be read by anyone who can read pods, as can pod logs and ConfigMaps.
#   - An editor can change ConfigMaps that running pods load, and the custom
#     resources of the installed software, which their operators act on.
#   - A Software Hub dynamic group with Administrator takes in guests whose login
#     matches its rule, whatever the template says. The script warns about these.
#   - manage_users in a Software Hub role lets a guest give themselves
#     Administrator (guest-admin has it, cp4d-editor doesn't).
#
# Passwords go to CREDENTIALS_FILE only (gitignored, mode 600) and are never
# printed. Logs in like the other scripts (OC_LOGIN from cpd_vars.sh, else the
# current session) and needs a cluster-admin. Software Hub steps need CPD_URL,
# CPD_USERNAME and CPD_PASSWORD from cpd_instance_details.sh.
#
# Safe to re-run: each run adds --count new guests and applies the template to
# the group, removing access the template no longer gives. Use -n 0 to apply it
# without adding anyone, e.g. after installing software or editing the template.
# A Software Hub role that already exists and differs from its template, e.g.
# edited in the web UI, is left as it is unless --sync-role is given.
#
#   create_guest_admin_users.sh -n 3                          3 guest admins
#   create_guest_admin_users.sh -n 2 --template cp4d-editor   2 CP4D editors
#   create_guest_admin_users.sh -n 1 --template /path/to/my-template.sh
#   create_guest_admin_users.sh -n 0 --template cp4d-editor   only apply the template
#   create_guest_admin_users.sh -n 3 --dry-run
#   create_guest_admin_users.sh --list-templates
#   create_guest_admin_users.sh --template cp4d-advanced-editor \
#       --move-users guestuser_a1b2,guestuser_c3d4 --from-group guest-cp4d-editors
#
#   -t, --template <name|path>  template to use [guest-admin]
#   -n, --count <n>             guests to add, 0-50 [1]
#       --list-templates        show the templates and exit
#       --skip-softwarehub      OpenShift only
#       --softwarehub-only      only the Software Hub role and group; OpenShift is
#                               not changed. Takes no -n.
#       --move-users <a,b>      existing Software Hub users to move into the
#                               template's group; implies --softwarehub-only, needs
#                               --from-group. Their directly assigned roles and
#                               OpenShift groups stay as they are.
#       --from-group <name>     Software Hub group they leave
#       --sync-role             overwrite an existing Software Hub role with the
#                               template's permissions
#       --dry-run               validate on the server, change nothing

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/cpd_api_helpers.sh"

GUEST_PREFIX="guestuser_"
TEMPLATE_DIR="${SCRIPT_DIR}/guest_user_templates"

EDIT_ROLE="guest-admin-edit-no-secrets"
KUBECOST_UI_ROLE="guest-kubecost-ui"
MONITORING_TARGETS_ROLE="guest-monitoring-targets"
MANAGED_LABEL="guest-admin/managed"
GROUP_LABEL="guest-admin/group"
CREDENTIALS_FILE="${_CP4D_REPO_ROOT}/configs/openshift_config/guest_admin_credentials.txt"

# API groups and resources left out of the guests' copy of 'edit'. Reads of most
# of these still work through cluster-reader; Secrets don't.
EXCLUDED_API_GROUPS=(
    apiextensions.k8s.io build.openshift.io charts.kubecost.com external-secrets.io
    generators.external-secrets.io image.openshift.io operator.external-secrets.io
    operator.tekton.dev operators.coreos.com packages.operators.coreos.com
    pipelinesascode.tekton.dev results.tekton.dev tekton.dev
    techzone.techzone.ibm.com triggers.tekton.dev
)
EXCLUDED_RESOURCES='^(secrets|serviceaccounts(/.*)?|pods/(attach|exec|portforward|proxy|ephemeralcontainers)|services/proxy|imagestream.*|images?(/.*)?|builds?(/.*)?|buildconfigs(/.*)?|buildlogs)$'

TEMPLATE="guest-admin"
COUNT=1
SKIP_SWH=false
SWH_ONLY=false
SYNC_ROLE=false
MOVE_USERS=()
FROM_GROUP=""
COUNT_GIVEN=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--template)      TEMPLATE="${2:?--template needs a name or path}"; shift 2 ;;
        -n|--count)         COUNT="${2:?--count needs a number}"; COUNT_GIVEN=true; shift 2 ;;
        --softwarehub-only) SWH_ONLY=true; shift ;;
        --sync-role)        SYNC_ROLE=true; shift ;;
        --move-users)       MOVE_USERS=(${(s:,:)${2:?--move-users needs a comma-separated list}}); SWH_ONLY=true; shift 2 ;;
        --from-group)       FROM_GROUP="${2:?--from-group needs a group name}"; shift 2 ;;
        --list-templates)
            for _f in "${TEMPLATE_DIR}"/*.sh(N); do
                ( source "${_f}"; printf '%-14s %s\n' "${_f:t:r}" "${TEMPLATE_DESCRIPTION}" )
            done
            exit 0 ;;
        --skip-softwarehub) SKIP_SWH=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        # The comment header from line 9 up to the first non-comment line.
        -h|--help)          awk 'NR >= 9 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *)                  echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done
if [[ "${COUNT}" != <-> ]] || (( COUNT > 50 )); then
    echo "[ERROR] --count must be a number from 0 to 50." >&2; exit 1
fi
if [[ "${SWH_ONLY}" == true ]]; then
    [[ "${COUNT_GIVEN}" != true ]] || { echo "[ERROR] --softwarehub-only and --move-users add no accounts; drop -n." >&2; exit 1; }
    [[ "${SKIP_SWH}" != true ]] || { echo "[ERROR] --skip-softwarehub can't be combined with --softwarehub-only or --move-users." >&2; exit 1; }
    COUNT=0
fi
if [[ ( -n "${MOVE_USERS[*]}" && -z "${FROM_GROUP}" ) || ( -z "${MOVE_USERS[*]}" && -n "${FROM_GROUP}" ) ]]; then
    echo "[ERROR] --move-users and --from-group go together." >&2; exit 1
fi

# --- Template -------------------------------------------------------------------
TEMPLATE_FILE="${TEMPLATE}"
[[ "${TEMPLATE}" == */* || "${TEMPLATE}" == *.sh ]] || TEMPLATE_FILE="${TEMPLATE_DIR}/${TEMPLATE}.sh"
if [[ ! -f "${TEMPLATE_FILE}" ]]; then
    echo "[ERROR] Template '${TEMPLATE}' not found. See --list-templates." >&2; exit 1
fi
TEMPLATE_DESCRIPTION=""
GUEST_GROUP=""
OCP_CLUSTER_ROLE=""
EDIT_NAMESPACE_VARS=()
EDIT_NAMESPACES=()
WORKSPACE_NAMESPACE=""
MONITORING_VIEW=false
KUBECOST_UI=false
SWH_ROLE_NAME=""
SWH_PERMISSIONS=()
SWH_BASE_ROLE=""
SWH_REMOVE_PERMISSIONS=()
source "${TEMPLATE_FILE}"

# Goes into object names and the admission policy's expression.
if [[ ! "${GUEST_GROUP}" =~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' ]]; then
    echo "[ERROR] GUEST_GROUP in ${TEMPLATE_FILE} must be lowercase letters, digits and dashes." >&2; exit 1
fi
if [[ -n "${SWH_ROLE_NAME}" ]] && (( ${#SWH_PERMISSIONS} == 0 )) && [[ -z "${SWH_BASE_ROLE}" ]]; then
    echo "[ERROR] ${TEMPLATE_FILE}: SWH_ROLE_NAME needs SWH_PERMISSIONS or SWH_BASE_ROLE." >&2; exit 1
fi
POLICY="${GUEST_GROUP}-no-secret-workloads"
if [[ "${FROM_GROUP}" == "${GUEST_GROUP}" ]]; then
    echo "[ERROR] --from-group is the template's own group." >&2; exit 1
fi

for _tool in oc htpasswd openssl jq python3; do
    command -v "${_tool}" &>/dev/null || { echo "[ERROR] '${_tool}' is not installed." >&2; exit 1; }
done
unset _tool

ocu_login
echo "[INFO] Logged in as:   $(oc whoami)"
ocu_require_cluster_admin
echo "[INFO] Template:       ${TEMPLATE_FILE:t:r} (group ${GUEST_GROUP})"
[[ "${DRY_RUN}" == true ]] && echo "[INFO] Dry run, nothing will be changed."

if [[ -n "${OCP_CLUSTER_ROLE}" ]]; then
    _rules="$(oc get clusterrole "${OCP_CLUSTER_ROLE}" -o json)" \
        || { echo "[ERROR] ClusterRole '${OCP_CLUSTER_ROLE}' not found." >&2; exit 1; }
    if jq -e 'any(.rules[]?; ((.resources // []) | index("secrets")) or
                  (((.resources // []) | index("*")) and ((.apiGroups // []) | index("") or index("*"))))' \
            <<< "${_rules}" >/dev/null; then
        echo "[ERROR] OCP_CLUSTER_ROLE '${OCP_CLUSTER_ROLE}' can read Secrets, which guests must not." >&2; exit 1
    fi
    unset _rules
fi

DRY_ARGS=()
[[ "${DRY_RUN}" == true ]] && DRY_ARGS=(--dry-run=server)
apply() { oc apply "${DRY_ARGS[@]}" -f - >/dev/null; }

GUESTS=("${MOVE_USERS[@]}")
NEW_GUESTS=()
# Everything up to the Software Hub section is OpenShift.
if [[ "${SWH_ONLY}" != true ]]; then

# --- Which htpasswd login to add to ---------------------------------------------
# The cluster's existing provider, so guests don't get a second login button.
IDP_NAME="$(oc get oauth cluster -o json | jq -r '[.spec.identityProviders[]? | select(.type == "HTPasswd")][0].name // empty')"
IDP_ARGS=()
SECRET_NAME="${HTPASSWD_SECRET_NAME:-local-users-htpasswd}"
if [[ -n "${IDP_NAME}" ]]; then
    IDP_ARGS=(-i "${IDP_NAME}")
    htpw_read_idp add
else
    IDP_NAME="${HTPASSWD_IDP_NAME:-local-users}"
fi
htpw_read_lines
echo "[INFO] Login provider: ${IDP_NAME}"

# --- Editable namespaces --------------------------------------------------------
typeset -aU _found=("${EDIT_NAMESPACES[@]}")
for _f in "${_CP4D_REPO_ROOT}"/configs/*/*_vars.sh(N); do
    [[ "${_f}" == */old_configs/* ]] && continue
    for _line in ${(f)"$(sed -nE "s/^(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=[\"']?([a-z0-9][a-z0-9-]*)[\"']?[[:space:]]*(#.*)?$/\2 \3/p" "${_f}")"}; do
        for _p in "${EDIT_NAMESPACE_VARS[@]}"; do
            [[ "${_line%% *}" == ${~_p} ]] && _found+=("${_line#* }")
        done
    done
done
SOFTWARE_NAMESPACES=()
for _ns in "${(@o)_found}"; do
    # Platform namespaces are never software, even if a vars file names one.
    [[ "${_ns}" == openshift* || "${_ns}" == kube-* || "${_ns}" == default ]] && continue
    oc get namespace "${_ns}" &>/dev/null && SOFTWARE_NAMESPACES+=("${_ns}")
done
unset _f _ns _found _line _p
if (( ${#EDIT_NAMESPACE_VARS} + ${#EDIT_NAMESPACES} > 0 && ${#SOFTWARE_NAMESPACES} == 0 )); then
    echo "[ERROR] The template names namespaces to edit, but none exist on this cluster." >&2; exit 1
fi
if (( ${#SOFTWARE_NAMESPACES} > 0 )); then
    echo "[INFO] Editable namespaces (no Secrets):"
    printf '         %s\n' "${SOFTWARE_NAMESPACES[@]}"
fi

# --- OpenShift access, in place before any guest can log in ---------------------
# 'edit' is copied rather than bound so its Secret rules can be left out. RBAC
# has no deny, and a copy doesn't follow later aggregation: re-run to refresh it.
oc get clusterrole edit -o json \
    | jq --arg name "${EDIT_ROLE}" --arg label "${MANAGED_LABEL}" --arg re "${EXCLUDED_RESOURCES}" \
         --argjson groups "$(jq -cn '$ARGS.positional' --args -- "${EXCLUDED_API_GROUPS[@]}")" '
        {apiVersion: "rbac.authorization.k8s.io/v1", kind: "ClusterRole",
         metadata: {name: $name, labels: {($label): "true"}},
         rules: [.rules[]
                 | select(((.apiGroups // []) + (.resources // []) | index("*")) | not)
                 | .apiGroups = ((.apiGroups // []) - $groups)
                 | .resources = [(.resources // [])[] | select(test($re) | not)]
                 | .verbs -= ["impersonate"]
                 | select((.apiGroups | length) > 0 and (.resources | length) > 0 and (.verbs | length) > 0)]}' \
    | apply
echo "[INFO] ClusterRole ${EDIT_ROLE} ready."

if ! oc get group "${GUEST_GROUP}" &>/dev/null; then
    [[ "${DRY_RUN}" == true ]] || oc adm groups new "${GUEST_GROUP}" >/dev/null
fi

# Bindings made by this run; what the group has beyond these is removed below.
DESIRED_BINDINGS=()
bind_namespace_role() {   # <namespace> <binding suffix> <role> [role kind, default ClusterRole]
    local name="${GUEST_GROUP}-$2"
    DESIRED_BINDINGS+=("$1/${name}")
    apply <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${name}
  namespace: $1
  labels: {${MANAGED_LABEL}: "true", ${GROUP_LABEL}: ${GUEST_GROUP}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ${4:-ClusterRole}, name: $3}
subjects:
- {apiGroup: rbac.authorization.k8s.io, kind: Group, name: ${GUEST_GROUP}}
YAML
}

bind_cluster_role() {   # <ClusterRole>
    DESIRED_BINDINGS+=("/${GUEST_GROUP}-$1")
    apply <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${GUEST_GROUP}-$1
  labels: {${MANAGED_LABEL}: "true", ${GROUP_LABEL}: ${GUEST_GROUP}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: $1}
subjects:
- {apiGroup: rbac.authorization.k8s.io, kind: Group, name: ${GUEST_GROUP}}
YAML
}

[[ -z "${OCP_CLUSTER_ROLE}" ]] || bind_cluster_role "${OCP_CLUSTER_ROLE}"

# cluster-reader doesn't include the monitoring query API; without these the
# console's Observe pages fail, Metrics with "Bad Request".
if [[ "${MONITORING_VIEW}" == true ]]; then
    bind_cluster_role cluster-monitoring-view
    bind_cluster_role monitoring-rules-view
    # For Observe > Targets; no stock role covers these.
    apply <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${MONITORING_TARGETS_ROLE}
  labels: {${MANAGED_LABEL}: "true"}
rules:
- {apiGroups: [monitoring.coreos.com], resources: [servicemonitors, podmonitors], verbs: [get, list, watch]}
YAML
    bind_cluster_role "${MONITORING_TARGETS_ROLE}"
    bind_namespace_role openshift-monitoring alertmanager-view monitoring-alertmanager-view Role
fi

for _ns in "${SOFTWARE_NAMESPACES[@]}"; do
    bind_namespace_role "${_ns}" edit "${EDIT_ROLE}"
done
unset _ns

if [[ -n "${WORKSPACE_NAMESPACE}" ]]; then
    if [[ "${DRY_RUN}" != true ]] || oc get namespace "${WORKSPACE_NAMESPACE}" &>/dev/null; then
        oc get namespace "${WORKSPACE_NAMESPACE}" &>/dev/null || oc create namespace "${WORKSPACE_NAMESPACE}" >/dev/null
        bind_namespace_role "${WORKSPACE_NAMESPACE}" admin admin
    else
        DESIRED_BINDINGS+=("${WORKSPACE_NAMESPACE}/${GUEST_GROUP}-admin")
    fi
fi

# The Kubecost login proxy lets in whoever can get Services in its namespace
# (the default of enable_kubecost_ui_login.sh).
if [[ "${KUBECOST_UI}" == true ]]; then
    _kc_namespaces=(${(fu)"$(oc get kubecosts.charts.kubecost.com -A -o json 2>/dev/null | jq -r '.items[].metadata.namespace' || true)"})
    if (( ${#_kc_namespaces} == 0 )); then
        echo "[WARN] KUBECOST_UI is on but no Kubecost instance was found."
    else
        apply <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${KUBECOST_UI_ROLE}
  labels: {${MANAGED_LABEL}: "true"}
rules:
- {apiGroups: [""], resources: [services], verbs: [get]}
YAML
        for _ns in "${_kc_namespaces[@]}"; do
            bind_namespace_role "${_ns}" kubecost-ui "${KUBECOST_UI_ROLE}"
        done
        unset _ns
    fi
    unset _kc_namespaces
fi

# Access the template no longer gives.
for _b in ${(f)"$(oc get rolebindings,clusterrolebindings -A -l "${GROUP_LABEL}=${GUEST_GROUP}" -o json \
        | jq -r '.items[] | [.kind, (.metadata.namespace // ""), .metadata.name] | join("|")')"}; do
    # '|', not a tab: read collapses empty fields between whitespace separators.
    IFS='|' read -r _kind _ns _name <<< "${_b}"
    (( ${DESIRED_BINDINGS[(Ie)${_ns}/${_name}]} )) && continue
    echo "[INFO] Removing ${_kind} ${_ns:+${_ns}/}${_name}: no longer in the template."
    [[ "${DRY_RUN}" == true ]] && continue
    _ns_args=()
    [[ -n "${_ns}" ]] && _ns_args=(-n "${_ns}")
    oc delete "${(L)_kind}" "${_name}" "${_ns_args[@]}" >/dev/null
done
unset _b _kind _ns _name _ns_args

# A pod can read any Secret in its namespace, so RBAC alone doesn't protect them.
# Matches this group only. An update that leaves the pod spec as it is always passes
# (rollout restart changes only the template's metadata; scale is a subresource).
_hint="${WORKSPACE_NAMESPACE:+ Use ${WORKSPACE_NAMESPACE} instead.}"
if (( ${#SOFTWARE_NAMESPACES} == 0 )); then
    if oc get validatingadmissionpolicy "${POLICY}" &>/dev/null; then
        echo "[INFO] Removing admission policy ${POLICY}: the template edits no namespaces."
        if [[ "${DRY_RUN}" != true ]]; then
            oc delete validatingadmissionpolicybinding "${POLICY}" --ignore-not-found >/dev/null
            oc delete validatingadmissionpolicy "${POLICY}" >/dev/null
        fi
    fi
else
apply <<YAML
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: ${POLICY}
  labels: {${MANAGED_LABEL}: "true"}
spec:
  failurePolicy: Fail
  matchConstraints:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: [${(j:, :)SOFTWARE_NAMESPACES}]
    resourceRules:
    - {apiGroups: [""], apiVersions: [v1], operations: [CREATE, UPDATE], resources: [pods, replicationcontrollers]}
    - {apiGroups: [apps], apiVersions: [v1], operations: [CREATE, UPDATE], resources: [deployments, statefulsets, daemonsets, replicasets]}
    - {apiGroups: [batch], apiVersions: [v1], operations: [CREATE, UPDATE], resources: [jobs, cronjobs]}
    - {apiGroups: [apps.openshift.io], apiVersions: [v1], operations: [CREATE, UPDATE], resources: [deploymentconfigs]}
  matchConditions:
  - name: guests-only
    expression: "'${GUEST_GROUP}' in request.userInfo.groups"
  variables:
  - name: spec
    expression: >-
      object.kind == 'Pod' ? object.spec :
      object.kind == 'CronJob' ? object.spec.jobTemplate.spec.template.spec :
      object.spec.template.spec
  - name: unchanged
    expression: >-
      request.operation == 'UPDATE' && variables.spec == (
      oldObject.kind == 'Pod' ? oldObject.spec :
      oldObject.kind == 'CronJob' ? oldObject.spec.jobTemplate.spec.template.spec :
      oldObject.spec.template.spec)
  - name: containers
    expression: >-
      variables.spec.containers +
      (has(variables.spec.initContainers) ? variables.spec.initContainers : [])
  validations:
  - expression: >-
      variables.unchanged ||
      ((!has(variables.spec.serviceAccountName) || variables.spec.serviceAccountName in ['', 'default']) &&
       (!has(variables.spec.serviceAccount) || variables.spec.serviceAccount in ['', 'default']))
    message: Guests can only run pods with the default service account here.${_hint}
  - expression: >-
      variables.unchanged || !has(variables.spec.volumes) ||
      variables.spec.volumes.all(v, has(v.emptyDir) || has(v.configMap) || has(v.downwardAPI) ||
        (has(v.projected) && v.projected.sources.all(s, !has(s.secret))))
    message: Guests can only mount emptyDir, ConfigMap and downward API volumes here.${_hint}
  - expression: >-
      variables.unchanged ||
      variables.containers.all(c,
        (!has(c.envFrom) || c.envFrom.all(e, !has(e.secretRef))) &&
        (!has(c.env) || c.env.all(e, !has(e.valueFrom) || !has(e.valueFrom.secretKeyRef))))
    message: Guests can't load Secrets into environment variables here.${_hint}
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: ${POLICY}
  labels: {${MANAGED_LABEL}: "true"}
spec:
  policyName: ${POLICY}
  validationActions: [Deny]
YAML
fi
unset _hint
echo "[INFO] OpenShift access for '${GUEST_GROUP}' ready."

# --- New accounts ---------------------------------------------------------------
# Every guest made so far, of any template, so set_htpasswd_users.sh keeps treating
# them as listed. Only this template's group gets its Software Hub access below.
ALL_GUESTS=()
if [[ -f "${CREDENTIALS_FILE}" ]]; then
    ALL_GUESTS=(${(f)"$(awk -F: -v p="${GUEST_PREFIX}" 'index($1, p) == 1 {print $1}' "${CREDENTIALS_FILE}")"})
fi
GUESTS=(${(f)"$(oc get group "${GUEST_GROUP}" -o json 2>/dev/null | jq -r '.users[]?' || true)"})

NEW_GUESTS=()
while (( ${#NEW_GUESTS} < COUNT )); do
    _u="${GUEST_PREFIX}$(openssl rand -hex 2)"
    (( ${NEW_GUESTS[(Ie)${_u}]} )) && continue
    [[ -n "${CURRENT_LINES[${_u}]:-}" ]] && continue
    oc get user "${_u}" &>/dev/null && continue
    NEW_GUESTS+=("${_u}")
done
unset _u

if (( ${#NEW_GUESTS} > 0 )); then
    echo "[INFO] New guests: ${NEW_GUESTS[*]}"
fi
if [[ "${DRY_RUN}" != true ]] && (( ${#NEW_GUESTS} > 0 )); then
    "${SCRIPT_DIR}/set_htpasswd_users.sh" "${IDP_ARGS[@]}" -c "${CREDENTIALS_FILE}" -l 20 \
        --no-print-passwords -u "${(j:,:)ALL_GUESTS},${(j:,:)NEW_GUESTS}"
    oc adm groups add-users "${GUEST_GROUP}" "${NEW_GUESTS[@]}" >/dev/null
    GUESTS+=("${NEW_GUESTS[@]}")
fi

fi   # SWH_ONLY

# --- Software Hub ---------------------------------------------------------------
swh_setup() {
    local role_id gid uid user code other
    if ! cpdapi_login "${CPD_URL}" "${CPD_USERNAME}" password "${CPD_PASSWORD}"; then
        echo "[ERROR] Could not get a Software Hub token for ${CPD_USERNAME} at ${CPD_URL}." >&2
        return 1
    fi

    cpdapi GET "/usermgmt/v1/roles"
    [[ "${API_CODE}" == 200 ]] || { echo "[ERROR] Listing Software Hub roles failed (HTTP ${API_CODE})." >&2; return 1; }
    local roles="${API_BODY}" wanted current body
    _role_id() { print -r -- "$1" | jq -r --arg n "${SWH_ROLE_NAME}" '[.rows[] | select(.doc.role_name == $n)][0].id // empty'; }
    role_id="$(_role_id "${roles}")"

    if (( ${#SWH_PERMISSIONS} > 0 )); then
        wanted="$(jq -cn '$ARGS.positional | unique' --args -- "${SWH_PERMISSIONS[@]}")"
    else
        wanted="$(print -r -- "${roles}" | jq -c --arg b "${SWH_BASE_ROLE}" \
            --argjson drop "$(jq -cn '$ARGS.positional' --args -- "${SWH_REMOVE_PERMISSIONS[@]}")" \
            '([.rows[] | select(.id == $b)][0].doc.permissions // []) - $drop | unique')"
        if [[ "${wanted}" == '[]' ]]; then
            echo "[ERROR] SWH_BASE_ROLE '${SWH_BASE_ROLE}' not found, or nothing is left of it." >&2; return 1
        fi
    fi
    cpdapi GET "/icp4d-api/v1/permissions"
    if [[ "${API_CODE}" == 200 ]]; then
        local unknown
        unknown="$(print -r -- "${API_BODY}" | jq -r --argjson w "${wanted}" '$w - .Permissions | join(" ")')"
        if [[ -n "${unknown}" ]]; then
            echo "[ERROR] Unknown Software Hub permission(s) in the template: ${unknown}" >&2; return 1
        fi
    else
        echo "[WARN] Could not read the permission list (HTTP ${API_CODE}); template permissions not checked."
    fi
    # A dynamic group with Administrator takes guests in at their first browser
    # login, on top of the template's role. API sign-ins don't show this.
    local g
    cpdapi GET "/usermgmt/v4/groups?offset=0&limit=100"
    for g in ${(f)"$(print -r -- "${API_BODY}" | jq -r '.results[]? | select(any(.roles[]?; .role_id == "zen_administrator_role")) | "\(.group_id)|\(.name)"')"}; do
        cpdapi GET "/usermgmt/v2/groups/${g%%|*}/membership_rules"
        if print -r -- "${API_BODY}" | jq -e --arg p "${GUEST_PREFIX%_}" 'any(.results[]?; has("rules")
                and (any(.rules[]; .attribute == "userName" and .operator == "not match" and .value == $p) | not))' >/dev/null; then
            echo "[WARN] Dynamic group '${g#*|}' gives Administrator and doesn't exclude guests. Add this to its rule:"
            echo "       {\"attribute\": \"userName\", \"operator\": \"not match\", \"value\": \"${GUEST_PREFIX%_}\"}"
        fi
    done
    if jq -e 'index("manage_vaults_and_secrets")' <<< "${wanted}" >/dev/null; then
        echo "[WARN] Role '${SWH_ROLE_NAME}' has manage_vaults_and_secrets, so its users can see all vault secrets."
    fi
    local drift=false
    if [[ -n "${role_id}" ]]; then
        current="$(print -r -- "${roles}" | jq -c --arg i "${role_id}" '[.rows[] | select(.id == $i)][0].doc.permissions | unique')"
        [[ "${current}" == "${wanted}" ]] || drift=true
    fi
    if [[ "${drift}" == true && "${SYNC_ROLE}" != true ]]; then
        echo "[WARN] Role '${SWH_ROLE_NAME}' differs from the template and is left as it is (--sync-role overwrites it)."
        echo "       Only on the cluster: $(jq -rn --argjson a "${current}" --argjson b "${wanted}" '$a - $b | join(" ")')"
        echo "       Only in the template: $(jq -rn --argjson a "${current}" --argjson b "${wanted}" '$b - $a | join(" ")')"
    fi
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[INFO] Software Hub role '${SWH_ROLE_NAME}' ($([[ -n "${role_id}" ]] && echo exists || echo would be created)): $(jq -r 'join(" ")' <<< "${wanted}")"
        (( ${#MOVE_USERS} == 0 )) || echo "[INFO] Would move from '${FROM_GROUP}' to '${GUEST_GROUP}': ${MOVE_USERS[*]}"
        return 0
    fi

    body="$(jq -cn --arg n "${SWH_ROLE_NAME}" --arg t "${TEMPLATE_FILE:t:r}" --argjson p "${wanted}" \
        '{role_name: $n, description: ("Guest role from template " + $t + " (create_guest_admin_users.sh)"), permissions: $p}')"
    if [[ -z "${role_id}" ]]; then
        cpdapi POST "/usermgmt/v1/role" "${body}"
        [[ "${API_CODE}" == 2* ]] || { echo "[ERROR] Creating role '${SWH_ROLE_NAME}' failed (HTTP ${API_CODE}): ${API_BODY}" >&2; return 1; }
        cpdapi GET "/usermgmt/v1/roles"
        role_id="$(_role_id "${API_BODY}")"
        [[ -n "${role_id}" ]] || { echo "[ERROR] Role '${SWH_ROLE_NAME}' was created but cannot be found." >&2; return 1; }
        echo "[INFO] Software Hub role '${SWH_ROLE_NAME}' created (${role_id})."
    elif [[ "${drift}" == true && "${SYNC_ROLE}" == true ]]; then
        cpdapi PUT "/usermgmt/v1/role/${role_id}" "${body}"
        [[ "${API_CODE}" == 2* ]] || { echo "[ERROR] Updating role '${SWH_ROLE_NAME}' failed (HTTP ${API_CODE}): ${API_BODY}" >&2; return 1; }
        echo "[INFO] Software Hub role '${SWH_ROLE_NAME}' updated to match the template."
    fi

    # Fails on an API error, so that isn't taken for "no such group" (100 is the API's maximum page).
    _group_id() {   # [group name, default GUEST_GROUP]
        local offset=0 id name="${1:-${GUEST_GROUP}}"
        while true; do
            cpdapi GET "/usermgmt/v4/groups?offset=${offset}&limit=100"
            [[ "${API_CODE}" == 200 ]] || return 1
            id="$(print -r -- "${API_BODY}" | jq -r --arg n "${name}" '[.results[] | select(.name == $n)][0].group_id // empty')"
            [[ -n "${id}" ]] && { print -r -- "${id}"; return 0; }
            (( $(print -r -- "${API_BODY}" | jq '.results | length') < 100 )) && return 0
            (( offset += 100 ))
        done
    }
    gid="$(_group_id)" || { echo "[ERROR] Listing Software Hub groups failed." >&2; return 1; }
    if [[ -z "${gid}" ]]; then
        cpdapi POST "/usermgmt/v2/groups" "$(jq -cn --arg n "${GUEST_GROUP}" --arg r "${role_id}" \
            '{name: $n, description: "Guests (create_guest_admin_users.sh)", role_identifiers: [$r]}')"
        [[ "${API_CODE}" == 2* ]] || { echo "[ERROR] Creating group '${GUEST_GROUP}' failed (HTTP ${API_CODE}): ${API_BODY}" >&2; return 1; }
        gid="$(_group_id)" || gid=""
        [[ -n "${gid}" ]] || { echo "[ERROR] Group '${GUEST_GROUP}' was created but cannot be found." >&2; return 1; }
        echo "[INFO] Software Hub group '${GUEST_GROUP}' created (id ${gid})."
    fi

    local from_gid=""
    if [[ -n "${FROM_GROUP}" ]]; then
        from_gid="$(_group_id "${FROM_GROUP}")" || { echo "[ERROR] Listing Software Hub groups failed." >&2; return 1; }
        [[ -n "${from_gid}" ]] || { echo "[ERROR] Software Hub group '${FROM_GROUP}' not found." >&2; return 1; }
    fi

    local failed=0
    for user in "${GUESTS[@]}"; do
        cpdapi GET "/usermgmt/v1/user/$(cpdapi_urlencode "${user}")"
        if [[ "${API_CODE}" == 404 && -n "${from_gid}" ]]; then
            echo "[ERROR] ${user}: not a Software Hub user, nothing to move." >&2
            (( ++failed )); continue
        elif [[ "${API_CODE}" == 404 ]]; then
            cpdapi POST "/usermgmt/v1/user" "$(jq -cn --arg u "${user}" --arg r "${role_id}" \
                '{username: $u, displayName: $u, email: ($u + "@guest.invalid"), authenticator: "external", user_roles: [$r]}')"
            if [[ "${API_CODE}" != 2* ]]; then
                echo "[ERROR] ${user}: adding to Software Hub failed (HTTP ${API_CODE}): ${API_BODY}" >&2
                (( ++failed )); continue
            fi
            cpdapi GET "/usermgmt/v1/user/$(cpdapi_urlencode "${user}")"
        fi
        uid="$(print -r -- "${API_BODY}" | jq -r '.uid // empty')"
        if [[ -z "${uid}" ]]; then
            echo "[ERROR] ${user}: no Software Hub uid (HTTP ${API_CODE})." >&2
            (( ++failed )); continue
        fi
        # Someone moved to another guest group stays in this template's OpenShift
        # group, so a normal run must not pull them back here.
        other="$(print -r -- "${API_BODY}" | jq -r --arg g "${GUEST_GROUP}" '[.groups[]?.name | select(startswith("guest-") and . != $g)] | join(" ")')"
        if [[ -z "${from_gid}" && -n "${other}" ]]; then
            echo "[INFO] ${user}: in Software Hub group ${other}, left there (--move-users changes that)."
            continue
        fi
        # The API wants numbers here, though /usermgmt/v1/user returns uid as a string.
        cpdapi POST "/usermgmt/v2/groups/${gid}/members" "$(jq -cn --arg i "${uid}" '{user_identifiers: [$i | tonumber]}')"
        code="${API_CODE}"
        if [[ "${code}" != 2* && "${code}" != 409 ]]; then
            echo "[ERROR] ${user}: adding to group '${GUEST_GROUP}' failed (HTTP ${code}): ${API_BODY}" >&2
            (( ++failed ))
        elif [[ -n "${from_gid}" ]]; then
            # Only once they are in the new group, so a failure never leaves them in neither.
            cpdapi DELETE "/usermgmt/v2/groups/${from_gid}/members/${uid}"
            if [[ "${API_CODE}" == 2* ]]; then
                echo "[INFO] ${user}: moved from '${FROM_GROUP}' to '${GUEST_GROUP}'."
            else
                echo "[ERROR] ${user}: leaving group '${FROM_GROUP}' failed (HTTP ${API_CODE}): ${API_BODY}" >&2
                (( ++failed ))
            fi
        fi
    done
    (( failed == 0 ))
}

SWH_STATUS="skipped"
if [[ "${SKIP_SWH}" != true && -n "${SWH_ROLE_NAME}" ]]; then
    : "${CPD_URL:?CPD_URL is not set, run 3.3.1_get_instance_creds.sh first}"
    : "${CPD_USERNAME:?CPD_USERNAME is not set, run 3.3.1_get_instance_creds.sh first}"
    : "${CPD_PASSWORD:?CPD_PASSWORD is not set, run 3.3.1_get_instance_creds.sh first}"
    if swh_setup; then
        SWH_STATUS="done"
    else
        SWH_STATUS="FAILED"
    fi
fi

if [[ "${DRY_RUN}" == true ]]; then
    echo "[INFO] Dry run finished. Names above are examples; a real run picks new ids."
    [[ "${SWH_STATUS}" != FAILED ]] || exit 1
    exit 0
fi

# --- Summary: names and locations only, never a password ------------------------
echo "[INFO] ---"
echo "[INFO] Guests in '${GUEST_GROUP}': ${GUESTS[*]:-none}"
[[ "${SWH_ONLY}" == true ]] || echo "[INFO] Console:      $(oc whoami --show-console 2>/dev/null || echo unknown) (login '${IDP_NAME}')"
[[ -z "${WORKSPACE_NAMESPACE}" ]] || echo "[INFO] Own namespace: ${WORKSPACE_NAMESPACE}"
echo "[INFO] Software Hub: ${SWH_STATUS}"
[[ "${SWH_ONLY}" == true ]] || echo "[INFO] Passwords:    ${CREDENTIALS_FILE}"
[[ "${SWH_STATUS}" != FAILED ]] || exit 1
