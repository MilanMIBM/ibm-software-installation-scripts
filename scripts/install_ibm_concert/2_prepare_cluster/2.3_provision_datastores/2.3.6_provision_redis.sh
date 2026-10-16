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
# 2.3.6 Redis for Concert Data Apps (only when Redis is provisioned)
# ------------------------------------------------------------------------------
# Single-instance StatefulSet 'concert-redis' (Red Hat Redis image), shaped to
# what Data Apps' secret expects: an ACL user (DA_REDIS_USER is required),
# AOF persistence, and TLS when CONCERT_DS_REDIS_TLS=yes (IBM's default). The
# certificate comes from the OpenShift service CA (serving-cert annotation).
# Whether Data Apps verifies it without a CA file is open (spike S6); set
# CONCERT_DS_REDIS_TLS=no to fall back to plain in-cluster traffic.
# ==============================================================================

if ! concert_ds_server_provisioned REDIS; then
    concert_info "Redis is not provisioned by these scripts - skipping."
    exit 0
fi

eval "${OC_LOGIN}"

NS="${PROJECT_CONCERT_DATASTORES}"
TLS=false
concert_is_true "${CONCERT_DS_REDIS_TLS:-yes}" && TLS=true
PW="$(concert_ds_cred_ensure REDIS_PASSWORD_DATAAPPS)"
[[ -n "${PW}" ]] || concert_die "Could not create the Redis credential."

STAGE="$(concert_private_tmpdir)"
trap 'rm -rf "${STAGE}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
{
    print -r -- "dir /var/lib/redis/data"
    print -r -- "appendonly yes"
    print -r -- "protected-mode no"
    print -r -- "user default off"
    print -r -- "user dataapps on >${PW} ~* &* +@all"
    if ${TLS}; then
        print -r -- "port 0"
        print -r -- "tls-port 6379"
        print -r -- "tls-cert-file /tls/tls.crt"
        print -r -- "tls-key-file /tls/tls.key"
        print -r -- "tls-auth-clients no"
    else
        print -r -- "port 6379"
    fi
} > "${STAGE}/redis.conf"
oc create secret generic concert-redis-config -n "${NS}" --from-file=redis.conf="${STAGE}/redis.conf" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: concert-redis
  namespace: ${NS}
  labels:
    app: concert-redis
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: concert-redis-tls
spec:
  selector:
    app: concert-redis
  ports:
  - name: redis
    port: 6379
    targetPort: 6379
EOF

# The service CA creates the certificate asynchronously; Redis would crash-loop
# on a missing tls-cert-file if it started first.
if ${TLS}; then
    concert_wait_for 300 "service CA certificate concert-redis-tls" oc get secret concert-redis-tls -n "${NS}"
fi

# Volume templates are fixed once the StatefulSet exists; a bigger size grows the PVC below.
VOL_WANT="${CONCERT_DS_REDIS_STORAGE_SIZE:-2Gi}"
VOL_SIZE="$(concert_sts_template_size "${NS}" concert-redis "${VOL_WANT}")"
oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: concert-redis
  namespace: ${NS}
  labels:
    app: concert-redis
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  serviceName: concert-redis
  replicas: 1
  selector:
    matchLabels:
      app: concert-redis
  template:
    metadata:
      labels:
        app: concert-redis
      annotations:
        concert.ibm.com/config-hash: "$( { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } < "${STAGE}/redis.conf" | cut -c1-16)"
    spec:
      containers:
      - name: redis
        image: ${CONCERT_DS_REDIS_IMAGE}
        command: ["redis-server", "/etc/redis-concert/redis.conf"]
        ports:
        - containerPort: 6379
        readinessProbe:
          tcpSocket:
            port: 6379
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: ${CONCERT_DS_REDIS_MEM_LIMIT:-2Gi}
        volumeMounts:
        - name: config
          mountPath: /etc/redis-concert
          readOnly: true
        - name: tls
          mountPath: /tls
          readOnly: true
        - name: data
          mountPath: /var/lib/redis/data
      volumes:
      - name: config
        secret:
          secretName: concert-redis-config
      - name: tls
        secret:
          secretName: concert-redis-tls
          optional: true
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

concert_sts_grow_volume "${NS}" data-concert-redis-0 "${VOL_WANT}"

oc rollout status statefulset/concert-redis -n "${NS}" --timeout=600s
concert_info "Redis ready: concert-redis.${NS}.svc.cluster.local:6379 (user dataapps, TLS ${TLS})."
