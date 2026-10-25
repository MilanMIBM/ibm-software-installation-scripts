#!/bin/zsh
# Segment 4 hook: cpd (contract: _template.sh) - move <root>/cpd to another
# Software Hub patch of the same release, copying only what the patch changed.
#
#   plan    mirror  case-download --patch_id=<to>; mirror-images writes the
#                   mapping files only (nothing pushed); every mapping line not
#                   in the recorded mapping of <from> is probed in the registry
#                   by digest (skopeo, concurrently) -> delta.tsv
#           save    the same, but the registry is out of reach: the delta is the
#                   <to> mapping minus the <from> mapping (recorded, or generated
#                   once from the <from> CASEs)
#           load    verifies the patch bundle, then probes its delta lines in the
#                   registry (only what is still missing gets pushed)
#   copy    tags the delta re-points are first kept as <tag>-p<from>; then
#           oc image mirror per CASE, MIRROR_CPD_PARALLEL_JOBS at a time: to the
#           registry (mirror), into the patch bundle (save, plus the new CASE
#           packages and the patch metadata), or from it (load)
#   record  verifies the delta (--full: the whole <to> mapping) by digest, adds
#           the version tags, records <to> as the registry's patch, and moves
#           native.jsonl / inventory.json to it (2.0 / 2.4 then follow)
#   list    the recorded and planned patches
#
# Version tags (they keep every patch addressable): a tag that a patch moves
# (same tag, new digest) keeps the old digest as <tag>-p<from>; olm-utils gets
# IBM's <release>.<patch>[.<arch>] tags (cpd_vars.sh's OLM_UTILS_IMAGE form).
# Everything else is already versioned by its own tags and digests.
#
# Workspace: <cpd path>/patches/<release>-p<n>/ (plan.json, mapping.tsv,
# delta.tsv, changed-components.tsv, report.txt, recorded.json | saved.json),
# patches/current (the registry's patch), patches/saved (the last save),
# patches/pending.env (the plan copy / record work on), patches/history.log.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/progress_panel_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/cpd_mirror_helpers.sh"

VERB="${1:-}"; shift || true
preg_parse_phase_args "$@"
PHASE="${PREG_PHASE_ARG:-${MIRROR_PHASE:-mirror}}"
set -- "${PREG_ARGS[@]}"
TO_ARG="" FROM_ARG="" FROM_SET=false ALL=false FULL=false ESTIMATE=false QUICK=false BUNDLE_ARG=""
while (( $# )); do
    case "$1" in
        --to) TO_ARG="${2:?--to needs a patch number}"; shift 2 ;;
        --from) FROM_ARG="${2?--from needs a patch number (0 = no patch)}"; FROM_SET=true; shift 2 ;;
        --all) ALL=true; shift ;;
        --full) FULL=true; shift ;;
        --estimate) ESTIMATE=true; shift ;;
        --quick) QUICK=true; shift ;;
        --bundle) BUNDLE_ARG="${2:?--bundle needs a directory}"; shift 2 ;;
        *) preg_die "Unknown argument: $1" ;;
    esac
done
[[ "${FROM_ARG}" == 0 ]] && FROM_ARG=""

