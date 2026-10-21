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
# 1.1 Preflight - read-only checks against the DataStax OpenShift prerequisites
# ------------------------------------------------------------------------------
# Changes nothing. Exits 1 when a check fails; warnings do not fail it.
# ==============================================================================

FAILED=()
ok()   { print -r -- "  [OK]   $*"; }
warn() { print -r -- "  [WARN] $*"; }
fail() { print -r -- "  [FAIL] $*"; FAILED+=("$*"); }

eval "${OC_LOGIN}"
echo "[INFO] Preflight for Mission Control ${MC_VERSION} (${MC_PLANE} plane) in ${MC_NAMESPACE} on $(oc whoami --show-server)"

# --- OpenShift 4.8+ -------------------------------------------------------------
ocp_ver="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
if [[ -z "${ocp_ver}" ]]; then
    fail "Could not read the OpenShift version (clusterversion/version) - is this OpenShift, and are you cluster-admin?"
elif is-at-least 4.8 "${ocp_ver}"; then
    ok "OpenShift ${ocp_ver}"
else
    fail "OpenShift ${ocp_ver} is older than 4.8"
fi

# --- Helm 3.14 - 3.18 and chart access --------------------------------------------
mc_ensure_helm
ok "helm $(mc_helm_version_of "${MC_HELM}") (${MC_HELM})"
if "${MC_HELM}" show chart oci://icr.io/mission-control-helm/mission-control --version "${MC_VERSION}" >/dev/null 2>&1; then
    ok "Chart oci://icr.io/mission-control-helm/mission-control:${MC_VERSION} reachable"
else
    fail "Chart oci://icr.io/mission-control-helm/mission-control:${MC_VERSION} not reachable (version typo or no network to icr.io?)"
fi

# --- Entitlement key ----------------------------------------------------------------
if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
    if [[ "${IBM_ENTITLEMENT_KEY}" != "${IBM_ENTITLEMENT_KEY//[[:space:]]/}" ]]; then
        fail "IBM_ENTITLEMENT_KEY contains whitespace (DataStax: no leading or trailing spaces)"
    else
        ok "IBM_ENTITLEMENT_KEY set"
    fi
else
    fail "IBM_ENTITLEMENT_KEY is empty"
fi

# --- cert-manager -------------------------------------------------------------------
cm_ver="$(oc get crd certificates.cert-manager.io -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)"
if [[ -z "$(oc get crd certificates.cert-manager.io -o name 2>/dev/null || true)" ]]; then
    fail "cert-manager is not installed (run 1.0_install_cert_manager.sh)"
elif [[ -n "${cm_ver}" ]] && ! is-at-least 1.18.5 "${cm_ver#v}"; then
    fail "cert-manager ${cm_ver} is older than 1.18.5"
else
    ok "cert-manager ${cm_ver:-<version unknown>}"
fi

# --- OpenShift DNS (the Loki/Mimir resolver settings point at it) -----------------
if oc get svc dns-default -n openshift-dns >/dev/null 2>&1; then
    ok "DNS service openshift-dns/dns-default"
else
    fail "openshift-dns/dns-default not found - the Loki/Mimir resolver values need adjusting for this cluster"
fi

# --- Storage --------------------------------------------------------------------------
if [[ -z "${MC_STORAGE_CLASS:-}" ]]; then
    fail "MC_STORAGE_CLASS is empty"
elif oc get storageclass "${MC_STORAGE_CLASS}" >/dev/null 2>&1; then
    ok "Storage class ${MC_STORAGE_CLASS}"
else
    fail "Storage class ${MC_STORAGE_CLASS} not found (oc get storageclass)"
fi

# --- Platform nodes ---------------------------------------------------------------------
labelled="$(oc get nodes -l mission-control.datastax.com/role=platform -o name 2>/dev/null | wc -l | tr -d ' ')"
case "${MC_PLATFORM_NODES:-all-workers}" in
    existing)
        (( labelled > 0 )) && ok "${labelled} node(s) labelled mission-control.datastax.com/role=platform" \
                           || fail "MC_PLATFORM_NODES=existing but no node is labelled mission-control.datastax.com/role=platform" ;;
    *)
        ok "Platform nodes: ${labelled} labelled now; 1.3 labels '${MC_PLATFORM_NODES:-all-workers}'" ;;
esac

# --- Plane specifics --------------------------------------------------------------------
if [[ "${MC_PLANE}" == data ]]; then
    [[ -n "${MC_VECTOR_AGGREGATOR_URL:-}" ]] && ok "Vector aggregator: ${MC_VECTOR_AGGREGATOR_URL}" \
                                             || fail "MC_VECTOR_AGGREGATOR_URL is empty (required for a data plane)"
else
    case "${MC_OBSERVABILITY_STORE:-minio}" in
        minio) ok "Observability storage: in-cluster MinIO" ;;
        s3)
            if [[ -n "${MC_S3_ACCESS_KEY_ID:-}" && -n "${MC_S3_SECRET_ACCESS_KEY:-}" ]]; then
                ok "Observability storage: S3 ${MC_S3_ENDPOINT:-s3.${MC_S3_REGION}.amazonaws.com} (buckets ${MC_LOGS_BUCKET}, ${MC_METRICS_BUCKET} must already exist)"
            else
                fail "MC_OBSERVABILITY_STORE=s3 needs MC_S3_ACCESS_KEY_ID and MC_S3_SECRET_ACCESS_KEY"
            fi ;;
        *) fail "MC_OBSERVABILITY_STORE must be minio or s3" ;;
    esac
fi

# --- Existing release ---------------------------------------------------------------------
if oc get namespace "${MC_NAMESPACE}" >/dev/null 2>&1; then
    rel_status="$("${MC_HELM}" status "${MC_RELEASE_NAME}" -n "${MC_NAMESPACE}" -o json 2>/dev/null | jq -r '.info.status + " (chart " + .chart.metadata.version + ")"' 2>/dev/null || true)"
    [[ -n "${rel_status}" ]] && warn "Release ${MC_RELEASE_NAME} already exists: ${rel_status} - 2.1 upgrades it in place"
fi
other="$(oc get deployments -A -l app.kubernetes.io/name=mission-control -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u | grep -vx "${MC_NAMESPACE}" || true)"
[[ -n "${other}" ]] && warn "Mission Control also runs in: ${(f)other} (e.g. CP4D's DataStax service) - CRDs are cluster-wide and shared"

echo ""
if (( ${#FAILED} )); then
    echo "[ERROR] Preflight failed (${#FAILED} check(s)):"
    printf '          - %s\n' "${FAILED[@]}"
    exit 1
fi
echo "[INFO] Preflight passed."
