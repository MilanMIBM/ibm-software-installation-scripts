#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# No env_bootstrap here: the config this script writes is what the other
# scripts load, so it may not exist yet. Find the repo root the same way.
REPO_ROOT="${SCRIPT_DIR}"; while [[ "${REPO_ROOT}" != "/" && ! -f "${REPO_ROOT}/env_bootstrap.sh" ]]; do REPO_ROOT="$(dirname "${REPO_ROOT}")"; done

usage() {
    cat <<'EOF'
Write configs/kubecost_config/kubecost_vars.sh for the Kubecost operator install,
image mirroring and the other scripts in src/utilities/kubecost_utils/.

When this file exists those scripts load it instead of cpd_vars.sh (cluster
login, install source, private registry). Without it they keep using
cpd_vars.sh (OC_LOGIN, CPD_IMAGE_SOURCE, PRIVATE_REGISTRY_*).

  generate_kubecost_config.sh [options]
  generate_kubecost_config.sh --empty   [options]
  generate_kubecost_config.sh --from-cpd [CPD_VARS_FILE] [options]

Modes (none given: --from-cpd if configs/cp4d_config/cpd_vars.sh exists,
otherwise --empty):
  --empty               Defaults everywhere; cluster login and registry left
                        blank for you to fill in.
  --from-cpd [FILE]     Take the cluster login (OCP_URL, OCP_USERNAME/OCP_PASSWORD
                        or OCP_TOKEN), the image source (CPD_IMAGE_SOURCE), the
                        private registry (PRIVATE_REGISTRY_LOCATION + push/pull
                        credentials) and STG_CLASS_BLOCK from a CP4D config
                        (default configs/cp4d_config/cpd_vars.sh). Nothing else
                        from CP4D is used, and the two configs stay independent.

  --from-cluster [NAME] Also take, from a Kubecost instance on the logged-in
                        cluster (NAME, else the first one): its product key
                        (linked Secret), namespace, instance name, cluster ID,
                        storage class and the installed operator version.
                        Combine with --empty or --from-cpd; flags still win.

Options:
  --namespace NS        Operator + instance namespace (default: kubecost)
  --instance NAME       Kubecost instance (CR) created at install (default:
                        kubecost; "" = operator only)
  --source SRC          auto | marketplace | private | local (default: auto, or
                        the CP4D image source with --from-cpd)
  --registry LOCATION   Private registry host[:port][/path]
  --images all|required Images to mirror (default: all = required + optional)
  --version X.Y.Z       Operator version (default: the newest the cluster's
                        OperatorHub offers, else the newest mirrored one)
  --cluster-id ID       Kubecost cluster ID (default: the one an instance on the
                        logged-in cluster has, else a generated ocp-<6 chars>)
  --out FILE            Write somewhere else (default:
                        configs/kubecost_config/kubecost_vars.sh)
  --force               Overwrite an existing file (a timestamped .bak is kept)
  -h, --help            Show this help
EOF
}

MODE=""
CPD_FILE="${REPO_ROOT}/configs/cp4d_config/cpd_vars.sh"
OUT_FILE="${REPO_ROOT}/configs/kubecost_config/kubecost_vars.sh"
NAMESPACE=""
INSTANCE="__default__"
FROM_CLUSTER=false
FROM_INSTANCE=""
SOURCE=""
REGISTRY_OPT=""
IMAGES="all"
VERSION=""
CLUSTER_ID=""
FORCE=false

while (( $# )); do
    case "$1" in
        --empty)       MODE=empty; shift ;;
        --from-cpd)
            MODE=cpd; shift
            if [[ $# -gt 0 && "$1" != -* ]]; then CPD_FILE="$1"; shift; fi ;;
        --from-cluster)
            FROM_CLUSTER=true; shift
            if [[ $# -gt 0 && "$1" != -* ]]; then FROM_INSTANCE="$1"; shift; fi ;;
        --namespace)   NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
        --instance)    INSTANCE="${2-}"; shift 2 ;;
        --source)      SOURCE="${2:?--source needs a value}"; shift 2 ;;
        --registry)    REGISTRY_OPT="${2:?--registry needs host[:port][/path]}"; shift 2 ;;
        --images)      IMAGES="${2:?--images needs all or required}"; shift 2 ;;
        --version)     VERSION="${${2:?--version needs X.Y.Z}#v}"; shift 2 ;;
        --cluster-id)  CLUSTER_ID="${2:?--cluster-id needs a value}"; shift 2 ;;
        --out)         OUT_FILE="${2:?--out needs a path}"; shift 2 ;;
        --force)       FORCE=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# No mode given: --from-cpd when the default CP4D config exists, else --empty.
