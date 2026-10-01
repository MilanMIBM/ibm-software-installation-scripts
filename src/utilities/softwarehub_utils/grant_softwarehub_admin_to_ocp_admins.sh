#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# Gives every OpenShift user who is an admin on the cluster the same access as
# REFERENCE_USER (cpadmin), in two places:
#
#   1. Software Hub   the reference user's platform roles (zen_administrator_role
#                     for cpadmin). These live in the Software Hub user database,
#                     not in OpenShift, so they are set through the usermgmt API.
#                     Users missing from Software Hub are added. Existing roles
#                     are kept, only missing ones are added.
#   2. OpenShift      the reference user's RoleBindings in the CPD instance
#                     projects (set up by 3.2_set_up_cpd_admin.sh). A no-op for
#                     cluster-admins, who already have these rights.
#
# An "admin" is a user from 'oc get users' bound to one of ADMIN_CLUSTER_ROLES
# through a ClusterRoleBinding, or through a RoleBinding in a CPD instance
# project, either directly or via an OpenShift group. Being admin of some other
# project (e.g. one the user created themselves) does not count.
#
# OpenShift users can only sign in to Software Hub when it uses OpenShift
# authentication (ROKS_ENABLED in the platform-auth-idp configmap).
#
# Needs CPD_URL / CPD_USERNAME / CPD_PASSWORD from cpd_instance_details.sh
# (written by 3.3.1_get_instance_creds.sh). Safe to re-run.
#
# Usage: grant_softwarehub_admin_to_ocp_admins.sh [--dry-run]

# --- Edit these ---------------------------------------------------------------
REFERENCE_USER="${CPD_ADMIN_USERNAME:-cpadmin}"
ADMIN_CLUSTER_ROLES=(cluster-admin admin)
# OpenShift user names to leave alone even if they are admins.
EXCLUDE_USERS=(
    # "someone@example.com"
)
MIRROR_OPENSHIFT_RBAC=true
DRY_RUN="${DRY_RUN:-false}"
# ------------------------------------------------------------------------------

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

: "${CPD_URL:?CPD_URL is not set, run 3.3.1_get_instance_creds.sh first}"
: "${CPD_USERNAME:?CPD_USERNAME is not set, run 3.3.1_get_instance_creds.sh first}"
: "${CPD_PASSWORD:?CPD_PASSWORD is not set, run 3.3.1_get_instance_creds.sh first}"

eval "${OC_LOGIN}"

INSTANCE_NAMESPACES=("${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}")
[[ -n "${PROJECT_CPD_INSTANCE_TETHERED:-}" ]] && INSTANCE_NAMESPACES+=("${PROJECT_CPD_INSTANCE_TETHERED}")

[[ "${DRY_RUN}" == true ]] && echo "[INFO] Dry run, nothing will be changed."

# --- Collect admin users and the reference user's RoleBindings ----------------
# Prints "USER<TAB>name" and "BINDING<TAB>namespace<TAB>binding<TAB>roleKind<TAB>roleName" lines.
_CLUSTER_STATE="$(python3 - "${REFERENCE_USER}" "${(j:,:)ADMIN_CLUSTER_ROLES}" "${(j:,:)EXCLUDE_USERS}" "${INSTANCE_NAMESPACES[@]}" <<'PY'
import json, subprocess, sys

ref, admin_roles, excluded, *namespaces = sys.argv[1:]
admin_roles = set(filter(None, admin_roles.split(",")))
excluded = set(filter(None, excluded.split(",")))

def items(*args):
    out = subprocess.run(["oc", "get", *args, "-o", "json"], capture_output=True, text=True)
    if out.returncode != 0:
        print(f"[WARN] oc get {' '.join(args)} failed: {out.stderr.strip()}", file=sys.stderr)
        return []
    return json.loads(out.stdout)["items"]

present = {u["metadata"]["name"] for u in items("users")}
groups = {g["metadata"]["name"]: g.get("users") or [] for g in items("groups")}
cluster_bindings = items("clusterrolebindings")
ns_bindings = [b for ns in namespaces for b in items("rolebindings", "-n", ns)]

admins = set()
for b in cluster_bindings + ns_bindings:
    if b["roleRef"]["kind"] != "ClusterRole" or b["roleRef"]["name"] not in admin_roles:
        continue
    for s in b.get("subjects") or []:
        if s["kind"] == "User":
            admins.add(s["name"])
        elif s["kind"] == "Group":
            admins.update(groups.get(s["name"], []))

for name in sorted((admins & present) - excluded - {ref}):
    print(f"USER\t{name}")

for b in ns_bindings:
    if any(s["kind"] == "User" and s["name"] == ref for s in b.get("subjects") or []):
        print("BINDING\t" + "\t".join((b["metadata"]["namespace"], b["metadata"]["name"],
                                        b["roleRef"]["kind"], b["roleRef"]["name"])))
PY
)"

ADMIN_USERS=(${(f)"$(print -r -- "${_CLUSTER_STATE}" | awk -F'\t' '$1 == "USER" {print $2}')"})
REF_BINDINGS=(${(f)"$(print -r -- "${_CLUSTER_STATE}" | awk -F'\t' '$1 == "BINDING" {print $2 "\t" $3 "\t" $4 "\t" $5}')"})
unset _CLUSTER_STATE

