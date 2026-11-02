#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ASSET_DIR="${SCRIPT_DIR}/dynamic_user_groups"  # env_bootstrap.sh reassigns SCRIPT_DIR
# Load only the CP4D config (cpd_vars.sh) so another configs/*/ file can't
# redirect OC_LOGIN to a different cluster. Override with ENV_TARGET=<name|path>.
: "${ENV_TARGET:=cpd}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/cpd_api_helpers.sh"

# Creates or updates a Software Hub *dynamic* user group: membership is a rule
# that usermgmt re-evaluates at every login, so new holders of the permission
# join and former holders drop out without re-running anything. The default
# run makes "tzadmin": users who sign in through the OpenShift identity
# provider and are bound to the cluster-admin ClusterRole (directly or through
# an OpenShift group) get the Administrator role.
#
# OpenShift groups and RBAC never reach the Identity Management Service (IAM),
# so they are fed to Software Hub by a small custom attribute provider this
# script deploys in the instance namespace (dynamic_user_groups/
# ocp_rbac_attribute_provider.py). usermgmt calls it at login and gets:
#   ocp_cluster_roles       ClusterRoles bound cluster-wide   ",cluster-admin,self-provisioner,"
#   ocp_namespace_roles     RoleBindings in the instance namespaces   ",cpdata-operands/admin,"
#   ocp_groups              OpenShift groups                  ",ocp-users,"
#   ocp_identity_providers  OpenShift OAuth providers used    ",IBMid,"
# Rules use "match ,<value>," so "admin" never matches "cluster-admin".
# The IAM identity provider (realm) comes from IAM itself: "OpenShift", or the
# realm name of an LDAP / SAML / OIDC connection.
#
# Rules reference raw attribute paths, so they keep working when the zen
# operator resets attributes-configmap (which only feeds the UI rule editor;
# re-run this script to put the UI entries back). If the provider is down,
# its attributes are empty and members drop out at their next login.
# Plan: .claude/plans/softwarehub-dynamic-user-groups-plan.md
#
# Needs a cluster-admin oc login (OC_LOGIN) and CPD_URL / CPD_USERNAME /
# CPD_PASSWORD from cpd_instance_details.sh (3.3.1_get_instance_creds.sh).
# Safe to re-run.
#
#   set_dynamic_user_group.sh                          tzadmin: OpenShift users with cluster-admin -> Administrator
#   set_dynamic_user_group.sh --group=ns-admins --namespace-role=cpdata-operands/admin --role=Administrator
#   set_dynamic_user_group.sh --group=ibmid-admins --ocp-idp=IBMid --cluster-role=cluster-admin
#   set_dynamic_user_group.sh --group=devs --ocp-group=developers --role=zen_developer_role --role=zen_user_role
#   set_dynamic_user_group.sh --group=ldap-ops --idp=<IAM realm> --rule=ocp_groups:match:,ops,
#
#   --group=<name>            group to create/update (default tzadmin)
#   --description=<text>
#   --idp=openshift|any|<realm>   IAM identity provider the users must come from (default openshift)
#   --ocp-idp=<name>          also require this OpenShift OAuth provider (e.g. IBMid, htpasswdId)
#   --cluster-role=<role>     permission: ClusterRoleBinding to <role> (repeatable)
#   --namespace-role=<ns>/<role>  permission: RoleBinding in an instance namespace (repeatable)
#   --ocp-group=<group>       permission: OpenShift group membership (repeatable)
#   --rule=<attr>:<op>:<value>    raw rule; op is equal, "not equal", match, "not match" (repeatable)
#   --match=all|any           all conditions (default) or any of them
#   --role=<id or name>       Software Hub role for the group (repeatable, default zen_administrator_role)
#   --check-user=<username>   show the user's provider attributes and which dynamic groups match; no changes
#   --status                  provider, extension, UI attributes and all dynamic groups; no changes
#   --provider-only           install/update the attribute provider only
#   --remove-group            delete --group
#   --uninstall               remove the attribute provider (groups are kept, but lose ocp_* members)
#   --dry-run                 print what would change

# --- Edit these ---------------------------------------------------------------
GROUP_NAME="tzadmin"
GROUP_DESCRIPTION=""
IDP="openshift"
OCP_IDP=""
DEFAULT_CLUSTER_ROLE="cluster-admin"   # used when no permission flag is given
DEFAULT_ROLES=(zen_administrator_role)
MATCH="all"
PROVIDER_NAME="ocp-rbac-attribute-provider"
EXT_NAME="ocp-rbac-attributes"         # zen-ext-attribute-provider-secret keys: <EXT_NAME>_token / _certificate
PROVIDER_REPLICAS=2
PROVIDER_SOURCES="openshift_rbac"
# Empty = the python:3.12-ubi9 image from the cluster's openshift imagestream.
ATTR_PROVIDER_IMAGE="${ATTR_PROVIDER_IMAGE:-}"
REGISTER_UI_ATTRIBUTES=true
# ------------------------------------------------------------------------------

