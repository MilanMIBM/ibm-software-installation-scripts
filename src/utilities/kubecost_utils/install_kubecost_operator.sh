#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Installs the IBM Kubecost operator on OpenShift and creates a Kubecost
# instance (a Kubecost CR), from one of two sources:
#
#   marketplace  OperatorHub (OLM): a Subscription to kubecost-operator in the
#                Red Hat certified-operators catalog (or the catalog that offers it)
#   private      images mirrored with mirror_images/mirror_kubecost_images.sh:
#   local        the operator's bundle manifests applied directly (no OLM, no
#                catalog needed), every image pointed at the private registry
#
# Source order: --source, else configs/kubecost_config/kubecost_vars.sh
# (KUBECOST_INSTALL_SOURCE; a KUBECOST_PRIVATE_REGISTRY_LOCATION with source auto
# means private), else cpd_vars.sh (CPD_IMAGE_SOURCE private|local), else auto:
# marketplace when a catalog on the cluster offers kubecost-operator and is
# reachable, otherwise a warning and the private registry when one is set up.
#
# Re-running is safe: an installed operator is kept (images: re-applied, which
# also upgrades to a newer mirrored version), an existing instance is kept
# (images: its image settings are refreshed; KUBECOST_REFRESH_INTERVAL and
# KUBECOST_REFRESH_DYNAMIC, when set, are applied to it as well as to a new one).
#
#   install_kubecost_operator.sh [options]
#     --source <src>           auto | marketplace | private | local
#     -n, --namespace <ns>     operator + instance namespace (default
#                              KUBECOST_OPERATOR_NAMESPACE, else kubecost)
#     --channel <name>         marketplace: default KUBECOST_OPERATOR_CHANNEL, else the package default
#     --version <x.y.z>        default KUBECOST_OPERATOR_VERSION, else the channel's
#                              newest (marketplace) or the newest mirrored (private)
#     --approval <mode>        Automatic | Manual (marketplace upgrades)
#     --catalog <name>         marketplace catalog (default KUBECOST_CATALOG_SOURCE,
#                              else certified-operators)
#     --instance <name>        Kubecost CR to create (default KUBECOST_INSTANCE_NAME,
#                              else kubecost)
#     --no-instance            operator only
#     --cluster-id <id>        default KUBECOST_CLUSTER_ID, else the infrastructure name
#     --storage-class <sc>     default KUBECOST_STORAGE_CLASS, else the cluster default
#     --refresh-interval <d>   how often the UI data is published, e.g. 15m, or default
#                              (default KUBECOST_REFRESH_INTERVAL, else left as it is)
#     --registry <location>    private: host[:port][/path] the cluster pulls from
#     --redirect <mode>        private: explicit | idms | both (default KUBECOST_IMAGE_REDIRECT)
#     --dry-run                decide and show what would be done, change nothing
#     --timeout <seconds>      wait at most this long per step (default 900)
#     --server/--token/-u/-p   log in first (see ocu_login); otherwise OC_LOGIN
#                              from kubecost_vars.sh / cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_install_helpers.sh"

usage() { sed -n '/^# Installs the IBM Kubecost operator/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# OLM's Subscription, not ACM's (apps.open-cluster-management.io) of the same kind.
SUB_RES="subscriptions.operators.coreos.com"

SOURCE_OPT=""
NAMESPACE=""
CHANNEL=""
VERSION=""
APPROVAL=""
CATALOG=""
INSTANCE="${KUBECOST_INSTANCE_NAME-kubecost}"
CLUSTER_ID=""
STORAGE_CLASS=""
REFRESH_INTERVAL=""
REGISTRY_OPT=""
REDIRECT_OPT=""
DRY_RUN=false
TIMEOUT=900
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)          SOURCE_OPT="${2:?$1 needs a value}"; shift 2 ;;
        -n|--namespace)    NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        --channel)         CHANNEL="${2:?$1 needs a value}"; shift 2 ;;
        --version)         VERSION="${${2:?$1 needs a value}#v}"; shift 2 ;;
        --approval)        APPROVAL="${2:?$1 needs Automatic or Manual}"; shift 2 ;;
        --catalog)         CATALOG="${2:?$1 needs a value}"; shift 2 ;;
        --instance)        INSTANCE="${2:?$1 needs a name}"; shift 2 ;;
        --no-instance)     INSTANCE=""; shift ;;
        --cluster-id)      CLUSTER_ID="${2:?$1 needs a value}"; shift 2 ;;
        --storage-class)   STORAGE_CLASS="${2:?$1 needs a value}"; shift 2 ;;
        --refresh-interval) REFRESH_INTERVAL="${2:?$1 needs a duration like 15m, or default}"; shift 2 ;;
        --registry)        REGISTRY_OPT="${2:?$1 needs host[:port][/path]}"; shift 2 ;;
        --redirect)        REDIRECT_OPT="${2:?$1 needs explicit, idms or both}"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --timeout)         TIMEOUT="${2:?$1 needs a value}"; shift 2 ;;
        --server)          LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)           LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)     LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)     LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done
