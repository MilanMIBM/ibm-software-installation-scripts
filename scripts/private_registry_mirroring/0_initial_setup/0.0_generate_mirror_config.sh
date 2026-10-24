#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# No env_bootstrap here: the config this script writes is what the other steps
# load, so it may not exist yet. Find the repo root the same way.
REPO_ROOT="${SCRIPT_DIR}"; while [[ "${REPO_ROOT}" != "/" && ! -f "${REPO_ROOT}/env_bootstrap.sh" ]]; do REPO_ROOT="$(dirname "${REPO_ROOT}")"; done
export _CP4D_REPO_ROOT="${REPO_ROOT}" CONFIGS_ROOT="${REPO_ROOT}/configs"
# Hooks load install configs through env_bootstrap.sh; skip its podman/chmod prep
# and keep its summary quiet - generating a config needs neither.
export _CP4D_PREP_DONE=1 ENV_SETUP_QUIET=1
source "${REPO_ROOT}/src/helpers/private_registry_helpers.sh"

usage() {
    cat <<'EOF'
Write configs/registry_mirror_config/registry_mirror_vars.sh, the configuration of
the private registry mirroring track (scripts/private_registry_mirroring/).

  0.0_generate_mirror_config.sh [options]

The file lists, per install, WHICH components and WHAT content to mirror. Every
selection starts empty: nothing is mirrored until you fill them in (or prefill).
Re-running keeps every value already in the file and adds new settings (a
timestamped .bak copy is kept).

Options:
  --installs ID,...           Sections to include (default: every install the track
                              knows: 0_initial_setup/installs/*.conf)
  --prefill-from-installs [ID,...]
                              Copy selections and registry settings from the
                              installs' own configs (default: every install with a
                              config). Prefilled values replace existing ones.
  --out FILE                  Write somewhere else (default above). Use it with
                              MIRROR_CONFIG_FILE=FILE when running the steps.
  --reset                     Ignore the values in the existing file (it is still
                              backed up)
  --cpd-parallel true|false   MIRROR_CPD_PARALLEL: cpd mirrors several CASEs at
                              once (default: true; false = IBM's serial run)
  --cpd-parallel-jobs N       MIRROR_CPD_PARALLEL_JOBS: CASEs at a time (default: 6)
  --oc-mirror-image-timeout D MIRROR_OC_MIRROR_IMAGE_TIMEOUT: time oc-mirror (2.2)
                              allows per image, all architectures together, as a Go
                              duration: 90m, 6h, 1h30m (default: 6h; oc-mirror's own
                              10m times out on RHOAI's 8-20 GB GPU images)
  --oc-mirror-parallel-images N
                              MIRROR_OC_MIRROR_PARALLEL_IMAGES: images oc-mirror
                              copies at once (default: 4; they share the uplink)
                              These four are written on every run from these options
                              (or their defaults), not kept from the existing file.
  -h, --help                  Show this help

Next: 0.1_detect_registry.sh to check the registry, then 1_map_content/.
EOF
}

OUT_FILE="${CONFIGS_ROOT}/registry_mirror_config/registry_mirror_vars.sh"
INSTALLS=""
PREFILL=false
PREFILL_IDS=""
RESET=false
CPD_PARALLEL=true
CPD_PARALLEL_JOBS=6
OCM_IMAGE_TIMEOUT=6h
OCM_PARALLEL_IMAGES=2
while (( $# )); do
    case "$1" in
        --installs) INSTALLS="${2:?--installs needs a list}"; shift 2 ;;
        --prefill-from-installs)
            PREFILL=true; shift
            if [[ $# -gt 0 && "$1" != -* ]]; then PREFILL_IDS="$1"; shift; fi ;;
        --out)      OUT_FILE="${2:?--out needs a path}"; shift 2 ;;
        --reset)    RESET=true; shift ;;
        --cpd-parallel)      CPD_PARALLEL="${2:?--cpd-parallel needs true|false}"; shift 2 ;;
        --cpd-parallel=*)    CPD_PARALLEL="${1#*=}"; shift ;;
        --cpd-parallel-jobs) CPD_PARALLEL_JOBS="${2:?--cpd-parallel-jobs needs a number}"; shift 2 ;;
        --cpd-parallel-jobs=*) CPD_PARALLEL_JOBS="${1#*=}"; shift ;;
        --oc-mirror-image-timeout) OCM_IMAGE_TIMEOUT="${2:?--oc-mirror-image-timeout needs a duration}"; shift 2 ;;
        --oc-mirror-image-timeout=*) OCM_IMAGE_TIMEOUT="${1#*=}"; shift ;;
        --oc-mirror-parallel-images) OCM_PARALLEL_IMAGES="${2:?--oc-mirror-parallel-images needs a number}"; shift 2 ;;
        --oc-mirror-parallel-images=*) OCM_PARALLEL_IMAGES="${1#*=}"; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) preg_error "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
done
case "${CPD_PARALLEL:l}" in
    true|yes|y|1)   CPD_PARALLEL=true ;;
    false|no|n|0)   CPD_PARALLEL=false ;;
    *) preg_die "--cpd-parallel must be true or false (is '${CPD_PARALLEL}')" ;;
esac
[[ "${CPD_PARALLEL_JOBS}" == <1-> ]] || preg_die "--cpd-parallel-jobs must be a whole number >= 1 (is '${CPD_PARALLEL_JOBS}')"
[[ "${OCM_IMAGE_TIMEOUT}" =~ '^([0-9]+(h|m|s))+$' ]] || preg_die "--oc-mirror-image-timeout must be a duration like 90m, 6h or 1h30m (is '${OCM_IMAGE_TIMEOUT}')"
[[ "${OCM_PARALLEL_IMAGES}" == <1-> ]] || preg_die "--oc-mirror-parallel-images must be a whole number >= 1 (is '${OCM_PARALLEL_IMAGES}')"

KNOWN=("${(@f)$(preg_known_installs)}")
if [[ -n "${INSTALLS}" ]]; then
    IDS=(shared)
    for _id in ${(s:,:)INSTALLS}; do
        (( ${KNOWN[(Ie)${_id}]} )) || preg_die "Unknown install '${_id}' (known: ${KNOWN[*]})"
        [[ "${_id}" == shared ]] || IDS+=("${_id}")
    done
else
    # cpd first: with --prefill-from-installs the first install that provides a
    # shared key (registry root, credentials, entitlement key) wins.
    IDS=(shared)
    (( ${KNOWN[(Ie)cpd]} )) && IDS+=(cpd)
    IDS+=(${KNOWN:#(shared|cpd)})
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mirror-config.XXXXXX")"
trap 'rm -rf "${TMP}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
mkdir -p "${TMP}/catalogs"

# Run a segment-0 hook with the install's config loaded when it has one.
run0() {   # <id> <verb> <fd3 output file>
    local id="$1" verb="$2" out="$3" target f has_config=false
    target="$(preg_install_conf "${id}" INSTALL_ENV_TARGET)"
    if [[ -n "${target}" ]]; then
        for f in "${CONFIGS_ROOT}"/*/"${target}"_vars.sh(N); do has_config=true; done
    fi
    if ${has_config}; then
        ENV_TARGET="${target}" PREG_SKIP_REGISTRY_OVERRIDES=1 zsh "${SCRIPT_DIR}/installs/${id}.sh" "${verb}" 3>"${out}"
    else
        PREG_NO_ENV=1 zsh "${SCRIPT_DIR}/installs/${id}.sh" "${verb}" 3>"${out}"
    fi
}

for id in "${IDS[@]}"; do
    [[ -f "${SCRIPT_DIR}/installs/${id}.sh" ]] || continue
    run0 "${id}" components "${TMP}/catalogs/${id}.tsv" >/dev/null || preg_die "installs/${id}.sh components failed"
done

: > "${TMP}/prefill.tsv"
if ${PREFILL}; then
    selected=()
    for id in "${IDS[@]}"; do
        [[ -n "${PREFILL_IDS}" ]] && ! preg_in_list "${id}" "${PREFILL_IDS}" && continue
        [[ -f "${SCRIPT_DIR}/installs/${id}.sh" ]] || continue
        run0 "${id}" prefill "${TMP}/prefill.${id}.tsv" >/dev/null || preg_die "installs/${id}.sh prefill failed"
        # The first install that provides a shared key (registry, key) wins.
        while IFS=$'\t' read -r k v; do
            [[ -n "${k}" ]] || continue
            grep -q "^${k}"$'\t' "${TMP}/prefill.tsv" || print -r -- "${k}"$'\t'"${v}" >> "${TMP}/prefill.tsv"
        done < "${TMP}/prefill.${id}.tsv"
        grep -q "^MIRROR_$(preg_id_upper "${id}")_COMPONENTS"$'\t' "${TMP}/prefill.${id}.tsv" && selected+=("${id}")
    done
    (( ${#selected} )) && print -r -- "MIRROR_INSTALLS"$'\t'"${(j:,:)selected}" >> "${TMP}/prefill.tsv"
    preg_info "Prefilled from: ${(j:, :)selected:-nothing (no install config found)}"
    awk -F'\t' '{ v = $2; if ($1 ~ /PASSWORD|KEY$/) v = (length($2) ? "(set)" : "(empty)"); printf "    %-34s %s\n", $1, v }' "${TMP}/prefill.tsv"
fi

EXISTING=""
if [[ -f "${OUT_FILE}" ]]; then
    _bak="${OUT_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    cp -p "${OUT_FILE}" "${_bak}"
    chmod 600 "${_bak}"
    preg_info "Previous file kept as ${_bak:t}"
    ${RESET} || EXISTING="${OUT_FILE}"
fi

python_bin="python3"
[[ -x "${REPO_ROOT}/.venv/bin/python" ]] && python_bin="${REPO_ROOT}/.venv/bin/python"
# An array, not ${EXISTING:+--existing "..."}: zsh keeps that as ONE word.
existing_args=()
[[ -n "${EXISTING}" ]] && existing_args=(--existing "${EXISTING}")
"${python_bin}" "${REPO_ROOT}/src/helpers/registry_mirror_config_render.py" \
    --template "${REPO_ROOT}/src/helpers/config_file_jinja2_templates/registry_mirror_variable_template.sh.j2" \
    --installs-dir "${SCRIPT_DIR}/installs" \
    --catalogs-dir "${TMP}/catalogs" \
    --installs "${(j:,:)IDS}" \
    --out "${OUT_FILE}" \
    "${existing_args[@]}" \
    --set "MIRROR_CPD_PARALLEL=${CPD_PARALLEL}" \
    --set "MIRROR_CPD_PARALLEL_JOBS=${CPD_PARALLEL_JOBS}" \
    --set "MIRROR_OC_MIRROR_IMAGE_TIMEOUT=${OCM_IMAGE_TIMEOUT}" \
    --set "MIRROR_OC_MIRROR_PARALLEL_IMAGES=${OCM_PARALLEL_IMAGES}" \
    --prefill "${TMP}/prefill.tsv" >/dev/null || preg_die "Rendering the config failed (previous file unchanged)."
preg_info "cpd: MIRROR_CPD_PARALLEL=${CPD_PARALLEL}, MIRROR_CPD_PARALLEL_JOBS=${CPD_PARALLEL_JOBS}"
preg_info "oc-mirror: MIRROR_OC_MIRROR_IMAGE_TIMEOUT=${OCM_IMAGE_TIMEOUT}, MIRROR_OC_MIRROR_PARALLEL_IMAGES=${OCM_PARALLEL_IMAGES}"

zsh -n "${OUT_FILE}" || preg_die "The generated file has a syntax error: ${OUT_FILE}"
preg_info "Wrote ${OUT_FILE#${REPO_ROOT}/} (mode 600)"
cat <<EOF

Next:
  1. Edit it: MIRROR_REGISTRY_ROOT + credentials, MIRROR_INSTALLS, and per install
     MIRROR_<ID>_COMPONENTS / MIRROR_<ID>_CONTENT (empty = nothing is mirrored).
  2. 0_initial_setup/0.1_detect_registry.sh   - classify and probe the registry
  3. 1_map_content/1.0_build_inventory.sh     - see exactly what goes where
EOF