REALM_PATH='["urn:ietf:params:scim:schemas:extension:ibmcp:2.0:User"].realmName'
PROVIDER_SECRET="zen-ext-attribute-provider-secret"
ACTION="apply"
DRY_RUN=false
CLUSTER_ROLES=() NAMESPACE_ROLES=() OCP_GROUPS=() RAW_RULES=() ROLES=()
CHECK_USER=""

for _arg in "$@"; do
    case "${_arg}" in
        --group=*)          GROUP_NAME="${_arg#*=}" ;;
        --description=*)    GROUP_DESCRIPTION="${_arg#*=}" ;;
        --idp=*)            IDP="${_arg#*=}" ;;
        --ocp-idp=*)        OCP_IDP="${_arg#*=}" ;;
        --cluster-role=*)   CLUSTER_ROLES+=("${_arg#*=}") ;;
        --namespace-role=*) NAMESPACE_ROLES+=("${_arg#*=}") ;;
        --ocp-group=*)      OCP_GROUPS+=("${_arg#*=}") ;;
        --rule=*)           RAW_RULES+=("${_arg#*=}") ;;
        --match=*)          MATCH="${_arg#*=}" ;;
        --role=*)           ROLES+=("${_arg#*=}") ;;
        --check-user=*)     ACTION="check-user"; CHECK_USER="${_arg#*=}" ;;
        --status)           ACTION="status" ;;
        --provider-only)    ACTION="provider-only" ;;
        --remove-group)     ACTION="remove-group" ;;
        --uninstall)        ACTION="uninstall" ;;
        --dry-run|--preview=true) DRY_RUN=true ;;
        -h|--help)          sed -n '/^# Creates or updates/,/^# --- Edit these/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument: ${_arg} (see --help)" >&2; exit 1 ;;
    esac