[[ "${TIMEOUT}" == <-> ]] || die "--timeout needs a number of seconds."

kc_install_settings
[[ -n "${REGISTRY_OPT}" ]] && KC_REGISTRY="${${REGISTRY_OPT#https://}%/}"
[[ -n "${REDIRECT_OPT}" ]] && KC_REDIRECT="${REDIRECT_OPT}"
[[ "${KC_REDIRECT}" == (explicit|idms|both) ]] || die "--redirect must be explicit, idms or both (not '${KC_REDIRECT}')."
SOURCE="${SOURCE_OPT:-${KC_SOURCE}}"
SOURCE_WHY="$([[ -n "${SOURCE_OPT}" ]] && echo "--source" || echo "${KC_SOURCE_WHY}")"
[[ "${SOURCE}" == (auto|marketplace|private|local) ]] || die "Install source must be auto, marketplace, private or local (not '${SOURCE}')."
NAMESPACE="${NAMESPACE:-${KUBECOST_OPERATOR_NAMESPACE:-kubecost}}"
CHANNEL="${CHANNEL:-${KUBECOST_OPERATOR_CHANNEL:-}}"
VERSION="${VERSION:-${KUBECOST_OPERATOR_VERSION:-}}"
APPROVAL="${APPROVAL:-${KUBECOST_INSTALL_PLAN_APPROVAL:-Automatic}}"
[[ "${APPROVAL}" == (Automatic|Manual) ]] || die "--approval must be Automatic or Manual."
CATALOG="${CATALOG:-${KUBECOST_CATALOG_SOURCE:-certified-operators}}"
CATALOG_NS="${KUBECOST_CATALOG_SOURCE_NAMESPACE:-openshift-marketplace}"
CLUSTER_ID="${CLUSTER_ID:-${KUBECOST_CLUSTER_ID:-}}"
STORAGE_CLASS="${STORAGE_CLASS:-${KUBECOST_STORAGE_CLASS:-}}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-${KUBECOST_REFRESH_INTERVAL:-}}"
REFRESH_DYNAMIC="${KUBECOST_REFRESH_DYNAMIC:-}"

# Data refresh settings against an instance's spec -> REFRESH_VALUES (spec values
# to merge in, {} when none are asked for or they are already there).
REFRESH_VALUES='{}'
refresh_values() {   # <spec json> [quiet]
    REFRESH_VALUES='{}'
    [[ -n "${REFRESH_INTERVAL}${REFRESH_DYNAMIC}" ]] || return 0
    local plan
    plan="$(jq -cn --arg i "${INSTANCE}" --arg ns "${NAMESPACE}" --argjson spec "$1" --arg ri "${REFRESH_INTERVAL}" --arg rd "${REFRESH_DYNAMIC}" \
        '{instance: $i, namespace: $ns, crSpec: $spec, refreshVars: {interval: $ri, dynamic: $rd}}' \
        | kc_python refresh --ctx /dev/stdin)" || die "Could not work out the data refresh settings."
    (( $(jq '.errors | length' <<<"${plan}") == 0 )) || die "$(jq -r '.errors | join("; ")' <<<"${plan}")"
    if [[ -z "${2:-}" ]]; then
        jq -r '.warnings[]? | "[WARN] \(.)"' <<<"${plan}" >&2
        jq -r '.summary[]? | "[INFO] Data refresh: \(.state)"' <<<"${plan}"
    fi
    REFRESH_VALUES="$(jq -c '.patch.spec // {}' <<<"${plan}")"
}
refresh_values '{}' quiet   # a bad value stops here, before anything is installed

