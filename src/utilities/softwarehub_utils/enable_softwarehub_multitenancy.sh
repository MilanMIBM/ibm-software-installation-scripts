#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# enable_softwarehub_multitenancy.sh - turn on IBM Software Hub multitenancy
# -----------------------------------------------------------------------------
# Runs IBM's documented command, then waits for the ZenService reconcile it
# starts to finish, with a progress bar and time left:
#
#   cpd-cli manage enable-premium-features --features=multi-tenancy
#
# The flag in product-configmap turns true early, while the operator is still
# restarting Software Hub services, so the wait follows the reconcile instead.
#
# Multitenancy is a Software Hub Premium feature. It adds Accounts (Platform ->
# Account -> Service instance). Accounts separate data, administrators and
# tokens; they do not add pods. IBM does not document turning it back off.
#
# Usage:
#   ./enable_softwarehub_multitenancy.sh --status
#   ./enable_softwarehub_multitenancy.sh --dry-run
#   ./enable_softwarehub_multitenancy.sh --accept-license
#
# Options:
#   --status               Print the state and exit (reads the cluster only):
#                            0 Enabled, 10 Enabling, 11 Not enabled, 1 error
#   --dry-run              Run the checks and print the plan; changes nothing
#   --accept-license       Required to enable: passes --license_acceptance=true
#   --skip-premium-check   Continue although product-configmap reports
#                          SOFTWARE_HUB_PREMIUM other than true. Use only if
#                          you hold the Premium entitlement
#   --image=<image>        Premium olm-utils image to use (for a private
#                          registry); default: newest published for this release
#   --no-wait              Do not wait for the reconcile to finish
#   --timeout=<seconds>    How long to wait (default 1800; measured about 11 min,
#                          IBM says 10 to 20)
#
# Enabling switches the olm-utils container to the Premium image, because the
# standard image only has stubs of this command. Recreating the container kills
# any cpd-cli job in it, so the script stops if one is running. The next
# cpd-cli script recreates the container on the image from cpd_vars.sh.
# =============================================================================

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/progress_panel_helpers.sh"

# --- Edit these ---------------------------------------------------------------
PREMIUM_IMAGE_REPO="cp.icr.io/cp/cpd/olm-utils-premium-v4"
WAIT_TIMEOUT=1800
# When the operator reported each percentage, in seconds into the reconcile this
# change starts (measured on zen 6.10.8; the last entry is status Completed).
# The percentages are far from even: 35 -> 51 took 246s, 66 -> 99 took 20s, so
# the bar and time left weight by these. A slower cluster stretches the time
# left, because ppanel scales it by this run's own pace.
ZEN_MILESTONE_PERCENT=(0 3 16 35 51 66 99 100)
ZEN_MILESTONE_SECONDS=(0 21 201 251 497 590 610 631)
# ------------------------------------------------------------------------------

EXIT_ENABLED=0
EXIT_ENABLING=10
EXIT_NOT_ENABLED=11

MODE="enable"
DRY_RUN=false
ACCEPT_LICENSE=false
SKIP_PREMIUM_CHECK=false
IMAGE_OVERRIDE=""
WAIT=true

for arg in "$@"; do
    case "${arg}" in
        --status)              MODE="status" ;;
        --dry-run)             DRY_RUN=true ;;
        --accept-license)      ACCEPT_LICENSE=true ;;
        --skip-premium-check)  SKIP_PREMIUM_CHECK=true ;;
        --image=*)             IMAGE_OVERRIDE="${arg#--image=}" ;;
        --no-wait)             WAIT=false ;;
        --timeout=<->)         WAIT_TIMEOUT="${arg#--timeout=}" ;;
        -h|--help)             sed -n '6,43p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                     h_die "Unknown argument: ${arg} (see --help)" ;;
    esac
done

: "${PROJECT_CPD_INST_OPERATORS:?PROJECT_CPD_INST_OPERATORS is not set, check cpd_vars.sh}"
: "${PROJECT_CPD_INST_OPERANDS:?PROJECT_CPD_INST_OPERANDS is not set, check cpd_vars.sh}"
NS="${PROJECT_CPD_INST_OPERANDS}"

