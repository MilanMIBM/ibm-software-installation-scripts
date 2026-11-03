#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# 5_redirect_informix_preprod_images.sh - pull Informix instance images from a
# registry this cluster can use
# -----------------------------------------------------------------------------
# The Informix operator (10.2.2, icr.io/cpopen/ibm-informix-operator@sha256:5e8ec6e7...)
# writes preprod.icr.io/cp/cpd/informix-*@sha256 refs into each instance's
# <instance>-digests-config, so every instance pod fails with ImagePullBackOff
# (preprod.icr.io is IBM's internal registry). IBM's CASE publishes the very same
# digests under cp.icr.io/cp/cpd/, which is also what cpd-cli mirror-images copies
# to a private registry (<PRIVATE_REGISTRY_LOCATION>/cp/cpd/...).
#
# This applies an ImageDigestMirrorSet "cpd-informix-preprod-redirect" that sends
# those pulls to the registry cpd_vars.sh (+ registry_overrides.sh) selects:
#   CPD_IMAGE_SOURCE=private|local  <PRIVATE_REGISTRY_LOCATION>/cp/cpd, then cp.icr.io/cp/cpd
#   entitled (default)              cp.icr.io/cp/cpd
# Mirrors are tried in order, so cp.icr.io stays the fallback when the private
# registry lacks an image. Pulls are by digest only, so the redirect can't change
# what runs. IBM's cloud-pak-for-data-mirror objects (apply-icsp) are not touched.
# Once IBM ships a fixed operator the redirect simply goes unused.
#
# Usage:
#   ./5_redirect_informix_preprod_images.sh                    # apply when needed, restart stuck pods
#   ./5_redirect_informix_preprod_images.sh --dry-run          # print the IDMS, change nothing
#   ./5_redirect_informix_preprod_images.sh --registry=<pull prefix>   # e.g. <pull root>/cpd (mirror track)
#   ./5_redirect_informix_preprod_images.sh --no-restart       # leave pods in back-off alone
#   ./5_redirect_informix_preprod_images.sh --remove           # delete the redirect
# =============================================================================

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

IDMS_NAME="cpd-informix-preprod-redirect"
CANONICAL_HOST="cp.icr.io"
DEFAULT_SOURCES=("preprod.icr.io/cp/cpd")   # what the 10.2.2 operator writes, before any instance exists

DRY=false RESTART=true REMOVE=false REGISTRY_OPT=""
for _a in "$@"; do
    case "${_a}" in
        --dry-run) DRY=true ;;
        --no-restart) RESTART=false ;;
        --remove) REMOVE=true ;;
        --registry=*) REGISTRY_OPT="${_a#--registry=}" ;;
        *) h_die "unknown option ${_a} (see the header of $(basename $0))" ;;
    esac
done

: "${PROJECT_CPD_INST_OPERANDS:?PROJECT_CPD_INST_OPERANDS is not set - generate configs/cp4d_config/cpd_vars.sh}"
NS="${PROJECT_CPD_INST_OPERANDS}"
# Plain oc login only: CPDM_OC_LOGIN is cpd-cli manage, which recreates the olm-utils container.
eval "${OC_LOGIN:?OC_LOGIN is not set - generate configs/cp4d_config/cpd_vars.sh}"

if ${REMOVE}; then
    if ${DRY}; then
        h_info "[dry-run] would delete imagedigestmirrorset/${IDMS_NAME}"
    else
        oc delete imagedigestmirrorset "${IDMS_NAME}" --ignore-not-found
        h_wait_mcp_updated 1800
    fi
    exit 0
fi

# --- 1. Sources: the default plus every non-cp.icr.io prefix the instances' digests-config hold ---
h_info "[1/4] Reading the Informix image refs in ${NS}"
detected="$(oc -n "${NS}" get configmaps -o json | python3 -I -c '
import json, sys
canon = sys.argv[1]
out = set()
for cm in json.load(sys.stdin)["items"]:
    if not cm["metadata"]["name"].endswith("-digests-config"):
        continue
    for ref in (cm.get("data") or {}).values():
        repo = ref.split("@", 1)[0]
        host, _, path = repo.partition("/")
        if "@sha256:" in ref and "." in host and host != canon and path.startswith("cp/"):
            out.add(host + "/" + path.rsplit("/", 1)[0])
print("\n".join(sorted(out)))' "${CANONICAL_HOST}")"
typeset -U sources
sources=("${DEFAULT_SOURCES[@]}" ${(f)detected})
h_info "      source prefixes: ${sources[*]}${detected:+ (detected in digests-config)}"

# --- 2. Mirrors: the registry cpd_vars.sh selects, then cp.icr.io as the fallback ---
IMAGE_SOURCE="${CPD_IMAGE_SOURCE:-entitled}"
PRIVATE_PREFIX="${REGISTRY_OPT:-${PRIVATE_REGISTRY_LOCATION:-}}"
PRIVATE_PREFIX="${PRIVATE_PREFIX%/}"
if [[ -n "${REGISTRY_OPT}" ]]; then
    h_info "[2/4] Registry from --registry: ${PRIVATE_PREFIX}, fallback ${CANONICAL_HOST}"
