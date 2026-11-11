#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# =============================================================================
# multi_cluster.sh - manages the multi-cluster switch, registered clusters and
#                    their olm-utils containers
# -----------------------------------------------------------------------------
# Plan: .claude/plans/multi-cluster-management/multi-cluster-management-plan.md (5.9)
#
# Sources only multi_cluster_helpers.sh, so it works before any config exists and
# never fans out. Exit codes: 0 done, 1 refused or failed, 2 bad usage.
#
# Delineation is one-way per cluster (decision 2026-11-10): a cluster with a .cluster
# marker never goes back to the flat layout. 'off' only flips the repo default, 'remove'
# retires (marker kept, RETIRED="true"), only 'remove --purge' deletes the marker.
# =============================================================================

usage() {
    cat <<'EOF'
Manage multi-cluster mode, the registered clusters and their containers.

  multi_cluster.sh status
  multi_cluster.sh on  [--migrate | --no-migrate]
  multi_cluster.sh off
  multi_cluster.sh list
  multi_cluster.sh add [NAME] [--url URL] [--copy-from CLUSTER] [--use]
  multi_cluster.sh use NAME
  multi_cluster.sh targets a,b,c | --clear
  multi_cluster.sh apply-to-all true|false
  multi_cluster.sh rename OLD NEW
  multi_cluster.sh remove NAME [--purge]
  multi_cluster.sh containers status | start NAME | stop NAME | stop-all

Delineation is one-way per cluster. A cluster with a folder in configs/clusters/NAME/
(made by add or by a migration) is delineated for good: it never goes back to the flat
configs/ layout, and a flat config pointing at its URL is refused. Per-cluster folders are
the preferred layout. The on/off switch (MULTI_CLUSTER_MANAGEMENT) is only the repo
default: for new clusters and for runs that name no cluster.

status        The default, the delineated and retired clusters, the selection and the
              container settings. Warns about flat configs that point at a delineated cluster.
list          Each cluster folder: current, targeted, state (active, retired, unregistered
              or folder only) and URL, then the default and the delineated clusters.
on            Makes per-cluster folders the default. Flat configs in configs/*_config prompt
              for a migration (migrate_to_multi_cluster.sh shows its plan and asks before
              moving anything); each cluster it moves is delineated for good. --migrate runs
              it with no prompts; --no-migrate leaves the flat configs alone.
off           Makes the flat layout the default again: runs that name no cluster read the flat
              configs in configs/*_config. Delineated clusters stay delineated and can still be
              named: --target-cluster NAME, --target-clusters a,b, --all-clusters or
              MCM_CLUSTER=NAME. Idle cluster containers are stopped. Refused while a run holds
              a lease on any cluster, or (mode on) while an install slot launched from here
              exists in any cluster. No cluster can be moved back to the flat layout.
add           Registers a cluster. NAME defaults to the label after 'api.' in --url, or in
              OCP_URL from the environment. A new cluster folder is delineated for good, so
              add warns that this cannot be undone. A retired cluster is re-activated with
              its files as they were. --copy-from copies the *_config folders of
              another cluster (not openshift_config, whose files belong to one cluster, nor
              workspaces, nor *_instance_details.sh and managed-service-instances/, which
              describe the source cluster's live install). With --url the copied configs
              get the new URL. Tokens are copied as they are, so log in again before using
              them. --use also makes it current.
use           Sets the current cluster, then stops idle containers that left the target set.
targets       Runs each command on these clusters; beats apply-to-all. --clear empties it.
apply-to-all  Runs each command on every registered cluster.
              use, targets and apply-to-all select only while the mode is on.
rename        Renames a cluster: its folders, marker and state entries. Its containers are
              removed and cpd-cli recreates them under the new name on next use.
remove        Retires a cluster: unregisters it and removes its containers. Its folder and
              marker stay, so it stays delineated, is not re-added when the state file is
              rebuilt, and comes back with add NAME. --purge deletes its folders instead
              (it lists them and asks you to type the cluster name), so nothing remains.
containers    status: each container's state, whether its cluster is targeted, idle time
              and time left before auto-stop. start: refused unless the cluster is targeted
              (with the mode off, only a cluster the run names: MCM_CLUSTER=NAME).
              stop and stop-all leave a busy container running.

rename and remove are refused while the cluster has a live run, a busy container, or an
install slot launched from here (INSTALL_RUN_MODE=cluster): tear it down first with
scripts/install_runner/x_install_runner.sh teardown --target-cluster NAME --slot SLOT.
Add --forget when the cluster no longer exists: it clears only this machine's record.

  --help, -h  Show this help.
EOF
}

# --- Paths -------------------------------------------------------------------
MCM_CLI_REPO="${0:A:h}"
while [[ "${MCM_CLI_REPO}" != "/" && ! -f "${MCM_CLI_REPO}/env_bootstrap.sh" ]]; do
    MCM_CLI_REPO="${MCM_CLI_REPO:h}"
done
if [[ "${MCM_CLI_REPO}" == "/" ]]; then
    print -r -- "[ERROR] Cannot find the repo root (env_bootstrap.sh) above ${0:A:h}." >&2
    exit 1
fi
_CP4D_REPO_ROOT="${MCM_CLI_REPO}"
MCM_CLI_MIGRATE="${0:A:h}/migrate_to_multi_cluster.sh"

source "${MCM_CLI_REPO}/src/helpers/multi_cluster_helpers.sh"
source "${MCM_CLI_REPO}/src/helpers/install_runner_slots.sh"

zmodload zsh/datetime
zmodload -F zsh/stat b:zstat

MCM_CLI_CLUSTERS_ROOT="$(mcm_clusters_root)"
MCM_CLI_CONFIGS="${MCM_CLI_CLUSTERS_ROOT:h}"
MCM_CLI_CPD_CLI_CLUSTERS="$(_mcm_clusters_home)"

typeset -gA MCM_CLI_STATE_OF

_mcm_cli_info() { print -r -- "[INFO] $*"; }
_mcm_cli_die() { print -r -- "[ERROR] $*" >&2; exit 1; }
_mcm_cli_bad_usage() { print -r -- "[ERROR] $* See --help." >&2; exit 2; }
_mcm_cli_is_on() { [[ "${MULTI_CLUSTER_MANAGEMENT}" == true ]]; }
_mcm_cli_note_mode_off() {
    if ! _mcm_cli_is_on; then
        _mcm_cli_info "Multi-cluster mode is off, so this takes effect once it is on (multi_cluster.sh on)."
    fi
}

# The global flag is only the default; delineation is per cluster and one-way.
_mcm_cli_default_text() {
    if _mcm_cli_is_on; then
        print -r -- "per-cluster folders (configs/clusters/NAME/) for runs that name no cluster and for new clusters"
    else
        print -r -- "the flat configs/ layout for runs that name no cluster; delineated clusters are named with --target-cluster NAME"
    fi
}

# Every cluster folder that gets its first marker says so: there is no way back.
_mcm_cli_warn_one_way() {   # NAME
    _mcm_warn "Cluster $1 is now delineated: its configs live in configs/clusters/$1/. Per-cluster management is the preferred layout, but it cannot be undone for this cluster: it never goes back to the flat configs/ layout, and flat configs pointing at its URL are refused."
    _mcm_warn "To drop $1 later: multi_cluster.sh remove $1 (retires it, files kept) or remove $1 --purge (deletes its files)."
}

# Sets reply to "FILE URL CLUSTER" triples: flat *_vars.sh files whose OCP_URL belongs to
# a delineated cluster (ONLY: just that one). A flat run refuses to load those.
_mcm_cli_flat_conflicts() {   # [ONLY]
    local only="${1:-}" file url owner
    reply=()
    for file in "${MCM_CLI_CONFIGS}"/*_config/**/*_vars.sh(.DN); do
        url="$(_mcm_cli_config_url "${file}")"
        [[ -n "${url}" ]] || continue
        owner="$(mcm_cluster_for_url "${url}")"
        [[ -n "${owner}" ]] || continue
        if [[ -z "${only}" || "${owner}" == "${only}" ]]; then
            reply+=("${file}" "${url}" "${owner}")
        fi
    done
}

