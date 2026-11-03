#!/bin/zsh
# Shared by src/utilities/kubecost_utils/ (install, config) and mirror_images/. Source
# it after kubecost_helpers.sh; it runs nothing itself:
#     source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_install_helpers.sh"
#
# Settings come from configs/kubecost_config/kubecost_vars.sh when it exists
# (env_bootstrap.sh then loads it instead of cpd_vars.sh for these scripts),
# else from cpd_vars.sh: CPD_IMAGE_SOURCE and PRIVATE_REGISTRY_*.
#
# Operator facts (certified-operator-index, package kubecost-operator, checked
# 2026-11-03 for 3.3.1): the bundle's relatedImages pin every image by digest
# under registry.connect.redhat.com/kubecost/; the CSV is not embedded in the
# catalog (the bundle image's /manifests holds it); one Deployment, no webhooks,
# OwnNamespace/SingleNamespace install modes. Each operand takes its registry
# from <component>.image.registry (which beats global.imageRegistry), except the
# finops agent, whose fullImageName is hard-coded in the chart.

KC_PACKAGE="kubecost-operator"
KC_SOURCE_REGISTRY="registry.connect.redhat.com"
KC_INDEX_REPO="registry.redhat.io/redhat/certified-operator-index"
KC_VARS_FILE="${_CP4D_REPO_ROOT}/configs/kubecost_config/kubecost_vars.sh"
KC_MIRROR_META_DIR="${_CP4D_REPO_ROOT}/configs/kubecost_config/mirror"
KC_WORKSPACE="${_CP4D_REPO_ROOT}/kubecost_workspace"

# relatedImages name -> "<component> <class>". Classes: operator (the operator
# and its bundle), required, optional (IBM's air-gap list; MCP is optional too:
# the chart can turn it off). Unknown names count as required.
typeset -gA KC_IMAGE_CLASS=(
    kubecost-frontend           "frontend required"
    kubecost-cost-model         "cost-model required"
    ibm-finops-agent            "finops-agent required"
    kubecost-cluster-controller "cluster-controller required"
    kubecost-network-costs      "network-costs optional"
    kubecost-modeling           "forecasting optional"
    kubecost-mcp                "mcp optional"
    kubecost-operator           "operator operator"
)
KC_OPTIONAL_COMPONENTS=(network-costs forecasting mcp)
# Chart value that turns an optional component off.
typeset -gA KC_COMPONENT_TOGGLE=(network-costs networkCosts forecasting forecasting mcp mcp)
# Chart values that hold each operand's registry (the source path is kept
# below it, so all of them get the same <registry>/<path> root).
typeset -gA KC_COMPONENT_REGISTRY_KEYS=(
    frontend           "frontend"
    cost-model         "aggregator cloudCost localStore"
    network-costs      "networkCosts"
    forecasting        "forecasting"
    cluster-controller "clusterController"
    mcp                "mcp"
)

