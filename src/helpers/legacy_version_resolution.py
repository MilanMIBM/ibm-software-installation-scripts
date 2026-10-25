"""legacy_version_resolution.py - the version / channel / image logic as it was
before the dynamic resolvers (cpd_release_meta.py, version_catalog.json, the
PackageManifest channel lookup, image_tags.py).

Kept as the fallback: every resolver tries its new source first and uses this
only when that fails or returns nothing, so an install that worked before still
works when, say, the catalog file is missing or a CASE is not downloaded. Do not
edit these values to change a default; edit version_catalog.json instead.
The zsh side of the legacy logic is legacy_version_resolution.sh.
"""

# The literals the scripts, notebooks and mirror hooks carried, by catalog path
# (version_catalog.json) or channel.<OLM package>.
LEGACY_PINS = {
    # catalog paths
    "cpd/rhoai_channel_by_release/5.3.0": "stable-2.25",
    "cpd/rhoai_channel_by_release/5.3.1": "stable-2.25",
    "cpd/rhoai_channel_by_release/5.4.0": "stable-2.25",
    "cpd/wxo_prereq/min_ocp_version": "4.12",
    "cpd/wxo_prereq/min_worker_nodes": "4",
    "cpd/wxo_prereq/min_cpu_per_node": "16",
    "cpd/wxo_prereq/min_memory_per_node_gb": "64",
    "cpd/wxo_prereq/min_storage_gb": "500",
    "helm/pinned_version": "v3.18.4",
    "helm/mission_control_min": "3.14.0",
    "helm/mission_control_max_exclusive": "3.19.0",
    "concert/optimize_version": "8.21.2",
    "confluent/version": "8.2.0",
    "confluent/c3_version": "2.5.0",
    "confluent/connect_image": "docker.io/cnfldemos/cp-server-connect-datagen:0.6.4-7.6.0",
    "confluent/ldap_image": "docker.io/bitnamilegacy/openldap:2.6.10",
    "confluent/keycloak_image": "quay.io/keycloak/keycloak:26.0",
    "confluent/c3_gateway_image": "registry.access.redhat.com/ubi9/nginx-124:latest",
    "flink/cmf_chart_version": "2.4.2",
    "flink/operator_chart_version": "1.150.3",
    "flink/cert_manager_version": "v1.18.2",
    "flink/application_image": "confluentinc/cp-flink:2.0.2-cp3",
    "flink/sql_image": "confluentinc/cp-flink-sql:1.19-cp11",
    # OLM channels the install scripts wrote literally
    "channel.nfd": "stable",
    "channel.servicemeshoperator": "stable",
    "channel.servicemeshoperator3": "stable",
    "channel.openshift-cert-manager-operator": "stable-v1",
    "channel.cloudnative-pg": "stable-v1",
}


def legacy_pin(path):
    """The legacy literal for <path>; KeyError when there was none."""
    return LEGACY_PINS[path]


def legacy_patch_meta(path):
    """patch_components_meta of cpd-cli's patch-<release>-<n>.yaml as {component: {key: value}};
    scalar keys only (list items such as block_upgrade_patch are skipped).
    (registry_mirror_engine.py's parser before cpd_release_meta.py.)"""
    meta, comp, inside = {}, None, False
    with open(path) as fh:
        for raw in fh:
            line = raw.rstrip()
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            ind = len(line) - len(line.lstrip())
            if ind == 0:
                inside, comp = text == "patch_components_meta:", None
                continue
            if not inside or text.startswith("-"):
                continue
            key, _, val = text.partition(":")
            val = val.strip().strip("'\"")
            if ind == 2:
                comp = key
                meta.setdefault(comp, {})
            elif ind == 4 and comp and val:
                meta[comp][key] = val
    meta.pop("patch_info", None)
    return meta
