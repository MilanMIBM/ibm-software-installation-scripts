# CP4D advanced editor: everything in cp4d-editor plus managing CP4D projects,
# spaces, catalogs, data source definitions and service instances, adding
# external vaults, and monitoring. Same OpenShift and Kubecost access as
# cp4d-editor. Settings are explained in guest-admin.sh.
# Use with: create_guest_admin_users.sh --template cp4d-advanced-editor

TEMPLATE_DESCRIPTION="Advanced editor in CP4D, viewer of OpenShift, admin of Kubecost UI"

GUEST_GROUP="guest-cp4d-advanced-editors"
OCP_CLUSTER_ROLE="cluster-reader"
MONITORING_VIEW=true
EDIT_NAMESPACE_VARS=()
EDIT_NAMESPACES=()
WORKSPACE_NAMESPACE=""
KUBECOST_UI=true

SWH_ROLE_NAME="Guest CP4D Advanced Editor"
SWH_PERMISSIONS=(
    # Work in CP4D
    create_project create_space can_provision access_catalog
    add_catalog_assets_to_projects create_data_source_definitions
    # Manage CP4D
    manage_project manage_space manage_catalog manage_data_source_definitions
    manage_service_instances manage_user_runtimes add_vaults
    # Monitor and view the platform
    monitor_platform monitor_project monitor_space
    view_platform_health view_locations view_data_planes
)
SWH_BASE_ROLE=""
SWH_REMOVE_PERMISSIONS=()
