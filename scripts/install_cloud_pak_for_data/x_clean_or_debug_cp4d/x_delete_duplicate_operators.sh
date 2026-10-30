#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# Local oc + jq only, so OC_LOGIN (CPDM_OC_LOGIN would also log in the cpd-cli container).
eval "${OC_LOGIN}"

# Removes OLM duplicates that leave operators degraded, cluster-wide:
#   1. Extra OperatorGroups in a namespace (TooManyOperatorGroups) -> keep oldest
#   2. Extra Subscriptions for the same package in a namespace that are
#      ResolutionFailed -> keep the one with an installedCSV, else oldest
#   3. Failed/Pending CSVs of a package that already has a Succeeded CSV in the
#      same namespace and that no Subscription points at
# Usage: x_delete_duplicate_operators.sh [--dry-run]
#---
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
#---

_delete() {
    local kind="$1" ns="$2" name="$3"
    if ${DRY_RUN}; then
        echo "  [DRY-RUN] would delete ${kind}/${name} -n ${ns}"
    else
        oc delete "${kind}" "${name}" -n "${ns}" --ignore-not-found && echo "  [OK] deleted ${kind}/${name} -n ${ns}"
    fi
}

SUBS_JSON=$(oc get subscriptions.operators.coreos.com -A -o json)
OGS_JSON=$(oc get operatorgroups.operators.coreos.com -A -o json)
CSVS_JSON=$(oc get csv -A -o json)

DUP_OGS=(${(f)"$(jq -r '
    [.items[]] | group_by(.metadata.namespace)[] | select(length > 1)
    | sort_by(.metadata.creationTimestamp) | .[1:][]
    | "\(.metadata.namespace) \(.metadata.name)"' <<< "${OGS_JSON}")"})

DUP_SUBS=(${(f)"$(jq -r '
    [.items[]] | group_by(.metadata.namespace + "/" + .spec.name)[] | select(length > 1)
    | select(any(.[]; (.status.conditions // [])[]
                      | .type == "ResolutionFailed" and .status == "True"))
    | sort_by((if .status.installedCSV then 0 else 1 end), .metadata.creationTimestamp) | .[1:][]
    | "\(.metadata.namespace) \(.metadata.name)"' <<< "${SUBS_JSON}")"})

DUP_CSVS=(${(f)"$(jq -r --argjson subs "${SUBS_JSON}" '
    ([$subs.items[] | "\(.metadata.namespace)/\(.status.installedCSV // "")",
                      "\(.metadata.namespace)/\(.status.currentCSV // "")"]) as $ref
    | [.items[] | select(.metadata.labels["olm.copiedFrom"] == null)
        | .metadata.name as $n
        | . + {pkg: ([(.metadata.labels // {}) | keys[] | select(startswith("operators.coreos.com/"))
                      | sub("^operators.coreos.com/"; "") | sub("\\.[^.]+$"; "")] | first // $n)}]
    | group_by(.metadata.namespace + "/" + .pkg)[] | select(length > 1)
    | select(any(.[]; .status.phase == "Succeeded"))
    | .[] | select((.status.phase // "") | IN("Failed", "Pending", "Unknown", ""))
    | select(("\(.metadata.namespace)/\(.metadata.name)" | IN($ref[])) | not)
    | "\(.metadata.namespace) \(.metadata.name)"' <<< "${CSVS_JSON}")"})

TOTAL=0
for kind list in operatorgroup DUP_OGS subscription DUP_SUBS csv DUP_CSVS; do
    echo "=== ${kind}: ${#${(@P)list}:#} duplicate(s) ==="
    for entry in "${(@P)list}"; do
        [[ -z "${entry}" ]] && continue
        _delete "${kind}" "${entry%% *}" "${entry#* }"
        (( TOTAL++ )) || true
    done
done

echo ""
echo "[INFO] Done. ${TOTAL} duplicate(s) $(${DRY_RUN} && echo found || echo removed)."