if [[ -z "${MODE}" ]]; then
    if [[ -f "${CPD_FILE}" ]]; then
        MODE=cpd
        echo "[INFO] No mode given: found ${CPD_FILE#${REPO_ROOT}/}, using --from-cpd (pass --empty to skip it)."
    else
        MODE=empty
        echo "[INFO] No mode given and no ${CPD_FILE#${REPO_ROOT}/}: using --empty."
    fi
fi
[[ -z "${SOURCE}" || "${SOURCE}" == (auto|marketplace|private|local) ]] \
    || { echo "[ERROR] --source must be auto, marketplace, private or local." >&2; exit 1; }
[[ "${IMAGES}" == (all|required) ]] || { echo "[ERROR] --images must be all or required." >&2; exit 1; }

if [[ -f "${OUT_FILE}" ]] && ! ${FORCE}; then
    echo "[ERROR] ${OUT_FILE} already exists. Re-run with --force to replace it (a .bak copy is kept)." >&2
    exit 1
fi

# --- Values taken from CP4D --------------------------------------------------
OCP_URL="" OCP_USERNAME="" OCP_PASSWORD="" OCP_TOKEN="" STORAGE_CLASS=""
CPD_SOURCE="" REGISTRY="" PUSH_USER="" PUSH_PASSWORD="" PULL_USER="" PULL_PASSWORD=""
if [[ "${MODE}" == cpd ]]; then
    [[ -f "${CPD_FILE}" ]] || { echo "[ERROR] CP4D config not found: ${CPD_FILE}" >&2; exit 1; }
    # Source it in a subshell so nothing else from CP4D leaks into this run;
    # values come back NUL-separated so any character survives.
    _cpd=("${(@0)$(
        set +u
        source "${CPD_FILE}" >/dev/null 2>&1
        print -rn -- "${OCP_URL:-}"$'\0'"${OCP_USERNAME:-}"$'\0'"${OCP_PASSWORD:-}"$'\0'"${OCP_TOKEN:-}"$'\0'"${STG_CLASS_BLOCK:-}"$'\0'"${CPD_IMAGE_SOURCE:-}"$'\0'"${PRIVATE_REGISTRY_LOCATION:-}"$'\0'"${PRIVATE_REGISTRY_PUSH_USER:-}"$'\0'"${PRIVATE_REGISTRY_PUSH_PASSWORD:-}"$'\0'"${PRIVATE_REGISTRY_PULL_USER:-}"$'\0'"${PRIVATE_REGISTRY_PULL_PASSWORD:-}"
    )}")
    OCP_URL="${_cpd[1]:-}" OCP_USERNAME="${_cpd[2]:-}" OCP_PASSWORD="${_cpd[3]:-}" OCP_TOKEN="${_cpd[4]:-}"
    STORAGE_CLASS="${_cpd[5]:-}" CPD_SOURCE="${_cpd[6]:-}" REGISTRY="${_cpd[7]:-}"
    PUSH_USER="${_cpd[8]:-}" PUSH_PASSWORD="${_cpd[9]:-}" PULL_USER="${_cpd[10]:-}" PULL_PASSWORD="${_cpd[11]:-}"
    unset _cpd
    # CP4D's "entitled" pulls from IBM: for Kubecost that's the marketplace (auto).
    [[ -z "${SOURCE}" && "${CPD_SOURCE}" == (private|local) ]] && SOURCE="${CPD_SOURCE}"
    # Placeholder registry values from the notebook template are not a registry.
    [[ "${REGISTRY}" == *'<'* || "${REGISTRY}" == *example* ]] && REGISTRY=""
    _taken=()
    for _v in OCP_URL OCP_USERNAME OCP_PASSWORD OCP_TOKEN; do
        [[ -n "${(P)_v}" ]] && _taken+=("${_v}")
    done
    [[ -n "${CPD_SOURCE}" ]] && _taken+=("CPD_IMAGE_SOURCE=${CPD_SOURCE}")
    [[ -n "${REGISTRY}" ]] && _taken+=("PRIVATE_REGISTRY_LOCATION + credentials")
    [[ -n "${STORAGE_CLASS}" ]] && _taken+=("STG_CLASS_BLOCK -> KUBECOST_STORAGE_CLASS")
    echo "[INFO] Taken from ${CPD_FILE#${REPO_ROOT}/}: ${(j:, :)_taken:-nothing}"
    [[ -z "${OCP_URL}" ]] && echo "[WARN] OCP_URL was empty in the CP4D config - fill it in by hand." >&2
    unset _taken _v
