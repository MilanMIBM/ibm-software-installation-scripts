#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

for var in CPDM_OC_LOGIN PROJECT_CPD_INST_OPERANDS PROJECT_CPD_INST_OPERATORS; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${CPDM_OC_LOGIN}"

# =============================================================================
# DataStax HCD (Hyper-Converged Database) instance provisioning
# -----------------------------------------------------------------------------
# Unlike the other 4.5_* provisioners, this one does NOT use
# "cpd-cli service-instance create". DataStax is not exposed as a zen addon
# with a provisionable payload - it is driven entirely by a MissionControlCluster
# custom resource.
#
# Verified against the live cluster on 2026-09-22 (CPD 5.4, DataStax 2.4.5):
#   - The watsonx.data UI writes exactly one MissionControlCluster CR. The
#     managedFields manager on the existing cluster is "restapi-server", i.e.
#     the Mission Control REST API inside the datastax-mc-ui pod.
#   - That REST API is built with -embedded-mode=true, which COMPILES OUT the
#     cluster-management routes. /v1/projects and /v1/project/{ns}/clusters
#     return 404 unauthenticated while /v1/auth/activeuser returns 401 - a Gin
#     router returns 401 for registered-but-unauthorised routes, so the 404s
#     prove those handlers do not exist in the binary. No token unlocks them.
#   - Therefore the CR *is* the programmatic interface. Everything below
#     (K8ssandraCluster -> CassandraDatacenter -> StatefulSet/Reaper/DataApi/
#     CqlConnectivity) is created by the operators as a cascade.
#
# The operators reconcile ONLY these namespaces:
#     WATCH_NAMESPACE=cpd-operators,cpd-operands
# A CR created anywhere else passes admission and is then silently ignored
# forever, so DS_NAMESPACE is validated against that list below.
# =============================================================================

# --- Shared configuration
DS_NAMESPACE="${DS_NAMESPACE:-${PROJECT_CPD_INST_OPERANDS}}"
DS_OPERATOR_NAMESPACE="${DS_OPERATOR_NAMESPACE:-${PROJECT_CPD_INST_OPERATORS}}"

# Set to true to print the rendered CR and exit without applying anything.
DS_DRY_RUN="${DS_DRY_RUN:-false}"
# Set to false to return as soon as the CR is applied instead of waiting.
DS_WAIT_FOR_READY="${DS_WAIT_FOR_READY:-true}"
DS_WAIT_TIMEOUT_SECONDS="${DS_WAIT_TIMEOUT_SECONDS:-2400}"

# --- Configuration - cluster identity
# DS_CLUSTER_NAME is the MissionControlCluster name, DS_DATACENTER_NAME the DC
# inside it. Both must be valid DNS labels; the DC name is baked into pod and
# service names, so keep it short.
#
# Leave either unset to auto-generate. The existing instance is named
# datastax929 / dc929, so the pattern is <prefix><NNN> / dc<NNN> with a shared
# 3-digit suffix. The suffix is picked below as the lowest free number that
# collides with nothing in the watched namespaces.
DS_NAME_PREFIX="${DS_NAME_PREFIX:-datastax}"
DS_DC_PREFIX="${DS_DC_PREFIX:-dc}"
DS_RACK_NAME="${DS_RACK_NAME:-defaultrack}"

# --- Configuration - server version
# Do NOT set an explicit image here. serverType/serverVersion are resolved
# through the datastax-mc-image-config ConfigMap in the operator namespace,
# which carries "overrides.registry: cp.icr.io". That override is what rewrites
# the raw AWS ECR addresses still present in that ConfigMap (cql-router, cqlsh,
# and the hcd type default all point at 559669398656.dkr.ecr.us-west-2...)
# onto the entitled IBM registry. Pinning an image bypasses the override.
#
# NOTE: the validating webhook does NOT check this value - a bogus version is
# accepted at apply time and only fails later at image pull. It is checked
# against the image-config ConfigMap below instead.
DS_SERVER_TYPE="${DS_SERVER_TYPE:-hcd}"
DS_SERVER_VERSION="${DS_SERVER_VERSION:-2.0.6}"

