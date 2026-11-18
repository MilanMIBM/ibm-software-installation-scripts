import marimo

__generated_with = "0.25.2"
app = marimo.App(
    width="full",
    app_title="Confluent Platform - Setup Config Generator",
)

with app.setup:
    import marimo as mo
    import shutil
    import uuid
    import os
    from src.helpers import multi_cluster_notebook as mcm_nb
    from src.helpers.vars_handling_helpers import (
        bool_str,
        dict_to_records,
        generate_cluster_id,
        ordered_values,
        records_to_dict,
        without_keys,
    )


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

    from src.helpers import confluent_operator_config
    from src.helpers.confluent_id_options_templates import (
        confluent_auth_mode_records,
        confluent_component_toggle_records,
        confluent_connector_management_options,
        confluent_deploy_mode_records,
        confluent_external_sasl_mechanism_options,
        confluent_internal_sasl_mechanism_options,
        confluent_mds_user_store_records,
        confluent_operator_approval_options,
        confluent_operator_sasl_impl_options,
        confluent_operator_size_presets,
        confluent_operator_tls_source_options,
        confluent_operator_var_order,
        confluent_sasl_mechanism_options,
        confluent_sasl_protocol_records,
        confluent_size_presets,
        confluent_size_records,
        default_confluent_component_toggles,
        default_confluent_deploy_mode,
        default_confluent_external_access,
        default_confluent_external_sasl_mechanisms,
        default_confluent_images,
        default_confluent_internal_sasl_mechanisms,
        default_confluent_ldap,
        default_confluent_mds,
        default_confluent_oauth,
        default_confluent_operator,
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
        default_flink_operator_olm,
        default_flink_project_and_storage,
        default_flink_state,
        flink_cmf_resource_mode_options,
        flink_operator_mode_overrides,
        flink_operator_source_options,
        flink_size_presets,
        flink_state_backend_records,
        operator_mode_overrides,
        records_with_overrides,
        without_scram,
    )
    from src.helpers.jinja2_template_rendering_helpers import (
        render_template_from_environment,
    )
    from src.helpers.marimo_sortablekv import sortable_kv

    return (
        confluent_auth_mode_records,
        confluent_component_toggle_records,
        confluent_connector_management_options,
        confluent_deploy_mode_records,
        confluent_external_sasl_mechanism_options,
        confluent_internal_sasl_mechanism_options,
        confluent_mds_user_store_records,
        confluent_operator_approval_options,
        confluent_operator_config,
        confluent_operator_sasl_impl_options,
        confluent_operator_size_presets,
        confluent_operator_tls_source_options,
        confluent_operator_var_order,
        confluent_sasl_mechanism_options,
        confluent_sasl_protocol_records,
        confluent_size_presets,
        confluent_size_records,
        default_confluent_component_toggles,
        default_confluent_deploy_mode,
        default_confluent_external_access,
        default_confluent_external_sasl_mechanisms,
        default_confluent_images,
        default_confluent_internal_sasl_mechanisms,
        default_confluent_ldap,
        default_confluent_mds,
        default_confluent_oauth,
        default_confluent_operator,
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
        default_flink_operator_olm,
        default_flink_project_and_storage,
        default_flink_state,
        flink_cmf_resource_mode_options,
        flink_operator_mode_overrides,
        flink_operator_source_options,
        flink_size_presets,
        flink_state_backend_records,
        operator_mode_overrides,
        records_with_overrides,
        render_template_from_environment,
        sortable_kv,
        without_scram,
    )


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
        "CONFLUENT_SASL_PROTOCOL",
        "CONFLUENT_SASL_MECHANISM",
        "CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS",
        "CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS",
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
        # Operator mode (plan: .claude/plans/confluent-operator-install-mode/)
        "CONFLUENT_DEPLOY_MODE",
        "CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL",
        "CONFLUENT_OPERATOR_TLS_SOURCE",
        "CONFLUENT_OPERATOR_SASL_IMPL",
        "CONFLUENT_CONNECTOR_MANAGEMENT",
        "FLINK_OPERATOR_SOURCE",
        "FLINK_CMF_RESOURCE_MODE",
        "FLINK_OLM_INSTALL_PLAN_APPROVAL",
    }
    return (widget_controlled_keys,)


