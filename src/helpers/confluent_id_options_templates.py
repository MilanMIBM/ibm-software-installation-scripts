# Customizable variables for configs/confluent_platform_config/confluent_vars.sh,
# mirroring 0_confluent_prepare_template_config.sh and
# install_confluent_platform_flink_addon/0_flink_prepare_template_config.sh.

from src.helpers import confluent_operator_config as _operator_config
from src.helpers.version_catalog import catalog_value

# ------------------------------------------------------------------------------
# T-shirt sizes (shared by the Confluent and Flink templating scripts)
# ------------------------------------------------------------------------------

confluent_size_options = ["xsmall", "small", "medium", "large"]

confluent_size_records = [
    {
        "size_name": "Extra Small - 1 broker, RF=1, demo only (not fault tolerant)",
        "size_id": "xsmall",
    },
    {
        "size_name": "Small - 3 brokers, RF=3, production POC (~5-10 topics)",
        "size_id": "small",
    },
    {"size_name": "Medium - 3 brokers, RF=3, 12 partitions", "size_id": "medium"},
    {"size_name": "Large - 5 brokers, RF=3, 24 partitions", "size_id": "large"},
]

default_confluent_size = "small"

confluent_size_presets = {
    "xsmall": {
        "CONFLUENT_BROKER_REPLICAS": "1",
        "CONFLUENT_REPLICATION_FACTOR": "1",
        "CONFLUENT_MIN_INSYNC_REPLICAS": "1",
        "CONFLUENT_PARTITIONS": "1",
        "CONFLUENT_BROKER_STORAGE_SIZE": "20Gi",
        "CONFLUENT_BROKER_CPU_REQUEST": "500m",
        "CONFLUENT_BROKER_MEM_REQUEST": "2Gi",
        "CONFLUENT_BROKER_CPU_LIMIT": "2",
        "CONFLUENT_BROKER_MEM_LIMIT": "4Gi",
        "CONFLUENT_COMPONENT_CPU_REQUEST": "250m",
        "CONFLUENT_COMPONENT_MEM_REQUEST": "1Gi",
        "CONFLUENT_COMPONENT_CPU_LIMIT": "1",
        "CONFLUENT_COMPONENT_MEM_LIMIT": "2Gi",
    },
    "small": {
        "CONFLUENT_BROKER_REPLICAS": "3",
        "CONFLUENT_REPLICATION_FACTOR": "3",
        "CONFLUENT_MIN_INSYNC_REPLICAS": "2",
        "CONFLUENT_PARTITIONS": "3",
        "CONFLUENT_BROKER_STORAGE_SIZE": "100Gi",
        "CONFLUENT_BROKER_CPU_REQUEST": "1",
        "CONFLUENT_BROKER_MEM_REQUEST": "4Gi",
        "CONFLUENT_BROKER_CPU_LIMIT": "2",
        "CONFLUENT_BROKER_MEM_LIMIT": "8Gi",
        "CONFLUENT_COMPONENT_CPU_REQUEST": "500m",
        "CONFLUENT_COMPONENT_MEM_REQUEST": "2Gi",
        "CONFLUENT_COMPONENT_CPU_LIMIT": "1",
        "CONFLUENT_COMPONENT_MEM_LIMIT": "4Gi",
    },
    "medium": {
        "CONFLUENT_BROKER_REPLICAS": "3",
        "CONFLUENT_REPLICATION_FACTOR": "3",
        "CONFLUENT_MIN_INSYNC_REPLICAS": "2",
        "CONFLUENT_PARTITIONS": "12",
        "CONFLUENT_BROKER_STORAGE_SIZE": "500Gi",
        "CONFLUENT_BROKER_CPU_REQUEST": "2",
        "CONFLUENT_BROKER_MEM_REQUEST": "8Gi",
        "CONFLUENT_BROKER_CPU_LIMIT": "4",
        "CONFLUENT_BROKER_MEM_LIMIT": "16Gi",
        "CONFLUENT_COMPONENT_CPU_REQUEST": "1",
        "CONFLUENT_COMPONENT_MEM_REQUEST": "4Gi",
        "CONFLUENT_COMPONENT_CPU_LIMIT": "2",
        "CONFLUENT_COMPONENT_MEM_LIMIT": "8Gi",
    },
    "large": {
        "CONFLUENT_BROKER_REPLICAS": "5",
        "CONFLUENT_REPLICATION_FACTOR": "3",
        "CONFLUENT_MIN_INSYNC_REPLICAS": "2",
        "CONFLUENT_PARTITIONS": "24",
        "CONFLUENT_BROKER_STORAGE_SIZE": "1Ti",
        "CONFLUENT_BROKER_CPU_REQUEST": "4",
        "CONFLUENT_BROKER_MEM_REQUEST": "16Gi",
        "CONFLUENT_BROKER_CPU_LIMIT": "8",
        "CONFLUENT_BROKER_MEM_LIMIT": "32Gi",
        "CONFLUENT_COMPONENT_CPU_REQUEST": "2",
        "CONFLUENT_COMPONENT_MEM_REQUEST": "8Gi",
        "CONFLUENT_COMPONENT_CPU_LIMIT": "4",
        "CONFLUENT_COMPONENT_MEM_LIMIT": "16Gi",
    },
}