_mcm_cli_warn_flat_conflicts() {   # [ONLY]
    local -i i
    local -a found
    _mcm_cli_flat_conflicts "${1:-}"
    found=("${reply[@]}")
    for (( i = 1; i <= ${#found}; i += 3 )); do
        _mcm_warn "Flat config ${found[i]#${MCM_CLI_CONFIGS:h}/} points at ${found[i+1]}, which belongs to the delineated cluster '${found[i+2]}'. Flat runs refuse it; edit the config in configs/clusters/${found[i+2]}/ instead, or move this copy to configs/old_configs/."
    done
}

_mcm_cli_note_pin() {
    if [[ -n "${MCM_CLUSTER:-}" ]]; then
        _mcm_cli_info "This shell is pinned to ${MCM_CLUSTER} (MCM_CLUSTER). Source s_env.sh again to follow the new selection."
    fi
}

_mcm_cli_require_registered() {   # NAME
    mcm_validate_name "${1:-}" || exit 2
    if ! mcm_is_registered "$1"; then
        _mcm_cli_die "Cluster '$1' is not registered. Registered: ${MCM_CLUSTERS:-none}."
    fi
}

_mcm_cli_duration() {   # SECONDS
    local -i secs="${1:-0}" days hours minutes
    days=$(( secs / 86400 ))
    hours=$(( secs % 86400 / 3600 ))
    minutes=$(( secs % 3600 / 60 ))
    if (( secs < 60 )); then
        print -r -- "<1m"
    elif (( days > 0 )); then
        print -r -- "${days}d ${hours}h"
    elif (( hours > 0 )); then
        printf '%dh %02dm\n' "${hours}" "${minutes}"
    else
        print -r -- "${minutes}m"
    fi
}

# Sets MCM_CLI_STATE_OF (container -> state). 1 when podman cannot be reached.
_mcm_cli_read_states() {
    local out="" line
    local -a words
    MCM_CLI_STATE_OF=()
    out="$(podman ps -a --format '{{.Names}} {{.State}}' 2>/dev/null)" || return 1
    for line in "${(@f)out}"; do
        words=(${=line})
        if (( ${#words} >= 2 )); then
            MCM_CLI_STATE_OF[${words[1]}]="${words[2]}"
        fi
    done
    return 0
}

_mcm_cli_state() { print -r -- "${MCM_CLI_STATE_OF[$1]:-}"; }   # CONTAINER

# Runs the migration utility; a non-zero exit ends this script with the same code.
_mcm_cli_run_migrate() {   # ARG...
    local rc=0
    if [[ ! -f "${MCM_CLI_MIGRATE}" ]]; then
        _mcm_cli_die "The migration utility is missing: ${MCM_CLI_MIGRATE}"
    fi
    zsh "${MCM_CLI_MIGRATE}" "$@" || rc=$?
    if (( rc != 0 )); then
        print -r -- "[ERROR] migrate_to_multi_cluster.sh failed (exit ${rc}); see its output above." >&2
        exit "${rc}"
    fi
    mcm_load_state || exit 1
}

# --- Moving folders and text -------------------------------------------------
# Literal replace. Keeps the file's mode; a file without FROM is not rewritten.
_mcm_cli_replace_in_file() {   # FILE FROM TO
    local file="$1" from="$2" to="$3" text="" tmp
    IFS= read -rd '' text < "${file}" || true
    [[ "${text}" == *"${from}"* ]] || return 0
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    if ! cp -p "${file}" "${tmp}" || ! print -rn -- "${text//${(b)from}/${to}}" > "${tmp}" || ! mv -f "${tmp}" "${file}"; then
        rm -f "${tmp}"
        return 1
    fi
    return 0
}

# FROM as a whole path (shared with migrate_to_multi_cluster.sh): see the helper.
_mcm_cli_replace_path_in_file() {   # FILE FROM TO
    mcm_replace_path_in_file "$@"
}

# Generated configs embed absolute paths (ssl.truststore.location in *.properties).
_mcm_cli_rewrite_config_paths() {   # CLUSTER_FOLDER FROM TO
    local root="$1" from="$2" to="$3" file
    for file in "${root}"/*_config/**/*.(sh|properties)(.DN); do
        if ! _mcm_cli_replace_path_in_file "${file}" "${from}" "${to}"; then
            _mcm_warn "Could not update paths in ${file}; it still points at ${from}."
        fi
    done
}

# --- Guards ------------------------------------------------------------------
_mcm_cli_refuse_live_run() {   # NAME
    if _mcm_lease_live "$1"; then
        _mcm_cli_die "A run is live on cluster '$1' (${MCM_CLI_CPD_CLI_CLUSTERS}/$1/.leases). Wait for it to finish, then retry."
    fi
}

# An install handed to a pod (INSTALL_RUN_MODE=cluster) holds no lease and leaves no
# local process, so only its launch record shows it (gap X15, decision D5). Removing,
# renaming or purging the cluster would strand the slot: no command here could reach
# it again, and its volume keeps a copy of the config with credentials.
_mcm_cli_refuse_remote_slots() {   # NAME | --clusters
    local records
    if [[ "$1" == --clusters ]]; then
        records="$(ir_slot_records --clusters)"
    else
        records="$(ir_slot_records --cluster "$1")"
    fi
    [[ -n "${records}" ]] || return 0
    ir_slot_records_explain "${records}"
    _mcm_cli_die "Nothing was changed."
}

# Refuses when a run, a busy container or a slot in the cluster means it is in use.
# Podman must answer: its containers have to be removed, and a VM that is down hides them.
_mcm_cli_require_quiet() {   # NAME
    local name="$1" container
    _mcm_cli_refuse_live_run "${name}"
    _mcm_cli_refuse_remote_slots "${name}"
    if ! command -v podman >/dev/null 2>&1; then
        return 0
    fi
    if ! _mcm_cli_read_states; then
        _mcm_cli_die "podman is not reachable, so the containers of '${name}' cannot be checked or removed. Start it (podman machine start) and retry."
    fi
    for container in "${(@f)$(mcm_container_names "${name}")}"; do
        if [[ "$(_mcm_cli_state "${container}")" == running ]] && mcm_container_busy "${container}"; then
            _mcm_cli_die "Container ${container} is busy (${_MCM_BUSY_WHY}). Wait for it to finish, then retry."
        fi
    done
}

_mcm_cli_remove_containers() {   # NAME
    local name="$1" container custom
    if ! command -v podman >/dev/null 2>&1; then
        return 0
    fi
    for container in "${(@f)$(mcm_container_names "${name}")}"; do
        if [[ -n "$(_mcm_cli_state "${container}")" ]]; then
            _mcm_cli_info "Removing container ${container}"
            if ! podman rm -f "${container}" >/dev/null 2>&1; then
                _mcm_cli_die "Could not remove container ${container}. Remove it with: podman rm -f ${container}"
            fi
        fi
    done
    custom="${MCM_CLI_CPD_CLI_CLUSTERS}/${name}/.custom_containers"
    rm -f "${custom}"
}

# State file without NAME. The marker is left alone: remove retires it (it stays
# delineated) and remove --purge deletes the whole folder. 1 when the write fails.
_mcm_cli_unregister() {   # NAME
    local name="$1"
    local -a list targets updates
    mcm_load_state || return 1
    list=(${=MCM_CLUSTERS})
    targets=(${=MCM_TARGET_CLUSTERS})
    list=("${(@)list:#${name}}")
    targets=("${(@)targets:#${name}}")
    updates=("MCM_CLUSTERS=${(j: :)list}" "MCM_TARGET_CLUSTERS=${(j: :)targets}")
    if [[ "${MCM_CURRENT_CLUSTER}" == "${name}" ]]; then
        updates+=("MCM_CURRENT_CLUSTER=")
    fi
    mcm_write_state "${updates[@]}"
}

# remove without --purge. The marker is retired first, so a rebuilt state file never
# brings the cluster back; a failed state write undoes the marker change.
_mcm_cli_retire() {   # NAME
    local name="$1"
    mcm_mark_retired "${name}" || exit 1
    if ! _mcm_cli_unregister "${name}"; then
        mcm_unretire "${name}" || true
        _mcm_cli_die "Could not update the state file; cluster '${name}' was left as it was."
    fi
}

# --- status, list ------------------------------------------------------------
_mcm_cli_flat_products() {   # sets reply
    local dir
    local -a kids
    reply=()
    for dir in "${MCM_CLI_CONFIGS}"/*_config(/N); do
        [[ "${dir:t}" != openshift_config ]] || continue
        kids=("${dir}"/*(N[1]))
        if (( ${#kids} > 0 )); then
            reply+=("${dir:t}")
        fi
    done
}

# Sets reply to the retired clusters among the delineated ones, in byte order.
_mcm_cli_retired_clusters() {
    local name
    reply=()
    for name in ${=$(mcm_delineated_clusters)}; do
        if mcm_is_retired "${name}"; then
            reply+=("${name}")
        fi
    done
}

cmd_status() {
    local targeted="" delineated="" line
    local -a flat retired remote
    if (( $# > 0 )); then
        _mcm_cli_bad_usage "status takes no arguments."
    fi
    _mcm_cli_flat_products
    flat=("${reply[@]}")
    _mcm_cli_retired_clusters
    retired=("${reply[@]}")
    delineated="$(mcm_delineated_clusters)" || delineated=""
    # Mode off: only this run's own explicit targets (MCM_CLUSTER) count.
    targeted="$(mcm_targeted_clusters)" || targeted=""
    print -r -- "Multi-cluster management:  $(_mcm_cli_is_on && print on || print off)"
    print -r -- "Default layout:            $(_mcm_cli_default_text)"
    print -r -- "State file:                $(mcm_state_file)"
    print -r -- "Delineated clusters:       ${delineated:-none}${delineated:+ (one-way: they never go back to the flat layout)}"
    print -r -- "Retired clusters:          ${retired[*]:-none}"
    print -r -- "Registered clusters:       ${MCM_CLUSTERS:-none}"
    print -r -- "Current cluster:           ${MCM_CURRENT_CLUSTER:-none}"
    print -r -- "MCM_TARGET_CLUSTERS:       ${MCM_TARGET_CLUSTERS:-none}"
    print -r -- "APPLY_TO_ALL:              ${APPLY_TO_ALL}"
    print -r -- "Targeted now:              ${targeted:-none}"
    print -r -- "Stop inactive containers:  ${MCM_STOP_INACTIVE_CONTAINERS}"
    if (( MCM_CONTAINER_IDLE_TIMEOUT_MINUTES > 0 )); then
        print -r -- "Container idle timeout:    ${MCM_CONTAINER_IDLE_TIMEOUT_MINUTES} minutes"
    else
        print -r -- "Container idle timeout:    never (0)"
    fi
    print -r -- "Stop idle podman VM:       ${MCM_STOP_IDLE_PODMAN_VM}"
    # From the launch records, so it needs no cluster (gap X16): <cluster>/<slot>.
    for line in "${(@f)$(ir_slot_records)}"; do
        [[ -n "${line}" ]] || continue
        remote+=("${${${(ps:\t:)line}[1]}/#%-/flat}/${${(ps:\t:)line}[2]}")
    done
    print -r -- "Remote runs:               ${#remote}${remote:+ (${(j:, :)remote}; see x_install_runner.sh status --all-clusters)}"
    if [[ -n "${MCM_CLUSTER:-}" ]]; then
        print -r -- "This shell is pinned to:   ${MCM_CLUSTER} (MCM_CLUSTER)"
    fi
    if ! _mcm_cli_is_on && [[ -n "${MCM_CLUSTERS}" ]]; then
        _mcm_cli_info "The mode is off: the current cluster, MCM_TARGET_CLUSTERS and APPLY_TO_ALL select nothing. Name a delineated cluster per run with --target-cluster NAME."
    fi
    if _mcm_cli_is_on && (( ${#flat} > 0 )); then
        _mcm_warn "Flat configs are not used while the mode is on: ${flat[*]}. Move them with migrate_to_multi_cluster.sh."
    elif ! _mcm_cli_is_on; then
        _mcm_cli_warn_flat_conflicts
    fi
}

cmd_list() {
    local name url mark target kind
    local -a names targeted folders others retired
    local -i width=7
    if (( $# > 0 )); then
        _mcm_cli_bad_usage "list takes no arguments."
    fi
    names=(${=MCM_CLUSTERS})
    targeted=(${=$(mcm_targeted_clusters)})
    folders=("${MCM_CLI_CLUSTERS_ROOT}"/*(/N:t))
    others=("${(@)folders:|names}")
    if (( ${#names} == 0 && ${#others} == 0 )); then
        _mcm_cli_info "No clusters registered. Add one with: multi_cluster.sh add NAME --url URL"
        _mcm_cli_info "Default (multi-cluster mode $(_mcm_cli_is_on && print on || print off)): $(_mcm_cli_default_text)."
        return 0
    fi
    for name in "${names[@]}" "${others[@]}"; do
        if (( ${#name} > width )); then
            width=${#name}
        fi
    done
    printf '%-*s  %-7s  %-8s  %-12s  %s\n' "${width}" CLUSTER CURRENT TARGETED STATE URL
    for name in "${names[@]}"; do
        url="$(_mcm_marker_value "${MCM_CLI_CLUSTERS_ROOT}/${name}/.cluster" OCP_URL)"
        mark="-"
        target="no"
        if [[ "${name}" == "${MCM_CURRENT_CLUSTER}" ]]; then
            mark="*"
        fi
        if (( ${targeted[(Ie)${name}]} )); then
            target="yes"
        elif ! _mcm_cli_is_on; then
            target="-"
        fi
        printf '%-*s  %-7s  %-8s  %-12s  %s\n' "${width}" "${name}" "${mark}" "${target}" active "${url:--}"
    done
    for name in "${others[@]}"; do
        url="$(_mcm_marker_value "${MCM_CLI_CLUSTERS_ROOT}/${name}/.cluster" OCP_URL)"
        if mcm_is_retired "${name}"; then
            kind=retired
            retired+=("${name}")
        elif mcm_is_delineated "${name}"; then
            kind=unregistered
            url="${url:--}  (delineated, not registered: multi_cluster.sh add ${name})"
        else
            kind="folder only"
            url="not registered (add it with: multi_cluster.sh add ${name})"
        fi
        printf '%-*s  %-7s  %-8s  %-12s  %s\n' "${width}" "${name}" "-" "-" "${kind}" "${url:--}"
    done
    _mcm_cli_info "Default (multi-cluster mode $(_mcm_cli_is_on && print on || print off)): $(_mcm_cli_default_text)."
    _mcm_cli_info "Delineated clusters (one-way, they never go back to the flat layout): $(mcm_delineated_clusters)"
    if (( ${#retired} > 0 )); then
        _mcm_cli_info "Retired clusters stay delineated: ${retired[*]}. Bring one back with multi_cluster.sh add NAME, or delete it with remove NAME --purge."
    fi
}

# --- on, off -----------------------------------------------------------------
# A flat chain resolves its cluster again at each nested step, so turning the mode on
# under it would carry on with another cluster's config. The migration's own preflight.
_mcm_cli_preflight_turn_on() {
    local rc=0
    if [[ ! -f "${MCM_CLI_MIGRATE}" ]]; then
        _mcm_cli_die "The migration utility is missing: ${MCM_CLI_MIGRATE}"
    fi
    # Nothing moves here, so a slot of a delineated cluster is no reason to refuse (only
    # a flat slot's collect and teardown depend on the flat layout staying the default).
    _MCM_MIG_FLAT_SLOTS_ONLY=true zsh "${MCM_CLI_MIGRATE}" --preflight-only || rc=$?
    if (( rc != 0 )); then
        _mcm_cli_die "Multi-cluster mode stays off (see the preflight errors above). Retry once they are cleared."
    fi
}

_mcm_cli_turn_on() {
    _mcm_cli_preflight_turn_on
    mcm_write_state "MULTI_CLUSTER_MANAGEMENT=true" || exit 1
    _mcm_cli_info "Multi-cluster mode is on. Clusters: ${MCM_CLUSTERS:-none}."
    if [[ -z "${MCM_CLUSTERS}" ]]; then
        _mcm_cli_info "Add a cluster with: multi_cluster.sh add NAME --url URL --use"
    fi
}

cmd_on() {
    local migrate=prompt answer=""
    local -a flat
    while (( $# > 0 )); do
        case "$1" in
            --migrate)
                [[ "${migrate}" != no ]] || _mcm_cli_bad_usage "--migrate and --no-migrate cannot be combined."
                migrate=yes; shift ;;
            --no-migrate)
                [[ "${migrate}" != yes ]] || _mcm_cli_bad_usage "--migrate and --no-migrate cannot be combined."
                migrate=no; shift ;;
            *) _mcm_cli_bad_usage "Unknown option for on: $1." ;;
        esac
    done

    _mcm_cli_flat_products
    flat=("${reply[@]}")

    if (( ${#flat} == 0 )); then
        if _mcm_cli_is_on; then
            _mcm_cli_info "Multi-cluster mode is already on."
        else
            _mcm_cli_turn_on
        fi
        return 0
    fi

    if [[ "${migrate}" == prompt ]] && _mcm_cli_is_on; then
        _mcm_cli_info "Multi-cluster mode is already on. Flat configs are not used: ${flat[*]}. Move them with: multi_cluster.sh on --migrate"
        return 0
    fi
    if [[ "${migrate}" == prompt ]]; then
        _mcm_cli_info "Flat (single-cluster) configs found: ${flat[*]}."
        _mcm_cli_info "They are not used while the mode is on. Migrating moves them into per-cluster folders."
        _mcm_cli_info "Migrating is one-way for each cluster it moves: per-cluster folders are preferred, but those clusters never go back to the flat layout."
        print -n -- "Migrate them now? [y/N] "
        if ! read -r answer; then
            print
            _mcm_cli_die "No answer available. Re-run with --migrate or --no-migrate."
        fi
        if [[ "${answer}" == [Yy]* ]]; then
            _mcm_cli_run_migrate
            if ! _mcm_cli_is_on; then
                _mcm_cli_info "Not migrated, so the mode stays off. To turn it on without migrating: multi_cluster.sh on --no-migrate"
            fi
            return 0
        fi
        migrate=no
    fi

    if [[ "${migrate}" == yes ]]; then
        _mcm_cli_run_migrate --yes
        if ! _mcm_cli_is_on; then
            _mcm_cli_turn_on
        fi
        return 0
    fi

    if ! _mcm_cli_is_on; then
        _mcm_cli_turn_on
    fi
    _mcm_warn "Flat configs stay where they are and are not used while the mode is on: ${flat[*]}. Migrate later with: multi_cluster.sh on --migrate"
}

# With the mode off only runs that name a cluster manage its containers, so the idle
# ones are stopped now rather than left running until such a run comes along.
_mcm_cli_stop_clusters_after_off() {
    local name container
    local -a candidates
    if ! _mcm_cli_read_states; then
        _mcm_warn "podman is not reachable; cluster containers were left as they are."
        return 0
    fi
    for name in ${=MCM_CLUSTERS}; do
        for container in "${(@f)$(mcm_container_names "${name}")}"; do
            if [[ "$(_mcm_cli_state "${container}")" == running ]]; then
                candidates+=("${container}")
            fi
        done
    done
    _mcm_cli_stop_list "${candidates[@]}"
    return 0
}

cmd_off() {
    local name was_on=false
    local -a delineated
    while (( $# > 0 )); do
        case "$1" in
            --restore|--restore=*)
                print -r -- "[ERROR] off --restore was removed: delineation is one-way per cluster. A cluster in configs/clusters/NAME/ stays there for good and never goes back to the flat configs/ layout." >&2
                print -r -- "[ERROR] Use multi_cluster.sh off to make the flat layout the default again; name a delineated cluster per run with --target-cluster NAME." >&2
                exit 2
                ;;
            *) _mcm_cli_bad_usage "Unknown option for off: $1." ;;
        esac
    done

    # A chain still running would load the flat layout at its next step.
    for name in ${=MCM_CLUSTERS}; do
        _mcm_cli_refuse_live_run "${name}"
    done
    # Commands with no cluster flag would go flat, away from the slots' clusters.
    if _mcm_cli_is_on; then
        _mcm_cli_refuse_remote_slots --clusters
    fi

    if _mcm_cli_is_on; then
        was_on=true
    fi
    mcm_write_state "MULTI_CLUSTER_MANAGEMENT=false" || exit 1
    if [[ "${was_on}" == true ]]; then
        _mcm_cli_info "Multi-cluster mode is off: runs that name no cluster now read the flat configs in ${MCM_CLI_CONFIGS}."
    else
        _mcm_cli_info "Multi-cluster mode is already off: runs that name no cluster read the flat configs in ${MCM_CLI_CONFIGS}."
    fi
    delineated=(${=$(mcm_delineated_clusters --exclude-retired)})
    if (( ${#delineated} > 0 )); then
        _mcm_warn "Delineated clusters stay delineated (one-way) in ${MCM_CLI_CLUSTERS_ROOT}: ${delineated[*]}."
        _mcm_warn "They can still be named explicitly: --target-cluster NAME, --target-clusters a,b, --all-clusters, or MCM_CLUSTER=NAME. Flat configs pointing at their URLs are refused."
    fi
    _mcm_cli_warn_flat_conflicts
    _mcm_cli_stop_clusters_after_off
}

# --- add, use, targets, apply-to-all -----------------------------------------
# Refuses before anything is created when a folder to be copied is already there.
_mcm_cli_check_copy() {   # FROM NAME
    local from="$1" name="$2" src_root dst_root dir
    local -a folders
    if [[ "${from}" == "${name}" ]]; then
        _mcm_cli_die "--copy-from must name another cluster."
    fi
    src_root="$(mcm_cluster_root "${from}")" || exit 2
    dst_root="$(mcm_cluster_root "${name}")" || exit 2
    if [[ ! -d "${src_root}" ]]; then
        _mcm_cli_die "No such cluster folder to copy from: ${src_root}"
    fi
    folders=("${src_root}"/*_config(/N))
    folders=("${(@)folders:#*/openshift_config}")
    if (( ${#folders} == 0 )); then
        _mcm_cli_die "Cluster '${from}' has no *_config folders to copy."
    fi
    for dir in "${folders[@]}"; do
        if [[ -e "${dst_root}/${dir:t}" ]]; then
            _mcm_cli_die "${dst_root}/${dir:t} already exists; --copy-from will not overwrite it."
        fi
    done
}

_mcm_cli_copy_configs() {   # FROM NAME URL
    local from="$1" name="$2" url="$3" src_root dst_root dir file old_url
    local -a folders files kept unread live
    src_root="$(mcm_cluster_root "${from}")" || exit 2
    dst_root="$(mcm_cluster_root "${name}")" || exit 2
    folders=("${src_root}"/*_config(/N))
    folders=("${(@)folders:#*/openshift_config}")
    for dir in "${folders[@]}"; do
        if ! cp -Rp "${dir}" "${dst_root}/${dir:t}"; then
            _mcm_cli_die "Could not copy ${dir} to ${dst_root}"
        fi
    done
    # These describe the live install of the source cluster (its Software Hub URL, admin
    # password and API key). Under the new cluster, REST calls would change the source one.
    live=("${dst_root}"/*_config/**/*_instance_details.sh(.DN) "${dst_root}"/*_config/**/managed-service-instances(/DN))
    if (( ${#live} > 0 )); then
        if ! rm -rf -- "${live[@]}"; then
            _mcm_cli_die "Could not remove the source cluster's instance details from ${dst_root}"
        fi
        _mcm_cli_info "Not copied, they describe ${from}'s live install: ${(j:, :)${(@u)live:t}}"
    fi
    _mcm_cli_rewrite_config_paths "${dst_root}" "${src_root}" "${dst_root}"
    _mcm_cli_rewrite_config_paths "${dst_root}" "${MCM_CLI_CPD_CLI_CLUSTERS}/${from}" "${MCM_CLI_CPD_CLI_CLUSTERS}/${name}"

    files=("${dst_root}"/*_config/**/*_vars.sh(.DN))
    for file in "${files[@]}"; do
        old_url="$(_mcm_cli_config_url "${file}")"
        if [[ -z "${old_url}" ]]; then
            if grep -Eq '^[[:space:]]*(export[[:space:]]+)?OCP_URL=' "${file}"; then
                unread+=("${file#${dst_root}/}")
            fi
            continue
        fi
        if [[ -n "${url}" ]]; then
            if [[ "${old_url}" != "${url}" ]] && ! _mcm_cli_replace_in_file "${file}" "${old_url}" "${url}"; then
                _mcm_cli_die "Could not set the URL in ${file}"
            fi
        else
            kept+=("${old_url}")
        fi
    done
    _mcm_cli_info "Copied from ${from}: ${folders[*]:t}"
    if (( ${#unread} > 0 )); then
        _mcm_warn "Could not read an OCP_URL in ${unread[*]}. Check it before running on ${name}."
    fi
    if (( ${#kept} > 0 )); then
        _mcm_warn "The copied configs still point at ${${(@u)kept}[*]}. Edit OCP_URL and the login commands before running on ${name}."
    elif [[ -n "${url}" ]]; then
        _mcm_warn "The copied login commands still hold ${from}'s tokens or passwords. Update them before running on ${name}."
    fi
}

# The first non-empty literal OCP_URL, as multi_cluster_notebook.url_in_text reads it:
# the Concert template ends with a conditional export OCP_URL="".
_mcm_cli_config_url() {   # FILE; prints the URL, without sourcing the file
    setopt local_options extended_glob
    local line value="" quote
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" == ([[:space:]]#)(export[[:space:]]##)#OCP_URL=* ]]; then
            value="${line#*=}"
            quote="${value[1]}"
            if [[ "${quote}" == [\"\'] ]]; then
                value="${value[2,-1]}"
                [[ "${value}" == *"${quote}"* ]] || continue
                value="${value%%${quote}*}"
            else
                value="${value%%[[:space:]]*}"
            fi
            if [[ -n "${value}" && "${value}" != *\$* && "${value}" != \#* ]]; then
                print -r -- "${value}"
                return 0
            fi
        fi
    done < "${1}"
    print -r -- ""
}

_mcm_cli_sync() {
    mcm_sync_containers stop-only
}

cmd_add() {
    local name="" url="" copy_from="" use=false source_url=""
    while (( $# > 0 )); do
        case "$1" in
            --url)
                [[ -n "${2:-}" ]] || _mcm_cli_bad_usage "--url needs a value."
                url="$2"; shift 2 ;;
            --url=*)
                url="${1#*=}"; shift
                [[ -n "${url}" ]] || _mcm_cli_bad_usage "--url needs a value." ;;
            --copy-from)
                [[ -n "${2:-}" ]] || _mcm_cli_bad_usage "--copy-from needs a cluster name."
                copy_from="$2"; shift 2 ;;
            --copy-from=*)
                copy_from="${1#*=}"; shift
                [[ -n "${copy_from}" ]] || _mcm_cli_bad_usage "--copy-from needs a cluster name." ;;
            --use) use=true; shift ;;
            -*) _mcm_cli_bad_usage "Unknown option for add: $1." ;;
            *)
                [[ -z "${name}" ]] || _mcm_cli_bad_usage "add takes one NAME (got '${name}' and '$1')."
                name="$1"; shift ;;
        esac
    done
    if [[ -z "${name}" ]]; then
        source_url="${url:-${OCP_URL:-}}"
        if [[ -z "${source_url}" ]]; then
            _mcm_cli_bad_usage "add needs NAME or --url."
        fi
        name="$(mcm_name_from_url "${source_url}")" || exit 1
        url="${source_url}"
    fi
    mcm_validate_name "${name}" || exit 2
    if [[ -n "${copy_from}" ]]; then
        mcm_validate_name "${copy_from}" || exit 2
        _mcm_cli_check_copy "${copy_from}" "${name}"
    fi

    local was_delineated=false was_retired=false
    if mcm_is_delineated "${name}"; then
        was_delineated=true
        if mcm_is_retired "${name}"; then
            was_retired=true
        fi
    fi
    # A retired cluster comes back as it was: unretire, then register as usual.
    if [[ "${was_retired}" == true ]]; then
        mcm_unretire "${name}" || exit 1
    fi
    if ! mcm_register "${name}" "${url}"; then
        if [[ "${was_retired}" == true ]]; then
            mcm_mark_retired "${name}" || true
        fi
        exit 1
    fi
    local shown_url="${url}"
    [[ -n "${shown_url}" ]] || shown_url="$(_mcm_marker_value "$(mcm_cluster_root "${name}")/.cluster" OCP_URL)"
    if [[ "${was_retired}" == true ]]; then
        _mcm_cli_info "Re-activated retired cluster ${name}${shown_url:+ (${shown_url})}: registered again, its files in $(mcm_cluster_root "${name}") as they were."
    else
        _mcm_cli_info "Registered cluster ${name}${shown_url:+ (${shown_url})}: $(mcm_cluster_root "${name}")"
    fi
    if [[ "${was_delineated}" == false ]]; then
        _mcm_cli_warn_one_way "${name}"
    fi
    if [[ -n "${copy_from}" ]]; then
        _mcm_cli_copy_configs "${copy_from}" "${name}" "${url}"
    fi
    if [[ "${use}" == true ]]; then
        mcm_set_current "${name}" || exit 1
        _mcm_cli_info "Current cluster: ${name}"
        _mcm_cli_sync
    fi
    _mcm_cli_warn_flat_conflicts "${name}"
    if ! _mcm_cli_is_on; then
        _mcm_cli_info "Multi-cluster mode is off: runs that name no cluster still use the flat layout. Name this one per run with --target-cluster ${name} (or MCM_CLUSTER=${name})."
    fi
}

cmd_use() {
    local name="${1:-}"
    if (( $# != 1 )); then
        _mcm_cli_bad_usage "use takes one NAME."
    fi
    mcm_validate_name "${name}" || exit 2
    mcm_set_current "${name}" || exit 1
    _mcm_cli_info "Current cluster: ${name}"
    _mcm_cli_note_pin
    _mcm_cli_note_mode_off
    _mcm_cli_sync
}

cmd_targets() {
    local name joined
    local -a names
    if [[ "${1:-}" == --clear ]]; then
        if (( $# != 1 )); then
            _mcm_cli_bad_usage "targets --clear takes nothing else."
        fi
        mcm_write_state "MCM_TARGET_CLUSTERS=" || exit 1
        _mcm_cli_info "Target list cleared."
    else
        joined="${(j:,:)@}"
        names=(${(s:,:)${joined// /,}})
        names=("${(@u)names}")
        if (( ${#names} == 0 )); then
            _mcm_cli_bad_usage "targets needs a list of clusters (a,b,c) or --clear."
        fi
        for name in "${names[@]}"; do
            _mcm_cli_require_registered "${name}"
        done
        mcm_write_state "MCM_TARGET_CLUSTERS=${(j: :)names}" || exit 1
        _mcm_cli_info "Target list: ${names[*]}"
    fi
    _mcm_cli_note_pin
    _mcm_cli_note_mode_off
    _mcm_cli_sync
}

cmd_apply_to_all() {
    if (( $# != 1 )) || [[ "$1" != (true|false) ]]; then
        _mcm_cli_bad_usage "apply-to-all takes true or false."
    fi
    mcm_write_state "APPLY_TO_ALL=$1" || exit 1
    _mcm_cli_info "APPLY_TO_ALL=$1"
    if [[ "$1" == true && -n "${MCM_TARGET_CLUSTERS}" ]]; then
        _mcm_cli_info "MCM_TARGET_CLUSTERS is set and wins over APPLY_TO_ALL: ${MCM_TARGET_CLUSTERS}"
    fi
    _mcm_cli_note_pin
    _mcm_cli_note_mode_off
    _mcm_cli_sync
}

# --- rename, remove ----------------------------------------------------------
cmd_rename() {
    local old="${1:-}" new="${2:-}" old_root new_root old_cli new_cli moved_cli=false
    local -a list targets
    if (( $# != 2 )); then
        _mcm_cli_bad_usage "rename takes OLD NEW."
    fi
    mcm_validate_name "${old}" || exit 2
    mcm_validate_name "${new}" || exit 2
    if [[ "${old}" == "${new}" ]]; then
        _mcm_cli_die "OLD and NEW are the same."
    fi
    _mcm_cli_require_registered "${old}"
    old_root="$(mcm_cluster_root "${old}")"
    new_root="$(mcm_cluster_root "${new}")"
    old_cli="$(mcm_cpd_cli_root "${old}")"
    new_cli="$(mcm_cpd_cli_root "${new}")"
    if mcm_is_registered "${new}"; then
        _mcm_cli_die "Cluster '${new}' is already registered."
    fi
    if [[ -e "${new_root}" || -L "${new_root}" ]]; then
        _mcm_cli_die "${new_root} already exists."
    fi
    if [[ -e "${new_cli}" || -L "${new_cli}" ]]; then
        _mcm_cli_die "${new_cli} already exists."
    fi
    if [[ ! -d "${old_root}" ]]; then
        _mcm_cli_die "No such cluster folder: ${old_root}"
    fi

    _mcm_cli_require_quiet "${old}"
    _mcm_cli_remove_containers "${old}"
    if [[ -d "${old_cli}/.scans" ]]; then
        rm -f "${old_cli}/.scans"/*(N.)
        rmdir "${old_cli}/.scans" 2>/dev/null || true
    fi

    if ! mv "${old_root}" "${new_root}"; then
        _mcm_cli_die "Could not move ${old_root} to ${new_root}; nothing else changed."
    fi
    if [[ -e "${old_cli}" ]]; then
        if ! mv "${old_cli}" "${new_cli}"; then
            mv "${new_root}" "${old_root}" || true
            _mcm_cli_die "Could not move ${old_cli} to ${new_cli}; ${old_root} was put back."
        fi
        moved_cli=true
    fi

    if [[ -f "${new_root}/.cluster" ]]; then
        if ! _mcm_cli_replace_in_file "${new_root}/.cluster" "NAME=\"${old}\"" "NAME=\"${new}\""; then
            _mcm_warn "Could not update ${new_root}/.cluster"
        fi
    fi
    _mcm_cli_rewrite_config_paths "${new_root}" "${old_root}" "${new_root}"
    _mcm_cli_rewrite_config_paths "${new_root}" "${old_cli}" "${new_cli}"

    list=(${=MCM_CLUSTERS})
    targets=(${=MCM_TARGET_CLUSTERS})
    list=("${(@)list/#%${old}/${new}}")
    targets=("${(@)targets/#%${old}/${new}}")
    local current="${MCM_CURRENT_CLUSTER}"
    if [[ "${current}" == "${old}" ]]; then
        current="${new}"
    fi
    if ! mcm_write_state "MCM_CLUSTERS=${(j: :)list}" "MCM_TARGET_CLUSTERS=${(j: :)targets}" "MCM_CURRENT_CLUSTER=${current}"; then
        mv "${new_root}" "${old_root}" || true
        if [[ "${moved_cli}" == true ]]; then
            mv "${new_cli}" "${old_cli}" || true
        fi
        _mcm_cli_die "Could not update the state file; the folders were put back."
    fi
    _mcm_cli_info "Renamed cluster ${old} to ${new}: ${new_root}"
    if [[ "${MCM_CLUSTER:-}" == "${old}" ]]; then
        _mcm_warn "This shell is still pinned to ${old}. Run: source s_env.sh --target-cluster ${new}"
    fi
}

# Prints what a purge would delete and refuses anything that is not a plain folder
# directly in its clusters root. Sets reply to the folders to delete.
_mcm_cli_purge_preview() {   # NAME
    local name="$1" base folder entry size
    local -a entries roots
    local -i total=0 done_count=0 vars_count=0
    roots=("${MCM_CLI_CLUSTERS_ROOT}/${name}" "${MCM_CLI_CPD_CLI_CLUSTERS}/${name}")
    reply=()
    for folder in "${roots[@]}"; do
        if [[ -L "${folder}" ]]; then
            _mcm_cli_die "${folder} is a symbolic link, so it was not treated as a cluster folder. Nothing was changed."
        fi
        [[ -e "${folder}" ]] || continue
        if [[ ! -d "${folder}" ]]; then
            _mcm_cli_die "${folder} is not a folder. Nothing was changed."
        fi
        base="${folder:h:A}"
        if [[ "${folder:A}" != "${base}/${name}" ]]; then
            _mcm_cli_die "${folder} resolves to ${folder:A}, outside ${base}. Nothing was changed."
        fi
        reply+=("${folder}")
    done
    if (( ${#reply} == 0 )); then
        _mcm_cli_die "Nothing to delete for '${name}': no folder in ${MCM_CLI_CLUSTERS_ROOT} or ${MCM_CLI_CPD_CLI_CLUSTERS}."
    fi

    roots=("${reply[@]}")
    for folder in "${roots[@]}"; do
        entries=("${folder}"/*(DN))
        total+=${#entries}
    done
    print -r -- "Will be deleted permanently:"
    for folder in "${roots[@]}"; do
        print -r -- "  ${folder}/"
        entries=("${folder}"/*(DN))
        if (( ${#entries} == 0 )); then
            print -r -- "    (empty)"
        fi
        for entry in "${entries[@]}"; do
            done_count=$(( done_count + 1 ))
            print -n -- "    ${done_count}/${total}  ${entry:t}  "
            size="$(du -sh "${entry}" 2>/dev/null)" || size="?"
            print -r -- "${size%%[[:space:]]*}"
        done
    done
    entries=("${MCM_CLI_CLUSTERS_ROOT}/${name}"/*_config/**/*_vars.sh(.DN))
    vars_count=${#entries}
    if (( vars_count > 0 )); then
        _mcm_warn "This includes ${vars_count} config file(s) with credentials (*_vars.sh)."
    fi
    if [[ -f "${MCM_CLI_CLUSTERS_ROOT}/${name}/.home/.kube/config" ]]; then
        _mcm_warn "This includes the cluster's oc session (.home/.kube/config)."
    fi
    # Gap X15: a purge deletes the config here, not the slot's copy in the cluster.
    local slot_line
    for slot_line in "${(@f)$(ir_slot_records --cluster "${name}")}"; do
        [[ -n "${slot_line}" ]] || continue
        _mcm_warn "Not deleted: install slot ${${(ps:\t:)slot_line}[2]} in the cluster (${${(ps:\t:)slot_line}[4]}) holds a copy of the config with credentials, which remains on the cluster. Tear it down first."
    done
    reply=("${roots[@]}")
}

cmd_remove() {
    local name="" purge=false url="" folder answer=""
    local -a to_delete
    local -i deleted=0
    local cluster_root
    while (( $# > 0 )); do
        case "$1" in
            --purge) purge=true; shift ;;
            -*) _mcm_cli_bad_usage "Unknown option for remove: $1." ;;
            *)
                [[ -z "${name}" ]] || _mcm_cli_bad_usage "remove takes one NAME."
                name="$1"; shift ;;
        esac
    done
    if [[ -z "${name}" ]]; then
        _mcm_cli_bad_usage "remove needs NAME."
    fi
    mcm_validate_name "${name}" || exit 2
    cluster_root="$(mcm_cluster_root "${name}")"
    local registered=false delineated=false
    if mcm_is_registered "${name}"; then
        registered=true
    fi
    if mcm_is_delineated "${name}"; then
        delineated=true
    fi
    if [[ "${purge}" == false ]]; then
        if [[ "${registered}" == false ]] && mcm_is_retired "${name}"; then
            _mcm_cli_info "Cluster '${name}' is already retired: unregistered, still delineated, files kept in ${cluster_root}. Add it back with: multi_cluster.sh add ${name}, or delete it with: multi_cluster.sh remove ${name} --purge"
            return 0
        fi
        if [[ "${registered}" == false && "${delineated}" == false ]]; then
            _mcm_cli_die "Cluster '${name}' is not registered. Registered: ${MCM_CLUSTERS:-none}. Use --purge to delete a leftover folder."
        fi
    elif [[ "${registered}" == false && ! -e "${cluster_root}" && ! -e "$(mcm_cpd_cli_root "${name}")" ]]; then
        _mcm_cli_die "Cluster '${name}' is not registered. Registered: ${MCM_CLUSTERS:-none}. Use --purge to delete a leftover folder."
    fi

    # With slots in the cluster, a purge shows what it would and would not delete
    # before the refusal below.
    if [[ "${purge}" == true && -n "$(ir_slot_records --cluster "${name}")" ]]; then
        _mcm_cli_purge_preview "${name}"
    fi
    _mcm_cli_require_quiet "${name}"

    if [[ "${purge}" == true ]]; then
        _mcm_cli_purge_preview "${name}"
        to_delete=("${reply[@]}")
        print -n -- "Type the cluster name (${name}) to delete these files permanently: "
        if ! read -r answer; then
            print
            _mcm_cli_die "No confirmation given. Nothing was changed."
        fi
        if [[ "${answer}" != "${name}" ]]; then
            _mcm_cli_die "The typed text did not match '${name}'. Nothing was changed."
        fi
        # The prompt can sit open for a long time; a run may have started meanwhile.
        _mcm_cli_require_quiet "${name}"
    fi

    url="$(_mcm_marker_value "${cluster_root}/.cluster" OCP_URL)"
    _mcm_cli_remove_containers "${name}"

    if [[ "${purge}" == true ]]; then
        if [[ "${registered}" == true ]]; then
            _mcm_cli_unregister "${name}" || exit 1
            _mcm_cli_info "Unregistered cluster ${name}${url:+ (${url})}."
        fi
        # The marker goes with the folder, so nothing of the cluster remains.
        for folder in "${to_delete[@]}"; do
            deleted=$(( deleted + 1 ))
            _mcm_cli_info "Deleting ${deleted}/${#to_delete}: ${folder}"
            rm -rf -- "${folder}"
        done
        _mcm_cli_info "Deleted the files of cluster ${name}; it is no longer delineated."
    elif [[ "${delineated}" == true ]]; then
        _mcm_cli_retire "${name}"
        _mcm_cli_info "Retired cluster ${name}${url:+ (${url})}: unregistered, files kept in ${cluster_root}."
        _mcm_cli_info "It stays delineated (one-way): flat configs for its URL are refused. Add the cluster back with: multi_cluster.sh add ${name}${url:+ --url ${url}}"
        _mcm_cli_info "To delete it for good: multi_cluster.sh remove ${name} --purge"
    else
        # Registered by hand in the state file, with no marker: nothing to retire.
        _mcm_cli_unregister "${name}" || exit 1
        _mcm_cli_info "Unregistered cluster ${name}; it had no folder marker in ${cluster_root}."
    fi
    if [[ "${MCM_CLUSTER:-}" == "${name}" ]]; then
        _mcm_warn "This shell is still pinned to ${name}. Source s_env.sh again to pick another cluster."
    fi
}

# --- containers --------------------------------------------------------------
# Stops each idle container named. REPLY is how many stayed running. Never exits.
_mcm_cli_stop_list() {   # CONTAINER...
    local container cluster
    local -i total=$# n=0 left=0 stop_rc=0
    for container in "$@"; do
        n=$(( n + 1 ))
        if mcm_container_busy "${container}"; then
            _mcm_warn "Containers ${n}/${total}: ${container} is busy (${_MCM_BUSY_WHY}), left running. If you are sure, run: podman stop -t 3 ${container}"
            left=$(( left + 1 ))
            continue
        fi
        cluster="$(_mcm_container_cluster "${container}")" || cluster=""
        _mcm_cli_info "Containers ${n}/${total}: stopping ${container}"
        stop_rc=0
        _mcm_stop_container "${container}" "${cluster}" || stop_rc=$?
        case "${stop_rc}" in
            0) ;;
            2)
                _mcm_warn "Containers ${n}/${total}: a run has just started on cluster ${cluster}, ${container} left running."
                left=$(( left + 1 ))
                ;;
            *)
                _mcm_warn "Containers ${n}/${total}: could not stop ${container}."
                left=$(( left + 1 ))
                ;;
        esac
    done
    REPLY="${left}"
    return 0
}

# Seconds since the epoch of the container's last activity, as the watcher judges it
# (newest of: an exec event, .last_activity, its last start). Empty when the start
# time cannot be read. Our own scans do not count, so reading status never resets it.
_mcm_cli_last_activity() {   # CONTAINER CLUSTER NOW; prints EPOCH
    local container="$1" cluster="$2" started="" events="" stamp="" own_stamp="" file
    local -i now="$3" last=0 mtime=0 event_epoch=0 seen=0 own=0 newest_exec=0
    local -a exec_times own_times
    started="$(podman inspect --format '{{.State.StartedAt}}' "${container}" 2>/dev/null)" || started=""
    last="$(_mcm_epoch_from_timestamp "${started}")" || return 0

    if [[ -n "${cluster}" ]]; then
        file="${MCM_CLI_CPD_CLI_CLUSTERS}/${cluster}/.last_activity"
        if [[ -f "${file}" ]]; then
            mtime="$(zstat +mtime "${file}" 2>/dev/null)" || mtime=0
            if (( mtime > last )); then
                last=${mtime}
            fi
        fi
    fi

    events="$(podman events --since "${last}" --until "$(( now + 1 ))" --filter event=exec --filter "container=${container}" --format '{{.Time}}' 2>/dev/null)" || events=""
    for stamp in "${(@f)events}"; do
        if [[ -n "${stamp}" ]] && event_epoch="$(_mcm_epoch_from_timestamp "${stamp}")"; then
            exec_times+=("${event_epoch}")
        fi
    done
    file="$(_mcm_scan_log_file "${container}")" || file=""
    if [[ -n "${file}" && -f "${file}" ]]; then
        own_times=("${(@f)$(<"${file}")}")
    fi
    for stamp in "${(@On)exec_times}"; do
        seen=$(( seen + 1 ))
        own=0
        for own_stamp in "${own_times[@]}"; do
            if [[ "${own_stamp}" == <-> ]] && (( own_stamp >= stamp )); then
                own=$(( own + 1 ))
            fi
        done
        if (( seen > own )); then
            newest_exec=${stamp}
            break
        fi
    done
    if (( newest_exec > last )); then
        last=${newest_exec}
    fi
    print -r -- "${last}"
}

_mcm_cli_status_row() {   # CLUSTER CONTAINER
    local cluster="$1" container="$2" state targeted="-" idle="-" left="-" note="" last=""
    local -i now idle_seconds left_seconds timeout
    state="$(_mcm_cli_state "${container}")"
    timeout=$(( MCM_CONTAINER_IDLE_TIMEOUT_MINUTES * 60 ))

    # Cluster containers are watched in both modes (a run that names the cluster starts
    # the watcher); with the mode off the flat pair is the default's and left alone.
    if [[ -n "${cluster}" ]]; then
        targeted=no
        if (( ${MCM_CLI_TARGETED[(Ie)${cluster}]} )); then
            targeted=yes
        fi
    elif _mcm_cli_is_on; then
        targeted=no
    else
        note="mode off: flat default, not auto-stopped"
    fi

    if [[ -z "${state}" ]]; then
        if (( MCM_CLI_REACHABLE )); then
            state="not created"
        else
            state="unknown"
        fi
    elif [[ "${state}" == running ]] && { _mcm_cli_is_on || [[ -n "${cluster}" ]]; }; then
        if mcm_container_busy "${container}"; then
            idle=busy
            note="${_MCM_BUSY_WHY}"
        else
            now=${EPOCHSECONDS}
            last="$(_mcm_cli_last_activity "${container}" "${cluster}" "${now}")" || last=""
            if [[ -z "${last}" ]]; then
                idle="?"
                left="?"
                note="start time unreadable"
            else
                idle_seconds=$(( now - last ))
                if (( idle_seconds < 0 )); then
                    idle_seconds=0
                fi
                idle="$(_mcm_cli_duration "${idle_seconds}")"
                if (( timeout <= 0 )); then
                    left="never"
                else
                    left_seconds=$(( timeout - idle_seconds ))
                    if (( left_seconds <= 0 )); then
                        left="due"
                    else
                        left="$(_mcm_cli_duration "${left_seconds}")"
                    fi
                fi
                if [[ "${targeted}" == no && "${MCM_STOP_INACTIVE_CONTAINERS}" == true ]]; then
                    note="not targeted: stopped by the next sync when idle"
                fi
            fi
        fi
    fi
    printf "%-${MCM_CLI_W1}s  %-${MCM_CLI_W2}s  %-12s  %-8s  %-8s  %-9s  %s\n" \
        "${cluster:-(flat)}" "${container}" "${state}" "${targeted}" "${idle}" "${left}" "${note}"
}

_mcm_cli_containers_status() {
    local name container
    local -a names shown cluster_names
    typeset -g MCM_CLI_W1=7 MCM_CLI_W2=9
    typeset -g MCM_CLI_REACHABLE=1
    typeset -ga MCM_CLI_TARGETED
    MCM_CLI_TARGETED=(${=$(mcm_targeted_clusters)})
    if ! _mcm_cli_read_states; then
        MCM_CLI_REACHABLE=0
        _mcm_warn "podman is not reachable, so container states are unknown."
    fi

    # The flat pair, then each cluster: containers that exist, and always its main one.
    local -a rows_cluster rows_container
    for container in "${(@f)$(mcm_container_names)}"; do
        if [[ -n "$(_mcm_cli_state "${container}")" ]]; then
            rows_cluster+=("")
            rows_container+=("${container}")
        fi
    done
    for name in ${=MCM_CLUSTERS}; do
        cluster_names=("${(@f)$(mcm_container_names "${name}")}")
        for container in "${cluster_names[@]}"; do
            if [[ "${container}" == "${cluster_names[1]}" || -n "$(_mcm_cli_state "${container}")" ]]; then
                rows_cluster+=("${name}")
                rows_container+=("${container}")
            fi
        done
    done

    if (( ${#rows_container} == 0 )); then
        _mcm_cli_info "No managed containers and no registered clusters."
        return 0
    fi
    local -i i
    for (( i = 1; i <= ${#rows_container}; i++ )); do
        if (( ${#rows_cluster[i]} > MCM_CLI_W1 )); then
            MCM_CLI_W1=${#rows_cluster[i]}
        fi
        if (( ${#rows_container[i]} > MCM_CLI_W2 )); then
            MCM_CLI_W2=${#rows_container[i]}
        fi
    done
    printf "%-${MCM_CLI_W1}s  %-${MCM_CLI_W2}s  %-12s  %-8s  %-8s  %-9s  %s\n" CLUSTER CONTAINER STATE TARGETED IDLE "TIME LEFT" NOTE
    for (( i = 1; i <= ${#rows_container}; i++ )); do
        _mcm_cli_status_row "${rows_cluster[i]}" "${rows_container[i]}"
    done
    if ! _mcm_cli_is_on; then
        _mcm_cli_info "Multi-cluster mode is off: the flat containers are not auto-stopped. Cluster containers still are, once a run that names their cluster has started the idle watcher."
    fi
    if (( MCM_CONTAINER_IDLE_TIMEOUT_MINUTES == 0 )); then
        _mcm_cli_info "Auto-stop is disabled (MCM_CONTAINER_IDLE_TIMEOUT_MINUTES=0)."
    fi
}

_mcm_cli_containers_start() {   # NAME
    local name="$1" container state
    local -a targeted names pending
    local -i n=0 failed=0
    mcm_validate_name "${name}" || exit 2
    _mcm_cli_require_registered "${name}"
    targeted=(${=$(mcm_targeted_clusters)})
    if (( ! ${targeted[(Ie)${name}]} )) && ! _mcm_cli_is_on; then
        _mcm_cli_die "Multi-cluster mode is off, so only a cluster the run names is targeted (targeted now: ${targeted[*]:-none}). Name it: MCM_CLUSTER=${name} multi_cluster.sh containers start ${name}, or turn the mode on with: multi_cluster.sh on"
    fi
    if (( ! ${targeted[(Ie)${name}]} )); then
        _mcm_cli_die "Cluster '${name}' is not targeted (targeted now: ${targeted[*]:-none}). Select it with: multi_cluster.sh use ${name} (or targets, apply-to-all)."
    fi

    _mcm_wait_vm_stopping
    _mcm_wait_stopping "${name}"
    if ! _mcm_cli_read_states; then
        if ! _mcm_restart_stopped_vm || ! _mcm_cli_read_states; then
            _mcm_cli_die "podman is not reachable, so nothing was started."
        fi
    fi

    names=("${(@f)$(mcm_container_names "${name}")}")
    for container in "${names[@]}"; do
        state="$(_mcm_cli_state "${container}")"
        case "${state}" in
            "") ;;
            running) _mcm_cli_info "${container} is already running." ;;
            paused|stopping|removing) _mcm_warn "${container} is ${state}, left as it is." ;;
            *) pending+=("${container}") ;;
        esac
    done
    if (( ${#pending} == 0 )); then
        local any=false
        for container in "${names[@]}"; do
            if [[ -n "$(_mcm_cli_state "${container}")" ]]; then
                any=true
            fi
        done
        if [[ "${any}" == false ]]; then
            _mcm_cli_info "Cluster ${name} has no container yet; the next 'cpd-cli manage' command creates it."
        fi
    fi
    for container in "${pending[@]}"; do
        n=$(( n + 1 ))
        _mcm_cli_info "Containers ${n}/${#pending}: starting ${container}"
        if ! podman start "${container}" >/dev/null 2>&1; then
            _mcm_warn "Could not start ${container}."
            failed=$(( failed + 1 ))
        fi
    done
    if (( n > failed )); then
        mcm_ensure_idle_watcher
    fi
    if (( failed > 0 )); then
        exit 1
    fi
}

_mcm_cli_running_of() {   # sets reply: running containers among the names given
    local container
    reply=()
    for container in "$@"; do
        if [[ "$(_mcm_cli_state "${container}")" == running ]]; then
            reply+=("${container}")
        fi
    done
}

_mcm_cli_containers_stop() {   # NAME
    local name="$1"
    local -a names
    _mcm_cli_require_registered "${name}"
    if ! _mcm_cli_read_states; then
        _mcm_cli_die "podman is not reachable, so nothing was stopped."
    fi
    names=("${(@f)$(mcm_container_names "${name}")}")
    _mcm_cli_running_of "${names[@]}"
    names=("${reply[@]}")
    if (( ${#names} == 0 )); then
        _mcm_cli_info "Cluster ${name} has no running container."
        return 0
    fi
    _mcm_cli_stop_list "${names[@]}"
    if (( REPLY > 0 )); then
        exit 1
    fi
}

_mcm_cli_containers_stop_all() {
    local -a names
    if ! _mcm_cli_read_states; then
        _mcm_cli_die "podman is not reachable, so nothing was stopped."
    fi
    names=("${(@f)$(mcm_managed_containers)}")
    _mcm_cli_running_of "${names[@]}"
    names=("${reply[@]}")
    if (( ${#names} == 0 )); then
        _mcm_cli_info "No managed container is running."
        return 0
    fi
    _mcm_cli_stop_list "${names[@]}"
    if (( REPLY > 0 )); then
        exit 1
    fi
}

cmd_containers() {
    local sub="${1:-}"
    if (( $# > 0 )); then
        shift
    fi
    case "${sub}" in
        status)
            if (( $# != 0 )); then
                _mcm_cli_bad_usage "containers status takes no arguments."
            fi
            _mcm_cli_containers_status
            ;;
        start|stop)
            if (( $# != 1 )); then
                _mcm_cli_bad_usage "containers ${sub} takes one NAME."
            fi
            if [[ "${sub}" == start ]]; then
                _mcm_cli_containers_start "$1"
            else
                _mcm_cli_containers_stop "$1"
            fi
            ;;
        stop-all)
            if (( $# != 0 )); then
                _mcm_cli_bad_usage "containers stop-all takes no arguments."
            fi
            _mcm_cli_containers_stop_all
            ;;
        -h|--help)
            usage
            ;;
        *)
            _mcm_cli_bad_usage "containers needs status, start NAME, stop NAME or stop-all."
            ;;
    esac
}

# --- Main --------------------------------------------------------------------
MCM_CLI_COMMAND="${1:-}"
case "${MCM_CLI_COMMAND}" in
    ""|-h|--help|help)
        usage
        if [[ -z "${MCM_CLI_COMMAND}" ]]; then
            exit 2
        fi
        exit 0
        ;;
esac
shift

# A subcommand's --help, without creating or reading the state file.
for _mcm_cli_arg in "$@"; do
    if [[ "${_mcm_cli_arg}" == -h || "${_mcm_cli_arg}" == --help ]]; then
        usage
        exit 0
    fi
done

mcm_load_state || exit 1

case "${MCM_CLI_COMMAND}" in
    status)       cmd_status "$@" ;;
    on)           cmd_on "$@" ;;
    off)          cmd_off "$@" ;;
    list)         cmd_list "$@" ;;
    add)          cmd_add "$@" ;;
    use)          cmd_use "$@" ;;
    targets)      cmd_targets "$@" ;;
    apply-to-all) cmd_apply_to_all "$@" ;;
    rename)       cmd_rename "$@" ;;
    remove)       cmd_remove "$@" ;;
    containers)   cmd_containers "$@" ;;
    *)            _mcm_cli_bad_usage "Unknown command: ${MCM_CLI_COMMAND}." ;;
esac
