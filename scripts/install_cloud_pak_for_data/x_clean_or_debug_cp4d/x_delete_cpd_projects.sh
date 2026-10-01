#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# --- Options
PREVIEW=false
DELETE_TIMEOUT=5  # seconds to wait for normal termination before force-removing finalizers

for arg in "$@"; do
    case "${arg}" in
        --preview=true)       PREVIEW=true ;;
        --preview=false)      PREVIEW=false ;;
        --timeout=*)          DELETE_TIMEOUT="${arg#--timeout=}" ;;
    esac
done

# --- Colours & formatting
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
preview() { echo -e "${DIM}[PREVIEW]${RESET} $*"; }

# Spinning wait bar while a condition holds.
# Usage: spin_until_gone <namespace> <deadline_var>
spin_until_gone() {
    local ns="$1"
    local deadline="$2"
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local nframes=10
    local i=0
    local f
    while oc get project "${ns}" &>/dev/null && (( SECONDS < deadline )); do
        f="${frames:$(( i % nframes )):1}"
        printf "\r  ${CYAN}%s${RESET} Waiting for '${BOLD}%s${RESET}' to terminate..." "${f}" "${ns}"
        (( i++ )) || true
        sleep 0.3
    done
    printf "\r\033[2K"
}

# Progress bar for the overall project loop.
# Usage: progress_bar <current> <total> <label>
progress_bar() {
    local cur="$1" total="$2" label="$3"
    local width=30
    local filled=$(( cur * width / total ))
    local empty=$(( width - filled ))
    local bar=""
    local j
    for (( j=0; j<filled; j++ )); do bar+="█"; done
    for (( j=0; j<empty;  j++ )); do bar+="░"; done
    printf "\r  [${GREEN}%s${DIM}%s${RESET}] %d/%d  %s\033[K" \
        "${bar:0:$filled}" "${bar:$filled}" "${cur}" "${total}" "${label}"
}

# ---
eval "${OC_LOGIN}"

PROJECTS=(
    "${PROJECT_LICENSE_SERVICE:-}"
    "${PROJECT_SCHEDULING_SERVICE:-}"
    "${PROJECT_IBM_EVENTS:-}"
    "${PROJECT_PRIVILEGED_MONITORING_SERVICE:-}"
    "${PROJECT_CPD_INST_OPERATORS:-}"
    "${PROJECT_CPD_INST_OPERANDS:-}"
)

# Filter to non-empty names
RESOLVED=()
for ns in "${PROJECTS[@]}"; do
    [[ -n "${ns}" ]] && RESOLVED+=("${ns}")
done

