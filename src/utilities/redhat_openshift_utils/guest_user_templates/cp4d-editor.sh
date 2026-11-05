# CP4D editor: work in CP4D (projects, spaces, catalogs, service instances), view
# Software Hub platform pages and OpenShift, use the Kubecost UI. CP4D access is
# all in the Software Hub role; OpenShift stays read-only. Settings are explained
# in guest-admin.sh. Use with: create_guest_admin_users.sh --template cp4d-editor

TEMPLATE_DESCRIPTION="Editor in CP4D, viewer of Software Hub and OpenShift, admin of Kubecost UI"

GUEST_GROUP="guest-cp4d-editors"
OCP_CLUSTER_ROLE="cluster-reader"
MONITORING_VIEW=true
EDIT_NAMESPACE_VARS=()
EDIT_NAMESPACES=()
WORKSPACE_NAMESPACE=""
KUBECOST_UI=true

SWH_ROLE_NAME="Guest CP4D Editor"
SWH_PERMISSIONS=(
    # CP4D editor: the built-in Developer role
    sign_in_only create_project create_space can_provision
    access_catalog add_catalog_assets_to_projects
    # Software Hub viewer
    view_platform_health view_locations view_data_planes
)
SWH_BASE_ROLE=""
SWH_REMOVE_PERMISSIONS=()
