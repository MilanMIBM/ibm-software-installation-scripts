# Options, presets and defaults for configs/concert_config/concert_vars.sh,
# rendered by ibm_concert_vars_generation.py. Facts behind the defaults are in
# .claude/plans/ibm-concert-installation-plan.md (IBM Concert 3.1.x installer).

from src.helpers.version_catalog import catalog_value

# ------------------------------------------------------------------------------
# Releases (the notebook also lists live releases from GitHub when reachable)
# ------------------------------------------------------------------------------

concert_release_records = [
    {
        "release_name": "IBM Concert 3.1.0 (x86)",
        "CONCERT_VERSION": "3.1.0",
        "CONCERT_RELEASE_TAG": "v3.1.0",
        "CONCERT_ARCHIVE": "ibm-concert-x86.tar.gz",
    },
]

default_concert_release_tag = "v3.1.0"

# GitHub release names that are not on-prem installs
concert_release_name_excludes = ("SaaS Only", "prerelease")

# ------------------------------------------------------------------------------
# Products - presets mirror IBM's etc/sample-params/*-k8s-*.ini combinations
# ------------------------------------------------------------------------------

concert_preset_records = [
    {
        "preset_name": "Concert + Data Apps + Workflows (Default)",
        "preset_id": "concert-dataapps-workflows",
        "products": [
            "CONCERT_INSTALL_CONCERT",
            "CONCERT_INSTALL_DATAAPPS",
            "CONCERT_INSTALL_WORKFLOWS",
        ],
    },
    {
        "preset_name": "Concert + Workflows",
        "preset_id": "concert-workflows",
        "products": ["CONCERT_INSTALL_CONCERT", "CONCERT_INSTALL_WORKFLOWS"],
    },
    {
        "preset_name": "Concert + Data Apps",
        "preset_id": "concert-dataapps",
        "products": ["CONCERT_INSTALL_CONCERT", "CONCERT_INSTALL_DATAAPPS"],
    },
    {
        "preset_name": "Concert only (also: Concert with a remote Hub)",
        "preset_id": "concert",
        "products": ["CONCERT_INSTALL_CONCERT"],
    },
    {
        "preset_name": "Workflows only",
        "preset_id": "workflows",
        "products": ["CONCERT_INSTALL_WORKFLOWS"],
    },
    {
        "preset_name": "Data Apps only",
        "preset_id": "dataapps",
        "products": ["CONCERT_INSTALL_DATAAPPS"],
    },
    {
        "preset_name": "Hub only (a shared Hub for products on other clusters)",
        "preset_id": "hub",
        "products": [],
    },
]

default_concert_preset = "concert-dataapps-workflows"

# Rows of the product table; selection = installed
concert_product_records = [
    {
        "product_id": "CONCERT_INSTALL_CONCERT",
        "product": "IBM Concert",
        "notes": "namespace PROJECT_CONCERT",
    },
    {
        "product_id": "CONCERT_INSTALL_DATAAPPS",
        "product": "Concert Data Apps",
        "notes": "x86 only",
    },
    {
        "product_id": "CONCERT_INSTALL_WORKFLOWS",
        "product": "Concert Workflows",
        "notes": "Helm chart rna-core; Istio or FaaS",
    },
    {
        "product_id": "CONCERT_INSTALL_SECURECODER",
        "product": "Secure Coder (add-on)",
        "notes": "needs Concert; Mend needs watsonx SaaS creds",
    },
    {
        "product_id": "CONCERT_INSTALL_VEIAS",
        "product": "VEIAS (add-on)",
        "notes": "needs Concert + Neo4j (provisioned automatically)",
    },
    {
        "product_id": "CONCERT_INSTALL_OPTIMIZE",
        "product": "Concert Optimize - Turbonomic (add-on)",
        "notes": "t8c-operator in PROJECT_CONCERT_OPTIMIZE, attached to the Hub (5_install_optimize)",
    },
]

# ------------------------------------------------------------------------------
# Profiles - production is the baseline (plan decision D4)
# ------------------------------------------------------------------------------

concert_profile_records = [
    {
        "profile_name": "Production (Default) - HA scale level_2, 2-instance Postgres, storage that grows later",
        "profile_id": "production",
    },
    {
        "profile_name": "Small - test/demo, level_1, single-instance data stores",
        "profile_id": "small",
    },
    {
        "profile_name": "Custom - choose the Hub/Concert scale levels and worker sizing yourself",
        "profile_id": "custom",
    },
]

default_concert_profile = "production"