NATIVE="${MIRROR_INSTALL_WORKDIR:?run through the 4.x scripts}/native.jsonl"
[[ -s "${NATIVE}" ]] || preg_die "No cpd native content in the inventory - run 1_map_content/1.0_build_inventory.sh (content ibm-images) and 2.0 first."
_vals=("${(@f)$(preg_python -c '
import json, sys
n = json.loads(open(sys.argv[1]).readline())
for k in ("components", "extra_cases", "release", "patch_id", "arch", "groups", "content"):
    print(n.get(k, ""))
print("END")' "${NATIVE}")}")
COMPS="${_vals[1]}" EXTRA="${_vals[2]}" REL="${_vals[3]}" N_PATCH="${_vals[4]}" ARCH="${_vals[5]}" IMG_GROUPS="${_vals[6]}" CONTENT="${_vals[7]}"
preg_in_list ibm-images "${CONTENT}" || preg_die "MIRROR_CPD_CONTENT has no ibm-images - nothing of a patch to mirror."
if [[ -n "${VERSION:-}" && "${VERSION}" != "${REL}" ]]; then
    preg_die "cpd_vars.sh has VERSION=${VERSION}, the registry has release ${REL}: a new release is not a patch update - run 1.0 and 2.0."
fi

WORK="$(cpdm_work)"
TARGET="${MIRROR_INSTALL_PUSH_PREFIX:?no registry configured}"
STOPOVER="127.0.0.1:12443"
OLM_REPO="cpopen/cpd/olm-utils-v4"
OLM_SFX="$(preg_olm_arch_suffix)"
PATCHES="${MIRROR_INSTALL_WORKDIR}/patches"
PENDING="${PATCHES}/pending.env"
BUNDLES="${MIRROR_CPD_PATCH_BUNDLE_DIR:-${MIRROR_WORKSPACE}/patch-bundles}"
PARALLEL_JOBS="${MIRROR_CPD_PARALLEL_JOBS:-6}"
PROBE_JOBS="${MIRROR_CPD_PATCH_PROBE_JOBS:-16}"
[[ "${PARALLEL_JOBS}" == <1-> ]] || preg_die "MIRROR_CPD_PARALLEL_JOBS must be a whole number >= 1 (is '${PARALLEL_JOBS}')"
[[ "${PROBE_JOBS}" == <1-> ]] || preg_die "MIRROR_CPD_PATCH_PROBE_JOBS must be a whole number >= 1 (is '${PROBE_JOBS}')"
mkdir -p "${PATCHES}"

RUN="$(preg_private_tmpdir)"
trap 'ppanel_watch_stop 2>/dev/null; rm -rf "${RUN}"' EXIT

pdir() { print -r -- "${PATCHES}/${REL}-p${1:-0}"; }
plabel() { [[ -n "$1" ]] && print -r -- "patch $1" || print -r -- "no patch"; }

# Patch recorded in patches/current or patches/saved for this release (empty: none).
state_patch() {   # <file>
    [[ -f "$1" ]] || return 0
    awk -F'\t' -v r="${REL}" '$1 == r { p = $2 } END { print p }' "$1"
}
state_has() {   # <file>: is this release recorded there?
    [[ -f "$1" ]] && awk -F'\t' -v r="${REL}" '$1 == r { f = 1 } END { exit !f }' "$1"
}

# <from>: --from, else the last save (save phase) or the registry's recorded
# patch, else what 1.0 mapped (and 2.0 mirrored).
resolve_from() {
    if ${FROM_SET}; then REPLY="${FROM_ARG}"; return 0; fi
    if [[ "${PHASE}" == save ]] && state_has "${PATCHES}/saved"; then REPLY="$(state_patch "${PATCHES}/saved")"; return 0; fi
    if state_has "${PATCHES}/current"; then REPLY="$(state_patch "${PATCHES}/current")"; return 0; fi
    REPLY="${N_PATCH}"
}
resolve_to() {
    REPLY="${TO_ARG:-${MIRROR_CPD_PATCH_ID:-${PATCH_ID:-}}}"
    [[ -n "${REPLY}" ]] || preg_die "No target patch: pass --to N, or set PATCH_ID in configs/cp4d_config/cpd_vars.sh (or MIRROR_CPD_PATCH_ID)."
    [[ "${REPLY}" == <1-> ]] || preg_die "Target patch must be a number (got '${REPLY}')."
}

# The plan copy / record continue (patches/pending.env, written by plan).
load_pending() {
    [[ -f "${PENDING}" ]] || preg_die "No plan - run 4.0_plan_cpd_patch_update.sh first."
    source "${PENDING}"
    [[ "${P_RELEASE}" == "${REL}" ]] || preg_die "The plan is for release ${P_RELEASE}, the inventory for ${REL} - re-run 4.0."
    [[ "${P_PHASE}" == "${PHASE}" ]] || preg_die "The plan is for phase ${P_PHASE}, this run is ${PHASE} - re-run 4.0 --phase=${PHASE}."
    [[ -z "${TO_ARG}" || "${TO_ARG}" == "${P_TO}" ]] || preg_die "The plan is for patch ${P_TO}, not ${TO_ARG} - re-run 4.0."
    TO="${P_TO}" FROM="${P_FROM}" DIR="${P_DIR}" BUNDLE="${P_BUNDLE}"
}

# --- Registry access -----------------------------------------------------------------
AUTH="${RUN}/auth.json"
write_auth() {
    case "${PHASE}" in
        mirror) preg_write_authfile "${AUTH}" push --sources ;;
        save)   preg_write_authfile "${AUTH}" none --sources ;;
        load)   preg_write_authfile "${AUTH}" push ;;
    esac
}
SK_OPTS=(${(z)$(preg_skopeo_target_opts)})
SK_SRC_OPTS=()
_cd="$(preg_cert_dir)"
if preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}"; then SK_SRC_OPTS=(--src-tls-verify=false)
elif [[ -n "${_cd}" ]]; then SK_SRC_OPTS=(--src-cert-dir="${_cd}"); fi
PROBE_TLS=()
[[ -n "${_cd}" ]] && PROBE_TLS=(--cert-dir "${_cd}")
preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}" && PROBE_TLS=(--tls-verify-false)
OC_TLS=(${(z)$(preg_oc_insecure)})
unset _cd

# Digest of the manifest <ref> points at (fails when it is not there). Through a
# file: $(...) would drop a trailing newline of the manifest and change the digest.
raw_digest() {   # <ref>
    skopeo inspect --raw --authfile "${AUTH}" "${SK_OPTS[@]}" "docker://$1" > "${RUN}/manifest" 2>/dev/null || return 1
    print -r -- "sha256:$(preg_sha256 "${RUN}/manifest")"
}

# Version tag of a target (repo:tag relative to <root>/cpd) for patch <p>.
version_tag() {   # <rel> <patch>
    local repo="${1%:*}" tag="${1##*:}" p="${2:-0}"
    if [[ "${repo}" == */olm-utils-v4 && ( "${tag}" == "${REL}" || "${tag}" == "${REL}".* ) ]]; then
        REPLY="${repo}:${REL}.${p}${tag#${REL}}"
    else
        REPLY="${repo}:${tag}-p${p}"
    fi
}

# <rel>@<digest> -> <alias rel>, inside the registry (blobs are already there).
tag_digest() {   # <rel> <digest> <alias rel>
    local repo="${1%:*}" d
    d="$(raw_digest "${TARGET}/$3")" || d=""
    if [[ "${d}" == "$2" ]]; then
        preg_info "cpd: ${3} already tagged"
        return 0
    fi
    skopeo copy --all --preserve-digests --quiet --src-authfile "${AUTH}" --dest-authfile "${AUTH}" \
        "${SK_SRC_OPTS[@]}" ${(z)$(preg_skopeo_dest_opts)} \
        "docker://${TARGET}/${repo}@$2" "docker://${TARGET}/$3" \
        || { preg_error "cpd: could not tag ${TARGET}/${repo}@$2 as ${3##*:}"; return 1; }
    preg_info "cpd: tagged ${3}  (${2:7:12})"
}

