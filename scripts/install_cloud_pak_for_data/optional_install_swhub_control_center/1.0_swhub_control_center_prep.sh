#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_helpers.sh"

# ==============================================================================
# Software Hub Control Center - prepare the cluster
# ------------------------------------------------------------------------------
# Starts the side-by-side premium cpd-cli, checks the prerequisites, creates the
# projects, downloads the CASE packages into the side workspace and applies their
# cluster-scoped resources. Safe to re-run.
# ==============================================================================

swhcc_activate
swhcc_ensure_image
swhcc_login

# --- Prerequisites: stop here rather than part way through the install
for sc in "${CONTROL_STG_CLASS_BLOCK}" "${CONTROL_STG_CLASS_FILE:-}"; do
    [[ -z "${sc}" ]] || oc get storageclass "${sc}" >/dev/null \
        || h_die "Storage class '${sc}' is not on the cluster. Check CONTROL_STG_CLASS_* in ${ENV_TARGET_FILE}."
done
oc get crd certificates.cert-manager.io >/dev/null 2>&1 \
    || h_die "No certificate manager on the cluster. Run 1_global_pull_secret_and_certmanager/1.0_set_up_openshift_certmanager.sh first."

[[ "${CONTROL_PROJECT_OPERATORS}" != "${CONTROL_PROJECT_OPERANDS}" ]] \
    || h_die "CONTROL_PROJECT_OPERATORS and CONTROL_PROJECT_OPERANDS must differ."
if [[ "${CONTROL_CLUSTER_MODE}" == same ]]; then
    for ns in "${PROJECT_CPD_INST_OPERATORS:-}" "${PROJECT_CPD_INST_OPERANDS:-}"; do
        [[ "${ns}" != "${CONTROL_PROJECT_OPERATORS}" && "${ns}" != "${CONTROL_PROJECT_OPERANDS}" ]] \
            || h_die "Control Center must not share project '${ns}' with a Software Hub instance."
    done
    h_missing_vars PROJECT_LICENSE_SERVICE PROJECT_SCHEDULING_SERVICE || h_die "Not set: ${REPLY}."
    for ns in "${PROJECT_LICENSE_SERVICE}" "${PROJECT_SCHEDULING_SERVICE}"; do
        oc get project "${ns}" >/dev/null 2>&1 \
            || h_die "Project '${ns}' not found: install the shared components with the main install first."
    done
fi

# Control Center installs exactly once per cluster.
other="$(oc get ibmswhccs.swh.ibm.com -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null \
    | grep -vx "${CONTROL_PROJECT_OPERANDS}" | head -1 || true)"
[[ -z "${other}" ]] || h_die "Control Center is already installed in project '${other}'; it installs once per cluster."

# --- Projects, with the pull secret as their default
PULL_SECRET_NAME="${IMAGE_PULL_SECRET:-pull-secret}"
PULL_SECRET_NAMESPACE="${PULL_SECRET_NAMESPACE:-openshift-config}"
# The projects get a copy of this secret, and Control Center's images come from
# cp.icr.io. On a cluster of its own, CP4D step 1.1 may never have added that login,
# and the pods would only fail to pull after the install has started.
if [[ "${CPD_IMAGE_SOURCE:-entitled}" == entitled ]]; then
    if ! oc get secret "${PULL_SECRET_NAME}" -n "${PULL_SECRET_NAMESPACE}" -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
        | base64 -d 2>/dev/null \
        | jq -e '.auths // {} | keys | any(. == "cp.icr.io" or startswith("cp.icr.io/"))' >/dev/null 2>&1; then
        h_error "${PULL_SECRET_NAMESPACE}/${PULL_SECRET_NAME} on ${CONTROL_OCP_URL:-the Control Center cluster} has no cp.icr.io login."
        # CP4D step 1.1 works on the Software Hub cluster (cpd_vars.sh's login), so
        # it only helps when that is this cluster.
        if [[ "${CONTROL_CLUSTER_MODE:-same}" == different ]]; then
            h_die "Add the entitlement key there (cp.icr.io, user cp) while logged in to ${CONTROL_OCP_URL:-that cluster}: run 1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh with a cpd_vars.sh for that cluster, or oc set data secret/${PULL_SECRET_NAME} -n ${PULL_SECRET_NAMESPACE} --from-file=.dockerconfigjson=<file with the cp.icr.io login>."
        fi
        h_die "Add the entitlement key first: 1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh"
    fi
fi
for ns in "${CONTROL_PROJECT_OPERATORS}" "${CONTROL_PROJECT_OPERANDS}"; do
    oc get project "${ns}" >/dev/null 2>&1 || oc new-project "${ns}" --skip-config-write >/dev/null
    oc get secret "${PULL_SECRET_NAME}" -n "${PULL_SECRET_NAMESPACE}" -o json \
        | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.ownerReferences)' \
        | oc apply -n "${ns}" -f -
    oc secrets link default "${PULL_SECRET_NAME}" --for=pull -n "${ns}"
    h_info "Project '${ns}' ready with default pull secret '${PULL_SECRET_NAME}'."
done

# --- CASE packages, in the side workspace
COMPONENTS="${SWHCC_COMPONENTS}"
SCHEDULER_FLAG=()
if [[ "${CONTROL_CLUSTER_MODE}" == different ]]; then
    COMPONENTS="ibm-licensing,scheduler,${COMPONENTS}"
    SCHEDULER_FLAG=(--scheduler_ns=${CONTROL_PROJECT_SCHEDULING_SERVICE})
fi

# Air-gapped: the transfer bundle was restored to the regular work dir.
if [[ "${CPD_CASE_SOURCE:-online}" == offline ]]; then
    mkdir -p "${CPD_CLI_WORK_PATH}/offline"
    cp -R "${CPD_CLI_BASE_WORK_PATH:-${HOME}/cpd-cli/work}/offline/." "${CPD_CLI_WORK_PATH}/offline/"
fi
cp4d_offline_case_check

cpd-cli manage case-download \
    --components=${COMPONENTS} \
    --release=${VERSION} \
    --operator_ns=${CONTROL_PROJECT_OPERATORS} \
    --swhcc_operator_ns=${CONTROL_PROJECT_OPERATORS} \
    --cluster_resources=true \
    --from_oci=true \
    "${SCHEDULER_FLAG[@]}" \
    "${SWHCC_PATCH_FLAG[@]}"

oc apply -f "${CPD_CLI_WORK_PATH}/cluster_scoped_resources.yaml" \
    --server-side \
    --force-conflicts
