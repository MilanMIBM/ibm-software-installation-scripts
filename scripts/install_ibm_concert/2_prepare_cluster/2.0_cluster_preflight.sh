#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -uo pipefail

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
# 2.0 Cluster preflight (read-only)
# ------------------------------------------------------------------------------
# Replaces CP4D's cpd-cli health check. Checks what IBM's installer and the
# plan's defaults need, reports everything, exits 1 on any FAIL:
#   - OpenShift >= 4.18, OpenShift Virtualization absent (IBM requirement)
#   - every configured storage class exists; a default class exists
#   - worker capacity vs the profile (IBM sizing: prod 3 x 16 vCPU / 32 Gi)
#   - runner prerequisites (internal registry, console downloads service)
#   - Istio: no foreign 'default' control plane; FaaS/Istio exclusivity
#   - data store prerequisites (catalogs, ODF) and known unverified values
# `set -e` is deliberately off: every check must run.
# ==============================================================================

eval "${OC_LOGIN}"

_fails=()
_warns=()
_ok()   { print -r -- "[ OK ] $*"; }
_fail() { print -r -- "[FAIL] $*"; _fails+=("$*"); }
_warn() { print -r -- "[WARN] $*"; _warns+=("$*"); }

concert_info "Products: $(concert_selected_products | xargs) | runner: ${CONCERT_RUNNER:-cluster} | images: ${CONCERT_IMAGE_SOURCE} | profile: ${CONCERT_PROFILE}"

# --- Platform -------------------------------------------------------------------
ver="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)"
if [[ -z "${ver}" ]]; then
    _fail "Cannot read the cluster version (not OpenShift, or no permission)."
elif is-at-least 4.18 "${ver}"; then
    _ok "OpenShift ${ver}"
else
    _fail "OpenShift ${ver} - IBM Concert 3.1 needs 4.18 or later."
fi

# awk reads all input (no early-exit grep -q): with pipefail a SIGPIPE'd oc
# would turn a match into a miss on clusters with long CSV lists.
if [[ -n "$(oc get hyperconvergeds.hco.kubevirt.io -A --no-headers 2>/dev/null || true)" ]] \
   || oc get csv -A --no-headers 2>/dev/null | awk '$2 ~ /^kubevirt-hyperconverged/ {f = 1} END {exit !f}'; then
    _fail "OpenShift Virtualization is installed - IBM: do not install it on a Concert cluster."
else
    _ok "OpenShift Virtualization not installed"
fi

# --- Storage --------------------------------------------------------------------
typeset -A _sc_seen
for v in CONCERT_STG_CLASS_BLOCK CONCERT_STG_CLASS_HUB CONCERT_STG_CLASS_CONCERT CONCERT_STG_CLASS_FILE_CONCERT \
         CONCERT_STG_CLASS_DATAAPPS CONCERT_STG_CLASS_WORKFLOWS CONCERT_STG_CLASS_DATASTORES; do
    sc="${(P)v:-}"
    [[ -z "${sc}" || -n "${_sc_seen[${sc}]:-}" ]] && continue
    _sc_seen[${sc}]=1
    if oc get storageclass "${sc}" >/dev/null 2>&1; then _ok "StorageClass ${sc}"
    else _fail "StorageClass ${sc} (${v}) does not exist."; fi
done
# Concert's buddy PVCs are ReadWriteMany (FILE_STORAGE_CLASS_CONCERT). Block
# provisioners only offer RWX for raw block volumes, so the PVCs stay Pending.
if concert_product_enabled concert && [[ -n "${CONCERT_STG_CLASS_FILE_CONCERT:-}" ]]; then
    prov="$(oc get storageclass "${CONCERT_STG_CLASS_FILE_CONCERT}" -o jsonpath='{.provisioner}' 2>/dev/null || true)"
    case "${prov}" in
        "") ;;   # missing class already reported above
        *rbd.csi.ceph.com|ebs.csi.aws.com|disk.csi.azure.com|pd.csi.storage.gke.io|csi.vsphere.vmware.com|*block*)
            _fail "CONCERT_STG_CLASS_FILE_CONCERT=${CONCERT_STG_CLASS_FILE_CONCERT} is block storage (${prov}) - Concert needs ReadWriteMany; use a file class (ODF: *-cephfs)." ;;
        *) _ok "File StorageClass ${CONCERT_STG_CLASS_FILE_CONCERT} (${prov}) for Concert ReadWriteMany volumes" ;;
    esac
fi
if oc get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' | grep -q true; then
    _ok "A default StorageClass exists"
else
    _warn "No default StorageClass - set every CONCERT_STG_CLASS_* explicitly."
fi

# --- Capacity -------------------------------------------------------------------
read -r _qual _total <<<"$(concert_worker_capacity "${CONCERT_MIN_WORKER_CPU:-16}" "${CONCERT_MIN_WORKER_MEM_GI:-32}")"
_need="${CONCERT_MIN_WORKERS:-3}"
if (( _qual >= _need )); then
    _ok "${_qual}/${_total} schedulable workers have >= ${CONCERT_MIN_WORKER_CPU} vCPU / ${CONCERT_MIN_WORKER_MEM_GI} Gi (need ${_need})"
else
    _warn "Only ${_qual}/${_total} schedulable workers meet ${CONCERT_MIN_WORKER_CPU} vCPU / ${CONCERT_MIN_WORKER_MEM_GI} Gi (IBM ${CONCERT_PROFILE} sizing needs ${_need}) - see 2.0.1_ensure_worker_capacity.sh."
fi