flink_size_presets = {
    "xsmall": {
        "FLINK_CMF_CPU_REQUEST": "500m",
        "FLINK_CMF_MEM_REQUEST": "1Gi",
        "FLINK_CMF_CPU_LIMIT": "1",
        "FLINK_CMF_MEM_LIMIT": "2Gi",
        "FLINK_CMF_STORAGE_SIZE": "10Gi",
        "FLINK_JOBMANAGER_CPU": "0.5",
        "FLINK_JOBMANAGER_MEMORY": "1024m",
        "FLINK_TASKMANAGER_CPU": "0.5",
        "FLINK_TASKMANAGER_MEMORY": "1024m",
        "FLINK_TASK_SLOTS": "1",
    },
    "small": {
        "FLINK_CMF_CPU_REQUEST": "1",
        "FLINK_CMF_MEM_REQUEST": "2Gi",
        "FLINK_CMF_CPU_LIMIT": "2",
        "FLINK_CMF_MEM_LIMIT": "4Gi",
        "FLINK_CMF_STORAGE_SIZE": "10Gi",
        "FLINK_JOBMANAGER_CPU": "0.5",
        "FLINK_JOBMANAGER_MEMORY": "1024m",
        "FLINK_TASKMANAGER_CPU": "1.0",
        "FLINK_TASKMANAGER_MEMORY": "2048m",
        "FLINK_TASK_SLOTS": "2",
    },
    "medium": {
        "FLINK_CMF_CPU_REQUEST": "2",
        "FLINK_CMF_MEM_REQUEST": "4Gi",
        "FLINK_CMF_CPU_LIMIT": "4",
        "FLINK_CMF_MEM_LIMIT": "8Gi",
        "FLINK_CMF_STORAGE_SIZE": "20Gi",
        "FLINK_JOBMANAGER_CPU": "1.0",
        "FLINK_JOBMANAGER_MEMORY": "2048m",
        "FLINK_TASKMANAGER_CPU": "2.0",
        "FLINK_TASKMANAGER_MEMORY": "4096m",
        "FLINK_TASK_SLOTS": "4",
    },
    "large": {
        "FLINK_CMF_CPU_REQUEST": "4",
        "FLINK_CMF_MEM_REQUEST": "8Gi",
        "FLINK_CMF_CPU_LIMIT": "8",
        "FLINK_CMF_MEM_LIMIT": "16Gi",
        "FLINK_CMF_STORAGE_SIZE": "50Gi",
        "FLINK_JOBMANAGER_CPU": "2.0",
        "FLINK_JOBMANAGER_MEMORY": "4096m",
        "FLINK_TASKMANAGER_CPU": "4.0",
        "FLINK_TASKMANAGER_MEMORY": "8192m",
        "FLINK_TASK_SLOTS": "8",
    },
}

# ------------------------------------------------------------------------------
# Enumerated options
# ------------------------------------------------------------------------------

confluent_component_toggle_records = [
    {"component_name": "Schema Registry", "component_id": "CONFLUENT_INSTALL_SCHEMA_REGISTRY"},
    {"component_name": "Kafka Connect", "component_id": "CONFLUENT_INSTALL_CONNECT"},
    {"component_name": "ksqlDB", "component_id": "CONFLUENT_INSTALL_KSQLDB"},
    {"component_name": "REST Proxy", "component_id": "CONFLUENT_INSTALL_REST_PROXY"},
    {"component_name": "Control Center", "component_id": "CONFLUENT_INSTALL_CONTROL_CENTER"},
]

confluent_auth_mode_options = ["openshift", "basic"]

