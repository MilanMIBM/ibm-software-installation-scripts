#!/bin/zsh
# =============================================================================
# multi_cluster_generator_args.sh - multi-cluster handling shared by the config
#                                   generators, which load no config themselves
# -----------------------------------------------------------------------------
# Plan: .claude/plans/multi-cluster-management/multi-cluster-management-plan.md (5.11)
#
#     source "${REPO_ROOT}/src/helpers/multi_cluster_generator_args.sh"
#     MCM_GENERATOR_URL_FILES=(cp4d_config/cpd_vars.sh)   # optional, see below
#     mcm_generator_setup "$@" || exit 1
#     set -- "${reply[@]}"
#     ...write the file...
#     mcm_generator_register "${OUT_FILE}"
#
#   mcm_generator_setup ARGS...   takes --target-cluster NAME out of ARGS, leaves
#                                 the rest in reply, sets CONFIGS_ROOT and, for a
#                                 cluster folder, MCM_CLUSTER for the generator's children
#   mcm_generator_register FILE   a cluster named by flag or MCM_CLUSTER, or one whose
#                                 folder this run creates: registers it, with the
#                                 OCP_URL found in FILE when there is one
#
# Delineation is one-way per cluster: a cluster with configs/clusters/<name>/.cluster
# keeps its own folder for good. MULTI_CLUSTER_MANAGEMENT is only the default for new
# clusters and for runs that name no cluster.
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _MCM_GENERATOR_ARGS_LOADED.
#   - A generator's "--cluster same|different" (Control Center) is a different flag.
#   - Mode on (table 5.4): --target-cluster wins, then MCM_CLUSTER, then the state
#     file's selection. Several clusters are refused: a generator writes one cluster's
#     config. A cluster without a folder yet gets one, with a [WARN] that this cannot
#     be undone for it.
#   - Mode off: --target-cluster or MCM_CLUSTER naming a delineated, not retired
#     cluster writes into its folder and pins the children to it. A name that is not
#     delineated is an error (B7); a stale MCM_CLUSTER that is not delineated is
#     ignored, as the env loaders ignore it. No name: this checkout's flat configs/,
#     whatever a shell loaded from elsewhere exported, unless a flat file listed in
#     MCM_GENERATOR_URL_FILES (paths under configs/, the files this generator reads or
#     rewrites; an absolute path is used as is, for a file named on the command line,
#     see mcm_generator_flag_file) points at a delineated cluster: then that cluster's
#     folder, with a [WARN], so the cluster never gets a second, flat config. Never prompts.
#   - --help is left for the generator and resolves nothing, so it works on a
#     machine with no selection or a broken state file.
# =============================================================================

[[ -n "${_MCM_GENERATOR_ARGS_LOADED:-}" ]] && return 0
_MCM_GENERATOR_ARGS_LOADED=1

source "${${(%):-%x}:A:h}/multi_cluster_helpers.sh"

# A shell loaded from another checkout exports its own root; a generator works on its own.
_CP4D_REPO_ROOT="${_MCM_HELPER_DIR:h:h}"

# First literal OCP_URL in FILE: not empty, not a ${reference}. Prints nothing when none.
_mcm_generator_file_url() {   # FILE
    _mcm_config_file_url "${1:-}"
}

