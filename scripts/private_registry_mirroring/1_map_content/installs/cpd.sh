#!/bin/zsh
# Segment 1 hook: cpd (contract: _template.sh)
#
#   native   cpd-cli does the IBM part (2_download_and_mirror/installs/cpd.sh):
#            CASE packages, IBM images (+ image groups), olm-utils, cpd-cli itself
#   operator Red Hat / certified operators the CP4D scripts install, gated with
#            the same rules as 2.2 (src/helpers/cp4d_prereq_requirements.py) - shared
#   image    Databand Postgres, StreamSets engine + stage libs, watsonx.data
#            HCD versions, vLLM (IBM's digests), OADP plugins, extras
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

VERB="${1:-}"
[[ "${VERB}" == (map|check) ]] || preg_die "usage: $0 map|check"
COMPS="${MIRROR_CPD_COMPONENTS:-}"
CONTENT="${MIRROR_CPD_CONTENT:-}"
[[ -n "${COMPS}" && -n "${CONTENT}" ]] || exit 0

REL="${MIRROR_CPD_VERSION:-${VERSION:-}}"
PATCH="${MIRROR_CPD_PATCH_ID:-${PATCH_ID:-}}"
ARCH="${MIRROR_CPD_ARCH:-${IMAGE_ARCH:-amd64}}"
[[ -n "${REL}" ]] || preg_die "No Software Hub release: set MIRROR_CPD_VERSION or generate configs/cp4d_config/cpd_vars.sh"
has() { preg_in_list "$1" "${CONTENT}"; }
comp() { preg_in_list "$1" "${COMPS}"; }

# check: IBM's own source check (mirroring directly, step 3): log in to the
# entitled registry, list-images --inspect_source_registry=true, no level=fatal.
# Off unless MIRROR_CPD_INSPECT_SOURCE_REGISTRY=true (it inspects every image).
if [[ "${VERB}" == check ]]; then
    has ibm-images || exit 0
    if ! preg_is_true "${MIRROR_CPD_INSPECT_SOURCE_REGISTRY:-false}"; then
        preg_info "cpd: source inspection skipped (MIRROR_CPD_INSPECT_SOURCE_REGISTRY=false)"
        exit 0
    fi
    command -v cpd-cli >/dev/null 2>&1 || preg_die "cpd-cli not on PATH (scripts/install_cloud_pak_for_data/0_initial_setup/0.2_install_cpd_cli-MAC-ONLY.sh)"
    [[ -n "${MIRROR_IBM_ENTITLEMENT_KEY:-}" ]] || preg_die "MIRROR_IBM_ENTITLEMENT_KEY is empty"
    preg_info "cpd: cpd-cli manage list-images --inspect_source_registry=true (${COMPS})"
    cpd-cli manage login-entitled-registry "${MIRROR_IBM_ENTITLEMENT_KEY}" >/dev/null
    cpd-cli manage list-images --components="${COMPS}" --release="${REL}" ${PATCH:+--patch_id=${PATCH}} \
        --inspect_source_registry=true $(preg_is_true "${MIRROR_CPD_CASE_FROM_OCI:-true}" && print -r -- --from_oci=true)
    csv="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}/offline/${REL}/list_images.csv"
    [[ -f "${csv}" ]] || preg_die "list_images.csv not found at ${csv}"
    fatal="$(grep -c 'level=fatal' "${csv}" || true)"
    if (( fatal )); then
        grep 'level=fatal' "${csv}" | head -20 >&2
        preg_die "cpd: ${fatal} image(s) not inspectable at the source (authorization or network) - ${csv}"
    fi
    preg_info "cpd: every source image is inspectable ($(grep -c . "${csv}") lines in list_images.csv)"
    exit 0
fi

