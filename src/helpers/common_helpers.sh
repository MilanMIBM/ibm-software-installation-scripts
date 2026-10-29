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
#   - step selection for chains (h_steps_parse, h_step, h_steps_plan, h_steps_run)
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

# =============================================================================
# Step selection for chained installs: --from / --skip / --list-steps
# =============================================================================
# A chain declares its steps in run order, then runs them:
#
#   h_steps_parse --strict "$@"
#   h_step certmanager "${DO_CERT_MANAGER}" "1.0 cert-manager" "${DIR}/1.0_x.sh"
#   h_step --warn status "${DO_STATUS}" "1.2 status" "${DIR}/1.2_x.sh" --wait
#   h_steps_plan    # check the step names, print the plan (exits on --list-steps / --help)
#   h_steps_run     # run every step in order
#
# h_steps_parse takes these out of the arguments and leaves the rest in
# H_STEPS_ARGS for the script's own parser (--strict: anything else is an error).
# Everything from a '--' on is left alone, for scripts that pass it to a tool:
#   --from <step>              start at this step (--from-step too; with --no-from
#                              only --from-step, for scripts whose --from means
#                              something else)
#   --skip <step>[,<step>...]  leave these steps out (repeatable)
#   --list-steps               print the plan, then exit
#   -h, --help                 usage + plan, then exit (not with --no-help: the
#                              script has its own and should mention the options)
# H_STEPS_USAGE, set before h_steps_plan, adds the script's own options to --help.
#
# A step runs when its toggle is "true" and --from / --skip / h_steps_until
# select it. When it fails:
#   (default) --stop   stop the chain and name the --from that resumes it
#   --warn             warn, add it to H_STEPS_FAILED, carry on
# A chain with logic between steps runs them one at a time with h_step_run <name>.
h_steps_parse() {   # [--strict] [--no-from] [--no-help] <args...>
    local strict=false take_from=true take_help=true
    while [[ "${1:-}" == (--strict|--no-from|--no-help) ]]; do
        case "$1" in
            --strict)  strict=true ;;
            --no-from) take_from=false ;;
            --no-help) take_help=false ;;
        esac
        shift
    done
    typeset -ga H_STEPS=() H_STEPS_ARGS=() H_STEPS_SKIP=() H_STEPS_FAILED=()
    typeset -gA H_STEP_TOGGLE=() H_STEP_LABEL=() H_STEP_MODE=() H_STEP_CMD=() H_STEP_HINT=()
    typeset -g H_STEPS_FROM="" H_STEPS_UNTIL="" H_STEPS_LIST=false H_STEPS_HELP=false
    typeset -g H_STEPS_FROM_OPT=--from
    ${take_from} || H_STEPS_FROM_OPT=--from-step
    while (( $# )); do
        case "$1" in
            --from-step)    H_STEPS_FROM="${2:?$1 needs a step name}"; shift 2 ;;
            --from-step=*)  H_STEPS_FROM="${1#*=}"; shift ;;
            --skip)         H_STEPS_SKIP+=(${(s:,:)${2:?--skip needs step names}}); shift 2 ;;
            --skip=*)       H_STEPS_SKIP+=(${(s:,:)${1#*=}}); shift ;;
            --list-steps)   H_STEPS_LIST=true; shift ;;
            --)
                ${strict} && h_die "Unknown option: $1 (see --help)"
                H_STEPS_ARGS+=("$@"); break ;;
            *)
                if ${take_from} && [[ "$1" == --from ]]; then
                    H_STEPS_FROM="${2:?--from needs a step name}"; shift 2
                elif ${take_from} && [[ "$1" == --from=* ]]; then
                    H_STEPS_FROM="${1#*=}"; shift
                elif ${take_help} && [[ "$1" == (-h|--help) ]]; then
                    H_STEPS_HELP=true; shift
                elif ${strict}; then
                    h_die "Unknown option: $1 (see --help)"
                else
                    H_STEPS_ARGS+=("$1"); shift
                fi ;;
        esac
    done
}

# h_step [--stop|--warn] <name> <toggle> <label> [command...]
# Declares the next step. Without a command, only h_step_run can run it (with one).
h_step() {
    local mode=stop
    [[ "${1:-}" == (--stop|--warn) ]] && { mode="${1#--}"; shift; }
    local name="$1" toggle="$2" label="$3"
    shift 3
    (( ${H_STEPS[(Ie)${name}]} )) && h_die "h_step: step '${name}' declared twice"
    H_STEPS+=("${name}")
    H_STEP_TOGGLE[$name]="${toggle}"
    H_STEP_LABEL[$name]="${label}"
    H_STEP_MODE[$name]="${mode}"
    H_STEP_CMD[$name]="${(j: :)${(q)@}}"
}

# h_step_hint <step> <text>: an extra line printed when that step stops the chain.
h_step_hint() { H_STEP_HINT[$1]="$2"; }

