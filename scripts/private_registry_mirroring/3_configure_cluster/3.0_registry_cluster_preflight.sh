#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config

# ==============================================================================
# 3.0 Cluster preflight (read-only, plus one short-lived debug pod)
# ------------------------------------------------------------------------------
#   - OpenShift >= 4.13 (ImageDigestMirrorSet / ImageTagMirrorSet)
#   - no ImageContentSourcePolicy left (convert those first - Red Hat docs)
#   - managed platforms: ROSA / ROKS / ARO / hosted control planes (mirror sets
#     may need extra steps or limit support; see MIRROR_CLUSTER_REDIRECT)
#   - existing IDMS/ITMS (ours: label app.kubernetes.io/managed-by=private-registry-mirroring)
#   - image.config: additionalTrustedCA, insecure registries
#   - global pull secret: has the registry host?
#   - local (air-gapped) mode: Subscriptions whose package is NOT in the mirrored
#     catalogs - they would be stranded once 3.4 disables the default sources
#   - registry reachable FROM A NODE (oc debug node ... curl) - --no-node-probe skips
#
#   ./3.0_registry_cluster_preflight.sh [--current] [--no-node-probe]
#     --current  use the current oc session instead of logging in with the
#                install config (MIRROR_CLUSTER_FROM / MIRROR_OC_LOGIN)
# ==============================================================================

CURRENT=false NODE_PROBE=true
for _a in "$@"; do
    case "${_a}" in
        --current) CURRENT=true ;;
        --no-node-probe) NODE_PROBE=false ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done
preg_resolve_registry
${CURRENT} || preg_cluster_login
PULL="$(preg_pull_root)"
HOST="$(preg_registry_host "${PULL}")"
SRC="$(preg_image_source)"
problems=() warnings=()
row() { printf '  %-28s %s\n' "$1" "$2"; }

print -r -- "Cluster $(oc whoami --show-server)"
ver="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
row "OpenShift" "${ver}"
autoload -Uz is-at-least
is-at-least 4.13 "${ver}" || problems+=("OpenShift ${ver} < 4.13: no ImageDigestMirrorSet/ImageTagMirrorSet")

icsp="$(oc get imagecontentsourcepolicy -o name 2>/dev/null | wc -l | tr -d ' ')"
row "ImageContentSourcePolicy" "${icsp}"
(( icsp == 0 )) || problems+=("${icsp} ImageContentSourcePolicy object(s): convert them to IDMS/ITMS first (oc adm migrate icsp; Red Hat docs)")

plat="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')"
topo="$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')"
row "platform / control plane" "${plat} / ${topo}"
if [[ "${topo}" == External ]]; then
    warnings+=("hosted control plane: mirror sets are set on the HostedCluster/ROSA side, not with oc apply - use MIRROR_CLUSTER_REDIRECT=explicit for non-IBM installs")
fi
[[ "${plat}" == IBMCloud ]] && warnings+=("Red Hat OpenShift on IBM Cloud: verify mirror sets take effect on workers (a worker reload/replace may be needed)")
if oc get configmap -n openshift-config rosa-brand-logo >/dev/null 2>&1 || [[ -n "$(oc get ns openshift-ocm-agent-operator -o name 2>/dev/null || true)" ]]; then
    warnings+=("looks like ROSA: changing IDMS/ITMS may limit Red Hat support (IBM docs) - consider MIRROR_CLUSTER_REDIRECT=explicit")
fi

print -r -- ""
print -r -- "Mirror sets"
oc get imagedigestmirrorset,imagetagmirrorset -o custom-columns='KIND:.kind,NAME:.metadata.name,MANAGED-BY:.metadata.labels.app\.kubernetes\.io/managed-by' --no-headers 2>/dev/null \
    | sed 's/^/  /' || true
[[ -n "$(oc get imagedigestmirrorset -o name 2>/dev/null)" ]] || row "" "(none)"

print -r -- ""
print -r -- "Image configuration"
ca_cm="$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.additionalTrustedCA.name}' 2>/dev/null || true)"
row "additionalTrustedCA" "${ca_cm:-(none)}"
insec="$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.registrySources.insecureRegistries}' 2>/dev/null || true)"
row "insecureRegistries" "${insec:-(none)}"
if [[ -n "${MIRROR_REGISTRY_CA_FILE:-}" ]]; then
    key="${HOST//:/..}"
    if [[ -n "${ca_cm}" ]] && oc get configmap "${ca_cm}" -n openshift-config -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null | grep -q BEGIN; then
        row "registry CA" "trusted (${ca_cm}/${key})"
    else
        row "registry CA" "NOT trusted yet - 3.2 adds it"
    fi
fi

print -r -- ""
print -r -- "Global pull secret"
hosts="$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode \
    | preg_python -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin).get("auths", {}))))')"
if [[ " ${hosts} " == *" ${HOST} "* ]]; then row "${HOST}" "present"; else row "${HOST}" "missing - 3.1 adds it"; fi

if [[ "${SRC}" == local && "$(preg_auto_bool "${MIRROR_DISABLE_DEFAULT_CATALOGS:-auto}")" == true ]]; then
    print -r -- ""
    print -r -- "Subscriptions vs mirrored operators (default catalogs get disabled in local mode)"
    inv="${MIRROR_WORKSPACE}/inventory/inventory.json"
    if [[ -f "${inv}" ]]; then
        stranded="$(oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null | preg_python -c '
import json, sys
inv = json.load(open(sys.argv[1]))
mapped = {p for pk in inv.get("operators", {}).values() for p in pk}
for s in json.load(sys.stdin).get("items", []):
    if s["spec"].get("source") in ("redhat-operators", "certified-operators", "community-operators", "redhat-marketplace") \
       and s["spec"].get("name") not in mapped:
        print(s["metadata"]["namespace"] + "/" + s["spec"]["name"] + " (" + s["spec"]["source"] + ")")' "${inv}")"
        if [[ -n "${stranded}" ]]; then
            print -r -- "${stranded}" | sed 's/^/  STRANDED  /'
            warnings+=("$(print -r -- "${stranded}" | wc -l | tr -d ' ') Subscription(s) would lose their catalog - add them to MIRROR_SHARED_OPERATORS and re-run 1.0 + 2.2")
        else
            row "" "every default-catalog Subscription is mirrored"
        fi
    else
        warnings+=("no inventory yet - cannot compare Subscriptions with the mirrored operators")
    fi
fi

if ${NODE_PROBE}; then
    print -r -- ""
    print -r -- "Registry from a node"
    node="$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${node}" ]] || node="$(oc get nodes -o jsonpath='{.items[0].metadata.name}')"
    code="$(oc debug "node/${node}" --quiet -- chroot /host curl -s -o /dev/null -m 15 -w '%{http_code}' -k "https://${HOST}/v2/" 2>/dev/null | tail -1 || true)"
    if [[ "${code}" == (200|401) ]]; then
        row "${node}" "https://${HOST}/v2/ -> HTTP ${code}"
    else
        row "${node}" "https://${HOST}/v2/ NOT reachable (${code:-no answer})"
        problems+=("the nodes cannot reach ${HOST} - for ICR from outside IBM Cloud use the public endpoint as MIRROR_REGISTRY_ROOT; for a local registry check DNS/firewall")
    fi
fi

print -r -- ""
for w in "${warnings[@]}"; do preg_warn "${w}"; done
if (( ${#problems} )); then
    for p in "${problems[@]}"; do preg_error "${p}"; done
    exit 1
fi
preg_info "Preflight passed (${SRC} registry ${PULL})."
