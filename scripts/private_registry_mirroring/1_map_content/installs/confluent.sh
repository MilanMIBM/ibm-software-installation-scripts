#!/bin/zsh
# Segment 1 hook: confluent (contract: _template.sh)
#   images      per component, from confluent_vars.sh (defaults as in 1.1_confluent_install.sh)
#   charts      the two Flink charts (HTTP repo FLINK_HELM_REPO_URL) + the images they render
#   files       the upstream cert-manager manifest the Flink add-on applies
#   connectors  Kafka Connect ZIPs resolved through the Confluent Hub API (as
#               x.3_confluent_add_connector.sh does) from MIRROR_CONFLUENT_CONNECTORS_FILE
#   operators   operator mode: the CFK (cfk-operator) and cp-fko (flink-operator-olm)
#               OLM packages for the shared operators track; with images, cfk-operator
#               adds the CFK init container and (MIRROR_CONFLUENT_OPERATOR_DIGEST) the
#               docker.io confluent-operator image
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in map) ;; check) exit 0 ;; *) preg_die "usage: $0 map|check" ;; esac
COMPS="${MIRROR_CONFLUENT_COMPONENTS:-}"
CONTENT="${MIRROR_CONFLUENT_CONTENT:-}"
[[ -n "${COMPS}" && -n "${CONTENT}" ]] || exit 0
has() { preg_in_list "$1" "${CONTENT}"; }
comp() { preg_in_list "$1" "${COMPS}"; }

REG="${CONFLUENT_REGISTRY:-docker.io/confluentinc}"
CPV="${CONFLUENT_VERSION:-}"
C3V="${CONFLUENT_C3_VERSION:-$(vr_catalog confluent/c3_version)}"

if has images; then
    [[ -n "${CPV}" ]] || preg_die "CONFLUENT_VERSION is empty - generate configs/confluent_platform_config/confluent_vars.sh first"
    comp broker          && preg_emit_image "${CONFLUENT_BROKER_IMAGE:-${REG}/cp-server:${CPV}}" broker
    comp schema-registry && preg_emit_image "${REG}/cp-schema-registry:${CPV}" schema-registry
    comp connect         && preg_emit_image "${CONFLUENT_CONNECT_IMAGE:-${REG}/cp-server-connect:${CPV}}" connect
    comp ksqldb          && preg_emit_image "${REG}/cp-ksqldb-server:${CPV}" ksqldb
    comp rest-proxy      && preg_emit_image "${REG}/cp-kafka-rest:${CPV}" rest-proxy
    if comp control-center; then
        preg_emit_image "${CONFLUENT_CONTROL_CENTER_IMAGE:-${REG}/cp-enterprise-control-center-next-gen:${C3V}}" control-center
        preg_emit_image "${CONFLUENT_PROMETHEUS_IMAGE:-${REG}/cp-enterprise-prometheus:${C3V}}" control-center
        preg_emit_image "${CONFLUENT_ALERTMANAGER_IMAGE:-${REG}/cp-enterprise-alertmanager:${C3V}}" control-center
    fi
    comp c3-gateway && preg_emit_image "${CONFLUENT_C3_GATEWAY_IMAGE:-$(vr_catalog confluent/c3_gateway_image)}" c3-gateway
    comp ldap       && preg_emit_image "${CONFLUENT_LDAP_IMAGE:-$(vr_catalog confluent/ldap_image)}" ldap
    comp keycloak   && preg_emit_image "${CONFLUENT_KEYCLOAK_IMAGE:-$(vr_catalog confluent/keycloak_image)}" keycloak
    comp flink-runtime && preg_emit_image "${FLINK_APPLICATION_IMAGE:-$(vr_catalog flink/application_image)}" flink-runtime
    comp flink-sql     && preg_emit_image "${FLINK_SQL_IMAGE:-$(vr_catalog flink/sql_image)}" flink-sql
fi

# Operator mode (docs/confluent-operator-mode.md). A catalog value with a literal
# fallback, so a broken catalog never empties a channel or a tag.
_cat() { vr_catalog "$1" 2>/dev/null || print -r -- "$2"; }
# cp-fko channel FLINK_CMF_CHART_VERSION needs (the CMF/FKO lock the Flink scripts enforce).
_fko_channel() {
    local out
    if out="$(preg_python -I "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_config.py" fko-for-cmf "${FLINK_CMF_CHART_VERSION:-}" 2>/dev/null)" \
            && [[ -n "${out}" ]]; then
        print -r -- "${out%% *}"
        return 0
    fi
    out="$(_cat confluent/operator/fko_channel stable-v1.16)"
    preg_warn "flink-operator-olm: FLINK_CMF_CHART_VERSION='${FLINK_CMF_CHART_VERSION:-}' has no cp-fko pairing in the version catalog - mirroring channel ${out} (set FLINK_OLM_CHANNEL to choose)" >&2
    print -r -- "${out}"
}

# OLM packages: the shared operators track mirrors the catalog index, the bundles and
# their relatedImages; 3.4 renames the mirrored catalogs back, so the Subscriptions
# keep source certified-operators.
# K8S-EXTENSION(K8): a Kubernetes (no OLM) variant would emit the CFK / cp-fko Helm charts here instead.
if has operators; then
    comp cfk-operator && preg_emit_operator "${CONFLUENT_OPERATOR_CATALOG_SOURCE:-certified-operators}" \
        confluent-for-kubernetes "${CONFLUENT_OPERATOR_CHANNEL:-$(_cat confluent/operator/cfk_channel 3.4)}" cfk-operator
    comp flink-operator-olm && preg_emit_operator "${FLINK_OLM_CATALOG_SOURCE:-certified-operators}" \
        cp-fko "${FLINK_OLM_CHANNEL:-$(_fko_channel)}" flink-operator-olm
