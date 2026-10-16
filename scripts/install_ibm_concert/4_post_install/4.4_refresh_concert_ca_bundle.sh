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
# 4.4 Rebuild Concert's CA bundle from app-cfg-custom-ca-certs
# ------------------------------------------------------------------------------
# Concert's Go services trust only SSL_CERT_FILE = tls-ca-bundle.pem from the
# app-cfg-internal-tls Secret. IBM's roja-mgmt-init-tls Job builds it (OS CAs +
# every cert in the app-cfg-custom-ca-certs Secret), but only on the first
# install and on version upgrades - certificates added later are ignored.
#
# This runs IBM's own init_internal_certs.sh --skip-generate (keeps Concert's
# key/cert, rebuilds the bundle only) in a one-off Job with IBM's ServiceAccount,
# then restarts the Concert deployments that mount the bundle.
#
# 2.4 adds the OpenShift service CA (signs the in-cluster MCG S3 endpoint) to
# app-cfg-custom-ca-certs and calls this script when Concert is already installed.
# Without it, uploads to the landing-zone bucket fail with CNCRTRCOELO10013E (503)
# and discovery / ingestion jobs never run.
# ==============================================================================

concert_product_enabled concert || { concert_info "Concert is not selected - nothing to do."; exit 0; }

eval "${OC_LOGIN}"

NS="${PROJECT_CONCERT}"
oc get secret app-cfg-internal-tls -n "${NS}" >/dev/null 2>&1 \
    || { concert_info "Concert is not installed yet (no app-cfg-internal-tls) - its first install builds the bundle."; exit 0; }
IMAGE="$(oc get deploy roja-py-utils -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[[ -n "${IMAGE}" ]] || concert_die "Cannot read the roja-py-utils image in ${NS}."
UIDV="$(oc get deploy roja-py-utils -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsUser}' 2>/dev/null || true)"

JOB="concert-ca-bundle-refresh"
oc delete job "${JOB}" -n "${NS}" --ignore-not-found >/dev/null
oc apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      serviceAccountName: roja-mgmt-sa
      restartPolicy: Never
      containers:
      - name: refresh
        image: ${IMAGE}
        command: ["/app/bin/init_internal_certs.sh", "--skip-generate"]
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          ${UIDV:+runAsUser: ${UIDV}}
          capabilities: {drop: [ALL]}
        envFrom:
        - configMapRef: {name: app-cfg-cm}
        env:
        - {name: IS_k8s, value: "true"}
        - name: MY_POD_NAMESPACE
          valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
        resources:
          requests: {cpu: 50m, memory: 128Mi}
          limits: {memory: 512Mi}
        volumeMounts:
        - {name: tmp, mountPath: /tmp}
        - {name: tls, mountPath: /app/tmp/self-signed-ssl, readOnly: true}
        - {name: custom, mountPath: /mnt/infra/custom-ca-certs, readOnly: true}
      volumes:
      - {name: tmp, emptyDir: {}}
      - name: tls
        secret: {secretName: app-cfg-internal-tls}
      - name: custom
        secret: {secretName: app-cfg-custom-ca-certs, optional: true}
EOF

if ! oc wait --for=condition=complete "job/${JOB}" -n "${NS}" --timeout=300s >/dev/null 2>&1; then
    oc logs "job/${JOB}" -n "${NS}" --tail=30 >&2 || true
    concert_die "CA bundle refresh failed (job/${JOB} in ${NS})."
fi
oc logs "job/${JOB}" -n "${NS}" | grep -E "Appended|Validation failed" || true

# Restart what mounts the bundle (the services read it at start-up).
DEPLOYS=(${(f)"$(oc get deploy -n "${NS}" -o json \
    | jq -r '.items[] | select([.spec.template.spec.volumes[]? | (.secret.secretName // empty), (.projected.sources[]?.secret.name // empty)] | index("app-cfg-internal-tls")) | .metadata.name')"})
if (( ${#DEPLOYS} )); then
    oc rollout restart deploy "${DEPLOYS[@]}" -n "${NS}" >/dev/null
    for d in "${DEPLOYS[@]}"; do oc rollout status "deploy/${d}" -n "${NS}" --timeout=600s >/dev/null; done
    concert_info "Restarted ${#DEPLOYS} Concert deployments: ${DEPLOYS[*]}"
fi
concert_info "Concert CA bundle refreshed."
