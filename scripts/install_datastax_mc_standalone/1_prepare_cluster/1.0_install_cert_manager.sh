#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
mc_require_config

# ==============================================================================
# 1.0 cert-manager Operator for Red Hat OpenShift
# ------------------------------------------------------------------------------
# Installs it with the CP4D track's script (reused unchanged; it runs against
# this config because ENV_TARGET=datastax_mc is exported). It skips the install
# when a healthy cert-manager is already there.
#
# Then, with MC_CERT_MANAGER_OWNER_REF=true, adds --enable-certificate-owner-ref
# to the operator's CertManager/cluster resource. DataStax's Helm guide sets
# this flag; without it the OpenShift operator leaves a certificate's secret
# behind when the Certificate is deleted.
# ==============================================================================

"${_CP4D_REPO_ROOT}/scripts/install_cloud_pak_for_data/1_global_pull_secret_and_certmanager/1.0_set_up_openshift_certmanager.sh"

eval "${OC_LOGIN}"

# --- Version (DataStax: cert-manager 1.18.5 or later) -------------------------
cm_ver="$(oc get crd certificates.cert-manager.io -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)"
cm_ver="${cm_ver#v}"
if [[ -z "${cm_ver}" ]]; then
    mc_warn "Could not read the cert-manager version from its CRDs."
elif ! is-at-least 1.18.5 "${cm_ver}"; then
    mc_warn "cert-manager ${cm_ver} is older than the 1.18.5 Mission Control requires - upgrade the operator (its channel) before installing."
else
    mc_info "cert-manager ${cm_ver} (>= 1.18.5)."
fi

# --- Certificate owner references --------------------------------------------
if ! mc_is_true "${MC_CERT_MANAGER_OWNER_REF:-true}"; then
    mc_info "MC_CERT_MANAGER_OWNER_REF=false - leaving the cert-manager arguments alone."
    exit 0
fi

if ! oc get crd certmanagers.operator.openshift.io >/dev/null 2>&1; then
    mc_warn "No certmanagers.operator.openshift.io CRD: cert-manager was not installed by the OpenShift operator."
    mc_warn "Set --enable-certificate-owner-ref=true on its controller yourself, as DataStax's Helm guide shows."
    exit 0
fi

# The operator creates CertManager/cluster shortly after its CSV succeeds.
for (( i = 0; i < 30; i++ )); do
    oc get certmanagers.operator.openshift.io cluster >/dev/null 2>&1 && break
    sleep 5
done
oc get certmanagers.operator.openshift.io cluster >/dev/null 2>&1 \
    || mc_die "CertManager/cluster did not appear - check the cert-manager operator in openshift-cert-manager-operator."

FLAG="--enable-certificate-owner-ref"
current="$(oc get certmanagers.operator.openshift.io cluster -o json | jq -c '.spec.controllerConfig.overrideArgs // []')"
if jq -e --arg f "${FLAG}" 'map(select(. == $f or startswith($f + "="))) | length > 0' <<<"${current}" >/dev/null; then
    mc_info "CertManager/cluster already has ${FLAG}."
else
    # overrideArgs is a list, which a merge patch replaces whole - so send the
    # existing entries along with the new one.
    patch="$(jq -c --arg f "${FLAG}" '{spec: {controllerConfig: {overrideArgs: (. + [$f])}}}' <<<"${current}")"
    oc patch certmanagers.operator.openshift.io cluster --type=merge -p "${patch}"
    mc_info "Added ${FLAG} to CertManager/cluster; the operator rolls the cert-manager controller."
    oc rollout status deployment/cert-manager -n cert-manager --timeout=300s 2>/dev/null \
        || mc_warn "cert-manager controller rollout not confirmed within 5 minutes - check: oc get pods -n cert-manager"
fi
