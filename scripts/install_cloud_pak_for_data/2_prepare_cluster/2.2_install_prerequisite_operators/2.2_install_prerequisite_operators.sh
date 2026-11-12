#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
ir_dispatch "$@"
# No options of its own: each lane installs only what CPD_COMPONENTS needs (below).
case "${1:-}" in
  -h|--help)
    print -r -- "Usage: ${0:t} [options]"
    print -r -- "Installs the prerequisite operators the components in CPD_COMPONENTS need: NFD and the GPU"
    print -r -- "Operator, OpenShift AI, MCG and Knative Eventing (see the comments in this script). It takes no"
    print -r -- "options of its own; INSTALL_OPERATORS_IN_PARALLEL and the SKIP_*_INSTALL settings steer it."
    _h_steps_runner_usage
    exit 0 ;;
esac
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Run the independent lanes below concurrently (true) or every script one after
# another in numbered order (false). Override at runtime, e.g.:
#   INSTALL_OPERATORS_IN_PARALLEL=false ./2.2_install_prerequisite_operators.sh
INSTALL_OPERATORS_IN_PARALLEL="${INSTALL_OPERATORS_IN_PARALLEL:-true}"

# Scripts within a lane always run in order; only the lanes run concurrently.
#   gpu     - the GPU Operator relies on NFD node labels, so NFD must go first.
#   rhoai   - OpenShift AI (+ Service Mesh in openshift-operators); shares nothing
#             with the other lanes.
#   cpd-cli - MCG and Knative Eventing both drive `cpd-cli manage` through the one
#             shared olm-utils container and work dir, so they must not overlap.
#
# Run from here, each script installs its operator only when a component in
# CPD_COMPONENTS needs it with its install options (IBM's defaults where none are
# set), and exits straight away otherwise. Run directly, a 2.2.x script installs
# its operator regardless. CP4D_PREREQ_GATE_DEFAULT carries the "auto" default to
# the scripts. Override per operator with auto / true (skip) / false (install anyway):
#   SKIP_GPU_OPERATORS_INSTALL     2.2.1 + 2.2.2
#   SKIP_RHOAI_INSTALL             2.2.3 (RHOAI_CREATE_DSC for the DataScienceCluster)
#   SKIP_MCG_INSTALL               2.2.4
#   SKIP_KNATIVE_EVENTING_INSTALL  2.2.5
# The rules live in src/helpers/cp4d_prereq_requirements.py.
export CP4D_PREREQ_GATE_DEFAULT="${CP4D_PREREQ_GATE_DEFAULT:-auto}"

LANES=(
  "gpu:2.2.1_install_nvidia_node_discovery.sh 2.2.2_install_nvidia_gpu_operator.sh"
  "rhoai:2.2.3_install_openshift_ai_operator.sh"
  "cpd-cli:2.2.4_install_multicloud_object_gateway_operator.sh 2.2.5_install_ibm_knative_eventing_operator.sh"
)

run_lane() {
  local script
  for script in "$@"; do
    "${CURRENT_DIR}/${script}" || return $?
  done
}

prefix_lines() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    print -r -- "[${1}] ${line}"
  done
}

if [[ "${INSTALL_OPERATORS_IN_PARALLEL}" != "true" ]]; then
  for _entry in "${LANES[@]}"; do
    run_lane ${=_entry#*:}
  done
  exit 0
fi

# --- Parallel mode ---------------------------------------------------------------
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/2.2_prerequisite_operators.XXXXXX")"
KUBE_DIR="${LOG_DIR}/kubeconfigs"
mkdir -p "${KUBE_DIR}"
# The per-lane kubeconfigs carry the login token; never leave them behind.
trap 'rm -rf "${KUBE_DIR}"; exit 130' INT TERM

# Log in once here, then give every lane its own flattened copy of the session.
# `oc login` and `oc new-project` both rewrite the kubeconfig, and concurrent
# writers to the shared ~/.kube/config can collide or clobber each other. With
# a valid session already in its copy, each child's OC_LOGIN skips the login.
eval "${OC_LOGIN}"

echo "[INFO] Installing prerequisite operators in ${#LANES[@]} parallel lanes (logs: ${LOG_DIR})"
for _entry in "${LANES[@]}"; do
  _lane="${_entry%%:*}"
  echo "[INFO]   ${_lane}: ${_entry#*:}"
  oc config view --raw > "${KUBE_DIR}/${_lane}.kubeconfig"
  (
    export KUBECONFIG="${KUBE_DIR}/${_lane}.kubeconfig"
    # Multi-cluster mode: the children keep this copy instead of the cluster's shared one.
    export MCM_KUBECONFIG_OVERRIDE=1
    run_lane ${=_entry#*:} && _rc=0 || _rc=$?
    print -r -- "${_rc}" > "${LOG_DIR}/${_lane}.rc"
  ) 2>&1 | tee "${LOG_DIR}/${_lane}.log" | prefix_lines "${_lane}" &
done
wait
rm -rf "${KUBE_DIR}"

echo ""
echo "[INFO] Prerequisite operator lanes finished:"
FAILED_LANES=()
for _entry in "${LANES[@]}"; do
  _lane="${_entry%%:*}"
  _rc="$(cat "${LOG_DIR}/${_lane}.rc" 2>/dev/null || echo "?")"
  if [[ "${_rc}" == "0" ]]; then
    echo "[INFO]   ${_lane}: OK"
  else
    echo "[ERROR]  ${_lane}: failed (exit ${_rc}) - see ${LOG_DIR}/${_lane}.log" >&2
    FAILED_LANES+=("${_lane}")
  fi
done

if (( ${#FAILED_LANES[@]} > 0 )); then
  echo "[ERROR] ${#FAILED_LANES[@]} lane(s) failed: ${FAILED_LANES[*]}" >&2
  exit 1
fi
