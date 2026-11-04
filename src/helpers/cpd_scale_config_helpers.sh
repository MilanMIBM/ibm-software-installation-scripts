#!/bin/zsh
# =============================================================================
# cpd_scale_config_helpers.sh - inputs for the Software Hub scale-config table
# -----------------------------------------------------------------------------
# How scripts use it:
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/cpd_scale_config_helpers.sh"
#
# Fetches what src/helpers/cpd_scale_config_table.py reads and caches it under
# ${SCC_CACHE_ROOT} (default cpd-cli-workspace/scale_config_cache/):
#
#   <image tag>/config-vars/   from a throwaway container of OLM_UTILS_IMAGE
#                              (never `cpd-cli manage`: that recreates the shared
#                              olm-utils-play-v4 container and kills a running job)
#   <image tag>/index.yaml     IBM/charts repo/ibm-helm index (refreshed daily)
#   <image tag>/charts/<chart> the charts at the CASE versions of this patch
#   operators/<digest>.json    per-operator size breakdown (shared across tags;
#                              an operator digest never changes its content)
#
# Functions:
#   scc_py <args>                      run cpd_scale_config_table.py (repo .venv when present)
#   scc_cache_dir                      -> REPLY  cache dir for OLM_UTILS_IMAGE
#   scc_config_vars <cache>            copy config-vars out of the olm-utils image (once)
#   scc_patch_file                     -> REPLY  patch-<VERSION>-<PATCH_ID>.yaml, or "" if missing
#   scc_chart_index <cache> [force]    download the chart index (daily, or when forced)
#   scc_fetch_charts <cache> <plan>    download + unpack the charts the plan lists
#   scc_operator_sizing <plan>         pull each operator image once, store its size breakdown
#
# Settings: SCC_CACHE_ROOT, SCC_PARALLEL (operator pulls at a time, default 4),
# SCC_OPERATOR_REGISTRY (default icr.io), SCC_CHARTS_REPO (IBM/charts ibm-helm URL),
# IMAGE_ARCH (amd64).
#
# Needs: podman, skopeo, curl, tar, and a Python with PyYAML (uv sync).
# Must be SOURCED (zsh). Guarded via _SCC_HELPERS_LOADED.
# =============================================================================

[[ -n "${_SCC_HELPERS_LOADED:-}" ]] && return 0
_SCC_HELPERS_LOADED=1

source "${_CP4D_REPO_ROOT}/src/helpers/progress_panel_helpers.sh"

: "${SCC_CACHE_ROOT:=${_CP4D_REPO_ROOT}/cpd-cli-workspace/scale_config_cache}"
: "${SCC_PARALLEL:=4}"
: "${SCC_OPERATOR_REGISTRY:=icr.io}"
: "${SCC_CHARTS_REPO:=https://raw.githubusercontent.com/IBM/charts/master/repo/ibm-helm}"

scc_py() {
    local py="python3"
    [[ -x "${_CP4D_REPO_ROOT}/.venv/bin/python" ]] && py="${_CP4D_REPO_ROOT}/.venv/bin/python"
    "${py}" -c 'import yaml' 2>/dev/null \
        || { echo "[ERROR] ${py} has no PyYAML; run 'uv sync' in the repo (or pip install pyyaml)." >&2; return 1; }
    "${py}" "${_CP4D_REPO_ROOT}/src/helpers/cpd_scale_config_table.py" "$@"
}

scc_cache_dir() {
    local tag="${OLM_UTILS_IMAGE:?OLM_UTILS_IMAGE is not set}"
    tag="${${tag##*/}//:/_}"                  # olm-utils-v4:5.4.0.8 -> olm-utils-v4_5.4.0.8
    REPLY="${SCC_CACHE_ROOT}/${tag}"
    mkdir -p "${REPLY}" "${SCC_CACHE_ROOT}/operators"
}

scc_config_vars() {   # <cache>
    local cache="$1" cid arch="${IMAGE_ARCH:-amd64}"
    [[ -s "${cache}/config-vars/service_features.yml" ]] && return 0
    if ! podman image exists "${OLM_UTILS_IMAGE}" 2>/dev/null; then
        echo "[INFO] Pulling ${OLM_UTILS_IMAGE} (${arch}) to read its metadata"
        podman pull --arch="${arch}" "${OLM_UTILS_IMAGE}" >/dev/null || { echo "[ERROR] Could not pull ${OLM_UTILS_IMAGE}" >&2; return 1; }
    fi
    # a throwaway container with its own name: the shared olm-utils-play-v4 is never touched
    cid="$(podman create --arch="${arch}" --name "scc-config-vars-$$" "${OLM_UTILS_IMAGE}" sh)" || return 1
    rm -rf "${cache}/config-vars.tmp"
    if podman cp "${cid}:/opt/ansible/ansible-play/config-vars" "${cache}/config-vars.tmp" >/dev/null; then
        rm -rf "${cache}/config-vars" && mv "${cache}/config-vars.tmp" "${cache}/config-vars"
    fi
    podman rm -f "${cid}" >/dev/null 2>&1
    [[ -s "${cache}/config-vars/service_features.yml" ]] \
        || { echo "[ERROR] No config-vars/service_features.yml in ${OLM_UTILS_IMAGE}" >&2; return 1; }
    echo "[INFO] olm-utils metadata: ${cache#${_CP4D_REPO_ROOT}/}/config-vars"
}

