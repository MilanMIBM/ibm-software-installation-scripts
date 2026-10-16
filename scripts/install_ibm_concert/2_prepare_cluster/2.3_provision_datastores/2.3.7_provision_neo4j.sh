#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 2.3.7 Neo4j for the Concert graph / VEIAS (only when Neo4j is provisioned)
# ------------------------------------------------------------------------------
# IBM has no built-in Neo4j: VEIAS refuses to install without the
# concert-neo4j-creds secret. This provisions a single-instance Neo4j 5
# community StatefulSet (GPLv3; clustering needs Enterprise). Community has one
# user database, 'neo4j'. The official image runs as uid 7474, so its
# ServiceAccount is allowed the nonroot-v2 SCC. The required Neo4j version for
# VEIAS is not documented (spike S8).
# ==============================================================================

if ! concert_ds_server_provisioned NEO4J; then
    concert_info "Neo4j is not provisioned by these scripts (VEIAS/graph off or existing server) - skipping."
    exit 0
fi

eval "${OC_LOGIN}"

NS="${PROJECT_CONCERT_DATASTORES}"
NEO4J_PW="$(concert_ds_cred_ensure NEO4J_PASSWORD)"
[[ -n "${NEO4J_PW}" ]] || concert_die "Could not create the Neo4j credential."
concert_apply_secret "${NS}" concert-neo4j-auth "NEO4J_AUTH=neo4j/${NEO4J_PW}"

# Volume templates are fixed once the StatefulSet exists; a bigger size grows the PVC below.
VOL_WANT="${CONCERT_DS_NEO4J_STORAGE_SIZE:-50Gi}"
VOL_SIZE="$(concert_sts_template_size "${NS}" concert-neo4j "${VOL_WANT}")"
oc create serviceaccount concert-neo4j -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: concert-neo4j-nonroot-v2
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:nonroot-v2
subjects:
- kind: ServiceAccount
  name: concert-neo4j
  namespace: ${NS}
---
apiVersion: v1
kind: Service
metadata:
  name: concert-neo4j
  namespace: ${NS}
  labels:
    app: concert-neo4j
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  selector:
    app: concert-neo4j
  ports:
  - name: bolt
    port: 7687
    targetPort: 7687
  - name: http
    port: 7474
    targetPort: 7474
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: concert-neo4j
  namespace: ${NS}
  labels:
    app: concert-neo4j
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  serviceName: concert-neo4j
  replicas: 1
  selector:
    matchLabels:
      app: concert-neo4j
  template:
    metadata:
      labels:
        app: concert-neo4j
    spec:
      serviceAccountName: concert-neo4j
      securityContext:
        runAsNonRoot: true
        runAsUser: 7474
        runAsGroup: 7474
        fsGroup: 7474
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: neo4j
        image: ${CONCERT_DS_NEO4J_IMAGE}
        envFrom:
        - secretRef:
            name: concert-neo4j-auth
        ports:
        - containerPort: 7687
        - containerPort: 7474
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        readinessProbe:
          tcpSocket:
            port: 7687
          initialDelaySeconds: 30
          periodSeconds: 10
        resources:
          requests:
            cpu: 500m
            memory: 2Gi
          limits:
            memory: ${CONCERT_DS_NEO4J_MEM_LIMIT:-8Gi}
        volumeMounts:
        - name: data
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: ${CONCERT_STG_CLASS_DATASTORES:-${CONCERT_STG_CLASS_BLOCK}}
      resources:
        requests:
          storage: ${VOL_SIZE}
EOF

concert_sts_grow_volume "${NS}" data-concert-neo4j-0 "${VOL_WANT}"

oc rollout status statefulset/concert-neo4j -n "${NS}" --timeout=900s
concert_info "Neo4j ready: concert-neo4j.${NS}.svc.cluster.local:7687 (database neo4j)."