# REPLY = enabled | enabling | disabled. Reads the same two values as
# 'cpd-cli manage get-premium-feature-status', without touching the container.
# Fails if they cannot be read, so a passing API blip is not taken for "off".
mt_state() {
    local spec applied
    ZEN="$(oc get zenservice -n "${NS}" -o name 2>/dev/null | head -1)" || return 1
    [[ -n "${ZEN}" ]] || return 1
    spec="$(oc get "${ZEN}" -n "${NS}" -o jsonpath='{.spec.multi_tenancy_usage_enabled}' 2>/dev/null)" || return 1
    applied="$(oc get cm product-configmap -n "${NS}" -o jsonpath='{.data.MULTI_TENANCY_USAGE_ENABLED}' 2>/dev/null)" || return 1
    if [[ "${spec}" == true && "${applied}" == true ]]; then
        REPLY="enabled"
    elif [[ "${spec}" == true ]]; then
        REPLY="enabling"
    else
        REPLY="disabled"
    fi
}

zen_status() { oc get "${ZEN}" -n "${NS}" -o jsonpath='{.status.zenStatus}' 2>/dev/null; }

# Enabled, and the operator has finished applying it.
mt_is_settled() { mt_state && [[ "${REPLY}" == enabled && "$(zen_status)" == Completed ]]; }

typeset -g MT_RECONCILE_SEEN=false MT_STAGE="" MT_STAGE_SINCE=0 MT_DONE=0
typeset -g MT_DETAIL="waiting for the zen operator to start"