@app.cell
def _(
    confluent_auth_mode_records,
    confluent_deploy_mode_records,
    confluent_external_sasl_mechanism_options,
    confluent_internal_sasl_mechanism_options,
    confluent_mds_user_store_records,
    confluent_sasl_mechanism_options,
    confluent_sasl_protocol_records,
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
    sasl_protocol_options = {
        r["sasl_protocol_name"]: r["sasl_protocol_id"]
        for r in confluent_sasl_protocol_records
    }
    internal_sasl_mechanism_options = {
        m: m for m in confluent_internal_sasl_mechanism_options
    }
    external_sasl_mechanism_options = {
        m: m for m in confluent_external_sasl_mechanism_options
    }
    mds_user_store_options = {
        r["user_store_name"]: r["user_store_id"]
        for r in confluent_mds_user_store_records
    }

    # Deploy mode - scripts (raw manifests) | operator (CFK + cp-fko through OLM)
    deploy_mode_options = {
        r["deploy_mode_name"]: r["deploy_mode_id"] for r in confluent_deploy_mode_records
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
        deploy_mode_options,
        external_sasl_mechanism_options,
        flink_state_backend_options,
        internal_sasl_mechanism_options,
        login_argument_options,
        mds_user_store_options,
        sasl_mechanism_options,
        sasl_protocol_options,
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
        "sasl_mechanism": "**Select the SASL mechanism the brokers and components use:**",
        "internal_sasl_mechanisms": "**Select the in-cluster listener SASL mechanisms (what clients may use):**",
        "sasl_protocol": "**Select the in-cluster Kafka security protocol:**",
        "external_sasl_mechanisms": "**Select the EXTERNAL listener SASL mechanisms (SASL_SSL):**",
        "mds_user_store": "**Select the MDS / RBAC user store:**",
        "flink_state_backend": "**Select the Flink checkpoint storage:**",
        "confluent_storage_class": "**Select the broker storage class:**",
        "flink_cmf_storage_class": "**Select the CMF metadata storage class:**",
        "flink_state_storage_class": "**Select the Flink checkpoint PVC storage class (RWX, pvc backend):**",
        "components_multiselect": "**Select the optional components to install (the broker is always installed):**",
        "auth_enabled": "Protect the web UIs with authentication?",
        "sasl_enabled": "Require **SASL** authentication for Kafka clients?",
        "mds_enabled": "Enable **MDS / RBAC** (`confluent login`)? *Requires SASL, licensed (30-day trial).*",
        "external_kafka_enabled": "Expose Kafka **outside the cluster** (SASL_SSL passthrough routes, PLAIN by default)? *Requires SASL.*",
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
        "deploy_mode": "**Select the deploy mode:**",
        "operator_approval": "**Operator InstallPlan approval (OLM):**",
        "operator_tls_source": "**In-cluster TLS certificates (operator mode):**",
        "operator_sasl_impl": "**SASL implementation (operator mode; scram = configOverrides, outside Confluent Support):**",
        "connector_management": "**Connector management (operator mode):**",
        "flink_operator_source": "**Flink operator source** *(follow = the deploy mode decides: olm with operator, helm with scripts)*:",
        "flink_cmf_resource_mode": "**CMF resources** *(follow = cfk with OLM, cli with Helm)*:",
        "flink_olm_approval": "**cp-fko InstallPlan approval (OLM):**",
    }
    return (widget_labels,)


@app.cell
def _(
    auth_mode_select,
    block_storage_class_select,
    confluent_c3_version_input,
    confluent_version_input,
    external_sasl_mechanisms_select,
    file_storage_class_select,
    flink_state_backend_select,
    internal_sasl_mechanisms_select,
    login_argument_select,
    mds_user_store_select,
    sasl_mechanism_select,
    sasl_protocol_select,
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
                    sasl_protocol_select.style({"width": widget_width}),
                    sasl_mechanism_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    internal_sasl_mechanisms_select.style({"width": widget_width}),
                    external_sasl_mechanisms_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    auth_mode_select.style({"width": widget_width}),
                    mds_user_store_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    flink_state_backend_select.style({"width": widget_width}),
                    mo.md(""),
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
    confluent_deploy_mode,
    connector_management_select,
    deploy_mode_select,
    external_kafka_enabled_checkbox,
    mds_enabled_checkbox,
    operator_approval_select,
    operator_sasl_impl_select,
    operator_tls_source_select,
    sasl_enabled_checkbox,
    widget_width,
):
    # The operator selects appear only in operator mode
    _operator_selects = (
        [
            mo.hstack(
                [
                    operator_approval_select.style({"width": widget_width}),
                    operator_tls_source_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    operator_sasl_impl_select.style({"width": widget_width}),
                    connector_management_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
        ]
        if confluent_deploy_mode == "operator"
        else []
    )
    components_and_security_stack = mo.vstack(
        [
            deploy_mode_select.style({"width": widget_width}),
            *_operator_selects,
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
    confluent_deploy_mode,
    confluent_operator_sizing_records,
    confluent_sizing_records,
    confluent_storage_class_select,
    widget_width,
):
    _kraft_item = (
        {
            "**KRaft controllers (operator mode)** *(prefilled from the selected size)*": confluent_operator_sizing_records
        }
        if confluent_deploy_mode == "operator"
        else {}
    )
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
            **_kraft_item,
        },
        multiple=True,
    )
    install_specs_accordion
    return


@app.cell
def _(
    auth_password_input,
    confluent_deploy_mode,
    confluent_external_access_records,
    confluent_images_records,
    confluent_ldap_records,
    confluent_mds_records,
    confluent_oauth_records,
    confluent_operator_records,
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
            **(
                {"*Operator (OLM)* ***(optional)***": confluent_operator_records}
                if confluent_deploy_mode == "operator"
                else {}
            ),
        },
        multiple=True,
    )
    advanced_specs_accordion
    return


@app.cell
def _(
    flink_cert_manager_records,
    flink_cmf_endpoint_records,
    flink_cmf_resource_mode_select,
    flink_cmf_storage_class_select,
    flink_create_routes_checkbox,
    flink_helm_records,
    flink_images_records,
    flink_license_records,
    flink_naming_records,
    flink_olm_approval_select,
    flink_operator_olm_records,
    flink_operator_source,
    flink_operator_source_select,
    flink_s3_access_key_input,
    flink_s3_path_style_checkbox,
    flink_s3_secret_key_input,
    flink_sizing_records,
    flink_state_records,
    flink_state_storage_class_select,
    include_flink_checkbox,
    widget_width,
):
    # cp-fko settings appear only when the resolved Flink operator source is not helm
    _olm_items = (
        [flink_olm_approval_select.style({"width": widget_width}), flink_operator_olm_records]
        if flink_operator_source != "helm"
        else []
    )
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
                    mo.hstack(
                        [
                            flink_operator_source_select.style({"width": widget_width}),
                            flink_cmf_resource_mode_select.style({"width": widget_width}),
                        ],
                        justify="space-around",
                    ),
                    *_olm_items,
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
    sasl_mechanism_select = mo.ui.dropdown(
        label=widget_labels.get("sasl_mechanism"),
        options=sasl_mechanism_options,
        value=list(sasl_mechanism_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (sasl_mechanism_select,)


@app.cell
def _(sasl_protocol_options, widget_labels):
    sasl_protocol_select = mo.ui.dropdown(
        label=widget_labels.get("sasl_protocol"),
        options=sasl_protocol_options,
        value=list(sasl_protocol_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (sasl_protocol_select,)


@app.cell
def _(
    default_confluent_internal_sasl_mechanisms,
    internal_sasl_mechanism_options,
    widget_labels,
):
    # The platform's own mechanism (the dropdown above) is accepted whether or
    # not it is selected here.
    internal_sasl_mechanisms_select = mo.ui.multiselect(
        label=widget_labels.get("internal_sasl_mechanisms"),
        options=internal_sasl_mechanism_options,
        value=default_confluent_internal_sasl_mechanisms,
        full_width=True,
    )
    return (internal_sasl_mechanisms_select,)


@app.cell
def _(
    default_confluent_external_sasl_mechanisms,
    external_sasl_mechanism_options,
    widget_labels,
):
    # Order matters: the first selected mechanism is the one the generated
    # client properties use.
    external_sasl_mechanisms_select = mo.ui.multiselect(
        label=widget_labels.get("external_sasl_mechanisms"),
        options=external_sasl_mechanism_options,
        value=default_confluent_external_sasl_mechanisms,
        full_width=True,
    )
    return (external_sasl_mechanisms_select,)


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
        value=records_to_dict(default_confluent_images).get("CONFLUENT_VERSION", ""),
        full_width=True,
    )
    return (confluent_version_input,)


@app.cell
def _(default_confluent_images, widget_labels):
    confluent_c3_version_input = mo.ui.text(
        label=widget_labels.get("confluent_c3_version"),
        value=records_to_dict(default_confluent_images).get("CONFLUENT_C3_VERSION", ""),
        full_width=True,
    )
    return (confluent_c3_version_input,)


@app.cell
def _(widget_labels):
    cluster_url_input = mo.ui.text(
        label=widget_labels.get("cluster_url"),
        kind="url",
        debounce=300,  # the "Save to" line follows the typing
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
def _(default_confluent_deploy_mode, deploy_mode_options, widget_labels):
    deploy_mode_select = mo.ui.dropdown(
        label=widget_labels.get("deploy_mode"),
        options=deploy_mode_options,
        value=next(
            k for k, v in deploy_mode_options.items() if v == default_confluent_deploy_mode
        ),
        allow_select_none=False,
        full_width=True,
    )
    return (deploy_mode_select,)


@app.cell
def _(
    confluent_connector_management_options,
    confluent_operator_approval_options,
    confluent_operator_sasl_impl_options,
    confluent_operator_tls_source_options,
    flink_cmf_resource_mode_options,
    flink_operator_source_options,
    widget_labels,
):
    # Operator-mode selects; the first option is the default
    def _select(label_key, options):
        return mo.ui.dropdown(
            label=widget_labels.get(label_key),
            options=options,
            value=options[0],
            allow_select_none=False,
            full_width=True,
        )

    operator_approval_select = _select("operator_approval", confluent_operator_approval_options)
    operator_tls_source_select = _select("operator_tls_source", confluent_operator_tls_source_options)
    operator_sasl_impl_select = _select("operator_sasl_impl", confluent_operator_sasl_impl_options)
    connector_management_select = _select("connector_management", confluent_connector_management_options)
    flink_operator_source_select = _select("flink_operator_source", flink_operator_source_options)
    flink_cmf_resource_mode_select = _select("flink_cmf_resource_mode", flink_cmf_resource_mode_options)
    flink_olm_approval_select = _select("flink_olm_approval", confluent_operator_approval_options)
    return (
        connector_management_select,
        flink_cmf_resource_mode_select,
        flink_olm_approval_select,
        flink_operator_source_select,
        operator_approval_select,
        operator_sasl_impl_select,
        operator_tls_source_select,
    )


@app.cell
def _(
    confluent_operator_config,
    deploy_mode_select,
    flink_cmf_resource_mode_select,
    flink_operator_source_select,
):
    # The modes the template and the Flink widgets follow ("follow" = not written)
    confluent_deploy_mode = deploy_mode_select.value
    _source = flink_operator_source_select.value
    flink_operator_source, _ = confluent_operator_config.resolve_flink_operator_source(
        None if _source == "follow" else _source, confluent_deploy_mode
    )
    _cmf = flink_cmf_resource_mode_select.value
    flink_cmf_resource_mode, _ = confluent_operator_config.resolve_flink_cmf_resource_mode(
        None if _cmf == "follow" else _cmf, flink_operator_source
    )
    return confluent_deploy_mode, flink_cmf_resource_mode, flink_operator_source


@app.cell
def _():
    return


@app.cell
def _(
    confluent_operator_size_presets,
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
    # Operator mode: KRaft controllers and the operator-only storage sizes
    confluent_operator_sizing_records = sortable_kv(
        label="KRaft controllers (odd count) and operator-mode storage:",
        value=dict_to_records(confluent_operator_size_presets[size_select.value]),
        addable=False,
        removable=False,
        editable=True,
        movable=False,
    )
    return (
        confluent_operator_sizing_records,
        confluent_sizing_records,
        flink_sizing_records,
    )


@app.cell
def _(
    default_confluent_external_access,
    default_confluent_images,
    default_confluent_ldap,
    default_confluent_mds,
    default_confluent_oauth,
    default_confluent_operator,
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
        "Kafka SASL (clients are comma-separated; TLS settings apply to SASL_SSL):",
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
    confluent_operator_records = _kv(
        "Operator (OLM): CFK package, channel, catalog, target namespaces, timeouts (operator mode):",
        default_confluent_operator,
    )
    return (
        confluent_external_access_records,
        confluent_images_records,
        confluent_ldap_records,
        confluent_mds_records,
        confluent_oauth_records,
        confluent_operator_records,
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
    default_flink_operator_olm,
    default_flink_state,
    flink_operator_mode_overrides,
    flink_operator_source,
    records_with_overrides,
    sortable_kv,
    widget_controlled_keys,
):
    # Operator source (not helm): CMF 2.5.0 and its SQL image are the defaults shown
    _overrides = flink_operator_mode_overrides if flink_operator_source != "helm" else {}
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
    flink_helm_records = _kv(
        "Helm charts:", records_with_overrides(default_flink_helm, _overrides)
    )
    flink_images_records = _kv(
        "Images (empty registry = chart default):",
        records_with_overrides(default_flink_images, _overrides),
    )
    flink_operator_olm_records = _kv(
        "cp-fko through OLM (channel follows FLINK_CMF_CHART_VERSION):",
        default_flink_operator_olm,
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
        flink_operator_olm_records,
        flink_state_records,
    )


@app.cell
def _(
    auth_enabled_checkbox,
    auth_mode_select,
    auth_password_input,
    component_toggle_table,
    confluent_c3_version_input,
    confluent_deploy_mode,
    confluent_external_access_records,
    confluent_images_records,
    confluent_ldap_records,
    confluent_mds_records,
    confluent_oauth_records,
    confluent_operator_records,
    confluent_operator_size_presets,
    confluent_operator_sizing_records,
    confluent_operator_var_order,
    confluent_ports_records,
    confluent_routes_and_waits_records,
    confluent_sasl_records,
    confluent_size_presets,
    confluent_sizing_records,
    confluent_storage_class_select,
    confluent_version_input,
    confluent_web_ui_auth_records,
    connector_management_select,
    create_routes_checkbox,
    default_confluent_component_toggles,
    default_confluent_external_access,
    default_confluent_images,
    default_confluent_ldap,
    default_confluent_mds,
    default_confluent_oauth,
    default_confluent_operator,
    default_confluent_ports,
    default_confluent_routes_and_waits,
    default_confluent_sasl,
    default_confluent_storage,
    default_confluent_web_ui_auth,
    external_kafka_enabled_checkbox,
    external_sasl_mechanisms_select,
    internal_sasl_mechanisms_select,
    license_key_input,
    mds_enabled_checkbox,
    mds_user_store_select,
    monitoring_network_policy_checkbox,
    operator_approval_select,
    operator_mode_overrides,
    operator_sasl_impl_select,
    operator_tls_source_select,
    registry_password_input,
    sasl_enabled_checkbox,
    sasl_mechanism_select,
    sasl_protocol_select,
    size_select,
    without_scram,
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
            "CONFLUENT_SASL_PROTOCOL": sasl_protocol_select.value,
            "CONFLUENT_SASL_MECHANISM": sasl_mechanism_select.value,
            # Nothing selected means the platform's own mechanism only; an empty
            # value would make the scripts fall back to their default list.
            "CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS": ",".join(
                internal_sasl_mechanisms_select.value
            )
            or sasl_mechanism_select.value,
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
            ),
            "CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS": ",".join(
                external_sasl_mechanisms_select.value
            ),
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

    # Operator mode (plan O9): CFK components authenticate with PLAIN; with SASL impl
    # plain the listeners accept PLAIN only, so SCRAM is dropped from both lists.
    if confluent_deploy_mode == "operator":
        confluent_sasl.update(
            {k: v for k, v in operator_mode_overrides.items() if k in confluent_sasl}
        )
        if operator_sasl_impl_select.value == "plain":
            confluent_sasl["CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS"] = without_scram(
                confluent_sasl["CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS"]
            )
            confluent_external_access["CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS"] = (
                without_scram(
                    confluent_external_access["CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS"]
                )
            )
        _operator_values = {
            "CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL": operator_approval_select.value,
            "CONFLUENT_OPERATOR_TLS_SOURCE": operator_tls_source_select.value,
            "CONFLUENT_OPERATOR_SASL_IMPL": operator_sasl_impl_select.value,
            "CONFLUENT_CONNECTOR_MANAGEMENT": connector_management_select.value,
            **ordered_values(default_confluent_operator, confluent_operator_records),
        }
        # Same order as 0_confluent_prepare_template_config.sh writes them
        confluent_operator = {k: _operator_values[k] for k in confluent_operator_var_order}
        confluent_operator_sizing = ordered_values(
            dict_to_records(confluent_operator_size_presets[size_select.value]),
            confluent_operator_sizing_records,
        )
    else:
        confluent_operator = {}
        confluent_operator_sizing = {}
    return (
        confluent_component_toggles,
        confluent_external_access,
        confluent_images,
        confluent_ldap,
        confluent_mds,
        confluent_oauth,
        confluent_operator,
        confluent_operator_sizing,
        confluent_ports,
        confluent_routes_and_waits,
        confluent_sasl,
        confluent_sizing,
        confluent_web_ui_auth,
    )


@app.cell
def _(
    confluent_operator_config,
    default_flink_cert_manager,
    default_flink_cmf_endpoint,
    default_flink_helm,
    default_flink_images,
    default_flink_license,
    default_flink_naming,
    default_flink_operator_olm,
    default_flink_project_and_storage,
    default_flink_state,
    flink_cert_manager_records,
    flink_cmf_endpoint_records,
    flink_cmf_resource_mode_select,
    flink_cmf_storage_class_select,
    flink_create_routes_checkbox,
    flink_helm_records,
    flink_images_records,
    flink_license_records,
    flink_naming_records,
    flink_olm_approval_select,
    flink_operator_olm_records,
    flink_operator_source,
    flink_operator_source_select,
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

    # Flink operator settings: the explicit selects (follow = not written), plus the
    # cp-fko block when the resolved source is not helm.
    flink_operator_olm = {
        _k: _select.value
        for _k, _select in (
            ("FLINK_OPERATOR_SOURCE", flink_operator_source_select),
            ("FLINK_CMF_RESOURCE_MODE", flink_cmf_resource_mode_select),
        )
        if _select.value != "follow"
    }
    if flink_operator_source != "helm":
        _olm = ordered_values(
            default_flink_operator_olm,
            flink_operator_olm_records,
            {"FLINK_OLM_INSTALL_PLAN_APPROVAL": flink_olm_approval_select.value},
        )
        # CMF/FKO lock: an unedited channel/CSV follows the CMF chart version chosen above
        _default_olm = {r["key"]: r["value"] for r in default_flink_operator_olm}
        if (_olm["FLINK_OLM_CHANNEL"], _olm["FLINK_OLM_STARTING_CSV"]) == (
            _default_olm["FLINK_OLM_CHANNEL"],
            _default_olm["FLINK_OLM_STARTING_CSV"],
        ):
            try:
                _fko = confluent_operator_config.fko_for_cmf(flink_helm["FLINK_CMF_CHART_VERSION"])
                _olm["FLINK_OLM_CHANNEL"] = _fko["channel"]
                _olm["FLINK_OLM_STARTING_CSV"] = _fko["csv"]
            except KeyError:
                pass  # the warnings cell reports the unknown CMF line
        flink_operator_olm.update(_olm)
    return (
        flink_cert_manager,
        flink_cmf_endpoint,
        flink_helm,
        flink_images,
        flink_license,
        flink_naming,
        flink_operator_olm,
        flink_sizing,
        flink_state,
    )


@app.cell
def _(
    cluster_id_input,
    confluent_component_toggles,
    confluent_deploy_mode,
    confluent_external_access,
    confluent_images,
    confluent_mds,
    confluent_operator,
    confluent_operator_config,
    confluent_operator_sizing,
    confluent_sasl,
    confluent_web_ui_auth,
    external_kafka_enabled_checkbox,
    external_sasl_mechanisms_select,
    flink_helm,
    flink_images,
    flink_operator_olm,
    flink_operator_source,
    flink_sizing,
    flink_state,
    include_flink_checkbox,
    internal_sasl_mechanisms_select,
    license_key_input,
    mds_enabled_checkbox,
    operator_sasl_impl_select,
    project_confluent_server_input,
    sasl_enabled_checkbox,
    sasl_mechanism_select,
    sasl_protocol_select,
):
    # Flag combinations the install scripts reject
    _warnings = []
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
    if (
        external_kafka_enabled_checkbox.value
        and not external_sasl_mechanisms_select.value
    ):
        _warnings.append(
            "Select at least one SASL mechanism for the EXTERNAL listener."
        )
    _internal = set(internal_sasl_mechanisms_select.value) | {sasl_mechanism_select.value}
    if sasl_enabled_checkbox.value and not internal_sasl_mechanisms_select.value:
        _warnings.append(
            f"No in-cluster listener mechanisms selected - the listeners will accept "
            f"only {sasl_mechanism_select.value}, the platform's own."
        )
    if (
        sasl_enabled_checkbox.value
        and "PLAIN" in _internal
        and sasl_protocol_select.value == "SASL_PLAINTEXT"
    ):
        _warnings.append(
            "The in-cluster listeners accept PLAIN over SASL_PLAINTEXT: a client that picks "
            "PLAIN sends its password unencrypted across the pod network. Confluent recommends "
            "PLAIN only with SASL_SSL."
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

    # Operator mode: what the generator changes, then the operator-mode checks
    # (confluent_operator_config.check, the same rules as cfo_check_config).
    _flink_olm = include_flink_checkbox.value and flink_operator_source != "helm"
    if confluent_deploy_mode == "operator":
        _scram_picked = [
            m
            for m in [sasl_mechanism_select.value, *internal_sasl_mechanisms_select.value, *external_sasl_mechanisms_select.value]
            if m.startswith("SCRAM-")
        ]
        if _scram_picked:
            _warnings.append(
                "Operator mode writes CONFLUENT_SASL_MECHANISM=PLAIN (CFK components use PLAIN)"
                + (
                    " and drops SCRAM from the listener lists (SASL implementation plain)."
                    if operator_sasl_impl_select.value == "plain"
                    else "; the listener lists keep SCRAM (SASL implementation scram)."
                )
            )
    if confluent_deploy_mode == "operator" or _flink_olm:
        _values = {
            "CONFLUENT_DEPLOY_MODE": confluent_deploy_mode,
            "PROJECT_CONFLUENT_SERVER": project_confluent_server_input.value,
            **confluent_images,
            **confluent_component_toggles,
            **confluent_web_ui_auth,
            **confluent_sasl,
            **confluent_mds,
            **confluent_external_access,
            **confluent_operator,
            **confluent_operator_sizing,
        }
        if include_flink_checkbox.value:
            _values.update(
                {**flink_sizing, **flink_helm, **flink_images, **flink_operator_olm}
            )
        # Only the names the checks know; secret values never go in (the license is a boolean)
        _values = {
            k: v for k, v in _values.items() if k in confluent_operator_config.ALLOWED_VARS
        }
        _result = confluent_operator_config.check(
            _values, license_present=bool(license_key_input.value)
        )
        _warnings += [f"Error: {e}" for e in _result["errors"]] + _result["warnings"]

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
        label="**Save to the folder shown above**",
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
        # marimo's gap is in rem: keep it small and wrap, so no button is squeezed out.
        justify="center",
        align="center",
        gap=1.5,
        wrap=True,
    )
    return (save_file_stack,)


@app.cell
def _():
    mcm_enable_checkbox = mo.ui.checkbox(
        label="**Manage multiple clusters**", value=mcm_nb.mode_default()
    )
    return (mcm_enable_checkbox,)


@app.cell
def _():
    # Starts blank on purpose: prefilling the current cluster would make a new URL overwrite it.
    mcm_name_input = mo.ui.text(
        label="**Cluster name (optional):**",
        placeholder="taken from the cluster URL",
        debounce=300,
    )
    return (mcm_name_input,)


@app.cell
def _():
    mcm_migrate_button = mo.ui.run_button(label="**Migrate now**", kind="warn")
    return (mcm_migrate_button,)


@app.cell
def _(mcm_migrate_button):
    mcm_migrate_result = mcm_nb.run_migration() if mcm_migrate_button.value else None
    return (mcm_migrate_result,)


@app.cell
def _(cluster_url_input, mcm_enable_checkbox, mcm_migrate_result, mcm_name_input):
    _after_migration = mcm_migrate_result  # a migration moves the folders resolved here
    mcm_target = mcm_nb.resolve_target(
        "confluent_platform_config",
        mcm_enable_checkbox.value,
        mcm_name_input.value,
        cluster_url_input.value,
    )
    return (mcm_target,)


@app.cell
def _(mcm_target):
    # Rebuilt with every change of target, so a tick never carries over to another cluster.
    mcm_overwrite_checkbox = mo.ui.checkbox(
        label=mcm_nb.overwrite_label(mcm_target), value=False
    )
    return (mcm_overwrite_checkbox,)


@app.cell
def _(mcm_migrate_result):
    _after_migration = mcm_migrate_result  # a migration empties this list
    mcm_flat_configs = mcm_nb.flat_configs()
    return (mcm_flat_configs,)


@app.cell
def _(cluster_url_input, mcm_migrate_result):
    _after_migration = mcm_migrate_result  # a migration creates cluster folders
    # From the URL only, so the cell below does not redraw while a name is typed.
    mcm_url_cluster = mcm_nb.delineated_owner(cluster_url_input.value)
    return (mcm_url_cluster,)


@app.cell
def _(mcm_enable_checkbox, mcm_name_input, mcm_url_cluster):
    # The only cell showing the inputs: the live lines below redraw without taking the focus away.
    # A cluster with its own folder keeps it for good, so the tick shows forced on for its URL.
    _forced = bool(mcm_url_cluster) and not mcm_enable_checkbox.value
    mo.hstack(
        [
            mo.ui.checkbox(
                label=f"**Manage multiple clusters** (always on for cluster {mcm_url_cluster})",
                value=True,
                disabled=True,
            )
            if _forced
            else mcm_enable_checkbox,
            mcm_name_input if mcm_enable_checkbox.value else "",
        ],
        justify="start",
        align="center",
        gap=2,
    )
    return


@app.cell
def _(mcm_overwrite_checkbox, mcm_target):
    _one_way = mcm_nb.one_way_markdown(mcm_target)
    mo.vstack(
        [
            mo.md(mcm_nb.save_to_markdown(mcm_target)),
            mo.callout(mo.md(_one_way), kind="warn") if _one_way else "",
            mcm_overwrite_checkbox if mcm_target.conflict else "",
        ]
    )
    return


@app.cell
def _(mcm_flat_configs, mcm_migrate_button, mcm_migrate_result, mcm_target):
    _items = []
    if mcm_migrate_result is not None:
        _ok, _output = mcm_migrate_result
        _items.append(
            mo.callout(
                mo.vstack(
                    [
                        mo.md("**Migration finished.**" if _ok else "**Migration failed.**"),
                        mo.plain_text(_output[-4000:]),
                    ]
                ),
                kind="success" if _ok else "danger",
            )
        )
    if mcm_target.enabled and mcm_flat_configs:
        _items.append(
            mo.callout(
                mo.vstack(
                    [
                        mo.md(mcm_nb.flat_configs_markdown(mcm_flat_configs)),
                        mcm_migrate_button,
                    ]
                ),
                kind="warn",
            )
        )
    mo.vstack(_items) if _items else None
    return


@app.cell
def _(confluent_vars_template_editor, save_file_stack):
    config_file_accordion_confluent = mo.accordion(
        items={
            "**Review & Save Results**": mo.vstack(
                [
                    mo.md(
                        "*The install scripts only read `confluent_vars.sh` in the folder shown in the **Save to** line - keep that name unless you rename it afterwards.*"
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
def _(confluent_vars_filename, mcm_target):
    # In its own cell, under the save button: rebuilding the accordion on every keystroke
    # in the cluster URL would collapse it.
    mo.md(mcm_nb.save_paths_markdown(mcm_target, [confluent_vars_filename], backup=True))
    return


@app.cell
def _(
    confluent_vars_filename,
    confluent_vars_template_editor,
    mcm_overwrite_checkbox,
    mcm_target,
    save_to_config_dir_button,
):
    _save_result = None
    _blockers = (
        mcm_nb.save_blockers(
            mcm_target, mcm_overwrite_checkbox.value, confluent_vars_template_editor.value
        )
        if save_to_config_dir_button.value
        else []
    )
    if _blockers:
        _save_result = mo.callout(
            mo.md("**Not saved.** " + " ".join(_blockers)), kind="danger"
        )
    elif save_to_config_dir_button.value and confluent_vars_template_editor.value:
        _config_dir = mcm_target.directory
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

        _notes = mcm_nb.finish_save(mcm_target)

        _save_result = mo.callout(
            mo.md(
                f"**Saved to `{mcm_target.display}`:**\n"
                + "\n".join(f"- `{p}`" for p in _saved)
                + "".join(f"\n\n{n}" for n in _notes)
            ),
            kind="success",
        )

    _save_result
    return


if __name__ == "__main__":
    app.run()
