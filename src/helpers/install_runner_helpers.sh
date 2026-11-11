#!/bin/zsh
# =============================================================================
# install_runner_helpers.sh - run install chains in cluster (ir_*)
# -----------------------------------------------------------------------------
# Workstation side of the in-cluster install runner. ir_dispatch (common_helpers.sh)
# loads this when INSTALL_RUN_MODE=cluster; scripts/install_runner/x_install_runner.sh
# loads it for attach, status, stop, resume, collect and teardown.
#
# A slot is one independently runnable install, with its own namespace, pod, volume
# and config, so several can run at once. Core code here never names a product:
# what is specific lives in src/install_runner/installs/<id>.{conf,sh}.
#
# Never use CPDM_OC_LOGIN or `cpd-cli manage` here: they recreate the local
# olm-utils container, which may be running something. OC_LOGIN only.
#
# Plan: .claude/plans/in-cluster-install-runner-plan.md
# =============================================================================

[[ -n "${_IR_HELPERS_LOADED:-}" ]] && return 0
_IR_HELPERS_LOADED=1

source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
# The cluster folder that owns a URL, and a config file's literal OCP_URL.
source "${_CP4D_REPO_ROOT}/src/helpers/multi_cluster_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/install_runner_slots.sh"

IR_SRC="${_CP4D_REPO_ROOT}/src/install_runner"
IR_SYSTEM_NS="install-runner-system"
IR_POD="install-runner-0"
IR_BIN_IN_POD="/opt/install-runner/bin"
IR_LABEL="app.kubernetes.io/managed-by=install-runner"
# The launched chain's arguments, for the module hooks (ir_handoff sets them).
typeset -ga _IR_CHAIN_ARGS=()

ir_info() { h_info "$@"; }
ir_warn() { h_warn "$@"; }
ir_die()  { h_die "$@"; }

# =============================================================================
# Install modules
# =============================================================================
ir_conf() {   # <id> <key>  -> value on stdout (empty when absent)
    local f="${IR_SRC}/installs/$1.conf"
    [[ -f "${f}" ]] || ir_die "No install module: $1 (${f})"
    awk -F= -v k="$2" '$1 == k { v = substr($0, index($0, "=") + 1); gsub(/^"|"$/, "", v); print v; exit }' "${f}"
}