# --- Configuration - topology and sizing
#
# DS_SIZE_PROFILE selects a preset: Small | Medium | Large | custom
#
# These are NOT operator or CRD defaults - the CRD defines no t-shirt sizes and
# a dry-run of a CR with no resources/storageConfig confirms the operator
# injects nothing (only "stopped: false"). They are the watsonx.data console's
# own presets, lifted verbatim from getDatastaxSizes() in the shipped UI bundle
# (lhconsole-ui:/usr/share/nginx/html/static/js/652.*.chunk.js) on 2026-09-22:
#
#   Small    heap=8   cpu=4   memory=24   nodes=3
#   Medium   heap=16  cpu=16  memory=60   nodes=6
#   Large    heap=31  cpu=16  memory=60   nodes=6
#
# Medium and Large differ ONLY in heap size - cpu, memory and node count are
# identical. That is genuinely what the console ships. Its own description
# strings (AddService.datastaxMediumDescription / ...LargeDescription) are
# byte-identical and mention neither heap nor node count, so they read as a
# copy-paste slip in IBM's en.json; the numbers above are from the code that
# actually builds the request, not from those strings.
#
# The console's node counts (3/6/6) are its production recommendations. This
# script defaults to Small with DS_SIZE=1 for a single-node dev instance,
# matching the existing datastax929 instance. Set DS_SIZE explicitly (or
# DS_USE_PROFILE_NODES=true) to take the console's node count instead.
#
# Storage is not in the preset table - the console asks separately, and the
# descriptions only give a "recommended up to" ceiling (256GB Small,
# 512GB Medium/Large). DS_STORAGE_GI stays independently set.
DS_SIZE_PROFILE="${DS_SIZE_PROFILE:-Small}"
DS_USE_PROFILE_NODES="${DS_USE_PROFILE_NODES:-false}"

case "${DS_SIZE_PROFILE:l}" in
    small)
        _DS_P_CPU=4;  _DS_P_MEM=24; _DS_P_HEAP=8;  _DS_P_NODES=3;  _DS_P_STORAGE=256 ;;
    medium)
        _DS_P_CPU=16; _DS_P_MEM=60; _DS_P_HEAP=16; _DS_P_NODES=6;  _DS_P_STORAGE=512 ;;
    large)
        _DS_P_CPU=16; _DS_P_MEM=60; _DS_P_HEAP=31; _DS_P_NODES=6;  _DS_P_STORAGE=512 ;;
    custom)
        # Every value must come from the environment; the fallbacks below are
        # the Small preset so a partially-specified custom profile still runs.
        _DS_P_CPU=4;  _DS_P_MEM=24; _DS_P_HEAP=8;  _DS_P_NODES=1;  _DS_P_STORAGE=10 ;;
    *)
        echo "Error: DS_SIZE_PROFILE='${DS_SIZE_PROFILE}' is not valid. Use: Small | Medium | Large | custom"
        exit 1 ;;
esac

# Explicit env vars always win over the preset.
DS_CPU="${DS_CPU:-${_DS_P_CPU}}"            # requests == limits (Guaranteed QoS)
DS_MEMORY_GI="${DS_MEMORY_GI:-${_DS_P_MEM}}"
DS_HEAP_GI="${DS_HEAP_GI:-${_DS_P_HEAP}}"   # keep well under DS_MEMORY_GI - off-heap needs the rest

if [[ "${DS_USE_PROFILE_NODES}" == "true" ]]; then
    DS_SIZE="${DS_SIZE:-${_DS_P_NODES}}"    # nodes in the datacenter
else
    DS_SIZE="${DS_SIZE:-1}"
fi

DS_STORAGE_GI="${DS_STORAGE_GI:-10}"
DS_STORAGE_CLASS="${DS_STORAGE_CLASS:-${STG_CLASS_BLOCK}}"