confluent_auth_mode_records = [
    {
        "auth_mode_name": "OpenShift OAuth proxy (cluster login, no password to distribute)",
        "auth_mode_id": "openshift",
    },
    {
        "auth_mode_name": "HTTP basic auth (nginx sidecar, CONFLUENT_AUTH_USERNAME/PASSWORD)",
        "auth_mode_id": "basic",
    },
]

confluent_sasl_mechanism_options = ["SCRAM-SHA-512", "SCRAM-SHA-256", "PLAIN"]

confluent_sasl_protocol_records = [
    {
        "sasl_protocol_name": "SASL_PLAINTEXT - authenticated, unencrypted in-cluster traffic (default)",
        "sasl_protocol_id": "SASL_PLAINTEXT",
    },
    {
        "sasl_protocol_name": "SASL_SSL - authenticated and TLS-encrypted (generated in-cluster CA)",
        "sasl_protocol_id": "SASL_SSL",
    },
]

# Mechanisms each listener accepts. In-cluster: the platform's own
# CONFLUENT_SASL_MECHANISM is always accepted on top of these. EXTERNAL is always
# SASL_SSL (the passthrough routes route on the TLS SNI), so only its mechanisms
# are selectable; the first selected one is what the generated client files use.
confluent_internal_sasl_mechanism_options = ["PLAIN", "SCRAM-SHA-512", "SCRAM-SHA-256"]
confluent_external_sasl_mechanism_options = ["PLAIN", "SCRAM-SHA-512", "SCRAM-SHA-256"]

default_confluent_internal_sasl_mechanisms = ["PLAIN", "SCRAM-SHA-512"]
default_confluent_external_sasl_mechanisms = ["PLAIN", "SCRAM-SHA-512"]

confluent_mds_user_store_options = ["LDAP", "OAUTH"]

confluent_mds_user_store_records = [
    {"user_store_name": "Bundled OpenLDAP (default)", "user_store_id": "LDAP"},
    {
        "user_store_name": "Bundled Keycloak or external OIDC provider (SSO / device-code login)",
        "user_store_id": "OAUTH",
    },
]

flink_state_backend_options = ["pvc", "s3", "none"]

flink_state_backend_records = [
    {
        "state_backend_name": "RWX PersistentVolumeClaim (default, needs STG_CLASS_FILE)",
        "state_backend_id": "pvc",
    },
    {
        "state_backend_name": "S3-compatible bucket (set FLINK_S3_* values)",
        "state_backend_id": "s3",
    },
    {
        "state_backend_name": "No checkpointing (jobs cannot recover, no savepoints)",
        "state_backend_id": "none",
    },
]

# ------------------------------------------------------------------------------
# Defaults, grouped as they appear in confluent_vars.sh
# ------------------------------------------------------------------------------

default_confluent_cluster_setup = [
    {"key": "OCP_URL", "value": "https://api.<cluster_domain>:6443/"},
    {"key": "OCP_USERNAME", "value": "kubeadmin"},
    {"key": "OCP_PASSWORD", "value": "<insert_password>"},
    {"key": "SERVER_ARGUMENTS", "value": "--server=${OCP_URL}"},
    {
        "key": "LOGIN_ARGUMENTS",
        "value": "--username=${OCP_USERNAME} --password=${OCP_PASSWORD}",
    },
    {"key": "OC_LOGIN", "value": "oc login ${SERVER_ARGUMENTS} ${LOGIN_ARGUMENTS}"},
    {"key": "PROJECT_CONFLUENT_SERVER", "value": "confluent"},
    {"key": "STG_CLASS_BLOCK", "value": "ocs-external-storagecluster-ceph-rbd"},
    {"key": "STG_CLASS_FILE", "value": "ocs-external-storagecluster-cephfs"},
]

default_confluent_images = [
    {"key": "CONFLUENT_VERSION", "value": catalog_value("confluent/version")},
    {"key": "CONFLUENT_REGISTRY", "value": "docker.io/confluentinc"},
    {
        "key": "CONFLUENT_CONNECT_IMAGE",
        "value": catalog_value("confluent/connect_image"),
    },
    {"key": "CONFLUENT_REGISTRY_USER", "value": ""},
    {"key": "CONFLUENT_REGISTRY_PASSWORD", "value": ""},
    {"key": "CONFLUENT_PULL_SECRET", "value": "confluent-registry"},
    {"key": "CONFLUENT_C3_VERSION", "value": catalog_value("confluent/c3_version")},
]

