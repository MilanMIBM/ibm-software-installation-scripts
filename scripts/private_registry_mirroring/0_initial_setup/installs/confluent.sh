#!/bin/zsh
# Segment 0 hook: confluent (contract: _template.sh)
#   prefill  from configs/confluent_platform_config/confluent_vars.sh: the
#            component toggles, auth add-ons and the Flink add-on
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done
if [[ -n "${PREG_NO_ENV:-}" ]]; then export _CP4D_REPO_ROOT="${_b}"; else source "${_b}/env_bootstrap.sh"; fi; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in
    components)
        cat >&3 <<'EOF'
component	broker	cp-server (KRaft broker + controller)
component	schema-registry	cp-schema-registry
component	connect	Kafka Connect (CONFLUENT_CONNECT_IMAGE)
component	ksqldb	cp-ksqldb-server
component	rest-proxy	cp-kafka-rest
component	control-center	C3 next-gen + its Prometheus and Alertmanager
component	c3-gateway	nginx auth gateway in front of C3 (CONFLUENT_AUTH_MODE=basic)
component	ldap	bundled OpenLDAP (CONFLUENT_MDS_USER_STORE=LDAP)
component	keycloak	bundled Keycloak (CONFLUENT_MDS_USER_STORE=OAUTH)
component	flink-operator	Flink Kubernetes operator chart + images
component	flink-cmf	Confluent Manager for Apache Flink chart + images
component	flink-runtime	FLINK_APPLICATION_IMAGE
component	flink-sql	FLINK_SQL_IMAGE
component	flink-cert-manager	upstream cert-manager manifest + images (only if the cluster has no cert-manager)
EOF
        ;;
    prefill)
        [[ -n "${PREG_NO_ENV:-}" ]] && exit 0
        comps=(broker)
        preg_is_true "${CONFLUENT_INSTALL_SCHEMA_REGISTRY:-false}" && comps+=(schema-registry)
        preg_is_true "${CONFLUENT_INSTALL_CONNECT:-false}" && comps+=(connect)
        preg_is_true "${CONFLUENT_INSTALL_KSQLDB:-false}" && comps+=(ksqldb)
        preg_is_true "${CONFLUENT_INSTALL_REST_PROXY:-false}" && comps+=(rest-proxy)
        if preg_is_true "${CONFLUENT_INSTALL_CONTROL_CENTER:-false}"; then
            comps+=(control-center)
            preg_is_true "${CONFLUENT_AUTH_ENABLED:-false}" && [[ "${CONFLUENT_AUTH_MODE:-openshift}" == basic ]] && comps+=(c3-gateway)
        fi
        if preg_is_true "${CONFLUENT_MDS_ENABLED:-false}"; then
            case "${(U)CONFLUENT_MDS_USER_STORE:-LDAP}" in
                LDAP)  comps+=(ldap) ;;
                OAUTH) comps+=(keycloak) ;;
            esac
        fi
        content="images"
        if [[ -n "${FLINK_CMF_CHART_VERSION:-}" ]]; then
            comps+=(flink-operator flink-cmf flink-runtime flink-sql)
            content="images,charts"
        fi
        print -r -- "MIRROR_CONFLUENT_COMPONENTS"$'\t'"${(j:,:)comps}" >&3
        print -r -- "MIRROR_CONFLUENT_CONTENT"$'\t'"${content}" >&3
        ;;
    *) preg_die "usage: $0 components|prefill" ;;
esac
exit 0
