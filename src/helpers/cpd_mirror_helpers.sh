#!/bin/zsh
# =============================================================================
# cpd_mirror_helpers.sh - cpd-cli mirroring pieces shared by the cpd hooks of
# scripts/private_registry_mirroring (2_download_and_mirror, 4_update_cpd_patch)
# -----------------------------------------------------------------------------
#     source "${_CP4D_REPO_ROOT}/src/helpers/cpd_mirror_helpers.sh"
#
#   cpdm_work                       the cpd-cli work dir
#   cpdm_apply_prunes <release>     IBM's optional EDB / WSL image prunes
#   cpdm_mapping_only <release> <mapping file name> <mirror-images args...>
#                                   mirror-images that only writes each CASE's
#                                   mapping file; CPDM_MAPS = the files written
#                                   (relative to the work dir), CPDM_MAP_LINES =
#                                   file -> line count
#
# Must be SOURCED after private_registry_helpers.sh. Guarded via
# _CPDM_HELPERS_LOADED.
# =============================================================================

[[ -n "${_CPDM_HELPERS_LOADED:-}" ]] && return 0
_CPDM_HELPERS_LOADED=1

cpdm_work() { print -r -- "${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}"; }

# IBM's optional prunes (EDB Postgres Standard; Watson Studio GPU / NLP) - a
# portable in-place edit instead of GNU sed -i.
cpdm_prune_csv() {   # <case dir glob> <pattern>
    local f
    for f in ${~1}(N); do
        PAT="$2" preg_python -I - "${f}" <<'PY'
import os, sys
p, pat = sys.argv[1], os.environ["PAT"]
lines = open(p).read().splitlines(True)
kept = [l for l in lines if pat not in l]
open(p, "w").writelines(kept)
print(f"[INFO] pruned {len(lines) - len(kept)} line(s) matching '{pat}' from {os.path.basename(p)}")
PY
    done
}

cpdm_apply_prunes() {   # <release>
    local cases="$(cpdm_work)/offline/$1/.ibm-pak/data/cases"
    preg_is_true "${MIRROR_CPD_EDB_STANDARD_ONLY:-false}" && cpdm_prune_csv "${cases}/ibm-cpd-edb/*/ibm-cpd-edb-*-images.csv" "edb-postgres-advanced"
    preg_is_true "${MIRROR_CPD_WSL_EXCLUDE_GPU:-false}" && cpdm_prune_csv "${cases}/ibm-wsl-runtimes/*/ibm-wsl-runtimes-*-images.csv" "/gpu/"
    preg_is_true "${MIRROR_CPD_WSL_EXCLUDE_NLP:-false}" && cpdm_prune_csv "${cases}/ibm-wsl-runtimes/*/ibm-wsl-runtimes-*-images.csv" "/nlp/"
    return 0
}

# mirror-images with the playbook's skip_do_mirror + do_mirror_manifests vars
# (through the documented --param-file): it prunes (--arch) and writes each
# CASE's mapping file (.../mirror/<case>/<version>/<name>), pushes nothing.
typeset -ga CPDM_MAPS=()
typeset -gA CPDM_MAP_LINES=()
cpdm_mapping_only() {   # <release> <mapping file name> <mirror-images args...>
    local rel="$1" map_name="$2" work params marker f
    shift 2
    work="$(cpdm_work)"
    params="${work}/mirror_manifests_only.yml"
    print -r -- $'skip_do_mirror: true\ndo_mirror_manifests: true' > "${params}"
    marker="$(preg_private_tmpdir)/marker"; : > "${marker}"
    cpd-cli manage mirror-images "$@" --param-file="/tmp/work/${params:t}"
    CPDM_MAPS=() CPDM_MAP_LINES=()
    for f in "${work}/offline/${rel}/.ibm-pak/data/mirror"/*/*/"${map_name}"(N); do
        [[ "${f}" -nt "${marker}" ]] || continue
        CPDM_MAPS+=("${f#${work}/}")
        CPDM_MAP_LINES[${f#${work}/}]="$(grep -c . "${f}" || true)"
    done
    rm -rf -- "${marker:h}"
    (( ${#CPDM_MAPS} )) || { preg_error "cpd: mirror-images wrote no ${map_name}"; return 1; }
    return 0
}