# --- cpd-cli ---------------------------------------------------------------------------
common_flags() {   # <patch> -> reply: --release / --patch_id
    reply=(--release="${REL}")
    [[ -n "$1" ]] && reply+=(--patch_id="$1")
    return 0
}

private_login() {
    preg_require_vars MIRROR_REGISTRY_PUSH_USER MIRROR_REGISTRY_PUSH_PASSWORD
    cpd-cli manage login-private-registry "${TARGET}" "${MIRROR_REGISTRY_PUSH_USER}" "${MIRROR_REGISTRY_PUSH_PASSWORD}" >/dev/null
}

# A cpd-cli run with its output in <log> and one progress row (its probe <fn>).
_W_LOG="" _W_MARK="" _W_TOTAL=""
cpd_watched() {   # <title> <log> <probe> <cpd-cli manage args...>
    local title="$1" log="$2" probe="$3" rc=0
    shift 3
    _W_LOG="${log}"
    : > "${log}"
    ppanel_watch_start -p "${probe}" -t "${title}" -u CASEs
    "$@" > "${log}" 2>&1 || rc=$?
    ppanel_watch_stop
    if (( rc )); then
        sed -E $'s/\e\\[[0-9;]*m//g; s/\r$//' "${log}" | tail -n 25 >&2
        preg_error "${title} failed (exit ${rc}) - full output: ${log}"
    fi
    return "${rc}"
}
_dl_probe() {   # CASE versions case-download added since the start
    local -a n
    n=("${WORK}/offline/${REL}/.ibm-pak/data/cases"/*/*(N/e:'[[ ${REPLY} -nt ${_W_MARK} ]]':))
    PPANEL_DONE="${#n}" PPANEL_DETAIL="new CASE versions (cached ones are reused)"
}
_map_probe() {   # CASEs whose mapping file mirror-images generated
    local -a v
    v=(${=$(awk '
{ gsub(/\033\[[0-9;]*m/, "") }
/^TASK \[utils : generate mirror manifests for / { c = $0; sub(/.*manifests for /, "", c); sub(/\].*/, "", c)
                                                  if (!(c in s)) { s[c] = 1; n++ }; cur = c }
END { print n + 0, cur }' "${_W_LOG}" 2>/dev/null)})
    PPANEL_TOTAL="${_W_TOTAL}" PPANEL_DONE="${v[1]:-0}"
    PPANEL_DETAIL="${v[2]:+mapping file - ${v[2]}}"
    [[ -n "${v[2]:-}" ]] || PPANEL_DETAIL="starting (olm-utils container, CASE metadata)"
}

# CASE packages + patch metadata for <patch>, then its mapping -> <out> (TSV).
generate_mapping() {   # <patch> <out tsv> <expected CASEs or "">
    local p="$1" out="$2" target="${TARGET}" f
    local -a flags
    common_flags "${p}"; flags=("${reply[@]}")
    _W_MARK="${RUN}/dl-start"; : > "${_W_MARK}"
    preg_info "cpd: case-download, release ${REL} $(plabel "${p}")"
    cpd_watched "cpd case-download ($(plabel "${p}"))" "${out:h}/case-download-p${p:-0}.log" _dl_probe \
        cpd-cli manage case-download --components="${COMPS}${EXTRA:+,${EXTRA}}" "${flags[@]}" \
        $(preg_is_true "${MIRROR_CPD_CASE_FROM_OCI:-true}" && print -r -- --from_oci=true) || return 1
    cpdm_apply_prunes "${REL}"
    if [[ "${PHASE}" == mirror ]]; then
        private_login
    else
        target="${STOPOVER}"   # mapping only, as 2.0's save phase; the host is dropped below
    fi
    local -a mflags=(--components="${COMPS}" "${flags[@]}" --target_registry="${target}" --case_download=false)
    [[ "${ARCH}" != all ]] && mflags+=(--arch="${ARCH}")
    preg_in_list image-groups "${CONTENT}" && [[ -n "${IMG_GROUPS}" ]] && mflags+=(--groups="${IMG_GROUPS}")
    _W_TOTAL="$3"
    preg_info "cpd: mirror-images, mapping files only ($(plabel "${p}"); nothing is pushed)"
    cpd_watched "cpd mapping ($(plabel "${p}"))" "${out:h}/mapping-p${p:-0}.log" _map_probe \
        cpdm_mapping_only "${REL}" images-mapping.txt "${mflags[@]}" || return 1
    preg_engine cpd-collect --prefix "${target}" "${WORK}/${^CPDM_MAPS[@]}" | sort -u > "${out}" \
        || preg_die "cpd: unexpected lines in the mapping files (see the warnings above)"
    preg_info "cpd: $(plabel "${p}"): $(grep -c . "${out}") mapping line(s) in ${#CPDM_MAPS} CASE(s)"
}