ir_install_ids() {   # every module, without the template
    local f
    for f in "${IR_SRC}"/installs/*.conf(N); do
        [[ "${f:t:r}" == _template ]] || print -r -- "${f:t:r}"
    done
}

ir_install_for_chain() {   # <repo-relative chain> -> REPLY = install id
    local id
    REPLY=""
    for id in $(ir_install_ids); do
        if (( ${${(s: :)$(ir_conf "${id}" RUNNER_ENTRYPOINTS)}[(Ie)$1]} )); then
            REPLY="${id}"
            return 0
        fi
    done
    return 1
}

ir_hook() {   # <id> <verb> [args...] - run a module hook when the module has one
    local f="${IR_SRC}/installs/$1.sh"
    [[ -f "${f}" ]] || return 0
    zsh "${f}" "$2" "${@:3}"
}

# A hook that checks or sizes a launch sees the very folders that will be staged:
# IR_STAGED_<VAR> for each root, once _ir_stage_plan has worked them out, the
# chain in IR_HOOK_CHAIN (empty for x_install_runner.sh preflight), and the
# chain's arguments in IR_HOOK_ARGS, one per line (--skip / --only can leave a
# step out that a sidecar is only for).
_ir_hook_staged() {   # <id> <verb> [chain]
    (
        local snap
        if [[ -n "${_IR_PLANNED:-}" ]]; then
            for snap in "${(@k)_IR_ROOT_DIR}"; do
                export "IR_STAGED_${_IR_ROOT_VAR[${snap}]}=${_IR_ROOT_DIR[${snap}]}"
            done
        fi
        export IR_HOOK_CHAIN="${3:-}" IR_HOOK_ARGS="${(pj:\n:)_IR_CHAIN_ARGS[@]}"
        ir_hook "$1" "$2" "${3:-}"
    )
}

# =============================================================================
# Names
# =============================================================================
# Kubernetes names: lowercase alphanumerics and '-', at most 63 characters. A cut
# name keeps a hash of the whole, so two long ones can't collide.
_ir_dns_name() {   # <text> <max length> -> REPLY
    local name="${${(L)1}//[^a-z0-9-]/-}"
    if (( ${#name} > $2 )); then
        local hash="$(print -rn -- "$1" | _ir_sha | cut -c1-6)"
        name="${name[1,$(( $2 - 7 ))]}-${hash}"
    fi
    REPLY="${${name##-#}%%-#}"
}

_ir_sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    else shasum -a 256 | awk '{print $1}'
    fi
}

ir_slot() {   # <id> -> REPLY = slot
    local var instance=""
    var="$(ir_conf "$1" RUNNER_INSTANCE_VAR)"
    [[ -n "${var}" ]] && instance="${(P)var:-}"
    _ir_dns_name "$1${instance:+-${instance}}" 48
}

ir_namespace() { REPLY="install-runner-$1"; }
ir_admin_binding() { REPLY="install-runner-$1-admin"; }

# What a printed next step adds so it acts on this run's cluster (gap X14). Slot names
# do not carry the cluster, so without it a pasted command acts on the current cluster,
# or fans out. Empty for a flat run.
_ir_tc() {
    [[ -n "${MCM_CLUSTER:-}" ]] && print -rn -- " --target-cluster ${MCM_CLUSTER}"
    return 0
}

# =============================================================================
# Manifests
# =============================================================================
# Fills @KEY@ placeholders; one left over means a template and its caller disagree.
ir_render() {   # <template file name> KEY=value...
    local text pair
    text="$(<"${IR_SRC}/manifests/$1")"
    shift
    for pair in "$@"; do
        text="${text//@${pair%%=*}@/${pair#*=}}"
    done
    if [[ "${text}" =~ '@[A-Z_]+@' ]]; then
        ir_die "Unfilled placeholder in a manifest: ${MATCH}"
    fi
    print -r -- "${text}"
}

ir_apply() {   # <template> KEY=value...
    ir_render "$@" | oc apply -f - >/dev/null
}

# =============================================================================
# Runner image
# =============================================================================
ir_image_source() {
    if [[ -n "${INSTALL_RUNNER_IMAGE_SOURCE:-}" ]]; then print -r -- "${INSTALL_RUNNER_IMAGE_SOURCE}"
    elif [[ -n "${INSTALL_RUNNER_IMAGE:-}" ]]; then print -r -- prebuilt
    else print -r -- build-in-cluster
    fi
}

# <base tag>-<hash of what goes into the image>: an unchanged image is never rebuilt,
# and two instances on different patches get different images by themselves.
_ir_image_tag() {   # <base image> -> REPLY
    local base="$1" hash
    hash="$( { print -r -- "${base}"
               ( cd "${IR_SRC}/image" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do print -r -- "${f}"; cat "${f}"; done )
             } | _ir_sha | cut -c1-10)"
    REPLY="${base##*:}-${hash}"
}

_ir_cpd_cli_url() {   # -> stdout; empty when the install needs no cpd-cli
    [[ "$(ir_conf "$1" RUNNER_NEEDS_CPD_CLI)" == true ]] || return 0
    if [[ -n "${INSTALL_RUNNER_CPD_CLI_URL:-}" ]]; then
        print -r -- "${INSTALL_RUNNER_CPD_CLI_URL}"
        return 0
    fi
    source "${_CP4D_REPO_ROOT}/src/helpers/resolve_cpd_cli_release.sh"
    cpd_cli_resolve_release "${VERSION}" linux "${CPD_CLI_EDITION:-EE}" | awk -F'\t' '$1 == "URL" { print $2 }'
}

# Every build leaves a finished Build and its pod in the system namespace. Keeps
# the newest, which `oc logs bc/<name>` shows, and never one still going. Tidying
# only: a failure warns and the launch goes on.
_ir_prune_builds() {   # <build config>
    local bc="$1" json name pod n=0
    local -a old
    json="$(oc get builds -n "${IR_SYSTEM_NS}" -l "openshift.io/build-config.name=${bc}" -o json 2>/dev/null)" \
        || { ir_warn "Could not list the builds of ${bc} to prune old ones."; return 0; }
    old=("${(@f)$(print -r -- "${json}" | jq -r '
            [.items[] | {n: ((.metadata.annotations["openshift.io/build.number"] // "0") | tonumber? // 0),
                         t: (.metadata.creationTimestamp // ""), item: .}]
            | sort_by(.n, .t) | .[:-1][] | .item
            | select(.status.phase // "" | IN("New", "Pending", "Running") | not)
            | [.metadata.name, (.metadata.annotations["openshift.io/build.pod-name"] // (.metadata.name + "-build"))]
            | @tsv' 2>/dev/null)}") \
        || { ir_warn "Could not read the builds of ${bc} to prune old ones."; return 0; }
    for name in "${old[@]}"; do
        [[ -n "${name}" ]] || continue
        pod="${name#*$'\t'}" name="${name%%$'\t'*}"
        # The pod goes with its Build (owner reference); deleted by name too, as a stray one would stay.
        if oc delete build "${name}" -n "${IR_SYSTEM_NS}" --ignore-not-found >/dev/null 2>&1; then
            oc delete pod "${pod}" -n "${IR_SYSTEM_NS}" --ignore-not-found >/dev/null 2>&1 || true
            (( ++n ))
        else
            ir_warn "Could not delete the old build ${name} in ${IR_SYSTEM_NS}."
        fi
    done
    (( n == 0 )) || ir_info "Removed ${n} older build(s) of ${bc}."
    return 0
}

# Multi-cluster mode: a cluster-mode chain's env load takes no lease and starts nothing
# (gap X8), so the local build holds a lease of its own while podman works. Without it
# the idle watcher may stop the VM in the middle of a build or push (gap X8b). 0 when
# this call took the lease, 1 when the run already held one (a local-mode load's).
_ir_build_lease_take() {
    local held=1
    (( $+functions[mcm_take_lease] )) || source "${_CP4D_REPO_ROOT}/src/helpers/multi_cluster_helpers.sh"
    [[ " ${_MCM_LEASE_HELD:-} " == *" ${MCM_CLUSTER} "* ]] || held=0
    mcm_take_lease "${MCM_CLUSTER}"
    # The watcher may be stopping the VM right now; then it is started again.
    _mcm_wait_vm_stopping
    if mcm_podman_machine_needs_prep; then
        ir_info "Starting the podman VM for the image build (this can take a minute)..."
        zsh "${_CP4D_REPO_ROOT}/scripts/0.0_make_executable.sh" || ir_die "Could not start the podman VM for the image build."
        ir_info "Podman VM is up."
    fi
    return "${held}"
}

# After the push: counts as activity on the cluster, and drops a lease the build took.
_ir_build_lease_done() {   # <true when _ir_build_lease_take took the lease>
    [[ -n "${MCM_CPD_CLI_WORKSPACE:-}" ]] && { mkdir -p "${MCM_CPD_CLI_WORKSPACE}" && touch "${MCM_CPD_CLI_WORKSPACE}/.last_activity"; } 2>/dev/null
    [[ "$1" == true ]] && mcm_release_lease "${MCM_CLUSTER}"
    return 0
}

ir_image_ensure() {   # <id> -> REPLY = image reference
    local id="$1" var base tag source url
    source="$(ir_image_source)"
    if [[ "${source}" == prebuilt ]]; then
        [[ -n "${INSTALL_RUNNER_IMAGE:-}" ]] || ir_die "INSTALL_RUNNER_IMAGE_SOURCE=prebuilt needs INSTALL_RUNNER_IMAGE."
        ir_info "Runner image (prebuilt): ${INSTALL_RUNNER_IMAGE}"
        REPLY="${INSTALL_RUNNER_IMAGE}"
        return 0
    fi

    var="$(ir_conf "${id}" RUNNER_BASE_IMAGE_VAR)"
    base="${(P)var:-}"
    [[ -n "${base}" ]] || ir_die "${var:-RUNNER_BASE_IMAGE_VAR} is not set: no base image for the runner."
    _ir_image_tag "${base}"; tag="${REPLY}"

    case "${source}" in
        build-in-cluster)
            local ref="image-registry.openshift-image-registry.svc:5000/${IR_SYSTEM_NS}/install-runner:${tag}"
            if oc get istag "install-runner:${tag}" -n "${IR_SYSTEM_NS}" >/dev/null 2>&1; then
                ir_info "Runner image is up to date (${tag})."
                REPLY="${ref}"
                return 0
            fi
            url="$(_ir_cpd_cli_url "${id}")" || ir_die "Could not resolve the Linux cpd-cli download. Set INSTALL_RUNNER_CPD_CLI_URL."
            _ir_dns_name "install-runner-${tag}" 63; local build="${REPLY}"
            # The build lives in the system namespace, which the first launch on a
            # cluster has not created yet (ir_slot_apply comes later).
            ir_apply system.yaml.tmpl SYSTEM_NAMESPACE="${IR_SYSTEM_NS}"
            ir_apply build.yaml.tmpl SYSTEM_NAMESPACE="${IR_SYSTEM_NS}" BUILD_NAME="${build}" \
                BASE_IMAGE="${base}" CPD_CLI_URL="${url}" IMAGE_TAG="${tag}"
            ir_info "Building the runner image in cluster (${tag})..."
            oc start-build "${build}" -n "${IR_SYSTEM_NS}" --from-dir="${IR_SRC}/image" --follow --wait \
                || ir_die "Runner image build failed. See: oc logs -n ${IR_SYSTEM_NS} bc/${build}"
            _ir_prune_builds "${build}"
            REPLY="${ref}"
            ;;
        build-local-push)
            h_missing_vars PRIVATE_REGISTRY_LOCATION PRIVATE_REGISTRY_PUSH_USER PRIVATE_REGISTRY_PUSH_PASSWORD \
                || ir_die "build-local-push needs: ${REPLY}"
            local ref="${PRIVATE_REGISTRY_LOCATION}/install-runner/install-runner:${tag}"
            url="$(_ir_cpd_cli_url "${id}")" || ir_die "Could not resolve the Linux cpd-cli download. Set INSTALL_RUNNER_CPD_CLI_URL."
            local lease_taken=false
            if [[ -n "${MCM_CLUSTER:-}" ]] && _ir_build_lease_take; then
                lease_taken=true
            fi
            ir_info "Building ${ref} here (linux/amd64)..."
            podman build --platform linux/amd64 -f "${IR_SRC}/image/Containerfile" -t "${ref}" \
                --build-arg "BASE_IMAGE=${base}" --build-arg "CPD_CLI_URL=${url}" "${IR_SRC}/image"
            print -r -- "${PRIVATE_REGISTRY_PUSH_PASSWORD}" \
                | podman login --username "${PRIVATE_REGISTRY_PUSH_USER}" --password-stdin "${PRIVATE_REGISTRY_LOCATION%%/*}" >/dev/null
            podman push "${ref}"
            [[ -z "${MCM_CLUSTER:-}" ]] || _ir_build_lease_done "${lease_taken}"
            REPLY="${ref}"
            ;;
        *) ir_die "Unknown INSTALL_RUNNER_IMAGE_SOURCE=${source}" ;;
    esac
}

# =============================================================================
# Preflight
# =============================================================================
ir_storage_class() {   # <id> -> stdout
    local var
    var="$(ir_conf "$1" RUNNER_STORAGE_CLASS_VAR)"
    print -r -- "${INSTALL_RUNNER_STORAGE_CLASS:-${(P)var:-}}"
}

# Prints every problem before stopping, so one run shows all that needs fixing.
ir_preflight() {   # <id> [chain]
    local id="$1" chain="${2:-}" rc=0 sc source state
    ir_info "Preflight for $(ir_conf "${id}" INSTALL_LABEL)"

    if [[ "$(oc auth can-i '*' '*' 2>/dev/null)" != yes ]]; then
        h_error "This login is not cluster-admin: it can't create the runner's namespace and binding."
        rc=1
    fi
    sc="$(ir_storage_class "${id}")"
    if [[ -z "${sc}" ]]; then
        h_error "No storage class for the runner's volume: set INSTALL_RUNNER_STORAGE_CLASS."
        rc=1
    elif ! oc get storageclass "${sc}" >/dev/null 2>&1; then
        h_error "Storage class ${sc} does not exist on this cluster."
        rc=1
    fi
    source="$(ir_image_source)"
    if [[ "${source}" == build-in-cluster ]]; then
        state="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || true)"
        if [[ "${state}" != Managed ]]; then
            h_error "The internal image registry is '${state:-unknown}', not Managed. Set INSTALL_RUNNER_IMAGE_SOURCE=build-local-push or prebuilt."
            rc=1
        fi
    fi
    # A registry on this machine stops serving images when the machine goes off.
    if [[ -n "${LOCAL_REGISTRY_HOST:-}" || "${CPD_IMAGE_SOURCE:-}" == local ]]; then
        if [[ "${INSTALL_RUNNER_ALLOW_LOCAL_REGISTRY:-false}" != true ]]; then
            h_error "A local registry can't outlive this machine. Set INSTALL_RUNNER_ALLOW_LOCAL_REGISTRY=true if it runs elsewhere."
            rc=1
        fi
    fi
    # The module checks the very folders that will be staged (hand-off and preflight verb).
    _ir_hook_staged "${id}" preflight "${chain}" || rc=1
    # Two runs on one cluster share its cluster-wide steps (the global pull secret, the
    # mirror sets, the cluster components), and those are not locked against each other
    # yet (plan G8): a lost pull-secret update breaks image pulls on every node. So one
    # run per cluster, unless asked (gap X10). This install's own slot is the busy-slot
    # check's.
    local -a active
    active=(${(f)"$(ir_active_slots)"})
    ir_slot "${id}"; active=("${(@)active:#${REPLY}}")
    if (( ${#active} )); then
        if [[ "${INSTALL_RUNNER_ALLOW_PARALLEL:-false}" == true ]]; then
            ir_warn "Also running on this cluster: ${(j:, :)active}. Cluster-wide steps are not locked against each other yet."
        else
            h_error "Also running on this cluster: ${(j:, :)active}. Cluster-wide steps are not locked against each other yet, so one run at a time."
            h_error "Wait for it to end, or set INSTALL_RUNNER_ALLOW_PARALLEL=true to run both anyway."
            rc=1
        fi
    fi
    (( rc == 0 )) || ir_die "Preflight failed: nothing was changed."
    ir_info "Preflight passed."
}

ir_active_slots() {   # slots with a live run, one per line
    oc get configmap -A -l "${IR_LABEL}" -o json 2>/dev/null \
        | jq -r '.items[] | select(.metadata.name == "ir-status")
                 | select(.data.state | IN("staged", "running", "interrupted")) | .data.slot' 2>/dev/null || true
}

# =============================================================================
# Slot resources
# =============================================================================
ir_grant_admin() {   # <slot>
    local ns binding
    ir_namespace "$1"; ns="${REPLY}"
    ir_admin_binding "$1"; binding="${REPLY}"
    ir_apply admin-binding.yaml.tmpl ADMIN_BINDING="${binding}" SLOT="$1" NAMESPACE="${ns}"
}

ir_slot_status_value() {   # <namespace> <key>
    oc get configmap ir-status -n "$1" -o jsonpath="{.data.$2}" 2>/dev/null || true
}

# What the slot's pod spec needs, worked out without changing the cluster: the
# sidecars hook and, for a sidecar, its image pinned by digest (a read of the
# registry). ir_handoff runs it before the slot's launch record, so a refusal here
# leaves neither a slot nor a record of one.
ir_slot_prepare() {   # <id> <slot> <image> [chain] -> _IR_SLOT_EXTRA, _IR_SLOT_SIDECAR
    local id="$1" slot="$2" image="$3" chain="${4:-}" ns line sidecar
    ir_namespace "${slot}"; ns="${REPLY}"
    # Empty unless the module's sidecars hook asks for one: the slot then renders
    # exactly as it always has.
    typeset -ga _IR_SLOT_EXTRA=(POD_ANNOTATIONS_EXTRA= POD_SPEC_EXTRA= INIT_CONTAINERS= SIDECARS= RUNNER_ENV_EXTRA= RUNNER_MOUNTS_EXTRA= VOLUMES_EXTRA=)
    typeset -g _IR_SLOT_SIDECAR="" _IR_SWHCC_PULL=""
    line="$(_ir_hook_staged "${id}" sidecars "${chain}")" || ir_die "The ${id} sidecars hook failed: nothing was changed."
    line="${line%%$'\n'*}"
    sidecar="${line%%$'\t'*}"
    case "${sidecar}" in
        "")    ;;
        swhcc) _ir_swhcc_slot_extra "${ns}" "${slot}" "${image}" "${line}" ;;
        *)     ir_die "The ${id} sidecars hook asks for '${sidecar}', which the runner does not know." ;;
    esac
    _IR_SLOT_SIDECAR="${sidecar}"
    typeset -g _IR_SLOT_PREPARED="${slot}"
}

ir_slot_apply() {   # <id> <slot> <image> [chain]
    local id="$1" slot="$2" image="$3" chain="${4:-}" ns binding size selector="{}" sidecar
    ir_namespace "${slot}"; ns="${REPLY}"
    ir_admin_binding "${slot}"; binding="${REPLY}"
    size="${INSTALL_RUNNER_PVC_SIZE:-$(ir_conf "${id}" RUNNER_PVC_SIZE)}"
    if [[ -n "${INSTALL_RUNNER_NODE_SELECTOR:-}" ]]; then
        selector="{\"${INSTALL_RUNNER_NODE_SELECTOR%%=*}\": \"${INSTALL_RUNNER_NODE_SELECTOR#*=}\"}"
    fi
    [[ "${_IR_SLOT_PREPARED:-}" == "${slot}" ]] || ir_slot_prepare "${id}" "${slot}" "${image}" "${chain}"
    unset _IR_SLOT_PREPARED
    sidecar="${_IR_SLOT_SIDECAR}"
    # The first change on the cluster: the sidecar's pull secret, linked before the pod starts.
    [[ "${sidecar}" == swhcc ]] && _ir_swhcc_pull_apply "${ns}" "${slot}"

    # A StatefulSet already there may have had another pod spec (a sidecar the
    # last run had and this one does not, or the other way round).
    local existed=""
    oc get statefulset install-runner -n "${ns}" >/dev/null 2>&1 && existed=1

    ir_apply system.yaml.tmpl SYSTEM_NAMESPACE="${IR_SYSTEM_NS}"
    # SOURCE_CLUSTER: this checkout's name for the cluster, shown by status (gap X16).
    # For display only: names are per checkout, the URL is the identity.
    ir_apply slot.yaml.tmpl NAMESPACE="${ns}" SLOT="${slot}" IMAGE="${image}" NODE_SELECTOR="${selector}" \
        OCP_URL="${OCP_URL:-}" SOURCE_CLUSTER="${MCM_CLUSTER:-}" ADMIN_BINDING="${binding}" \
        AUTO_RESUME="${INSTALL_RUNNER_AUTO_RESUME:-true}" MAX_RESUMES="${INSTALL_RUNNER_MAX_RESUMES:-3}" \
        KEEP_ADMIN="${INSTALL_RUNNER_KEEP_ADMIN:-false}" TTY_SIZE="${INSTALL_RUNNER_TTY_SIZE:-120x50}" \
        CPU_REQUEST="$(ir_conf "${id}" RUNNER_CPU_REQUEST)" \
        MEMORY_REQUEST="$(ir_conf "${id}" RUNNER_MEMORY_REQUEST)" \
        MEMORY_LIMIT="$(ir_conf "${id}" RUNNER_MEMORY_LIMIT)" \
        "${_IR_SLOT_EXTRA[@]}"
    # A PVC's size can't be applied over an existing one.
    if ! oc get pvc install-runner-work -n "${ns}" >/dev/null 2>&1; then
        ir_apply pvc.yaml.tmpl NAMESPACE="${ns}" STORAGE_CLASS="$(ir_storage_class "${id}")" PVC_SIZE="${size}"
    fi
    if [[ "${image}" == image-registry.openshift-image-registry.svc:* ]]; then
        ir_apply image-puller.yaml.tmpl NAMESPACE="${ns}" SYSTEM_NAMESPACE="${IR_SYSTEM_NS}"
    fi
    ir_grant_admin "${slot}"
    # A changed pod spec replaces the pod. Until the new one is up, `oc exec` can
    # still reach the old one while it terminates, and stage into a dying pod.
    # Unchanged, this returns at once. A new slot has no old pod: ir_wait_pod
    # waits for it, with progress.
    if [[ -n "${existed}" || -n "${sidecar}" ]]; then
        ir_info "Waiting for the runner pod${sidecar:+ with its ${sidecar} sidecar} to be on the current spec..."
        # The slot is idle (ir_refuse_busy_slot ran first), so deleting a stuck pod loses nothing.
        oc rollout status sts/install-runner -n "${ns}" --timeout="${INSTALL_RUNNER_ROLLOUT_TIMEOUT:-900}s" >/dev/null \
            || ir_die "The runner pod did not come up${sidecar:+ with its sidecar}. See: oc describe pod ${IR_POD} -n ${ns}. If it is stuck, delete it (the slot is idle): oc delete pod ${IR_POD} -n ${ns}"
    fi
}

# =============================================================================
# Sidecars
# =============================================================================
# One "### NAME" section of a fragments template, with a newline in front: each
# goes in at the end of a line of slot.yaml.tmpl.
_ir_fragment() {   # <template file name> <section> -> stdout
    local text
    text="$(awk -v want="$2" '/^### / { on = ($2 == want); next } on' "${IR_SRC}/manifests/$1")"
    [[ -n "${text}" ]] || ir_die "No section ${2} in manifests/$1."
    print -rn -- $'\n'"${text}"
}

# The Control Center sidecar (D4): the premium olm-utils image next to the runner.
# The hook line is "swhcc<TAB><premium image by tag><TAB><same|different>".
_ir_swhcc_slot_extra() {   # <namespace> <slot> <runner image> <hook line> -> _IR_SLOT_EXTRA
    local ns="$1" slot="$2" image="$3" rest="${4#*$'\t'}" source mode pinned name text pair
    source="${rest%%$'\t'*}" mode="${rest#*$'\t'}"
    [[ "${rest}" == *$'\t'* && -n "${source}" ]] || ir_die "The Control Center sidecar has no image: is swhub_control_center_vars.sh there?"
    [[ "${mode}" == (same|different) ]] || ir_die "CONTROL_CLUSTER_MODE must be same or different (got '${mode}')."
    _ir_swhcc_image_resolve "${ns}" "${slot}" "${source}"
    pinned="${REPLY}"
    local -a fill=(IMAGE="${image}" SWHCC_IMAGE="${pinned}" SWHCC_IMAGE_SOURCE="${source}" SWHCC_MODE="${mode}"
                   SWHCC_MEMORY_LIMIT="${INSTALL_RUNNER_SWHCC_MEMORY_LIMIT:-4Gi}"
                   SWHCC_IMAGE_OVERRIDE="${INSTALL_RUNNER_SWHCC_IMAGE:-}" SIDECAR_SA_MOUNT=)
    # The service account token reaches the sidecar only when its cluster is this one.
    [[ "${mode}" == same ]] && fill[-1]="SIDECAR_SA_MOUNT=$(_ir_fragment swhcc-sidecar.fragments.tmpl SIDECAR_SA_MOUNT)"
    _IR_SLOT_EXTRA=()
    for name in POD_ANNOTATIONS_EXTRA POD_SPEC_EXTRA INIT_CONTAINERS SIDECARS RUNNER_ENV_EXTRA RUNNER_MOUNTS_EXTRA VOLUMES_EXTRA; do
        text="$(_ir_fragment swhcc-sidecar.fragments.tmpl "${name}")"
        for pair in "${fill[@]}"; do
            text="${text//@${pair%%=*}@/${pair#*=}}"
        done
        _IR_SLOT_EXTRA+=("${name}=${text}")
    done
}

# Pins the premium image by digest, so an eviction can't pick up a moved tag in the
# middle of a run, and gives the slot's service account a cp.icr.io pull secret.
# No imagePullSecrets on the pod: a pod-level list would drop the service account's
# own secret for the internal registry, which the runner image comes from. Runs on
# this machine after preflight; the key only ever goes through stdin and a private
# temp file, never an argument. Removing the slot namespace removes the secret.
# INSTALL_RUNNER_SWHCC_IMAGE (a mirrored premium image) skips the pull secret, and
# INSTALL_RUNNER_SWHCC_PULL_SECRET names one already in the slot namespace for it.
ir_swhcc_image_prepare() {   # <namespace> <slot> <premium image by tag> -> REPLY = image for the pod spec
    _ir_swhcc_image_resolve "$@"
    local pinned="${REPLY}"
    _ir_swhcc_pull_apply "$1" "$2"
    REPLY="${pinned}"
}

# The read-only half, run before the launch record: the digest, or the check that a
# named pull secret is there. What the slot's service account then needs goes in
# _IR_SWHCC_PULL ("link <secret>", "create <registry host>" or empty).
_ir_swhcc_image_resolve() {   # <namespace> <slot> <premium image by tag> -> REPLY, _IR_SWHCC_PULL
    local ns="$1" slot="$2" source="$3" host arch af ef info digest why rc=0
    typeset -g _IR_SWHCC_PULL=""
    if [[ -n "${INSTALL_RUNNER_SWHCC_IMAGE:-}" ]]; then
        ir_info "Control Center sidecar image (INSTALL_RUNNER_SWHCC_IMAGE): ${INSTALL_RUNNER_SWHCC_IMAGE}"
        if [[ -n "${INSTALL_RUNNER_SWHCC_PULL_SECRET:-}" ]]; then
            oc get secret "${INSTALL_RUNNER_SWHCC_PULL_SECRET}" -n "${ns}" >/dev/null 2>&1 \
                || ir_die "INSTALL_RUNNER_SWHCC_PULL_SECRET=${INSTALL_RUNNER_SWHCC_PULL_SECRET} is not in ${ns}. Create it there first (oc create secret docker-registry ... -n ${ns})."
            _IR_SWHCC_PULL="link ${INSTALL_RUNNER_SWHCC_PULL_SECRET}"
        fi
        REPLY="${INSTALL_RUNNER_SWHCC_IMAGE}"
        return 0
    fi
    [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]] || ir_die "IBM_ENTITLEMENT_KEY is needed to pull ${source}."
    host="${source%%/*}"
    # The tag ends in the node arch (swhcc_pod_image put it there).
    arch="${source##*.}"
    [[ "${arch}" == (amd64|arm64|ppc64le|s390x) ]] || arch="${IMAGE_ARCH:-amd64}"
    ir_info "Pinning the Control Center sidecar image ${source} (linux/${arch})..."
    af="$(umask 077; mktemp "${TMPDIR:-/tmp}/ir-swhcc-auth.XXXXXX")" || ir_die "Could not make a temp file."
    ef="$(umask 077; mktemp "${TMPDIR:-/tmp}/ir-swhcc-err.XXXXXX")" || { rm -f "${af}"; ir_die "Could not make a temp file."; }
    {
        IR_KEY="${IBM_ENTITLEMENT_KEY}" IR_HOST="${host}" \
            jq -n '{auths: {(env.IR_HOST): {auth: ("cp:" + env.IR_KEY | @base64)}}}' > "${af}" || rc=1
        # stderr apart: a warning line from oc would otherwise break the JSON.
        (( rc )) || info="$(oc image info --registry-config "${af}" --filter-by-os "linux/${arch}" -o json "${source}" 2>"${ef}")" || rc=1
        why="$(tail -n 1 "${ef}" 2>/dev/null)"
    } always {
        rm -f "${af}" "${ef}"
    }
    digest="$(print -r -- "${info:-}" | jq -r '.digest // empty' 2>/dev/null || true)"
    if (( rc )) || [[ "${digest}" != sha256:* ]]; then
        ir_die "Could not read ${source} with IBM_ENTITLEMENT_KEY: ${why:-${${info:-no answer}##*$'\n'}}"
    fi
    local repo="${source}"
    [[ "${source:t}" == *:* ]] && repo="${source%:*}"
    REPLY="${repo}@${digest}"
    ir_info "Pinned it at ${digest}: the tag moves with IBM's patches, this slot keeps this build."
    _IR_SWHCC_PULL="create ${host}"
}

# The half that changes the cluster: the slot's namespace and service account, with
# the pull secret _ir_swhcc_image_resolve asked for linked to it.
_ir_swhcc_pull_apply() {   # <namespace> <slot>
    local ns="$1" slot="$2" what="${_IR_SWHCC_PULL:-}"
    case "${what}" in
        "") ;;
        link\ *)
            _ir_slot_namespace_sa "${ns}" "${slot}"
            oc secrets link install-runner "${what#link }" --for=pull -n "${ns}" >/dev/null \
                || ir_die "Could not link ${what#link } to the runner's service account."
            ;;
        create\ *)
            [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]] || ir_die "IBM_ENTITLEMENT_KEY is needed for the sidecar's pull secret."
            _ir_slot_namespace_sa "${ns}" "${slot}"
            IR_KEY="${IBM_ENTITLEMENT_KEY}" IR_HOST="${what#create }" jq -n --arg ns "${ns}" '{
                apiVersion: "v1", kind: "Secret", type: "kubernetes.io/dockerconfigjson",
                metadata: {name: "ir-cp-icr-pull", namespace: $ns, labels: {"app.kubernetes.io/managed-by": "install-runner"}},
                data: {".dockerconfigjson": ({auths: {(env.IR_HOST): {auth: ("cp:" + env.IR_KEY | @base64)}}} | tojson | @base64)}}' \
                | oc apply -f - >/dev/null || ir_die "Could not create the sidecar's pull secret in ${ns}."
            oc secrets link install-runner ir-cp-icr-pull --for=pull -n "${ns}" >/dev/null \
                || ir_die "Could not link the sidecar's pull secret to the runner's service account."
            ;;
        *) ir_die "Unknown sidecar pull secret step: ${what}" ;;
    esac
}

# The slot's namespace and service account, ahead of slot.yaml.tmpl (which applies
# the same), so a pull secret can be linked before the pod first starts.
_ir_slot_namespace_sa() {   # <namespace> <slot>
    oc create namespace "$1" --dry-run=client -o yaml \
        | oc label --local -f - app.kubernetes.io/managed-by=install-runner "install-runner/slot=$2" --dry-run=client -o yaml \
        | oc apply -f - >/dev/null || ir_die "Could not create namespace $1."
    oc create serviceaccount install-runner -n "$1" --dry-run=client -o yaml \
        | oc label --local -f - app.kubernetes.io/managed-by=install-runner --dry-run=client -o yaml \
        | oc apply -f - >/dev/null || ir_die "Could not create the runner's service account in $1."
}

ir_wait_pod() {   # <namespace> [timeout-s, default 900]
    local ns="$1" timeout="${2:-900}" start=${SECONDS} phase="" last=-30
    while (( SECONDS - start < timeout )); do
        if oc exec -n "${ns}" "${IR_POD}" -- true >/dev/null 2>&1; then
            return 0
        fi
        if (( SECONDS - last >= 15 )); then
            phase="$(oc get pod "${IR_POD}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
            ir_info "Waiting for the runner pod (${phase:-not created yet}, $(( SECONDS - start ))s)..."
            last=${SECONDS}
        fi
        sleep 3
    done
    ir_die "Runner pod not ready after ${timeout}s. See: oc describe pod ${IR_POD} -n ${ns}"
}

# =============================================================================
# Snapshot and run
# =============================================================================
# The pod always sees the flat layout (plan §5): each root a module names
# (RUNNER_STAGE_ROOTS) goes to its fixed place in the snapshot, wherever it lives
# here (configs/ or configs/clusters/<name>/), and collect maps it back from the
# run's path record. Nothing below is ever staged, whatever names it: home folders
# with logins, cluster markers, the multi-cluster state file, workspaces (large,
# and other products' data), conflict copies and backups.
_ir_pruned() {   # <path> -> 0 when it must never reach a pod
    local p="$1" seg
    local -a segs=(${(s:/:)p})
    [[ "${p}" == configs/multi_cluster_management.sh || "${p}" == configs/clusters(|/*) ]] && return 0
    for seg in "${segs[@]}"; do
        [[ "${seg}" == (.home|.kube|.cpd-cli|*_workspace|cpd-cli-workspace|registry_mirror_cluster|oadp) ]] && return 0
    done
    [[ "${segs[-1]}" == (.cluster|.DS_Store|*.bak*|*.in-cluster-*) ]]
}

# Files under a folder, relative to it. The prune stops find from walking into a
# workspace that can hold gigabytes.
_ir_find_files() {   # <folder> -> NUL-separated paths
    local f
    ( cd "$1" && find . \( -name .home -o -name .kube -o -name .cpd-cli -o -name '*_workspace' \
                          -o -name cpd-cli-workspace -o -name registry_mirror_cluster -o -name oadp \) -prune \
                       -o -type f -print0 ) \
        | while IFS= read -r -d '' f; do
              f="${f#./}"
              _ir_pruned "${f}" || print -rn -- "${f}"$'\0'
          done | LC_ALL=C sort -zu
}

# Repo code the way it is right now, including uncommitted work. Config comes only
# through the roots: never configs/clusters/ or the state file, even if tracked.
_ir_snapshot_files() {   # <id> -> NUL-separated paths, repo-relative
    local f
    ( cd "${_CP4D_REPO_ROOT}" || exit 1
      git ls-files -z -c -o --exclude-standard | while IFS= read -r -d '' f; do
          # if, not &&: a skipped last file must not fail the pipeline.
          if [[ -f "${f}" ]] && ! _ir_pruned "${f}"; then print -rn -- "${f}"$'\0'; fi
      done ) | LC_ALL=C sort -zu
}

_ir_count_nul() { tr -cd '\0' | wc -c | tr -d ' '; }

# Snapshot paths are module constants, used in a pod shell command: keep them plain.
_ir_snapshot_path_ok() {   # <path>
    [[ "$1" == [A-Za-z0-9_]* && "$1" != *[^A-Za-z0-9._/-]* && "$1" != */ \
       && "/$1/" != */../* && "/$1/" != */./* && "$1" != configs/clusters(|/*) ]]
}

# Allowlist for a root (plan §5.3, X3): one product's config folder, or the service
# instance folder. Never a whole cluster folder, nor anything inside a home folder.
_ir_root_allowed() {   # <absolute folder> <repo-relative folder> -> 0, or 1 with why in REPLY
    local seg
    for seg in ${(s:/:)2}; do
        if [[ "${seg}" == (.home|.kube|.cpd-cli) ]]; then
            REPLY="it is inside a ${seg} folder, which holds logins"
            return 1
        fi
    done
    if [[ "$2" == (configs|configs/clusters) || ( "$2" == configs/clusters/* && "$2" != configs/clusters/*/* ) ]]; then
        REPLY="it is a whole configs folder, with logins and workspaces"
        return 1
    fi
    [[ "${1:t}" == *_config ]] && return 0
    [[ -n "${SERVICE_INSTANCE_FILE_DIR:-}" && "$1" == "${SERVICE_INSTANCE_FILE_DIR:A}" ]] && return 0
    REPLY="only *_config folders and SERVICE_INSTANCE_FILE_DIR can be staged"
    return 1
}

