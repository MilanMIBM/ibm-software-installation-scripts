#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -uo pipefail

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
# 5.6 Optimize status (read-only)
# ------------------------------------------------------------------------------
# The t8c-operator, the Xl release and its mode, workload readiness, unbound
# volumes, the optimize route, and whether the (local) Hub has Optimize.
#
#   ./5.6_optimize_status.sh              one report; exit 0 only if all ready
#   ./5.6_optimize_status.sh --wait[=s]   repeat until ready (default 1800 s)
# `set -e` is deliberately off: the report must cover everything.
# ==============================================================================

WAIT=0
for _arg in "$@"; do
    case "${_arg}" in
        --wait)   WAIT=1800 ;;
        --wait=*) WAIT="${_arg#*=}" ;;
        *) concert_die "Unknown argument: ${_arg}" ;;
    esac
done

concert_product_enabled optimize || { concert_info "Optimize is not selected - nothing to report."; exit 0; }

eval "${OC_LOGIN}"
NS="$(concert_optimize_namespace)"

_report() {
    local ok=true v unready bad pvc host code url mode
    print -r -- ""
    print -r -- "=== Optimize (Turbonomic ${CONCERT_OPTIMIZE_VERSION:-}) in ${NS}"
    if ! oc get namespace "${NS}" >/dev/null 2>&1; then
        print -r -- "  [FAIL] namespace missing (5.1)"
        return 1
    fi

    v="$(oc get deployment t8c-operator -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    if [[ "${v:-0}" -ge 1 ]]; then print -r -- "  [ OK ] t8c-operator ready"
    else ok=false; print -r -- "  [FAIL] t8c-operator not ready (5.1)"; fi

    mode="$(concert_optimize_xl_annotation "${CONCERT_OPTIMIZE_MODE_ANNOTATION}")"
    v="$(oc get xl "${CONCERT_OPTIMIZE_XL}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null)"
    if [[ "${v}" == True && "${mode}" == concert ]]; then
        print -r -- "  [ OK ] Xl ${CONCERT_OPTIMIZE_XL} deployed in Concert mode"
    elif [[ "${v}" == True ]]; then
        ok=false; print -r -- "  [WAIT] Xl ${CONCERT_OPTIMIZE_XL} deployed in ${mode:-unknown} mode - 5.3/5.4 still to run"
    else
        ok=false; print -r -- "  [FAIL] Xl ${CONCERT_OPTIMIZE_XL} not deployed (${v:-missing})"
    fi
    v="$(oc get xl "${CONCERT_OPTIMIZE_XL}" -n "${NS}" -o jsonpath='{range .status.conditions[?(@.type=="ReleaseFailed")]}{.status}{" "}{.message}{end}' 2>/dev/null)"
    [[ "${v}" == True\ * ]] && { ok=false; print -r -- "  [FAIL] release failed: ${v#True }"; }
    [[ -n "$(concert_optimize_xl_annotation "${CONCERT_OPTIMIZE_LICENSE_ANNOTATION}")" ]] \
        && print -r -- "  [ OK ] license added (5.3)" \
        || print -r -- "  [WARN] no license added by 5.3 (--license=<file>)"

    unready="$(concert_ns_unready_workloads "${NS}")"
    bad="$(oc get pods -n "${NS}" --no-headers 2>/dev/null | awk '$3 ~ /CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error|CreateContainer/ {print $1" "$3}')"
    pvc="$(oc get pvc -n "${NS}" --no-headers 2>/dev/null | awk '$2 != "Bound" {print $1" "$2}')"
    total="$(oc get deployments,statefulsets -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ -z "${unready}${bad}${pvc}" && "${total}" -gt 1 ]]; then
        print -r -- "  [ OK ] ${total} workloads ready"
    else
        ok=false
        [[ -n "${unready}" ]] && print -r -- "${unready}" | sed 's/^/  [WAIT] /'
        [[ -n "${bad}" ]] && print -r -- "${bad}" | sed 's/^/  [FAIL] pod /'
        [[ -n "${pvc}" ]] && print -r -- "${pvc}" | sed 's/^/  [WAIT] pvc /'
    fi

    host="$(oc get route "${CONCERT_OPTIMIZE_ROUTE}" -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null)"
    if [[ -n "${host}" ]]; then
        code="$(curl -sk -o /dev/null --max-time 15 -w '%{http_code}' "https://${host}/" || true)"
        print -r -- "  route ${CONCERT_OPTIMIZE_ROUTE} https://${host} (HTTP ${code})"
        [[ "${code}" == (000|502|503) ]] && ok=false
    else
        ok=false; print -r -- "  [WAIT] route ${CONCERT_OPTIMIZE_ROUTE} missing (5.4)"
    fi

    if concert_remote_hub_enabled; then
        print -r -- "  Hub: remote (${CONCERT_REMOTE_HUB_URL}) - not checked from here"
    else
        url="$(concert_hub_product_url turbonomic)"
        if [[ -n "${url}" ]]; then print -r -- "  [ OK ] attached to the Hub in ${PROJECT_CONCERT_HUB} (${url})"
        else ok=false; print -r -- "  [WAIT] not attached to the Hub yet (5.5)"; fi
    fi
    ${ok}
}

if (( WAIT > 0 )); then
    start=${SECONDS}
    until _report; do
        (( SECONDS - start >= WAIT )) && { concert_error "Not ready after ${WAIT}s."; exit 1; }
        concert_info "Not ready yet - checking again in 30s ($(( SECONDS - start ))s)"
        sleep 30
    done
    rc=0
else
    _report
    rc=$?
fi

print -r -- ""
(( rc == 0 )) && concert_info "Optimize is ready." || concert_warn "Optimize is not ready."
exit ${rc}
