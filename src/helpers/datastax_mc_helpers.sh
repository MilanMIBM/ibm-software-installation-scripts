#!/bin/zsh
# =============================================================================
# datastax_mc_helpers.sh - shared functions for the standalone DataStax Mission
# Control install (scripts/install_datastax_mc_standalone/).
# -----------------------------------------------------------------------------
# Source after the env_bootstrap line:
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
#     mc_require_config
#
# Must be SOURCED. Safe to source more than once.
# =============================================================================

[[ -n "${_MC_HELPERS_LOADED:-}" ]] && return 0
_MC_HELPERS_LOADED=1

autoload -Uz is-at-least
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/cli_install_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/version_resolver.sh"

mc_info()  { h_info "$@"; }
mc_warn()  { h_warn "$@"; }
mc_error() { h_error "$@"; }
mc_die()   { h_die "$@"; }
mc_is_true() { h_is_true "$@"; }

# Downloaded tools (pinned helm) and rendered scratch files. Gitignored.
export MC_WORKSPACE="${MC_WORKSPACE:-${_CP4D_REPO_ROOT}/datastax_mc_workspace}"
# Generated values files and instance details live next to the loaded config.
if [[ "${ENV_TARGET_FILE:-}" == *datastax_mc_vars.sh ]]; then
    export MC_CONFIG_DIR="${ENV_TARGET_FILE:h}"
else
    export MC_CONFIG_DIR="${DATASTAX_MC_CONFIG_DIR:-${_CP4D_REPO_ROOT}/configs/datastax_mc_config}"
fi
# DataStax's OpenShift Helm values files with **TOKEN** placeholders, filled in
# by 2.0_render_values.sh (source URL and local changes in each file's header).
export MC_VALUES_SRC_DIR="${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helm_values_templates"

mc_require_vars() {
    h_missing_vars "$@" || mc_die "Not set in datastax_mc_vars.sh: ${REPLY}"
}

# The config must be the DataStax MC one - never fall back to cpd_vars.sh,
# which may point at a different cluster.
mc_require_config() {
    if [[ "${ENV_TARGET_FILE:-}" != *datastax_mc_vars.sh ]]; then
        mc_die "configs/datastax_mc_config/datastax_mc_vars.sh is not loaded (ENV_TARGET=${ENV_TARGET:-unset})." \
               "Create it with scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh"
    fi
    mc_require_vars OCP_URL OC_LOGIN MC_VERSION MC_RELEASE_NAME MC_NAMESPACE MC_PLANE MC_SCC_MODE
    # DataStax's OpenShift values hard-code "mission-control-*" service names
    # (Dex issuer, Mimir ruler -> alertmanager/query-frontend), and with any
    # other release name the chart renames its own resources to
    # <release>-mission-control-*. Only this name renders consistently.
    [[ "${MC_RELEASE_NAME}" == mission-control ]] \
        || mc_die "MC_RELEASE_NAME must be 'mission-control' (got '${MC_RELEASE_NAME}'): DataStax's OpenShift values hard-code service names for that release."
    [[ "${MC_PLANE}" == (control|data) ]] || mc_die "MC_PLANE must be 'control' or 'data' (got '${MC_PLANE}')."
    [[ "${MC_SCC_MODE}" == (nonroot-v2|restricted-v2|custom) ]] \
        || mc_die "MC_SCC_MODE must be nonroot-v2, restricted-v2 or custom (got '${MC_SCC_MODE}')."
}

# -----------------------------------------------------------------------------
# Helm: DataStax supports Helm 3.14.0 - 3.18.x only (version_catalog.json
# helm/mission_control_*, read once into MC_HELM_MIN / MC_HELM_MAX). A helm on PATH in that
# range is used as is; otherwise MC_HELM_VERSION is downloaded (checksum
# verified, by src/utilities/cli_tool_utils/install_helm.sh) into
# ${MC_WORKSPACE}/tools/, which stays off PATH. Sets and exports MC_HELM.
# -----------------------------------------------------------------------------
mc_helm_version_of() {
    "$1" version --template '{{.Version}}' 2>/dev/null | sed 's/^v//'
}