fi
[[ -n "${REGISTRY_OPT}" ]] && REGISTRY="${REGISTRY_OPT}"

# --- Values taken from an existing instance on the cluster ----------------------
PRODUCT_KEY="" KEY_SECRET="kubecost-product-key"
if [[ "${FROM_CLUSTER}" == true ]]; then
    oc whoami &>/dev/null || { echo "[ERROR] --from-cluster needs an oc login to the cluster." >&2; exit 1; }
    _cr="$(oc get kubecosts.charts.kubecost.com -A -o json | jq -c --arg n "${FROM_INSTANCE}" \
        '[.items[] | select($n == "" or .metadata.name == $n)] | first // empty')"
    [[ -n "${_cr}" ]] || { echo "[ERROR] No Kubecost instance${FROM_INSTANCE:+ named ${FROM_INSTANCE}} on $(oc whoami --show-server)." >&2; exit 1; }
    _ns="$(jq -r '.metadata.namespace' <<<"${_cr}")"
    _taken=()
    [[ -n "${NAMESPACE}" ]] || { NAMESPACE="${_ns}"; _taken+=("namespace ${_ns}"); }
    [[ "${INSTANCE}" != __default__ ]] || { INSTANCE="$(jq -r '.metadata.name' <<<"${_cr}")"; _taken+=("instance ${INSTANCE}"); }
    if [[ -z "${CLUSTER_ID}" ]]; then
        CLUSTER_ID="$(jq -r '.spec.global.clusterId // empty | select(test("SET_A_UNIQUE") | not)' <<<"${_cr}")"
        [[ -n "${CLUSTER_ID}" ]] && _taken+=("cluster ID ${CLUSTER_ID}")
    fi
    _sc="$(jq -r '.spec.global.defaultStorageClass // empty' <<<"${_cr}")"
    [[ -n "${_sc}" ]] && { STORAGE_CLASS="${_sc}"; _taken+=("storage class ${_sc}"); }
    if [[ -z "${VERSION}" ]]; then
        VERSION="$(oc get csv -n "${_ns}" -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | startswith("kubecost-operator.v")) | .spec.version] | first // empty')"
        [[ -n "${VERSION}" ]] && { VERSION_FROM_CLUSTER=true; _taken+=("installed version ${VERSION}"); }
    fi
    # Product key: inline in the CR, else the linked Secret (chart default name product-key).
    if [[ "$(jq -r '.spec.kubecostProductConfigs.productKey.enabled // false' <<<"${_cr}")" == true ]]; then
        PRODUCT_KEY="$(jq -r '.spec.kubecostProductConfigs.productKey.key // empty' <<<"${_cr}")"
        if [[ -z "${PRODUCT_KEY}" ]]; then
            KEY_SECRET="$(jq -r '.spec.kubecostProductConfigs.productKey.secretname // "" | if . == "" then "product-key" else . end' <<<"${_cr}")"
            PRODUCT_KEY="$(oc get secret "${KEY_SECRET}" -n "${_ns}" -o json 2>/dev/null \
                | jq -r '.data["productkey.json"] // empty | @base64d | fromjson? | .key // empty')"
        fi
        [[ -n "${PRODUCT_KEY}" ]] && _taken+=("product key ${PRODUCT_KEY[1,4]}**** (Secret ${KEY_SECRET})")
    fi
    echo "[INFO] Taken from instance $(jq -r '.metadata.name' <<<"${_cr}") in ${_ns}: ${(j:, :)_taken:-nothing}"
    unset _cr _ns _sc _taken