default_confluent_component_toggles = [
    {"key": "CONFLUENT_INSTALL_SCHEMA_REGISTRY", "value": "true"},
    {"key": "CONFLUENT_INSTALL_CONNECT", "value": "true"},
    {"key": "CONFLUENT_INSTALL_KSQLDB", "value": "true"},
    {"key": "CONFLUENT_INSTALL_REST_PROXY", "value": "true"},
    {"key": "CONFLUENT_INSTALL_CONTROL_CENTER", "value": "true"},
    {"key": "CONFLUENT_MONITORING_NETWORK_POLICY", "value": "true"},
]

default_confluent_ports = [
    {"key": "CONFLUENT_BROKER_INTERNAL_PORT", "value": "29092"},
    {"key": "CONFLUENT_BROKER_CONTROLLER_PORT", "value": "29093"},
    {"key": "CONFLUENT_BROKER_EXTERNAL_PORT", "value": "9092"},
    {"key": "CONFLUENT_SCHEMA_REGISTRY_PORT", "value": "8081"},
    {"key": "CONFLUENT_CONNECT_PORT", "value": "8083"},
    {"key": "CONFLUENT_KSQLDB_PORT", "value": "8088"},
    {"key": "CONFLUENT_REST_PROXY_PORT", "value": "8082"},
    {"key": "CONFLUENT_CONTROL_CENTER_PORT", "value": "9021"},
    {"key": "CONFLUENT_PROMETHEUS_PORT", "value": "9090"},
    {"key": "CONFLUENT_ALERTMANAGER_PORT", "value": "9093"},
    {"key": "CONFLUENT_BROKER_JMX_PORT", "value": "9101"},
]

default_confluent_routes_and_waits = [
    {"key": "CONFLUENT_CREATE_ROUTES", "value": "true"},
    {"key": "CONFLUENT_ROUTE_DOMAIN", "value": ""},  # empty = cluster apps domain
    {"key": "CONFLUENT_ROLLOUT_TIMEOUT", "value": "600s"},
]

default_confluent_storage = [
    {"key": "CONFLUENT_STORAGE_CLASS", "value": "${STG_CLASS_BLOCK}"},
    # 22 chars of [A-Za-z0-9_-]; generated by the templating script when empty
    {"key": "CONFLUENT_CLUSTER_ID", "value": ""},
]

default_confluent_web_ui_auth = [
    {"key": "CONFLUENT_AUTH_ENABLED", "value": "true"},
    {"key": "CONFLUENT_AUTH_MODE", "value": "openshift"},
    {"key": "CONFLUENT_AUTH_SECRET", "value": "confluent-auth"},
    {"key": "CONFLUENT_AUTH_USERNAME", "value": "${OCP_USERNAME}"},
    {"key": "CONFLUENT_AUTH_PASSWORD", "value": ""},  # empty = generated
    {"key": "CONFLUENT_AUTH_PASSWORD_LENGTH", "value": "24"},
]

default_confluent_sasl = [
    {"key": "CONFLUENT_SASL_ENABLED", "value": "true"},
    # In-cluster listeners, inter-broker traffic and every platform component
    {"key": "CONFLUENT_SASL_PROTOCOL", "value": "SASL_PLAINTEXT"},  # or SASL_SSL
    # What broker-to-broker traffic and the components use
    {"key": "CONFLUENT_SASL_MECHANISM", "value": "SCRAM-SHA-512"},  # SCRAM-SHA-256, PLAIN
    # What in-cluster clients may use (comma-separated)
    {"key": "CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS", "value": "PLAIN,SCRAM-SHA-512"},
    {"key": "CONFLUENT_SASL_ADMIN_USER", "value": "confluent-admin"},
    {"key": "CONFLUENT_SASL_CLIENTS", "value": "app-client"},  # comma-separated
    {"key": "CONFLUENT_SASL_SECRET", "value": "confluent-sasl"},
    # CONFLUENT_SASL_PROTOCOL=SASL_SSL only
    {"key": "CONFLUENT_INTERNAL_TLS_SECRET", "value": "confluent-kafka-internal-tls"},
    {"key": "CONFLUENT_INTERNAL_CERT_VALIDITY_DAYS", "value": "825"},
]

