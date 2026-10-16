#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

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
# Delete stuck pods in the Concert namespaces
# ------------------------------------------------------------------------------
# Duplicate of the CP4D track's x_clean_or_debug_cp4d/x_delete_stuck_pods.sh:
#   - logs in with OC_LOGIN (no cpd-cli) and loops over the Concert product
#     namespaces + the data store namespace (or the namespaces given as args);
#   - Phase 1 (the icr.io <-> cp.icr.io prefix swap) is replaced by a
#     diagnostic: every Concert image comes from one prefix, so a pull failure
#     here means a missing/wrong pull secret or an unmirrored image, which a
#     prefix swap cannot fix;
#   - Phase 2 (deleting stuck pods) is unchanged.
#
#   ./x_delete_stuck_pods_concert.sh [namespace ...]
# ==============================================================================

eval "${OC_LOGIN}"

#---
NAMESPACES=("$@")
if (( ${#NAMESPACES} == 0 )); then
    NAMESPACES=(${(f)"$(concert_product_namespaces)"})
    oc get namespace "${PROJECT_CONCERT_DATASTORES}" >/dev/null 2>&1 && NAMESPACES+=("${PROJECT_CONCERT_DATASTORES}")
fi

# Stuck pod phases to delete (no image-pull patching for these)
STUCK_PHASES=("Pending")

# Container waiting/terminated reasons that indicate image pull failure
IMGPULL_REASONS=("ImagePullBackOff" "ErrImagePull")

# Other stuck container reasons to delete without patching
OTHER_STUCK_REASONS=("CrashLoopBackOff" "Error" "OOMKilled")
#---

TOTAL_DELETED=0
for NAMESPACE in "${NAMESPACES[@]}"; do
    [[ -n "${NAMESPACE}" ]] || continue
    oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || { echo "[SKIP] ${NAMESPACE}: namespace not found"; continue; }

    # -----------------------------------------------------------------------
    # Phase 1: diagnose image pull failures (replaces CP4D's prefix swap)
    # -----------------------------------------------------------------------
    echo ""
    echo "=== Phase 1: Image pull diagnostics in ${NAMESPACE} ==="
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
    IMGPULL_PODS+=(${(f)"$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
        | grep -E 'ImagePullBackOff|ErrImagePull' | awk '{print $1}' || true)"})
    IMGPULL_PODS=(${(u)IMGPULL_PODS})

    if [[ ${#IMGPULL_PODS[@]} -eq 0 || -z "${IMGPULL_PODS[1]:-}" ]]; then
        echo "[INFO] No image-pull-stuck pods found in ${NAMESPACE}."
    else
        for POD in "${IMGPULL_PODS[@]}"; do
            [[ -z "${POD:-}" ]] && continue
            echo "[INFO] ${POD}: $(oc get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{range .status.containerStatuses[*]}{.image}{" "}{.state.waiting.message}{"\n"}{end}' 2>/dev/null | head -2)"
        done
        echo "[HINT] Check the namespace pull secret (IBM creates it from REG_USER/REG_PASS on each 3.2 run) and, for mirrored/airgap, that 1.1 mirrored the image."
    fi

    # -----------------------------------------------------------------------
    # Phase 2: Delete all stuck pods (Pending, image-pull errors, other stuck states)
    # -----------------------------------------------------------------------
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

    echo "[INFO] ${NAMESPACE}: ${DELETED} pod(s) deleted."
    (( TOTAL_DELETED += DELETED )) || true
done

echo ""
echo "[INFO] Done. Total pods deleted: ${TOTAL_DELETED}"
