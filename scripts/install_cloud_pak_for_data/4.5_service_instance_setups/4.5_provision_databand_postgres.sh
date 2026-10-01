#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# =============================================================================
# PostgreSQL for Databand (data observability in watsonx.dataintegration)
# -----------------------------------------------------------------------------
# With enableDataObservability: true, the DatabandInstaller CR installs the
# databand chart with:
#     databand.sqlAlchemyConn.existingSecret.name: databand-postgres
# Neither the operator nor the chart creates that secret or a database - it is
# customer provided. Without it the databand-dbnd-web-migration-1 hook pod
# sits in Init with "secret databand-postgres not found", and the helm release
# stays pending-install.
#
# The chart reads these keys from the secret (configmap-env.yaml and
# job-dbnd-web-migration.yaml in databand-54.0.5) and appends /<dbname>:
#     connection.postgres.authentication.username
#     connection.postgres.authentication.password
#     connection.postgres.hosts.0.hostname
#     connection.postgres.hosts.0.port
# The values are interpolated into a SQLAlchemy URL WITHOUT url-encoding, so
# the password is kept alphanumeric.
#
# This script provisions a dedicated database and writes that secret:
#   - edb:   an EDB Cluster via the CPD Postgres operator, when its CRD exists
#   - plain: otherwise, a single-instance PostgreSQL Deployment + PVC + Service
#            using the Red Hat postgresql image (runs under restricted-v2 SCC)
# DBND_PG_MODE=auto (default) picks edb if the operator is present, else plain.
# Set DBND_PG_MODE=edb or DBND_PG_MODE=plain to force one.
# Run it before installing watsonx.dataintegration, or any time after - a
# stuck migration pod picks the secret up on its own once it exists.
# =============================================================================

for var in OC_LOGIN PROJECT_CPD_INST_OPERANDS; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

# --- Configuration
DBND_NAMESPACE="${PROJECT_CPD_INST_OPERANDS}"
DBND_SECRET_NAME="databand-postgres"            # must match sqlAlchemyConn.existingSecret.name
DBND_DB_NAME="databand"                         # must match sqlAlchemyConn.dbname
DBND_DB_USER="databand"
DBND_PG_MODE="${DBND_PG_MODE:-auto}"            # auto | edb | plain
DBND_INSTANCES="${DBND_INSTANCES:-2}"           # edb only: 1 = no HA, 2+ = primary + replicas
DBND_STORAGE_SIZE="${DBND_STORAGE_SIZE:-20Gi}"
DBND_STORAGE_CLASS="${STG_CLASS_BLOCK:-ocs-storagecluster-ceph-rbd}"
DBND_PULL_SECRET="${IMAGE_PULL_SECRET:-pull-secret}"
# Postgres major version to reuse from the other CPD-managed EDB clusters.
# Leave DBND_PG_IMAGE unset to auto-resolve; the operator default is used if
# no cluster in the namespace runs this major version.
DBND_PG_MAJOR="${DBND_PG_MAJOR:-16}"
DBND_PG_IMAGE="${DBND_PG_IMAGE:-}"
DBND_WAIT_TIMEOUT="${DBND_WAIT_TIMEOUT:-15m}"
EDB_CLUSTER_RESOURCE="clusters.postgresql.k8s.enterprisedb.io"

# ---
eval "${OC_LOGIN}"

# --- Skip if the secret is already in place ---
if oc get secret "${DBND_SECRET_NAME}" -n "${DBND_NAMESPACE}" >/dev/null 2>&1; then
    echo "[INFO] Secret ${DBND_SECRET_NAME} already exists in ${DBND_NAMESPACE} - nothing to do."
    exit 0
fi

# --- Pick the provisioning mode ---
case "${DBND_PG_MODE}" in
    auto)
        # Stick with a plain deployment from an earlier run rather than adding an EDB cluster beside it
        if oc get deployment "${DBND_CLUSTER_NAME:-databand-postgres-db}" -n "${DBND_NAMESPACE}" >/dev/null 2>&1; then
            DBND_PG_MODE="plain"
        elif oc get crd "${EDB_CLUSTER_RESOURCE}" >/dev/null 2>&1; then
            DBND_PG_MODE="edb"
        else
            echo "[INFO] CRD ${EDB_CLUSTER_RESOURCE} not found - provisioning a plain PostgreSQL deployment."
            DBND_PG_MODE="plain"
        fi
        ;;
    edb)
        if ! oc get crd "${EDB_CLUSTER_RESOURCE}" >/dev/null 2>&1; then
            echo "[ERROR] DBND_PG_MODE=edb but CRD ${EDB_CLUSTER_RESOURCE} not found - install Software Hub (cpd_platform) first."
            exit 1
        fi
        ;;
    plain) ;;
    *)
        echo "[ERROR] DBND_PG_MODE must be auto, edb or plain (got: ${DBND_PG_MODE})"
        exit 1
        ;;
esac
echo "[INFO] Provisioning mode: ${DBND_PG_MODE}"

