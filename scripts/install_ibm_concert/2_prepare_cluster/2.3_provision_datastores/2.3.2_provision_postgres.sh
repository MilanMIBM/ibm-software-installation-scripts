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
# 2.3.2 PostgreSQL server + databases for every active consumer
# ------------------------------------------------------------------------------
# provision: CloudNativePG Cluster 'concert-pg' in PROJECT_CONCERT_DATASTORES
#            (2 instances in production = primary + standby, anti-affinity, TLS on,
#            superuser secret). Raise CONCERT_DS_PG_*STORAGE_SIZE and re-run to grow
#            the volumes online (never shrink: CloudNativePG rejects a smaller size).
# existing:  your server; CONCERT_DS_PG_HOST + admin user/password from the config
#
# Then an idempotent init Job (psql, run inside the cluster) creates one login
# role per consumer, its database(s) and the extensions IBM requires:
#   Hub/Keycloak         concert_keycloak   ${CONCERT_DS_PG_DB_KEYCLOAK}
#   Concert              concert_app        appdb, configdb (names fixed) + vector
#   Data Apps            concert_dataapps   ${CONCERT_DS_PG_DB_DATAAPPS}
#   Workflows AI         concert_workflows  ${CONCERT_DS_PG_DB_WORKFLOWS}
# Concert 3.1 (rojacore) connects to appdb with the role name cut at the first
# underscore ("concert_app" -> "concert") while configdb keeps the full name, so
# appdb also gets a login alias "concert": same password, member of concert_app,
# and SET role = concert_app on login (same rights, objects owned by concert_app).
# Role passwords are generated once and kept in the
# concert-datastore-credentials Secret; re-runs reset them to the same values.
# ==============================================================================

if ! concert_ds_server_needed POSTGRES; then
    concert_info "No consumer uses an external PostgreSQL - skipping."
    exit 0
fi

eval "${OC_LOGIN}"

NS="${PROJECT_CONCERT_DATASTORES}"
PROVIDER="$(concert_ds_server_provider POSTGRES)"
CLUSTER=concert-pg

# --- Server ---------------------------------------------------------------------------
if [[ "${PROVIDER}" == provision ]]; then
    oc get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 || concert_die "CloudNativePG is not installed - run 2.3.1 first."
    oc apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER}
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  instances: ${CONCERT_DS_PG_INSTANCES:-2}
  imageName: ${CONCERT_DS_PG_IMAGE}
  enableSuperuserAccess: true
  primaryUpdateStrategy: unsupervised
  postgresql:
    parameters:
      max_connections: "${CONCERT_DS_PG_MAX_CONNECTIONS:-500}"
  affinity:
    enablePodAntiAffinity: true
    topologyKey: kubernetes.io/hostname
  storage:
    size: ${CONCERT_DS_PG_STORAGE_SIZE:-250Gi}
    storageClass: ${CONCERT_STG_CLASS_DATASTORES:-${CONCERT_STG_CLASS_BLOCK}}
  walStorage:
    size: ${CONCERT_DS_PG_WAL_STORAGE_SIZE:-20Gi}
    storageClass: ${CONCERT_STG_CLASS_DATASTORES:-${CONCERT_STG_CLASS_BLOCK}}
  resources:
    requests:
      cpu: "${CONCERT_DS_PG_CPU_REQUEST:-4}"
      memory: ${CONCERT_DS_PG_MEM_REQUEST:-12Gi}
    limits:
      cpu: "${CONCERT_DS_PG_CPU_LIMIT:-6}"
      memory: ${CONCERT_DS_PG_MEM_LIMIT:-16Gi}
EOF
    _ready() {
        local want have
        want="$(oc get cluster.postgresql.cnpg.io "${CLUSTER}" -n "${NS}" -o jsonpath='{.spec.instances}')"
        have="$(oc get cluster.postgresql.cnpg.io "${CLUSTER}" -n "${NS}" -o jsonpath='{.status.readyInstances}')"
        [[ -n "${have}" && "${have}" == "${want}" ]]
    }
    concert_wait_for 1800 "PostgreSQL cluster ${CLUSTER} (all instances ready)" _ready
    ADMIN_SECRET="${CLUSTER}-superuser"
    PGHOST_VALUE="${CLUSTER}-rw.${NS}.svc.cluster.local"
    PGPORT_VALUE=5432
    PGSSLMODE_VALUE=require
else
    concert_require_vars CONCERT_DS_PG_HOST CONCERT_DS_PG_ADMIN_USER CONCERT_DS_PG_ADMIN_PASSWORD
    ADMIN_SECRET=concert-pg-admin
    concert_apply_secret "${NS}" "${ADMIN_SECRET}" \
        "username=${CONCERT_DS_PG_ADMIN_USER}" "password=${CONCERT_DS_PG_ADMIN_PASSWORD}"
    PGHOST_VALUE="${CONCERT_DS_PG_HOST}"
    PGPORT_VALUE="${CONCERT_DS_PG_PORT:-5432}"
    PGSSLMODE_VALUE="${CONCERT_DS_PG_SSLMODE:-require}"