# level_2 is the first level with multi-replica components (Concert 16/19,
# Hub 3/5). Data Apps: IBM documents level_1 only.
# Worker minimums: IBM's hardware table (prod 3 x 16 vCPU / 32 Gi, test
# 2 x 16 / 32) assumes IBM's built-in stores. With HA PostgreSQL and Istio on
# top, production requests ~50 vCPU (see the notebook's estimate), so it uses
# 4 x 16 / 32 (~80% CPU; losing a worker leaves too little room - use 5 for
# that). Small keeps IBM's test minimum (tight, no HA).
#
# Storage starts small and grows: CloudNativePG expands its volumes when
# CONCERT_DS_PG_*STORAGE_SIZE is raised and 2.3.2 re-runs (the class must allow
# expansion - 2.0 checks), but volumes never shrink. For reference, IBM's own
# built-in stores are single copies of appdb 500 Gi, configdb 50 Gi, Hub DB
# 50 Gi, Data Apps Postgres 10 Gi, Workflows Postgres 6 Gi / MySQL 4 Gi,
# Data Apps Redis 100 Mi. Production Postgres runs 2 instances (primary + one
# standby, each a full copy).
concert_profile_presets = {
    "production": {
        "CONCERT_SCALE_HUB": "level_2",
        "CONCERT_SCALE_CONCERT": "level_2",
        "CONCERT_SCALE_DATAAPPS": "level_1",
        "CONCERT_MIN_WORKERS": "4",
        "CONCERT_MIN_WORKER_CPU": "16",
        "CONCERT_MIN_WORKER_MEM_GI": "32",
        "CONCERT_DS_PG_INSTANCES": "2",
        "CONCERT_DS_PG_STORAGE_SIZE": "250Gi",
        "CONCERT_DS_PG_WAL_STORAGE_SIZE": "20Gi",
        "CONCERT_DS_PG_CPU_REQUEST": "4",
        "CONCERT_DS_PG_MEM_REQUEST": "12Gi",
        "CONCERT_DS_PG_CPU_LIMIT": "6",
        "CONCERT_DS_PG_MEM_LIMIT": "16Gi",
        "CONCERT_DS_MYSQL_STORAGE_SIZE": "20Gi",
        "CONCERT_DS_MYSQL_CPU_REQUEST": "1",
        "CONCERT_DS_MYSQL_MEM_REQUEST": "2Gi",
        "CONCERT_DS_MYSQL_MEM_LIMIT": "4Gi",
        "CONCERT_DS_REDIS_STORAGE_SIZE": "2Gi",
        "CONCERT_DS_REDIS_MEM_LIMIT": "2Gi",
        "CONCERT_DS_NEO4J_STORAGE_SIZE": "50Gi",
        "CONCERT_DS_NEO4J_MEM_LIMIT": "8Gi",
    },
    "small": {
        "CONCERT_SCALE_HUB": "level_1",
        "CONCERT_SCALE_CONCERT": "level_1",
        "CONCERT_SCALE_DATAAPPS": "level_1",
        "CONCERT_MIN_WORKERS": "2",
        "CONCERT_MIN_WORKER_CPU": "16",
        "CONCERT_MIN_WORKER_MEM_GI": "32",
        "CONCERT_DS_PG_INSTANCES": "1",
        "CONCERT_DS_PG_STORAGE_SIZE": "100Gi",
        "CONCERT_DS_PG_WAL_STORAGE_SIZE": "10Gi",
        "CONCERT_DS_PG_CPU_REQUEST": "1",
        "CONCERT_DS_PG_MEM_REQUEST": "4Gi",
        "CONCERT_DS_PG_CPU_LIMIT": "2",
        "CONCERT_DS_PG_MEM_LIMIT": "6Gi",
        "CONCERT_DS_MYSQL_STORAGE_SIZE": "10Gi",
        "CONCERT_DS_MYSQL_CPU_REQUEST": "250m",
        "CONCERT_DS_MYSQL_MEM_REQUEST": "1Gi",
        "CONCERT_DS_MYSQL_MEM_LIMIT": "2Gi",
        "CONCERT_DS_REDIS_STORAGE_SIZE": "1Gi",
        "CONCERT_DS_REDIS_MEM_LIMIT": "1Gi",
        "CONCERT_DS_NEO4J_STORAGE_SIZE": "20Gi",
        "CONCERT_DS_NEO4J_MEM_LIMIT": "4Gi",
    },
}

# Custom starts from the production values; the notebook's custom panel then
# overrides the scale levels, worker minimums and the PostgreSQL size.
concert_profile_presets["custom"] = dict(concert_profile_presets["production"])

# Data Apps is always level_1 (the only level IBM documents for it).
concert_dataapps_scale_level = "level_1"

