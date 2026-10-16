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
# 3.3 Concert status (read-only)
# ------------------------------------------------------------------------------
# There are no CRs to watch (IBM installs plain manifests + Helm), so health is
# workload readiness: Deployments/StatefulSets, stuck pods, unbound PVCs and
# routes per product namespace, plus the provisioned data stores and Istio.
#
#   ./3.3_concert_status.sh              one report; exit 0 only if all ready
#   ./3.3_concert_status.sh --wait[=s]   repeat until ready (default 1800 s)
#   ./3.3_concert_status.sh --ibm        also run IBM's per-product status
#                                        scripts in the runner
# `set -e` is deliberately off: the report must cover everything.
# ==============================================================================

WAIT=0
IBM=false
for _arg in "$@"; do
    case "${_arg}" in
        --wait)   WAIT=1800 ;;
        --wait=*) WAIT="${_arg#*=}" ;;
        --ibm)    IBM=true ;;
        *) concert_die "Unknown argument: ${_arg}" ;;
    esac
done

eval "${OC_LOGIN}"

_report() {
    local ok=true ns unready bad pvc routes
    for ns in $(concert_product_namespaces); do
        print -r -- ""
        print -r -- "=== ${ns}"
        if ! oc get namespace "${ns}" >/dev/null 2>&1; then
            print -r -- "  [FAIL] namespace missing"
            ok=false
            continue
        fi
        unready="$(concert_ns_unready_workloads "${ns}")"
        bad="$(oc get pods -n "${ns}" --no-headers 2>/dev/null | awk '$3 ~ /CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error|CreateContainer/ {print $1" "$3}')"
        pvc="$(oc get pvc -n "${ns}" --no-headers 2>/dev/null | awk '$2 != "Bound" {print $1" "$2}')"
        routes="$(oc get routes -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{" https://"}{.spec.host}{"\n"}{end}' 2>/dev/null)"
        total="$(oc get deployments,statefulsets -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${total}" -eq 0 && -z "${bad}${pvc}" ]] && [[ "${ns}" == "${PROJECT_CONCERT_WORKFLOWS_FAAS}" || "${ns}" == "${PROJECT_CONCERT_SECURECODER}" ]]; then
            # FaaS runs functions on demand; on Kubernetes Secure Coder is Concert
            # configuration (IBM 3.1.0 deploys no workloads into SECURECODER_NS).
            print -r -- "  [ OK ] no workloads expected yet"
        elif [[ -z "${unready}${bad}${pvc}" && "${total}" -gt 0 ]]; then
            print -r -- "  [ OK ] ${total} workloads ready"
        else
            ok=false
            [[ "${total}" -eq 0 ]] && print -r -- "  [FAIL] no workloads (not installed yet?)"
            [[ -n "${unready}" ]] && print -r -- "${unready}" | sed 's/^/  [WAIT] /'
            [[ -n "${bad}" ]] && print -r -- "${bad}" | sed 's/^/  [FAIL] pod /'
            [[ -n "${pvc}" ]] && print -r -- "${pvc}" | sed 's/^/  [WAIT] pvc /'
        fi
        [[ -n "${routes}" ]] && print -r -- "${routes}" | sed 's/^/  route /'
    done

    if oc get namespace "${PROJECT_CONCERT_DATASTORES}" >/dev/null 2>&1; then
        print -r -- ""
        print -r -- "=== ${PROJECT_CONCERT_DATASTORES} (data stores)"
        unready="$(concert_ns_unready_workloads "${PROJECT_CONCERT_DATASTORES}")"
        if oc get cluster.postgresql.cnpg.io concert-pg -n "${PROJECT_CONCERT_DATASTORES}" >/dev/null 2>&1; then
            print -r -- "  postgres concert-pg: $(oc get cluster.postgresql.cnpg.io concert-pg -n "${PROJECT_CONCERT_DATASTORES}" -o jsonpath='{.status.phase} ({.status.readyInstances}/{.spec.instances} ready)')"
        fi
        oc get objectbucketclaims -n "${PROJECT_CONCERT_DATASTORES}" --no-headers 2>/dev/null | awk '{print "  bucket " $1 ": " $NF}'
        if [[ -n "${unready}" ]]; then ok=false; print -r -- "${unready}" | sed 's/^/  [WAIT] /'; else print -r -- "  [ OK ] data store workloads ready"; fi
    fi

    if concert_product_enabled istio; then
        print -r -- ""
        ready="$(oc get istio default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
        if [[ "${ready}" == True ]]; then print -r -- "=== Istio: [ OK ] control plane Ready"
        else ok=false; print -r -- "=== Istio: [FAIL] control plane not Ready (${ready:-missing})"; fi
    fi
    ${ok}
}

if (( WAIT > 0 )); then
    start=${SECONDS}
    until _report; do
        (( SECONDS - start >= WAIT )) && { concert_error "Not ready after ${WAIT}s."; exit 1; }
        concert_info "Not ready yet - checking again in 30s ($(( SECONDS - start ))s)"
        sleep 30
    done
    rc=0
else
    _report
    rc=$?
fi

if ${IBM}; then
    cmds=()
    concert_product_enabled hub       && cmds+=("concert-hub/bin/status-k8s --namespace=${PROJECT_CONCERT_HUB}")
    concert_product_enabled concert   && cmds+=("concert/k8s/status.sh --namespace=${PROJECT_CONCERT}")
    concert_product_enabled dataapps  && cmds+=("dataapps/k8s/status.sh --namespace=${PROJECT_CONCERT_DATAAPPS}")
    concert_product_enabled workflows && cmds+=("concert-workflows/bin/status.sh --namespace=${PROJECT_CONCERT_WORKFLOWS}")
    concert_run --name status --timeout 900 -- __shell__ "${(j:; :)cmds}" || true
fi

print -r -- ""
(( rc == 0 )) && concert_info "All Concert components are ready." || concert_warn "Some components are not ready."
exit ${rc}
