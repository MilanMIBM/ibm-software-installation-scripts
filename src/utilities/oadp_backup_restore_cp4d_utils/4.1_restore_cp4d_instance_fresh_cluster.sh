#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Restores a tenant backup onto a FRESH cluster (no Software Hub instance in the
# backed-up projects yet). A tenant restore recreates the instance projects, but
# not the cluster-wide setup the instance runs on, so this first runs the repo's
# install_cloud_pak_for_data steps for that, then sets up OADP, restores with
# 4_restore_cp4d_instance.sh, and finishes the setup the restored instance needs
# on this cluster.
#
# Steps, in order (names for --skip / --from):
#   certmanager           1.0    Red Hat cert-manager operator
#   pull-secret           1.1    IBM entitlement key / private registry in the global pull secret
#   projects              2.0.1  shared projects (License Service, scheduler, events, privileged
#                                monitoring) - not the instance projects: the restore creates those
#   cluster-resources     2.0.2  CASE download + cluster-scoped resources (CRDs, cluster roles)
#                                for COMPLETE_COMPONENT_LIST
#   cluster-components    2.1    License Service and scheduling service; authorize-instance-topology
#                                is left out (its RBAC lives in the instance projects and is restored)
#   prereq-operators      2.2    NFD + GPU, OpenShift AI, MCG operator, Knative Eventing, as on a
#                                normal install; setup-mcg waits for mcg-secrets
#   oadp                         2_install_oadp_br_utilities.sh --rbac-only (OADP, DPA, cpdbr-tenant roles)
#   restore                      4_restore_cp4d_instance.sh
#   oadp-full                    2_install_oadp_br_utilities.sh --full, so the restored instance can be
#                                backed up from this cluster
#   pull-secret-relink    1.1    again: this cluster's pull secret into the restored projects
#   mcg-secrets           2.2.4  setup-mcg: restored NooBaa secrets pointed at this cluster's MCG
#                                (does nothing unless CPD_COMPONENTS has an MCG-dependent service)
#   admission-controller  3.3.2  configuration admission controller webhook (cluster-scoped)
# A failure before or in 'restore' stops the script (resume with --from <step>);
# after it, the failed step is reported and the rest still run.
#
# The restore step is always a clean start: 4_restore_cp4d_instance.sh first
# removes what an earlier attempt left (Velero restore objects, a stuck Velero,
# restore scripts still running against this target, and the instance projects
# with their volumes), so re-running - e.g. --from restore - redoes the restore
# from scratch. --no-clean keeps the old behaviour (refuse when the instance
# projects exist, unless --force).
#
# Everything runs against the --target config alone, which needs the settings
# 1.2_generate_restore_target_config.sh copies from the source config (VERSION,
# SOFTWARE_HUB, COMPLETE_COMPONENT_LIST, IMAGE_PULL_*, IBM_ENTITLEMENT_KEY, ...).
# oc gets a kubeconfig of its own for the target (restore_target_configs/<name>.kubeconfig,
# a copy of your current one on first use), so your usual oc session, e.g. a
# backup running against the source cluster, is left alone; --shared-kubeconfig
# turns that off. The cpd-cli olm-utils container has a single login, which
# these steps move to the target.
#
# Not done here; set them up by hand where the source had them: node settings
# (CRI-O, kernel parameters, db2u kubelet), image mirrors for a private registry,
# and any storage class the backed-up PVCs use besides STG_CLASS_BLOCK/FILE.
#
#   4.1_restore_cp4d_instance_fresh_cluster.sh --target <name|path> --backup <name> [options] [-- <args>]
#     --target <name|path>        restore target config (required)
#     --backup <name>             tenant backup to restore (see --list)
#     --bucket <name|path>        bucket config (optional when there is only one)
#     --name <name>               restore name (default restore-<timestamp>)
#     --skip <step>[,<step>...]   leave these steps out (repeatable)
#     --from <step>               start at this step, e.g. to resume after a failure
#     --list-steps                print the steps and what this run would do, then exit
#     --prepare-only              stop after the 'oadp' step; no --backup needed
#     --no-clean                  no clean start before the restore (passed to 4_restore_cp4d_instance.sh)
#     --wipe-healthy              delete the instance projects even if they hold a finished, healthy
#                                 instance, without asking for the project name
#     --clean-timeout <minutes>   how long to wait for the old projects to terminate (default 10)
#     --force                     restore into the existing instance projects instead of deleting them
#                                 (passed on to tenant-restore)
#     --sync-timeout <minutes>    passed to 4_restore_cp4d_instance.sh
#     --timeout <duration>        passed to 4_restore_cp4d_instance.sh
#     --health-timeout <minutes>  passed to 4_restore_cp4d_instance.sh
#     --oadp-resources <preset>   minimal | small | medium: OADP resource requests, passed to
#                                 2_install_oadp_br_utilities.sh --resources (default there: small)
#     --shared-kubeconfig         use your current kubeconfig instead of the target's own
#     --yes                       do not ask for confirmation
#     --list                      list the tenant backups the target sees (OADP must be set up), then exit
#     -h, --help
# Arguments after '--' are passed to tenant-restore create unchanged.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Repo root only for now: the env is loaded after the options are parsed,
# because --target decides which config to load.
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; unset _b
source "${REPO_ROOT}/src/helpers/oadp_br_helpers.sh"
source "${REPO_ROOT}/src/helpers/common_helpers.sh"

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

