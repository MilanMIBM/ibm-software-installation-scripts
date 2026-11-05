import marimo

__generated_with = "0.25.1"
app = marimo.App(
    width="full",
    app_title="Cloud Pak For Data - Setup Config Generator",
)

with app.setup:
    import marimo as mo
    import uuid
    import os


@app.cell
def _():
    widget_width = "30%"
    return (widget_width,)


@app.cell(hide_code=True)
def _():
    import sys

    parent_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    if parent_dir not in sys.path:
        sys.path.insert(0, parent_dir)

    from src.helpers.cp4d_id_options_templates import (
        cp4d_component_id_records,
        cp4d_license_entitlement_id_records,
        default_project_naming_conventions,
        default_private_registry_setup,
        default_local_registry_setup,
        default_swhub_control_center_separate_cluster,
        default_swhub_control_center_setup,
        image_group_id_records,
    )
    from src.helpers.marimo_sortablekv import sortable_kv
    from src.helpers.jinja2_template_rendering_helpers import (
        render_template_from_environment,
    )
    from src.helpers.swhub_control_center_config_render import (
        render_swhcc_vars,
        write_vars_file,
    )

    return (
        cp4d_component_id_records,
        cp4d_license_entitlement_id_records,
        default_local_registry_setup,
        default_private_registry_setup,
        default_project_naming_conventions,
        default_swhub_control_center_separate_cluster,
        default_swhub_control_center_setup,
        image_group_id_records,
        render_swhcc_vars,
        render_template_from_environment,
        sortable_kv,
        write_vars_file,
    )


@app.function
def records_to_dict(records):
    return {r["key"]: r["value"] for r in records}


@app.cell(hide_code=True)
def _():
    mo.md(r"""
    ## **Cloud Pak for Data** - Setup Config Generator
    """)
    return


@app.cell
def _(default_project_naming_conventions, sortable_kv):
    cp4d_install_project_naming_records = sortable_kv(
        label="Project Naming Specs:",
        value=default_project_naming_conventions,
        addable=False,
        removable=False,
        editable=True,
        movable=False,
    )

    # cp4d_install_project_naming_records
    return (cp4d_install_project_naming_records,)


@app.cell
def _(cp4d_install_project_naming_records):
    cp4d_install_project_naming = records_to_dict(
        cp4d_install_project_naming_records.value.get("value")
    )
    print(cp4d_install_project_naming)
    return


@app.cell
def _(
    default_local_registry_setup,
    default_private_registry_setup,
    image_pull_creds_select,
    sortable_kv,
):
    # The defaults follow the image source: an ICR-style cloud registry for
    # private, the registry inside the disconnected network for local.
    _local = image_pull_creds_select.selected_key == "Local Private Registry (air-gapped)"
    cp4d_private_registry_naming_records = sortable_kv(
        label=(
            "Local private registry (inside the disconnected network):"
            if _local
            else "If you are using a private registry:"
        ),
        value=default_local_registry_setup if _local else default_private_registry_setup,
        addable=False,
        removable=False,
        editable=True,
        movable=False,
    )

    # cp4d_private_registry_naming_records
    return (cp4d_private_registry_naming_records,)


@app.cell
def _(cp4d_private_registry_naming_records):
    cp4d_private_registry_naming = records_to_dict(
        cp4d_private_registry_naming_records.value.get("value")
    )
    print(cp4d_private_registry_naming)
    return (cp4d_private_registry_naming,)


@app.cell
def _():
    # Cluster options - Login and Architecture
    openshift_type_options = {
        "Self-Managed (Default)": "self-managed",
        "IBM Cloud": "roks",
        "Azure": "aro",
        "AWS": "rosa",
    }
    image_arch_options = {
        "x86-64": "amd64",
        "IBM Power": "ppc64le",
        "IBM Z": "s390x",
    }

    login_argument_options = {
        "Username/Password": "--username=${OCP_USERNAME} --password=${OCP_PASSWORD}",
        "Token": "--token=${OCP_TOKEN}",
    }

    # Credentials Options - Pull Secret

    # Image sources (CPD_IMAGE_SOURCE): entitled | private (cloud/remote registry)
    # | local (local private registry, air-gapped). The two private ones are
    # filled and wired by scripts/private_registry_mirroring/.
    image_pull_credentials = {
        "IBM Entitled Registry": '$(echo -n "cp:$IBM_ENTITLEMENT_KEY" | base64 -w 0)',
        "Private Container Registry": '$(echo -n "$PRIVATE_REGISTRY_PULL_USER:$PRIVATE_REGISTRY_PULL_PASSWORD" | base64 -w 0)',
        "Local Private Registry (air-gapped)": '$(echo -n "$PRIVATE_REGISTRY_PULL_USER:$PRIVATE_REGISTRY_PULL_PASSWORD" | base64 -w 0)',
    }

    # Storage options - Block Storage
    stg_class_block_options = {
        "OpenShift Data Foundation": "ocs-storagecluster-ceph-rbd",
        "OpenShift Data Foundation (External)": "ocs-external-storagecluster-ceph-rbd",
        "IBM Fusion Data Foundation": "ocs-storagecluster-ceph-rbd",
        "IBM Fusion Global Data Platform (Spectrum Scale)": "ibm-spectrum-scale-sc",
        "IBM Fusion Global Data Platform (Storage Fusion)": "ibm-storage-fusion-cp-sc",
        "IBM Storage Scale Container Native": "ibm-spectrum-scale-sc",
        "Portworx": "portworx-metastoredb-sc",
        "NFS": "managed-nfs-storage",
        "Amazon EBS (gp2)": "gp2-csi",
        "Amazon EBS (gp3)": "gp3-csi",
        "Nutanix": "nutanix-volume",
    }
    # Storage options - File Storage
    stg_class_file_options = {
        "OpenShift Data Foundation": "ocs-storagecluster-cephfs",
        "OpenShift Data Foundation (External)": "ocs-external-storagecluster-cephfs",
        "IBM Fusion Data Foundation": "ocs-storagecluster-cephfs",
        "IBM Fusion Global Data Platform (Spectrum Scale)": "ibm-spectrum-scale-sc",
        "IBM Fusion Global Data Platform (Storage Fusion)": "ibm-storage-fusion-cp-sc",
        "IBM Storage Scale Container Native": "ibm-spectrum-scale-sc",
        "Portworx": "portworx-rwx-gp3-sc",
        "NFS": "managed-nfs-storage",
        "Amazon Elastic File System": "efs-nfs-client",
        "Nutanix": "nutanix-file",
    }
    return (
        image_arch_options,
        image_pull_credentials,
        login_argument_options,
        openshift_type_options,
        stg_class_block_options,
        stg_class_file_options,
    )


