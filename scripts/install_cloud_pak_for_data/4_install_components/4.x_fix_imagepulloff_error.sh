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

# ---

for var in OC_LOGIN PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS IMAGE_PULL_SECRET; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

_link_pull_secrets() {
    local NS="$1"

    echo ""
    echo "=== Linking ${IMAGE_PULL_SECRET} to all service accounts in ${NS} ==="

    local SA_NAMES
    SA_NAMES=(${(f)"$(oc get sa -n "${NS}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)"})

    for SA_NAME in "${SA_NAMES[@]}"; do
        local ALREADY_LINKED
        ALREADY_LINKED=$(oc get sa "${SA_NAME}" -n "${NS}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || true)
        if [[ "${ALREADY_LINKED}" == *"${IMAGE_PULL_SECRET}"* ]]; then
            echo "[SKIP] ${SA_NAME} already has ${IMAGE_PULL_SECRET} linked."
        else
            oc secrets link "${SA_NAME}" ${IMAGE_PULL_SECRET} --for=pull -n "${NS}"
            echo "[OK] Linked ${IMAGE_PULL_SECRET} to SA: ${SA_NAME}"
        fi
    done
}

_restart_stuck_pods() {
    local NS="$1"

    local STUCK_PODS
    STUCK_PODS=(${(f)"$(oc get pods -n "${NS}" --no-headers 2>/dev/null | grep -E 'ImagePullBackOff|ErrImagePull' | awk '{print $1}' || true)"})

    if [[ ${#STUCK_PODS[@]} -gt 0 && -n "${STUCK_PODS[1]:-}" ]]; then
        echo "[INFO] Restarting ${#STUCK_PODS[@]} stuck pod(s) in ${NS}..."
        for POD in "${STUCK_PODS[@]}"; do
            oc delete pod "${POD}" -n "${NS}" --grace-period=0 2>/dev/null || true
            echo "[OK] Deleted stuck pod: ${POD}"
        done
    else
        echo "[INFO] No stuck pods found in ${NS}."
    fi
}

# _link_pull_secrets "${PROJECT_CPD_INST_OPERATORS}"
_link_pull_secrets "${PROJECT_CPD_INST_OPERANDS}"

# ---
# Fix image pull prefix for ibm-wxd-opensearch deployments: icr.io/ → cp.icr.io/

_detect_failing_registry() {
    local ns="$1"
    # Look at ImagePullBackOff/ErrImagePull pods and extract which registry prefix is failing
    local pod_events
    pod_events=$(oc get events -n "${ns}" --field-selector reason=Failed 2>/dev/null | grep -iE 'ImagePullBackOff|ErrImagePull|Failed to pull image' || true)

    local failing_icr=0 failing_cp_icr=0
    if echo "${pod_events}" | grep -qE '"icr\.io/' && ! echo "${pod_events}" | grep -qE '"cp\.icr\.io/'; then
        failing_icr=1
    fi
    if echo "${pod_events}" | grep -qE '"cp\.icr\.io/'; then
        failing_cp_icr=1
    fi

    if [[ "${failing_icr}" -eq 1 ]]; then
        echo "icr.io"
    elif [[ "${failing_cp_icr}" -eq 1 ]]; then
        echo "cp.icr.io"
    else
        echo ""
    fi
}

_swap_registry_prefix() {
    local img="$1" failing_registry="$2"
    if [[ "${failing_registry}" == "icr.io" && "${img}" == icr.io/* && "${img}" != cp.icr.io/* ]]; then
        echo "cp.${img}"
    elif [[ "${failing_registry}" == "cp.icr.io" && "${img}" == cp.icr.io/* ]]; then
        # strip the leading "cp." to go back to icr.io
        echo "${img#cp.}"
    else
        echo ""
    fi
}

_patch_deployment_images() {
    local ns="$1" deploy="$2"

    local failing_registry
    failing_registry=$(_detect_failing_registry "${ns}")

    # Fall back to icr.io→cp.icr.io if events give no clear signal
    if [[ -z "${failing_registry:-}" ]]; then
        local first_img
        first_img=$(oc get deployment "${deploy}" -n "${ns}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
        if [[ "${first_img}" == icr.io/* && "${first_img}" != cp.icr.io/* ]]; then
            failing_registry="icr.io"
        elif [[ "${first_img}" == cp.icr.io/* ]]; then
            failing_registry="cp.icr.io"
        fi
    fi

    if [[ -z "${failing_registry:-}" ]]; then
        echo "[SKIP] ${deploy}: cannot determine failing registry, skipping."
        return
    fi

    echo "[INFO] ${deploy}: detected failing registry → ${failing_registry}"

    local container_count patched=0 idx img new_img
    container_count=$(oc get deployment "${deploy}" -n "${ns}" -o jsonpath='{.spec.template.spec.containers}' | jq '. | length')
    for idx in $(seq 0 $(( container_count - 1 ))); do
        img=$(oc get deployment "${deploy}" -n "${ns}" -o jsonpath="{.spec.template.spec.containers[${idx}].image}")
        new_img=$(_swap_registry_prefix "${img}" "${failing_registry}")
        if [[ -n "${new_img:-}" ]]; then
            oc patch deployment "${deploy}" -n "${ns}" \
                --type='json' \
                -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/${idx}/image\",\"value\":\"${new_img}\"}]"
            echo "[OK] ${deploy} container[${idx}]: ${img} → ${new_img}"
            patched=$(( patched + 1 ))
        fi
    done
    local init_count
    init_count=$(oc get deployment "${deploy}" -n "${ns}" -o jsonpath='{.spec.template.spec.initContainers}' 2>/dev/null | jq '. | length' 2>/dev/null || echo 0)
    for idx in $(seq 0 $(( init_count - 1 ))); do
        img=$(oc get deployment "${deploy}" -n "${ns}" -o jsonpath="{.spec.template.spec.initContainers[${idx}].image}" 2>/dev/null || true)
        new_img=$(_swap_registry_prefix "${img}" "${failing_registry}")
        if [[ -n "${new_img:-}" ]]; then
            oc patch deployment "${deploy}" -n "${ns}" \
                --type='json' \
                -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/initContainers/${idx}/image\",\"value\":\"${new_img}\"}]"
            echo "[OK] ${deploy} initContainer[${idx}]: ${img} → ${new_img}"
            patched=$(( patched + 1 ))
        fi
    done
    if [[ "${patched}" -eq 0 ]]; then
        echo "[SKIP] ${deploy}: no icr.io images needing prefix fix."
        return
    fi
    # Verify the patch actually stuck (operator may revert immediately)
    sleep 3
    local verify_img
    verify_img=$(oc get deployment "${deploy}" -n "${ns}" -o jsonpath='{.spec.template.spec.containers[0].image}')
    local reverted=0
    if [[ "${failing_registry}" == "icr.io" && "${verify_img}" == icr.io/* && "${verify_img}" != cp.icr.io/* ]]; then
        reverted=1
    elif [[ "${failing_registry}" == "cp.icr.io" && "${verify_img}" == cp.icr.io/* ]]; then
        reverted=1
    fi
    if [[ "${reverted}" -eq 1 ]]; then
        echo "[WARN] ${deploy}: operator reverted the image patch - Deployment is operator-managed."
        echo "[INFO] ${deploy}: patching operator CSV image references instead..."
        local csv
        # Find the CSV that owns this deployment via its app.kubernetes.io/managed-by or olm.owner label
        csv=$(oc get deployment "${deploy}" -n "${ns}" \
            -o jsonpath='{.metadata.labels.olm\.owner}' 2>/dev/null || true)
        if [[ -z "${csv:-}" ]]; then
            csv=$(oc get deployment "${deploy}" -n "${ns}" \
                -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
        fi
        # Fall back: find any CSV whose name appears in the deployment name
        if [[ -z "${csv:-}" ]]; then
            local deploy_prefix
            deploy_prefix=$(echo "${deploy}" | sed 's/-[a-z0-9]*$//')
            csv=$(oc get csv -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
                | grep -i "${deploy_prefix}" | head -n1 || true)
        fi
        if [[ -n "${csv:-}" ]]; then
            echo "[INFO] Found CSV: ${csv} - patching relatedImages and deployments spec..."
            local csv_json patched_json
            csv_json=$(oc get csv "${csv}" -n "${ns}" -o json)
            if [[ "${failing_registry}" == "icr.io" ]]; then
                patched_json=$(echo "${csv_json}" | sed 's|"icr\.io/|"cp.icr.io/|g')
            else
                # cp.icr.io → icr.io: remove the "cp." prefix
                patched_json=$(echo "${csv_json}" | sed 's|"cp\.icr\.io/|"icr.io/|g')
            fi
            echo "${patched_json}" | oc apply -f - 2>/dev/null || \
                echo "[WARN] Could not patch CSV ${csv} - may need manual intervention."
            echo "[OK] Patched CSV ${csv}."
        else
            echo "[WARN] No owning CSV found for ${deploy} in ${ns}. Cannot patch operator source."
        fi
    else
        echo "[OK] ${deploy}: patch verified (image: ${verify_img})."
    fi
}

echo ""
echo "=== Patching image pull prefix (icr.io ↔ cp.icr.io) on all failing deployments ==="

_get_failing_deploy_names() {
    local ns="$1"
    # Find deployments that own pods currently in ErrImagePull/ImagePullBackOff
    oc get pods -n "${ns}" --no-headers 2>/dev/null \
        | grep -E 'ImagePullBackOff|ErrImagePull' \
        | awk '{print $1}' \
        | xargs -I{} oc get pod {} -n "${ns}" \
            -o jsonpath='{.metadata.ownerReferences[?(@.kind=="ReplicaSet")].name}{"\n"}' 2>/dev/null \
        | xargs -I{} oc get rs {} -n "${ns}" \
            -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}{"\n"}' 2>/dev/null \
        | sort -u \
        || true
}

for NS in "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}"; do
    FAILING_DEPLOYS=(${(f)"$(_get_failing_deploy_names "${NS}")"})
    for DEPLOY in "${FAILING_DEPLOYS[@]}"; do
        [[ -z "${DEPLOY:-}" ]] && continue
        _patch_deployment_images "${NS}" "${DEPLOY}"
    done
done

# ---
# Delete stale ReplicaSets whose images still reference the failing registry prefix

echo ""
echo "=== Removing stale ReplicaSets with broken image registry prefix ==="

for NS in "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}"; do
    local ns_failing_registry
    ns_failing_registry=$(_detect_failing_registry "${NS}")
    [[ -z "${ns_failing_registry:-}" ]] && continue
    ALL_RS=(${(f)"$(oc get rs -n "${NS}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)"})
    for RS in "${ALL_RS[@]}"; do
        [[ -z "${RS:-}" ]] && continue
        local_images=$(oc get rs "${RS}" -n "${NS}" \
            -o jsonpath='{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}' 2>/dev/null || true)
        [[ -z "${local_images:-}" ]] && continue
        local stale=0
        if [[ "${ns_failing_registry}" == "icr.io" ]] && echo "${local_images}" | grep -qE '^icr\.io/' && ! echo "${local_images}" | grep -qE '^cp\.icr\.io/'; then
            stale=1
        elif [[ "${ns_failing_registry}" == "cp.icr.io" ]] && echo "${local_images}" | grep -qE '^cp\.icr\.io/'; then
            stale=1
        fi
        if [[ "${stale}" -eq 1 ]]; then
            oc delete rs "${RS}" -n "${NS}" --grace-period=0 2>/dev/null || true
            echo "[OK] Deleted stale RS: ${RS}"
        fi
    done
done

# ---
# Patch opensearch-release-config ConfigMap: icr.io/ → cp.icr.io/ in image URLs

echo ""
echo "=== Patching opensearch-release-config ConfigMap image URLs (icr.io → cp.icr.io) ==="

_patch_opensearch_release_config() {
    local ns="$1"
    local cm="opensearch-release-config"

    if ! oc get configmap "${cm}" -n "${ns}" &>/dev/null; then
        echo "[SKIP] ConfigMap ${cm} not found in ${ns}."
        return
    fi

    local current_data
    current_data=$(oc get configmap "${cm}" -n "${ns}" -o jsonpath='{.data.opensearch_config\.json}' 2>/dev/null || true)

    if [[ -z "${current_data:-}" ]]; then
        echo "[SKIP] ${cm}: opensearch_config.json key is empty or missing."
        return
    fi

    if ! echo "${current_data}" | grep -qE '"icr\.io/'; then
        echo "[SKIP] ${cm}: no unpatched icr.io image URLs found."
        return
    fi

    local patched_data
    patched_data=$(echo "${current_data}" | sed 's|"icr\.io/|"cp.icr.io/|g')

    local escaped_data
    escaped_data=$(echo "${patched_data}" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')

    oc patch configmap "${cm}" -n "${ns}" \
        --type='merge' \
        -p="{\"data\":{\"opensearch_config.json\":${escaped_data}}}" 2>/dev/null && \
        echo "[OK] Patched ${cm} in ${ns}: replaced icr.io → cp.icr.io in image URLs." || \
        echo "[WARN] Failed to patch ${cm} in ${ns}."
}

_patch_opensearch_release_config "${PROJECT_CPD_INST_OPERANDS}"

# ---
# Restart pods that are still stuck after patching

echo ""
echo "=== Restarting remaining stuck pods ==="

# _restart_stuck_pods "${PROJECT_CPD_INST_OPERATORS}"
_restart_stuck_pods "${PROJECT_CPD_INST_OPERANDS}"
