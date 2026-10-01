#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

eval "${OC_LOGIN}"

#---
DRY_RUN=false   # Set to false to actually clear finalizers
NAMESPACE="${PROJECT_CPD_INST_OPERANDS}"
#---

echo "[INFO] Scanning namespace '${NAMESPACE}' for resources stuck in Terminating with finalizers (DRY_RUN=${DRY_RUN})"
echo ""

FOUND=0

for resource in $(oc api-resources --verbs=list --namespaced -o name 2>/dev/null); do
    results=$(oc get "$resource" -n "$NAMESPACE" --ignore-not-found -o json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', [])
for item in items:
    name = item['metadata']['name']
    finalizers = item['metadata'].get('finalizers', [])
    deletion = item['metadata'].get('deletionTimestamp')
    if deletion and finalizers:
        print(f'$resource/{name}|{deletion}|{finalizers}')
" 2>/dev/null || true)

    if [[ -n "$results" ]]; then
        while IFS='|' read -r ref deletion finalizers; do
            resource_type=$(echo "$ref" | cut -d/ -f1)
            name=$(echo "$ref" | cut -d/ -f2)
            echo "[STUCK] ${ref}"
            echo "        deletionTimestamp : ${deletion}"
            echo "        finalizers        : ${finalizers}"
            FOUND=$((FOUND + 1))

            if [[ "${DRY_RUN}" == "false" ]]; then
                echo "        --> Clearing finalizers..."
                oc patch "$resource_type" "$name" -n "$NAMESPACE" \
                    --type=merge \
                    -p '{"metadata":{"finalizers":[]}}' \
                    && echo "        --> Done." \
                    || echo "        --> Failed (may need --subresource or different patch strategy)"
            fi
        done <<< "$results"
        echo ""
    fi
done

echo "[INFO] Operation completed."

if [[ $FOUND -eq 0 ]]; then
    echo "[INFO] No stuck finalizers found in namespace '${NAMESPACE}'."
else
    echo "[INFO] Found ${FOUND} stuck resource(s) in namespace '${NAMESPACE}'."
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[INFO] DRY_RUN=true - set DRY_RUN=false at the top of the script to clear them."
    fi
fi
