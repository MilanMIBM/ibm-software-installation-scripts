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
# Every mirror-images step pushes MIRROR_CPD_PARALLEL_JOBS CASEs at a time
# (MIRROR_CPD_PARALLEL=true, the default; false = IBM's serial run, see mirror_images).
#
# olm-utils lands as <root>/cpd/cpopen/cpd/olm-utils-v4:<release>[.<arch>] (the
# CASE tags, pinned to the patch build's digest; there is no <release>.<patch>
# tag in a private registry). The arch suffix is added only when one is
# specified (preg_olm_arch_suffix). The tap step (3.5) points OLM_UTILS_IMAGE there.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/progress_panel_helpers.sh"

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
PARALLEL=false
preg_is_true "${MIRROR_CPD_PARALLEL:-true}" && PARALLEL=true
PARALLEL_JOBS="${MIRROR_CPD_PARALLEL_JOBS:-6}"
[[ "${PARALLEL_JOBS}" == <1-> ]] || preg_die "MIRROR_CPD_PARALLEL_JOBS must be a whole number >= 1 (is '${PARALLEL_JOBS}')"
OLM_C="${OLM_UTILS_CONTAINER:-olm-utils-play-v4}"

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

# mirror-images, serial (IBM's playbook: one CASE after another, one upload at a
# time) or with MIRROR_CPD_PARALLEL=true: mirror-images only prunes (--arch) and
# writes each CASE's mapping file (the playbook's skip_do_mirror +
# do_mirror_manifests vars, through the documented --param-file), then the
# oc image mirror the playbook would run per CASE runs here, MIRROR_CPD_PARALLEL_JOBS
# CASEs at a time, largest first - same flags, auth, log (mirror_<case>.log) and
# retries (3, 60 s apart). In a terminal one pinned row per running CASE shows
# its progress (progress_panel_helpers.sh; PPANEL_MODE=plain for log lines).

# A pool job is a mapping file path relative to the work dir
# (.../mirror/<case>/<version>/<file>; /tmp/work/<path> in the container).
case_label() { REPLY="${${1:h:h}:t}"; }

mirror_case() {   # <job> - pool worker
    local c="${${1:h:h}:t}" rc=0 n
    rm -f -- "${WORK}/mirror_${c}.log"   # the probe reads only this attempt's log
    podman exec "${OLM_C}" sh -c "oc image mirror -f /tmp/work/$1 --max-per-registry=1 --skip-multiple-scopes=true --continue-on-error=true --filter-by-os \".*\" -a /opt/ansible/.airgap/secrets/config.json --insecure > /tmp/work/mirror_${c}.log 2>&1" \
        || rc=$?
    (( rc )) || return 0
    n="$(grep -c '^error' "${WORK}/mirror_${c}.log" 2>/dev/null)"
    ppanel_job_reason "${n:-0} error line(s) in mirror_${c}.log"
    return "${rc}"
}

# oc image mirror's log: one "sha256:<digest> <target>:<tag>" line per tag
# pushed (one per mapping line), "uploading: / mounted: <repo> <blob> <size>"
# per layer, "error: ..." per image it could not copy (it carries on).
typeset -gA probe_vals probe_warned
mirror_case_probe() {   # <job> <attempt> - pool probe
    local c="${${1:h:h}:t}" log
    log="${WORK}/mirror_${c}.log"
    if ppanel_changed "${log}"; then
        probe_vals[$1]=""
        [[ -s "${log}" ]] && probe_vals[$1]="$(awk '
/^sha256:[0-9a-f]+ [^ ]/          { p++; n = split($2, a, "/"); last = "pushed " a[n]; next }
/^error/                          { e++; if (fe == "") fe = $0; next }
/^info: Planning completed/       { pl = 1; next }
/^info: Mirroring completed/      { last = "finishing"; next }
/^(uploading|mounted|skipped): /  { n = split($2, a, "/"); last = substr($1, 1, length($1) - 1) " " a[n] ($4 != "" ? " " $4 : "") }
END { printf "%d\t%d\t%d\t%s\t%s", p, e, pl, last, fe }' "${log}")"
    fi
    if [[ -z "${probe_vals[$1]}" ]]; then
        PPANEL_DETAIL="starting"
        return 0
    fi
    local -a v=("${(@ps:\t:)probe_vals[$1]}")
    local key="${1}:${2}"
    PPANEL_DONE="${v[1]}" PPANEL_DETAIL="planning"
    (( v[3] )) && PPANEL_DETAIL="${v[4]:-copying}"
    if (( v[2] )); then
        PPANEL_DETAIL+=" · ${v[2]} error(s)"
        if [[ -z "${probe_warned[$key]:-}" ]]; then
            probe_warned[$key]=1
            ppanel_event WARN "cpd: ${c}: ${v[5]#error: } (attempt $2; oc carries on - see mirror_${c}.log)"
        fi
    fi
    return 0
}

