# Customizable variables for configs/confluent_platform_config/confluent_vars.sh,
# mirroring 0_confluent_prepare_template_config.sh and
# install_confluent_platform_flink_addon/0_flink_prepare_template_config.sh.

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

confluent_sasl_mechanism_options = ["SCRAM-SHA-512", "SCRAM-SHA-256"]

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
    {"key": "CONFLUENT_VERSION", "value": "8.2.0"},
    {"key": "CONFLUENT_REGISTRY", "value": "docker.io/confluentinc"},
    {
        "key": "CONFLUENT_CONNECT_IMAGE",
        "value": "docker.io/cnfldemos/cp-server-connect-datagen:0.6.4-7.6.0",
    },
    {"key": "CONFLUENT_REGISTRY_USER", "value": ""},
    {"key": "CONFLUENT_REGISTRY_PASSWORD", "value": ""},
    {"key": "CONFLUENT_PULL_SECRET", "value": "confluent-registry"},
    {"key": "CONFLUENT_C3_VERSION", "value": "2.5.0"},
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
    {"key": "CONFLUENT_SASL_MECHANISM", "value": "SCRAM-SHA-512"},
    {"key": "CONFLUENT_SASL_ADMIN_USER", "value": "confluent-admin"},
    {"key": "CONFLUENT_SASL_CLIENTS", "value": "app-client"},  # comma-separated
    {"key": "CONFLUENT_SASL_SECRET", "value": "confluent-sasl"},
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
    {"key": "CONFLUENT_LDAP_IMAGE", "value": "docker.io/bitnamilegacy/openldap:2.6.10"},
    {"key": "CONFLUENT_LDAP_PORT", "value": "1389"},
    {"key": "CONFLUENT_LDAP_DOMAIN", "value": "confluent.io"},
    {"key": "CONFLUENT_LDAP_ADMIN_USER", "value": "admin"},
    {"key": "CONFLUENT_LDAP_SECRET", "value": "confluent-ldap"},
]

default_confluent_oauth = [
    {"key": "CONFLUENT_KEYCLOAK_IMAGE", "value": "quay.io/keycloak/keycloak:26.0"},
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
    {"key": "FLINK_CMF_CHART_VERSION", "value": "2.4.2"},
    {"key": "FLINK_OPERATOR_CHART_VERSION", "value": "1.150.3"},
    {"key": "FLINK_CMF_RELEASE_NAME", "value": "cmf"},
    {"key": "FLINK_OPERATOR_RELEASE_NAME", "value": "cp-flink-kubernetes-operator"},
]

default_flink_images = [
    {"key": "FLINK_IMAGE_REGISTRY", "value": ""},  # empty = chart default
    {"key": "FLINK_APPLICATION_IMAGE", "value": "confluentinc/cp-flink:2.0.2-cp3"},
    {"key": "FLINK_SQL_IMAGE", "value": "confluentinc/cp-flink-sql:1.19-cp11"},
    {"key": "FLINK_APPLICATION_VERSION", "value": "v2_0"},
    {"key": "FLINK_SQL_VERSION", "value": "v1_19"},
]

default_flink_cert_manager = [
    {"key": "FLINK_CERT_MANAGER_VERSION", "value": "v1.18.2"},
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
