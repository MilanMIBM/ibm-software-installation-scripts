#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Applies a Kubecost instance's optional-features config (made with
# ../generate_kubecost_features_config.sh) to the cluster:
#
#   configs/kubecost_config/<namespace>/<instance>-features.yaml
#
# Checks the whole file first, then writes the Secrets it needs
# (<instance>-smtp, <instance>-plugins, <instance>-federated-storage; labelled
# kubecost-features/managed), merge-patches the Kubecost CR (a feature turned
# off has its settings removed, so the chart default applies), waits for the
# operator, and restarts the pods that read a Secret whose content changed.
# Managed Secrets no longer used are deleted. Only the settings in the file are
# touched: login, product key, pricing, currency and Postgres are left alone.
#
#   apply_kubecost_features.sh [<kubecost name>] [options]
#     -n, --namespace <ns>     default: the namespace holding that Kubecost CR
#   No name: KUBECOST_INSTANCE_NAME from configs/kubecost_config/kubecost_vars.sh,
#   else the only instance on the cluster (asks which one when there are several)
#     -f, --file <yaml>        default configs/kubecost_config/<ns>/<instance>-features.yaml
#     --dry-run                check the file and show the change (Secret values hidden)
#     --no-wait                don't wait for the operator to roll it out
#     --timeout <seconds>      wait at most this long (default 600)
#     --server/--token/-u/-p   log in first (see ocu_login); otherwise OC_LOGIN
#                              from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Applies a Kubecost instance.s optional-features/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

CR_NAME=""
NAMESPACE=""
CONF_FILE=""
DRY_RUN=false
WAIT=true
TIMEOUT=600
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)  NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        -f|--file)       CONF_FILE="${2:?$1 needs a value}"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --no-wait)       WAIT=false; shift ;;
        --timeout)       TIMEOUT="${2:?$1 needs a value}"; shift 2 ;;
        --server)        LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)         LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)   LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)   LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)               [[ -z "${CR_NAME}" ]] || die "Unexpected argument: $1"; CR_NAME="$1"; shift ;;
    esac
done
[[ "${TIMEOUT}" == <-> ]] || die "--timeout needs a number of seconds."

ocu_login
kc_resolve_instance || exit 1
oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" &>/dev/null \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
echo "[INFO] Kubecost instance: ${NAMESPACE}/${CR_NAME}"
kc_features_file "${NAMESPACE}" "${CR_NAME}"
CONF_FILE="${CONF_FILE:-${REPLY}}"
[[ -r "${CONF_FILE}" ]] \
    || die "No file at ${CONF_FILE#${_CP4D_REPO_ROOT}/}. Make one with src/utilities/kubecost_utils/generate_kubecost_features_config.sh ${CR_NAME}."
echo "[INFO] Features: ${CONF_FILE#${_CP4D_REPO_ROOT}/}"

CTX="$(mktemp "${${TMPDIR:-/tmp}%/}/kc-features-ctx.XXXXXX")"
trap 'rm -f "${CTX}"' EXIT
kc_features_context "${CR_NAME}" "${NAMESPACE}" "${CTX}"
PLAN="$(kc_python plan --ctx "${CTX}" --file "${CONF_FILE}")" || die "Could not read the features config."

jq -r '.summary[]? | "  \(if .changed then "*" else " " end) \(.feature): \(.state)"' <<<"${PLAN}"
jq -r '.warnings[]? | "[WARN] \(.)"' <<<"${PLAN}"
if (( $(jq '.errors | length' <<<"${PLAN}") > 0 )); then
    echo "[ERROR] ${CONF_FILE:t}: nothing applied:" >&2
    jq -r '.errors[] | "  \(.)"' <<<"${PLAN}" >&2
    exit 1
fi
PATCH="$(jq -c '.patch' <<<"${PLAN}")"

# --- Secrets: compare with the cluster ---------------------------------------------
typeset -a SECRET_NEW SECRET_CHANGED SECRET_ORPHANS
typeset -A SECRET_MANIFEST
for name in ${(f)"$(jq -r '.secrets[]?.name' <<<"${PLAN}")"}; do
    [[ -n "${name}" ]] || continue
    want="$(jq -c --arg n "${name}" '.secrets[] | select(.name == $n) | .data' <<<"${PLAN}")"
    have_js="$(oc get secret "${name}" -n "${NAMESPACE}" -o json 2>/dev/null || true)"
    if [[ -z "${have_js}" ]]; then
        SECRET_NEW+=("${name}")
    else
        [[ "$(jq -r --arg l "kubecost-features/managed" '.metadata.labels[$l] // ""' <<<"${have_js}")" == true ]] \
            || die "Secret ${name} exists but was not made by this script; rename or delete it, or point the file's existingSecret at it."
        have="$(jq -c '.data // {} | map_values(try @base64d catch "")' <<<"${have_js}")"
        [[ "$(jq -cS . <<<"${have}")" == "$(jq -cS . <<<"${want}")" ]] || SECRET_CHANGED+=("${name}")
    fi
    SECRET_MANIFEST[${name}]="$(jq -cn --arg n "${name}" --arg ns "${NAMESPACE}" --arg cr "${CR_NAME}" --argjson d "${want}" '
        {apiVersion: "v1", kind: "Secret", type: "Opaque",
         metadata: {name: $n, namespace: $ns,
                    labels: {"kubecost-features/managed": "true", "kubecost-features/instance": $cr}},
         stringData: $d}')"