ocu_login
ocu_require_cluster_admin
if [[ -n "${STORAGE_CLASS}" ]] && ! oc get storageclass "${STORAGE_CLASS}" &>/dev/null; then
    die "Storage class ${STORAGE_CLASS} not found (oc get storageclass); fix KUBECOST_STORAGE_CLASS or --storage-class."
fi
echo "[INFO] Settings: ${KC_VARS_FROM}; source ${SOURCE} (${SOURCE_WHY}); namespace ${NAMESPACE}"

step() { print -r -- ""; print -r -- "== $*"; }
run() {   # prints in --dry-run, runs otherwise
    if [[ "${DRY_RUN}" == true ]]; then print -r -- "[DRY-RUN] $*"; else "$@"; fi
}

# --- What is on the cluster already -----------------------------------------------------
OLM_CSV="" OLM_NS=""
read -r OLM_NS OLM_CSV <<<"$(oc get csv -A -o json 2>/dev/null | jq -r '
    [.items[] | select(.metadata.name | startswith("kubecost-operator.v")) | select(.status.reason != "Copied")]
    | first // empty | "\(.metadata.namespace) \(.metadata.name)"')" || true
IMG_NS="" IMG_CSV=""
read -r IMG_NS IMG_CSV <<<"$(oc get deployments -A -l app.kubernetes.io/managed-by=kubecost-images-install -o json 2>/dev/null | jq -r '
    .items | first // empty | "\(.metadata.namespace) \(.metadata.labels["kubecost-install/csv"] // "?")"')" || true
[[ -n "${OLM_CSV}" ]] && echo "[INFO] Installed by OLM: ${OLM_CSV} in ${OLM_NS}"
[[ -n "${IMG_CSV}" ]] && echo "[INFO] Installed from images: ${IMG_CSV} in ${IMG_NS}"

# A catalog on the cluster that offers kubecost-operator and is reachable.
# Sets OFFER_CATALOG, OFFER_DEFAULT_CHANNEL, OFFER_WHY (why not, when none).
find_offer() {
    local pms js state c
    OFFER_CATALOG="" OFFER_DEFAULT_CHANNEL="" OFFER_WHY=""
    pms="$(oc get packagemanifests -n "${CATALOG_NS}" -o json 2>/dev/null | jq -c --arg p "${KC_PACKAGE}" --arg c "${CATALOG}" '
        [.items[] | select(.metadata.name == $p) | {catalog: .status.catalogSource, ns: .status.catalogSourceNamespace,
          channel: .status.defaultChannel}] | sort_by(if .catalog == $c then 0 else 1 end)')"
    if [[ -z "${pms}" || "${pms}" == "[]" ]]; then
        OFFER_WHY="no catalog in ${CATALOG_NS} offers ${KC_PACKAGE}"
        return 1
    fi
    for js in ${(f)"$(jq -c '.[]' <<<"${pms}")"}; do
        c="$(jq -r '.catalog' <<<"${js}")"
        state="$(oc get catalogsource "${c}" -n "$(jq -r '.ns' <<<"${js}")" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
        if [[ "${state}" == READY ]]; then
            OFFER_CATALOG="${c}"; OFFER_CATALOG_NS="$(jq -r '.ns' <<<"${js}")"; OFFER_DEFAULT_CHANNEL="$(jq -r '.channel' <<<"${js}")"
            return 0
        fi
        OFFER_WHY="${OFFER_WHY:+${OFFER_WHY}; }catalog ${c} is ${state:-not ready}"
    done
    return 1
}

# --- Pick the source ----------------------------------------------------------------------
step "Install source"
MODE=""
case "${SOURCE}" in
    auto)
        if find_offer; then
            MODE=marketplace
            echo "[OK] ${KC_PACKAGE} is offered by catalog ${OFFER_CATALOG} (READY): installing from OperatorHub."
        else
            echo "[WARN] ${KC_PACKAGE} is not reachable in OperatorHub: ${OFFER_WHY}."
            if [[ -n "${KC_REGISTRY}" || -n "$(kc_latest_mirror_version)" ]]; then
                MODE=images
                echo "[INFO] Using the private registry ${KC_REGISTRY:-from the mirror record} instead."
            else
                die "No private registry either. Mirror the images (mirror_images/mirror_kubecost_images.sh) and set KUBECOST_PRIVATE_REGISTRY_LOCATION (generate_kubecost_config.sh), then run again."
            fi
        fi ;;
    marketplace)
        find_offer || die "${KC_PACKAGE} is not reachable in OperatorHub: ${OFFER_WHY}. Use --source private with mirrored images instead."
        [[ "${OFFER_CATALOG}" == "${CATALOG}" ]] || echo "[INFO] Catalog ${CATALOG} doesn't offer it; using ${OFFER_CATALOG}."
        MODE=marketplace
        echo "[OK] Installing from OperatorHub (catalog ${OFFER_CATALOG})." ;;
    private|local)
        MODE=images
        echo "[OK] Installing from mirrored images (${SOURCE})." ;;
