#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---
# WHY OPENSEARCH IS MISSING FROM THE watsonx.data UI:
#   watsonx.data keeps its own registry of provisioned services in the
#   'public.engine' table of the 'ibm_lh_repo' database (EDB/Postgres). When an
#   OpenSearchCluster CR is deleted, its row in that table is NOT removed.
#
#   Listing OpenSearch services makes lhconsole-api-v3 walk that table and fetch
#   each row's CR. The first row whose CR no longer exists aborts the whole
#   listing rather than being skipped:
#
#       Error fetching OpenSearch instance:
#         opensearchclusters.opensearch.opster.io "opensearch15" not found
#
#   The API then returns  "engines": { "opensearch": null }  and the UI widget
#   shows nothing - even when a perfectly healthy cluster is registered further
#   down the table. Every re-provision adds another tombstone, so this gets
#   worse over time.
#
#   This script reconciles the registry against reality: any 'opensearch' row
#   whose OpenSearchCluster CR is gone is deleted, and any live cluster that is
#   missing from the registry is inserted. Nothing is hardcoded - clusters,
#   instance id and the database pod are all discovered at runtime.
#
# NOTE: This writes directly to an IBM-managed product database. The supported
#   DELETE endpoint (/lakehouse/api/v3/opensearch/<id>) cannot help here: it
#   looks up the CR *before* removing the row, so it fails with the very error
#   we are trying to clear. A backup of the table is taken before any change.
# ---

eval "${OC_LOGIN}"

# Switch to the operands project if the login landed elsewhere.
if [[ "$(oc project -q 2>/dev/null || true)" != "${PROJECT_CPD_INST_OPERANDS}" ]]; then
    echo "[INFO] Switching project to ${PROJECT_CPD_INST_OPERANDS}."
    oc project "${PROJECT_CPD_INST_OPERANDS}" >/dev/null
fi

# Set DRY_RUN=true to report what would change without touching the database.
DRY_RUN="${DRY_RUN:-false}"

# watsonx.data registry database and table.
WXD_DB="ibm_lh_repo"
WXD_TABLE="public.engine"
WXD_ENGINE_TYPE="opensearch"

# Default engine_name prefix used when registering a cluster that is missing
# from the registry. The cluster name is appended to keep it unique.
WXD_ENGINE_NAME_PREFIX="wxdata_opensearch"

# ---
# Locate the watsonx.data EDB primary pod (dynamic - no hardcoded pod name).

echo ""
echo "=== Locating watsonx.data registry database ==="

PG_POD=$(oc get pods -n "${PROJECT_CPD_INST_OPERANDS}" \
    -l "k8s.enterprisedb.io/instanceRole=primary,icpdsupport/addOnId=watsonx-data,icpdsupport/module=postgres" \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -n1 || true)

if [[ -z "${PG_POD:-}" ]]; then
    echo "[ERROR] Could not find the watsonx.data Postgres primary pod in ${PROJECT_CPD_INST_OPERANDS}."
    echo "[ERROR] Expected a pod labelled k8s.enterprisedb.io/instanceRole=primary for the watsonx-data addon."
    exit 1
fi
echo "[OK] Using database pod ${PG_POD}."

# Small helper: run a query and return raw rows (tuples only, unaligned).
_wxd_psql() {
    oc exec -n "${PROJECT_CPD_INST_OPERANDS}" "${PG_POD}" -c postgres -- \
        psql -U postgres -d "${WXD_DB}" -v ON_ERROR_STOP=1 -tAc "$1" 2>/dev/null
}

if ! _wxd_psql "SELECT 1;" >/dev/null; then
    echo "[ERROR] Could not query database ${WXD_DB} on ${PG_POD}."
    exit 1
fi

# ---
# Determine the watsonx.data instance id from the registry itself, so the script
# stays correct on clusters with a different instance id.

WXD_INSTANCE_ID=$(_wxd_psql \
    "SELECT instance_id FROM ${WXD_TABLE} GROUP BY instance_id ORDER BY count(*) DESC LIMIT 1;" || true)

if [[ -z "${WXD_INSTANCE_ID:-}" ]]; then
    # Fall back to the label the operator stamps on its own pods.
    WXD_INSTANCE_ID=$(oc get pod "${PG_POD}" -n "${PROJECT_CPD_INST_OPERANDS}" \
        -o jsonpath='{.metadata.labels.icpdsupport/serviceInstanceId}' 2>/dev/null || true)
fi

if [[ -z "${WXD_INSTANCE_ID:-}" ]]; then
    echo "[ERROR] Could not determine the watsonx.data instance id."
    exit 1