@app.cell
def _(cp4d_private_registry_naming):
    custom_pull_prefix = list(cp4d_private_registry_naming.values())[0]
    return (custom_pull_prefix,)


@app.cell
def _(custom_pull_prefix, image_pull_creds_select):
    image_pull_prefix = (
        "icr.io"
        if image_pull_creds_select.selected_key == "IBM Entitled Registry"
        else custom_pull_prefix
    )
    print(image_pull_prefix)
    return


@app.cell(hide_code=True)
def _(custom_pull_prefix, image_pull_creds_select):
    # Same classifier as scripts/private_registry_mirroring (0.1_detect_registry.sh):
    # warn when the chosen source does not match the registry host.
    from src.helpers.registry_classifier import classify as _classify_registry

    _registry_check = None
    if (
        image_pull_creds_select.selected_key != "IBM Entitled Registry"
        and "<" not in str(custom_pull_prefix)
    ):
        _kind, _reason = _classify_registry(str(custom_pull_prefix))
        _chosen = (
            "local" if "Local" in image_pull_creds_select.selected_key else "private"
        )
        if _kind != "unknown" and _kind != _chosen:
            _registry_check = mo.callout(
                mo.md(
                    f"**{custom_pull_prefix}** looks like a **{_kind}** registry ({_reason}), "
                    f"but *{image_pull_creds_select.selected_key}* is selected."
                ),
                kind="warn",
            )
    _registry_check
    return


@app.cell(hide_code=True)
def _(ibm_entitlement_key_input):
    # Required with every image source: private/local registries are filled from
    # IBM's registry with this key (mirroring, CASE packages).
    _key_check = None
    if not str(ibm_entitlement_key_input.value or "").strip():
        _key_check = mo.callout(
            mo.md(
                "**IBM entitlement key is empty.** It is required with every image source - "
                "with a private or local registry it is still needed to pull the images from IBM "
                "for mirroring."
            ),
            kind="warn",
        )
    _key_check
    return


@app.cell
def _():
    widget_labels = {
        "cluster_type": "**Select your openshift cluster type**:",
        "cluster_arch": "**Select your openshift cluster hardware architecture:**",
        "login_arguments": "**Select how you want to login to the cluster:**",
        "pull_secrets": "**Select your pull secret type:**",
        "pull_secret_name": "**Select your pull secret variable name:**",
        "storage_block": "**Select your pull block storage class:**",
        "storage_file": "**Select your pull file storage class:**",
        "components_multiselect": "**Select all of the components you wish to install:**",
        "entitlements_multiselect": "**Select all of the license entitlements you wish to apply:**",
        "optional_images_multiselect": "**Select any optional models or images you wish to mirror:**",
        "prod_license": "Set licenses to **production** version?",
        "updating_components": "Are you updating **existing** components? **DO NOT** Select if installing a new instance.",
        "cp4d_version": "**Cloud Pak for Data version:**",
        "cp4d_patch": "**Patch ID (optional):** *[Check latest version here](https://github.com/IBM/software-hub/releases)*",
        "softwarehub_scale": "**Software Hub (zen) scale:**",
        "scheduler_scale": "**Scheduling service scale:**",
        "entitlement_key": "**Input your ibm entitlement key:** *[Get one here](https://myibm.ibm.com/products-services/containerlibrary)*",
        "cluster_url": "**Enter your openshift cluster url:**",
        "cluster_token": "**Enter your openshift token:**",
        "cluster_username": "**Enter your openshift cluster username:**",
        "cluster_password": "**Enter your openshift cluster password:**",
        "cpd_admin_username": "**Preselect your cp4d admin username:**",
        "review_and_save": "**Review or alter your config and save it and you're good to go!**",
        "include_install_options": "**Do you want to include customized install options?**",
        "swhcc_enable": "Set up **IBM Software Hub Control Center**? *Optional, needs IBM Software Hub Premium.*",
        "swhcc_chain": "Install it at the **end of the main install**? *Otherwise run its own full install script.*",
        "swhcc_autodetect": "**Auto-detect** the Software Hub instances on the cluster and add them? *A token-only cluster login needs one browser approval.*",
        "swhcc_cluster_admins": "Make all OpenShift **cluster-admins** Control Center admins? *Or list specific users in CONTROL_ADMIN_USERS below.*",
        "swhcc_indicator": "Deploy the **other workloads indicator**, so the other workloads account shows requests and usage? *Unsupported by IBM.*",
        "swhcc_cluster": "**Where does Control Center run?**",
        "swhcc_oauth_secret": "**OAuth client secret:**",
    }
    return (widget_labels,)


