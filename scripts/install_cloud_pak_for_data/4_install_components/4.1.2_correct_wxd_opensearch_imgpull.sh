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

for var in OC_LOGIN PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

# ---
# Discover all CRD kinds under the opensearch.opster.io API group

echo ""
echo "=== Discovering opensearch.opster.io API group resources ==="

OPSTER_KINDS=(${(f)"$(oc api-resources --api-group=opensearch.opster.io --no-headers -o name 2>/dev/null || true)"})

if [[ ${#OPSTER_KINDS[@]} -eq 0 || -z "${OPSTER_KINDS[1]:-}" ]]; then
    echo "[WARN] No resources found under opensearch.opster.io. Is the operator installed?"
    exit 0
fi

echo "[INFO] Found resource types: ${OPSTER_KINDS[*]}"

# ---
# For each resource kind and each target namespace, list CRs and patch icr.io → cp.icr.io

_patch_cr_images() {
    local kind="$1" ns="$2" name="$3"

    local cr_json
    cr_json=$(oc get "${kind}" "${name}" -n "${ns}" -o json 2>/dev/null || true)
    if [[ -z "${cr_json:-}" ]]; then
        echo "  [SKIP] ${kind}/${name}: could not retrieve."
        return
    fi

    # Stash existing cp.icr.io/ refs, replace bare icr.io/, restore - so cp.icr.io is never touched.
    local patched_json
    patched_json=$(echo "${cr_json}" \
        | sed 's|cp\.icr\.io/|__CP_ICR_IO__|g' \
        | sed 's|icr\.io/|cp.icr.io/|g' \
        | sed 's|__CP_ICR_IO__|cp.icr.io/|g')

    if [[ "${patched_json}" == "${cr_json}" ]]; then
        echo "  [SKIP] ${kind}/${name}: no bare icr.io refs to patch."
        return
    fi

    echo "${patched_json}" | oc apply -f - 2>/dev/null && \
        echo "  [OK] ${kind}/${name} in ${ns}: patched icr.io → cp.icr.io." || \
        echo "  [WARN] ${kind}/${name} in ${ns}: apply failed - may need manual intervention."
}

for KIND in "${OPSTER_KINDS[@]}"; do
    [[ -z "${KIND:-}" ]] && continue

    echo ""
    echo "--- Resource kind: ${KIND} ---"

    for NS in "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}"; do
        local_crs=(${(f)"$(oc get "${KIND}" -n "${NS}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)"})

        if [[ ${#local_crs[@]} -eq 0 || -z "${local_crs[1]:-}" ]]; then
            echo "  [SKIP] No ${KIND} instances found in ${NS}."
            continue
        fi

        for CR in "${local_crs[@]}"; do
            [[ -z "${CR:-}" ]] && continue
            echo "  [FOUND] ${KIND}/${CR} in ${NS}"
            _patch_cr_images "${KIND}" "${NS}" "${CR}"
        done
    done
done

echo ""
echo "=== Done. All opensearch.opster.io CRs have been checked and patched. ==="

# ---
# Patch Helm-managed ibm-wxd-opensearch-* Deployments directly.
# These are owned by the Helm release (not by any CR), so there is no higher-level resource
# to reconcile from - each container/initContainer image must be patched in-place.

_patch_helm_deployment_images() {
    local ns="$1" deploy="$2"

    local deploy_json
    deploy_json=$(oc get deployment "${deploy}" -n "${ns}" -o json 2>/dev/null || true)
    if [[ -z "${deploy_json:-}" ]]; then
        echo "  [SKIP] Deployment/${deploy}: could not retrieve."
        return
    fi

    local patched_json
    patched_json=$(echo "${deploy_json}" \
        | sed 's|cp\.icr\.io/|__CP_ICR_IO__|g' \
        | sed 's|icr\.io/|cp.icr.io/|g' \
        | sed 's|__CP_ICR_IO__|cp.icr.io/|g')

    if [[ "${patched_json}" == "${deploy_json}" ]]; then
        echo "  [SKIP] Deployment/${deploy}: no bare icr.io refs to patch."
        return
    fi

    # Extract and patch only the container/initContainer image fields via json patch
    # to avoid triggering immutable field errors from a full apply on a Deployment.
    local idx img new_img patched=0

    local container_count
    container_count=$(echo "${deploy_json}" | jq '.spec.template.spec.containers | length')
    for idx in $(seq 0 $(( container_count - 1 ))); do
        img=$(echo "${deploy_json}" | jq -r ".spec.template.spec.containers[${idx}].image")
        new_img=$(echo "${img}" \
            | sed 's|cp\.icr\.io/|__CP_ICR_IO__|g' \
            | sed 's|icr\.io/|cp.icr.io/|g' \
            | sed 's|__CP_ICR_IO__|cp.icr.io/|g')
        if [[ "${new_img}" != "${img}" ]]; then
            oc patch deployment "${deploy}" -n "${ns}" \
                --type='json' \
                -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/${idx}/image\",\"value\":\"${new_img}\"}]" \
                2>/dev/null && echo "  [OK] ${deploy} container[${idx}]: ${img} → ${new_img}" || \
                echo "  [WARN] ${deploy} container[${idx}]: patch failed."
            patched=$(( patched + 1 ))
        fi
    done

    local init_count
    init_count=$(echo "${deploy_json}" | jq '.spec.template.spec.initContainers // [] | length')
    for idx in $(seq 0 $(( init_count - 1 ))); do
        img=$(echo "${deploy_json}" | jq -r ".spec.template.spec.initContainers[${idx}].image")
        new_img=$(echo "${img}" \
            | sed 's|cp\.icr\.io/|__CP_ICR_IO__|g' \
            | sed 's|icr\.io/|cp.icr.io/|g' \
            | sed 's|__CP_ICR_IO__|cp.icr.io/|g')
        if [[ "${new_img}" != "${img}" ]]; then
            oc patch deployment "${deploy}" -n "${ns}" \
                --type='json' \
                -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/initContainers/${idx}/image\",\"value\":\"${new_img}\"}]" \
                2>/dev/null && echo "  [OK] ${deploy} initContainer[${idx}]: ${img} → ${new_img}" || \
                echo "  [WARN] ${deploy} initContainer[${idx}]: patch failed."
            patched=$(( patched + 1 ))
        fi
    done

    if [[ "${patched}" -eq 0 ]]; then
        echo "  [SKIP] Deployment/${deploy}: all images already use cp.icr.io."
    fi
}

echo ""
echo "=== Patching Helm-managed ibm-wxd-opensearch-* Deployments ==="

for NS in "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}"; do
    HELM_DEPLOYS=(${(f)"$(oc get deployment -n "${NS}" --no-headers \
        -o custom-columns=NAME:.metadata.name,MANAGED:.metadata.labels.app\\.kubernetes\\.io/managed-by 2>/dev/null \
        | awk '$2 == "Helm" && $1 ~ /^ibm-wxd-opensearch/ {print $1}' || true)"})

    if [[ ${#HELM_DEPLOYS[@]} -eq 0 || -z "${HELM_DEPLOYS[1]:-}" ]]; then
        echo "  [SKIP] No Helm-managed ibm-wxd-opensearch-* deployments found in ${NS}."
        continue
    fi

    for DEPLOY in "${HELM_DEPLOYS[@]}"; do
        [[ -z "${DEPLOY:-}" ]] && continue
        echo "  [FOUND] Deployment/${DEPLOY} in ${NS}"
        _patch_helm_deployment_images "${NS}" "${DEPLOY}"
    done
done

echo ""
echo "=== Done. All Helm-managed ibm-wxd-opensearch-* Deployments have been checked and patched. ==="