fi
echo "[OK] watsonx.data instance id: ${WXD_INSTANCE_ID}"

# ---
# Gather live OpenSearch clusters and registered rows.

echo ""
echo "=== Comparing registry against live OpenSearch clusters ==="

LIVE_CLUSTERS=(${(f)"$(oc get opensearchcluster -n "${PROJECT_CPD_INST_OPERANDS}" \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)"})

REGISTERED=(${(f)"$(_wxd_psql \
    "SELECT engine_id FROM ${WXD_TABLE} WHERE type='${WXD_ENGINE_TYPE}' ORDER BY created_on;" || true)"})

echo "[INFO] Live OpenSearch clusters : ${LIVE_CLUSTERS[*]:-<none>}"
echo "[INFO] Registered in watsonx.data: ${REGISTERED[*]:-<none>}"

# Rows whose CR no longer exists.
STALE=()
for ROW in "${REGISTERED[@]}"; do
    [[ -z "${ROW}" ]] && continue
    if [[ ! " ${LIVE_CLUSTERS[*]} " == *" ${ROW} "* ]]; then
        STALE+=("${ROW}")
    fi
done

# Clusters that exist but are not registered.
MISSING=()
for CL in "${LIVE_CLUSTERS[@]}"; do
    [[ -z "${CL}" ]] && continue
    if [[ ! " ${REGISTERED[*]} " == *" ${CL} "* ]]; then
        MISSING+=("${CL}")
    fi
done

if [[ ${#STALE[@]} -eq 0 && ${#MISSING[@]} -eq 0 ]]; then
    echo "[SKIP] Registry already matches the live clusters. Nothing to do."
    exit 0
fi

[[ ${#STALE[@]}   -gt 0 ]] && echo "[INFO] Stale rows to remove   : ${STALE[*]}"
[[ ${#MISSING[@]} -gt 0 ]] && echo "[INFO] Clusters to register   : ${MISSING[*]}"

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[INFO] DRY_RUN=true - no changes made."
    exit 0
fi

# ---
# Back up the table before touching it.

BACKUP_TABLE="engine_backup_$(date -u +%Y%m%d%H%M%S)"
if _wxd_psql "CREATE TABLE ${BACKUP_TABLE} AS SELECT * FROM ${WXD_TABLE};" >/dev/null; then
    echo "[OK] Backed up ${WXD_TABLE} to ${BACKUP_TABLE} (in ${WXD_DB})."
else
    echo "[ERROR] Could not back up ${WXD_TABLE}. Aborting without changes."
    exit 1
fi

# ---
# Remove stale rows.

for ROW in "${STALE[@]}"; do
    if _wxd_psql "DELETE FROM ${WXD_TABLE} WHERE engine_id='${ROW}' AND type='${WXD_ENGINE_TYPE}';" >/dev/null; then
        echo "[OK] Removed stale registry row ${ROW}."
    else
        echo "[ERROR] Failed to remove stale registry row ${ROW}."
    fi
done

# ---
# Register live clusters that are missing. Column defaults mirror the rows the
# product writes itself (native origin, small size, single coordinator/worker).

for CL in "${MISSING[@]}"; do
    ENGINE_NAME="${WXD_ENGINE_NAME_PREFIX}_${CL}"
    if _wxd_psql "INSERT INTO ${WXD_TABLE}
            (engine_id, type, origin, size_config, coordinator_quantity, worker_quantity,
             engine_name, created_on, created_by, instance_id)
        VALUES
            ('${CL}', '${WXD_ENGINE_TYPE}', 'native', 'small', 1, 1,
             '${ENGINE_NAME}', extract(epoch from now())::bigint, 'cpadmin', '${WXD_INSTANCE_ID}');" >/dev/null; then
        echo "[OK] Registered ${CL} as ${ENGINE_NAME}."
    else
        echo "[ERROR] Failed to register ${CL}."
    fi
done

# ---
# Report the reconciled registry.

echo ""
echo "=== watsonx.data OpenSearch registry after reconcile ==="
oc exec -n "${PROJECT_CPD_INST_OPERANDS}" "${PG_POD}" -c postgres -- \
    psql -U postgres -d "${WXD_DB}" \
    -c "SELECT engine_id, engine_name, instance_id FROM ${WXD_TABLE} WHERE type='${WXD_ENGINE_TYPE}' ORDER BY created_on;" 2>/dev/null

echo ""
echo "[INFO] The watsonx.data UI reads this registry on a ~60s reconcile loop."
echo "[INFO] Refresh the OpenSearch page shortly; a hard reload may be needed."
echo "[INFO] Backup of the previous state: ${WXD_DB}.${BACKUP_TABLE}"
