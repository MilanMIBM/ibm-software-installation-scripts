#!/bin/zsh
# Segment 3 hook: datastax_mc (contract: _template.sh)
#   tap             configs/datastax_mc_config/registry_overrides.sh:
#                   MC_IMAGE_SOURCE, MC_CHART=oci://<push root>/datastax-mc/... (helm runs
#                   here), MC_PRIVATE_REGISTRY_* (1.2 builds <release>-registry from
#                   them), and - explicit redirect - mc-values-registry.yaml appended to
#                   MC_EXTRA_VALUES_FILES: DataStax's documented air-gap keys
#                   (global.imageConfig.overrides.registry, image.registry, ...) pointing
#                   at <pull root>/datastax-mc, repositories kept as mirrored
#   verify-cluster  every pod image in MC_NAMESPACE comes from the registry
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

PULL_PREFIX="${MIRROR_INSTALL_PULL_PREFIX:?no registry configured}"

case "${1:-}" in
tap)
    CFGDIR="${DATASTAX_MC_CONFIG_DIR:?}"
    VALUES="${CFGDIR}/mc-values-registry.yaml"
    body="$(preg_private_tmpdir)/body"
    : > "${body}"
    emit() { print -r -- "$1" >> "${body}"; }
    emit "export MC_IMAGE_SOURCE=$(preg_q "${MIRROR_RESOLVED_IMAGE_SOURCE:-private}")"
    charts="${MIRROR_INSTALL_WORKDIR}/charts.tsv"
    if [[ -s "${charts}" ]]; then
        rel_dir="$(awk -F'\t' '$2 == "mission-control" { print $4; exit }' "${charts}")"
        [[ -n "${rel_dir}" ]] && emit "export MC_CHART=$(preg_q "oci://$(preg_push_root)/${rel_dir}/mission-control")"
    fi
    emit "export MC_PRIVATE_REGISTRY_HOST=$(preg_q "$(preg_registry_host "$(preg_pull_root)")")"
    emit "export MC_PRIVATE_REGISTRY_USER=$(preg_q "${MIRROR_REGISTRY_PULL_USER:-}")"
    emit "export MC_PRIVATE_REGISTRY_PASSWORD=$(preg_q "${MIRROR_REGISTRY_PULL_PASSWORD:-}")"
    if preg_redirect_explicit; then
        R="${PULL_PREFIX}"
        values_body="$(preg_private_tmpdir)/values"
        cat > "${values_body}" <<EOF
# Written by scripts/private_registry_mirroring/3_configure_cluster/3.5_point_installs_at_registry.sh
# DataStax's documented air-gap overrides, pointed at ${R}
# (repositories kept as the mirroring track laid them out). Loaded through
# MC_EXTRA_VALUES_FILES (registry_overrides.sh), after the repo's own values.
global:
  imageConfig:
    overrides:
      registry: "${R}"
  imagePullSecrets:
    - name: "${MC_PULL_SECRET_NAME:-${MC_RELEASE_NAME:-mission-control}-registry}"
image:
  registry: "${R}"
client:
  image:
    registry: "${R}"
ui:
  image:
    registry: "${R}"
aggregator:
  image:
    repository: "${R}/timberio/vector"
k8ssandra-operator:
  image:
    registry: "${R}"
  cass-operator:
    image:
      registry: "${R}"
dex:
  image:
    repository: "${R}/datastax-mission-control/mission-control-dex"
kube-state-metrics:
  image:
    registry: "${R}"
loki:
  global:
    image:
      registry: "${R}"
  image:
    registry: "${R}"
  gateway:
    image:
      registry: "${R}"
  sidecar:
    image:
      registry: "${R}"
mimir:
  image:
    repository: "${R}/grafana/mimir"
  gateway:
    nginx:
      image:
        registry: "${R}"
  # in-cluster object store (MC_OBSERVABILITY_STORE=minio) - not in DataStax's
  # air-gap page; keys found in chart 1.21.2's values
  minio:
    image:
      repository: "${R}/pgsty/silo"
    mcImage:
      repository: "${R}/pgsty/mc"
EOF
        if preg_is_true "${MIRROR_TAP_DRY_RUN:-false}"; then
            preg_info "[dry-run] ${VALUES#${_CP4D_REPO_ROOT}/} would be:"
            sed 's/^/    /' "${values_body}"
        else
            cp "${values_body}" "${VALUES}"
            chmod 600 "${VALUES}"
            preg_info "datastax_mc: wrote ${VALUES#${_CP4D_REPO_ROOT}/}"
        fi
        # MC_EXTRA_VALUES_FILES is a space-separated list (2.0_render_values.sh), so
        # the path is used as is; it is appended once, after the config's own files.
        emit "# mc-values-registry.yaml goes last (once), after any values the config lists"
        emit "case \" \${MC_EXTRA_VALUES_FILES:-} \" in *\" ${VALUES} \"*) ;; *) export MC_EXTRA_VALUES_FILES=\"\${MC_EXTRA_VALUES_FILES:+\${MC_EXTRA_VALUES_FILES} }${VALUES}\" ;; esac"
    fi
    preg_write_overrides datastax_mc "${body}"
    if [[ -s "${charts}" ]] && ! preg_is_true "${MIRROR_TAP_DRY_RUN:-false}"; then
        tls=()
        [[ -n "${MIRROR_REGISTRY_CA_FILE:-}" ]] && tls=(--ca-file "${MIRROR_REGISTRY_CA_FILE}")
        print -r -- "${MIRROR_REGISTRY_PULL_PASSWORD}" | helm registry login "$(preg_registry_host "$(preg_push_root)")" \
            -u "${MIRROR_REGISTRY_PULL_USER}" --password-stdin "${tls[@]}" >/dev/null \
            && preg_info "datastax_mc: helm logged in to $(preg_registry_host "$(preg_push_root)") for the chart"
    fi
    ;;
verify-cluster)
    preg_redirect_explicit || exit 0
    ns="${MC_NAMESPACE:-mission-control}"
    oc get ns "${ns}" >/dev/null 2>&1 || { preg_info "datastax_mc: not installed - nothing to check"; exit 0; }
    # DataStax's own check: any image not under the registry is a leak.
    bad="$(oc get pods -n "${ns}" -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
        | sort -u | grep -v -E "^(${PULL_PREFIX}|$(preg_pull_root)/$(preg_install_path shared))/" || true)"
    if [[ -n "${bad}" ]]; then
        print -r -- "${bad}" | sed 's/^/  NOT FROM THE REGISTRY  /'
        preg_warn "datastax_mc: these images are redirected by the mirror sets only (3.3) - fine with MIRROR_CLUSTER_REDIRECT=both"
    else
        preg_info "datastax_mc: every pod image comes from the registry"
    fi
    ;;
*) exit 0 ;;
esac

exit 0
