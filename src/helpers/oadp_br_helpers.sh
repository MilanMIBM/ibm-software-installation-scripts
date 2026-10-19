#!/bin/zsh
# =============================================================================
# oadp_br_helpers.sh - shared functions for src/utilities/oadp_backup_restore_cp4d_utils
# -----------------------------------------------------------------------------
# How scripts use it (BEFORE the env load: they resolve --bucket/--target with
# it first, because --target decides which config env_bootstrap.sh loads):
#
#     _b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; unset _b
#     source "${REPO_ROOT}/src/helpers/oadp_br_helpers.sh"
#     ... parse options, export ENV_TARGET for --target ...
#     source "${REPO_ROOT}/env_bootstrap.sh"
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _OADP_BR_HELPERS_LOADED.
#   - Needs no env loaded; functions that touch the cluster assume the caller
#     has logged oc in.
# =============================================================================

[[ -n "${_OADP_BR_HELPERS_LOADED:-}" ]] && return 0
_OADP_BR_HELPERS_LOADED=1

_OADP_REPO_ROOT="${${(%):-%x}:A:h:h:h}"
OADP_UTILS_DIR="${_OADP_REPO_ROOT}/src/utilities/oadp_backup_restore_cp4d_utils"
# Generated configs, both gitignored (see the repo .gitignore). Their names do
# not end in configs/*/*_vars.sh, so source_env_setup.sh never picks them up on
# its own: a restore target's OCP_URL cannot leak into the normal install env.
BUCKET_CONFIG_DIR="${OADP_UTILS_DIR}/backup_bucket_configs"
TARGET_CONFIG_DIR="${OADP_UTILS_DIR}/restore_target_configs"
BUCKET_CONFIG_SUFFIX="_bucket.sh"
TARGET_CONFIG_SUFFIX="_vars.sh"
# cpd-cli output is tee'd here (cpd-cli-workspace/ is gitignored).
OADP_LOG_DIR="${_OADP_REPO_ROOT}/cpd-cli-workspace/oadp"

# Defaults, overridable from cpd_vars.sh / the target config / the shell.
: "${OADP_PROJECT:=oadp-operator}"
: "${OADP_DPA_NAME:=cpd-dpa}"
: "${OADP_CREDENTIALS_SECRET:=cloud-credentials}"

# Print the comment block that follows 'set -euo pipefail' in a script (its usage).
oadp_usage() {
    awk '/^set -euo pipefail/ {f=1; next} f && /^#/ {sub(/^# ?/, ""); print; next} f && NF {exit}' "$1"
}