# Heap must leave room for off-heap structures; HCD will not start with a heap
# at or above the container limit, and the kubelet OOM-kills before Cassandra
# can report anything useful.
if (( DS_HEAP_GI >= DS_MEMORY_GI )); then
    echo "Error: DS_HEAP_GI (${DS_HEAP_GI}Gi) must be less than DS_MEMORY_GI (${DS_MEMORY_GI}Gi)."
    exit 1
fi

if (( DS_STORAGE_GI > _DS_P_STORAGE )); then
    echo "[WARN] DS_STORAGE_GI=${DS_STORAGE_GI}Gi exceeds the ${DS_SIZE_PROFILE} profile's recommended ceiling of ${_DS_P_STORAGE}GB."
fi

# --- Configuration - features
DS_AUTH_ENABLED="${DS_AUTH_ENABLED:-true}"
DS_ENCRYPTION_ENABLED="${DS_ENCRYPTION_ENABLED:-true}"  # internode + mgmt-api TLS, certs auto-created
DS_REAPER_ENABLED="${DS_REAPER_ENABLED:-true}"          # anti-entropy repair scheduler

# --- Configuration - CP4D licence metering annotations
# Verified: admission does NOT enforce these (a CR with no annotations passes
# all three validating webhooks). They are carried purely so the instance is
# attributed correctly in IBM licence reporting - keep them accurate.
DS_PRODUCT_VERSION="${DS_PRODUCT_VERSION:-2.4.5}"
DS_CLOUDPAK_INSTANCE_ID="${DS_CLOUDPAK_INSTANCE_ID:-}"

# --- Auto-generate the 3-digit suffix
# Nothing here is hardcoded: the range is derived from what is actually on the
# cluster. Every watched namespace is scanned for existing MissionControlCluster
# and CassandraDatacenter names, the 3-digit suffixes are extracted from those
# that match our prefixes, and the next number after the highest one wins. On a
# cluster with nothing installed the search simply starts at 100 (the lowest
# 3-digit value).
#
# CassandraDatacenters are scanned as well as MissionControlClusters: a DC name
# is reused in StatefulSet and Service names, and a collision there surfaces as
# a confusing mid-reconcile failure rather than a clean rejection.
#
# A candidate is rejected unless BOTH the cluster name and the datacenter name
# are free, so the pair always shares one suffix.
if [[ -z "${DS_CLUSTER_NAME:-}" || -z "${DS_DATACENTER_NAME:-}" ]]; then
    _ds_ns_list="${PROJECT_CPD_INST_OPERANDS},${PROJECT_CPD_INST_OPERATORS}"

    _ds_taken="$(
        for _ns in ${(s:,:)_ds_ns_list}; do
            oc get missioncontrolclusters.missioncontrol.datastax.com -n "${_ns}" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
            oc get cassandradatacenters.cassandra.datastax.com -n "${_ns}" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
        done
    )"

    # Pull the 3-digit suffix off every name that uses one of our prefixes.
    # Names that do not match (hand-made clusters with arbitrary names) still
    # block their exact string via the collision check below - they just do not
    # influence where the search starts.
    _ds_used_nums="$(
        print -r -- "${_ds_taken}" \
            | sed -n -E "s/^(${DS_NAME_PREFIX}|${DS_DC_PREFIX})([0-9]{3})$/\2/p" \
            | sort -un
    )"

    if [[ -n "${_ds_used_nums}" ]]; then
        _ds_start=$(( $(print -r -- "${_ds_used_nums}" | tail -1) + 1 ))
    else
        _ds_start=100
    fi
    (( _ds_start < 100 )) && _ds_start=100

    _ds_found=""
    for (( _n = _ds_start; _n <= 999; _n++ )); do
        _ds_try_cluster="${DS_NAME_PREFIX}${_n}"
        _ds_try_dc="${DS_DC_PREFIX}${_n}"
        if ! print -r -- "${_ds_taken}" | grep -qx -e "${_ds_try_cluster}" -e "${_ds_try_dc}"; then
            _ds_found="${_n}"
            break
        fi
    done

    if [[ -z "${_ds_found}" ]]; then
        echo "Error: no free 3-digit suffix at or above ${_ds_start} for prefix '${DS_NAME_PREFIX}'."
        echo "       Set DS_CLUSTER_NAME and DS_DATACENTER_NAME explicitly."
        exit 1
    fi

    DS_CLUSTER_NAME="${DS_CLUSTER_NAME:-${DS_NAME_PREFIX}${_ds_found}}"
    DS_DATACENTER_NAME="${DS_DATACENTER_NAME:-${DS_DC_PREFIX}${_ds_found}}"
    echo "[INFO] Auto-generated names: ${DS_CLUSTER_NAME} / ${DS_DATACENTER_NAME}"
    echo "[INFO]   existing suffixes: ${${_ds_used_nums//$'\n'/ }:-<none>} -> next free ${_ds_found}"
    unset _ds_ns_list _ds_taken _ds_used_nums _ds_start _ds_found _ds_try_cluster _ds_try_dc _n _ns