if [[ "${DBND_PG_MODE}" == "edb" ]]; then
    DBND_CLUSTER_NAME="${DBND_CLUSTER_NAME:-databand-postgres-edb}"
    DBND_PG_IMAGE_DEFAULT=""
    DBND_DB_RESOURCE="${EDB_CLUSTER_RESOURCE}"
    DBND_DB_HOST="${DBND_CLUSTER_NAME}-rw.${DBND_NAMESPACE}.svc"
else
    DBND_CLUSTER_NAME="${DBND_CLUSTER_NAME:-databand-postgres-db}"
    DBND_PG_IMAGE_DEFAULT="registry.redhat.io/rhel9/postgresql-${DBND_PG_MAJOR}:latest"
    DBND_DB_RESOURCE="deployment"
    DBND_DB_HOST="${DBND_CLUSTER_NAME}.${DBND_NAMESPACE}.svc"
fi
DBND_CREDS_SECRET_NAME="${DBND_CLUSTER_NAME}-app-credentials"

# --- Connection secret in the format the databand chart expects ---
create_connection_secret() {
    local host="$1"
    oc create secret generic "${DBND_SECRET_NAME}" -n "${DBND_NAMESPACE}" \
        --from-literal=connection.postgres.authentication.username="${DBND_DB_USER}" \
        --from-literal=connection.postgres.authentication.password="${DBND_DB_PASSWORD}" \
        --from-literal=connection.postgres.hosts.0.hostname="${host}" \
        --from-literal=connection.postgres.hosts.0.port=5432
    echo "[INFO] Created secret ${DBND_SECRET_NAME} (host: ${host})"
}

# --- EDB Cluster via the CPD Postgres operator ---
provision_edb() {
    # Resolve the Postgres image
    if [[ -z "${DBND_PG_IMAGE}" ]]; then
        DBND_PG_IMAGE="$(oc get "${EDB_CLUSTER_RESOURCE}" -n "${DBND_NAMESPACE}" \
            -o jsonpath='{range .items[*]}{.spec.imageName}{"\n"}{end}' \
            | grep -m1 "/postgresql:${DBND_PG_MAJOR}\." || true)"
    fi
    local image_line=""
    if [[ -n "${DBND_PG_IMAGE}" ]]; then
        echo "[INFO] Using Postgres image: ${DBND_PG_IMAGE}"
        image_line="  imageName: ${DBND_PG_IMAGE}"
    else
        echo "[INFO] No Postgres ${DBND_PG_MAJOR} image found in ${DBND_NAMESPACE} - using the operator default image."
    fi

    echo "[INFO] Applying EDB Cluster ${DBND_CLUSTER_NAME} in ${DBND_NAMESPACE}"
    cat <<EOF | oc apply -f -
apiVersion: postgresql.k8s.enterprisedb.io/v1
kind: Cluster
metadata:
  name: ${DBND_CLUSTER_NAME}
  namespace: ${DBND_NAMESPACE}
spec:
  description: PostgreSQL cluster for Databand (data observability)
  instances: ${DBND_INSTANCES}
${image_line}
  imagePullSecrets:
  - name: ${DBND_PULL_SECRET}
  enableSuperuserAccess: false
  bootstrap:
    initdb:
      database: ${DBND_DB_NAME}
      owner: ${DBND_DB_USER}
      encoding: UTF8
      secret:
        name: ${DBND_CREDS_SECRET_NAME}
  postgresql:
    parameters:
      max_connections: "300"
      shared_buffers: 512MB
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 2Gi
  storage:
    size: ${DBND_STORAGE_SIZE}
    storageClass: ${DBND_STORAGE_CLASS}
EOF

    create_connection_secret "${DBND_DB_HOST}"

    echo "[INFO] Waiting up to ${DBND_WAIT_TIMEOUT} for ${DBND_CLUSTER_NAME} to become Ready..."
    oc wait "${EDB_CLUSTER_RESOURCE}/${DBND_CLUSTER_NAME}" -n "${DBND_NAMESPACE}" \
        --for=condition=Ready --timeout="${DBND_WAIT_TIMEOUT}"
    oc get "${EDB_CLUSTER_RESOURCE}" "${DBND_CLUSTER_NAME}" -n "${DBND_NAMESPACE}"
}

