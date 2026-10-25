#!/bin/zsh
# =============================================================================
# private_registry_helpers.sh - shared functions for scripts/private_registry_mirroring
# -----------------------------------------------------------------------------
# How scripts use it (after the env_bootstrap line):
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
#     preg_require_config
#
# Sections:
#   - logging / small utilities / python
#   - installs: the per-install metadata (0_initial_setup/installs/<id>.conf),
#     registry paths, selections, and running a segment's install hook
#   - registry: image source (detect), pull/push roots, auth files, probes
#   - phases (mirror | save | load) and the transfer bundle
#   - tools: oc-mirror (native on Linux, container elsewhere); cpd-cli
#     list-images and rsync with a progress row
#   - cluster: login through an install's config, waits
#   - hook output: preg_emit_* (JSON lines on file descriptor 3)
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _PREG_HELPERS_LOADED.
#   - Mirror-track settings all start with MIRROR_, so they never clash with an
#     install's own variables (PRIVATE_REGISTRY_LOCATION, VERSION, ...).
#   - Credentials never reach argv: auth files are written by Python from
#     environment variable names, 0600, in a private tmpdir.
#   - Registry roots: the PULL root (MIRROR_REGISTRY_ROOT) is what the cluster
#     uses; the PUSH root is what this workstation uses (it differs only for
#     ICR private endpoints pushed "from local", see registry_classifier.py).
# =============================================================================

[[ -n "${_PREG_HELPERS_LOADED:-}" ]] && return 0
_PREG_HELPERS_LOADED=1

export MIRROR_WORKSPACE="${MIRROR_WORKSPACE:-${_CP4D_REPO_ROOT}/registry_mirror_workspace}"
PREG_TRACK_DIR="${_CP4D_REPO_ROOT}/scripts/private_registry_mirroring"
PREG_ENGINE="${_CP4D_REPO_ROOT}/src/helpers/registry_mirror_engine.py"
PREG_CLASSIFIER="${_CP4D_REPO_ROOT}/src/helpers/registry_classifier.py"
PREG_MANAGED_BY="private-registry-mirroring"

source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/version_resolver.sh"

# =============================================================================
# Logging / small utilities
# =============================================================================
preg_info()  { h_info "$@"; }
preg_warn()  { h_warn "$@"; }
preg_error() { h_error "$@"; }
preg_die()   { h_die "$@"; }
preg_is_true() { h_is_true "$@"; }

preg_require_vars() {
    h_missing_vars "$@" || preg_die "Missing values: ${REPLY} (configs/registry_mirror_config/registry_mirror_vars.sh)"
}

