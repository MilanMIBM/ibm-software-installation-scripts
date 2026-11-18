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

# =============================================================================
# Operator install mode (CONFLUENT_DEPLOY_MODE, plan 15.1; contract 3.1)
# -----------------------------------------------------------------------------
# Pure zsh, no python, no cluster call (except cf_operator_guard, which hands
# over to confluent_operator_helpers.sh). In scripts mode every function here
# returns at once and prints nothing, so scripts-mode output stays unchanged.
# The Python twin of the resolvers is confluent_operator_config.py; the tests
# run one table through both.
# =============================================================================
_CF_HELPERS_DIR="${${(%):-%x}:A:h}"

# _cf_trim <value> - REPLY = the value without leading/trailing whitespace.
_cf_trim() {
    setopt localoptions extendedglob
    REPLY="${1##[[:space:]]##}"
    REPLY="${REPLY%%[[:space:]]##}"
}

# cf_resolve_deploy_mode - "scripts" or "operator" on stdout. scripts / operator
# (any case, whitespace trimmed) as given; unset, empty or anything else means
# operator, and an invalid value warns once per process tree.
cf_resolve_deploy_mode() {
    _cf_deploy_mode
    print -r -- "${REPLY}"
}

# Sets REPLY (no subshell, so the once-only warning marker and the cache stick).
_cf_deploy_mode() {
    if [[ -n "${_CF_DEPLOY_MODE:-}" && "${_CF_DEPLOY_MODE_SRC-}" == "${CONFLUENT_DEPLOY_MODE-}" ]]; then
        REPLY="${_CF_DEPLOY_MODE}"
        return 0
    fi
    _cf_trim "${CONFLUENT_DEPLOY_MODE:-}"
    local v="${REPLY}"
    case "${(L)v}" in
        scripts)     REPLY=scripts ;;
        operator|"") REPLY=operator ;;
        *)
            if [[ -z "${_CF_DEPLOY_MODE_WARNED:-}" ]]; then
                export _CF_DEPLOY_MODE_WARNED=1
                print -r -- "[WARN] CONFLUENT_DEPLOY_MODE='${v}' is not scripts|operator - using operator" >&2
            fi
            REPLY=operator ;;
    esac
    _CF_DEPLOY_MODE="${REPLY}"
    _CF_DEPLOY_MODE_SRC="${CONFLUENT_DEPLOY_MODE-}"
}

# cf_is_operator_mode - status 0 in operator mode, 1 in scripts mode; no output.
cf_is_operator_mode() {
    _cf_deploy_mode
    [[ "${REPLY}" == operator ]]
}

# cf_flink_operator_source - helm | olm | existing. Unset follows the platform
# (olm in operator mode, helm in scripts mode); invalid means olm, warned once.
cf_flink_operator_source() {
    _cf_flink_source
    print -r -- "${REPLY}"
}

_cf_flink_source() {
    _cf_trim "${FLINK_OPERATOR_SOURCE:-}"
    local v="${REPLY}"
    case "${(L)v}" in
        helm|olm|existing) REPLY="${(L)v}" ;;
        "")
            if cf_is_operator_mode; then REPLY=olm; else REPLY=helm; fi ;;
        *)
            if [[ -z "${_CF_FLINK_SOURCE_WARNED:-}" ]]; then
                export _CF_FLINK_SOURCE_WARNED=1
                print -r -- "[WARN] FLINK_OPERATOR_SOURCE='${v}' is not helm|olm|existing - using olm" >&2
            fi
            REPLY=olm ;;
    esac
}

# cf_flink_is_olm - status 0 when the Flink operator is not the Helm chart.
cf_flink_is_olm() {
    _cf_flink_source
    [[ "${REPLY}" != helm ]]
}

# cf_flink_cmf_resource_mode - cli | cfk. Unset: cfk when the Flink operator
# source is not helm, else cli; invalid: that default, warned once.
cf_flink_cmf_resource_mode() {
    _cf_flink_cmf_mode
    print -r -- "${REPLY}"
}

