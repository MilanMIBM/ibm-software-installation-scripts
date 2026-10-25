import marimo

__generated_with = "0.25.1"
app = marimo.App(
    width="full",
    app_title="IBM Concert - Setup Config Generator",
)

with app.setup:
    import marimo as mo
    import json
    import os
    import secrets
    import shutil
    import string
    import urllib.request
    import uuid


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

    from src.helpers.concert_id_options_templates import (
        concert_block_storage_options,
        concert_custom_sizing_keys,
        concert_dataapps_scale_level,
        concert_datastore_consumer_records,
        concert_datastore_provider_records,
        concert_datastore_server_records,
        concert_fixed_requests,
        concert_hub_mode_records,
        concert_image_source_records,
        concert_optimize_other_storage_gi,
        concert_preset_records,
        concert_product_records,
        concert_profile_presets,
        concert_profile_records,
        concert_release_name_excludes,
        concert_release_records,
        concert_runner_records,
        concert_scale_level_optional_requests,
        concert_scale_level_requests,
        default_concert_admin,
        default_concert_ai,
        default_concert_ds_other,
        default_concert_ds_postgres,
        default_concert_ds_s3,
        default_concert_hub,
        default_concert_images,
        default_concert_namespaces,
        default_concert_optimize,
        default_concert_preset,
        default_concert_products,
        default_concert_profile,
        default_concert_release,
        default_concert_release_tag,
        default_concert_runner,
        default_concert_securecoder,
        default_concert_sizing,
        default_concert_storage,
        default_concert_workflows,
    )
    from src.helpers.marimo_sortablekv import sortable_kv
    from src.helpers.jinja2_template_rendering_helpers import (
        render_template_from_environment,
    )

    return (
        concert_block_storage_options,
        concert_custom_sizing_keys,
        concert_dataapps_scale_level,
        concert_datastore_consumer_records,
        concert_datastore_provider_records,
        concert_datastore_server_records,
        concert_fixed_requests,
        concert_hub_mode_records,
        concert_image_source_records,
        concert_optimize_other_storage_gi,
        concert_preset_records,
        concert_product_records,
        concert_profile_presets,
        concert_profile_records,
        concert_release_name_excludes,
        concert_release_records,
        concert_runner_records,
        concert_scale_level_optional_requests,
        concert_scale_level_requests,
        default_concert_admin,
        default_concert_ai,
        default_concert_ds_other,
        default_concert_ds_postgres,
        default_concert_ds_s3,
        default_concert_hub,
        default_concert_images,
        default_concert_namespaces,
        default_concert_optimize,
        default_concert_preset,
        default_concert_products,
        default_concert_profile,
        default_concert_release,
        default_concert_release_tag,
        default_concert_runner,
        default_concert_securecoder,
        default_concert_sizing,
        default_concert_storage,
        default_concert_workflows,
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
def quantity_cpu(value):
    # Kubernetes CPU quantity ("4", "250m") -> cores; unparsable -> 0
    v = str(value or "").strip()
    try:
        return float(v[:-1]) / 1000 if v.endswith("m") else float(v)
    except ValueError:
        return 0.0


@app.function
def quantity_gi(value):
    # Kubernetes memory/storage quantity ("12Gi", "512Mi", "1Ti") -> Gi; unparsable -> 0
    v = str(value or "").strip()
    for suffix, factor in (
        ("Ti", 1024),
        ("Gi", 1),
        ("Mi", 1 / 1024),
        ("Ki", 1 / 1024**2),
    ):
        if v.endswith(suffix):
            try:
                return float(v[: -len(suffix)]) * factor
            except ValueError:
                return 0.0
    try:
        return float(v) / 1024**3
    except ValueError:
        return 0.0


@app.function
def generate_password(length=20):
    # Alphanumeric only: safe in params.ini, URLs and Keycloak
    alphabet = string.ascii_letters + string.digits
    while True:
        pw = "".join(secrets.choice(alphabet) for _ in range(length))
        if any(c.isdigit() for c in pw) and any(c.isupper() for c in pw):
            return pw


@app.function
def generate_turbonomic_password(length=20):
    # Upper, lower, digit and one of - _ . : meets the usual complexity rules
    # and stays safe in form posts and the single-quoted export
    while True:
        pw = list(generate_password(length - 1))
        if any(c.islower() for c in pw):
            pw.insert(secrets.randbelow(length), secrets.choice("-_."))
            return "".join(pw)


@app.function
def existing_config_value(key):
    # Value of a single-quoted export in an already saved concert_vars.sh, so a
    # re-save keeps credentials that a live install depends on.
    import re

    path = os.path.join(
        os.path.dirname(__file__),
        "configs",
        "concert_config",
        "concert_vars.sh",
    )
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None
    m = re.search(rf"^export {re.escape(key)}='(.*)'$", text, re.M)
    return m.group(1).replace("'\\''", "'") if m else None


@app.function
def fetch_live_releases(fallback, excludes):
    # On-prem releases with an x86 archive, newest first; offline -> fallback
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/IBM/Concert/releases?per_page=30",
            headers={"Accept": "application/vnd.github+json"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            releases = json.load(resp)
    except Exception:
        return fallback
    live = []
    for rel in releases:
        name = rel.get("name") or rel.get("tag_name", "")
        if rel.get("draft") or any(x.lower() in name.lower() for x in excludes):
            continue
        assets = {a.get("name") for a in rel.get("assets", [])}
        if "ibm-concert-x86.tar.gz" not in assets:
            continue
        tag = rel["tag_name"]
        live.append(
            {
                "release_name": f"{name} ({rel.get('published_at', '')[:10]})",
                "CONCERT_VERSION": tag.lstrip("v"),
                "CONCERT_RELEASE_TAG": tag,
                "CONCERT_ARCHIVE": "ibm-concert-x86.tar.gz",
            }
        )
    return live or fallback


@app.cell(hide_code=True)
def _():
    mo.md(r"""
    ## **IBM Concert** - Setup Config Generator

    Writes `configs/concert_config/concert_vars.sh` for `scripts/install_ibm_concert/`.
    Defaults follow the plan's decisions: production profile, external data stores provisioned in the cluster,
    Workflows with Istio (FaaS off), Hub in *auto* mode, installer running as a Job in the cluster.
    """)
    return


@app.cell
def _():
    # Keys owned by a dedicated widget rather than a key/value list
    widget_controlled_keys = {
        "CONCERT_VERSION",
        "CONCERT_RELEASE_TAG",
        "CONCERT_ARCHIVE",
        "CONCERT_PROFILE",
        "CONCERT_ACCEPT_LICENSE",
        "CONCERT_RUNNER",
        "CONCERT_IMAGE_SOURCE",
        "CONCERT_PRESET",
        "CONCERT_INSTALL_CONCERT",
        "CONCERT_INSTALL_DATAAPPS",
        "CONCERT_INSTALL_WORKFLOWS",
        "CONCERT_INSTALL_SECURECODER",
        "CONCERT_INSTALL_VEIAS",
        "CONCERT_ENABLE_CROSS_PRODUCT_INTEGRATION",
        "CONCERT_HUB_MODE",
        "CONCERT_SCALE_DATAAPPS",
        "CONCERT_STG_CLASS_BLOCK",
        "CONCERT_WORKFLOWS_ENABLE_ISTIO",
        "CONCERT_WORKFLOWS_ENABLE_FAAS",
        "CONCERT_ADMIN_USERNAME",
        "CONCERT_ADMIN_PASSWORD",
    }
    return (widget_controlled_keys,)


@app.cell
def _(
    concert_block_storage_options,
    concert_datastore_provider_records,
    concert_hub_mode_records,
    concert_image_source_records,
    concert_preset_records,
    concert_profile_records,
    concert_release_name_excludes,
    concert_release_records,
    concert_runner_records,
):
    login_argument_options = {
        "Username/Password": "--username=${OCP_USERNAME} --password=${OCP_PASSWORD}",
        "Token": "--token=${OCP_TOKEN}",
    }
    release_records = fetch_live_releases(
        concert_release_records, concert_release_name_excludes
    )
    release_options = {
        r["release_name"]: r["CONCERT_RELEASE_TAG"] for r in release_records
    }
    release_by_tag = {r["CONCERT_RELEASE_TAG"]: r for r in release_records}
    profile_options = {
        r["profile_name"]: r["profile_id"] for r in concert_profile_records
    }
    runner_options = {r["runner_name"]: r["runner_id"] for r in concert_runner_records}
    image_source_options = {
        r["image_source_name"]: r["image_source_id"]
        for r in concert_image_source_records
    }
    hub_mode_options = {
        r["hub_mode_name"]: r["hub_mode_id"] for r in concert_hub_mode_records
    }
    preset_options = {r["preset_name"]: r["preset_id"] for r in concert_preset_records}
    preset_products = {r["preset_id"]: r["products"] for r in concert_preset_records}
    provider_options = {
        r["provider_name"]: r["provider_id"] for r in concert_datastore_provider_records
    }
    block_storage_options = dict(concert_block_storage_options)
    return (
        block_storage_options,
        hub_mode_options,
        image_source_options,
        login_argument_options,
        preset_options,
        preset_products,
        profile_options,
        provider_options,
        release_by_tag,
        release_options,
        runner_options,
    )


@app.cell
def _():
    widget_labels = {
        "login_arguments": "**Select how you want to login to the cluster:**",
        "release": "**IBM Concert release:**",
        "profile": "**Deployment profile:**",
        "preset": "**Product combination:**",
        "storage_block": "**Block storage class (RWO) for Concert and the data stores:**",
        "storage_block_custom": "**...or type a storage class name** *(overrides the dropdown)*:",
        "image_source": "**Where the cluster pulls images from:**",
        "runner": "**Where IBM's installer runs:**",
        "hub_mode": "**Hub:**",
        "products_table": "**Products to install** *(prefilled from the combination)*:",
        "datastores_table": "**Data stores - selected = external (provisioned or existing), unselected = IBM built-in:**",
        "accept_license": "I have read and accept the IBM Concert license terms (`license/` in the installer archive) - required",
        "istio": "Workflows: secure pod traffic with **Istio** (mTLS) - default, needs Service Mesh 3",
        "faas": "Workflows: enable **FaaS** *(not supported together with Istio; adds a cluster-wide insecure registry)*",
        "cross_product": "Install the **cross-product integration** (ITOM) with a local Hub",
        "cluster_url": "**Enter your openshift cluster url:**",
        "cluster_token": "**Enter your openshift token:**",
        "cluster_username": "**Enter your openshift cluster username:**",
        "cluster_password": "**Enter your openshift cluster password:**",
        "entitlement_key": "**IBM entitlement key** *(also needed to mirror images)*:",
        "admin_username": "**Initial Concert admin username (Keycloak):**",
        "admin_password": "**Initial Concert admin password** *(kept from the saved config, else generated)*:",
        "custom_hub_scale": "**Hub scale level:**",
        "custom_concert_scale": "**Concert scale level:**",
        "custom_workers": "**Worker nodes (minimum):**",
        "custom_worker_cpu": "**vCPU per worker:**",
        "custom_worker_mem": "**Memory per worker (Gi):**",
        "custom_pg_instances": "**PostgreSQL instances** *(1 = no HA)*:",
        "custom_pg_storage": "**PostgreSQL storage per instance (Gi):**",
    }
    return (widget_labels,)


@app.cell
def _(
    block_storage_class_custom_input,
    block_storage_class_select,
    hub_mode_select,
    image_source_select,
    login_argument_select,
    preset_select,
    profile_select,
    release_select,
    runner_select,
    widget_width,
):
    cluster_specs_stack = mo.vstack(
        [
            mo.hstack(
                [
                    login_argument_select.style({"width": widget_width}),
                    release_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    profile_select.style({"width": widget_width}),
                    preset_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    block_storage_class_select.style({"width": widget_width}),
                    block_storage_class_custom_input.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [
                    image_source_select.style({"width": widget_width}),
                    runner_select.style({"width": widget_width}),
                ],
                justify="space-around",
            ),
            mo.hstack(
                [hub_mode_select.style({"width": widget_width}), mo.md("")],
                justify="space-around",
            ),
        ]
    )
    cluster_specs_stack
    return


@app.cell
def _(
    custom_concert_scale_select,
    custom_hub_scale_select,
    custom_pg_instances_number,
    custom_pg_storage_number,
    custom_worker_cpu_number,
    custom_worker_mem_number,
    custom_workers_number,
    profile_select,
    sizing_estimate,
    widget_width,
):
    # Outside the accordions: the estimate changes with every edit, and a
    # re-rendered accordion would collapse.
    if profile_select.value == "custom":
        _panel = mo.vstack(
            [
                mo.md(
                    "#### Custom sizing\n"
                    "*Concert Data Apps always uses `level_1` (the only level IBM documents for it). "
                    "Everything else in the **Sizing** section below stays editable.*"
                ),
                mo.hstack(
                    [
                        custom_hub_scale_select.style({"width": widget_width}),
                        custom_concert_scale_select.style({"width": widget_width}),
                    ],
                    justify="space-around",
                ),
                mo.hstack(
                    [
                        custom_workers_number,
                        custom_worker_cpu_number,
                        custom_worker_mem_number,
                    ],
                    justify="space-around",
                ),
                mo.hstack(
                    [custom_pg_instances_number, custom_pg_storage_number],
                    justify="space-around",
                ),
                sizing_estimate,
            ],
            gap=1,
        )
    else:
        _panel = sizing_estimate
    mo.accordion(items={"*Sizing Setup Preview*": _panel})
    return


@app.cell
def _(
    accept_license_checkbox,
    admin_password_input,
    admin_username_input,
    cluster_password_input,
    cluster_token_input,
    cluster_url_input,
    cluster_username_input,
    entitlement_key_input,
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
                    entitlement_key_input,
                    admin_username_input,
                    admin_password_input,
                    accept_license_checkbox,
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
    cluster_credentials_stack,
    concert_namespaces_records,
    concert_sizing_records,
    cross_product_checkbox,
    datastore_consumer_table,
    datastore_provider_dict,
    faas_checkbox,
    istio_checkbox,
    product_table,
):
    install_specs_accordion = mo.accordion(
        items={
            "**Cluster Credentials, Entitlement & Admin**": cluster_credentials_stack,
            "**Products & Workflows Options**": mo.vstack(
                [
                    product_table,
                    istio_checkbox,
                    faas_checkbox,
                    cross_product_checkbox,
                ],
                gap=1,
            ),
            "**Data Stores** *(external by default - provisioned into the datastores namespace)*": mo.vstack(
                [
                    datastore_consumer_table,
                    mo.md("**Server per store type:**"),
                    datastore_provider_dict,
                ],
                gap=1,
            ),
            "**Sizing** *(prefilled from the profile)*": concert_sizing_records,
            "**Namespaces** *(IBM defaults)*": concert_namespaces_records,
        },
        multiple=True,
    )
    install_specs_accordion
    return


@app.cell
def _(
    concert_admin_records,
    concert_ai_records,
    concert_ds_other_records,
    concert_ds_postgres_records,
    concert_ds_s3_records,
    concert_hub_records,
    concert_images_records,
    concert_optimize_records,
    concert_release_records_kv,
    concert_runner_records_kv,
    concert_securecoder_records,
    concert_storage_records,
    concert_workflows_records,
):
    advanced_specs_accordion = mo.accordion(
        items={
            "*Remote Hub & Routes* ***(optional)***": concert_hub_records,
            "*Private Registry* ***(mirrored / airgap)***": concert_images_records,
            "*Runner & Release* ***(optional)***": mo.vstack(
                [concert_runner_records_kv, concert_release_records_kv], gap=1
            ),
            "*Per-product Storage Classes* ***(optional)***": concert_storage_records,
            "*Workflows, Istio & Service Mesh* ***(optional)***": concert_workflows_records,
            "*PostgreSQL* ***(existing server values / provisioning settings)***": concert_ds_postgres_records,
            "*S3 Object Storage* ***(existing server values / provisioning settings)***": concert_ds_s3_records,
            "*MySQL, Redis, Neo4j, RabbitMQ* ***(optional)***": concert_ds_other_records,
            "*AI (watsonx.ai / vLLM)* ***(optional)***": concert_ai_records,
            "*Secure Coder (Mend)* ***(optional)***": concert_securecoder_records,
            "*Optimize - Turbonomic* ***(when selected in Products)***": concert_optimize_records,
            "*Admin Password Rotation* ***(optional)***": concert_admin_records,
        },
        multiple=True,
    )
    advanced_specs_accordion
    return


@app.cell
def _(config_errors, config_warnings):
    _items = []
    if config_errors:
        _items.append(
            mo.callout(
                mo.md(
                    "**Fix before saving:**\n"
                    + "\n".join(f"- {e}" for e in config_errors)
                ),
                kind="danger",
            )
        )
    if config_warnings:
        _items.append(
            mo.callout(mo.md("\n".join(f"- {w}" for w in config_warnings)), kind="warn")
        )
    mo.vstack(_items) if _items else None
    return


@app.cell
def _(run_button):
    mo.hstack([run_button], justify="center", gap=20)
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
def _(default_concert_release_tag, release_options, widget_labels):
    release_select = mo.ui.dropdown(
        label=widget_labels.get("release"),
        options=release_options,
        value=next(
            (k for k, v in release_options.items() if v == default_concert_release_tag),
            list(release_options.keys())[0],
        ),
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (release_select,)


@app.cell
def _(default_concert_profile, profile_options, widget_labels):
    profile_select = mo.ui.dropdown(
        label=widget_labels.get("profile"),
        options=profile_options,
        value=next(
            k for k, v in profile_options.items() if v == default_concert_profile
        ),
        allow_select_none=False,
        full_width=True,
    )
    return (profile_select,)


@app.cell
def _(default_concert_preset, preset_options, widget_labels):
    preset_select = mo.ui.dropdown(
        label=widget_labels.get("preset"),
        options=preset_options,
        value=next(k for k, v in preset_options.items() if v == default_concert_preset),
        allow_select_none=False,
        full_width=True,
    )
    return (preset_select,)


@app.cell
def _(block_storage_options, widget_labels):
    block_storage_class_select = mo.ui.dropdown(
        label=widget_labels.get("storage_block"),
        options=block_storage_options,
        value=list(block_storage_options.keys())[0],
        allow_select_none=False,
        searchable=True,
        full_width=True,
    )
    return (block_storage_class_select,)


@app.cell
def _(widget_labels):
    block_storage_class_custom_input = mo.ui.text(
        label=widget_labels.get("storage_block_custom"),
        value="",
        full_width=True,
    )
    return (block_storage_class_custom_input,)


@app.cell
def _(image_source_options, widget_labels):
    image_source_select = mo.ui.dropdown(
        label=widget_labels.get("image_source"),
        options=image_source_options,
        value=list(image_source_options.keys())[0],
        allow_select_none=False,
        full_width=True,
    )
    return (image_source_select,)


@app.cell
def _(runner_options, widget_labels):
    runner_select = mo.ui.dropdown(
        label=widget_labels.get("runner"),
        options=runner_options,
        value=list(runner_options.keys())[0],
        allow_select_none=False,
        full_width=True,
    )
    return (runner_select,)


@app.cell
def _(hub_mode_options, widget_labels):
    hub_mode_select = mo.ui.dropdown(
        label=widget_labels.get("hub_mode"),
        options=hub_mode_options,
        value=list(hub_mode_options.keys())[0],
        allow_select_none=False,
        full_width=True,
    )
    return (hub_mode_select,)


@app.cell
def _(concert_product_records, preset_products, preset_select, widget_labels):
    # Recreated when the combination changes, so its products are reselected
    _selected = set(preset_products[preset_select.value])
    product_table = mo.ui.table(
        label=widget_labels.get("products_table"),
        data=concert_product_records,
        selection="multi",
        initial_selection=[
            i
            for i, r in enumerate(concert_product_records)
            if r["product_id"] in _selected
        ],
    )
    return (product_table,)


@app.cell
def _(concert_datastore_consumer_records, widget_labels):
    _rows = [
        {k: r[k] for k in ("consumer_id", "consumer", "server")}
        for r in concert_datastore_consumer_records
    ]
    datastore_consumer_table = mo.ui.table(
        label=widget_labels.get("datastores_table"),
        data=_rows,
        selection="multi",
        initial_selection=[
            i
            for i, r in enumerate(concert_datastore_consumer_records)
            if r["external_default"]
        ],
    )
    return (datastore_consumer_table,)


@app.cell
def _(concert_datastore_server_records, provider_options):
    _provision_label = next(k for k, v in provider_options.items() if v == "provision")
    _existing_label = next(k for k, v in provider_options.items() if v == "existing")
    datastore_provider_dict = mo.ui.dictionary(
        {
            r["server_id"]: mo.ui.dropdown(
                label=r["server_name"],
                options=provider_options
                if r["provisionable"]
                else {_existing_label: "existing"},
                value=_provision_label if r["provisionable"] else _existing_label,
                allow_select_none=False,
                full_width=True,
            )
            for r in concert_datastore_server_records
        }
    )
    return (datastore_provider_dict,)


@app.cell
def _(concert_profile_presets, concert_scale_level_requests, widget_labels):
    # Custom-profile widgets, prefilled from the production values
    _base = concert_profile_presets["custom"]

    def _level_options(component):
        return {
            f"{level} - up to ~{cpu:g} vCPU / {mem:g} Gi requests": level
            for level, (cpu, mem) in concert_scale_level_requests[component].items()
        }

    def _dropdown(label_key, component, current):
        options = _level_options(component)
        return mo.ui.dropdown(
            label=widget_labels.get(label_key),
            options=options,
            value=next(k for k, v in options.items() if v == current),
            allow_select_none=False,
            full_width=True,
        )

    custom_hub_scale_select = _dropdown(
        "custom_hub_scale", "hub", _base["CONCERT_SCALE_HUB"]
    )
    custom_concert_scale_select = _dropdown(
        "custom_concert_scale", "concert", _base["CONCERT_SCALE_CONCERT"]
    )
    custom_workers_number = mo.ui.number(
        start=1,
        stop=200,
        step=1,
        value=int(_base["CONCERT_MIN_WORKERS"]),
        label=widget_labels.get("custom_workers"),
    )
    custom_worker_cpu_number = mo.ui.number(
        start=2,
        stop=512,
        step=1,
        value=int(_base["CONCERT_MIN_WORKER_CPU"]),
        label=widget_labels.get("custom_worker_cpu"),
    )
    custom_worker_mem_number = mo.ui.number(
        start=4,
        stop=8192,
        step=1,
        value=int(_base["CONCERT_MIN_WORKER_MEM_GI"]),
        label=widget_labels.get("custom_worker_mem"),
    )
    custom_pg_instances_number = mo.ui.number(
        start=1,
        stop=9,
        step=1,
        value=int(_base["CONCERT_DS_PG_INSTANCES"]),
        label=widget_labels.get("custom_pg_instances"),
    )
    custom_pg_storage_number = mo.ui.number(
        start=20,
        stop=100000,
        step=10,
        value=int(quantity_gi(_base["CONCERT_DS_PG_STORAGE_SIZE"])),
        label=widget_labels.get("custom_pg_storage"),
    )
    return (
        custom_concert_scale_select,
        custom_hub_scale_select,
        custom_pg_instances_number,
        custom_pg_storage_number,
        custom_worker_cpu_number,
        custom_worker_mem_number,
        custom_workers_number,
    )


@app.cell
def _(widget_labels):
    accept_license_checkbox = mo.ui.checkbox(
        label=widget_labels.get("accept_license"), value=False
    )
    return (accept_license_checkbox,)


@app.cell
def _(widget_labels):
    istio_checkbox = mo.ui.checkbox(label=widget_labels.get("istio"), value=True)
    return (istio_checkbox,)


@app.cell
def _(widget_labels):
    faas_checkbox = mo.ui.checkbox(label=widget_labels.get("faas"), value=False)
    return (faas_checkbox,)


@app.cell
def _(widget_labels):
    cross_product_checkbox = mo.ui.checkbox(
        label=widget_labels.get("cross_product"), value=False
    )
    return (cross_product_checkbox,)


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
    entitlement_key_input = mo.ui.text(
        label=widget_labels.get("entitlement_key"),
        kind="password",
        full_width=False,
    )
    return (entitlement_key_input,)


@app.cell
def _(default_concert_admin, widget_labels):
    admin_username_input = mo.ui.text(
        label=widget_labels.get("admin_username"),
        value=records_to_dict(default_concert_admin).get("CONCERT_ADMIN_USERNAME"),
        full_width=False,
    )
    return (admin_username_input,)


@app.cell
def _(widget_labels):
    # Keep the saved password: IBM's installer receives it again on every 3.2 run
    admin_password_input = mo.ui.text(
        label=widget_labels.get("admin_password"),
        value=existing_config_value("CONCERT_ADMIN_PASSWORD") or generate_password(),
        kind="password",
        full_width=False,
    )
    return (admin_password_input,)


@app.cell
def _(
    concert_custom_sizing_keys,
    concert_profile_presets,
    default_concert_sizing,
    profile_select,
    sortable_kv,
    widget_controlled_keys,
):
    # Recreated whenever the profile changes, so the preset values are reapplied.
    # In the custom profile the custom panel owns its keys.
    _excluded = set(widget_controlled_keys)
    if profile_select.value == "custom":
        _excluded |= set(concert_custom_sizing_keys)
    concert_sizing_records = sortable_kv(
        label="Scale levels, worker minimums, data store sizes and resources:",
        value=without_keys(
            default_concert_sizing
            + dict_to_records(concert_profile_presets[profile_select.value]),
            _excluded,
        ),
        addable=False,
        removable=False,
        editable=True,
        movable=False,
    )
    return (concert_sizing_records,)


@app.cell
def _(
    default_concert_admin,
    default_concert_ai,
    default_concert_ds_other,
    default_concert_ds_postgres,
    default_concert_ds_s3,
    default_concert_hub,
    default_concert_images,
    default_concert_namespaces,
    default_concert_optimize,
    default_concert_release,
    default_concert_runner,
    default_concert_securecoder,
    default_concert_storage,
    default_concert_workflows,
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

    concert_namespaces_records = _kv(
        "Namespaces (RFC 1123, must not start with openshift- or kube-):",
        default_concert_namespaces,
    )
    concert_hub_records = _kv(
        "Remote Hub (Auto mode: URL = scheme://host:port without /platform-hub; key from "
        "`concert-hub/bin/access-key --namespace=<hub-ns> --generate` on the Hub cluster; "
        "OC login = an `oc login ...` command for the Hub cluster) and Hub route overrides:",
        default_concert_hub,
    )
    concert_images_records = _kv(
        "Private registry (CP4D names) - push creds for mirroring, pull creds for the cluster:",
        default_concert_images,
    )
    concert_runner_records_kv = _kv(
        "Runner (image source empty = automatic: in-cluster build for entitled, local build + push otherwise):",
        default_concert_runner,
    )
    concert_release_records_kv = _kv(
        "Release details (SHA-256 empty = recorded on first download):",
        default_concert_release,
    )
    concert_storage_records = _kv(
        "Per-product storage classes (default: the block class above):",
        default_concert_storage,
    )
    concert_workflows_records = _kv(
        "Workflows / Istio (Istio pin = IBM's tested version; channel = the Service Mesh 3 channel shared with CP4D):",
        default_concert_workflows,
    )
    concert_ds_postgres_records = _kv(
        "PostgreSQL (existing: host/port/admin user+password - the init Job creates the databases and pgvector):",
        default_concert_ds_postgres,
    )
    concert_ds_s3_records = _kv(
        "S3 (existing: host/port/keys/region; AWS: AUTH_TYPE=BYOS3):",
        default_concert_ds_s3,
    )
    concert_ds_other_records = _kv(
        "MySQL / Redis / Neo4j / RabbitMQ (existing-server values, provisioned images):",
        default_concert_ds_other,
    )
    concert_ai_records = _kv(
        "AI: watsonx.ai (on-prem: URL + user + password, SaaS: API key) or vLLM:",
        default_concert_ai,
    )
    concert_securecoder_records = _kv(
        "Secure Coder Mend integration (needs the watsonx SaaS values in the AI group):",
        default_concert_securecoder,
    )
    concert_admin_records = _kv(
        "Admin password rotation (4_post_install/4.0 changes the password to this value):",
        default_concert_admin,
    )
    # Keep a saved Turbonomic admin password: 5.3 logs in with it on every run
    concert_optimize_records = _kv(
        "Optimize / Turbonomic (version = IBM's matrix for Hub 3.0.3; license file from Passport Advantage, "
        "relative to configs/concert_config/; probes = extra Turbonomic probes, e.g. vcenter,aws,kubeturbo; "
        "SCC restricted|anyuid; empty route hostname / Hub URL = automatic):",
        [
            dict(
                r,
                value=existing_config_value(r["key"])
                or generate_turbonomic_password(),
            )
            if r["key"] == "CONCERT_OPTIMIZE_ADMIN_PASSWORD"
            else r
            for r in default_concert_optimize
        ],
    )
    return (
        concert_admin_records,
        concert_ai_records,
        concert_ds_other_records,
        concert_ds_postgres_records,
        concert_ds_s3_records,
        concert_hub_records,
        concert_images_records,
        concert_namespaces_records,
        concert_optimize_records,
        concert_release_records_kv,
        concert_runner_records_kv,
        concert_securecoder_records,
        concert_storage_records,
        concert_workflows_records,
    )


@app.cell
def _(
    accept_license_checkbox,
    admin_password_input,
    admin_username_input,
    block_storage_class_custom_input,
    block_storage_class_select,
    concert_admin_records,
    concert_ai_records,
    concert_dataapps_scale_level,
    concert_datastore_consumer_records,
    concert_ds_other_records,
    concert_ds_postgres_records,
    concert_ds_s3_records,
    concert_hub_records,
    concert_images_records,
    concert_namespaces_records,
    concert_optimize_records,
    concert_profile_presets,
    concert_release_records_kv,
    concert_runner_records_kv,
    concert_securecoder_records,
    concert_sizing_records,
    concert_storage_records,
    concert_workflows_records,
    cross_product_checkbox,
    custom_concert_scale_select,
    custom_hub_scale_select,
    custom_pg_instances_number,
    custom_pg_storage_number,
    custom_worker_cpu_number,
    custom_worker_mem_number,
    custom_workers_number,
    datastore_consumer_table,
    datastore_provider_dict,
    default_concert_admin,
    default_concert_ai,
    default_concert_ds_other,
    default_concert_ds_postgres,
    default_concert_ds_s3,
    default_concert_hub,
    default_concert_images,
    default_concert_namespaces,
    default_concert_optimize,
    default_concert_products,
    default_concert_release,
    default_concert_runner,
    default_concert_securecoder,
    default_concert_sizing,
    default_concert_storage,
    default_concert_workflows,
    faas_checkbox,
    hub_mode_select,
    image_source_select,
    istio_checkbox,
    preset_select,
    product_table,
    profile_select,
    release_by_tag,
    release_select,
    runner_select,
):
    _release = release_by_tag[release_select.value]
    concert_release = ordered_values(
        default_concert_release,
        concert_release_records_kv,
        {
            "CONCERT_VERSION": _release["CONCERT_VERSION"],
            "CONCERT_RELEASE_TAG": _release["CONCERT_RELEASE_TAG"],
            "CONCERT_ARCHIVE": _release["CONCERT_ARCHIVE"],
            "CONCERT_PROFILE": profile_select.value,
            "CONCERT_ACCEPT_LICENSE": bool_str(accept_license_checkbox.value),
        },
    )
    concert_runner = ordered_values(
        default_concert_runner,
        concert_runner_records_kv,
        {"CONCERT_RUNNER": runner_select.value},
    )
    concert_images = ordered_values(
        default_concert_images,
        concert_images_records,
        {"CONCERT_IMAGE_SOURCE": image_source_select.value},
    )
    _selected_products = {r["product_id"] for r in product_table.value}
    concert_products = ordered_values(
        default_concert_products,
        overrides={
            "CONCERT_PRESET": preset_select.value,
            **{
                r["key"]: bool_str(r["key"] in _selected_products)
                for r in default_concert_products
                if r["key"].startswith("CONCERT_INSTALL_")
            },
            "CONCERT_ENABLE_CROSS_PRODUCT_INTEGRATION": bool_str(
                cross_product_checkbox.value
            ),
        },
    )
    concert_hub = ordered_values(
        default_concert_hub,
        concert_hub_records,
        {"CONCERT_HUB_MODE": hub_mode_select.value},
    )
    concert_namespaces = ordered_values(
        default_concert_namespaces, concert_namespaces_records
    )
    # Data Apps is always level_1; the custom panel owns its keys in "custom"
    _sizing_overrides = {"CONCERT_SCALE_DATAAPPS": concert_dataapps_scale_level}
    if profile_select.value == "custom":
        _sizing_overrides.update(
            {
                "CONCERT_SCALE_HUB": custom_hub_scale_select.value,
                "CONCERT_SCALE_CONCERT": custom_concert_scale_select.value,
                "CONCERT_MIN_WORKERS": str(int(custom_workers_number.value)),
                "CONCERT_MIN_WORKER_CPU": str(int(custom_worker_cpu_number.value)),
                "CONCERT_MIN_WORKER_MEM_GI": str(int(custom_worker_mem_number.value)),
                "CONCERT_DS_PG_INSTANCES": str(int(custom_pg_instances_number.value)),
                "CONCERT_DS_PG_STORAGE_SIZE": f"{int(custom_pg_storage_number.value)}Gi",
            }
        )
    concert_sizing = ordered_values(
        default_concert_sizing
        + dict_to_records(concert_profile_presets[profile_select.value]),
        concert_sizing_records,
        _sizing_overrides,
    )
    concert_storage = ordered_values(
        default_concert_storage,
        concert_storage_records,
        {
            "CONCERT_STG_CLASS_BLOCK": block_storage_class_custom_input.value.strip()
            or block_storage_class_select.value
        },
    )
    concert_workflows = ordered_values(
        default_concert_workflows,
        concert_workflows_records,
        {
            "CONCERT_WORKFLOWS_ENABLE_ISTIO": bool_str(istio_checkbox.value),
            "CONCERT_WORKFLOWS_ENABLE_FAAS": bool_str(faas_checkbox.value),
        },
    )
    concert_ai = ordered_values(default_concert_ai, concert_ai_records)
    concert_securecoder = ordered_values(
        default_concert_securecoder, concert_securecoder_records
    )
    concert_admin = ordered_values(
        default_concert_admin,
        concert_admin_records,
        {
            "CONCERT_ADMIN_USERNAME": admin_username_input.value.strip(),
            "CONCERT_ADMIN_PASSWORD": admin_password_input.value,
        },
    )
    _external = {r["consumer_id"] for r in datastore_consumer_table.value}
    concert_ds_consumers = {
        f"CONCERT_DS_{r['consumer_id']}": "external"
        if r["consumer_id"] in _external or r["consumer_id"] == "CONCERT_NEO4J"
        else "internal"
        for r in concert_datastore_consumer_records
    }
    concert_ds_providers = {
        f"CONCERT_DS_{server}_PROVIDER": provider
        for server, provider in datastore_provider_dict.value.items()
    }
    concert_ds_postgres = ordered_values(
        default_concert_ds_postgres, concert_ds_postgres_records
    )
    concert_ds_s3 = ordered_values(default_concert_ds_s3, concert_ds_s3_records)
    concert_ds_other = ordered_values(
        default_concert_ds_other, concert_ds_other_records
    )
    concert_optimize = ordered_values(
        default_concert_optimize, concert_optimize_records
    )
    return (
        concert_admin,
        concert_ai,
        concert_ds_consumers,
        concert_ds_other,
        concert_ds_postgres,
        concert_ds_providers,
        concert_ds_s3,
        concert_hub,
        concert_images,
        concert_namespaces,
        concert_optimize,
        concert_products,
        concert_release,
        concert_runner,
        concert_securecoder,
        concert_sizing,
        concert_storage,
        concert_workflows,
    )


@app.cell
def _(
    concert_ds_consumers,
    concert_ds_providers,
    concert_fixed_requests,
    concert_hub,
    concert_optimize,
    concert_optimize_other_storage_gi,
    concert_products,
    concert_scale_level_optional_requests,
    concert_scale_level_requests,
    concert_sizing,
    concert_workflows,
):
    _p = {
        k: v == "true"
        for k, v in concert_products.items()
        if k.startswith("CONCERT_INSTALL_")
    }
    _remote_hub = bool(
        concert_hub["CONCERT_HUB_MODE"] == "auto"
        and concert_hub["CONCERT_REMOTE_HUB_URL"].strip()
        and concert_hub["CONCERT_REMOTE_HUB_ACCESS_KEY"].strip()
    )
    _rows, _notes = [], []

    def _ext(consumer):
        return concert_ds_consumers.get(f"CONCERT_DS_{consumer}") == "external"

    _part_names = {
        "embedded_db": "built-in DB",
        "minio": "built-in MinIO",
        "appdb_configdb": "built-in appdb/configdb",
        "veias": "VEIAS",
        "buddy": "buddy",
        "postgres": "built-in Postgres",
        "redis": "built-in Redis",
    }

    def _level(component, key, label, absent):
        # IBM's level totals minus the parts this configuration does not deploy
        level = concert_sizing.get(key, "")
        req = concert_scale_level_requests[component].get(level)
        if not req:
            _notes.append(
                f"{label} `{level}`: no request data for this level - not counted."
            )
            return
        cpu, mem = req
        for part in absent:
            part_cpu, part_mem = concert_scale_level_optional_requests[component][
                part
            ].get(level, (0, 0))
            cpu, mem = cpu - part_cpu, mem - part_mem
        _without = (
            f" (without {', '.join(_part_names[p] for p in absent)})" if absent else ""
        )
        _rows.append((f"{label} `{level}`{_without}", cpu, mem))

    if not _remote_hub:
        _level(
            "hub",
            "CONCERT_SCALE_HUB",
            "Hub",
            ["embedded_db"] if _ext("KEYCLOAK") else [],
        )
    if _p["CONCERT_INSTALL_CONCERT"]:
        _level(
            "concert",
            "CONCERT_SCALE_CONCERT",
            "Concert",
            (["minio"] if _ext("CONCERT_S3") else [])
            + (["appdb_configdb"] if _ext("CONCERT_DB") else [])
            + ([] if _p["CONCERT_INSTALL_VEIAS"] else ["veias"])
            + (
                []
                if concert_sizing.get("CONCERT_ENABLE_BUDDY", "true") == "true"
                else ["buddy"]
            ),
        )
    if _p["CONCERT_INSTALL_DATAAPPS"]:
        _level(
            "dataapps",
            "CONCERT_SCALE_DATAAPPS",
            "Data Apps",
            (["postgres"] if _ext("DATAAPPS_DB") else [])
            + (["redis"] if _ext("DATAAPPS_REDIS") else []),
        )
    if _p["CONCERT_INSTALL_WORKFLOWS"]:
        _rows.append(
            (
                "Workflows (no scale levels)",
                *concert_fixed_requests["workflows"],
            )
        )
        if concert_workflows["CONCERT_WORKFLOWS_ENABLE_ISTIO"] == "true":
            _rows.append(
                (
                    "Istio control plane + Workflows sidecars",
                    *concert_fixed_requests["istio"],
                )
            )
    if _p["CONCERT_INSTALL_OPTIMIZE"]:
        _rows.append(
            (
                "Optimize - Turbonomic (memory requests only)",
                *concert_fixed_requests["optimize"],
            )
        )
        _db_gi = quantity_gi(concert_optimize.get("CONCERT_OPTIMIZE_DB_STORAGE_SIZE"))
        _notes.append(
            "Turbonomic requests almost no CPU, but IBM's minimum for it is 4 vCPU / 32 GB - leave that headroom. "
            f"Its volumes: database {_db_gi:g} Gi + ~{concert_optimize_other_storage_gi} Gi (Kafka, rsyslog, Prometheus, ...)."
        )

    # Provisioned data stores (existing servers live elsewhere)
    _active = {
        "KEYCLOAK": not _remote_hub,
        "CONCERT_DB": _p["CONCERT_INSTALL_CONCERT"],
        "CONCERT_S3": _p["CONCERT_INSTALL_CONCERT"],
        "CONCERT_NEO4J": _p["CONCERT_INSTALL_CONCERT"] and _p["CONCERT_INSTALL_VEIAS"],
        "DATAAPPS_DB": _p["CONCERT_INSTALL_DATAAPPS"],
        "DATAAPPS_REDIS": _p["CONCERT_INSTALL_DATAAPPS"],
        "WORKFLOWS_MYSQL": _p["CONCERT_INSTALL_WORKFLOWS"],
        "WORKFLOWS_POSTGRES": _p["CONCERT_INSTALL_WORKFLOWS"],
        "WORKFLOWS_S3": _p["CONCERT_INSTALL_WORKFLOWS"],
    }
    _server_of = {
        "KEYCLOAK": "POSTGRES",
        "CONCERT_DB": "POSTGRES",
        "DATAAPPS_DB": "POSTGRES",
        "WORKFLOWS_POSTGRES": "POSTGRES",
        "CONCERT_S3": "S3",
        "WORKFLOWS_S3": "S3",
        "CONCERT_NEO4J": "NEO4J",
        "DATAAPPS_REDIS": "REDIS",
        "WORKFLOWS_MYSQL": "MYSQL",
    }
    _provisioned = {
        _server_of[c]
        for c, on in _active.items()
        if on
        and concert_ds_consumers.get(f"CONCERT_DS_{c}") == "external"
        and concert_ds_providers.get(f"CONCERT_DS_{_server_of[c]}_PROVIDER")
        == "provision"
    }
    _pg_cpu = quantity_cpu(concert_sizing.get("CONCERT_DS_PG_CPU_REQUEST"))
    _pg_mem = quantity_gi(concert_sizing.get("CONCERT_DS_PG_MEM_REQUEST"))
    _pg_n = int(concert_sizing.get("CONCERT_DS_PG_INSTANCES") or 1)
    if "POSTGRES" in _provisioned:
        _rows.append(
            (
                f"PostgreSQL ({_pg_n} x {_pg_cpu:g} vCPU / {_pg_mem:g} Gi)",
                _pg_n * _pg_cpu,
                _pg_n * _pg_mem,
            )
        )
    if "MYSQL" in _provisioned:
        _rows.append(
            (
                "MySQL",
                quantity_cpu(concert_sizing.get("CONCERT_DS_MYSQL_CPU_REQUEST")),
                quantity_gi(concert_sizing.get("CONCERT_DS_MYSQL_MEM_REQUEST")),
            )
        )
    if "REDIS" in _provisioned:
        _rows.append(("Redis", 0.1, 0.25))
    if "NEO4J" in _provisioned:
        _rows.append(("Neo4j", 0.5, 2.0))
    if "S3" in _provisioned:
        _rows.append(
            (
                "Multicloud Object Gateway (only if not already on the cluster)",
                2.5,
                10.0,
            )
        )
    _rows.append(
        (
            "Installer runner Job (while it runs)",
            *concert_fixed_requests["runner"],
        )
    )

    _workers = int(concert_sizing.get("CONCERT_MIN_WORKERS") or 0)
    _node_cpu = float(concert_sizing.get("CONCERT_MIN_WORKER_CPU") or 0) * 0.9
    _node_mem = float(concert_sizing.get("CONCERT_MIN_WORKER_MEM_GI") or 0) * 0.9
    _cap_cpu, _cap_mem = _workers * _node_cpu, _workers * _node_mem
    _tot_cpu = sum(r[1] for r in _rows)
    _tot_mem = sum(r[2] for r in _rows)
    _cpu_pct = 100 * _tot_cpu / _cap_cpu if _cap_cpu else 999
    _mem_pct = 100 * _tot_mem / _cap_mem if _cap_mem else 999
    _n1_ok = (
        _workers > 1
        and _tot_cpu <= (_workers - 1) * _node_cpu
        and _tot_mem <= (_workers - 1) * _node_mem
    )
    _pg_fits = "POSTGRES" not in _provisioned or (
        _pg_cpu <= _node_cpu and _pg_mem <= _node_mem
    )

    _table = "\n".join(
        f"| {name} | {cpu:.1f} | {mem:.1f} |" for name, cpu, mem in _rows
    )
    _text = (
        "**Estimated resource requests vs worker capacity**\n\n"
        "| Component | vCPU | Memory Gi |\n|---|---:|---:|\n"
        f"{_table}\n| **Total requests** | **{_tot_cpu:.1f}** | **{_tot_mem:.1f}** |\n"
        f"| Workers: {_workers} x {concert_sizing.get('CONCERT_MIN_WORKER_CPU')} vCPU / "
        f"{concert_sizing.get('CONCERT_MIN_WORKER_MEM_GI')} Gi (90% allocatable) | {_cap_cpu:.1f} | {_cap_mem:.1f} |\n\n"
        f"Requests use **{_cpu_pct:.0f}% CPU** and **{_mem_pct:.0f}% memory**. "
        + (
            "The cluster can lose one worker and still fit them. "
            if _n1_ok
            else "Losing one worker would not leave room for them. "
        )
        + (
            ""
            if _pg_fits
            else "A single PostgreSQL instance does not fit on one worker. "
        )
        + "\n\n*Requests only (limits, upgrade surges and other workloads need headroom). Hub/Concert/Data Apps "
        "from IBM's level_*.cfg files; IBM's hardware table (production 3 x 16 vCPU / 32 Gi) is the supported minimum.*"
        + ("\n\n" + "\n".join(f"- {n}" for n in _notes) if _notes else "")
    )
    _worst = max(_cpu_pct, _mem_pct)
    _kind = (
        "success"
        if _worst <= 70 and _pg_fits
        else ("warn" if _worst <= 100 and _pg_fits else "danger")
    )
    sizing_estimate = mo.callout(mo.md(_text), kind=_kind)
    sizing_utilization = {
        "cpu_pct": _cpu_pct,
        "mem_pct": _mem_pct,
        "pg_fits": _pg_fits,
        "survives_node_loss": _n1_ok,
    }
    return sizing_estimate, sizing_utilization


@app.cell
def _(
    cluster_password_input,
    cluster_token_input,
    cluster_url_input,
    concert_admin,
    concert_ai,
    concert_ds_consumers,
    concert_ds_other,
    concert_ds_postgres,
    concert_ds_providers,
    concert_ds_s3,
    concert_hub,
    concert_images,
    concert_namespaces,
    concert_optimize,
    concert_products,
    concert_release,
    concert_runner,
    concert_securecoder,
    concert_workflows,
    entitlement_key_input,
    login_argument_select,
    sizing_utilization,
):
    import re

    from src.helpers.version_catalog import catalog_value as _catalog_value

    _errors, _warnings = [], []
    _p = {
        k: v == "true"
        for k, v in concert_products.items()
        if k.startswith("CONCERT_INSTALL_")
    }
    _concert, _dataapps, _workflows = (
        _p["CONCERT_INSTALL_CONCERT"],
        _p["CONCERT_INSTALL_DATAAPPS"],
        _p["CONCERT_INSTALL_WORKFLOWS"],
    )
    _hub_url = concert_hub["CONCERT_REMOTE_HUB_URL"].strip()
    _hub_key = concert_hub["CONCERT_REMOTE_HUB_ACCESS_KEY"].strip()
    _remote_hub = concert_hub["CONCERT_HUB_MODE"] == "auto" and _hub_url and _hub_key

    if concert_release["CONCERT_ACCEPT_LICENSE"] != "true":
        _errors.append(
            "Accept the IBM Concert license terms (checkbox in *Cluster Credentials*)."
        )
    if not cluster_url_input.value:
        _errors.append("Enter the OpenShift API URL.")
    if login_argument_select.selected_key == "Token" and not cluster_token_input.value:
        _errors.append("Enter an OpenShift token (or switch to username/password).")
    if (
        login_argument_select.selected_key == "Username/Password"
        and not cluster_password_input.value
    ):
        _errors.append("Enter the OpenShift password.")

    _admin_user = concert_admin["CONCERT_ADMIN_USERNAME"]
    _admin_pw = concert_admin["CONCERT_ADMIN_PASSWORD"]
    if not _admin_user or not _admin_pw:
        _errors.append("Set the initial Concert admin username and password.")
    elif (_admin_user, _admin_pw) == (
        "ibmconcert",
        "password",
    ) or _admin_pw == "password":
        _errors.append("Do not use IBM's default admin password 'password'.")
    elif len(_admin_pw) < 12:
        _warnings.append("The admin password is shorter than 12 characters.")

    # Products and hub
    _optimize = _p["CONCERT_INSTALL_OPTIMIZE"]
    if not (_concert or _dataapps or _workflows or _optimize) and _remote_hub:
        _errors.append("Nothing to install: no product selected and the Hub is remote.")
    if _p["CONCERT_INSTALL_SECURECODER"] and not _concert:
        _errors.append("Secure Coder requires Concert.")
    if _p["CONCERT_INSTALL_VEIAS"] and not _concert:
        _errors.append("VEIAS requires Concert.")
    if concert_hub["CONCERT_HUB_MODE"] == "auto" and bool(_hub_url) != bool(_hub_key):
        _errors.append(
            "Remote Hub needs both CONCERT_REMOTE_HUB_URL and CONCERT_REMOTE_HUB_ACCESS_KEY (or neither)."
        )
    if _hub_url and not re.fullmatch(r"https://[^/\s]+(:\d+)?/?", _hub_url):
        _errors.append(
            "CONCERT_REMOTE_HUB_URL must be https://host[:port] without a path (no /platform-hub)."
        )
    if (
        _remote_hub
        and concert_products["CONCERT_ENABLE_CROSS_PRODUCT_INTEGRATION"] == "true"
    ):
        _errors.append("Cross-product integration needs a local Hub.")
    if concert_hub["CONCERT_HUB_MODE"] == "local" and (_hub_url or _hub_key):
        _warnings.append(
            "Hub mode is 'local only' - the remote Hub values are ignored."
        )

    # Workflows
    if _workflows:
        if (
            concert_workflows["CONCERT_WORKFLOWS_ENABLE_ISTIO"] == "true"
            and concert_workflows["CONCERT_WORKFLOWS_ENABLE_FAAS"] == "true"
        ):
            _errors.append(
                "Workflows: Istio and FaaS cannot be enabled together (IBM limitation)."
            )
        if concert_workflows["CONCERT_WORKFLOWS_ENABLE_FAAS"] == "true":
            _warnings.append(
                "FaaS adds the Workflows route to image.config insecureRegistries - every node gets the change (MachineConfigPool rollout)."
            )

    # Optimize (Turbonomic)
    if _optimize:
        _o = concert_optimize
        if concert_images["CONCERT_IMAGE_SOURCE"] != "entitled":
            _errors.append(
                "Optimize pulls Turbonomic from icr.io/cpopen - mirrored/air-gapped Turbonomic is not supported by these scripts yet."
            )
        if not re.fullmatch(r"\d+\.\d+\.\d+", _o["CONCERT_OPTIMIZE_VERSION"]):
            _errors.append(
                "CONCERT_OPTIMIZE_VERSION must be a Turbonomic release such as 8.21.2 (a t8c-operator tag)."
            )
        elif _o["CONCERT_OPTIMIZE_VERSION"] != (
            _matrix_turbo := _catalog_value("concert/optimize_version")
        ):
            _warnings.append(
                f"Optimize {_o['CONCERT_OPTIMIZE_VERSION']}: IBM's version matrix pairs Hub 3.0.3 (Concert 3.1.0) with Turbonomic {_matrix_turbo}."
            )
        _turbo_user = _o["CONCERT_OPTIMIZE_ADMIN_USERNAME"]
        _turbo_pw = _o["CONCERT_OPTIMIZE_ADMIN_PASSWORD"]
        if not _turbo_user or not _turbo_pw:
            _errors.append(
                "Optimize needs CONCERT_OPTIMIZE_ADMIN_USERNAME and CONCERT_OPTIMIZE_ADMIN_PASSWORD (Turbonomic's local administrator)."
            )
        elif len(_turbo_pw) < 12:
            _warnings.append("The Turbonomic admin password is shorter than 12 characters.")
        if _o["CONCERT_OPTIMIZE_SCC"] not in ("restricted", "anyuid"):
            _errors.append("CONCERT_OPTIMIZE_SCC must be restricted or anyuid.")
        if _o["CONCERT_OPTIMIZE_ROUTE_TERMINATION"] not in ("reencrypt", "passthrough"):
            _errors.append("CONCERT_OPTIMIZE_ROUTE_TERMINATION must be reencrypt or passthrough.")
        if quantity_gi(_o["CONCERT_OPTIMIZE_DB_STORAGE_SIZE"]) <= 0:
            _errors.append(
                "CONCERT_OPTIMIZE_DB_STORAGE_SIZE must be a size such as 100Gi."
            )
        if _o["CONCERT_OPTIMIZE_PROBES"] and not re.fullmatch(
            r"[a-z0-9-]+(,[a-z0-9-]+)*", _o["CONCERT_OPTIMIZE_PROBES"].replace(" ", "")
        ):
            _errors.append(
                "CONCERT_OPTIMIZE_PROBES is a comma-separated list of Turbonomic chart keys (e.g. vcenter,aws,kubeturbo)."
            )
        if _o["CONCERT_OPTIMIZE_ROUTE_HOSTNAME"] and not re.fullmatch(
            r"[a-z0-9]([-a-z0-9.]*[a-z0-9])?", _o["CONCERT_OPTIMIZE_ROUTE_HOSTNAME"]
        ):
            _errors.append("CONCERT_OPTIMIZE_ROUTE_HOSTNAME is not a valid host name.")
        if _o["CONCERT_OPTIMIZE_HUB_URL"] and not _o[
            "CONCERT_OPTIMIZE_HUB_URL"
        ].startswith("https://"):
            _errors.append("CONCERT_OPTIMIZE_HUB_URL must start with https://.")
        _license = _o["CONCERT_OPTIMIZE_LICENSE_FILE"]
        if not _license:
            _warnings.append(
                "Optimize: no Turbonomic license file - add it later with 5_install_optimize/5.3 --license=<file> (Passport Advantage license keys)."
            )
        else:
            _license_path = os.path.expanduser(_license)
            if not os.path.isabs(_license_path):
                _license_path = os.path.join(
                    os.path.dirname(__file__), "configs", "concert_config", _license_path
                )
            if not os.path.isfile(_license_path):
                _warnings.append(
                    f"Optimize: license file {_license_path} not found on this workstation."
                )
        if _remote_hub and not concert_hub["CONCERT_REMOTE_HUB_OC_LOGIN"].strip():
            _warnings.append(
                "Optimize with a remote Hub: attaching it (5.5) needs CONCERT_REMOTE_HUB_OC_LOGIN for the Hub cluster."
            )
        _warnings.append(
            f"Optimize: CONCERT_OPTIMIZE_OAUTH2_AUDIENCE='{_o['CONCERT_OPTIMIZE_OAUTH2_AUDIENCE']}' - IBM's t8c-operator samples use CONCERT, "
            "IBM's Optimize docs page the Hub URL; unverified which one the Hub expects."
        )

    # Images and runner
    _source = concert_images["CONCERT_IMAGE_SOURCE"]
    if _source == "entitled" and not entitlement_key_input.value:
        _errors.append("Enter the IBM entitlement key.")
    if _source in ("mirrored", "airgap"):
        for _k in (
            "PRIVATE_REGISTRY_LOCATION",
            "PRIVATE_REGISTRY_PULL_USER",
            "PRIVATE_REGISTRY_PULL_PASSWORD",
            "PRIVATE_REGISTRY_PUSH_USER",
            "PRIVATE_REGISTRY_PUSH_PASSWORD",
        ):
            if not concert_images[_k]:
                _errors.append(f"{_source} mode needs {_k} (Private Registry group).")
        if not entitlement_key_input.value:
            _warnings.append(
                "Mirroring from IBM needs the entitlement key on the connected side."
            )
    if (
        concert_runner["CONCERT_RUNNER_IMAGE_SOURCE"] == "prebuilt"
        and not concert_runner["CONCERT_RUNNER_IMAGE"]
    ):
        _errors.append(
            "CONCERT_RUNNER_IMAGE_SOURCE=prebuilt needs CONCERT_RUNNER_IMAGE."
        )
    if concert_runner["CONCERT_RUNNER"] == "native":
        _warnings.append(
            "Native runner: run the scripts on a Linux x86_64 host (IBM's installer reads the local architecture)."
        )

    # Namespaces
    for _k, _ns in concert_namespaces.items():
        if not re.fullmatch(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?", _ns or ""):
            _errors.append(f"{_k}='{_ns}' is not a valid namespace name.")
        elif _ns.startswith(("openshift-", "kube-")):
            _errors.append(f"{_k}='{_ns}' must not start with openshift- or kube-.")
    if len(set(concert_namespaces.values())) != len(concert_namespaces):
        _errors.append("Every namespace must be different.")

    # Sizing (Data Apps is forced to level_1 in the merge)
    if sizing_utilization["cpu_pct"] > 100 or sizing_utilization["mem_pct"] > 100:
        _warnings.append(
            f"Estimated requests exceed the worker minimums ({sizing_utilization['cpu_pct']:.0f}% CPU, "
            f"{sizing_utilization['mem_pct']:.0f}% memory) - add workers or lower the scale levels (see the estimate)."
        )
    if not sizing_utilization["pg_fits"]:
        _warnings.append(
            "A PostgreSQL instance requests more than one worker can offer - lower CONCERT_DS_PG_*_REQUEST or use bigger workers."
        )
    if (
        concert_release["CONCERT_PROFILE"] != "small"
        and not sizing_utilization["survives_node_loss"]
    ):
        _warnings.append(
            "The workers cannot absorb the loss of one node - not HA at this size."
        )

    # Data stores
    _active = {
        "KEYCLOAK": not _remote_hub,
        "CONCERT_DB": _concert,
        "CONCERT_S3": _concert,
        "CONCERT_NEO4J": _concert and _p["CONCERT_INSTALL_VEIAS"],
        "DATAAPPS_DB": _dataapps,
        "DATAAPPS_REDIS": _dataapps,
        "WORKFLOWS_MYSQL": _workflows,
        "WORKFLOWS_POSTGRES": _workflows,
        "WORKFLOWS_S3": _workflows,
        "WORKFLOWS_RABBITMQ": _workflows,
    }
    _server_of = {
        "KEYCLOAK": "POSTGRES",
        "CONCERT_DB": "POSTGRES",
        "DATAAPPS_DB": "POSTGRES",
        "WORKFLOWS_POSTGRES": "POSTGRES",
        "CONCERT_S3": "S3",
        "WORKFLOWS_S3": "S3",
        "CONCERT_NEO4J": "NEO4J",
        "DATAAPPS_REDIS": "REDIS",
        "WORKFLOWS_MYSQL": "MYSQL",
        "WORKFLOWS_RABBITMQ": "RABBITMQ",
    }
    _needed = {
        _server_of[c]
        for c, on in _active.items()
        if on and concert_ds_consumers[f"CONCERT_DS_{c}"] == "external"
    }
    _existing_fields = {
        "POSTGRES": (
            concert_ds_postgres,
            [
                "CONCERT_DS_PG_HOST",
                "CONCERT_DS_PG_ADMIN_USER",
                "CONCERT_DS_PG_ADMIN_PASSWORD",
            ],
        ),
        "S3": (
            concert_ds_s3,
            [
                "CONCERT_DS_S3_HOST",
                "CONCERT_DS_S3_ACCESS_KEY",
                "CONCERT_DS_S3_SECRET_KEY",
            ],
        ),
        "MYSQL": (
            concert_ds_other,
            [
                "CONCERT_DS_MYSQL_HOST",
                "CONCERT_DS_MYSQL_USER",
                "CONCERT_DS_MYSQL_PASSWORD",
            ],
        ),
        "REDIS": (
            concert_ds_other,
            ["CONCERT_DS_REDIS_HOST", "CONCERT_DS_REDIS_USER"],
        ),
        "NEO4J": (
            concert_ds_other,
            [
                "CONCERT_DS_NEO4J_HOST",
                "CONCERT_DS_NEO4J_USERNAME",
                "CONCERT_DS_NEO4J_PASSWORD",
            ],
        ),
        "RABBITMQ": (
            concert_ds_other,
            [
                "CONCERT_DS_RABBITMQ_HOST",
                "CONCERT_DS_RABBITMQ_USER",
                "CONCERT_DS_RABBITMQ_PASSWORD",
            ],
        ),
    }
    for _server in sorted(_needed):
        if concert_ds_providers.get(f"CONCERT_DS_{_server}_PROVIDER") == "existing":
            _group, _fields = _existing_fields[_server]
            _missing = [f for f in _fields if not _group.get(f)]
            if _missing:
                _errors.append(
                    f"{_server} is set to an existing server but {', '.join(_missing)} is empty."
                )
    _internal = [
        c
        for c, on in _active.items()
        if on
        and concert_ds_consumers[f"CONCERT_DS_{c}"] == "internal"
        and c != "WORKFLOWS_RABBITMQ"
    ]
    if _internal and concert_release["CONCERT_PROFILE"] != "small":
        _warnings.append(
            f"{concert_release['CONCERT_PROFILE'].capitalize()} profile with IBM built-in stores for: "
            + ", ".join(_internal)
            + ". IBM's built-in stores are dev/test grade and cannot be switched to external after installing."
        )
    if (
        "S3" in _needed
        and _workflows
        and concert_ds_consumers["CONCERT_DS_WORKFLOWS_S3"] == "external"
    ):
        _warnings.append(
            f"Workflows external S3 uses CW_AUTH_TYPE='{concert_ds_s3['CONCERT_DS_S3_CW_AUTH_TYPE']}', a value IBM does not document (plan spike S7)."
        )
    if (
        "POSTGRES" in _needed
        and concert_ds_providers.get("CONCERT_DS_POSTGRES_PROVIDER") == "provision"
    ):
        _warnings.append(
            "PostgreSQL is provisioned with the community CloudNativePG operator"
        )
    if (
        "S3" in _needed
        and concert_ds_providers.get("CONCERT_DS_S3_PROVIDER") == "provision"
    ):
        _warnings.append(
            "S3 uses ODF Multicloud Object Gateway: reused when ODF/Fusion is present, otherwise standalone MCG is installed (needs an ODF entitlement)."
        )

    # AI / Secure Coder
    if concert_ai["CONCERT_ENABLE_AI"] == "true":
        if concert_ai["CONCERT_LLM_PROVIDER"] == "watsonx" and not (
            concert_ai["CONCERT_WATSONX_API_URL"]
            and concert_ai["CONCERT_WATSONX_API_PROJECT_ID"]
        ):
            _errors.append(
                "AI with watsonx needs CONCERT_WATSONX_API_URL and CONCERT_WATSONX_API_PROJECT_ID."
            )
        if concert_ai["CONCERT_LLM_PROVIDER"] == "vllm" and not (
            concert_ai["CONCERT_LLM_MODEL"]
            and concert_ai["CONCERT_EMBED_MODEL"]
            and concert_ai["CONCERT_LLM_BASE_URL"]
        ):
            _errors.append(
                "AI with vLLM needs CONCERT_LLM_MODEL, CONCERT_EMBED_MODEL and CONCERT_LLM_BASE_URL."
            )
    if (
        _p["CONCERT_INSTALL_SECURECODER"]
        and concert_securecoder["CONCERT_SECURECODER_MEND_ENABLED"].upper() == "TRUE"
    ):
        for _k in (
            "CONCERT_SECURECODER_MEND_ORG_NAME",
            "CONCERT_SECURECODER_MEND_SERVICE_URL",
            "CONCERT_SECURECODER_MEND_EMAIL_ADDRESS",
            "CONCERT_SECURECODER_MEND_PROJECT_NAME",
            "CONCERT_SECURECODER_MEND_USER_KEY",
            "CONCERT_SECURECODER_MEND_API_KEY",
        ):
            if not concert_securecoder[_k]:
                _errors.append(f"Secure Coder Mend needs {_k}.")
        if not (
            concert_ai["CONCERT_WATSONX_API_KEY"]
            and concert_ai["CONCERT_WATSONX_API_URL"]
            and concert_ai["CONCERT_WATSONX_API_PROJECT_ID"]
        ):
            _errors.append(
                "Secure Coder Mend needs the watsonx SaaS API key, URL and project ID (AI group)."
            )

    config_errors, config_warnings = _errors, _warnings
    return config_errors, config_warnings


@app.cell
def _():
    run_button = mo.ui.run_button(label="**Generate Variable File**")
    return (run_button,)


@app.cell
def _():
    save_to_config_dir_button = mo.ui.run_button(
        label="**Save directly to ./configs/concert_config/**",
        kind="neutral",
    )
    return (save_to_config_dir_button,)


@app.cell
def _(
    cluster_password_input,
    cluster_token_input,
    cluster_url_input,
    cluster_username_input,
    concert_admin,
    concert_ai,
    concert_ds_consumers,
    concert_ds_other,
    concert_ds_postgres,
    concert_ds_providers,
    concert_ds_s3,
    concert_hub,
    concert_images,
    concert_namespaces,
    concert_optimize,
    concert_products,
    concert_release,
    concert_runner,
    concert_securecoder,
    concert_sizing,
    concert_storage,
    concert_workflows,
    entitlement_key_input,
    login_argument_select,
    render_template_from_environment,
    run_button,
    save_to_config_dir_button,
):
    rendered_variables_file_concert = (
        render_template_from_environment(
            template_path=os.path.join(
                os.path.dirname(__file__),
                "src/helpers/config_file_jinja2_templates/concert_variable_template.sh.j2",
            ),
            extra_vars={
                "cluster_url_input": cluster_url_input,
                "cluster_username_input": cluster_username_input,
                "cluster_password_input": cluster_password_input,
                "cluster_token_input": cluster_token_input,
                "login_argument_select": login_argument_select,
                "ibm_entitlement_key_input": entitlement_key_input,
                "concert_release": concert_release,
                "concert_runner": concert_runner,
                "concert_images": concert_images,
                "concert_products": concert_products,
                "concert_hub": concert_hub,
                "concert_namespaces": concert_namespaces,
                "concert_sizing": concert_sizing,
                "concert_storage": concert_storage,
                "concert_workflows": concert_workflows,
                "concert_ai": concert_ai,
                "concert_securecoder": concert_securecoder,
                "concert_admin": concert_admin,
                "concert_optimize": concert_optimize,
                "concert_ds_consumers": concert_ds_consumers,
                "concert_ds_providers": concert_ds_providers,
                "concert_ds_postgres": concert_ds_postgres,
                "concert_ds_s3": concert_ds_s3,
                "concert_ds_other": concert_ds_other,
            },
        )
        if run_button.value or save_to_config_dir_button.value
        else ""
    )
    return (rendered_variables_file_concert,)


@app.cell
def _(rendered_variables_file_concert):
    concert_vars_template_editor = mo.ui.code_editor(
        label="> **Edit your concert_vars.sh file.** \n",
        value=rendered_variables_file_concert,
        language="bash",
        show_copy_button=True,
        theme="dark",
        max_height=1000,
        disabled=(not rendered_variables_file_concert),
    )
    return (concert_vars_template_editor,)


@app.cell
def _():
    name_variable_file_concert = mo.ui.text(
        label="**Name your variable file:**",
        value="concert_vars",
        max_length=256,
    )
    return (name_variable_file_concert,)


@app.cell
def _(name_variable_file_concert):
    concert_vars_filename = (
        f"{name_variable_file_concert.value}.sh"
        if name_variable_file_concert.value
        else f"concert_vars_{uuid.uuid4().hex[:4]}.sh"
    )
    return (concert_vars_filename,)


@app.cell
def _(concert_vars_filename, concert_vars_template_editor):
    save_config_concert = mo.download(
        data=concert_vars_template_editor.value.encode("utf-8"),
        filename=concert_vars_filename,
        mimetype="application/x-sh",
        label="**Save your concert_vars.sh file**",
    )
    return (save_config_concert,)


@app.cell
def _(
    name_variable_file_concert,
    save_config_concert,
    save_to_config_dir_button,
):
    save_file_stack = mo.hstack(
        [
            name_variable_file_concert,
            save_config_concert,
            save_to_config_dir_button,
        ],
        justify="space-around",
        align="center",
        gap=15,
    )
    return (save_file_stack,)


@app.cell
def _(concert_vars_template_editor, save_file_stack):
    config_file_accordion_concert = mo.accordion(
        items={
            "**Review & Save Results**": mo.vstack(
                [
                    mo.md(
                        "*The install scripts read `configs/concert_config/concert_vars.sh` (with `ENV_TARGET=concert`) - keep that name.*"
                    ),
                    concert_vars_template_editor,
                    save_file_stack,
                ]
            )
        }
    )
    config_file_accordion_concert
    return


@app.cell
def _(
    concert_vars_filename,
    concert_vars_template_editor,
    config_errors,
    save_to_config_dir_button,
):
    _save_result = None
    if save_to_config_dir_button.value and config_errors:
        _save_result = mo.callout(
            mo.md("**Not saved** - fix the errors listed above first."),
            kind="danger",
        )
    elif save_to_config_dir_button.value and concert_vars_template_editor.value:
        _config_dir = os.path.join(
            os.path.dirname(__file__), "configs", "concert_config"
        )
        os.makedirs(_config_dir, exist_ok=True)

        _vars_path = os.path.join(_config_dir, concert_vars_filename)
        _saved = []
        # Keep the previous file: it holds credentials and may describe a live install
        if os.path.exists(_vars_path):
            shutil.copy2(_vars_path, f"{_vars_path}.bak")
            os.chmod(f"{_vars_path}.bak", 0o600)
            _saved.append(f"{_vars_path}.bak (previous version)")

        with open(_vars_path, "w") as _f:
            _f.write(concert_vars_template_editor.value)
        os.chmod(_vars_path, 0o600)
        _saved.insert(0, _vars_path)

        _save_result = mo.callout(
            mo.md(
                "**Saved to `./configs/concert_config/`:**\n"
                + "\n".join(f"- `{p}`" for p in _saved)
                + "\n\nNext: `./scripts/install_ibm_concert/0_x_full_quick_install_script/full_concert_installprocess.sh`"
            ),
            kind="success",
        )

    _save_result
    return


if __name__ == "__main__":
    app.run()