# Comma- or space-separated list -> one item per line (empty items dropped).
preg_split() {
    local items=(${(s: :)${1//,/ }})
    (( ${#items} )) && print -rl -- "${items[@]}"
    return 0
}

# Is <item> in the comma/space list <list>?
preg_in_list() {
    local item="$1" list="$2" x
    for x in ${(s: :)${list//,/ }}; do [[ "${x}" == "${item}" ]] && return 0; done
    return 1
}

# The repo's virtualenv has PyYAML/Jinja2; plain python3 is enough for the engine.
preg_python() {
    if [[ -x "${_CP4D_REPO_ROOT}/.venv/bin/python" ]]; then
        "${_CP4D_REPO_ROOT}/.venv/bin/python" "$@"
    else
        python3 "$@"
    fi
}
preg_engine()     { preg_python -I "${PREG_ENGINE}" "$@"; }
preg_classifier() { preg_python -I "${PREG_CLASSIFIER}" "$@"; }

# Private scratch dir under the (gitignored) workspace.
preg_private_tmpdir() { h_private_tmpdir "${MIRROR_WORKSPACE}"; }
preg_sha256() { h_sha256 "$@"; }

# Every track step calls this right after loading the env.
preg_require_config() {
    if [[ -z "${MIRROR_CONFIG_VERSION:-}" ]]; then
        preg_die "No mirror config loaded. Create it with scripts/private_registry_mirroring/0_initial_setup/0.0_generate_mirror_config.sh"
    fi
    # Install hooks without an install config of their own load this file instead.
    export MIRROR_CONFIG_FILE_PATH="${ENV_TARGET_FILE:-${CONFIGS_ROOT}/registry_mirror_config/registry_mirror_vars.sh}"
}

# =============================================================================
# Installs
# =============================================================================
# Known installs = 0_initial_setup/installs/<id>.conf (excluding _template).
preg_known_installs() {
    local f
    for f in "${PREG_TRACK_DIR}"/0_initial_setup/installs/*.conf(N); do
        [[ "${f:t:r}" == _* ]] || print -r -- "${f:t:r}"
    done
}

# preg_install_conf <id> <KEY> -> value from installs/<id>.conf (KEY="value" lines)
preg_install_conf() {
    local f="${PREG_TRACK_DIR}/0_initial_setup/installs/$1.conf"
    [[ -f "${f}" ]] || return 1
    awk -F= -v k="$2" '$1 == k { v = substr($0, index($0, "=") + 1); gsub(/^"|"$/, "", v); print v; exit }' "${f}"
}

# cpd -> CPD, datastax_mc -> DATASTAX_MC
preg_id_upper() { print -r -- "${(U)1//-/_}"; }

# Selected installs (MIRROR_INSTALLS), validated. "shared" is implicit and always last.
preg_installs() {
    local id known=("${(@f)$(preg_known_installs)}")
    for id in ${(s: :)${MIRROR_INSTALLS//,/ }}; do
        [[ "${id}" == shared ]] && continue
        (( ${known[(Ie)${id}]} )) || preg_die "MIRROR_INSTALLS: unknown install '${id}' (known: ${known[*]})"
        print -r -- "${id}"
    done
}

# Registry path of an install: MIRROR_<ID>_REGISTRY_PATH, else its .conf default.
preg_install_path() {
    local up="$(preg_id_upper "$1")" var
    var="MIRROR_${up}_REGISTRY_PATH"
    print -r -- "${(P)var:-$(preg_install_conf "$1" INSTALL_REGISTRY_PATH_DEFAULT)}"
}

preg_install_selection() {   # <id> COMPONENTS|CONTENT
    local var="MIRROR_$(preg_id_upper "$1")_$2"
    print -r -- "${(P)var:-}"
}

# Has the install selected content kind <kind>? (MIRROR_<ID>_CONTENT)
preg_has_content() { preg_in_list "$2" "$(preg_install_selection "$1" CONTENT)"; }
preg_has_component() { preg_in_list "$2" "$(preg_install_selection "$1" COMPONENTS)"; }

# Config file an install hook should load: the install's own *_vars.sh when it
# exists, otherwise the mirror config itself (hooks then see only MIRROR_*).
preg_install_env_target() {
    local target="$(preg_install_conf "$1" INSTALL_ENV_TARGET)" f
    if [[ -n "${target}" ]]; then
        for f in "${CONFIGS_ROOT}"/*/"${target}"_vars.sh(N); do
            print -r -- "${target}"
            return 0
        done
    fi
    print -r -- "${MIRROR_CONFIG_FILE_PATH:-registry_mirror}"
}

# preg_run_hook <segment dir name> <id> <verb> [args...]
#   Runs <segment>/installs/<id>.sh <verb> [args] as a child process with the
#   install's config loaded. A missing hook means nothing install-specific is
#   needed in that segment. Exported for the child: MIRROR_INSTALL_ID/PATH/
#   WORKDIR/PULL_PREFIX/PUSH_PREFIX. Callers redirect fd 3 for map output.
preg_run_hook() {
    local segment="$1" id="$2" verb="$3"
    shift 3
    local hook="${PREG_TRACK_DIR}/${segment}/installs/${id}.sh"
    if [[ ! -f "${hook}" ]]; then
        return 0
    fi
    # Not "path": in zsh that is the PATH array.
    local rpath target pull push src
    rpath="$(preg_install_path "${id}")"
    target="$(preg_install_env_target "${id}")"
    # Best effort: mapping must work before a registry is configured.
    pull="$(preg_pull_root 2>/dev/null)" || pull=""
    push="$(preg_push_root 2>/dev/null)" || push=""
    src="$(preg_image_source 2>/dev/null)" || src=""
    (
        export ENV_TARGET="${target}"
        export MIRROR_INSTALL_ID="${id}" MIRROR_INSTALL_PATH="${rpath}"
        export MIRROR_INSTALL_WORKDIR="${MIRROR_WORKSPACE}/${rpath}"
        export MIRROR_INSTALL_PULL_PREFIX="${pull:+${pull}/${rpath}}"
        export MIRROR_INSTALL_PUSH_PREFIX="${push:+${push}/${rpath}}"
        export MIRROR_RESOLVED_IMAGE_SOURCE="${src}" MIRROR_RESOLVED_PUSH_ROOT="${push}"
        mkdir -p "${MIRROR_INSTALL_WORKDIR}"
        zsh "${PREG_TRACK_DIR}/${segment}/installs/${id}.sh" "${verb}" "$@"
    )
}

# =============================================================================
# Registry: image source, roots, auth
# =============================================================================
preg_local_state_file() { print -r -- "${MIRROR_WORKSPACE}/local-registry/state.env"; }

# Pull root = MIRROR_REGISTRY_ROOT, or the running local registry when empty.
preg_pull_root() {
    if [[ -n "${MIRROR_REGISTRY_ROOT:-}" ]]; then
        print -r -- "${MIRROR_REGISTRY_ROOT%/}"
        return 0
    fi
    local state="$(preg_local_state_file)"
    if [[ -f "${state}" ]]; then
        local h p ns
        h="$(awk -F= '$1=="LOCAL_REGISTRY_HOST"{print $2}' "${state}")"
        p="$(awk -F= '$1=="LOCAL_REGISTRY_PORT"{print $2}' "${state}")"
        ns="$(awk -F= '$1=="LOCAL_REGISTRY_NAMESPACE"{print $2}' "${state}")"
        print -r -- "${h}:${p}${ns:+/${ns}}"
        return 0
    fi
    preg_die "MIRROR_REGISTRY_ROOT is empty and no local registry is running (0.3_local_registry.sh up)."
}

preg_push_root() {
    if [[ -n "${MIRROR_REGISTRY_PUSH_ROOT:-}" ]]; then
        print -r -- "${MIRROR_REGISTRY_PUSH_ROOT%/}"
    elif [[ -n "${_PREG_PUSH_ROOT_CACHE:-}" ]]; then
        print -r -- "${_PREG_PUSH_ROOT_CACHE}"
    else
        _PREG_PUSH_ROOT_CACHE="$(preg_classifier push-root "$(preg_pull_root)" "${MIRROR_REGISTRY_PUSH_FROM:-local}")"
        print -r -- "${_PREG_PUSH_ROOT_CACHE}"
    fi
}

preg_registry_host() { print -r -- "${1%%/*}"; }

# private | local. MIRROR_IMAGE_SOURCE=auto asks the classifier.
preg_image_source() {
    local s="${MIRROR_IMAGE_SOURCE:-auto}"
    if [[ "${s}" == auto && -n "${_PREG_IMAGE_SOURCE_CACHE:-}" ]]; then
        s="${_PREG_IMAGE_SOURCE_CACHE}"
    elif [[ "${s}" == auto ]]; then
        local verdict
        verdict="$(preg_classifier classify "$(preg_pull_root)" --local-state "$(preg_local_state_file)")"
        s="${verdict%%$'\t'*}"
        [[ "${s}" == unknown ]] && preg_die "Cannot tell whether $(preg_pull_root) is a local or a cloud registry (${verdict#*$'\t'}). Set MIRROR_IMAGE_SOURCE=private or local."
        _PREG_IMAGE_SOURCE_CACHE="${s}"
    fi
    [[ "${s}" == (private|local) ]] || preg_die "MIRROR_IMAGE_SOURCE must be auto, private or local (got '${s}')."
    print -r -- "${s}"
}

# Resolve image source and push root once, in the calling shell, and export the
# results: $(...) subshells and install hooks then reuse them instead of asking
# the classifier again.
preg_resolve_registry() {
    local s p
    s="$(preg_image_source)" || exit 1
    p="$(preg_push_root)" || exit 1
    export _PREG_IMAGE_SOURCE_CACHE="${s}" _PREG_PUSH_ROOT_CACHE="${p}"
}

# Mirror-set policy: local registries are the only source (air-gapped).
preg_policy() { [[ "$(preg_image_source)" == local ]] && print -r -- never || print -r -- allow; }

# auto -> true for local (air-gapped), false for private.
preg_auto_bool() {
    local v="${1:-auto}"
    if [[ "${v}" == auto ]]; then
        [[ "$(preg_image_source)" == local ]] && print -r -- true || print -r -- false
    else
        preg_is_true "${v}" && print -r -- true || print -r -- false
    fi
}

# preg_write_authfile <file> <push|pull|none> [--sources]
#   Host-level entries (one credential for every install path; IBM's
#   login-private-registry would scope it to one path). "none" = no target
#   registry entry. --sources adds the source registries: Red Hat pull secret,
#   cp.icr.io (entitlement key), Docker Hub.
preg_write_authfile() {
    local file="$1" side="${2:-push}" sources=false
    [[ "${3:-}" == --sources ]] && sources=true
    local root host merge=() entries=()
    if [[ "${side}" == pull ]]; then
        root="$(preg_pull_root)"; host="$(preg_registry_host "${root}")"
        entries+=("${host}=MIRROR_REGISTRY_PULL_USER:MIRROR_REGISTRY_PULL_PASSWORD")
    elif [[ "${side}" == push ]]; then
        root="$(preg_push_root)"; host="$(preg_registry_host "${root}")"
        entries+=("${host}=MIRROR_REGISTRY_PUSH_USER:MIRROR_REGISTRY_PUSH_PASSWORD")
    fi
    if ${sources}; then
        [[ -n "${MIRROR_REDHAT_PULL_SECRET_FILE:-}" && -f "${MIRROR_REDHAT_PULL_SECRET_FILE}" ]] && merge+=(--merge "${MIRROR_REDHAT_PULL_SECRET_FILE}")
        export PREG_CP_USER=cp
        entries+=("cp.icr.io=PREG_CP_USER:MIRROR_IBM_ENTITLEMENT_KEY")
        entries+=("docker.io=MIRROR_DOCKERHUB_USER:MIRROR_DOCKERHUB_TOKEN")
    fi
    local args=() e
    for e in "${entries[@]}"; do args+=(--entry "${e}"); done
    preg_engine authfile --out "${file}" "${merge[@]}" "${args[@]}" >/dev/null
}

# HTTP status of <root>/v2/ (000 = unreachable). Optional CA file.
preg_probe_registry() {
    local root="$1" ca="${2:-}" host
    host="$(preg_registry_host "${root}")"
    local args=(-s -o /dev/null -m 10 -w '%{http_code}') code
    if [[ -n "${ca}" && -f "${ca}" ]]; then args+=(--cacert "${ca}")
    elif preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}"; then args+=(-k); fi
    # curl prints 000 itself on a TLS/connection failure (and exits non-zero)
    code="$(curl "${args[@]}" "https://${host}/v2/" 2>/dev/null || true)"
    print -r -- "${code:-000}"
}

# skopeo --cert-dir for a registry with its own CA (MIRROR_REGISTRY_CA_FILE):
# prints the directory, or nothing when the registry uses public TLS.
preg_cert_dir() {
    [[ -n "${MIRROR_REGISTRY_CA_FILE:-}" && -f "${MIRROR_REGISTRY_CA_FILE}" ]] || return 0
    local d="${MIRROR_WORKSPACE}/.certs"
    mkdir -p "${d}"
    cp "${MIRROR_REGISTRY_CA_FILE}" "${d}/ca.crt"
    print -r -- "${d}"
}

# oc image mirror has no CA option: a registry with its own CA (or an insecure
# one) is reached with --insecure=true, as IBM's mirror-images always does.
preg_oc_insecure() {
    if [[ -n "${MIRROR_REGISTRY_CA_FILE:-}" ]] || preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}"; then
        print -r -- "--insecure=true"
    fi
}

# skopeo options to reach the target registry (push side).
preg_skopeo_target_opts() {
    local d
    d="$(preg_cert_dir)"
    if preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}"; then print -r -- "--tls-verify=false"
    elif [[ -n "${d}" ]]; then print -r -- "--cert-dir=${d}"; fi
}

# Same for skopeo copy's destination side (--dest-*).
preg_skopeo_dest_opts() {
    local d
    d="$(preg_cert_dir)"
    if preg_is_true "${MIRROR_REGISTRY_INSECURE:-false}"; then print -r -- "--dest-tls-verify=false"
    elif [[ -n "${d}" ]]; then print -r -- "--dest-cert-dir=${d}"; fi
}

preg_probe_internet() {
    local code
    code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' https://cp.icr.io/v2/ 2>/dev/null || true)"
    [[ "${code}" == (200|401) ]]
}

# =============================================================================
# Phases and the transfer bundle
# =============================================================================
preg_bundle_dir() { print -r -- "${MIRROR_BUNDLE_DIR:-${MIRROR_WORKSPACE}/bundle}"; }

# preg_resolve_phase [explicit] -> mirror | save | load
#   explicit (from --phase=) wins, then MIRROR_PHASE, then detection:
#   internet + registry -> mirror; internet only -> save; registry only -> load.
preg_resolve_phase() {
    local p="${1:-${MIRROR_PHASE:-auto}}"
    if [[ "${p}" == auto ]]; then
        local net=false reg=false code
        preg_probe_internet && net=true
        code="$(preg_probe_registry "$(preg_push_root)" "${MIRROR_REGISTRY_CA_FILE:-}")"
        [[ "${code}" == (200|401) ]] && reg=true
        if ${net} && ${reg}; then p=mirror
        elif ${net}; then p=save
        elif ${reg}; then p=load
        else preg_die "Neither the internet (cp.icr.io) nor the registry $(preg_push_root) is reachable from here."
        fi
        preg_info "Phase: ${p} (internet reachable: ${net}, registry reachable: ${reg})" >&2
    fi
    [[ "${p}" == (mirror|save|load) ]] || preg_die "Phase must be mirror, save or load (got '${p}')."
    if [[ "${p}" != mirror && "${MIRROR_TRANSPORT:-direct}" != stopover ]]; then
        preg_die "Phase '${p}' needs MIRROR_TRANSPORT=stopover (the registry is not reachable from the internet side)."
    fi
    print -r -- "${p}"
}

# Parse --phase=... from a script's arguments into PREG_PHASE (others kept in PREG_ARGS).
preg_parse_phase_args() {
    PREG_PHASE_ARG="" PREG_ARGS=()
    local a
    for a in "$@"; do
        case "${a}" in
            --phase=*) PREG_PHASE_ARG="${a#*=}" ;;
            *) PREG_ARGS+=("${a}") ;;
        esac
    done
}

# =============================================================================
# Tools
# =============================================================================
preg_tools_dir() { print -r -- "${MIRROR_WORKSPACE}/tools"; }

# Arch suffix of the olm-utils tag: none by default (the tag is a manifest list,
# like cpd_vars.sh's <version>.<patch>), ".<arch>" only when one is specified -
# MIRROR_CPD_ARCH (not "all"), or an arch-suffixed OLM_UTILS_IMAGE in cpd_vars.sh.
preg_olm_arch_suffix() {
    local a="${MIRROR_CPD_ARCH:-}" tag="${OLM_UTILS_IMAGE:-}"
    tag="${tag##*:}"
    if [[ -z "${a}" || "${a}" == all ]]; then
        a=""
        [[ "${tag}" == *.(amd64|arm64|ppc64le|s390x) ]] && a="${tag##*.}"
    fi
    print -r -- "${a:+.${a}}"
}

# cpd-cli manage list-images with one progress row (progress_panel_helpers.sh);
# its own output goes to <log>. Its playbook writes a mapping file per CASE,
# then (--target_registry / --inspect_source_registry=true) it skopeo-inspects
# every mapping line into list_images.csv and prints nothing until the end -
# 45 min for a full watsonx set. A CASE shared by components is inspected once
# per component, so the total is IBM's own per-component CASE list
# (find_case_info.py with the run's metadata file), read in the olm-utils
# container by podman exec only: any other cpd-cli manage call restarts the
# container and kills the run.
preg_cpd_list_images() {   # <title> <log> <list-images args...>
    local title="$1" log="$2" a rc=0
    shift 2
    source "${_CP4D_REPO_ROOT}/src/helpers/progress_panel_helpers.sh"
    _PREG_LI_WORK="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}" _PREG_LI_C="${OLM_UTILS_CONTAINER:-olm-utils-play-v4}"
    _PREG_LI_LOG="${log}" _PREG_LI_COMPS="" _PREG_LI_REL="" _PREG_LI_SKIP="" _PREG_LI_MAP=images-mapping.txt
    for a in "$@"; do
        case "${a}" in
            --components=*) _PREG_LI_COMPS="${a#*=}" ;;
            --release=*) _PREG_LI_REL="${a#*=}" ;;
            --skip_components=*) _PREG_LI_SKIP="${a#*=}" ;;
            --target_registry=*) _PREG_LI_MAP=images-mapping-from-registry.txt ;;
        esac
    done
    _PREG_LI_CASES="$(preg_private_tmpdir)/cases" _PREG_LI_TRY=0 _PREG_LI_TOTAL=""
    _PREG_LI_MARK="${_PREG_LI_WORK}/.preg-list-images-start"
    : > "${_PREG_LI_MARK}"
    mkdir -p "${log:h}"
    : > "${log}"
    preg_info "${title}: cpd-cli manage list-images (output: ${log#${_CP4D_REPO_ROOT}/})"
    ppanel_watch_start -p _preg_li_probe -t "${title}" -u images
    cpd-cli manage list-images "$@" > "${log}" 2>&1 || rc=$?
    ppanel_watch_stop
    rm -rf -- "${_PREG_LI_MARK}" "${_PREG_LI_CASES:h}"
    # cpd-cli's own lines ("[SUCCESS] 2026-...Z ..."), not ansible's
    sed -E $'s/\e\\[[0-9;]*m//g; s/\r$//' "${log}" | grep -E '^\[(SUCCESS|WARN|WARNING|ERROR)\] [0-9]{4}-[0-9]{2}-[0-9]{2}T' || true
    if (( rc )); then
        sed -E $'s/\e\\[[0-9;]*m//g; s/\r$//' "${log}" | tail -n 20 >&2
        preg_error "${title}: list-images failed (exit ${rc}) - full output: ${log}"
    fi
    return "${rc}"
}

