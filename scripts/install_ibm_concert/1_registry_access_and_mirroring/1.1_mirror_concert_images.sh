#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 1.1 Mirror the IBM Concert images (CONCERT_IMAGE_SOURCE=mirrored|airgap)
# ------------------------------------------------------------------------------
# Runs on this workstation/bastion with `oc image mirror` - no container
# runtime needed, works on macOS and supports mirror-to-disk.
#
# Why not IBM's bin/manage-images: it pushes <registry>/<image>:<tag> and
# drops the product path, but the installer pulls
# IMAGE_REGISTRY_PREFIX + /platform-hub|/concert + /<image>:<tag>. This
# script keeps that layout:
#   cp.icr.io/cp/<suffix>/<image>  ->  <PRIVATE_REGISTRY_LOCATION>/cp/<suffix>/<image>
# and concert_vars.sh sets IMAGE_REGISTRY_PREFIX=<PRIVATE_REGISTRY_LOCATION>/cp.
#
# Image lists come from the installer archive (0.1): <product>/etc/images.lst;
# suffixes from etc/<product>.prod.conf (hub, itom = platform-hub; the rest =
# concert). All products are mirrored (CONCERT_MIRROR_SELECTED_ONLY=true for
# just the configured ones) so adding a product later needs no new mirror.
#
#   mirrored:  ./1.1_mirror_concert_images.sh
#   airgap:    ./1.1_mirror_concert_images.sh --phase=save   (connected side)
#              ...transfer CONCERT_AIRGAP_DIR...
#              ./1.1_mirror_concert_images.sh --phase=load   (disconnected side)
# ==============================================================================

if [[ "${CONCERT_IMAGE_SOURCE}" == entitled ]]; then
    concert_info "CONCERT_IMAGE_SOURCE=entitled - the cluster pulls from cp.icr.io, nothing to mirror."
    exit 0
fi

PHASE="${CONCERT_AIRGAP_PHASE:-}"
for _arg in "$@"; do
    case "${_arg}" in
        --phase=*) PHASE="${_arg#*=}" ;;
        *) concert_die "Unknown argument: ${_arg} (only --phase=save|load)" ;;
    esac
done
if [[ "${CONCERT_IMAGE_SOURCE}" == mirrored ]]; then
    PHASE=mirror
elif [[ "${PHASE}" != (save|load) ]]; then
    concert_die "CONCERT_IMAGE_SOURCE=airgap needs --phase=save (connected side) or --phase=load (disconnected side)."
fi

concert_require_local_installer
INSTALL_DIR="$(concert_local_install_dir)"
AIRGAP_DIR="${CONCERT_AIRGAP_DIR:-${CONCERT_WORKSPACE}/airgap}"
SRC="cp.icr.io/cp"
DEST="${PRIVATE_REGISTRY_LOCATION:-}/cp"
[[ "${PHASE}" == save ]] || concert_require_vars PRIVATE_REGISTRY_LOCATION PRIVATE_REGISTRY_PUSH_USER PRIVATE_REGISTRY_PUSH_PASSWORD
[[ "${PHASE}" == load ]] || concert_require_vars IBM_ENTITLEMENT_KEY

# <dir with etc/images.lst>:<registry suffix>:<product key for selection>
LISTS=(
    "concert-hub:platform-hub:hub"
    "itom:platform-hub:itom"
    "concert:concert:concert"
    "dataapps:concert:dataapps"
    "concert-workflows:concert:workflows"
    "concert-securecoder:concert:securecoder"
)

STAGE="$(concert_private_tmpdir)"
trap 'rm -rf "${STAGE}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
MAPPING="${STAGE}/mapping.txt"
: > "${MAPPING}"

for entry in "${LISTS[@]}"; do
    dir="${entry%%:*}" rest="${entry#*:}"
    suffix="${rest%%:*}" product="${rest#*:}"
    list="${INSTALL_DIR}/${dir}/etc/images.lst"
    [[ -f "${list}" ]] || continue
    if concert_is_true "${CONCERT_MIRROR_SELECTED_ONLY:-false}" && ! concert_product_enabled "${product}"; then
        # Workflows still needs Concert's ibm-solis-gw image
        [[ "${product}" == concert ]] && concert_product_enabled workflows || continue
    fi
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "${line}" ]] || continue
        img="${line##*/}"
        case "${PHASE}" in
            mirror) print -r -- "${SRC}/${suffix}/${img}=${DEST}/${suffix}/${img}" ;;
            save)   print -r -- "${SRC}/${suffix}/${img}=file://cp/${suffix}/${img}" ;;
            load)   print -r -- "file://cp/${suffix}/${img}=${DEST}/${suffix}/${img}" ;;
        esac
    done < "${list}" >> "${MAPPING}"
done
sort -u -o "${MAPPING}" "${MAPPING}"
COUNT="$(wc -l < "${MAPPING}" | tr -d ' ')"
(( COUNT > 0 )) || concert_die "No images found in the installer's images.lst files."
concert_info "${COUNT} images to ${PHASE} (mapping: first lines below)"
head -3 "${MAPPING}" | sed 's/^/    /'

CONCERT_ICR_USER=cp
concert_write_dockerconfig "${STAGE}/auth.json" \
    "cp.icr.io=CONCERT_ICR_USER:IBM_ENTITLEMENT_KEY" \
    "${PRIVATE_REGISTRY_LOCATION%%/*}=PRIVATE_REGISTRY_PUSH_USER:PRIVATE_REGISTRY_PUSH_PASSWORD"

ARGS=(-a "${STAGE}/auth.json" -f "${MAPPING}" --keep-manifest-list=true --filter-by-os='.*'
      --max-per-registry="${CONCERT_MIRROR_PARALLEL:-4}" --continue-on-error=false)
concert_is_true "${CONCERT_MIRROR_INSECURE:-false}" && ARGS+=(--insecure=true)
case "${PHASE}" in
    save) mkdir -p "${AIRGAP_DIR}/concert-images"; ARGS+=(--dir="${AIRGAP_DIR}/concert-images") ;;
    load) [[ -d "${AIRGAP_DIR}/concert-images" ]] || concert_die "Missing ${AIRGAP_DIR}/concert-images (from the save phase)."
          ARGS+=(--from-dir="${AIRGAP_DIR}/concert-images") ;;
esac

oc image mirror "${ARGS[@]}"

if [[ "${PHASE}" != save ]]; then
    probe="$(awk -F= 'NR==1 {print $2}' "${MAPPING}")"
    oc image info -a "${STAGE}/auth.json" --filter-by-os=linux/amd64 "${probe}" >/dev/null \
        && concert_info "Verified ${probe}" \
        || concert_die "Mirrored image ${probe} is not readable from the private registry."
    concert_info "Done. The installer will pull from IMAGE_REGISTRY_PREFIX=${DEST}"
else
    concert_info "Saved to ${AIRGAP_DIR}/concert-images - transfer that directory, then run --phase=load."
fi
