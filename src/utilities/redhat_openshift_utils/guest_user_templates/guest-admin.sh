# Guest admin: as close to admin as the cluster allows without reading its
# existing Secrets. Use with: create_guest_admin_users.sh --template guest-admin
#
# Copy this file to make a template; every setting is explained here. Pass a
# copy kept elsewhere by its path. Re-running the script with an edited template
# updates the group's access, including taking away what was removed.

TEMPLATE_DESCRIPTION="Read the whole cluster, edit all installed software, admin of Kubecost UI and Software Hub (no vault management)"

# Group in OpenShift and in Software Hub. Lowercase letters, digits and dashes.
# Each template needs its own.
GUEST_GROUP="guest-admins"

# ClusterRole bound cluster-wide; empty for none. A role that can read Secrets is
# refused, which rules out cluster-admin, admin and edit.
OCP_CLUSTER_ROLE="cluster-reader"

# true: the console's Observe pages work (metrics, alerts, dashboards), read-only.
# Metrics show the names of Secrets, not their contents.
MONITORING_VIEW=true

# Namespaces to edit, without Secrets. EDIT_NAMESPACE_VARS are patterns matched
# against the variable names in configs/*/*_vars.sh; EDIT_NAMESPACES are extra
# names. Namespaces not on the cluster are skipped, and openshift*, kube-* and
# default are never used. Empty both for no edit access.
EDIT_NAMESPACE_VARS=('PROJECT_*' '*_NAMESPACE')
EDIT_NAMESPACES=()

# Namespace owned by the group, where it has full admin including Secrets.
# Created if missing; empty for none.
WORKSPACE_NAMESPACE="guest-admins-workspace"

# true: can log in to the Kubecost UI. Kubecost has no viewer/admin split under
# OpenShift login, so this is full use of the UI.
KUBECOST_UI=true

# Software Hub role, created by name if missing (an existing one changes only
# with --sync-role); empty SWH_ROLE_NAME skips Software Hub. Either list SWH_PERMISSIONS, or leave it empty to take the
# permissions of SWH_BASE_ROLE minus SWH_REMOVE_PERMISSIONS. Names are checked
# against GET /icp4d-api/v1/permissions; labels and descriptions are in
# GET /zen-data/v1/extensions?extension_point_id=zen_permissions.
SWH_ROLE_NAME="Guest Administrator"
SWH_PERMISSIONS=()
SWH_BASE_ROLE="zen_administrator_role"
SWH_REMOVE_PERMISSIONS=(manage_vaults_and_secrets)