fi

echo "[INFO] Cluster     : ${DS_CLUSTER_NAME} (datacenter ${DS_DATACENTER_NAME})"
echo "[INFO] Namespace   : ${DS_NAMESPACE}"
echo "[INFO] Server      : ${DS_SERVER_TYPE} ${DS_SERVER_VERSION}"
echo "[INFO] Profile     : ${DS_SIZE_PROFILE}"
echo "[INFO] Topology    : ${DS_SIZE} node(s), ${DS_CPU} CPU / ${DS_MEMORY_GI}Gi each, ${DS_HEAP_GI}Gi heap"
echo "[INFO] Storage     : ${DS_STORAGE_GI}Gi on ${DS_STORAGE_CLASS}"

# --- Guard: the operators only watch a fixed namespace list.
DS_WATCHED_NAMESPACES="$(oc get deploy datastax-mc-mc-operator -n "${DS_OPERATOR_NAMESPACE}" \
    -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="WATCH_NAMESPACE")]}{.value}{end}' 2>/dev/null || echo "")"

if [[ -z "${DS_WATCHED_NAMESPACES}" ]]; then
    echo "Error: could not read WATCH_NAMESPACE from datastax-mc-mc-operator in ${DS_OPERATOR_NAMESPACE}."
    echo "       Is the DataStax add-on installed? Check: oc get deploy -n ${DS_OPERATOR_NAMESPACE} | grep datastax"
    exit 1
fi

if [[ ",${DS_WATCHED_NAMESPACES}," != *",${DS_NAMESPACE},"* ]]; then
    echo "Error: namespace '${DS_NAMESPACE}' is not watched by the DataStax operators."
    echo "       Watched namespaces: ${DS_WATCHED_NAMESPACES}"
    echo "       A CR outside this list is ACCEPTED by admission and then never reconciled."
    exit 1
fi
echo "[INFO] Operators watch: ${DS_WATCHED_NAMESPACES} - '${DS_NAMESPACE}' is reconciled."

# --- Guard: storage class must exist, otherwise the PVC pends forever.
if ! oc get storageclass "${DS_STORAGE_CLASS}" >/dev/null 2>&1; then
    echo "Error: storage class '${DS_STORAGE_CLASS}' does not exist on this cluster."
    echo "       Available:"
    oc get storageclass --no-headers 2>/dev/null | awk '{print "         " $1}'
    exit 1
fi

# --- Guard: the requested server version must be the one the image-config can
# resolve. The webhook does not check this, so catch it here rather than at pull.
DS_IMAGE_CONFIG="$(oc get cm datastax-mc-image-config -n "${DS_OPERATOR_NAMESPACE}" \
    -o jsonpath='{.data.image_config\.yaml}' 2>/dev/null || echo "")"