done
unset _arg
[[ "${MATCH}" == (all|any) ]] || { echo "[ERROR] --match must be all or any" >&2; exit 1; }
(( ${#CLUSTER_ROLES} + ${#NAMESPACE_ROLES} + ${#OCP_GROUPS} + ${#RAW_RULES} == 0 )) && CLUSTER_ROLES=("${DEFAULT_CLUSTER_ROLE}")
(( ${#ROLES} == 0 )) && ROLES=("${DEFAULT_ROLES[@]}")

NS="${PROJECT_CPD_INST_OPERANDS:?PROJECT_CPD_INST_OPERANDS is not set}"
INSTANCE_NAMESPACES=("${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}")
[[ -n "${PROJECT_CPD_INSTANCE_TETHERED:-}" ]] && INSTANCE_NAMESPACES+=("${PROJECT_CPD_INSTANCE_TETHERED}")
PROVIDER_URL="https://${PROVIDER_NAME}.${NS}.svc:8443"
LABELS_JSON='{"app.kubernetes.io/name":"'"${PROVIDER_NAME}"'","app.kubernetes.io/managed-by":"set_dynamic_user_group.sh"}'
[[ "${DRY_RUN}" == true ]] && echo "[INFO] Dry run, nothing will be changed."

run() { if [[ "${DRY_RUN}" == true ]]; then echo "[DRY-RUN] $*"; else "$@"; fi; }

# =============================================================================
# Preflight
# =============================================================================
eval "${OC_LOGIN}"
if [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" != "yes" ]]; then
    echo "[ERROR] The current oc user is not a cluster-admin." >&2
    exit 1
fi
if [[ "$(oc get zenservice -n "${NS}" -o jsonpath='{.items[0].spec.iamIntegration}' 2>/dev/null)" != "true" ]]; then
    echo "[ERROR] Software Hub in ${NS} is not integrated with the Identity Management Service" >&2
    echo "        (ZenService spec.iamIntegration). Dynamic user groups need it." >&2
    exit 1
fi

cpd_login() {
    : "${CPD_URL:?CPD_URL is not set, run 3.3.1_get_instance_creds.sh first}"
    : "${CPD_USERNAME:?CPD_USERNAME is not set}"
    : "${CPD_PASSWORD:?CPD_PASSWORD is not set}"
    cpdapi_login "${CPD_URL}" "${CPD_USERNAME}" password "${CPD_PASSWORD}" \
        || { echo "[ERROR] Could not get a Software Hub token for ${CPD_USERNAME} at ${CPD_URL}." >&2; exit 1; }
}

# =============================================================================
# Attribute provider
# =============================================================================
secret_key() {   # <key> -> decoded value ("" if absent)
    oc get secret "${PROVIDER_SECRET}" -n "${NS}" -o json 2>/dev/null \
        | python3 -c 'import sys,json,base64; d=(json.load(sys.stdin).get("data") or {}).get(sys.argv[1]); print(base64.b64decode(d).decode() if d else "", end="")' "$1" 2>/dev/null || true
}

# Sets <key> in the shared provider secret (no trailing newline: usermgmt sends
# the file content as is). Returns 0 when it changed.
secret_set() {   # <key> <value>
    [[ "$(secret_key "$1")" == "$2" ]] && return 1
    echo "[INFO] Setting ${PROVIDER_SECRET}/$1"
    [[ "${DRY_RUN}" == true ]] && return 0
    oc get secret "${PROVIDER_SECRET}" -n "${NS}" &>/dev/null \
        || oc create secret generic "${PROVIDER_SECRET}" -n "${NS}" >/dev/null
    oc label secret "${PROVIDER_SECRET}" -n "${NS}" app.kubernetes.io/managed-by=set_dynamic_user_group.sh --overwrite >/dev/null
    oc patch secret "${PROVIDER_SECRET}" -n "${NS}" --type merge \
        -p "{\"data\":{\"$1\":\"$(printf '%s' "$2" | base64 | tr -d '\n')\"}}" >/dev/null
}

provider_image() {
    if [[ -n "${ATTR_PROVIDER_IMAGE}" ]]; then print -r -- "${ATTR_PROVIDER_IMAGE}"; return; fi
    # The upstream digest the imagestream points at, not the internal registry
    # copy (that registry is often disabled).
    local ref
    ref="$(oc get is python -n openshift -o jsonpath='{.status.tags[?(@.tag=="3.12-ubi9")].items[0].dockerImageReference}' 2>/dev/null || true)"
    print -r -- "${ref:-registry.redhat.io/ubi9/python-312:latest}"
}

# Every provider object except the secret and the ZenExtension, as a JSON List.
provider_manifests() {
    python3 - "${NS}" "${PROVIDER_NAME}" "${EXT_NAME}" "$(provider_image)" "${PROVIDER_REPLICAS}" \
        "${(j:,:)INSTANCE_NAMESPACES}" "${PROVIDER_SOURCES}" "${LABELS_JSON}" \
        "${ASSET_DIR}/ocp_rbac_attribute_provider.py" <<'PY'
import hashlib, json, sys
ns, name, ext, image, replicas, namespaces, sources, labels, code_file = sys.argv[1:]
labels = json.loads(labels)
code = open(code_file).read()
meta = lambda n, **kw: {"name": n, "namespace": ns, "labels": labels, **kw}
sel = {"app.kubernetes.io/name": name}
items = [
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta(f"{name}-code"), "data": {"provider.py": code}},
    {"apiVersion": "v1", "kind": "ConfigMap",
     "metadata": meta(f"{name}-ca", annotations={"service.beta.openshift.io/inject-cabundle": "true"})},
    {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta(name)},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole",
     "metadata": {"name": name, "labels": labels},
     "rules": [
         {"apiGroups": ["user.openshift.io"], "resources": ["users", "groups"], "verbs": ["get", "list"]},
         {"apiGroups": ["rbac.authorization.k8s.io"], "resources": ["clusterrolebindings", "rolebindings"], "verbs": ["get", "list"]},
     ]},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
     "metadata": {"name": name, "labels": labels},
     "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": name},
     "subjects": [{"kind": "ServiceAccount", "name": name, "namespace": ns}]},
    {"apiVersion": "v1", "kind": "Service",
     "metadata": meta(name, annotations={"service.beta.openshift.io/serving-cert-secret-name": f"{name}-tls"}),
     "spec": {"selector": sel, "ports": [{"name": "https", "port": 8443, "targetPort": 8443}]}},
    {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": meta(name),
     "spec": {
         "replicas": int(replicas),
         "selector": {"matchLabels": sel},
         "template": {
             "metadata": {"labels": labels,
                          "annotations": {"set-dynamic-user-group/code-sha": hashlib.sha256(code.encode()).hexdigest()[:16]}},
             "spec": {
                 "serviceAccountName": name,
                 "affinity": {"podAntiAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [
                     {"weight": 100, "podAffinityTerm": {"topologyKey": "kubernetes.io/hostname",
                                                         "labelSelector": {"matchLabels": sel}}}]}},
                 "containers": [{
                     "name": "provider",
                     "image": image,
                     "command": ["python3", "/app/provider.py"],
                     "env": [{"name": "NAMESPACES", "value": namespaces},
                             {"name": "SOURCES", "value": sources}],
                     "ports": [{"containerPort": 8443, "name": "https"}],
                     "readinessProbe": {"httpGet": {"path": "/healthz", "port": 8443, "scheme": "HTTPS"}, "periodSeconds": 10},
                     "livenessProbe": {"httpGet": {"path": "/healthz", "port": 8443, "scheme": "HTTPS"}, "periodSeconds": 30},
                     "resources": {"requests": {"cpu": "10m", "memory": "48Mi"}, "limits": {"cpu": "200m", "memory": "128Mi"}},
                     "securityContext": {"allowPrivilegeEscalation": False, "runAsNonRoot": True,
                                         "capabilities": {"drop": ["ALL"]}, "seccompProfile": {"type": "RuntimeDefault"}},
                     "volumeMounts": [{"name": "code", "mountPath": "/app"},
                                      {"name": "tls", "mountPath": "/etc/tls"},
                                      {"name": "token", "mountPath": "/etc/provider-token"}],
                 }],
                 "volumes": [
                     {"name": "code", "configMap": {"name": f"{name}-code"}},
                     {"name": "tls", "secret": {"secretName": f"{name}-tls"}},
                     {"name": "token", "secret": {"secretName": "zen-ext-attribute-provider-secret",
                                                  "items": [{"key": f"{ext}_token", "path": "token"}]}},
                 ],
             }}}},
]
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
PY
}

zen_extension_json() {
    python3 - "${NS}" "${PROVIDER_NAME}" "${EXT_NAME}" "${PROVIDER_URL}" "${LABELS_JSON}" <<'PY'
import json, sys
ns, name, ext, url, labels = sys.argv[1:]
ext_list = [{
    "extension_point_id": "attribute_provider",
    "extension_name": ext,
    "display_name": "OpenShift RBAC attributes",
    "details": {"url": url, "secretTokenKey": f"{ext}_token", "secretCertificateKey": f"{ext}_certificate"},
}]
print(json.dumps({"apiVersion": "zen.cpd.ibm.com/v1", "kind": "ZenExtension",
                  "metadata": {"name": name, "namespace": ns, "labels": json.loads(labels)},
                  "spec": {"extensions": json.dumps(ext_list, indent=2)}}))
PY
}

# UI entries for the rule editor. Returns 0 when attributes-configmap changed.
ui_attributes_apply() {   # add|remove
    local current new
    current="$(oc get cm attributes-configmap -n "${NS}" -o jsonpath='{.data.attributes_dictionary}')"
    new="$(print -r -- "${current}" | python3 -c '
import json, sys
mode, realm_path = sys.argv[1:]
d = json.load(sys.stdin)
attrs = d[0]
ours = {
    "idp_realm": ("Identity provider (IAM realm)", realm_path),
    "ocp_cluster_roles": ("OpenShift cluster roles", "ocp_cluster_roles"),
    "ocp_namespace_roles": ("OpenShift instance namespace roles", "ocp_namespace_roles"),
    "ocp_groups": ("OpenShift groups", "ocp_groups"),
    "ocp_identity_providers": ("OpenShift identity providers", "ocp_identity_providers"),
}
for key, (label, path) in ours.items():
    if mode == "remove":
        attrs.pop(key, None)
    else:
        attrs[key] = {"displayName": label, "attribute_type": "simple", "type": "string",
                      "enabled": True, "internal_only": False, "path": path}
print(json.dumps(d, indent=2))' "$1" "${REALM_PATH}")"
    [[ "$(print -r -- "${current}" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')" \
        == "$(print -r -- "${new}" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')" ]] && return 1
    echo "[INFO] Updating UI attributes in attributes-configmap ($1)"
    [[ "${DRY_RUN}" == true ]] && return 0
    oc patch cm attributes-configmap -n "${NS}" --type merge \
        -p "$(python3 -c 'import json,sys; print(json.dumps({"data": {"attributes_dictionary": sys.argv[1]}}))' "${new}")" >/dev/null
}

restart_usermgmt() {
    echo "[INFO] Restarting usermgmt so it picks up the attribute provider / attributes"
    run oc rollout restart deploy/usermgmt -n "${NS}"
    [[ "${DRY_RUN}" == true ]] && return 0
    oc rollout status deploy/usermgmt -n "${NS}" --timeout=600s
}

# Calls the provider from a usermgmt pod exactly like usermgmt does (axios,
# token and CA from the mounted secret). Prints the JSON attributes.
probe_provider() {   # <username>
    oc exec -n "${NS}" deploy/usermgmt -c usermgmt-container -- node -e '
const fs = require("fs"), https = require("https");
const axios = require("/usr/src/server-src/node_modules/axios");
const [url, ext, user] = process.argv.slice(1);
const d = "/etc/zen-ext-attribute-provider-secret/";
axios({ method: "GET", timeout: 20000,
        url: url + "/v1/external/usermgmt/attributes?username=" + user,
        headers: { Authorization: "Bearer " + fs.readFileSync(d + ext + "_token") },
        httpsAgent: new https.Agent({ ca: fs.readFileSync(d + ext + "_certificate") }) })
  .then(r => console.log(JSON.stringify(r.data)))
  .catch(e => { console.error(e.message); process.exit(1); });' "${PROVIDER_URL}" "${EXT_NAME}" "$1"
}

install_provider() {
    local changed=false token ca i

    # 1. Token first: the provider pod mounts it.
    token="$(secret_key "${EXT_NAME}_token")"
    [[ -z "${token}" ]] && token="$(openssl rand -hex 32)"
    secret_set "${EXT_NAME}_token" "${token}" && changed=true

    # 2. Provider objects.
    echo "[INFO] Applying attribute provider ${NS}/${PROVIDER_NAME} (image $(provider_image))"
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY-RUN] oc apply: $(provider_manifests | python3 -c 'import json,sys; print(", ".join(i["kind"]+"/"+i["metadata"]["name"] for i in json.load(sys.stdin)["items"]))')"
    else
        provider_manifests | oc apply -f - | sed 's/^/         /'
        oc rollout status deploy/"${PROVIDER_NAME}" -n "${NS}" --timeout=300s
    fi

    # 3. Service CA for usermgmt's TLS check.
    if [[ "${DRY_RUN}" != true ]]; then
        for i in {1..30}; do
            ca="$(oc get cm "${PROVIDER_NAME}-ca" -n "${NS}" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true)"
            [[ -n "${ca}" ]] && break
            sleep 2
        done
        [[ -z "${ca}" ]] && { echo "[ERROR] Service CA was not injected into ${PROVIDER_NAME}-ca." >&2; exit 1; }
        secret_set "${EXT_NAME}_certificate" "${ca}" && changed=true
    fi

    # 4. Register with Software Hub.
    local desired current
    desired="$(zen_extension_json)"
    current="$(oc get zenextension "${PROVIDER_NAME}" -n "${NS}" -o jsonpath='{.spec.extensions}' 2>/dev/null || true)"
    if [[ "${current}" != "$(print -r -- "${desired}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["spec"]["extensions"])')" ]]; then
        echo "[INFO] Registering ZenExtension ${PROVIDER_NAME} (attribute_provider ${EXT_NAME} -> ${PROVIDER_URL})"
        changed=true
        if [[ "${DRY_RUN}" != true ]]; then
            print -r -- "${desired}" | oc apply -f - >/dev/null
            local st=""
            for i in {1..60}; do
                st="$(oc get zenextension "${PROVIDER_NAME}" -n "${NS}" -o jsonpath='{.status.zenExtensionStatus}' 2>/dev/null || true)"
                [[ "${st}" == "Completed" || "${st}" == "Failed" ]] && break
                sleep 5
            done
            [[ "${st}" != "Completed" ]] && { echo "[ERROR] ZenExtension ${PROVIDER_NAME} status: ${st:-none}" >&2; exit 1; }
        fi
    fi

    # 5. UI attributes (cosmetic; rules work without them).
    [[ "${REGISTER_UI_ATTRIBUTES}" == true ]] && ui_attributes_apply add && changed=true

    [[ "${changed}" == true ]] && restart_usermgmt

    # 6. End-to-end probe through usermgmt's own network path, TLS and token.
    if [[ "${DRY_RUN}" != true ]]; then
        local probe_user
        probe_user="$(oc whoami)"
        echo "[INFO] Probing the provider from usermgmt as it would for '${probe_user}':"
        probe_provider "${probe_user}" | sed 's/^/         /' \
            || { echo "[ERROR] usermgmt cannot reach the attribute provider." >&2; exit 1; }
    fi
}

uninstall_provider() {
    echo "[INFO] Removing attribute provider ${PROVIDER_NAME}"
    run oc delete zenextension "${PROVIDER_NAME}" -n "${NS}" --ignore-not-found
    run oc delete deploy,svc,cm,sa -n "${NS}" -l app.kubernetes.io/name="${PROVIDER_NAME}" --ignore-not-found
    run oc delete secret "${PROVIDER_NAME}-tls" -n "${NS}" --ignore-not-found
    run oc delete clusterrole,clusterrolebinding "${PROVIDER_NAME}" --ignore-not-found
    if oc get secret "${PROVIDER_SECRET}" -n "${NS}" &>/dev/null; then
        run oc patch secret "${PROVIDER_SECRET}" -n "${NS}" --type json \
            -p "[{\"op\":\"remove\",\"path\":\"/data/${EXT_NAME}_token\"},{\"op\":\"remove\",\"path\":\"/data/${EXT_NAME}_certificate\"}]" 2>/dev/null || true
        if [[ "$(oc get secret "${PROVIDER_SECRET}" -n "${NS}" -o jsonpath='{.data}' 2>/dev/null)" == ("{}"|"") ]]; then
            run oc delete secret "${PROVIDER_SECRET}" -n "${NS}"
        fi
    fi
    ui_attributes_apply remove || true
    restart_usermgmt
    echo "[WARN] Dynamic groups whose rules use ocp_* attributes now match nobody; members drop out at their next login."
}

# =============================================================================
# Software Hub groups
# =============================================================================
# All groups as JSON list (v4 is paginated).
list_groups() {
    local offset=0 all="[]" page
    while true; do
        cpdapi GET "/usermgmt/v4/groups?offset=${offset}&limit=100"
        [[ "${API_CODE}" == 200 ]] || { echo "[ERROR] Listing groups failed (HTTP ${API_CODE}): ${API_BODY}" >&2; exit 1; }
        page="${API_BODY}"
        all="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]) + json.loads(sys.argv[2])["results"]))' "${all}" "${page}")"
        [[ "$(print -r -- "${page}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["results"]))')" -lt 100 ]] && break
        offset=$(( offset + 100 ))
    done
    print -r -- "${all}"
}

group_field() {   # <groups json> <name> <python expr on g>
    python3 -c 'import json,sys
g = next((g for g in json.loads(sys.argv[1]) if g["name"] == sys.argv[2]), None)
print("" if g is None else eval(sys.argv[3]))' "$1" "$2" "$3"
}

# Role ids for ROLES (ids or display names).
resolve_roles() {
    cpdapi GET "/usermgmt/v1/roles"
    [[ "${API_CODE}" == 200 ]] || { echo "[ERROR] Listing roles failed (HTTP ${API_CODE})" >&2; exit 1; }
    print -r -- "${API_BODY}" | python3 -c '
import json, sys
rows = json.load(sys.stdin)["rows"]
by = {}
for r in rows:
    by[r["id"].lower()] = r["id"]
    by[(r.get("doc") or {}).get("role_name", "").lower()] = r["id"]
bad = [a for a in sys.argv[1:] if a.lower() not in by]
if bad:
    sys.exit("[ERROR] Unknown Software Hub role(s): " + ", ".join(bad) + ". Known: " + ", ".join(sorted(r["id"] for r in rows)))
print(" ".join(dict.fromkeys(by[a.lower()] for a in sys.argv[1:])))' "${ROLES[@]}"
}

# The attribute_rules object for the flags.
build_rule() {
    python3 - "${MATCH}" "${IDP}" "${OCP_IDP}" "${REALM_PATH}" \
        "${(pj:\n:)CLUSTER_ROLES}" "${(pj:\n:)NAMESPACE_ROLES}" "${(pj:\n:)OCP_GROUPS}" "${(pj:\n:)RAW_RULES}" <<'PY'
import json, sys
match, idp, ocp_idp, realm_path, *lists = sys.argv[1:]
cluster_roles, ns_roles, ocp_groups, raw = [[v for v in l.split("\n") if v] for l in lists]
rules = []
if idp.lower() != "any":
    rules.append({"attribute": realm_path, "operator": "equal", "value": "OpenShift" if idp.lower() == "openshift" else idp})
if ocp_idp:
    rules.append({"attribute": "ocp_identity_providers", "operator": "match", "value": f",{ocp_idp},"})
rules += [{"attribute": "ocp_cluster_roles", "operator": "match", "value": f",{r},"} for r in cluster_roles]
rules += [{"attribute": "ocp_namespace_roles", "operator": "match", "value": f",{r},"} for r in ns_roles]
rules += [{"attribute": "ocp_groups", "operator": "match", "value": f",{g},"} for g in ocp_groups]
for r in raw:
    try:
        attr, op, value = r.split(":", 2)
    except ValueError:
        sys.exit(f"[ERROR] --rule '{r}' is not <attribute>:<operator>:<value>")
    if op not in ("equal", "not equal", "match", "not match"):
        sys.exit(f"[ERROR] --rule '{r}': operator must be equal, 'not equal', match or 'not match'")
    rules.append({"attribute": attr, "operator": op, "value": value})
for r in rules:
    if "'" in r["value"] or "'" in r["attribute"]:
        sys.exit("[ERROR] Rule values cannot contain a single quote (usermgmt stores rules unescaped).")
if match == "any" and idp.lower() != "any":
    print("[WARN] --match=any with an --idp filter: users from any realm who meet another condition also match.", file=sys.stderr)
print(json.dumps({"logical_operator": "and" if match == "all" else "or", "rules": rules}))
PY
}

describe_rule() {   # <attribute_rules json>
    print -r -- "$1" | python3 -c '
import json, sys
r = json.load(sys.stdin)
lo = r["logical_operator"]
for x in r["rules"]:
    a = "idp_realm" if x["attribute"].endswith("].realmName") else x["attribute"]
    print("           %3s  %s %s \"%s\"" % (lo, a, x["operator"], x["value"]))'
}

apply_group() {
    local rule role_ids groups gid existing_roles missing_roles rules_json rule_id current_rule static
    rule="$(build_rule)"
    role_ids=(${=$(resolve_roles)})
    echo "[INFO] Group '${GROUP_NAME}': roles ${role_ids[*]}, members when:"
    describe_rule "${rule}"

    groups="$(list_groups)"
    gid="$(group_field "${groups}" "${GROUP_NAME}" 'g["group_id"]')"
    if [[ -z "${gid}" ]]; then
        echo "[INFO] Creating group '${GROUP_NAME}'"
        if [[ "${DRY_RUN}" == true ]]; then echo "[DRY-RUN] POST /usermgmt/v2/groups, then its membership rule"; return; fi
        cpdapi POST "/usermgmt/v2/groups" "$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "description": sys.argv[2], "role_identifiers": sys.argv[3:]}))' \
            "${GROUP_NAME}" "${GROUP_DESCRIPTION:-Dynamic: ${IDP} users matching ${MATCH} of the rules (set_dynamic_user_group.sh)}" "${role_ids[@]}")"
        [[ "${API_CODE}" == 2* ]] || { echo "[ERROR] Creating group failed (HTTP ${API_CODE}): ${API_BODY}" >&2; exit 1; }
        gid="$(group_field "$(list_groups)" "${GROUP_NAME}" 'g["group_id"]')"
        [[ -n "${gid}" ]] || { echo "[ERROR] Group '${GROUP_NAME}' was created but cannot be found." >&2; exit 1; }
    else
        echo "[INFO] Group '${GROUP_NAME}' exists (id ${gid})"
        existing_roles=(${=$(group_field "${groups}" "${GROUP_NAME}" '" ".join(r["role_id"] for r in g.get("roles") or [])')})
        missing_roles=(${role_ids:|existing_roles})
        local extra=(${existing_roles:|role_ids})
        (( ${#extra} > 0 )) && echo "[WARN] Group also has roles not asked for (left in place): ${extra[*]}"
        if (( ${#missing_roles} > 0 )); then
            echo "[INFO] Adding roles ${missing_roles[*]}"
            if [[ "${DRY_RUN}" != true ]]; then
                cpdapi PATCH "/usermgmt/v2/groups/${gid}" "$(python3 -c 'import json,sys; print(json.dumps({"add_role_identifiers": sys.argv[1:]}))' "${missing_roles[@]}")"
                [[ "${API_CODE}" == 2* ]] || { echo "[ERROR] Adding roles failed (HTTP ${API_CODE}): ${API_BODY}" >&2; exit 1; }
            fi
        fi
    fi

    cpdapi GET "/usermgmt/v2/groups/${gid}/membership_rules"
    [[ "${API_CODE}" == 200 ]] || { echo "[ERROR] Reading membership rules failed (HTTP ${API_CODE}): ${API_BODY}" >&2; exit 1; }
    rules_json="${API_BODY}"
    static="$(print -r -- "${rules_json}" | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin)["results"] if "rules" not in r))')"
    if (( static > 0 )); then
        echo "[ERROR] Group '${GROUP_NAME}' has ${static} static member(s) or LDAP/IdP-group rule(s)." >&2
        echo "        A group is either assigned or dynamic; pick another --group name." >&2
        exit 1
    fi
    rule_id="$(print -r -- "${rules_json}" | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["results"] if "rules" in r]; print(r[0]["rule_id"] if r else "")')"
    current_rule="$(print -r -- "${rules_json}" | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["results"] if "rules" in r]; print(json.dumps({"logical_operator": r[0]["logical_operator"], "rules": r[0]["rules"]}, sort_keys=True) if r else "")')"
    if [[ "${current_rule}" == "$(print -r -- "${rule}" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')" ]]; then
        echo "[INFO] Membership rule is up to date"
        return
    fi
    local body
    body="$(python3 -c 'import json,sys; print(json.dumps({"attribute_rules": json.loads(sys.argv[1])}))' "${rule}")"
    if [[ -n "${rule_id}" ]]; then
        echo "[INFO] Updating membership rule ${rule_id}"
        [[ "${DRY_RUN}" == true ]] && return
        cpdapi PUT "/usermgmt/v2/groups/membership_rules/${rule_id}" "${body}"
    else
        echo "[INFO] Adding membership rule"
        [[ "${DRY_RUN}" == true ]] && return
        cpdapi POST "/usermgmt/v2/groups/${gid}/members" "${body}"
    fi
    [[ "${API_CODE}" == 2* ]] || { echo "[ERROR] Setting the membership rule failed (HTTP ${API_CODE}): ${API_BODY}" >&2; exit 1; }
}

remove_group() {
    local gid
    gid="$(group_field "$(list_groups)" "${GROUP_NAME}" 'g["group_id"]')"
    [[ -z "${gid}" ]] && { echo "[INFO] Group '${GROUP_NAME}' does not exist"; return; }
    echo "[INFO] Deleting group '${GROUP_NAME}' (id ${gid})"
    [[ "${DRY_RUN}" == true ]] && return
    cpdapi DELETE "/usermgmt/v2/groups/${gid}"
    [[ "${API_CODE}" == 2* ]] || { echo "[ERROR] Deleting group failed (HTTP ${API_CODE}): ${API_BODY}" >&2; exit 1; }
}

# Every dynamic group with its rule; with <attributes json>, also whether it
# matches (same evaluation as usermgmt's attributesToUserGroups).
show_dynamic_groups() {   # [attributes json]
    local groups gid name
    local -a pairs
    groups="$(list_groups)"
    pairs=(${(f)"$(print -r -- "${groups}" | python3 -c 'import json,sys; [print("%s\n%s" % (g["group_id"], g["name"])) for g in json.load(sys.stdin) if g.get("is_dynamic_group")]')"})
    (( ${#pairs} == 0 )) && { echo "[INFO] No dynamic user groups."; return; }
    for gid name in "${pairs[@]}"; do
        cpdapi GET "/usermgmt/v2/groups/${gid}/membership_rules"
        print -r -- "${API_BODY}" | python3 -c '
import json, re, sys
name, groups, attrs = sys.argv[1], json.loads(sys.argv[2]), (json.loads(sys.argv[3]) if sys.argv[3] else None)
g = next(g for g in groups if g["name"] == name)
roles = ", ".join(r["role_id"] for r in g.get("roles") or []) or "none"

def get(path):   # lodash.get for a.b / ["a"].b / [\x27a\x27].b
    cur = attrs
    for part in re.findall(r"\[[\"\x27]([^\"\x27]+)[\"\x27]\]|([^.\[\]]+)", path):
        key = part[0] or part[1]
        cur = cur.get(key) if isinstance(cur, dict) else None
    return cur

def ok(x):   # usermgmt attributesToUserGroups
    v = get(x["attribute"])
    if not isinstance(v, str):
        return False
    v, w = v.lower(), x["value"].lower()
    return {"equal": v == w, "not equal": v != w, "match": w in v, "not match": w not in v}[x["operator"]]

for r in [r for r in json.load(sys.stdin)["results"] if "rules" in r]:
    lo = r["logical_operator"]
    verdict = ""
    if attrs is not None:
        hits = [ok(x) for x in r["rules"]]
        verdict = "  -> MEMBER" if (all(hits) if lo == "and" else any(hits)) else "  -> not a member"
    print("[INFO] %s (id %s, roles: %s, members now: %s)%s" % (name, g["group_id"], roles, g.get("members_count"), verdict))
    for x in r["rules"]:
        a = "idp_realm" if x["attribute"].endswith("].realmName") else x["attribute"]
        mark = ("  ok " if ok(x) else "  no ") if attrs is not None else "     "
        print("       %s%3s  %s %s \"%s\"" % (mark, lo, a, x["operator"], x["value"]))
' "${name}" "${groups}" "${1:-}"
    done
}

show_status() {
    echo "== Attribute provider ${NS}/${PROVIDER_NAME}"
    oc get deploy "${PROVIDER_NAME}" -n "${NS}" -o jsonpath='   ready {.status.readyReplicas}/{.spec.replicas}  image {.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || echo "   not installed"
    echo "== ZenExtension"
    oc get zenextension "${PROVIDER_NAME}" -n "${NS}" -o jsonpath='   {.status.zenExtensionStatus}{"\n"}' 2>/dev/null || echo "   not registered"
    echo "== ${PROVIDER_SECRET} keys"
    oc get secret "${PROVIDER_SECRET}" -n "${NS}" -o json 2>/dev/null | python3 -c 'import json,sys; print("   " + ", ".join(sorted((json.load(sys.stdin).get("data") or {}).keys())))' || echo "   missing"
    echo "== UI attributes (attributes-configmap)"
    oc get cm attributes-configmap -n "${NS}" -o jsonpath='{.data.attributes_dictionary}' | python3 -c 'import json,sys; print("   " + ", ".join(json.load(sys.stdin)[0].keys()))'
    echo "== Dynamic groups"
    cpd_login
    show_dynamic_groups
}

check_user() {
    local attrs realm
    echo "[INFO] Provider attributes for '${CHECK_USER}' (fetched from a usermgmt pod):"
    attrs="$(probe_provider "${CHECK_USER}")" || { echo "[ERROR] Provider call failed." >&2; exit 1; }
    print -r -- "${attrs}" | python3 -c 'import json,sys; [print(f"         {k} = {v}") for k,v in json.load(sys.stdin).items()]'
    cpd_login
    cpdapi GET "/usermgmt/v1/user/$(cpdapi_urlencode "${CHECK_USER}")"
    realm="$(print -r -- "${API_BODY}" | python3 -c 'import json,sys; print(((json.load(sys.stdin).get("misc") or {}).get("realm_name")) or "")' 2>/dev/null || true)"
    if [[ "${API_CODE}" == 200 ]]; then
        echo "[INFO] Software Hub user: realm '${realm:-unknown}', roles $(print -r -- "${API_BODY}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("user_roles") or [])')"
    else
        echo "[INFO] '${CHECK_USER}' is not a Software Hub user yet (signs up at first login); realm assumed OpenShift."
        realm="OpenShift"
    fi
    attrs="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a["urn:ietf:params:scim:schemas:extension:ibmcp:2.0:User"]={"realmName": sys.argv[2]}; print(json.dumps(a))' "${attrs}" "${realm}")"
    echo "[INFO] Dynamic groups, evaluated as at the user's next login:"
    show_dynamic_groups "${attrs}"
}

# =============================================================================
case "${ACTION}" in
    status)        show_status ;;
    check-user)    check_user ;;
    provider-only) install_provider ;;
    uninstall)     uninstall_provider ;;
    remove-group)  cpd_login; remove_group ;;
    apply)
        install_provider
        cpd_login
        apply_group
        [[ "${DRY_RUN}" != true ]] && { echo "[INFO] Current dynamic groups:"; show_dynamic_groups; }
        echo "[INFO] Done. Members are (re)evaluated when they log in. Check someone with:"
        echo "         $(basename "$0") --check-user=<username>"
        ;;
esac