fi
NAMESPACE="${NAMESPACE:-kubecost}"
[[ "${INSTANCE}" != __default__ ]] || INSTANCE="kubecost"
SOURCE="${SOURCE:-auto}"
if [[ "${SOURCE}" == (private|local) && -z "${REGISTRY}" ]]; then
    echo "[WARN] Source ${SOURCE} without a registry: set KUBECOST_PRIVATE_REGISTRY_LOCATION in the file." >&2
fi

# --- Operator version: OperatorHub on the logged-in cluster, else the mirrors ----
VERSION_FROM="$([[ "${VERSION_FROM_CLUSTER:-}" == true ]] && echo "installed on the cluster" || echo "--version")"
if [[ -z "${VERSION}" ]]; then
    VERSION_FROM=""
    if oc whoami &>/dev/null; then
        VERSION="$(oc get packagemanifest kubecost-operator -n openshift-marketplace -o json 2>/dev/null \
            | jq -r '.status as $s | $s.channels[]? | select(.name == $s.defaultChannel) | .currentCSVDesc.version // empty' 2>/dev/null || true)"
        [[ -n "${VERSION}" ]] && VERSION_FROM="OperatorHub on $(oc whoami --show-server 2>/dev/null)"
    fi
    if [[ -z "${VERSION}" ]]; then
        VERSION="$(for _r in "${REPO_ROOT}"/configs/kubecost_config/mirror/*/record.json(N); do print -r -- "${${_r:h}:t}"; done \
            | sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1)"
        [[ -n "${VERSION}" ]] && VERSION_FROM="newest mirrored version (configs/kubecost_config/mirror/)"
    fi
fi
if [[ -n "${VERSION}" ]]; then
    echo "[INFO] Operator version ${VERSION} (${VERSION_FROM})."
else
    echo "[WARN] No OperatorHub offer or mirror found for the version: KUBECOST_OPERATOR_VERSION left empty (newest at install time)." >&2
fi

# --- Cluster ID: unique per cluster, never all digits (the chart breaks on that) ---
# One cluster, one ID: reuse the one an existing instance on the logged-in cluster has.
if [[ -z "${CLUSTER_ID}" ]] && oc whoami &>/dev/null; then
    CLUSTER_ID="$(oc get kubecosts.charts.kubecost.com -A -o json 2>/dev/null \
        | jq -r '[.items[].spec.global.clusterId // empty | select(test("SET_A_UNIQUE") | not)] | first // empty' 2>/dev/null || true)"
    [[ -n "${CLUSTER_ID}" ]] && echo "[INFO] Cluster ID ${CLUSTER_ID} (from the Kubecost instance already on the cluster)."
fi
if [[ -z "${CLUSTER_ID}" ]]; then
    CLUSTER_ID="ocp-$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(6)))')"
fi
[[ "${CLUSTER_ID}" == <-> ]] && { echo "[ERROR] --cluster-id must not be all digits." >&2; exit 1; }

# Single-quoted shell literal for any value (passwords may hold $ " ' etc.).
q() { print -r -- "${(qq)1}"; }

# --- Write -------------------------------------------------------------------
(umask 077; mkdir -p "${OUT_FILE:h}")
if [[ -f "${OUT_FILE}" ]]; then
    _bak="${OUT_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    cp -p "${OUT_FILE}" "${_bak}"
    echo "[INFO] Previous file kept as ${_bak:t}"
fi

