#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Undoes what these scripts did on a restore TARGET cluster (--target config;
# never the cluster in configs/cp4d_config/cpd_vars.sh, which is refused).
#
# --restore (default): removes the restore - like uninstalling it:
#   - restore scripts still running against this target are stopped
#   - Velero restore / volume-restore / data-download objects are deleted (Velero
#     is restarted if one never finished); backups are kept, in the cluster and
#     in the bucket
#   - the instance projects are deleted, with their volumes
#   - cluster-scoped objects of the instance: webhooks and API services pointing
#     at its services, cluster roles/bindings of its operators or service accounts
#   The cluster setup stays (cert-manager, License Service, scheduler, operators,
#   OADP, CRDs), so a restore can be run again straight away.
#
# --all: --restore, plus everything else the scripts changed since the baseline:
#   projects, operators (Subscriptions, CSVs, catalog sources, operator groups),
#   CRDs with their custom resources, cluster roles/bindings, webhooks, API
#   services, priority classes, SCCs, storage classes, console plugins - and puts
#   back the global pull secret, mastersSchedulable, console plugin list and
#   snapshot class labels as they were. What existed before stays, and so does
#   anything that belongs to an operator that existed before (an ODF upgrade
#   after the baseline creates new objects; they stay).
#
# The baseline is restore_target_configs/<name>.baseline/, recorded by
# 4.1_restore_cp4d_instance_fresh_cluster.sh / 2_install_oadp_br_utilities.sh
# on their first run against a target (or now with --snapshot). Without one,
# --all counts everything created at or after --since as the scripts' changes;
# the default is when this target's kubeconfig copy was made, i.e. the first
# 4.1 run (macOS keeps that time; elsewhere pass --since). The global pull
# secret, mastersSchedulable and snapshot class labels need a baseline to be
# put back; without one they are only reported.
#
# Always shows the plan first (also written to cpd-cli-workspace/oadp/) and asks
# before changing anything; --dry-run stops after the plan. Not undone either
# way: node labels set by NFD / the GPU operator, images pulled onto the nodes,
# and the local files in restore_target_configs/.
#
#   5_uninstall_from_target_cluster.sh --target <name|path> [--restore | --all] [options]
#     --target <name|path>          restore target config (required)
#     --restore                     remove the restore only (default)
#     --all                         remove the restore and the setup changes
#     --since <time>                --all without a baseline: changes from this time on, e.g.
#                                   '2026-10-21 12:40' (local), 2026-10-21T10:40:00Z, or epoch seconds
#     --keep-namespace <a,b>        never remove these projects or the operators in them
#                                   (repeatable), e.g. oadp-operator to keep OADP for the next restore
#     --snapshot                    record the cluster as it is now as the baseline, then exit
#     --overwrite-snapshot          with --snapshot: replace an existing baseline
#     --dry-run                     show the plan and exit
#     --timeout <minutes>           how long to wait for projects to terminate (default 15)
#     --wipe-healthy                delete a finished, healthy instance without asking for its name
#     --shared-kubeconfig           use your current kubeconfig instead of the target's own
#     --yes                         do not ask for confirmation
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Repo root only for now: the env is loaded after the options are parsed,
# because --target decides which config to load.
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; unset _b
source "${REPO_ROOT}/src/helpers/oadp_br_helpers.sh"
CLASSIFIER="${REPO_ROOT}/src/helpers/oadp_cluster_changes.py"

SECONDS=0
DUMP_DIR=""
trap '[[ -n "${DUMP_DIR}" ]] && rm -rf "${DUMP_DIR}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