INSTALL_DIR="${REPO_ROOT}/scripts/install_cloud_pak_for_data"
PREP_DIR="${INSTALL_DIR}/2_prepare_cluster"

h_steps_parse --no-help "$@"
set -- "${H_STEPS_ARGS[@]}"
# Up to and including the restore, a failed step stops everything after it;
# after it, the failed step is recorded and the next one still runs.
h_step        certmanager          true "1.0 Red Hat cert-manager operator"
h_step        pull-secret          true "1.1 global pull secret"
h_step        projects             true "2.0.1 shared projects (not the instance projects)"
h_step        cluster-resources    true "2.0.2 CASE download + cluster-scoped resources"
h_step        cluster-components   true "2.1 License Service + scheduling service"
h_step        prereq-operators     true "2.2 prerequisite operators"
h_step        oadp                 true "OADP + cpdbr-tenant cluster roles"
h_step        restore              true "tenant restore"
h_step --warn oadp-full            true "cpdbr-tenant + br_orchestration in the restored instance"
h_step --warn pull-secret-relink   true "1.1 pull secret into the restored projects"
h_step --warn mcg-secrets          true "2.2.4 MCG secrets for the restored instance"
h_step --warn admission-controller true "3.3.2 configuration admission controller"
h_step_hint restore "(the restore step clears what the failed attempt left before it starts again)"

TARGET=""
BACKUP_NAME=""
BUCKET=""
RESTORE_NAME=""
PREPARE_ONLY=false
FORCE=false
NO_CLEAN=false
RESTORE_PASS=()
OADP_ARGS=()
SHARED_KUBECONFIG=false
ASSUME_YES=false
LIST_ONLY=false
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)            TARGET="${2:?--target needs a config name or path}"; shift 2 ;;
        --backup)            BACKUP_NAME="${2:?--backup needs a tenant backup name}"; shift 2 ;;
        --bucket)            BUCKET="${2:?--bucket needs a config name or path}"; shift 2 ;;
        --name)              RESTORE_NAME="${2:?--name needs a value}"; shift 2 ;;
        --prepare-only)      PREPARE_ONLY=true; shift ;;
        --force)             FORCE=true; shift ;;
        --no-clean)          NO_CLEAN=true; RESTORE_PASS+=(--no-clean); shift ;;
        --wipe-healthy)      RESTORE_PASS+=(--wipe-healthy); shift ;;
        --clean-timeout)     RESTORE_PASS+=(--clean-timeout "${2:?--clean-timeout needs minutes}"); shift 2 ;;
        --sync-timeout|--timeout|--health-timeout)
                             RESTORE_PASS+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
        --oadp-resources)
            case "${2:-}" in
                minimal|small|medium) OADP_ARGS=(--resources "$2"); shift 2 ;;
                *) echo "[ERROR] --oadp-resources needs minimal, small or medium (got '${2:-}')." >&2; exit 1 ;;
            esac ;;
        --shared-kubeconfig) SHARED_KUBECONFIG=true; shift ;;
        --yes)               ASSUME_YES=true; shift ;;
        --list)              LIST_ONLY=true; shift ;;
        --)                  shift; EXTRA_ARGS=("$@"); break ;;
        -h|--help)           oadp_usage "$0"; exit 0 ;;
        *)                   echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done