if [[ -n "${DS_IMAGE_CONFIG}" ]]; then
    # The "hcd:" block in image-config carries the tag the operator will use,
    # e.g. "tag: 2.0.6-ubi" for serverVersion 2.0.6.
    if ! print -r -- "${DS_IMAGE_CONFIG}" | grep -q "${DS_SERVER_VERSION}"; then
        echo "[WARN] '${DS_SERVER_VERSION}' does not appear in datastax-mc-image-config."
        echo "[WARN] The validating webhook will NOT reject this - it fails later at image pull."
        echo "[WARN] Tags present in image-config:"
        print -r -- "${DS_IMAGE_CONFIG}" | grep -E "^\s+tag:" | sort -u | sed 's/^/         /'
    fi
fi

# --- Guard: refuse to silently mutate an existing cluster.
# Re-applying over a live MissionControlCluster can trigger a rolling restart of
# the StatefulSet, so an existing CR is an explicit opt-in via DS_ALLOW_UPDATE.
DS_ALLOW_UPDATE="${DS_ALLOW_UPDATE:-false}"
if oc get missioncontrolclusters.missioncontrol.datastax.com "${DS_CLUSTER_NAME}" \
        -n "${DS_NAMESPACE}" >/dev/null 2>&1; then
    if [[ "${DS_ALLOW_UPDATE}" != "true" ]]; then
        DS_EXISTING_STATUS="$(oc get missioncontrolclusters.missioncontrol.datastax.com "${DS_CLUSTER_NAME}" \
            -n "${DS_NAMESPACE}" -o jsonpath='{.status.status}' 2>/dev/null || echo "unknown")"
        echo "Error: MissionControlCluster '${DS_CLUSTER_NAME}' already exists in ${DS_NAMESPACE} (status: ${DS_EXISTING_STATUS})."
        echo "       Re-applying can roll the StatefulSet. Set DS_ALLOW_UPDATE=true to proceed,"
        echo "       or pick a different DS_CLUSTER_NAME."
        exit 1
    fi
    echo "[WARN] '${DS_CLUSTER_NAME}' exists and DS_ALLOW_UPDATE=true - applying over it may roll the StatefulSet."
fi

# --- Render the CR
export DS_PAYLOAD_FILE="${SERVICE_INSTANCE_FILE_DIR}/datastax-${DS_CLUSTER_NAME}-instance.yaml"

# Optional blocks are assembled first so the heredoc below stays flat. Every
# fragment is indented to sit under spec.* at the right depth.
if [[ "${DS_ENCRYPTION_ENABLED}" == "true" ]]; then
    DS_ENCRYPTION_BLOCK="  createIssuer: true
  encryption:
    internodeEncryption:
      enabled: true
      certs:
        createCerts: true
    managementApiAuthEncryption:
      enabled: true
      certs:
        createCerts: true"
else
    DS_ENCRYPTION_BLOCK="  createIssuer: false"
fi

if [[ "${DS_REAPER_ENABLED}" == "true" ]]; then
    # storageType local + a PVC is what the working instance uses; reaper keeps
    # its own schema in the cluster (keyspace reaper_db) but needs local scratch.
    DS_REAPER_BLOCK="    reaper:
      deploymentMode: SINGLE
      heapSize: 2Gi
      keyspace: reaper_db
      secretsProvider: internal
      skipSchemaMigration: false
      storageType: local
      httpManagement:
        enabled: true
      storageConfig:
        accessModes:
        - ReadWriteOnce
        storageClassName: ${DS_STORAGE_CLASS}
        resources:
          requests:
            storage: 1Gi"
else
    DS_REAPER_BLOCK=""
fi

if [[ -n "${DS_CLOUDPAK_INSTANCE_ID}" ]]; then
    DS_INSTANCE_ID_ANNOTATION="    cloudpakInstanceId: \"${DS_CLOUDPAK_INSTANCE_ID}\""
else
    DS_INSTANCE_ID_ANNOTATION=""
fi