_tmp="$(mktemp "${OUT_FILE:h}/.kubecost_vars.XXXXXX")"
chmod 600 "${_tmp}"
cat > "${_tmp}" <<EOF
#!/bin/zsh
# ==============================================================================
# Kubecost (IBM Kubecost operator) configuration
# Generated by generate_kubecost_config.sh --${MODE/cpd/from-cpd} on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# ==============================================================================
# Sourced (never executed) by src/utilities/kubecost_utils/*, which run with
# ENV_TARGET=kubecost while this file exists (cpd_vars.sh otherwise). Skipped
# for any other target, so CP4D scripts never pick up this cluster login.
#
#   Interactive shell:  source s_env.sh kubecost
[[ "\${ENV_TARGET:-}" == kubecost || "\${ENV_TARGET:-}" == *kubecost_vars.sh ]] || return 0

# ------------------------------------------------------------------------------
# Cluster login (OCP_TOKEN wins over username/password when set)
# ------------------------------------------------------------------------------
export OCP_URL=$(q "${OCP_URL}")
export OCP_USERNAME=$(q "${OCP_USERNAME}")
export OCP_PASSWORD=$(q "${OCP_PASSWORD}")
export OCP_TOKEN=$(q "${OCP_TOKEN}")
export SERVER_ARGUMENTS="--server=\${OCP_URL}"
# Single quotes: the credentials are expanded when OC_LOGIN is eval'd, so a
# password containing \$ ' or " still logs in.
if [[ -n "\${OCP_TOKEN}" ]]; then
    export LOGIN_ARGUMENTS='--token="\${OCP_TOKEN}"'
else
    export LOGIN_ARGUMENTS='--username="\${OCP_USERNAME}" --password="\${OCP_PASSWORD}"'
fi
export OC_LOGIN="oc login \${SERVER_ARGUMENTS} \${LOGIN_ARGUMENTS}"

# ------------------------------------------------------------------------------
# Install (install_kubecost_operator.sh)
# ------------------------------------------------------------------------------
# Where the operator comes from:
#   auto         OperatorHub (OLM) when a catalog on the cluster offers
#                kubecost-operator and is reachable; otherwise a warning and the
#                private registry below. A registry set below makes auto = private.
#   marketplace  OperatorHub only (Red Hat certified-operators by default)
#   private      images mirrored to a private registry (mirror_images/), no catalog
#   local        same as private, for a registry reachable only from an air-gapped
#                network (mirror_images --phase save, then --phase load inside)
export KUBECOST_INSTALL_SOURCE=$(q "${SOURCE}")
export KUBECOST_OPERATOR_NAMESPACE=$(q "${NAMESPACE}")
export KUBECOST_OPERATOR_CHANNEL="stable"
# Filled in when generated: the newest the cluster's OperatorHub offered, else the
# newest mirrored one. Empty = the newest at install time (marketplace: the
# channel head; private/local: the newest mirrored). Also what mirror_images/ mirrors.
export KUBECOST_OPERATOR_VERSION=$(q "${VERSION}")
# Automatic | Manual (OLM upgrades within the channel)
export KUBECOST_INSTALL_PLAN_APPROVAL="Automatic"
export KUBECOST_CATALOG_SOURCE="certified-operators"
export KUBECOST_CATALOG_SOURCE_NAMESPACE="openshift-marketplace"
# Kubecost instance (Kubecost CR) created after the operator; empty = none
export KUBECOST_INSTANCE_NAME=$(q "${INSTANCE}")
# Unique per cluster, not all digits (an existing instance's ID, else ocp-<6 random characters)
export KUBECOST_CLUSTER_ID=$(q "${CLUSTER_ID}")
# Storage class for the aggregator/local-store PVCs; empty = the cluster default
export KUBECOST_STORAGE_CLASS=$(q "${STORAGE_CLASS}")

# ------------------------------------------------------------------------------
# License (Kubecost Enterprise product key)
# ------------------------------------------------------------------------------
# Empty = free tier. When set, the install stores it in the Secret below and
# links it to the instance (product_key/link_kubecost_product_key.sh).
export KUBECOST_PRODUCT_KEY=$(q "${PRODUCT_KEY}")
export KUBECOST_PRODUCT_KEY_SECRET=$(q "${KEY_SECRET}")

