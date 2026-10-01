#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

eval "${CPDM_OC_LOGIN}"

#---
# Set the namespace to target. Defaults to the CPD instance operands namespace.
NAMESPACE="${PROJECT_CPD_INST_OPERANDS}"

# Stuck pod phases to delete (no image-pull patching for these)
STUCK_PHASES=("Pending")

# Container waiting/terminated reasons that indicate image pull failure
IMGPULL_REASONS=("ImagePullBackOff" "ErrImagePull")

# Other stuck container reasons to delete without patching
OTHER_STUCK_REASONS=("CrashLoopBackOff" "Error" "OOMKilled")
#---

# ---------------------------------------------------------------------------
# Registry detection / swap helpers (borrowed from 4.x_fix_imagepulloff_error)
# ---------------------------------------------------------------------------

_detect_failing_registry() {
    local ns="$1"
    local pod_events
    pod_events=$(oc get events -n "${ns}" --field-selector reason=Failed 2>/dev/null \
        | grep -iE 'ImagePullBackOff|ErrImagePull|Failed to pull image' || true)

    if echo "${pod_events}" | grep -qE '"cp\.icr\.io/'; then
        echo "cp.icr.io"
    elif echo "${pod_events}" | grep -qE '"icr\.io/'; then
        echo "icr.io"
    else
        echo ""
    fi
}

