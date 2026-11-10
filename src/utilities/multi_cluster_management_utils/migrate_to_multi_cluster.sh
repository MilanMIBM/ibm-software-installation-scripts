#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# =============================================================================
# migrate_to_multi_cluster.sh - moves a single-cluster (flat) setup into per-cluster
#                               folders, one way
# -----------------------------------------------------------------------------
# Plan: .claude/plans/multi-cluster-management/multi-cluster-management-plan.md (5.10)
#
# Sources only multi_cluster_helpers.sh, so it works before any config exists.
#
# Every step of a run is written to a journal first
# (configs/old_configs/pre_multi_cluster_<timestamp>/migration_journal.tsv, tab
# separated). A re-run continues from the journal. --rollback undoes, in reverse, only
# a migration whose journal is not complete: delineation is one-way per cluster, so a
# completed migration is final (its backup stays in the journal folder). --dry-run
# changes nothing at all (no state file, no folders, no journal).
#
# Nothing here prints file contents: the credential files are only scanned for
# their comment lines.
# =============================================================================

usage() {
    cat <<'EOF'
Move a flat, single-cluster setup into per-cluster folders under
configs/clusters/<name>/, then turn multi-cluster management on.

  migrate_to_multi_cluster.sh [--dry-run] [--yes] [--name NAME]
                              [--map KEY=CLUSTER]... [--mirror-state-to REGISTRY_ROOT]
  migrate_to_multi_cluster.sh --rollback [--dry-run] [--yes]
  migrate_to_multi_cluster.sh --preflight-only

Options:
  --dry-run                  Print the plan and stop. Changes nothing.
  --yes, -y                  Do not ask for confirmation.
  --name NAME                Use NAME instead of the name derived from the URL for the
                             cluster holding cp4d_config (or, with no cp4d_config, the
                             only cluster found). Items with no URL also go there.
  --map KEY=CLUSTER          Send one item to CLUSTER. Repeatable. KEY is a product
                             folder (cp4d_config, concert_config or concert), a file in
                             configs/openshift_config, or one of: service_instances,
                             cpd-cli-workspace, concert_workspace, datastax_mc_workspace,
                             kubecost_workspace, cpd-cli-work, swhub-control-center-work,
                             cpd-cli-profiles, oadp, confluent-rendered, flink-rendered.
  --mirror-state-to ROOT     Assign registry_mirror_workspace/ to the destination
                             registry ROOT: its state moves to registries/<destination>/,
                             cluster/ to the cluster's registry_mirror_cluster/, and tools/
                             and local-registry/ stay. Without it that folder is not
                             touched, since nothing records which registry it describes.
  --rollback                 Undo a migration that did not finish (stopped or failed
                             part way), from its journal. A completed migration is
                             final and --rollback refuses it.
  --preflight-only           Only run the preflight below and exit 0 or 1. Used before
                             the mode is turned on without moving anything.
  --help, -h                 Show this help.

Steps: preflight (no live lease, no running 'cpd-cli manage', no other script of this
checkout running, olm-utils idle), plan, back up configs to configs/old_configs/pre_multi_cluster_<timestamp>/ (mode 0700), move
each item, update the moved folders' absolute paths inside the moved config files (cert
paths in instance details, truststores, bundle zips; binary files and workspaces are not
touched), seed .home/.kube/config from ~/.kube/config (not changed), remove the old flat
olm-utils container, then register the clusters and turn the mode on.

Routing: each product folder goes to the cluster derived from its OCP_URL. Files in
openshift_config go by the cluster URL in their comment; no URL or several URLs goes
with cp4d_config (several also warns). A comment URL counts only if it looks like a
cluster API endpoint: no path, and a host starting with api. or an explicit port other
than 80 or 443. Two different URLs under one cluster name are refused, as is a URL that
differs from an existing .cluster marker; --map is the only way to override that. A
cluster is registered only if it ends up with a *_vars.sh. If a run stops part way,
re-run the same command to continue, or use --rollback.

One way: moving a cluster into configs/clusters/<name>/ is permanent for that cluster.
Once a migration completes there is no way back to the flat layout for the clusters it
moved; the backup in configs/old_configs/pre_multi_cluster_<timestamp>/ keeps the old
files for reference. The repo-wide default (MULTI_CLUSTER_MANAGEMENT) stays switchable
with multi_cluster.sh on|off.
EOF
}

# --- Paths -------------------------------------------------------------------
MCM_MIG_SCRIPT_DIR="${0:A:h}"
MCM_MIG_REPO="${MCM_MIG_SCRIPT_DIR}"
while [[ "${MCM_MIG_REPO}" != "/" && ! -f "${MCM_MIG_REPO}/env_bootstrap.sh" ]]; do
    MCM_MIG_REPO="${MCM_MIG_REPO:h}"
done
_CP4D_REPO_ROOT="${MCM_MIG_REPO}"

MCM_MIG_DRY_RUN=false
MCM_MIG_PREFLIGHT_ONLY=false
MCM_MIG_YES=false
MCM_MIG_NAME=""
MCM_MIG_ROLLBACK=false
MCM_MIG_MIRROR_TO=""
typeset -gA MCM_MIG_MAP

_mcm_mig_need() { [[ -n "${2:-}" ]] || { echo "[ERROR] $1 needs a value. See --help." >&2; exit 2; }; }
# --reverse was removed: a delineated cluster never goes back to the flat layout.
_mcm_mig_one_way_error() {   # OPTION
    echo "[ERROR] $1 was removed: delineation is one-way for each cluster. A cluster set up under configs/clusters/<name>/ stays there for good and never goes back to the flat layout." >&2
    echo "[ERROR] To stop targeting a cluster, unregister it with multi_cluster.sh remove NAME (it stays delineated). The repo-wide default can still be switched with multi_cluster.sh off." >&2
    exit 2
}
_mcm_mig_add_map() {
    local spec="${1:-}" key value
    if [[ "${spec}" != *=* ]]; then
        echo "[ERROR] --map expects KEY=CLUSTER, got '${spec}'." >&2
        exit 2
    fi
    key="${spec%%=*}"
    value="${spec#*=}"
    if [[ -z "${key}" || -z "${value}" ]]; then
        echo "[ERROR] --map expects KEY=CLUSTER, got '${spec}'." >&2
        exit 2
    fi
    MCM_MIG_MAP[$key]="${value}"
}

while (( $# > 0 )); do
    case "$1" in
        --dry-run)            MCM_MIG_DRY_RUN=true; shift ;;
        --yes|-y)             MCM_MIG_YES=true; shift ;;
        --name)               _mcm_mig_need "$1" "${2:-}"; MCM_MIG_NAME="$2"; shift 2 ;;
        --name=*)             MCM_MIG_NAME="${1#*=}"; _mcm_mig_need --name "${MCM_MIG_NAME}"; shift ;;
        --map)                _mcm_mig_need "$1" "${2:-}"; _mcm_mig_add_map "$2"; shift 2 ;;
        --map=*)              _mcm_mig_add_map "${1#*=}"; shift ;;
        --mirror-state-to)    _mcm_mig_need "$1" "${2:-}"; MCM_MIG_MIRROR_TO="$2"; shift 2 ;;
        --mirror-state-to=*)  MCM_MIG_MIRROR_TO="${1#*=}"; _mcm_mig_need --mirror-state-to "${MCM_MIG_MIRROR_TO}"; shift ;;
        --rollback)           MCM_MIG_ROLLBACK=true; shift ;;
        --preflight-only)     MCM_MIG_PREFLIGHT_ONLY=true; shift ;;
        --reverse|--reverse=*) _mcm_mig_one_way_error "${1%%=*}" ;;
        --help|-h)            usage; exit 0 ;;
        *)                    echo "[ERROR] Unknown option: $1. See --help." >&2; exit 2 ;;
    esac
done