# Resource REQUESTS per scale level as (vCPU, memory Gi), summed from IBM's
# level_*.cfg files (replicas x requests) in the 3.1.0 archive:
#   Hub      concert-hub/k8s-templates/   Concert  concert/k8s/etc/
#   Data Apps dataapps/k8s/etc/
# level_0 (everything scaled to 0) and the undocumented level_3_1..3_3 variants
# are left out; level_3_resilience is the documented-by-name HA variant.
# Totals include every component the level file sizes - see the optional parts below.
concert_scale_level_requests = {
    "hub": {
        "level_1": (0.52, 0.48),
        "level_2": (0.78, 0.74),
        "level_3": (1.28, 1.24),
    },
    "concert": {
        "level_1": (16.84, 9.25),
        "level_2": (27.61, 15.5),
        "level_3": (52.23, 29.75),
        "level_3_resilience": (66.05, 37.75),
        "level_4": (76.78, 42.5),
    },
    "dataapps": {
        "level_1": (3.32, 2.25),
    },
}

# Parts of those totals that only run in some configurations; the notebook's
# estimate subtracts them when they are not deployed:
#   built-in stores (absent when the store is external), VEIAS (only when
#   selected), buddy (CONCERT_ENABLE_BUDDY).
_concert_levels = ("level_1", "level_2", "level_3", "level_3_resilience", "level_4")
concert_scale_level_optional_requests = {
    "hub": {
        "embedded_db": {
            level: (0.13, 0.12) for level in ("level_1", "level_2", "level_3")
        },
    },
    "concert": {
        "minio": {level: (3.07, 1.5) for level in _concert_levels},
        "appdb_configdb": {level: (2.04, 1.0) for level in _concert_levels},
        "veias": {
            "level_1": (1.02, 0.5),
            "level_2": (2.05, 1.0),
            "level_3": (5.12, 2.5),
            "level_3_resilience": (5.12, 2.5),
            "level_4": (6.14, 3.0),
        },
        "buddy": {
            "level_1": (1.02, 1.0),
            "level_2": (2.05, 2.0),
            "level_3": (5.12, 5.0),
            "level_3_resilience": (5.12, 5.0),
            "level_4": (6.14, 6.0),
        },
    },
    "dataapps": {
        "postgres": {"level_1": (1.02, 0.5)},
        "redis": {"level_1": (0.26, 0.5)},
    },
}

# Components without scale levels, as (vCPU, memory Gi) requests:
#   workflows  rna-core values.yaml defaults (~36 pods)
#   istio      istiod (0.5 / 2 Gi) + one sidecar per Workflows pod (100m / 128Mi)
#   runner     the installer Job while it runs
#   optimize   Turbonomic 8.21.2 in Concert mode: `helm template` of the
#              t8c-operator 42.116 chart with 5.4's values (33 workloads,
#              memory requests only - none requests CPU). Extra probes add
#              ~0.4 Gi each. IBM's minimum spec for Turbonomic is 4 vCPU / 32 GB.
concert_fixed_requests = {
    "workflows": (6.9, 9.2),
    "istio": (4.1, 6.5),
    "runner": (0.25, 0.5),
    "optimize": (0.0, 13.0),
}

# Turbonomic volumes besides the database (CONCERT_OPTIMIZE_DB_STORAGE_SIZE),
# in Gi, from `helm template` of the 42.116 chart with 5.4's values: Kafka 50,
# rsyslog 2 x 30, Prometheus 8, topology-processor 3, api/api-certs/auth/Consul 1 each.
concert_optimize_other_storage_gi = 125

# Keys the custom panel sets (removed from the editable sizing list in custom)
concert_custom_sizing_keys = (
    "CONCERT_SCALE_HUB",
    "CONCERT_SCALE_CONCERT",
    "CONCERT_MIN_WORKERS",
    "CONCERT_MIN_WORKER_CPU",
    "CONCERT_MIN_WORKER_MEM_GI",
    "CONCERT_DS_PG_INSTANCES",
    "CONCERT_DS_PG_STORAGE_SIZE",
)

# ------------------------------------------------------------------------------
# Runner, image source, hub mode
# ------------------------------------------------------------------------------

concert_runner_records = [
    {
        "runner_name": "In-cluster Job (Default) - runs where Concert runs",
        "runner_id": "cluster",
    },
    {"runner_name": "Podman container on this workstation", "runner_id": "container"},
    {"runner_name": "Native on a Linux x86 bastion", "runner_id": "native"},
]

concert_image_source_records = [
    {
        "image_source_name": "IBM Entitled Registry - cp.icr.io (Default)",
        "image_source_id": "entitled",
    },
    {
        "image_source_name": "Mirrored private registry (connected mirror host)",
        "image_source_id": "mirrored",
    },
    {
        "image_source_name": "Air-gapped private registry (mirror to disk, transfer, load)",
        "image_source_id": "airgap",
    },
]

