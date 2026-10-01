#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

# Creates two OpenShift groups and gives them access to the cluster:
#   TEAM_GROUP     read-only on the whole cluster, plus 'edit' in EDIT_NAMESPACES
#   STUDENT_GROUP  read-only on the whole cluster
#
# Assumes 'oc' is already logged in as a cluster-admin. Safe to re-run: existing
# groups, members and bindings are left as they are.

# --- Edit these ---------------------------------------------------------------
TEAM_GROUP="dca-team"
STUDENT_GROUP="dca-students"

# Must match the OpenShift User name exactly (see 'oc get users'), normally the
# IBMid email. Users can be added before their first login.
TEAM_USERS=(
    # "user1@ibm.com"
    # "user2@ibm.com"
)
STUDENT_USERS=(
    # "student@example.com"
)

# Namespaces where TEAM_GROUP may create, change and delete things. Leave empty
# for read-only everywhere. 'edit' also lets them read the secrets in that
# namespace, so adding the CP4D instance namespace exposes its admin credentials.
EDIT_NAMESPACES=(
    # "my-sandbox"
)
# To add others to newly created projects run the command below, or add the project to EDIT_NAMESPACES above and re-run the script.
# oc adm policy add-role-to-group edit dca-team -n <project>

# By default anyone who can log in may create their own projects. Set to true to
# take that away, so a login without group membership can do nothing.
DISABLE_SELF_PROVISIONER=true
# ------------------------------------------------------------------------------

echo "[INFO] Target cluster: $(oc whoami --show-server)"
echo "[INFO] Logged in as:   $(oc whoami)"

if [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" != "yes" ]]; then
    echo "[ERROR] The current user is not a cluster-admin." >&2
    exit 1
fi

ensure_group() {
    local group="$1"; shift

    if oc get group "${group}" &>/dev/null; then
        echo "[INFO] Group '${group}' already exists."
    else
        oc adm groups new "${group}"
    fi

    if (( $# > 0 )); then
        oc adm groups add-users "${group}" "$@"
    else
        echo "[WARN] No users listed for '${group}', it is empty."
    fi
}

ensure_group "${TEAM_GROUP}" "${TEAM_USERS[@]}"
ensure_group "${STUDENT_GROUP}" "${STUDENT_USERS[@]}"

# Cluster-wide read-only. cluster-reader does not include reading secrets.
oc adm policy add-cluster-role-to-group cluster-reader "${TEAM_GROUP}"
oc adm policy add-cluster-role-to-group cluster-reader "${STUDENT_GROUP}"

# Write access, one RoleBinding per namespace.
for _ns in "${EDIT_NAMESPACES[@]}"; do
    if ! oc get namespace "${_ns}" &>/dev/null; then
        echo "[ERROR] Namespace '${_ns}' does not exist, skipping." >&2
        continue
    fi
    oc adm policy add-role-to-group edit "${TEAM_GROUP}" -n "${_ns}"
done
unset _ns

if [[ "${DISABLE_SELF_PROVISIONER}" == true ]]; then
    # The annotation stops OpenShift restoring the default subjects on restart.
    oc patch clusterrolebinding.rbac self-provisioners -p '{"subjects": null}'
    oc annotate clusterrolebinding.rbac self-provisioners \
        rbac.authorization.kubernetes.io/autoupdate=false --overwrite
    echo "[INFO] Self-provisioning of projects is disabled for everyone by default."
fi

# TEAM_GROUP may still create new projects; the creator becomes admin of their
# own project. Uses its own binding so the patch above never wipes it on re-run.
oc adm policy add-cluster-role-to-group self-provisioner "${TEAM_GROUP}" \
    --rolebinding-name="${TEAM_GROUP}-self-provisioner"

echo "[INFO] ---"
oc get groups "${TEAM_GROUP}" "${STUDENT_GROUP}"