# Where the settings come from and what they say. Sets:
#   KC_VARS_FROM        kubecost_vars.sh | cpd_vars.sh | none
#   KC_SOURCE           auto | marketplace | private | local (install source)
#   KC_SOURCE_WHY       which setting picked it
#   KC_REGISTRY         private registry location host[:port][/path] ("" = none)
#   KC_REGISTRY_PATH    path under it for Kubecost (default kubecost)
#   KC_PUSH_USER/KC_PUSH_PASSWORD, KC_PULL_USER/KC_PULL_PASSWORD
#   KC_REGISTRY_INSECURE true|false, KC_REDIRECT explicit|idms|both
kc_install_settings() {
    if [[ "${ENV_TARGET_FILE:-}" == *kubecost_vars.sh || "${ENV_TARGET:-}" == kubecost ]]; then
        KC_VARS_FROM="kubecost_vars.sh"
        KC_SOURCE="${KUBECOST_INSTALL_SOURCE:-auto}"
        KC_SOURCE_WHY="KUBECOST_INSTALL_SOURCE in kubecost_vars.sh"
        KC_REGISTRY="${KUBECOST_PRIVATE_REGISTRY_LOCATION:-}"
        KC_PUSH_USER="${KUBECOST_PRIVATE_REGISTRY_PUSH_USER:-}"; KC_PUSH_PASSWORD="${KUBECOST_PRIVATE_REGISTRY_PUSH_PASSWORD:-}"
        KC_PULL_USER="${KUBECOST_PRIVATE_REGISTRY_PULL_USER:-}"; KC_PULL_PASSWORD="${KUBECOST_PRIVATE_REGISTRY_PULL_PASSWORD:-}"
        # A registry named in kubecost_vars.sh with source auto means "use it".
        if [[ "${KC_SOURCE}" == auto && -n "${KC_REGISTRY}" ]]; then
            KC_SOURCE=private
            KC_SOURCE_WHY="KUBECOST_PRIVATE_REGISTRY_LOCATION is set in kubecost_vars.sh"
        fi
    elif [[ -n "${CPD_IMAGE_SOURCE:-}${PRIVATE_REGISTRY_LOCATION:-}" ]]; then
        KC_VARS_FROM="cpd_vars.sh"
        case "${CPD_IMAGE_SOURCE:-entitled}" in
            private|local) KC_SOURCE="${CPD_IMAGE_SOURCE}"; KC_SOURCE_WHY="CPD_IMAGE_SOURCE in cpd_vars.sh" ;;
            *)             KC_SOURCE=auto; KC_SOURCE_WHY="CPD_IMAGE_SOURCE=${CPD_IMAGE_SOURCE:-entitled} in cpd_vars.sh" ;;
        esac
        KC_REGISTRY="${PRIVATE_REGISTRY_LOCATION:-}"
        KC_PUSH_USER="${PRIVATE_REGISTRY_PUSH_USER:-}"; KC_PUSH_PASSWORD="${PRIVATE_REGISTRY_PUSH_PASSWORD:-}"
        KC_PULL_USER="${PRIVATE_REGISTRY_PULL_USER:-}"; KC_PULL_PASSWORD="${PRIVATE_REGISTRY_PULL_PASSWORD:-}"
    else
        KC_VARS_FROM="none"; KC_SOURCE=auto; KC_SOURCE_WHY="default"
        KC_REGISTRY=""; KC_PUSH_USER=""; KC_PUSH_PASSWORD=""; KC_PULL_USER=""; KC_PULL_PASSWORD=""
    fi
    KC_REGISTRY="${${KC_REGISTRY#https://}%/}"
    KC_REGISTRY_PATH="${${KUBECOST_REGISTRY_PATH:-kubecost}#/}"
    KC_REGISTRY_PATH="${KC_REGISTRY_PATH%/}"
    KC_REGISTRY_INSECURE="${KUBECOST_REGISTRY_INSECURE:-false}"
    KC_REDIRECT="${KUBECOST_IMAGE_REDIRECT:-explicit}"
    # Pull credentials default to the push ones.
    [[ -n "${KC_PULL_USER}" ]] || { KC_PULL_USER="${KC_PUSH_USER}"; KC_PULL_PASSWORD="${KC_PUSH_PASSWORD}"; }
}

# <registry>/<path>: the root every mirrored Kubecost image sits under, with
# its source path kept (registry.connect.redhat.com/kubecost/kubecost-frontend
# -> <root>/kubecost/kubecost-frontend).
kc_dest_root() { [[ -n "${KC_REGISTRY}" ]] && print -r -- "${KC_REGISTRY}${KC_REGISTRY_PATH:+/${KC_REGISTRY_PATH}}"; return 0; }

# <source image ref> -> destination repo (no tag/digest) under kc_dest_root.
kc_dest_repo() {   # <source ref>
    local ref="${1%@*}"; ref="${ref%:*}"
    print -r -- "$(kc_dest_root)/${ref#*/}"
}