default_confluent_mds = [
    {"key": "CONFLUENT_MDS_ENABLED", "value": "true"},  # requires SASL
    {"key": "CONFLUENT_MDS_PORT", "value": "8090"},
    {"key": "CONFLUENT_MDS_USER_STORE", "value": "LDAP"},
    {"key": "CONFLUENT_MDS_SECRET", "value": "confluent-mds"},
    {"key": "CONFLUENT_MDS_SUPER_USER", "value": "mds-admin"},
    {"key": "CONFLUENT_MDS_USERS", "value": "kafka-admin,kafka-user"},
    {"key": "CONFLUENT_LICENSE_KEY", "value": ""},  # empty = 30-day trial
]

default_confluent_ldap = [
    {"key": "CONFLUENT_LDAP_IMAGE", "value": catalog_value("confluent/ldap_image")},
    {"key": "CONFLUENT_LDAP_PORT", "value": "1389"},
    {"key": "CONFLUENT_LDAP_DOMAIN", "value": "confluent.io"},
    {"key": "CONFLUENT_LDAP_ADMIN_USER", "value": "admin"},
    {"key": "CONFLUENT_LDAP_SECRET", "value": "confluent-ldap"},
]

default_confluent_oauth = [
    {"key": "CONFLUENT_KEYCLOAK_IMAGE", "value": catalog_value("confluent/keycloak_image")},
    {"key": "CONFLUENT_KEYCLOAK_PORT", "value": "8080"},
    {"key": "CONFLUENT_KEYCLOAK_REALM", "value": "confluent"},
    {"key": "CONFLUENT_KEYCLOAK_CLIENT_ID", "value": "confluent-cli"},
    {"key": "CONFLUENT_KEYCLOAK_ADMIN_USER", "value": "admin"},
    {"key": "CONFLUENT_KEYCLOAK_SECRET", "value": "confluent-keycloak"},
    # Set these to use an external OIDC provider instead of bundled Keycloak
    {"key": "CONFLUENT_MDS_OAUTH_JWKS_URL", "value": ""},
    {"key": "CONFLUENT_MDS_OAUTH_ISSUER", "value": ""},
    {"key": "CONFLUENT_MDS_OAUTH_AUDIENCE", "value": "Confluent"},
    {"key": "CONFLUENT_MDS_OAUTH_SUB_CLAIM", "value": "preferred_username"},
    {"key": "CONFLUENT_MDS_OAUTH_GROUPS_CLAIM", "value": "groups"},
    {"key": "CONFLUENT_MDS_OAUTH_DEVICE_AUTH_URL", "value": ""},
]

default_confluent_external_access = [
    {"key": "CONFLUENT_EXTERNAL_KAFKA_ENABLED", "value": "true"},  # requires SASL
    # Always SASL_SSL; comma-separated, the first is the one client files use
    {"key": "CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS", "value": "PLAIN,SCRAM-SHA-512"},
    {"key": "CONFLUENT_EXTERNAL_KAFKA_PORT", "value": "9094"},
    {"key": "CONFLUENT_EXTERNAL_TLS_SECRET", "value": "confluent-kafka-tls"},
    {"key": "CONFLUENT_EXTERNAL_CERT_VALIDITY_DAYS", "value": "825"},
]

# ------------------------------------------------------------------------------
# Flink addon defaults
# ------------------------------------------------------------------------------

default_flink_project_and_storage = [
    {"key": "PROJECT_CONFLUENT_FLINK", "value": "${PROJECT_CONFLUENT_SERVER}-flink"},
    {"key": "FLINK_CMF_STORAGE_CLASS", "value": "${STG_CLASS_BLOCK}"},
]

default_flink_helm = [
    {"key": "FLINK_HELM_REPO_NAME", "value": "confluentinc"},
    {"key": "FLINK_HELM_REPO_URL", "value": "https://packages.confluent.io/helm"},
    {"key": "FLINK_CMF_CHART_VERSION", "value": catalog_value("flink/cmf_chart_version")},
    {"key": "FLINK_OPERATOR_CHART_VERSION", "value": catalog_value("flink/operator_chart_version")},
    {"key": "FLINK_CMF_RELEASE_NAME", "value": "cmf"},
    {"key": "FLINK_OPERATOR_RELEASE_NAME", "value": "cp-flink-kubernetes-operator"},
]

default_flink_images = [
    {"key": "FLINK_IMAGE_REGISTRY", "value": ""},  # empty = chart default
    {"key": "FLINK_APPLICATION_IMAGE", "value": catalog_value("flink/application_image")},
    {"key": "FLINK_SQL_IMAGE", "value": catalog_value("flink/sql_image")},
    {"key": "FLINK_APPLICATION_VERSION", "value": "v2_0"},
    {"key": "FLINK_SQL_VERSION", "value": "v1_19"},
]