TARGET=""
SCOPE=restore
SINCE_ARG=""
KEEP_NS=()
SNAPSHOT=false
OVERWRITE_SNAPSHOT=false
DRY_RUN=false
TIMEOUT_MIN=15
WIPE_HEALTHY=false
SHARED_KUBECONFIG=false
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)             TARGET="${2:?--target needs a config name or path}"; shift 2 ;;
        --restore)            SCOPE=restore; shift ;;
        --all)                SCOPE=all; shift ;;
        --since)              SINCE_ARG="${2:?--since needs a time}"; shift 2 ;;
        --keep-namespace)     KEEP_NS+=(${(s:,:)${2:?--keep-namespace needs project names}}); shift 2 ;;
        --snapshot)           SNAPSHOT=true; shift ;;
        --overwrite-snapshot) OVERWRITE_SNAPSHOT=true; shift ;;
        --dry-run)            DRY_RUN=true; shift ;;
        --timeout)            TIMEOUT_MIN="${2:?--timeout needs minutes}"; shift 2 ;;
        --wipe-healthy)       WIPE_HEALTHY=true; shift ;;
        --shared-kubeconfig)  SHARED_KUBECONFIG=true; shift ;;
        --yes)                ASSUME_YES=true; shift ;;
        -h|--help)            oadp_usage "$0"; exit 0 ;;
        *)                    echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done
if [[ -z "${TARGET}" ]]; then
    echo "[ERROR] --target is required: the restore target config to clean up." >&2
    exit 1
fi
if [[ "${TIMEOUT_MIN}" != <-> ]]; then
    echo "[ERROR] --timeout must be a number of minutes (got '${TIMEOUT_MIN}')." >&2
    exit 1
fi
if [[ "${OVERWRITE_SNAPSHOT}" == "true" && "${SNAPSHOT}" != "true" ]]; then
    echo "[ERROR] --overwrite-snapshot only goes with --snapshot." >&2
    exit 1
fi
if [[ -n "${SINCE_ARG}" && "${SCOPE}" != "all" ]]; then
    echo "[ERROR] --since only goes with --all." >&2
    exit 1
fi

ENV_TARGET="$(oadp_resolve_config "${TARGET_CONFIG_DIR}" "${TARGET_CONFIG_SUFFIX}" target "${TARGET}" 1.2_generate_restore_target_config.sh)"
export ENV_TARGET
TARGET_BASE="${${ENV_TARGET:t}%${TARGET_CONFIG_SUFFIX}}"
BASELINE_DIR="$(oadp_baseline_dir "${TARGET_BASE}")"

# The same kubeconfig 4.1 uses for this target, so your usual oc session stays put.
TARGET_KUBECONFIG=""
if [[ "${SHARED_KUBECONFIG}" != "true" ]]; then
    TARGET_KUBECONFIG="${TARGET_CONFIG_DIR}/${TARGET_BASE}.kubeconfig"
    if [[ ! -s "${TARGET_KUBECONFIG}" ]]; then
        mkdir -p "${TARGET_CONFIG_DIR}" && chmod 700 "${TARGET_CONFIG_DIR}"
        ( umask 077; oc config view --raw > "${TARGET_KUBECONFIG}" 2>/dev/null || : )
    fi
    export KUBECONFIG="${TARGET_KUBECONFIG}"
fi

# --- Env load (repo root found above) ---
source "${REPO_ROOT}/env_bootstrap.sh"
oadp_require_target_login
oadp_require_vars OCP_URL OC_LOGIN OADP_PROJECT PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS

# Never the source cluster: this removes whole projects and operators.
SOURCE_URL="$(sed -n "s/^export OCP_URL=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "${CONFIG_DIR}/cpd_vars.sh" 2>/dev/null | tail -1 || true)"
if [[ -n "${SOURCE_URL}" && "${SOURCE_URL%/}" == "${OCP_URL%/}" ]]; then
    echo "[ERROR] ${ENV_TARGET:t} points at ${OCP_URL}, the cluster in configs/cp4d_config/cpd_vars.sh (the source)." >&2
    echo "[ERROR] This script only cleans up restore targets. Fix OCP_URL in ${ENV_TARGET}." >&2
    exit 1
fi

eval "${OC_LOGIN}"
oadp_check_cluster