# Resolves "<LOCAL_VAR>:<snapshot path>" pairs from the loaded env, so a pinned run
# stages its cluster's folders and a flat run the flat ones.
_ir_resolve_roots() {   # <id> <conf key> -> reply = snapshot paths; fills _IR_ROOT_DIR, _IR_ROOT_VAR
    local id="$1" key="$2" pair var snap dir rel repo="${_CP4D_REPO_ROOT:A}"
    reply=()
    for pair in ${(s: :)$(ir_conf "${id}" "${key}")}; do
        var="${pair%%:*}" snap="${pair#*:}"
        [[ "${pair}" == *:* && "${var}" == [A-Za-z_]* && "${var}" != *[^A-Za-z0-9_]* ]] \
            || ir_die "${key} in ${id}.conf: '${pair}' is not <LOCAL_VAR>:<snapshot path>."
        _ir_snapshot_path_ok "${snap}" || ir_die "${key} in ${id}.conf: '${snap}' is not a plain relative path."
        dir="${(P)var:-}"
        [[ -n "${dir}" ]] || ir_die "${key} in ${id}.conf names ${var}, which the loaded config does not set."
        dir="${dir:A}"
        # Missing is fine (a collect root the run creates); a file is not a root.
        [[ ! -e "${dir}" || -d "${dir}" ]] || ir_die "${key} in ${id}.conf names ${var}=${dir}, which is not a folder."
        [[ "${dir}" == "${repo}"/* ]] || ir_die "${var}=${dir} is outside this checkout: the runner stages only the repo's config folders."
        rel="${dir#${repo}/}"
        _ir_root_allowed "${dir}" "${rel}" || ir_die "Refusing to stage ${var}=${rel}: ${REPLY}."
        if [[ -n "${_IR_ROOT_DIR[${snap}]:-}" && "${_IR_ROOT_DIR[${snap}]}" != "${dir}" ]]; then
            ir_die "${id}.conf maps two folders to ${snap}: ${_IR_ROOT_DIR[${snap}]} and ${dir}."
        fi
        _IR_ROOT_DIR[${snap}]="${dir}"
        _IR_ROOT_VAR[${snap}]="${var}"
        (( ${reply[(Ie)${snap}]} )) || reply+=("${snap}")
    done
}

# X1: a config written for another cluster must not run on this session's cluster.
# Only a literal OCP_URL can be checked; a ${reference} is left to the load.
_ir_refuse_other_cluster_config() {   # <config file>
    local literal here="${${OCP_URL:-}%/}"
    literal="$(_mcm_config_file_url "$1")"
    # Compared as MCM compares clusters (host and port, any case), so one cluster
    # written two ways is not refused.
    [[ -z "${literal}" || "$(_mcm_url_key "${literal}")" == "$(_mcm_url_key "${here}")" ]] && return 0
    ir_die "${1#${_CP4D_REPO_ROOT:A}/} is for ${literal%/}, but this session is on ${here:-no cluster (OCP_URL is empty)}. Nothing was staged. Load the config of the cluster you mean, or fix OCP_URL in that file."
}

# Chains whose config is not the install's own: RUNNER_CHAIN_ENV_TARGETS,
# space-separated "<chain>=<bare target>" (cpd.conf: the Control Center chain).
_ir_chain_env_target() {   # <id> <chain> -> REPLY = bare target, or empty
    local entry
    REPLY=""
    for entry in ${(s: :)$(ir_conf "$1" RUNNER_CHAIN_ENV_TARGETS)}; do
        [[ "${entry%%=*}" == "$2" ]] && { REPLY="${entry#*=}"; return 0; }
    done
    return 0
}

# X4: the pod loads the file this session loaded. Its place in the snapshot goes to
# run.env; the bare name stays when env_bootstrap inferred it (not exported), since
# the pod infers the same. A file outside the roots but inside the repo is staged
# at its flat place.
_ir_plan_env_target() {   # <id> <chain> -> _IR_ENV_TARGET, _IR_ENV_TARGET_REL; may add to _IR_EXTRA_PAIRS
    local id="$1" chain="$2" file snap dir rel="" repo="${_CP4D_REPO_ROOT:A}" configs
    if [[ -z "${ENV_TARGET:-}" || "${ENV_TARGET}" == all ]]; then
        ir_die "ENV_TARGET=${ENV_TARGET:-all} loads every config, but a runner pod gets one install's config. Pick one with --env-target <name|file>."
    fi
    # The guard runs for a chain-specific target too: the file loaded here still says
    # which cluster this session meant.
    file="${ENV_TARGET_FILE:-}"
    [[ -n "${file}" && -f "${file}" ]] && _ir_refuse_other_cluster_config "${file:A}"
    _ir_chain_env_target "${id}" "${chain}"
    if [[ -n "${REPLY}" ]]; then
        typeset -g _IR_ENV_TARGET="${REPLY}" _IR_ENV_TARGET_REL="${REPLY}"
        return 0
    fi
    [[ -n "${file}" && -f "${file}" ]] || ir_die "ENV_TARGET=${ENV_TARGET} loaded no config file here: nothing to stage."
    file="${file:A}"
    for snap in "${_IR_STAGE_ROOTS[@]}"; do
        dir="${_IR_ROOT_DIR[${snap}]}"
        if [[ "${file}" == "${dir}"/* ]]; then
            rel="${snap}/${file#${dir}/}"
            break
        fi
    done
    if [[ -n "${rel}" && "${(t)ENV_TARGET}" != *export* ]]; then
        typeset -g _IR_ENV_TARGET="${ENV_TARGET}" _IR_ENV_TARGET_REL="${rel}"
        return 0
    fi
    if [[ -z "${rel}" ]]; then
        [[ "${file}" == "${repo}"/* ]] || ir_die "The config ${file} is outside this checkout: the runner can't stage it."
        configs="${${CONFIGS_ROOT:-${repo}/configs}:A}"
        if [[ "${file}" == "${configs}"/* ]]; then
            # The flat name: configs/<product>_config/..., from either layout.
            rel="configs/${file#${configs}/}"
        elif [[ "${file#${repo}/}" == configs/* ]]; then
            ir_die "The config ${file#${repo}/} belongs to another cluster folder than this session's (${configs#${repo}/})."
        else
            rel="${file#${repo}/}"
        fi
        if _ir_pruned "${rel}" || ! _ir_snapshot_path_ok "${rel}"; then
            ir_die "The config ${file#${repo}/} is in a place the runner never stages (${rel})."
        fi
        _IR_EXTRA_PAIRS+=("${file}"$'\t'"${rel}")
    fi
    typeset -g _IR_ENV_TARGET="${rel}" _IR_ENV_TARGET_REL="${rel}"
}

# A module's own extras: its `stage` hook prints "<source>\t<snapshot path>" lines
# (source absolute or repo-relative, a file or a folder).
_ir_plan_hook_pairs() {   # <id> -> adds to _IR_EXTRA_PAIRS
    local id="$1" out line src snap seg rel repo="${_CP4D_REPO_ROOT:A}"
    out="$(ir_hook "${id}" stage)" || ir_die "The ${id} stage hook failed: nothing was staged."
    for line in "${(@f)out}"; do
        [[ -n "${line}" ]] || continue
        [[ "${line}" == *$'\t'* ]] || ir_die "The ${id} stage hook printed '${line}', not <source><TAB><snapshot path>."
        src="${line%%$'\t'*}" snap="${line#*$'\t'}"
        [[ "${src}" == /* ]] || src="${_CP4D_REPO_ROOT}/${src}"
        [[ -e "${src}" ]] || ir_die "The ${id} stage hook names ${src}, which does not exist."
        src="${src:A}"
        _ir_snapshot_path_ok "${snap}" || ir_die "The ${id} stage hook gave '${snap}', not a plain relative path."
        for seg in ${(s:/:)src}; do
            [[ "${seg}" == (.home|.kube|.cpd-cli) ]] && ir_die "Refusing to stage ${src}: it is inside a ${seg} folder, which holds logins."
        done
        # A hook may name a workspace file (an archive, an inventory), but never what
        # would pin the pod, nor a whole cluster folder with its logins.
        rel="${src#${repo}/}"
        if [[ "${src:t}" == .cluster || "${rel}" == (configs|configs/clusters|configs/multi_cluster_management.sh) \
              || ( "${rel}" == configs/clusters/* && "${rel}" != configs/clusters/*/* ) ]]; then
            ir_die "Refusing to stage ${rel}: cluster markers, the multi-cluster state file and whole cluster folders never go to a pod."
        fi
        _IR_EXTRA_PAIRS+=("${src}"$'\t'"${snap}")
    done
}