# --- Summary header
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  CPD Project Deletion${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

if [[ "${PREVIEW}" == "true" ]]; then
    echo -e "  ${YELLOW}Mode   :${RESET} Preview (no changes will be made)"
else
    echo -e "  ${RED}Mode   :${RESET} ${BOLD}Live - projects will be permanently deleted${RESET}"
fi
echo -e "  ${CYAN}Timeout:${RESET} ${DELETE_TIMEOUT}s before force-removing finalizers"
echo ""
echo -e "  ${BOLD}Projects targeted (${#RESOLVED[@]})${RESET}"
echo ""

EXISTS=()
MISSING=()
for ns in "${RESOLVED[@]}"; do
    if oc get project "${ns}" &>/dev/null; then
        EXISTS+=("${ns}")
        echo -e "    ${GREEN}✔${RESET}  ${ns}"
    else
        MISSING+=("${ns}")
        echo -e "    ${DIM}✘  ${ns}  (not found)${RESET}"
    fi
done

echo ""
echo -e "  ${BOLD}${#EXISTS[@]} to delete, ${#MISSING[@]} not found${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

if [[ "${PREVIEW}" == "true" ]]; then
    for ns in "${EXISTS[@]}"; do
        preview "Would delete: ${BOLD}${ns}${RESET}"
    done
    echo ""
    info "Preview complete - no projects were deleted."
    exit 0
fi

if [[ ${#EXISTS[@]} -eq 0 ]]; then
    info "Nothing to delete."
    exit 0
fi

# Kill the namespace's own "kubernetes" finalizer via the /finalize subresource.
# A plain `oc patch namespace ... spec.finalizers` is silently ignored by the API
# server for this finalizer - it is only honoured through the finalize subresource.
kill_namespace_finalizer() {
    local ns="$1"
    local token server
    token=$(oc whoami -t 2>/dev/null || true)
    server=$(oc whoami --show-server 2>/dev/null || true)

    # Grab the live namespace object, strip spec.finalizers, PUT to /finalize.
    local body
    body=$(oc get namespace "${ns}" -o json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); d.get('spec',{}).pop('finalizers',None); print(json.dumps(d))" 2>/dev/null || true)
    [[ -z "${body}" ]] && return 0

    if [[ -n "${token}" && -n "${server}" ]]; then
        curl -sk -X PUT \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            --data "${body}" \
            "${server}/api/v1/namespaces/${ns}/finalize" &>/dev/null || true
    else
        # Fallback: oc replace against the finalize subresource via raw API.
        echo "${body}" | oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - &>/dev/null || true
    fi
}

force_delete_project() {
    local ns="$1"
    local cur="$2"
    local total="$3"

    echo -e "\n  ${BOLD}[${cur}/${total}]${RESET} Deleting ${BOLD}${ns}${RESET}"

    # Drop the openshift.io/requester annotation so the project can't be
    # re-reconciled/blocked on the basis of its original requester.
    oc annotate namespace "${ns}" openshift.io/requester- --overwrite &>/dev/null || true

    oc delete project "${ns}" --wait=false --ignore-not-found=true

    local deadline=$(( SECONDS + DELETE_TIMEOUT ))
    spin_until_gone "${ns}" "${deadline}"

    if oc get namespace "${ns}" &>/dev/null; then
        warn "Project '${BOLD}${ns}${RESET}' stuck - tracking down finalizers."

        # 1. Find and clear per-resource finalizers, reporting what's holding the ns.
        local resources
        resources=$(oc api-resources --verbs=list --namespaced -o name 2>/dev/null || true)
        local res_count
        res_count=$(echo "${resources}" | wc -w | tr -d ' ')
        local res_idx=0

        for resource in ${resources}; do
            (( res_idx++ )) || true
            progress_bar "${res_idx}" "${res_count}" "Scanning ${resource}"

            # Names of objects of this type that still carry finalizers.
            local stuck
            stuck=$(oc get "${resource}" -n "${ns}" -o json 2>/dev/null \
                | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for it in d.get('items',[]):
    f=it.get('metadata',{}).get('finalizers',[])
    if f: print(it['metadata']['name'], ','.join(f))" 2>/dev/null || true)

            [[ -z "${stuck}" ]] && continue

            printf "\r\033[2K"
            while IFS=' ' read -r name fins; do
                [[ -z "${name}" ]] && continue
                warn "  ${resource}/${name}  ${DIM}[${fins}]${RESET}"
                oc patch "${resource}" "${name}" -n "${ns}" \
                    --type=merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null \
                    && success "    cleared finalizers on ${resource}/${name}" \
                    || warn "    failed to clear ${resource}/${name}"
            done <<< "${stuck}"
        done
        printf "\r\033[2K"

        # 2. Kill the namespace's own finalizers (metadata + the kubernetes spec finalizer).
        oc patch namespace "${ns}" --type=merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null || true
        kill_namespace_finalizer "${ns}"

        # 3. Give the API server a moment, then confirm.
        local fdeadline=$(( SECONDS + DELETE_TIMEOUT ))
        spin_until_gone "${ns}" "${fdeadline}"
        if oc get namespace "${ns}" &>/dev/null; then
            warn "Project '${BOLD}${ns}${RESET}' still present after clearing finalizers - inspect manually."
            return 0
        fi
    fi

    success "Project '${BOLD}${ns}${RESET}' deleted."
}

total=${#EXISTS[@]}
idx=0
for ns in "${EXISTS[@]}"; do
    (( idx++ )) || true
    force_delete_project "${ns}" "${idx}" "${total}"
done

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
success "All ${total} CPD project(s) deleted."
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