# Writes a private auth file for <registries...> (space-separated hosts) to
# <file>: the Red Hat pull secret (KUBECOST_REDHAT_PULL_SECRET_FILE, else the
# logged-in cluster's openshift-config/pull-secret, else REGISTRY_AUTH_FILE or
# ~/.docker/config.json) plus push credentials for the private registry.
kc_write_authfile() {   # <file> <use push creds: true|false>
    local f="$1" base='{"auths":{}}' src="" user pass host
    if [[ -n "${KUBECOST_REDHAT_PULL_SECRET_FILE:-}" ]]; then
        [[ -r "${KUBECOST_REDHAT_PULL_SECRET_FILE}" ]] || { echo "[ERROR] Cannot read KUBECOST_REDHAT_PULL_SECRET_FILE=${KUBECOST_REDHAT_PULL_SECRET_FILE}" >&2; return 1; }
        base="$(<"${KUBECOST_REDHAT_PULL_SECRET_FILE}")"; src="${KUBECOST_REDHAT_PULL_SECRET_FILE}"
    elif base="$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null)" && [[ -n "${base}" ]]; then
        src="the cluster's pull secret"
    elif [[ -r "${REGISTRY_AUTH_FILE:-}" ]]; then
        base="$(<"${REGISTRY_AUTH_FILE}")"; src="${REGISTRY_AUTH_FILE}"
    elif [[ -r "${HOME}/.docker/config.json" ]]; then
        base="$(<"${HOME}/.docker/config.json")"; src="~/.docker/config.json"
    else
        base='{"auths":{}}'
    fi
    jq -e '.auths' <<<"${base}" >/dev/null 2>&1 || { echo "[ERROR] ${src:-the pull secret} is not a docker config JSON." >&2; return 1; }
    if [[ "$2" == true ]]; then user="${KC_PUSH_USER}"; pass="${KC_PUSH_PASSWORD}"; else user="${KC_PULL_USER}"; pass="${KC_PULL_PASSWORD}"; fi
    host="${KC_REGISTRY%%/*}"
    if [[ -n "${host}" && -n "${user}" ]]; then
        base="$(jq -c --arg h "${host}" --arg a "$(print -rn -- "${user}:${pass}" | base64 | tr -d '\n')" '.auths[$h] = {auth: $a}' <<<"${base}")"
    fi
    (umask 077; print -r -- "${base}" > "${f}")
    KC_AUTH_SOURCE="${src:-none}"
    if ! jq -e --arg h "${KC_SOURCE_REGISTRY}" '.auths[$h]' <<<"${base}" >/dev/null; then
        echo "[WARN] No credentials for ${KC_SOURCE_REGISTRY} / registry.redhat.io in ${src:-any pull secret}; set KUBECOST_REDHAT_PULL_SECRET_FILE (console.redhat.com/openshift/downloads#tool-pull-secret)." >&2
    fi
}

# oc image flags for the private registry.
kc_oc_registry_flags() {
    [[ "${KC_REGISTRY_INSECURE}" == true ]] && print -r -- "--insecure=true"
    return 0
}

# "v4.19" for the logged-in cluster, else KUBECOST_OCP_VERSION.
kc_ocp_index_tag() {
    local v="${KUBECOST_OCP_VERSION:-}"
    if [[ -z "${v}" ]]; then
        v="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
    fi
    v="${v#v}"; v="${v%%-*}"
    [[ "${v}" =~ '^[0-9]+\.[0-9]+' ]] || { echo "[ERROR] OpenShift version unknown: log in to the target cluster or set KUBECOST_OCP_VERSION (e.g. 4.19)." >&2; return 1; }
    print -r -- "v${MATCH}"
}

# Highest version first: kubecost-operator.vX.Y.Z names, one per line.
kc_sort_csvs() { sed 's/^kubecost-operator\.v//' | sort -t. -k1,1nr -k2,2nr -k3,3nr | sed 's/^/kubecost-operator.v/'; }

# Mirror metadata (record, bundle manifests, package) for a version:
#   configs/kubecost_config/mirror/<version>/
kc_mirror_meta() { print -r -- "${KC_MIRROR_META_DIR}/$1"; }

# Newest version with a mirror record, or nothing.
kc_latest_mirror_version() {
    local d
    for d in "${KC_MIRROR_META_DIR}"/*/record.json(N); do print -r -- "kubecost-operator.v${${d:h}:t}"; done | kc_sort_csvs | head -1 | sed 's/^kubecost-operator\.v//'
}