# Single-quoted delimiter: no shell expansion happens inside the heredoc body
# itself. Substitution is done explicitly below so a stray character in a
# rendered value can never terminate the document early.
cat > "${DS_PAYLOAD_FILE}" <<EOF
apiVersion: missioncontrol.datastax.com/v1beta2
kind: MissionControlCluster
metadata:
  name: ${DS_CLUSTER_NAME}
  namespace: ${DS_NAMESPACE}
  annotations:
    productName: DataStax Hyper-Converged Database
    productVersion: "${DS_PRODUCT_VERSION}"
    productMetric: VIRTUAL_PROCESSOR_CORE
    productChargedContainers: All
${DS_INSTANCE_ID_ANNOTATION}
spec:
${DS_ENCRYPTION_BLOCK}
  k8ssandra:
    auth: ${DS_AUTH_ENABLED}
    secretsProvider: internal
${DS_REAPER_BLOCK}
    cassandra:
      serverType: ${DS_SERVER_TYPE}
      serverVersion: "${DS_SERVER_VERSION}"
      readOnlyRootFilesystem: true
      podSecurityContext:
        runAsNonRoot: true
      resources:
        requests:
          cpu: "${DS_CPU}"
          memory: ${DS_MEMORY_GI}Gi
        limits:
          cpu: "${DS_CPU}"
          memory: ${DS_MEMORY_GI}Gi
      config:
        jvmOptions:
          gc: G1GC
          heapSize: ${DS_HEAP_GI}Gi
      storageConfig:
        cassandraDataVolumeClaimSpec:
          accessModes:
          - ReadWriteOnce
          storageClassName: ${DS_STORAGE_CLASS}
          resources:
            requests:
              storage: ${DS_STORAGE_GI}Gi
      datacenters:
      - metadata:
          name: ${DS_DATACENTER_NAME}
        datacenterName: ${DS_DATACENTER_NAME}
        size: ${DS_SIZE}
        stopped: false
        racks:
        - name: ${DS_RACK_NAME}
EOF

# Strip blank lines left behind by empty optional blocks so the YAML stays clean.
sed -i '' '/^[[:space:]]*$/d' "${DS_PAYLOAD_FILE}" 2>/dev/null || sed -i '/^[[:space:]]*$/d' "${DS_PAYLOAD_FILE}"

echo "[INFO] Rendered CR: ${DS_PAYLOAD_FILE}"

# --- Validate through the real admission chain before committing to anything.
# There are three validating webhooks in play (vmissioncontrolcluster,
# vk8ssandracluster, vcassandradatacenter), all failurePolicy: Fail. A
# server-side dry-run exercises every one of them without creating an object.
echo "[INFO] Validating against the live admission chain (server dry-run)..."
if ! oc apply --dry-run=server -f "${DS_PAYLOAD_FILE}"; then
    echo "Error: the rendered CR was rejected by admission. Nothing was created."
    echo "       Review ${DS_PAYLOAD_FILE}"
    exit 1
fi

if [[ "${DS_DRY_RUN}" == "true" ]]; then
    echo
    echo "[INFO] DS_DRY_RUN=true - validated only, nothing applied. Rendered CR:"
    echo "-------------------------------------------------------------------"
    cat "${DS_PAYLOAD_FILE}"
    echo "-------------------------------------------------------------------"
    exit 0
fi

# --- Apply
oc apply -f "${DS_PAYLOAD_FILE}"
echo "[INFO] Applied MissionControlCluster/${DS_CLUSTER_NAME} in ${DS_NAMESPACE}."

if [[ "${DS_WAIT_FOR_READY}" != "true" ]]; then
    echo "[INFO] DS_WAIT_FOR_READY=false - not waiting. Track progress with:"
    echo "         oc get missioncontrolclusters ${DS_CLUSTER_NAME} -n ${DS_NAMESPACE} -o jsonpath='{.status.progress}'"
    exit 0
fi

