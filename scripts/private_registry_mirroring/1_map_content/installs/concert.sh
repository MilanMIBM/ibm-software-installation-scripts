#!/bin/zsh
# Segment 1 hook: concert (contract: _template.sh)
#   ibm-images        native: Concert's own 1_registry_access_and_mirroring/1.1 mirrors
#                     IBM's images.lst in IBM's cp/<suffix> layout (2_download_and_mirror)
#   operators         Service Mesh 3 (istio), CloudNativePG (ds-postgres), ODF (ds-odf) - shared
#   datastore-images  CONCERT_DS_*_IMAGE of the selected data stores
#   runner-image      the installer runner's UBI base (shared)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in map) ;; check) exit 0 ;; *) preg_die "usage: $0 map|check" ;; esac
COMPS="${MIRROR_CONCERT_COMPONENTS:-}"
CONTENT="${MIRROR_CONCERT_CONTENT:-}"
[[ -n "${COMPS}" && -n "${CONTENT}" ]] || exit 0
has() { preg_in_list "$1" "${CONTENT}"; }
comp() { preg_in_list "$1" "${COMPS}"; }

if has ibm-images; then
    products=()
    for p in hub concert dataapps workflows securecoder itom; do comp "${p}" && products+=("${p}"); done
    if (( ${#products} )); then
        preg_emit_native concert-1.1 "IBM Concert ${CONCERT_VERSION:-?} images (${(j:,:)products}) via Concert's 1.1_mirror_concert_images.sh" \
            "\"products\":$(_preg_json "${(j:,:)products}"),\"version\":$(_preg_json "${CONCERT_VERSION:-}")"
    fi
fi

if has operators; then
    comp istio && preg_emit_operator redhat-operators servicemeshoperator3 "${CONCERT_ISTIO_CHANNEL:-stable}" istio
    if comp ds-postgres; then
        # Concert 1.2: CloudNativePG is certified on OCP >= 4.21, community before that.
        preg_emit_operator "${CONCERT_DS_PG_OPERATOR_SOURCE:-certified-operators}" cloudnative-pg \
            "${CONCERT_DS_PG_OPERATOR_CHANNEL:-stable-v1}" ds-postgres
    fi
    if comp ds-odf; then
        # oc-mirror does not resolve operator dependencies: the whole ODF set
        # (Concert 1.2's list + odf-external-snapshotter-operator, seen on OCP 4.20).
        for p in ${=CONCERT_MIRROR_ODF_PACKAGES:-odf-operator ocs-operator mcg-operator odf-csi-addons-operator ocs-client-operator odf-prometheus-operator recipe rook-ceph-operator cephcsi-operator odf-dependencies odf-external-snapshotter-operator}; do
            preg_emit_operator redhat-operators "${p}" "${MIRROR_OCP_MINOR:+stable-${MIRROR_OCP_MINOR}}" ds-odf
        done
    fi
fi

if has datastore-images; then
    comp ds-postgres && preg_emit_image "${CONCERT_DS_PG_IMAGE:-}" ds-postgres
    comp ds-mysql    && preg_emit_image "${CONCERT_DS_MYSQL_IMAGE:-}" ds-mysql
    comp ds-redis    && preg_emit_image "${CONCERT_DS_REDIS_IMAGE:-}" ds-redis
    comp ds-neo4j    && preg_emit_image "${CONCERT_DS_NEO4J_IMAGE:-}" ds-neo4j
fi

if has runner-image && comp runner; then
    preg_emit_image "${CONCERT_RUNNER_BASE_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}" runner shared
fi
exit 0
