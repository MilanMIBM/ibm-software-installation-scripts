#!/bin/zsh
# =============================================================================
# version_resolver.sh - versions, channels, image tags and pins, read from what
# the installs already have, with the old logic as the fallback
# -----------------------------------------------------------------------------
# How scripts use it (after the env_bootstrap line, or by path where a script
# skips env_bootstrap):
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/version_resolver.sh"
#     ver="$(vr_catalog helm/pinned_version)"
#
# Sources, tried in this order by each resolver:
#   1. the new source
#      - cpd_release_meta.py  patch / release metadata and downloaded CASEs
#      - cp4d_pkg_channel     the PackageManifest (scripts/operator_install_helpers.sh)
#      - image_tags.py        registry tag listings
#      - version_catalog.json pins no artifact carries
#   2. the legacy logic (legacy_version_resolution.sh / .py), when 1 fails or
#      returns nothing - the code and literals the scripts used before
# Explicit overrides (the scripts' own variables) are checked by the callers
# before they ask, as before.
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _VR_LOADED.
#   - Needs nothing from env_bootstrap.sh: it finds the repo from its own path.
#   - Results on stdout; where a value came from, and fallbacks, on stderr.
# =============================================================================

[[ -n "${_VR_LOADED:-}" ]] && return 0
_VR_LOADED=1

VR_DIR="${${(%):-%x}:A:h}"
VR_REPO_ROOT="${VR_DIR:h:h}"

# The repo's virtualenv has PyYAML; plain python3 is enough otherwise.
_vr_python() {
    if [[ -x "${VR_REPO_ROOT}/.venv/bin/python" ]]; then
        "${VR_REPO_ROOT}/.venv/bin/python" -I "$@"
    else
        python3 -I "$@"
    fi
}

source "${VR_DIR}/legacy_version_resolution.sh"

# vr_try <label> <new command...> -- <legacy command...>
# Prints the new command's output when it succeeds with output; otherwise warns
# and runs the legacy command (its output and status are the result).
vr_try() {
    local label="$1"
    shift
    local -a new=()
    while (( $# )) && [[ "$1" != -- ]]; do new+=("$1"); shift; done
    [[ "${1:-}" == -- ]] && shift
    local out rc=0
    out="$("${new[@]}")" || rc=$?
    if (( rc == 0 )) && [[ -n "${out}" ]]; then
        print -r -- "${out}"
        return 0
    fi
    echo "[WARN] ${label}: the new lookup did not work out (exit ${rc}${out:+, output '${out}'}); using the legacy logic." >&2
    "$@"
}

# -----------------------------------------------------------------------------
# F4: version_catalog.json (falls back to the legacy literal inside)
# -----------------------------------------------------------------------------
vr_catalog() {   # <path>, e.g. helm/pinned_version
    _vr_python "${VR_DIR}/version_catalog.py" get "$1"
}

# -----------------------------------------------------------------------------
# F1: release metadata and CASEs (cpd_release_meta.py)
# -----------------------------------------------------------------------------
_vr_meta() {
    VERSION="${VERSION:-}" PATCH_ID="${PATCH_ID:-}" IMAGE_ARCH="${IMAGE_ARCH:-amd64}" \
    CPD_CLI_WORK_PATH="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}" \
    OLM_UTILS_CONTAINER="${OLM_UTILS_CONTAINER:-olm-utils-play-v4}" \
        _vr_python "${VR_DIR}/cpd_release_meta.py" "$@"
}

vr_cpd_meta() {   # <component> <case_version|csv_version|cr_version|sub_channel|operator_version>
    _vr_meta meta "$1" "$2"
}

# The <arch> tag of the image whose name matches <repo-regex> in the CASE the
# metadata names for <component>.
vr_cpd_image_tag() {   # <case> <component> <repo-regex> [arch]
    _vr_meta image-tag "$1" --component "$2" --repo "$3" --arch "${4:-${IMAGE_ARCH:-amd64}}"
}

vr_cpd_case_images() {   # <case> [cpd_release_meta.py case-images options...]
    _vr_meta case-images "$@"
}

# -----------------------------------------------------------------------------
# F2: operator channels (PackageManifest, else the script's literal)
# -----------------------------------------------------------------------------
# vr_operator_channel [--strict] <package> [preferred]
vr_operator_channel() {
    local -a strict=()
    [[ "${1:-}" == --strict ]] && { strict=(--strict); shift; }
    (( ${+functions[cp4d_pkg_channel]} )) || source "${VR_REPO_ROOT}/scripts/operator_install_helpers.sh"
    vr_try "$1 channel" cp4d_pkg_channel "${strict[@]}" "$1" "${2:-}" -- legacy_pkg_channel "$1" "${2:-}"
}

# Red Hat OpenShift AI channel for a Software Hub release: the catalog's pin
# for that release, if the cluster's catalog offers it; else the old map / the
# catalog's default channel.
vr_rhoai_channel() {   # <release>
    _vr_rhoai_new() {
        local pin
        pin="$(_vr_python "${VR_DIR}/version_catalog.py" get "cpd/rhoai_channel_by_release/$1" 2>/dev/null)" || return 1
        (( ${+functions[cp4d_pkg_channel]} )) || source "${VR_REPO_ROOT}/scripts/operator_install_helpers.sh"
        cp4d_pkg_channel --strict rhods-operator "${pin}"
    }
    vr_try "RHOAI channel for ${1}" _vr_rhoai_new "$1" -- legacy_rhoai_channel "$1"
}

# -----------------------------------------------------------------------------
# F3: registry tags (image_tags.py)
# -----------------------------------------------------------------------------
# vr_newest_tags <repo> <n> <pattern> [authfile] [min] [max-exclusive]
# The matching tags of <repo>, oldest first, comma-separated: the newest <n>
# (0 = all) whose version (the pattern's numeric groups) is within the bounds.
vr_newest_tags() {
    local repo="$1" n="$2" pat="$3" auth="${4:-}" vmin="${5:-}" vmax="${6:-}" tags
    local -a args=(--pattern "${pat}" --n "${n}") skopeo_auth=()
    [[ -n "${vmin}" ]] && args+=(--min "${vmin}")
    [[ -n "${vmax}" ]] && args+=(--max-exclusive "${vmax}")
    [[ -n "${auth}" ]] && skopeo_auth=(--authfile "${auth}")
    tags="$(skopeo list-tags "${skopeo_auth[@]}" "docker://${repo}" 2>/dev/null)" || return 1
    print -r -- "${tags}" | _vr_python "${VR_DIR}/image_tags.py" "${args[@]}"
}
