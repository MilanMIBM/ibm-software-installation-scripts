import marimo

__generated_with = "0.24.0"
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

    from src.helpers.id_options_templates import (
        cp4d_component_id_records,
        cp4d_license_entitlement_id_records,
        default_project_naming_conventions,
        default_private_registry_setup,
        image_group_id_records,
    )
    from src.helpers.marimo_sortablekv import sortable_kv
    from src.helpers.jinja2_template_rendering_helpers import (
        render_template_from_environment,
    )

    return (
        cp4d_component_id_records,
        cp4d_license_entitlement_id_records,
        default_private_registry_setup,
        default_project_naming_conventions,
        image_group_id_records,
        render_template_from_environment,
        sortable_kv,
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
def _(default_private_registry_setup, sortable_kv):
    cp4d_private_registry_naming_records = sortable_kv(
        label="If you are using a private registry:",
        value=default_private_registry_setup,
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

    image_pull_credentials = {
        "IBM Entitled Registry": '$(echo -n "cp:$IBM_ENTITLEMENT_KEY" | base64 -w 0)',
        "Private Container Registry": '$(echo -n "$PRIVATE_REGISTRY_PULL_USER:$PRIVATE_REGISTRY_PULL_PASSWORD" | base64 -w 0)',
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
        "cp4d_patch": "**Patch ID (optional):**",
        "entitlement_key": "**Input your ibm entitlement key:** *[Get one here](https://myibm.ibm.com/products-services/containerlibrary)*",
        "cluster_url": "**Enter your openshift cluster url:**",
        "cluster_token": "**Enter your openshift token:**",
        "cluster_username": "**Enter your openshift cluster username:**",
        "cluster_password": "**Enter your openshift cluster password:**",
        "cpd_admin_username": "**Preselect your cp4d admin username:**",
        "review_and_save": "**Review or alter your config and save it and you're good to go!**",
        "include_install_options": "**Do you want to include customized install options?**",
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
    updating_components_checkbox,
):
    component_specs_accordion = mo.accordion(
        items={
            "**License Entitlements**": mo.vstack(
                [
                    license_entitlement_table,
                    licenses_are_prod_checkbox.center(),
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
        initial_selection=[0, 17, 25, 26, 41],
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
        label=widget_labels.get("prod_license"), value=True
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
        label="**Save directly to ./cp4d_config/**", kind="neutral"
    )
    return (save_to_config_dir_button,)


@app.cell
def _(render_template_from_environment, run_button, save_to_config_dir_button):
    rendered_variables_file_cpd = (
        render_template_from_environment(
            template_path="src/helpers/cpd_variable_template.sh.j2"
        )
        if run_button.value or save_to_config_dir_button.value
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
def _(cpd_vars_template_editor, inst_options_template_editor, save_file_stack):
    config_stack_cpd = mo.vstack(
        [
            cpd_vars_template_editor,
            inst_options_template_editor,
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
def _(
    name_variable_file_cpd,
    save_config_cpd,
    save_config_inst_options,
    save_to_config_dir_button,
):
    save_file_stack = mo.hstack(
        [
            name_variable_file_cpd,
            save_config_cpd,
            save_config_inst_options,
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
def _(
    install_options_addon,
    render_template_from_environment,
    run_button,
    save_to_config_dir_button,
):
    rendered_variables_file_inst_options = (
        render_template_from_environment(
            template_path="src/helpers/install_options_template.sh.j2"
        )
        if (run_button.value or save_to_config_dir_button.value)
        and install_options_addon.value
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
    save_to_config_dir_button,
):
    _save_result = None
    if save_to_config_dir_button.value and cpd_vars_template_editor.value:
        _config_dir = os.path.join(os.path.dirname(__file__), "cp4d_config")
        os.makedirs(_config_dir, exist_ok=True)

        _cpd_vars_path = os.path.join(_config_dir, cpd_vars_filename)
        with open(_cpd_vars_path, "w") as _f:
            _f.write(cpd_vars_template_editor.value)

        _saved = [_cpd_vars_path]

        if install_options_addon.value and inst_options_template_editor.value:
            _inst_opts_path = os.path.join(_config_dir, inst_options_filename)
            with open(_inst_opts_path, "w") as _f:
                _f.write(inst_options_template_editor.value)
            _saved.append(_inst_opts_path)

        _save_result = mo.callout(
            mo.md(
                "**Saved to `./cp4d_config/`:**\n"
                + "\n".join(f"- `{p}`" for p in _saved)
            ),
            kind="success",
        )

    _save_result
    return


if __name__ == "__main__":
    app.run()
