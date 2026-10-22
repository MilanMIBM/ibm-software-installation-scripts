#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
mc_require_config

# ==============================================================================
# 2.1 helm upgrade --install Mission Control
# ------------------------------------------------------------------------------
#   1. 2.0 renders the values files (DataStax OpenShift base + overrides)
#   2. control plane: the Loki/Mimir object storage credentials secret
#      (MinIO root user, or the S3 keys) as AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY
#   3. helm upgrade --install oci://icr.io/mission-control-helm/mission-control
#
# Install and upgrade are the same command: re-run after changing the config
# or MC_VERSION. Extra arguments go to helm, e.g.
#   2.1_install_mission_control.sh --dry-run=server
# A data plane must use the same MC_RELEASE_NAME as its control plane.
# ==============================================================================

# MC_CHART: the private registry mirroring track points it at the chart's copy in
# the registry (registry_overrides.sh; 3.5 also logs helm in there).
CHART="${MC_CHART:-oci://icr.io/mission-control-helm/mission-control}"

"${SCRIPT_DIR}/2.0_render_values.sh"

eval "${OC_LOGIN}"
mc_ensure_helm
oc get namespace "${MC_NAMESPACE}" >/dev/null 2>&1 \
    || mc_die "Namespace ${MC_NAMESPACE} does not exist - run 1.2_create_namespace_and_pull_secret.sh first."
oc get secret "${MC_PULL_SECRET_NAME}" -n "${MC_NAMESPACE}" >/dev/null 2>&1 \
    || mc_die "Pull secret ${MC_NAMESPACE}/${MC_PULL_SECRET_NAME} missing - run 1.2_create_namespace_and_pull_secret.sh first."

# --- Object storage credentials (control plane) --------------------------------
DRY_RUN=false
for _a in "$@"; do [[ "${_a}" == --dry-run* ]] && DRY_RUN=true; done
if [[ "${MC_PLANE}" == control ]] && ${DRY_RUN}; then
    mc_info "helm --dry-run: object storage secret not written."
elif [[ "${MC_PLANE}" == control ]]; then
    _work="$(mktemp -d)"
    chmod 700 "${_work}"
    trap 'rm -rf "${_work}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
    if [[ "${MC_OBSERVABILITY_STORE:-minio}" == minio ]]; then
        print -rn -- "${MC_MINIO_ROOT_USER}" > "${_work}/AWS_ACCESS_KEY_ID"
        print -rn -- "${MC_MINIO_ROOT_PASSWORD}" > "${_work}/AWS_SECRET_ACCESS_KEY"
    else
        print -rn -- "${MC_S3_ACCESS_KEY_ID}" > "${_work}/AWS_ACCESS_KEY_ID"
        print -rn -- "${MC_S3_SECRET_ACCESS_KEY}" > "${_work}/AWS_SECRET_ACCESS_KEY"
    fi
    S3_SECRET="${MC_S3_SECRET_NAME:-${MC_RELEASE_NAME}-observability-s3}"
    oc create secret generic "${S3_SECRET}" -n "${MC_NAMESPACE}" \
        --from-file=AWS_ACCESS_KEY_ID="${_work}/AWS_ACCESS_KEY_ID" \
        --from-file=AWS_SECRET_ACCESS_KEY="${_work}/AWS_SECRET_ACCESS_KEY" \
        --dry-run=client -o yaml | oc apply -f - >/dev/null
    mc_info "Object storage secret ${MC_NAMESPACE}/${S3_SECRET} applied (${MC_OBSERVABILITY_STORE:-minio})."
fi

# --- Helm ------------------------------------------------------------------------
VALUES_ARGS=()
while IFS= read -r _f; do
    [[ -n "${_f}" ]] && VALUES_ARGS+=(-f "${_f}")
done < "${MC_CONFIG_DIR}/helm-values-files.txt"

# --- Validate against the cluster's API first --------------------------------------
# helm template only proves the YAML renders. A server-side dry run of every
# object also catches values of the wrong type (e.g. a string where the API
# wants an object), which otherwise fail mid-install and leave a failed release
# with half its resources created. Jobs are skipped: completed hook Jobs are
# immutable and Helm recreates them anyway. MC_SERVER_VALIDATE=false skips this.
if mc_is_true "${MC_SERVER_VALIDATE:-true}" && ! ${DRY_RUN}; then
    mc_info "Validating the rendered manifests against the cluster (server-side dry run)..."
    _vdir="$(mktemp -d)"
    "${MC_HELM}" template "${MC_RELEASE_NAME}" "${CHART}" --version "${MC_VERSION}" \
        --namespace "${MC_NAMESPACE}" "${VALUES_ARGS[@]}" --skip-tests \
        --api-versions security.openshift.io/v1 --api-versions route.openshift.io/v1 2>/dev/null \
        | python3 -c '
import re, sys
docs = re.split(r"^---\s*$", sys.stdin.read(), flags=re.M)
keep = [d for d in docs if d.strip() and not re.search(r"^kind:\s*(Job|Pod)\s*$", d, re.M)]
print("\n---\n".join(keep))' > "${_vdir}/manifests.yaml"
    if ! oc apply --dry-run=server -n "${MC_NAMESPACE}" -f "${_vdir}/manifests.yaml" > "${_vdir}/out.txt" 2>&1; then
        grep -v '^Warning:\|patched automatically\|(server dry run)$' "${_vdir}/out.txt" | sed 's/^/    /' >&2
        rm -rf "${_vdir}"
        mc_die "The cluster rejects the rendered manifests (above) - nothing was installed."
    fi
    mc_info "All $(grep -c '(server dry run)$' "${_vdir}/out.txt") objects accepted by the API server."
    rm -rf "${_vdir}"
fi

prev="$("${MC_HELM}" status "${MC_RELEASE_NAME}" -n "${MC_NAMESPACE}" -o json 2>/dev/null | jq -r '.chart.metadata.version // empty' 2>/dev/null || true)"
if [[ -n "${prev}" ]]; then
    mc_info "Upgrading release ${MC_RELEASE_NAME}: chart ${prev} -> ${MC_VERSION}"
else
    mc_info "Installing release ${MC_RELEASE_NAME} (chart ${MC_VERSION}, ${MC_PLANE} plane) into ${MC_NAMESPACE}"
fi

"${MC_HELM}" upgrade --install "${MC_RELEASE_NAME}" "${CHART}" \
    --version "${MC_VERSION}" \
    --namespace "${MC_NAMESPACE}" \
    "${VALUES_ARGS[@]}" \
    --timeout "${MC_HELM_TIMEOUT:-15m}" \
    "$@"

mc_info "Helm finished. Pods take several minutes to start; follow with 2.3_mission_control_status.sh --wait"