default_flink_cert_manager = [
    {"key": "FLINK_CERT_MANAGER_VERSION", "value": catalog_value("flink/cert_manager_version")},
    {"key": "FLINK_CERT_MANAGER_NAMESPACE", "value": "cert-manager"},
]

default_flink_cmf_endpoint = [
    {"key": "FLINK_CMF_SERVICE", "value": "cmf-service"},
    {"key": "FLINK_CMF_PORT", "value": "80"},
    {"key": "FLINK_CREATE_ROUTES", "value": "true"},  # CMF REST API is unauthenticated
    {"key": "FLINK_CMF_LOCAL_PORT", "value": "8080"},
    {"key": "FLINK_ROLLOUT_TIMEOUT", "value": "600s"},
]

default_flink_naming = [
    {"key": "FLINK_ENVIRONMENT", "value": "cp-env"},
    {"key": "FLINK_COMPUTE_POOL", "value": "cp-pool"},
    {"key": "FLINK_CATALOG", "value": "cp-kafka"},
    {"key": "FLINK_KAFKA_DATABASE", "value": "cp-cluster"},
    {"key": "FLINK_KAFKA_SECRET", "value": "cp-kafka-credentials"},
]

default_flink_state = [
    {"key": "FLINK_STATE_BACKEND", "value": "pvc"},
    {"key": "FLINK_STATE_STORAGE_CLASS", "value": "${STG_CLASS_FILE}"},
    {"key": "FLINK_STATE_STORAGE_SIZE", "value": "50Gi"},
    {"key": "FLINK_STATE_PVC_NAME", "value": "flink-state"},
    {"key": "FLINK_CHECKPOINT_INTERVAL", "value": "60s"},
    # FLINK_STATE_BACKEND=s3 only; the bucket must already exist
    {"key": "FLINK_S3_BUCKET", "value": ""},
    {"key": "FLINK_S3_ENDPOINT", "value": ""},
    {"key": "FLINK_S3_ACCESS_KEY", "value": ""},
    {"key": "FLINK_S3_SECRET_KEY", "value": ""},
    {"key": "FLINK_S3_PATH_STYLE_ACCESS", "value": "true"},
    {"key": "FLINK_S3_SECRET", "value": "flink-s3-credentials"},
]

default_flink_license = [
    {"key": "FLINK_LICENSE_KEY", "value": "${CONFLUENT_LICENSE_KEY:-}"},
    {"key": "FLINK_LICENSE_SECRET", "value": "flink-license"},
]

# ------------------------------------------------------------------------------
# Deploy mode: scripts (raw manifests) | operator (CFK + cp-fko through OLM)
# ------------------------------------------------------------------------------
# Plan: .claude/plans/confluent-operator-install-mode/implementation-contract.md §2, §5.2.
# KRaft presets live once, in confluent_operator_config.py (WP-A); this module only
# re-exports them for the notebook.

confluent_deploy_mode_options = ["operator", "scripts"]

confluent_deploy_mode_records = [
    {
        "deploy_mode_name": "Operator - Confluent for Kubernetes (CFK) + cp-fko through OLM (default)",
        "deploy_mode_id": "operator",
    },
    {
        "deploy_mode_name": "Scripts - the repo renders and applies raw manifests (StatefulSet broker, Deployments)",
        "deploy_mode_id": "scripts",
    },
]

default_confluent_deploy_mode = "operator"

# Operator-mode selects (the first entry is the default)
confluent_operator_approval_options = ["Manual", "Automatic"]
confluent_operator_tls_source_options = ["repo", "cfk"]
confluent_operator_sasl_impl_options = ["plain", "scram"]
confluent_connector_management_options = ["rest", "cr"]
# "follow" = do not write the variable: the Flink scripts then follow the platform mode
flink_operator_source_options = ["follow", "helm", "olm", "existing"]
flink_cmf_resource_mode_options = ["follow", "cli", "cfk"]

# Every operator-settings variable, in the order 0_confluent_prepare_template_config.sh
# writes them; the four select-controlled ones are marked by the selects below.
confluent_operator_select_keys = {
    "CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL": confluent_operator_approval_options,
    "CONFLUENT_OPERATOR_TLS_SOURCE": confluent_operator_tls_source_options,
    "CONFLUENT_OPERATOR_SASL_IMPL": confluent_operator_sasl_impl_options,
    "CONFLUENT_CONNECTOR_MANAGEMENT": confluent_connector_management_options,
}

