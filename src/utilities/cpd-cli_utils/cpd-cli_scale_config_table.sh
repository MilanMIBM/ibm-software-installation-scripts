#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Builds the Software Hub scale-config table for VERSION / PATCH_ID in cpd_vars.sh:
# for each scale-capable component, the CR value `cpd-cli manage apply-scale-config`
# sets at level_1..level_5, whether install-options.yml can set it at install time
# (non_olm: <key>: <value>) and what a re-run of install-components does to it, and
# the CPU / memory the operator requests at each size (replicas x requests summed
# over the operator's size files; limits are in the saved file).
#
# Reads the olm-utils image (a throwaway container, never `cpd-cli manage`), the
# patch file from the CASE download, the IBM/charts Helm charts and the operator
# images (pulled once with skopeo, cached by digest). Nothing is read from a cluster.
#
#   cpd-cli_scale_config_table.sh [options]
#     (default)                 components in CPD_COMPONENTS + their dependencies
#                               + cpfs / zen (what install-components installs)
#     --all                     every scale-capable component
#     -c, --components <list>   only these comma-separated components (with dependencies)
#     -p, --print-only          show the table, don't save it
#     -o, --output-dir <dir>    where to save (default configs/cp4d_config)
#     -j, --parallel <n>        operator images pulled at a time (default 4)
#     --refresh                 download the metadata, index and charts again
#                               (operator results are kept: a digest never changes)
#     -h, --help
#
#   Saves configs/cp4d_config/scale_config_table_<VERSION>[.<PATCH_ID>][_all|_custom].md
#   (requests, limits, re-run behaviour, size files used) and a .json beside it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/cpd_scale_config_helpers.sh"

usage() { sed -n '/^# Builds the Software Hub scale-config table/,/^#   (requests, limits/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

SCOPE="cpd_vars"
COMPONENTS=""
PRINT_ONLY=false
OUT_DIR="${CONFIGS_ROOT:-${_CP4D_REPO_ROOT}/configs}/cp4d_config"
REFRESH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)              SCOPE="all"; shift ;;
        -c|--components)    SCOPE="list"; COMPONENTS="${2:?$1 needs a comma-separated list}"; shift 2 ;;
        -p|--print-only)    PRINT_ONLY=true; shift ;;
        -o|--output-dir)    OUT_DIR="${2:?$1 needs a directory}"; shift 2 ;;
        -j|--parallel)      SCC_PARALLEL="${2:?$1 needs a number}"; shift 2 ;;
        --refresh)          REFRESH=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done
[[ "${SCC_PARALLEL}" == <1-> ]] || die "--parallel needs a number >= 1."
[[ -n "${VERSION:-}" ]] || die "VERSION is not set. Set it in configs/cp4d_config/cpd_vars.sh."
[[ -n "${OLM_UTILS_IMAGE:-}" ]] || die "OLM_UTILS_IMAGE is not set. Set it in configs/cp4d_config/cpd_vars.sh."
for t in podman skopeo curl tar; do
    command -v "${t}" >/dev/null || die "${t} is not installed."
done
if [[ "${SCOPE}" == cpd_vars && -z "${CPD_COMPONENTS:-}" ]]; then
    die "CPD_COMPONENTS is empty in cpd_vars.sh; use --all or --components."
fi

scc_cache_dir; CACHE="${REPLY}"
WORK="$(mktemp -d "${${TMPDIR:-/tmp}%/}/scc.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "[INFO] Software Hub ${VERSION}${PATCH_ID:+ patch ${PATCH_ID}}, olm-utils ${OLM_UTILS_IMAGE##*/}"
if ${REFRESH}; then
    echo "[INFO] --refresh: dropping cached metadata, index and charts for ${CACHE:t}"
    rm -rf "${CACHE}/config-vars" "${CACHE}/index.yaml" "${CACHE}/charts"
fi

# 1. olm-utils metadata, patch versions, chart index
scc_config_vars "${CACHE}"
scc_patch_file; PATCH_FILE="${REPLY}"
scc_chart_index "${CACHE}" $(${REFRESH} && print force)

# 2. which components
typeset -a plan_args=(--config-vars "${CACHE}/config-vars" --index "${CACHE}/index.yaml")
[[ -n "${PATCH_FILE}" ]] && plan_args+=(--patch "${PATCH_FILE}")
case "${SCOPE}" in
    all)      plan_args+=(--all) ;;
    list)     plan_args+=(--components "${COMPONENTS}") ;;
    cpd_vars) plan_args+=(--cpd-components "${CPD_COMPONENTS}") ;;
esac
scc_py plan "${plan_args[@]}" > "${WORK}/plan.json" || die "Could not resolve the components."

# 3. charts -> install-options keys and operator images
scc_fetch_charts "${CACHE}" "${WORK}/plan.json"
scc_py scan --plan "${WORK}/plan.json" --charts-dir "${CACHE}/charts" > "${WORK}/scan.json" || die "Could not read the charts."

# 4. operator size files
scc_operator_sizing "${WORK}/scan.json"

# 5. table
TITLE="Software Hub scale-config table"
if ${PRINT_ONLY}; then
    scc_py render --plan "${WORK}/scan.json" --sizing-dir "${SCC_CACHE_ROOT}/operators" --print --title "${TITLE}"
    exit 0
fi
mkdir -p "${OUT_DIR}"
BASE="${OUT_DIR}/scale_config_table_${VERSION}${PATCH_ID:+.${PATCH_ID}}"
case "${SCOPE}" in
    all)  BASE+="_all" ;;
    list) BASE+="_custom" ;;
esac
scc_py render --plan "${WORK}/scan.json" --sizing-dir "${SCC_CACHE_ROOT}/operators" --print --title "${TITLE}" \
    --md "${BASE}.md" --json "${BASE}.json"
echo "[INFO] Saved ${BASE#${_CP4D_REPO_ROOT}/}.md (requests, limits, re-run behaviour, size files) and .json"