# --- Reports ---------------------------------------------------------------------------
write_plan_json() {   # <dir> <from> <to> <bundle>
    preg_python -c '
import json, sys, datetime
d, frm, to, bundle, rel, comps, extra, arch, groups, phase, target = sys.argv[1:12]
s = json.load(open(f"{d}/delta-summary.json"))
json.dump({"release": rel, "from": frm, "to": to, "phase": phase, "components": comps,
           "extra_cases": extra, "arch": arch, "groups": groups, "target": target, "bundle": bundle,
           "counts": s["counts"], "per_case": s["per_case"],
           "planned": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
          open(f"{d}/plan.json", "w"), indent=2, sort_keys=True)' \
        "$1" "$2" "$3" "$4" "${REL}" "${COMPS}" "${EXTRA}" "${ARCH}" "${IMG_GROUPS}" "${PHASE}" "${TARGET}"
}

report() {   # <dir> <from> <to>
    local d="$1" n
    {
        print -r -- "cpd patch update: release ${REL}, $(plabel "$2") -> $(plabel "$3")   (phase ${PHASE}, <root>/cpd = ${TARGET})"
        print -r -- ""
        if [[ -s "${d}/changed-components.tsv" ]]; then
            print -r -- "Components the patch changes (CASE version old -> new):"
            awk -F'\t' '$2 == "selected" { printf "  %-28s %-12s -> %s\n", $1, $3, $4 }' "${d}/changed-components.tsv"
            n="$(awk -F'\t' '$2 == "other"' "${d}/changed-components.tsv" | grep -c . || true)"
            (( n )) && print -r -- "  (+${n} not selected; mirrored only where a selected component depends on them)"
        else
            print -r -- "Components the patch changes: none of the selected ones (or no metadata for $(plabel "$2"))"
        fi
        print -r -- ""
        preg_python -c '
import json, sys
s = json.load(open(sys.argv[1]))
c = s["counts"]
print("Mapping lines: %(desired)d   already in the registry: %(present)d (recorded %(recorded)d, probed %(probed)d)" % c)
print("To copy: %(missing)d new, %(moved)d moved tag(s) (old digest kept as <tag>-p<from>)" % c)
if s["per_case"]:
    print("Per CASE:")
    for k, v in sorted(s["per_case"].items(), key=lambda kv: -kv[1]):
        print(f"  {k:<36} {v}")' "${d}/delta-summary.json"
        if grep -q $'\tmoved\t' "${d}/delta.tsv" 2>/dev/null; then
            print -r -- "Moved tags:"
            awk -F'\t' '$5 == "moved" { printf "  %s  (%s -> %s)\n", $4, substr($6, 8, 12), substr($3, index($3, "@") + 8, 12) }' "${d}/delta.tsv" | head -20
        fi
        [[ -f "${d}/estimate.txt" ]] && { print -r -- ""; cat "${d}/estimate.txt"; }
    } > "${d}/report.txt"
    cat "${d}/report.txt"
}

write_pending() {   # <from> <to> <dir> <bundle>
    {
        print -r -- "P_RELEASE=$(preg_q "${REL}")"
        print -r -- "P_PHASE=$(preg_q "${PHASE}")"
        print -r -- "P_FROM=$(preg_q "$1")"
        print -r -- "P_TO=$(preg_q "$2")"
        print -r -- "P_DIR=$(preg_q "$3")"
        print -r -- "P_BUNDLE=$(preg_q "$4")"
    } > "${PENDING}"
}

# =============================================================================
# plan
# =============================================================================
plan_online() {   # mirror | save
    local to from dir fdir known="" mark
    resolve_to; to="${REPLY}"
    resolve_from; from="${REPLY}"
    dir="$(pdir "${to}")" fdir="$(pdir "${from}")"
    mkdir -p "${dir}"
    preg_info "cpd: release ${REL}, $(plabel "${from}") -> $(plabel "${to}") (phase ${PHASE})"
    [[ "${from}" == "${to}" ]] && preg_info "cpd: the registry is recorded at $(plabel "${to}") already - checking what is missing$(${ALL} && print -r -- ' (--all: every line)')"
    : > "${dir}/.started"
    # cpd-cli's olm-utils for this patch (online here), not the one the tap set
    export OLM_UTILS_IMAGE="icr.io/${OLM_REPO}:${REL}.${to}${OLM_SFX}"
    write_auth

    # The mapping of <from>: recorded by an earlier update, or (save, first time)
    # generated from its CASEs - what 2.0 put into the registry.
    if ! ${ALL} && [[ -s "${fdir}/mapping.tsv" && ( -f "${fdir}/recorded.json" || -f "${fdir}/saved.json" || -f "${fdir}/assumed.json" ) ]]; then
        known="${RUN}/known.tsv"
        cp "${fdir}/mapping.tsv" "${known}"
        preg_info "cpd: $(plabel "${from}"): recorded mapping, $(grep -c . "${known}") line(s) taken as present"
    elif [[ "${PHASE}" == save ]]; then
        [[ "${from}" == "${to}" ]] && preg_die "No recorded mapping of $(plabel "${from}") to compare with - pass --from <patch the inside registry has>."
        preg_info "cpd: no recorded mapping of $(plabel "${from}") - generating it from its CASEs (taken as what the inside registry has)"
        mkdir -p "${fdir}"
        generate_mapping "${from}" "${fdir}/mapping.tsv" "" || preg_die "cpd: mapping of $(plabel "${from}") failed"
        print -r -- "{\"note\": \"generated from the $(plabel "${from}") CASE packages by 4.0 (save); assumed to be the inside registry's content\"}" > "${fdir}/assumed.json"
        known="${RUN}/known.tsv"
        cp "${fdir}/mapping.tsv" "${known}"
    fi

    local expect=""
    [[ -n "${known}" ]] && expect="$(cut -f1 "${known}" | sort -u | grep -c . || true)"
    generate_mapping "${to}" "${dir}/mapping.tsv" "${expect}" || preg_die "cpd: mapping of $(plabel "${to}") failed"

    local pyaml="${WORK}/offline/patch/patch-${REL}-${to}.yaml" oyaml=""
    [[ -f "${pyaml}" ]] || preg_die "cpd: no patch metadata ${pyaml} - is patch ${to} published for ${REL}?"
    [[ -n "${from}" && -f "${WORK}/offline/patch/patch-${REL}-${from}.yaml" ]] && oyaml="${WORK}/offline/patch/patch-${REL}-${from}.yaml"
    preg_engine patch-diff ${oyaml:+--old "${oyaml}"} --new "${pyaml}" --components "${COMPS},${EXTRA}" > "${dir}/changed-components.tsv"

    local -a dargs=(--mapping "${dir}/mapping.tsv" --out "${dir}/delta.tsv" --summary "${dir}/delta-summary.json" --jobs "${PROBE_JOBS}")
    [[ -n "${known}" ]] && dargs+=(--known "${known}")
    ${ALL} && dargs+=(--all)
    if [[ "${PHASE}" == mirror ]]; then
        dargs+=(--root "${TARGET}" --authfile "${AUTH}" "${PROBE_TLS[@]}")
        preg_info "cpd: probing the registry by digest (${PROBE_JOBS} at a time)"
    fi
    preg_engine cpd-delta "${dargs[@]}" || preg_die "cpd: the registry probe failed (errors above) - check the push credentials and the network"

    if ${ESTIMATE} && [[ -s "${dir}/delta.tsv" ]]; then
        cut -f3 "${dir}/delta.tsv" | sort -u > "${RUN}/delta-sources"
        preg_info "cpd: estimating the delta size ($(grep -c . "${RUN}/delta-sources") source image(s))"
        preg_write_authfile "${RUN}/src-auth.json" none --sources
        preg_engine inspect --refs-file "${RUN}/delta-sources" --authfile "${RUN}/src-auth.json" --sizes \
            | awk '/^SIZE/ { printf "Delta size: %.1f GB of unique layers at most (layers the registry already has are not pushed again)\n", $2 / 1e9 }' \
            > "${dir}/estimate.txt" || true
    fi

    local bundle=""
    [[ "${PHASE}" == save ]] && bundle="${BUNDLES}/cpd-${REL}-p${from:-0}-to-p${to}"
    write_plan_json "${dir}" "${from}" "${to}" "${bundle}"
    print -r -- ""
    report "${dir}" "${from}" "${to}"
    write_pending "${from}" "${to}" "${dir}" "${bundle}"
}

plan_load() {
    local b="${BUNDLE_ARG}" to from rel dir
    if [[ -z "${b}" ]]; then
        b="$(print -rl -- "${BUNDLES}"/cpd-"${REL}"-p*-to-p*(N/om[1]))"
        [[ -n "${b}" ]] || preg_die "No patch bundle in ${BUNDLES} - pass --bundle <dir> (written by 4.1 --phase=save)."
    fi
    [[ -f "${b}/plan/plan.json" ]] || preg_die "${b} is not a cpd patch bundle (no plan/plan.json)."
    preg_info "cpd: patch bundle ${b}"
    preg_engine bundle-manifest verify --dir "${b}" $(${QUICK} && print -r -- --quick) || preg_die "cpd: the bundle does not match its checksums"
    _vals=("${(@f)$(preg_python -c '
import json, sys
p = json.load(open(sys.argv[1]))
for k in ("release", "from", "to"):
    print(p.get(k, ""))
print("END")' "${b}/plan/plan.json")}")
    rel="${_vals[1]}" from="${_vals[2]}" to="${_vals[3]}"
    [[ "${rel}" == "${REL}" ]] || preg_die "The bundle is for release ${rel}, the inventory for ${REL}."
    [[ -z "${TO_ARG}" || "${TO_ARG}" == "${to}" ]] || preg_die "The bundle is for patch ${to}, not ${TO_ARG}."
    if state_has "${PATCHES}/current" && [[ "$(state_patch "${PATCHES}/current")" != "${from}" ]]; then
        preg_warn "cpd: the registry is recorded at $(plabel "$(state_patch "${PATCHES}/current")"), the bundle starts from $(plabel "${from}") - anything else missing shows up in 4.2 --full."
    fi
    dir="$(pdir "${to}")"
    mkdir -p "${dir}"
    cp "${b}/plan/mapping.tsv" "${b}/plan/changed-components.tsv" "${dir}/"
    cp "${b}/plan/delta.tsv" "${dir}/delta-bundle.tsv"
    [[ -f "${b}/plan/from-mapping.tsv" && ! -s "$(pdir "${from}")/mapping.tsv" ]] && { mkdir -p "$(pdir "${from}")"; cp "${b}/plan/from-mapping.tsv" "$(pdir "${from}")/mapping.tsv"; }
    write_auth
    # Only the bundle's lines that the registry does not have yet are pushed.
    cut -f1-4 "${dir}/delta-bundle.tsv" > "${RUN}/bundle-lines.tsv"
    preg_info "cpd: probing the registry for the bundle's $(grep -c . "${RUN}/bundle-lines.tsv") line(s)"
    preg_engine cpd-delta --mapping "${RUN}/bundle-lines.tsv" --all --root "${TARGET}" --authfile "${AUTH}" "${PROBE_TLS[@]}" \
        --jobs "${PROBE_JOBS}" --out "${dir}/delta.tsv" --summary "${dir}/delta-summary.json" \
        || preg_die "cpd: the registry probe failed (errors above)"
    write_plan_json "${dir}" "${from}" "${to}" "${b}"
    print -r -- ""
    report "${dir}" "${from}" "${to}"
    write_pending "${from}" "${to}" "${dir}" "${b}"
}

# =============================================================================
# copy
# =============================================================================
# oc image mirror's log: one "sha256:<digest> <target>" line per mapping line
# pushed, "uploading: / mounted: / skipped: <repo> <blob> <size>" per layer,
# "error: ..." per image it could not copy (it carries on).
typeset -gA PROBE_VALS
copy_case() {   # <case> - pool worker
    local c="$1" rc=0 n
    local -a args=(-a "${AUTH}" -f "${RUN}/maps/${c}.txt" --keep-manifest-list=true --filter-by-os='.*'
                   --max-per-registry="${MIRROR_CPD_PATCH_MAX_PER_REGISTRY:-2}" --skip-multiple-scopes=true --continue-on-error=true)
    case "${PHASE}" in
        mirror) args+=("${OC_TLS[@]}") ;;
        save)   mkdir -p "${BUNDLE}/images/${c}"; args+=(--dir="${BUNDLE}/images/${c}") ;;
        load)   args+=(--from-dir="${BUNDLE}/images/${c}" "${OC_TLS[@]}") ;;
    esac
    oc image mirror "${args[@]}" > "${RUN}/oc.${c}.log" 2>&1 || rc=$?
    n="$(grep -c '^error' "${RUN}/oc.${c}.log" 2>/dev/null || true)"
    (( rc == 0 && ${n:-0} == 0 )) && return 0
    cp "${RUN}/oc.${c}.log" "${DIR}/oc-${PHASE}-${c}.log"
    ppanel_job_reason "${n:-0} error line(s) - ${DIR#${_CP4D_REPO_ROOT}/}/oc-${PHASE}-${c}.log"
    return 1
}
copy_case_probe() {   # <case> <attempt> - pool probe
    local log="${RUN}/oc.${1}.log"
    if ppanel_changed "${log}"; then
        PROBE_VALS[$1]=""
        [[ -s "${log}" ]] && PROBE_VALS[$1]="$(awk '
/^sha256:[0-9a-f]+ [^ ]/          { p++; n = split($2, a, "/"); last = "pushed " a[n]; next }
/^error/                          { e++; next }
/^info: Planning completed/       { pl = 1; next }
/^info: Mirroring completed/      { last = "finishing"; next }
/^(uploading|mounted|skipped): /  { n = split($2, a, "/"); last = substr($1, 1, length($1) - 1) " " a[n] ($4 != "" ? " " $4 : "") }
END { printf "%d\t%d\t%d\t%s", p, e, pl, last }' "${log}")"
    fi
    PPANEL_DETAIL="starting"
    [[ -n "${PROBE_VALS[$1]:-}" ]] || return 0
    local -a v=("${(@ps:\t:)PROBE_VALS[$1]}")
    PPANEL_DONE="${v[1]}" PPANEL_DETAIL="planning"
    (( v[3] )) && PPANEL_DETAIL="${v[4]:-copying}"
    (( v[2] )) && PPANEL_DETAIL+=" · ${v[2]} error(s)"
    return 0
}