# Background: the CASE list list-images inspects, in its order (one line per
# component; utils.sh check_and_add_zen adds zen next to cpd_platform).
_preg_li_cases_job() {
    local comps="${(j: :)${(s:,:)_PREG_LI_COMPS}}"
    [[ ",${_PREG_LI_COMPS}," == *,cpd_platform,* && ",${_PREG_LI_COMPS}," != *,zen,* ]] && comps+=" zen"
    podman exec "${_PREG_LI_C}" sh -c 'cd /opt/ansible/ansible-play/config-vars || exit 1
md="$(find . -maxdepth 1 -name "list-images-*.yaml" -newer /tmp/work/'"${_PREG_LI_MARK:t}"' | head -1)"
[ -n "${md}" ] || exit 1
for c in '"${comps}"'; do
    python3 /opt/ansible/bin/find_case_info.py --component "${c}" --release '"${_PREG_LI_REL}"' --metadata_filename="${md#./}" --skip_components='"${_PREG_LI_SKIP}"' || exit 1
done' > "${_PREG_LI_CASES}.tmp" 2>/dev/null && mv -f "${_PREG_LI_CASES}.tmp" "${_PREG_LI_CASES}"
}

# Probe (in the drawer): stage from the log, then CASEs manifested / lines inspected.
_preg_li_probe() {
    local -a v cases
    local c n csv="${_PREG_LI_WORK}/offline/${_PREG_LI_REL}/list_images.csv"
    v=("${(@ps:\t:)$(awk '
{ gsub(/\033\[[0-9;]*m/, ""); sub(/\r$/, "") }
/^PLAY \[/ && !st                               { st = 1 }
/^TASK \[utils : generate mirror manifests for / { c = $0; sub(/.*manifests for /, "", c); sub(/\].*/, "", c)
                                                  if (!(c in seen)) { seen[c] = 1; n++ }; cur = c }
/^========logging to/                           { st = 2 }
/^========manifest info logged/                 { st = 3 }
END { printf "%d\t%d\t%s", st, n, cur }' "${_PREG_LI_LOG}" 2>/dev/null)}")
    if (( ${v[1]:-0} == 0 )); then
        PPANEL_DETAIL="starting (olm-utils container, CASE metadata)"
        return 0
    fi
    # the CASE list, once the run's metadata file exists (retried every 15 s)
    if [[ ! -s "${_PREG_LI_CASES}" ]] && (( EPOCHSECONDS >= _PREG_LI_TRY )); then
        _PREG_LI_TRY=$(( EPOCHSECONDS + 15 ))
        _preg_li_cases_job &!
    fi
    [[ -s "${_PREG_LI_CASES}" ]] && cases=(${=$(<"${_PREG_LI_CASES}")})
    case "${v[1]}" in
        1)  PPANEL_UNITS=CASEs PPANEL_DONE="${v[2]}" PPANEL_DETAIL="playbook${v[3]:+: mapping files - ${v[3]}}"
            (( ${#cases} )) && PPANEL_TOTAL="${#${(@u)cases}}" ;;
        2)  if [[ -z "${_PREG_LI_TOTAL}" ]] && (( ${#cases} )); then
                _PREG_LI_TOTAL=0
                for c in "${cases[@]}"; do
                    n="$(grep -c . "${_PREG_LI_WORK}/offline/${_PREG_LI_REL}/.ibm-pak/data/mirror/${c}/${_PREG_LI_MAP}" 2>/dev/null)"
                    (( _PREG_LI_TOTAL += ${n:-0} ))
                done
            fi
            v=(${=$(awk 'NF && !/level=/ && !/^[ \t"]/ { n++ } /level=fatal/ { f++ } END { print n + 0, f + 0 }' "${csv}" 2>/dev/null)})
            PPANEL_TOTAL="${_PREG_LI_TOTAL}" PPANEL_DONE="${v[1]:-0}" PPANEL_DETAIL="skopeo inspect per image"
            (( ${v[2]:-0} )) && PPANEL_DETAIL+=" · ${v[2]} level=fatal" ;;
        *)  PPANEL_TOTAL="${_PREG_LI_TOTAL}" PPANEL_DONE="${_PREG_LI_TOTAL}" PPANEL_DETAIL="finishing" ;;
    esac
    return 0
}

# rsync with one progress row: the destination's size against the source's
# (du, every 5 s - excluded paths count in the source, so it may end below 100%).
preg_rsync() {   # <title> <rsync args...> <src/> <dst/>
    local title="$1" log rc=0
    shift
    source "${_CP4D_REPO_ROOT}/src/helpers/progress_panel_helpers.sh"
    _PREG_RS_DST="${@[-1]}" _PREG_RS_SRC_KB="$(du -sk "${@[-2]}" 2>/dev/null | awk '{ print $1 }')"
    log="$(preg_private_tmpdir)/rsync.log"
    ppanel_watch_start -p _preg_rsync_probe -t "${title}" -u MB -i 5
    rsync "$@" > "${log}" 2>&1 || rc=$?
    ppanel_watch_stop
    (( rc == 0 )) || { tail -n 20 "${log}" >&2; preg_error "${title}: rsync failed (exit ${rc})"; }
    rm -rf -- "${log:h}"
    return "${rc}"
}

_preg_rsync_probe() {
    local -i kb
    kb="$(du -sk "${_PREG_RS_DST}" 2>/dev/null | awk '{ print $1 }')"
    if (( ${_PREG_RS_SRC_KB:-0} >= 10 * 1024 * 1024 )); then
        PPANEL_UNITS=GB PPANEL_DONE=$(( kb / 1048576 )) PPANEL_TOTAL=$(( _PREG_RS_SRC_KB / 1048576 ))
    else
        PPANEL_DONE=$(( kb / 1024 )) PPANEL_TOTAL=$(( ${_PREG_RS_SRC_KB:-0} / 1024 ))
    fi
}

# Tags of <repo> matching <pattern> (a Python regex whose groups are the numeric
# version parts), oldest first, comma-separated: the newest <n>, or all with n=0.
# Lists with the source credentials; fails loudly so nothing is skipped silently.
preg_version_tags() {   # <repo> <n> <pattern>
    _preg_newest_tags() {
        local tmp rc=0
        tmp="$(preg_private_tmpdir)"
        preg_write_authfile "${tmp}/auth.json" none --sources
        vr_newest_tags "$1" "$2" "$3" "${tmp}/auth.json" || rc=$?
        rm -rf "${tmp}"
        return "${rc}"
    }
    vr_try "tags of $1" _preg_newest_tags "$1" "$2" "$3" -- legacy_preg_version_tags "$1" "$2" "$3"
}

# Architecture of the machine that runs Linux tools: this host on Linux, the
# podman VM elsewhere (arm64 on Apple Silicon).
preg_linux_arch() {
    local m
    if [[ "$(uname -s)" == Linux ]]; then m="$(uname -m)"
    else m="$(podman info --format '{{.Host.Arch}}' 2>/dev/null || uname -m)"; fi
    case "${m}" in
        x86_64|amd64) print -r -- amd64 ;;
        aarch64|arm64) print -r -- arm64 ;;
        *) print -r -- "${m}" ;;
    esac
}

# oc-mirror binary for Linux (downloaded by 0.2).
preg_oc_mirror_binary() { print -r -- "$(preg_tools_dir)/linux-$(preg_linux_arch)/oc-mirror"; }

# preg_oc_mirror <workdir> <args...>
#   Paths inside <args> must be below <workdir>, MIRROR_WORKSPACE or the bundle
#   dir; they are mounted at the same paths in the container.
preg_oc_mirror() {
    local workdir="$1"; shift
    if [[ "$(uname -s)" == Linux ]]; then
        local bin="$(command -v oc-mirror 2>/dev/null || preg_oc_mirror_binary)"
        [[ -x "${bin}" ]] || preg_die "oc-mirror not found - run 0_initial_setup/0.2_fetch_mirror_tools.sh"
        HOME="${workdir}" "${bin}" "$@"
        return
    fi
    local bin="$(preg_oc_mirror_binary)"
    [[ -x "${bin}" ]] || preg_die "oc-mirror (linux) not found at ${bin} - run 0_initial_setup/0.2_fetch_mirror_tools.sh"
    # The whole workspace (ImageSetConfiguration, auth file) at the same path,
    # plus workdir / bundle when they live elsewhere.
    local mounts=(-v "${MIRROR_WORKSPACE}:${MIRROR_WORKSPACE}" -v "${bin}:/usr/local/bin/oc-mirror:ro")
    [[ "${workdir}" == "${MIRROR_WORKSPACE}"/* ]] || mounts+=(-v "${workdir}:${workdir}")
    local b="$(preg_bundle_dir)"
    [[ "${b}" == "${MIRROR_WORKSPACE}"* || ! -d "${b}" ]] || mounts+=(-v "${b}:${b}")
    # --network host: the podman VM's network, so a local registry published on
    # it (0.3, localhost:<port>) is reachable like from the Mac itself.
    podman run --rm --network host --user 0:0 -e HOME="${workdir}" "${mounts[@]}" \
        --entrypoint /usr/local/bin/oc-mirror "${MIRROR_TOOLS_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}" "$@"
}

# =============================================================================
# Cluster
# =============================================================================
# Log in with an install's config (MIRROR_CLUSTER_FROM, default: the first
# selected install whose config has OC_LOGIN). The login lands in the kubeconfig,
# so later oc calls in this process use it.
preg_cluster_login() {
    if [[ -n "${MIRROR_OC_LOGIN:-}" ]]; then
        eval "${MIRROR_OC_LOGIN}"
        return
    fi
    local id candidates=()
    [[ -n "${MIRROR_CLUSTER_FROM:-}" ]] && candidates=("${MIRROR_CLUSTER_FROM}") || candidates=("${(@f)$(preg_installs)}")
    for id in "${candidates[@]}"; do
        [[ -n "${id}" ]] || continue
        local target="$(preg_install_env_target "${id}")"
        [[ "${target}" == "${MIRROR_CONFIG_FILE_PATH:-registry_mirror}" ]] && continue
        if ENV_TARGET="${target}" ENV_SETUP_QUIET=1 zsh -c '
            source "${_CP4D_REPO_ROOT}/env_bootstrap.sh"
            [[ -n "${OC_LOGIN:-}" ]] || exit 3
            eval "${OC_LOGIN}" >&2' ; then
            preg_info "Logged in with the ${id} config: $(oc whoami --show-server 2>/dev/null)"
            return 0
        fi
    done
    preg_die "No cluster login: set MIRROR_OC_LOGIN or MIRROR_CLUSTER_FROM to an install whose config has OC_LOGIN."
}

# OpenShift minor (4.20) from MIRROR_OCP_MINOR or the logged-in cluster.
preg_ocp_minor() {
    if [[ -n "${MIRROR_OCP_MINOR:-}" ]]; then print -r -- "${MIRROR_OCP_MINOR}"; return; fi
    oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d. -f1,2
}

preg_wait_for() { h_wait_for "$@"; }

preg_wait_mcp_updated() { h_wait_mcp_updated "$@"; }

# =============================================================================
# Tap: an install's registry_overrides.sh
# =============================================================================
# preg_write_overrides <id> <body file>
#   Writes <install config dir>/registry_overrides.sh (sourced after the
#   install's *_vars.sh by scripts/source_env_setup.sh): header, the same
#   ENV_TARGET guard as the install's config (INSTALL_ENV_GUARD), the body.
#   Mode 0600 (pull credentials), atomic. MIRROR_TAP_DRY_RUN=true prints it
#   with secrets masked instead.
preg_write_overrides() {
    local id="$1" body="$2" dirvar target guard dir out tmp
    dirvar="$(preg_install_conf "${id}" INSTALL_CONFIG_DIR_VAR)"
    target="$(preg_install_conf "${id}" INSTALL_ENV_TARGET)"
    guard="$(preg_install_conf "${id}" INSTALL_ENV_GUARD)"
    dir="${(P)dirvar:-}"
    [[ -n "${dir}" ]] || preg_die "${id}: ${dirvar} is not set - cannot place registry_overrides.sh"
    out="${dir}/registry_overrides.sh"
    tmp="$(preg_private_tmpdir)/registry_overrides.sh"
    {
        print -r -- "#!/bin/zsh"
        print -r -- "# Written by scripts/private_registry_mirroring/3_configure_cluster/3.5_point_installs_at_registry.sh"
        print -r -- "# on $(date -u +%Y-%m-%dT%H:%M:%SZ). Sourced right after this folder's *_vars.sh"
        print -r -- "# (scripts/source_env_setup.sh) and points ${id} at the private registry."
        print -r -- "# Re-run 3.5 to refresh it; delete it to go back to the install's own settings."
        if preg_is_true "${guard}" && [[ -n "${target}" ]]; then
            print -r -- "[[ \"\${ENV_TARGET:-}\" == ${target} || \"\${ENV_TARGET:-}\" == *${target}_vars.sh ]] || return 0"
        fi
        cat "${body}"
    } > "${tmp}"
    zsh -n "${tmp}" || preg_die "${id}: generated overrides have a syntax error (${tmp})"
    if preg_is_true "${MIRROR_TAP_DRY_RUN:-false}"; then
        preg_info "[dry-run] ${out#${_CP4D_REPO_ROOT}/} would be:"
        sed -E "s/^(export [A-Z0-9_]*(PASSWORD|_KEY|TOKEN)=).*/\1'****'/" "${tmp}" | sed 's/^/    /'
        rm -f "${tmp}"
        return 0
    fi
    chmod 600 "${tmp}"
    mkdir -p "${dir}"
    mv "${tmp}" "${out}"
    preg_info "${id}: wrote ${out#${_CP4D_REPO_ROOT}/}"
}

# zsh single-quoted literal of a value, for generated files.
preg_q() { print -r -- "${(qq)1}"; }

# Pull-side reference of a source image as mapped by 1.0 (empty when unmapped).
#   preg_lookup_pull <source ref> [path]   (path defaults to the install's own)
preg_lookup_pull() {
    local src="$1" rp="${2:-${MIRROR_INSTALL_PATH:-}}" root out
    root="$(preg_pull_root)"
    out="$(preg_engine lookup --workspace "${MIRROR_WORKSPACE}" --path "${rp}" --source "${src}" --root "${root}" 2>/dev/null)" && { print -r -- "${out}"; return 0; }
    # declared shared?
    out="$(preg_engine lookup --workspace "${MIRROR_WORKSPACE}" --path "$(preg_install_path shared)" --source "${src}" --root "${root}" 2>/dev/null)" && { print -r -- "${out}"; return 0; }
    return 1
}

# Redirect mode for non-CP4D installs: does it include explicit overrides / mirror sets?
preg_redirect_explicit()    { [[ "${MIRROR_CLUSTER_REDIRECT:-both}" == (both|explicit) ]]; }
preg_redirect_mirror_sets() { [[ "${MIRROR_CLUSTER_REDIRECT:-both}" == (both|mirror-sets) ]]; }

# =============================================================================
# Hook output: JSON lines on fd 3 (map verb)
# =============================================================================
_preg_json() {   # minimal JSON string escaping
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    print -rn -- "\"${s}\""
}

# preg_emit_image <source> <component> [install|shared]
preg_emit_image() {
    [[ -n "${1:-}" ]] || return 0
    print -r -- "{\"kind\":\"image\",\"source\":$(_preg_json "$1"),\"component\":$(_preg_json "${2:-}"),\"scope\":$(_preg_json "${3:-install}")}" >&3
}

# preg_emit_operator <catalog> <package> <channel|""> <component>   (always shared)
preg_emit_operator() {
    print -r -- "{\"kind\":\"operator\",\"catalog\":$(_preg_json "$1"),\"package\":$(_preg_json "$2"),\"channel\":$(_preg_json "${3:-}"),\"component\":$(_preg_json "${4:-}"),\"scope\":\"shared\"}" >&3
}

# preg_emit_chart <source: oci://... | https repo URL> <chart> <version> <component> [install|shared]
preg_emit_chart() {
    print -r -- "{\"kind\":\"chart\",\"source\":$(_preg_json "$1"),\"chart\":$(_preg_json "$2"),\"version\":$(_preg_json "$3"),\"component\":$(_preg_json "${4:-}"),\"scope\":$(_preg_json "${5:-install}")}" >&3
}

# preg_emit_file <url> <dest relative to <path>/files/> <component>
preg_emit_file() {
    print -r -- "{\"kind\":\"file\",\"source\":$(_preg_json "$1"),\"dest\":$(_preg_json "$2"),\"component\":$(_preg_json "${3:-}")}" >&3
}

# preg_emit_native <handler> <summary> [extra JSON object members, already encoded]
preg_emit_native() {
    print -r -- "{\"kind\":\"native\",\"handler\":$(_preg_json "$1"),\"summary\":$(_preg_json "$2")${3:+,$3}}" >&3
}

# Images referenced by a rendered chart: preg_chart_images <helm template args...>
preg_chart_images() {
    helm template "$@" 2>/dev/null | preg_engine yaml-images
}