# Everything ir_stage needs that can be worked out on this machine. ir_handoff calls
# it before touching the cluster, so a refusal leaves nothing behind.
_ir_stage_plan() {   # <id> <chain>
    local id="$1" chain="$2"
    [[ "${_IR_PLANNED:-}" == "${id}|${chain}" ]] && return 0
    typeset -gA _IR_ROOT_DIR=() _IR_ROOT_VAR=()
    typeset -ga _IR_STAGE_ROOTS=() _IR_COLLECT_ROOTS=() _IR_EXTRA_PAIRS=()
    _ir_resolve_roots "${id}" RUNNER_STAGE_ROOTS; _IR_STAGE_ROOTS=("${reply[@]}")
    _ir_resolve_roots "${id}" RUNNER_COLLECT_ROOTS; _IR_COLLECT_ROOTS=("${reply[@]}")
    _ir_plan_env_target "${id}" "${chain}"
    _ir_plan_hook_pairs "${id}"
    typeset -g _IR_PLANNED="${id}|${chain}"
}

# One tar stream into the pod, unpacked at <snapshot>/<dest>. Made here by this
# machine's tar (bsdtar on macOS, GNU tar on Linux) and unpacked by GNU tar in the
# pod, so names stay plain and relative to the folder: no -s or --transform, which
# the two read differently.
_ir_stream_to_pod() {   # <namespace> <run> <dest, snapshot-relative, "" = top> <local folder>   stdin: NUL list
    local ns="$1" run="$2" dest="/work/snapshots/$2${3:+/$3}"
    ( cd "$4" && COPYFILE_DISABLE=1 tar --null -T - -cf - 2>/dev/null ) \
        | oc exec -i -n "${ns}" "${IR_POD}" -- sh -c \
            "mkdir -p ${dest} /work/runs/${run} && tar -xf - --no-same-owner --warning=no-unknown-keyword -C ${dest}"
}