confluent_operator_var_order = [
    "CONFLUENT_OPERATOR_SOURCE",
    "CONFLUENT_OPERATOR_PACKAGE",
    "CONFLUENT_OPERATOR_SUBSCRIPTION_NAME",
    "CONFLUENT_OPERATOR_CHANNEL",
    "CONFLUENT_OPERATOR_STARTING_CSV",
    "CONFLUENT_OPERATOR_CATALOG_SOURCE",
    "CONFLUENT_OPERATOR_CATALOG_SOURCE_NAMESPACE",
    "CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL",
    "CONFLUENT_OPERATOR_INSTALL_IN_PLATFORM_NS",
    "CONFLUENT_OPERATOR_INSTALL_IN_FLINK_NS",
    "CONFLUENT_OPERATOR_EXTRA_NAMESPACES",
    "CONFLUENT_OPERATOR_PACKAGES_PER_NS",
    "CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING",
    "CONFLUENT_OPERATOR_RESTRICT_CROSS_NS_RESTCLASS",
    "CONFLUENT_OPERATOR_IMAGE_SOURCE",
    "CONFLUENT_OPERATOR_INIT_IMAGE",
    "CONFLUENT_OPERATOR_TLS_SOURCE",
    "CONFLUENT_OPERATOR_SASL_IMPL",
    "CONFLUENT_CONNECTOR_MANAGEMENT",
    "CONFLUENT_AUTO_CREATE_TOPICS",
    "CONFLUENT_OPERATOR_NETWORK_POLICIES",
    "CONFLUENT_EXTERNAL_KAFKA_BOOTSTRAP_PREFIX",
    "CONFLUENT_EXTERNAL_KAFKA_BROKER_PREFIX",
    "CONFLUENT_OPERATOR_CSV_TIMEOUT",
    "CONFLUENT_OPERATOR_INSTALLPLAN_TIMEOUT",
    "CONFLUENT_OPERATOR_KAFKA_TIMEOUT",
    "CONFLUENT_OPERATOR_COMPONENT_TIMEOUT",
    "CONFLUENT_OPERATOR_CONNECT_TIMEOUT",
    "CONFLUENT_CONNECT_PLUGINS_PVC",
    "CONFLUENT_CONNECT_PLUGINS_PVC_SIZE",
    "CONFLUENT_CONNECT_PLUGINS_LOADER_IMAGE",
]

_cfk_init_tag = catalog_value("confluent/operator/cfk_init_tag", default="3.4.0")

# Operator settings (§2.2) minus the select-controlled ones. ${...} references stay
# literal: they expand when confluent_vars.sh is sourced.
default_confluent_operator = [
    {"key": "CONFLUENT_OPERATOR_SOURCE", "value": "olm"},  # olm | existing
    {"key": "CONFLUENT_OPERATOR_PACKAGE", "value": "confluent-for-kubernetes"},
    {"key": "CONFLUENT_OPERATOR_SUBSCRIPTION_NAME", "value": "confluent-for-kubernetes"},
    {
        "key": "CONFLUENT_OPERATOR_CHANNEL",
        "value": catalog_value("confluent/operator/cfk_channel", default="3.4"),
    },
    {
        "key": "CONFLUENT_OPERATOR_STARTING_CSV",
        "value": catalog_value("confluent/operator/cfk_csv", default="confluent-for-kubernetes.v3.4.0"),
    },
    {"key": "CONFLUENT_OPERATOR_CATALOG_SOURCE", "value": "certified-operators"},
    {"key": "CONFLUENT_OPERATOR_CATALOG_SOURCE_NAMESPACE", "value": "openshift-marketplace"},
    {"key": "CONFLUENT_OPERATOR_INSTALL_IN_PLATFORM_NS", "value": "true"},
    {"key": "CONFLUENT_OPERATOR_INSTALL_IN_FLINK_NS", "value": "true"},
    {"key": "CONFLUENT_OPERATOR_EXTRA_NAMESPACES", "value": ""},  # space-separated
    {"key": "CONFLUENT_OPERATOR_PACKAGES_PER_NS", "value": ""},  # ns=pkg[,pkg] ns2=pkg
    {"key": "CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING", "value": "false"},
    {"key": "CONFLUENT_OPERATOR_RESTRICT_CROSS_NS_RESTCLASS", "value": "false"},
    {"key": "CONFLUENT_OPERATOR_IMAGE_SOURCE", "value": "tags"},  # tags | csv
    {
        "key": "CONFLUENT_OPERATOR_INIT_IMAGE",
        "value": "${CONFLUENT_REGISTRY}/confluent-init-container:" + _cfk_init_tag,
    },
    {"key": "CONFLUENT_AUTO_CREATE_TOPICS", "value": "true"},
    {"key": "CONFLUENT_OPERATOR_NETWORK_POLICIES", "value": "true"},
    {"key": "CONFLUENT_EXTERNAL_KAFKA_BOOTSTRAP_PREFIX", "value": "kafka-${PROJECT_CONFLUENT_SERVER}"},
    {"key": "CONFLUENT_EXTERNAL_KAFKA_BROKER_PREFIX", "value": "kafka-${PROJECT_CONFLUENT_SERVER}-b"},
    {"key": "CONFLUENT_OPERATOR_CSV_TIMEOUT", "value": "600"},
    {"key": "CONFLUENT_OPERATOR_INSTALLPLAN_TIMEOUT", "value": "300"},
    {"key": "CONFLUENT_OPERATOR_KAFKA_TIMEOUT", "value": "900"},
    {"key": "CONFLUENT_OPERATOR_COMPONENT_TIMEOUT", "value": "600"},
    {"key": "CONFLUENT_OPERATOR_CONNECT_TIMEOUT", "value": "900"},
    {"key": "CONFLUENT_CONNECT_PLUGINS_PVC", "value": "connect-plugins"},
    {"key": "CONFLUENT_CONNECT_PLUGINS_PVC_SIZE", "value": "5Gi"},
    {
        "key": "CONFLUENT_CONNECT_PLUGINS_LOADER_IMAGE",
        "value": "registry.access.redhat.com/ubi9/ubi:latest",
    },
]