# Mirror processes in the olm-utils container: podman exec does not pass signals
# on, so an interrupted run leaves them pushing (into the same logs) - its
# mirror-images playbook (which would start the next CASE) and oc image mirror.
# Only called when no mirror-images of this run is active. Prints how many it
# stopped. The patterns are split (${m}) so this shell's own command line does
# not match them.
stop_container_mirrors() {
    podman exec "${OLM_C}" sh -c 'm=mirror n=0
for pat in "/opt/ansible/bin/${m}-images " "ansible-playbook ./${m}-playbook.yml " "bin/oc image ${m} -f /tmp/work/"; do
    for p in /proc/[0-9]*; do
        [ "${p#/proc/}" = "$$" ] && continue
        case "$(tr "\0" " " < "${p}/cmdline" 2>/dev/null)" in
            *"${pat}"*) kill "${p#/proc/}" 2>/dev/null && n=$((n + 1)) ;;
        esac
    done
done
echo "${n}"' 2>/dev/null || print 0
}

mirror_images() {   # <mapping file name> <mirror-images args...>
    local map_name="$1"; shift
    if ! ${PARALLEL}; then
        cpd-cli manage mirror-images "$@"
        return
    fi
    local params="${WORK}/mirror_manifests_only.yml" gen_marker f maps=()
    print -r -- $'skip_do_mirror: true\ndo_mirror_manifests: true' > "${params}"
    gen_marker="$(preg_private_tmpdir)/marker"; : > "${gen_marker}"
    preg_info "cpd: mirror-images (mapping files only; MIRROR_CPD_PARALLEL=true)"
    cpd-cli manage mirror-images "$@" --param-file="/tmp/work/${params:t}"
    for f in "${WORK}/offline/${REL}/.ibm-pak/data/mirror"/*/*/"${map_name}"(N); do
        [[ "${f}" -nt "${gen_marker}" ]] && maps+=("${f#${WORK}/}")
    done
    (( ${#maps} )) || preg_die "cpd: mirror-images wrote no ${map_name} - re-run with MIRROR_CPD_PARALLEL=false"
    podman exec "${OLM_C}" sh -c "test -s /opt/ansible/.airgap/secrets/config.json" \
        || preg_die "cpd: no registry auth in ${OLM_C} - re-run with MIRROR_CPD_PARALLEL=false"
    local n
    n="$(stop_container_mirrors)"
    (( n == 0 )) || preg_warn "cpd: stopped ${n} mirror process(es) an interrupted run left in ${OLM_C}"
    # images per CASE (mapping lines): the panel's totals and the order, largest first
    local -A map_lines
    for f in "${maps[@]}"; do map_lines[$f]="$(grep -c . "${WORK}/${f}" || true)"; done
    maps=("${(@f)$(for f in "${maps[@]}"; do print -r -- "${map_lines[$f]} ${f}"; done | sort -rn | cut -d' ' -f2-)}")
    preg_info "cpd: oc image mirror for ${#maps} CASE(s), ${PARALLEL_JOBS} at a time (logs: ${WORK}/mirror_<case>.log)"
    ppanel_pool_run -j "${PARALLEL_JOBS}" -a 4 -d 60 -t cpd -k CASEs -u images -W map_lines \
        -w mirror_case -p mirror_case_probe -l case_label -c stop_container_mirrors -- "${maps[@]}" \
        || preg_die "cpd: ${#PPANEL_FAILED} CASE(s) failed to mirror (${(j:, :)${PPANEL_FAILED[@]:h:h:t}}) - see mirror_<case>.log in ${WORK}, fix and re-run (mirroring resumes)"
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
                mirror_images images-mapping.txt --components="${COMPS}" "${common[@]}" --target_registry="${TARGET}" \
                    "${mirror_flags[@]}" --case_download=false
            else
                preg_info "cpd: mirror-images -> stop-over ${STOPOVER} (in ${WORK}/registry-storage)"
                mirror_images images-mapping.txt --components="${COMPS}" "${common[@]}" --target_registry="${STOPOVER}" \
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
            mirror_images images-mapping-from-registry.txt --components="${COMPS}" "${common[@]}" --source_registry="${STOPOVER}" \
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
