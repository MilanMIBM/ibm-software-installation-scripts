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

# How an HTTP route answers a request WITHOUT credentials, as a short label.
# This probes the route itself rather than reading config, so it reports what
# is actually protected - including components that have no auth configured at
# all. The path per component is one that returns data when open, because some
# answer "/" with a redirect or a 404 whatever their auth.
cf_route_protection() {   # <namespace> <route>
    local host probe_path out code redirect
    host="$(oc get route "$2" -n "$1" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -z "${host}" ]] && return 0
    case "$2" in
        schema-registry) probe_path="/subjects" ;;
        connect)         probe_path="/connectors" ;;
        ksqldb-server)   probe_path="/info" ;;
        rest-proxy)      probe_path="/v3/clusters" ;;
        mds)             probe_path="/security/1.0/authenticate" ;;
        *)               probe_path="/" ;;
    esac
    out="$(curl -sk -o /dev/null --max-time 8 -w '%{http_code} %{redirect_url}' "https://${host}${probe_path}" 2>/dev/null || true)"
    code="${out%% *}"
    redirect="${out#* }"
    case "${code}" in
        401|403) echo "protected - credentials required (HTTP ${code} on ${probe_path})" ;;
        3??)     if [[ "${redirect}" == *oauth* ]]; then
                     echo "protected - OpenShift login (oauth-proxy)"
                 else
                     echo "unverified - HTTP ${code} redirect on ${probe_path}"
                 fi ;;
        2??)     echo "OPEN - answered ${probe_path} without credentials" ;;
        ""|000)  echo "unknown - route not reachable from this machine" ;;
        *)       echo "unverified - HTTP ${code} on ${probe_path}" ;;
    esac
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
