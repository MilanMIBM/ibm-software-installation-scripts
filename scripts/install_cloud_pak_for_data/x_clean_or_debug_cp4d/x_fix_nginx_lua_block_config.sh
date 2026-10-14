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
# Fixes nginx/OpenResty proxies that crash-loop on an empty Lua block rendered
# by their operator, e.g. watsonx Orchestrate 8.0.2 wo-uiproxy:
#   [emerg] directive "access_by_lua_block" has no opening "{" in .../api-docker.conf:4
# Every ConfigMap in the target namespaces is scanned for `*_by_lua_block ''`
# (or "" / {}), rewritten to `*_by_lua_block { return }`, and the pods mounting
# it are restarted. Crash-looping pods with a Lua-block error the scan can't
# repair are reported.
#
# Because the operator re-renders the ConfigMap on reconcile, a watcher
# Deployment (namespace cpd-cluster-fixes) is installed that re-applies the fix
# every --interval seconds.
#
#   --preview=true          ->  only report what would be changed
#   --namespace=a,b         ->  namespaces to scan (default: PROJECT_CPD_INST_OPERANDS)
#   --install-watcher=auto  ->  install/refresh the watcher only if the issue is found (default)
#   --install-watcher=true  ->  always install/refresh the watcher
#   --install-watcher=false ->  never install the watcher
#   --interval=<sec>        ->  watcher re-scan interval (default 30)
#   --uninstall=true        ->  remove the watcher and its RBAC, then exit
PREVIEW=false
NAMESPACES="${PROJECT_CPD_INST_OPERANDS:-}"
INSTALL_WATCHER=auto
INTERVAL=30
UNINSTALL=false

for arg in "$@"; do
    case "${arg}" in
        --preview=*)          PREVIEW="${arg#--preview=}" ;;
        --namespace=*)        NAMESPACES="${arg#--namespace=}" ;;
        --install-watcher=*)  INSTALL_WATCHER="${arg#--install-watcher=}" ;;
        --interval=*)         INTERVAL="${arg#--interval=}" ;;
        --uninstall=*)        UNINSTALL="${arg#--uninstall=}" ;;
        *) echo "[ERROR] Unknown option: ${arg}" >&2; exit 1 ;;
    esac
done

FIX_NAME="nginx-lua-block-fix"
FIX_PY="${FIXES_DIR}/fix_nginx_lua_block.py"
source "${FIXES_DIR}/in_cluster_fix_helpers.zsh"

if [[ -n "${OC_LOGIN:-}" ]]; then
    eval "${OC_LOGIN}"
elif ! oc whoami &>/dev/null; then
    echo "[ERROR] Not logged in. Set OC_LOGIN in cpd_vars.sh or run oc login first." >&2
    exit 1
fi
echo "[INFO] Target cluster: $(oc whoami --show-server 2>/dev/null || echo unknown)"

if [[ "${UNINSTALL}" == "true" ]]; then
    oc -n "${CLUSTER_FIXES_NS}" delete deployment,configmap,serviceaccount -l "${CLUSTER_FIXES_LABEL}=${FIX_NAME}" --ignore-not-found
    oc delete role,rolebinding -A -l "${CLUSTER_FIXES_LABEL}=${FIX_NAME}" --ignore-not-found
    exit 0
fi

[[ -z "${NAMESPACES}" ]] && { echo "[ERROR] No namespace: set PROJECT_CPD_INST_OPERANDS or pass --namespace=" >&2; exit 1; }
ns_list=("${(@s:,:)NAMESPACES}")
py_ns_args=(); for ns in "${ns_list[@]}"; do py_ns_args+=(-n "${ns}"); done

# --- Detect and fix now
py_args=("${py_ns_args[@]}")
[[ "${PREVIEW}" == "true" ]] && py_args+=(--preview)
output=$(python3 -I "${FIX_PY}" "${py_args[@]}" 2>&1 | tee /dev/stderr) || true
issue_found=false
grep -qE '^\[(FOUND|WARN)\]' <<< "${output}" && issue_found=true

# --- Keep it fixed
if [[ "${INSTALL_WATCHER}" == "false" ]] || [[ "${INSTALL_WATCHER}" == "auto" && "${issue_found}" == "false" ]]; then
    echo "[INFO] Watcher not installed (--install-watcher=${INSTALL_WATCHER}, issue found: ${issue_found})"
    exit 0
fi
if [[ "${PREVIEW}" == "true" ]]; then
    echo "[PREVIEW] would install watcher deployment ${CLUSTER_FIXES_NS}/${FIX_NAME} for: ${NAMESPACES}"
    exit 0
fi

echo "[INFO] Installing watcher ${CLUSTER_FIXES_NS}/${FIX_NAME} (every ${INTERVAL}s) for: ${NAMESPACES}"
cluster_fix_base "${FIX_NAME}" "${FIX_PY}"
for ns in "${ns_list[@]}"; do
    cluster_fix_role "${FIX_NAME}" "${ns}" '- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "patch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "delete"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]'
done

oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${FIX_NAME}
  namespace: ${CLUSTER_FIXES_NS}
  labels: {${CLUSTER_FIXES_LABEL}: ${FIX_NAME}}
spec:
  replicas: 1
  selector:
    matchLabels: {app: ${FIX_NAME}}
  template:
    metadata:
      labels: {app: ${FIX_NAME}}
      annotations: {cluster-fixes/script-hash: "$(shasum "${FIX_PY}" | cut -c1-12)"}
    spec:
$(cluster_fix_pod_spec 6 "${FIX_NAME}" "${FIX_PY}" "${py_ns_args[@]}" --loop "${INTERVAL}")
EOF
oc -n "${CLUSTER_FIXES_NS}" rollout status "deployment/${FIX_NAME}" --timeout=180s
echo "[OK] Watcher running. Logs: oc -n ${CLUSTER_FIXES_NS} logs deploy/${FIX_NAME}"