# ppanel_watch probe. Done / total are seconds of measured reconcile work, so
# ppanel's time left is the work remaining at this run's own pace. Inside a
# stage the bar creeps on with the clock, but stops short of the next milestone
# until the operator reports it: a slow stage shows as a growing time left.
mt_wait_probe() {
    local line state percent message i=1 last=${#ZEN_MILESTONE_PERCENT} base next limit extra
    PPANEL_TOTAL=${ZEN_MILESTONE_SECONDS[-1]}
    PPANEL_DONE=${MT_DONE} PPANEL_DETAIL="${MT_DETAIL}"
    line="$(oc get "${ZEN}" -n "${NS}" -o jsonpath='{.status.zenStatus}|{.status.progress}|{.status.progressMessage}' 2>/dev/null)" || return 0
    IFS='|' read -r state percent message <<< "${line}"
    percent="${percent%\%}"
    [[ "${percent}" == <-> ]] || percent=0

    if [[ "${state}" != InProgress ]]; then
        # The operator can finish at 99%, so go by the status, not the percentage.
        if [[ "${MT_RECONCILE_SEEN}" == true ]]; then MT_DONE=${PPANEL_TOTAL}; MT_DETAIL="operator finished"; fi
        PPANEL_DONE=${MT_DONE} PPANEL_DETAIL="${MT_DETAIL}"
        return 0
    fi
    MT_RECONCILE_SEEN=true

    while (( i < last - 1 && ZEN_MILESTONE_PERCENT[i + 1] <= percent )); do (( i += 1 )); done
    base=$(( ZEN_MILESTONE_SECONDS[i] + (percent - ZEN_MILESTONE_PERCENT[i]) * (ZEN_MILESTONE_SECONDS[i + 1] - ZEN_MILESTONE_SECONDS[i]) / (ZEN_MILESTONE_PERCENT[i + 1] - ZEN_MILESTONE_PERCENT[i]) ))
    next=${ZEN_MILESTONE_SECONDS[i + 1]}
    (( base >= next )) && next=${ZEN_MILESTONE_SECONDS[-1]}

    if [[ "${percent}" != "${MT_STAGE}" ]]; then MT_STAGE="${percent}"; MT_STAGE_SINCE=${EPOCHSECONDS}; fi
    extra=$(( EPOCHSECONDS - MT_STAGE_SINCE ))
    limit=$(( (next - base) * 9 / 10 ))
    (( extra > limit )) && extra=${limit}

    MT_DONE=$(( base + extra ))
    MT_DETAIL="operator ${percent}%: ${message}"
    PPANEL_DONE=${MT_DONE} PPANEL_DETAIL="${MT_DETAIL}"
}

# 0 settled, 1 timed out, 2 the ZenService failed.
mt_wait() {
    local deadline=$(( EPOCHSECONDS + WAIT_TIMEOUT )) rc=0
    ppanel_watch_start -p mt_wait_probe -t "Multitenancy" -u "%" -i 5
    until mt_is_settled; do
        if [[ "$(zen_status)" == Failed ]]; then rc=2; break; fi
        if (( EPOCHSECONDS >= deadline )); then rc=1; break; fi
        sleep 10
    done
    ppanel_watch_stop
    return ${rc}
}

# REPLY = the Premium image. IBM does not publish one for every patch, so take
# the newest at or below PATCH_ID. The tag carries the architecture.
mt_resolve_image() {
    if [[ -n "${IMAGE_OVERRIDE}" ]]; then REPLY="${IMAGE_OVERRIDE}"; return 0; fi
    if [[ "${OLM_UTILS_IMAGE:-}" == */olm-utils-premium-v4:* ]]; then REPLY="${OLM_UTILS_IMAGE}"; return 0; fi

    local arch="${IMAGE_ARCH:-amd64}" tags tag="" p
    tags="$(skopeo list-tags "docker://${PREMIUM_IMAGE_REPO}" 2>/dev/null | jq -r '.Tags[]?')" || tags=""
    [[ -n "${tags}" ]] || h_die "Could not list ${PREMIUM_IMAGE_REPO}. Log in to the registry, or pass --image=<image>."
    local -a available=("${(@f)tags}")

    for (( p = ${PATCH_ID:-0}; p >= 1; p-- )); do
        if (( ${available[(Ie)${VERSION}.${p}.${arch}]} )); then tag="${VERSION}.${p}.${arch}"; break; fi
    done
    if [[ -z "${tag}" ]] && (( ${available[(Ie)${VERSION}.${arch}]} )); then tag="${VERSION}.${arch}"; fi
    [[ -n "${tag}" ]] || h_die "No Premium image for ${VERSION} (${arch}) in ${PREMIUM_IMAGE_REPO}. Pass --image=<image>."

    [[ "${tag}" == "${VERSION}.${PATCH_ID:-}.${arch}" ]] \
        || h_warn "No Premium image published for ${VERSION}.${PATCH_ID:-} yet; using ${tag}."
    REPLY="${PREMIUM_IMAGE_REPO}:${tag}"
}

# Prints cpd-cli jobs running in the container. start-registry / registry serve
# are cpd-cli's normal stop-over registry. The container has no ps.
mt_container_jobs() {
    podman exec "${OLM_UTILS_CONTAINER:-olm-utils-play-v4}" sh -c \
        'for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f" 2>/dev/null; echo; done' 2>/dev/null \
        | grep -E 'ansible-playbook|/opt/ansible/bin/|oc image mirror' \
        | grep -vE 'start-registry|registry serve' || true
}

eval "${OC_LOGIN}"

mt_state || h_die "Could not read the ZenService or product-configmap in ${NS}. Is Software Hub installed there?"
STATE="${REPLY}"

if [[ "${MODE}" == status ]]; then
    case "${STATE}" in
        enabled)
            RECONCILE="$(zen_status)"
            [[ "${RECONCILE}" == Completed ]] && RECONCILE="" || RECONCILE=" (ZenService ${RECONCILE:-status unknown}: still applying)"
            echo "Multitenancy for IBM Software Hub (${NS}): Enabled${RECONCILE}"
            exit "${EXIT_ENABLED}"
            ;;
        enabling) echo "Multitenancy for IBM Software Hub (${NS}): Enabling";    exit "${EXIT_ENABLING}" ;;
        *)        echo "Multitenancy for IBM Software Hub (${NS}): Not enabled"; exit "${EXIT_NOT_ENABLED}" ;;
    esac