# h_steps_until <step>: nothing after this step runs (e.g. a --prepare-only option).
h_steps_until() { H_STEPS_UNTIL="$1"; }

# h_step_selected <step>: --from / --skip / h_steps_until leave it in (toggle aside).
h_step_selected() {
    local i=${H_STEPS[(Ie)$1]} from=1 last=${#H_STEPS}
    [[ -n "${H_STEPS_FROM}" ]] && from=${H_STEPS[(Ie)${H_STEPS_FROM}]}
    [[ -n "${H_STEPS_UNTIL}" ]] && last=${H_STEPS[(Ie)${H_STEPS_UNTIL}]}
    (( i >= from && i <= last && ! ${H_STEPS_SKIP[(Ie)$1]} ))
}

# h_step_on <step>: the step will run (toggle on and selected).
h_step_on() { [[ "${H_STEP_TOGGLE[$1]}" == true ]] && h_step_selected "$1"; }

# h_steps_check: every step named in --from / --skip exists, and they leave something to run.
h_steps_check() {
    _h_steps_check_names
    _h_steps_check_left
}
_h_steps_check_names() {
    local s
    for s in "${H_STEPS_SKIP[@]}" ${H_STEPS_FROM:+"${H_STEPS_FROM}"} ${H_STEPS_UNTIL:+"${H_STEPS_UNTIL}"}; do
        (( ${H_STEPS[(Ie)${s}]} )) || h_die "Unknown step '${s}'. Steps: ${H_STEPS[*]}"
    done
}
_h_steps_check_left() {
    local s
    [[ -n "${H_STEPS_FROM}${H_STEPS_UNTIL}${H_STEPS_SKIP[*]}" ]] || return 0
    for s in "${H_STEPS[@]}"; do h_step_on "${s}" && return 0; done
    h_die "No steps left to run with these --from / --skip options."
}

# h_steps_print: one line per step - run, skip (--from / --skip) or off (toggle).
h_steps_print() {
    local s mark
    h_info "Steps:"
    for s in "${H_STEPS[@]}"; do
        if [[ "${H_STEP_TOGGLE[$s]}" != true ]]; then mark="off "
        elif h_step_selected "${s}"; then mark="run "
        else mark="skip"; fi
        printf '[INFO]   [%s] %-20s %s\n' "${mark}" "${s}" "${H_STEP_LABEL[$s]}"
    done
}

# h_steps_plan: check, print the plan; --help / --list-steps exit here.
h_steps_plan() {
    _h_steps_check_names
    if ${H_STEPS_HELP}; then
        print -r -- "Usage: ${ZSH_ARGZERO:t} [${H_STEPS_FROM_OPT} <step>] [--skip <step>[,<step>...]] [--list-steps]${H_STEPS_USAGE:+ [options]}"
        printf '  %-28s%s\n' "${H_STEPS_FROM_OPT} <step>" "start at this step, e.g. to resume after a failure" \
            "--skip <step>[,<step>...]" "leave these steps out (repeatable)" \
            "--list-steps" "print the steps and what this run would do, then exit"
        [[ -n "${H_STEPS_USAGE:-}" ]] && print -r -- "${H_STEPS_USAGE}"
        print -r -- "A step runs when its DO_* toggle is on and ${H_STEPS_FROM_OPT} / --skip select it."
        print ""
    fi
    h_steps_print
    { ${H_STEPS_LIST} || ${H_STEPS_HELP}; } && exit 0
    _h_steps_check_left
}

# h_step_run <step> [command...]: run one step (its declared command when none is given).
h_step_run() {
    local name="$1"
    shift
    (( ${H_STEPS[(Ie)${name}]} )) || h_die "h_step_run: unknown step '${name}'"
    local on=false rc=0
    h_step_on "${name}" && on=true
    if (( $# )); then
        h_run_step "${on}" "${H_STEP_LABEL[$name]}" "$@" || rc=$?
    elif [[ -z "${H_STEP_CMD[$name]}" ]]; then
        h_die "h_step_run: step '${name}' has no command (declare one with h_step, or pass it here)"
    else
        eval "h_run_step \"\${on}\" \"\${H_STEP_LABEL[\$name]}\" ${H_STEP_CMD[$name]}" || rc=$?
    fi
    (( rc == 0 )) && return 0
    if [[ "${H_STEP_MODE[$name]}" == warn ]]; then
        H_STEPS_FAILED+=("${name}")
        h_warn "Step '${name}' exited ${rc}; continuing with the rest."
        return 0
    fi
    h_error "Step '${name}' exited ${rc}. Fix the cause, then re-run the same command with ${H_STEPS_FROM_OPT} ${name} added."
    [[ -n "${H_STEP_HINT[$name]:-}" ]] && h_error "${H_STEP_HINT[$name]}"
    exit "${rc}"
}

# h_steps_run: every declared step, in order.
h_steps_run() {
    local s
    for s in "${H_STEPS[@]}"; do h_step_run "${s}"; done
}