# --- IBM content through cpd-cli ---------------------------------------------------
# IBM: watsonx Assistant / Orchestrate also need ibm_events_operator; Control
# Center needs ibm_swhcc (a component of its own when selected).
extra_cases=()
if comp watson_assistant || comp watsonx_orchestrate; then extra_cases+=(ibm_events_operator); fi
native_kinds=()
for k in case ibm-images image-groups olm-utils cli; do has "${k}" && native_kinds+=("${k}"); done
if (( ${#native_kinds} )); then
    groups=""
    has image-groups && groups="${MIRROR_CPD_IMAGE_GROUPS:-}"
    has image-groups && [[ -z "${groups}" ]] && preg_warn "image-groups selected but MIRROR_CPD_IMAGE_GROUPS is empty."
    summary="${(j:,:)native_kinds} for ${COMPS} - release ${REL}${PATCH:+ patch ${PATCH}}, arch ${ARCH}${groups:+, groups ${groups}}"
    preg_emit_native cpd-cli "${summary}" \
        "\"components\":$(_preg_json "${COMPS}"),\"extra_cases\":$(_preg_json "${(j:,:)extra_cases}"),\"release\":$(_preg_json "${REL}"),\"patch_id\":$(_preg_json "${PATCH}"),\"arch\":$(_preg_json "${ARCH}"),\"groups\":$(_preg_json "${groups}"),\"content\":$(_preg_json "${(j:,:)native_kinds}")"
fi

# install-options YAML next to the cpd_vars.sh in use (when INSTALL_OPTIONS=true)
opts=""
if preg_is_true "${INSTALL_OPTIONS:-false}" && [[ -n "${INSTALL_OPTIONS_FILE:-}" ]]; then
    for opts in "${ENV_TARGET_FILE:+${ENV_TARGET_FILE:h}/${INSTALL_OPTIONS_FILE}}" "${CONFIG_DIR:-}/${INSTALL_OPTIONS_FILE}"; do
        [[ -n "${opts}" && -f "${opts}" ]] && break
        opts=""
    done
fi

# --- Red Hat / certified operators the CP4D scripts install (shared) ------------------
if has prereq-operators; then
    # 1.0 always installs the OpenShift cert-manager operator.
    preg_emit_operator redhat-operators openshift-cert-manager-operator stable-v1 cert-manager
    # Same verdicts as 2.2: "[needed] <component>: why" lines per prerequisite.
    needed() {
        local out
        out="$(CPD_COMPONENTS="${COMPS}" preg_python "${_CP4D_REPO_ROOT}/src/helpers/cp4d_prereq_requirements.py" "$1" ${opts:+"${opts}"} 2>/dev/null || true)"
        [[ "${out}" == *"[needed]"* ]]
    }
    if needed gpu; then
        preg_emit_operator redhat-operators nfd stable gpu
        preg_emit_operator certified-operators gpu-operator-certified "" gpu
    fi
    if needed rhoai; then
        # 2.2.3's channel map: Software Hub 5.3.x / 5.4.0 pin RHOAI 2.25.
        case "${REL}" in
            5.3.0|5.3.1|5.4.0) rhoai_channel="stable-2.25" ;;
            *) rhoai_channel="" ;;
        esac
        preg_emit_operator redhat-operators rhods-operator "${rhoai_channel}" rhoai
        autoload -Uz is-at-least
        if is-at-least 5.4.0 "${REL}"; then
            preg_emit_operator redhat-operators servicemeshoperator3 stable rhoai
        else
            preg_emit_operator redhat-operators servicemeshoperator stable rhoai
        fi
        # KServe (serverless mode) runs on OpenShift Serverless.
        preg_emit_operator redhat-operators serverless-operator stable rhoai
    fi
    if needed mcg; then
        # cpd-cli deploy-noobaa-backing-store subscribes mcg-operator (channel
        # stable-<OCP minor>; the default channel when the minor is unknown).
        preg_emit_operator redhat-operators mcg-operator "${MIRROR_OCP_MINOR:+stable-${MIRROR_OCP_MINOR}}" mcg
    fi
    if needed knative; then
        preg_emit_operator redhat-operators serverless-operator stable knative
    fi
fi

# --- Images the CP4D scripts use outside the CASE packages -----------------------------
if has extra-images; then
    if comp ibm-databand; then
        preg_emit_image "${DBND_PG_IMAGE:-registry.redhat.io/rhel9/postgresql-${DBND_PG_MAJOR:-16}:latest}" ibm-databand
    fi
    for img in ${=MIRROR_CPD_EXTRA_IMAGES:-}; do
        preg_emit_image "${img}" MIRROR_CPD_EXTRA_IMAGES
    done

    # StreamSets engines (5_component_specific_scripts/cp4d_streamsets): engine +
    # stage-libs image per version. The CASE has one engine tag and no libs image.
    # Explicit MIRROR_CPD_STREAMSETS_VERSIONS, else the newest N versions that
    # have a libs image, plus SSET_IMAGE_TAG / SSET_ENGINE_VERSION when pinned.
    realtime_streaming() {
        [[ -n "${opts}" ]] || return 1
        preg_python -c '
import sys, yaml
def walk(n):
    if isinstance(n, dict):
        w = n.get("watsonx_dataintegration")
        if isinstance(w, dict) and str(w.get("enableRealtimeStreaming")).lower() == "true":
            return True
        return any(walk(v) for v in n.values())
    return isinstance(n, list) and any(walk(v) for v in n)
sys.exit(0 if any(walk(d) for d in yaml.safe_load_all(open(sys.argv[1]))) else 1)' "${opts}"
    }
    if comp ibm-streamsets-sdi || comp streamsets || { comp watsonx_dataintegration && realtime_streaming; }; then
        sset="cp.icr.io/cp/cpd/ibm-streamsets-datacollector"
        libs=("${(@s:,:)$(preg_version_tags "${sset}-libs" 0 '^JDK(\d+)_(\d+)\.(\d+)\.(\d+)$')}")   # oldest first
        tags="${MIRROR_CPD_STREAMSETS_VERSIONS:-}"
        if [[ -z "${tags}" ]]; then
            n="${MIRROR_CPD_STREAMSETS_LATEST:-3}"
            [[ "${n}" == <1-> ]] || preg_die "MIRROR_CPD_STREAMSETS_LATEST must be a positive number (got '${n}')"
            tags="${(j:,:)libs[$(( n >= ${#libs} ? 1 : ${#libs} - n + 1 )),-1]}"
            tags+="${SSET_IMAGE_TAG:+,${SSET_IMAGE_TAG}}${SSET_ENGINE_VERSION:+,${SSET_ENGINE_VERSION}}"
            preg_info "streamsets: MIRROR_CPD_STREAMSETS_VERSIONS empty - the newest ${n} with stage libs${SSET_IMAGE_TAG:+ + SSET_IMAGE_TAG}${SSET_ENGINE_VERSION:+ + SSET_ENGINE_VERSION}: ${tags}"
        fi
        for t in ${(u)${(s:,:)tags}}; do
            preg_emit_image "${sset}:${t}" streamsets
            if (( ${libs[(Ie)${t}]} )); then
                preg_emit_image "${sset}-libs:${t}" streamsets
            else
                preg_warn "streamsets: no stage-libs image for ${t} - engine image only"
            fi
        done
    fi

    # watsonx.data's DataStax HCD (4.5_provision_datastax_hcd.sh, DS_SERVER_VERSION):
    # the CASE ships one HCD version. Explicit MIRROR_CPD_HCD_VERSIONS, else the
    # newest N plus DS_SERVER_VERSION when pinned.
    if comp watsonx_data_premium || comp datastax_mc; then
        hcd="cp.icr.io/cp/cpd/ibm-datastax-hcd/hcd"
        vers="${MIRROR_CPD_HCD_VERSIONS:-}"
        if [[ -z "${vers}" ]]; then
            n="${MIRROR_CPD_HCD_LATEST:-3}"
            [[ "${n}" == <1-> ]] || preg_die "MIRROR_CPD_HCD_LATEST must be a positive number (got '${n}')"
            vers="$(preg_version_tags "${hcd}" "${n}" '^(\d+)\.(\d+)\.(\d+)-ubi$')"
            vers="${vers//-ubi/}${DS_SERVER_VERSION:+,${DS_SERVER_VERSION}}"
            preg_info "hcd (watsonx.data): MIRROR_CPD_HCD_VERSIONS empty - the newest ${n}${DS_SERVER_VERSION:+ + DS_SERVER_VERSION}: ${vers}"
        fi
        for v in ${(u)${(s:,:)vers}}; do
            preg_emit_image "${hcd}:${v}-ubi" hcd
        done
    fi
fi

# --- vLLM for ibm-watsonx-ai-ifm (IBM's digests, 5.4.x docs) ---------------------------
if has vllm; then
    for v in ${(s:,:)MIRROR_CPD_VLLM:-}; do
        case "${v}" in
            mistral)     preg_emit_image "cp.icr.io/cp/cpd/vllm@sha256:cc95bc7619549a5fb9342f8c41c613df5cd65b4e1f90b408db062559a2fdcff9" vllm-mistral ;;
            rhaiis-cuda) preg_emit_image "registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:ec799bb5eeb7e25b4b25a8917ab5161da6b6f1ab830cbba61bba371cffb0c34d" vllm-rhaiis-cuda ;;
            rhoai-cuda)  preg_emit_image "registry.redhat.io/rhoai/odh-vllm-cuda-rhel9:v2.25.1-1765556017@sha256:5b86924790aeb996a7e3b7f9f4c8a3a676a83cd1d7484ae584101722d362c69b" vllm-rhoai-cuda ;;
            spyre)       preg_emit_image "registry.redhat.io/rhaii-early-access/vllm-spyre-rhel9:3.5.0-ea.1-1781067361" vllm-spyre ;;
            *) preg_warn "MIRROR_CPD_VLLM: unknown entry '${v}' (mistral, rhaiis-cuda, rhoai-cuda, spyre)" ;;
        esac
    done
fi

# --- OADP backup/restore (src/utilities/oadp_backup_restore_cp4d_utils) ----------------
if has oadp; then
    preg_emit_operator redhat-operators redhat-oadp-operator "${OADP_OPERATOR_CHANNEL:-}" oadp
    # cpd-cli's own plugin images are mirrored with the platform CASE; the
    # OADP_*_PLUGIN_IMAGE overrides (when set) are mirrored here.
    for v in OADP_CPDBR_VELERO_PLUGIN_IMAGE OADP_SWHUB_VELERO_PLUGIN_IMAGE OADP_CPFS_OADP_PLUGIN_IMAGE OADP_DB2U_VELERO_PLUGIN_IMAGE; do
        [[ -n "${(P)v:-}" ]] && preg_emit_image "${(P)v}" oadp
    done
fi
exit 0
