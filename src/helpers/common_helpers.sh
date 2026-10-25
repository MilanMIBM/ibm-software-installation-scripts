#!/bin/zsh
# =============================================================================
# common_helpers.sh - product-independent shell functions (h_*)
# -----------------------------------------------------------------------------
# The product libraries (concert_helpers.sh, datastax_mc_helpers.sh,
# private_registry_helpers.sh, confluent_helpers.sh, cli_install_helpers.sh,
# ...) source this and keep their own prefixed names as one-line wrappers, so
# their callers do not change. Scripts without a product library source it
# directly:
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
#
# Sections:
#   - logging / small utilities
#   - command-line helpers (option values, y/N questions)
#   - waits (generic, MachineConfigPools)
#   - chained installs (h_run_step)
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _COMMON_HELPERS_LOADED.
#   - Needs nothing from env_bootstrap.sh (the CLI installers skip it), so it
#     loads no config and reads no repo paths.
# =============================================================================

[[ -n "${_COMMON_HELPERS_LOADED:-}" ]] && return 0
_COMMON_HELPERS_LOADED=1

# =============================================================================
# Logging / small utilities
# =============================================================================
h_info()  { print -r -- "[INFO] $*"; }
h_warn()  { print -r -- "[WARN] $*" >&2; }
h_error() { print -r -- "[ERROR] $*" >&2; }
h_die()   { h_error "$@"; exit 1; }

# true / TRUE / yes / y / 1 -> success
h_is_true() { [[ "${1:-}" == ([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Yy]|1) ]]; }

# h_missing_vars VAR... - fails when any named variable is empty or unset, with
# the missing names (space-separated) in REPLY. The callers word the error,
# since each points at its own config file.
h_missing_vars() {
    local _hv
    local -a _hmissing=()
    for _hv in "$@"; do
        [[ -n "${(P)_hv:-}" ]] || _hmissing+=("${_hv}")
    done
    REPLY="${_hmissing[*]}"
    (( ${#_hmissing} == 0 ))
}

# Alphanumeric (safe in URLs, conf files, JSON), no trailing newline. Not
# `tr </dev/urandom | head`: under pipefail the SIGPIPE'd tr fails the pipeline
# and errexit kills the caller.
h_random_password() {   # [length, default 24]
    python3 -c 'import secrets, string, sys
a = string.ascii_letters + string.digits
print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))), end="")' "${1:-24}"
}

# A new 0700 directory under <base>/.run. Callers pass their (gitignored)
# workspace rather than $TMPDIR: on macOS podman can only bind-mount paths
# below $HOME.
h_private_tmpdir() {   # <base>
    local base="$1/.run"
    mkdir -p "${base}"
    chmod 700 "${base}"
    (umask 077; mktemp -d "${base}/run.XXXXXX")
}

h_sha256() {   # <file>
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# =============================================================================
# Command-line helpers
# =============================================================================
# For "--opt value" parsing: exits when <value> is missing or is the next option.
h_need_value() {   # <option> <value>
    [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }
}

# y/N question on the terminal; succeeds on y / yes (any case).
h_confirm() {   # <question>
    local _reply=""
    printf "%s [y/N] " "$1"
    read -r _reply || true
    [[ "${_reply}" == ([Yy]|[Yy][Ee][Ss]) ]]
}

# =============================================================================
# Waits
# =============================================================================
# h_wait_for <timeout-s> <description> <command...>
# Re-runs the command every 10s until it succeeds.
h_wait_for() {
    local timeout="$1" desc="$2"
    shift 2
    local start=${SECONDS}
    until "$@" >/dev/null 2>&1; do
        if (( SECONDS - start >= timeout )); then
            h_error "Timed out after ${timeout}s waiting for: ${desc}"
            return 1
        fi
        h_info "Waiting for ${desc} ($(( SECONDS - start ))s)"
        sleep 10
    done
}

# Wait for every MachineConfigPool to be Updated and not Updating.
h_wait_mcp_updated() {   # [timeout-s, default 3600]
    local timeout="${1:-3600}" start=${SECONDS} pending raw
    sleep 20   # let the MCO notice the change first
    while true; do
        # Control-plane nodes reboot during a rollout, so API errors are expected:
        # treat them as "still rolling", never as a failure of the caller.
        raw="$(oc get machineconfigpools -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Updated")].status} {.status.conditions[?(@.type=="Updating")].status}{"\n"}{end}' 2>/dev/null || true)"
        if [[ -z "${raw}" ]]; then
            pending="(API not reachable)"
        else
            pending="$(print -r -- "${raw}" | awk '$2 != "True" || $3 == "True" { print $1 }' | xargs)"
        fi
        [[ -z "${pending}" ]] && { h_info "All MachineConfigPools are updated."; return 0; }
        if (( SECONDS - start >= timeout )); then
            h_error "MachineConfigPools still updating after ${timeout}s: ${pending}"
            return 1
        fi
        h_info "MachineConfigPools rolling out: ${pending} ($(( SECONDS - start ))s)"
        sleep 30
    done
}

# =============================================================================
# Chained installs
# =============================================================================
# h_run_step [--stop|--warn] <enabled> <label> <command...>
# Runs the command when <enabled> is "true", else prints a skip line. On a
# non-zero exit:
#   (default)  the exit status is returned, so `set -e` callers stop there
#   --stop     prints an error and exits the caller with that status
#   --warn     prints a warning and carries on (returns 0)
h_run_step() {
    local on_failure=""
    [[ "${1:-}" == (--stop|--warn) ]] && { on_failure="${1#--}"; shift; }
    local enabled="$1" label="$2"
    shift 2

    if [[ "${enabled}" != "true" ]]; then
        echo ""
        echo "==> Skipping: ${label}"
        return 0
    fi

    echo ""
    echo "==> Running:  ${label}"
    if [[ -z "${on_failure}" ]]; then
        "$@"
        return
    fi
    local rc=0
    "$@" || rc=$?
    if (( rc != 0 )); then
        if [[ "${on_failure}" == "stop" ]]; then
            echo "[ERROR] ${label} exited ${rc}; stopping the install chain." >&2
            exit "${rc}"
        fi
        echo "[WARN] ${label} exited ${rc}; continuing chain."
    fi
    return 0
}
