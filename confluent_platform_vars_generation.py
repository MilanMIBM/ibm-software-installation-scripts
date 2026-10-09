import marimo

__generated_with = "0.25.0"
app = marimo.App(
    width="full",
    app_title="Confluent Platform - Setup Config Generator",
)

with app.setup:
    import marimo as mo
    import base64
    import shutil
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

    from src.helpers.confluent_id_options_templates import (
        confluent_auth_mode_records,
        confluent_component_toggle_records,
        confluent_mds_user_store_records,
        confluent_sasl_mechanism_options,
        confluent_sasl_security_protocol_options,
        confluent_size_presets,
        confluent_size_records,
        default_confluent_component_toggles,
        default_confluent_external_access,
        default_confluent_images,
        default_confluent_ldap,
        default_confluent_mds,
        default_confluent_oauth,
        default_confluent_ports,
        default_confluent_routes_and_waits,
        default_confluent_sasl,
        default_confluent_size,
        default_confluent_storage,
        default_confluent_web_ui_auth,
        default_flink_cert_manager,
        default_flink_cmf_endpoint,
        default_flink_helm,
        default_flink_images,
        default_flink_license,
        default_flink_naming,
        default_flink_project_and_storage,
        default_flink_state,
        flink_size_presets,
        flink_state_backend_records,
    )
    from src.helpers.marimo_sortablekv import sortable_kv
    from src.helpers.jinja2_template_rendering_helpers import (
        render_template_from_environment,
    )

    return (
        confluent_auth_mode_records,
        confluent_component_toggle_records,
        confluent_mds_user_store_records,
        confluent_sasl_mechanism_options,
        confluent_sasl_security_protocol_options,
        confluent_size_presets,
        confluent_size_records,
        default_confluent_component_toggles,
        default_confluent_external_access,
        default_confluent_images,
        default_confluent_ldap,
        default_confluent_mds,
        default_confluent_oauth,
        default_confluent_ports,
        default_confluent_routes_and_waits,
        default_confluent_sasl,
        default_confluent_size,
        default_confluent_storage,
        default_confluent_web_ui_auth,
        default_flink_cert_manager,
        default_flink_cmf_endpoint,
        default_flink_helm,
        default_flink_images,
        default_flink_license,
        default_flink_naming,
        default_flink_project_and_storage,
        default_flink_state,
        flink_size_presets,
        flink_state_backend_records,
        render_template_from_environment,
        sortable_kv,
    )


@app.function
def records_to_dict(records):
    return {r["key"]: r["value"] for r in records}


@app.function
def without_keys(records, keys):
    # Keys set by a dedicated widget are dropped from the editable key/value lists
    return [r for r in records if r["key"] not in keys]


@app.function
def dict_to_records(values):
    return [{"key": k, "value": v} for k, v in values.items()]


@app.function
def kv_value(kv_widget):
    return records_to_dict(kv_widget.value.get("value"))


@app.function
def ordered_values(default_records, kv_widget=None, overrides=None):
    # Keeps the defaults' order: widget overrides win, then the edited key/value list
    edited = kv_value(kv_widget) if kv_widget is not None else {}
    overrides = overrides or {}
    return {
        r["key"]: overrides.get(r["key"], edited.get(r["key"], r["value"]))
        for r in default_records
    }


@app.function
def bool_str(value):
    return "true" if value else "false"


@app.function
def generate_cluster_id():
    # KRaft cluster id: base64url-encoded 16-byte UUID, 22 chars of [A-Za-z0-9_-]
    return base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip("=")


@app.cell(hide_code=True)
def _():
    mo.md(r"""
    ## **Confluent Platform** - Setup Config Generator
    """)
    return


@app.cell
def _():
    # Keys owned by a dedicated widget rather than a key/value list
    widget_controlled_keys = {
        "CONFLUENT_VERSION",
        "CONFLUENT_C3_VERSION",
        "CONFLUENT_REGISTRY_PASSWORD",
        "CONFLUENT_CLUSTER_ID",
        "CONFLUENT_STORAGE_CLASS",
        "CONFLUENT_CREATE_ROUTES",
        "CONFLUENT_MONITORING_NETWORK_POLICY",
        "CONFLUENT_AUTH_ENABLED",
        "CONFLUENT_AUTH_MODE",
        "CONFLUENT_AUTH_PASSWORD",
        "CONFLUENT_SASL_ENABLED",
        "CONFLUENT_SASL_MECHANISM",
        "CONFLUENT_SASL_SECURITY_PROTOCOL",
        "CONFLUENT_MDS_ENABLED",
        "CONFLUENT_MDS_USER_STORE",
        "CONFLUENT_LICENSE_KEY",
        "CONFLUENT_EXTERNAL_KAFKA_ENABLED",
        "CONFLUENT_INSTALL_SCHEMA_REGISTRY",
        "CONFLUENT_INSTALL_CONNECT",
        "CONFLUENT_INSTALL_KSQLDB",
        "CONFLUENT_INSTALL_REST_PROXY",
        "CONFLUENT_INSTALL_CONTROL_CENTER",
        "FLINK_CMF_STORAGE_CLASS",
        "FLINK_CREATE_ROUTES",
        "FLINK_STATE_BACKEND",
        "FLINK_STATE_STORAGE_CLASS",
        "FLINK_S3_ACCESS_KEY",
        "FLINK_S3_SECRET_KEY",
        "FLINK_S3_PATH_STYLE_ACCESS",
    }
    return (widget_controlled_keys,)