[[ "${PREPARE_ONLY}" == "true" ]] && h_steps_until oadp
${H_STEPS_LIST} && h_steps_plan
if [[ -z "${TARGET}" ]]; then
    echo "[ERROR] --target is required: the restore target config (1.2_generate_restore_target_config.sh)." >&2
    echo "[ERROR] To restore onto the cluster the backup came from, use 4_restore_cp4d_instance.sh --same-cluster." >&2
    exit 1
fi
if [[ "${LIST_ONLY}" != "true" ]]; then
    h_steps_check
    if h_step_selected restore && [[ -z "${BACKUP_NAME}" ]]; then
        echo "[ERROR] --backup is required for the restore step (or pass --prepare-only; --list shows the backups)." >&2
        exit 1
    fi
fi

ENV_TARGET="$(oadp_resolve_config "${TARGET_CONFIG_DIR}" "${TARGET_CONFIG_SUFFIX}" target "${TARGET}" 1.2_generate_restore_target_config.sh)"
export ENV_TARGET
TARGET_BASE="${${ENV_TARGET:t}%${TARGET_CONFIG_SUFFIX}}"

# The OADP install steps need the bucket; the restore and --list only check against it.
BUCKET_FILE=""
BUCKET_ARGS=()
_bucket_files=("${BUCKET_CONFIG_DIR}"/*"${BUCKET_CONFIG_SUFFIX}"(N))
if [[ -n "${BUCKET}" ]] || (( ${#_bucket_files} )) \
        || { [[ "${LIST_ONLY}" != "true" ]] && { h_step_selected oadp || h_step_selected oadp-full; }; }; then
    BUCKET_FILE="$(oadp_resolve_config "${BUCKET_CONFIG_DIR}" "${BUCKET_CONFIG_SUFFIX}" bucket "${BUCKET}" 1.1_generate_backup_bucket_config.sh)"
    BUCKET_ARGS=(--bucket "${BUCKET_FILE}")
fi

# A kubeconfig of the target's own, so logging in to it does not move your
# usual oc session (it may be in use against the source cluster). Every step
# below inherits it. First use copies your current one, which carries over a TLS
# decision you already made for this cluster.
# Decided before the kubeconfig copy below exists: a baseline is only recorded
# on a target these scripts have not changed yet.
FIRST_USE=false
oadp_target_first_use "${TARGET_BASE}" && FIRST_USE=true
mkdir -p "${TARGET_CONFIG_DIR}"
chmod 700 "${TARGET_CONFIG_DIR}"
TARGET_KUBECONFIG=""
if [[ "${SHARED_KUBECONFIG}" != "true" ]]; then
    TARGET_KUBECONFIG="${TARGET_CONFIG_DIR}/${TARGET_BASE}.kubeconfig"
    if [[ ! -s "${TARGET_KUBECONFIG}" ]]; then
        ( umask 077; oc config view --raw > "${TARGET_KUBECONFIG}" 2>/dev/null || : )
    fi
    export KUBECONFIG="${TARGET_KUBECONFIG}"
fi
# 1.1 saves the pull secret it reads; keep the target's copy next to its config
# (owner-only folder) instead of over the source cluster's in configs/cp4d_config/.
export PULL_SECRET_FILE="${TARGET_CONFIG_DIR}/${TARGET_BASE}.pull-secret.dockerconfigjson"

# --- Env load (repo root found above) ---
source "${REPO_ROOT}/env_bootstrap.sh"
oadp_require_target_login
oadp_require_vars OCP_URL OC_LOGIN CPDM_OC_LOGIN OADP_PROJECT PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS
if [[ "${LIST_ONLY}" != "true" ]] && { h_step_selected cluster-resources || h_step_selected cluster-components; }; then
    if ! oadp_require_vars VERSION SOFTWARE_HUB COMPLETE_COMPONENT_LIST IMAGE_PULL_PREFIX IMAGE_PULL_SECRET \
            PROJECT_LICENSE_SERVICE PROJECT_SCHEDULING_SERVICE; then
        echo "[ERROR] These come from the source config: regenerate ${ENV_TARGET:t} with 1.2_generate_restore_target_config.sh" >&2
        echo "[ERROR] (without --no-copy-source), or add them to ${ENV_TARGET}." >&2
        exit 1
    fi
fi

eval "${OC_LOGIN}"
oadp_check_cluster
# What the cluster had before any step ran, for 5_uninstall_from_target_cluster.sh --all.
oadp_auto_baseline "${TARGET_BASE}" "${FIRST_USE}"

if [[ "${LIST_ONLY}" == "true" ]]; then
    if [[ -z "$(oc get dataprotectionapplications.oadp.openshift.io -n "${OADP_PROJECT}" -o name 2>/dev/null)" ]]; then
        echo "[ERROR] OADP is not set up on ${OCP_URL} yet (no DPA in ${OADP_PROJECT}). Set it up first with:" >&2
        echo "[ERROR]   $0 --target ${TARGET} --from oadp --prepare-only" >&2
        exit 1
    fi
    "${SCRIPT_DIR}/4_restore_cp4d_instance.sh" --target "${ENV_TARGET}" "${BUCKET_ARGS[@]}" --list
    exit $?
fi

# ------------------------------------------------------------------------------
# Pre-flight (read-only)
# ------------------------------------------------------------------------------
EXISTING_NS=()
for ns in "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}"; do
    oc get namespace "${ns}" >/dev/null 2>&1 && EXISTING_NS+=("${ns}")
done
if h_step_selected restore && (( ${#EXISTING_NS} )) && [[ "${FORCE}" != "true" && "${NO_CLEAN}" == "true" ]]; then
    echo "[ERROR] ${EXISTING_NS[*]} already exist(s) on ${OCP_URL}: not a fresh cluster for this instance." >&2
    echo "[ERROR] Drop --no-clean to have the restore step delete them first, or pass --force to restore into them." >&2
    exit 1
fi

# Restoring without this run's 'oadp' step: OADP must already be on the cluster.
if h_step_selected restore && ! h_step_selected oadp \
        && [[ -z "$(oc get dataprotectionapplications.oadp.openshift.io -n "${OADP_PROJECT}" -o name 2>/dev/null)" ]]; then
    echo "[ERROR] OADP is not set up on ${OCP_URL} (no DPA in ${OADP_PROJECT}), and this run skips the 'oadp' step." >&2
    echo "[ERROR] On a fresh cluster, run without --from to do the cluster setup and OADP first, or" >&2
    echo "[ERROR] start earlier, e.g. --from oadp if the cluster setup steps were already done." >&2
    exit 1
fi

OTHER_INSTANCES=(${(f)"$(oc get ibmcpd -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null || true)"})
if (( ${#OTHER_INSTANCES} )); then
    echo "[WARN] Software Hub already runs on this cluster in: ${OTHER_INSTANCES[*]}. The cluster-wide steps will"
    echo "[WARN] reconcile the shared components it uses too (cert-manager, License Service, scheduler, operators)."
fi

MISSING_SC=()
for _v in STG_CLASS_BLOCK STG_CLASS_FILE; do
    [[ -n "${(P)_v:-}" ]] || continue
    oc get storageclass "${(P)_v}" >/dev/null 2>&1 || MISSING_SC+=("${(P)_v} (${_v})")
done
if h_step_selected restore && (( ${#MISSING_SC} )); then
    echo "[ERROR] Storage class(es) missing on ${OCP_URL}: ${MISSING_SC[*]}. The restored PVCs would stay Pending." >&2
    echo "[ERROR] Create them with the source cluster's names first. Storage classes here: $(oc get storageclass -o name 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')" >&2
    exit 1
fi

RESTORE_ARGS=(--target "${ENV_TARGET}" "${BUCKET_ARGS[@]}" --backup "${BACKUP_NAME}" --yes "${RESTORE_PASS[@]}")
[[ -n "${RESTORE_NAME}" ]] && RESTORE_ARGS+=(--name "${RESTORE_NAME}")
[[ "${FORCE}" == "true" ]] && RESTORE_ARGS+=(--force)
(( ${#EXTRA_ARGS} )) && RESTORE_ARGS+=(-- "${EXTRA_ARGS[@]}")

echo ""
echo "  Cluster:   ${OCP_URL} (target config: ${ENV_TARGET:t})"
[[ -n "${TARGET_KUBECONFIG}" ]] && echo "  oc config: ${TARGET_KUBECONFIG}"
[[ -n "${BUCKET_FILE}" ]] && echo "  Bucket:    ${BUCKET_FILE:t}"
h_step_selected restore && echo "  Backup:    ${BACKUP_NAME}"
echo "  Instance:  ${PROJECT_CPD_INST_OPERATORS} (operators) / ${PROJECT_CPD_INST_OPERANDS} (operands)"
if (( ${#EXISTING_NS} )) && h_step_selected restore; then
    if [[ "${FORCE}" == "true" ]]; then
        echo "  --force:   restoring into existing ${EXISTING_NS[*]}"
    else
        echo "  Leftover:  ${EXISTING_NS[*]} exist(s): the restore step deletes them first (clean start)"
    fi
fi
h_steps_print
echo ""
if h_step_selected restore; then
    oadp_confirm "This sets up ${OCP_URL} for Software Hub and restores ${BACKUP_NAME} onto it."
else
    oadp_confirm "This sets up ${OCP_URL} for Software Hub."
fi

# ------------------------------------------------------------------------------
# Steps
# ------------------------------------------------------------------------------
# Run directly, a 2.2.x prerequisite script installs its operator regardless of
# CPD_COMPONENTS. Here they are part of the whole flow (2.2.4 is also called
# directly for mcg-secrets), so they install only what the components need.
export CP4D_PREREQ_GATE_DEFAULT="${CP4D_PREREQ_GATE_DEFAULT:-auto}"

h_step_run certmanager        "${INSTALL_DIR}/1_global_pull_secret_and_certmanager/1.0_set_up_openshift_certmanager.sh"
h_step_run pull-secret        "${INSTALL_DIR}/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh"
h_step_run projects           env SETUP_INSTANCE_PROJECTS=false \
                             "${PREP_DIR}/2.0-2.1_preliminary_setup/2.0.1_preliminary_project_setup.sh"
h_step_run cluster-resources  "${PREP_DIR}/2.0-2.1_preliminary_setup/2.0.2_cluster_component_case_download.sh"
h_step_run cluster-components env AUTHORIZE_INSTANCE_TOPOLOGY=false \
                             "${PREP_DIR}/2.0-2.1_preliminary_setup/2.1_apply_shared_cluster_CASE_packages.sh"
h_step_run prereq-operators   env MCG_SETUP_INSTANCE_SECRETS=false \
                             "${PREP_DIR}/2.2_install_prerequisite_operators/2.2_install_prerequisite_operators.sh"
h_step_run oadp               "${SCRIPT_DIR}/2_install_oadp_br_utilities.sh" --target "${ENV_TARGET}" "${BUCKET_ARGS[@]}" "${OADP_ARGS[@]}" --rbac-only
h_step_run restore            "${SCRIPT_DIR}/4_restore_cp4d_instance.sh" "${RESTORE_ARGS[@]}"

h_step_run oadp-full            "${SCRIPT_DIR}/2_install_oadp_br_utilities.sh" --target "${ENV_TARGET}" "${BUCKET_ARGS[@]}" "${OADP_ARGS[@]}" --full
h_step_run pull-secret-relink   "${INSTALL_DIR}/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh"
h_step_run mcg-secrets          "${PREP_DIR}/2.2_install_prerequisite_operators/2.2.4_install_multicloud_object_gateway_operator.sh"
h_step_run admission-controller "${INSTALL_DIR}/3_install_softwarehub/3.3.2_softwarehub_admission_controller.sh"

echo ""
[[ -n "${TARGET_KUBECONFIG}" ]] && echo "[INFO] oc against the target from your shell: export KUBECONFIG=${TARGET_KUBECONFIG}"
if (( ${#H_STEPS_FAILED} )); then
    echo "[WARN] The restore finished, but these steps after it failed: ${H_STEPS_FAILED[*]}" >&2
    echo "[WARN] Re-run one with --from <step> once fixed (--skip the ones already done)." >&2
    exit 1
fi
if h_step_selected restore; then
    echo "[OK] ${BACKUP_NAME} restored onto ${OCP_URL}"
    echo "[INFO] Check the instance: oc get ibmcpd -n ${PROJECT_CPD_INST_OPERANDS}; cpd-cli manage get-cr-status --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}"
elif [[ "${PREPARE_ONLY}" == "true" ]]; then
    echo "[OK] ${OCP_URL} is set up for the restore"
    echo "[INFO] Next: $0 --target ${TARGET} --list"
    echo "[INFO]       $0 --target ${TARGET} --backup <backup name> --from restore"
else
    echo "[OK] Selected steps finished on ${OCP_URL}"
fi