# KRaft controllers + operator-mode storage per size (§2.3), from confluent_operator_config.py
confluent_operator_size_presets = _operator_config.KRAFT_PRESETS

# Flink operator settings (§2.5), written only when the Flink operator source is not helm.
# FLINK_OLM_CHANNEL / FLINK_OLM_STARTING_CSV follow the CMF chart (CMF/FKO lock).
_fko_default = _operator_config.fko_for_cmf(catalog_value("confluent/operator/cmf_chart", default="2.5.0"))

default_flink_operator_olm = [
    {"key": "FLINK_OLM_PACKAGE", "value": "cp-fko"},
    {"key": "FLINK_OLM_SUBSCRIPTION_NAME", "value": "cp-fko"},
    {"key": "FLINK_OLM_CHANNEL", "value": _fko_default["channel"]},
    {"key": "FLINK_OLM_STARTING_CSV", "value": _fko_default["csv"]},
    {"key": "FLINK_OLM_CATALOG_SOURCE", "value": "certified-operators"},
    {"key": "FLINK_OLM_CATALOG_SOURCE_NAMESPACE", "value": "openshift-marketplace"},
    {"key": "FLINK_OLM_INSTALL_PLAN_APPROVAL", "value": "Manual"},
    {"key": "FLINK_CFK_NAMESPACE", "value": "${PROJECT_CONFLUENT_FLINK}"},
    {"key": "FLINK_CMF_RESTCLASS_NAME", "value": "default"},
    {"key": "FLINK_ENVIRONMENT_DELETE_WAIT", "value": "60"},
]

# Values operator mode writes instead of the scripts-mode defaults
operator_mode_overrides = {"CONFLUENT_SASL_MECHANISM": "PLAIN"}

flink_operator_mode_overrides = {
    "FLINK_CMF_CHART_VERSION": catalog_value("confluent/operator/cmf_chart", default="2.5.0"),
    "FLINK_SQL_IMAGE": catalog_value(
        "confluent/operator/flink_sql_image", default="confluentinc/cp-flink-sql:1.19-cmf2.5-cp1"
    ),
}


def records_with_overrides(records, overrides):
    """Copy of key/value rows with the values of ``overrides`` swapped in (same keys, same order)."""
    return [{"key": r["key"], "value": overrides.get(r["key"], r["value"])} for r in records]


def without_scram(mechanisms):
    """Comma list without SCRAM-* entries; PLAIN when nothing is left (operator mode, SASL impl plain)."""
    kept = [m.strip() for m in str(mechanisms or "").split(",") if m.strip() and not m.strip().upper().startswith("SCRAM-")]
    return ",".join(kept) or "PLAIN"