# With the mode off, a name must be a delineated cluster that is not retired.
_mcm_generator_check_delineated() {   # NAME SOURCE
    emulate -L zsh
    local name="${1:-}" source="${2:-}" delineated
    mcm_validate_name "${name}" || return 1
    if ! mcm_is_delineated "${name}"; then
        delineated="$(mcm_delineated_clusters --exclude-retired)"
        _mcm_err "Cluster '${name}' (${source}) has no folder of its own (no configs/clusters/${name}/.cluster), and multi-cluster mode is off."
        _mcm_err "While multi-cluster mode is off, a generator writes only for a cluster that already has its folder (${delineated:-none yet}), or the flat configs/ with no name."
        _mcm_err "To give '${name}' its own folder (cannot be undone for it): src/utilities/multi_cluster_management_utils/multi_cluster.sh add ${name} --url URL, or turn the mode on with multi_cluster.sh on."
        return 1
    fi
    if mcm_is_retired "${name}"; then
        _mcm_err "Cluster '${name}' (${source}) is retired (removed from the registered clusters; its folder stays delineated)."
        _mcm_err "Add it back with src/utilities/multi_cluster_management_utils/multi_cluster.sh add ${name}${${(M)source:#MCM_CLUSTER}:+, or unset MCM_CLUSTER in this shell}."
        return 1
    fi
    return 0
}

