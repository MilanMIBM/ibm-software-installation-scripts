#!/bin/zsh
# Segment 0 hook: datastax_mc (contract: _template.sh)
#   prefill  from configs/datastax_mc_config/datastax_mc_vars.sh: the plane
#            (control/data) and what the 3.x post-install scripts create
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done
if [[ -n "${PREG_NO_ENV:-}" ]]; then export _CP4D_REPO_ROOT="${_b}"; else source "${_b}/env_bootstrap.sh"; fi; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in
    components)
        cat >&3 <<'EOF'
component	control-plane	Mission Control control plane (chart rendered with the repo's values)
component	data-plane	data plane only (MC_PLANE=data)
component	hcd	HCD server images (MIRROR_DATASTAX_MC_HCD_VERSIONS; empty = the newest MIRROR_DATASTAX_MC_HCD_LATEST)
component	dse	DSE server images (MIRROR_DATASTAX_MC_DSE_VERSIONS)
component	data-api	Stargate Data API (3.2_create_data_api.sh)
component	cql-gateway	CQL router (3.3_create_cql_gateway.sh)
component	cqlsh	cqlsh pod used by Mission Control
component	k8ssandra-client	k8ssandra-client (cluster registration, upgrades)
EOF
        ;;
    prefill)
        [[ -n "${PREG_NO_ENV:-}" ]] && exit 0
        comps=()
        [[ "${MC_PLANE:-control}" == data ]] && comps+=(data-plane) || comps+=(control-plane)
        comps+=(hcd data-api cql-gateway cqlsh k8ssandra-client)
        print -r -- "MIRROR_DATASTAX_MC_COMPONENTS"$'\t'"${(j:,:)comps}" >&3
        print -r -- "MIRROR_DATASTAX_MC_CONTENT"$'\t'"chart,images" >&3
        [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]] && print -r -- "MIRROR_IBM_ENTITLEMENT_KEY"$'\t'"${IBM_ENTITLEMENT_KEY}" >&3
        :
        ;;
    *) preg_die "usage: $0 components|prefill" ;;
esac
exit 0
