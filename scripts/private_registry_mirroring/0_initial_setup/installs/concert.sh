#!/bin/zsh
# Segment 0 hook: concert (contract: _template.sh)
#   prefill  from configs/concert_config/concert_vars.sh, with the same product
#            and data-store logic Concert's own scripts use (concert_helpers.sh)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done
if [[ -n "${PREG_NO_ENV:-}" ]]; then export _CP4D_REPO_ROOT="${_b}"; else source "${_b}/env_bootstrap.sh"; fi; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in
    components)
        cat >&3 <<'EOF'
component	hub	IBM Concert Hub (platform-hub)
component	concert	IBM Concert
component	dataapps	Concert Data Apps
component	workflows	Concert Workflows
component	securecoder	Concert Secure Coder
component	itom	ITOM cross-product integration
component	istio	Service Mesh 3 for Workflows (operator, shared)
component	ds-postgres	CloudNativePG operator (shared) + Postgres image
component	ds-mysql	MySQL image
component	ds-redis	Redis image
component	ds-neo4j	Neo4j image
component	ds-odf	ODF / Multicloud Object Gateway operators (shared)
component	runner	installer runner base image (shared)
EOF
        ;;
    prefill)
        [[ -n "${PREG_NO_ENV:-}" ]] && exit 0
        source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
        comps=()
        for p in hub concert dataapps workflows securecoder itom istio; do
            concert_product_enabled "${p}" && comps+=("${p}")
        done
        concert_ds_server_provisioned POSTGRES && comps+=(ds-postgres)
        concert_ds_server_provisioned MYSQL && comps+=(ds-mysql)
        concert_ds_server_provisioned REDIS && comps+=(ds-redis)
        concert_ds_server_provisioned NEO4J && comps+=(ds-neo4j)
        concert_ds_server_provisioned S3 && comps+=(ds-odf)
        [[ "${CONCERT_RUNNER:-cluster}" == cluster ]] || comps+=(runner)
        print -r -- "MIRROR_CONCERT_COMPONENTS"$'\t'"${(j:,:)comps}" >&3
        print -r -- "MIRROR_CONCERT_CONTENT"$'\t'"ibm-images,operators,datastore-images,runner-image" >&3
        [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]] && print -r -- "MIRROR_IBM_ENTITLEMENT_KEY"$'\t'"${IBM_ENTITLEMENT_KEY}" >&3
        if [[ "${CONCERT_IMAGE_SOURCE:-entitled}" != entitled && -n "${PRIVATE_REGISTRY_LOCATION:-}" ]]; then
            print -r -- "MIRROR_REGISTRY_ROOT"$'\t'"${PRIVATE_REGISTRY_LOCATION}" >&3
            [[ -n "${PRIVATE_REGISTRY_PUSH_USER:-}" ]] && print -r -- "MIRROR_REGISTRY_PUSH_USER"$'\t'"${PRIVATE_REGISTRY_PUSH_USER}" >&3
            [[ -n "${PRIVATE_REGISTRY_PUSH_PASSWORD:-}" ]] && print -r -- "MIRROR_REGISTRY_PUSH_PASSWORD"$'\t'"${PRIVATE_REGISTRY_PUSH_PASSWORD}" >&3
            [[ -n "${CONCERT_REDHAT_PULL_SECRET_FILE:-}" ]] && print -r -- "MIRROR_REDHAT_PULL_SECRET_FILE"$'\t'"${CONCERT_REDHAT_PULL_SECRET_FILE}" >&3
        fi
        :
        ;;
    *) preg_die "usage: $0 components|prefill" ;;
esac
exit 0