fi

# --- Databases ------------------------------------------------------------------------
STAGE="$(concert_private_tmpdir)"
trap 'rm -rf "${STAGE}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
SPEC="${STAGE}/spec"
: > "${SPEC}"
_add() {   # <role> <database> <extensions,comma-separated> [<login alias>]
    local pw
    pw="$(concert_ds_cred_ensure "PG_PASSWORD_${1:u}")"
    [[ -n "${pw}" ]] || concert_die "Could not create the password for role ${1}."
    print -r -- "${1}|${2}|${3}|${4:-}|${pw}" >> "${SPEC}"
}
concert_ds_consumer_active KEYCLOAK           && _add concert_keycloak  "${CONCERT_DS_PG_DB_KEYCLOAK:-keycloak}" ""
if concert_ds_consumer_active CONCERT_DB; then
    _add concert_app appdb vector "${${:-concert_app}%%_*}"
    _add concert_app configdb vector
fi
concert_ds_consumer_active DATAAPPS_DB        && _add concert_dataapps  "${CONCERT_DS_PG_DB_DATAAPPS:-dataapps}" ""
concert_ds_consumer_active WORKFLOWS_POSTGRES && _add concert_workflows "${CONCERT_DS_PG_DB_WORKFLOWS:-pliant_ai}" ""

cat > "${STAGE}/init.sh" <<'SH'
#!/bin/bash
set -euo pipefail
export HOME=/tmp PGDATABASE=postgres PGCONNECT_TIMEOUT=10
for _ in $(seq 1 60); do pg_isready -q && break; sleep 5; done
while IFS='|' read -r role db exts alias pw; do
    [[ -n "${role}" ]] || continue
    psql -v ON_ERROR_STOP=1 -q -v role="${role}" -v pw="${pw}" -v db="${db}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role')\gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'role', :'pw')\gexec
SELECT format('CREATE DATABASE %I OWNER %I ENCODING %L', :'db', :'role', 'UTF8') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db')\gexec
SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'db', :'role')\gexec
SQL
    for ext in ${exts//,/ }; do
        psql -v ON_ERROR_STOP=1 -q -d "${db}" -c "CREATE EXTENSION IF NOT EXISTS \"${ext}\"" \
            || { echo "FAILED: CREATE EXTENSION ${ext} in ${db} - the server image needs ${ext} (pgvector)"; exit 1; }
    done
    psql -q -d "${db}" -v role="${role}" <<'SQL' || echo "note: could not change the owner of schema public in ${db}"
SELECT format('ALTER SCHEMA public OWNER TO %I', :'role')\gexec
SQL
    if [[ -n "${alias}" && "${alias}" != "${role}" ]]; then
        psql -v ON_ERROR_STOP=1 -q -v role="${role}" -v alias="${alias}" -v pw="${pw}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'alias') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'alias')\gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'alias', :'pw')\gexec
SELECT format('GRANT %I TO %I', :'role', :'alias')\gexec
SELECT format('ALTER ROLE %I SET role = %I', :'alias', :'role')\gexec
SQL
    fi
    echo "ready: database ${db}, owner ${role}${alias:+ (login alias ${alias})}${exts:+, extensions ${exts}}"
done < /init/spec
SH

oc create secret generic concert-pg-init -n "${NS}" --from-file=spec="${SPEC}" --from-file=init.sh="${STAGE}/init.sh" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

oc delete job concert-pg-init -n "${NS}" --ignore-not-found >/dev/null
oc apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: concert-pg-init
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: init
        image: ${CONCERT_DS_PG_IMAGE}
        command: ["/bin/bash", "/init/init.sh"]
        env:
        - {name: PGHOST, value: "${PGHOST_VALUE}"}
        - {name: PGPORT, value: "${PGPORT_VALUE}"}
        - {name: PGSSLMODE, value: "${PGSSLMODE_VALUE}"}
        - name: PGUSER
          valueFrom: {secretKeyRef: {name: ${ADMIN_SECRET}, key: username}}
        - name: PGPASSWORD
          valueFrom: {secretKeyRef: {name: ${ADMIN_SECRET}, key: password}}
        volumeMounts:
        - {name: init, mountPath: /init, readOnly: true}
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {memory: 256Mi}
      volumes:
      - name: init
        secret: {secretName: concert-pg-init}
EOF

if oc wait --for=condition=complete job/concert-pg-init -n "${NS}" --timeout=900s >/dev/null 2>&1; then
    oc logs job/concert-pg-init -n "${NS}" | grep -E '^(ready|note):' || true
    oc delete secret concert-pg-init -n "${NS}" --ignore-not-found >/dev/null
    concert_info "PostgreSQL databases ready on ${PGHOST_VALUE}:${PGPORT_VALUE}."
else
    oc logs job/concert-pg-init -n "${NS}" --tail=40 >&2 || true
    concert_die "The PostgreSQL init Job failed (job/concert-pg-init in ${NS})."
fi
