#!/bin/zsh
# =============================================================================
# multi_cluster_helpers.sh - state file, cluster names and per-cluster folders
#                            for multi-cluster management (mcm_*)
# -----------------------------------------------------------------------------
# Plan: .claude/plans/multi-cluster-management/multi-cluster-management-plan.md
# Python twin (kept in step, tests/test_mcm_state.py compares them):
#   src/helpers/multi_cluster_state.py
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/multi_cluster_helpers.sh"
#
# State file (MCM_STATE_FILE, else <repo>/configs/multi_cluster_management.sh):
#   mcm_state_file                  path of the state file
#   mcm_ensure_state_file           writes the default when missing; MCM_CLUSTERS
#                                   is rebuilt from configs/clusters/*/.cluster
#   mcm_load_state                  parses it (never sources it) into the plain,
#                                   non-exported globals named in _MCM_STATE_KEYS
#   mcm_write_state KEY=VALUE...    read, change, re-render, atomic rename, 0600;
#                                   unknown keys are kept
#   mcm_is_on                       0 on, 1 off, 2 the state file is invalid. The flag
#                                   is only the default: for new clusters and for runs
#                                   that name no cluster
#
# Names and folders:
#   mcm_name_from_url URL           cluster name derived from an OCP URL (stdout)
#   mcm_validate_name NAME          allowed pattern and reserved names
#   mcm_clusters_root               <repo>/configs/clusters
#   mcm_cluster_root NAME           <repo>/configs/clusters/NAME
#   mcm_cpd_cli_root NAME           ~/cpd-cli/clusters/NAME
#   mcm_is_registered NAME          listed in MCM_CLUSTERS?
#   mcm_register NAME [URL]         folder, .cluster marker (DELINEATED="true", any
#                                   RETIRED cleared), entry in MCM_CLUSTERS
#   mcm_set_current NAME            sets MCM_CURRENT_CLUSTER (must be registered)
#   mcm_resolve_configs_root [NAME] for scripts that load no config: NAME's folder,
#                                   else (mode on) MCM_CLUSTER, the current cluster
#                                   or the only registered one; (mode off) a delineated
#                                   MCM_CLUSTER, else flat; fails with guidance if on
#                                   and none is found, or MCM_CLUSTER is retired
#
# Delineation, one-way per cluster (a cluster with a marker never goes back to flat):
#   mcm_is_delineated NAME          0 when configs/clusters/NAME/.cluster exists (retired
#                                   included; a marker without DELINEATED counts)
#   mcm_is_retired NAME             0 when delineated and the marker has RETIRED="true"
#   mcm_delineated_clusters [--exclude-retired]
#                                   delineated names, space separated, byte order
#   mcm_cluster_for_url URL         the delineated cluster owning URL (marker OCP_URL by
#                                   _mcm_url_key, else the derived name's marker when it
#                                   records no URL); empty if none, rc 0
#   mcm_mark_retired NAME           marker RETIRED="true"; the state file is untouched
#   mcm_unretire NAME               clears RETIRED; the state file is untouched
#   mcm_flat_config_conflict URL [FILE...]
#                                   1 with guidance when a flat load's URL belongs to a
#                                   delineated cluster (source_env_setup.sh)
#   mcm_flat_configs_root           mode off, a script that loads no config: this
#                                   checkout's configs/, or a CONFIGS_ROOT inside it
#
# Targets and the per-cluster environment (plan 5.4, 5.5):
#   mcm_take_target_flags "$@"      strips the target flags into _MCM_ARGV
#   mcm_resolve_targets             table 5.4; sets _MCM_RESOLVED, prints the names.
#                                   Mode off: only explicit names of delineated, not
#                                   retired clusters (flags, MCM_CLUSTER); else empty
#   mcm_resolve_one                 same, narrowed to one cluster; exports nothing
#   mcm_env_setup "$@"              env load: state file, resolve, fan out or pin
#   mcm_env_setup_no_fanout         same for a sourced load, which ends on one cluster
#   mcm_fanout "$@"                 multi-target run: re-runs the script per cluster, exits
#   mcm_exit_no_trap CODE           ends a process without the script's EXIT trap
#   mcm_script_policy SCRIPT        allow, single-only or confirm (plan 5.8); an
#                                   exported MCM_SCRIPT_POLICY wins, and a
#                                   single-only refusal adds MCM_SCRIPT_POLICY_WHY
#   mcm_pin NAME                    exports the per-cluster values of this run
#   mcm_container_name [NAME]       olm-utils container name
#   mcm_mirror_destination_key ROOT folder name under registries/
#
# Containers on and off (plan 5.7, 5.7.1):
#   mcm_sync_containers [stop-only] start this run's container, stop what is no
#                                   longer targeted, lease, watcher. Never fails.
#                                   The env load passes stop-only for MCM_SYNC_MODE=stop-only
#                                   and for a chain whose run goes to a pod
#   mcm_targeted_clusters           run's targets plus the state file's selection
#   mcm_container_names [NAME]      one cluster's names (no NAME: the flat pair), with
#                                   any custom Control Center name sync has recorded
#   mcm_managed_containers          every name sync and the watcher may touch
#   mcm_container_busy NAME         0 busy, 1 idle (NAME: a container or a cluster);
#                                   _MCM_BUSY_WHY says what is keeping it busy
#   mcm_take_lease [NAME]           marks this top-level run as live on the cluster
#   mcm_release_lease [NAME]        drops that mark again, for a lease held only for a step
#   mcm_ensure_idle_watcher         starts multi_cluster_idle_watcher.sh if none runs
#   mcm_stop_idle_after_off         mode just went off: stops idle cluster containers,
#                                   warns about busy ones. Needs no watcher. Never fails
#   mcm_login_probe_command         what CPDM_OC_LOGIN runs for its login probes
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _MCM_HELPERS_LOADED.
#   - Loads no config, so generators can use it before a config exists. Only
#     mcm_pin and mcm_activate_shim export, and only for a run pinned to a cluster:
#     a flat run (mode off, no delineated cluster named) keeps its environment.
#   - Safe under 'set -euo pipefail'. Failures print [ERROR] on stderr and return
#     non-zero; only mcm_fanout and mcm_exit_no_trap end the process.
#   - The repo root is this file's own checkout. _CP4D_REPO_ROOT counts only when it
#     names that checkout: a shell loaded from another one exports its own.
# =============================================================================

# Per checkout: a shell that loaded this file from one checkout can source a script
# from another, and that script must get its own copy.
[[ -n "${_MCM_HELPERS_LOADED:-}" && "${_MCM_HELPER_DIR:-}" == "${${(%):-%x}:A:h}" ]] && return 0
_MCM_HELPERS_LOADED=1

_MCM_HELPER_DIR="${${(%):-%x}:A:h}"

# Every known key, in file order. The zsh and Python readers share this list.
typeset -ga _MCM_STATE_KEYS=(
    MULTI_CLUSTER_MANAGEMENT
    MCM_CLUSTERS
    MCM_CURRENT_CLUSTER
    APPLY_TO_ALL
    MCM_TARGET_CLUSTERS
    MCM_STOP_INACTIVE_CONTAINERS
    MCM_CONTAINER_IDLE_TIMEOUT_MINUTES
    MCM_STOP_IDLE_PODMAN_VM
)
typeset -gA _MCM_STATE_DEFAULTS=(
    MULTI_CLUSTER_MANAGEMENT            false
    MCM_CLUSTERS                        ""
    MCM_CURRENT_CLUSTER                 ""
    APPLY_TO_ALL                        false
    MCM_TARGET_CLUSTERS                 ""
    MCM_STOP_INACTIVE_CONTAINERS        true
    MCM_CONTAINER_IDLE_TIMEOUT_MINUTES  120
    MCM_STOP_IDLE_PODMAN_VM             true
)
typeset -gA _MCM_STATE_COMMENTS=(
    MULTI_CLUSTER_MANAGEMENT            "true | false"
    MCM_CLUSTERS                        "registered clusters, space separated"
    MCM_CURRENT_CLUSTER                 "working cluster"
    APPLY_TO_ALL                        "run each command on every registered cluster"
    MCM_TARGET_CLUSTERS                 "or a specific list; beats APPLY_TO_ALL when set"
    MCM_STOP_INACTIVE_CONTAINERS        "stop idle containers of clusters no longer targeted"
    MCM_CONTAINER_IDLE_TIMEOUT_MINUTES  "stop a container after this long with no commands; 0 = never"
    MCM_STOP_IDLE_PODMAN_VM             "also shut down the podman VM once nothing at all is running"
)

_mcm_err() { print -r -- "[ERROR] $*" >&2; }
_mcm_warn() { print -r -- "[WARN] $*" >&2; }

# =============================================================================
# Paths
# =============================================================================
# _CP4D_REPO_ROOT is honoured only for its spelling (a path through a symlink).
mcm_repo_root() {
    local own="${_MCM_HELPER_DIR:h:h}"
    if [[ -n "${_CP4D_REPO_ROOT:-}" && "${_CP4D_REPO_ROOT:A}" == "${own}" ]]; then
        print -r -- "${_CP4D_REPO_ROOT}"
    else
        print -r -- "${own}"
    fi
}

mcm_state_file() {
    local repo
    if [[ -n "${MCM_STATE_FILE:-}" ]]; then
        print -r -- "${MCM_STATE_FILE}"
        return 0
    fi
    repo="$(mcm_repo_root)" || return 1
    print -r -- "${repo}/configs/multi_cluster_management.sh"
}

mcm_clusters_root() {
    local repo
    repo="$(mcm_repo_root)" || return 1
    print -r -- "${repo}/configs/clusters"
}

mcm_cluster_root() {
    local name="${1:-}" root
    mcm_validate_name "${name}" || return 1
    root="$(mcm_clusters_root)" || return 1
    print -r -- "${root}/${name}"
}

mcm_cpd_cli_root() {
    local name="${1:-}"
    mcm_validate_name "${name}" || return 1
    print -r -- "${HOME}/cpd-cli/clusters/${name}"
}

# =============================================================================
# Names
# =============================================================================
# Pattern check only, no message. Reserved names count as invalid.
_mcm_name_ok() {
    emulate -L zsh
    local name="${1:-}"
    [[ -n "${name}" ]] || return 1
    [[ "${name}" == [a-z0-9]* ]] || return 1
    [[ "${name}" != *[^a-z0-9._-]* ]] || return 1
    case "${name}" in
        clusters|old_configs|*_config|*_workspace) return 1 ;;
    esac
    return 0
}

mcm_validate_name() {
    emulate -L zsh
    local name="${1:-}"
    if _mcm_name_ok "${name}"; then
        return 0
    fi
    case "${name}" in
        clusters|old_configs|*_config|*_workspace)
            _mcm_err "Invalid cluster name '${name}': reserved (clusters, old_configs, or ending in _config or _workspace)." ;;
        *)
            _mcm_err "Invalid cluster name '${name}': must match [a-z0-9][a-z0-9._-]*." ;;
    esac
    return 1
}