esac

# A conflict stops a real run; a dry run reports it and still shows the rest.
BLOCKED=""
block() {
    [[ "${DRY_RUN}" == true ]] || die "$*"
    echo "[ERROR] $* (dry run: showing the rest anyway)" >&2
    BLOCKED="$*"
}
if [[ "${MODE}" == marketplace && -n "${IMG_CSV}" ]]; then
    block "The operator was installed from images in ${IMG_NS} (${IMG_CSV}); an OLM install next to it would clash. Use --source private."
fi
if [[ "${MODE}" == images && -n "${OLM_CSV}" ]]; then
    block "The operator is installed by OLM in ${OLM_NS} (${OLM_CSV}); applying it from images would overwrite OLM's CRD and roles."
fi
if [[ -n "${OLM_NS}" && "${OLM_NS}" != "${NAMESPACE}" && "${MODE}" == marketplace ]]; then
    echo "[INFO] Using the operator's namespace ${OLM_NS} (not ${NAMESPACE})."
    NAMESPACE="${OLM_NS}"
fi
if [[ -n "${IMG_NS}" && "${IMG_NS}" != "${NAMESPACE}" && "${MODE}" == images ]]; then
    echo "[INFO] Using the operator's namespace ${IMG_NS} (not ${NAMESPACE})."
    NAMESPACE="${IMG_NS}"
fi

ensure_namespace() {
    oc get namespace "${NAMESPACE}" &>/dev/null && return 0
    run oc create namespace "${NAMESPACE}" >/dev/null
    [[ "${DRY_RUN}" == true ]] || echo "[OK] Namespace ${NAMESPACE} created."
}

# --- Marketplace (OLM) ----------------------------------------------------------------------
install_marketplace() {
    local sub csv phase i=0 started=${SECONDS} ip
    CHANNEL="${CHANNEL:-${OFFER_DEFAULT_CHANNEL}}"
    step "Operator from OperatorHub: ${KC_PACKAGE}, channel ${CHANNEL}, catalog ${OFFER_CATALOG}${VERSION:+, version ${VERSION}}"
    if [[ -n "${OLM_CSV}" ]]; then
        echo "[OK] Already installed (${OLM_CSV}); upgrades follow its Subscription."
        CSV_NAME="${OLM_CSV}"
        return 0
    fi
    ensure_namespace
    if [[ -z "$(oc get operatorgroups -n "${NAMESPACE}" -o name 2>/dev/null)" ]]; then
        # The operator supports OwnNamespace/SingleNamespace only.
        oc apply --dry-run=$([[ "${DRY_RUN}" == true ]] && echo client || echo none) -f - <<EOF >/dev/null
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubecost-operator-group
  namespace: ${NAMESPACE}
spec:
  targetNamespaces: [${NAMESPACE}]
EOF
        echo "$([[ "${DRY_RUN}" == true ]] && echo "[DRY-RUN] Would create" || echo "[OK] Created") OperatorGroup kubecost-operator-group (targets ${NAMESPACE})."
    fi
    sub="$(jq -n --arg ns "${NAMESPACE}" --arg ch "${CHANNEL}" --arg src "${OFFER_CATALOG}" --arg srcns "${OFFER_CATALOG_NS}" \
        --arg ap "${APPROVAL}" --arg p "${KC_PACKAGE}" --arg v "${VERSION}" '
        {apiVersion: "operators.coreos.com/v1alpha1", kind: "Subscription",
         metadata: {name: $p, namespace: $ns},
         spec: ({channel: $ch, name: $p, source: $src, sourceNamespace: $srcns, installPlanApproval: $ap}
                + (if $v == "" then {} else {startingCSV: "kubecost-operator.v\($v)"} end))}')"
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY-RUN] Would create Subscription:"; jq -c '.spec' <<<"${sub}"
        CSV_NAME="kubecost-operator.v${VERSION:-<channel head>}"
        return 0
    fi
    print -r -- "${sub}" | oc apply -f - >/dev/null
    echo "[OK] Subscription ${KC_PACKAGE} created; waiting for the operator (up to ${TIMEOUT}s)..."
    while (( SECONDS - started < TIMEOUT )); do
        csv="$(oc get "${SUB_RES}" "${KC_PACKAGE}" -n "${NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
        if [[ "${APPROVAL}" == Manual && -z "${csv}" ]]; then
            # The first InstallPlan of a Manual Subscription waits for approval: this run is it.
            ip="$(oc get "${SUB_RES}" "${KC_PACKAGE}" -n "${NAMESPACE}" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)"
            if [[ -n "${ip}" && "$(oc get installplan "${ip}" -n "${NAMESPACE}" -o jsonpath='{.spec.approved}')" == false ]]; then
                oc patch installplan "${ip}" -n "${NAMESPACE}" --type merge -p '{"spec":{"approved":true}}' >/dev/null
                echo "  approved InstallPlan ${ip}"
            fi
        fi
        phase="$([[ -n "${csv}" ]] && oc get csv "${csv}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        printf '  [%ds/%ds] %s %s\n' $(( SECONDS - started )) "${TIMEOUT}" "${csv:-waiting for an InstallPlan}" "${phase}"
        if [[ "${phase}" == Succeeded ]]; then
            echo "[OK] ${csv} installed."
            CSV_NAME="${csv}"
            return 0
        fi
        [[ "${phase}" == Failed ]] && die "${csv} failed: $(oc get csv "${csv}" -n "${NAMESPACE}" -o jsonpath='{.status.message}')"
        sleep 10
    done
    die "The operator did not install within ${TIMEOUT}s. Check: oc get ${SUB_RES},installplan,csv -n ${NAMESPACE}"
}

