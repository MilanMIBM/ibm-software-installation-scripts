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
# 5.1 Turbonomic operator (Concert Optimize)
# ------------------------------------------------------------------------------
# Concert Optimize is IBM Turbonomic. IBM's Concert installer does not deploy
# it; the t8c-operator does (5.2/5.4), and IBM's manage-product.sh attaches it
# to the Hub (5.5).
#
# Installed without OLM, following the t8c-operator README, from
# github.com/IBM/t8c-operator at the tag CONCERT_OPTIMIZE_VERSION: IBM's
# version matrix pairs Hub 3.0.3 (Concert 3.1.0) with Turbonomic 8.21.2, whose
# tag pins operator image 42.116. The certified OLM package (t8c-certified)
# only offers the newest operator (42.117 = 8.21.3 on OCP 4.21).
#
# Manifests are downloaded to concert_workspace/optimize/<version>/ with their
# SHA-256 recorded on the first download and verified afterwards (as in 0.1).
# The Xl CRD is cluster-scoped and large (~180 KB as JSON, 70% of the 256 KiB
# last-applied annotation limit a client-side apply would hit as it grows), so
# it is applied server-side - unless an OLM operator (another Turbonomic) owns
# it. The operator itself is namespace-scoped (WATCH_NAMESPACE).
# ==============================================================================

concert_product_enabled optimize || { concert_info "Optimize is not selected - nothing to do."; exit 0; }
[[ "${CONCERT_IMAGE_SOURCE:-entitled}" == entitled ]] \
    || concert_die "Optimize pulls Turbonomic from icr.io/cpopen; mirrored/air-gapped Turbonomic is not supported by these scripts yet."
concert_require_vars CONCERT_OPTIMIZE_VERSION

NS="$(concert_optimize_namespace)"
DIR="$(concert_optimize_manifest_dir)"
BASE="https://raw.githubusercontent.com/IBM/t8c-operator/${CONCERT_OPTIMIZE_VERSION}"
CRD="xls.charts.helm.k8s.io"
FILES=(
    deploy/service_account.yaml
    deploy/role.yaml
    deploy/role_binding.yaml
    deploy/crds/charts_v1_xl_crd.yaml
    deploy/operator.yaml
    deploy/samples/platform/gw/charts_platform_gw_v1_xl_cr.yaml   # reference for 5.4
)

# --- Manifests (workstation) ----------------------------------------------------
for f in "${FILES[@]}"; do
    dest="${DIR}/${f}"
    [[ -f "${dest}" ]] && continue
    mkdir -p "${dest:h}"
    concert_info "Downloading ${BASE}/${f}"
    curl -fsSL --retry 3 -o "${dest}.part" "${BASE}/${f}" \
        || concert_die "Download failed: ${BASE}/${f} (is ${CONCERT_OPTIMIZE_VERSION} a t8c-operator tag?)"
    mv "${dest}.part" "${dest}"
done

sums="${DIR}/SHA256SUMS"
current=""
for f in "${FILES[@]}"; do
    current+="$(concert_sha256 "${DIR}/${f}")  ${f}"$'\n'
done
if [[ -f "${sums}" ]]; then
    [[ "${current}" == "$(<"${sums}")"$'\n' ]] \
        || concert_die "Manifests in ${DIR} changed since their SHA-256 was recorded (${sums}). Delete the directory to accept the new ones."
    concert_info "Manifests match the recorded SHA-256."
else
    print -rn -- "${current}" > "${sums}"
    concert_info "Manifest SHA-256 recorded in ${sums}."
fi

IMAGE="$(awk '$1 == "image:" {print $2; exit}' "${DIR}/deploy/operator.yaml")"
concert_info "t8c-operator for Turbonomic ${CONCERT_OPTIMIZE_VERSION}: ${IMAGE}"

eval "${OC_LOGIN}"

# --- Namespace and SCC ------------------------------------------------------------
cp4d_ensure_namespace "${NS}"
if [[ "${CONCERT_OPTIMIZE_SCC:-restricted}" == anyuid ]]; then
    oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${NS}" >/dev/null
    concert_info "SCC anyuid granted to the service accounts of ${NS} (CONCERT_OPTIMIZE_SCC=anyuid)."
else
    concert_optimize_fsgroup >/dev/null \
        || concert_die "Namespace ${NS} has no openshift.io/sa.scc.uid-range annotation - set CONCERT_OPTIMIZE_SCC=anyuid."
fi

# --- CRD --------------------------------------------------------------------------
# awk reads all input (no early-exit grep -q): see 2.0 on pipefail and SIGPIPE.
if oc get csv -A -o jsonpath='{range .items[*]}{.spec.customresourcedefinitions.owned[*].name}{"\n"}{end}' 2>/dev/null \
    | tr ' ' '\n' | awk -v c="${CRD}" '$0 == c {f = 1} END {exit !f}'; then
    concert_warn "An OLM operator owns ${CRD} (another Turbonomic on this cluster) - leaving the CRD as it is."
else
    oc apply --server-side --force-conflicts --field-manager="${CONCERT_MANAGED_BY}" \
        -f "${DIR}/deploy/crds/charts_v1_xl_crd.yaml" >/dev/null
    concert_info "CRD ${CRD} applied (server-side)."
fi
oc wait --for=condition=Established "crd/${CRD}" --timeout=120s >/dev/null

# --- Operator ---------------------------------------------------------------------
for f in deploy/service_account.yaml deploy/role.yaml deploy/role_binding.yaml deploy/operator.yaml; do
    oc apply -n "${NS}" -f "${DIR}/${f}" >/dev/null
done
concert_info "Waiting for the t8c-operator in ${NS}..."
oc rollout status deployment/t8c-operator -n "${NS}" --timeout=600s

concert_info "t8c-operator ready. Next: 5.2_deploy_turbonomic.sh"