concert_hub_mode_records = [
    {
        "hub_mode_name": "Auto (Default) - local Hub, or a remote Hub when its URL + access key are set",
        "hub_mode_id": "auto",
    },
    {
        "hub_mode_name": "Local only - always install a Hub on this cluster",
        "hub_mode_id": "local",
    },
]

# ------------------------------------------------------------------------------
# Data stores (plan §6) - selection in the table = external
# ------------------------------------------------------------------------------

concert_datastore_consumer_records = [
    {
        "consumer_id": "KEYCLOAK",
        "consumer": "Hub / Keycloak database",
        "server": "POSTGRES",
        "external_default": True,
    },
    {
        "consumer_id": "CONCERT_DB",
        "consumer": "Concert appdb + configdb (pgvector)",
        "server": "POSTGRES",
        "external_default": True,
    },
    {
        "consumer_id": "CONCERT_S3",
        "consumer": "Concert landing zone + evidence locker buckets",
        "server": "S3",
        "external_default": True,
    },
    {
        "consumer_id": "CONCERT_NEO4J",
        "consumer": "Concert graph (VEIAS) - always external",
        "server": "NEO4J",
        "external_default": True,
    },
    {
        "consumer_id": "DATAAPPS_DB",
        "consumer": "Data Apps database",
        "server": "POSTGRES",
        "external_default": True,
    },
    {
        "consumer_id": "DATAAPPS_REDIS",
        "consumer": "Data Apps Redis cache",
        "server": "REDIS",
        "external_default": True,
    },
    {
        "consumer_id": "WORKFLOWS_MYSQL",
        "consumer": "Workflows MySQL (pliant)",
        "server": "MYSQL",
        "external_default": True,
    },
    {
        "consumer_id": "WORKFLOWS_POSTGRES",
        "consumer": "Workflows AI PostgreSQL",
        "server": "POSTGRES",
        "external_default": True,
    },
    {
        "consumer_id": "WORKFLOWS_S3",
        "consumer": "Workflows object storage",
        "server": "S3",
        "external_default": True,
    },
    {
        "consumer_id": "WORKFLOWS_RABBITMQ",
        "consumer": "Workflows RabbitMQ (messaging, not storage)",
        "server": "RABBITMQ",
        "external_default": False,
    },
]

concert_datastore_provider_records = [
    {
        "provider_name": "Provision in this cluster (Default)",
        "provider_id": "provision",
    },
    {
        "provider_name": "Use an existing server (fill its connection values)",
        "provider_id": "existing",
    },
]

# Servers we can provision; RabbitMQ is "existing" only
concert_datastore_server_records = [
    {
        "server_id": "POSTGRES",
        "server_name": "PostgreSQL 16 - CloudNativePG cluster",
        "provisionable": True,
    },
    {
        "server_id": "S3",
        "server_name": "S3 - ODF Multicloud Object Gateway buckets",
        "provisionable": True,
    },
    {
        "server_id": "MYSQL",
        "server_name": "MySQL 8.4 - Red Hat image StatefulSet",
        "provisionable": True,
    },
    {
        "server_id": "REDIS",
        "server_name": "Redis 7 - Red Hat image StatefulSet (ACL + TLS)",
        "provisionable": True,
    },
    {
        "server_id": "NEO4J",
        "server_name": "Neo4j 5 community - StatefulSet",
        "provisionable": True,
    },
    {
        "server_id": "RABBITMQ",
        "server_name": "RabbitMQ - existing server only",
        "provisionable": False,
    },
]

# ------------------------------------------------------------------------------
# Default key/value groups (rendered as export lines, in this order)
# ------------------------------------------------------------------------------

default_concert_release = [
    {"key": "CONCERT_VERSION", "value": "3.1.0"},
    {"key": "CONCERT_RELEASE_TAG", "value": "v3.1.0"},
    {"key": "CONCERT_ARCHIVE", "value": "ibm-concert-x86.tar.gz"},
    {"key": "CONCERT_ARCHIVE_SHA256", "value": ""},
    {"key": "CONCERT_HELM_VERSION", "value": catalog_value("helm/pinned_version")},
    {"key": "CONCERT_PROFILE", "value": "production"},
    {"key": "CONCERT_ACCEPT_LICENSE", "value": "false"},
]

