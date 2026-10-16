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
# Copy IBM's installer logs (and previews / mustgathers) off the runner volume
# ------------------------------------------------------------------------------
# Cluster runner: starts a short-lived pod on the work PVC and `oc rsync`s
#   /work/<version>/ibm-concert/{logs,mustgather-output-*}  (+ /work/preview with --preview)
# to concert_workspace/logs/cluster-<timestamp>/. Container/native runners
# already write into concert_workspace (container-work/, native-work/).
#   ./x_fetch_installer_logs.sh [--preview]
# ==============================================================================

PREVIEW=false
[[ "${1:-}" == --preview ]] && PREVIEW=true

case "${CONCERT_RUNNER:-cluster}" in
    container) concert_info "Logs are in ${CONCERT_WORKSPACE}/container-work/${CONCERT_VERSION}/ibm-concert/logs"; exit 0 ;;
    native)    concert_info "Logs are in ${CONCERT_WORKSPACE}/native-work/${CONCERT_VERSION}/ibm-concert/logs"; exit 0 ;;
esac

eval "${OC_LOGIN}"
NS="${PROJECT_CONCERT_INSTALLER}"
POD=concert-installer-logs
DEST="${CONCERT_WORKSPACE}/logs/cluster-$(date +%Y%m%d-%H%M%S)"

running="$(oc get pods -n "${NS}" -l app.kubernetes.io/name=concert-installer-runner --field-selector=status.phase=Running -o name 2>/dev/null || true)"
[[ -z "${running}" ]] || concert_die "A runner Job is still running (${running}) - the RWO volume is in use; wait for it or read its live log with oc logs."

oc delete pod "${POD}" -n "${NS}" --ignore-not-found --wait=true >/dev/null
oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  serviceAccountName: ${CONCERT_RUNNER_SA}
  restartPolicy: Never
  containers:
  - name: logs
    image: $(concert_runner_image)
    command: ["/bin/sleep", "900"]
    volumeMounts:
    - name: work
      mountPath: /work
  volumes:
  - name: work
    persistentVolumeClaim:
      claimName: ${CONCERT_RUNNER_PVC}
EOF
trap 'oc delete pod "${POD}" -n "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
oc wait --for=condition=Ready "pod/${POD}" -n "${NS}" --timeout=300s >/dev/null

mkdir -p "${DEST}"
BASE="/work/${CONCERT_VERSION}/ibm-concert"
oc rsync -n "${NS}" "${POD}:${BASE}/logs" "${DEST}/" >/dev/null 2>&1 || concert_warn "No IBM logs yet in ${BASE}/logs."
for d in $(oc exec -n "${NS}" "${POD}" -- sh -c "ls -d ${BASE}/mustgather-output-* 2>/dev/null" || true); do
    oc rsync -n "${NS}" "${POD}:${d}" "${DEST}/" >/dev/null 2>&1 || true
done
${PREVIEW} && { oc rsync -n "${NS}" "${POD}:/work/preview" "${DEST}/" >/dev/null 2>&1 || concert_warn "No previews on the volume."; }

concert_info "Copied to ${DEST}:"
find "${DEST}" -maxdepth 2 | sed "s|${DEST}/||" | sort | head -40 | sed 's/^/    /' || true
