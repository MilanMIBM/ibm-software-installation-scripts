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
# 2.2 Istio for Concert Workflows (default on, plan decision D8)
# ------------------------------------------------------------------------------
# Must run before the first Workflows install (IBM).
#   1. Service Mesh 3 operator: the CP4D track's
#      2_prepare_cluster/2.2_install_prerequisite_operators/2.2.3.x_install_servicemesh_only.sh,
#      reused as is with SERVICE_MESH_VERSION=3 (channel `stable`).
#   2. Istio version: IBM pins v1.26.4 (CONCERT_ISTIO_VERSION). The operator
#      installs only the versions its CSV offers (the CRD enum also lists
#      end-of-life ones it then rejects: "version ... is end-of-life"). If the pin
#      is not offered: newest patch of the same minor, else newest patch of the
#      oldest offered minor above it (closest to IBM's tested version), with a warning.
#   3. IBM's concert-workflows/bin/security/cw-istio-configure-k8s.sh in the runner:
#      IstioCNI 'default' (istio-cni) + Istio 'default' (istio-system). It is
#      given the channel the Subscription already uses, so it never flips the
#      Service Mesh Subscription shared with CP4D (IBM's own default: stable-3.1).
#   4. Refuses to touch an Istio 'default' it did not create, unless
#      CONCERT_ISTIO_ADOPT=true (cluster singletons).
# The Workflows NetworkPolicy is switched off by 3.0's override values file.
# ==============================================================================

if ! concert_product_enabled istio; then
    concert_info "Workflows Istio is off - nothing to do."
    exit 0
fi
concert_product_enabled faas && concert_die "Workflows Istio and FaaS are both on - IBM does not support that combination."

export SERVICE_MESH_VERSION="${SERVICE_MESH_VERSION:-3}"
[[ "${SERVICE_MESH_VERSION}" == 3 ]] || concert_die "IBM's Istio script needs Service Mesh 3 (SERVICE_MESH_VERSION=${SERVICE_MESH_VERSION})."

eval "${OC_LOGIN}"

# --- 1. Service Mesh 3 operator (reused CP4D script) --------------------------------
# The CP4D script gives the CSV only 60s, which a first install on a fresh
# cluster often needs more than. Its Subscription is in place by then, so a
# timeout there is tolerated and the CSV is awaited here for longer.
if ! "${_CP4D_REPO_ROOT}/scripts/install_cloud_pak_for_data/2_prepare_cluster/2.2_install_prerequisite_operators/2.2.3.x_install_servicemesh_only.sh"; then
    oc get subscriptions.operators.coreos.com servicemeshoperator3 -n openshift-operators >/dev/null 2>&1 \
        || concert_die "The Service Mesh 3 Subscription was not created - see the output above."
    concert_warn "Service Mesh 3 not ready within the CP4D script's 60s - waiting up to 15 min."
fi
cp4d_wait_for_csv openshift-operators 'servicemeshoperator3\.' 900

CHANNEL="$(oc get subscriptions.operators.coreos.com servicemeshoperator3 -n openshift-operators -o jsonpath='{.spec.channel}' 2>/dev/null || true)"
CHANNEL="${CHANNEL:-${CONCERT_ISTIO_CHANNEL:-stable}}"
concert_info "Service Mesh 3 Subscription channel: ${CHANNEL}"

# --- 2. Istio version ---------------------------------------------------------------
concert_wait_for 600 "CRD istios.sailoperator.io" oc get crd istios.sailoperator.io
WANT="${CONCERT_ISTIO_VERSION:-v1.26.4}"
# Installable versions = the CSV's version picker for kind Istio (exact vX.Y.Z only).
_csv="$(oc get subscriptions.operators.coreos.com servicemeshoperator3 -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
SERVED=(${(f)"$(oc get csv "${_csv}" -n openshift-operators -o json 2>/dev/null \
    | jq -r '.spec.customresourcedefinitions.owned[]? | select(.kind == "Istio") | .specDescriptors[]?
             | select(.path == "version") | .["x-descriptors"][]? | capture("select:(?<v>v[0-9]+\\.[0-9]+\\.[0-9]+)$").v' || true)"})
VERSION="${WANT}"
if [[ -z "${SERVED[1]:-}" ]]; then
    concert_warn "Could not read the installable Istio versions from CSV ${_csv:-<none>} - using ${WANT}."
elif (( ${SERVED[(Ie)${WANT}]} )); then
    concert_info "Istio ${WANT} is supported by ${_csv}."
else
    # Same minor first, else the oldest newer minor; newest patch within it.
    VERSION="$(print -rl -- "${SERVED[@]}" | python3 -c '
import sys
want = tuple(int(x) for x in sys.argv[1].lstrip("v").split("."))
vs = sorted({tuple(int(x) for x in l.strip().lstrip("v").split(".")) for l in sys.stdin if l.strip()})
same = [v for v in vs if v[:2] == want[:2]]
newer = [v for v in vs if v[:2] > want[:2]]
pick = same[-1] if same else ([v for v in newer if v[:2] == newer[0][:2]][-1] if newer else None)
print("v" + ".".join(map(str, pick)) if pick else "")' "${WANT}")"
    [[ -n "${VERSION}" ]] || concert_die "Istio ${WANT}: ${_csv} offers no version of that minor or newer (${SERVED[*]}). Set CONCERT_ISTIO_VERSION."
    concert_warn "Istio ${WANT} (IBM's pin) is not supported by ${_csv} (end of life); using ${VERSION}, which IBM has not tested. Offered: ${SERVED[*]}"
fi

# --- 3. Ownership of the cluster singletons -----------------------------------------
typeset -A _existed
for kind in istio istiocni; do
    if oc get "${kind}" default >/dev/null 2>&1; then
        _existed[${kind}]=1
        owner="$(oc get "${kind}" default -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
        if [[ "${owner}" != "${CONCERT_MANAGED_BY}" ]] && ! concert_is_true "${CONCERT_ISTIO_ADOPT:-false}"; then
            concert_die "${kind}/default already exists and was not created by these scripts. Reuse it as is (set CONCERT_ISTIO_ADOPT=true to let IBM's script reconfigure it) or remove it."
        fi
    fi
done

# --- 4. IBM's Istio configuration (runner) --------------------------------------------
rc=0
concert_run --name istio --timeout 3600 -- \
    concert-workflows/bin/security/cw-istio-configure-k8s.sh \
    --channel "${CHANNEL}" --version "${VERSION}" --cni-version "${VERSION}" || rc=$?

# Claim what this run created (or was allowed to reconfigure) even when IBM's
# script failed, so the re-run is not refused by the ownership check above.
for kind in istio istiocni; do
    [[ -z "${_existed[${kind}]:-}" ]] || concert_is_true "${CONCERT_ISTIO_ADOPT:-false}" \
        || [[ "$(oc get "${kind}" default -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" == "${CONCERT_MANAGED_BY}" ]] \
        || continue
    oc label "${kind}" default "app.kubernetes.io/managed-by=${CONCERT_MANAGED_BY}" --overwrite >/dev/null 2>&1 || true
done
(( rc == 0 )) || concert_die "IBM's Istio configuration failed (exit ${rc}) - fix the cause and re-run this script."
concert_info "Istio ${VERSION} ready for Concert Workflows."
