#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

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
# 2.0.1 Worker capacity for the profile (OPT-IN changes)
# ------------------------------------------------------------------------------
# Compares schedulable workers against CONCERT_MIN_WORKERS x
# CONCERT_MIN_WORKER_CPU / CONCERT_MIN_WORKER_MEM_GI (profile values, from IBM's
# hardware table). On a shortfall it proposes scaling a worker MachineSet
# whose instance size meets the minimum. Nodes cost money, so it only changes
# the cluster when CONCERT_AUTOSCALE_APPLY=true. CONCERT_AUTOSCALE_MACHINESET
# picks the MachineSet explicitly. Clusters without the Machine API (UPI, ROKS)
# get guidance only.
# ==============================================================================

eval "${OC_LOGIN}"

MIN_CPU="${CONCERT_MIN_WORKER_CPU:-16}"
MIN_MEM="${CONCERT_MIN_WORKER_MEM_GI:-32}"
NEED="${CONCERT_MIN_WORKERS:-3}"

read -r QUAL TOTAL <<<"$(concert_worker_capacity "${MIN_CPU}" "${MIN_MEM}")"
SHORT=$(( NEED - QUAL ))
if (( SHORT <= 0 )); then
    concert_info "${QUAL}/${TOTAL} workers meet ${MIN_CPU} vCPU / ${MIN_MEM} Gi - the ${CONCERT_PROFILE} profile needs ${NEED}. Nothing to do."
    exit 0
fi
concert_warn "${QUAL}/${TOTAL} workers meet ${MIN_CPU} vCPU / ${MIN_MEM} Gi; the ${CONCERT_PROFILE} profile needs ${NEED} (short by ${SHORT})."

if ! oc get machinesets -n openshift-machine-api >/dev/null 2>&1; then
    concert_warn "No Machine API on this cluster (UPI / ROKS): add ${SHORT} worker(s) of >= ${MIN_CPU} vCPU / ${MIN_MEM} Gi with your platform's tooling."
    exit 0
fi

# name replicas vCPU memoryGi for worker MachineSets with size annotations
CANDIDATES="$(oc get machinesets -n openshift-machine-api -o json | python3 -c '
import json, sys
for ms in json.load(sys.stdin)["items"]:
    labels = ms["spec"]["template"]["metadata"].get("labels", {})
    if labels.get("machine.openshift.io/cluster-api-machine-role") != "worker":
        continue
    ann = ms["metadata"].get("annotations", {})
    cpu = ann.get("machine.openshift.io/vCPU", "")
    mem = ann.get("machine.openshift.io/memoryMb", "")
    gi = str(int(int(mem) / 1024)) if mem.isdigit() else "?"
    print(ms["metadata"]["name"], ms["spec"].get("replicas", 0), cpu or "?", gi)
')"

[[ -n "${CANDIDATES}" ]] || { concert_warn "No worker MachineSets found."; exit 0; }
print -r -- "Worker MachineSets (name replicas vCPU memoryGi):"
print -r -- "${CANDIDATES}" | sed 's/^/    /'

MS="${CONCERT_AUTOSCALE_MACHINESET:-}"
if [[ -z "${MS}" ]]; then
    MS="$(print -r -- "${CANDIDATES}" | awk -v c="${MIN_CPU}" -v m="${MIN_MEM}" '$3 != "?" && $4 != "?" && $3 >= c && $4 >= m {print $1; exit}')"
fi
if [[ -z "${MS}" ]]; then
    concert_warn "No worker MachineSet with an instance size >= ${MIN_CPU} vCPU / ${MIN_MEM} Gi. Create one (copy a MachineSet with a larger instance type) and set CONCERT_AUTOSCALE_MACHINESET."
    exit 0
fi

CURRENT="$(oc get machineset "${MS}" -n openshift-machine-api -o jsonpath='{.spec.replicas}')"
TARGET=$(( CURRENT + SHORT ))
if ! concert_is_true "${CONCERT_AUTOSCALE_APPLY:-false}"; then
    concert_info "Proposed (set CONCERT_AUTOSCALE_APPLY=true to apply):"
    print -r -- "    oc scale machineset ${MS} -n openshift-machine-api --replicas=${TARGET}"
    exit 0
fi

concert_info "Scaling MachineSet ${MS}: ${CURRENT} -> ${TARGET}"
oc scale machineset "${MS}" -n openshift-machine-api --replicas="${TARGET}"
_enough() {
    local q t
    read -r q t <<<"$(concert_worker_capacity "${MIN_CPU}" "${MIN_MEM}")"
    (( q >= NEED ))
}
concert_wait_for 2400 "${NEED} qualifying worker nodes" _enough
concert_info "Capacity reached."
