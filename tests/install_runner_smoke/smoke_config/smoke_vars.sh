# =============================================================================
# smoke_vars.sh - config of the runner smoke test (tests/install_runner_smoke/)
# -----------------------------------------------------------------------------
# Copy this folder to configs/smoke_config/ (or configs/clusters/<name>/smoke_config/)
# to run the smoke chain live; see ../README.md. It holds no credentials: the
# cluster and its login come from the environment (OCP_URL and OC_LOGIN, or
# SMOKE_OCP_URL and SMOKE_OC_LOGIN to keep them apart from a CP4D shell).
# =============================================================================
# Loaded only for the smoke chain: a load of every config must not take its values.
[[ "${ENV_TARGET:-}" == smoke || "${ENV_TARGET:-}" == *smoke_vars.sh ]] || return 0

# The folder this file was loaded from: the runner's stage and collect root.
export SMOKE_CONFIG_DIR="${${(%):-%x}:A:h}"
# In the pod the supervisor's session is used, and IR_OCP_URL is the slot's cluster.
export OCP_URL="${SMOKE_OCP_URL:-${OCP_URL:-${IR_OCP_URL:-}}}"
export OC_LOGIN="${SMOKE_OC_LOGIN:-${OC_LOGIN:-oc whoami >/dev/null}}"
export OLM_UTILS_IMAGE="${OLM_UTILS_IMAGE:-icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8}"
export STG_CLASS_BLOCK="${STG_CLASS_BLOCK:-ocs-storagecluster-ceph-rbd}"
export INSTALL_RUN_MODE="${INSTALL_RUN_MODE:-cluster}"
export SMOKE_LONG_SECONDS="${SMOKE_LONG_SECONDS:-240}"
