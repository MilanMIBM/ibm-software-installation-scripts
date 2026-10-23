#!/bin/zsh
# Segment 2 hook: cpd (contract: _template.sh)
#
# IBM's documented flows (Software Hub 5.4 "Mirroring images directly" and
# "Mirroring images using an intermediary container registry"), cpd-cli only:
#
#   mirror  case-download -> login-entitled-registry -> [list-images
#           --inspect_source_registry, when MIRROR_CPD_INSPECT_SOURCE_REGISTRY=true]
#           -> (EDB/WSL prunes) -> login-private-registry
#           -> mirror-images --target_registry=<root>/cpd -> list-images
#           --target_registry (no level=fatal)
#   save    same up to mirror-images, which goes to cpd-cli's own stop-over
#           registry 127.0.0.1:12443 (its storage is ~/cpd-cli/work/registry-storage,
#           carried in the bundle by 2.5); olm-utils saved as a tar
#   load    olm-utils loaded from the tar -> login-private-registry ->
#           mirror-images --source_registry=127.0.0.1:12443
#           --target_registry=<root>/cpd -> list-images --target_registry
#
# olm-utils lands as <root>/cpd/cpopen/cpd/olm-utils-v4:<release>[.<arch>] (the
# CASE tags, pinned to the patch build's digest; there is no <release>.<patch>
# tag in a private registry). The arch suffix is added only when one is
# specified (preg_olm_arch_suffix). The tap step (3.5) points OLM_UTILS_IMAGE there.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

VERB="${1:-}"; shift || true
NATIVE="${MIRROR_INSTALL_WORKDIR:?run through 2.0 / 2.4}/native.jsonl"
[[ -s "${NATIVE}" ]] || exit 0