# --- Wait for reconcile
# The CR reports .status.status / .status.progress. A fresh single-node cluster
# takes roughly 15-20 minutes: image pull, cert issuance, bootstrap, then the
# Reaper/DataApi/CqlConnectivity cascade.
echo "[INFO] Waiting up to ${DS_WAIT_TIMEOUT_SECONDS}s for ${DS_CLUSTER_NAME} to become Ready..."
DS_DEADLINE=$(( SECONDS + DS_WAIT_TIMEOUT_SECONDS ))
DS_LAST_REPORT=""

while (( SECONDS < DS_DEADLINE )); do
    DS_STATUS="$(oc get missioncontrolclusters.missioncontrol.datastax.com "${DS_CLUSTER_NAME}" \
        -n "${DS_NAMESPACE}" -o jsonpath='{.status.status}' 2>/dev/null || echo "")"
    DS_PROGRESS="$(oc get missioncontrolclusters.missioncontrol.datastax.com "${DS_CLUSTER_NAME}" \
        -n "${DS_NAMESPACE}" -o jsonpath='{.status.progress}' 2>/dev/null || echo "")"
    DS_MESSAGE="$(oc get missioncontrolclusters.missioncontrol.datastax.com "${DS_CLUSTER_NAME}" \
        -n "${DS_NAMESPACE}" -o jsonpath='{.status.progressMessage}' 2>/dev/null || echo "")"

    DS_REPORT="${DS_STATUS}|${DS_PROGRESS}|${DS_MESSAGE}"
    if [[ "${DS_REPORT}" != "${DS_LAST_REPORT}" ]]; then
        echo "[WAIT] status=${DS_STATUS:-<pending>} progress=${DS_PROGRESS:-0%} ${DS_MESSAGE:+- ${DS_MESSAGE}}"
        DS_LAST_REPORT="${DS_REPORT}"
    fi

    if [[ "${DS_STATUS}" == "Ready" ]]; then
        echo "[INFO] Cluster ${DS_CLUSTER_NAME} is Ready."
        break
    fi

    sleep 20
done

if [[ "${DS_STATUS:-}" != "Ready" ]]; then
    echo "[WARN] ${DS_CLUSTER_NAME} did not reach Ready within ${DS_WAIT_TIMEOUT_SECONDS}s (last status: ${DS_STATUS:-<pending>})."
    echo "[WARN] This is not necessarily a failure - large clusters take longer. Inspect with:"
    echo "         oc get missioncontrolclusters ${DS_CLUSTER_NAME} -n ${DS_NAMESPACE} -o yaml"
    echo "         oc get pods -n ${DS_NAMESPACE} | grep ${DS_DATACENTER_NAME}"
    exit 1
fi

# --- Report what the operators built
echo
echo "=== Provisioned resources for ${DS_CLUSTER_NAME} ==="
oc get missioncontrolclusters.missioncontrol.datastax.com "${DS_CLUSTER_NAME}" -n "${DS_NAMESPACE}" 2>/dev/null || true
echo
oc get cassandradatacenters.cassandra.datastax.com -n "${DS_NAMESPACE}" 2>/dev/null | grep -E "NAME|${DS_DATACENTER_NAME}" || true
echo
oc get pods -n "${DS_NAMESPACE}" --no-headers 2>/dev/null | grep "${DS_DATACENTER_NAME}" || true

# The superuser secret is generated by the operator when auth is enabled. Its
# name follows <cluster>-superuser. Print how to read it rather than the value.
if [[ "${DS_AUTH_ENABLED}" == "true" ]]; then
    echo
    echo "[INFO] Superuser credentials (auth is enabled):"
    echo "         oc get secret ${DS_CLUSTER_NAME}-superuser -n ${DS_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d"
    echo "         oc get secret ${DS_CLUSTER_NAME}-superuser -n ${DS_NAMESPACE} -o jsonpath='{.data.password}' | base64 -d"
fi

echo
echo "[INFO] Done. CR retained at ${DS_PAYLOAD_FILE}"