mc_helm_version_ok() {
    local v="$1"
    : "${MC_HELM_MIN:=$(vr_catalog helm/mission_control_min)}" "${MC_HELM_MAX:=$(vr_catalog helm/mission_control_max_exclusive)}"
    [[ -n "${v}" ]] && is-at-least "${MC_HELM_MIN}" "${v}" && ! is-at-least "${MC_HELM_MAX}" "${v}"
}

mc_ensure_helm() {
    if [[ -n "${MC_HELM:-}" && -x "${MC_HELM}" ]] && mc_helm_version_ok "$(mc_helm_version_of "${MC_HELM}")"; then
        return 0
    fi

    local path_helm path_ver
    path_helm="$(command -v helm 2>/dev/null || true)"
    if [[ -n "${path_helm}" ]]; then
        path_ver="$(mc_helm_version_of "${path_helm}")"
        if mc_helm_version_ok "${path_ver}"; then
            export MC_HELM="${path_helm}"
            return 0
        fi
        mc_info "helm on PATH is ${path_ver:-unknown}; Mission Control needs ${MC_HELM_MIN} up to (not incl.) ${MC_HELM_MAX}. Using a pinned ${MC_HELM_VERSION:-$(vr_catalog helm/pinned_version)}."
    fi

    local ver="v${${MC_HELM_VERSION:-$(vr_catalog helm/pinned_version)}#v}" os arch
    os="$(cli_os)" && arch="$(cli_arch)" || mc_die "No helm download for this platform."

    local dir="${MC_WORKSPACE}/tools/helm-${ver}-${os}-${arch}"
    local bin="${dir}/helm$(cli_exe_suffix)"
    if [[ ! -x "${bin}" ]]; then
        mc_info "Downloading helm ${ver} (${os}-${arch})..."
        zsh "${_CP4D_REPO_ROOT}/src/utilities/cli_tool_utils/install_helm.sh" \
            --version "${ver}" --dir "${dir}" --force --yes --no-path-check \
            || mc_die "helm ${ver} download failed."
    fi
    export MC_HELM="${bin}"
}

# -----------------------------------------------------------------------------
# Service accounts for release ${MC_RELEASE_NAME}: the list from the DataStax
# OpenShift docs plus the names chart 1.21 actually creates (helm template:
# <release>-loki rather than loki, minio-sa, <release>-crd-upgrader). Granting
# an SCC to a service account that does not exist yet is harmless, so the
# union covers both older and newer charts.
#
# The grant matters most for <release>-loki: the chart's own ClusterRoleBinding
# (<release>-openshift-scc, anyuid + nonroot-v2) names "loki", but Loki's pods
# run as <release>-loki, so without 1.4 they only get restricted-v2 and their
# fixed UID 10001 is rejected.
# -----------------------------------------------------------------------------
mc_service_accounts() {
    local r="${MC_RELEASE_NAME}"
    print -l -- loki "${r}-loki" "${r}" "${r}-agent" "${r}-aggregator" "${r}-cass-operator" \
        "${r}-dex" "${r}-k8ssandra-operator" "${r}-kube-state-metrics" "${r}-mimir" \
        "${r}-crd-upgrader" minio-sa
}

# Service accounts whose pods keep fixed UIDs even with the restricted-v2
# overrides (checked with helm template on chart 1.21.2: Loki 10001, its
# gateway 101, kube-state-metrics 65534, Mimir and MinIO 1000). They keep
# nonroot-v2 in restricted-v2 mode; the operators, UI, Dex and the Vector
# aggregator move to dynamic UIDs.
mc_fixed_uid_service_accounts() {
    local r="${MC_RELEASE_NAME}"
    print -l -- loki "${r}-loki" "${r}-kube-state-metrics" "${r}-mimir" minio-sa
}

# -----------------------------------------------------------------------------
# bcrypt hash for the Dex static admin password, as the DataStax docs make it
# (htpasswd -BinC 10). Falls back to the python bcrypt module.
# -----------------------------------------------------------------------------
mc_bcrypt() {
    local password="$1" hash=""
    if command -v htpasswd >/dev/null 2>&1; then
        hash="$(print -rn -- "${password}" | htpasswd -BinC 10 admin | cut -d: -f2)"
    else
        hash="$(MC_PW="${password}" python3 -c 'import bcrypt, os; print(bcrypt.hashpw(os.environ["MC_PW"].encode(), bcrypt.gensalt(10)).decode())' 2>/dev/null || true)"
    fi
    [[ "${hash}" == \$2* ]] || mc_die "Could not bcrypt the admin password: install htpasswd (httpd-tools / apache2-utils) or the python bcrypt module."
    print -r -- "${hash}"
}