scc_patch_file() {
    local work="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}"
    REPLY=""
    [[ -n "${PATCH_ID:-}" ]] || return 0
    local f="${work}/offline/patch/patch-${VERSION}-${PATCH_ID}.yaml"
    if [[ -s "${f}" ]]; then
        REPLY="${f}"
    else
        echo "[WARN] ${f/#${HOME}/~} not found (it comes with the CASE download): base ${VERSION} versions are used, not patch ${PATCH_ID}" >&2
    fi
}

scc_chart_index() {   # <cache> [force]
    local idx="$1/index.yaml"
    if [[ -n "${2:-}" || ! -s "${idx}" || -n "$(find "${idx}" -mtime +0 2>/dev/null)" ]]; then
        echo "[INFO] Downloading the IBM chart index"
        curl -sfL --retry 3 -o "${idx}.tmp" "${SCC_CHARTS_REPO}/index.yaml" && mv "${idx}.tmp" "${idx}" \
            || { rm -f "${idx}.tmp"; [[ -s "${idx}" ]] && echo "[WARN] Index download failed; using the cached one" >&2 || { echo "[ERROR] Could not download ${SCC_CHARTS_REPO}/index.yaml" >&2; return 1; }; }
    fi
    return 0
}

scc_fetch_charts() {   # <cache> <plan.json>
    local cache="$1" plan="$2" chart ver url tmp
    local -a lines
    lines=("${(@f)$(scc_py list charts --plan "${plan}")}")
    lines=(${lines:#})
    local -i total=${#lines} i=0 got=0
    mkdir -p "${cache}/charts"
    for line in "${lines[@]}"; do
        (( ++i ))
        read -r chart ver url <<<"${line}"
        if [[ "$(cat "${cache}/charts/${chart}/.scc_version" 2>/dev/null)" == "${ver}" ]]; then
            continue
        fi
        tmp="$(mktemp -d "${cache}/charts/.dl.XXXXXX")"
        if curl -sfL --retry 3 "${url}" | tar -xzf - -C "${tmp}" 2>/dev/null && [[ -d "${tmp}/${chart}" ]]; then
            rm -rf "${cache}/charts/${chart}" && mv "${tmp}/${chart}" "${cache}/charts/${chart}"
            print -r -- "${ver}" > "${cache}/charts/${chart}/.scc_version"
            (( ++got ))
        else
            echo "[WARN] Chart ${chart} ${ver}: download failed (${url})" >&2
        fi
        rm -rf "${tmp}"
        print -r -- "[INFO] charts: ${i}/${total} ($(( i * 100 / total ))%) ${chart} ${ver}"
    done
    echo "[INFO] Charts: ${total} needed, ${got} downloaded, $(( total - got )) cached or failed"
}

# Pool worker: one operator image -> operators/<digest>.json
scc_operator_worker() {   # <digest>|<ref>
    local dg="${1%%|*}" ref="${1#*|}" tmp rc=0
    tmp="$(mktemp -d "${SCC_CACHE_ROOT}/operators/.pull.XXXXXX")" || return 1
    {
        skopeo copy -q --override-arch "${IMAGE_ARCH:-amd64}" --override-os linux \
            "docker://${SCC_OPERATOR_REGISTRY}/${ref}" "dir:${tmp}/img" \
        && scc_py extract --image-dir "${tmp}/img" --out "${tmp}/fs" >/dev/null \
        && scc_py sizing --fs "${tmp}/fs" > "${tmp}/sizing.json" \
        && mv "${tmp}/sizing.json" "${SCC_CACHE_ROOT}/operators/${dg}.json"
    } || rc=$?
    rm -rf "${tmp}"
    return ${rc}
}

scc_operator_label() { REPLY="${${1#*|}##*/}"; REPLY="${REPLY%%@*}"; }

scc_operator_sizing() {   # <plan.json>
    local dg ref
    local -a jobs
    # only operators without a result in the current format (a parser update redoes them)
    for dg ref in ${=$(scc_py list operators --plan "$1" --missing-in "${SCC_CACHE_ROOT}/operators")}; do
        jobs+=("${dg}|${ref}")
    done
    local -i cached=$(( $(scc_py list operators --plan "$1" | grep -c .) - ${#jobs} ))
    if (( ! ${#jobs} )); then
        echo "[INFO] Operator sizes: all ${cached} cached"
        return 0
    fi
    echo "[INFO] Operator sizes: ${#jobs} to pull (${cached} cached), ${SCC_PARALLEL} at a time"
    export SCC_CACHE_ROOT SCC_OPERATOR_REGISTRY IMAGE_ARCH
    ppanel_pool_run -j "${SCC_PARALLEL}" -a 2 -d 15 -t "operator sizing" -k operators -u operators \
        -w scc_operator_worker -l scc_operator_label -- "${jobs[@]}"
    (( ${#PPANEL_FAILED} )) && echo "[WARN] ${#PPANEL_FAILED} operator(s) could not be read: ${(j:, :)${PPANEL_FAILED[@]#*|}}" >&2
    return 0   # a missing operator only leaves its row without sizes
}
