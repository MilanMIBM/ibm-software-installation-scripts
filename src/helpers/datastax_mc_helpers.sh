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

# Host of the UI route, empty when it does not exist yet.
mc_ui_route_host() {
    oc get route "${MC_UI_ROUTE_NAME:-${MC_RELEASE_NAME}-ui}" -n "${MC_NAMESPACE}" \
        -o jsonpath='{.spec.host}' 2>/dev/null || true
}