# ------------------------------------------------------------------------------
# --snapshot
# ------------------------------------------------------------------------------
if [[ "${SNAPSHOT}" == "true" ]]; then
    if [[ -e "${BASELINE_DIR}" && "${OVERWRITE_SNAPSHOT}" != "true" ]]; then
        echo "[ERROR] ${BASELINE_DIR} exists ($(cat "${BASELINE_DIR}/captured.txt" 2>/dev/null)). Pass --overwrite-snapshot to replace it." >&2
        exit 1
    fi
    oadp_capture_baseline "${BASELINE_DIR}"
    exit 0
fi

fmt_time() { python3 -I -c 'import sys, datetime as d; print(d.datetime.fromtimestamp(float(sys.argv[1])).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z"))' "$1"; }
parse_time() {
    python3 -I -c '
import sys, datetime as d
s = sys.argv[1].strip()
try:
    print(float(s)); sys.exit(0)
except ValueError:
    pass
t = d.datetime.fromisoformat(s.replace("Z", "+00:00"))
print((t if t.tzinfo else t.astimezone()).timestamp())' "$1"
}

# ------------------------------------------------------------------------------
# What counts as the scripts' changes (--all)
# ------------------------------------------------------------------------------
CUTOFF_ARGS=()
CUTOFF_NOTE=""
HAVE_BASELINE=false
if [[ "${SCOPE}" == "all" ]]; then
    if [[ -z "${SINCE_ARG}" && -s "${BASELINE_DIR}/inventory.txt" ]]; then
        HAVE_BASELINE=true
        CUTOFF_ARGS=(--baseline "${BASELINE_DIR}/inventory.txt")
        CUTOFF_NOTE="anything not in the baseline (${$(cat "${BASELINE_DIR}/captured.txt")##*captured=})"
    else
        SINCE_EPOCH=""
        if [[ -n "${SINCE_ARG}" ]]; then
            SINCE_EPOCH="$(parse_time "${SINCE_ARG}" 2>/dev/null)" || { echo "[ERROR] Could not read --since '${SINCE_ARG}'." >&2; exit 1; }
            CUTOFF_NOTE="created at or after $(fmt_time "${SINCE_EPOCH}") (--since)"
        elif [[ -e "${TARGET_CONFIG_DIR}/${TARGET_BASE}.kubeconfig" ]]; then
            if [[ "$(uname -s)" == "Darwin" ]]; then
                SINCE_EPOCH="$(stat -f %B "${TARGET_CONFIG_DIR}/${TARGET_BASE}.kubeconfig" 2>/dev/null || true)"
            else
                SINCE_EPOCH="$(stat -c %W "${TARGET_CONFIG_DIR}/${TARGET_BASE}.kubeconfig" 2>/dev/null || true)"
            fi
            [[ "${SINCE_EPOCH}" == (|0|-) ]] && SINCE_EPOCH=""
            [[ -n "${SINCE_EPOCH}" ]] && CUTOFF_NOTE="created at or after $(fmt_time "${SINCE_EPOCH}") (when ${TARGET_BASE}.kubeconfig was made, the first 4.1 run; no baseline)"
        fi
        if [[ -z "${SINCE_EPOCH}" ]]; then
            echo "[ERROR] No baseline for ${TARGET_BASE} and no first-run time to fall back on. Pass --since <time>:" >&2
            echo "[ERROR] the time just before the scripts first changed this cluster." >&2
            exit 1
        fi
        CUTOFF_ARGS=(--since "${SINCE_EPOCH}")
    fi
fi

# ------------------------------------------------------------------------------
# Plan (read-only)
# ------------------------------------------------------------------------------
echo "[INFO] Reading the cluster..."
DUMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oadp-uninstall.XXXXXX")"
chmod 700 "${DUMP_DIR}"
for r in "${OADP_CHANGE_RESOURCES[@]}" persistentvolumes; do
    if ! oc get "${r}" -A -o json > "${DUMP_DIR}/${r}.json" 2>"${DUMP_DIR}/err"; then
        # A kind the cluster does not have is fine; a failed read would make the plan wrong.
        if grep -q "doesn't have a resource type" "${DUMP_DIR}/err"; then
            : > "${DUMP_DIR}/${r}.json"
            continue
        fi
        echo "[ERROR] Could not read ${r}: $(cat "${DUMP_DIR}/err")" >&2
        exit 1
    fi