if (( ${#ADMIN_USERS} == 0 )); then
    echo "[INFO] No OpenShift users with ${(j:/:)ADMIN_CLUSTER_ROLES} rights found (besides ${REFERENCE_USER}). Nothing to do."
    exit 0
fi

echo "[INFO] OpenShift admins to grant ${REFERENCE_USER}'s access to:"
printf '         %s\n' "${ADMIN_USERS[@]}"

# --- 1. Software Hub roles ----------------------------------------------------
TOKEN="$(curl -k -s -X POST "${CPD_URL}/icp4d-api/v1/authorize" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${CPD_USERNAME}\",\"password\":\"${CPD_PASSWORD}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"

if [[ -z "${TOKEN}" ]]; then
    echo "[ERROR] Could not get a Software Hub token for ${CPD_USERNAME} at ${CPD_URL}." >&2
    exit 1
fi

# Usage: cpd_api METHOD PATH [JSON_BODY]. Sets API_CODE and API_BODY.
cpd_api() {
    local _resp _data=()
    [[ -n "${3:-}" ]] && _data=(-d "$3")
    _resp="$(curl -k -s -X "$1" "${CPD_URL}$2" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        "${_data[@]}" \
        -w '\n%{http_code}')"
    API_CODE="${_resp##*$'\n'}"
    API_BODY="${_resp%$'\n'*}"
}

urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
json_roles() { print -r -- "$1" | python3 -c 'import sys,json; print(" ".join(json.load(sys.stdin).get("user_roles") or []))'; }

cpd_api GET "/usermgmt/v1/user/$(urlencode "${REFERENCE_USER}")"
if [[ "${API_CODE}" != 200 ]]; then
    echo "[ERROR] Could not read Software Hub user '${REFERENCE_USER}' (HTTP ${API_CODE}): ${API_BODY}" >&2
    exit 1
fi
REF_ROLES=(${=$(json_roles "${API_BODY}")})
echo "[INFO] ${REFERENCE_USER} Software Hub roles: ${REF_ROLES[*]}"

FAILED=()
for _user in "${ADMIN_USERS[@]}"; do
    cpd_api GET "/usermgmt/v1/user/$(urlencode "${_user}")"

    if [[ "${API_CODE}" == 200 ]]; then
        _current=(${=$(json_roles "${API_BODY}")})
        _missing=(${REF_ROLES:|_current})
        if (( ${#_missing} == 0 )); then
            echo "[INFO] ${_user}: already has ${REF_ROLES[*]} in Software Hub."
            continue
        fi
        _body="$(python3 -c 'import json,sys; print(json.dumps({"user_roles": sys.argv[1:]}))' "${_current[@]}" "${_missing[@]}")"
        echo "[INFO] ${_user}: adding Software Hub roles ${_missing[*]}"
        [[ "${DRY_RUN}" == true ]] && continue
        cpd_api PUT "/usermgmt/v1/user/$(urlencode "${_user}")" "${_body}"

    elif [[ "${API_CODE}" == 404 ]]; then
        # Same shape as the records Software Hub creates for cpadmin/kubeadmin.
        _body="$(python3 -c 'import json,sys; u=sys.argv[1]; print(json.dumps({"username": u, "displayName": u, "email": u, "authenticator": "external", "user_roles": sys.argv[2:]}))' "${_user}" "${REF_ROLES[@]}")"
        echo "[INFO] ${_user}: not in Software Hub yet, adding with roles ${REF_ROLES[*]}"
        [[ "${DRY_RUN}" == true ]] && continue
        cpd_api POST "/usermgmt/v1/user" "${_body}"

    else
        echo "[ERROR] ${_user}: could not look up Software Hub user (HTTP ${API_CODE}): ${API_BODY}" >&2
        FAILED+=("${_user}")
        continue
    fi

    if [[ "${API_CODE}" != 2* ]]; then
        echo "[ERROR] ${_user}: Software Hub update failed (HTTP ${API_CODE}): ${API_BODY}" >&2
        FAILED+=("${_user}")
    fi
done
unset _user _current _missing _body

# --- 2. OpenShift RoleBindings ------------------------------------------------
if [[ "${MIRROR_OPENSHIFT_RBAC}" == true ]]; then
    if (( ${#REF_BINDINGS} == 0 )); then
        echo "[WARN] ${REFERENCE_USER} has no RoleBindings in ${INSTANCE_NAMESPACES[*]}, nothing to mirror."
    fi
    for _binding in "${REF_BINDINGS[@]}"; do
        IFS=$'\t' read -r _ns _name _kind _role <<< "${_binding}"
        _role_ns_arg=()
        [[ "${_kind}" == "Role" ]] && _role_ns_arg=(--role-namespace="${_ns}")
        for _user in "${ADMIN_USERS[@]}"; do
            echo "[INFO] ${_user}: ${_kind} '${_role}' in ${_ns} (RoleBinding ${_name})"
            [[ "${DRY_RUN}" == true ]] && continue
            # Re-using the binding name adds the user to cpadmin's existing RoleBinding.
            oc adm policy add-role-to-user "${_role}" "${_user}" \
                --namespace="${_ns}" "${_role_ns_arg[@]}" \
                --rolebinding-name="${_name}" >/dev/null
        done
    done
    unset _binding _ns _name _kind _role _role_ns_arg _user
fi

if (( ${#FAILED} > 0 )); then
    echo "[ERROR] Software Hub access could not be set for: ${FAILED[*]}" >&2
    exit 1
fi
echo "[INFO] Done."