# --- Runner ---------------------------------------------------------------------
if [[ "${CONCERT_RUNNER:-cluster}" == cluster ]]; then
    if [[ "$(concert_runner_image_source)" == build-in-cluster ]]; then
        reg="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' 2>/dev/null)"
        [[ "${reg}" == Managed ]] && _ok "Internal image registry Managed" \
            || _fail "Internal image registry is '${reg:-unknown}' - in-cluster runner build impossible (use build-local-push or CONCERT_RUNNER=container)."
        oc get service downloads -n openshift-console >/dev/null 2>&1 && _ok "Console downloads service (oc for the runner build)" \
            || _warn "openshift-console/downloads not found - set CONCERT_RUNNER_OC_URL for the runner build."
    fi
fi

# --- Workflows: Istio / FaaS ----------------------------------------------------
if concert_product_enabled workflows; then
    if concert_product_enabled istio && concert_product_enabled faas; then
        _fail "Workflows Istio and FaaS are both on - IBM does not support that combination."
    fi
    if concert_product_enabled istio; then
        if oc get crd istios.sailoperator.io >/dev/null 2>&1; then
            owner="$(oc get istio default -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
            if oc get istio default >/dev/null 2>&1 && [[ "${owner}" != "${CONCERT_MANAGED_BY}" ]]; then
                _warn "An Istio control plane 'default' already exists (not created by these scripts) - 2.2 will refuse to change it unless CONCERT_ISTIO_ADOPT=true."
            else
                _ok "No foreign Istio 'default' control plane"
            fi
        fi
        oc get smcp -A --no-headers 2>/dev/null | grep -q . \
            && _warn "A Service Mesh 2 control plane (SMCP) exists - SM2 and SM3 side by side need care (Red Hat migration docs)."
    fi
fi

# --- Data stores ----------------------------------------------------------------
if concert_ds_server_provisioned POSTGRES; then
    _pg_src="${CONCERT_DS_PG_OPERATOR_SOURCE:-certified-operators}"
    _pg_cat="$(oc get packagemanifest -n openshift-marketplace --field-selector metadata.name=cloudnative-pg \
        -o jsonpath='{range .items[*]}{.status.catalogSource}{" "}{end}' 2>/dev/null || true)"
    if [[ -z "${_pg_cat// }" ]]; then
        _fail "No catalog offers cloudnative-pg - CloudNativePG cannot be installed (offline: run 1.2/1.3)."
    elif [[ " ${_pg_cat}" == *" ${_pg_src} "* ]]; then
        _ok "CloudNativePG offered by CatalogSource ${_pg_src}"
    else
        _warn "CatalogSource ${_pg_src} does not offer cloudnative-pg; 2.3.1 will use ${_pg_cat%% *} (set CONCERT_DS_PG_OPERATOR_SOURCE)."
    fi
fi
if concert_ds_server_provisioned S3; then
    if oc get noobaa noobaa -n openshift-storage >/dev/null 2>&1; then
        _ok "NooBaa / Multicloud Object Gateway present (reused)"
    else
        _warn "No Multicloud Object Gateway - 2.3.3 installs standalone MCG (ODF operator; needs an ODF entitlement)."
    fi
fi
# Data-store volumes start small (profile defaults) and grow by raising
# CONCERT_DS_*_STORAGE_SIZE and re-running 2.3.x, which needs volume expansion.
_ds_volumes=false
for s in POSTGRES MYSQL REDIS NEO4J; do
    if concert_ds_server_provisioned "${s}"; then _ds_volumes=true; fi
done
if ${_ds_volumes}; then
    sc="${CONCERT_STG_CLASS_DATASTORES:-${CONCERT_STG_CLASS_BLOCK:-}}"
    exp="$(oc get storageclass "${sc}" -o jsonpath='{.allowVolumeExpansion}' 2>/dev/null || true)"
    if [[ "${exp}" == true ]]; then
        _ok "StorageClass ${sc} allows volume expansion (data-store volumes can grow later)"
    else
        _warn "StorageClass ${sc:-<unset>} does not allow volume expansion - data-store volumes cannot grow later; use a class that does, or size CONCERT_DS_*_STORAGE_SIZE for the long run (they never shrink)."
    fi
fi
if concert_ds_consumer_active WORKFLOWS_S3; then
    _warn "Workflows external S3 uses CW_AUTH_TYPE='${CONCERT_DS_S3_CW_AUTH_TYPE}', which IBM does not document (spike S7)."
fi
for c in "${CONCERT_DS_CONSUMERS[@]}"; do
    concert_ds_consumer_active "${c}" || continue
    s="$(concert_ds_server_of "${c}")"
    [[ "$(concert_ds_server_provider "${s}")" == provision ]] || continue
    [[ "${s}" == RABBITMQ ]] && _fail "${c}: RabbitMQ cannot be provisioned - set CONCERT_DS_RABBITMQ_PROVIDER=existing with its values, or CONCERT_DS_WORKFLOWS_RABBITMQ=internal."
done

# --- Remote Hub -----------------------------------------------------------------
if concert_remote_hub_enabled; then
    if curl -sk --max-time 8 -o /dev/null "${CONCERT_REMOTE_HUB_URL%/}"; then
        _ok "Remote Hub ${CONCERT_REMOTE_HUB_URL} reachable from this workstation"
    else
        _warn "Remote Hub ${CONCERT_REMOTE_HUB_URL} not reachable from this workstation (the installer checks from inside the cluster)."
    fi
fi

# --- Summary --------------------------------------------------------------------
print ""
if (( ${#_fails} )); then
    concert_error "${#_fails} check(s) failed, ${#_warns} warning(s)."
    exit 1
fi
concert_info "Preflight passed with ${#_warns} warning(s)."