@app.cell
def _(
    confluent_auth_mode_records,
    confluent_mds_user_store_records,
    confluent_sasl_mechanism_options,
    confluent_sasl_security_protocol_options,
    confluent_size_records,
    flink_state_backend_records,
):
    # Cluster options - Login
    login_argument_options = {
        "Username/Password": "--username=${OCP_USERNAME} --password=${OCP_PASSWORD}",
        "Token": "--token=${OCP_TOKEN}",
    }

    # Sizing options - T-shirt size shared by Confluent and Flink
    size_options = {r["size_name"]: r["size_id"] for r in confluent_size_records}

    # Security options - Web UI auth, Kafka SASL, MDS user store
    auth_mode_options = {
        r["auth_mode_name"]: r["auth_mode_id"] for r in confluent_auth_mode_records
    }
    sasl_mechanism_options = {m: m for m in confluent_sasl_mechanism_options}
    sasl_security_protocol_options = {
        p: p for p in confluent_sasl_security_protocol_options
    }
    mds_user_store_options = {
        r["user_store_name"]: r["user_store_id"]
        for r in confluent_mds_user_store_records
    }

    # Flink options - Checkpoint storage
    flink_state_backend_options = {
        r["state_backend_name"]: r["state_backend_id"]
        for r in flink_state_backend_records
    }

    # Storage options - Block Storage (RWO, broker + CMF PVCs)
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
    # Storage options - File Storage (RWX, Flink checkpoint PVC)
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
    # Per-component storage - defaults reference the cluster-wide classes above
    component_block_storage_options = {
        "Same as cluster block storage class (Default)": "${STG_CLASS_BLOCK}",
        **stg_class_block_options,
    }
    component_file_storage_options = {
        "Same as cluster file storage class (Default)": "${STG_CLASS_FILE}",
        **stg_class_file_options,
    }
    return (
        auth_mode_options,
        component_block_storage_options,
        component_file_storage_options,
        flink_state_backend_options,
        login_argument_options,
        mds_user_store_options,
        sasl_mechanism_options,
        sasl_security_protocol_options,
        size_options,
        stg_class_block_options,
        stg_class_file_options,
    )


@app.cell
def _():
    widget_labels = {
        "login_arguments": "**Select how you want to login to the cluster:**",
        "storage_block": "**Select your block storage class (RWO):**",
        "storage_file": "**Select your file storage class (RWX):**",
        "size": "**Select your t-shirt size (Confluent + Flink):**",
        "auth_mode": "**Select the web UI authentication mode:**",
        "sasl_mechanism": "**Select the Kafka SASL mechanisms** *(clients use the strongest)*:",
        "sasl_security_protocol": "**Select the Kafka security protocol** *(internal listeners)*:",
        "mds_user_store": "**Select the MDS / RBAC user store:**",
        "flink_state_backend": "**Select the Flink checkpoint storage:**",
        "confluent_storage_class": "**Select the broker storage class:**",
        "flink_cmf_storage_class": "**Select the CMF metadata storage class:**",
        "flink_state_storage_class": "**Select the Flink checkpoint PVC storage class (RWX, pvc backend):**",
        "components_multiselect": "**Select the optional components to install (the broker is always installed):**",
        "auth_enabled": "Protect the web UIs with authentication?",
        "sasl_enabled": "Require **SASL** authentication (PLAIN / SCRAM) for Kafka clients?",
        "mds_enabled": "Enable **MDS / RBAC** (`confluent login`)? *Requires SASL, licensed (30-day trial).*",
        "external_kafka_enabled": "Expose Kafka **outside the cluster** (SASL_SSL passthrough routes)? *Requires SASL.*",
        "create_routes": "Expose the component web endpoints as **OpenShift routes**?",
        "monitoring_network_policy": "Restrict Prometheus/Alertmanager ingress to the Confluent pods?",
        "include_flink": "Include the **Confluent Platform for Apache Flink** addon?",
        "flink_create_routes": "Expose **CMF** as an OpenShift route? *The CMF REST API is unauthenticated.*",
        "flink_s3_path_style": "Use **path-style** S3 access?",
        "confluent_version": "**Confluent Platform version:**",
        "confluent_c3_version": "**Control Center version:**",
        "cluster_url": "**Enter your openshift cluster url:**",
        "cluster_token": "**Enter your openshift token:**",
        "cluster_username": "**Enter your openshift cluster username:**",
        "cluster_password": "**Enter your openshift cluster password:**",
        "project_confluent_server": "**Project to install Confluent into:**",
        "cluster_id": "**KRaft cluster id** *(keep stable across reinstalls that reuse broker PVCs)*:",
        "license_key": "**Confluent license key** *(empty = 30-day trial)*:",
        "registry_password": "**Image registry password** *(empty = anonymous pull)*:",
        "auth_password": "**Web UI basic-auth password** *(basic mode only, empty = generated)*:",
        "flink_s3_access_key": "**S3 access key:**",
        "flink_s3_secret_key": "**S3 secret key:**",
    }
    return (widget_labels,)


