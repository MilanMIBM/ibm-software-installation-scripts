#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config

# ==============================================================================
# 1.2 Estimate the size (internet side, read-only)
# ------------------------------------------------------------------------------
#   images     layer sizes from the manifests of every architecture mirrored,
#              shared layers counted once (= registry storage, roughly)
#   operators  --with-operators: oc-mirror --dry-run of the shared catalog run,
#              then the same manifest sum over its mapping (slow: many images)
#   cpd-cli    not estimated - IBM's hardware requirements topic lists sizes;
#              --with-cpd sums the images in cpd-cli's list_images.csv instead
#              (needs 1.1 / list-images first; thousands of manifests)
# Compared with free space in the workspace, the bundle dir and the local
# registry storage, and with the ICR quota when `ibmcloud cr quota` answers.
# Flags any single image over 40 GB (IBM's private registry requirement).
#
#   ./1.2_estimate_size.sh [--with-operators] [--with-cpd]
# ==============================================================================

WITH_OPS=false WITH_CPD=false
for _a in "$@"; do
    case "${_a}" in
        --with-operators) WITH_OPS=true ;;
        --with-cpd) WITH_CPD=true ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done
WS="${MIRROR_WORKSPACE}"
[[ -f "${WS}/inventory/inventory.json" ]] || preg_die "No inventory - run 1.0_build_inventory.sh first."
RUN="$(preg_private_tmpdir)"
trap 'rm -rf "${RUN}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
preg_write_authfile "${RUN}/auth.json" none --sources

human() { preg_python -c 'import sys; b=float(sys.argv[1]); u=["B","KB","MB","GB","TB"]; i=0
while b >= 1000 and i < 4: b/=1000; i+=1
print(f"{b:.1f} {u[i]}")' "$1"; }

total=0
estimate() {   # <label> <refs file>
    local out bytes
    [[ -s "$2" ]] || return 0
    preg_info "Sizing ${1}: $(grep -c . "$2") image(s)"
    out="$(preg_engine inspect --refs-file "$2" --authfile "${RUN}/auth.json" --sizes --jobs 12 || true)"
    print -r -- "${out}" | grep -E '^(AUTH|MISSING|TLS|NETWORK|OVER40GB)' | sed 's/^/    /' || true
    bytes="$(print -r -- "${out}" | awk '/^SIZE /{print $2}')"
    bytes="${bytes:-0}"
    printf '  %-40s %s\n' "${1}" "$(human "${bytes}")"
    total=$(( total + bytes ))
}

print -r -- "Estimated registry storage (all architectures mirrored, layers deduplicated per group)"
for t in "${WS}"/*/targets.tsv(N); do
    cut -f1 "${t}" | sort -u > "${RUN}/refs.${t:h:t}"
    estimate "<root>/${t:h:t} images" "${RUN}/refs.${t:h:t}"
done

ISC="${WS}/$(preg_install_path shared)/imageset-config.yaml"
if ${WITH_OPS} && [[ -f "${ISC}" ]]; then
    DR="${WS}/$(preg_install_path shared)/oc-mirror-dryrun"
    mkdir -p "${DR}"
    cp "${RUN}/auth.json" "${DR}/.auth.json"
    preg_info "oc-mirror --dry-run for the shared catalogs (pulls the catalog indexes)"
    preg_oc_mirror "${DR}" --v2 -c "${ISC}" "file://${DR}/archive" --dry-run --authfile "${DR}/.auth.json" >/dev/null
    rm -f "${DR}/.auth.json"
    map="${DR}/archive/working-dir/dry-run/mapping.txt"
    [[ -f "${map}" ]] || map="$(find "${DR}" -name mapping.txt -path '*dry-run*' | head -1)"
    if [[ -n "${map}" && -f "${map}" ]]; then
        sed -E 's|^docker://||; s|=.*$||' "${map}" | sort -u > "${RUN}/refs.ops"
        estimate "<root>/shared operators (oc-mirror)" "${RUN}/refs.ops"
    else
        preg_warn "oc-mirror wrote no dry-run mapping - operators not estimated."
    fi
elif [[ -f "${ISC}" ]]; then
    printf '  %-40s %s\n' "<root>/shared operators" "not estimated (--with-operators); every architecture is mirrored"
fi

if [[ -s "${WS}/$(preg_install_path cpd)/native.jsonl" ]]; then
    REL="$(preg_python -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline()).get("release",""))' "${WS}/$(preg_install_path cpd)/native.jsonl")"
    csv="${HOME}/cpd-cli/work/offline/${REL}/list_images.csv"
    if ${WITH_CPD} && [[ -f "${csv}" ]]; then
        # registry,image_name,tag,digest,...  -> registry/image_name@digest
        awk -F, 'NR > 1 && $4 ~ /^sha256:/ { print $1 "/" $2 "@" $4 }' "${csv}" | sort -u > "${RUN}/refs.cpd"
        estimate "<root>/cpd (cpd-cli list_images.csv)" "${RUN}/refs.cpd"
    else
        printf '  %-40s %s\n' "<root>/cpd (cpd-cli)" "not estimated - see IBM's hardware requirements (or --with-cpd after 1.1)"
    fi
fi
printf '  %-40s %s\n' "TOTAL (estimated above)" "$(human "${total}")"

print -r -- ""
print -r -- "Free space"
free_of() { df -k "$1" 2>/dev/null | awk 'NR==2 { print $4 * 1024 }'; }
for d in "${WS}" "$(preg_bundle_dir)" "${LOCAL_REGISTRY_DIR:-${WS}/local-registry/data}"; do
    probe="${d}"
    while [[ ! -d "${probe}" && "${probe}" != / ]]; do probe="${probe:h}"; done
    f="$(free_of "${probe}")"
    note=""
    (( ${f:-0} < total )) && note="   <-- less than the estimate"
    printf '  %-60s %s free%s\n' "${d#${_CP4D_REPO_ROOT}/}" "$(human "${f:-0}")" "${note}"
done

if [[ "$(preg_pull_root 2>/dev/null || true)" == *icr.io* ]]; then
    print -r -- ""
    if command -v ibmcloud >/dev/null 2>&1 && q="$(ibmcloud cr quota 2>/dev/null)"; then
        print -r -- "ICR quota"; print -r -- "${q}" | sed 's/^/  /'
    else
        preg_info "ICR quota unknown (ibmcloud not logged in, or the key has no management-API access) - check it in the IBM Cloud console."
    fi
fi