_swap_registry_prefix() {
    local img="$1" failing_registry="$2"
    if [[ "${failing_registry}" == "icr.io" && "${img}" == icr.io/* && "${img}" != cp.icr.io/* ]]; then
        echo "cp.${img}"
    elif [[ "${failing_registry}" == "cp.icr.io" && "${img}" == cp.icr.io/* ]]; then
        echo "${img#cp.}"
    else
        echo ""
    fi
}

# Patch all containers (and initContainers) in a given resource kind/name.
_patch_resource_images() {
    local ns="$1" kind="$2" name="$3" failing_registry="$4"
    local patched=0 idx img new_img

    local container_count
    container_count=$(oc get "${kind}" "${name}" -n "${ns}" \
        -o jsonpath='{.spec.template.spec.containers}' 2>/dev/null | jq '. | length' 2>/dev/null || echo 0)

    for idx in $(seq 0 $(( container_count - 1 ))); do
        img=$(oc get "${kind}" "${name}" -n "${ns}" \
            -o jsonpath="{.spec.template.spec.containers[${idx}].image}" 2>/dev/null || true)
        new_img=$(_swap_registry_prefix "${img}" "${failing_registry}")
        if [[ -n "${new_img:-}" ]]; then
            oc patch "${kind}" "${name}" -n "${ns}" \
                --type='json' \
                -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/${idx}/image\",\"value\":\"${new_img}\"}]" \
                2>/dev/null || true
            echo "[OK] ${kind}/${name} container[${idx}]: ${img} → ${new_img}"
            patched=$(( patched + 1 ))
        fi
    done

    local init_count
    init_count=$(oc get "${kind}" "${name}" -n "${ns}" \
        -o jsonpath='{.spec.template.spec.initContainers}' 2>/dev/null | jq '. | length' 2>/dev/null || echo 0)

    for idx in $(seq 0 $(( init_count - 1 ))); do
        img=$(oc get "${kind}" "${name}" -n "${ns}" \
            -o jsonpath="{.spec.template.spec.initContainers[${idx}].image}" 2>/dev/null || true)
        new_img=$(_swap_registry_prefix "${img}" "${failing_registry}")
        if [[ -n "${new_img:-}" ]]; then
            oc patch "${kind}" "${name}" -n "${ns}" \
                --type='json' \
                -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/initContainers/${idx}/image\",\"value\":\"${new_img}\"}]" \
                2>/dev/null || true
            echo "[OK] ${kind}/${name} initContainer[${idx}]: ${img} → ${new_img}"
            patched=$(( patched + 1 ))
        fi
    done

    if [[ "${patched}" -eq 0 ]]; then
        echo "[SKIP] ${kind}/${name}: no images matched registry prefix '${failing_registry}'"
    fi
}

# For a given pod name, find its owning Job or Deployment and patch registry prefix.
_patch_owner_of_pod() {
    local ns="$1" pod="$2" failing_registry="$3"

    local owner_kind owner_name
    # Direct owners: Job or ReplicaSet
    owner_kind=$(oc get pod "${pod}" -n "${ns}" \
        -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)
    owner_name=$(oc get pod "${pod}" -n "${ns}" \
        -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)

    if [[ -z "${owner_kind:-}" || -z "${owner_name:-}" ]]; then
        echo "[SKIP] ${pod}: no ownerReference found, cannot patch owner."
        return
    fi

    if [[ "${owner_kind}" == "Job" ]]; then
        echo "[INFO] ${pod} is owned by Job/${owner_name} - patching job image prefix..."
        _patch_resource_images "${ns}" "job" "${owner_name}" "${failing_registry}"

    elif [[ "${owner_kind}" == "ReplicaSet" ]]; then
        # Walk up to the Deployment
        local deploy_name
        deploy_name=$(oc get rs "${owner_name}" -n "${ns}" \
            -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)
        if [[ -n "${deploy_name:-}" ]]; then
            echo "[INFO] ${pod} → RS/${owner_name} → Deployment/${deploy_name} - patching deployment image prefix..."
            _patch_resource_images "${ns}" "deployment" "${deploy_name}" "${failing_registry}"
        else
            echo "[INFO] ${pod} → RS/${owner_name} (no Deployment owner) - patching RS image prefix..."
            _patch_resource_images "${ns}" "replicaset" "${owner_name}" "${failing_registry}"
        fi

    elif [[ "${owner_kind}" == "StatefulSet" ]]; then
        echo "[INFO] ${pod} is owned by StatefulSet/${owner_name} - patching statefulset image prefix..."
        _patch_resource_images "${ns}" "statefulset" "${owner_name}" "${failing_registry}"

    elif [[ "${owner_kind}" == "DaemonSet" ]]; then
        echo "[INFO] ${pod} is owned by DaemonSet/${owner_name} - patching daemonset image prefix..."
        _patch_resource_images "${ns}" "daemonset" "${owner_name}" "${failing_registry}"

    else
        echo "[SKIP] ${pod}: owner kind '${owner_kind}' not handled for image patching."
    fi
}

# ---------------------------------------------------------------------------
# Phase 1: Patch registry prefix on owners of image-pull-stuck pods
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 1: Patch registry prefix (icr.io ↔ cp.icr.io) on owners of image-pull-stuck pods ==="

FAILING_REGISTRY=$(_detect_failing_registry "${NAMESPACE}")

if [[ -z "${FAILING_REGISTRY:-}" ]]; then
    echo "[INFO] No clear failing registry detected from events - will attempt to infer per-pod."
fi

IMGPULL_PODS=()
for REASON in "${IMGPULL_REASONS[@]}"; do
    FOUND=(${(f)"$(oc get pods -n "${NAMESPACE}" -o json | \
        jq -r --arg r "${REASON}" \
        '.items[] | select(
            (.status.containerStatuses // [])[] |
            (.state.waiting.reason // "") == $r
            or (.lastState.terminated.reason // "") == $r
        ) | .metadata.name' 2>/dev/null | sort -u || true)"})
    for P in "${FOUND[@]}"; do
        [[ -n "${P:-}" ]] && IMGPULL_PODS+=("${P}")
    done
done
# Also catch pods listed with those reasons in plain oc get pods output
IMGPULL_PODS+=(${(f)"$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E 'ImagePullBackOff|ErrImagePull' | awk '{print $1}' || true)"})
# Deduplicate
IMGPULL_PODS=(${(u)IMGPULL_PODS})

if [[ ${#IMGPULL_PODS[@]} -eq 0 || -z "${IMGPULL_PODS[1]:-}" ]]; then
    echo "[INFO] No image-pull-stuck pods found in ${NAMESPACE}."
else
    echo "[INFO] Found ${#IMGPULL_PODS[@]} image-pull-stuck pod(s) in ${NAMESPACE}."
    for POD in "${IMGPULL_PODS[@]}"; do
        [[ -z "${POD:-}" ]] && continue

        # Per-pod registry inference if global detection gave nothing
        local_failing_registry="${FAILING_REGISTRY}"
        if [[ -z "${local_failing_registry:-}" ]]; then
            # Look at the pod's container image directly
            FIRST_IMG=$(oc get pod "${POD}" -n "${NAMESPACE}" \
                -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)
            if [[ "${FIRST_IMG}" == cp.icr.io/* ]]; then
                local_failing_registry="cp.icr.io"
            elif [[ "${FIRST_IMG}" == icr.io/* ]]; then
                local_failing_registry="icr.io"
            fi
        fi

        if [[ -z "${local_failing_registry:-}" ]]; then
            echo "[SKIP] ${POD}: cannot determine failing registry, skipping patch."
            continue
        fi

        echo ""
        echo "[INFO] Processing image-pull-stuck pod: ${POD} (failing registry: ${local_failing_registry})"
        _patch_owner_of_pod "${NAMESPACE}" "${POD}" "${local_failing_registry}"
    done
fi

# ---------------------------------------------------------------------------
# Phase 2: Delete all stuck pods (Pending, image-pull errors, other stuck states)
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 2: Delete stuck pods in namespace: ${NAMESPACE} ==="

DELETED=0

# Delete pods in stuck phases (e.g. Pending)
for PHASE in "${STUCK_PHASES[@]}"; do
    PODS=(${(f)"$(oc get pods -n "${NAMESPACE}" --field-selector="status.phase=${PHASE}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"})
    if [[ ${#PODS[@]} -gt 0 && -n "${PODS[1]:-}" ]]; then
        echo "[INFO] Deleting ${#PODS[@]} pod(s) in phase '${PHASE}':"
        for POD in "${PODS[@]}"; do
            [[ -z "${POD:-}" ]] && continue
            echo "  - ${POD}"
            oc delete pod "${POD}" -n "${NAMESPACE}" --grace-period=0 --force 2>/dev/null || true
            (( DELETED++ )) || true
        done
    else
        echo "[INFO] No pods found in phase '${PHASE}'"
    fi
done

# Delete image-pull-stuck pods (already collected above)
if [[ ${#IMGPULL_PODS[@]} -gt 0 && -n "${IMGPULL_PODS[1]:-}" ]]; then
    echo "[INFO] Deleting ${#IMGPULL_PODS[@]} image-pull-stuck pod(s):"
    for POD in "${IMGPULL_PODS[@]}"; do
        [[ -z "${POD:-}" ]] && continue
        echo "  - ${POD}"
        oc delete pod "${POD}" -n "${NAMESPACE}" --grace-period=0 --force 2>/dev/null || true
        (( DELETED++ )) || true
    done
fi

# Delete pods in other stuck container states (CrashLoopBackOff, OOMKilled, etc.)
for REASON in "${OTHER_STUCK_REASONS[@]}"; do
    PODS=(${(f)"$(oc get pods -n "${NAMESPACE}" -o json | \
        jq -r --arg r "${REASON}" \
        '.items[] | select(
            (.status.containerStatuses // [])[] |
            (.state.waiting.reason // "") == $r
            or (.lastState.terminated.reason // "") == $r
        ) | .metadata.name' 2>/dev/null | sort -u || true)"})
    # Also catch pods surfaced in plain oc get pods (covers Terminating, etc.)
    PODS+=(${(f)"$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
        | grep -i "${REASON}" | awk '{print $1}' || true)"})
    PODS=(${(u)PODS})
    if [[ ${#PODS[@]} -gt 0 && -n "${PODS[1]:-}" ]]; then
        echo "[INFO] Deleting ${#PODS[@]} pod(s) with reason '${REASON}':"
        for POD in "${PODS[@]}"; do
            [[ -z "${POD:-}" ]] && continue
            echo "  - ${POD}"
            oc delete pod "${POD}" -n "${NAMESPACE}" --grace-period=0 --force 2>/dev/null || true
            (( DELETED++ )) || true
        done
    else
        echo "[INFO] No pods found with reason '${REASON}'"
    fi
done

echo ""
echo "[INFO] Done. Total pods deleted: ${DELETED}"