elif [[ "${IMAGE_SOURCE}" == (private|local) && -n "${PRIVATE_PREFIX}" ]]; then
    h_info "[2/4] CPD_IMAGE_SOURCE=${IMAGE_SOURCE}: ${PRIVATE_PREFIX}, fallback ${CANONICAL_HOST}"
    [[ "${IMAGE_SOURCE}" == local ]] && h_info "      (air-gapped: the ${CANONICAL_HOST} fallback only helps if the cluster can reach it)"
elif [[ "${IMAGE_SOURCE}" == (private|local) ]]; then
    h_warn "CPD_IMAGE_SOURCE=${IMAGE_SOURCE} but PRIVATE_REGISTRY_LOCATION is empty - falling back to ${CANONICAL_HOST} only"
    PRIVATE_PREFIX=""
else
    h_info "[2/4] Entitled registry: ${CANONICAL_HOST}"
    PRIVATE_PREFIX=""
fi

mirror_hosts=("${CANONICAL_HOST}")
[[ -n "${PRIVATE_PREFIX}" ]] && mirror_hosts=("${PRIVATE_PREFIX%%/*}" "${mirror_hosts[@]}")
# CRI-O pulls through mirrors with the global pull secret: say so when a mirror has no entry there
have_auth="$(oc -n openshift-config get secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
    | python3 -I -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("auths", {})))' 2>/dev/null || true)"
for h in "${mirror_hosts[@]}"; do
    print -r -- "${have_auth}" | grep -qxF "${h}" \
        || h_warn "the global pull secret has no entry for ${h} - pulls from it will fail (see 1_global_pull_secret_and_certmanager/)"
done

file="$(mktemp "${TMPDIR:-/tmp}/informix-idms.XXXXXX")"
trap 'rm -f "${file}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
{
    print -r -- "apiVersion: config.openshift.io/v1"
    print -r -- "kind: ImageDigestMirrorSet"
    print -r -- "metadata:"
    print -r -- "  name: ${IDMS_NAME}"
    print -r -- "  labels:"
    print -r -- "    app.kubernetes.io/managed-by: ibm-software-installation-scripts"
    print -r -- "    icpdsupport/addOnId: informix"
    print -r -- "spec:"
    print -r -- "  imageDigestMirrors:"
    for s in "${sources[@]}"; do
        repo_path="${s#*/}"
        print -r -- "  - source: ${s}"
        print -r -- "    mirrorSourcePolicy: NeverContactSource"
        print -r -- "    mirrors:"
        [[ -n "${PRIVATE_PREFIX}" ]] && print -r -- "    - ${PRIVATE_PREFIX}/${repo_path}"
        print -r -- "    - ${CANONICAL_HOST}/${repo_path}"
    done
} > "${file}"

# --- 3. Apply (only when it differs from what the cluster has) ---
if ${DRY}; then
    h_info "[3/4] [dry-run] would apply:"
    sed 's/^/    /' "${file}"
    exit 0
fi
rc=0; oc diff -f "${file}" >/dev/null 2>&1 || rc=$?
if (( rc == 0 )); then
    h_info "[3/4] imagedigestmirrorset/${IDMS_NAME} is already in place"
elif (( rc == 1 )); then
    h_info "[3/4] Applying imagedigestmirrorset/${IDMS_NAME} (the nodes pick it up through a MachineConfigPool rollout)"
    oc apply -f "${file}"
    h_wait_mcp_updated 1800
else
    h_die "oc diff failed for ${file} (exit ${rc})"
fi

# --- 4. Pods stuck in image pull back-off: delete them so they pull at once (their owners recreate them) ---
stuck() {
    oc -n "${NS}" get pods -l icpdsupport/addOnId=informix -o json | python3 -I -c '
import json, sys
bad = ("ErrImagePull", "ImagePullBackOff")
for p in json.load(sys.stdin)["items"]:
    st = p.get("status") or {}
    cs = (st.get("initContainerStatuses") or []) + (st.get("containerStatuses") or [])
    if any(((c.get("state") or {}).get("waiting") or {}).get("reason") in bad for c in cs):
        print(p["metadata"]["name"])'
}
pods=(${(f)"$(stuck)"})
if (( ${#pods} == 0 )); then
    h_info "[4/4] No Informix pods in image pull back-off"
    exit 0
fi
if ! ${RESTART}; then
    h_info "[4/4] ${#pods} Informix pod(s) in image pull back-off left alone (--no-restart); they retry on their own"
    exit 0
fi
h_info "[4/4] Restarting ${#pods} Informix pod(s) in image pull back-off"
oc -n "${NS}" delete pod "${pods[@]}" --wait=false
total=${#pods} start=${SECONDS}
while true; do
    sleep 15
    left=(${(f)"$(stuck)"})
    h_info "      $(( total - ${#left} ))/${total} pulled ($(( (total - ${#left}) * 100 / total ))%), $(( SECONDS - start ))s"
    (( ${#left} == 0 )) && break
    if (( SECONDS - start >= 300 )); then
        h_warn "still in image pull back-off after 300s: ${left[*]}"
        h_warn "check: oc -n ${NS} get events --field-selector reason=Failed | grep -i pull"
        exit 1
    fi
done
h_info "All Informix pods got their images"