fi

if mt_is_settled; then
    h_info "Multitenancy is already enabled in ${NS}. Nothing to do."
    exit 0
fi

if [[ "${STATE}" == disabled ]]; then
    PREMIUM="$(oc get cm product-configmap -n "${NS}" -o jsonpath='{.data.SOFTWARE_HUB_PREMIUM}')"
    if [[ "${PREMIUM}" != true && "${SKIP_PREMIUM_CHECK}" != true ]]; then
        PREMIUM_MESSAGE="Multitenancy needs the IBM Software Hub Premium cartridge, but product-configmap reports SOFTWARE_HUB_PREMIUM=${PREMIUM:-<unset>}. If you hold the entitlement, re-run with --skip-premium-check."
        [[ "${DRY_RUN}" == true ]] && h_warn "A real run would stop here. ${PREMIUM_MESSAGE}" || h_die "${PREMIUM_MESSAGE}"
    fi

    mt_resolve_image
    PREMIUM_IMAGE="${REPLY}"
    ENABLE_ARGS=(
        --license_acceptance=true
        --features=multi-tenancy
        --operator_ns="${PROJECT_CPD_INST_OPERATORS}"
        --instance_ns="${NS}"
    )

    JOBS="$(mt_container_jobs)"
    if [[ -n "${JOBS}" ]]; then
        JOBS_MESSAGE="A cpd-cli job is running in the olm-utils container, and switching images would kill it. Wait for it to finish:"$'\n'"${JOBS}"
        [[ "${DRY_RUN}" == true ]] && h_warn "A real run would stop here. ${JOBS_MESSAGE}" || h_die "${JOBS_MESSAGE}"
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        [[ "${ACCEPT_LICENSE}" == true ]] || h_warn "A real run needs --accept-license."
        h_info "Dry run, nothing was changed. A real run would:"
        h_info "  use image ${PREMIUM_IMAGE}"
        h_info "  run cpd-cli manage enable-premium-features ${ENABLE_ARGS[*]}"
        h_info "  wait up to ${WAIT_TIMEOUT}s for MULTI_TENANCY_USAGE_ENABLED=true in product-configmap"
        exit 0
    fi

    [[ "${ACCEPT_LICENSE}" == true ]] || h_die "Re-run with --accept-license to accept the IBM Software Hub Premium license terms."

    # Pull first: a failed pull then leaves the running container alone.
    h_info "Pulling ${PREMIUM_IMAGE}"
    podman pull --arch="${IMAGE_ARCH:-amd64}" "${PREMIUM_IMAGE}" \
        || h_die "Could not pull ${PREMIUM_IMAGE}. Check your entitlement and registry login, or pass --image=<image>."

    # Only for this run: cpd_vars.sh keeps pointing at the standard image.
    export OLM_UTILS_IMAGE="${PREMIUM_IMAGE}"
    eval "${CPDM_OC_LOGIN}"

    h_info "Enabling multitenancy in ${NS}"
    cpd-cli manage enable-premium-features "${ENABLE_ARGS[@]}"
elif [[ "${DRY_RUN}" == true ]]; then
    h_info "Dry run: multitenancy is already being applied. A real run would wait up to ${WAIT_TIMEOUT}s for the reconcile."
    exit 0
fi

if [[ "${WAIT}" != true ]]; then
    h_info "Requested. Check progress with: $(basename "$0") --status"
    exit 0
fi

WAIT_RESULT=0
mt_wait || WAIT_RESULT=$?
(( WAIT_RESULT != 2 )) || h_die "The ZenService reports Failed. Check it and the ibm-zen-operator log in ${PROJECT_CPD_INST_OPERATORS}."
(( WAIT_RESULT == 0 )) || h_die "Timed out after ${WAIT_TIMEOUT}s; the reconcile is not finished. Re-run this script to keep waiting."

h_info "Multitenancy is enabled in ${NS}."
h_info "Create accounts in the web client: navigation menu > Accounts > New Account."