# Moved tags: the digest they point at now is kept as <tag>-p<from> first.
keep_moved() {
    local c v src rel st old
    while IFS=$'\t' read -r c v src rel st old; do
        [[ "${st}" == moved && -n "${old}" ]] || continue
        version_tag "${rel}" "${FROM}"
        tag_digest "${rel}" "${old}" "${REPLY}" || return 1
    done < "${DIR}/delta.tsv"
}

copy_verb() {
    load_pending
    local delta="${DIR}/delta.tsv" c
    if [[ ! -s "${delta}" ]]; then
        preg_info "cpd: nothing to copy - the registry has every image of $(plabel "${TO}")"
        [[ "${PHASE}" == save ]] || return 0
    fi
    write_auth
    [[ "${PHASE}" == save ]] && { mkdir -p "${BUNDLE}"; preg_info "cpd: patch bundle ${BUNDLE}"; }
    if [[ "${PHASE}" == load ]]; then
        # CASE packages + patch metadata, for the install's offline case-download
        [[ -d "${BUNDLE}/cpd-cli-work" ]] && preg_rsync "patch CASEs -> cpd-cli work dir" -a "${BUNDLE}/cpd-cli-work/" "${WORK}/"
    fi
    [[ "${PHASE}" == save ]] || keep_moved || preg_die "cpd: could not keep the moved tags' old digests - nothing was overwritten"

    mkdir -p "${RUN}/maps"
    if [[ -s "${delta}" ]]; then
        awk -F'\t' -v ph="${PHASE}" -v t="${TARGET}" -v d="${RUN}/maps" '
            ph == "mirror" { print $3 "=" t "/" $4 > (d "/" $1 ".txt"); next }
            ph == "save"   { print $3 "=file://" $4 > (d "/" $1 ".txt"); next }
                           { print "file://" $4 "=" t "/" $4 > (d "/" $1 ".txt") }' "${delta}"
        local -A lines
        local -a jobs
        for c in "${RUN}/maps"/*.txt(N); do lines[${c:t:r}]="$(grep -c . "${c}")"; done
        jobs=("${(@f)$(for c in "${(@k)lines}"; do print -r -- "${lines[$c]} ${c}"; done | sort -rn | cut -d' ' -f2-)}")
        preg_info "cpd: oc image mirror for ${#jobs} CASE(s), ${PARALLEL_JOBS} at a time ($(cut -f4 "${delta}" | grep -c .) image(s), ${PHASE})"
        ppanel_pool_run -j "${PARALLEL_JOBS}" -a 3 -d 30 -t "cpd patch ${TO}" -k CASEs -u images -W lines \
            -w copy_case -p copy_case_probe -- "${jobs[@]}" \
            || preg_die "cpd: ${#PPANEL_FAILED} CASE(s) failed (${(j:, :)PPANEL_FAILED}) - fix and re-run 4.1 (copied images are skipped)"
        preg_info "cpd: copied in $(ppanel_duration "${PPANEL_ELAPSED}"; print -r -- "${REPLY}")"
    fi
    [[ "${PHASE}" == save ]] && build_bundle
    return 0
}

# Patch bundle (save): images/<case>/ (oc's --dir), cpd-cli-work/ (the CASE
# versions this patch adds and its patch metadata), plan/, checksums.
build_bundle() {
    local fdir="$(pdir "${FROM}")" cases="${WORK}/offline/${REL}/.ibm-pak/data/cases" cv
    local dst="${BUNDLE}/cpd-cli-work/offline/${REL}/.ibm-pak/data/cases"
    mkdir -p "${BUNDLE}/cpd-cli-work/offline/patch" "${BUNDLE}/plan" "${dst}"
    cp "${WORK}/offline/patch/patch-${REL}-${TO}.yaml" "${BUNDLE}/cpd-cli-work/offline/patch/"
    {
        cut -f1,2 "${DIR}/mapping.tsv" | tr '\t' / | sort -u > "${RUN}/to-cases"
        if [[ -s "${fdir}/mapping.tsv" ]]; then cut -f1,2 "${fdir}/mapping.tsv" | tr '\t' / | sort -u; fi > "${RUN}/from-cases"
        comm -23 "${RUN}/to-cases" "${RUN}/from-cases"
        # CASE versions case-download added for this plan (dependencies without images too)
        for cv in "${cases}"/*/*(N/); do [[ "${cv}" -nt "${DIR}/.started" ]] && print -r -- "${cv#${cases}/}"; done
        :
    } | sort -u > "${RUN}/ship-cases"
    while read -r cv; do
        [[ -n "${cv}" && -d "${cases}/${cv}" ]] || continue
        mkdir -p "${dst}/${cv}"
        rsync -a "${cases}/${cv}/" "${dst}/${cv}/"
    done < "${RUN}/ship-cases"
    preg_info "cpd: $(grep -c . "${RUN}/ship-cases" || true) CASE version(s) + patch-${REL}-${TO}.yaml in the bundle"
    cp "${DIR}"/{plan.json,mapping.tsv,delta.tsv,changed-components.tsv,report.txt} "${BUNDLE}/plan/"
    [[ -s "${fdir}/mapping.tsv" ]] && cp "${fdir}/mapping.tsv" "${BUNDLE}/plan/from-mapping.tsv"
    cat > "${BUNDLE}/README.txt" <<EOF