default_concert_runner = [
    {"key": "CONCERT_RUNNER", "value": "cluster"},
    {"key": "CONCERT_RUNNER_IMAGE_SOURCE", "value": ""},
    {"key": "CONCERT_RUNNER_IMAGE", "value": ""},
    {
        "key": "CONCERT_RUNNER_BASE_IMAGE",
        "value": "registry.access.redhat.com/ubi9/ubi:latest",
    },
    {"key": "CONCERT_RUNNER_PVC_SIZE", "value": "5Gi"},
    {"key": "CONCERT_RUNNER_KEEP_ADMIN", "value": "false"},
    {"key": "CONCERT_RUN_TIMEOUT", "value": "10800"},
]

default_concert_images = [
    {"key": "CONCERT_IMAGE_SOURCE", "value": "entitled"},
    {"key": "PRIVATE_REGISTRY_LOCATION", "value": ""},
    {"key": "PRIVATE_REGISTRY_PUSH_USER", "value": ""},
    {"key": "PRIVATE_REGISTRY_PUSH_PASSWORD", "value": ""},
    {"key": "PRIVATE_REGISTRY_PULL_USER", "value": ""},
    {"key": "PRIVATE_REGISTRY_PULL_PASSWORD", "value": ""},
    {"key": "CONCERT_AIRGAP_DIR", "value": ""},
    {"key": "IMAGE_PULL_SECRET", "value": "concert-pull-secret"},
]

default_concert_products = [
    {"key": "CONCERT_PRESET", "value": "concert-dataapps-workflows"},
    {"key": "CONCERT_INSTALL_CONCERT", "value": "true"},
    {"key": "CONCERT_INSTALL_DATAAPPS", "value": "true"},
    {"key": "CONCERT_INSTALL_WORKFLOWS", "value": "true"},
    {"key": "CONCERT_INSTALL_SECURECODER", "value": "false"},
    {"key": "CONCERT_INSTALL_VEIAS", "value": "false"},
    {"key": "CONCERT_INSTALL_OPTIMIZE", "value": "false"},
    {"key": "CONCERT_ENABLE_CONCERT_GRAPH", "value": "false"},
    {"key": "CONCERT_ENABLE_CROSS_PRODUCT_INTEGRATION", "value": "true"},
]

default_concert_hub = [
    {"key": "CONCERT_HUB_MODE", "value": "auto"},
    {"key": "CONCERT_REMOTE_HUB_URL", "value": ""},
    {"key": "CONCERT_REMOTE_HUB_ACCESS_KEY", "value": ""},
    {"key": "CONCERT_REMOTE_HUB_OC_LOGIN", "value": ""},
    {"key": "CONCERT_REMOTE_HUB_NAMESPACE", "value": "ibm-platform-hub"},
    {"key": "CONCERT_OCP_ROUTE_NAME", "value": ""},
    {"key": "CONCERT_OCP_ROUTE_HOSTNAME", "value": ""},
    {"key": "CONCERT_OCP_ROUTE_CERT", "value": ""},
]

default_concert_namespaces = [
    {"key": "PROJECT_CONCERT_HUB", "value": "ibm-platform-hub"},
    {"key": "PROJECT_CONCERT", "value": "ibm-concert"},
    {"key": "PROJECT_CONCERT_DATAAPPS", "value": "ibm-concert-dataapps"},
    {"key": "PROJECT_CONCERT_WORKFLOWS", "value": "ibm-concert-workflows"},
    {"key": "PROJECT_CONCERT_WORKFLOWS_FAAS", "value": "ibm-concert-workflows-faas"},
    {"key": "PROJECT_CONCERT_SECURECODER", "value": "ibm-concert-securecoder"},
    {"key": "PROJECT_CONCERT_INSTALLER", "value": "ibm-concert-installer"},
    {"key": "PROJECT_CONCERT_DATASTORES", "value": "ibm-concert-datastores"},
    # IBM's Turbonomic docs and t8c-operator samples use "turbonomic"
    {"key": "PROJECT_CONCERT_OPTIMIZE", "value": "turbonomic"},
]

# Profile-driven values are appended from concert_profile_presets
default_concert_sizing = [
    {"key": "CONCERT_ENABLE_HPA", "value": "false"},
    {"key": "CONCERT_DATAAPPS_ENABLE_HPA", "value": "false"},
    {"key": "CONCERT_ENABLE_BUDDY", "value": "true"},
    {"key": "CONCERT_IP_FAMILIES", "value": ""},
    {"key": "CONCERT_AUTOSCALE_APPLY", "value": "false"},
    {"key": "CONCERT_AUTOSCALE_MACHINESET", "value": ""},
]

