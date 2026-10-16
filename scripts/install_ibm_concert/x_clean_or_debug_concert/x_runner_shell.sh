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
# Interactive shell in the runner (debugging IBM's scripts)
# ------------------------------------------------------------------------------
# Cluster runner: a pod with the runner image, the work PVC and the
# concert-installer ServiceAccount (cluster-admin bound while the shell is
# open, removed on exit unless CONCERT_RUNNER_KEEP_ADMIN=true). The shell
# starts in /work; IBM's installer is in /work/<version>/ibm-concert.
# Container runner: podman run -it with the workspace and your kubeconfig.
# ==============================================================================

eval "${OC_LOGIN}"

if [[ "${CONCERT_RUNNER:-cluster}" == container ]]; then
    STAGE="$(concert_private_tmpdir)"
    trap 'rm -rf "${STAGE}"' EXIT
    (umask 077; oc config view --raw --minify --flatten > "${STAGE}/kubeconfig")
    mkdir -p "${CONCERT_WORKSPACE}/container-work"
    exec podman run --rm -it --platform linux/amd64 --user 0:0 \
        -v "${CONCERT_WORKSPACE}/container-work:/work" -v "${STAGE}/kubeconfig:/kube/config:ro" \
        -e KUBECONFIG=/kube/config -e CONCERT_VERSION --entrypoint /bin/bash "$(concert_runner_image)"
fi
[[ "${CONCERT_RUNNER:-cluster}" == cluster ]] || concert_die "Native runner: just open a shell on the bastion."

NS="${PROJECT_CONCERT_INSTALLER}"
POD=concert-installer-shell
concert_runner_grant_admin
# Delete synchronously first: revoke keeps the binding while any runner pod
# (including this one) is still Running.
trap 'oc delete pod "${POD}" -n "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1; concert_runner_revoke_admin' EXIT
oc delete pod "${POD}" -n "${NS}" --ignore-not-found --wait=true >/dev/null
oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: concert-installer-runner
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  serviceAccountName: ${CONCERT_RUNNER_SA}
  restartPolicy: Never
  containers:
  - name: shell
    image: $(concert_runner_image)
    command: ["/bin/sleep", "14400"]
    env:
    - {name: CONCERT_VERSION, value: "${CONCERT_VERSION}"}
    volumeMounts:
    - name: work
      mountPath: /work
  volumes:
  - name: work
    persistentVolumeClaim:
      claimName: ${CONCERT_RUNNER_PVC}
EOF
oc wait --for=condition=Ready "pod/${POD}" -n "${NS}" --timeout=300s >/dev/null
concert_info "Shell in ${NS}/${POD} (cluster-admin while open). Installer: /work/${CONCERT_VERSION}/ibm-concert"
oc rsh -n "${NS}" "${POD}" /bin/bash || true