# The label after "api." in the host, else the first label; an IPv4 address keeps
# all four parts joined by dashes. Prints the name on stdout.
mcm_name_from_url() {
    emulate -L zsh -o extended_glob
    local url="${1:-}" host name part
    local -a parts
    url="${${url##[[:space:]]#}%%[[:space:]]#}"
    host="${url#[A-Za-z][A-Za-z0-9+.-]#://}"
    host="${host%%[/?#]*}"
    host="${host##*@}"
    host="${host%%:*}"
    host="${(L)host}"
    if [[ -z "${host}" ]]; then
        _mcm_err "Cannot derive a cluster name from '${url}': no host found. Give an explicit name."
        return 1
    fi
    parts=("${(@s:.:)host}")

    local ipv4=1
    if (( ${#parts} != 4 )); then
        ipv4=0
    else
        for part in "${parts[@]}"; do
            if (( ${#part} > 3 )) || [[ "${part}" != <0-255> ]]; then
                ipv4=0
            fi
        done
    fi

    if (( ipv4 )); then
        name="${(j:-:)parts}"
    elif [[ "${parts[1]}" == api ]] && (( ${#parts} > 1 )) && [[ -n "${parts[2]}" ]]; then
        name="${parts[2]}"
    else
        name="${parts[1]}"
    fi

    if ! mcm_validate_name "${name}"; then
        _mcm_err "Cannot derive a usable cluster name from '${url}'. Give an explicit name."
        return 1
    fi
    print -r -- "${name}"
}

# =============================================================================
# Reading and writing the state file
# =============================================================================
# The functions below work on these names in the caller's scope (zsh locals are
# visible to callees):
#   _mcm_kv        known and unknown keys -> value
#   _mcm_unknown   unknown keys, in file order
#   _mcm_raw       lines that are neither comments nor KEY="value", kept verbatim

# Registered clusters found on disk, space separated, in byte order. A retired cluster
# (multi_cluster.sh remove without --purge) keeps its marker but is not registered.
_mcm_clusters_on_disk() {
    emulate -L zsh
    local LC_ALL=C marker root name
    local -a names
    root="$(mcm_clusters_root)" || return 1
    for marker in "${root}"/*/.cluster(N.); do
        name="${marker:h:t}"
        if ! _mcm_name_ok "${name}"; then
            _mcm_warn "Skipping cluster folder with an invalid name: ${marker:h}"
            continue
        fi
        [[ "$(_mcm_marker_value "${marker}" RETIRED)" == true ]] && continue
        names+=("${name}")
    done
    print -r -- "${(j: :)${(@o)names}}"
}

_mcm_set_defaults() {
    local key
    _mcm_unknown=()
    _mcm_raw=()
    _mcm_kv=()
    for key in "${_MCM_STATE_KEYS[@]}"; do
        _mcm_kv[$key]="${_MCM_STATE_DEFAULTS[$key]}"
    done
}

# Fills _mcm_kv, _mcm_unknown and _mcm_raw from FILE. A missing file gives the
# defaults with MCM_CLUSTERS rebuilt from disk.
_mcm_parse_state() {
    emulate -L zsh
    setopt no_re_match_pcre
    local file="$1" line key value
    local MATCH MBEGIN MEND
    local -a match mbegin mend
    _mcm_set_defaults
    if [[ ! -f "${file}" ]]; then
        _mcm_kv[MCM_CLUSTERS]="$(_mcm_clusters_on_disk)" || return 1
        return 0
    fi
    if [[ ! -r "${file}" ]]; then
        _mcm_err "Cannot read ${file}"
        return 1
    fi
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ '^[[:space:]]*(#.*)?$' ]]; then
            continue
        fi
        if [[ "${line}" =~ '^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"[[:space:]]*(#.*)?$' ]]; then
            key="${match[2]}"
            value="${match[3]}"
            if (( ! ${_MCM_STATE_KEYS[(Ie)${key}]} && ! ${_mcm_unknown[(Ie)${key}]} )); then
                _mcm_unknown+=("${key}")
            fi
            _mcm_kv[$key]="${value}"
            continue
        fi
        if [[ "${line}" =~ '^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=' ]] \
            && (( ${_MCM_STATE_KEYS[(Ie)${match[2]}]} )); then
            key="${match[2]}"
            value="${key} must be written as export ${key}=\"value\" (found: ${line})"
            # A read (mcm_load_state) decides after the flag is known; a write always stops.
            if (( ${+_mcm_malformed} )) && [[ "${key}" != MULTI_CLUSTER_MANAGEMENT ]]; then
                _mcm_malformed+=("${value}")
                continue
            fi
            _mcm_err "${file}: ${value}"
            return 1
        fi
        _mcm_raw+=("${line}")
    done < "${file}"
    return 0
}

# 0 when KEY's value in _mcm_kv is allowed, else 1 with the complaint in REPLY.
_mcm_check_state_key() {   # KEY
    emulate -L zsh
    local key="$1" value="${_mcm_kv[$1]-}" item
    local IFS=$' \t\n'
    REPLY=""
    case "${key}" in
        MULTI_CLUSTER_MANAGEMENT|APPLY_TO_ALL|MCM_STOP_INACTIVE_CONTAINERS|MCM_STOP_IDLE_PODMAN_VM)
            [[ "${value}" == (true|false) ]] && return 0
            REPLY="${key} must be true or false (found: '${value}')"
            ;;
        MCM_CONTAINER_IDLE_TIMEOUT_MINUTES)
            [[ -n "${value}" && "${value}" != *[^0-9]* ]] && return 0
            REPLY="${key} must be a whole number of minutes, 0 to disable (found: '${value}')"
            ;;
        MCM_CLUSTERS|MCM_TARGET_CLUSTERS)
            for item in ${=value}; do
                if ! _mcm_name_ok "${item}"; then
                    REPLY="${key} must be a space separated list of cluster names (bad entry: '${item}')"
                    return 1
                fi
            done
            return 0
            ;;
        MCM_CURRENT_CLUSTER)
            [[ -z "${value}" ]] || _mcm_name_ok "${value}" && return 0
            REPLY="${key} is not a valid cluster name (found: '${value}')"
            ;;
    esac
    return 1
}

# Checked in this order, so the first complaint is stable. Unknown keys are not checked.
typeset -ga _MCM_STATE_CHECK_ORDER=(
    MULTI_CLUSTER_MANAGEMENT APPLY_TO_ALL MCM_STOP_INACTIVE_CONTAINERS MCM_STOP_IDLE_PODMAN_VM
    MCM_CONTAINER_IDLE_TIMEOUT_MINUTES MCM_CLUSTERS MCM_TARGET_CLUSTERS MCM_CURRENT_CLUSTER
)

_mcm_validate_state() {
    emulate -L zsh
    local file="$1" key REPLY=""
    for key in "${_MCM_STATE_CHECK_ORDER[@]}"; do
        if ! _mcm_check_state_key "${key}"; then
            _mcm_err "${file}: ${REPLY}"
            return 1
        fi
    done
    return 0
}

# Mode off: a mistyped setting of an unused feature must not stop a single-cluster run.
# Each bad value becomes its default for this run, with a warning naming the key.
_mcm_soften_state() {
    emulate -L zsh
    local file="$1" key item REPLY=""
    for item in "${_mcm_malformed[@]}"; do
        _mcm_warn "${file}: ${item}. Ignored while multi-cluster mode is off."
    done
    for key in "${_MCM_STATE_CHECK_ORDER[@]}"; do
        if ! _mcm_check_state_key "${key}"; then
            _mcm_warn "${file}: ${REPLY}. Using the default while multi-cluster mode is off."
            _mcm_kv[$key]="${_MCM_STATE_DEFAULTS[$key]}"
        fi
    done
    return 0
}

_mcm_render_state() {
    emulate -L zsh
    local key line pad
    print -r -- '# Generated. Safe to edit by hand; keep the KEY="value" form.'
    print -r -- '# Manage with src/utilities/multi_cluster_management_utils/multi_cluster.sh or the notebooks.'
    for key in "${_MCM_STATE_KEYS[@]}"; do
        line="export ${key}=\"${_mcm_kv[$key]-}\""
        pad=$(( 45 - ${#line} ))
        if (( pad < 2 )); then
            pad=2
        fi
        printf '%s%*s# %s\n' "${line}" "${pad}" "" "${_MCM_STATE_COMMENTS[$key]}"
    done
    for key in "${_mcm_unknown[@]}"; do
        print -r -- "export ${key}=\"${_mcm_kv[$key]-}\""
    done
    for line in "${_mcm_raw[@]}"; do
        print -r -- "${line}"
    done
}

# Atomic: renders to a temp file beside FILE, then renames it over FILE.
_mcm_write_rendered() {
    emulate -L zsh
    local file="$1" tmp
    if ! mkdir -p "${file:h}"; then
        _mcm_err "Cannot create folder ${file:h}"
        return 1
    fi
    if ! tmp="$(mktemp "${file}.XXXXXX")"; then
        _mcm_err "Cannot create a temp file next to ${file}"
        return 1
    fi
    if _mcm_render_state >"${tmp}" && chmod 600 "${tmp}" && mv -f "${tmp}" "${file}"; then
        return 0
    fi
    rm -f "${tmp}"
    _mcm_err "Cannot write ${file}"
    return 1
}

mcm_ensure_state_file() {
    emulate -L zsh
    local file
    typeset -A _mcm_kv
    typeset -a _mcm_unknown _mcm_raw
    file="$(mcm_state_file)" || return 1
    if [[ -f "${file}" ]]; then
        return 0
    fi
    _mcm_parse_state "${file}" || return 1
    _mcm_write_rendered "${file}"
}

# Sets the known keys as plain globals. "+x" keeps them out of children's
# environment even if a caller had exported the same name.
mcm_load_state() {
    emulate -L zsh
    local file key
    typeset -A _mcm_kv
    typeset -a _mcm_unknown _mcm_raw _mcm_malformed
    file="$(mcm_state_file)" || return 1
    # Best effort: a missing file reads as the defaults (mode off) anyway, and every
    # load would otherwise repeat the failure. Explicit writes still report it.
    mcm_ensure_state_file 2>/dev/null || true
    _mcm_parse_state "${file}" || return 1
    if [[ "${_mcm_kv[MULTI_CLUSTER_MANAGEMENT]-}" == false ]]; then
        _mcm_soften_state "${file}"
    else
        if (( ${#_mcm_malformed} )); then
            _mcm_err "${file}: ${_mcm_malformed[1]}"
            return 1
        fi
        _mcm_validate_state "${file}" || return 1
    fi
    for key in "${_MCM_STATE_KEYS[@]}"; do
        typeset -g +x "${key}=${_mcm_kv[$key]-}"
    done
    return 0
}

mcm_write_state() {
    emulate -L zsh
    local file kv key value
    typeset -A _mcm_kv
    typeset -a _mcm_unknown _mcm_raw
    file="$(mcm_state_file)" || return 1
    mcm_ensure_state_file || return 1
    _mcm_parse_state "${file}" || return 1
    for kv in "$@"; do
        if [[ "${kv}" != *=* ]]; then
            _mcm_err "mcm_write_state: expected KEY=VALUE, got '${kv}'"
            return 1
        fi
        key="${kv%%=*}"
        value="${kv#*=}"
        if [[ "${key}" != [A-Za-z_]* || "${key}" == *[^A-Za-z0-9_]* ]]; then
            _mcm_err "mcm_write_state: invalid key name '${key}'"
            return 1
        fi
        if [[ "${value}" == *[\"$'\n']* ]]; then
            _mcm_err "mcm_write_state: ${key}: value may not contain a double quote or a newline"
            return 1
        fi
        if (( ! ${_MCM_STATE_KEYS[(Ie)${key}]} && ! ${_mcm_unknown[(Ie)${key}]} )); then
            _mcm_unknown+=("${key}")
        fi
        _mcm_kv[$key]="${value}"
    done
    _mcm_validate_state "${file}" || return 1
    _mcm_write_rendered "${file}" || return 1
    mcm_load_state
}

# 0 on, 1 off, 2 when the state file is invalid (the error is already printed).
mcm_is_on() {
    emulate -L zsh
    mcm_load_state || return 2
    [[ "${MULTI_CLUSTER_MANAGEMENT}" == true ]]
}

# =============================================================================
# Registration
# =============================================================================
_mcm_marker_value() {   # FILE KEY
    emulate -L zsh
    local file="$1" key="$2" line
    [[ -f "${file}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" == ${key}=\"*\" ]]; then
            line="${line#*=\"}"
            print -r -- "${line%\"}"
            return 0
        fi
    done < "${file}"
    return 0
}

# The key two OCP URLs are compared by: "host:port", lowercase, with the scheme,
# userinfo, path, query, fragment and trailing dots of the host dropped and the port
# defaulting to 6443 (the OpenShift API port). So api.x:6443, https://api.x and
# https://api.x.:6443// are one cluster. Prints nothing when there is no host.
# Python twin: multi_cluster_state.url_key (compared by tests/test_mcm_state.py).
_mcm_url_key() {
    emulate -L zsh -o extended_glob
    local url="${1:-}" host port rest
    url="${(L)${${url##[[:space:]]#}%%[[:space:]]#}}"
    url="${url#[a-z][a-z0-9+.-]#://}"
    url="${url%%[/?#]*}"
    url="${url##*@}"
    if [[ "${url}" == \[* ]]; then
        host="${url%%\]*}]"
        rest="${url#*\]}"
        port=""
        [[ "${url}" == *\]* && "${rest}" == :* ]] && port="${rest#:}"
    else
        host="${url%%:*}"
        port=""
        [[ "${url}" == *:* ]] && port="${url#*:}"
    fi
    host="${host%%.##}"
    [[ -n "${host}" && "${host}" != "[]" ]] || return 0
    print -r -- "${host}:${port:-6443}"
}

# FROM as a whole path, in a text file: rewritten to TO unless the next character could
# continue the folder name, so a sibling such as FROM-dr/ is not touched. The file is
# replaced in one rename and keeps its mode; a file without FROM is not rewritten. Used by
# multi_cluster.sh rename/add --copy-from and migrate_to_multi_cluster.sh. The caller
# keeps binary files away: the read stops at the first NUL byte.
mcm_replace_path_in_file() {   # FILE FROM TO
    emulate -L zsh
    local file="$1" from="$2" to="$3" text="" rest="" new="" before after tmp
    IFS= read -rd '' text < "${file}" || true
    rest="${text}"
    while [[ "${rest}" == *"${from}"* ]]; do
        before="${rest%%${(b)from}*}"
        after="${rest#*${(b)from}}"
        if [[ "${after}" == [[:alnum:]._-]* ]]; then
            new+="${before}${from}"
        else
            new+="${before}${to}"
        fi
        rest="${after}"
    done
    new+="${rest}"
    [[ "${new}" != "${text}" ]] || return 0
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    if ! cp -p "${file}" "${tmp}" || ! print -rn -- "${new}" > "${tmp}" || ! mv -f "${tmp}" "${file}"; then
        rm -f "${tmp}"
        return 1
    fi
    return 0
}

mcm_is_registered() {
    emulate -L zsh
    local name="${1:-}"
    local IFS=$' \t\n'
    local -a list
    mcm_load_state || return 1
    list=(${=MCM_CLUSTERS})
    (( ${list[(Ie)${name}]} ))
}

# ---- delineation (one-way per cluster) -------------------------------------
# A cluster folder with a .cluster marker is delineated for good: it never goes back
# to the flat layout. Every marker counts, also one without DELINEATED (written before
# the field existed) and a retired one. RETIRED="true" means unregistered on purpose
# (multi_cluster.sh remove without --purge): still delineated, not targetable, and
# left out when MCM_CLUSTERS is rebuilt. Only remove --purge deletes the marker.

_MCM_MARKER_HEADER="# Multi-cluster management marker: this folder is a delineated cluster. Delineation is
# one-way: this cluster never goes back to the flat configs/ layout."

# Writes the marker: the known fields in a fixed order, then any other KEY=\"value\"
# lines the old marker had. RETIRED is written only when true.
_mcm_write_marker() {   # FILE NAME URL CREATED RETIRED
    emulate -L zsh
    local file="$1" name="$2" url="$3" created="$4" retired="$5" line tmp
    local -a body kept
    if [[ -f "${file}" ]]; then
        for line in "${(@f)$(<"${file}")}"; do
            [[ "${line}" == [A-Za-z_]*=\"*\" ]] || continue
            case "${line%%=*}" in
                NAME|OCP_URL|CREATED|DELINEATED|RETIRED) ;;
                *) kept+=("${line}") ;;
            esac
        done
    fi
    body=("${_MCM_MARKER_HEADER}" "NAME=\"${name}\"" "OCP_URL=\"${url}\"" "CREATED=\"${created}\"" 'DELINEATED="true"')
    [[ "${retired}" == true ]] && body+=('RETIRED="true"')
    body+=("${kept[@]}")
    if ! tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)"; then
        _mcm_err "Cannot write ${file}"
        return 1
    fi
    if print -rl -- "${body[@]}" > "${tmp}" && chmod 644 "${tmp}" && mv -f "${tmp}" "${file}"; then
        return 0
    fi
    rm -f "${tmp}"
    _mcm_err "Cannot write ${file}"
    return 1
}

# 0 when NAME has a .cluster marker (retired included). No message.
mcm_is_delineated() {
    emulate -L zsh
    local name="${1:-}" root
    _mcm_name_ok "${name}" || return 1
    root="$(mcm_clusters_root)" || return 1
    [[ -f "${root}/${name}/.cluster" ]]
}

# 0 when NAME is delineated and its marker says RETIRED="true".
mcm_is_retired() {
    emulate -L zsh
    local name="${1:-}" root
    mcm_is_delineated "${name}" || return 1
    root="$(mcm_clusters_root)" || return 1
    [[ "$(_mcm_marker_value "${root}/${name}/.cluster" RETIRED)" == true ]]
}

# Delineated clusters, space separated, in byte order. --exclude-retired leaves the
# retired ones out.
mcm_delineated_clusters() {
    emulate -L zsh
    local LC_ALL=C marker root name
    local -i active_only=0
    local -a names
    case "${1:-}" in
        "") ;;
        --exclude-retired) active_only=1 ;;
        *)
            _mcm_err "mcm_delineated_clusters: unknown option '$1'"
            return 1
            ;;
    esac
    root="$(mcm_clusters_root)" || return 1
    for marker in "${root}"/*/.cluster(N.); do
        name="${marker:h:t}"
        _mcm_name_ok "${name}" || continue
        if (( active_only )) && [[ "$(_mcm_marker_value "${marker}" RETIRED)" == true ]]; then
            continue
        fi
        names+=("${name}")
    done
    print -r -- "${(j: :)${(@o)names}}"
}

# The delineated cluster that owns URL: the first (byte order) whose marker holds that
# URL (compared by _mcm_url_key), else the name derived from URL when that name has a
# marker with no URL recorded. A marker with another URL is another cluster whose URL
# derives the same name (ROKS hosts such as c100-e.<region>...). Retired clusters
# count. Prints nothing when none owns it; always returns 0.
mcm_cluster_for_url() {
    emulate -L zsh
    local LC_ALL=C url="${1:-}" key root marker name
    [[ -n "${url}" ]] || return 0
    root="$(mcm_clusters_root)" || return 0
    key="$(_mcm_url_key "${url}")"
    [[ -n "${key}" ]] || return 0
    for marker in "${root}"/*/.cluster(N.); do
        name="${marker:h:t}"
        _mcm_name_ok "${name}" || continue
        if [[ "$(_mcm_url_key "$(_mcm_marker_value "${marker}" OCP_URL)")" == "${key}" ]]; then
            print -r -- "${name}"
            return 0
        fi
    done
    name="$(mcm_name_from_url "${url}" 2>/dev/null)" || return 0
    if [[ -f "${root}/${name}/.cluster" && -z "$(_mcm_url_key "$(_mcm_marker_value "${root}/${name}/.cluster" OCP_URL)")" ]]; then
        print -r -- "${name}"
    fi
    return 0
}

# Sets RETIRED on a delineated cluster's marker (true) or clears it (false). The state
# file is not touched: the caller unregisters or registers.
_mcm_set_retired() {   # NAME true|false
    emulate -L zsh
    local name="$1" want="$2" root marker current
    mcm_validate_name "${name}" || return 1
    root="$(mcm_cluster_root "${name}")" || return 1
    marker="${root}/.cluster"
    if [[ ! -f "${marker}" ]]; then
        _mcm_err "Cluster '${name}' is not delineated: ${marker} does not exist."
        return 1
    fi
    current="$(_mcm_marker_value "${marker}" RETIRED)"
    if [[ "${current:-false}" == "${want}" && "$(_mcm_marker_value "${marker}" DELINEATED)" == true ]]; then
        return 0
    fi
    _mcm_write_marker "${marker}" "${name}" "$(_mcm_marker_value "${marker}" OCP_URL)" \
        "$(_mcm_marker_value "${marker}" CREATED)" "${want}"
}

# multi_cluster.sh remove without --purge: the cluster stays delineated, but is no
# longer rebuilt into MCM_CLUSTERS. Only the marker changes.
mcm_mark_retired() {
    _mcm_set_retired "${1:-}" true
}

# Undoes mcm_mark_retired. Only the marker changes; mcm_register also unretires.
mcm_unretire() {
    _mcm_set_retired "${1:-}" false
}

mcm_register() {
    emulate -L zsh
    local name="${1:-}" url="${2:-}" cluster_root clusters_root marker old_url created other other_url key
    local IFS=$' \t\n'
    local -a list
    mcm_validate_name "${name}" || return 1
    if [[ "${url}" == *[\"$'\n']* ]]; then
        _mcm_err "mcm_register: the URL may not contain a double quote or a newline"
        return 1
    fi
    mcm_load_state || return 1
    cluster_root="$(mcm_cluster_root "${name}")" || return 1
    clusters_root="$(mcm_clusters_root)" || return 1
    if ! mkdir -p "${cluster_root}"; then
        _mcm_err "Cannot create ${cluster_root}"
        return 1
    fi

    # Registering makes the cluster targetable, so a retired one is unretired.
    marker="${cluster_root}/.cluster"
    old_url="$(_mcm_marker_value "${marker}" OCP_URL)"
    [[ -n "${url}" ]] || url="${old_url}"
    if [[ ! -f "${marker}" || "${url}" != "${old_url}" ]] \
        || [[ "$(_mcm_marker_value "${marker}" DELINEATED)" != true || -n "$(_mcm_marker_value "${marker}" RETIRED)" ]]; then
        created="$(_mcm_marker_value "${marker}" CREATED)"
        [[ -n "${created}" ]] || created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _mcm_write_marker "${marker}" "${name}" "${url}" "${created}" false || return 1
    fi

    key="$(_mcm_url_key "${url}")"
    if [[ -n "${key}" ]]; then
        for other in "${clusters_root}"/*/.cluster(N.); do
            [[ "${other:h:t}" != "${name}" ]] || continue
            other_url="$(_mcm_marker_value "${other}" OCP_URL)"
            if [[ "$(_mcm_url_key "${other_url}")" == "${key}" ]]; then
                _mcm_warn "Clusters '${other:h:t}' and '${name}' point at the same URL (${url})."
            fi
        done
    fi

    list=(${=MCM_CLUSTERS})
    if (( ! ${list[(Ie)${name}]} )); then
        list+=("${name}")
        mcm_write_state "MCM_CLUSTERS=${(j: :)list}" || return 1
    fi
    return 0
}

mcm_set_current() {
    emulate -L zsh
    local name="${1:-}" rc=0
    mcm_validate_name "${name}" || return 1
    mcm_is_registered "${name}" || rc=$?
    if (( rc != 0 )); then
        _mcm_err "Cluster '${name}' is not registered. Registered: ${MCM_CLUSTERS:-none}. Add it with multi_cluster.sh add ${name}."
        return 1
    fi
    mcm_write_state "MCM_CURRENT_CLUSTER=${name}"
}

# For scripts that do not load a config (generators and the like).
mcm_resolve_configs_root() {
    emulate -L zsh
    local name="${1:-}" repo
    local IFS=$' \t\n'
    local -a list
    if [[ -n "${name}" ]]; then
        mcm_cluster_root "${name}"
        return $?
    fi
    mcm_load_state || return 1
    if [[ "${MULTI_CLUSTER_MANAGEMENT}" != true ]]; then
        # A pin to a delineated cluster holds whatever the flag says (it never goes flat).
        if [[ -n "${MCM_CLUSTER:-}" ]] && mcm_is_delineated "${MCM_CLUSTER}"; then
            if mcm_is_retired "${MCM_CLUSTER}"; then
                _mcm_err "Cluster '${MCM_CLUSTER}' (MCM_CLUSTER) is retired. Add it back with multi_cluster.sh add ${MCM_CLUSTER}, or unset MCM_CLUSTER."
                return 1
            fi
            mcm_cluster_root "${MCM_CLUSTER}"
            return $?
        fi
        repo="$(mcm_repo_root)" || return 1
        print -r -- "${repo}/configs"
        return 0
    fi
    name="${MCM_CLUSTER:-${MCM_CURRENT_CLUSTER}}"
    if [[ -z "${name}" ]]; then
        list=(${=MCM_CLUSTERS})
        if (( ${#list} == 1 )); then
            name="${list[1]}"
        fi
    fi
    if [[ -z "${name}" ]]; then
        _mcm_err "Multi-cluster mode is on but no cluster is selected. Registered: ${MCM_CLUSTERS:-none}."
        _mcm_err "Pick one with --target-cluster NAME, MCM_CLUSTER=NAME or multi_cluster.sh use NAME."
        return 1
    fi
    mcm_cluster_root "${name}"
}

# The flat configs folder, for a script that loads no config and has found the mode
# off. CONFIGS_ROOT counts only inside this checkout's configs/ and outside its cluster
# folders: a shell loaded from another checkout, or still pinned to a cluster, exports
# somewhere else.
mcm_flat_configs_root() {
    emulate -L zsh
    local repo configs given
    repo="$(mcm_repo_root)" || return 1
    configs="${repo}/configs"
    given="${CONFIGS_ROOT:-}"
    if [[ -n "${given}" && ( "${given:A}" == "${configs:A}" || "${given:A}" == "${configs:A}"/* ) \
        && "${given:A}" != "${configs:A}/clusters" && "${given:A}" != "${configs:A}/clusters"/* ]]; then
        print -r -- "${given}"
    else
        print -r -- "${configs}"
    fi
}

# =============================================================================
# Which clusters a run targets (plan 5.4) and its per-cluster environment (5.5)
# =============================================================================
# Exit code of a run on a cluster that has no config for the script's product. Inside
# a fan-out only the fanned-out script's own first config load may report "skipped"
# (nothing has run yet). A nested step exits 1 instead, or a partly executed run would
# be reported as skipped. _MCM_FANOUT_SCRIPT holds that script until its config is
# loaded, then the word "loaded" (source_env_setup.sh).
MCM_SKIP_EXIT_CODE=75
if [[ -n "${_MCM_FANOUT_SCRIPT:-}" && "${ZSH_ARGZERO:A}" != "${_MCM_FANOUT_SCRIPT}" ]]; then
    MCM_SKIP_EXIT_CODE=1
fi

typeset -ga _MCM_ARGV=() _MCM_ARG_TARGETS=() _MCM_RESOLVED=()
typeset -g _MCM_ARG_ALL=0 _MCM_ARG_LIST=0 _MCM_ARG_YES_ALL=0 _MCM_RESOLVED_FROM="" _MCM_TARGET_WHY="" _MCM_PIN_NOTE=""

# Removes --target-cluster, --target-clusters, --all-clusters and --yes-all-clusters
# from the arguments. --yes-all-clusters only answers the fan-out's confirmation, so
# it means nothing on a single-cluster run and is simply dropped there.
# The rest land in _MCM_ARGV (spaces and empty values intact), so the
# caller does:   mcm_take_target_flags "$@" || <fail>; set -- "${_MCM_ARGV[@]}"
# Flags add to what an earlier call took, because oadp_br_helpers.sh and the mirror
# guard run ahead of env_bootstrap.sh.
mcm_take_target_flags() {
    emulate -L zsh
    local flag value
    local -a names
    _MCM_ARGV=()
    while (( $# )); do
        flag="$1"
        case "${flag}" in
            --all-clusters)
                _MCM_ARG_ALL=1
                shift
                continue
                ;;
            --yes-all-clusters)
                _MCM_ARG_YES_ALL=1
                shift
                continue
                ;;
            --target-cluster=*|--target-clusters=*)
                value="${flag#*=}"
                flag="${flag%%=*}"
                shift
                ;;
            --target-cluster|--target-clusters)
                value="${2:-}"
                (( $# >= 2 )) && shift 2 || shift
                ;;
            *)
                _MCM_ARGV+=("${flag}")
                shift
                continue
                ;;
        esac
        names=(${(s:,:)${value// /,}})
        if (( ! ${#names} )); then
            _mcm_err "${flag} needs a cluster name."
            return 1
        fi
        if [[ "${flag}" == --target-cluster ]] && (( ${#names} > 1 )); then
            _mcm_err "--target-cluster takes one name (got '${value}'); use --target-clusters a,b for several."
            return 1
        fi
        [[ "${flag}" == --target-clusters ]] && _MCM_ARG_LIST=1
        _MCM_ARG_TARGETS+=("${names[@]}")
    done
    if (( _MCM_ARG_ALL && ${#_MCM_ARG_TARGETS} )); then
        _mcm_err "--all-clusters cannot be combined with --target-cluster or --target-clusters."
        return 1
    fi
    return 0
}

mcm_clear_target_flags() {
    _MCM_ARG_TARGETS=()
    _MCM_ARG_ALL=0
    _MCM_ARG_LIST=0
    _MCM_ARG_YES_ALL=0
}

_mcm_no_selection_error() {
    _mcm_err "Multi-cluster mode is on but no cluster is selected. Registered: ${MCM_CLUSTERS:-none}."
    _mcm_err "Pick one with --target-cluster NAME, MCM_CLUSTER=NAME or multi_cluster.sh use NAME."
}

# Mode off: what an explicit name may pick. Sets list and from in the caller (or
# leaves list empty for the flat layout). Only delineated clusters can be named, since
# a cluster that is set up per cluster stays that way for good; the state file's
# selection (MCM_TARGET_CLUSTERS, APPLY_TO_ALL, MCM_CURRENT_CLUSTER) applies only while
# the mode is on. An MCM_CLUSTER that names no delineated cluster is a stale pin, which
# _mcm_env_setup drops as before.
_mcm_resolve_mode_off() {
    emulate -L zsh
    local IFS=$' \t\n' name delineated
    local -a active registered
    delineated="$(mcm_delineated_clusters)" || return 1
    if (( _MCM_ARG_ALL || ${#_MCM_ARG_TARGETS} )) && [[ -z "${delineated}" ]]; then
        _mcm_err "--target-cluster, --target-clusters and --all-clusters need multi-cluster mode, which is off."
        _mcm_err "Turn it on with src/utilities/multi_cluster_management_utils/multi_cluster.sh on."
        return 1
    fi
    active=(${=$(mcm_delineated_clusters --exclude-retired)})
    registered=(${=MCM_CLUSTERS})
    if (( _MCM_ARG_ALL )); then
        list=("${(@)registered:*active}")
        from=flag
        if (( ! ${#list} )); then
            _mcm_err "--all-clusters: no registered cluster is delineated (registered: ${MCM_CLUSTERS:-none}; delineated: ${delineated})."
            _mcm_err "Multi-cluster mode is off, so --all-clusters covers only registered clusters under configs/clusters/."
            return 1
        fi
        return 0
    elif (( ${#_MCM_ARG_TARGETS} )); then
        list=("${_MCM_ARG_TARGETS[@]}")
        from=flag
    elif [[ -n "${MCM_CLUSTER:-}" ]] && mcm_is_delineated "${MCM_CLUSTER}"; then
        list=("${MCM_CLUSTER}")
        from=pin
    else
        return 0
    fi
    for name in "${list[@]}"; do
        if ! mcm_is_delineated "${name}"; then
            _mcm_err "Cluster '${name}' is not delineated (no configs/clusters/${name}/.cluster), and multi-cluster mode is off."
            _mcm_err "Delineated clusters: ${delineated}. Pick one of those, or turn the mode on with src/utilities/multi_cluster_management_utils/multi_cluster.sh on."
            return 1
        fi
        if mcm_is_retired "${name}"; then
            _mcm_err "Cluster '${name}' is retired (removed from the registered clusters; its folder stays delineated)."
            _mcm_err "Add it back with src/utilities/multi_cluster_management_utils/multi_cluster.sh add ${name}${${(M)from:#pin}:+, or unset MCM_CLUSTER in this shell}."
            return 1
        fi
    done
    return 0
}

# Table 5.4. Sets _MCM_RESOLVED and _MCM_RESOLVED_FROM (flag, pin, targets, all,
# current, only, url) and prints the names space separated. Mode off: only an explicit
# name of a delineated cluster resolves (_mcm_resolve_mode_off); anything else prints
# nothing and leaves the list empty, the flat layout.
mcm_resolve_targets() {
    emulate -L zsh
    local IFS=$' \t\n' name from="" root
    local -a list registered
    _MCM_RESOLVED=()
    _MCM_RESOLVED_FROM=""
    mcm_load_state || return 1
    registered=(${=MCM_CLUSTERS})
    if [[ "${MULTI_CLUSTER_MANAGEMENT}" != true ]]; then
        _mcm_resolve_mode_off || return 1
        (( ${#list} )) || return 0
    elif (( _MCM_ARG_ALL )); then
        list=("${registered[@]}")
        from=flag
    elif (( ${#_MCM_ARG_TARGETS} )); then
        list=("${_MCM_ARG_TARGETS[@]}")
        from=flag
    elif [[ -n "${MCM_CLUSTER:-}" ]]; then
        list=("${MCM_CLUSTER}")
        from=pin
    elif [[ -n "${MCM_TARGET_CLUSTERS}" ]]; then
        list=(${=MCM_TARGET_CLUSTERS})
        from=targets
    elif [[ "${APPLY_TO_ALL}" == true ]]; then
        list=("${registered[@]}")
        from=all
    elif [[ -n "${MCM_CURRENT_CLUSTER}" ]]; then
        list=("${MCM_CURRENT_CLUSTER}")
        from=current
    elif (( ${#registered} == 1 )); then
        list=("${registered[1]}")
        from=only
    elif [[ -n "${OCP_URL:-}" ]] && name="$(mcm_name_from_url "${OCP_URL}" 2>/dev/null)" \
        && (( ${registered[(Ie)${name}]} )); then
        list=("${name}")
        from=url
    else
        _mcm_no_selection_error
        return 1
    fi

    list=("${(@u)list}")
    if (( ! ${#list} )); then
        _mcm_err "No cluster to run on: none is registered. Add one with src/utilities/multi_cluster_management_utils/multi_cluster.sh add NAME."
        return 1
    fi
    for name in "${list[@]}"; do
        root="$(mcm_cluster_root "${name}")" || return 1
        if [[ ! -d "${root}" ]]; then
            _mcm_err "Cluster '${name}' has no folder: ${root}"
            _mcm_err "Create it with src/utilities/multi_cluster_management_utils/multi_cluster.sh add ${name}, or pick another. Registered: ${MCM_CLUSTERS:-none}."
            return 1
        fi
        if (( ! ${registered[(Ie)${name}]} )); then
            # A list runs on each name unattended, so a removed cluster must not stay
            # in it, as "multi_cluster.sh targets" refuses. One explicit pin stays allowed.
            if [[ "${from}" == targets ]] || (( _MCM_ARG_LIST || ${#list} > 1 )); then
                _mcm_err "Cluster '${name}' is in the target list but is not registered. Registered: ${MCM_CLUSTERS:-none}."
                _mcm_err "Take it off the list, or add it with src/utilities/multi_cluster_management_utils/multi_cluster.sh add ${name}."
                return 1
            fi
            if mcm_is_retired "${name}"; then
                _mcm_warn "Cluster '${name}' is retired: it has a folder but is not registered (registered: ${MCM_CLUSTERS:-none})."
            else
                _mcm_warn "Cluster '${name}' has a folder but is not registered (registered: ${MCM_CLUSTERS:-none})."
            fi
        fi
    done
    _MCM_RESOLVED=("${list[@]}")
    _MCM_RESOLVED_FROM="${from}"
    print -r -- "${(j: :)list}"
}

# Narrows _MCM_RESOLVED to one cluster for loads that cannot run per cluster: the
# current cluster when it is among the targets, else an error with guidance.
_mcm_narrow_to_one() {
    emulate -L zsh
    (( ${#_MCM_RESOLVED} > 1 )) || return 0
    # The current cluster is state-file selection, which counts only while the mode is on.
    if [[ "${MULTI_CLUSTER_MANAGEMENT}" == true ]] && (( ${_MCM_RESOLVED[(Ie)${MCM_CURRENT_CLUSTER}]} )); then
        _MCM_RESOLVED=("${MCM_CURRENT_CLUSTER}")
        _MCM_RESOLVED_FROM=current
        return 0
    fi
    _mcm_err "This load runs on one cluster, but the targets are: ${_MCM_RESOLVED[*]}."
    _mcm_err "Pick one with --target-cluster NAME, or set the current cluster with multi_cluster.sh use NAME."
    return 1
}

# For scripts that are not fanned out and may be sourced (nothing is exported).
# Prints one cluster name; empty when the mode is off.
mcm_resolve_one() {
    emulate -L zsh
    mcm_resolve_targets >/dev/null || return 1
    (( ${#_MCM_RESOLVED} )) || return 0
    _mcm_narrow_to_one || return 1
    print -r -- "${_MCM_RESOLVED[1]}"
}

# Base olm-utils container name plus the cluster suffix. A given cluster's name
# even while OLM_UTILS_CONTAINER holds another's.
mcm_container_name() {
    local OLM_UTILS_CONTAINER=""
    print -r -- "${OLM_UTILS_CONTAINER:-olm-utils-play-v4}${1:+-$1}"
}

# Registry root -> folder name below registry_mirror_workspace/registries/. A colon
# would break the podman -v mounts of the workspace and '/' would add a folder
# level. '+' cannot occur in a registry name, so '/' -> '+' keeps two roots that
# differ only by '_' and '/' apart.
mcm_mirror_destination_key() {
    emulate -L zsh -o extended_glob
    local root="${(L)${1%/}}"
    if [[ -z "${root}" ]]; then
        _mcm_err "mcm_mirror_destination_key: empty registry root."
        return 1
    fi
    root="${root//:/_}"
    root="${root//\//+}"
    print -r -- "${root//[^a-z0-9._+-]/_}"
}

# Darwin only, like the start-up check in env_bootstrap.sh: 0 when the podman
# machine is stopped, or reports running while its API socket is dead.
mcm_podman_machine_needs_prep() {
    [[ "$(uname -s)" == "Darwin" ]] || return 1
    local state
    state="$(podman machine inspect --format '{{.State}}' 2>/dev/null || true)"
    [[ "${state}" == running ]] || return 0
    podman info >/dev/null 2>&1 && return 1
    return 0
}

_mcm_shim_dir() {
    local repo
    repo="$(mcm_repo_root)" || return 1
    print -r -- "${repo}/src/helpers/multi_cluster_bin"
}

# Puts the cpd-cli shim first on PATH and points CPD_CLI at it (source_env_setup.sh,
# after CPD_CLI_HOME has gone on PATH). The shim has no .sh suffix, so
# 0.0_make_executable.sh would miss it; an unexecutable shim would be skipped by
# PATH lookup and cpd-cli would run with the real HOME.
mcm_activate_shim() {
    emulate -L zsh
    local dir
    dir="$(_mcm_shim_dir)" || return 1
    [[ -x "${dir}/cpd-cli" ]] || chmod +x "${dir}/cpd-cli"
    path=("${dir}" "${(@)path:#${dir}}")
    export CPD_CLI="${dir}/cpd-cli"
}

# Lists what a config load exported, so a later switch to another cluster can
# unset exactly those names. source_env_setup.sh brackets its config loading with
# the snapshot and the record. A load with no pin (mode off) is recorded too, in a
# plain global that adds nothing to the exported environment: the mode can come on
# later in the same shell, and the first pin must then drop the flat values.
_mcm_exported_names() {
    zmodload zsh/parameter 2>/dev/null
    reply=("${(@k)parameters[(R)*export*]}")
}

mcm_snapshot_exports() {
    local -a reply
    _mcm_exported_names
    typeset -ga _MCM_EXPORTS_BEFORE=("${reply[@]}")
}

mcm_record_config_exports() {
    emulate -L zsh
    local -a reply added kept
    local name IFS=$' \t\n'
    _mcm_exported_names
    added=("${(@)reply:|_MCM_EXPORTS_BEFORE}")
    for name in "${added[@]}"; do
        case "${name}" in
            ENV_TARGET|MCM_*|_MCM_*|_CP4D_*) ;;
            *) kept+=("${name}") ;;
        esac
    done
    if [[ -z "${MCM_CLUSTER:-}" ]]; then
        kept+=(${=_MCM_FLAT_CONFIG_VARS:-})
        kept=("${(@u)kept}")
        typeset -g +x _MCM_FLAT_CONFIG_VARS="${kept[*]}"
        return 0
    fi
    if [[ "${MCM_LOADED_CONFIG_CLUSTER:-}" == "${MCM_CLUSTER:-}" ]]; then
        kept+=(${=MCM_LOADED_CONFIG_VARS:-})
    fi
    kept=("${(@u)kept}")
    export MCM_LOADED_CONFIG_VARS="${kept[*]}"
    export MCM_LOADED_CONFIG_CLUSTER="${MCM_CLUSTER:-}"
}

_mcm_forget_names() {
    emulate -L zsh
    local _mcm_forget_item
    for _mcm_forget_item in "$@"; do
        if [[ "${_mcm_forget_item}" == [A-Za-z_]* && "${_mcm_forget_item}" != *[^A-Za-z0-9_]* ]]; then
            unset "${_mcm_forget_item}"
        fi
    done
}

_mcm_forget_loaded_config() {
    emulate -L zsh
    local IFS=$' \t\n'
    _mcm_forget_names ${=MCM_LOADED_CONFIG_VARS:-} OC_LOGIN_FORCE CPDM_OC_LOGIN_FORCE
    unset MCM_LOADED_CONFIG_VARS MCM_LOADED_CONFIG_CLUSTER
}

# Names the flat-layout config files export, read from the files source_env_setup.sh
# would load (one per line). For a process that cannot see the record of the flat load
# in its parent shell. Names that are not the config's to own are left out.
_mcm_flat_config_names() {
    emulate -L zsh -o extended_glob
    local repo file line name
    repo="$(mcm_repo_root)" || return 0
    for file in "${repo}"/configs/*/*.sh(N.) "${repo}"/configs/cp4d_config/*/*.sh(N.) \
        "${repo}"/configs/*/managed-service-instances/*/*.sh(N.); do
        [[ "${file:t}" == (*_vars.sh|*_instance_details.sh|registry_overrides.sh) ]] || continue
        for line in "${(@f)$(<"${file}")}"; do
            [[ "${line}" == (#b)[[:space:]]#(export|typeset[[:space:]]##-x|declare[[:space:]]##-x)[[:space:]]##([A-Za-z_][A-Za-z0-9_]#)(|=*|[[:space:]]*) ]] || continue
            name="${match[2]}"
            case "${name}" in
                PATH|HOME|USER|LOGNAME|SHELL|TERM|TMPDIR|PWD|OLDPWD|LANG|LC_*|ZDOTDIR|ENV_TARGET|MCM_*|_MCM_*|_CP4D_*) continue ;;
                KUBECONFIG) [[ -n "${MCM_KUBECONFIG_OVERRIDE:-}" ]] && continue ;;
            esac
            print -r -- "${name}"
        done
    done
    return 0
}

# The first pin of a process that still holds a flat-layout load. *_FORCE exist only
# after a load, so they also identify a child of a flat shell. That child cannot see
# the parent's record of what the load exported, so it reads the names from the files.
_mcm_forget_flat_config() {
    emulate -L zsh
    local IFS=$' \t\n'
    local -a names
    [[ -n "${_MCM_FLAT_CONFIG_VARS:-}${OC_LOGIN_FORCE:-}${CPDM_OC_LOGIN_FORCE:-}" ]] || return 0
    if [[ -n "${_MCM_FLAT_CONFIG_VARS:-}" ]]; then
        names=(${=_MCM_FLAT_CONFIG_VARS})
    else
        names=("${(@f)$(_mcm_flat_config_names)}")
    fi
    _mcm_forget_names "${names[@]}" OCP_URL OC_LOGIN CPDM_OC_LOGIN OC_LOGIN_FORCE CPDM_OC_LOGIN_FORCE
    unset _MCM_FLAT_CONFIG_VARS
}

# A flat load (no pin) must not reach a delineated cluster: that cluster's config lives
# in its folder, and one cluster never has two configs. 1, with guidance on stderr, when
# URL belongs to a delineated cluster (mcm_cluster_for_url); FILES are the flat files
# that set it, for the message. 0 otherwise, silently.
mcm_flat_config_conflict() {   # URL [FILE...]
    emulate -L zsh
    local url="${1:-}" name root repo file
    local -a shown
    shift
    [[ -n "${url}" ]] || return 0
    name="$(mcm_cluster_for_url "${url}")"
    [[ -n "${name}" ]] || return 0
    root="$(mcm_cluster_root "${name}")" || return 0
    repo="$(mcm_repo_root)" || repo=""
    for file in "$@"; do
        shown+=("${file#${repo}/}")
    done
    _mcm_err "This flat config points at ${url}, which belongs to the delineated cluster '${name}' (${root#${repo}/}/)."
    (( ${#shown} )) && _mcm_err "Flat file(s): ${(j:, :)shown}"
    _mcm_err "A delineated cluster is managed from its own folder for good, so a second, flat config for it is not loaded."
    if mcm_is_retired "${name}"; then
        _mcm_err "'${name}' is retired: add it back with src/utilities/multi_cluster_management_utils/multi_cluster.sh add ${name}, then run with --target-cluster ${name}."
    else
        _mcm_err "Run with --target-cluster ${name} (source s_env.sh ... --target-cluster ${name} in a shell), and edit the config in ${root#${repo}/}/."
    fi
    _mcm_err "If the flat file is an old copy, move it to configs/old_configs/ so flat runs stop picking it up."
    return 1
}

# 0 when ENV_TARGET resolves under cluster folder ROOT, by the lookup source_env_setup.sh does.
_mcm_target_config_exists() {
    emulate -L zsh
    local root="$1" folder
    [[ -z "${ENV_TARGET:-}" || "${ENV_TARGET}" == all || -f "${ENV_TARGET}" ]] && return 0
    for folder in "${root}"/*(N/) "${root}/cp4d_config"/*(N/); do
        [[ -f "${folder}/${ENV_TARGET}_vars.sh" || -f "${folder}/${ENV_TARGET}" ]] && return 0
    done
    return 1
}

# 0 when ENV_TARGET is a file outside cluster folder ROOT. A bare name resolves inside
# it. MIRROR_CONFIG_FILE is the mirror track's documented way to keep its file elsewhere.
_mcm_env_target_elsewhere() {   # ROOT
    emulate -L zsh
    [[ -n "${ENV_TARGET:-}" && "${ENV_TARGET}" != all && -f "${ENV_TARGET}" ]] || return 1
    [[ "${ENV_TARGET:A}" != "${1:A}"/* ]] || return 1
    [[ "${ENV_TARGET}" != "${MIRROR_CONFIG_FILE:-}" ]]
}

# Mode off in a shell or process that still carries a pin.
_mcm_forget_pin() {
    emulate -L zsh
    local dir
    _mcm_forget_loaded_config
    if [[ -n "${MCM_CLUSTER_ROOT:-}" && "${KUBECONFIG:-}" == "${MCM_CLUSTER_ROOT}/.home/.kube/config" ]]; then
        unset KUBECONFIG
    fi
    dir="$(_mcm_shim_dir)" || return 1
    path=("${(@)path:#${dir}}")
    unset MCM_CLUSTER MCM_CLUSTER_ROOT MCM_CPD_CLI_WORKSPACE MCM_CONTAINER_SUFFIX \
        OLM_UTILS_CONTAINER CPD_CLI CPD_CLI_WORKSPACE CPDCONFIG SCC_CACHE_ROOT \
        CONCERT_WORKSPACE MC_WORKSPACE KC_WORKSPACE OADP_LOG_DIR \
        MIRROR_BASE MIRROR_WORKSPACE MIRROR_CLUSTER_OUT
}

# First literal OCP_URL in FILE: not empty, not a ${reference}, no quote. Prints nothing when none.
_mcm_config_file_url() {   # FILE
    emulate -L zsh
    local file="${1:-}" line value
    [[ -r "${file}" ]] || return 0
    for line in "${(@f)$(<"${file}")}"; do
        [[ "${line}" =~ "^[[:space:]]*(export[[:space:]]+)?OCP_URL=[\"']?([^\"'[:space:]]*)[\"']?[[:space:]]*(#.*)?$" ]] || continue
        value="${match[2]}"
        [[ -n "${value}" && "${value}" != *\$* ]] || continue
        print -r -- "${value}"
        return 0
    done
    return 0
}

# A cluster folder about to run per cluster with no .cluster marker (made by hand,
# copied in, or registered by editing the state file) gets one, so it counts as
# delineated from now on and the one-way rule covers it once the mode is off. The URL
# comes from the folder's configs, cp4d_config/cpd_vars.sh first.
_mcm_mark_unmarked_folder() {   # NAME ROOT
    emulate -L zsh
    local name="$1" root="$2" file url=""
    [[ ! -f "${root}/.cluster" ]] || return 0
    for file in "${root}/cp4d_config/cpd_vars.sh" "${root}"/*_config/*_vars.sh(N.); do
        url="$(_mcm_config_file_url "${file}")"
        [[ -z "${url}" ]] || break
    done
    _mcm_write_marker "${root}/.cluster" "${name}" "${url}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" false || return 1
    _mcm_warn "Cluster folder configs/clusters/${name}/ had no .cluster marker; it has one now${url:+ (OCP_URL ${url})}. Per-cluster management cannot be undone for '${name}': it never goes back to the flat configs/ layout."
    return 0
}

# Pins this process to one cluster: every value in table 5.5 that is not derived
# later by source_env_setup.sh. Paths already preset by an earlier load (the
# helpers that run before the env load, a previous cluster) are overwritten.
# A folder without a marker gets one (_mcm_mark_unmarked_folder): a pinned run is
# always a delineated cluster's.
mcm_pin() {
    emulate -L zsh
    local name="${1:-}" root cli repo
    root="$(mcm_cluster_root "${name}")" || return 1
    if [[ ! -d "${root}" ]]; then
        _mcm_err "Cluster '${name}' has no folder: ${root}"
        _mcm_err "Create it with src/utilities/multi_cluster_management_utils/multi_cluster.sh add ${name}."
        return 1
    fi
    _mcm_mark_unmarked_folder "${name}" "${root}" || return 1
    cli="$(mcm_cpd_cli_root "${name}")" || return 1
    repo="$(mcm_repo_root)" || return 1
    if ! mkdir -p "${root}/.home/.kube" "${root}/.home/.cpd-cli" "${root}/cpd-cli-workspace" "${cli}" \
        || ! chmod 700 "${root}/.home" "${root}/.home/.kube" "${root}/.home/.cpd-cli"; then
        _mcm_err "Cannot prepare the folders of cluster '${name}'."
        return 1
    fi

    export MCM_CLUSTER="${name}"
    export MCM_CLUSTER_ROOT="${root}"
    export MCM_CPD_CLI_WORKSPACE="${cli}"
    export MCM_CONTAINER_SUFFIX="-${name}"
    export CPD_CLI_WORKSPACE="${root}/cpd-cli-workspace"
    export CPDCONFIG="${root}/.home/.cpd-cli/config"
    export CONCERT_WORKSPACE="${root}/concert_workspace"
    export MC_WORKSPACE="${root}/datastax_mc_workspace"
    export KC_WORKSPACE="${root}/kubecost_workspace"
    export OADP_LOG_DIR="${root}/cpd-cli-workspace/oadp"
    export MIRROR_CLUSTER_OUT="${root}/registry_mirror_cluster"
    # Content-addressed, so it stays shared across clusters.
    export SCC_CACHE_ROOT="${repo}/cpd-cli-workspace/scale_config_cache"
    # OADP restore steps run against a target's own kubeconfig and keep it (plan 5.5).
    if [[ -z "${MCM_KUBECONFIG_OVERRIDE:-}" ]]; then
        export KUBECONFIG="${root}/.home/.kube/config"
    fi
}

# What the env summary says about the pin.
_mcm_describe_pin() {
    emulate -L zsh
    local name="$1"
    _MCM_PIN_NOTE=""
    case "${_MCM_RESOLVED_FROM}" in
        flag)    _MCM_TARGET_WHY="--target-cluster" ;;
        pin)     _MCM_TARGET_WHY="MCM_CLUSTER" ;;
        targets) _MCM_TARGET_WHY="MCM_TARGET_CLUSTERS" ;;
        all)     _MCM_TARGET_WHY="APPLY_TO_ALL" ;;
        current) _MCM_TARGET_WHY="current cluster" ;;
        only)    _MCM_TARGET_WHY="only registered cluster" ;;
        url)     _MCM_TARGET_WHY="OCP_URL" ;;
    esac
    if [[ "${MULTI_CLUSTER_MANAGEMENT}" != true ]]; then
        # Delineated clusters stay per cluster; the flag only sets the default layout.
        _MCM_PIN_NOTE="multi-cluster mode is off, the default stays the flat layout"
    elif [[ "${_MCM_RESOLVED_FROM}" == (flag|pin) && -z "${_MCM_FANOUT_CHILD:-}" ]]; then
        if [[ -n "${MCM_TARGET_CLUSTERS}" ]]; then
            _MCM_PIN_NOTE="overrides MCM_TARGET_CLUSTERS (${MCM_TARGET_CLUSTERS})"
        elif [[ "${APPLY_TO_ALL}" == true ]]; then
            _MCM_PIN_NOTE="overrides APPLY_TO_ALL"
        elif [[ -n "${MCM_CURRENT_CLUSTER}" && "${MCM_CURRENT_CLUSTER}" != "${name}" ]]; then
            _MCM_PIN_NOTE="overrides current cluster ${MCM_CURRENT_CLUSTER}"
        fi
    fi
}

# =============================================================================
# Running across several clusters (plan 5.8)
# =============================================================================
# Which multi-target policy a script gets: "allow" (runs per cluster), "single-only"
# (refuses several targets) or "confirm" (needs a typed confirmation). Lives here and
# not next to the target inference in env_bootstrap.sh, because oadp_br_helpers.sh
# fans out before env_bootstrap.sh is loaded. Confirm goes by the file name only:
# the x_clean_or_debug_* folders also hold read-only scripts. Case does not matter
# (x_specific_component_REinstall.sh). "reinstall" is on the list because a reinstall
# uninstalls first, and its nested uninstall step is pinned and cannot ask. "restore"
# because a restore replaces what is there: an OADP restore a cluster's instance,
# 2.6_restore_transfer_bundle.sh the cluster's work dir (then it restarts the container).
# cpd-cli_toggle_olm_image.sh force-removes the cluster's container and matches no word.
# A script whose verbs differ (scripts/install_runner/x_install_runner.sh) exports
# MCM_SCRIPT_POLICY before its env load instead; it wins over the file name.
mcm_script_policy() {
    emulate -L zsh
    local script="${1:-}" repo relative name
    case "${MCM_SCRIPT_POLICY:-}" in
        "") ;;
        allow|single-only|confirm)
            print -r -- "${MCM_SCRIPT_POLICY}"
            return 0
            ;;
        *)
            _mcm_err "MCM_SCRIPT_POLICY must be allow, single-only or confirm (got '${MCM_SCRIPT_POLICY}')."
            return 1
            ;;
    esac
    repo="$(mcm_repo_root)" || return 1
    relative="${${script:A}#${repo:A}/}"
    name="${relative:t}"
    case "${relative}" in
        src/utilities/multi_cluster_management_utils/*)
            print -r -- single-only
            return 0
            ;;
    esac
    case "${name:l}" in
        # TUI launchers and shells: one screen, one cluster.
        x_service_instance_manager.sh|x_cr_state_dashboard.sh|x_runner_shell.sh)
            print -r -- single-only
            return 0
            ;;
        # Config generators: they write one cluster's config.
        0_swhub_control_center_generate_config.sh|0_confluent_prepare_template_config.sh|0_flink_prepare_template_config.sh|0.0_generate_datastax_mc_config.sh|0.0_generate_mirror_config.sh|generate_kubecost_config.sh|generate_kubecost_features_config.sh|generate_kubecost_csv_pricing_template.sh|generate_kubecost_custom_pricing_template.sh|1.1_generate_backup_bucket_config.sh|1.2_generate_restore_target_config.sh)
            print -r -- single-only
            return 0
            ;;
        # Matches the file-name rule below but only refreshes a CA bundle.
        4.4_refresh_concert_ca_bundle.sh)
            print -r -- allow
            return 0
            ;;
        *uninstall*|*reinstall*|*delete*|*remove*|*prune*|*force*|*clean*|*refresh*|*restore*|cpd-cli_toggle_olm_image.sh)
            print -r -- confirm
            return 0
            ;;
    esac
    print -r -- allow
}

# The script to re-run; fails when there is none (an interactive shell, zsh -c, a
# script on stdin). A script that changed folder before the env load is found
# through its own SCRIPT_DIR.
_mcm_fanout_script() {
    emulate -L zsh
    local script="${ZSH_ARGZERO:A}"
    if [[ ! -f "${script}" && -n "${SCRIPT_DIR:-}" ]]; then
        script="${SCRIPT_DIR}/${ZSH_ARGZERO:t}"
    fi
    [[ -f "${script}" ]] || return 1
    print -r -- "${script}"
}

# Ends the process without running the script's EXIT trap, which would report the
# wrong script name and time when the exit happens inside a sourced file (plan 3.4).
# "trap - EXIT" cannot do it from a function: zsh scopes it to the function, and the
# trap still fires on exit.
mcm_exit_no_trap() {   # CODE
    exec zsh -fc "exit $1"
}

# A shell pinned to one cluster hands its loaded values to every child, so they go
# first (plan: no variable leakage). KUBECONFIG only if it is that cluster's own: a
# restore target's stays. _mcm_forget_flat_config before the rest, because the login
# names it looks for are removed by _mcm_forget_pin.
_mcm_fanout_clean_env() {
    emulate -L zsh
    if [[ -z "${MCM_LOADED_CONFIG_CLUSTER:-}" ]]; then
        _mcm_forget_flat_config
    fi
    _mcm_forget_pin || return 1
    # Runner settings name one cluster's storage class, registry or image, so values
    # exported in this shell must not reach the others: each child reads its own from
    # its cpd_vars.sh. INSTALL_RUN_MODE_OVERRIDE (--run-mode) stays, it is meant for all.
    # So do the one-run switches below: they are not in cpd_vars.sh, they name no
    # cluster, and NEW_RUN is the only way to start over on every cluster at once.
    # ATTACH_LOST_MAX (how long a watch waits) is such a switch too.
    local -a _mcm_ir_names=(${(k)parameters[(I)INSTALL_RUNNER_*]})
    _mcm_ir_names=(${_mcm_ir_names:#(INSTALL_RUNNER_NEW_RUN|INSTALL_RUNNER_CPD_CLI_URL|INSTALL_RUNNER_ALLOW_LOCAL_REGISTRY|INSTALL_RUNNER_ATTACH_LOST_MAX)})
    _mcm_forget_names INSTALL_RUN_MODE ${_mcm_ir_names}
    return 0
}

# One answer typed at the terminal -> REPLY, as typed. The prompt goes to stdout, on the
# line the answer is typed on. 1 at the end of input (REPLY is then what was typed, if
# anything). Used by the fan-out's questions (_mcm_fanout_confirm, install_runner_fanout.sh).
_mcm_ask() {   # PROMPT
    printf '%s' "[MCM] $1"
    REPLY=""
    IFS= read -r REPLY
}

# Typed confirmation for a destructive script. At a terminal it is always asked. With
# no terminal (cron, a pipe, a notebook) nothing can be typed, so only
# --yes-all-clusters lets it run.
_mcm_fanout_confirm() {   # SCRIPT
    emulate -L zsh
    local script="$1" expected="confirm-${#_MCM_RESOLVED}" answer="" name
    if [[ ! -t 0 ]]; then
        (( _MCM_ARG_YES_ALL )) && return 0
        _mcm_err "${script:t} changes or deletes things on each cluster, and there is no terminal to confirm that on."
        _mcm_err "Targets: ${_MCM_RESOLVED[*]}. Pass --yes-all-clusters to run it on all of them, or pick one with --target-cluster NAME."
        return 1
    fi
    print -r -- "[MCM] ${script:t} changes or deletes things on each of these clusters:"
    for name in "${_MCM_RESOLVED[@]}"; do
        print -r -- "[MCM]   ${name}"
    done
    _mcm_ask "Type ${expected} to run it on all ${#_MCM_RESOLVED} (anything else cancels): " || REPLY=""
    answer="${REPLY}"
    if [[ "${answer}" != "${expected}" ]]; then
        _mcm_err "Cancelled: nothing was run. Pick one cluster with --target-cluster NAME."
        return 1
    fi
    return 0
}

# Standard input is a stream, so the first cluster to read it would take it all and
# the rest would see end of file and still report ok. Reads it once into a 0600 file
# that every cluster starts from (mcm_fanout removes it). Sets _MCM_FANOUT_INPUT:
# empty for a terminal (each child prompts there), else the file, or /dev/null when
# there is nothing to read. Fails above the size limit: "yes | script" never ends.
_MCM_FANOUT_STDIN_MAX=$(( 16 * 1024 * 1024 ))
_MCM_FANOUT_STDIN_WAIT_CENTISECONDS=500
_mcm_fanout_prepare_stdin() {
    emulate -L zsh
    local file
    local -a reply
    typeset -g _MCM_FANOUT_INPUT=""
    [[ -t 0 ]] && return 0
    zmodload zsh/zselect 2>/dev/null
    # An open pipe nobody writes to (ssh without -n, a parent holding it) would block
    # the read for ever; every cluster then gets the same empty input.
    if ! zselect -t "${_MCM_FANOUT_STDIN_WAIT_CENTISECONDS}" -r 0 2>/dev/null; then
        _mcm_warn "Standard input is open but sent nothing in $(( _MCM_FANOUT_STDIN_WAIT_CENTISECONDS / 100 ))s: every cluster runs with empty input."
        _MCM_FANOUT_INPUT=/dev/null
        return 0
    fi
    if ! file="$(mktemp "${TMPDIR:-/tmp}/mcm-stdin.XXXXXX")"; then
        _mcm_err "Cannot create a temporary file to hand standard input to each cluster."
        return 1
    fi
    if ! head -c $(( _MCM_FANOUT_STDIN_MAX + 1 )) > "${file}" 2>/dev/null; then
        rm -f -- "${file}"
        _MCM_FANOUT_INPUT=/dev/null
        return 0
    fi
    if [[ ! -s "${file}" ]]; then
        rm -f -- "${file}"
        _MCM_FANOUT_INPUT=/dev/null
    elif (( $(wc -c < "${file}") > _MCM_FANOUT_STDIN_MAX )); then
        rm -f -- "${file}"
        _mcm_err "Standard input is over $(( _MCM_FANOUT_STDIN_MAX / 1024 / 1024 )) MiB: too much to hand to each cluster. Nothing was run."
        return 1
    else
        _MCM_FANOUT_INPUT="${file}"
    fi
    return 0
}

# "45s", "2m 05s", "1h 02m".
_mcm_fanout_duration() {   # SECONDS
    emulate -L zsh
    local -i total="$1"
    if (( total >= 3600 )); then
        printf '%dh %02dm\n' $(( total / 3600 )) $(( total % 3600 / 60 ))
    elif (( total >= 60 )); then
        printf '%dm %02ds\n' $(( total / 60 )) $(( total % 60 ))
    else
        printf '%ds\n' "${total}"
    fi
}

_mcm_fanout_table() {   # NAMES RESULTS DURATIONS (array names)
    emulate -L zsh
    local -a names=("${(@P)1}") results=("${(@P)2}") durations=("${(@P)3}")
    local -i i width_name=7 width_result=6
    for (( i = 1; i <= ${#names}; i++ )); do
        (( ${#names[i]} > width_name )) && width_name=${#names[i]}
        (( ${#results[i]} > width_result )) && width_result=${#results[i]}
    done
    print -r -- "[MCM] Result per cluster:"
    printf '[MCM]   %-*s  %-*s  %s\n' "${width_name}" CLUSTER "${width_result}" RESULT DURATION
    for (( i = 1; i <= ${#names}; i++ )); do
        printf '[MCM]   %-*s  %-*s  %s\n' "${width_name}" "${names[i]}" "${width_result}" "${results[i]}" "${durations[i]}"
    done
}

# --parallel (gap X10): two targets on one cluster would run two installs there at the
# same time, and cluster-wide steps are not locked against each other yet (plan G8).
# Targets whose markers hold the same URL (compared by _mcm_url_key) are refused, with
# nothing run. A target with no URL recorded cannot be compared and passes. The
# confirmation round of a runner chain (install_runner_fanout.sh) checks the targets it
# runs at the same time, under its own label.
_mcm_fanout_refuse_same_url() {   # [LABEL NAME...]
    emulate -L zsh
    local label="${1:---parallel}" name root key
    local -A owner
    local -a clashes names=("${_MCM_RESOLVED[@]}")
    (( $# > 1 )) && names=("${@:2}")
    for name in "${names[@]}"; do
        root="$(mcm_cluster_root "${name}")" || continue
        key="$(_mcm_url_key "$(_mcm_marker_value "${root}/.cluster" OCP_URL)")"
        [[ -n "${key}" ]] || continue
        if [[ -n "${owner[${key}]:-}" ]]; then
            clashes+=("'${owner[${key}]}' and '${name}' (${key})")
        else
            owner[${key}]="${name}"
        fi
    done
    (( ${#clashes} )) || return 0
    _mcm_err "${label}: these targets are one cluster under two names: ${(j:, :)clashes}."
    _mcm_err "Two installs on one cluster at once are not safe yet (cluster-wide steps are not locked). Nothing was run."
    if [[ "${label}" == --parallel ]]; then
        _mcm_err "Target one of the names, or drop --parallel to run them one after the other."
    else
        _mcm_err "Target one of the names (--target-clusters a,b)."
    fi
    return 1
}

# A fan-out child that handed its install to a pod (ir_handoff) leaves a note: the slot
# and how to watch it, tab-separated. Sets slot and watch in the caller; 1 when none.
_mcm_fanout_read_note() {   # FILE
    [[ -n "$1" && -s "$1" ]] || return 1
    IFS=$'\t' read -r slot watch < "$1" || [[ -n "${slot}" ]]
}

# Runs the calling script once per target and ends the process. env_bootstrap.sh and
# oadp_br_helpers.sh call it with the script's arguments minus the target flags. One
# cluster at a time; a failure does not stop the others; the exit code is the first
# failure's, or MCM_SKIP_EXIT_CODE when every cluster was skipped. Ctrl-C (or TERM,
# HUP) ends the current cluster, marks the rest "not run" and still prints the table.
# A refused run (policy, cancelled) ends with code 1 and runs nothing.
# A child that hands its install to a pod (INSTALL_RUN_MODE=cluster) has codes of its
# own, read only when it left a note: 76 its install keeps running unwatched (launched
# by --parallel, or detached by Ctrl-C), 77 ok with warnings, 78 its watch was lost.
# Such a chain with a target whose install would run on this machine first gets the
# questions of install_runner_fanout.sh (C12); then the in-cluster targets launch
# without watching, the one local target runs, and the status of every cluster follows.
mcm_fanout() {
    emulate -L zsh
    local script policy name when result slot watch note_dir="" note local_name=""
    local -a names=("${_MCM_RESOLVED[@]}") results durations watches plan_skipped child_env
    local -i total=${#_MCM_RESOLVED} n=0 rc=0 ok=0 failed=0 skipped=0 first_failure=0 started=0 elapsed=0 interrupted=0
    local -i parallel=0 detached=0 planned=0 staged=0
    [[ "${IR_FANOUT_PARALLEL:-}" == 1 ]] && parallel=1

    if ! script="$(_mcm_fanout_script)"; then
        _mcm_err "Cannot tell which script to re-run for each cluster (targets: ${names[*]})."
        _mcm_err "Pick one with --target-cluster NAME."
        mcm_exit_no_trap 1
    fi
    # One file holds one cluster's URL and credentials: every other cluster would
    # run against that one while the table reports it as done.
    if [[ "${ENV_TARGET:-}" == */* ]]; then
        _mcm_err "ENV_TARGET is the config file ${ENV_TARGET}, which belongs to one cluster, but the targets are: ${names[*]}."
        _mcm_err "Pick one with --target-cluster NAME, or use a config name such as cpd."
        mcm_exit_no_trap 1
    fi
    policy="$(mcm_script_policy "${script}")" || mcm_exit_no_trap 1
    case "${policy}" in
        single-only)
            _mcm_err "${script:t} runs on one cluster at a time, but the targets are: ${names[*]}."
            # A script whose policy depends on its arguments says why (MCM_SCRIPT_POLICY_WHY).
            [[ -n "${MCM_SCRIPT_POLICY_WHY:-}" ]] && _mcm_err "${MCM_SCRIPT_POLICY_WHY}"
            _mcm_err "Pick one with --target-cluster NAME, or set the current cluster with multi_cluster.sh use NAME."
            mcm_exit_no_trap 1
            ;;
        confirm)
            _mcm_fanout_confirm "${script}" || mcm_exit_no_trap 1
            ;;
    esac

    # The questions come first: nothing starts before the last answer (C12). --parallel
    # gets them too: a local target would otherwise fail after the pods before it, and
    # the switches of its local targets must reach their children.
    if _mcm_fanout_runner_chain "${script}"; then
        source "$(mcm_repo_root)/src/helpers/install_runner_fanout.sh"
        rc=0
        ir_fanout_plan "${script}" "$@" || rc=$?
        case "${rc}" in
            0) planned=1 ;;
            2) ;;
            *) mcm_exit_no_trap 1 ;;
        esac
        rc=0
    elif _mcm_fanout_dispatch_chain "${script}"; then
        # A chain that can't run in the cluster, on targets set to run there: one
        # question for all of them, before anything starts. They then run here, one at
        # a time, as below.
        source "$(mcm_repo_root)/src/helpers/install_runner_fanout.sh"
        ir_fanout_local_fallback "${script}" "$@" || mcm_exit_no_trap 1
    fi
    if (( planned )); then
        local_name="${_IR_PLAN_LOCAL}"
        names=("${_IR_PLAN_PODS[@]}")
        if [[ -n "${local_name}" ]]; then
            names+=("${local_name}")
            staged=1
        fi
        plan_skipped=("${_IR_PLAN_SKIPPED[@]}")
        total=${#names}
        # ir_fanout_plan has refused targets that would run at the same time on one
        # cluster under two names, before its last question.
    elif (( parallel )); then
        _mcm_fanout_refuse_same_url || mcm_exit_no_trap 1
    fi

    _mcm_fanout_clean_env || mcm_exit_no_trap 1
    _mcm_fanout_prepare_stdin || mcm_exit_no_trap 1
    note_dir="$(mktemp -d "${TMPDIR:-/tmp}/mcm-fanout.XXXXXX" 2>/dev/null)" || note_dir=""
    # Keeps this process alive through a Ctrl-C meant for the running child. Local to
    # this function (emulate -L), and not inherited by the children.
    trap 'interrupted=1' INT TERM HUP
    export _MCM_FANOUT_CHILD=1 _MCM_FANOUT_SCRIPT="${script:A}" _CP4D_PREP_DONE=1
    if (( staged && total > 1 )); then
        print -r -- "[MCM] Launching ${script:t} on $(( total - 1 )) cluster(s) without watching (${(j:, :)${(@)names:#${local_name}}}), then running it here on ${local_name}."
    elif (( staged )); then
        print -r -- "[MCM] Running ${script:t} here on ${local_name} only."
    elif (( parallel )); then
        print -r -- "[MCM] Launching ${script:t} on ${total} clusters, one at a time; each install then runs on in its cluster (--parallel): ${names[*]}"
    else
        print -r -- "[MCM] Running ${script:t} on ${total} clusters, one at a time: ${names[*]}"
    fi
    for name in "${names[@]}"; do
        n=$(( n + 1 ))
        if (( interrupted )); then
            results+=("not run")
            durations+=("-")
            continue
        fi
        print -r -- "[MCM] ${n}/${total} ${name} ..."
        started=${SECONDS}
        rc=0
        export MCM_CLUSTER="${name}"
        note=""
        [[ -n "${note_dir}" ]] && note="${note_dir}/${n}"
        export _MCM_FANOUT_NOTE="${note}"
        if (( planned )); then
            # In-cluster targets only launch while a local one waits its turn (Q-a6); a
            # target switched by the questions runs in the cluster for this run only.
            child_env=()
            if (( staged )) && [[ "${name}" != "${local_name}" ]]; then
                child_env+=(IR_FANOUT_PARALLEL=1)
            fi
            if (( ${_IR_PLAN_SWITCHED[(Ie)${name}]} )); then
                child_env+=(INSTALL_RUN_MODE_OVERRIDE=cluster)
            fi
            # A launch that is not watched (next to the local run, or --parallel) reads
            # nothing: the terminal, and what is typed ahead on it, stays for the local
            # run. A pty on stdin can also hang the staging upload (zsh read -d '').
            if (( staged || parallel )) && [[ "${name}" != "${local_name}" ]]; then
                env "${child_env[@]}" zsh "${script}" "$@" < /dev/null || rc=$?
            elif [[ -n "${_MCM_FANOUT_INPUT}" ]]; then
                env "${child_env[@]}" zsh "${script}" "$@" < "${_MCM_FANOUT_INPUT}" || rc=$?
            else
                env "${child_env[@]}" zsh "${script}" "$@" || rc=$?
            fi
        elif [[ -n "${_MCM_FANOUT_INPUT}" ]]; then
            zsh "${script}" "$@" < "${_MCM_FANOUT_INPUT}" || rc=$?
        else
            zsh "${script}" "$@" || rc=$?
        fi
        elapsed=$(( SECONDS - started ))
        when="$(_mcm_fanout_duration "${elapsed}")"
        slot="" watch=""
        # Another script's 76-78 is only a failure code: the note says it is a hand-off's.
        if (( rc >= 76 && rc <= 78 )) && _mcm_fanout_read_note "${note}"; then
            case "${rc}" in
                76)
                    if (( interrupted )); then
                        result="detached (still running)"
                        detached=1
                    else
                        result="launched${slot:+ (slot ${slot})}"
                    fi
                    ok=$(( ok + 1 ))
                    [[ -n "${watch}" ]] && watches+=("${name}"$'\t'"${watch}")
                    ;;
                77)
                    result="ok (warnings)"
                    ok=$(( ok + 1 ))
                    ;;
                78)
                    result="watch lost (still running?)"
                    failed=$(( failed + 1 ))
                    (( first_failure )) || first_failure=${rc}
                    [[ -n "${watch}" ]] && watches+=("${name}"$'\t'"${watch}")
                    ;;
            esac
        else
            case "${rc}" in
                0)
                    result=ok
                    ok=$(( ok + 1 ))
                    ;;
                "${MCM_SKIP_EXIT_CODE}")
                    result=skipped
                    skipped=$(( skipped + 1 ))
                    ;;
                130)
                    result=interrupted
                    failed=$(( failed + 1 ))
                    (( first_failure )) || first_failure=${rc}
                    interrupted=1
                    ;;
                *)
                    result="FAILED (rc ${rc})"
                    failed=$(( failed + 1 ))
                    (( first_failure )) || first_failure=${rc}
                    ;;
            esac
        fi
        results+=("${result}")
        durations+=("${when}")
        print -r -- "[MCM] ${n}/${total} ${name}: ${result} (${when})"
    done
    unset _MCM_FANOUT_NOTE
    # Targets the questions left out: a local install runs on one target only.
    for name in "${plan_skipped[@]}"; do
        names+=("${name}")
        results+=("skipped (runs here, but only ${local_name} does in this run)")
        durations+=("-")
    done

    if [[ -n "${_MCM_FANOUT_INPUT}" && "${_MCM_FANOUT_INPUT}" != /dev/null ]]; then
        rm -f -- "${_MCM_FANOUT_INPUT}"
    fi
    [[ -n "${note_dir}" ]] && rm -rf -- "${note_dir}"
    _mcm_fanout_table names results durations
    if (( ${#watches} )); then
        print -r -- "[MCM] Installs left running in their clusters (nothing here waits for them). Watch each one with:"
        for watch in "${watches[@]}"; do
            print -r -- "[MCM]   ${watch%%$'\t'*}: ${watch#*$'\t'}"
        done
    fi
    if (( detached )); then
        print -r -- "[MCM] Ctrl-C detached from a running install; the clusters after it were not launched (not run)."
    fi
    # Once pods were planned next to the local run, whatever each launch returned
    # (Q-a6); not after a Ctrl-C, which asked to stop.
    (( staged && ${#_IR_PLAN_PODS} && ! interrupted )) && ir_fanout_status
    # A child that handled the Ctrl-C itself may have ended with 0.
    (( interrupted && ! first_failure )) && first_failure=130
    if (( first_failure )); then
        mcm_exit_no_trap "${first_failure}"
    fi
    if (( ! ok && skipped )); then
        _mcm_warn "No cluster has a config for this script; nothing ran."
        mcm_exit_no_trap "${MCM_SKIP_EXIT_CODE}"
    fi
    mcm_exit_no_trap 0
}

# 0 when SCRIPT is an install chain that can run in the cluster (a RUNNER_ENTRYPOINTS
# script of src/install_runner/installs/).
_mcm_fanout_runner_chain() {   # SCRIPT
    emulate -L zsh
    local repo
    repo="$(mcm_repo_root)" || return 1
    (( $+functions[ir_is_runner_entrypoint] )) || source "${repo}/src/helpers/install_runner_mode.sh"
    ir_is_runner_entrypoint "${repo}" "${${1:A}#${repo:A}/}"
}

# 0 when SCRIPT calls ir_dispatch (INSTALL_RUN_MODE=cluster would move its run to a pod)
# but is not a runner chain: no install module lists it (ir_fanout_local_fallback).
_mcm_fanout_dispatch_chain() {   # SCRIPT
    emulate -L zsh
    local repo
    repo="$(mcm_repo_root)" || return 1
    (( $+functions[ir_is_dispatch_chain] )) || source "${repo}/src/helpers/install_runner_mode.sh"
    ir_is_dispatch_chain "$1"
}

# 0 when the arguments ask the script for its usage and the script has such an option.
# One that does not would ignore the word and do its real work, so that stays a normal run.
_mcm_help_requested() {   # SCRIPT ARGS...
    emulate -L zsh
    local script="$1" arg
    shift
    for arg in "$@"; do
        [[ "${arg}" == -- ]] && return 1
        if [[ "${arg}" == (-h|--help) ]]; then
            grep -qF -e '-h|--help' -e '--help|-h' -e '"--help"' -- "${script}" 2>/dev/null
            return $?
        fi
    done
    return 1
}

# The cluster a usage request runs on: the current one when targeted, else the first.
_mcm_narrow_for_help() {
    emulate -L zsh
    if [[ "${MULTI_CLUSTER_MANAGEMENT}" != true ]] || (( ! ${_MCM_RESOLVED[(Ie)${MCM_CURRENT_CLUSTER}]} )); then
        _MCM_RESOLVED=("${_MCM_RESOLVED[1]}")
    fi
    _mcm_narrow_to_one
}

# The one call at env load. Generates the state file, resolves the targets and
# either fans out or pins this process. Mode off leaves the environment alone (apart
# from clearing a stale pin). Returns non-zero with [ERROR] on stderr.
mcm_env_setup() {
    _mcm_env_setup 0 "$@"
}

# A sourced load: always ends on one cluster. Separate from mcm_env_setup so that no
# argument of a script can select it.
mcm_env_setup_no_fanout() {
    _mcm_env_setup 1
}

_mcm_env_setup() {   # NO_FANOUT ARGS...
    emulate -L zsh
    local -i no_fanout="$1"
    shift
    mcm_resolve_targets >/dev/null || return 1
    if (( ! ${#_MCM_RESOLVED} )); then
        # Flat layout: the mode is off and no delineated cluster is named. A pin to a
        # cluster that is not delineated (a stale shell) is dropped.
        if [[ -n "${MCM_CLUSTER:-}${MCM_CLUSTER_ROOT:-}${MCM_LOADED_CONFIG_CLUSTER:-}" ]]; then
            _mcm_warn "Multi-cluster mode is off; ignoring the pin to '${MCM_CLUSTER:-${MCM_LOADED_CONFIG_CLUSTER:-}}' in this environment."
            _mcm_forget_pin || return 1
        fi
        _MCM_ENV_READY=1
        return 0
    fi
    if (( ${#_MCM_RESOLVED} > 1 )); then
        if [[ -n "${_MCM_FANOUT_CHILD:-}" && -n "${MCM_CLUSTER:-}" ]]; then
            # Already one branch of a fan-out: a chained script must not start another.
            _mcm_warn "This is one cluster of a multi-cluster run: staying on ${MCM_CLUSTER} and ignoring the other targets (${_MCM_RESOLVED[*]})."
            _MCM_RESOLVED=("${MCM_CLUSTER}")
            _MCM_RESOLVED_FROM=pin
        elif (( no_fanout )) || [[ -o interactive ]] || ! _mcm_fanout_script >/dev/null; then
            _mcm_narrow_to_one || return 1
        elif _mcm_help_requested "$(_mcm_fanout_script)" "$@"; then
            _mcm_narrow_for_help || return 1
        else
            # Every cluster of this run stays "targeted" while its siblings run (plan 5.7).
            export MCM_RUN_TARGETS="${_MCM_RESOLVED[*]}"
            mcm_fanout "$@"
            return $?
        fi
    fi

    local name="${_MCM_RESOLVED[1]}" root
    root="$(mcm_cluster_root "${name}")" || return 1
    if _mcm_env_target_elsewhere "${root}"; then
        _mcm_err "ENV_TARGET is ${ENV_TARGET}, which is not in the folder of cluster '${name}' (${root})."
        _mcm_err "Its URL and credentials would run with that cluster's kubeconfig and container. Use a config name such as cpd, or target the cluster that owns the file."
        return 1
    fi
    # An interactive shell outlives a failed load, so refuse before changing anything.
    # Elsewhere the loader reports it and the process ends (the skip code of a fan-out).
    if (( no_fanout )) && [[ -o interactive ]]; then
        if ! _mcm_target_config_exists "${root}"; then
            _mcm_err "Cluster '${name}' has no '${ENV_TARGET}' config (looked in ${root}). This shell keeps what it had loaded."
            _mcm_err "Create the config there, or pick another cluster with --target-cluster NAME."
            return 1
        fi
    fi
    if [[ -z "${MCM_LOADED_CONFIG_CLUSTER:-}" ]]; then
        _mcm_forget_flat_config
    elif [[ "${MCM_LOADED_CONFIG_CLUSTER}" != "${name}" ]]; then
        _mcm_forget_loaded_config
    fi
    mcm_pin "${name}" || return 1
    _mcm_describe_pin "${name}"
    mcm_clear_target_flags
    _MCM_ENV_READY=1
    return 0
}

# =============================================================================
# Containers on and off (plan 5.7, 5.7.1)
# =============================================================================
# Exported guards, so a chain of nested scripts does this work once. Sourced shells
# and TUI launchers set none: scripts started from them must do their own sync.
#   _MCM_SYNC_STOP_DONE   cluster whose stop pass this process tree has run
#   _MCM_SYNC_STARTED     containers this tree has seen running
#   _MCM_LEASE_HELD       clusters this tree already holds a lease on
#   _MCM_SYNC_WARNED      the "podman unreachable" warning has been printed
# MCM_RUN_TARGETS, set by a fan-out, is the whole target list of the run.
#
# Under ~/cpd-cli/clusters:
#   <name>/.stopping           a container of the cluster is being stopped
#   <name>/.custom_containers  custom Control Center names of the cluster, one per line
#   <name>/.scans/<container>  times of our own exec calls into the container
#   .vm-stopping               the watcher is shutting the podman VM down

# Default of CONTROL_OLM_UTILS_CONTAINER in swhub_control_center_config_render.py.
_MCM_SWHCC_CONTAINER_BASE="olm-utils-swhub-control-center"

# What the process scan runs in the container, which has no ps. It lists every
# process, itself included, one per line: "PID PPID cmdline". The first line names
# its own PID so the host can leave it and its children out. Newlines in a cmdline
# become spaces (a multi-line "sh -c" must stay one record).
_MCM_SCAN_SCRIPT='# mcm-proc-scan
echo "self $$"
for p in /proc/[0-9]*; do
    [ -r "${p}/stat" ] || continue
    s=$(cat "${p}/stat" 2>/dev/null) || continue
    [ -n "${s}" ] || continue
    rest=${s##*) }
    set -- ${rest}
    c=$(tr "\0\n" "  " < "${p}/cmdline" 2>/dev/null) || c=""
    echo "${p#/proc/} ${2:-0} ${c}"
done'

_mcm_say() {
    [[ -n "${ENV_SETUP_QUIET:-}" ]] || print -r -- "[INFO] $*" >&2
    return 0
}

_mcm_clusters_home() {
    print -r -- "${HOME}/cpd-cli/clusters"
}

# Custom Control Center names recorded for the cluster, one per line. A line that
# is not a container name ending in -<cluster> is left out.
_mcm_custom_containers() {   # CLUSTER
    emulate -L zsh
    local cluster="$1" file line
    file="$(_mcm_clusters_home)/${cluster}/.custom_containers"
    [[ -f "${file}" ]] || return 0
    for line in "${(@f)$(<"${file}")}"; do
        if [[ "${line}" == [a-zA-Z0-9]*-"${cluster}" && "${line}" != *[^a-zA-Z0-9_.-]* ]]; then
            print -r -- "${line}"
        fi
    done
    return 0
}

# CONTROL_OLM_UTILS_CONTAINER can name any container, so the name sync starts is
# written down here: without it nothing could ever stop that container.
_mcm_record_custom_container() {   # CLUSTER CONTAINER
    emulate -L zsh
    local cluster="$1" container="$2" file
    local -a known
    [[ "${container}" != "${_MCM_SWHCC_CONTAINER_BASE}-${cluster}" && "${container}" != "$(mcm_container_name "${cluster}")" ]] || return 0
    known=("${(@f)$(_mcm_custom_containers "${cluster}")}")
    (( ${known[(Ie)${container}]} )) && return 0
    file="$(_mcm_clusters_home)/${cluster}/.custom_containers"
    if ! mkdir -p "${file:h}" 2>/dev/null || ! { print -r -- "${container}" >> "${file}" } 2>/dev/null; then
        _mcm_warn "Could not record the container name ${container}; it will not be stopped automatically."
    fi
    return 0
}

# The cluster's container names, one per line. No name: the flat-layout pair.
mcm_container_names() {
    emulate -L zsh
    local name="${1:-}"
    if [[ -n "${name}" ]]; then
        mcm_validate_name "${name}" || return 1
    fi
    mcm_container_name "${name}"
    print -r -- "${_MCM_SWHCC_CONTAINER_BASE}${name:+-${name}}"
    if [[ -n "${name}" ]]; then
        _mcm_custom_containers "${name}"
    fi
}

# Every name this feature owns: the flat pair and each registered cluster's pair.
mcm_managed_containers() {
    emulate -L zsh
    local name
    local IFS=$' \t\n'
    mcm_load_state || return 1
    mcm_container_names
    for name in ${=MCM_CLUSTERS}; do
        mcm_container_names "${name}"
    done
}

# The cluster a managed container belongs to on stdout, empty for the flat pair.
# Returns 1 when the name is not one of ours.
_mcm_container_cluster() {
    emulate -L zsh
    local container="${1:-}" base file
    for base in "$(mcm_container_name)" "${_MCM_SWHCC_CONTAINER_BASE}"; do
        if [[ "${container}" == "${base}" ]]; then
            print -r -- ""
            return 0
        fi
        if [[ "${container}" == "${base}-"* ]]; then
            print -r -- "${container#${base}-}"
            return 0
        fi
    done
    for file in "$(_mcm_clusters_home)"/*/.custom_containers(N.); do
        if [[ "${${(@f)"$(<"${file}")"}[(Ie)${container}]}" != 0 ]]; then
            print -r -- "${file:h:t}"
            return 0
        fi
    done
    return 1
}

# What the state file selects, by the order in table 5.4. Needs mcm_load_state.
_mcm_state_selection() {
    emulate -L zsh
    local IFS=$' \t\n'
    local -a list registered
    registered=(${=MCM_CLUSTERS})
    if [[ -n "${MCM_TARGET_CLUSTERS}" ]]; then
        list=(${=MCM_TARGET_CLUSTERS})
    elif [[ "${APPLY_TO_ALL}" == true ]]; then
        list=("${registered[@]}")
    elif [[ -n "${MCM_CURRENT_CLUSTER}" ]]; then
        list=("${MCM_CURRENT_CLUSTER}")
    elif (( ${#registered} == 1 )); then
        list=("${registered[1]}")
    fi
    print -r -- "${list[*]}"
}

# The clusters whose containers may stay on: this run's targets plus what the state
# file selects, so a one-off --target-cluster keeps the cluster you are working on.
# Mode off: the state file selects nothing, so only the run's own explicit targets.
mcm_targeted_clusters() {
    emulate -L zsh
    local IFS=$' \t\n' selection=""
    local -a list
    mcm_load_state || return 1
    if [[ "${MULTI_CLUSTER_MANAGEMENT}" == true ]]; then
        selection="$(_mcm_state_selection)" || selection=""
    fi
    list=(${=MCM_CLUSTER:-} "${_MCM_RESOLVED[@]}" ${=MCM_RUN_TARGETS:-} ${=selection})
    print -r -- "${(j: :)${(@u)list}}"
}

# ---- leases ----------------------------------------------------------------
# An open s_env.sh shell or a TUI launcher can stay open for days and must not keep
# a container on. The launchers are the "single only" group of plan 5.8. The in-cluster
# runner's control scripts need only oc, and an attach can last hours (gap X8).
_mcm_long_lived_load() {
    [[ -o interactive ]] && return 0
    (( ${funcstack[(I)*s_env.sh]} )) && return 0
    case "${ZSH_ARGZERO:t}" in
        x_service_instance_manager.sh|x_cr_state_dashboard.sh|x_runner_shell.sh) return 0 ;;
        x_install_runner.sh|x_watch_install.sh) return 0 ;;
    esac
    return 1
}

# 0 when a live run holds a lease on the cluster. Leases of dead PIDs are removed.
_mcm_lease_live() {
    emulate -L zsh
    local cluster="${1:-}" file live=1
    [[ -n "${cluster}" ]] || return 1
    for file in "$(_mcm_clusters_home)/${cluster}/.leases"/<->(N.); do
        if kill -0 "${file:t}" 2>/dev/null; then
            live=0
        else
            rm -f "${file}" 2>/dev/null || true
        fi
    done
    return "${live}"
}

# Marks this top-level run as live on the cluster (default MCM_CLUSTER). The file is
# ~/cpd-cli/clusters/<name>/.leases/<pid> and holds the script the run was started by,
# as an absolute path when it is a file (install_runner_lock.sh reads which install
# that is). A dead PID counts as stale, so no EXIT trap is needed. Never fails the run.
mcm_take_lease() {
    emulate -L zsh
    local cluster="${1:-${MCM_CLUSTER:-}}" dir started="${ZSH_ARGZERO:-zsh}"
    [[ -f "${started}" ]] && started="${started:A}"
    [[ -n "${cluster}" ]] || return 0
    if _mcm_long_lived_load; then
        return 0
    fi
    if [[ " ${_MCM_LEASE_HELD:-} " == *" ${cluster} "* ]]; then
        return 0
    fi
    dir="$(_mcm_clusters_home)/${cluster}/.leases"
    if ! mkdir -p "${dir}" 2>/dev/null || ! { print -r -- "${started}" > "${dir}/$$" } 2>/dev/null; then
        _mcm_warn "Could not write a lease in ${dir}; the idle checks cannot see this run."
        return 0
    fi
    export _MCM_LEASE_HELD="${_MCM_LEASE_HELD:-} ${cluster}"
    return 0
}

# Drops this run's lease on the cluster (default MCM_CLUSTER), for a lease taken only
# around one podman step (the runner's local image build, gap X8b). Never fails the run.
mcm_release_lease() {
    emulate -L zsh
    local cluster="${1:-${MCM_CLUSTER:-}}"
    local -a held
    [[ -n "${cluster}" ]] || return 0
    rm -f "$(_mcm_clusters_home)/${cluster}/.leases/$$" 2>/dev/null || true
    held=(${=_MCM_LEASE_HELD:-})
    held=("${(@)held:#${cluster}}")
    if (( ${#held} )); then
        export _MCM_LEASE_HELD=" ${(j: :)held}"
    else
        unset _MCM_LEASE_HELD
    fi
    return 0
}

# ---- process scan ----------------------------------------------------------
# Prints what keeps a container busy, given the scan's output. Empty means idle.
_mcm_scan_busy_lines() {
    emulate -L zsh
    local input="${1:-}" self="" line pid ppid tool
    local IFS=$' \t\n'
    local -a words
    for line in "${(@f)input}"; do
        words=(${=line})
        (( ${#words} )) || continue
        if [[ "${words[1]}" == self ]]; then
            self="${words[2]:-}"
            continue
        fi
        pid="${words[1]}"
        ppid="${words[2]:-}"
        # PID 1 is the container itself; the rest here is this scan and its children.
        [[ "${pid}" != 1 ]] || continue
        if [[ -n "${self}" ]] && [[ "${pid}" == "${self}" || "${ppid}" == "${self}" ]]; then
            continue
        fi
        # Another sync's scan, running at the same moment.
        [[ "${line}" != *mcm-proc-scan* ]] || continue
        words=("${(@)words[3,-1]}")
        # A zombie or kernel thread has no command line.
        (( ${#words} )) || continue
        # Under emulation a cmdline starts with the emulator, which may add "-0 ARGV0"
        # or repeat the program's own argv[0] after its path.
        if [[ "${words[1]:t}" == qemu-* || "${words[1]:t}" == rosetta* ]]; then
            words=("${(@)words[2,-1]}")
            if [[ "${words[1]:-}" == -0 ]]; then
                words=("${(@)words[3,-1]}")
            elif (( ${#words} >= 2 )) && [[ "${words[2]}" == "${words[1]:t}" ]]; then
                words[2]=()
            fi
        fi
        tool="${words[1]:-}"
        tool="${tool:t}"
        if [[ "${tool}" == registry && "${words[2]:-}" == serve ]]; then
            continue
        fi
        if [[ "${tool}" == start-registry ]]; then
            continue
        fi
        if [[ "${tool}" == (sh|bash|dash) && "${${words[2]:-}:t}" == start-registry ]]; then
            continue
        fi
        # Not known to be idle: count it, so the failure mode is a container left on.
        print -r -- "${pid}: ${(j: :)words}"
    done
    return 0
}

_mcm_scan_log_file() {   # CONTAINER
    emulate -L zsh
    local container="$1" cluster
    cluster="$(_mcm_container_cluster "${container}")" || cluster=""
    print -r -- "$(_mcm_clusters_home)/${cluster:-.flat}/.scans/${container}"
}

# A scan is itself a podman exec, so it shows up as an exec event. The watcher takes
# these out of the event count, or checking a busy container would restart its clock.
# The login probes in CPDM_OC_LOGIN are logged here too (multi_cluster_bin/mcm_login_probe.sh).
_mcm_note_own_scan() {   # CONTAINER
    emulate -L zsh
    local file
    zmodload zsh/datetime 2>/dev/null || return 0
    file="$(_mcm_scan_log_file "$1")" || return 0
    if mkdir -p "${file:h}" 2>/dev/null; then
        { print -r -- "${EPOCHSECONDS}" >> "${file}" } 2>/dev/null || true
    fi
    return 0
}

# Prints how many of our own scans of CONTAINER fall at or after SINCE, and forgets older ones.
_mcm_own_scans_since() {   # CONTAINER SINCE
    emulate -L zsh
    local container="$1" file stamp
    local -i since="$2" count=0
    local -a kept
    file="$(_mcm_scan_log_file "${container}")" || { print 0; return 0; }
    if [[ ! -f "${file}" ]]; then
        print 0
        return 0
    fi
    for stamp in "${(@f)$(<"${file}")}"; do
        if [[ "${stamp}" == <-> ]] && (( stamp >= since )); then
            kept+=("${stamp}")
            count=$(( count + 1 ))
        fi
    done
    { print -rl -- "${kept[@]}" > "${file}" } 2>/dev/null || true
    print -r -- "${count}"
}

# What CPDM_OC_LOGIN runs in place of podman exec for its login probes. By file path
# through zsh, so it needs neither PATH nor the executable bit.
mcm_login_probe_command() {
    emulate -L zsh
    local dir
    dir="$(_mcm_shim_dir)" || return 1
    print -r -- "zsh ${(qq)dir}/mcm_login_probe.sh"
}

# 0 busy, 1 idle. REPLY says why it is busy. A scan that cannot run, or that returns
# without its "self" line, counts as busy unless podman says the container is not
# running or does not exist. _MCM_SCAN_NO_NOTE=1 leaves the own-scan log alone, for
# a caller that must write nothing (a migrate dry run).
_mcm_scan_container() {   # CONTAINER
    emulate -L zsh
    local container="$1" output="" running="" busy=""
    local -i rc=0 exists=0
    REPLY=""
    output="$(podman exec "${container}" sh -c "${_MCM_SCAN_SCRIPT}" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        running="$(podman inspect --format '{{.State.Running}}' "${container}" 2>/dev/null)" || running=""
        if [[ "${running}" == false ]]; then
            return 1
        fi
        # "exists" answers 1 only for a container that really is not there; anything
        # else (podman unreachable) must stay busy.
        podman container exists "${container}" 2>/dev/null || exists=$?
        if (( exists == 1 )); then
            return 1
        fi
        REPLY="process scan failed (podman exec rc ${rc})"
        return 0
    fi
    [[ -n "${_MCM_SCAN_NO_NOTE:-}" ]] || _mcm_note_own_scan "${container}"
    if [[ $'\n'"${output}" != *$'\n'"self "[0-9]* ]]; then
        REPLY="process scan returned no data"
        return 0
    fi
    busy="$(_mcm_scan_busy_lines "${output}")" || busy=""
    if [[ -n "${busy}" ]]; then
        REPLY="process ${busy%%$'\n'*}"
        return 0
    fi
    return 1
}

_mcm_one_container_busy() {   # CONTAINER CLUSTER
    emulate -L zsh
    local container="$1" cluster="${2:-}"
    if [[ -n "${cluster}" ]] && _mcm_lease_live "${cluster}"; then
        _MCM_BUSY_WHY="a live run holds a lease on cluster ${cluster}"
        return 0
    fi
    if _mcm_scan_container "${container}"; then
        _MCM_BUSY_WHY="${REPLY}"
        return 0
    fi
    return 1
}

# 0 busy, 1 idle. NAME is a container, or a cluster (then any of its containers).
# A container that does not exist is idle. The reason lands in _MCM_BUSY_WHY, so call
# it in this shell, not in $(...).
mcm_container_busy() {
    emulate -L zsh
    local name="${1:-}" cluster="" container
    local -a names
    _MCM_BUSY_WHY=""
    if cluster="$(_mcm_container_cluster "${name}")"; then
        _mcm_one_container_busy "${name}" "${cluster}"
        return $?
    fi
    if _mcm_lease_live "${name}"; then
        _MCM_BUSY_WHY="a live run holds a lease on cluster ${name}"
        return 0
    fi
    names=("${(@f)$(mcm_container_names "${name}")}") || return 1
    for container in "${names[@]}"; do
        if _mcm_scan_container "${container}"; then
            _MCM_BUSY_WHY="${container}: ${REPLY}"
            return 0
        fi
    done
    return 1
}

# ---- starting and stopping ---------------------------------------------------
# Whether a config file of this load sets the image (not an inherited value). Reads
# the list source_env_setup.sh keeps. Control Center's is CONTROL_OLM_UTILS_IMAGE.
_mcm_loaded_config_declares_image() {
    emulate -L zsh
    local file repo
    repo="$(mcm_repo_root)" || return 1
    for file in "${_env_loaded[@]:-}"; do
        [[ -n "${file}" ]] || continue
        [[ "${file}" == /* ]] || file="${repo}/${file}"
        if grep -Eq '^[[:space:]]*(export[[:space:]]+)?(CONTROL_)?OLM_UTILS_IMAGE=' "${file}" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# The container this load's scripts will use.
_mcm_own_container() {
    if [[ "${ENV_TARGET:-}" == *swhub_control_center* ]]; then
        print -r -- "${CONTROL_OLM_UTILS_CONTAINER:-${_MCM_SWHCC_CONTAINER_BASE}}${MCM_CONTAINER_SUFFIX:-}"
    else
        mcm_container_name "${MCM_CLUSTER:-}"
    fi
}

# Holds the .stopping marker while stopping, then re-checks the lease, which closes
# the race with a run starting now: that run writes its lease first, then waits for
# the marker. 0 stopped, 1 the stop failed, 2 a lease appeared.
_mcm_stop_container() {   # CONTAINER CLUSTER
    emulate -L zsh
    local container="$1" cluster="${2:-}" marker="" rc=0
    if [[ -n "${cluster}" ]]; then
        marker="$(_mcm_clusters_home)/${cluster}/.stopping"
        mkdir -p "${marker:h}" 2>/dev/null || true
        { print -r -- "$$" > "${marker}" } 2>/dev/null || true
        if _mcm_lease_live "${cluster}"; then
            rm -f "${marker}" 2>/dev/null || true
            return 2
        fi
    fi
    podman stop -t 3 "${container}" >/dev/null 2>&1 || rc=1
    if [[ -n "${marker}" ]]; then
        rm -f "${marker}" 2>/dev/null || true
    fi
    return "${rc}"
}

# Waits while MARKER exists. A marker whose owner died is removed.
_mcm_wait_marker() {   # MARKER LIMIT_SECONDS WHAT
    emulate -L zsh
    local marker="$1" what="$3" owner
    local -i waited=0 limit="$2"
    while [[ -f "${marker}" ]]; do
        owner="$(<"${marker}")" 2>/dev/null || owner=""
        if [[ -n "${owner}" ]] && ! kill -0 "${owner}" 2>/dev/null; then
            rm -f "${marker}" 2>/dev/null || true
            return 0
        fi
        if (( waited >= limit )); then
            _mcm_warn "${what}: still being stopped after ${limit}s; continuing."
            return 0
        fi
        if (( waited == 0 )); then
            _mcm_say "${what}: waiting for the stop to finish ..."
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    return 0
}

# Waits for a stop in progress on the cluster.
_mcm_wait_stopping() {   # CLUSTER
    _mcm_wait_marker "$(_mcm_clusters_home)/$1/.stopping" "${MCM_STOP_WAIT_SECONDS:-30}" "Container of cluster $1"
}

# 0 when the VM was stopped and has been started again.
_mcm_restart_stopped_vm() {
    emulate -L zsh
    local state=""
    state="$(podman machine inspect --format '{{.State}}' 2>/dev/null)" || state=""
    [[ "${state}" == stopped ]] || return 1
    _mcm_say "The podman VM is stopped (the idle watcher shuts it down when nothing runs); starting it."
    if ! podman machine start >/dev/null 2>&1; then
        _mcm_warn "Could not start the podman VM; the run continues."
        return 1
    fi
    return 0
}

# Same order as a container stop: the run has written its lease, then waits here, and
# the watcher writes this marker, then checks the leases. env_bootstrap.sh checked the
# machine before the lease existed, so a VM that went down is started again.
_mcm_wait_vm_stopping() {
    emulate -L zsh
    local marker
    marker="$(_mcm_clusters_home)/.vm-stopping"
    [[ -f "${marker}" ]] || return 0
    _mcm_wait_marker "${marker}" "${MCM_VM_STOP_WAIT_SECONDS:-120}" "Podman VM"
    _mcm_restart_stopped_vm || true
    return 0
}

# Starts the watcher unless one is alive. No timeout (0) means nothing to watch.
_mcm_watcher_alive() {   # PID
    kill -0 "$1" 2>/dev/null && ps -o command= -p "$1" 2>/dev/null | grep -q multi_cluster_idle_watcher
}

mcm_ensure_idle_watcher() {
    emulate -L zsh
    local home pid_file log_file pid="" script repo rc=0
    mcm_load_state || rc=$?
    if (( rc != 0 )); then
        return 0
    fi
    # A run pinned to a delineated cluster is managed whatever the flag says.
    [[ "${MULTI_CLUSTER_MANAGEMENT}" == true || -n "${MCM_CLUSTER:-}" ]] || return 0
    (( MCM_CONTAINER_IDLE_TIMEOUT_MINUTES > 0 )) || return 0
    home="$(_mcm_clusters_home)"
    pid_file="${home}/.idle-watcher.pid"
    log_file="${home}/.idle-watcher.log"
    if [[ -f "${pid_file}" ]]; then
        pid="$(<"${pid_file}")" 2>/dev/null || pid=""
        if [[ -n "${pid}" ]] && _mcm_watcher_alive "${pid}"; then
            return 0
        fi
    fi
    repo="$(mcm_repo_root)" || return 0
    script="${repo}/src/helpers/multi_cluster_idle_watcher.sh"
    if [[ ! -f "${script}" ]]; then
        _mcm_warn "The idle watcher is missing: ${script}"
        return 0
    fi
    mkdir -p "${home}" 2>/dev/null || return 0
    # A process command line can carry a password, so only its owner reads the log.
    { ( umask 077; : >> "${log_file}" ); chmod 600 "${log_file}" } 2>/dev/null || true
    {
        nohup zsh "${script}" </dev/null >>"${log_file}" 2>&1 &!
    } 2>/dev/null || true
    return 0
}

# Makes the containers follow the target (table in plan 5.7). "stop-only" (the
# multi_cluster.sh use, targets and apply-to-all commands) only stops what left the
# set. Prints to stderr and always returns 0: containers never fail a run.
# Runs while the mode is on, and for any run pinned to a delineated cluster (MCM_CLUSTER)
# with the mode off. Then the targeted set is the run's own targets, and the flat
# containers are left alone: flat runs, the default, use them.
mcm_sync_containers() {
    emulate -L zsh
    local mode="${1:-}" cluster="${MCM_CLUSTER:-}" own="" states="" line state container name
    local IFS=$' \t\n'
    local -i rc=0 long_lived=0 want_stop=0 total=0 n=0 stop_rc=0 up=0
    local -a words targeted candidates registered names managed
    local -A state_of

    mcm_load_state || rc=$?
    if (( rc != 0 )); then
        _mcm_warn "Skipping the container sync: the multi-cluster state file is invalid."
        return 0
    fi
    [[ "${MULTI_CLUSTER_MANAGEMENT}" == true || -n "${cluster}" ]] || return 0

    if _mcm_long_lived_load; then
        long_lived=1
    fi
    registered=(${=MCM_CLUSTERS})
    if [[ "${mode}" == stop-only || -z "${cluster}" || "${_MCM_SYNC_STOP_DONE:-}" != "${cluster}" ]]; then
        want_stop=1
    fi
    if [[ "${mode}" != stop-only && -n "${cluster}" ]]; then
        mcm_take_lease "${cluster}"
        _mcm_wait_vm_stopping
        if _mcm_loaded_config_declares_image; then
            own="$(_mcm_own_container)" || own=""
        fi
    fi
    # Only names of registered clusters are ours to touch (plan 5.7).
    if [[ -n "${own}" ]] && (( ! ${registered[(Ie)${cluster}]} )); then
        if (( want_stop )); then
            _mcm_say "Cluster ${cluster} is not registered: ${own} is neither started nor auto-stopped here. Register it with multi_cluster.sh add ${cluster}."
        fi
        own=""
    fi
    if [[ -n "${own}" ]]; then
        _mcm_record_custom_container "${cluster}" "${own}"
        if [[ " ${_MCM_SYNC_STARTED:-} " == *" ${own} "* ]]; then
            own=""
        fi
    fi
    if (( ! want_stop )) && [[ -z "${own}" ]]; then
        return 0
    fi

    if [[ -n "${own}" ]]; then
        _mcm_wait_stopping "${cluster}"
    fi
    states="$(podman ps -a --format '{{.Names}} {{.State}}' 2>/dev/null)" || rc=$?
    # The VM went down after env_bootstrap.sh looked at it, before this run's lease.
    if (( rc != 0 && ! long_lived )) && [[ "${mode}" != stop-only ]] && _mcm_restart_stopped_vm; then
        rc=0
        states="$(podman ps -a --format '{{.Names}} {{.State}}' 2>/dev/null)" || rc=$?
    fi
    if (( rc != 0 )); then
        if [[ -z "${_MCM_SYNC_WARNED:-}" ]]; then
            _mcm_warn "podman is not reachable; skipping the container sync, the run continues."
            if (( ! long_lived )); then
                export _MCM_SYNC_WARNED=1
            fi
        fi
        return 0
    fi
    for line in "${(@f)states}"; do
        words=(${=line})
        if (( ${#words} >= 2 )); then
            state_of[${words[1]}]="${words[2]}"
        fi
    done

    if (( want_stop )); then
        targeted=(${=$(mcm_targeted_clusters)}) || targeted=()
        names=()
        if [[ "${MULTI_CLUSTER_MANAGEMENT}" == true ]]; then
            names=("${(@f)$(mcm_container_names)}")
        fi
        if [[ "${MCM_STOP_INACTIVE_CONTAINERS}" == true ]]; then
            for name in "${registered[@]}"; do
                if (( ! ${targeted[(Ie)${name}]} )); then
                    names+=("${(@f)$(mcm_container_names "${name}")}")
                fi
            done
        fi
        for container in "${names[@]}"; do
            if [[ "${state_of[${container}]:-}" == running ]]; then
                candidates+=("${container}")
            fi
        done
        total=${#candidates}
        for container in "${candidates[@]}"; do
            n=$(( n + 1 ))
            name="$(_mcm_container_cluster "${container}")" || name=""
            if mcm_container_busy "${container}"; then
                _mcm_say "Containers ${n}/${total}: ${container} is not targeted but busy, left running (${_MCM_BUSY_WHY})."
                continue
            fi
            _mcm_say "Containers ${n}/${total}: stopping ${container}, not targeted."
            stop_rc=0
            _mcm_stop_container "${container}" "${name}" || stop_rc=$?
            case "${stop_rc}" in
                0) state_of[${container}]=exited ;;
                2) _mcm_say "Containers ${n}/${total}: ${container} left running, a run has just started on it." ;;
                *) _mcm_warn "Could not stop ${container}; continuing." ;;
            esac
        done
        if (( ! long_lived )) && [[ "${mode}" != stop-only && -n "${cluster}" ]]; then
            export _MCM_SYNC_STOP_DONE="${cluster}"
        fi
    fi

    if [[ -n "${own}" ]]; then
        state="${state_of[${own}]:-}"
        case "${state}" in
            ""|running|paused|stopping|removing) ;;
            *)
                _mcm_say "Starting container ${own} (cluster ${cluster})."
                if podman start "${own}" >/dev/null 2>&1; then
                    state_of[${own}]=running
                else
                    _mcm_warn "Could not start ${own}; a later cpd-cli manage may still bring it up."
                fi
                ;;
        esac
        if [[ "${state_of[${own}]:-}" == running ]] && (( ! long_lived )); then
            export _MCM_SYNC_STARTED="${_MCM_SYNC_STARTED:-} ${own}"
        fi
    fi

    # A missing container counts as coming up: this run's cpd-cli manage creates it
    # after this point. The watcher waits for it while the run's lease is live, and
    # the cpd-cli shim starts a watcher for a manage that comes after this one has gone.
    if [[ -n "${own}" && -z "${state_of[${own}]:-}" ]]; then
        up=1
    fi
    managed=("${(@f)$(mcm_managed_containers)}") || managed=()
    for container in "${managed[@]}"; do
        if [[ "${state_of[${container}]:-}" == running ]]; then
            up=1
        fi
    done
    if (( up )); then
        mcm_ensure_idle_watcher
    fi
    return 0
}

# A busy reason fit to show or keep: a process's arguments can hold a password, so only
# the program's name stays.
_mcm_safe_busy_reason() {   # REASON
    emulate -L zsh
    local reason="$1" pid rest
    if [[ "${reason}" == "process "<->": "* ]]; then
        pid="${${reason#process }%%:*}"
        rest="${reason#process ${pid}: }"
        print -r -- "process ${pid}: ${${rest%% *}:t}"
    else
        print -r -- "${reason}"
    fi
}

# Once the mode is off nothing manages the cluster containers, and a watcher, if one
# runs at all (timeout 0 has none), only stops them when it next wakes and never warns
# anyone. So whoever turned the mode off calls this: idle ones are stopped now, busy
# ones stay and get a warning. The flat containers are left alone, a mode-off run uses
# them. No-op while the mode is on. Prints to stderr and always returns 0.
mcm_stop_idle_after_off() {
    emulate -L zsh
    local IFS=$' \t\n' states="" line name container
    local -i rc=0 total=0 n=0 stop_rc=0
    local -a words candidates
    local -A state_of

    mcm_load_state || rc=$?
    if (( rc != 0 )); then
        _mcm_warn "The multi-cluster state file is invalid; cluster containers were left as they are."
        return 0
    fi
    [[ "${MULTI_CLUSTER_MANAGEMENT}" != true ]] || return 0

    states="$(podman ps -a --format '{{.Names}} {{.State}}' 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        _mcm_warn "podman is not reachable; cluster containers were left as they are."
        return 0
    fi
    for line in "${(@f)states}"; do
        words=(${=line})
        if (( ${#words} >= 2 )); then
            state_of[${words[1]}]="${words[2]}"
        fi
    done
    for name in ${=MCM_CLUSTERS}; do
        for container in "${(@f)$(mcm_container_names "${name}")}"; do
            if [[ "${state_of[${container}]:-}" == running ]]; then
                candidates+=("${container}")
            fi
        done
    done

    total=${#candidates}
    for container in "${candidates[@]}"; do
        n=$(( n + 1 ))
        if mcm_container_busy "${container}"; then
            _mcm_warn "Containers ${n}/${total}: ${container} is busy ($(_mcm_safe_busy_reason "${_MCM_BUSY_WHY}")), left running. If you are sure, run: podman stop -t 3 ${container}"
            continue
        fi
        name="$(_mcm_container_cluster "${container}")" || name=""
        _mcm_say "Containers ${n}/${total}: stopping ${container}, multi-cluster mode is off."
        stop_rc=0
        _mcm_stop_container "${container}" "${name}" || stop_rc=$?
        case "${stop_rc}" in
            0) ;;
            2) _mcm_warn "Containers ${n}/${total}: a run has just started on cluster ${name}, ${container} left running." ;;
            *) _mcm_warn "Containers ${n}/${total}: could not stop ${container}." ;;
        esac
    done
    return 0
}

# Seconds since the epoch for a podman timestamp: plain epoch seconds (podman events
# {{.Time}} since 4.x), RFC 3339, or Go's "2006-01-02 15:04:05.999 -0700 MST" (older
# clients). Plain arithmetic, so it needs no TZ or date(1).
_mcm_epoch_from_timestamp() {
    emulate -L zsh
    setopt no_re_match_pcre
    local text="${1:-}" MATCH MBEGIN MEND zone
    local -a match mbegin mend
    local -i year mon day hour min sec era yoe doy doe offset=0
    if [[ "${text}" == <-> ]]; then
        print -r -- "${text}"
        return 0
    fi
    [[ "${text}" =~ '^([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?[ ]*(Z|[+-][0-9]{2}:?[0-9]{2})?' ]] || return 1
    year="${match[1]}"
    mon="${match[2]}"
    day="${match[3]}"
    hour="${match[4]}"
    min="${match[5]}"
    sec="${match[6]}"
    zone="${${match[8]:-}//:/}"
    if [[ "${zone}" == [+-]* ]]; then
        offset=$(( ${zone[2,3]} * 3600 + ${zone[4,5]} * 60 ))
        if [[ "${zone}" == -* ]]; then
            offset=$(( -offset ))
        fi
    fi
    if (( mon <= 2 )); then
        year=$(( year - 1 ))
    fi
    era=$(( year / 400 ))
    yoe=$(( year - era * 400 ))
    doy=$(( (153 * (mon + (mon > 2 ? -3 : 9)) + 2) / 5 + day - 1 ))
    doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
    print -r -- $(( (era * 146097 + doe - 719468) * 86400 + hour * 3600 + min * 60 + sec - offset ))
}