default_concert_storage = [
    {"key": "CONCERT_STG_CLASS_BLOCK", "value": "ocs-storagecluster-ceph-rbd"},
    {"key": "CONCERT_STG_CLASS_HUB", "value": "${CONCERT_STG_CLASS_BLOCK}"},
    {"key": "CONCERT_STG_CLASS_CONCERT", "value": "${CONCERT_STG_CLASS_BLOCK}"},
    # Concert buddy volumes are ReadWriteMany: needs a file class. ODF/FDF:
    # *-ceph-rbd -> *-cephfs; other block classes stay as-is (preflight checks).
    {
        "key": "CONCERT_STG_CLASS_FILE_CONCERT",
        "value": "${CONCERT_STG_CLASS_BLOCK/ceph-rbd/cephfs}",
    },
    {"key": "CONCERT_STG_CLASS_DATAAPPS", "value": "${CONCERT_STG_CLASS_BLOCK}"},
    {"key": "CONCERT_STG_CLASS_WORKFLOWS", "value": "${CONCERT_STG_CLASS_BLOCK}"},
    {"key": "CONCERT_STG_CLASS_DATASTORES", "value": "${CONCERT_STG_CLASS_BLOCK}"},
    {"key": "CONCERT_STG_CLASS_OPTIMIZE", "value": "${CONCERT_STG_CLASS_BLOCK}"},
]

# Istio pin = IBM's cw-istio-configure-k8s.sh default; channel = the repo's
# Service Mesh 3 channel (shared with CP4D), see plan decision D8.
default_concert_workflows = [
    {"key": "CONCERT_WORKFLOWS_ENABLE_ISTIO", "value": "true"},
    {"key": "CONCERT_WORKFLOWS_ENABLE_FAAS", "value": "false"},
    {"key": "CONCERT_WORKFLOWS_INSTALL_ALL_INTEGRATIONS", "value": ""},
    {"key": "CONCERT_WORKFLOWS_ENABLE_MCP_SERVER", "value": "true"},
    {"key": "CONCERT_WORKFLOWS_INSTANCE_ADDRESS", "value": ""},
    {"key": "CONCERT_WORKFLOWS_EXTRA_VALUES_FILE", "value": ""},
    {"key": "CONCERT_WORKFLOWS_FLOW_PAUSE_ENABLED", "value": ""},
    {"key": "CONCERT_WORKFLOWS_TERMINATION_TIMEOUT", "value": ""},
    {"key": "CONCERT_WORKFLOWS_USER_WORKER_TOKEN_DURATION", "value": ""},
    {"key": "SERVICE_MESH_VERSION", "value": "3"},
    {"key": "CONCERT_ISTIO_CHANNEL", "value": "stable"},
    {"key": "CONCERT_ISTIO_VERSION", "value": "v1.26.4"},
]

# Plan decision D9: plain manual inputs, no CP4D pre-fill
default_concert_ai = [
    {"key": "CONCERT_ENABLE_AI", "value": "false"},
    {"key": "CONCERT_LLM_PROVIDER", "value": "watsonx"},
    {"key": "CONCERT_WATSONX_API_URL", "value": ""},
    {"key": "CONCERT_WATSONX_API_PROJECT_ID", "value": ""},
    {"key": "CONCERT_WATSONX_API_USER", "value": ""},
    {"key": "CONCERT_WATSONX_API_PASSWORD", "value": ""},
    {"key": "CONCERT_WATSONX_API_KEY", "value": ""},
    {"key": "CONCERT_WATSONX_API_MODEL_ID", "value": ""},
    {"key": "CONCERT_WATSONX_API_VERSION", "value": ""},
    {"key": "CONCERT_WATSONX_API_INSTANCE_ID", "value": ""},
    {"key": "CONCERT_LLM_MODEL", "value": ""},
    {"key": "CONCERT_EMBED_MODEL", "value": ""},
    {"key": "CONCERT_LLM_BASE_URL", "value": ""},
    {"key": "CONCERT_LLM_API_KEY", "value": ""},
]

default_concert_securecoder = [
    {"key": "CONCERT_SECURECODER_MEND_ENABLED", "value": "FALSE"},
    {"key": "CONCERT_SECURECODER_MEND_ORG_NAME", "value": ""},
    {"key": "CONCERT_SECURECODER_MEND_PRODUCT_NAME", "value": ""},
    {"key": "CONCERT_SECURECODER_MEND_SERVICE_URL", "value": ""},
    {"key": "CONCERT_SECURECODER_MEND_EMAIL_ADDRESS", "value": ""},
    {"key": "CONCERT_SECURECODER_MEND_PROJECT_NAME", "value": ""},
    {"key": "CONCERT_SECURECODER_MEND_USER_KEY", "value": ""},
    {"key": "CONCERT_SECURECODER_MEND_API_KEY", "value": ""},
]