# A YAML double-quoted scalar (valid JSON string) for any value.
mc_yaml_str() {
    MC_V="$1" python3 -c 'import json, os; print(json.dumps(os.environ["MC_V"]))'
}

mc_random_password() { h_random_password "$@"; }

# -----------------------------------------------------------------------------
# mc_resolve_datacenter [project] [datacenter-cr]
# -----------------------------------------------------------------------------
# Find the database datacenter a post-install script acts on and export:
#   MC_DB_PROJECT          project namespace
#   MC_DB_DC               CassandraDatacenter resource name (e.g. hcd-standolini)
#   MC_DB_DC_NAME          Cassandra datacenter name drivers see (e.g. standolini)
#   MC_DB_CLUSTER          cluster name (MissionControlCluster / k8ssandra)
#   MC_DB_SUPERUSER_SECRET secret holding the superuser username/password
# Either argument may be empty: it is then picked automatically when there is
# exactly one candidate, otherwise the candidates are listed.
mc_resolve_datacenter() {
    local project="${1:-}" dc="${2:-}" candidates

    if [[ -z "${project}" ]]; then
        candidates=("${(@f)$(oc get cassandradatacenters.cassandra.datastax.com -A \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)}")
        candidates=(${candidates:#})
        (( ${#candidates} == 0 )) && mc_die "No database datacenters found. Create a cluster in the Mission Control UI first."
        (( ${#candidates} > 1 )) && mc_die "Several projects have databases - pass --project (one of: ${candidates[*]})."
        project="${candidates[1]}"
    fi
    oc get namespace "${project}" >/dev/null 2>&1 || mc_die "Project namespace '${project}' not found."

    if [[ -z "${dc}" ]]; then
        candidates=("${(@f)$(oc get cassandradatacenters.cassandra.datastax.com -n "${project}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)}")
        candidates=(${candidates:#})
        (( ${#candidates} == 0 )) && mc_die "No datacenter in project ${project} yet."
        (( ${#candidates} > 1 )) && mc_die "Project ${project} has several datacenters - pass --datacenter (one of: ${candidates[*]})."
        dc="${candidates[1]}"
    fi

    local json
    json="$(oc get cassandradatacenters.cassandra.datastax.com "${dc}" -n "${project}" -o json 2>/dev/null)" \
        || mc_die "Datacenter '${dc}' not found in project ${project}."
    export MC_DB_PROJECT="${project}" MC_DB_DC="${dc}"
    export MC_DB_DC_NAME="$(jq -r '.spec.datacenterName // .metadata.name' <<<"${json}")"
    export MC_DB_CLUSTER="$(jq -r '.spec.clusterName // .metadata.labels["k8ssandra.io/cluster-name"]' <<<"${json}")"

    # The superuser secret is set on the MissionControlCluster; MC's default is <cluster>-superuser.
    local ref
    ref="$(oc get missioncontrolclusters.missioncontrol.datastax.com "${MC_DB_CLUSTER}" -n "${project}" \
        -o jsonpath='{.spec.k8ssandra.cassandra.superuserSecretRef.name}' 2>/dev/null || true)"
    export MC_DB_SUPERUSER_SECRET="${ref:-${MC_DB_CLUSTER}-superuser}"
    oc get secret "${MC_DB_SUPERUSER_SECRET}" -n "${project}" >/dev/null 2>&1 \
        || mc_die "Superuser secret ${project}/${MC_DB_SUPERUSER_SECRET} not found (is authentication enabled on the cluster?)."

    local ready
    ready="$(jq -r '.status.conditions[]? | select(.type == "Ready") | .status' <<<"${json}")"
    [[ "${ready}" == True ]] || mc_warn "Datacenter ${dc} is not Ready yet - continuing, the gateway waits for it."
    mc_info "Datacenter: ${project}/${dc} (Cassandra DC '${MC_DB_DC_NAME}', cluster '${MC_DB_CLUSTER}')"
}

# Decoded value of a key in a secret.
mc_secret_value() {
    oc get secret "$2" -n "$1" -o jsonpath="{.data.${3//./\\.}}" 2>/dev/null | base64 --decode
}

# mc_wait_ready <resource> <name> <namespace> <timeout-seconds>
# Poll until the resource's Ready condition is True.
mc_wait_ready() {
    local res="$1" name="$2" ns="$3" timeout="$4" cond elapsed=0
    while true; do
        cond="$(oc get "${res}" "${name}" -n "${ns}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        [[ "${cond}" == True ]] && return 0
        (( elapsed >= timeout )) && return 1
        sleep 5; (( elapsed += 5 ))
        (( elapsed % 30 == 0 )) && mc_info "  waiting for ${res} ${name} (${elapsed}s)"
    done
}

# =============================================================================
# CQL gateway (CqlConnectivity) - shared by the standalone 3.3 script and the
# watsonx.data 5_2 script
# =============================================================================
# mc_cql_gateway_dns_base <gateway-name> <namespace>
# Default DNS base for a gateway: <name>-<namespace>.<apps domain>. Sets REPLY.
mc_cql_gateway_dns_base() {
    local name="$1" ns="$2" apps_domain label
    apps_domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
    [[ -n "${apps_domain}" ]] || mc_die "Could not read the cluster's apps domain - pass --dns-base."
    label="${name}-${ns}"
    (( ${#label} <= 63 )) || mc_die "'${label}' is longer than a DNS label allows (63) - pass a shorter --name or --dns-base."
    REPLY="${label}.${apps_domain}"
}

# mc_cql_gateway_wait <namespace> <gateway-name> <size> <metadata-host>
# Wait for the CqlConnectivity to be Ready, its cql-router deployments to be
# available and the passthrough Route for the metadata host to exist.
mc_cql_gateway_wait() {
    local ns="$1" name="$2" size="$3" metadata_host="$4" i t
    mc_wait_ready cqlconnectivities.missioncontrol.datastax.com "${name}" "${ns}" 600 \
        || mc_die "CqlConnectivity ${name} not Ready after 10 minutes: oc describe cqlconnectivities.missioncontrol.datastax.com ${name} -n ${ns}"

    # Ready flips before the router pods are up; wait for them and the metadata Route.
    for (( i = 0; i < size; i++ )); do
        for (( t = 0; t < 60; t++ )); do
            oc get deployment "${name}-cql-router-${i}" -n "${ns}" >/dev/null 2>&1 && break
            sleep 5
        done
        oc rollout status "deployment/${name}-cql-router-${i}" -n "${ns}" --timeout=600s >/dev/null \
            || mc_die "cql-router ${i} did not become available: oc get pods -n ${ns} | grep ${name}-cql-router"
    done
    for (( t = 0; t < 60; t++ )); do
        oc get route -n "${ns}" -o jsonpath='{.items[*].spec.host}' | tr ' ' '\n' | grep -qx "${metadata_host}" && break
        sleep 5
    done
    oc get route -n "${ns}" -o jsonpath='{.items[*].spec.host}' | tr ' ' '\n' | grep -qx "${metadata_host}" \
        || mc_die "No Route for ${metadata_host} - check: oc get ingress,route -n ${ns}"
    mc_info "Routers available, metadata Route: ${metadata_host}"
}

# mc_cql_gateway_scb <namespace> <gateway-name> <metadata-host> <scb-file> <work-dir>
# Build the gateway's Secure Connect Bundle: an Astra-format zip made from its
# cert-manager secrets - client cert/key/CA (PEM, for Python/Node/C++/Go),
# keystore/truststore (JKS, for Java) and config.json pointing at the metadata
# service. <work-dir> is a private (0700) scratch dir the caller removes on exit;
# it holds the client key. Sets REPLY to the gateway's local DC.
mc_cql_gateway_scb() {
    local ns="$1" name="$2" metadata_host="$3" scb="$4" work="$5"
    local client_secret="${name}-client" store_pw meta t
    for (( t = 0; t < 30; t++ )); do
        oc get secret "${client_secret}" "${name}-pw" -n "${ns}" >/dev/null 2>&1 && break
        sleep 5
    done
    oc get secret "${client_secret}" "${name}-pw" -n "${ns}" >/dev/null 2>&1 \
        || mc_die "Gateway secrets ${client_secret} / ${name}-pw not found in ${ns}."
    mkdir -p "${work}/bundle"
    mc_secret_value "${ns}" "${client_secret}" ca.crt         > "${work}/bundle/ca.crt"
    mc_secret_value "${ns}" "${client_secret}" tls.crt        > "${work}/bundle/cert"
    mc_secret_value "${ns}" "${client_secret}" tls.key        > "${work}/bundle/key"
    mc_secret_value "${ns}" "${client_secret}" keystore.jks   > "${work}/bundle/identity.jks"
    mc_secret_value "${ns}" "${client_secret}" truststore.jks > "${work}/bundle/trustStore.jks"
    store_pw="$(mc_secret_value "${ns}" "${name}-pw" keystore-pw)"

    # Check the metadata service the way the drivers call it (mutual TLS; the
    # drivers do not verify its host name, and its certificate is issued for the
    # proxy host and router IDs). Its answer also gives the gateway's local DC.
    meta="$(python3 - "${work}/bundle" "${metadata_host}" <<'PY'
import json, ssl, sys, time, urllib.request
d, host = sys.argv[1], sys.argv[2]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.load_verify_locations(f"{d}/ca.crt")
ctx.load_cert_chain(f"{d}/cert", f"{d}/key")
last = None
for _ in range(24):
    try:
        with urllib.request.urlopen(f"https://{host}:443/metadata", context=ctx, timeout=10) as r:
            print(json.dumps(json.load(r)))
            sys.exit(0)
    except Exception as e:
        last = e
        time.sleep(5)
sys.exit(f"metadata service at https://{host}:443/metadata not reachable: {last}")
PY
)" || mc_die "${meta:-metadata service check failed}"
    REPLY="$(jq -r '.contact_info.local_dc // "dc1"' <<<"${meta}")"
    mc_info "Metadata service OK: proxy $(jq -r '.contact_info.sni_proxy_address' <<<"${meta}"), $(jq -r '.contact_info.contact_points | length' <<<"${meta}") router(s), local DC '${REPLY}'"

    MC_STORE_PW="${store_pw}" python3 - "${work}/bundle" "${metadata_host}" "${REPLY}" "${scb}" <<'PY'
import json, os, sys, zipfile
d, host, local_dc, out = sys.argv[1:5]
pw = os.environ["MC_STORE_PW"]
config = {
    "host": host, "port": 443, "localDC": local_dc,
    "caCertLocation": "./ca.crt", "certLocation": "./cert", "keyLocation": "./key",
    "keyStoreLocation": "./identity.jks", "keyStorePassword": pw,
    "trustStoreLocation": "./trustStore.jks", "trustStorePassword": pw,
}
os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
old = os.umask(0o077)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("config.json", json.dumps(config, indent=2))
    for f in ("ca.crt", "cert", "key", "identity.jks", "trustStore.jks"):
        z.write(os.path.join(d, f), f)
os.umask(old)
PY
    mc_info "Secure Connect Bundle: ${scb#${_CP4D_REPO_ROOT}/}"
}

# Driver snippets for connecting through a gateway with its Secure Connect Bundle.
mc_cql_gateway_usage() {
    cat <<'EOF'

Connect from outside the cluster (driver chooses contact points and TLS from the bundle;
do not also set contact points, port or SSL options):
  Python  Cluster(cloud={"secure_connect_bundle": "$DATASTAX_HCD_SCB"},
                  auth_provider=PlainTextAuthProvider("$DATASTAX_HCD_CQL_USER", "$DATASTAX_HCD_CQL_PASSWORD"))
  Java    CqlSession.builder().withCloudSecureConnectBundle(Paths.get(scb)).withAuthCredentials(user, pass)
  cqlsh   cqlsh -b "$DATASTAX_HCD_SCB" -u "$DATASTAX_HCD_CQL_USER" -p "$DATASTAX_HCD_CQL_PASSWORD"
EOF
}

# Host of the UI route, empty when it does not exist yet.
mc_ui_route_host() {
    oc get route "${MC_UI_ROUTE_NAME:-${MC_RELEASE_NAME}-ui}" -n "${MC_NAMESPACE}" \
        -o jsonpath='{.spec.host}' 2>/dev/null || true
}