IBM Software Hub ${REL}: $(plabel "${FROM}") -> $(plabel "${TO}") patch bundle for <root>/cpd
(scripts/private_registry_mirroring/4_update_cpd_patch). On the inside workstation:

  4_update_cpd_patch/4.x_full_cpd_patch_update.sh --phase=load --bundle <this dir>

(or 4.0, 4.1, 4.2 with --phase=load). It verifies the checksums, pushes only what the
registry is missing, restores the CASE packages into cpd-cli's work dir, and records
$(plabel "${TO}").
EOF
    preg_engine bundle-manifest write --dir "${BUNDLE}" --meta kind=cpd-patch --meta "release=${REL}" \
        --meta "from=${FROM}" --meta "to=${TO}"
    preg_info "cpd: bundle ready: ${BUNDLE} ($(du -sh "${BUNDLE}" | awk '{ print $1 }'))"
}

# =============================================================================
# record
# =============================================================================
record_verb() {
    load_pending
    local now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "${PHASE}" == save ]]; then
        print -r -- "{\"phase\": \"save\", \"saved\": \"${now}\", \"bundle\": \"${BUNDLE}\"}" > "${DIR}/saved.json"
        print -r -- "${REL}"$'\t'"${TO}"$'\t'save$'\t'"${now}" > "${PATCHES}/saved"
        print -r -- "${now} save   ${REL} $(plabel "${FROM}") -> $(plabel "${TO}")  ${BUNDLE}" >> "${PATCHES}/history.log"
        rm -f "${PENDING}"
        preg_info "cpd: recorded the save of $(plabel "${TO}") (the next save starts from it). Carry ${BUNDLE} inside."
        return 0
    fi
    write_auth
    local lines="${RUN}/verify.tsv" what="the delta"
    if ${FULL}; then cp "${DIR}/mapping.tsv" "${lines}"; what="every image of $(plabel "${TO}")"
    else cut -f1-4 "${DIR}/delta.tsv" > "${lines}"; fi
    if [[ -s "${lines}" ]]; then
        preg_info "cpd: verifying ${what} in the registry by digest ($(grep -c . "${lines}") line(s))"
        preg_engine cpd-delta --mapping "${lines}" --check --root "${TARGET}" --authfile "${AUTH}" "${PROBE_TLS[@]}" \
            --jobs "${PROBE_JOBS}" --out "${DIR}/verify-problems.tsv" --summary "${DIR}/verify-summary.json" \
            || preg_die "cpd: not everything is in the registry (${DIR#${_CP4D_REPO_ROOT}/}/verify-problems.tsv) - re-run 4.1"
    fi

    # Version tags: moved tags (<tag>-p<to>) and olm-utils (<release>.<to>[.<arch>]).
    local c v src rel st old
    while IFS=$'\t' read -r c v src rel st old; do
        [[ "${st}" == moved ]] || continue
        version_tag "${rel}" "${TO}"
        tag_digest "${rel}" "${src#*@}" "${REPLY}" || preg_die "cpd: version tag failed"
    done < "${DIR}/delta.tsv"
    while IFS=$'\t' read -r c v src rel; do
        [[ "${rel%:*}" == "${OLM_REPO}" ]] || continue
        version_tag "${rel}" "${TO}"
        tag_digest "${rel}" "${src#*@}" "${REPLY}" || preg_die "cpd: olm-utils version tag failed"
    done < "${DIR}/mapping.tsv"

    preg_python -c '