default_concert_admin = [
    {"key": "CONCERT_ADMIN_USERNAME", "value": "concertadmin"},
    {"key": "CONCERT_ADMIN_PASSWORD", "value": ""},
    {"key": "CONCERT_ADMIN_NEW_PASSWORD", "value": ""},
]

# Concert Optimize = Turbonomic, installed by 5_install_optimize (not by IBM's
# Concert installer). The version follows IBM's Concert platform version
# matrix: Hub 3.0.3 (bundled with Concert 3.1.0) <-> Turbonomic 8.21.2; the
# operator manifests come from github.com/IBM/t8c-operator at that tag.
#   ADMIN_*         Turbonomic's local administrator (5.3 creates it; the
#                   notebook generates the password, kept across saves)
#   LICENSE_FILE    the Turbonomic license from Passport Advantage (5.3 adds
#                   it); relative paths are read from configs/concert_config/
#   DB_STORAGE_SIZE the Turbonomic database volume; IBM's chart default is
#                   500Gi - it starts smaller and can grow (never shrink)
#   PROBES          extra Turbonomic probes to enable, comma-separated chart
#                   keys (vcenter,aws,azure,kubeturbo,...); IBM's sample CR
#                   enables only instana, prometheus and metrics-processor
#   SCC             restricted = fsGroup from the namespace's UID range (the
#                   t8c-operator README's first option); anyuid = its fallback
#   ROUTE_HOSTNAME  empty = optimize-<namespace>.<apps domain>
#   ROUTE_TERMINATION reencrypt = the router's certificate (like Concert's
#                   routes); passthrough = the gateway's own (fallback, see 5.4)
#   HUB_URL         empty = the local Hub's in-cluster gateway, or the remote Hub
#   OAUTH2_AUDIENCE IBM's t8c-operator samples use CONCERT; IBM's Optimize docs
#                   page shows the Hub URL there instead (unverified)
default_concert_optimize = [
    {"key": "CONCERT_OPTIMIZE_VERSION", "value": catalog_value("concert/optimize_version")},
    {"key": "CONCERT_OPTIMIZE_IMAGE_REPOSITORY", "value": "icr.io/cpopen/turbonomic"},
    {"key": "CONCERT_OPTIMIZE_ADMIN_USERNAME", "value": "administrator"},
    {"key": "CONCERT_OPTIMIZE_ADMIN_PASSWORD", "value": ""},
    {"key": "CONCERT_OPTIMIZE_LICENSE_FILE", "value": ""},
    {"key": "CONCERT_OPTIMIZE_DB_STORAGE_SIZE", "value": "100Gi"},
    {"key": "CONCERT_OPTIMIZE_PROBES", "value": ""},
    {"key": "CONCERT_OPTIMIZE_SCC", "value": "restricted"},
    {"key": "CONCERT_OPTIMIZE_ROUTE_HOSTNAME", "value": ""},
    {"key": "CONCERT_OPTIMIZE_ROUTE_TERMINATION", "value": "reencrypt"},
    {"key": "CONCERT_OPTIMIZE_HUB_URL", "value": ""},
    {"key": "CONCERT_OPTIMIZE_OAUTH2_AUDIENCE", "value": "CONCERT"},
]

default_concert_ds_postgres = [
    {"key": "CONCERT_DS_PG_OPERATOR_CHANNEL", "value": "stable-v1"},
    {"key": "CONCERT_DS_PG_OPERATOR_SOURCE", "value": "certified-operators"},
    {
        "key": "CONCERT_DS_PG_IMAGE",
        "value": "ghcr.io/cloudnative-pg/postgresql:16-standard-bookworm",
    },
    {"key": "CONCERT_DS_PG_MAX_CONNECTIONS", "value": "500"},
    {"key": "CONCERT_DS_PG_SECURE", "value": "true"},
    {"key": "CONCERT_DS_PG_DB_KEYCLOAK", "value": "keycloak"},
    {"key": "CONCERT_DS_PG_DB_DATAAPPS", "value": "dataapps"},
    {"key": "CONCERT_DS_PG_DB_WORKFLOWS", "value": "pliant_ai"},
    {"key": "CONCERT_DS_PG_HOST", "value": ""},
    {"key": "CONCERT_DS_PG_PORT", "value": "5432"},
    {"key": "CONCERT_DS_PG_ADMIN_USER", "value": ""},
    {"key": "CONCERT_DS_PG_ADMIN_PASSWORD", "value": ""},
    {"key": "CONCERT_DS_PG_SSLMODE", "value": "require"},
]