@app.cell
def _(
    auth_mode_select,
    block_storage_class_select,
    confluent_c3_version_input,
    confluent_version_input,
    file_storage_class_select,
    flink_state_backend_select,
    login_argument_select,
    mds_user_store_select,
    sasl_mechanism_select,
    sasl_security_protocol_select,
    size_select,
    widget_width,
):
    cluster_specs_stack = mo.vstack(
        [
            mo.hstack(
                [
                    login_argument_select.style({"width": widget_width}),
                    size_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    block_storage_class_select.style({"width": widget_width}),
                    file_storage_class_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    auth_mode_select.style({"width": widget_width}),
                    sasl_mechanism_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    sasl_security_protocol_select.style({"width": widget_width}),
                    mds_user_store_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    flink_state_backend_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    confluent_version_input.style({"width": widget_width}),
                    confluent_c3_version_input.style({"width": widget_width}),
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
    cluster_id_input,
    cluster_password_input,
    cluster_token_input,
    cluster_url_input,
    cluster_username_input,
    license_key_input,
    project_confluent_server_input,
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
            ),
            mo.vstack(
                [
                    "",
                    project_confluent_server_input,
                    cluster_id_input,
                    license_key_input,
                ],
                justify="end",
            ),
        ],
        justify="space-around",
        widths=[0.4, 0.4],
    )
    return (cluster_credentials_stack,)


@app.cell
def _(
    auth_enabled_checkbox,
    component_toggle_table,
    external_kafka_enabled_checkbox,
    mds_enabled_checkbox,
    sasl_enabled_checkbox,
):
    components_and_security_stack = mo.vstack(
        [
            component_toggle_table,
            auth_enabled_checkbox,
            sasl_enabled_checkbox,
            mds_enabled_checkbox,
            external_kafka_enabled_checkbox,
        ],
        gap=1,
    )
    return (components_and_security_stack,)


@app.cell
def _(
    cluster_credentials_stack,
    components_and_security_stack,
    confluent_sizing_records,
    confluent_storage_class_select,
    widget_width,
):
    install_specs_accordion = mo.accordion(
        items={
            "**Cluster Credentials & Project**": cluster_credentials_stack,
            "**Components & Security**": components_and_security_stack,  # .style({"width": "60%"}).center(),
            "**Broker Sizing** *(prefilled from the selected size)*": mo.vstack(
                [
                    confluent_storage_class_select.style({"width": widget_width}),
                    confluent_sizing_records,
                ],
                gap=1,
            ),
        },
        multiple=True,
    )
    install_specs_accordion
    return


@app.cell
def _(
    auth_password_input,
    confluent_external_access_records,
    confluent_images_records,
    confluent_ldap_records,
    confluent_mds_records,
    confluent_oauth_records,
    confluent_ports_records,
    confluent_routes_and_waits_records,
    confluent_sasl_records,
    confluent_web_ui_auth_records,
    create_routes_checkbox,
    monitoring_network_policy_checkbox,
    registry_password_input,
):
    advanced_specs_accordion = mo.accordion(
        items={
            "*Images & Registry* ***(optional)***": mo.vstack(
                [confluent_images_records, registry_password_input], gap=1
            ),
            "*Ports, Routes & Network Policy* ***(optional)***": mo.vstack(
                [
                    create_routes_checkbox,
                    monitoring_network_policy_checkbox,
                    confluent_routes_and_waits_records,
                    confluent_ports_records,
                ],
                gap=1,
            ),
            "*Web UI Auth & SASL* ***(optional)***": mo.vstack(
                [
                    confluent_web_ui_auth_records,
                    auth_password_input,
                    confluent_sasl_records,
                ],
                gap=1,
            ),
            "*MDS / RBAC User Stores* ***(optional)***": mo.vstack(
                [
                    confluent_mds_records,
                    confluent_ldap_records,
                    confluent_oauth_records,
                ]
            ),
            "*External Kafka Access* ***(optional)***": confluent_external_access_records,
        },
        multiple=True,
    )
    advanced_specs_accordion
    return


@app.cell
def _(
    flink_cert_manager_records,
    flink_cmf_endpoint_records,
    flink_cmf_storage_class_select,
    flink_create_routes_checkbox,
    flink_helm_records,
    flink_images_records,
    flink_license_records,
    flink_naming_records,
    flink_s3_access_key_input,
    flink_s3_path_style_checkbox,
    flink_s3_secret_key_input,
    flink_sizing_records,
    flink_state_records,
    flink_state_storage_class_select,
    include_flink_checkbox,
    widget_width,
):
    flink_accordion = mo.accordion(
        items={
            "**Confluent Platform for Apache Flink Addon**": mo.vstack(
                [
                    include_flink_checkbox,
                    flink_cmf_storage_class_select.style({"width": widget_width}),
                    flink_sizing_records,
                    flink_state_storage_class_select.style({"width": widget_width}),
                    flink_state_records,
                    mo.hstack(
                        [
                            flink_s3_access_key_input,
                            flink_s3_secret_key_input,
                            flink_s3_path_style_checkbox,
                        ],
                        justify="start",
                        gap=2,
                    ),
                    flink_naming_records,
                    flink_create_routes_checkbox,
                    flink_cmf_endpoint_records,
                    flink_helm_records,
                    flink_images_records,
                    flink_cert_manager_records,
                    flink_license_records,
                ],
                gap=1,
            )
        },
        multiple=True,
    )
    flink_accordion
    return


@app.cell
def _(security_warnings):
    security_warnings
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
def _(login_argument_options, widget_labels):
    login_argument_select = mo.ui.dropdown(
        label=widget_labels.get("login_arguments"),
        options=login_argument_options,
        value=list(login_argument_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (login_argument_select,)


@app.cell
def _(default_confluent_size, size_options, widget_labels):
    size_select = mo.ui.dropdown(
        label=widget_labels.get("size"),
        options=size_options,
        value=next(k for k, v in size_options.items() if v == default_confluent_size),
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (size_select,)


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
    return (file_storage_class_select,)


@app.cell
def _(component_block_storage_options, widget_labels):
    confluent_storage_class_select = mo.ui.dropdown(
        label=widget_labels.get("confluent_storage_class"),
        options=component_block_storage_options,
        value=list(component_block_storage_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (confluent_storage_class_select,)


@app.cell
def _(component_block_storage_options, widget_labels):
    flink_cmf_storage_class_select = mo.ui.dropdown(
        label=widget_labels.get("flink_cmf_storage_class"),
        options=component_block_storage_options,
        value=list(component_block_storage_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (flink_cmf_storage_class_select,)


@app.cell
def _(component_file_storage_options, widget_labels):
    flink_state_storage_class_select = mo.ui.dropdown(
        label=widget_labels.get("flink_state_storage_class"),
        options=component_file_storage_options,
        value=list(component_file_storage_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (flink_state_storage_class_select,)


@app.cell
def _(auth_mode_options, widget_labels):
    auth_mode_select = mo.ui.dropdown(
        label=widget_labels.get("auth_mode"),
        options=auth_mode_options,
        value=list(auth_mode_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (auth_mode_select,)


@app.cell
def _(sasl_mechanism_options, widget_labels):
    sasl_mechanism_select = mo.ui.multiselect(
        label=widget_labels.get("sasl_mechanism"),
        options=sasl_mechanism_options,
        value=[list(sasl_mechanism_options.keys())[0]],
        full_width=True,
    )
    return (sasl_mechanism_select,)


@app.cell
def _(sasl_security_protocol_options, widget_labels):
    sasl_security_protocol_select = mo.ui.dropdown(
        label=widget_labels.get("sasl_security_protocol"),
        options=sasl_security_protocol_options,
        value=list(sasl_security_protocol_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (sasl_security_protocol_select,)


@app.cell
def _(mds_user_store_options, widget_labels):
    mds_user_store_select = mo.ui.dropdown(
        label=widget_labels.get("mds_user_store"),
        options=mds_user_store_options,
        value=list(mds_user_store_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (mds_user_store_select,)


@app.cell
def _(flink_state_backend_options, widget_labels):
    flink_state_backend_select = mo.ui.dropdown(
        label=widget_labels.get("flink_state_backend"),
        options=flink_state_backend_options,
        value=list(flink_state_backend_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (flink_state_backend_select,)


@app.cell
def _(confluent_component_toggle_records, widget_labels):
    component_toggle_table = mo.ui.table(
        label=widget_labels.get("components_multiselect"),
        data=confluent_component_toggle_records,
        selection="multi",
        initial_selection=list(range(len(confluent_component_toggle_records))),
    )
    return (component_toggle_table,)


@app.cell
def _(widget_labels):
    auth_enabled_checkbox = mo.ui.checkbox(
        label=widget_labels.get("auth_enabled"), value=True
    )
    return (auth_enabled_checkbox,)


@app.cell
def _(widget_labels):
    sasl_enabled_checkbox = mo.ui.checkbox(
        label=widget_labels.get("sasl_enabled"), value=True
    )
    return (sasl_enabled_checkbox,)


@app.cell
def _(widget_labels):
    mds_enabled_checkbox = mo.ui.checkbox(
        label=widget_labels.get("mds_enabled"), value=True
    )
    return (mds_enabled_checkbox,)


@app.cell
def _(widget_labels):
    external_kafka_enabled_checkbox = mo.ui.checkbox(
        label=widget_labels.get("external_kafka_enabled"), value=True
    )
    return (external_kafka_enabled_checkbox,)


@app.cell
def _(widget_labels):
    create_routes_checkbox = mo.ui.checkbox(
        label=widget_labels.get("create_routes"), value=True
    )
    return (create_routes_checkbox,)


@app.cell
def _(widget_labels):
    monitoring_network_policy_checkbox = mo.ui.checkbox(
        label=widget_labels.get("monitoring_network_policy"), value=True
    )
    return (monitoring_network_policy_checkbox,)


@app.cell
def _(widget_labels):
    include_flink_checkbox = mo.ui.checkbox(
        label=widget_labels.get("include_flink"), value=True
    )
    return (include_flink_checkbox,)


@app.cell
def _(widget_labels):
    flink_create_routes_checkbox = mo.ui.checkbox(
        label=widget_labels.get("flink_create_routes"), value=True
    )
    return (flink_create_routes_checkbox,)


@app.cell
def _(widget_labels):
    flink_s3_path_style_checkbox = mo.ui.checkbox(
        label=widget_labels.get("flink_s3_path_style"), value=True
    )
    return (flink_s3_path_style_checkbox,)


@app.cell
def _(default_confluent_images, widget_labels):
    confluent_version_input = mo.ui.text(
        label=widget_labels.get("confluent_version"),
        value=records_to_dict(default_confluent_images).get("CONFLUENT_VERSION"),
        full_width=True,
    )
    return (confluent_version_input,)


@app.cell
def _(default_confluent_images, widget_labels):
    confluent_c3_version_input = mo.ui.text(
        label=widget_labels.get("confluent_c3_version"),
        value=records_to_dict(default_confluent_images).get("CONFLUENT_C3_VERSION"),
        full_width=True,
    )
    return (confluent_c3_version_input,)


@app.cell
def _(widget_labels):
    cluster_url_input = mo.ui.text(
        label=widget_labels.get("cluster_url"),
        kind="url",
        full_width=True,
    )
    return (cluster_url_input,)


@app.cell
def _(widget_labels):
    cluster_username_input = mo.ui.text(
        label=widget_labels.get("cluster_username"),
        value="kubeadmin",
        kind="text",
        full_width=False,
    )
    return (cluster_username_input,)


@app.cell
def _(widget_labels):
    cluster_password_input = mo.ui.text(
        label=widget_labels.get("cluster_password"),
        kind="password",
        full_width=False,
    )
    return (cluster_password_input,)


@app.cell
def _(widget_labels):
    cluster_token_input = mo.ui.text(
        label=widget_labels.get("cluster_token"),
        kind="password",
        full_width=False,
    )
    return (cluster_token_input,)


@app.cell
def _(widget_labels):
    project_confluent_server_input = mo.ui.text(
        label=widget_labels.get("project_confluent_server"),
        value="confluent",
        kind="text",
        full_width=False,
    )
    return (project_confluent_server_input,)


@app.cell
def _(widget_labels):
    cluster_id_input = mo.ui.text(
        label=widget_labels.get("cluster_id"),
        value=generate_cluster_id(),
        kind="text",
        max_length=22,
        full_width=False,
    )
    return (cluster_id_input,)


@app.cell
def _(widget_labels):
    license_key_input = mo.ui.text(
        label=widget_labels.get("license_key"),
        kind="password",
        full_width=False,
    )
    return (license_key_input,)


@app.cell
def _(widget_labels):
    registry_password_input = mo.ui.text(
        label=widget_labels.get("registry_password"),
        kind="password",
        full_width=False,
    )
    return (registry_password_input,)


@app.cell
def _(widget_labels):
    auth_password_input = mo.ui.text(
        label=widget_labels.get("auth_password"),
        kind="password",
        full_width=False,
    )
    return (auth_password_input,)


@app.cell
def _(widget_labels):
    flink_s3_access_key_input = mo.ui.text(
        label=widget_labels.get("flink_s3_access_key"),
        kind="password",
        full_width=False,
    )
    return (flink_s3_access_key_input,)


@app.cell
def _(widget_labels):
    flink_s3_secret_key_input = mo.ui.text(
        label=widget_labels.get("flink_s3_secret_key"),
        kind="password",
        full_width=False,
    )
    return (flink_s3_secret_key_input,)


@app.cell
def _(
    confluent_size_presets,
    default_confluent_storage,
    default_flink_project_and_storage,
    flink_size_presets,
    size_select,
    sortable_kv,
    widget_controlled_keys,
):
    # Recreated whenever the size changes, so the preset values are reapplied
    confluent_sizing_records = sortable_kv(
        label="Broker sizing and resources:",
        value=without_keys(default_confluent_storage, widget_controlled_keys)
        + dict_to_records(confluent_size_presets[size_select.value]),
        addable=False,
        removable=False,
        editable=True,
        movable=False,
    )
    flink_sizing_records = sortable_kv(
        label="Flink project, CMF sizing and default compute pool:",
        value=without_keys(default_flink_project_and_storage, widget_controlled_keys)
        + dict_to_records(flink_size_presets[size_select.value]),
        addable=False,
        removable=False,
        editable=True,
        movable=False,
    )
    return confluent_sizing_records, flink_sizing_records


@app.cell
def _(
    default_confluent_external_access,
    default_confluent_images,
    default_confluent_ldap,
    default_confluent_mds,
    default_confluent_oauth,
    default_confluent_ports,
    default_confluent_routes_and_waits,
    default_confluent_sasl,
    default_confluent_web_ui_auth,
    sortable_kv,
    widget_controlled_keys,
):
    def _kv(label, records):
        return sortable_kv(
            label=label,
            value=without_keys(records, widget_controlled_keys),
            addable=False,
            removable=False,
            editable=True,
            movable=False,
        )

    confluent_images_records = _kv(
        "Images & registry (empty registry user = anonymous pull):",
        default_confluent_images,
    )
    confluent_ports_records = _kv("Ports:", default_confluent_ports)
    confluent_routes_and_waits_records = _kv(
        "Route domain & waits (empty domain = cluster apps domain):",
        default_confluent_routes_and_waits,
    )
    confluent_web_ui_auth_records = _kv(
        "Web UI auth:",
        default_confluent_web_ui_auth,
    )
    confluent_sasl_records = _kv(
        "Kafka SASL (clients are comma-separated):",
        default_confluent_sasl,
    )
    confluent_mds_records = _kv(
        "Metadata Service (users are comma-separated):", default_confluent_mds
    )
    confluent_ldap_records = _kv(
        "Bundled OpenLDAP (user store = LDAP):", default_confluent_ldap
    )
    confluent_oauth_records = _kv(
        "Keycloak / external OIDC (user store = OAUTH; set JWKS URL for an external provider):",
        default_confluent_oauth,
    )
    confluent_external_access_records = _kv(
        "External Kafka access:", default_confluent_external_access
    )
    return (
        confluent_external_access_records,
        confluent_images_records,
        confluent_ldap_records,
        confluent_mds_records,
        confluent_oauth_records,
        confluent_ports_records,
        confluent_routes_and_waits_records,
        confluent_sasl_records,
        confluent_web_ui_auth_records,
    )


@app.cell
def _(
    default_flink_cert_manager,
    default_flink_cmf_endpoint,
    default_flink_helm,
    default_flink_images,
    default_flink_license,
    default_flink_naming,
    default_flink_state,
    sortable_kv,
    widget_controlled_keys,
):
    def _kv(label, records):
        return sortable_kv(
            label=label,
            value=without_keys(records, widget_controlled_keys),
            addable=False,
            removable=False,
            editable=True,
            movable=False,
        )

    flink_state_records = _kv(
        "Checkpoint storage (FLINK_S3_* only used with the s3 backend):",
        default_flink_state,
    )
    flink_naming_records = _kv(
        "CMF environment / compute pool / catalog names:", default_flink_naming
    )
    flink_cmf_endpoint_records = _kv("CMF endpoint:", default_flink_cmf_endpoint)
    flink_helm_records = _kv("Helm charts:", default_flink_helm)
    flink_images_records = _kv(
        "Images (empty registry = chart default):", default_flink_images
    )
    flink_cert_manager_records = _kv(
        "cert-manager (installed only if absent):", default_flink_cert_manager
    )
    flink_license_records = _kv(
        "Licence (falls back to CONFLUENT_LICENSE_KEY):", default_flink_license
    )
    return (
        flink_cert_manager_records,
        flink_cmf_endpoint_records,
        flink_helm_records,
        flink_images_records,
        flink_license_records,
        flink_naming_records,
        flink_state_records,
    )


@app.cell
def _(
    auth_enabled_checkbox,
    auth_mode_select,
    auth_password_input,
    component_toggle_table,
    confluent_c3_version_input,
    confluent_external_access_records,
    confluent_images_records,
    confluent_ldap_records,
    confluent_mds_records,
    confluent_oauth_records,
    confluent_ports_records,
    confluent_routes_and_waits_records,
    confluent_sasl_records,
    confluent_size_presets,
    confluent_sizing_records,
    confluent_storage_class_select,
    confluent_version_input,
    confluent_web_ui_auth_records,
    create_routes_checkbox,
    default_confluent_component_toggles,
    default_confluent_external_access,
    default_confluent_images,
    default_confluent_ldap,
    default_confluent_mds,
    default_confluent_oauth,
    default_confluent_ports,
    default_confluent_routes_and_waits,
    default_confluent_sasl,
    default_confluent_storage,
    default_confluent_web_ui_auth,
    external_kafka_enabled_checkbox,
    license_key_input,
    mds_enabled_checkbox,
    mds_user_store_select,
    monitoring_network_policy_checkbox,
    registry_password_input,
    sasl_enabled_checkbox,
    sasl_mechanism_select,
    sasl_security_protocol_select,
    size_select,
):
    # Merge widget-controlled values into the key/value groups the template renders
    _selected_components = {
        r["component_id"] for r in component_toggle_table.value
    }

    confluent_images = ordered_values(
        default_confluent_images,
        confluent_images_records,
        {
            "CONFLUENT_VERSION": confluent_version_input.value,
            "CONFLUENT_C3_VERSION": confluent_c3_version_input.value,
            "CONFLUENT_REGISTRY_PASSWORD": registry_password_input.value,
        },
    )
    confluent_component_toggles = ordered_values(
        default_confluent_component_toggles,
        overrides={
            **{
                r["component_id"]: bool_str(
                    r["component_id"] in _selected_components
                )
                for r in component_toggle_table.data
            },
            "CONFLUENT_MONITORING_NETWORK_POLICY": bool_str(
                monitoring_network_policy_checkbox.value
            ),
        },
    )
    confluent_ports = ordered_values(default_confluent_ports, confluent_ports_records)
    confluent_routes_and_waits = ordered_values(
        default_confluent_routes_and_waits,
        confluent_routes_and_waits_records,
        {"CONFLUENT_CREATE_ROUTES": bool_str(create_routes_checkbox.value)},
    )
    confluent_web_ui_auth = ordered_values(
        default_confluent_web_ui_auth,
        confluent_web_ui_auth_records,
        {
            "CONFLUENT_AUTH_ENABLED": bool_str(auth_enabled_checkbox.value),
            "CONFLUENT_AUTH_MODE": auth_mode_select.value,
            "CONFLUENT_AUTH_PASSWORD": auth_password_input.value,
        },
    )
    confluent_sasl = ordered_values(
        default_confluent_sasl,
        confluent_sasl_records,
        {
            "CONFLUENT_SASL_ENABLED": bool_str(sasl_enabled_checkbox.value),
            "CONFLUENT_SASL_MECHANISM": ",".join(sasl_mechanism_select.value),
            "CONFLUENT_SASL_SECURITY_PROTOCOL": sasl_security_protocol_select.value,
        },
    )
    confluent_mds = ordered_values(
        default_confluent_mds,
        confluent_mds_records,
        {
            "CONFLUENT_MDS_ENABLED": bool_str(mds_enabled_checkbox.value),
            "CONFLUENT_MDS_USER_STORE": mds_user_store_select.value,
            "CONFLUENT_LICENSE_KEY": license_key_input.value,
        },
    )
    confluent_ldap = ordered_values(default_confluent_ldap, confluent_ldap_records)
    confluent_oauth = ordered_values(
        default_confluent_oauth, confluent_oauth_records
    )
    confluent_external_access = ordered_values(
        default_confluent_external_access,
        confluent_external_access_records,
        {
            "CONFLUENT_EXTERNAL_KAFKA_ENABLED": bool_str(
                external_kafka_enabled_checkbox.value
            )
        },
    )
    # CONFLUENT_CLUSTER_ID is rendered on its own at the top of the sizing block
    confluent_sizing = ordered_values(
        without_keys(default_confluent_storage, {"CONFLUENT_CLUSTER_ID"})
        + dict_to_records(confluent_size_presets[size_select.value]),
        confluent_sizing_records,
        {"CONFLUENT_STORAGE_CLASS": confluent_storage_class_select.value},
    )
    print(confluent_component_toggles)
    return


@app.cell
def _(
    default_flink_cert_manager,
    default_flink_cmf_endpoint,
    default_flink_helm,
    default_flink_images,
    default_flink_license,
    default_flink_naming,
    default_flink_project_and_storage,
    default_flink_state,
    flink_cert_manager_records,
    flink_cmf_endpoint_records,
    flink_cmf_storage_class_select,
    flink_create_routes_checkbox,
    flink_helm_records,
    flink_images_records,
    flink_license_records,
    flink_naming_records,
    flink_s3_access_key_input,
    flink_s3_path_style_checkbox,
    flink_s3_secret_key_input,
    flink_size_presets,
    flink_sizing_records,
    flink_state_backend_select,
    flink_state_records,
    flink_state_storage_class_select,
    size_select,
):
    flink_sizing = ordered_values(
        default_flink_project_and_storage
        + dict_to_records(flink_size_presets[size_select.value]),
        flink_sizing_records,
        {"FLINK_CMF_STORAGE_CLASS": flink_cmf_storage_class_select.value},
    )
    flink_helm = ordered_values(default_flink_helm, flink_helm_records)
    flink_images = ordered_values(default_flink_images, flink_images_records)
    flink_cert_manager = ordered_values(
        default_flink_cert_manager, flink_cert_manager_records
    )
    flink_cmf_endpoint = ordered_values(
        default_flink_cmf_endpoint,
        flink_cmf_endpoint_records,
        {"FLINK_CREATE_ROUTES": bool_str(flink_create_routes_checkbox.value)},
    )
    flink_naming = ordered_values(default_flink_naming, flink_naming_records)
    flink_state = ordered_values(
        default_flink_state,
        flink_state_records,
        {
            "FLINK_STATE_BACKEND": flink_state_backend_select.value,
            "FLINK_STATE_STORAGE_CLASS": flink_state_storage_class_select.value,
            "FLINK_S3_ACCESS_KEY": flink_s3_access_key_input.value,
            "FLINK_S3_SECRET_KEY": flink_s3_secret_key_input.value,
            "FLINK_S3_PATH_STYLE_ACCESS": bool_str(
                flink_s3_path_style_checkbox.value
            ),
        },
    )
    flink_license = ordered_values(default_flink_license, flink_license_records)
    return (flink_state,)


@app.cell
def _(
    cluster_id_input,
    external_kafka_enabled_checkbox,
    flink_state,
    include_flink_checkbox,
    mds_enabled_checkbox,
    sasl_enabled_checkbox,
    sasl_mechanism_select,
    sasl_security_protocol_select,
):
    # Flag combinations the install scripts reject
    _warnings = []
    if sasl_enabled_checkbox.value and not sasl_mechanism_select.value:
        _warnings.append("SASL is enabled - select at least one SASL mechanism.")
    if (
        sasl_enabled_checkbox.value
        and sasl_security_protocol_select.value != "SASL_PLAINTEXT"
    ):
        _warnings.append(
            f"Security protocol {sasl_security_protocol_select.value} is not supported yet - "
            "the internal listeners have no TLS and PLAINTEXT/SSL disable SASL. Use SASL_PLAINTEXT."
        )
    if not sasl_enabled_checkbox.value and mds_enabled_checkbox.value:
        _warnings.append(
            "MDS / RBAC requires SASL - enable SASL or disable MDS."
        )
    if (
        not sasl_enabled_checkbox.value
        and external_kafka_enabled_checkbox.value
    ):
        _warnings.append(
            "External Kafka access requires SASL - enable SASL or disable external access."
        )
    if len(cluster_id_input.value) != 22:
        _warnings.append("The KRaft cluster id must be exactly 22 characters.")
    if (
        include_flink_checkbox.value
        and flink_state.get("FLINK_STATE_BACKEND") == "s3"
        and not flink_state.get("FLINK_S3_BUCKET")
    ):
        _warnings.append(
            "The s3 Flink checkpoint backend needs FLINK_S3_BUCKET set."
        )

    security_warnings = (
        mo.callout(mo.md("\n".join(f"- {w}" for w in _warnings)), kind="warn")
        if _warnings
        else None
    )
    return (security_warnings,)


@app.cell
def _():
    run_button = mo.ui.run_button(label="**Generate Variable File**")
    return (run_button,)


@app.cell
def _():
    save_to_config_dir_button = mo.ui.run_button(
        label="**Save directly to ./configs/confluent_platform_config/**",
        kind="neutral",
    )
    return (save_to_config_dir_button,)


@app.cell
def _(render_template_from_environment, run_button, save_to_config_dir_button):
    rendered_variables_file_confluent = (
        render_template_from_environment(
            template_path="src/helpers/config_file_jinja2_templates/confluent_variable_template.sh.j2"
        )
        if run_button.value or save_to_config_dir_button.value
        else ""
    )
    return (rendered_variables_file_confluent,)


@app.cell
def _(rendered_variables_file_confluent):
    confluent_vars_template_editor = mo.ui.code_editor(
        label="> **Edit your confluent_vars.sh file template.** \n",
        value=rendered_variables_file_confluent,
        language="bash",
        show_copy_button=True,
        theme="dark",
        max_height=1000,
        disabled=(not rendered_variables_file_confluent),
    )
    return (confluent_vars_template_editor,)


@app.cell
def _():
    name_variable_file_confluent = mo.ui.text(
        label="**Name your variable file:**",
        value="confluent_vars",
        max_length=256,
    )
    return (name_variable_file_confluent,)


@app.cell
def _(name_variable_file_confluent):
    confluent_vars_filename = (
        f"{name_variable_file_confluent.value}.sh"
        if name_variable_file_confluent.value
        else f"confluent_vars_{uuid.uuid4().hex[:4]}.sh"
    )
    return (confluent_vars_filename,)


@app.cell
def _(confluent_vars_filename, confluent_vars_template_editor):
    save_config_confluent = mo.download(
        data=confluent_vars_template_editor.value.encode("utf-8"),
        filename=confluent_vars_filename,
        mimetype="application/x-sh",
        label="**Save your confluent_vars.sh file**",
    )
    return (save_config_confluent,)


@app.cell
def _(
    name_variable_file_confluent,
    save_config_confluent,
    save_to_config_dir_button,
):
    save_file_stack = mo.hstack(
        [
            name_variable_file_confluent,
            save_config_confluent,
            save_to_config_dir_button,
        ],
        justify="space-around",
        align="center",
        gap=15,
    )
    return (save_file_stack,)


@app.cell
def _(confluent_vars_template_editor, save_file_stack):
    config_file_accordion_confluent = mo.accordion(
        items={
            "**Review & Save Results**": mo.vstack(
                [
                    mo.md(
                        "*The install scripts only read `configs/confluent_platform_config/confluent_vars.sh` - keep that name unless you rename it afterwards.*"
                    ),
                    confluent_vars_template_editor,
                    save_file_stack,
                ]
            )
        }
    )
    config_file_accordion_confluent
    return


@app.cell
def _(
    confluent_vars_filename,
    confluent_vars_template_editor,
    save_to_config_dir_button,
):
    _save_result = None
    if save_to_config_dir_button.value and confluent_vars_template_editor.value:
        _config_dir = os.path.join(
            os.path.dirname(__file__), "configs", "confluent_platform_config"
        )
        os.makedirs(_config_dir, exist_ok=True)

        _vars_path = os.path.join(_config_dir, confluent_vars_filename)
        _saved = []
        # Keep the previous file: it may hold credentials and a cluster id in use
        if os.path.exists(_vars_path):
            shutil.copy2(_vars_path, f"{_vars_path}.bak")
            _saved.append(f"{_vars_path}.bak (previous version)")

        with open(_vars_path, "w") as _f:
            _f.write(confluent_vars_template_editor.value)
        _saved.insert(0, _vars_path)

        _save_result = mo.callout(
            mo.md(
                "**Saved to `./configs/confluent_platform_config/`:**\n"
                + "\n".join(f"- `{p}`" for p in _saved)
            ),
            kind="success",
        )

    _save_result
    return


if __name__ == "__main__":
    app.run()
