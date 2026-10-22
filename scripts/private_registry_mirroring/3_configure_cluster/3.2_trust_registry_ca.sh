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
# 3.2 Trust the registry's CA on the cluster (registries with their own CA)
# ------------------------------------------------------------------------------
# MIRROR_REGISTRY_CA_FILE set (0.3_local_registry.sh sets it for its registry):
#   adds key "<host>..<port>" (OpenShift's convention) to the ConfigMap that
#   image.config.openshift.io/cluster spec.additionalTrustedCA already points
#   to - merged, never replaced - or creates "registry-mirror-ca" and points to it.
# MIRROR_REGISTRY_INSECURE=true (last resort): merges the host into
#   spec.registrySources.insecureRegistries.
# Nothing to do for registries with public TLS (ICR, Quay.io, ...).
# The MCO rolls the change out to the nodes; this waits for the MachineConfigPools.
#
#   ./3.2_trust_registry_ca.sh [--current] [--dry-run] [--no-wait]
# ==============================================================================

CURRENT=false DRY=false WAIT=true
for _a in "$@"; do
    case "${_a}" in
        --current) CURRENT=true ;;
        --dry-run) DRY=true ;;
        --no-wait) WAIT=false ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done
preg_resolve_registry
HOST="$(preg_registry_host "$(preg_pull_root)")"
INSECURE=false
preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}" && INSECURE=true
if [[ -z "${MIRROR_REGISTRY_CA_FILE:-}" ]] && ! ${INSECURE}; then
    preg_info "Registry ${HOST} uses public TLS (no MIRROR_REGISTRY_CA_FILE) - nothing to trust."
    exit 0
fi
${CURRENT} || preg_cluster_login
changed=false

if [[ -n "${MIRROR_REGISTRY_CA_FILE:-}" ]]; then
    [[ -f "${MIRROR_REGISTRY_CA_FILE}" ]] || preg_die "MIRROR_REGISTRY_CA_FILE not found: ${MIRROR_REGISTRY_CA_FILE}"
    KEY="${HOST//:/..}"
    CM="$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.additionalTrustedCA.name}' 2>/dev/null || true)"
    if [[ -z "${CM}" ]]; then
        CM="registry-mirror-ca"
        point=true
    else
        point=false
    fi
    current="$(oc get configmap "${CM}" -n openshift-config -o json 2>/dev/null || print -r -- '{}')"
    have="$(print -r -- "${current}" | KEY="${KEY}" preg_python -c 'import json,os,sys; print((json.load(sys.stdin).get("data") or {}).get(os.environ["KEY"], ""))')"
    want="$(< "${MIRROR_REGISTRY_CA_FILE}")"
    if [[ "${have}" == "${want}" ]]; then
        preg_info "CA for ${HOST} already in ConfigMap openshift-config/${CM} (key ${KEY})"
    elif ${DRY}; then
        preg_info "[dry-run] would add key ${KEY} to ConfigMap openshift-config/${CM}$(${point} && print -rn -- ' (new) and point image.config at it')"
    else
        # Merge the key into the existing data (other registries' CAs stay).
        print -r -- "${current}" | KEY="${KEY}" CAFILE="${MIRROR_REGISTRY_CA_FILE}" CM="${CM}" preg_python -c '
import json, os, sys
cm = json.load(sys.stdin) or {}
cm.setdefault("apiVersion", "v1"); cm.setdefault("kind", "ConfigMap")
md = cm.setdefault("metadata", {}); md["name"] = os.environ["CM"]; md["namespace"] = "openshift-config"
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    md.pop(k, None)
md.setdefault("labels", {})["app.kubernetes.io/managed-by"] = "private-registry-mirroring"
cm.setdefault("data", {})[os.environ["KEY"]] = open(os.environ["CAFILE"]).read()
print(json.dumps(cm))' | oc apply -f - >/dev/null
        if ${point}; then
            oc patch image.config.openshift.io cluster --type=merge -p "{\"spec\":{\"additionalTrustedCA\":{\"name\":\"${CM}\"}}}" >/dev/null
        fi
        preg_info "CA for ${HOST} added to ConfigMap openshift-config/${CM} (key ${KEY})"
        changed=true
    fi
fi

if ${INSECURE}; then
    cur="$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.registrySources.insecureRegistries}' 2>/dev/null || true)"
    if [[ "${cur}" == *"\"${HOST}\""* ]]; then
        preg_info "${HOST} already in insecureRegistries"
    elif ${DRY}; then
        preg_info "[dry-run] would add ${HOST} to image.config spec.registrySources.insecureRegistries"
    else
        list="$(CUR="${cur}" HOST="${HOST}" preg_python -c 'import json,os; c=os.environ["CUR"]; l=json.loads(c) if c else []; l.append(os.environ["HOST"]); print(json.dumps(sorted(set(l))))')"
        oc patch image.config.openshift.io cluster --type=merge -p "{\"spec\":{\"registrySources\":{\"insecureRegistries\":${list}}}}" >/dev/null
        preg_warn "${HOST} added to insecureRegistries (TLS not verified by the nodes)"
        changed=true
    fi
fi

if ${changed} && ${WAIT}; then
    preg_wait_mcp_updated "${MIRROR_MCP_TIMEOUT:-3600}"
fi