_ir_stage_pair() {   # <namespace> <run> <source> <snapshot path> -> REPLY = files sent
    local ns="$1" run="$2" src="$3" snap="$4" tmp dest=""
    if [[ -d "${src}" ]]; then
        REPLY="$(_ir_find_files "${src}" | _ir_count_nul)"
        (( REPLY > 0 )) && _ir_find_files "${src}" | _ir_stream_to_pod "${ns}" "${run}" "${snap}" "${src}"
        return 0
    fi
    # A file lands under another name only through a copy: renaming in tar isn't portable.
    [[ "${snap}" == */* ]] && dest="${snap:h}"
    tmp="$(h_private_tmpdir "${TMPDIR:-/tmp}")"
    cp -p "${src}" "${tmp}/${snap:t}"
    print -rn -- "${snap:t}"$'\0' | _ir_stream_to_pod "${ns}" "${run}" "${dest}" "${tmp}"
    rm -rf "${tmp}"
    REPLY=1
}

# The run record's path map: "<snapshot path>=<VAR>:<local folder, repo-relative>".
_ir_path_map() {
    local snap repo="${_CP4D_REPO_ROOT:A}"
    for snap in "${_IR_STAGE_ROOTS[@]}" "${(@)_IR_COLLECT_ROOTS:|_IR_STAGE_ROOTS}"; do
        print -r -- "${snap}=${_IR_ROOT_VAR[${snap}]}:${_IR_ROOT_DIR[${snap}]#${repo}/}"
    done
}

# Toggles the user may have set for this run. Never anything credential-shaped.
_ir_run_env_toggles() {
    local name
    for name in ${(k)parameters[(R)*export*]}; do
        [[ "${name}" == (DO_*|PREP_*|SKIP_*|CP4D_PREREQ_*|INSTALL_OPERATORS_IN_PARALLEL) ]] || continue
        [[ "${name}" == *(KEY|PASSWORD|TOKEN|SECRET)* ]] && continue
        print -r -- "export ${name}=${(qq)${(P)name}}"
    done
}

ir_stage() {   # <id> <namespace> <chain> <run id> [chain args...] - needs a ready pod
    local id="$1" ns="$2" chain="$3" run="$4" count total snap dir pair repo="${_CP4D_REPO_ROOT:A}"
    shift 4
    _ir_stage_plan "${id}" "${chain}"
    ir_info "Staging run ${run}"
    count="$(_ir_snapshot_files "${id}" | _ir_count_nul)"
    (( count > 0 )) || ir_die "Nothing to stage: is this a git checkout?"
    _ir_snapshot_files "${id}" | _ir_stream_to_pod "${ns}" "${run}" "" "${_CP4D_REPO_ROOT}"
    ir_info "  code: ${count} files"
    total=${count}
    for snap in "${_IR_STAGE_ROOTS[@]}"; do
        dir="${_IR_ROOT_DIR[${snap}]}"
        count=0
        [[ -d "${dir}" ]] && count="$(_ir_find_files "${dir}" | _ir_count_nul)"
        (( count > 0 )) && _ir_find_files "${dir}" | _ir_stream_to_pod "${ns}" "${run}" "${snap}" "${dir}"
        ir_info "  ${snap}: ${count} files from ${dir#${repo}/}"
        (( total += count ))
    done
    for pair in "${_IR_EXTRA_PAIRS[@]}"; do
        _ir_stage_pair "${ns}" "${run}" "${pair%%$'\t'*}" "${pair#*$'\t'}"
        ir_info "  ${pair#*$'\t'}: ${REPLY} file(s) from ${${pair%%$'\t'*}#${repo}/}"
        (( total += REPLY ))
    done
    local layout=flat
    [[ -n "${MCM_CLUSTER:-}" ]] && layout=cluster
    {
        print -r -- "IR_RUN_ID=${(qq)run}"
        print -r -- "IR_CHAIN=${(qq)chain}"
        print -r -- "IR_INSTALL_ID=${(qq)id}"
        print -r -- "IR_ARGS=(${(j: :)${(qq)@}})"
        print -r -- "export ENV_TARGET=${(qq)_IR_ENV_TARGET}"
        # The run record (plan §5.4), read back by collect. IR_SOURCE_CLUSTER is for
        # display: MCM_CLUSTER would pin the pod.
        print -r -- "IR_CLUSTER_URL=${(qq)${${OCP_URL:-}%/}}"
        print -r -- "IR_SOURCE_CLUSTER=${(qq)${MCM_CLUSTER:-}}"
        print -r -- "IR_LAYOUT=${(qq)layout}"
        print -r -- "IR_PATH_MAP=${(qq):-/work/runs/${run}/path_map}"
        print -r -- "IR_ENV_TARGET=${(qq)_IR_ENV_TARGET_REL}"
        _ir_run_env_toggles
    } | oc exec -i -n "${ns}" "${IR_POD}" -- sh -c "cat > /work/runs/${run}/run.env"
    _ir_path_map | oc exec -i -n "${ns}" "${IR_POD}" -- sh -c "cat > /work/runs/${run}/path_map"
    # The baseline is taken once every stream is in.
    oc exec -n "${ns}" "${IR_POD}" -- "${IR_BIN_IN_POD}/finalize-stage.sh" "${run}"
    ir_info "Staged ${total} files."
}

# =============================================================================
# Hand-off (ir_dispatch lands here)
# =============================================================================
ir_handoff() {   # <chain args...>
    local arg
    # Questions about the chain are answered here, not in a pod.
    for arg in "$@"; do
        [[ "${arg}" == (--list-steps|--list_steps|-h|--help) ]] && return 0
    done

    # Both sides resolved: :A follows symlinks, and the repo may sit behind one.
    local chain="${${ZSH_ARGZERO:A}#${_CP4D_REPO_ROOT:A}/}" id slot ns state
    ir_install_for_chain "${chain}" \
        || ir_die "INSTALL_RUN_MODE=cluster, but ${chain} has no install module. Use INSTALL_RUN_MODE=local, or see src/install_runner/installs/_template.conf."
    id="${REPLY}"
    ir_slot "${id}"; slot="${REPLY}"
    ir_namespace "${slot}"; ns="${REPLY}"
    _ir_check_chain_args "${_CP4D_REPO_ROOT}/${chain}" "$@"
    # What to stage, and the refusals (wrong cluster's config, ENV_TARGET=all), come
    # first: nothing on the cluster changes for a run that can't go.
    _ir_stage_plan "${id}" "${chain}"
    typeset -ga _IR_CHAIN_ARGS=("$@")

    eval "${OC_LOGIN}"
    ir_refuse_busy_slot "${ns}" "${slot}"
    ir_preflight "${id}" "${chain}"
    ir_image_ensure "${id}"
    local image="${REPLY}"
    # The pod spec first, with no change on the cluster: a sidecar that can't go (no
    # entitlement key, an image the key can't read) stops here, before the record.
    ir_slot_prepare "${id}" "${slot}" "${image}" "${chain}"
    # Written before anything is created on the cluster, so a slot never exists without
    # its record: multi_cluster.sh refuses remove, rename and off while one is there
    # (gap X15). Cleared by teardown.
    ir_slot_record_set "${MCM_CLUSTER:-}" "${slot}" url="${OCP_URL:-}" run= install="${id}" \
        launched="$(date -u +%Y-%m-%dT%H:%M:%SZ)" state=starting
    ir_slot_apply "${id}" "${slot}" "${image}" "${chain}"
    ir_wait_pod "${ns}"

    local run="$(date -u +%Y%m%dT%H%M%SZ)" watch rc=0
    ir_stage "${id}" "${ns}" "${chain}" "${run}" "$@"
    ir_slot_record_set "${MCM_CLUSTER:-}" "${slot}" run="${run}" state=launched
    watch="scripts/install_runner/x_watch_install.sh --install ${id}$(_ir_tc)"
    _ir_fanout_note "${slot}" "${watch}"
    # --parallel (plan 15.1 D3): launch only, so the next cluster of a fan-out can start.
    if [[ "${IR_FANOUT_PARALLEL:-}" == 1 ]]; then
        ir_info "Run ${run} is launched in slot ${slot}. It keeps running in the cluster; nothing waits for it here."
        ir_info "Watch it with: ${watch}"
        exit 76
    fi
    ir_info "Run ${run} is in slot ${slot}. You can close this terminal: the install keeps going."
    ir_info "Watch it again with: ${watch}"
    # The run's result is this chain's: 0, 1, 76 detached, 77 warnings, 78 watch lost.
    ir_attach "${slot}" --from-start || rc=$?
    exit "${rc}"
}

# A fan-out child's row in the result table (mcm_fanout): the slot, and how to watch it.
# mcm_fanout names the file in _MCM_FANOUT_NOTE; nothing to do outside a fan-out.
_ir_fanout_note() {   # <slot> <watch command>
    [[ -n "${_MCM_FANOUT_NOTE:-}" ]] || return 0
    print -r -- "$1"$'\t'"$2" > "${_MCM_FANOUT_NOTE}" 2>/dev/null || true
}

# A bad option fails here, before the preflight, the image and the upload (gap X13).
# Only for a chain that parses its options with h_steps_parse --strict: the same call
# in a subshell has no side effects (it only sets variables, or dies). A step-name typo
# is left to the pod, where the steps are known; it ends as a "rejected" run, which
# frees the slot again.
_ir_check_chain_args() {   # <chain file> <chain args...>
    local file="$1" line err word
    local -a flags
    shift
    line="$(grep -m1 -E '^[[:space:]]*h_steps_parse[[:space:]]+(--(no-from|no-help)[[:space:]]+)*--strict' "${file}" 2>/dev/null)" || return 0
    for word in ${(z)line}; do
        [[ "${word}" == h_steps_parse ]] && continue
        [[ "${word}" == --(strict|no-from|no-help) ]] || break
        flags+=("${word}")
    done
    if ! err="$( ( h_steps_parse "${flags[@]}" "$@" ) 2>&1 >/dev/null )"; then
        [[ -n "${err}" ]] && print -r -- "${err}" >&2
        h_error "Nothing was launched: fix the arguments of ${file:t} (see --help)."
        exit 2
    fi
}

# One run per slot, and a finished run's results must be home before the next
# replaces them.
ir_refuse_busy_slot() {   # <namespace> <slot>
    local ns="$1" slot="$2" state collected tool="scripts/install_runner/x_install_runner.sh"
    state="$(ir_slot_status_value "${ns}" state)"
    collected="$(ir_slot_status_value "${ns}" collected)"
    case "${state}" in
        # rejected: the last run stopped before its first step, so nothing changed (gap X13).
        ""|idle|rejected) return 0 ;;
        staged|running|interrupted)
            ir_die "Slot ${slot} already has a run (${state}). Watch it: ${tool} attach --slot ${slot}$(_ir_tc)" ;;
    esac
    [[ "${INSTALL_RUNNER_NEW_RUN:-false}" == true ]] && return 0
    case "${state}" in
        failed|stopped)
            ir_die "Slot ${slot} has a ${state} run. Continue it (${tool} resume --slot ${slot}$(_ir_tc)), or set INSTALL_RUNNER_NEW_RUN=true to start over." ;;
    esac
    [[ "${collected}" == yes ]] || ir_die "Slot ${slot} has a finished run that isn't collected. Run ${tool} collect --slot ${slot}$(_ir_tc), or set INSTALL_RUNNER_NEW_RUN=true."
}

# =============================================================================
# Tap-in
# =============================================================================
# Read-only: Ctrl-C ends this viewer and nothing else. The stream carries the raw
# terminal bytes; a dropped connection or a replaced pod just means reconnecting
# at the same byte. Returns the run's result:
#   0 completed, 77 completed with warnings, 1 failed, stopped, rejected, no run, or
#   the slot was torn down, 76 detached (Ctrl-C or a closed terminal: the run goes on),
#   78 watch lost (the login is gone, or no read for INSTALL_RUNNER_ATTACH_LOST_MAX
#   minutes, default 30: the run may still be going).
# A fan-out (mcm_fanout) shows each code in its table.
# --resumed (from the resume verb): a finished state read while control.resume is
# still there is the old run the supervisor has yet to restart, so the watch waits
# for it instead of reporting it.
ir_attach() {   # <slot> [--plain] [--from-start] [--last N] [--resumed]
    local slot="$1" ns log=terminal position="last:200" offset_file state offset="" resumed=false
    shift
    while (( $# )); do
        case "$1" in
            --plain)      log=plain ;;
            --from-start) position=start ;;
            --last)       h_need_value "$1" "${2:-}"; position="last:$2"; shift ;;
            --resumed)    resumed=true ;;
            *) ir_die "Unknown attach option: $1" ;;
        esac
        shift
    done
    ir_namespace "${slot}"; ns="${REPLY}"
    # IR_ATTACH_RETRY_SECONDS exists for tests, as IR_POLL does in the supervisor.
    local retry="${IR_ATTACH_RETRY_SECONDS:-5}" lost_max="${INSTALL_RUNNER_ATTACH_LOST_MAX:-30}"
    if [[ "${lost_max}" != (<->|<->.<->) ]]; then
        ir_warn "INSTALL_RUNNER_ATTACH_LOST_MAX must be a number of minutes (got '${lost_max}'); using 30."
        lost_max=30
    fi
    local -i last_read=${SECONDS} lost_after=$(( lost_max * 60 ))
    local detached=false said_lost=false said_unreachable=false relogged=false said_waiting=false
    offset_file="$(mktemp "${TMPDIR:-/tmp}/ir-attach.XXXXXX")"

    # INT is Ctrl-C, HUP a closed terminal: both only detach (gap X9). A signal that
    # lands during a call ends that call, and the loop checks ${detached} right after.
    # The loop runs in a function of its own so the clean-up below always runs: under
    # errexit a non-zero return would end the shell before an "always" block.
    local rc=0
    trap 'detached=true' INT HUP
    _ir_attach_follow || rc=$?
    rm -f "${offset_file}"
    trap - INT HUP
    if (( rc == 76 )); then
        # A closed terminal takes no more output; the result still counts.
        { print -r -- ""; ir_info "Detached. The install keeps running in slot ${slot}."; } 2>/dev/null || true
    fi
    return "${rc}"
}

# ir_attach's loop, on its locals (slot, ns, log, position, offset_file, offset, state,
# detached, ...). Returns ir_attach's codes. A command substitution has its "|| true"
# outside: inside, a Ctrl-C that ends it would still fail the assignment.
_ir_attach_follow() {
    local before
    local -a reply
    while ! ${detached}; do
        if [[ -z "${offset}" ]]; then
            offset="$(oc exec -n "${ns}" "${IR_POD}" -- "${IR_BIN_IN_POD}/follow.sh" "${log}" "${position}" resolve 2>/dev/null)" || true
        fi
        # A Ctrl-C during the resolve leaves no offset: that is a detach, not "no run".
        ${detached} && break
        if [[ "${offset}" != <-> ]]; then
            offset=""
            if oc exec -n "${ns}" "${IR_POD}" -- true >/dev/null 2>&1; then
                h_error "Slot ${slot} has no run to watch."
                return 1
            fi
            ${detached} && break
            _ir_attach_check_lost || return $?
            ${said_lost} || print -r -- "[attach] Runner pod not reachable; retrying..." >&2
            said_lost=true
            sleep "${retry}" || true
            continue
        fi
        last_read=${SECONDS}
        relogged=false
        print -r -- "${offset}" > "${offset_file}"
        said_lost=false said_unreachable=false
        oc exec -n "${ns}" "${IR_POD}" -- "${IR_BIN_IN_POD}/follow.sh" "${log}" "offset:${offset}" 2>/dev/null \
            | python3 -I "${IR_SRC}/stream_counter.py" "${offset_file}" "${offset}" || true
        ${detached} && break
        before="${offset}"
        offset="$(<"${offset_file}")"
        state="$(oc exec -n "${ns}" "${IR_POD}" -- sh -c 'cat /work/current/state' 2>/dev/null)" || true
        ${detached} && break
        # After a resume: the old run's end until the supervisor takes the request
        # (a slow poll, or a pod replaced in between). Once taken, states count,
        # from the next round on: the state above may predate the take.
        if ${resumed} && [[ "${state}" == (failed|stopped|completed-with-warnings) ]]; then
            _ir_resume_check "${ns}"
            ${detached} && break
            if [[ "${reply[1]}" == (pending|taken) ]]; then
                last_read=${SECONDS}
                relogged=false
                if [[ "${reply[1]}" == taken ]]; then
                    resumed=false
                    continue
                fi
                ${said_waiting} || print -r -- "[attach] Waiting for the runner to take the resume (run state: ${state})..." >&2
                said_waiting=true said_lost=false
                sleep "${retry}" || true
                continue
            fi
        fi
        case "${state}" in
            completed)
                ir_info "Run finished: ${state}. Next: x_install_runner.sh collect --slot ${slot}$(_ir_tc)"
                return 0 ;;
            completed-with-warnings)
                if [[ -n "${MCM_CLUSTER:-}" ]]; then
                    ir_warn "Run finished: ${state}. See x_install_runner.sh status$(_ir_tc), then collect --slot ${slot}$(_ir_tc)."
                else
                    ir_warn "Run finished: ${state}. See x_install_runner.sh status, then collect."
                fi
                return 77 ;;
            failed|stopped)
                ir_error_state "${slot}" "${state}"
                return 1 ;;
            rejected)
                h_error "Run rejected in slot ${slot}: the chain stopped before its first step, so nothing changed. Fix what it reports above, then launch it again."
                return 1 ;;
        esac
        # Bytes that came in, or a state that could be read, are word from the pod.
        if [[ -n "${state}" || "${offset}" != "${before}" ]]; then
            last_read=${SECONDS}
            relogged=false
        else
            _ir_attach_check_lost || return $?
        fi
        ${said_lost} || print -r -- "[attach] Connection lost (run state: ${state:-unknown}); reconnecting..." >&2
        said_lost=true
        sleep "${retry}" || true
    done
    return 76
}

# After a reconnect that got no word from the pod (gap X11): why? Uses ir_attach's
# locals slot, ns, last_read, lost_after, relogged and said_unreachable. 0 to keep
# retrying, else the code to return.
# A login that expired, or a token that no longer works, is tried once more with the
# config's login; often that is a fixed --token, which fails again, so then the watch
# ends with a next step. An API that does not answer (network drop, VPN, sleep) is no
# login problem: the watch keeps retrying up to INSTALL_RUNNER_ATTACH_LOST_MAX. A
# deleted namespace means another terminal tore the slot down.
_ir_attach_check_lost() {
    local watch="scripts/install_runner/x_watch_install.sh --slot ${slot}$(_ir_tc)" found err
    if err="$(oc whoami 2>&1 >/dev/null)"; then
        :
    elif [[ "${err}" != *(Unauthorized|"must be logged in"|"provide credentials"|Forbidden|401|403)* ]]; then
        # Connection refused, no such host, a timeout: on to the deadline below.
        ${said_unreachable} || print -r -- "[attach] API not reachable; retrying..." >&2
        said_unreachable=true
    else
        if ! ${relogged}; then
            relogged=true
            ir_warn "The login to ${OCP_URL:-the cluster}${MCM_CLUSTER:+ (cluster ${MCM_CLUSTER})} no longer works; logging in again..."
            ( eval "${OC_LOGIN_FORCE:-${OC_LOGIN:-false}}" ) >/dev/null 2>&1 || true
        fi
        if ! oc whoami >/dev/null 2>&1; then
            h_error "The login to ${OCP_URL:-the cluster}${MCM_CLUSTER:+ (cluster ${MCM_CLUSTER})} has expired. Log in again, then watch the run with: ${watch}"
            return 78
        fi
        ir_info "Logged in again."
        return 0
    fi
    if found="$(oc get namespace "${ns}" --ignore-not-found -o name 2>/dev/null)" && [[ -z "${found}" ]]; then
        h_error "Slot ${slot} was torn down: its namespace ${ns} is gone."
        return 1
    fi
    if (( SECONDS - last_read >= lost_after )); then
        h_error "No word from slot ${slot} for $(( (SECONDS - last_read) / 60 )) minute(s): stopped watching. The run may still be going; watch it again with: ${watch}"
        return 78
    fi
    return 0
}

ir_error_state() {   # <slot> <state>
    h_error "Run ${2} in slot ${1}. Fix the cause, then: x_install_runner.sh resume --slot ${1}$(_ir_tc)"
}

# =============================================================================
# Status and control
# =============================================================================
# CLUSTER is this checkout's name for the cluster the login points at, so it is what
# --target-cluster takes; a flat load shows the name the slot was launched under, if
# any. URL is the one the slot was launched for (gap X16). In a fan-out child the rows
# also go to IR_STATUS_ROWS, for the table of every cluster that
# x_install_runner.sh status prints at the end.
ir_status() {
    local now="$(date +%s)" rows
    rows="$(oc get configmap -A -l "${IR_LABEL}" -o json 2>/dev/null \
        | jq -r --argjson now "${now}" --arg cluster "${MCM_CLUSTER:-}" --arg url "${OCP_URL:-}" '
            def known: select(. != null and . != "" and . != "-");
            (.items[] | select(.metadata.name == "ir-status") | .data
             | [([$cluster, .cluster] | map(known) | first // "-"),
                ([.ocp_url, $url] | map(known) | first // "-"),
                .slot, .state, ((.step // "-") | split("/") | last), .attempts, .collected,
                (($now - (.heartbeat | tonumber)) | tostring + "s ago")])
            | @tsv')" || rows=""
    { print -r -- $'CLUSTER\tURL\tSLOT\tSTATE\tSTEP\tATTEMPT\tCOLLECTED\tSEEN'
      if [[ -n "${rows}" ]]; then print -r -- "${rows}"; fi
    } | column -t -s $'\t'
    if [[ -n "${rows}" && -n "${_MCM_FANOUT_CHILD:-}" && -n "${IR_STATUS_ROWS:-}" ]]; then
        print -r -- "${rows}" >> "${IR_STATUS_ROWS}" 2>/dev/null || true
    fi
    local line slot ns seen state
    oc get configmap -A -l "${IR_LABEL}" -o json 2>/dev/null \
        | jq -r '.items[] | select(.metadata.name == "ir-status")
                 | [.metadata.namespace, .data.slot, .data.state, .data.heartbeat, (.data.warned // "-"), (.data.notice // "-")] | @tsv' \
        | while IFS=$'\t' read -r ns slot state seen line notice; do
            [[ "${line}" == - ]] || ir_warn "${slot}: finished with warnings in ${line}"
            # Something only a person can do (the Control Center browser step).
            [[ -z "${notice}" || "${notice}" == - ]] || ir_warn "${slot}: ${notice}"
            [[ "${state}" != rejected ]] || ir_warn "${slot}: the last run stopped before its first step (rejected: a bad option?). Nothing changed; a new launch replaces it."
            # A live run reports at least every minute; silence means the pod is in trouble.
            if [[ "${state}" == (running|staged|interrupted) ]] && (( now - seen > 180 )); then
                ir_warn "${slot}: no report for $(( now - seen ))s. If its node is gone, the pod stays stuck until:"
                ir_warn "  oc delete pod ${IR_POD} -n ${ns} --grace-period=0 --force   (only once the node is really down)"
            fi
        done
    return 0
}

ir_stop() {   # <slot>
    local ns; ir_namespace "$1"; ns="${REPLY}"
    oc exec -n "${ns}" "${IR_POD}" -- sh -c 'touch /work/current/control.stop'
    ir_info "Stop requested for slot $1."
}

ir_resume() {   # <slot> [--retry-warned]
    local slot="$1" ns state content="" lines
    local -a reply
    [[ "${2:-}" == --retry-warned ]] && content=retry-warned
    ir_namespace "${slot}"; ns="${REPLY}"
    state="$(oc exec -n "${ns}" "${IR_POD}" -- sh -c 'cat /work/current/state' 2>/dev/null || true)"
    # A rejected run would only stop again on the same arguments.
    [[ "${state}" != rejected ]] \
        || ir_die "Slot ${slot}'s last run was rejected before its first step: nothing to resume. Launch it again with fixed arguments."
    [[ "${state}" == (failed|stopped|completed-with-warnings) ]] \
        || ir_die "Slot ${slot} is '${state:-unreachable}': nothing to resume."
    ir_grant_admin "${slot}"
    _ir_resume_check "${ns}"; lines="${reply[3]}"
    print -r -- "${content}" | oc exec -i -n "${ns}" "${IR_POD}" -- sh -c 'cat > /work/current/control.resume'
    ir_info "Resuming slot ${slot}."
    _ir_resume_wait "${slot}" "${ns}" "${state}" "${lines}"
}

# Where a resume request is: reply=(<pending|taken> <state> <lines in attempts.log>),
# empty when the pod does not answer. The no-op marker (ir-resume-check) lets the
# test fakes tell this command apart.
_ir_resume_check() {   # <namespace>
    local answer
    answer="$(oc exec -n "$1" "${IR_POD}" -- sh -c ': ir-resume-check; cd /work/current || exit 1
        if [ -e control.resume ]; then t=pending; else t=taken; fi
        echo "$t $(cat state 2>/dev/null) $(wc -l < attempts.log 2>/dev/null || echo 0)"' 2>/dev/null)" || answer=""
    reply=(${=answer} "" "" "")
}

# The supervisor takes a resume on its next poll; until then the run still reads
# failed or stopped, and a watch started now would see a finished run that then
# moves again, which looks like a lost connection (live finding L-02). So wait for
# the hand-over: control.resume gone and the state moved on, or a new line in
# attempts.log (an attempt that already ended, maybe in the same state). After
# IR_RESUME_WAIT_SECONDS the watch takes over; started with --resumed, it keeps
# waiting while the request is still there, and reports a pod that does not answer.
# The request is already sent, so Ctrl-C (or a closed terminal) here only detaches,
# as it does in the watch: REPLY=detached, else REPLY=taken.
_ir_resume_wait() {   # <slot> <namespace> <state before> <attempts.log lines before>
    local slot="$1" ns="$2" before="$3" lines="$4" detached=false
    local -i deadline=$(( SECONDS + ${IR_RESUME_WAIT_SECONDS:-60} )) polls=0
    local -a reply
    trap 'detached=true' INT HUP
    while :; do
        _ir_resume_check "${ns}"
        ${detached} && break
        if [[ "${reply[1]}" == taken ]]; then
            [[ -n "${reply[2]}" && "${reply[2]}" != "${before}" ]] && break
            [[ "${reply[3]}" == <-> && "${lines}" == <-> ]] && (( reply[3] > lines )) && break
        fi
        if (( SECONDS >= deadline )); then
            ir_warn "The runner has not picked up the resume yet (state: ${reply[2]:-unknown}); it will on its next poll. Watching; the watch waits for it."
            break
        fi
        (( ++polls == 3 )) && ir_info "Waiting for the runner to take the resume..."
        sleep "${IR_RESUME_POLL_SECONDS:-1}" || true
        ${detached} && break
    done
    trap - INT HUP
    if ${detached}; then
        { print -r -- ""; ir_info "Detached. The resume is sent: the install goes on in slot ${slot} once the runner takes it. Watch it with: x_install_runner.sh attach --slot ${slot}$(_ir_tc)"; } 2>/dev/null || true
        REPLY=detached
    else
        REPLY=taken
    fi
    return 0
}

# =============================================================================
# Collect and teardown
# =============================================================================
# One value from a run.env read back from a pod: parsed, never sourced.
_ir_record_value() {   # <run.env text> <key> -> stdout
    local line
    for line in "${(@f)1}"; do
        if [[ "${line}" == "$2="* ]]; then
            print -r -- "${(Q)${line#*=}}"
            return 0
        fi
    done
}

_ir_layout_text() {   # <flat|cluster> <name> -> stdout
    if [[ "$1" == cluster ]]; then print -r -- "cluster folder configs/clusters/$2"
    else print -r -- "the flat configs/ layout"
    fi
}

# Where each collect root goes on this machine (plan §5.6): the run's path record,
# checked against where the cluster's config lives now. Names are per checkout, so
# the cluster is found by its URL. A migration, a rename or another machine with a
# different layout is refused: --to-loaded (the folders this session loaded) or
# --to <dir> then says where the results go.
_ir_collect_destinations() {   # <id> <namespace> <run> <--to folder or ""> [loaded] -> _IR_DEST, _IR_COLLECT_SNAPS
    local id="$1" ns="$2" run="$3" to="$4" loaded="${5:-}" pair snap record map line rel url layout source now now_layout
    local repo="${_CP4D_REPO_ROOT:A}" hint
    typeset -gA _IR_DEST=()
    typeset -ga _IR_COLLECT_SNAPS=()
    for pair in ${(s: :)$(ir_conf "${id}" RUNNER_COLLECT_ROOTS)}; do
        _IR_COLLECT_SNAPS+=("${pair#*:}")
    done
    if [[ -n "${to}" ]]; then
        for snap in "${_IR_COLLECT_SNAPS[@]}"; do
            _IR_DEST[${snap}]="${to:A}/${snap:t}"
        done
        ir_info "Collecting into ${to:A} (--to)."
        return 0
    fi
    record="$(oc exec -n "${ns}" "${IR_POD}" -- sh -c "cat /work/runs/${run}/run.env" 2>/dev/null || true)"
    map="$(oc exec -n "${ns}" "${IR_POD}" -- sh -c "cat /work/runs/${run}/path_map" 2>/dev/null || true)"
    url="$(_ir_record_value "${record}" IR_CLUSTER_URL)"
    now="$(mcm_cluster_for_url "${url}")"
    now_layout=flat
    [[ -n "${now}" ]] && now_layout=cluster
    if [[ -n "${loaded}" ]]; then
        _ir_loaded_destinations "${id}" "${run}" "${url}" "${now}"
        return 0
    fi
    # Both ways out of a refusal: each root into the folder loaded for it now (in the
    # flat layout they have different parents), or all of them under one folder.
    hint="collect$(_ir_tc) --to-loaded (into $(_ir_loaded_roots_text "${id}")) or collect$(_ir_tc) --to <folder>"
    [[ -n "${now}" ]] && hint+=" (e.g. --to $(mcm_clusters_root)/${now})"
    [[ -n "${map}" ]] || ir_die "Run ${run} has no path record (an older runner staged it). Say where its results go: ${hint}."
    layout="$(_ir_record_value "${record}" IR_LAYOUT)"
    source="$(_ir_record_value "${record}" IR_SOURCE_CLUSTER)"
    if [[ "${layout:-flat}" != "${now_layout}" || "${source}" != "${now}" ]]; then
        ir_die "Run ${run} was staged from $(_ir_layout_text "${layout:-flat}" "${source}"), but ${url:-its cluster} now has $(_ir_layout_text "${now_layout}" "${now}") here. Nothing was collected. Say where the results go: ${hint}."
    fi
    for line in "${(@f)map}"; do
        snap="${line%%=*}" rel="${line#*=}" rel="${rel#*:}"
        (( ${_IR_COLLECT_SNAPS[(Ie)${snap}]} )) || continue
        [[ -n "${rel}" && "${rel}" != /* && "/${rel}/" != */../* ]] || ir_die "Run ${run} records a bad folder for ${snap}: '${rel}'."
        # The record comes back from the pod, so it is checked like a root at staging:
        # a config folder of this layout, never code, a login folder or another
        # cluster's folder. Another root (the service instance folder) only at its own
        # place: <snapshot path> when flat, as in the pod, or under the cluster folder.
        if ! _ir_root_allowed "${repo}/${rel}" "${rel}"; then
            if [[ "${REPLY}" != only* ]] \
               || ! [[ ( -n "${now}" && "${rel}" == configs/clusters/${now}/${snap:t} ) || ( -z "${now}" && "${rel}" == "${snap}" ) ]]; then
                ir_die "Run ${run} records ${rel} for ${snap}, which collect never writes to: ${REPLY}. Say where it goes: ${hint}."
            fi
        fi
        if [[ -n "${now}" && "${rel}" != configs/clusters/${now}/* ]] || [[ -z "${now}" && "${rel}" == configs/clusters/* ]]; then
            ir_die "Run ${run} records ${rel} for ${snap}, outside $(_ir_layout_text "${now_layout}" "${now}"). Say where it goes: ${hint}."
        fi
        _IR_DEST[${snap}]="${_CP4D_REPO_ROOT}/${rel}"
    done
    for snap in "${_IR_COLLECT_SNAPS[@]}"; do
        [[ -n "${_IR_DEST[${snap}]:-}" ]] || ir_die "Run ${run} has no record of where ${snap} came from. Say where it goes: ${hint}."
    done
}

# For a refusal's hint: the folders this session loaded for the collect roots.
_ir_loaded_roots_text() {   # <id> -> stdout
    local pair var dir repo="${_CP4D_REPO_ROOT:A}"
    local -a shown=()
    for pair in ${(s: :)$(ir_conf "$1" RUNNER_COLLECT_ROOTS)}; do
        var="${pair%%:*}"
        dir="${(P)var:-}"
        [[ -n "${dir}" ]] && shown+=("${${dir:A}#${repo}/}") || shown+=("${var} (not set here)")
    done
    print -r -- "${(j:, :)shown}"
}

# --to-loaded: each root goes to the folder the loaded config gives it, checked as at
# staging, and inside the folder that holds this cluster's config now.
_ir_loaded_destinations() {   # <id> <run> <recorded url or ""> <cluster that owns it now or ""> -> _IR_DEST
    local id="$1" run="$2" url="$3" now="$4" snap rel repo="${_CP4D_REPO_ROOT:A}"
    typeset -gA _IR_ROOT_DIR=() _IR_ROOT_VAR=()
    _ir_resolve_roots "${id}" RUNNER_COLLECT_ROOTS
    for snap in "${reply[@]}"; do
        rel="${_IR_ROOT_DIR[${snap}]#${repo}/}"
        if [[ -n "${url}" ]]; then
            if [[ -n "${now}" && "${rel}" != configs/clusters/${now}/* ]] || [[ -z "${now}" && "${rel}" == configs/clusters/* ]]; then
                ir_die "This session loaded ${rel} for ${snap}, but run ${run}'s cluster (${url}) has $(_ir_layout_text "${now:+cluster}" "${now}") here. Load that config, or use collect$(_ir_tc) --to <folder>."
            fi
        fi
        _IR_DEST[${snap}]="${_IR_ROOT_DIR[${snap}]}"
        ir_info "  ${snap} -> ${rel}"
    done
    ir_info "Collecting into the folders this session loaded (--to-loaded)."
}

# A collect-list path (snapshot-relative) -> its local file, through the longest root.
_ir_local_path() {   # <file> -> REPLY
    local snap best=""
    REPLY=""
    [[ "/$1/" == */../* ]] && return 1
    for snap in "${_IR_COLLECT_SNAPS[@]}"; do
        [[ "$1" == "${snap}"/* && ${#snap} -gt ${#best} ]] && best="${snap}"
    done
    [[ -n "${best}" ]] || return 1
    REPLY="${_IR_DEST[${best}]}/${1#${best}/}"
}

# A collected text file can name pod paths (/work/snapshots/<run>/...): they become
# the same places here, a root's local folder first, then the repo for the rest.
# Text under 1 MB only; binary files are left alone.
_ir_rewrite_pod_paths() {   # <file> <run>
    local file="$1" pod="/work/snapshots/$2" size snap line
    local -a order=()
    [[ -f "${file}" ]] || return 0
    size="$(wc -c < "${file}" | tr -d ' ')"
    (( size > 0 && size < 1048576 )) || return 0
    grep -qF -- "${pod}" "${file}" 2>/dev/null || return 0
    LC_ALL=C grep -qI . "${file}" 2>/dev/null || return 0
    for snap in "${_IR_COLLECT_SNAPS[@]}"; do order+=("${#snap}"$'\t'"${snap}"); done
    for line in ${(On)order}; do
        snap="${line#*$'\t'}"
        IR_FROM="${pod}/${snap}" IR_TO="${_IR_DEST[${snap}]}" \
            perl -pi -e 's{\Q$ENV{IR_FROM}\E(?=/|[^\w.\-]|$)}{$ENV{IR_TO}}g' "${file}"
    done
    IR_FROM="${pod}" IR_TO="${_CP4D_REPO_ROOT}" \
        perl -pi -e 's{\Q$ENV{IR_FROM}\E(?=/|[^\w.\-]|$)}{$ENV{IR_TO}}g' "${file}"
}

# Brings back what the run changed. A local file changed since launch is never
# overwritten: the pod's copy lands next to it instead. A file missing here is
# taken, as there is nothing to protect. New folders are owner-only: these are
# config folders, some holding credentials.
ir_collect() {   # <id> <slot> [--force] [--to <folder> | --to-loaded]
    local id="$1" slot="$2" force="" to="" loaded="" ns state run list tmp
    shift 2
    while (( $# )); do
        case "$1" in
            --force) force=--force ;;
            --to)    h_need_value "$1" "${2:-}"; to="$2"; shift ;;
            --to=*)  to="${1#*=}"; [[ -n "${to}" ]] || ir_die "--to needs a folder." ;;
            --to-loaded) loaded=1 ;;
            *)       ir_die "Unknown collect option: $1" ;;
        esac
        shift
    done
    [[ -n "${to}" && -n "${loaded}" ]] && ir_die "Use --to <folder> or --to-loaded, not both."
    ir_namespace "${slot}"; ns="${REPLY}"
    state="$(oc exec -n "${ns}" "${IR_POD}" -- sh -c 'cat /work/current/state' 2>/dev/null || true)"
    [[ -n "${state}" ]] || ir_die "Slot ${slot} has no reachable run."
    if [[ "${state}" == (staged|running|interrupted) && "${force}" != --force ]]; then
        ir_die "Run is still ${state}. Wait for it, or use --force for what exists so far."
    fi
    run="$(oc exec -n "${ns}" "${IR_POD}" -- sh -c 'basename "$(readlink -f /work/current)"')"
    _ir_collect_destinations "${id}" "${ns}" "${run}" "${to}" "${loaded}"
    list="$(oc exec -n "${ns}" "${IR_POD}" -- "${IR_BIN_IN_POD}/collect-list.sh" "${_IR_COLLECT_SNAPS[@]}")"
    if [[ -z "${list}" ]]; then
        ir_info "Nothing changed under the collect paths."
    else
        tmp="$(h_private_tmpdir "${TMPDIR:-/tmp}")"
        print -r -- "${list}" | cut -f3 \
            | oc exec -i -n "${ns}" "${IR_POD}" -- sh -c "cd /work/snapshots/${run} && tar -cf - -T -" \
            | tar -xf - -C "${tmp}"
        # (not "path": in zsh that is PATH)
        local base hash file target shown lhash rhash taken=0 kept=0 repo="${_CP4D_REPO_ROOT:A}"
        while IFS=$'\t' read -r base hash file; do
            if ! _ir_local_path "${file}"; then
                ir_warn "Skipped ${file}: it is outside the collect roots."
                continue
            fi
            target="${REPLY}" shown="${${REPLY:A}#${repo}/}"
            # Compared after the rewrite too, so collecting twice finds nothing new.
            _ir_rewrite_pod_paths "${tmp}/${file}" "${run}"
            rhash="$(_ir_sha < "${tmp}/${file}")"
            lhash=-
            [[ -f "${target}" ]] && lhash="$(_ir_sha < "${target}")"
            if [[ "${lhash}" == "${hash}" || "${lhash}" == "${rhash}" ]]; then
                continue
            fi
            (umask 077; mkdir -p "${target:h}")
            if [[ "${lhash}" == - || "${lhash}" == "${base}" ]]; then
                cp -p "${tmp}/${file}" "${target}"
                (( ++taken ))
            else
                cp -p "${tmp}/${file}" "${target}.in-cluster-${run}"
                ir_warn "Kept your local ${shown}; the pod's copy is ${shown}.in-cluster-${run}"
                (( ++kept ))
            fi
        done <<< "${list}"
        rm -rf "${tmp}"
        ir_info "Collected ${taken} file(s); ${kept} kept back because they changed here too."
    fi
    oc exec -n "${ns}" "${IR_POD}" -- sh -c 'touch /work/current/collected'
    # The supervisor reports the marker only on its next publish, up to a heartbeat
    # later, and teardown reads ir-status: set it now, as the supervisor writes it.
    # The marker is already there, so its next publish says yes too.
    oc patch configmap ir-status -n "${ns}" --type merge -p '{"data":{"collected":"yes"}}' >/dev/null 2>&1 \
        || ir_warn "Could not mark slot ${slot} collected in ir-status; the runner reports it within a minute."
    # Only a launch from this machine has a record; a collect elsewhere starts none.
    ir_slot_record_dir "${MCM_CLUSTER:-}" \
        && [[ -f "${REPLY}/${slot}" ]] && ir_slot_record_set "${MCM_CLUSTER:-}" "${slot}" state=collected
    # The follow-up reads the loaded config, which --to <folder> did not fill: it
    # would work from stale details (an API key the pod has since rotated).
    if [[ -n "${to}" ]]; then
        ir_info "Results are in ${to:A}. Skipped the ${id} follow-up: it reads the loaded config, which these results did not reach. collect$(_ir_tc) --to-loaded would put them there and run it."
        return 0
    fi
    ir_hook "${id}" post-collect
    return 0
}

ir_teardown() {   # <slot> [--discard]
    local slot="$1" discard="${2:-}" ns binding collected
    ir_namespace "${slot}"; ns="${REPLY}"
    ir_admin_binding "${slot}"; binding="${REPLY}"
    case "$(ir_slot_status_value "${ns}" state)" in
        staged|running|interrupted) ir_die "Slot ${slot} has a live run. Stop it first." ;;
    esac
    collected="$(ir_slot_status_value "${ns}" collected)"
    if [[ "${collected}" != yes && "${discard}" != --discard ]]; then
        ir_die "Slot ${slot} isn't collected. Collect it, or use --discard to lose its results."
    fi
    ir_info "Deleting slot ${slot} (namespace, volume, credentials)..."
    oc delete clusterrolebinding "${binding}" --ignore-not-found >/dev/null
    oc delete rolebinding "image-puller-${ns}" -n "${IR_SYSTEM_NS}" --ignore-not-found >/dev/null 2>&1 || true
    oc delete namespace "${ns}" --ignore-not-found --wait=true >/dev/null
    ir_slot_record_remove "${MCM_CLUSTER:-}" "${slot}"
    ir_info "Slot ${slot} is gone."
}
