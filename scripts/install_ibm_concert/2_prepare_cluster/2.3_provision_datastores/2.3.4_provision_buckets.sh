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
# 2.3.4 S3 buckets as ObjectBucketClaims (only when S3 is provisioned)
# ------------------------------------------------------------------------------
# One claim per bucket IBM needs, all in PROJECT_CONCERT_DATASTORES so they
# outlive product uninstalls:
#   Concert:   landing zone (CONCERT_DS_S3_BUCKET_LZ), evidence locker (..._EL)
#   Workflows: CONCERT_DS_S3_BUCKET_WORKFLOWS
# Each claim gets a ConfigMap (BUCKET_HOST/PORT/NAME) and a Secret (AWS keys)
# with the same name; 2.4 turns those into IBM's secrets.
# The NooBaa class deletes the bucket when its claim is deleted.
# ==============================================================================

if ! concert_ds_server_provisioned S3; then
    concert_info "S3 is not provisioned by these scripts - skipping bucket claims."
    exit 0
fi

eval "${OC_LOGIN}"

NS="${PROJECT_CONCERT_DATASTORES}"
SC="${CONCERT_DS_S3_STORAGE_CLASS:-openshift-storage.noobaa.io}"
claims=()
if concert_ds_consumer_active CONCERT_S3; then
    claims+=("${CONCERT_DS_S3_BUCKET_LZ:-concert-lz}" "${CONCERT_DS_S3_BUCKET_EL:-concert-el}")
fi
concert_ds_consumer_active WORKFLOWS_S3 && claims+=("${CONCERT_DS_S3_BUCKET_WORKFLOWS:-concert-workflows}")

for claim in "${claims[@]}"; do
    oc apply -f - >/dev/null <<EOF
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${claim}
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  generateBucketName: ${claim}
  storageClassName: ${SC}
EOF
    _bound() { [[ "$(oc get objectbucketclaim "${claim}" -n "${NS}" -o jsonpath='{.status.phase}')" == Bound ]]; }
    concert_wait_for 600 "bucket claim ${claim}" _bound
    concert_info "Bucket ${claim}: $(oc get configmap "${claim}" -n "${NS}" -o jsonpath='{.data.BUCKET_NAME}') on $(oc get configmap "${claim}" -n "${NS}" -o jsonpath='{.data.BUCKET_HOST}'):$(oc get configmap "${claim}" -n "${NS}" -o jsonpath='{.data.BUCKET_PORT}')"
done
