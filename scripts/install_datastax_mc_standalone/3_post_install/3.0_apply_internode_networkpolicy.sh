#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
mc_require_config

usage() {
    cat <<'EOF'
Restrict the database internode ports (7000/7001) to database pods.

DataStax requires this NetworkPolicy isolation when the database shares the
OpenShift cluster with other applications. In each Mission Control project
namespace it applies NetworkPolicy "mc-cassandra-internode", selecting the
database pods (label cassandra.datastax.com/cluster):
  - TCP 7000/7001 only from database pods (any namespace, so a datacenter in
    another project can still gossip) and from --allow-cidr ranges
  - every other port stays open as before
Run it after creating a project in the UI; safe to re-run.

  3.0_apply_internode_networkpolicy.sh [NAMESPACE ...] [options]

  NAMESPACE           Default: every namespace labelled
                      mission-control.datastax.com/is-project=true
  --allow-cidr CIDR   Also allow 7000/7001 from this range (repeatable): the pod
                      CIDRs of other clusters in a multi-cluster deployment
  --remove            Delete the policy instead
  --dry-run           Print the policy, change nothing
  -h, --help          Show this help

Internode TLS is a database setting (MissionControlCluster spec), not part of
this script; DataStax requires it as well on shared clusters.
EOF
}

NAMESPACES=()
CIDRS=()
REMOVE=false
DRY_RUN=false
while (( $# )); do
    case "$1" in
        --allow-cidr) CIDRS+=("${2:?--allow-cidr needs a CIDR}"); shift 2 ;;
        --remove)     REMOVE=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           mc_die "Unknown option: $1" ;;
        *)            NAMESPACES+=("$1"); shift ;;
    esac
done

eval "${OC_LOGIN}"

if (( ${#NAMESPACES} == 0 )); then
    NAMESPACES=("${(@f)$(oc get namespaces -l mission-control.datastax.com/is-project=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')}")
    NAMESPACES=(${NAMESPACES:#})
    (( ${#NAMESPACES} )) || mc_die "No Mission Control project namespaces found - create a project first, or name the namespaces."
fi

POLICY="mc-cassandra-internode"

policy_yaml() {
    local ns="$1" cidr
    cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${POLICY}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
spec:
  podSelector:
    matchExpressions:
      - {key: cassandra.datastax.com/cluster, operator: Exists}
  policyTypes: [Ingress]
  ingress:
    # Every port except 7000/7001, from anywhere (unchanged behaviour)
    - ports:
        - {protocol: TCP, port: 1, endPort: 6999}
        - {protocol: TCP, port: 7002, endPort: 65535}
        - {protocol: UDP, port: 1, endPort: 65535}
    # Internode (7000 plain, 7001 TLS) only from database pods
    - from:
        - namespaceSelector: {}
          podSelector:
            matchExpressions:
              - {key: cassandra.datastax.com/cluster, operator: Exists}
EOF
    for cidr in "${CIDRS[@]}"; do
        echo "        - ipBlock: {cidr: \"${cidr}\"}"
    done
    cat <<EOF
      ports:
        - {protocol: TCP, port: 7000}
        - {protocol: TCP, port: 7001}
EOF
}

for ns in "${NAMESPACES[@]}"; do
    oc get namespace "${ns}" >/dev/null 2>&1 || { mc_warn "Namespace ${ns} not found - skipped."; continue; }
    if ${REMOVE}; then
        if ${DRY_RUN}; then
            mc_info "[dry-run] would delete networkpolicy/${POLICY} in ${ns}"
        else
            oc delete networkpolicy "${POLICY}" -n "${ns}" --ignore-not-found >/dev/null
            mc_info "${ns}: ${POLICY} removed"
        fi
    elif ${DRY_RUN}; then
        policy_yaml "${ns}"
        echo "---"
    else
        policy_yaml "${ns}" | oc apply -f - >/dev/null
        mc_info "${ns}: ${POLICY} applied (7000/7001 from database pods${CIDRS:+ and ${(j:, :)CIDRS}})"
    fi
done