import json, sys
d, phase, now, frm, to, full = sys.argv[1:7]
try:
    counts = json.load(open(f"{d}/verify-summary.json"))["counts"]
except (OSError, ValueError):
    counts = {}
json.dump({"phase": phase, "recorded": now, "from": frm, "to": to,
           "verified": "full" if full == "true" else "delta", "counts": counts},
          open(f"{d}/recorded.json", "w"), indent=2, sort_keys=True)' "${DIR}" "${PHASE}" "${now}" "${FROM}" "${TO}" "${FULL}"
    print -r -- "${REL}"$'\t'"${TO}"$'\t'"${PHASE}"$'\t'"${now}" > "${PATCHES}/current"
    print -r -- "${now} ${PHASE} ${REL} $(plabel "${FROM}") -> $(plabel "${TO}")  $(cut -f4 "${DIR}/delta.tsv" | grep -c . || true) image(s) copied" >> "${PATCHES}/history.log"
    rm -f "${PENDING}"

    # 1.0's outputs follow, so 2.0 / 2.4 (and the next 1.0 from cpd_vars.sh) agree.
    preg_python -c '
import json, re, sys
patch = sys.argv[1]
def fix(n):
    if n.get("handler") != "cpd-cli":
        return n
    n["patch_id"] = patch
    s, rel = n.get("summary", ""), n.get("release", "")
    if " patch " in s:
        s = re.sub(r" patch [^,]+,", " patch %s," % patch, s)
    else:
        s = s.replace("release %s," % rel, "release %s patch %s," % (rel, patch))
    n["summary"] = s
    return n