# CW_AUTH_TYPE: IBM does not document the accepted values (spike S7)
default_concert_ds_s3 = [
    {"key": "CONCERT_DS_S3_MCG_CHANNEL", "value": ""},
    {"key": "CONCERT_DS_S3_STORAGE_CLASS", "value": "openshift-storage.noobaa.io"},
    {"key": "CONCERT_DS_S3_SECURE", "value": "true"},
    {"key": "CONCERT_DS_S3_REGION", "value": "us-east-1"},
    {"key": "CONCERT_DS_S3_CW_AUTH_TYPE", "value": "hmac"},
    # Workflows (Node.js, SSL forced) rejects the MCG service's OpenShift
    # service-CA certificate: auto = the MCG route when its certificate is
    # publicly trusted, else the service (2.4 warns). service | route force one.
    {"key": "CONCERT_DS_S3_CW_ENDPOINT", "value": "auto"},
    {"key": "CONCERT_DS_S3_HOST", "value": ""},
    {"key": "CONCERT_DS_S3_PORT", "value": ""},
    {"key": "CONCERT_DS_S3_ACCESS_KEY", "value": ""},
    {"key": "CONCERT_DS_S3_SECRET_KEY", "value": ""},
    {"key": "CONCERT_DS_S3_AUTH_TYPE", "value": ""},
    {"key": "CONCERT_DS_S3_BUCKET_LZ", "value": "concert-lz"},
    {"key": "CONCERT_DS_S3_BUCKET_EL", "value": "concert-el"},
    {"key": "CONCERT_DS_S3_BUCKET_WORKFLOWS", "value": "concert-workflows"},
]

default_concert_ds_other = [
    {"key": "CONCERT_DS_MYSQL_IMAGE", "value": "registry.redhat.io/rhel9/mysql-84"},
    {"key": "CONCERT_DS_MYSQL_HOST", "value": ""},
    {"key": "CONCERT_DS_MYSQL_PORT", "value": "3306"},
    {"key": "CONCERT_DS_MYSQL_USER", "value": ""},
    {"key": "CONCERT_DS_MYSQL_PASSWORD", "value": ""},
    {"key": "CONCERT_DS_MYSQL_DBNAME", "value": "pliant"},
    {"key": "CONCERT_DS_REDIS_IMAGE", "value": "registry.redhat.io/rhel9/redis-7"},
    {"key": "CONCERT_DS_REDIS_TLS", "value": "yes"},
    {"key": "CONCERT_DS_REDIS_HOST", "value": ""},
    {"key": "CONCERT_DS_REDIS_PORT", "value": "6379"},
    {"key": "CONCERT_DS_REDIS_USER", "value": ""},
    {"key": "CONCERT_DS_REDIS_PASSWORD", "value": ""},
    {
        "key": "CONCERT_DS_NEO4J_IMAGE",
        "value": "docker.io/library/neo4j:5.26-community",
    },
    {"key": "CONCERT_DS_NEO4J_HOST", "value": ""},
    {"key": "CONCERT_DS_NEO4J_PORT", "value": "7687"},
    {"key": "CONCERT_DS_NEO4J_USERNAME", "value": ""},
    {"key": "CONCERT_DS_NEO4J_PASSWORD", "value": ""},
    {"key": "CONCERT_DS_NEO4J_DATABASE", "value": "neo4j"},
    {"key": "CONCERT_DS_NEO4J_TLS", "value": "false"},
    {"key": "CONCERT_DS_RABBITMQ_HOST", "value": ""},
    {"key": "CONCERT_DS_RABBITMQ_PORT", "value": "5672"},
    {"key": "CONCERT_DS_RABBITMQ_USER", "value": ""},
    {"key": "CONCERT_DS_RABBITMQ_PASSWORD", "value": ""},
]

# ------------------------------------------------------------------------------
# Storage class choices (RWO block; Concert's FILE_STORAGE_CLASS needs RWX)
# ------------------------------------------------------------------------------

concert_block_storage_options = {
    "OpenShift Data Foundation": "ocs-storagecluster-ceph-rbd",
    "OpenShift Data Foundation (External)": "ocs-external-storagecluster-ceph-rbd",
    "IBM Fusion Data Foundation": "ocs-storagecluster-ceph-rbd",
    "IBM Fusion Global Data Platform (Spectrum Scale)": "ibm-spectrum-scale-sc",
    "IBM Fusion Global Data Platform (Storage Fusion)": "ibm-storage-fusion-cp-sc",
    "IBM Storage Scale Container Native": "ibm-spectrum-scale-sc",
    "IBM Cloud Block Storage": "ibmc-block-gold",
    "Portworx": "portworx-metastoredb-sc",
    "NFS": "managed-nfs-storage",
    "Amazon EBS (gp3)": "gp3-csi",
    "Amazon EBS (gp2)": "gp2-csi",
    "Nutanix": "nutanix-volume",
}
