#!/bin/zsh
# =============================================================================
# confluent_helpers.sh - shared functions for scripts/install_confluent_platform
# (the platform, its utility scripts and the Flink add-on)
# -----------------------------------------------------------------------------
# How scripts use it (after the env_bootstrap line):
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/confluent_helpers.sh"
#
# Also loads common_helpers.sh (h_need_value, h_confirm, ...).
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _CF_HELPERS_LOADED.
#   - The utility scripts change the platform by exporting toggles and
#     re-running 1.1_confluent_install.sh (or 1.1_flink_install.sh); these
#     helpers only cover what they do around that.
# =============================================================================

[[ -n "${_CF_HELPERS_LOADED:-}" ]] && return 0
_CF_HELPERS_LOADED=1

source "${${(%):-%x}:A:h}/common_helpers.sh"

# "Continue? [y/N]" after a script has described a disruptive change; anything
# but yes exits 0 with "Aborted".
cf_continue_or_abort() {
    h_confirm "Continue?" || { echo "[INFO] Aborted."; exit 0; }
    echo ""
}

# cf_dry_run [--ignore-errors] <command...>
# Prints the command when DRY_RUN=true, else runs it. --ignore-errors hides its
# stderr and failures (deletes of things that may already be gone).
cf_dry_run() {
    local ignore=false
    [[ "${1:-}" == --ignore-errors ]] && { ignore=true; shift; }
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY-RUN] $*"
    elif ${ignore}; then
        "$@" 2>/dev/null || true
    else
        "$@"
    fi
}

# https://<host> of a route, empty when it does not exist. The trailing
# 'return 0' matters: without it a missing route makes the [[ ]] test the
# function's exit status, and under `set -e` a caller that uses it inside a
# heredoc dies mid-write, silently truncating the generated file.
cf_route_url() {   # <namespace> <route>
    local host
    host="$(oc get route "$2" -n "$1" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && echo "https://${host}"
    return 0
}

# Runs the status script after a change, unless <run> is false. A non-zero
# status means a component is not ready yet: information, not a failure.
cf_closing_status() {   # <run: true|false> <status script>
    if [[ "$1" == "true" && -f "$2" ]]; then
        echo ""
        "$2" || echo "[WARN] Status reported one or more components not ready (see above)."
    fi
    return 0
}