# --- From mirrored images (no OLM) --------------------------------------------------------------
install_images() {
    local meta rec op_src op_dst map rendered
    VERSION="${VERSION:-$(kc_latest_mirror_version)}"
    [[ -n "${VERSION}" ]] || die "No mirrored version in configs/kubecost_config/mirror/. Run mirror_images/mirror_kubecost_images.sh --phase mirror (or save + load) first."
    meta="$(kc_mirror_meta "${VERSION}")"
    [[ -f "${meta}/record.json" && -d "${meta}/bundle/manifests" ]] \
        || die "No mirror record for ${VERSION} (${meta#${_CP4D_REPO_ROOT}/}). Mirror that version first."
    rec="$(<"${meta}/record.json")"
    CSV_NAME="$(jq -r '.csv' <<<"${rec}")"
    # The registry the cluster pulls from: the configured one, else where the images were put.
    DEST_ROOT="$(kc_dest_root)"
    if [[ -z "${DEST_ROOT}" ]]; then
        DEST_ROOT="$(jq -r '.destRoot' <<<"${rec}")"
    elif [[ "${DEST_ROOT}" != "$(jq -r '.destRoot' <<<"${rec}")" ]]; then
        echo "[WARN] Images were mirrored to $(jq -r '.destRoot' <<<"${rec}"); the cluster is pointed at ${DEST_ROOT}."
    fi
    [[ -n "${DEST_ROOT}" && "${DEST_ROOT}" != /* ]] || die "No registry for the cluster to pull from: set KUBECOST_PRIVATE_REGISTRY_LOCATION or --registry."
    # Images as the cluster will pull them: <root>/<source path>@<digest>.
    IMAGES_JSON="$(jq -c --arg r "${DEST_ROOT}" '[.images[] | . + {pull:
        "\($r)/\(.source | split("@")[0] | split("/")[1:] | join("/"))@\(.digest)"}]' <<<"${rec}")"
    op_src="$(jq -r '.[] | select(.component == "operator") | .source' <<<"${IMAGES_JSON}")"
    op_dst="$(jq -r '.[] | select(.component == "operator" and .selected) | .pull' <<<"${IMAGES_JSON}")"
    [[ -n "${op_dst}" ]] || die "The operator image was not mirrored for ${VERSION} (--no-operator); mirror it first."
    step "Operator from images: ${CSV_NAME} from ${DEST_ROOT} (redirect ${KC_REDIRECT})"
    echo "[INFO] Mirrored: $(jq -r '[.[] | select(.selected) | .component] | join(", ")' <<<"${IMAGES_JSON}")"
    MISSING_OPTIONAL=(${(f)"$(jq -r '.[] | select((.selected | not) and .class == "optional") | .component' <<<"${IMAGES_JSON}")"})
    MISSING_OPTIONAL=(${MISSING_OPTIONAL:#})
    MISSING_REQUIRED="$(jq -r '[.[] | select((.selected | not) and .class == "required") | .component] | join(", ")' <<<"${IMAGES_JSON}")"
    [[ -z "${MISSING_REQUIRED}" ]] || echo "[WARN] Required image(s) not mirrored: ${MISSING_REQUIRED}; their pods will not start."
    (( ${#MISSING_OPTIONAL} == 0 )) || echo "[INFO] Not mirrored, turned off in the instance: ${MISSING_OPTIONAL[*]}"

    # Reachable from here? (Only a hint: the workstation may not see the registry the cluster uses.)
    kc_write_authfile "${WORK}/auth.json" false 2>/dev/null || true
    if ! oc image info -a "${WORK}/auth.json" $(kc_oc_registry_flags) --filter-by-os=linux/amd64 "${op_dst}" >/dev/null 2>&1; then
        echo "[WARN] Cannot read ${op_dst%@*} from this workstation; going on (the cluster may still reach it)."
    fi

    ensure_namespace
    PULL_SECRET=""
    if [[ -n "${KC_PULL_USER}" ]]; then
        PULL_SECRET="${KUBECOST_PULL_SECRET_NAME:-kubecost-registry}"
        if [[ "${DRY_RUN}" == true ]]; then
            echo "[DRY-RUN] Would create pull Secret ${PULL_SECRET} for ${DEST_ROOT%%/*}"
        else
            oc create secret docker-registry "${PULL_SECRET}" -n "${NAMESPACE}" --docker-server="${DEST_ROOT%%/*}" \
                --docker-username="${KC_PULL_USER}" --docker-password="${KC_PULL_PASSWORD}" --dry-run=client -o yaml \
                | oc apply -f - >/dev/null
            echo "[OK] Pull Secret ${PULL_SECRET} for ${DEST_ROOT%%/*}."
        fi
    else
        echo "[INFO] No pull credentials: the cluster's global pull secret must cover ${DEST_ROOT%%/*} (if it needs a login)."
    fi

    map="${WORK}/image-map.json"
    jq -n --arg s "${op_src}" --arg d "$([[ "${KC_REDIRECT}" == idms ]] && print -r -- "${op_src}" || print -r -- "${op_dst}")" '{($s): $d}' > "${map}"
    rendered="${WORK}/operator.json"
    kc_py kubecost_bundle.py render --bundle "${meta}/bundle/manifests" --namespace "${NAMESPACE}" \
        --image-map "${map}" --pull-secret "${PULL_SECRET}" > "${rendered}" || die "Could not render the bundle."
    jq -r '.items[] | "  \(.kind)/\(.metadata.name)"' "${rendered}"
    if [[ "${DRY_RUN}" == true ]]; then
        oc apply --dry-run=server -f "${rendered}" 2>&1 | grep -v 'last-applied-configuration\|namespaces ".*" not found' | sed 's/^/  /' || true
    else
        oc apply -f "${rendered}" 2>&1 | grep -v 'last-applied-configuration' | sed 's/^/  /'
    fi

    if [[ "${KC_REDIRECT}" == (idms|both) ]]; then
        step "ImageDigestMirrorSet kubecost-mirror: ${KC_SOURCE_REGISTRY}/kubecost -> ${DEST_ROOT}/kubecost"
        run oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: kubecost-mirror
spec:
  imageDigestMirrors:
    - source: ${KC_SOURCE_REGISTRY}/kubecost
      mirrors: [${DEST_ROOT}/kubecost]
EOF
        echo "[INFO] Nodes pick it up through a MachineConfigPool update (oc get mcp)."
    fi

    if [[ "${DRY_RUN}" != true ]]; then
        echo "[INFO] Waiting for the operator..."
        oc rollout status deployment -n "${NAMESPACE}" -l app.kubernetes.io/managed-by=kubecost-images-install --timeout="${TIMEOUT}s" 2>&1 | sed 's/^/  /' \
            || die "The operator did not start. Check: oc get pods -n ${NAMESPACE}; oc describe pod -n ${NAMESPACE} -l control-plane=controller-manager"
        echo "[OK] ${CSV_NAME} running from ${DEST_ROOT}."
    fi
}

WORK="$(mktemp -d "${${TMPDIR:-/tmp}%/}/kc-install.XXXXXX")"
chmod 700 "${WORK}"
trap 'rm -rf "${WORK}"' EXIT
CSV_NAME="" DEST_ROOT="" IMAGES_JSON="[]" MISSING_OPTIONAL=() PULL_SECRET=""
if [[ "${MODE}" == marketplace ]]; then install_marketplace; else install_images; fi

# --- Instance ------------------------------------------------------------------------------------
[[ -n "${INSTANCE}" ]] || { echo "[OK] Done (no instance: --no-instance)."; exit 0; }
step "Kubecost instance ${INSTANCE} in ${NAMESPACE}"

# Image settings for an images install with explicit redirect: every operand's
# registry, the finops agent's full name, the pull secret, and optional
# components that were not mirrored turned off.
image_values() {
    [[ "${MODE}" == images ]] || { print -r -- '{}'; return 0; }
    local v='{}' comp key
    if [[ "${KC_REDIRECT}" == (explicit|both) ]]; then
        # global.imageRegistry: the MCP subchart lets it win over mcp.image.registry.
        v="$(jq -c --arg r "${DEST_ROOT}" '.global.imageRegistry = $r' <<<"${v}")"
        for comp in ${(k)KC_COMPONENT_REGISTRY_KEYS}; do
            for key in ${=KC_COMPONENT_REGISTRY_KEYS[${comp}]}; do
                v="$(jq -c --arg k "${key}" --arg r "${DEST_ROOT}" '.[$k].image.registry = $r' <<<"${v}")"
            done
        done
        v="$(jq -c --argjson img "${IMAGES_JSON}" '([$img[] | select(.component == "finops-agent" and .selected) | .pull][0]) as $f
            | if $f then .finopsagent.fullImageName = $f else . end' <<<"${v}")"
    fi
    [[ -n "${PULL_SECRET}" ]] && v="$(jq -c --arg s "${PULL_SECRET}" '.global.imagePullSecrets = [$s]' <<<"${v}")"
    for comp in "${MISSING_OPTIONAL[@]}"; do
        v="$(jq -c --arg k "${KC_COMPONENT_TOGGLE[${comp}]}" '.[$k].enabled = false' <<<"${v}")"
    done
    print -r -- "${v}"
}
IMAGE_VALUES="$(image_values)"

# License: KUBECOST_PRODUCT_KEY from kubecost_vars.sh, linked once the instance exists.
link_license() {
    [[ -n "${KUBECOST_PRODUCT_KEY:-}" ]] || { echo "[INFO] No KUBECOST_PRODUCT_KEY: free tier."; return 0; }
    local secret="${KUBECOST_PRODUCT_KEY_SECRET:-kubecost-product-key}"
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY-RUN] Would link the product key (${KUBECOST_PRODUCT_KEY[1,4]}****) to ${INSTANCE} via Secret ${secret}"
        return 0
    fi
    step "License: product key ${KUBECOST_PRODUCT_KEY[1,4]}**** -> ${INSTANCE} (Secret ${secret})"
    print -rn -- "${KUBECOST_PRODUCT_KEY}" | "${SCRIPT_DIR}/product_key/link_kubecost_product_key.sh" "${INSTANCE}" \
        -n "${NAMESPACE}" -s "${secret}" -f - --timeout "${TIMEOUT}" 2>&1 | grep -v '^\[ENV\]' | sed 's/^/  /' \
        || die "Linking the product key failed; retry: product_key/link_kubecost_product_key.sh ${INSTANCE} -n ${NAMESPACE} -k <key>"
}

if oc get "${KC_RESOURCE}" "${INSTANCE}" -n "${NAMESPACE}" &>/dev/null; then
    refresh_values "$(oc get "${KC_RESOURCE}" "${INSTANCE}" -n "${NAMESPACE}" -o json | jq -c '.spec // {}')"
    UPDATE_VALUES="$(jq -cn --argjson a "${IMAGE_VALUES}" --argjson b "${REFRESH_VALUES}" '$a * $b')"
    if [[ "${UPDATE_VALUES}" == "{}" ]]; then
        echo "[OK] Instance ${INSTANCE} exists; left as is."
    else
        START_REV="$(kc_release_revision "${INSTANCE}" "${NAMESPACE}")"; START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [[ "${DRY_RUN}" == true ]]; then
            echo "[DRY-RUN] Would update the settings of ${INSTANCE}: ${UPDATE_VALUES}"
        else
            oc patch "${KC_RESOURCE}" "${INSTANCE}" -n "${NAMESPACE}" --type merge -p "$(jq -c '{spec: .}' <<<"${UPDATE_VALUES}")" >/dev/null
            echo "[OK] Settings of ${INSTANCE} updated."
            kc_wait_for_release "${INSTANCE}" "${NAMESPACE}" "${START_REV}" "${START_TS}" "${TIMEOUT}" || true
            [[ "${REFRESH_VALUES}" == "{}" ]] || kc_check_refresh "${INSTANCE}" "${NAMESPACE}" "${TIMEOUT}"
        fi
    fi
else
    # Start from the CSV's example (the OpenShift settings), as the console does.
    if [[ "${MODE}" == images ]]; then
        EXAMPLE="$(kc_py kubecost_bundle.py example --bundle "$(kc_mirror_meta "${VERSION}")/bundle/manifests")"
    elif [[ "${DRY_RUN}" == true && -z "${OLM_CSV}" ]]; then
        EXAMPLE='{"spec": {"global": {"platforms": {"openshift": {"enabled": true}}}}}'
    else
        EXAMPLE="$(oc get csv "${CSV_NAME}" -n "${NAMESPACE}" -o json | jq -c '.metadata.annotations["alm-examples"] // "[]" | fromjson | map(select(.kind == "Kubecost"))[0] // {}')"
    fi
    if [[ -z "${CLUSTER_ID}" ]]; then
        CLUSTER_ID="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || true)"
        CLUSTER_ID="${CLUSTER_ID:-${INSTANCE}}"
    fi
    # Rendered unquoted into an env value by the chart: all digits breaks the release.
    [[ "${CLUSTER_ID}" == <-> ]] && CLUSTER_ID="ocp-${CLUSTER_ID}"
    refresh_values "$(jq -c '.spec // {}' <<<"${EXAMPLE}")"
    CR="$(jq -c --arg n "${INSTANCE}" --arg ns "${NAMESPACE}" --arg id "${CLUSTER_ID}" --arg sc "${STORAGE_CLASS}" \
        --argjson img "${IMAGE_VALUES}" --argjson refresh "${REFRESH_VALUES}" '
        {apiVersion: "charts.kubecost.com/v1", kind: "Kubecost", metadata: {name: $n, namespace: $ns},
         spec: ((.spec // {}) * {global: ({clusterId: $id} + (if $sc == "" then {} else {defaultStorageClass: $sc} end))} * $img * $refresh)}' <<<"${EXAMPLE}")"
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY-RUN] Would create:"; jq '.spec' <<<"${CR}"
        link_license
        [[ -z "${BLOCKED}" ]] || die "Dry run done, but a real run would stop: ${BLOCKED}"
        echo "[OK] Dry run done; nothing changed."
        exit 0
    fi
    print -r -- "${CR}" | oc apply -f - >/dev/null
    echo "[OK] Instance ${INSTANCE} created (clusterId ${CLUSTER_ID}${STORAGE_CLASS:+, storage class ${STORAGE_CLASS}})."
    kc_wait_for_release "${INSTANCE}" "${NAMESPACE}" 0 "$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)" "${TIMEOUT}" || exit 1
    echo "[INFO] Waiting for the aggregator..."
    oc rollout status "statefulset/${INSTANCE}-aggregator" -n "${NAMESPACE}" --timeout="${TIMEOUT}s" 2>&1 | sed 's/^/  /' \
        || echo "[WARN] The aggregator is not ready yet: oc get pods -n ${NAMESPACE}"
    [[ "${REFRESH_VALUES}" == "{}" ]] || kc_check_refresh "${INSTANCE}" "${NAMESPACE}" "${TIMEOUT}"
fi

link_license
if [[ "${DRY_RUN}" == true ]]; then
    [[ -z "${BLOCKED}" ]] || die "Dry run done, but a real run would stop: ${BLOCKED}"
    echo "[OK] Dry run done; nothing changed."; exit 0
fi
kc_save_instance_details "${INSTANCE}" "${NAMESPACE}" false >/dev/null || true
echo "[OK] Done. Next: ui_login/enable_kubecost_ui_login.sh ${INSTANCE} (publish the UI), product_key/ for Enterprise."
