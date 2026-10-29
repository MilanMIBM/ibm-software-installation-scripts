#!/bin/zsh
# Copy to configs/confluent_platform_config/iceberg_watsonx_setup.sh (Git-ignored).
# The integration expects an existing COS-backed Iceberg catalog in watsonx.data.

export ICEBERG_CONNECTOR_NAME="iceberg-sink"
export ICEBERG_SERVICE_ID="svc-iceberg"
export ICEBERG_KAFKA_TOPIC="<KAFKA_TOPIC>"
export ICEBERG_TABLE="<SCHEMA>.<TABLE>"
export ICEBERG_WATSONX_CATALOG="<WATSONX_DATA_CATALOG>"
export ICEBERG_WATSONX_REST_URI="https://<WATSONX_DATA_MDS_REST_HOST>/api/v1/iceberg"
export ICEBERG_WATSONX_INSTANCE="lakehouse"

export ICEBERG_COS_ENDPOINT="https://s3.<COS_REGION>.cloud-object-storage.appdomain.cloud"
export ICEBERG_COS_REGION="<COS_REGION>"
export ICEBERG_COS_ACCESS_KEY_ID="<COS_HMAC_ACCESS_KEY_ID>"
export ICEBERG_COS_SECRET_ACCESS_KEY="<COS_HMAC_SECRET_ACCESS_KEY>"
export ICEBERG_COS_PATH_STYLE_ACCESS="false"

export ICEBERG_SCHEMA_REGISTRY_URL="http://schema-registry:8081"
export ICEBERG_PLUGIN_SOURCE="iceberg/iceberg-kafka-connect:1.9.2"
export ICEBERG_COMMIT_INTERVAL_MS="300000"
export ICEBERG_VERIFY_TLS="true"
export ICEBERG_APPLY_CONNECTOR="true"

# CPD admin credentials come from the usual cpd_instance_details.sh; they grant
# the role but are never used as the running connector's identity.
# export ICEBERG_CPD_DETAILS_FILE="/path/to/cpd_instance_details.sh"
# SID creation loads this CPD config in an isolated kubeconfig. Keep it paired
# with the Software Hub credentials above when the platforms use separate clusters.
export ICEBERG_CPD_ENV_TARGET="cpd"

# Existing identities can supply their password through the environment. With
# this set, an unsuccessful sign-in fails without creating or repairing an SID.
# export ICEBERG_SERVICE_PASSWORD="<EXISTING_SID_PASSWORD>"

# Generated credentials-bearing JSON must stay inside the repository and ignored.
# export ICEBERG_OUTPUT_FILE="${CONFLUENT_CONFIG_DIR}/iceberg-sink.json"