done

INSTANCE_NS=("${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}")
PLAN_FILE="$(oadp_log_file "uninstall-${TARGET_BASE}-${SCOPE}")"
PLAN_FILE="${PLAN_FILE%.log}.plan.tsv"
python3 -I "${CLASSIFIER}" --dump-dir "${DUMP_DIR}" --scope "${SCOPE}" \
    --instance-ns "${(j:,:)INSTANCE_NS}" --keep-ns "${(j:,:)KEEP_NS}" "${CUTOFF_ARGS[@]}" > "${PLAN_FILE}"

P_WEBHOOK=() P_NS=() P_OLM=() P_CRD=() P_CLUSTER=() P_NOTE=()
while IFS= read -r line; do
    # Split on tabs keeping empty fields (cluster-scoped objects have no namespace).
    f=("${(@ps:\t:)line}")
    act="${f[1]}" res="${f[2]}" pns="${f[3]}" pname="${f[4]}" reason="${f[5]:-}"
    entry="${res}|${pns}|${pname}|${reason}"
    case "${act}" in
        webhook)   P_WEBHOOK+=("${entry}") ;;
        namespace) P_NS+=("${pname}") ;;
        olm)       P_OLM+=("${entry}") ;;
        crd)       P_CRD+=("${pname}") ;;
        cluster)   P_CLUSTER+=("${entry}") ;;
        note)      P_NOTE+=("${entry}") ;;
    esac
done < "${PLAN_FILE}"

OADP_NS_GOES=false
(( ${P_NS[(Ie)${OADP_PROJECT}]} )) && OADP_NS_GOES=true
OADP_RESTORE_MATCH="${TARGET_BASE}"
oadp_find_restore_remnants "${INSTANCE_NS[@]}"

# Settings to put back (--all with a baseline), and console plugins to unregister.
PS_CHANGES=() PS_NEW="" MASTERS_BACK="" VSC_UNLABEL=() CONSOLE_PLUGINS_NEW="" CONSOLE_REMOVED=()
CUR_PLUGINS="$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || true)"
DEL_PLUGINS=()
for e in "${P_CLUSTER[@]}"; do
    [[ "${e}" == consoleplugins.* ]] && DEL_PLUGINS+=("${${e#*|*|}%%|*}")