done
for name in ${(f)"$(oc get secret -n "${NAMESPACE}" -l "kubecost-features/managed=true,kubecost-features/instance=${CR_NAME}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"}; do
    [[ -n "${name}" && -z "${SECRET_MANIFEST[${name}]:-}" ]] && SECRET_ORPHANS+=("${name}")
done

if [[ "${PATCH}" == "{}" && ${#SECRET_NEW} -eq 0 && ${#SECRET_CHANGED} -eq 0 && ${#SECRET_ORPHANS} -eq 0 ]]; then
    echo "[OK] '${CR_NAME}' already runs these features; nothing to change."
    [[ "${DRY_RUN}" == true ]] || kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
    exit 0
fi

if [[ "${DRY_RUN}" == true ]]; then
    for name in "${SECRET_NEW[@]}"; do echo "[DRY-RUN] Would create Secret ${name} (keys: $(jq -r '.stringData | keys | join(", ")' <<<"${SECRET_MANIFEST[${name}]}"))"; done
    for name in "${SECRET_CHANGED[@]}"; do echo "[DRY-RUN] Would update Secret ${name} and restart the pods using it"; done
    for name in "${SECRET_ORPHANS[@]}"; do echo "[DRY-RUN] Would delete Secret ${name} (no longer used)"; done
    if [[ "${PATCH}" != "{}" ]]; then
        echo "[DRY-RUN] Would merge-patch ${KC_RESOURCE}/${CR_NAME} -n ${NAMESPACE} (null = back to the chart default):"
        jq '(.. | objects | select(has("clientSecret")) | .clientSecret) |= (if . == null then . else "****" end)' <<<"${PATCH}"
    fi
    exit 0
fi

# --- Apply ---------------------------------------------------------------------------
for name in "${SECRET_NEW[@]}" "${SECRET_CHANGED[@]}"; do
    print -r -- "${SECRET_MANIFEST[${name}]}" | oc apply -f - >/dev/null
    echo "[OK] Secret ${name} $([[ ${SECRET_NEW[(Ie)${name}]} -gt 0 ]] && echo created || echo updated)."
done

if [[ "${PATCH}" != "{}" ]]; then
    START_REV="$(kc_release_revision "${CR_NAME}" "${NAMESPACE}")"
    START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    oc patch "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" --type merge -p "${PATCH}" >/dev/null
    echo "[OK] Features set on '${CR_NAME}'."
    if [[ "${WAIT}" == true ]]; then
        kc_wait_for_release "${CR_NAME}" "${NAMESPACE}" "${START_REV}" "${START_TS}" "${TIMEOUT}" || exit 1
    fi
fi

if [[ "${WAIT}" == true ]]; then
    # A Secret that only changed content does not roll its pods by itself.
    for name in "${SECRET_CHANGED[@]}"; do
        kc_restart_secret_consumers "${NAMESPACE}" "${name}" "${TIMEOUT}" || die "Pods using Secret ${name} did not become ready."
    done
    for w in "statefulset/${CR_NAME}-aggregator" "deployment/${CR_NAME}-frontend"; do
        oc get "${w}" -n "${NAMESPACE}" &>/dev/null || continue
        echo "[INFO] Waiting for ${w}..."
        oc rollout status "${w}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s" 2>&1 | sed 's/^/  /' || die "${w} did not become ready."
    done
    ds="${CR_NAME}-network-costs"
    if oc get daemonset "${ds}" -n "${NAMESPACE}" &>/dev/null; then
        oc rollout status "daemonset/${ds}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s" >/dev/null 2>&1 || true
        echo "[INFO] Network costs: $(oc get daemonset "${ds}" -n "${NAMESPACE}" \
            -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}') pods ready."
    fi
else
    (( ${#SECRET_CHANGED} == 0 )) || echo "[WARN] --no-wait: restart the pods using ${SECRET_CHANGED[*]} yourself once the operator is done."
fi

# Deleted after the CR stopped pointing at them.
if (( ${#SECRET_ORPHANS} > 0 )); then
    if [[ "${WAIT}" == true ]]; then
        for name in "${SECRET_ORPHANS[@]}"; do
            oc delete secret "${name}" -n "${NAMESPACE}" >/dev/null
            echo "[OK] Secret ${name} deleted (no longer used)."
        done
    else
        echo "[INFO] --no-wait: Secret(s) ${SECRET_ORPHANS[*]} no longer used; run again to delete them."
    fi
fi

kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
echo "[OK] Done."