# oadp_resolve_config <dir> <suffix> <kind> <name-or-path> <generator script>
# Prints the absolute path of a config. <name-or-path> may be a path, or a bare
# name looked up as <dir>/<name><suffix>. Empty: the only config in <dir>, if
# there is exactly one.
oadp_resolve_config() {
    local dir="$1" suffix="$2" kind="$3" want="$4" generator="$5" f
    local -a found
    if [[ -n "${want}" ]]; then
        for f in "${want}" "${dir}/${want}${suffix}" "${dir}/${want}"; do
            [[ -f "${f}" ]] && { print -r -- "${f:A}"; return 0; }
        done
        echo "[ERROR] No ${kind} config '${want}' (tried ${want}, ${dir}/${want}${suffix})." >&2
        return 1
    fi
    found=("${dir}"/*"${suffix}"(N))
    if (( ${#found} == 1 )); then
        print -r -- "${found[1]:A}"
        return 0
    fi
    if (( ${#found} == 0 )); then
        echo "[ERROR] No ${kind} configs in ${dir}. Create one with ${generator}." >&2
    else
        echo "[ERROR] ${#found} ${kind} configs in ${dir}; pick one with --${kind}:" >&2
        for f in "${found[@]}"; do echo "         ${${f:t}%${suffix}}" >&2; done
    fi
    return 1
}

# Source a bucket config and check it has what the DPA needs.
oadp_load_bucket() {
    local file="$1" var
    source "${file}"
    for var in OADP_BUCKET_NAME OADP_BUCKET_PREFIX OADP_S3_REGION OADP_S3_FORCE_PATH_STYLE \
               OADP_S3_ACCESS_KEY_ID OADP_S3_SECRET_ACCESS_KEY; do
        if [[ -z "${(P)var:-}" ]]; then
            echo "[ERROR] ${var} is not set in ${file}." >&2
            return 1
        fi
    done
    echo "[INFO] Bucket config: ${file} (s3://${OADP_BUCKET_NAME}/${OADP_BUCKET_PREFIX} at ${OADP_S3_URL:-AWS S3})"
}

oadp_require_vars() {
    local var
    for var in "$@"; do
        if [[ -z "${(P)var:-}" ]]; then
            echo "[ERROR] ${var} is not set. Set it in the config this script loads (cpd_vars.sh or the restore target config)." >&2
            return 1
        fi
    done
}

# Six lowercase hex characters, for default config names (bucket-1a2b3c).
oadp_short_id() {
    local id
    id="$(uuidgen 2>/dev/null || openssl rand -hex 16)"
    id="${(L)id//-/}"
    print -r -- "${id[1,6]}"
}

# oadp_prompt <VAR> <question> [default] [secret]
# Leaves VAR alone when already set. Unless OADP_INTERACTIVE=true (the
# generators' --interactive), never asks: VAR gets the default, which may be
# empty - that is how the generators write fill-in-the-blanks templates.
# Interactive without a terminal: takes the default or fails.
oadp_prompt() {
    local var="$1" question="$2" def="${3:-}" secret="${4:-}" ans=""
    [[ -n "${(P)var:-}" ]] && return 0
    if [[ "${OADP_INTERACTIVE:-false}" != "true" ]]; then
        typeset -g "${var}=${def}"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        if [[ -n "${def}" ]]; then
            typeset -g "${var}=${def}"
            return 0
        fi
        echo "[ERROR] ${question} is required (no terminal to ask on; pass it as an option)." >&2
        return 1
    fi
    if [[ -n "${secret}" ]]; then
        read -rs "ans?${question}: "
        echo >&2
    else
        read -r "ans?${question}${def:+ [${def}]}: "
    fi
    ans="${ans:-${def}}"
    if [[ -z "${ans}" ]]; then
        echo "[ERROR] ${question} is required." >&2
        return 1
    fi
    typeset -g "${var}=${ans}"
}

# oadp_report_empty <file> <VAR>... - after a generator wrote <file>, list the
# values still to fill in. Returns 1 when there are any.
oadp_report_empty() {
    local file="$1" var
    local -a empty=()
    shift
    for var in "$@"; do
        [[ -z "${(P)var:-}" ]] && empty+=("${var}")
    done
    (( ${#empty} )) || return 0
    echo "[TODO] Fill in before using it - edit ${file}:"
    for var in "${empty[@]}"; do echo "         ${var}"; done
    return 1
}

# A restore target config may still be a generated template: check it has a
# cluster URL and a way to log in before anything runs oc login with it.
oadp_require_target_login() {
    if [[ -z "${OCP_URL:-}" ]]; then
        echo "[ERROR] OCP_URL is empty in ${ENV_TARGET_FILE:-the target config}. Fill it in first." >&2
        return 1
    fi
    if [[ -z "${OCP_TOKEN:-}" && ( -z "${OCP_USERNAME:-}" || -z "${OCP_PASSWORD:-}" ) ]]; then
        echo "[ERROR] Set OCP_TOKEN, or OCP_USERNAME and OCP_PASSWORD, in ${ENV_TARGET_FILE:-the target config}." >&2
        return 1
    fi
}

# Ask for 'yes' before something disruptive. Skipped with ASSUME_YES=true.
oadp_confirm() {
    local ans=""
    [[ "${ASSUME_YES:-false}" == "true" ]] && return 0
    if [[ ! -t 0 ]]; then
        echo "[ERROR] Confirmation needed and no terminal to ask on; pass --yes." >&2
        return 1
    fi
    read -r "ans?$1 Type 'yes' to continue: "
    [[ "${ans}" == "yes" ]] || { echo "[INFO] Aborted."; return 1; }
}

# Fail unless the oc session points at OCP_URL: these scripts change clusters,
# so running against the wrong one is the main thing to guard against.
oadp_check_cluster() {
    local server; server="$(oc whoami --show-server 2>/dev/null || true)"
    if [[ "${server%/}" != "${OCP_URL%/}" ]]; then
        echo "[ERROR] oc is on '${server:-<not logged in>}', expected ${OCP_URL}." >&2
        return 1
    fi
    echo "[INFO] Cluster: ${OCP_URL} (as $(oc whoami))"
}

# --private-registry-location for air-gapped clusters; IBM documents it as
# accepted by every cpd-cli oadp command.
oadp_registry_flags() {
    OADP_REGISTRY_FLAGS=()
    [[ -n "${PRIVATE_REGISTRY_LOCATION:-}" ]] && OADP_REGISTRY_FLAGS=(--private-registry-location="${PRIVATE_REGISTRY_LOCATION}")
    return 0
}

# Point cpd-cli oadp at this cluster's OADP project. The client config lives on
# the workstation, not the cluster, so set it on every run in case the last run
# was against another cluster.
oadp_set_client_namespace() {
    cpd-cli oadp client config set namespace="${OADP_PROJECT}" >/dev/null
    echo "[INFO] cpd-cli oadp client namespace: ${OADP_PROJECT}"
}

# Wait for the default BackupStorageLocation to be Available, then check it
# points at the bucket config's bucket/prefix (when a bucket config is loaded).
oadp_check_bsl() {
    local tries="${1:-30}" i line bsl phase bucket prefix
    for (( i = 1; i <= tries; i++ )); do
        line="$(oc get backupstoragelocations.velero.io -n "${OADP_PROJECT}" \
            -o jsonpath='{range .items[?(@.spec.default==true)]}{.metadata.name}{" "}{.status.phase}{" "}{.spec.objectStorage.bucket}{" "}{.spec.objectStorage.prefix}{"\n"}{end}' 2>/dev/null | head -1)"
        read -r bsl phase bucket prefix <<< "${line}"
        [[ "${phase:-}" == "Available" ]] && break
        (( i == 1 )) && echo "[INFO] Waiting for the default backup storage location in ${OADP_PROJECT} to be Available..."
        sleep 10
    done
    if [[ "${phase:-}" != "Available" ]]; then
        echo "[ERROR] No Available default backup storage location in ${OADP_PROJECT} (got: '${line:-none}')." >&2
        echo "[ERROR] Check the bucket URL/credentials, then: oc describe backupstoragelocations -n ${OADP_PROJECT}" >&2
        return 1
    fi
    echo "[OK] Backup storage location ${bsl} is Available (s3://${bucket}/${prefix})"
    if [[ -n "${OADP_BUCKET_NAME:-}" && ( "${bucket}" != "${OADP_BUCKET_NAME}" || "${prefix}" != "${OADP_BUCKET_PREFIX}" ) ]]; then
        echo "[ERROR] ${bsl} points at s3://${bucket}/${prefix}, but the bucket config says s3://${OADP_BUCKET_NAME}/${OADP_BUCKET_PREFIX}." >&2
        echo "[ERROR] Re-run 2_install_oadp_br_utilities.sh with --recreate-dpa to repoint it." >&2
        return 1
    fi
}

# Namespace of a Backup Restore Orchestration CR (tenantbackups / tenantrestores),
# empty when it does not exist. With br_orchestration installed, cpd-cli can run
# the backup as a CR in the cluster instead of in the CLI process.
oadp_br_cr_namespace() {
    oc get "$1.bros.ibm.com" -A \
        -o jsonpath="{range .items[?(@.metadata.name=='$2')]}{.metadata.namespace}{end}" 2>/dev/null || true
}

# Wait for a tenantbackups/tenantrestores CR when cpd-cli handed the work to the
# BR orchestration operator. No-op when cpd-cli ran it itself (CLI mode).
oadp_wait_for_br_cr() {
    local kind="$1" name="$2" timeout="$3" ns
    ns="$(oadp_br_cr_namespace "${kind}" "${name}")"
    [[ -z "${ns}" ]] && return 0
    echo "[INFO] ${kind}/${name} runs in the BR orchestration operator (${ns}); waiting up to ${timeout}..."
    cpd-cli oadp wait --cr="${kind}" --name="${name}" --br-operator-namespace="${ns}" \
        --runtime-mode=operator --timeout="${timeout}"
}

oadp_log_file() {
    mkdir -p "${OADP_LOG_DIR}"
    print -r -- "${OADP_LOG_DIR}/$1-$(date +%Y%m%d-%H%M%S).log"
}

# ------------------------------------------------------------------------------
# Workload health (storage independent): is the instance back after a backup?
# ------------------------------------------------------------------------------

# oadp_workload_lines <ns>...
# One line per workload: <ns>|<Kind>/<name>|<spec replicas>|<ready replicas>|<hibernation>
# for every Deployment and StatefulSet, and every EDB Postgres cluster (instances,
# readyInstances and its hibernation annotation). '|' keeps empty fields in place.
oadp_workload_lines() {
    local ns
    for ns in "$@"; do
        oc get deployments.apps,statefulsets.apps -n "${ns}" \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.kind}{"/"}{.metadata.name}{"|"}{.spec.replicas}{"|"}{.status.readyReplicas}{"|"}{"\n"}{end}' 2>/dev/null || true
        oc get clusters.postgresql.k8s.enterprisedb.io -n "${ns}" \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}EDBCluster/{.metadata.name}{"|"}{.spec.instances}{"|"}{.status.readyInstances}{"|"}{.metadata.annotations.k8s\.enterprisedb\.io/hibernation}{"\n"}{end}' 2>/dev/null || true
    done
}

# oadp_workload_snapshot <file> <ns>... - record replica counts before a backup.
oadp_workload_snapshot() {
    local file="$1"
    shift
    mkdir -p "${file:h}"
    oadp_workload_lines "$@" | cut -d'|' -f1-3 > "${file}"
    echo "[INFO] Recorded $(wc -l < "${file}" | tr -d ' ') workload replica counts in ${file}"
}

# oadp_check_workloads <timeout minutes> <snapshot file or ''> <ns>...
# Waits until no workload has fewer replicas than in the snapshot, every one with
# replicas > 0 is fully ready, and no EDB cluster is hibernated. Without a
# snapshot, only readiness is checked (a deployment at 0 may be normal).
# Returns 1 with the list when that is not reached in time, and leaves commands
# that put the recorded replica counts back in OADP_RESCALE_CMDS.
oadp_check_workloads() {
    local timeout_min="$1" snap="$2"
    shift 2
    local -A before
    local -a down
    local ns res spec ready hib key want deadline=$(( SECONDS + timeout_min * 60 )) waited=false
    OADP_RESCALE_CMDS=()
    if [[ -n "${snap}" && -f "${snap}" ]]; then
        while IFS='|' read -r ns res spec; do
            [[ -z "${res}" ]] && continue
            key="${ns}|${res}"
            before[$key]="${spec:-0}"
        done < "${snap}"
    fi
    while true; do
        down=()
        OADP_RESCALE_CMDS=()
        while IFS='|' read -r ns res spec ready hib; do
            [[ -z "${res}" ]] && continue
            [[ "${spec}" == <-> ]] || spec=0
            [[ "${ready}" == <-> ]] || ready=0
            key="${ns}|${res}"
            want="${before[$key]:-}"
            if [[ "${hib}" == "on" ]]; then
                down+=("${ns} ${res}: hibernated")
                OADP_RESCALE_CMDS+=("oc annotate -n ${ns} clusters.postgresql.k8s.enterprisedb.io/${res#*/} k8s.enterprisedb.io/hibernation=off --overwrite")
            elif [[ "${want}" == <-> ]] && (( spec < want )); then
                down+=("${ns} ${res}: ${spec} replicas, ${want} before the backup")
                OADP_RESCALE_CMDS+=("oc scale -n ${ns} ${(L)res} --replicas=${want}")
            elif (( spec > 0 && ready < spec )); then
                down+=("${ns} ${res}: ${ready}/${spec} ready")
            fi
        done < <(oadp_workload_lines "$@")
        if (( ${#down} == 0 )); then
            echo "[OK] Every deployment, statefulset and EDB cluster in $* is back${snap:+ to its replica count from before} and ready"
            return 0
        fi
        (( SECONDS >= deadline )) && break
        if [[ "${waited}" == "false" ]]; then
            echo "[INFO] Waiting up to ${timeout_min}m for ${#down} workload(s) in $* to come back..."
            waited=true
        else
            echo "  ${#down} workload(s) not back yet"
        fi
        sleep 30
    done
    echo "[WARN] ${#down} workload(s) not back after ${timeout_min}m:"
    print -rl -- "${down[@]}" | head -50 | sed 's/^/         /'
    return 1
}

# ------------------------------------------------------------------------------
# Snapshot capability (storage independent): can the instance's volumes be
# CSI-snapshotted, whatever the storage is (ODF, Storage Scale, Portworx,
# NetApp, cloud block/file, NFS, ...)?
# ------------------------------------------------------------------------------

# oadp_storage_report <ns>...
# Groups the PVs bound to PVCs in <ns> by CSI driver (or as non-CSI) and shows
# whether each driver has a VolumeSnapshotClass, and whether Velero would pick it
# (label velero.io/csi-volumesnapshot-class=true). Sets:
#   OADP_INSTANCE_PVS          PVs found
#   OADP_NO_SNAPSHOT_PVS       PVs that cannot be CSI-snapshotted (non-CSI, or driver without a class)
#   OADP_UNLABELED_SNAPCLASSES one class per driver that has classes but none labeled
oadp_storage_report() {
    local -a nss=("$@")
    local -A pv_count first_class labeled
    local name drv lbl ns sc key count state
    OADP_INSTANCE_PVS=0
    OADP_NO_SNAPSHOT_PVS=0
    OADP_UNLABELED_SNAPCLASSES=()
    while IFS='|' read -r name drv lbl; do
        [[ -z "${drv}" ]] && continue
        [[ -z "${first_class[$drv]:-}" ]] && first_class[$drv]="${name}"
        [[ "${lbl}" == "true" ]] && labeled[$drv]="${name}"
    done < <(oc get volumesnapshotclasses.snapshot.storage.k8s.io \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.driver}{"|"}{.metadata.labels.velero\.io/csi-volumesnapshot-class}{"\n"}{end}' 2>/dev/null || true)
    while IFS='|' read -r ns sc drv; do
        (( ${nss[(Ie)${ns}]} )) || continue
        OADP_INSTANCE_PVS=$(( OADP_INSTANCE_PVS + 1 ))
        key="${drv:-not CSI (${sc:-no storage class})}"
        pv_count[$key]=$(( ${pv_count[$key]:-0} + 1 ))
    done < <(oc get persistentvolumes \
        -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{"|"}{.spec.storageClassName}{"|"}{.spec.csi.driver}{"\n"}{end}' 2>/dev/null || true)

    (( OADP_INSTANCE_PVS )) || { echo "[INFO] No persistent volumes in $*"; return 0; }
    printf '  %-48s %5s  %s\n' "CSI driver" "PVs" "Snapshot class Velero uses"
    for key in ${(ko)pv_count}; do
        count="${pv_count[$key]}"
        if [[ "${key}" == "not CSI ("* ]]; then
            state="none - not a CSI volume, cannot be snapshotted"
            OADP_NO_SNAPSHOT_PVS=$(( OADP_NO_SNAPSHOT_PVS + count ))
        elif [[ -n "${labeled[$key]:-}" ]]; then
            state="${labeled[$key]}"
        elif [[ -n "${first_class[$key]:-}" ]]; then
            state="none labeled (${first_class[$key]} exists)"
            OADP_UNLABELED_SNAPCLASSES+=("${first_class[$key]}")
        else
            state="none - the driver has no VolumeSnapshotClass"
            OADP_NO_SNAPSHOT_PVS=$(( OADP_NO_SNAPSHOT_PVS + count ))
        fi
        printf '  %-48s %5s  %s\n' "${key}" "${count}" "${state}"
    done
}

# True when the DPA in OADP_PROJECT uploads CSI snapshot data to the bucket.
oadp_dpa_moves_snapshot_data() {
    oc get dataprotectionapplications.oadp.openshift.io -n "${OADP_PROJECT}" \
        -o jsonpath='{.items[*].spec.configuration.velero.defaultSnapshotMoveData}' 2>/dev/null | grep -qw true
}

# oadp_datamover_report <datauploads|datadownloads> <since, RFC3339 UTC>
# Summarises the data mover transfers created since <since>. Sets OADP_DM_TOTAL;
# returns 1 when any Failed or was Canceled.
oadp_datamover_report() {
    local kind="$1" since="$2" ts phase name summary=""
    local -A phases
    OADP_DM_TOTAL=0
    while IFS='|' read -r ts phase name; do
        [[ -z "${name}" || "${ts}" < "${since}" ]] && continue
        OADP_DM_TOTAL=$(( OADP_DM_TOTAL + 1 ))
        phase="${phase:-New}"
        phases[$phase]=$(( ${phases[$phase]:-0} + 1 ))
    done < <(oc get "${kind}.velero.io" -n "${OADP_PROJECT}" \
        -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"|"}{.status.phase}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    for phase in ${(ko)phases}; do summary+="${summary:+, }${phases[$phase]} ${phase}"; done
    echo "[INFO] ${kind} since ${since}: ${OADP_DM_TOTAL}${summary:+ (${summary})}"
    (( ${+phases[Failed]} || ${+phases[Canceled]} )) && return 1
    return 0
}