done
BASE_PLUGINS=""
if [[ "${HAVE_BASELINE}" == "true" ]]; then
    settings="$(cat "${BASELINE_DIR}/settings.txt" 2>/dev/null || true)"
    BASE_PLUGINS="$(print -r -- "${settings}" | sed -n 's/^consolePlugins=//p')"
    if [[ -s "${BASELINE_DIR}/pull-secret.json" ]]; then
        oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
            | base64 --decode > "${DUMP_DIR}/pull-secret.json" 2>/dev/null || true
        if [[ -s "${DUMP_DIR}/pull-secret.json" ]]; then
            PS_CHANGES=(${(f)"$(python3 -I "${CLASSIFIER}" pull-secret "${BASELINE_DIR}/pull-secret.json" "${DUMP_DIR}/pull-secret.json" "${DUMP_DIR}/pull-secret.new.json")"})
            (( ${#PS_CHANGES} )) && PS_NEW="${DUMP_DIR}/pull-secret.new.json"
        fi
    fi
    base_masters="$(print -r -- "${settings}" | sed -n 's/^mastersSchedulable=//p')"
    cur_masters="$(oc get schedulers.config.openshift.io cluster -o jsonpath='{.spec.mastersSchedulable}' 2>/dev/null || true)"
    [[ "${base_masters:-false}" != "${cur_masters:-false}" ]] && MASTERS_BACK="${base_masters:-false}"
    base_vsc=(${=$(print -r -- "${settings}" | sed -n 's/^labeledSnapshotClasses=//p')})
    for c in ${=$(oc get volumesnapshotclasses.snapshot.storage.k8s.io -l "${OADP_VSC_LABEL}=true" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)}; do
        (( ${base_vsc[(Ie)${c}]} )) || VSC_UNLABEL+=("${c}")
    done
fi
if [[ -n "${CUR_PLUGINS}" ]] && { (( ${#DEL_PLUGINS} )) || [[ "${HAVE_BASELINE}" == "true" ]]; }; then
    # Drop plugins being deleted and, with a baseline, plugins registered since.
    out="$(python3 -I -c '
import json, sys
cur = json.loads(sys.argv[1] or "[]")
base = json.loads(sys.argv[2]) if sys.argv[2] else None
drop = set(sys.argv[3].split(",")) - {""}
keep = [p for p in cur if p not in drop and (base is None or p in base)]
print(json.dumps(keep)); print(",".join(p for p in cur if p not in keep))' "${CUR_PLUGINS}" "${BASE_PLUGINS}" "${(j:,:)DEL_PLUGINS}")"
    if [[ -n "${out##*$'\n'}" ]]; then
        CONSOLE_PLUGINS_NEW="${out%%$'\n'*}"
        CONSOLE_REMOVED=(${(s:,:)out##*$'\n'})
    fi
fi

HEALTHY_NS=()
for ns in "${INSTANCE_NS[@]}"; do
    (( ${P_NS[(Ie)${ns}]} )) && oadp_instance_healthy "${ns}" && HEALTHY_NS+=("${ns}")
done

# ------------------------------------------------------------------------------
# Show it
# ------------------------------------------------------------------------------
# show_group <title> <entries...>: entries are res|ns|name|reason or plain names.
show_group() {
    local title="$1" e res ns nm i=0 max=15
    shift
    (( $# )) || return 0
    echo "  ${title} ($#):"
    for e in "$@"; do
        (( ++i > max )) && { echo "      ... and $(( $# - max )) more (all in the plan file)"; break; }
        if [[ "${e}" == *"|"* ]]; then
            res="${e%%|*}"; e="${e#*|}"; ns="${e%%|*}"; e="${e#*|}"; nm="${e%%|*}"
            echo "      ${res%%.*}/${ns:+${ns}/}${nm}"
        else
            echo "      ${e}"
        fi
    done
}

echo ""
echo "  Cluster:  ${OCP_URL} (target config: ${ENV_TARGET:t})"
if [[ "${SCOPE}" == "restore" ]]; then
    echo "  Scope:    --restore - the restored instance; the cluster setup stays"
else
    echo "  Scope:    --all - the restore and the setup changes: ${CUTOFF_NOTE}"
fi
(( ${#KEEP_NS} )) && echo "  Keeping:  ${KEEP_NS[*]} (--keep-namespace)"
echo ""
echo "  Removing:"
(( ${#OADP_OTHER_RESTORE_PIDS} )) && echo "  Restore scripts running against this target: PID ${OADP_OTHER_RESTORE_PIDS[*]}"
if [[ "${OADP_NS_GOES}" != "true" ]] && (( OADP_REM_VELERO + ${OADP_REM_BR:-0} )); then
    echo "  Velero restore objects in ${OADP_PROJECT}: $(( OADP_REM_VELERO + ${OADP_REM_BR:-0} ))$([[ "${OADP_REM_STUCK}" == "true" ]] && echo ' (one never finished: Velero is restarted)')"
fi
show_group "Webhook configurations" "${P_WEBHOOK[@]}"
show_group "Projects, with everything in them" "${P_NS[@]}"
show_group "Operators in projects that stay" "${P_OLM[@]}"
show_group "CRDs, with all their custom resources" "${P_CRD[@]}"
show_group "Other cluster-scoped objects" "${P_CLUSTER[@]}"
(( ${#HEALTHY_NS} )) && echo "  !! ${HEALTHY_NS[*]}: a finished, healthy Software Hub instance"
if (( ${#PS_CHANGES} )) || [[ -n "${MASTERS_BACK}" ]] || (( ${#VSC_UNLABEL} + ${#CONSOLE_REMOVED} )); then
    echo ""
    echo "  Putting back:"
    for c in "${PS_CHANGES[@]}"; do echo "      global pull secret: ${c}"; done
    [[ -n "${MASTERS_BACK}" ]] && echo "      mastersSchedulable: back to ${MASTERS_BACK}"
    for c in "${CONSOLE_REMOVED[@]}"; do echo "      console plugin list: remove ${c}"; done
    for c in "${VSC_UNLABEL[@]}"; do echo "      snapshot class ${c}: remove the ${OADP_VSC_LABEL} label"; done
fi
if [[ "${SCOPE}" == "all" && "${HAVE_BASELINE}" != "true" ]]; then
    P_NOTE+=("secrets|openshift-config|pull-secret|not put back without a baseline: the scripts add cp.icr.io and icr.io entries")
    [[ "$(oc get schedulers.config.openshift.io cluster -o jsonpath='{.spec.mastersSchedulable}' 2>/dev/null || true)" == "true" ]] \
        && P_NOTE+=("schedulers|cluster|mastersSchedulable|true; not put back without a baseline - set it to false if you turned it on")
fi
if (( ${#P_NOTE} )); then
    echo ""
    echo "  Kept:"
    for e in "${P_NOTE[@]}"; do
        res="${e%%|*}"; e="${e#*|}"; ns="${e%%|*}"; e="${e#*|}"; nm="${e%%|*}"
        echo "      ${res%%.*}/${ns:+${ns}/}${nm}: ${e#*|}"
    done
fi
echo ""
echo "  Plan file: ${PLAN_FILE}"
echo ""

TOTAL=$(( ${#P_WEBHOOK} + ${#P_NS} + ${#P_OLM} + ${#P_CRD} + ${#P_CLUSTER} + ${#OADP_OTHER_RESTORE_PIDS} + ${#PS_CHANGES} + ${#VSC_UNLABEL} + ${#CONSOLE_REMOVED} ))
[[ -n "${MASTERS_BACK}" ]] && TOTAL=$(( TOTAL + 1 ))
[[ "${OADP_NS_GOES}" != "true" ]] && TOTAL=$(( TOTAL + OADP_REM_VELERO + ${OADP_REM_BR:-0} ))
if (( TOTAL == 0 )); then
    echo "[OK] Nothing to remove on ${OCP_URL}."
    exit 0
fi
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[INFO] --dry-run: nothing was changed."
    exit 0
fi

# ------------------------------------------------------------------------------
# Confirm
# ------------------------------------------------------------------------------
if [[ "${SCOPE}" == "all" && "${ASSUME_YES}" != "true" ]]; then
    if [[ ! -t 0 ]]; then
        echo "[ERROR] Confirmation needed and no terminal to ask on; pass --yes." >&2
        exit 1
    fi
    read -r "ans?This removes everything listed above from ${OCP_URL}. Type the target name (${TARGET_BASE}) to continue: "
    [[ "${ans}" == "${TARGET_BASE}" ]] || { echo "[INFO] Aborted."; exit 1; }
else
    oadp_confirm "This removes everything listed above from ${OCP_URL}."
fi
if (( ${#HEALTHY_NS} )) && [[ "${WIPE_HEALTHY}" != "true" ]]; then
    if [[ ! -t 0 ]]; then
        echo "[ERROR] ${HEALTHY_NS[*]} hold(s) a finished, healthy instance and there is no terminal to confirm; pass --wipe-healthy." >&2
        exit 1
    fi
    for ns in "${HEALTHY_NS[@]}"; do
        read -r "ans?${ns} holds a finished, healthy instance that will be DELETED. Type the project name to confirm: "
        [[ "${ans}" == "${ns}" ]] || { echo "[INFO] Aborted."; exit 1; }
    done
fi

# ------------------------------------------------------------------------------
# Remove
# ------------------------------------------------------------------------------
FAILED=()
# Namespace flag as separate words ('-n' '<ns>'), or none for cluster-scoped objects.
nsflag() { reply=(); [[ -n "$1" ]] && reply=(-n "$1"); return 0; }
del() {  # del <resource> <namespace or ''> <name>
    nsflag "$2"
    oc delete "$1" "$3" "${reply[@]}" --ignore-not-found --wait=false >/dev/null 2>&1 \
        || echo "[WARN] Could not delete $1 ${2:+$2/}$3" >&2
}
crd_instances() {
    oc get "$1" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}
strip_crd_instances() {
    local a b
    crd_instances "$1" | while read -r a b; do
        if [[ -n "${b}" ]]; then
            oc patch "$1" "${b}" -n "${a}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        else
            oc patch "$1" "${a}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        fi
    done
}
# wait_crd_instances_gone <seconds>: true when no instance of P_CRD is left.
wait_crd_instances_gone() {
    local i c left
    for (( i = 0; i < $1; i += 10 )); do
        left=0
        for c in "${P_CRD[@]}"; do [[ -n "$(crd_instances "${c}")" ]] && (( ++left )); done
        (( left == 0 )) && return 0
        sleep 10
    done
    return 1
}

oadp_stop_restore_scripts

if (( ${#P_WEBHOOK} )); then
    echo "[INFO] Removing ${#P_WEBHOOK} webhook configuration(s)"
    for e in "${P_WEBHOOK[@]}"; do del "${e%%|*}" "" "${${e#*|*|}%%|*}"; done
fi

if [[ "${OADP_NS_GOES}" == "true" ]]; then
    # Stop Velero before its project goes, so nothing half-processes the restores.
    echo "[INFO] Removing the OADP DataProtectionApplication(s) in ${OADP_PROJECT}"
    oc delete dataprotectionapplications.oadp.openshift.io --all -n "${OADP_PROJECT}" --wait=false >/dev/null 2>&1 || true
    sleep 15
else
    oadp_clear_velero_restores
fi

if (( ${#P_CRD} )); then
    echo "[INFO] Removing the custom resources of ${#P_CRD} CRD(s) while their operators still run"
    for c in "${P_CRD[@]}"; do oc delete "${c}" --all -A --wait=false >/dev/null 2>&1 || true; done
    if ! wait_crd_instances_gone 180; then
        echo "[WARN] Some custom resources are still finalizing after 3m; clearing their finalizers."
        for c in "${P_CRD[@]}"; do strip_crd_instances "${c}"; done
    fi
fi

if (( ${#P_NS} )); then
    oadp_delete_namespaces "${TIMEOUT_MIN}" "${P_NS[@]}" || FAILED+=("projects")
fi

if (( ${#P_OLM} )); then
    echo "[INFO] Removing ${#P_OLM} operator object(s) in projects that stay"
    for e in "${P_OLM[@]}"; do
        res="${e%%|*}"; e="${e#*|}"; ns="${e%%|*}"; e="${e#*|}"
        del "${res}" "${ns}" "${e%%|*}"
    done
fi

if (( ${#P_CRD} )); then
    echo "[INFO] Removing ${#P_CRD} CRD(s)"
    for c in "${P_CRD[@]}"; do del customresourcedefinitions.apiextensions.k8s.io "" "${c}"; done
    for (( i = 0; i < 120; i += 10 )); do
        left=()
        for c in "${P_CRD[@]}"; do oc get crd "${c}" >/dev/null 2>&1 && left+=("${c}"); done
        (( ${#left} == 0 )) && break
        (( i == 60 )) && for c in "${left[@]}"; do strip_crd_instances "${c}"; done
        sleep 10
    done
    (( ${#left} )) && { echo "[WARN] CRD(s) still terminating: ${left[*]}" >&2; FAILED+=("crds"); }
fi

if (( ${#P_CLUSTER} )); then
    echo "[INFO] Removing ${#P_CLUSTER} other cluster-scoped object(s)"
    for e in "${P_CLUSTER[@]}"; do del "${e%%|*}" "" "${${e#*|*|}%%|*}"; done
fi

if [[ -n "${CONSOLE_PLUGINS_NEW}" ]]; then
    oc patch consoles.operator.openshift.io cluster --type=merge -p "{\"spec\":{\"plugins\":${CONSOLE_PLUGINS_NEW}}}" >/dev/null \
        && echo "[OK] Console plugin list: removed ${CONSOLE_REMOVED[*]}" || FAILED+=("console plugins")
fi
if [[ -n "${PS_NEW}" ]]; then
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${PS_NEW}" >/dev/null \
        && echo "[OK] Global pull secret put back to the baseline (nodes pick it up over the next minutes)" || FAILED+=("pull secret")
fi
if [[ -n "${MASTERS_BACK}" ]]; then
    oc patch schedulers.config.openshift.io cluster --type=merge -p "{\"spec\":{\"mastersSchedulable\":${MASTERS_BACK}}}" >/dev/null \
        && echo "[OK] mastersSchedulable back to ${MASTERS_BACK}" || FAILED+=("mastersSchedulable")
fi
for c in "${VSC_UNLABEL[@]}"; do
    oc label volumesnapshotclasses.snapshot.storage.k8s.io "${c}" "${OADP_VSC_LABEL}-" >/dev/null || FAILED+=("label on ${c}")
done

# Webhooks an operator re-registered while its project was going away.
REMOVED_NS=("${P_NS[@]}")
for kind in mutatingwebhookconfigurations validatingwebhookconfigurations; do
    oc get "${kind}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.webhooks[*].clientConfig.service.namespace}{"\n"}{end}' 2>/dev/null \
        | while read -r nm nss; do
            for n in ${=nss}; do
                if (( ${REMOVED_NS[(Ie)${n}]} )) && ! oc get namespace "${n}" >/dev/null 2>&1; then
                    del "${kind}" "" "${nm}"; echo "[INFO] Removed ${kind%%s}/${nm} (pointed at removed project ${n})"; break
                fi
            done
        done
done

# ------------------------------------------------------------------------------
# Check
# ------------------------------------------------------------------------------
LEFT=()
for ns in "${P_NS[@]}"; do oc get namespace "${ns}" >/dev/null 2>&1 && LEFT+=("namespace/${ns}"); done
for e in "${P_WEBHOOK[@]}" "${P_OLM[@]}" "${P_CLUSTER[@]}"; do
    res="${e%%|*}"; e="${e#*|}"; ns="${e%%|*}"; e="${e#*|}"; nm="${e%%|*}"
    nsflag "${ns}"
    oc get "${res}" "${nm}" "${reply[@]}" >/dev/null 2>&1 && LEFT+=("${res%%.*}/${ns:+${ns}/}${nm}")
done
for c in "${P_CRD[@]}"; do oc get crd "${c}" >/dev/null 2>&1 && LEFT+=("crd/${c}"); done

echo ""
if (( ${#LEFT} )); then
    echo "[WARN] Still present (may still be terminating; re-run this script to retry):" >&2
    print -rl -- "${LEFT[@]}" | head -30 | sed 's/^/         /' >&2
fi
(( ${#FAILED} )) && echo "[WARN] Steps that reported a problem: ${FAILED[*]}" >&2
if (( ${#LEFT} + ${#FAILED} )); then
    echo "[WARN] Finished with the leftovers above on ${OCP_URL}." >&2
elif [[ "${SCOPE}" == "restore" ]]; then
    echo "[OK] The restore is removed from ${OCP_URL}; the cluster setup is still in place for the next restore."
else
    echo "[OK] The restore and the setup changes are removed from ${OCP_URL}."
fi
[[ "${SCOPE}" == "all" ]] && echo "[INFO] Not undone: node labels from NFD / the GPU operator, images pulled onto the nodes, local files in restore_target_configs/."
(( ${#LEFT} + ${#FAILED} == 0 ))
