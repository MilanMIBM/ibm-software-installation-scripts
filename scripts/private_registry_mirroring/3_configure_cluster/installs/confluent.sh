#!/bin/zsh
# Segment 3 hook: confluent (contract: _template.sh)
#   tap             configs/confluent_platform_config/registry_overrides.sh:
#                   - explicit redirect: CONFLUENT_REGISTRY + every image variable
#                     the install scripts read, pointing at <pull root>/confluent
#                     (or <pull root>/shared for declared images); pull credentials
#                     (1.0_confluent_prep.sh makes the pull secret from them)
#                   - always: Flink charts from oci://<push root>/confluent/charts
#                     (FLINK_CHART_SOURCE=oci + chart refs), the cert-manager
#                     manifest from the workspace, helm registry login (push host)
#   verify-cluster  every pod image in the Confluent namespace comes from the registry
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

PULL_PREFIX="${MIRROR_INSTALL_PULL_PREFIX:?no registry configured}"
PUSH_PREFIX="${MIRROR_INSTALL_PUSH_PREFIX:?no registry configured}"
REG="${CONFLUENT_REGISTRY:-docker.io/confluentinc}"
CPV="${CONFLUENT_VERSION:-}"
C3V="${CONFLUENT_C3_VERSION:-2.5.0}"

case "${1:-}" in
tap)
    body="$(preg_private_tmpdir)/body"
    : > "${body}"
    emit() { print -r -- "$1" >> "${body}"; }
    # <VAR> <original source>: point VAR at where 1.0 put it (skipped when unmapped)
    img() {
        local v="$1" src="$2" ref
        [[ -n "${src}" ]] || return 0
        if ref="$(preg_lookup_pull "${src}")"; then emit "export ${v}=$(preg_q "${ref}")"; fi
        return 0
    }
    emit "export CONFLUENT_IMAGE_SOURCE=$(preg_q "${MIRROR_RESOLVED_IMAGE_SOURCE:-private}")"
    if preg_redirect_explicit; then
        broker="${CONFLUENT_BROKER_IMAGE:-${REG}/cp-server:${CPV}}"
        if ref="$(preg_lookup_pull "${broker}")"; then
            # 1.1 builds cp-schema-registry / cp-kafka-rest / cp-ksqldb-server from CONFLUENT_REGISTRY.
            emit "export CONFLUENT_REGISTRY=$(preg_q "${${ref%:*}:h}")"
        fi
        emit "export CONFLUENT_REGISTRY_USER=$(preg_q "${MIRROR_REGISTRY_PULL_USER:-}")"
        emit "export CONFLUENT_REGISTRY_PASSWORD=$(preg_q "${MIRROR_REGISTRY_PULL_PASSWORD:-}")"
        img CONFLUENT_BROKER_IMAGE "${broker}"
        img CONFLUENT_CONNECT_IMAGE "${CONFLUENT_CONNECT_IMAGE:-}"
        img CONFLUENT_CONTROL_CENTER_IMAGE "${CONFLUENT_CONTROL_CENTER_IMAGE:-${REG}/cp-enterprise-control-center-next-gen:${C3V}}"
        img CONFLUENT_PROMETHEUS_IMAGE "${CONFLUENT_PROMETHEUS_IMAGE:-${REG}/cp-enterprise-prometheus:${C3V}}"
        img CONFLUENT_ALERTMANAGER_IMAGE "${CONFLUENT_ALERTMANAGER_IMAGE:-${REG}/cp-enterprise-alertmanager:${C3V}}"
        img CONFLUENT_C3_GATEWAY_IMAGE "${CONFLUENT_C3_GATEWAY_IMAGE:-registry.access.redhat.com/ubi9/nginx-124:latest}"
        img CONFLUENT_LDAP_IMAGE "${CONFLUENT_LDAP_IMAGE:-docker.io/bitnamilegacy/openldap:2.6.10}"
        img CONFLUENT_KEYCLOAK_IMAGE "${CONFLUENT_KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.0}"
        img FLINK_APPLICATION_IMAGE "${FLINK_APPLICATION_IMAGE:-}"
        img FLINK_SQL_IMAGE "${FLINK_SQL_IMAGE:-}"
        # The Flink charts take a repository prefix for their own images.
        for src in $(cut -f1 "${MIRROR_INSTALL_WORKDIR}/targets.tsv" 2>/dev/null | grep -E '/cp-flink-kubernetes-operator[:@]' || true); do
            if ref="$(preg_lookup_pull "${src}")"; then emit "export FLINK_IMAGE_REGISTRY=$(preg_q "${${ref%:*}:h}")"; fi
        done
    fi
    # Charts: helm runs on this workstation -> push side.
    charts="${MIRROR_INSTALL_WORKDIR}/charts.tsv"
    if [[ -s "${charts}" ]]; then
        emit "export FLINK_CHART_SOURCE=oci"
        while IFS=$'\t' read -r _src chart _ver rel_dir _rest; do
            case "${chart}" in
                flink-kubernetes-operator) emit "export FLINK_OPERATOR_CHART_REF=$(preg_q "oci://$(preg_push_root)/${rel_dir}/${chart}")" ;;
                confluent-manager-for-apache-flink) emit "export FLINK_CMF_CHART_REF=$(preg_q "oci://$(preg_push_root)/${rel_dir}/${chart}")" ;;
            esac
        done < "${charts}"
    fi
    cms=("${MIRROR_INSTALL_WORKDIR}"/files/flink/cert-manager-*.yaml(N))
    (( ${#cms} )) && emit "export FLINK_CERT_MANAGER_MANIFEST=$(preg_q "${cms[1]}")"
    preg_write_overrides confluent "${body}"
    if [[ -s "${charts}" ]] && ! preg_is_true "${MIRROR_TAP_DRY_RUN:-false}"; then
        tls=()
        [[ -n "${MIRROR_REGISTRY_CA_FILE:-}" ]] && tls=(--ca-file "${MIRROR_REGISTRY_CA_FILE}")
        print -r -- "${MIRROR_REGISTRY_PULL_PASSWORD}" | helm registry login "$(preg_registry_host "$(preg_push_root)")" \
            -u "${MIRROR_REGISTRY_PULL_USER}" --password-stdin "${tls[@]}" >/dev/null \
            && preg_info "confluent: helm logged in to $(preg_registry_host "$(preg_push_root)") for the Flink charts"
    fi
    conns=("${MIRROR_INSTALL_WORKDIR}"/files/connectors/*(N))
    (( ${#conns} )) && preg_info "confluent: connector ZIPs for x.3_confluent_add_connector.sh: ${MIRROR_INSTALL_WORKDIR}/files/connectors/"
    ;;
verify-cluster)
    preg_redirect_explicit || exit 0
    ns="${PROJECT_CONFLUENT_SERVER:-}"
    [[ -n "${ns}" ]] && oc get ns "${ns}" >/dev/null 2>&1 || { preg_info "confluent: not installed - nothing to check"; exit 0; }
    bad="$(oc get pods -n "${ns}" -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
        | sort -u | grep -v -E "^(${PULL_PREFIX}|$(preg_pull_root)/$(preg_install_path shared)|image-registry\.openshift-image-registry\.svc)" || true)"
    if [[ -n "${bad}" ]]; then
        print -r -- "${bad}" | sed 's/^/  NOT FROM THE REGISTRY  /'
        preg_die "confluent: pods use images outside the registry (re-run 3.5, then the Confluent install scripts)"
    fi
    preg_info "confluent: every pod image comes from the registry"
    ;;
*) exit 0 ;;
esac

exit 0
