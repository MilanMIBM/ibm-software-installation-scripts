#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

eval "${OC_LOGIN}"

# ---
# When PREPARE_TLS=true, this script also creates the passthrough route (if not
# already requested elsewhere), extracts the instance server CA certificate, and
# saves it to cp4d_config/certs/<edb_instance_name>/ so the database can be
# reached securely from outside the cluster.
PREPARE_TLS="${PREPARE_TLS:-false}"

# ---

echo ""
echo "=== Listing CPDEdbInstances in namespace: ${PROJECT_CPD_INST_OPERANDS} ==="
oc get CPDEdbInstances -n "${PROJECT_CPD_INST_OPERANDS}" 2>/dev/null || true
echo ""

EDB_INSTANCES=(${(f)"$(oc get CPDEdbInstances -n "${PROJECT_CPD_INST_OPERANDS}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)"})

if [[ ${#EDB_INSTANCES[@]} -eq 0 ]]; then
    echo "[WARN] No CPDEdbInstances found in ${PROJECT_CPD_INST_OPERANDS}. Nothing to do."
    exit 0
fi

# ---
# Create passthrough routes for each instance's <name>-rw service
# (only when PREPARE_TLS=true, since external secure access needs both the
#  route and the exported CA certificate)

if [[ "${PREPARE_TLS}" == "true" ]]; then
echo "=== Creating passthrough routes ==="
echo ""

for INSTANCE in "${EDB_INSTANCES[@]}"; do
    [[ -z "${INSTANCE:-}" ]] && continue
    echo "--- Instance: ${INSTANCE} ---"

    SVC_NAME="${INSTANCE}-edb-db-rw"
    ROUTE_NAME="${INSTANCE}-edb-db-rw"

    if ! oc get svc "${SVC_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
        echo "  [WARN] Service '${SVC_NAME}' not found in ${PROJECT_CPD_INST_OPERANDS}. Skipping."
        echo ""
        continue
    fi

    if oc get route "${ROUTE_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
        echo "  [SKIP] Route '${ROUTE_NAME}' already exists."
    else
        oc create route passthrough "${ROUTE_NAME}" \
            --service="${SVC_NAME}" \
            -n "${PROJECT_CPD_INST_OPERANDS}" \
            --wildcard-policy=None
        echo "  [OK] Created passthrough route '${ROUTE_NAME}'."
    fi

    ROUTE_HOST=$(oc get route "${ROUTE_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    [[ -n "${ROUTE_HOST:-}" ]] && echo "  [INFO] Host: ${ROUTE_HOST}"
    echo ""
done

echo "=== Routes in ${PROJECT_CPD_INST_OPERANDS} ==="
oc get routes -n "${PROJECT_CPD_INST_OPERANDS}"
echo ""
else
    echo "=== PREPARE_TLS=false: skipping route creation and cert export ==="
    echo ""
fi

# ---
# Extract credentials from each instance's -app secret and write to cpd_instance_details.sh

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/cpd_instance_details.sh"
CERTS_ROOT="${REPO_ROOT}/cp4d_config/certs"

echo "=== Extracting EDB Postgres credentials ==="
echo ""

EDB_BLOCK="
# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

for INSTANCE in "${EDB_INSTANCES[@]}"; do
    [[ -z "${INSTANCE:-}" ]] && continue
    echo "--- Instance: ${INSTANCE} ---"

    APP_SECRET="${INSTANCE}-edb-db-app"

    if ! oc get secret "${APP_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
        echo "  [WARN] Secret '${APP_SECRET}' not found in ${PROJECT_CPD_INST_OPERANDS}. Skipping credentials."
        echo ""
        continue
    fi

    EDB_PASSWORD=$(oc get secret "${APP_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
    EDB_USERNAME=$(oc get secret "${APP_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
        -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)
    EDB_DBNAME=$(oc get secret "${APP_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
        -o jsonpath='{.data.dbname}' 2>/dev/null | base64 -d || true)
    EDB_LOCAL_PORT=$(oc get secret "${APP_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
        -o jsonpath='{.data.port}' 2>/dev/null | base64 -d || true)
    EDB_LOCAL_URI=$(oc get secret "${APP_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
        -o jsonpath='{.data.uri}' 2>/dev/null | base64 -d || true)

    ROUTE_HOST=$(oc get route "${INSTANCE}-edb-db-rw" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)

    # Build the route URI by replacing the host in the local URI with the route host, and the port with 443
    # Local URI format: postgresql://user:pass@host:port/dbname
    if [[ -n "${EDB_LOCAL_URI:-}" && -n "${ROUTE_HOST:-}" ]]; then
        # Extract URI prefix (scheme://user:pass@) and suffix (/dbname...)
        URI_PREFIX="${EDB_LOCAL_URI%%@*}@"
        URI_SUFFIX="/${EDB_LOCAL_URI##*/}"
        EDB_ROUTE_URI="${URI_PREFIX}${ROUTE_HOST}:443${URI_SUFFIX}"
    else
        EDB_ROUTE_URI=""
    fi

    # Sanitize instance name to uppercase with underscores for variable names
    VAR_PREFIX="EDB_POSTGRES_${INSTANCE:u}"
    VAR_PREFIX="${VAR_PREFIX//-/_}"

    # When TLS prep is requested, extract the instance server CA certificate and
    # save it to cp4d_config/certs/<instance>/ for secure external connections.
    EDB_CERT_PATH=""
    if [[ "${PREPARE_TLS}" == "true" ]]; then
        CERT_DIR="${CERTS_ROOT}/${INSTANCE}"

        # The CA cert lives in the dedicated <instance>-edb-db-ca secret (key ca.crt).
        EDB_CA_CRT=""
        CA_SECRET="${INSTANCE}-edb-db-ca"
        if oc get secret "${CA_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
            EDB_CA_CRT=$(oc get secret "${CA_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
                -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d || true)
        fi

        # Fall back to the -app secret in case a build publishes ca.crt there.
        if [[ -z "${EDB_CA_CRT:-}" ]]; then
            EDB_CA_CRT=$(oc get secret "${APP_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
                -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d || true)
        fi

        if [[ -n "${EDB_CA_CRT:-}" ]]; then
            mkdir -p "${CERT_DIR}"
            EDB_CERT_PATH="${CERT_DIR}/ca.crt"
            print -r -- "${EDB_CA_CRT}" > "${EDB_CERT_PATH}"
            chmod 600 "${EDB_CERT_PATH}"
            echo "  [OK] CA certificate saved to ${EDB_CERT_PATH}"
        else
            echo "  [WARN] No CA certificate found for '${INSTANCE}'. Skipping cert export."
        fi
    fi

    # Build an sslmode=verify-full external URI when both the route and cert exist.
    if [[ -n "${EDB_ROUTE_URI:-}" && -n "${EDB_CERT_PATH:-}" ]]; then
        EDB_ROUTE_URI_TLS="${EDB_ROUTE_URI}?sslmode=verify-full&sslrootcert=${EDB_CERT_PATH}"
    else
        EDB_ROUTE_URI_TLS=""
    fi

    echo "  Username : ${EDB_USERNAME}"
    echo "  DB Name  : ${EDB_DBNAME}"
    echo "  Local Port: ${EDB_LOCAL_PORT}"
    echo "  Route Host: ${ROUTE_HOST:-[not found]}"
    echo ""

    EDB_BLOCK+="
#--- EDB Postgres - ${INSTANCE}
export ${VAR_PREFIX}_PASSWORD=\"${EDB_PASSWORD}\"
export ${VAR_PREFIX}_USERNAME=\"${EDB_USERNAME}\"
export ${VAR_PREFIX}_DBNAME=\"${EDB_DBNAME}\"
export ${VAR_PREFIX}_LOCAL_PORT=\"${EDB_LOCAL_PORT}\"
export ${VAR_PREFIX}_LOCAL_URI=\"${EDB_LOCAL_URI}\"
export ${VAR_PREFIX}_ROUTE_PORT=\"443\"
export ${VAR_PREFIX}_ROUTE_URI=\"${EDB_ROUTE_URI}\"
export ${VAR_PREFIX}_SSLROOTCERT=\"${EDB_CERT_PATH}\"
export ${VAR_PREFIX}_ROUTE_URI_TLS=\"${EDB_ROUTE_URI_TLS}\""
done

if [[ -f "${VARS_FILE}" ]]; then
    echo "${EDB_BLOCK}" >> "${VARS_FILE}"
    echo "[INFO] EDB Postgres credentials appended to ${VARS_FILE##*/}"
else
    mkdir -p "$(dirname "${VARS_FILE}")"
    echo "${EDB_BLOCK}" > "${VARS_FILE}"
    echo "[INFO] EDB Postgres credentials written to ${VARS_FILE##*/}"
fi

echo ""
echo "=== Done ==="
