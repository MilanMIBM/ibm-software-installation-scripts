#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIXES_DIR="${SCRIPT_DIR}/cluster_fixes"  # env_bootstrap.sh reassigns SCRIPT_DIR
# Load only the CP4D config (cpd_vars.sh) so another configs/*/ file can't
# redirect OC_LOGIN to a different cluster. Override with ENV_TARGET=<name|path>.
: "${ENV_TARGET:=cpd}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# --- Options
# Fixes operator-embedded etcds that run out of space because nothing ever
# defragments them, e.g. the Milvus etcd behind watsonx Orchestrate / watsonx.data:
#   ibm-lh-lakehouse-wo-milvus-standalone  ->  panic: etcdserver: mvcc: database space exceeded
# Every running pod whose image looks like etcd is checked with etcdctl. Members
# with a NOSPACE alarm, a DB near quota, or lots of reclaimable space are
# snapshotted, compacted, defragmented and (if live data allows) disarmed; pods
# that crashed on "database space exceeded" are restarted.
#
# A CronJob (namespace cpd-cluster-fixes) is installed to repeat the check on a
# schedule. It may only exec into the etcd pods discovered at install time;
# re-run this script if those pods are renamed (e.g. after an upgrade).
#
#   --preview=true          ->  only report what would be changed
#   --namespace=a,b         ->  namespaces to scan (default: PROJECT_CPD_INST_OPERANDS)
#   --snapshot=false        ->  skip the pre-fix etcd snapshot (default: take one, on the etcd PVC)
#   --install-cronjob=auto  ->  install/refresh the CronJob only if the issue is found (default)
#   --install-cronjob=true  ->  always install/refresh the CronJob
#   --install-cronjob=false ->  never install the CronJob
#   --schedule="<cron>"     ->  CronJob schedule (default: every 6 hours)
#   --uninstall=true        ->  remove the CronJob and its RBAC, then exit
PREVIEW=false
NAMESPACES="${PROJECT_CPD_INST_OPERANDS:-}"
SNAPSHOT=true
INSTALL_CRONJOB=auto
SCHEDULE="0 */6 * * *"
UNINSTALL=false

for arg in "$@"; do
    case "${arg}" in
        --preview=*)          PREVIEW="${arg#--preview=}" ;;
        --namespace=*)        NAMESPACES="${arg#--namespace=}" ;;
        --snapshot=*)         SNAPSHOT="${arg#--snapshot=}" ;;
        --install-cronjob=*)  INSTALL_CRONJOB="${arg#--install-cronjob=}" ;;
        --schedule=*)         SCHEDULE="${arg#--schedule=}" ;;
        --uninstall=*)        UNINSTALL="${arg#--uninstall=}" ;;
        *) echo "[ERROR] Unknown option: ${arg}" >&2; exit 1 ;;
    esac
done

FIX_NAME="etcd-space-fix"
FIX_PY="${FIXES_DIR}/fix_etcd_space.py"
source "${FIXES_DIR}/in_cluster_fix_helpers.zsh"

if [[ -n "${OC_LOGIN:-}" ]]; then
    eval "${OC_LOGIN}"
elif ! oc whoami &>/dev/null; then
    echo "[ERROR] Not logged in. Set OC_LOGIN in cpd_vars.sh or run oc login first." >&2
    exit 1
fi
echo "[INFO] Target cluster: $(oc whoami --show-server 2>/dev/null || echo unknown)"

if [[ "${UNINSTALL}" == "true" ]]; then
    oc -n "${CLUSTER_FIXES_NS}" delete cronjob,configmap,serviceaccount -l "${CLUSTER_FIXES_LABEL}=${FIX_NAME}" --ignore-not-found
    oc delete role,rolebinding -A -l "${CLUSTER_FIXES_LABEL}=${FIX_NAME}" --ignore-not-found
    exit 0
fi

[[ -z "${NAMESPACES}" ]] && { echo "[ERROR] No namespace: set PROJECT_CPD_INST_OPERANDS or pass --namespace=" >&2; exit 1; }
ns_list=("${(@s:,:)NAMESPACES}")
py_ns_args=(); for ns in "${ns_list[@]}"; do py_ns_args+=(-n "${ns}"); done

# --- Detect and fix now
py_args=("${py_ns_args[@]}")
[[ "${PREVIEW}" == "true" ]] && py_args+=(--preview)
[[ "${SNAPSHOT}" == "false" ]] && py_args+=(--no-snapshot)
fix_rc=0
output=$(python3 -I "${FIX_PY}" "${py_args[@]}" 2>&1 | tee /dev/stderr) || fix_rc=$?
issue_found=false
grep -qE '^\[(FOUND|ERROR)\]' <<< "${output}" && issue_found=true

# --- Keep it fixed
if [[ "${INSTALL_CRONJOB}" == "false" ]] || [[ "${INSTALL_CRONJOB}" == "auto" && "${issue_found}" == "false" ]]; then
    echo "[INFO] CronJob not installed (--install-cronjob=${INSTALL_CRONJOB}, issue found: ${issue_found})"
    exit ${fix_rc}
fi

members=$(python3 -I "${FIX_PY}" "${py_ns_args[@]}" --list-members)
if [[ -z "${members}" ]]; then
    echo "[WARN] No etcd pods found in ${NAMESPACES}; CronJob not installed"
    exit ${fix_rc}
fi
if [[ "${PREVIEW}" == "true" ]]; then
    echo "[PREVIEW] would install CronJob ${CLUSTER_FIXES_NS}/${FIX_NAME} (${SCHEDULE}) with exec access to:"
    echo "${members}" | sed 's/^/            /'
    exit ${fix_rc}
fi

echo "[INFO] Installing CronJob ${CLUSTER_FIXES_NS}/${FIX_NAME} (${SCHEDULE}) for: ${NAMESPACES}"
cluster_fix_base "${FIX_NAME}" "${FIX_PY}"
for ns in "${ns_list[@]}"; do
    pods=$(awk -v ns="${ns}" '$1 == ns { printf "%s\"%s\"", (n++ ? ", " : ""), $2 }' <<< "${members}")
    [[ -z "${pods}" ]] && continue
    cluster_fix_role "${FIX_NAME}" "${ns}" "- apiGroups: [\"\"]
  resources: [\"pods\"]
  verbs: [\"get\", \"list\", \"delete\"]
- apiGroups: [\"\"]
  resources: [\"pods/log\"]
  verbs: [\"get\"]
- apiGroups: [\"\"]
  resources: [\"pods/exec\"]
  resourceNames: [${pods}]
  verbs: [\"create\", \"get\"]"
done

# Scheduled runs skip the snapshot so they don't fill the etcd PVC.
CLUSTER_FIX_RESTART_POLICY=Never
oc apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${FIX_NAME}
  namespace: ${CLUSTER_FIXES_NS}
  labels: {${CLUSTER_FIXES_LABEL}: ${FIX_NAME}}
spec:
  schedule: "${SCHEDULE}"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 1800
      template:
        spec:
$(cluster_fix_pod_spec 10 "${FIX_NAME}" "${FIX_PY}" "${py_ns_args[@]}" --no-snapshot)
EOF
echo "[OK] CronJob installed. Run now: oc -n ${CLUSTER_FIXES_NS} create job --from=cronjob/${FIX_NAME} ${FIX_NAME}-manual"
exit ${fix_rc}
