#!/bin/zsh
# =============================================================================
# install_runner_mode.sh - cheap answers about the in-cluster runner (ir_run_mode, ...)
# -----------------------------------------------------------------------------
# Sourced by the env load (scripts/source_env_setup.sh) and by ir_dispatch, which
# need to know whether a run moves to a pod before install_runner_helpers.sh is
# loaded. Only shell and awk here: no oc, no podman, no other helper file.
#
# Plan: .claude/plans/multi-cluster-management/in-cluster-install-addon/ (X8, X12)
# =============================================================================

# The run mode of this run -> REPLY. A one-off override (--run-mode, read by
# env_bootstrap.sh, or INSTALL_RUN_MODE_OVERRIDE) wins over INSTALL_RUN_MODE: configs
# set INSTALL_RUN_MODE and load after the caller's environment, but never set the
# override, so a stale export of the config value can never act as an override.
ir_run_mode() {
    REPLY="${INSTALL_RUN_MODE_OVERRIDE:-${INSTALL_RUN_MODE:-local}}"
}

# 0 when <repo-relative path> is a chain some install module lists in RUNNER_ENTRYPOINTS.
# Same rule as ir_install_for_chain, read with awk so nothing else has to be loaded.
ir_is_runner_entrypoint() {   # <repo root> <repo-relative path>
    emulate -L zsh
    local root="$1" chain="$2" f
    [[ -n "${chain}" ]] || return 1
    for f in "${root}"/src/install_runner/installs/*.conf(N); do
        [[ "${f:t:r}" == _template ]] && continue
        awk -F= -v want="${chain}" '
            $1 == "RUNNER_ENTRYPOINTS" {
                v = substr($0, index($0, "=") + 1); gsub(/^"|"$/, "", v)
                n = split(v, list, " ")
                for (i = 1; i <= n; i++) if (list[i] == want) found = 1
            }
            END { exit found ? 0 : 1 }' "${f}" && return 0
    done
    return 1
}

# 0 when this load is a workstation chain that hands its run to a pod: the run mode is
# cluster, this is not the pod itself, and the running script is a runner entry point.
# Such a load needs no local olm-utils container and no lease (gap X8).
ir_remote_run_load() {   # <repo root>
    emulate -L zsh
    local REPLY
    [[ -z "${IR_IN_RUNNER:-}" ]] || return 1
    ir_run_mode
    [[ "${REPLY}" == cluster ]] || return 1
    # Both sides resolved: :A follows symlinks, and the repo may sit behind one.
    ir_is_runner_entrypoint "$1" "${${ZSH_ARGZERO:A}#${1:A}/}"
}