@app.cell
def _(
    block_storage_class_select,
    cluster_arch_select,
    cluster_type_select,
    cp4d_patch_input,
    cp4d_version_input,
    file_storage_class_select,
    image_pull_creds_select,
    login_argument_select,
    scheduler_scale_select,
    softwarehub_scale_select,
    widget_width,
):
    cluster_specs_stack = mo.vstack(
        [
            mo.hstack(
                [
                    cluster_type_select.style({"width": widget_width}),
                    cluster_arch_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    login_argument_select.style({"width": widget_width}),
                    block_storage_class_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    image_pull_creds_select.style({"width": widget_width}),
                    file_storage_class_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    cp4d_version_input.style({"width": widget_width}),
                    cp4d_patch_input.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    softwarehub_scale_select.style({"width": widget_width}),
                    scheduler_scale_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
        ]
    )
    return (cluster_specs_stack,)


@app.cell
def _(cluster_specs_stack):
    cluster_specs_stack
    return


@app.cell
def _(
    cluster_credentials_stack,
    cp4d_install_project_naming_records,
    cp4d_private_registry_naming_records,
):
    install_specs_accordion = mo.accordion(
        items={
            "**Cluster Credentials**": cluster_credentials_stack,
            "**Cluster Project Setup**": cp4d_install_project_naming_records,
            "*Private Registry Credentials* ***(optional)***": cp4d_private_registry_naming_records,
        },
        multiple=True,
    )

    install_specs_accordion
    return


@app.cell
def _(
    component_selection_tables,
    license_entitlement_table,
    licenses_are_prod_checkbox,
    optional_images_selection_tables,
    prepare_inst_options_stack,
    prod_license_check,
    updating_components_checkbox,
):
    component_specs_accordion = mo.accordion(
        items={
            "**License Entitlements**": mo.vstack(
                [
                    mo.md(
                        "The **production** and **non_production** columns show which license variants each entitlement can be applied as. Checking the box below applies the selected entitlements as production; leaving it unchecked applies them as non-production, except entitlements whose **non_production** is `false` - those are always applied as production."
                    ),
                    license_entitlement_table,
                    licenses_are_prod_checkbox.center(),
                    prod_license_check,
                ],
                gap=1,
            ).center(),
            "**Components to Install**": mo.vstack(
                [
                    component_selection_tables,
                    updating_components_checkbox,
                ],
                gap=1,
            )
            .style({"width": "60%"})
            .center(),
            "*Models & Images to Mirror* ***Optional***": optional_images_selection_tables.style(
                {"width": "60%"}
            ).center(),
            "*Include custom install options for components?* ***Optional***": prepare_inst_options_stack,
        },
        multiple=True,
    )
    component_specs_accordion
    return


@app.cell
def _(widget_labels):
    swhcc_enable_checkbox = mo.ui.checkbox(
        label=widget_labels.get("swhcc_enable"), value=False
    )
    return (swhcc_enable_checkbox,)


@app.cell
def _(widget_labels):
    swhcc_chain_checkbox = mo.ui.checkbox(
        label=widget_labels.get("swhcc_chain"), value=True
    )
    return (swhcc_chain_checkbox,)


@app.cell
def _(widget_labels):
    swhcc_autodetect_checkbox = mo.ui.checkbox(
        label=widget_labels.get("swhcc_autodetect"), value=True
    )
    return (swhcc_autodetect_checkbox,)


@app.cell
def _(widget_labels):
    swhcc_cluster_admins_checkbox = mo.ui.checkbox(
        label=widget_labels.get("swhcc_cluster_admins"), value=True
    )
    return (swhcc_cluster_admins_checkbox,)


@app.cell
def _(widget_labels):
    swhcc_indicator_checkbox = mo.ui.checkbox(
        label=widget_labels.get("swhcc_indicator"), value=True
    )
    return (swhcc_indicator_checkbox,)


@app.cell
def _(widget_labels):
    swhcc_cluster_select = mo.ui.dropdown(
        label=widget_labels.get("swhcc_cluster"),
        options={
            "Same cluster as Software Hub (Default)": "same",
            "A different cluster": "different",
        },
        value="Same cluster as Software Hub (Default)",
        allow_select_none=False,
        full_width=True,
    )
    return (swhcc_cluster_select,)


@app.cell
def _(widget_labels):
    swhcc_oauth_secret_input = mo.ui.text(
        label=widget_labels.get("swhcc_oauth_secret"),
        value=uuid.uuid4().hex,
        kind="password",
        full_width=False,
    )
    return (swhcc_oauth_secret_input,)


@app.cell
def _(default_swhub_control_center_setup, sortable_kv):
    swhcc_setup_records = sortable_kv(
        label="Control Center Specs:",
        value=default_swhub_control_center_setup,
        addable=False,
        removable=False,
        editable=True,
        movable=False,
    )
    return (swhcc_setup_records,)


@app.cell
def _(default_swhub_control_center_separate_cluster, sortable_kv):
    swhcc_cluster_records = sortable_kv(
        label="Control Center Cluster (use a token or a username and password):",
        value=default_swhub_control_center_separate_cluster,
        addable=False,
        removable=False,
        editable=True,
        movable=False,
    )
    return (swhcc_cluster_records,)


@app.cell
def _(
    swhcc_autodetect_checkbox,
    swhcc_chain_checkbox,
    swhcc_cluster_admins_checkbox,
    swhcc_cluster_records,
    swhcc_cluster_select,
    swhcc_enable_checkbox,
    swhcc_indicator_checkbox,
    swhcc_oauth_secret_input,
    swhcc_setup_records,
    widget_width,
):
    # The accordion only appears once the checkbox is selected.
    _different = swhcc_cluster_select.value == "different"
    _accordion = ""
    if swhcc_enable_checkbox.value:
        _accordion = mo.accordion(
            items={
                "*Software Hub Control Center* ***(optional)***": mo.vstack(
                    [
                        swhcc_chain_checkbox,
                        swhcc_autodetect_checkbox,
                        swhcc_cluster_admins_checkbox,
                        swhcc_indicator_checkbox,
                        swhcc_cluster_select.style({"width": widget_width}),
                        swhcc_setup_records,
                        swhcc_cluster_records if _different else "",
                        swhcc_oauth_secret_input,
                    ],
                    gap=1,
                )
            },
            multiple=True,
        )
    mo.vstack([swhcc_enable_checkbox.center(), _accordion], gap=1)
    return


@app.cell
def _(
    cp4d_patch_input,
    cp4d_version_input,
    swhcc_autodetect_checkbox,
    swhcc_cluster_admins_checkbox,
    swhcc_cluster_records,
    swhcc_cluster_select,
    swhcc_indicator_checkbox,
    swhcc_oauth_secret_input,
    swhcc_setup_records,
):
    _setup = records_to_dict(swhcc_setup_records.value.get("value"))
    _cluster = records_to_dict(swhcc_cluster_records.value.get("value"))
    swhcc_settings = {
        "cluster_mode": swhcc_cluster_select.value,
        "version": cp4d_version_input.value,
        "patch_id": cp4d_patch_input.value,
        "operators_project": _setup.get("CONTROL_PROJECT_OPERATORS"),
        "operands_project": _setup.get("CONTROL_PROJECT_OPERANDS"),
        "premium_tag": _setup.get("CONTROL_OLM_UTILS_TAG"),
        "oauth_client_id": _setup.get("CONTROL_OAUTH_CLIENT_ID"),
        "oauth_secret": swhcc_oauth_secret_input.value,
        "autodetect": str(swhcc_autodetect_checkbox.value).lower(),
        "cluster_display_name": _setup.get("CONTROL_CLUSTER_DISPLAY_NAME"),
        "account_name": _setup.get("CONTROL_AUTODETECT_ACCOUNT_NAME"),
        "account_allocation": _setup.get("CONTROL_AUTODETECT_ACCOUNT_ALLOCATION"),
        "account_cpu": _setup.get("CONTROL_AUTODETECT_ACCOUNT_CPU"),
        "account_memory_gi": _setup.get("CONTROL_AUTODETECT_ACCOUNT_MEMORY_GI"),
        "other_account_name": _setup.get("CONTROL_AUTODETECT_OTHER_ACCOUNT_NAME"),
        "instance_quota": _setup.get("CONTROL_AUTODETECT_INSTANCE_QUOTA"),
        "quota_headroom": _setup.get("CONTROL_AUTODETECT_QUOTA_HEADROOM"),
        "indicator": str(swhcc_indicator_checkbox.value).lower(),
        "indicator_project": _setup.get("CONTROL_OTHER_WORKLOADS_INDICATOR_PROJECT"),
        "indicator_image": _setup.get("CONTROL_OTHER_WORKLOADS_INDICATOR_IMAGE"),
        "rotate_api_keys": _setup.get("CONTROL_AUTODETECT_ROTATE_API_KEYS"),
        "verify_wait_seconds": _setup.get("CONTROL_AUTODETECT_VERIFY_WAIT_SECONDS"),
        "add_cluster_admins": str(swhcc_cluster_admins_checkbox.value).lower(),
        "admin_users": _setup.get("CONTROL_ADMIN_USERS"),
        "admin_roles": _setup.get("CONTROL_ADMIN_ROLES"),
        "admin_exclude_users": _setup.get("CONTROL_ADMIN_EXCLUDE_USERS"),
        "ocp_url": _cluster.get("CONTROL_OCP_URL"),
        "ocp_username": _cluster.get("CONTROL_OCP_USERNAME"),
        "ocp_password": _cluster.get("CONTROL_OCP_PASSWORD"),
        "ocp_token": _cluster.get("CONTROL_OCP_TOKEN"),
        "image_arch": _cluster.get("CONTROL_IMAGE_ARCH"),
        "stg_block": _cluster.get("CONTROL_STG_CLASS_BLOCK"),
        "stg_file": _cluster.get("CONTROL_STG_CLASS_FILE"),
        "license_project": _cluster.get("CONTROL_PROJECT_LICENSE_SERVICE"),
        "scheduler_project": _cluster.get("CONTROL_PROJECT_SCHEDULING_SERVICE"),
    }
    return (swhcc_settings,)


@app.cell
def _(run_button):
    mo.hstack(
        [run_button],
        justify="center",
        gap=20,
    )
    return


@app.cell
def _():
    return


@app.cell
def _(openshift_type_options, widget_labels):
    cluster_type_select = mo.ui.dropdown(
        label=widget_labels.get("cluster_type"),
        options=openshift_type_options,
        value=list(openshift_type_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )

    # cluster_type_select.style({"width": widget_width})
    return (cluster_type_select,)


@app.cell
def _(image_arch_options, widget_labels):
    cluster_arch_select = mo.ui.dropdown(
        label=widget_labels.get("cluster_arch"),
        options=image_arch_options,
        value=list(image_arch_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )

    # cluster_arch_select.style({"width": widget_width})
    return (cluster_arch_select,)


@app.cell
def _(login_argument_options, widget_labels):
    login_argument_select = mo.ui.dropdown(
        label=widget_labels.get("login_arguments"),
        options=login_argument_options,
        value=list(login_argument_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )

    # login_argument_select.style({"width": widget_width})
    return (login_argument_select,)


@app.cell
def _(image_pull_credentials, widget_labels):
    image_pull_creds_select = mo.ui.dropdown(
        label=widget_labels.get("pull_secrets"),
        options=image_pull_credentials,
        value=list(image_pull_credentials.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )

    # image_pull_creds_select.style({"width": widget_width})
    return (image_pull_creds_select,)


@app.cell
def _():
    return


@app.cell
def _(stg_class_block_options, widget_labels):
    block_storage_class_select = mo.ui.dropdown(
        label=widget_labels.get("storage_block"),
        options=stg_class_block_options,
        value=list(stg_class_block_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )

    # block_storage_class_select.style({"width": widget_width})
    return (block_storage_class_select,)


@app.cell
def _(stg_class_file_options, widget_labels):
    file_storage_class_select = mo.ui.dropdown(
        label=widget_labels.get("storage_file"),
        options=stg_class_file_options,
        value=list(stg_class_file_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )

    # file_storage_class_select.style({"width": widget_width})
    return (file_storage_class_select,)


@app.cell
def _():
    # license_entitlement_multiselect = mo.ui.multiselect(
    #     label=widget_labels.get("license_entitlements"),
    #     options=cp4d_license_entitlement_id_options,
    #     value=[cp4d_license_entitlement_id_options[0]],
    #     full_width=True,
    # )

    # license_entitlement_multiselect.style({"width": widget_width})
    return


@app.cell
def _(cp4d_license_entitlement_id_records, widget_labels):
    license_entitlement_table = mo.ui.table(
        label=widget_labels.get("license_entitlements"),
        data=cp4d_license_entitlement_id_records,
        selection="multi",
        page_size=50,
        initial_selection=[
            _i
            for _i, _r in enumerate(cp4d_license_entitlement_id_records)
            if _r["license_id"]
            in (
                "cpd-enterprise",
                "watsonx-ai",
                "watsonx-data",
                "watsonx-data-premium",
                "watsonx-orchestrate",
            )
        ],
    )

    # license_entitlement_table.center()
    return (license_entitlement_table,)


@app.cell
def _(license_entitlement_table):
    entitlements_to_apply = [
        item["license_id"] for item in license_entitlement_table.value
    ]
    print(entitlements_to_apply)
    entitlements_to_apply_str = ",".join(entitlements_to_apply)
    print(entitlements_to_apply_str)
    return


@app.cell(hide_code=True)
def _(license_entitlement_table, licenses_are_prod_checkbox):
    # Same rule as cpdent_production_flag (3.4_apply_entitlements.sh): entitlements
    # without a non-production variant get no --production flag, i.e. production.
    _prod_only = [
        item["license_id"]
        for item in license_entitlement_table.value
        if not item["non_production"]
    ]
    prod_license_check = ""
    if not licenses_are_prod_checkbox.value and _prod_only:
        prod_license_check = mo.callout(
            mo.md(
                "**No non-production variant:** "
                + ", ".join(f"`{e}`" for e in _prod_only)
                + " - these are applied as **production** even with the box unchecked."
            ),
            kind="warn",
        )
    return (prod_license_check,)


@app.cell
def _():
    # install_components_multiselect = mo.ui.multiselect(
    #     label=widget_labels.get("components_multiselect"),
    #     options=cp4d_component_id_options,
    #     value=["ibm-licensing", "scheduler", "cpd_platform", "cpfs"],
    #     full_width=True,
    # )

    # install_components_multiselect.style({"width": widget_width})
    return


@app.cell
def _(cp4d_component_id_records, widget_labels):
    install_component_table_1 = mo.ui.table(
        label=widget_labels.get("components_multiselect"),
        data=cp4d_component_id_records[: (len(cp4d_component_id_records) // 2)],
        selection="multi",
        page_size=60,
        # initial_selection=[0, 1, 2, 3],
    )

    # install_component_table.style({"width": widget_width})
    return (install_component_table_1,)


@app.cell
def _(cp4d_component_id_records):
    install_component_table_2 = mo.ui.table(
        label="Apply the appropriate license entitlements in the license table.",
        data=cp4d_component_id_records[(len(cp4d_component_id_records) // 2) :],
        selection="multi",
        page_size=60,
        # initial_selection=[0, 1, 2, 3],
    )
    return (install_component_table_2,)


@app.cell
def _(install_component_table_1, install_component_table_2):
    component_selection_tables = mo.hstack(
        [install_component_table_1, install_component_table_2],
        justify="space-around",
        widths=[0.5, 0.5],
    )

    # component_selection_tables.style({"width": "60%"}).center()
    return (component_selection_tables,)


@app.cell
def _(install_component_table_1, install_component_table_2):
    components_to_install = [
        item["component_id"]
        for item in install_component_table_1.value + install_component_table_2.value
    ]
    print(components_to_install)
    components_to_install_str = ",".join(components_to_install)
    print(components_to_install_str)
    return


@app.cell
def _():
    # optional_images_multiselect = mo.ui.multiselect(
    #     label=widget_labels.get("optional_images_multiselect"),
    #     options=image_group_ids,
    #     full_width=True,
    # )

    # optional_images_multiselect.style({"width": widget_width})
    return


@app.cell
def _(image_group_id_records, widget_labels):
    optional_images_table_1 = mo.ui.table(
        label=widget_labels.get("optional_images_multiselect"),
        data=image_group_id_records[: (len(image_group_id_records) // 2)],
        selection="multi",
        page_size=45,
    )
    return (optional_images_table_1,)


@app.cell
def _(image_group_id_records):
    optional_images_table_2 = mo.ui.table(
        label="Only do this if you need to mirror optional images or are deploying LLMs.",
        data=image_group_id_records[(len(image_group_id_records) // 2) :],
        selection="multi",
        page_size=45,
    )
    return (optional_images_table_2,)


@app.cell
def _(optional_images_table_1, optional_images_table_2):
    optional_images_selection_tables = mo.hstack(
        [
            optional_images_table_1,
            optional_images_table_2,
        ],
        justify="space-around",
        widths=[0.5, 0.5],
    )

    # optional_images_selection_tables.style({"width": "60%"}).center()
    return (optional_images_selection_tables,)


@app.cell
def _(optional_images_table_1, optional_images_table_2):
    optional_images = [
        item["image_group_id"]
        for item in optional_images_table_1.value + optional_images_table_2.value
    ]
    print(optional_images)
    optional_images_str = ",".join(optional_images)
    print(optional_images_str)
    return


@app.cell
def _(
    cluster_password_input,
    cluster_token_input,
    cluster_url_input,
    cluster_username_input,
    cpd_admin_username_input,
    ibm_entitlement_key_input,
    pull_secret_name_input,
):
    cluster_credentials_stack = mo.hstack(
        [
            mo.vstack(
                [
                    cluster_url_input,
                    cluster_password_input,
                    cluster_username_input,
                    cluster_token_input,
                ],
                # align="start",
                # justify="space-around",
            ),
            mo.vstack(
                [
                    "",
                    ibm_entitlement_key_input,
                    pull_secret_name_input,
                    cpd_admin_username_input,
                ],
                # align="start",
                justify="end",
            ),
        ],
        justify="space-around",
        widths=[0.4, 0.4],
    )
    return (cluster_credentials_stack,)


@app.cell
def _():
    # cluster_credentials_stack
    return


@app.cell
def _(widget_labels):
    licenses_are_prod_checkbox = mo.ui.checkbox(
        label=widget_labels.get("prod_license"), value=False
    )
    return (licenses_are_prod_checkbox,)


@app.cell
def _(widget_labels):
    updating_components_checkbox = mo.ui.checkbox(
        label=widget_labels.get("updating_components"), value=False
    )
    return (updating_components_checkbox,)


@app.cell
def _(widget_labels):
    cp4d_version_input = mo.ui.text(
        label=widget_labels.get("cp4d_version"),
        value="5.4.0",
        full_width=True,
    )
    return (cp4d_version_input,)


@app.cell
def _(widget_labels):
    cp4d_patch_input = mo.ui.text(
        label=widget_labels.get("cp4d_patch"),
        full_width=True,
    )
    return (cp4d_patch_input,)


@app.cell
def _(widget_labels):
    softwarehub_scale_select = mo.ui.dropdown(
        label=widget_labels.get("softwarehub_scale"),
        options=["level_2", "level_3", "level_4"],
        value="level_3",
        allow_select_none=False,
        full_width=True,
    )
    return (softwarehub_scale_select,)


@app.cell
def _(widget_labels):
    scheduler_scale_select = mo.ui.dropdown(
        label=widget_labels.get("scheduler_scale"),
        options=["level_2", "level_3", "level_4"],
        value="level_3",
        allow_select_none=False,
        full_width=True,
    )
    return (scheduler_scale_select,)


@app.cell
def _(widget_labels):
    cluster_url_input = mo.ui.text(
        label=widget_labels.get("cluster_url"),
        kind="url",
        full_width=True,
    )

    # cluster_url_input.style({"width": widget_width})
    return (cluster_url_input,)


@app.cell
def _(widget_labels):
    cluster_username_input = mo.ui.text(
        label=widget_labels.get("cluster_username"),
        value="kubeadmin",
        kind="text",
        full_width=False,
    )

    # cluster_username_input
    return (cluster_username_input,)


@app.cell
def _(widget_labels):
    cluster_password_input = mo.ui.text(
        label=widget_labels.get("cluster_password"),
        kind="password",
        full_width=False,
    )

    # cluster_password_input
    return (cluster_password_input,)


@app.cell
def _(widget_labels):
    cluster_token_input = mo.ui.text(
        label=widget_labels.get("cluster_token"),
        kind="password",
        full_width=False,
    )

    # cluster_token_input
    return (cluster_token_input,)


@app.cell
def _(widget_labels):
    ibm_entitlement_key_input = mo.ui.text(
        label=widget_labels.get("entitlement_key"),
        kind="password",
        full_width=False,
    )

    # ibm_entitlement_key_input
    return (ibm_entitlement_key_input,)


@app.cell
def _(widget_labels):
    pull_secret_name_input = mo.ui.text(
        label=widget_labels.get("pull_secret_name"),
        value="pull-secret",
        kind="text",
        full_width=False,
    )

    # pull_secret_name_input.style({"width": widget_width})
    return (pull_secret_name_input,)


@app.cell
def _(widget_labels):
    cpd_admin_username_input = mo.ui.text(
        label=widget_labels.get("cpd_admin_username"),
        value="cpadmin",
        kind="text",
        full_width=False,
    )

    # cpd_admin_username_input
    return (cpd_admin_username_input,)


@app.cell
def _():
    run_button = mo.ui.run_button(label="**Generate Variable File**")
    return (run_button,)


@app.cell
def _():
    save_to_config_dir_button = mo.ui.run_button(
        label="**Save directly to ./configs/cp4d_config/**", kind="neutral"
    )
    return (save_to_config_dir_button,)


@app.cell
def _(render_template_from_environment, run_button):
    rendered_variables_file_cpd = (
        render_template_from_environment(
            template_path="src/helpers/config_file_jinja2_templates/cpd_variable_template.sh.j2"
        )
        if run_button.value
        else ""
    )
    return (rendered_variables_file_cpd,)


@app.cell
def _(rendered_variables_file_cpd):
    cpd_vars_template_editor = mo.ui.code_editor(
        label="> **Edit your cpd_vars.sh file template.** \n",
        value=rendered_variables_file_cpd,
        language="bash",
        show_copy_button=True,
        theme="dark",
        max_height=1000,
        disabled=(not rendered_variables_file_cpd),
    )
    return (cpd_vars_template_editor,)


@app.cell
def _(render_swhcc_vars, run_button, swhcc_enable_checkbox, swhcc_settings):
    rendered_variables_file_swhcc = (
        render_swhcc_vars(swhcc_settings)
        if run_button.value and swhcc_enable_checkbox.value
        else ""
    )
    return (rendered_variables_file_swhcc,)


@app.cell
def _(rendered_variables_file_swhcc, swhcc_enable_checkbox):
    swhcc_vars_template_editor = mo.ui.code_editor(
        label="> **Edit your swhub_control_center_vars.sh file template.** \n",
        value=rendered_variables_file_swhcc,
        language="bash",
        show_copy_button=True,
        theme="dark",
        max_height=1000,
        disabled=(not swhcc_enable_checkbox.value),
    )
    return (swhcc_vars_template_editor,)


@app.cell
def _(
    cpd_vars_template_editor,
    inst_options_template_editor,
    save_file_stack,
    swhcc_enable_checkbox,
    swhcc_vars_template_editor,
):
    config_stack_cpd = mo.vstack(
        [
            cpd_vars_template_editor,
            inst_options_template_editor,
            swhcc_vars_template_editor if swhcc_enable_checkbox.value else "",
            save_file_stack,
        ]
    )
    return (config_stack_cpd,)


@app.cell
def _(config_stack_cpd):
    config_file_accordion_cpd = mo.accordion(
        items={"**Review & Save Results**": config_stack_cpd}
    )
    config_file_accordion_cpd
    return


@app.cell
def _():
    name_variable_file_cpd = mo.ui.text(
        label="**Name your variable file:**",
        value="cpd_vars",
        max_length=256,  # full_width=True
    )
    return (name_variable_file_cpd,)


@app.cell
def _(name_variable_file_cpd):
    cpd_vars_filename = (
        f"{name_variable_file_cpd.value}.sh"
        if name_variable_file_cpd.value
        else f"cpd_vars_{uuid.uuid4().hex[:4]}.sh"
    )
    return (cpd_vars_filename,)


@app.cell
def _(cpd_vars_filename, cpd_vars_template_editor):
    save_config_cpd = mo.download(
        data=cpd_vars_template_editor.value.encode("utf-8"),
        filename=cpd_vars_filename,
        mimetype="application/x-sh",
        label="**Save your cpd-vars.sh file**",
    )
    return (save_config_cpd,)


@app.cell
def _(swhcc_enable_checkbox, swhcc_vars_template_editor):
    save_config_swhcc = mo.download(
        data=swhcc_vars_template_editor.value.encode("utf-8"),
        filename="swhub_control_center_vars.sh",
        mimetype="application/x-sh",
        label="**Save your swhub_control_center_vars.sh file**",
        disabled=(not swhcc_enable_checkbox.value),
    )
    return (save_config_swhcc,)


@app.cell
def _(
    name_variable_file_cpd,
    save_config_cpd,
    save_config_inst_options,
    save_config_swhcc,
    save_to_config_dir_button,
):
    save_file_stack = mo.hstack(
        [
            name_variable_file_cpd,
            save_config_cpd,
            save_config_inst_options,
            save_config_swhcc,
            save_to_config_dir_button,
        ],
        justify="space-around",
        align="center",
        gap=15,
    )
    return (save_file_stack,)


@app.cell
def _(install_options_addon, name_variable_file_inst_options):
    prepare_inst_options_stack = mo.hstack(
        [name_variable_file_inst_options, install_options_addon],
        justify="space-around",
        gap=15,
    )
    return (prepare_inst_options_stack,)


@app.cell
def _(widget_labels):
    install_options_addon = mo.ui.checkbox(
        label=widget_labels.get("include_install_options"), value=True
    )
    return (install_options_addon,)


@app.cell
def _():
    name_variable_file_inst_options = mo.ui.text(
        label="**Name your install-options file:**",
        value="install-options",
        max_length=256,  # full_width=True
    )
    return (name_variable_file_inst_options,)


@app.cell
def _(name_variable_file_inst_options):
    inst_options_filename = (
        f"{name_variable_file_inst_options.value}.yml"
        if name_variable_file_inst_options.value
        else "install-options.yml"
    )
    return (inst_options_filename,)


@app.cell
def _(
    inst_options_filename,
    inst_options_template_editor,
    install_options_addon,
):
    save_config_inst_options = mo.download(
        data=inst_options_template_editor.value.encode("utf-8"),
        filename=inst_options_filename,
        mimetype="application/x-yml",
        label="**Save your install-options.yml file**",
        disabled=(not install_options_addon.value),
    )
    return (save_config_inst_options,)


@app.cell
def _(install_options_addon, render_template_from_environment, run_button):
    rendered_variables_file_inst_options = (
        render_template_from_environment(
            template_path="src/helpers/config_file_jinja2_templates/install_options_template_v2.sh.j2"
        )
        if run_button.value and install_options_addon.value
        else ""
    )
    return (rendered_variables_file_inst_options,)


@app.cell
def _(install_options_addon, rendered_variables_file_inst_options):
    inst_options_template_editor = mo.ui.code_editor(
        label="> **Edit your install-options.yml file template which needs to be put in your cpd-cli/work directory.** \n",
        value=rendered_variables_file_inst_options,
        language="bash",
        show_copy_button=True,
        theme="dark",
        max_height=1000,
        disabled=(not install_options_addon.value),
    )
    return (inst_options_template_editor,)


@app.cell
def _(
    cpd_vars_filename,
    cpd_vars_template_editor,
    inst_options_filename,
    inst_options_template_editor,
    install_options_addon,
    render_swhcc_vars,
    render_template_from_environment,
    save_to_config_dir_button,
    swhcc_enable_checkbox,
    swhcc_settings,
    swhcc_vars_template_editor,
    write_vars_file,
):
    # Save what is in the editors so manual edits are kept; only fall back to
    # rendering the templates when "Generate" has not been clicked yet.
    _save_result = None
    if save_to_config_dir_button.value:
        _config_dir = os.path.join(os.path.dirname(__file__), "configs", "cp4d_config")
        os.makedirs(_config_dir, exist_ok=True)

        _cpd_vars_content = (
            cpd_vars_template_editor.value
            or render_template_from_environment(
                template_path="src/helpers/config_file_jinja2_templates/cpd_variable_template.sh.j2"
            )
        )
        _cpd_vars_path = os.path.join(_config_dir, cpd_vars_filename)
        with open(_cpd_vars_path, "w") as _f:
            _f.write(_cpd_vars_content)

        _saved = [_cpd_vars_path]

        if install_options_addon.value:
            _inst_opts_content = (
                inst_options_template_editor.value
                or render_template_from_environment(
                    template_path="src/helpers/config_file_jinja2_templates/install_options_template_v2.sh.j2"
                )
            )
            _inst_opts_path = os.path.join(_config_dir, inst_options_filename)
            with open(_inst_opts_path, "w") as _f:
                _f.write(_inst_opts_content)
            _saved.append(_inst_opts_path)

        # In its own subfolder, so the regular install never loads it.
        if swhcc_enable_checkbox.value:
            _swhcc_path = os.path.join(
                _config_dir, "swhub_control_center", "swhub_control_center_vars.sh"
            )
            write_vars_file(
                _swhcc_path,
                swhcc_vars_template_editor.value or render_swhcc_vars(swhcc_settings),
            )
            _saved.append(_swhcc_path)

        _save_result = mo.callout(
            mo.md(
                "**Saved to `./configs/cp4d_config/`:**\n"
                + "\n".join(f"- `{p}`" for p in _saved)
            ),
            kind="success",
        )

    _save_result
    return


if __name__ == "__main__":
    app.run()