nat, inv = sys.argv[2], sys.argv[3]
rows = [fix(json.loads(l)) for l in open(nat) if l.strip()]
open(nat, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
try:
    data = json.load(open(inv))
except OSError:
    sys.exit(0)
for k, v in (data.get("native") or {}).items():
    data["native"][k] = [fix(n) for n in v]
json.dump(data, open(inv, "w"), indent=2, sort_keys=True)
open(inv, "a").write("\n")' "${TO}" "${NATIVE}" "${MIRROR_WORKSPACE}/inventory/inventory.json"
    preg_info "cpd: <root>/cpd is recorded at $(plabel "${TO}") (native.jsonl / inventory.json follow)"
    if [[ -n "${PATCH_ID:-}" && "${PATCH_ID}" != "${TO}" ]]; then
        preg_warn "cpd: cpd_vars.sh still has PATCH_ID=${PATCH_ID} - set it to ${TO} before installing or upgrading."
    fi
}

# =============================================================================
# list
# =============================================================================
list_verb() {
    local cur saved
    cur="$(state_patch "${PATCHES}/current")" saved="$(state_patch "${PATCHES}/saved")"
    print -r -- "Release ${REL}, <root>/cpd = ${TARGET}"
    if state_has "${PATCHES}/current"; then
        print -r -- "Registry recorded at: $(plabel "${cur}")"
    else
        print -r -- "Registry recorded at: nothing yet (1.0 / 2.0 mapped $(plabel "${N_PATCH}"))"
    fi
    state_has "${PATCHES}/saved" && print -r -- "Last save (stop-over): $(plabel "${saved}")"
    [[ -f "${PENDING}" ]] && { source "${PENDING}"; print -r -- "Pending plan: $(plabel "${P_FROM}") -> $(plabel "${P_TO}") (${P_PHASE}) - continue with 4.1 / 4.2"; }
    print -r -- ""
    preg_python -c '
import json, os, sys
root, rel = sys.argv[1], sys.argv[2]
rows = []
for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
    p = os.path.join(root, d)
    if not (os.path.isdir(p) and d.startswith(rel + "-p")):
        continue
    def load(name):
        try:
            return json.load(open(os.path.join(p, name)))
        except (OSError, ValueError):
            return None
    plan, rec, saved, assumed = load("plan.json"), load("recorded.json"), load("saved.json"), load("assumed.json")
    state = ("recorded " + rec["recorded"][:10] + " (" + rec["phase"] + ", verified " + rec["verified"] + ")") if rec else \
            ("saved " + saved["saved"][:10]) if saved else ("assumed (generated from its CASEs)" if assumed else "planned")
    lines = sum(1 for _ in open(os.path.join(p, "mapping.tsv"))) if os.path.isfile(os.path.join(p, "mapping.tsv")) else 0
    c = (plan or {}).get("counts", {})
    delta = "%d new + %d moved" % (c.get("missing", 0), c.get("moved", 0)) if plan else "-"
    frm = (plan or {}).get("from", "")
    rows.append((d[len(rel) + 2:], state, lines, ("p" + (frm or "0")) if plan else "-", delta))
rows.sort(key=lambda r: int(r[0]) if r[0].isdigit() else -1)
fmt = "%-6s %-48s %6s  %-5s %s"
print(fmt % ("patch", "state", "lines", "from", "delta"))
for r in rows:
    print(fmt % r)' "${PATCHES}" "${REL}"
    [[ -f "${PATCHES}/history.log" ]] && { print -r -- ""; print -r -- "History:"; tail -n 10 "${PATCHES}/history.log" | sed 's/^/  /'; }
    return 0
}

case "${VERB}" in
    plan)
        case "${PHASE}" in
            mirror|save) plan_online ;;
            load) plan_load ;;
            *) preg_die "phase must be mirror, save or load (got '${PHASE}')" ;;
        esac ;;
    copy)   copy_verb ;;
    record) record_verb ;;
    list)   list_verb ;;
    *) preg_die "usage: $0 plan|copy|record|list [--phase=mirror|save|load] [--to N] [--from N] [--all] [--full] [--estimate] [--bundle DIR] [--quick]" ;;
esac

exit 0
