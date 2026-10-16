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
# 2.3.5 MySQL for Concert Workflows (only when MySQL is provisioned)
# ------------------------------------------------------------------------------
# Single-instance StatefulSet 'concert-mysql' from Red Hat's supported MySQL
# image (CONCERT_DS_MYSQL_IMAGE). That is the same replica count as IBM's
# built-in MySQL, but its data outlives Workflows reinstalls. The image creates
# the user and database (CONCERT_DS_MYSQL_DBNAME) on first start.
# registry.redhat.io must be in the cluster pull secret (true for most OCP
# installs; ROKS: set a quay.io/sclorg image instead).
# ==============================================================================

if ! concert_ds_server_provisioned MYSQL; then
    concert_info "MySQL is not provisioned by these scripts - skipping."
    exit 0
fi

eval "${OC_LOGIN}"

NS="${PROJECT_CONCERT_DATASTORES}"
# Assignments (not inline $(...) arguments) so a failure stops the script.
MYSQL_PW="$(concert_ds_cred_ensure MYSQL_PASSWORD_WORKFLOWS)"
MYSQL_ROOT_PW="$(concert_ds_cred_ensure MYSQL_ROOT_PASSWORD)"
[[ -n "${MYSQL_PW}" && -n "${MYSQL_ROOT_PW}" ]] || concert_die "Could not create the MySQL credentials."
concert_apply_secret "${NS}" concert-mysql \
    "MYSQL_USER=workflows" \
    "MYSQL_PASSWORD=${MYSQL_PW}" \
    "MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PW}" \
    "MYSQL_DATABASE=${CONCERT_DS_MYSQL_DBNAME:-pliant}"

# Volume templates are fixed once the StatefulSet exists; a bigger size grows the PVC below.
VOL_WANT="${CONCERT_DS_MYSQL_STORAGE_SIZE:-20Gi}"
VOL_SIZE="$(concert_sts_template_size "${NS}" concert-mysql "${VOL_WANT}")"
oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: concert-mysql
  namespace: ${NS}
  labels:
    app: concert-mysql
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  selector:
    app: concert-mysql
  ports:
  - name: mysql
    port: 3306
    targetPort: 3306
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: concert-mysql
  namespace: ${NS}
  labels:
    app: concert-mysql
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  serviceName: concert-mysql
  replicas: 1
  selector:
    matchLabels:
      app: concert-mysql
  template:
    metadata:
      labels:
        app: concert-mysql
    spec:
      containers:
      - name: mysql
        image: ${CONCERT_DS_MYSQL_IMAGE}
        envFrom:
        - secretRef:
            name: concert-mysql
        ports:
        - containerPort: 3306
        readinessProbe:
          exec:
            command: ["/bin/sh", "-c", "MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysqladmin -u \"\$MYSQL_USER\" -h 127.0.0.1 ping"]
          initialDelaySeconds: 20
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 3306
          initialDelaySeconds: 60
          periodSeconds: 20
        resources:
          requests:
            cpu: "${CONCERT_DS_MYSQL_CPU_REQUEST:-1}"
            memory: ${CONCERT_DS_MYSQL_MEM_REQUEST:-2Gi}
          limits:
            memory: ${CONCERT_DS_MYSQL_MEM_LIMIT:-4Gi}
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql/data
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

concert_sts_grow_volume "${NS}" data-concert-mysql-0 "${VOL_WANT}"

oc rollout status statefulset/concert-mysql -n "${NS}" --timeout=900s
concert_info "MySQL ready: concert-mysql.${NS}.svc.cluster.local:3306 (database ${CONCERT_DS_MYSQL_DBNAME:-pliant})."