fi

# CFK images outside the bundle: the init container every CR names (tags mode), and the
# operator image itself, which the CSV runs from docker.io by digest (V17: whether
# oc-mirror carries it through relatedImages is unverified). The digest cannot be
# derived offline - see MIRROR_CONFLUENT_OPERATOR_DIGEST in the mirror config.
if has images && comp cfk-operator; then
    preg_emit_image "${CONFLUENT_OPERATOR_INIT_IMAGE:-${REG}/confluent-init-container:$(_cat confluent/operator/cfk_init_tag 3.4.0)}" cfk-operator
    if [[ -n "${MIRROR_CONFLUENT_OPERATOR_DIGEST:-}" ]]; then
        dg="${MIRROR_CONFLUENT_OPERATOR_DIGEST}"
        [[ "${dg}" == sha256:* ]] || dg="sha256:${dg}"
        [[ "${dg}" =~ '^sha256:[0-9a-f]{64}$' ]] \
            || preg_die "MIRROR_CONFLUENT_OPERATOR_DIGEST='${MIRROR_CONFLUENT_OPERATOR_DIGEST}' is not a sha256 digest (64 hex characters)"
        preg_emit_image "docker.io/confluentinc/confluent-operator@${dg}" cfk-operator
    else
        preg_info "cfk-operator: MIRROR_CONFLUENT_OPERATOR_DIGEST is empty - docker.io/confluentinc/confluent-operator is left to oc-mirror (bundle relatedImages, unverified). Read the digest from the CSV: oc get csv <cfk csv> -n <ns> -o jsonpath='{.spec.install.spec.deployments[0].spec.template.spec.containers[0].image}'" >&2
    fi
fi

# Flink charts: the chart itself (charts) and every image it renders (images).
flink_chart() {   # <component> <chart> <version>
    local c="$1" chart="$2" ver="$3" repo="${FLINK_HELM_REPO_URL:-https://packages.confluent.io/helm}" img
    [[ -n "${ver}" ]] || { preg_warn "${c}: no chart version in confluent_vars.sh (run the Flink 0_ template step) - skipped"; return 0; }
    has charts && preg_emit_chart "${repo}" "${chart}" "${ver}" "${c}"
    if has images; then
        local found=0
        for img in $(preg_chart_images "${c}" "${chart}" --repo "${repo}" --version "${ver}"); do
            preg_emit_image "${img}" "${c}"
            (( found += 1 ))
        done
        (( found )) || preg_warn "${c}: 'helm template ${chart} ${ver}' rendered no images (repo reachable?)"
    fi
}
comp flink-operator && flink_chart flink-operator flink-kubernetes-operator "${FLINK_OPERATOR_CHART_VERSION:-}"
comp flink-cmf      && flink_chart flink-cmf confluent-manager-for-apache-flink "${FLINK_CMF_CHART_VERSION:-}"

if comp flink-cert-manager; then
    cmv="${FLINK_CERT_MANAGER_VERSION:-$(vr_catalog flink/cert_manager_version)}"
    has files && preg_emit_file "https://github.com/cert-manager/cert-manager/releases/download/${cmv}/cert-manager.yaml" "flink/cert-manager-${cmv}.yaml" flink-cert-manager
    if has images; then
        for n in controller webhook cainjector; do
            preg_emit_image "quay.io/jetstack/cert-manager-${n}:${cmv}" flink-cert-manager
        done
    fi
fi

# Connectors: owner/name[:version] lines (Hub coordinates); URLs to ZIP/JAR files
# are taken as given; local paths are already offline and skipped.
if has connectors; then
    f="${MIRROR_CONFLUENT_CONNECTORS_FILE:-}"
    [[ -n "${f}" && -f "${f}" ]] || preg_die "connectors selected but MIRROR_CONFLUENT_CONNECTORS_FILE is not a file: '${f}'"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%#*}"; src="${${=line}[1]:-}"
        [[ -n "${src}" ]] || continue
        case "${src}" in
            http://*|https://*)
                preg_emit_file "${src}" "connectors/${src:t}" connectors ;;
            ./*|/*|*.zip|*.jar)
                preg_info "connector ${src}: local file, nothing to download" >&2 ;;
            */*)
                coord="${src}" ver=""
                [[ "${coord}" == *:* ]] && { ver="${coord#*:}"; coord="${coord%%:*}"; }
                api="https://api.hub.confluent.io/api/plugins/${coord}"
                [[ -n "${ver}" && "${ver}" != latest ]] && api+="/versions/${ver}"
                url="$(curl -sfL --retry 2 "${api}" 2>/dev/null | preg_python -c 'import json,sys
try: print((json.load(sys.stdin).get("archive") or {}).get("url") or "")
except Exception: print("")' || true)"
                if [[ -n "${url}" ]]; then
                    preg_emit_file "${url}" "connectors/${url:t}" connectors
                else
                    preg_warn "connector ${src}: no archive URL from the Confluent Hub API (${api})"
                fi ;;
            *) preg_warn "connector line not understood: ${line}" ;;
        esac
    done < "${f}"
fi
exit 0