# ------------------------------------------------------------------------------
# Private registry (private / local installs, mirror_images/)
# ------------------------------------------------------------------------------
# host[:port][/path]. Images land at <location>/<KUBECOST_REGISTRY_PATH>/<source
# path>, e.g. <location>/kubecost/kubecost/kubecost-frontend
export KUBECOST_PRIVATE_REGISTRY_LOCATION=$(q "${REGISTRY}")
export KUBECOST_REGISTRY_PATH="kubecost"
export KUBECOST_PRIVATE_REGISTRY_PUSH_USER=$(q "${PUSH_USER}")
export KUBECOST_PRIVATE_REGISTRY_PUSH_PASSWORD=$(q "${PUSH_PASSWORD}")
# Pull credentials for the cluster (empty = the push ones); stored in the
# namespace Secret KUBECOST_PULL_SECRET_NAME. Leave both empty when the
# cluster's global pull secret already covers the registry.
export KUBECOST_PRIVATE_REGISTRY_PULL_USER=$(q "${PULL_USER}")
export KUBECOST_PRIVATE_REGISTRY_PULL_PASSWORD=$(q "${PULL_PASSWORD}")
export KUBECOST_PULL_SECRET_NAME="kubecost-registry"
# Registry with a self-signed certificate or plain HTTP (oc image --insecure)
export KUBECOST_REGISTRY_INSECURE="false"
# How the cluster is pointed at the mirrored images:
#   explicit  image references in the operator Deployment and the Kubecost CR
#             (no node changes)
#   idms      an ImageDigestMirrorSet for registry.connect.redhat.com/kubecost
#             (updates every node's registries.conf)
#   both
export KUBECOST_IMAGE_REDIRECT="explicit"

# ------------------------------------------------------------------------------
# Image mirroring (mirror_images/mirror_kubecost_images.sh)
# ------------------------------------------------------------------------------
# all = required (frontend, cost-model, finops-agent, cluster-controller) +
# optional (network-costs, forecasting, mcp); required = leave the optional
# ones out (the install then turns those components off). The operator and its
# bundle are always included.
export KUBECOST_MIRROR_IMAGES=$(q "${IMAGES}")
# Components to leave out as well, space-separated, e.g. "network-costs mcp"
export KUBECOST_MIRROR_EXCLUDE=""
# Disk location for --phase save/load (air gap); empty = kubecost_workspace/mirror/<version>
export KUBECOST_MIRROR_DIR=""
# Catalog to read the operator from: registry.redhat.io/redhat/certified-operator-index:v<this>
# Empty = the logged-in cluster's OpenShift version
export KUBECOST_OCP_VERSION=""
# Pull secret for registry.redhat.io + registry.connect.redhat.com (JSON from
# console.redhat.com/openshift/downloads#tool-pull-secret). Empty = the
# logged-in cluster's pull secret.
export KUBECOST_REDHAT_PULL_SECRET_FILE=""
EOF
mv "${_tmp}" "${OUT_FILE}"

echo "[INFO] Wrote ${OUT_FILE#${REPO_ROOT}/} (install source: ${SOURCE}${REGISTRY:+, registry ${REGISTRY}}, version ${VERSION:-newest at install}, cluster ID ${CLUSTER_ID})"
[[ -n "${PRODUCT_KEY}" ]] || echo "[INFO] License: set KUBECOST_PRODUCT_KEY in the file for Enterprise (empty = free tier; --from-cluster takes a linked one)."
if [[ "${MODE}" == empty ]]; then
    echo "[INFO] Fill in OCP_URL and the login (OCP_USERNAME/OCP_PASSWORD or OCP_TOKEN); for private/local installs the registry too."
fi
echo "[INFO] Next: src/utilities/kubecost_utils/install_kubecost_operator.sh (--dry-run first)"
[[ "${SOURCE}" == (private|local) ]] && echo "[INFO] Mirror the images first: src/utilities/kubecost_utils/mirror_images/mirror_kubecost_images.sh"
exit 0