_cf_flink_cmf_mode() {
    local def=cli
    cf_flink_is_olm && def=cfk
    _cf_trim "${FLINK_CMF_RESOURCE_MODE:-}"
    local v="${REPLY}"
    case "${(L)v}" in
        cli|cfk) REPLY="${(L)v}" ;;
        "")      REPLY="${def}" ;;
        *)
            if [[ -z "${_CF_FLINK_CMF_WARNED:-}" ]]; then
                export _CF_FLINK_CMF_WARNED=1
                print -r -- "[WARN] FLINK_CMF_RESOURCE_MODE='${v}' is not cli|cfk - using ${def}" >&2
            fi
            REPLY="${def}" ;;
    esac
}

# cf_flink_operator_mode - status 0 when the Flink add-on runs any operator-mode
# part (OLM cp-fko, or CMF resources as CFK CRs): the Flink x.0 dispatch test.
cf_flink_operator_mode() {
    cf_flink_is_olm && return 0
    _cf_flink_cmf_mode
    [[ "${REPLY}" == cfk ]]
}

# cf_flink_configured - the Flink add-on is configured (same rule as
# full_installprocess-confluent_platform.sh).
cf_flink_configured() {
    [[ -n "${PROJECT_CONFLUENT_FLINK:-}" && -n "${FLINK_CMF_CHART_VERSION:-}" ]]
}

# cf_operator_guard <platform|flink|all> - the read-only scripts-mode guard for
# scripts that stay shared. Scripts / helm mode: status 0 at once, no output,
# no cluster call. Operator mode: cfo_guard_scripts_install (status 2 = blocked).
cf_operator_guard() {
    case "${1:-}" in
        platform) cf_is_operator_mode || return 0 ;;
        flink)    cf_flink_is_olm || return 0 ;;
        all)      { cf_is_operator_mode || cf_flink_is_olm; } || return 0 ;;
        *)        print -r -- "[ERROR] cf_operator_guard: scope must be platform, flink or all (got '${1:-}')" >&2
                  return 1 ;;
    esac
    (( ${+functions[cfo_guard_scripts_install]} )) || source "${_CF_HELPERS_DIR}/confluent_operator_helpers.sh"
    cfo_guard_scripts_install "$1"
}

# cf_persist_var <file> <NAME> <value> - rewrite the `export NAME=` line of a
# vars file (or append one), as x.2_confluent_add_sasl.sh's persist_var does.
# Refuses values a double-quoted shell string or the rewrite cannot hold.
# A missing file is not an error (nothing to persist into), as in the original.
cf_persist_var() {
    local file="$1" name="$2" value="$3" nl=$'\n'
    if [[ ! "${name}" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]]; then
        print -r -- "[ERROR] cf_persist_var: '${name}' is not a variable name." >&2
        return 1
    fi
    if [[ "${value}" == *[\"\\\`\|]* || "${value}" == *'$('* || "${value}" == *"${nl}"* ]]; then
        print -r -- "[ERROR] ${name}: the value contains a character that cannot be saved safely (\" \\ \` \$( | or a newline)." >&2
        return 1
    fi
    [[ -f "${file}" ]] || return 0
    if grep -qE "^export ${name}=" "${file}"; then
        local tmp
        tmp="$(mktemp "${file}.XXXXXX")" || return 1
        CF_PV_NAME="${name}" CF_PV_VALUE="${value}" awk '
            BEGIN { p = "^export " ENVIRON["CF_PV_NAME"] "=" }
            $0 ~ p { print "export " ENVIRON["CF_PV_NAME"] "=\"" ENVIRON["CF_PV_VALUE"] "\""; next }
            { print }' "${file}" > "${tmp}" && cat "${tmp}" > "${file}"
        local rc=$?
        rm -f "${tmp}"
        (( rc == 0 )) || return 1
    else
        printf '\nexport %s="%s"\n' "${name}" "${value}" >> "${file}"
    fi
    print -r -- "[INFO] ${name}=${value} saved to ${file##*/}."
}