# Mode off, no name: the delineated cluster owning a flat file in MCM_GENERATOR_URL_FILES.
# Prints its name, or nothing. 1 when the files point at several, or at a retired one.
_mcm_generator_url_owner() {   # FLAT_CONFIGS_DIR
    emulate -L zsh
    local configs="${1:-}" rel file url name
    local -a owners files urls unique
    for rel in ${MCM_GENERATOR_URL_FILES[@]:+"${MCM_GENERATOR_URL_FILES[@]}"}; do
        if [[ "${rel}" == /* ]]; then
            file="${rel}"
        else
            file="${configs}/${rel}"
        fi
        url="$(_mcm_generator_file_url "${file}")"
        [[ -n "${url}" ]] || continue
        name="$(mcm_cluster_for_url "${url}")"
        [[ -n "${name}" ]] || continue
        owners+=("${name}") files+=("${file}") urls+=("${url}")
    done
    (( ${#owners} )) || return 0
    unique=("${(@u)owners}")
    if (( ${#unique} > 1 )); then
        _mcm_err "The flat configs this generator reads point at several clusters that have their own folders: ${(j:, :)unique}."
        _mcm_err "Name one with --target-cluster NAME. Flat files: ${(j:, :)${files[@]#${configs:h}/}}"
        return 1
    fi
    name="${owners[1]}"
    if mcm_is_retired "${name}"; then
        mcm_flat_config_conflict "${urls[1]}" "${files[@]}"
        return 1
    fi
    _mcm_warn "The flat config ${files[1]#${configs:h}/} points at ${urls[1]}, which belongs to cluster '${name}'."
    _mcm_warn "'${name}' has its own folder for good, so this generator writes into configs/clusters/${name}/ (as --target-cluster ${name}) instead of the flat configs/."
    print -r -- "${name}"
    return 0
}

# The FILE given after FLAG in ARGS (e.g. --from-cpd FILE), as an absolute path; nothing
# when FLAG is absent or has no FILE (the next argument starts with -). For a generator
# that copies OCP_URL from a file the user names: put it in MCM_GENERATOR_URL_FILES so a
# file of a delineated cluster sends the write into that cluster's folder.
mcm_generator_flag_file() {   # FLAG ARGS...
    emulate -L zsh
    local flag="${1:-}" file
    local -i i
    shift
    for (( i = 1; i < $#; i++ )); do
        if [[ "${@[i]}" == "${flag}" && "${@[i+1]}" != -* && -n "${@[i+1]}" ]]; then
            file="${@[i+1]}"
            print -r -- "${file:A}"
            return 0
        fi
    done
    return 0
}

mcm_generator_setup() {
    emulate -L zsh
    local help=false target="" root="" flat=""
    local -a rest=()
    while (( $# )); do
        case "$1" in
            --target-cluster=*) target="${1#*=}"; shift ;;
            --target-cluster)
                if [[ -z "${2:-}" ]]; then
                    _mcm_err "--target-cluster needs a cluster name."
                    return 1
                fi
                target="$2"; shift 2 ;;
            -h|--help) help=true; rest+=("$1"); shift ;;
            *) rest+=("$1"); shift ;;
        esac
    done
    reply=("${rest[@]}")
    typeset -g MCM_GENERATOR_TARGET="${target}"
    [[ "${help}" != true ]] || return 0

    mcm_load_state || return 1
    typeset -g MCM_GENERATOR_REGISTER="${target}"
    flat="${_MCM_HELPER_DIR:h:h}/configs"
    if [[ "${MULTI_CLUSTER_MANAGEMENT}" != true ]]; then
        # Mode off: only a delineated cluster has a folder to write into.
        if [[ -n "${target}" ]]; then
            _mcm_generator_check_delineated "${target}" --target-cluster || return 1
        elif [[ -n "${MCM_CLUSTER:-}" ]] && mcm_is_delineated "${MCM_CLUSTER}"; then
            target="${MCM_CLUSTER}"
            _mcm_generator_check_delineated "${target}" MCM_CLUSTER || return 1
            MCM_GENERATOR_REGISTER="${target}"
        else
            target="$(_mcm_generator_url_owner "${flat}")" || return 1
            if [[ -z "${target}" ]]; then
                export CONFIGS_ROOT="${flat}"
                return 0
            fi
            MCM_GENERATOR_REGISTER="${target}"
        fi
        root="$(mcm_cluster_root "${target}")" || return 1
        # Steps this generator runs load env_bootstrap.sh and must read the same cluster.
        export CONFIGS_ROOT="${root}" MCM_CLUSTER="${target}"
        return 0
    fi
    if [[ -z "${target}" ]]; then
        if [[ -n "${MCM_CLUSTER:-}" ]]; then
            target="${MCM_CLUSTER}"
            MCM_GENERATOR_REGISTER="${target}"
        else
            mcm_resolve_targets >/dev/null || return 1
            if (( ${#_MCM_RESOLVED} > 1 )); then
                _mcm_err "A config generator writes one cluster's config, but the targets are: ${_MCM_RESOLVED[*]}."
                _mcm_err "Pick one with --target-cluster NAME, or set the current cluster with multi_cluster.sh use NAME."
                return 1
            fi
            target="${_MCM_RESOLVED[1]}"
        fi
    fi
    root="$(mcm_resolve_configs_root "${target}")" || return 1
    # A folder this run creates gets its marker too, so it is a delineated cluster.
    mcm_is_delineated "${target}" || MCM_GENERATOR_REGISTER="${target}"
    export CONFIGS_ROOT="${root}"
    # Steps this generator runs load env_bootstrap.sh and must read the same cluster.
    export MCM_CLUSTER="${target}"
    return 0
}

mcm_generator_register() {
    emulate -L zsh
    local name="${MCM_GENERATOR_REGISTER:-}" file="${1:-}" url="" new=false retired=false
    [[ -n "${name}" ]] || return 0
    if mcm_is_delineated "${name}"; then
        mcm_is_retired "${name}" && retired=true
    else
        new=true
    fi
    # A name that came from MCM_CLUSTER and is already known needs nothing more.
    if [[ -z "${MCM_GENERATOR_TARGET:-}" && "${new}" != true && "${retired}" != true ]] && mcm_is_registered "${name}"; then
        return 0
    fi
    url="$(_mcm_generator_file_url "${file}")"
    if mcm_register "${name}" "${url}"; then
        print -r -- "[INFO] Cluster '${name}' is registered."
        [[ "${retired}" != true ]] || print -r -- "[INFO] Cluster '${name}' was retired and is registered again."
        if [[ "${new}" == true ]]; then
            _mcm_warn "Cluster '${name}' now has its own folder (configs/clusters/${name}/). Managing each cluster in its own folder is preferred, but this cannot be undone for '${name}': it stays there even if multi-cluster mode is turned off."
        fi
    else
        _mcm_warn "Could not register cluster '${name}'. Run multi_cluster.sh add ${name}."
    fi
    return 0
}