# native.jsonl -> shell values (one python pass; values via stdout lines).
# The final END line keeps the positions: $(...) drops trailing empty lines.
_vals=("${(@f)$(preg_python -c '
import json, sys
n = json.loads(open(sys.argv[1]).readline())
for k in ("components", "extra_cases", "release", "patch_id", "arch", "groups", "content"):
    print(n.get(k, ""))
print("END")' "${NATIVE}")}")
COMPS="${_vals[1]}" EXTRA="${_vals[2]}" REL="${_vals[3]}" PATCH="${_vals[4]}" ARCH="${_vals[5]}" IMG_GROUPS="${_vals[6]}" CONTENT="${_vals[7]}"
has() { preg_in_list "$1" "${CONTENT}"; }

command -v cpd-cli >/dev/null 2>&1 || preg_die "cpd-cli not on PATH (scripts/install_cloud_pak_for_data/0_initial_setup/0.2_install_cpd_cli-MAC-ONLY.sh, or 2.6 on the inside)"
WORK="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}"
TARGET="${MIRROR_INSTALL_PUSH_PREFIX:?no registry configured}"
STOPOVER="127.0.0.1:12443"
OLM_SFX="$(preg_olm_arch_suffix)"
OLM_REPO="cpopen/cpd/olm-utils-v4"

common=(--release="${REL}")
[[ -n "${PATCH}" ]] && common+=(--patch_id="${PATCH}")
mirror_flags=()
[[ "${ARCH}" != all ]] && mirror_flags+=(--arch="${ARCH}")
has image-groups && [[ -n "${IMG_GROUPS}" ]] && mirror_flags+=(--groups="${IMG_GROUPS}")
# -v: of the commands used here only mirror-images takes it
preg_is_true "${MIRROR_CPD_VERBOSE:-true}" && mirror_flags+=(-v)
oci=()
preg_is_true "${MIRROR_CPD_CASE_FROM_OCI:-true}" && oci=(--from_oci=true)

fatal_check() {   # <label>: list_images.csv must have no level=fatal lines
    local csv="${WORK}/offline/${REL}/list_images.csv" n
    [[ -f "${csv}" ]] || preg_die "$1: ${csv} not found"
    n="$(grep -c 'level=fatal' "${csv}" || true)"
    if (( n )); then
        grep 'level=fatal' "${csv}" | head -20 >&2
        preg_die "$1: ${n} image(s) failed (authorization or network) - ${csv}"
    fi
    preg_info "$1: no level=fatal in list_images.csv"
}

# IBM's optional prunes (EDB Postgres Standard; Watson Studio GPU / NLP) - a
# portable in-place edit instead of GNU sed -i.
prune_csv() {   # <case dir glob> <pattern>
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
apply_prunes() {
    local cases="${WORK}/offline/${REL}/.ibm-pak/data/cases"
    preg_is_true "${MIRROR_CPD_EDB_STANDARD_ONLY:-false}" && prune_csv "${cases}/ibm-cpd-edb/*/ibm-cpd-edb-*-images.csv" "edb-postgres-advanced"
    preg_is_true "${MIRROR_CPD_WSL_EXCLUDE_GPU:-false}" && prune_csv "${cases}/ibm-wsl-runtimes/*/ibm-wsl-runtimes-*-images.csv" "/gpu/"
    preg_is_true "${MIRROR_CPD_WSL_EXCLUDE_NLP:-false}" && prune_csv "${cases}/ibm-wsl-runtimes/*/ibm-wsl-runtimes-*-images.csv" "/nlp/"
    return 0
}

private_login() {
    preg_require_vars MIRROR_REGISTRY_PUSH_USER MIRROR_REGISTRY_PUSH_PASSWORD
    # IBM's command takes the credentials as arguments and stores them scoped to
    # this path (spike S2); 2.1 - 2.3 use their own host-level auth files.
    cpd-cli manage login-private-registry "${TARGET}" "${MIRROR_REGISTRY_PUSH_USER}" "${MIRROR_REGISTRY_PUSH_PASSWORD}" >/dev/null
}

mirror_logs_check() {   # mirror_*.log written after the marker must have no "error"
    local marker="$1" f bad=()
    for f in "${WORK}"/mirror_*.log(N); do
        [[ "${f}" -nt "${marker}" ]] || continue
        grep -qi 'error' "${f}" && bad+=("${f:t}")
    done
    (( ${#bad} == 0 )) || preg_die "errors in ${bad[*]} (in ${WORK}) - fix and re-run (mirroring resumes)"
}

# olm-utils digest from the platform CASE (its tag <release>[.<arch>] carries the patch build)
olm_digest() {
    local csv
    for csv in "${WORK}"/offline/"${REL}"/.ibm-pak/data/cases/ibm-cp-datacore/*/ibm-cp-datacore-*-images.csv(N); do
        awk -F, -v r="${OLM_REPO}" -v t="${REL}${OLM_SFX}" '$2 == r && $3 == t { print $4; exit }' "${csv}"
        return 0
    done
}

olm_tag="${REL}${OLM_SFX}"
# The ref cpd_vars.sh's OLM_UTILS_IMAGE uses by default (<release>.<patch>[.<arch>])
olm_save_ref="icr.io/${OLM_REPO}:${REL}${PATCH:+.${PATCH}}${OLM_SFX}"

case "${VERB}" in
download)
    preg_parse_phase_args "$@"
    PHASE="${PREG_PHASE_ARG:-${MIRROR_PHASE:-mirror}}"
    marker="$(preg_private_tmpdir)/marker"; : > "${marker}"
    if [[ "${PHASE}" == (mirror|save) ]]; then
        if has case || has ibm-images; then
            cases="${COMPS}${EXTRA:+,${EXTRA}}"
            preg_info "cpd: case-download ${cases}"
            cpd-cli manage case-download --components="${cases}" "${common[@]}" "${oci[@]}"
        fi
        if has ibm-images; then
            preg_require_vars MIRROR_IBM_ENTITLEMENT_KEY
            cpd-cli manage login-entitled-registry "${MIRROR_IBM_ENTITLEMENT_KEY}" >/dev/null
            if preg_is_true "${MIRROR_CPD_INSPECT_SOURCE_REGISTRY:-false}"; then
                preg_info "cpd: list-images --inspect_source_registry=true"
                cpd-cli manage list-images --components="${COMPS}" "${common[@]}" --inspect_source_registry=true "${oci[@]}"
                fatal_check "cpd source check"
            else
                preg_info "cpd: source inspection skipped (MIRROR_CPD_INSPECT_SOURCE_REGISTRY=false)"
            fi
            apply_prunes
            if [[ "${PHASE}" == mirror ]]; then
                private_login
                preg_info "cpd: mirror-images -> ${TARGET}"
                cpd-cli manage mirror-images --components="${COMPS}" "${common[@]}" --target_registry="${TARGET}" \
                    "${mirror_flags[@]}" --case_download=false
            else
                preg_info "cpd: mirror-images -> stop-over ${STOPOVER} (in ${WORK}/registry-storage)"
                cpd-cli manage mirror-images --components="${COMPS}" "${common[@]}" --target_registry="${STOPOVER}" \
                    "${mirror_flags[@]}" --case_download=false
            fi
            mirror_logs_check "${marker}"
            if [[ "${PHASE}" == mirror ]]; then
                cpd-cli manage list-images --components="${COMPS}" "${common[@]}" --target_registry="${TARGET}" --case_download=false
                fatal_check "cpd target check"
            fi
        fi
        if has olm-utils; then
            if [[ "${PHASE}" == mirror ]]; then
                # Mirrored with the platform CASE; make sure the tag the tap uses exists.
                auth="$(preg_private_tmpdir)/auth.json"
                preg_write_authfile "${auth}" push --sources
                topts=(--authfile "${auth}" ${(z)$(preg_skopeo_target_opts)})
                if skopeo inspect --raw "${topts[@]}" "docker://${TARGET}/${OLM_REPO}:${olm_tag}" >/dev/null 2>&1; then
                    preg_info "cpd: ${TARGET}/${OLM_REPO}:${olm_tag} present"
                else
                    d="$(olm_digest)"
                    src="icr.io/${OLM_REPO}@${d}"
                    [[ -n "${d}" ]] || src="${olm_save_ref}"
                    preg_info "cpd: copying ${src} -> ${TARGET}/${OLM_REPO}:${olm_tag}"
                    skopeo copy --all --src-authfile "${auth}" --dest-authfile "${auth}" ${(z)$(preg_skopeo_dest_opts)} \
                        "docker://${src}" "docker://${TARGET}/${OLM_REPO}:${olm_tag}"
                fi
                rm -f "${auth}"
            else
                preg_info "cpd: save-image ${olm_save_ref} (for the inside workstation)"
                cpd-cli manage save-image --from="${olm_save_ref}"
            fi
        fi
    else   # load
        if has olm-utils && ! podman image exists "${olm_save_ref}" 2>/dev/null; then
            preg_info "cpd: load-image ${olm_save_ref}"
            cpd-cli manage load-image --source-image="${olm_save_ref}"
        fi
        # Offline: cpd-cli must run the image just loaded, not pull one.
        podman image exists "${olm_save_ref}" 2>/dev/null && export OLM_UTILS_IMAGE="${olm_save_ref}"
        if has ibm-images; then
            private_login
            preg_info "cpd: mirror-images ${STOPOVER} -> ${TARGET}"
            cpd-cli manage mirror-images --components="${COMPS}" "${common[@]}" --source_registry="${STOPOVER}" \
                --target_registry="${TARGET}" "${mirror_flags[@]}" --case_download=false
            mirror_logs_check "${marker}"
            cpd-cli manage list-images --components="${COMPS}" "${common[@]}" --target_registry="${TARGET}" --case_download=false
            fatal_check "cpd target check"
        fi
    fi
    ;;
verify-registry)
    if has ibm-images; then
        private_login
        cpd-cli manage list-images --components="${COMPS}" "${common[@]}" --target_registry="${TARGET}" --case_download=false
        fatal_check "cpd target check"
    fi
    ;;
*) preg_die "usage: $0 download --phase=... | verify-registry" ;;
esac

exit 0