# --- Plain single-instance PostgreSQL (PVC + Deployment + Service) ---
# The Red Hat image runs as the namespace's arbitrary UID, so it fits the
# default restricted-v2 SCC. registry.redhat.io is covered by the cluster
# global pull secret; for air-gapped clusters set DBND_PG_IMAGE to a mirror.
provision_plain() {
    DBND_PG_IMAGE="${DBND_PG_IMAGE:-${DBND_PG_IMAGE_DEFAULT}}"
    echo "[INFO] Using Postgres image: ${DBND_PG_IMAGE}"

    echo "[INFO] Applying PostgreSQL deployment ${DBND_CLUSTER_NAME} in ${DBND_NAMESPACE}"
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${DBND_CLUSTER_NAME}-data
  namespace: ${DBND_NAMESPACE}
  labels:
    app: ${DBND_CLUSTER_NAME}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${DBND_STORAGE_SIZE}
  storageClassName: ${DBND_STORAGE_CLASS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DBND_CLUSTER_NAME}
  namespace: ${DBND_NAMESPACE}
  labels:
    app: ${DBND_CLUSTER_NAME}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ${DBND_CLUSTER_NAME}
  template:
    metadata:
      labels:
        app: ${DBND_CLUSTER_NAME}
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: postgresql
        image: ${DBND_PG_IMAGE}
        ports:
        - name: postgresql
          containerPort: 5432
        env:
        - name: POSTGRESQL_USER
          valueFrom:
            secretKeyRef:
              name: ${DBND_CREDS_SECRET_NAME}
              key: username
        - name: POSTGRESQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${DBND_CREDS_SECRET_NAME}
              key: password
        - name: POSTGRESQL_DATABASE
          value: ${DBND_DB_NAME}
        - name: POSTGRESQL_MAX_CONNECTIONS
          value: "300"
        - name: POSTGRESQL_SHARED_BUFFERS
          value: 512MB
        readinessProbe:
          exec:
            command: ["pg_isready", "-h", "127.0.0.1", "-p", "5432", "-U", "${DBND_DB_USER}", "-d", "${DBND_DB_NAME}"]
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 5432
          initialDelaySeconds: 30
          periodSeconds: 20
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: "2"
            memory: 2Gi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: data
          mountPath: /var/lib/pgsql/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ${DBND_CLUSTER_NAME}-data
---
apiVersion: v1
kind: Service
metadata:
  name: ${DBND_CLUSTER_NAME}
  namespace: ${DBND_NAMESPACE}
  labels:
    app: ${DBND_CLUSTER_NAME}
spec:
  selector:
    app: ${DBND_CLUSTER_NAME}
  ports:
  - name: postgresql
    port: 5432
    targetPort: 5432
EOF

    create_connection_secret "${DBND_DB_HOST}"

    echo "[INFO] Waiting up to ${DBND_WAIT_TIMEOUT} for ${DBND_CLUSTER_NAME} to become Ready..."
    oc rollout status "deployment/${DBND_CLUSTER_NAME}" -n "${DBND_NAMESPACE}" --timeout="${DBND_WAIT_TIMEOUT}"
    oc get deployment "${DBND_CLUSTER_NAME}" -n "${DBND_NAMESPACE}"
}

# --- Never re-provision an existing database: only restore its connection secret ---
if oc get "${DBND_DB_RESOURCE}" "${DBND_CLUSTER_NAME}" -n "${DBND_NAMESPACE}" >/dev/null 2>&1; then
    echo "[INFO] ${DBND_DB_RESOURCE}/${DBND_CLUSTER_NAME} already exists - not re-provisioning."
    if ! oc get secret "${DBND_CREDS_SECRET_NAME}" -n "${DBND_NAMESPACE}" >/dev/null 2>&1; then
        echo "[ERROR] Credentials secret ${DBND_CREDS_SECRET_NAME} is missing, so the existing database password is unknown."
        echo "[ERROR] Recreate ${DBND_CREDS_SECRET_NAME} with the database's password, or delete ${DBND_DB_RESOURCE}/${DBND_CLUSTER_NAME} to start fresh."
        exit 1
    fi
    DBND_DB_PASSWORD="$(oc get secret "${DBND_CREDS_SECRET_NAME}" -n "${DBND_NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)"
    create_connection_secret "${DBND_DB_HOST}"
else
    # --- App user credentials (reuse on re-run so the database and secret stay in sync) ---
    if oc get secret "${DBND_CREDS_SECRET_NAME}" -n "${DBND_NAMESPACE}" >/dev/null 2>&1; then
        echo "[INFO] Reusing credentials from secret ${DBND_CREDS_SECRET_NAME}"
        DBND_DB_PASSWORD="$(oc get secret "${DBND_CREDS_SECRET_NAME}" -n "${DBND_NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)"
    else
        DBND_DB_PASSWORD="$(openssl rand -hex 16)"
        oc create secret generic "${DBND_CREDS_SECRET_NAME}" -n "${DBND_NAMESPACE}" \
            --type=kubernetes.io/basic-auth \
            --from-literal=username="${DBND_DB_USER}" \
            --from-literal=password="${DBND_DB_PASSWORD}"
    fi

    "provision_${DBND_PG_MODE}"
fi

# --- A migration pod that already gave up waiting will not retry on its own ---
if oc get pods -n "${DBND_NAMESPACE}" -l job-name=databand-dbnd-web-migration-1 --no-headers 2>/dev/null | grep -q -E 'Error|Init:Error|Failed'; then
    echo "[WARN] databand-dbnd-web-migration-1 has a failed pod. If the job does not retry, delete it:"
    echo "       oc delete pod -n ${DBND_NAMESPACE} -l job-name=databand-dbnd-web-migration-1"
fi
