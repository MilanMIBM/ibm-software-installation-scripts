#!/bin/zsh
# Segment 0 hook: confluent (contract: _template.sh)
#   prefill  from configs/confluent_platform_config/confluent_vars.sh: the
#            component toggles, auth add-ons and the Flink add-on. Operator mode
#            (CONFLUENT_DEPLOY_MODE, docs/confluent-operator-mode.md) adds
#            cfk-operator, swaps flink-operator for flink-operator-olm when the
#            Flink operator source is olm, and adds the "operators" content kind.
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
component	cfk-operator	Confluent for Kubernetes operator (operator mode): OLM bundle via the shared operators track, init container, confluent-operator image
component	flink-operator	Flink Kubernetes operator chart + images
component	flink-operator-olm	cp-fko Flink operator (FLINK_OPERATOR_SOURCE=olm): OLM bundle via the shared operators track
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
        # Operator mode: the resolvers of confluent_helpers.sh read the loaded vars
        # (unset CONFLUENT_DEPLOY_MODE = operator). Scripts mode adds nothing here.
        source "${_CP4D_REPO_ROOT}/src/helpers/confluent_helpers.sh"
        # CFK: the platform in operator mode, and the Flink namespace when CMF
        # resources are CFK CRs (FLINK_CMF_RESOURCE_MODE=cfk) - same rule as
        # confluent_operator_config.plan_operator_targets.
        if cf_is_operator_mode \
            || { [[ -n "${FLINK_CMF_CHART_VERSION:-}" ]] && [[ "$(cf_flink_cmf_resource_mode)" == cfk ]]; }; then
            comps+=(cfk-operator)
        fi
        content="images"
        if [[ -n "${FLINK_CMF_CHART_VERSION:-}" ]]; then
            # helm: the operator chart; olm: the cp-fko bundle; existing: already on the cluster.
            case "$(cf_flink_operator_source)" in
                helm) comps+=(flink-operator) ;;
                olm)  comps+=(flink-operator-olm) ;;
            esac
            comps+=(flink-cmf flink-runtime flink-sql)
            content="images,charts"
        fi
        (( ${comps[(Ie)cfk-operator]} + ${comps[(Ie)flink-operator-olm]} )) && content+=",operators"
        print -r -- "MIRROR_CONFLUENT_COMPONENTS"$'\t'"${(j:,:)comps}" >&3
        print -r -- "MIRROR_CONFLUENT_CONTENT"$'\t'"${content}" >&3
        ;;
    *) preg_die "usage: $0 components|prefill" ;;
esac
exit 0