if [[ "${MCM_MIG_ROLLBACK}" == true ]]; then
    if [[ -n "${MCM_MIG_NAME}" || -n "${MCM_MIG_MIRROR_TO}" || ${#MCM_MIG_MAP} -gt 0 ]]; then
        echo "[ERROR] --name, --map and --mirror-state-to apply only to a forward migration." >&2
        exit 2
    fi
fi

source "${MCM_MIG_REPO}/src/helpers/multi_cluster_helpers.sh"

# Every --map value becomes a path component, so all of them are checked up front.
for _mcm_mig_map_value in "${(@v)MCM_MIG_MAP}"; do
    mcm_validate_name "${_mcm_mig_map_value}" || exit 2
done
unset _mcm_mig_map_value

MCM_MIG_CONFIGS="${MCM_MIG_REPO}/configs"
MCM_MIG_OLD_CONFIGS="${MCM_MIG_CONFIGS}/old_configs"
MCM_MIG_CLUSTERS_ROOT="$(mcm_clusters_root)"
MCM_MIG_CPD_CLI_CLUSTERS="${HOME}/cpd-cli/clusters"
MCM_MIG_MIRROR_WS="${MCM_MIG_REPO}/registry_mirror_workspace"
MCM_MIG_OADP_DIR="${MCM_MIG_REPO}/src/utilities/oadp_backup_restore_cp4d_utils"
MCM_MIG_CONFLUENT_RENDERED="${MCM_MIG_REPO}/scripts/install_confluent_platform/confluent_platform_vars/rendered"
MCM_MIG_FLINK_RENDERED="${MCM_MIG_REPO}/scripts/install_confluent_platform/install_confluent_platform_flink_addon/flink_vars/rendered"
MCM_MIG_KUBE="${HOME}/.kube/config"
MCM_MIG_FLAT_CONTAINER="$(mcm_container_name)"
# The flat layout's folders, whatever this shell has loaded.
MCM_MIG_CPD_CLI_HOME="${HOME}/cpd-cli"
MCM_MIG_SWHCC_CONTAINER="olm-utils-swhub-control-center"
MCM_MIG_SWHCC_WORKSPACE="${HOME}/cpd-cli-swhub-control-center"

# The plan: one row per step, across parallel arrays.
#   mv       cluster SRC DST [keep]    move; "keep" leaves an empty SRC folder behind
#   cp       cluster SRC DST           copy, 0600
#   rewrite  cluster DIR OLD NEW       truststore prefix in DIR/**/*.properties (journals
#                                      written before the paths step; no longer planned)
#   paths    "" "" "" COUNT            every mv's SRC path rewritten to its DST inside the
#                                      moved config files (COUNT: files found when planned)
#   seed    cluster DST CONTEXT       .kube/config from one ~/.kube/config context
#   rmc      cluster NAME              remove a container, after the idle check
#   register cluster NAME URL          marker (DELINEATED="true") and MCM_CLUSTERS; the
#                                      marker it replaced is saved for an undo
#   state    cluster MODE CURRENT      MULTI_CLUSTER_MANAGEMENT and MCM_CURRENT_CLUSTER
typeset -ga MCM_MIG_E_KIND MCM_MIG_E_CLUSTER MCM_MIG_E_A MCM_MIG_E_B MCM_MIG_E_C
typeset -gA MCM_MIG_E_STATE MCM_MIG_JMETA
typeset -gA MCM_MIG_CLUSTER_URL MCM_MIG_CLUSTER_URL_FROM MCM_MIG_MAPPED_URL MCM_MIG_CLUSTER_VARS
typeset -ga MCM_MIG_CLUSTERS MCM_MIG_NOTES MCM_MIG_PREFLIGHT_ERRORS MCM_MIG_KNOWN_KEYS
MCM_MIG_PRIMARY=""
MCM_MIG_RENAME_FROM=""
MCM_MIG_JOURNAL=""
MCM_MIG_JOURNAL_DIR=""

# --- Small helpers -----------------------------------------------------------
_mcm_mig_die() { echo "[ERROR] $*" >&2; exit 1; }

_mcm_mig_short() {
    local p="${1:-}"
    if [[ "${p}" == "${MCM_MIG_REPO}/"* ]]; then
        p="${p#"${MCM_MIG_REPO}/"}"
    elif [[ "${p}" == "${HOME}/"* ]]; then
        p="~/${p#"${HOME}/"}"
    fi
    print -r -- "${p}"
}

# True for a file, or a folder holding anything at all.
_mcm_mig_has_content() {
    local p="${1:-}"
    local -a kids
    if [[ -L "${p}" ]]; then
        return 0
    fi
    if [[ -d "${p}" ]]; then
        kids=("${p}"/*(DN))
        # Finder drops .DS_Store in any folder it opens; that is not content.
        kids=("${(@)kids:#*/.DS_Store}")
        (( ${#kids} > 0 ))
        return
    fi
    [[ -e "${p}" ]]
}

_mcm_mig_empty_dir() {
    [[ -d "${1:-}" && ! -L "${1:-}" ]] || return 1
    ! _mcm_mig_has_content "$1"
}

# rmdir, past a Finder .DS_Store. Fails when anything else is in there.
_mcm_mig_rmdir_empty() {   # DIR
    _mcm_mig_empty_dir "${1}" || return 1
    rm -f -- "${1}/.DS_Store"
    rmdir "${1}"
}

# A folder's entries, hidden ones included, past a Finder .DS_Store. Sets reply.
_mcm_mig_entries() {   # DIR
    reply=("${1}"/*(DN))
    reply=("${(@)reply:#*/.DS_Store}")
}

_mcm_mig_add() {   # KIND CLUSTER A B C
    local field
    for field in "$@"; do
        if [[ "${field}" == *$'\t'* || "${field}" == *$'\n'* ]]; then
            _mcm_mig_die "Cannot journal a path holding a tab or a newline: ${field}"
        fi
    done
    MCM_MIG_E_KIND+=("${1}")
    MCM_MIG_E_CLUSTER+=("${2:-}")
    MCM_MIG_E_A+=("${3:-}")
    MCM_MIG_E_B+=("${4:-}")
    MCM_MIG_E_C+=("${5:-}")
}

_mcm_mig_seen() {   # CLUSTER [HAS_VARS]
    local cluster="${1:-}"
    [[ -n "${cluster}" ]] || return 0
    if (( ! ${MCM_MIG_CLUSTERS[(Ie)${cluster}]} )); then
        MCM_MIG_CLUSTERS+=("${cluster}")
    fi
    if [[ "${2:-}" == 1 ]]; then
        MCM_MIG_CLUSTER_VARS[$cluster]=1
    fi
    return 0
}

# URLs compare by the helpers' key (host:port, scheme, case, path and trailing dots
# ignored, port 6443 by default), the same key the flat-load guard and notebooks use.
_mcm_mig_url_key() {
    _mcm_url_key "${1:-}"
}

_mcm_mig_is_mapped() {   # KEY
    [[ -n "${MCM_MIG_MAP[$1]:-}" ]] && return 0
    [[ "${1}" == *_config && -n "${MCM_MIG_MAP[${1%_config}]:-}" ]]
}

# One cluster name holds one cluster URL. Items routed by --map are the explicit
# override: they are not compared and their URL only fills a gap (see
# _mcm_mig_settle_urls), so the marker keeps the URL of the items that belong there.
_mcm_mig_claim_url() {   # KEY CLUSTER URL
    local key="$1" cluster="$2" url="${3:-}" held marker
    [[ -n "${url}" ]] || return 0
    if _mcm_mig_is_mapped "${key}"; then
        if [[ -z "${MCM_MIG_MAPPED_URL[$cluster]:-}" ]]; then
            MCM_MIG_MAPPED_URL[$cluster]="${url}"
        fi
        return 0
    fi
    marker="$(_mcm_mig_marker_url "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/.cluster")"
    if [[ -n "${marker}" && "$(_mcm_mig_url_key "${marker}")" != "$(_mcm_mig_url_key "${url}")" ]]; then
        _mcm_mig_die "Cluster folder ${cluster} is registered for ${marker}, but ${key} is on ${url}. Give ${key} its own cluster with --map ${key}=NAME."
    fi
    held="${MCM_MIG_CLUSTER_URL[$cluster]:-}"
    if [[ -n "${held}" && "$(_mcm_mig_url_key "${held}")" != "$(_mcm_mig_url_key "${url}")" ]]; then
        _mcm_mig_die "Cluster name ${cluster} would hold two clusters: ${MCM_MIG_CLUSTER_URL_FROM[$cluster]:-an earlier item} is on ${held}, ${key} is on ${url}. Give ${key} its own cluster with --map ${key}=NAME."
    fi
    if [[ -z "${held}" ]]; then
        MCM_MIG_CLUSTER_URL[$cluster]="${url}"
        MCM_MIG_CLUSTER_URL_FROM[$cluster]="${key}"
    fi
    return 0
}

# Clusters no unmapped item spoke for: an existing marker wins, then a mapped item's URL.
_mcm_mig_settle_urls() {
    local cluster url
    for cluster in "${MCM_MIG_CLUSTERS[@]}"; do
        [[ -z "${MCM_MIG_CLUSTER_URL[$cluster]:-}" ]] || continue
        url="$(_mcm_mig_marker_url "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/.cluster")"
        [[ -n "${url}" ]] || url="${MCM_MIG_MAPPED_URL[$cluster]:-}"
        if [[ -n "${url}" ]]; then
            MCM_MIG_CLUSTER_URL[$cluster]="${url}"
        fi
    done
    return 0
}

# The permission bits of a folder, as three octal digits. Empty when unreadable.
_mcm_mig_dir_mode() {
    local mode=""
    zmodload -F zsh/stat b:zstat 2>/dev/null || return 0
    mode="$(zstat -o +mode -- "${1}" 2>/dev/null)" || return 0
    print -r -- "${mode[-3,-1]}"
}

_mcm_mig_registered() {   # NAME: against the state already read
    local name="${1:-}"
    local IFS=$' \t\n'
    local -a list
    list=(${=MCM_CLUSTERS:-})
    (( ${list[(Ie)${name}]} ))
}

# The state file, without creating it during a dry run.
_mcm_mig_read_state() {
    local file
    file="$(mcm_state_file)"
    if [[ "${MCM_MIG_DRY_RUN}" == true && ! -f "${file}" ]]; then
        MULTI_CLUSTER_MANAGEMENT=false
        MCM_CLUSTERS=""
        MCM_CURRENT_CLUSTER=""
        MCM_TARGET_CLUSTERS=""
        return 0
    fi
    mcm_load_state || _mcm_mig_die "Fix ${file}, then re-run."
}

# --- Reading configs ---------------------------------------------------------
# The OCP_URL a file sets when sourced, in a subshell. Failures read as "no URL".
_mcm_mig_source_var() {   # FILE VARIABLE
    local file="$1" var="$2" value=""
    value="$(
        set +e
        set +u
        set +o pipefail
        unset "${var}"
        # One-off switches for a single command (CONCERT_TARGET_OC_LOGIN): when set, the
        # Concert template clears OCP_URL.
        unset -m '*_TARGET_OC_LOGIN'
        # Product templates start with a guard that returns unless ENV_TARGET names them.
        ENV_TARGET="${file}"
        source "${file}" </dev/null >/dev/null 2>&1
        print -r -- "${(P)var:-}"
    )" || value=""
    print -r -- "${value}"
}

# Every *_vars.sh of a product folder is tried, the top level first.
_mcm_mig_product_url() {   # DIR; sets REPLY (URL) and reply[1] (1 if a *_vars.sh exists)
    local dir="$1" file url first="" has_vars=0
    local -a files
    files=("${dir}"/*_vars.sh(.N))
    if (( ${#files} == 0 )); then
        files=("${dir}"/**/*_vars.sh(.N))
    fi
    if (( ${#files} > 0 )); then
        has_vars=1
    fi
    for file in "${files[@]}"; do
        url="$(_mcm_mig_source_var "${file}" OCP_URL)"
        [[ -n "${url}" ]] || continue
        if [[ -z "${first}" ]]; then
            first="${url}"
        elif [[ "${(L)${url%/}}" != "${(L)${first%/}}" ]]; then
            print -r -- "[WARN] ${dir:t} has several OCP_URL values; using ${first}." >&2
        fi
    done
    REPLY="${first}"
    reply=("${has_vars}")
}

# A cluster API endpoint, not a console route or a page: no path, and either a host
# starting with "api." or an explicit port other than 80 or 443.
_mcm_mig_is_cluster_url() {   # URL
    local rest port=""
    rest="${(L)${1#*://}}"
    rest="${rest%/}"
    [[ "${rest}" != *[/?#]* ]] || return 1
    rest="${rest##*@}"
    if [[ "${rest}" == *:<-> ]]; then
        port="${rest##*:}"
        rest="${rest%:*}"
    fi
    [[ "${rest}" != *.apps.* ]] || return 1
    if [[ "${rest}" == api.* ]]; then
        return 0
    fi
    [[ -n "${port}" && "${port}" != 80 && "${port}" != 443 ]]
}

# The distinct cluster URLs in a file's comment lines. The generators end the
# comment with 'oc whoami --show-server'; other URLs are ignored.
_mcm_mig_comment_urls() {   # FILE; sets reply
    local file="$1" line url key
    local MATCH MBEGIN MEND
    local -a match mbegin mend seen
    local regex='^[[:space:]]*#.*(https?://[^[:space:]]+)[[:space:]]*$'
    reply=()
    seen=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ${regex} ]] || continue
        url="${match[1]}"
        url="${url%%[.,;\'\"\)]}"
        _mcm_mig_is_cluster_url "${url}" || continue
        key="${(L)${url%/}}"
        if (( ! ${seen[(Ie)${key}]} )); then
            seen+=("${key}")
            reply+=("${url}")
        fi
    done < "${file}"
    return 0
}

# --- Preflight ---------------------------------------------------------------
# ps joins argv with spaces, so a cpd-cli path holding a space arrives as several
# words. Prints "cpd-cli VERB NEXT" when WORDS are a call to cpd-cli manage.
_mcm_mig_manage_in_words() {   # WORD...
    local k prefix
    local -a w
    w=("$@")
    for (( k = 1; k < ${#w}; k++ )); do
        [[ "${w[$k]:t}" == cpd-cli ]] || continue
        case "${w[$((k + 1))]}" in
            manage|manage-k8s) ;;
            *) continue ;;
        esac
        # What comes before "cpd-cli" has to be the folder it runs from.
        prefix="${(j: :)w[1,k-1]}"
        if (( k > 1 )); then
            prefix+=" "
        fi
        prefix+="${w[$k]%cpd-cli}"
        if [[ -n "${prefix}" ]]; then
            [[ "${prefix}" == */ ]] || continue
            if [[ "${prefix}" == *" "* ]]; then
                # Absolute, and the first word is not itself a program: otherwise
                # this is 'vim notes/cpd-cli manage', where cpd-cli is an argument.
                [[ "${prefix}" == /* && ! -f "${prefix%% *}" ]] || continue
            fi
        fi
        print -r -- "cpd-cli ${w[$((k + 1))]} ${w[$((k + 2))]:-}"
        return 0
    done
    return 1
}

_mcm_mig_running_manage() {   # prints one line per running 'cpd-cli manage'
    local out line pid i found
    local IFS=$' \t\n'
    local -a words rest
    out="$(ps -axo pid=,command= 2>/dev/null || true)"
    for line in "${(@f)out}"; do
        words=(${=line})
        (( ${#words} >= 3 )) || continue
        pid="${words[1]}"
        if [[ "${pid}" == "$$" || "${pid}" == "${PPID}" ]]; then
            continue
        fi
        rest=("${(@)words[2,-1]}")
        # An interpreter running the script counts (the shim, for example).
        case "${rest[1]:t}" in
            sh|bash|zsh|dash|-zsh|-bash|python|python3|python3.*)
                i=2
                while (( i <= ${#rest} )) && [[ "${rest[$i]}" == -* ]]; do
                    (( i += 1 ))
                done
                (( i <= ${#rest} )) || continue
                rest=("${(@)rest[i,-1]}")
                ;;
        esac
        found="$(_mcm_mig_manage_in_words "${rest[@]}")" || continue
        print -r -- "pid ${pid}: ${found}"
    done
    return 0
}

# A process's working folder. Empty when it cannot be read.
_mcm_mig_process_cwd() {   # PID
    local pid="$1" lsof_bin line
    if [[ -L "/proc/${pid}/cwd" ]]; then
        readlink "/proc/${pid}/cwd" 2>/dev/null || true
        return 0
    fi
    lsof_bin="${commands[lsof]:-/usr/sbin/lsof}"
    [[ -x "${lsof_bin}" ]] || return 0
    for line in "${(@f)$("${lsof_bin}" -a -p "${pid}" -d cwd -Fn 2>/dev/null || true)}"; do
        if [[ "${line}" == n/* ]]; then
            print -r -- "${line#n}"
            return 0
        fi
    done
    return 0
}

# The script file a zsh command line runs, as a full path; sets REPLY. ps joins argv with
# spaces, so a path holding a space is rebuilt word by word until a file exists. A
# relative path needs the process's folder; if that cannot be read, a script of the same
# name in this checkout counts, so the failure mode is refusing.
_mcm_mig_zsh_script() {   # PID WORD...
    local pid="$1" base="" k candidate i=2
    local -a w same
    shift
    w=("$@")
    REPLY=""
    case "${w[1]:t}" in
        zsh|-zsh|zsh-*) ;;
        *) return 1 ;;
    esac
    while (( i <= ${#w} )); do
        case "${w[$i]}" in
            --)              (( i += 1 )); break ;;
            --*)             (( i += 1 )) ;;
            -o|+o)           (( i += 2 )) ;;
            -c*|-[!-]*c*)    return 1 ;;
            -*|+*)           (( i += 1 )) ;;
            *)               break ;;
        esac
    done
    (( i <= ${#w} )) || return 1
    if [[ "${w[$i]}" != /* ]]; then
        base="$(_mcm_mig_process_cwd "${pid}")"
        if [[ -z "${base}" ]]; then
            same=("${MCM_MIG_REPO}/scripts"/**/"${w[$i]:t}"(.N) "${MCM_MIG_REPO}/src/utilities"/**/"${w[$i]:t}"(.N))
            (( ${#same} > 0 )) || return 1
            REPLY="${same[1]}"
            return 0
        fi
        base+="/"
    fi
    for (( k = i; k <= ${#w}; k++ )); do
        candidate="${base}${(j: :)w[i,k]}"
        if [[ -f "${candidate}" ]]; then
            REPLY="${candidate:A}"
            return 0
        fi
    done
    return 1
}

# A single-cluster chain holds no lease, and between 'cpd-cli manage' calls nothing else
# shows it: a mode change would send its next step to another cluster's folders. Prints
# one line per script of this checkout that zsh is running, leaving out this process,
# the ones that started it and this utility's own scripts.
_mcm_mig_running_repo_scripts() {   # prints "pid N: relative/script.sh"
    local out line pid walk script
    local IFS=$' \t\n'
    local -a lines words seen
    local -A parent mine
    out="$(ps -axww -o pid=,ppid=,command= 2>/dev/null || true)"
    lines=("${(@f)out}")
    for line in "${lines[@]}"; do
        words=(${=line})
        (( ${#words} >= 2 )) || continue
        [[ "${words[1]}" == <-> && "${words[2]}" == <-> ]] || continue
        parent[${words[1]}]="${words[2]}"
    done
    walk="$$"
    while [[ -n "${walk}" && "${walk}" != 0 && -z "${mine[$walk]:-}" ]]; do
        mine[$walk]=1
        walk="${parent[$walk]:-}"
    done
    for line in "${lines[@]}"; do
        words=(${=line})
        (( ${#words} >= 3 )) || continue
        [[ "${words[1]}" == <-> && "${words[2]}" == <-> ]] || continue
        pid="${words[1]}"
        [[ -z "${mine[$pid]:-}" ]] || continue
        _mcm_mig_zsh_script "${pid}" "${(@)words[3,-1]}" || continue
        script="${REPLY}"
        case "${script}" in
            "${MCM_MIG_REPO}/src/utilities/multi_cluster_management_utils/"*) continue ;;
            "${MCM_MIG_REPO}/scripts/"*|"${MCM_MIG_REPO}/src/utilities/"*) ;;
            *) continue ;;
        esac
        (( ! ${seen[(Ie)${script}]} )) || continue
        seen+=("${script}")
        print -r -- "pid ${pid}: ${script#"${MCM_MIG_REPO}/"}"
    done
    return 0
}

_mcm_mig_running_containers() {   # prints names; non-zero when podman is unreachable
    podman ps --format '{{.Names}}' 2>/dev/null
}

_mcm_mig_managed_container() {
    case "${1:-}" in
        "${MCM_MIG_FLAT_CONTAINER}"|"${MCM_MIG_FLAT_CONTAINER}"-*) return 0 ;;
        "${MCM_MIG_SWHCC_CONTAINER}"|"${MCM_MIG_SWHCC_CONTAINER}"-*) return 0 ;;
    esac
    return 1
}

# The shared process scan, so there is one idle list (_mcm_scan_busy_lines). A failed
# scan counts as busy too, so the failure mode is refusing, not moving folders under
# a running job. _MCM_SCAN_NO_NOTE: a --dry-run must not create the scan log.
_mcm_mig_container_busy() {   # NAME; prints what was found when busy
    local REPLY="" _MCM_SCAN_NO_NOTE=1
    if _mcm_scan_container "${1:-}"; then
        print -r -- "${REPLY}"
        return 0
    fi
    return 1
}

_mcm_mig_preflight() {
    local lease pid name line found
    local -a names
    MCM_MIG_PREFLIGHT_ERRORS=()

    for lease in "${MCM_MIG_CPD_CLI_CLUSTERS}"/*/.leases/*(N); do
        pid="${lease:t}"
        if [[ "${pid}" != <-> || "${pid}" == "$$" || "${pid}" == "${PPID}" ]]; then
            continue
        fi
        if kill -0 "${pid}" 2>/dev/null; then
            MCM_MIG_PREFLIGHT_ERRORS+=("A run is live on cluster ${lease:h:h:t} (lease $(_mcm_mig_short "${lease}")).")
        fi
    done

    for line in "${(@f)$(_mcm_mig_running_manage)}"; do
        [[ -n "${line}" ]] || continue
        MCM_MIG_PREFLIGHT_ERRORS+=("cpd-cli manage is running (${line}).")
    done

    for line in "${(@f)$(_mcm_mig_running_repo_scripts)}"; do
        [[ -n "${line}" ]] || continue
        MCM_MIG_PREFLIGHT_ERRORS+=("A script of this checkout is running (${line}). Wait for it or stop it: a single-cluster run holds no lease, and would switch cluster folders at its next step.")
    done

    if ! found="$(_mcm_mig_running_containers)"; then
        echo "[WARN] Podman is not reachable, so running containers cannot be checked. A stopped machine has no busy container."
        return 0
    fi
    names=("${(@f)found}")
    for name in "${names[@]}"; do
        [[ -n "${name}" ]] || continue
        _mcm_mig_managed_container "${name}" || continue
        if line="$(_mcm_mig_container_busy "${name}")"; then
            MCM_MIG_PREFLIGHT_ERRORS+=("Container ${name} is busy (${line}). Wait for it, or stop it with podman stop if it is not doing anything.")
        fi
    done
    return 0
}

_mcm_mig_report_preflight() {
    local item
    for item in "${MCM_MIG_PREFLIGHT_ERRORS[@]}"; do
        echo "[ERROR] Preflight: ${item}" >&2
    done
}

# --- ~/.kube/config contexts --------------------------------------------------
typeset -gA MCM_MIG_KUBE_SERVER MCM_MIG_KUBE_CTX_CLUSTER
MCM_MIG_KUBE_CONTEXTS=()
MCM_MIG_KUBE_CURRENT=""

_mcm_mig_read_kubeconfig() {
    local out line name value
    MCM_MIG_KUBE_CONTEXTS=()
    if [[ ! -f "${MCM_MIG_KUBE}" ]] || ! (( ${+commands[oc]} )); then
        return 0
    fi
    out="$(oc config view --kubeconfig="${MCM_MIG_KUBE}" -o jsonpath='{range .clusters[*]}{.name}{"\t"}{.cluster.server}{"\n"}{end}' 2>/dev/null || true)"
    for line in "${(@f)out}"; do
        [[ "${line}" == *$'\t'* ]] || continue
        name="${line%%$'\t'*}"
        value="${line#*$'\t'}"
        MCM_MIG_KUBE_SERVER[$name]="${value}"
    done
    out="$(oc config view --kubeconfig="${MCM_MIG_KUBE}" -o jsonpath='{range .contexts[*]}{.name}{"\t"}{.context.cluster}{"\n"}{end}' 2>/dev/null || true)"
    for line in "${(@f)out}"; do
        [[ "${line}" == *$'\t'* ]] || continue
        name="${line%%$'\t'*}"
        value="${line#*$'\t'}"
        MCM_MIG_KUBE_CONTEXTS+=("${name}")
        MCM_MIG_KUBE_CTX_CLUSTER[$name]="${value}"
    done
    MCM_MIG_KUBE_CURRENT="$(oc config current-context --kubeconfig="${MCM_MIG_KUBE}" 2>/dev/null || true)"
    return 0
}

# The context for CLUSTER: an exact URL match, the current context first among those.
# Only when the cluster has no known URL, the name its server derives to. The token of
# another cluster that happens to derive to the same name must not be filed here.
# Sets REPLY.
_mcm_mig_find_context() {   # CLUSTER URL
    local cluster="$1" url="$2" ctx server exact="" named="" derived
    REPLY=""
    for ctx in "${MCM_MIG_KUBE_CONTEXTS[@]}"; do
        server="${MCM_MIG_KUBE_SERVER[${MCM_MIG_KUBE_CTX_CLUSTER[$ctx]:-}]:-}"
        [[ -n "${server}" ]] || continue
        if [[ -n "${url}" ]]; then
            if [[ "${(L)${server%/}}" == "${(L)${url%/}}" ]]; then
                if [[ "${ctx}" == "${MCM_MIG_KUBE_CURRENT}" ]]; then
                    REPLY="${ctx}"
                    return 0
                fi
                [[ -n "${exact}" ]] || exact="${ctx}"
            fi
            continue
        fi
        derived="$(mcm_name_from_url "${server}" 2>/dev/null || true)"
        if [[ "${derived}" == "${cluster}" ]]; then
            if [[ "${ctx}" == "${MCM_MIG_KUBE_CURRENT}" ]]; then
                REPLY="${ctx}"
                return 0
            fi
            [[ -n "${named}" ]] || named="${ctx}"
        fi
    done
    REPLY="${exact:-${named}}"
    return 0
}

# --- Forward plan ------------------------------------------------------------
_mcm_mig_mapped() {   # KEY; sets REPLY
    MCM_MIG_KNOWN_KEYS+=("${1}")
    REPLY="${MCM_MIG_MAP[$1]:-}"
    if [[ -z "${REPLY}" && "${1}" == *_config ]]; then
        REPLY="${MCM_MIG_MAP[${1%_config}]:-}"
    fi
    return 0
}

_mcm_mig_route() {   # KEY DERIVED; sets REPLY to the cluster
    local key="$1" derived="${2:-}"
    _mcm_mig_mapped "${key}"
    if [[ -n "${REPLY}" ]]; then
        return 0
    fi
    if [[ -n "${derived}" ]]; then
        if [[ -n "${MCM_MIG_NAME}" && "${derived}" == "${MCM_MIG_RENAME_FROM}" ]]; then
            REPLY="${MCM_MIG_NAME}"
        else
            REPLY="${derived}"
        fi
        return 0
    fi
    REPLY="${MCM_MIG_PRIMARY}"
    return 0
}

_mcm_mig_cluster_or_die() {   # CLUSTER ITEM
    if [[ -z "${1:-}" ]]; then
        _mcm_mig_die "No cluster for ${2}: nothing holds cp4d_config and several clusters were found. Give one with --name NAME or --map ${2}=NAME."
    fi
}

_mcm_mig_add_move() {   # KEY CLUSTER SRC DST [keep]
    _mcm_mig_cluster_or_die "${2}" "${1}"
    _mcm_mig_seen "${2}"
    _mcm_mig_add mv "${2}" "${3}" "${4}" "${5:-}"
}

_mcm_mig_build_forward_plan() {
    local dir name file url derived cluster croot item has_vars key
    local -a products groups urls entries
    typeset -A p_url p_derived p_has_vars p_cluster

    # 1. Product folders: read the URLs before deciding anything.
    for dir in "${MCM_MIG_CONFIGS}"/*_config(/N); do
        name="${dir:t}"
        [[ "${name}" != openshift_config ]] || continue
        _mcm_mig_has_content "${dir}" || continue
        _mcm_mig_product_url "${dir}"
        url="${REPLY}"
        has_vars="${reply[1]}"
        derived=""
        if [[ -n "${url}" ]]; then
            derived="$(mcm_name_from_url "${url}")" || _mcm_mig_die "${name}: cannot derive a cluster from its OCP_URL. Use --map ${name}=NAME."
        fi
        products+=("${name}")
        p_url[$name]="${url}"
        p_derived[$name]="${derived}"
        p_has_vars[$name]="${has_vars}"
        if [[ -n "${derived}" ]] && (( ! ${groups[(Ie)${derived}]} )); then
            groups+=("${derived}")
        fi
    done

    # 2. The cluster holding CP4D is where everything without a URL goes.
    _mcm_mig_mapped cp4d_config
    if [[ -n "${REPLY}" ]]; then
        MCM_MIG_PRIMARY="${REPLY}"
        if [[ -n "${MCM_MIG_NAME}" ]]; then
            echo "[WARN] --name ${MCM_MIG_NAME} is ignored for cp4d_config, which has its own --map." >&2
        fi
    elif [[ -n "${p_derived[cp4d_config]:-}" ]]; then
        MCM_MIG_RENAME_FROM="${p_derived[cp4d_config]}"
        MCM_MIG_PRIMARY="${MCM_MIG_NAME:-${MCM_MIG_RENAME_FROM}}"
    elif [[ -n "${MCM_MIG_NAME}" ]]; then
        MCM_MIG_PRIMARY="${MCM_MIG_NAME}"
        if (( ${#groups} == 1 )); then
            MCM_MIG_RENAME_FROM="${groups[1]}"
        fi
    elif (( ${#groups} == 1 )); then
        MCM_MIG_PRIMARY="${groups[1]}"
    fi
    if [[ -n "${MCM_MIG_NAME}" ]]; then
        mcm_validate_name "${MCM_MIG_NAME}" || exit 1
    fi

    # 3. Product folders.
    for name in "${products[@]}"; do
        _mcm_mig_route "${name}" "${p_derived[$name]}"
        cluster="${REPLY}"
        if [[ -z "${p_derived[$name]}" ]]; then
            echo "[WARN] ${name} has no OCP_URL; it goes with the CP4D cluster${cluster:+ (${cluster})}."
        fi
        _mcm_mig_cluster_or_die "${cluster}" "${name}"
        mcm_validate_name "${cluster}" || exit 1
        p_cluster[$name]="${cluster}"
        croot="${MCM_MIG_CLUSTERS_ROOT}/${cluster}"
        _mcm_mig_seen "${cluster}" "${p_has_vars[$name]}"
        _mcm_mig_claim_url "${name}" "${cluster}" "${p_url[$name]}"
        # Absolute paths inside the folder (truststores, certs) are the paths step's.
        _mcm_mig_add_move "${name}" "${cluster}" "${MCM_MIG_CONFIGS}/${name}" "${croot}/${name}"
    done

    # 4. openshift_config, one file at a time.
    local flat_openshift="${MCM_MIG_CONFIGS}/openshift_config"
    if [[ -d "${flat_openshift}" ]]; then
        # Credential files may rely on the folder's mode alone.
        MCM_MIG_JMETA[openshift_mode]="$(_mcm_mig_dir_mode "${flat_openshift}")"
        _mcm_mig_entries "${flat_openshift}"
        entries=("${reply[@]}")
        for item in "${entries[@]}"; do
            name="${item:t}"
            urls=()
            if [[ -f "${item}" ]]; then
                _mcm_mig_comment_urls "${item}"
                urls=("${reply[@]}")
            fi
            derived=""
            url=""
            if (( ${#urls} == 1 )); then
                url="${urls[1]}"
                derived="$(mcm_name_from_url "${url}")" || derived=""
            elif (( ${#urls} > 1 )) && [[ -z "${MCM_MIG_MAP[$name]:-}" ]]; then
                echo "[WARN] openshift_config/${name} names several cluster URLs (${(j:, :)urls}); it goes with the CP4D cluster."
            fi
            _mcm_mig_route "${name}" "${derived}"
            cluster="${REPLY}"
            _mcm_mig_cluster_or_die "${cluster}" "${name}"
            mcm_validate_name "${cluster}" || exit 1
            _mcm_mig_seen "${cluster}"
            _mcm_mig_claim_url "${name}" "${cluster}" "${url}"
            _mcm_mig_add_move "${name}" "${cluster}" "${item}" "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/openshift_config/${name}"
            if [[ -n "${MCM_MIG_PRIMARY}" && "${cluster}" != "${MCM_MIG_PRIMARY}" ]]; then
                if [[ "${name}" == service_id_credentials.txt ]]; then
                    MCM_MIG_NOTES+=("service_id_credentials.txt goes to ${cluster} and is no longer visible on ${MCM_MIG_PRIMARY}: StreamSets step 5.3, generate_service_id_cpd_apikeys.sh and the Iceberg setup will report it missing there. That is correct, those IDs exist on ${cluster}.")
                else
                    MCM_MIG_NOTES+=("openshift_config/${name} goes to ${cluster} and is no longer visible on ${MCM_MIG_PRIMARY}.")
                fi
            fi
        done
    fi

    _mcm_mig_settle_urls

    # 5. The rest of the cluster's data.
    local src
    item=service_instances
    _mcm_mig_route "${item}" ""
    cluster="${REPLY}"
    if _mcm_mig_has_content "${MCM_MIG_REPO}/${item}"; then
        _mcm_mig_add_move "${item}" "${cluster}" "${MCM_MIG_REPO}/${item}" "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/${item}"
    fi

    # Entry by entry: the scale-config cache is shared and stays.
    item=cpd-cli-workspace
    _mcm_mig_route "${item}" ""
    cluster="${REPLY}"
    _mcm_mig_entries "${MCM_MIG_REPO}/${item}"
    entries=("${reply[@]}")
    for src in "${entries[@]}"; do
        [[ "${src:t}" != scale_config_cache ]] || continue
        _mcm_mig_add_move "${item}" "${cluster}" "${src}" "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/${item}/${src:t}"
    done

    # Workspaces follow their product.
    local workspace product
    for workspace product in concert_workspace concert_config \
        datastax_mc_workspace datastax_mc_config kubecost_workspace kubecost_config; do
        _mcm_mig_mapped "${workspace}"
        cluster="${REPLY}"
        if [[ -z "${cluster}" ]]; then
            cluster="${p_cluster[$product]:-${MCM_MIG_PRIMARY}}"
        fi
        if _mcm_mig_has_content "${MCM_MIG_REPO}/${workspace}"; then
            _mcm_mig_add_move "${workspace}" "${cluster}" "${MCM_MIG_REPO}/${workspace}" "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/${workspace}"
        fi
    done

    # ~/cpd-cli/work and the Control Center workspace. The empty folders stay,
    # because the flat layout needs them to exist.
    _mcm_mig_route cpd-cli-work ""
    cluster="${REPLY}"
    if _mcm_mig_has_content "${MCM_MIG_CPD_CLI_HOME}/work"; then
        _mcm_mig_add_move cpd-cli-work "${cluster}" "${MCM_MIG_CPD_CLI_HOME}/work" "${MCM_MIG_CPD_CLI_CLUSTERS}/${cluster}/work" keep
    fi

    local swhcc_vars="${MCM_MIG_CONFIGS}/cp4d_config/swhub_control_center/swhub_control_center_vars.sh"
    if [[ -f "${swhcc_vars}" ]]; then
        local configured
        configured="$(_mcm_mig_source_var "${swhcc_vars}" CONTROL_CPD_CLI_WORKSPACE)"
        [[ -z "${configured}" ]] || MCM_MIG_SWHCC_WORKSPACE="${configured}"
        configured="$(_mcm_mig_source_var "${swhcc_vars}" CONTROL_OLM_UTILS_CONTAINER)"
        [[ -z "${configured}" ]] || MCM_MIG_SWHCC_CONTAINER="${configured}"
    fi
    local swhcc_moved=false
    _mcm_mig_route swhub-control-center-work ""
    cluster="${REPLY}"
    if _mcm_mig_has_content "${MCM_MIG_SWHCC_WORKSPACE}/work"; then
        _mcm_mig_add_move swhub-control-center-work "${cluster}" "${MCM_MIG_SWHCC_WORKSPACE}/work" "${MCM_MIG_CPD_CLI_CLUSTERS}/${cluster}/swhub-control-center/work" keep
        swhcc_moved=true
    fi

    # OADP bucket and restore-target configs (S3 credentials, target logins).
    _mcm_mig_route oadp ""
    cluster="${REPLY}"
    for item in backup_bucket_configs restore_target_configs; do
        if _mcm_mig_has_content "${MCM_MIG_OADP_DIR}/${item}"; then
            _mcm_mig_add_move oadp "${cluster}" "${MCM_MIG_OADP_DIR}/${item}" "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/oadp/${item}"
        fi
    done

    # Rendered Confluent and Flink manifests go with the Confluent config.
    _mcm_mig_mapped confluent-rendered
    cluster="${REPLY}"
    [[ -n "${cluster}" ]] || cluster="${p_cluster[confluent_platform_config]:-${MCM_MIG_PRIMARY}}"
    if _mcm_mig_has_content "${MCM_MIG_CONFLUENT_RENDERED}"; then
        _mcm_mig_add_move confluent-rendered "${cluster}" "${MCM_MIG_CONFLUENT_RENDERED}" "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/confluent_platform_vars/rendered"
    fi
    _mcm_mig_mapped flink-rendered
    cluster="${REPLY}"
    [[ -n "${cluster}" ]] || cluster="${p_cluster[confluent_platform_config]:-${MCM_MIG_PRIMARY}}"
    if _mcm_mig_has_content "${MCM_MIG_FLINK_RENDERED}"; then
        _mcm_mig_add_move flink-rendered "${cluster}" "${MCM_MIG_FLINK_RENDERED}" "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/flink_vars/rendered"
    fi

    # 6. cpd-cli profiles are copied to the CP4D cluster.
    _mcm_mig_route cpd-cli-profiles ""
    cluster="${REPLY}"
    local profiles_src="${HOME}/.cpd-cli/config" profiles_dst
    # With nothing planned and no cluster to name (a finished migration leaves no
    # cp4d_config behind), the profiles alone are not a reason to run.
    if [[ -f "${profiles_src}" ]] && { [[ -n "${cluster}" ]] || (( ${#MCM_MIG_E_KIND} > 0 )); }; then
        _mcm_mig_cluster_or_die "${cluster}" cpd-cli-profiles
        profiles_dst="${MCM_MIG_CLUSTERS_ROOT}/${cluster}/.home/.cpd-cli/config"
        if [[ ! -e "${profiles_dst}" ]]; then
            _mcm_mig_seen "${cluster}"
            _mcm_mig_add cp "${cluster}" "${profiles_src}" "${profiles_dst}"
        fi
    fi

    local forward_moves=${#MCM_MIG_E_KIND}

    # 7. Mirror state, only on request.
    if [[ -n "${MCM_MIG_MIRROR_TO}" ]]; then
        local mirror_key
        mirror_key="$(mcm_mirror_destination_key "${MCM_MIG_MIRROR_TO}")" \
            || _mcm_mig_die "--mirror-state-to: '${MCM_MIG_MIRROR_TO}' is not a registry root."
        if [[ -d "${MCM_MIG_MIRROR_WS}" ]]; then
            _mcm_mig_entries "${MCM_MIG_MIRROR_WS}"
            entries=("${reply[@]}")
            for src in "${entries[@]}"; do
                case "${src:t}" in
                    tools|local-registry|local-registry-*|registries) continue ;;
                    cluster)
                        cluster="${p_cluster[registry_mirror_config]:-${MCM_MIG_PRIMARY}}"
                        if [[ -n "${cluster}" ]]; then
                            _mcm_mig_add_move mirror-cluster "${cluster}" "${src}" "${MCM_MIG_CLUSTERS_ROOT}/${cluster}/registry_mirror_cluster"
                        else
                            echo "[WARN] registry_mirror_workspace/cluster is left in place: no cluster to give it to."
                        fi
                        continue ;;
                esac
                _mcm_mig_add mv "" "${src}" "${MCM_MIG_MIRROR_WS}/registries/${mirror_key}/${src:t}"
            done
        else
            echo "[WARN] --mirror-state-to: there is no registry_mirror_workspace folder, so nothing to assign."
        fi
    fi

    # 8. --map keys must name something in the plan.
    local map_key
    for map_key in "${(@k)MCM_MIG_MAP}"; do
        if (( ! ${MCM_MIG_KNOWN_KEYS[(Ie)${map_key}]} && ! ${MCM_MIG_KNOWN_KEYS[(Ie)${map_key}_config]} )); then
            _mcm_mig_die "--map ${map_key}: not an item in this migration. Known: ${(j:, :)${(@ou)MCM_MIG_KNOWN_KEYS}}."
        fi
    done

    if (( forward_moves == 0 && ${#MCM_MIG_E_KIND} == 0 )); then
        return 0
    fi

    # 8b. Generated configs hold absolute paths of what just moved: instance details point
    # at certs/<instance>/ca.crt, Confluent properties at truststores, DataStax details at
    # the bundle zip. Every move's old path becomes its new one inside the moved configs.
    if (( ${MCM_MIG_E_KIND[(Ie)mv]} )); then
        _mcm_mig_path_candidates src
        _mcm_mig_add paths "" "" "" "${#reply}"
    fi

    # 9. Seed each cluster's oc session from ~/.kube/config.
    _mcm_mig_read_kubeconfig
    local kube_dst
    for cluster in "${MCM_MIG_CLUSTERS[@]}"; do
        kube_dst="${MCM_MIG_CLUSTERS_ROOT}/${cluster}/.home/.kube/config"
        [[ ! -e "${kube_dst}" ]] || continue
        url="${MCM_MIG_CLUSTER_URL[$cluster]:-}"
        [[ -n "${url}" ]] || continue
        _mcm_mig_find_context "${cluster}" "${url}"
        if [[ -n "${REPLY}" ]]; then
            _mcm_mig_add seed "${cluster}" "${kube_dst}" "${REPLY}"
        fi
    done

    # 10. The flat container's bind mount would point at an empty folder.
    if (( forward_moves > 0 )); then
        _mcm_mig_add rmc "" "${MCM_MIG_FLAT_CONTAINER}"
        if [[ "${swhcc_moved}" == true ]]; then
            _mcm_mig_add rmc "" "${MCM_MIG_SWHCC_CONTAINER}"
        fi
    fi

    # 11. Registration, then the switch. Only clusters left with a *_vars.sh join.
    local current="${MCM_CURRENT_CLUSTER:-}"
    local -a registered_now
    for cluster in "${MCM_MIG_CLUSTERS[@]}"; do
        [[ "${MCM_MIG_CLUSTER_VARS[$cluster]:-}" == 1 ]] || continue
        registered_now+=("${cluster}")
        if ! _mcm_mig_registered "${cluster}"; then
            _mcm_mig_add register "${cluster}" "${cluster}" "${MCM_MIG_CLUSTER_URL[$cluster]:-}"
        fi
    done
    if (( forward_moves > 0 && ${#registered_now} > 0 )); then
        if (( ${registered_now[(Ie)${MCM_MIG_PRIMARY}]} )); then
            current="${MCM_MIG_PRIMARY}"
        elif [[ -z "${current}" ]]; then
            current="${registered_now[1]}"
        fi
        _mcm_mig_add state "" true "${current}"
    fi
}

_mcm_mig_marker_url() {
    local line
    [[ -f "${1}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" == OCP_URL=\"*\" ]]; then
            line="${line#*=\"}"
            print -r -- "${line%\"}"
            return 0
        fi
    done < "${1}"
    return 0
}

# --- Printing the plan --------------------------------------------------------
_mcm_mig_describe() {   # INDEX; prints one line
    local i="$1" a="${MCM_MIG_E_A[$i]}" b="${MCM_MIG_E_B[$i]}" c="${MCM_MIG_E_C[$i]}"
    case "${MCM_MIG_E_KIND[$i]}" in
        mv)         print -r -- "move $(_mcm_mig_short "${a}") -> $(_mcm_mig_short "${b}")" ;;
        cp)         print -r -- "copy $(_mcm_mig_short "${a}") -> $(_mcm_mig_short "${b}")" ;;
        rewrite)    print -r -- "rewrite the truststore path in $(_mcm_mig_short "${a}")/*.properties to $(_mcm_mig_short "${c}")" ;;
        paths)      print -r -- "update the moved folders' paths inside the moved config files (${c:-0} file(s) found when planned)" ;;
        seed)       print -r -- "seed $(_mcm_mig_short "${a}") from ~/.kube/config context ${b}" ;;
        rmc)        print -r -- "remove container ${a} after the idle check" ;;
        register)   print -r -- "register cluster ${a}${b:+ (${b})}, delineated for good" ;;
        state)      print -r -- "set MULTI_CLUSTER_MANAGEMENT=${a}, MCM_CURRENT_CLUSTER=${b:-<empty>}" ;;
    esac
}

_mcm_mig_has_register() {   # CLUSTER
    local i
    for (( i = 1; i <= ${#MCM_MIG_E_KIND}; i++ )); do
        if [[ "${MCM_MIG_E_KIND[$i]}" == register && "${MCM_MIG_E_A[$i]}" == "${1}" ]]; then
            return 0
        fi
    done
    return 1
}

_mcm_mig_print_plan() {
    local i cluster label done_count=0 total=${#MCM_MIG_E_KIND}
    local -a groups
    _mcm_mig_plan_clusters
    local -a moved=("${reply[@]}")
    for (( i = 1; i <= total; i++ )); do
        if (( ! ${groups[(Ie)${MCM_MIG_E_CLUSTER[$i]}]} )); then
            groups+=("${MCM_MIG_E_CLUSTER[$i]}")
        fi
        if [[ "${MCM_MIG_E_STATE[$i]:-}" == done ]]; then
            (( done_count += 1 ))
        fi
    done
    print -r -- "[INFO] Plan: ${total} step(s)$( (( done_count > 0 )) && print -r -- ", ${done_count} already done")."
    for cluster in "${groups[@]}"; do
        if [[ -n "${cluster}" ]]; then
            label="${cluster}"
            if (( ${MCM_MIG_E_A[(Ie)${cluster}]} )) && _mcm_mig_has_register "${cluster}"; then
                label+=" (will be registered)"
            elif _mcm_mig_registered "${cluster}"; then
                label+=" (already registered)"
            else
                label+=" (folder only, not registered)"
            fi
            label+=" - permanent, never goes back to the flat layout"
            print -r -- "  ${label}:"
        else
            print -r -- "  everything else:"
        fi
        for (( i = 1; i <= total; i++ )); do
            [[ "${MCM_MIG_E_CLUSTER[$i]}" == "${cluster}" ]] || continue
            print -r -- "    $( [[ "${MCM_MIG_E_STATE[$i]:-}" == done ]] && print -r -- '[done] ')$(_mcm_mig_describe "${i}")"
        done
    done
    local note
    for note in "${MCM_MIG_NOTES[@]}"; do
        print -r -- "[NOTE] ${note}"
    done
    if (( ${#moved} > 0 )); then
        print -r -- "[WARN] One way: the move into configs/clusters/<name>/ is permanent for each cluster listed (${(j:, :)moved}). Once this migration completes there is no way back to the flat layout for them, and --rollback no longer applies. The repo-wide default can still be switched with multi_cluster.sh off."
    fi
}

# The clusters the plan moves something into, in plan order. Sets reply.
_mcm_mig_plan_clusters() {
    local i cluster
    reply=()
    for (( i = 1; i <= ${#MCM_MIG_E_KIND}; i++ )); do
        cluster="${MCM_MIG_E_CLUSTER[$i]}"
        if [[ -n "${cluster}" ]] && (( ! ${reply[(Ie)${cluster}]} )); then
            reply+=("${cluster}")
        fi
    done
    return 0
}

_mcm_mig_print_stays() {
    print -r -- "[INFO] Staying where they are: configs/old_configs/, cpd-cli-workspace/scale_config_cache/, ~/cpd-cli/m_backups/$( [[ -n "${MCM_MIG_MIRROR_TO}" ]] || print -r -- ', registry_mirror_workspace/ (use --mirror-state-to to assign it)')."
}

# --- Applying and undoing -----------------------------------------------------
# Suffix of a file being written beside its destination. A fixed name, so a resume or
# an undo can clear what a killed run left behind.
MCM_MIG_PARTIAL=".mcm-partial"

# mkdir -p for a file's parent. A new openshift_config folder gets the mode its
# source folder had, from the moment it exists.
_mcm_mig_make_parent() {   # PATH
    local dir="${1:h}" mode="${MCM_MIG_JMETA[openshift_mode]:-}"
    if [[ "${dir:t}" == openshift_config && -n "${mode}" && ! -d "${dir}" ]]; then
        mkdir -p "${dir:h}" || return 1
        mkdir -m "${mode}" "${dir}"
        return
    fi
    mkdir -p "${dir}"
}

_mcm_mig_do_mv() {   # SRC DST [keep]
    local src="$1" dst="$2" keep="${3:-}"
    if [[ ! -e "${src}" && ! -L "${src}" ]]; then
        if [[ -e "${dst}" || -L "${dst}" ]]; then
            # A kill between the mv and the mkdir below lands here.
            if [[ "${keep}" == keep ]]; then
                mkdir -p "${src}" || return 1
            fi
            return 0
        fi
        echo "[ERROR] Missing: ${src}" >&2
        return 1
    fi
    if [[ -e "${dst}" || -L "${dst}" ]]; then
        if [[ "${keep}" == keep ]] && _mcm_mig_empty_dir "${src}"; then
            return 0
        fi
        if _mcm_mig_empty_dir "${dst}"; then
            _mcm_mig_rmdir_empty "${dst}"
        else
            echo "[ERROR] Already exists, will not overwrite: ${dst}" >&2
            return 1
        fi
    fi
    _mcm_mig_make_parent "${dst}" || return 1
    mv "${src}" "${dst}" || return 1
    if [[ "${keep}" == keep ]]; then
        mkdir -p "${src}" || return 1
    fi
    return 0
}

# Copies to a temp file beside DST, 0600, then renames: DST is never partial.
_mcm_mig_install_file() {   # SRC DST
    local src="$1" dst="$2" tmp="${2}${MCM_MIG_PARTIAL}"
    rm -f "${tmp}"
    if ( umask 077; cp "${src}" "${tmp}" ) && chmod 600 "${tmp}" && mv -f "${tmp}" "${dst}"; then
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

_mcm_mig_do_cp() {   # SRC DST
    local src="$1" dst="$2"
    [[ -f "${dst}" ]] && return 0
    mkdir -p "${dst:h}" || return 1
    chmod 700 "${dst:h}" "${dst:h:h}" || return 1
    _mcm_mig_install_file "${src}" "${dst}"
}

# A file's checksum, kept in the journal folder so an undo can tell whether the
# seeded session is still the one this script wrote. Holds no credential.
_mcm_mig_seed_sum_file() { print -r -- "${MCM_MIG_JOURNAL_DIR}/seed-${1:h:h:h:t}.cksum"; }   # DST
_mcm_mig_checksum() { cksum < "${1}"; }

_mcm_mig_do_seed() {   # DST CONTEXT; a failure only costs a later login, so it warns
    local dst="$1" context="$2" tmp="${1}${MCM_MIG_PARTIAL}" sum
    [[ -f "${dst}" ]] && return 0
    mkdir -p "${dst:h}" || return 1
    chmod 700 "${dst:h}" "${dst:h:h}" || return 1
    rm -f "${tmp}"
    if ( umask 077; oc config view --kubeconfig="${MCM_MIG_KUBE}" --context="${context}" --minify --flatten >"${tmp}" 2>/dev/null ) \
        && [[ -s "${tmp}" ]]; then
        chmod 600 "${tmp}"
        sum="$(_mcm_mig_seed_sum_file "${dst}")"
        _mcm_mig_checksum "${tmp}" >"${sum}" 2>/dev/null || rm -f "${sum}"
        mv -f "${tmp}" "${dst}"
        return 0
    fi
    rm -f "${tmp}"
    echo "[WARN] Could not extract context ${context} from ~/.kube/config. The next oc login fills $(_mcm_mig_short "${dst}")."
    return 0
}

_mcm_mig_rewrite_truststores() {   # DIR OLD NEW
    local dir="$1" old="$2" new="$3" file line key value tmp changed=0
    local -a out
    for file in "${dir}"/**/*.properties(.DN); do
        changed=0
        out=()
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" == *ssl.truststore.location=* ]]; then
                key="${line%%=*}"
                value="${line#*=}"
                if [[ "${key}" == *ssl.truststore.location && "${value}" == "${old}"/* ]]; then
                    line="${key}=${new}/${value#"${old}/"}"
                    changed=1
                fi
            fi
            out+=("${line}")
        done < "${file}"
        (( changed == 1 )) || continue
        tmp="$(mktemp "${file}.XXXXXX")" || return 1
        if ! cp -p "${file}" "${tmp}" || ! print -rl -- "${out[@]}" >"${tmp}" || ! mv -f "${tmp}" "${file}"; then
            rm -f "${tmp}"
            return 1
        fi
    done
    return 0
}

# --- Paths inside the moved configs -------------------------------------------
# Folders whose files are scanned: the configs and what sits beside them (certs, instance
# details, OADP targets, rendered manifests), not the workspaces (logs, caches, downloads,
# ~/cpd-cli) or the seeded .home.
_mcm_mig_path_scanned() {   # DST
    local rel
    [[ "${1}" == "${MCM_MIG_CLUSTERS_ROOT}/"* ]] || return 1
    rel="${1#"${MCM_MIG_CLUSTERS_ROOT}/"}"
    [[ "${rel}" == */* ]] || return 1
    rel="${rel#*/}"
    case "${rel%%/*}" in
        *_workspace|cpd-cli-workspace|.home) return 1 ;;
    esac
    return 0
}

# Every move as FROM<TAB>TO, longest FROM first, so a nested move wins over its parent.
# fwd: old path to new; back: new path to old. Sets reply.
_mcm_mig_path_moves() {   # fwd|back
    local i from to
    local -a rows
    for (( i = 1; i <= ${#MCM_MIG_E_KIND}; i++ )); do
        [[ "${MCM_MIG_E_KIND[$i]}" == mv ]] || continue
        from="${MCM_MIG_E_A[$i]}"
        to="${MCM_MIG_E_B[$i]}"
        if [[ "${1}" == back ]]; then
            from="${MCM_MIG_E_B[$i]}"
            to="${MCM_MIG_E_A[$i]}"
        fi
        rows+=("${#from}"$'\t'"${from}"$'\t'"${to}")
    done
    reply=("${(@On)rows}")
    reply=("${(@)reply#*$'\t'}")
    return 0
}

# The text files of the scanned folders that hold an old path of any move. src: the
# folders before the move (the plan's count), dst: after it. grep -I leaves binary
# files (zips, keystores) out, so the rewrite never reads one. Sets reply.
_mcm_mig_path_candidates() {   # src|dst
    local i target row out
    local -a targets patterns
    for (( i = 1; i <= ${#MCM_MIG_E_KIND}; i++ )); do
        [[ "${MCM_MIG_E_KIND[$i]}" == mv ]] || continue
        _mcm_mig_path_scanned "${MCM_MIG_E_B[$i]}" || continue
        target="${MCM_MIG_E_B[$i]}"
        [[ "${1}" == dst ]] || target="${MCM_MIG_E_A[$i]}"
        if [[ -e "${target}" && ! -L "${target}" ]]; then
            targets+=("${target}")
        fi
    done
    _mcm_mig_path_moves fwd
    for row in "${reply[@]}"; do
        patterns+=(-e "${row%%$'\t'*}")
    done
    reply=()
    (( ${#targets} > 0 && ${#patterns} > 0 )) || return 0
    out="$(LC_ALL=C grep -rlIF "${patterns[@]}" -- "${targets[@]}" 2>/dev/null || true)"
    reply=("${(@f)out}")
    reply=("${(@)reply:#}")
    return 0
}

# The files this step changed, one path per line in the journal folder, so --rollback
# changes back only those. Written before each file changes.
_mcm_mig_paths_list() { print -r -- "${MCM_MIG_JOURNAL_DIR}/rewritten_paths.txt"; }

_mcm_mig_rewrite_paths() {   # fwd|back
    local direction="$1" list file row from to changed=0
    local -a moves files listed
    list="$(_mcm_mig_paths_list)"
    _mcm_mig_path_moves "${direction}"
    moves=("${reply[@]}")
    if [[ "${direction}" == fwd ]]; then
        _mcm_mig_path_candidates dst
        files=("${reply[@]}")
        [[ ! -f "${list}" ]] || listed=("${(@f)$(<"${list}")}")
    else
        [[ -f "${list}" ]] || return 0
        files=("${(@fu)$(<"${list}")}")
    fi
    for file in "${files[@]}"; do
        [[ -n "${file}" && -f "${file}" && ! -L "${file}" ]] || continue
        if [[ "${direction}" == fwd ]] && (( ! ${listed[(Ie)${file}]} )); then
            print -r -- "${file}" >> "${list}" || return 1
            listed+=("${file}")
        fi
        for row in "${moves[@]}"; do
            from="${row%%$'\t'*}"
            to="${row#*$'\t'}"
            if ! mcm_replace_path_in_file "${file}" "${from}" "${to}"; then
                echo "[ERROR] Could not update the paths in $(_mcm_mig_short "${file}")." >&2
                return 1
            fi
        done
        (( changed += 1 ))
    done
    if (( changed > 0 )); then
        print -r -- "[INFO] Paths updated in ${changed} file(s); the list is in $(_mcm_mig_short "${list}")."
    fi
    return 0
}

# Never fatal: the moves are done and the container is rebuilt on next use.
_mcm_mig_remove_container() {   # NAME
    local name="${1}" rc=0 running found
    podman container exists "${name}" 2>/dev/null || rc=$?
    if (( rc == 1 )); then
        return 0
    fi
    if (( rc != 0 )); then
        echo "[WARN] Podman is not reachable, so container ${name} was not removed. When the machine is up, run: podman rm -f ${name}"
        return 0
    fi
    running="$(podman inspect --format '{{.State.Running}}' "${name}" 2>/dev/null || true)"
    if [[ "${running}" == true ]] && found="$(_mcm_mig_container_busy "${name}")"; then
        echo "[WARN] Container ${name} became busy (${found}), so it was not removed. When it is idle, run: podman rm -f ${name}"
        return 0
    fi
    if ! podman rm -f "${name}" >/dev/null 2>&1; then
        echo "[WARN] Could not remove container ${name}. Remove it with: podman rm -f ${name}"
    fi
    return 0
}

# Where a register step keeps the marker it replaced. MARKER.absent says there was none.
# Either is written before the marker changes, so an undo restores exactly what was
# there: a cluster that was delineated before this migration stays delineated.
_mcm_mig_marker_save() { print -r -- "${MCM_MIG_JOURNAL_DIR}/marker-${1}.prior"; }   # NAME

_mcm_mig_do_register() {   # NAME URL
    local name="$1" url="${2:-}" marker save
    marker="${MCM_MIG_CLUSTERS_ROOT}/${name}/.cluster"
    save="$(_mcm_mig_marker_save "${name}")"
    rm -f "${save}${MCM_MIG_PARTIAL}"
    if [[ ! -e "${save}" && ! -e "${save}.absent" ]]; then
        if [[ -f "${marker}" ]]; then
            cp -p "${marker}" "${save}${MCM_MIG_PARTIAL}" || return 1
            mv -f "${save}${MCM_MIG_PARTIAL}" "${save}" || return 1
        else
            : > "${save}.absent" || return 1
        fi
    fi
    mcm_register "${name}" "${url}"
}

# Drops NAME from the cluster lists of the state file. The marker is the caller's.
_mcm_mig_drop_from_state() {   # NAME
    local name="$1"
    local IFS=$' \t\n'
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

# Only an unfinished migration is undone, so the cluster it registered was never
# fully delineated by it. A marker that was there before comes back as it was.
_mcm_mig_undo_register() {   # NAME STEP_STATE
    local name="$1" step_state="${2:-}" marker save
    marker="${MCM_MIG_CLUSTERS_ROOT}/${name}/.cluster"
    save="$(_mcm_mig_marker_save "${name}")"
    rm -f "${save}${MCM_MIG_PARTIAL}" "${marker}${MCM_MIG_PARTIAL}"
    if [[ -f "${save}" ]]; then
        _mcm_mig_drop_from_state "${name}" || return 1
        cp -p "${save}" "${marker}${MCM_MIG_PARTIAL}" || return 1
        mv -f "${marker}${MCM_MIG_PARTIAL}" "${marker}" || return 1
        rm -f "${save}"
    elif [[ -e "${save}.absent" || "${step_state}" == done ]]; then
        # done with neither file: a journal from before the saves existed.
        _mcm_mig_drop_from_state "${name}" || return 1
        rm -f "${marker}" "${save}.absent"
        _mcm_mig_prune "${MCM_MIG_CLUSTERS_ROOT}/${name}"
    fi
    # Neither file and not done: the step never reached the marker or the state file.
    return 0
}

_mcm_mig_apply() {   # INDEX
    local i="$1" a="${MCM_MIG_E_A[$i]}" b="${MCM_MIG_E_B[$i]}" c="${MCM_MIG_E_C[$i]}"
    case "${MCM_MIG_E_KIND[$i]}" in
        mv)         _mcm_mig_do_mv "${a}" "${b}" "${c}" ;;
        cp)         _mcm_mig_do_cp "${a}" "${b}" ;;
        rewrite)    _mcm_mig_rewrite_truststores "${a}" "${b}" "${c}" ;;
        paths)      _mcm_mig_rewrite_paths fwd ;;
        seed)       _mcm_mig_do_seed "${a}" "${b}" ;;
        rmc)        _mcm_mig_remove_container "${a}" ;;
        register)   _mcm_mig_do_register "${a}" "${b}" ;;
        state)      mcm_write_state "MULTI_CLUSTER_MANAGEMENT=${a}" "MCM_CURRENT_CLUSTER=${b}" ;;
        *)          echo "[ERROR] Unknown journal step: ${MCM_MIG_E_KIND[$i]}" >&2; return 1 ;;
    esac
}

# Removes empty folders from DIR upward, inside the folders this script creates.
_mcm_mig_prune() {   # DIR
    local dir="${1}"
    while [[ "${dir}" == "${MCM_MIG_CLUSTERS_ROOT}" || "${dir}" == "${MCM_MIG_CLUSTERS_ROOT}/"* \
        || "${dir}" == "${MCM_MIG_CPD_CLI_CLUSTERS}" || "${dir}" == "${MCM_MIG_CPD_CLI_CLUSTERS}/"* \
        || "${dir}" == "${MCM_MIG_MIRROR_WS}/registries" || "${dir}" == "${MCM_MIG_MIRROR_WS}/registries/"* ]]; do
        _mcm_mig_rmdir_empty "${dir}" 2>/dev/null || return 0
        dir="${dir:h}"
    done
    return 0
}

_mcm_mig_undo_mv() {   # SRC DST
    local src="$1" dst="$2"
    if [[ ! -e "${dst}" && ! -L "${dst}" ]]; then
        # Moved back by an earlier, interrupted undo, or removed before the move.
        return 0
    fi
    # An interrupted step that never moved anything: leave SRC alone.
    if _mcm_mig_empty_dir "${dst}" && _mcm_mig_has_content "${src}"; then
        return 0
    fi
    if [[ -e "${src}" || -L "${src}" ]]; then
        if _mcm_mig_empty_dir "${src}"; then
            _mcm_mig_rmdir_empty "${src}"
        else
            echo "[ERROR] Will not overwrite ${src}: it holds new content." >&2
            return 1
        fi
    fi
    _mcm_mig_make_parent "${src}" || return 1
    mv "${dst}" "${src}" || return 1
    _mcm_mig_prune "${dst:h}"
    return 0
}

_mcm_mig_undo() {   # INDEX
    local i="$1" a="${MCM_MIG_E_A[$i]}" b="${MCM_MIG_E_B[$i]}" c="${MCM_MIG_E_C[$i]}"
    case "${MCM_MIG_E_KIND[$i]}" in
        mv)  _mcm_mig_undo_mv "${a}" "${b}" ;;
        cp)
            rm -f "${b}${MCM_MIG_PARTIAL}"
            if [[ -f "${b}" ]]; then
                if cmp -s "${a}" "${b}"; then
                    rm -f "${b}"
                    _mcm_mig_prune "${b:h}"
                else
                    echo "[WARN] Keeping $(_mcm_mig_short "${b}"): it changed after the migration."
                fi
            fi
            ;;
        rewrite) _mcm_mig_rewrite_truststores "${a}" "${c}" "${b}" ;;
        paths)   _mcm_mig_rewrite_paths back ;;
        seed)
            rm -f "${a}${MCM_MIG_PARTIAL}"
            if [[ -f "${a}" ]]; then
                local sum_file
                sum_file="$(_mcm_mig_seed_sum_file "${a}")"
                if [[ -f "${sum_file}" && "$(_mcm_mig_checksum "${a}")" == "$(<"${sum_file}")" ]]; then
                    rm -f "${a}" "${sum_file}"
                else
                    echo "[WARN] Keeping $(_mcm_mig_short "${a}"): it changed after the migration."
                fi
            fi
            _mcm_mig_prune "${a:h}"
            ;;
        rmc) ;;
        register) _mcm_mig_undo_register "${a}" "${MCM_MIG_E_STATE[$i]:-}" ;;
        state)
            mcm_write_state "MULTI_CLUSTER_MANAGEMENT=${MCM_MIG_JMETA[prior_mode]:-false}" \
                "MCM_CURRENT_CLUSTER=${MCM_MIG_JMETA[prior_current]:-}"
            ;;
    esac
}

# --- Journal -------------------------------------------------------------------
_mcm_mig_j() { print -r -- "${(pj:\t:)@}" >> "${MCM_MIG_JOURNAL}"; }

_mcm_mig_timestamp() { date +%Y%m%d_%H%M%S; }

_mcm_mig_new_journal_dir() {   # PREFIX
    local stamp dir n=0
    stamp="$(_mcm_mig_timestamp)"
    dir="${MCM_MIG_OLD_CONFIGS}/${1}_${stamp}"
    while [[ -e "${dir}" ]]; do
        (( n += 1 ))
        dir="${MCM_MIG_OLD_CONFIGS}/${1}_${stamp}_${n}"
    done
    MCM_MIG_JOURNAL_DIR="${dir}"
    MCM_MIG_JOURNAL="${dir}/migration_journal.tsv"
}

_mcm_mig_journal_status() {   # FILE; prints the last status
    local line jstatus=""
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" == status$'\t'* ]]; then
            jstatus="${line#status$'\t'}"
        fi
    done < "${1}"
    print -r -- "${jstatus}"
}

# The newest journal that has not been rolled back. Sets REPLY, empty if none.
_mcm_mig_latest_journal() {
    local file
    REPLY=""
    for file in "${MCM_MIG_OLD_CONFIGS}"/pre_*/migration_journal.tsv(N.om); do
        if [[ "$(_mcm_mig_journal_status "${file}")" != rolled_back ]]; then
            REPLY="${file}"
            return 0
        fi
    done
    return 0
}

_mcm_mig_load_journal() {   # FILE
    local file="$1" line
    local -a fields
    MCM_MIG_E_KIND=(); MCM_MIG_E_CLUSTER=(); MCM_MIG_E_A=(); MCM_MIG_E_B=(); MCM_MIG_E_C=()
    MCM_MIG_E_STATE=(); MCM_MIG_JMETA=()
    MCM_MIG_JOURNAL="${file}"
    MCM_MIG_JOURNAL_DIR="${file:h}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        fields=("${(@ps:\t:)line}")
        case "${fields[1]:-}" in
            meta)   MCM_MIG_JMETA[${fields[2]}]="${fields[3]:-}" ;;
            entry)  _mcm_mig_add "${fields[3]}" "${fields[4]:-}" "${fields[5]:-}" "${fields[6]:-}" "${fields[7]:-}" ;;
            start)  MCM_MIG_E_STATE[${fields[2]}]=started ;;
            done)   MCM_MIG_E_STATE[${fields[2]}]=done ;;
            undo)   MCM_MIG_E_STATE[${fields[2]}]=undoing ;;
            undone) MCM_MIG_E_STATE[${fields[2]}]=undone ;;
            status) MCM_MIG_JMETA[status]="${fields[2]:-}" ;;
        esac
    done < "${file}"
    return 0
}

# Written beside the journal and renamed, so a killed run never leaves a partial
# plan for the next run to resume.
_mcm_mig_write_journal_header() {   # KIND
    local kind="$1" i final="${MCM_MIG_JOURNAL}"
    MCM_MIG_JOURNAL="${final}.tmp"
    _mcm_mig_j "# multi-cluster migration journal, used for resume and, until it is complete, --rollback. Do not edit."
    _mcm_mig_j meta kind "${kind}"
    _mcm_mig_j meta created "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _mcm_mig_j meta prior_mode "${MULTI_CLUSTER_MANAGEMENT:-false}"
    _mcm_mig_j meta prior_current "${MCM_CURRENT_CLUSTER:-}"
    _mcm_mig_j meta prior_clusters "${MCM_CLUSTERS:-}"
    _mcm_mig_j meta prior_targets "${MCM_TARGET_CLUSTERS:-}"
    _mcm_mig_j meta openshift_mode "${MCM_MIG_JMETA[openshift_mode]:-}"
    for (( i = 1; i <= ${#MCM_MIG_E_KIND}; i++ )); do
        _mcm_mig_j entry "${i}" "${MCM_MIG_E_KIND[$i]}" "${MCM_MIG_E_CLUSTER[$i]}" "${MCM_MIG_E_A[$i]}" "${MCM_MIG_E_B[$i]}" "${MCM_MIG_E_C[$i]}"
    done
    _mcm_mig_j status applying
    mv -f "${MCM_MIG_JOURNAL}" "${final}"
    MCM_MIG_JOURNAL="${final}"
}

_mcm_mig_apply_all() {
    local i total=${#MCM_MIG_E_KIND} step=0
    for (( i = 1; i <= total; i++ )); do
        step=$i
        if [[ "${MCM_MIG_E_STATE[$i]:-}" == done ]]; then
            print -r -- "[MCM] ${step}/${total} already done: $(_mcm_mig_describe "${i}")"
            continue
        fi
        print -r -- "[MCM] ${step}/${total} $(_mcm_mig_describe "${i}")"
        _mcm_mig_j start "${i}"
        if ! _mcm_mig_apply "${i}"; then
            echo "[ERROR] Step ${step}/${total} failed: $(_mcm_mig_describe "${i}")" >&2
            echo "[ERROR] Finished steps are recorded in $(_mcm_mig_short "${MCM_MIG_JOURNAL}")." >&2
            echo "[ERROR] Re-run the same command to continue, or --rollback to undo it (possible only until the migration completes)." >&2
            exit 1
        fi
        _mcm_mig_j done "${i}"
    done
    _mcm_mig_j status complete
}

# --- Backup -------------------------------------------------------------------
_mcm_mig_backup() {
    local dir src rel step=0 state_file
    local -a items
    items=("${MCM_MIG_CONFIGS}"/*_config(/N))
    for src in "${MCM_MIG_OADP_DIR}/backup_bucket_configs" "${MCM_MIG_OADP_DIR}/restore_target_configs" \
        "${MCM_MIG_CONFLUENT_RENDERED}" "${MCM_MIG_FLINK_RENDERED}"; do
        if [[ -d "${src}" ]]; then
            items+=("${src}")
        fi
    done
    dir="${MCM_MIG_JOURNAL_DIR}"
    for src in "${items[@]}"; do
        (( step += 1 ))
        rel="$(_mcm_mig_short "${src}")"
        print -r -- "[MCM] Backup ${step}/${#items} ${rel}"
        mkdir -p "${dir}/${rel:h}" || return 1
        cp -Rp "${src}" "${dir}/${rel}" || return 1
    done
    state_file="$(mcm_state_file)"
    if [[ -f "${state_file}" ]]; then
        cp -p "${state_file}" "${dir}/" || return 1
    fi
    chmod -R go-rwx "${dir}" || return 1
    print -r -- "[INFO] Backup written to $(_mcm_mig_short "${dir}") (0700)."
}

_mcm_mig_create_journal_dir() {
    mkdir -p "${MCM_MIG_OLD_CONFIGS}" || return 1
    mkdir "${MCM_MIG_JOURNAL_DIR}" || return 1
    chmod 700 "${MCM_MIG_JOURNAL_DIR}" || return 1
}

# --- Common gates ---------------------------------------------------------------
_mcm_mig_check_conflicts() {   # refuses before anything moves
    local i src dst
    local -a conflicts
    for (( i = 1; i <= ${#MCM_MIG_E_KIND}; i++ )); do
        [[ "${MCM_MIG_E_KIND[$i]}" == mv ]] || continue
        [[ "${MCM_MIG_E_STATE[$i]:-}" != done ]] || continue
        dst="${MCM_MIG_E_B[$i]}"
        if [[ -e "${dst}" || -L "${dst}" ]] && ! _mcm_mig_empty_dir "${dst}"; then
            src="${MCM_MIG_E_A[$i]}"
            # A "keep" step killed after its mv leaves SRC empty: that is finished, not a clash.
            if _mcm_mig_has_content "${src}"; then
                conflicts+=("$(_mcm_mig_short "${dst}")")
            fi
        fi
    done
    if (( ${#conflicts} > 0 )); then
        for dst in "${conflicts[@]}"; do
            echo "[ERROR] Already exists, will not overwrite: ${dst}" >&2
        done
        return 1
    fi
    return 0
}

_mcm_mig_confirm() {   # QUESTION
    local reply=""
    if [[ "${MCM_MIG_YES}" == true ]]; then
        return 0
    fi
    print -n -- "${1} [y/N] "
    if ! read -r reply; then
        print
        _mcm_mig_die "No answer available. Re-run with --yes to skip the confirmation."
    fi
    if [[ "${reply}" != [Yy]* ]]; then
        print -r -- "[INFO] Aborted, nothing changed."
        exit 0
    fi
    # The prompt can sit open for a long time; a run may have started meanwhile.
    _mcm_mig_preflight
    if (( ${#MCM_MIG_PREFLIGHT_ERRORS} > 0 )); then
        _mcm_mig_report_preflight
        exit 1
    fi
}

_mcm_mig_print_final_state() {
    mcm_load_state || return 0
    print -r -- "[INFO] MULTI_CLUSTER_MANAGEMENT=${MULTI_CLUSTER_MANAGEMENT}  clusters: ${MCM_CLUSTERS:-none}  current: ${MCM_CURRENT_CLUSTER:-none}"
}

# --- Runs -----------------------------------------------------------------------
# A journal left unfinished by another kind of run must be finished first.
_mcm_mig_check_pending() {   # KIND; sets REPLY to a journal this run should resume
    local want="$1" pending kind jstatus
    _mcm_mig_latest_journal
    pending="${REPLY}"
    REPLY=""
    [[ -n "${pending}" ]] || return 0
    jstatus="$(_mcm_mig_journal_status "${pending}")"
    case "${jstatus}" in
        complete) return 0 ;;
        rolling_back)
            _mcm_mig_die "A rollback of $(_mcm_mig_short "${pending}") was interrupted. Re-run --rollback first."
            ;;
    esac
    kind="$(_mcm_mig_journal_kind "${pending}")"
    _mcm_mig_refuse_removed_kind "${kind}" "${pending}"
    if [[ "${kind}" == "${want}" ]]; then
        REPLY="${pending}"
        return 0
    fi
    _mcm_mig_die "An unfinished ${kind} run exists ($(_mcm_mig_short "${pending}")). Finish it or use --rollback first."
}

_mcm_mig_journal_kind() {   # FILE
    awk -F'\t' '$1=="meta" && $2=="kind" {print $3; exit}' "${1}"
}

# A journal of the removed --reverse can be neither continued nor undone here.
_mcm_mig_refuse_removed_kind() {   # KIND FILE
    [[ "${1:-migrate}" == migrate ]] && return 0
    echo "[ERROR] $(_mcm_mig_short "${2}") was written by --reverse, which was removed: delineation is one-way for each cluster." >&2
    _mcm_mig_die "It can be neither continued nor rolled back. Its folder holds what it recorded; put any file back by hand, then move that folder out of $(_mcm_mig_short "${MCM_MIG_OLD_CONFIGS}")."
}

# Reports everything the real run would refuse on, then exits.
_mcm_mig_finish_dry_run() {   # CONFLICT_CHECK_FUNCTION
    local refused=false
    print -r -- "[INFO] Dry run: nothing changed."
    if (( ${#MCM_MIG_PREFLIGHT_ERRORS} > 0 )); then
        _mcm_mig_report_preflight
        refused=true
    fi
    if ! "${1}"; then
        refused=true
    fi
    if [[ "${refused}" == true ]]; then
        echo "[ERROR] A real run would refuse to start." >&2
        exit 1
    fi
    exit 0
}

_mcm_mig_finish_common() {
    print -r -- "[MCM] Done. Journal: $(_mcm_mig_short "${MCM_MIG_JOURNAL}")"
    print -r -- "[INFO] This migration is final: the clusters it moved stay in configs/clusters/ for good (one-way per cluster), and --rollback no longer applies to it."
    print -r -- "[INFO] The flat configs as they were before it are kept in $(_mcm_mig_short "${MCM_MIG_JOURNAL_DIR}")/ for reference."
}

_mcm_mig_run_forward() {
    local resume="" i
    _mcm_mig_check_pending migrate
    resume="${REPLY}"

    if [[ -n "${resume}" ]]; then
        print -r -- "[INFO] Continuing the migration recorded in $(_mcm_mig_short "${resume}")."
        if [[ -n "${MCM_MIG_NAME}" || -n "${MCM_MIG_MIRROR_TO}" || ${#MCM_MIG_MAP} -gt 0 ]]; then
            echo "[WARN] --name, --map and --mirror-state-to are ignored when continuing: the journal holds the plan."
        fi
        _mcm_mig_load_journal "${resume}"
    else
        _mcm_mig_new_journal_dir pre_multi_cluster
        _mcm_mig_build_forward_plan
    fi

    _mcm_mig_preflight
    _mcm_mig_print_plan
    _mcm_mig_print_stays

    if (( ${#MCM_MIG_E_KIND} == 0 )); then
        print -r -- "[INFO] Nothing to migrate."
        exit 0
    fi
    if [[ "${MCM_MIG_DRY_RUN}" == true ]]; then
        _mcm_mig_finish_dry_run _mcm_mig_check_conflicts
    fi
    if (( ${#MCM_MIG_PREFLIGHT_ERRORS} > 0 )); then
        _mcm_mig_report_preflight
        exit 1
    fi
    _mcm_mig_check_conflicts || exit 1
    _mcm_mig_plan_clusters
    if (( ${#reply} > 0 )); then
        _mcm_mig_confirm "Move these items now? This is permanent for ${(j:, :)reply}: once the migration completes they never go back to the flat layout."
    else
        _mcm_mig_confirm "Move these items now?"
    fi

    if [[ -z "${resume}" ]]; then
        _mcm_mig_create_journal_dir || _mcm_mig_die "Cannot create $(_mcm_mig_short "${MCM_MIG_JOURNAL_DIR}")"
        _mcm_mig_backup || _mcm_mig_die "Backup failed; nothing was moved."
        _mcm_mig_write_journal_header migrate
    fi

    _mcm_mig_apply_all

    # The flat openshift_config folder is empty now; drop it unless something stayed.
    _mcm_mig_rmdir_empty "${MCM_MIG_CONFIGS}/openshift_config" 2>/dev/null || true

    _mcm_mig_print_final_state
    _mcm_mig_finish_common
}

_mcm_mig_rollback_conflicts() {
    local i src dst state
    local -a conflicts lost
    for (( i = ${#MCM_MIG_E_KIND}; i >= 1; i-- )); do
        [[ "${MCM_MIG_E_KIND[$i]}" == mv ]] || continue
        state="${MCM_MIG_E_STATE[$i]:-}"
        [[ "${state}" == done || "${state}" == started || "${state}" == undoing ]] || continue
        src="${MCM_MIG_E_A[$i]}"
        dst="${MCM_MIG_E_B[$i]}"
        # A done move whose result is gone, with nothing back at the source: reporting
        # the undo as handled would turn the mode off with no config left.
        if [[ "${state}" == done && ! -e "${dst}" && ! -L "${dst}" ]] \
            && { { [[ ! -e "${src}" ]] && [[ ! -L "${src}" ]]; } || _mcm_mig_empty_dir "${src}"; }; then
            lost+=("$(_mcm_mig_short "${dst}")")
        fi
        if { [[ -e "${dst}" ]] || [[ -L "${dst}" ]]; } && ! _mcm_mig_empty_dir "${dst}" \
            && { [[ -e "${src}" ]] || [[ -L "${src}" ]]; } && ! _mcm_mig_empty_dir "${src}"; then
            conflicts+=("$(_mcm_mig_short "${src}")")
        fi
    done
    if (( ${#conflicts} > 0 || ${#lost} > 0 )); then
        for src in "${conflicts[@]}"; do
            echo "[ERROR] Will not overwrite ${src}: it holds new content. Move it aside and re-run." >&2
        done
        for dst in "${lost[@]}"; do
            echo "[ERROR] ${dst} is gone and its source is empty, so it cannot be moved back." >&2
        done
        if (( ${#lost} > 0 )); then
            echo "[ERROR] The cluster may have been renamed or removed since. Rename it back with multi_cluster.sh rename, or restore from the backup in $(_mcm_mig_short "${MCM_MIG_OLD_CONFIGS}")." >&2
        fi
        return 1
    fi
    return 0
}

# A completed migration is final: its clusters are delineated for good.
_mcm_mig_refuse_complete_rollback() {
    local dir
    _mcm_mig_plan_clusters
    dir="$(_mcm_mig_short "${MCM_MIG_JOURNAL_DIR}")"
    echo "[ERROR] The migration recorded in ${dir} is complete, and a completed migration is final: delineation is one-way for each cluster${reply:+ (${(j:, :)reply})}." >&2
    echo "[ERROR] --rollback only recovers a migration that did not finish. Nothing was changed." >&2
    echo "[ERROR] The flat configs as they were before it are backed up in ${dir}/ (configs/old_configs/pre_multi_cluster_*); copy a value from there by hand if you need it." >&2
    exit 1
}

_mcm_mig_run_rollback() {
    local i total state cluster step=0 kind jstatus
    _mcm_mig_latest_journal
    [[ -n "${REPLY}" ]] || _mcm_mig_die "No migration journal found under $(_mcm_mig_short "${MCM_MIG_OLD_CONFIGS}")."
    _mcm_mig_load_journal "${REPLY}"
    total=${#MCM_MIG_E_KIND}
    kind="${MCM_MIG_JMETA[kind]:-migrate}"
    jstatus="${MCM_MIG_JMETA[status]:-}"
    _mcm_mig_refuse_removed_kind "${kind}" "${MCM_MIG_JOURNAL}"
    if [[ "${jstatus}" == complete ]]; then
        _mcm_mig_refuse_complete_rollback
    fi

    _mcm_mig_preflight
    print -r -- "[INFO] Rolling back the ${kind} recorded in $(_mcm_mig_short "${MCM_MIG_JOURNAL}") (status ${jstatus:-unknown})."
    for (( i = total; i >= 1; i-- )); do
        state="${MCM_MIG_E_STATE[$i]:-}"
        [[ "${state}" == done || "${state}" == started || "${state}" == undoing ]] || continue
        print -r -- "  undo: $(_mcm_mig_describe "${i}")"
    done

    if [[ "${MCM_MIG_DRY_RUN}" == true ]]; then
        _mcm_mig_finish_dry_run _mcm_mig_rollback_conflicts
    fi
    if (( ${#MCM_MIG_PREFLIGHT_ERRORS} > 0 )); then
        _mcm_mig_report_preflight
        exit 1
    fi
    _mcm_mig_rollback_conflicts || exit 1
    _mcm_mig_confirm "Undo these steps?"

    mcm_load_state || _mcm_mig_die "Fix $(mcm_state_file), then re-run."
    _mcm_mig_j status rolling_back

    local -a touched_clusters
    for (( i = total; i >= 1; i-- )); do
        (( step += 1 ))
        state="${MCM_MIG_E_STATE[$i]:-}"
        if [[ "${state}" != done && "${state}" != started && "${state}" != undoing ]]; then
            print -r -- "[MCM] ${step}/${total} skipped (not applied): $(_mcm_mig_describe "${i}")"
            continue
        fi
        print -r -- "[MCM] ${step}/${total} undo: $(_mcm_mig_describe "${i}")"
        _mcm_mig_j undo "${i}"
        if ! _mcm_mig_undo "${i}"; then
            echo "[ERROR] Undo of step ${i} failed: $(_mcm_mig_describe "${i}")" >&2
            echo "[ERROR] Fix it, then re-run --rollback to continue." >&2
            exit 1
        fi
        _mcm_mig_j undone "${i}"
        cluster="${MCM_MIG_E_CLUSTER[$i]}"
        if [[ -n "${cluster}" ]] && (( ! ${touched_clusters[(Ie)${cluster}]} )); then
            touched_clusters+=("${cluster}")
        fi
    done

    # The containers these clusters' work folders were mounted into are stale now.
    for cluster in "${touched_clusters[@]}"; do
        _mcm_mig_remove_container "${MCM_MIG_FLAT_CONTAINER}-${cluster}"
        _mcm_mig_remove_container "${MCM_MIG_SWHCC_CONTAINER}-${cluster}"
    done

    _mcm_mig_j status rolled_back
    print -r -- "[MCM] Rollback finished: ${total}/${total} steps handled."
    _mcm_mig_print_final_state
}

# --- Main -----------------------------------------------------------------------
if [[ "${MCM_MIG_PREFLIGHT_ONLY}" == true ]]; then
    _mcm_mig_preflight
    if (( ${#MCM_MIG_PREFLIGHT_ERRORS} > 0 )); then
        _mcm_mig_report_preflight
        exit 1
    fi
    exit 0
fi

_mcm_mig_read_state

if [[ "${MCM_MIG_ROLLBACK}" == true ]]; then
    _mcm_mig_run_rollback
else
    _mcm_mig_run_forward
fi
