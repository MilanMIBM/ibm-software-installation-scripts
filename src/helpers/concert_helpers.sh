#!/bin/zsh
# =============================================================================
# concert_helpers.sh - shared functions for scripts/install_ibm_concert
# -----------------------------------------------------------------------------
# How scripts use it (after the env_bootstrap line):
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
#     concert_require_config
#
# Sections:
#   - logging / small utilities
#   - products, namespaces and hub mode (what the config selected)
#   - IBM installer workspace paths
#   - concert_run: run an IBM installer script in the runner
#     (cluster Job | workstation podman | native Linux bastion)
#   - data stores: consumer/server switches, generated credentials, secrets
#   - waits (generic, rollouts, MachineConfigPools), operator installs
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _CONCERT_HELPERS_LOADED.
#   - Every function assumes `oc` is already logged in by the caller.
#   - Never reads or prints secret values unless a function is explicitly
#     about producing one (concert_ds_cred_*).
# =============================================================================

[[ -n "${_CONCERT_HELPERS_LOADED:-}" ]] && return 0
_CONCERT_HELPERS_LOADED=1

source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"

export CONCERT_WORKSPACE="${CONCERT_WORKSPACE:-${_CP4D_REPO_ROOT}/concert_workspace}"
export CONCERT_CONFIG_DIR="${CONCERT_CONFIG_DIR:-${_CP4D_REPO_ROOT}/configs/concert_config}"
CONCERT_RUNNER_SRC_DIR="${_CP4D_REPO_ROOT}/src/helpers/concert_runner"
CONCERT_MANAGED_BY="concert-install-scripts"
CONCERT_RUNNER_SA="concert-installer"
CONCERT_RUNNER_PVC="concert-installer-work"
CONCERT_RUNNER_CRB="concert-installer-cluster-admin"
CONCERT_DS_CRED_SECRET="concert-datastore-credentials"

# eval "${OC_LOGIN}" -> concert_oc_login.sh: always ends on OCP_URL (reuses a
# valid session or saved context for it, else logs in, then verifies). Not for
# one-off CONCERT_TARGET_OC_LOGIN runs, which clear OCP_URL.
if [[ -n "${OCP_URL:-}" && -n "${OC_LOGIN_FORCE:-}" ]]; then
    export OC_LOGIN="zsh ${(q)_CP4D_REPO_ROOT}/src/helpers/concert_oc_login.sh"
fi

# =============================================================================
# Logging / small utilities
# =============================================================================
concert_info()  { print -r -- "[INFO] $*"; }
concert_warn()  { print -r -- "[WARN] $*" >&2; }
concert_error() { print -r -- "[ERROR] $*" >&2; }
concert_die()   { concert_error "$@"; exit 1; }

# true / TRUE / yes / y / 1 -> success
concert_is_true() { [[ "${1:-}" == ([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Yy]|1) ]]; }

concert_require_vars() {
    local v missing=()
    for v in "$@"; do
        [[ -n "${(P)v:-}" ]] || missing+=("${v}")
    done
    (( ${#missing} == 0 )) || concert_die "Missing config values: ${missing[*]} (configs/concert_config/concert_vars.sh)"
}

# Every Concert script calls this right after loading the env.
concert_require_config() {
    if [[ "${ENV_TARGET:-}" != concert && "${ENV_TARGET:-}" != *concert_vars.sh ]]; then
        concert_die "ENV_TARGET must be 'concert' (set before env_bootstrap.sh) so only concert_vars.sh is in scope."
    fi
    concert_require_vars CONCERT_VERSION CONCERT_RELEASE_TAG CONCERT_ARCHIVE OC_LOGIN \
        PROJECT_CONCERT_INSTALLER PROJECT_CONCERT_DATASTORES
}

# Alphanumeric (safe in URLs, conf files, JSON). Not `tr </dev/urandom | head`:
# under pipefail the SIGPIPE'd tr fails the pipeline and errexit kills the caller.
concert_random_password() {
    python3 -c 'import secrets, string, sys
a = string.ascii_letters + string.digits
print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))), end="")' "${1:-24}"
}

# Private scratch dir under the workspace. Not $TMPDIR: on macOS podman can
# only bind-mount paths below $HOME, and the workspace is gitignored.
concert_private_tmpdir() {
    local base="${CONCERT_WORKSPACE}/.run"
    mkdir -p "${base}"
    chmod 700 "${base}"
    (umask 077; mktemp -d "${base}/run.XXXXXX")
}

concert_b64d() { base64 --decode 2>/dev/null; }

# concert_write_dockerconfig <file> <registry>=<USER_VAR>:<PASSWORD_VAR>...
# Writes a docker config JSON (auths) for the given registries. Credentials are
# read from the named variables inside python, so they never reach argv.
concert_write_dockerconfig() {
    local file="$1"
    shift
    (
        umask 077
        local spec reg pair uvar pvar i=0
        for spec in "$@"; do
            reg="${spec%%=*}" pair="${spec#*=}"
            uvar="${pair%%:*}" pvar="${pair#*:}"
            # export (a builtin) keeps the values out of every process's argv
            export "CONCERT_DC_REG_${i}=${reg}" "CONCERT_DC_USER_${i}=${(P)uvar:-}" "CONCERT_DC_PASS_${i}=${(P)pvar:-}"
            (( i += 1 ))
        done
        export CONCERT_DC_COUNT="${i}"
        python3 - "${file}" <<'PY'
import base64, json, os, sys
auths = {}
for i in range(int(os.environ["CONCERT_DC_COUNT"])):
    reg, user, pw = (os.environ[f"CONCERT_DC_{k}_{i}"] for k in ("REG", "USER", "PASS"))
    if reg and user and pw:
        auths[reg] = {"auth": base64.b64encode(f"{user}:{pw}".encode()).decode()}
with open(sys.argv[1], "w") as f:
    json.dump({"auths": auths}, f)
PY
    )
}

# =============================================================================
# Products, namespaces, hub mode
# =============================================================================
# Remote Hub only in "auto" mode and only when both URL and access key are set.
concert_remote_hub_enabled() {
    [[ "${CONCERT_HUB_MODE:-auto}" == auto && -n "${CONCERT_REMOTE_HUB_URL:-}" && -n "${CONCERT_REMOTE_HUB_ACCESS_KEY:-}" ]]
}
concert_local_hub_enabled() { ! concert_remote_hub_enabled; }

concert_graph_enabled() {
    concert_is_true "${CONCERT_INSTALL_VEIAS:-false}" || concert_is_true "${CONCERT_ENABLE_CONCERT_GRAPH:-false}"
}

# concert_product_enabled hub|concert|dataapps|workflows|securecoder|veias|faas|istio|itom
concert_product_enabled() {
    case "$1" in
        hub)         concert_local_hub_enabled ;;
        concert)     concert_is_true "${CONCERT_INSTALL_CONCERT:-false}" ;;
        dataapps)    concert_is_true "${CONCERT_INSTALL_DATAAPPS:-false}" ;;
        workflows)   concert_is_true "${CONCERT_INSTALL_WORKFLOWS:-false}" ;;
        securecoder) concert_is_true "${CONCERT_INSTALL_CONCERT:-false}" && concert_is_true "${CONCERT_INSTALL_SECURECODER:-false}" ;;
        veias)       concert_is_true "${CONCERT_INSTALL_CONCERT:-false}" && concert_is_true "${CONCERT_INSTALL_VEIAS:-false}" ;;
        faas)        concert_product_enabled workflows && concert_is_true "${CONCERT_WORKFLOWS_ENABLE_FAAS:-false}" ;;
        istio)       concert_product_enabled workflows && concert_is_true "${CONCERT_WORKFLOWS_ENABLE_ISTIO:-false}" ;;
        itom)        concert_local_hub_enabled && concert_is_true "${CONCERT_ENABLE_CROSS_PRODUCT_INTEGRATION:-false}" ;;
        *)           return 1 ;;
    esac
}

# Products IBM's installer deploys into their own namespace, in install order.
concert_selected_products() {
    local p
    for p in hub concert dataapps workflows securecoder; do
        concert_product_enabled "${p}" && print -r -- "${p}"
    done
    return 0
}

concert_product_namespace() {
    case "$1" in
        hub)         print -r -- "${PROJECT_CONCERT_HUB:-}" ;;
        concert)     print -r -- "${PROJECT_CONCERT:-}" ;;
        dataapps)    print -r -- "${PROJECT_CONCERT_DATAAPPS:-}" ;;
        workflows)   print -r -- "${PROJECT_CONCERT_WORKFLOWS:-}" ;;
        faas)        print -r -- "${PROJECT_CONCERT_WORKFLOWS_FAAS:-}" ;;
        securecoder) print -r -- "${PROJECT_CONCERT_SECURECODER:-}" ;;
        installer)   print -r -- "${PROJECT_CONCERT_INSTALLER:-}" ;;
        datastores)  print -r -- "${PROJECT_CONCERT_DATASTORES:-}" ;;
    esac
}

# Namespaces of the selected products (+ FaaS when enabled).
concert_product_namespaces() {
    local p ns
    for p in $(concert_selected_products); do
        ns="$(concert_product_namespace "${p}")"
        [[ -n "${ns}" ]] && print -r -- "${ns}"
    done
    if concert_product_enabled faas; then
        ns="$(concert_product_namespace faas)"
        [[ -n "${ns}" ]] && print -r -- "${ns}"
    fi
    return 0
}

concert_apps_domain() {
    if [[ -n "${CONCERT_APPS_DOMAIN:-}" ]]; then
        print -r -- "${CONCERT_APPS_DOMAIN}"
        return 0
    fi
    oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null
}

# Host the Workflows route listens on (also the FaaS insecure registry entry).
concert_workflows_address() {
    if [[ -n "${CONCERT_WORKFLOWS_INSTANCE_ADDRESS:-}" ]]; then
        print -r -- "${CONCERT_WORKFLOWS_INSTANCE_ADDRESS}"
        return 0
    fi
    local domain
    domain="$(concert_apps_domain)"
    [[ -n "${domain}" ]] || return 1
    print -r -- "solis-gw-${PROJECT_CONCERT_WORKFLOWS}.${domain}"
}

# =============================================================================
# IBM installer workspace (workstation side)
# =============================================================================
concert_archive_path()       { print -r -- "${CONCERT_WORKSPACE}/archives/${CONCERT_RELEASE_TAG}/${CONCERT_ARCHIVE}"; }
concert_local_install_root() { print -r -- "${CONCERT_WORKSPACE}/${CONCERT_VERSION}"; }
concert_local_install_dir()  { print -r -- "${CONCERT_WORKSPACE}/${CONCERT_VERSION}/ibm-concert"; }

concert_require_local_installer() {
    [[ -f "$(concert_archive_path)" && -x "$(concert_local_install_dir)/bin/setup" ]] \
        || concert_die "IBM Concert ${CONCERT_VERSION} installer not found - run 0_initial_setup/0.1_fetch_concert_installer.sh first."
}

# =============================================================================
# Runner
# =============================================================================
# Image source: explicit setting, else in-cluster build when pulling from IBM,
# else a workstation build pushed to the private registry.
concert_runner_image_source() {
    if [[ -n "${CONCERT_RUNNER_IMAGE_SOURCE:-}" ]]; then
        print -r -- "${CONCERT_RUNNER_IMAGE_SOURCE}"
    elif [[ "${CONCERT_IMAGE_SOURCE:-entitled}" == entitled ]]; then
        print -r -- build-in-cluster
    else
        print -r -- build-local-push
    fi
}

concert_runner_image() {
    if [[ -n "${CONCERT_RUNNER_IMAGE:-}" ]]; then
        print -r -- "${CONCERT_RUNNER_IMAGE}"
        return 0
    fi
    if [[ "${CONCERT_RUNNER:-cluster}" == container ]]; then
        print -r -- "localhost/concert-installer-runner:${CONCERT_VERSION}"
        return 0
    fi
    case "$(concert_runner_image_source)" in
        build-in-cluster) print -r -- "image-registry.openshift-image-registry.svc:5000/${PROJECT_CONCERT_INSTALLER}/concert-installer-runner:${CONCERT_VERSION}" ;;
        build-local-push) print -r -- "${PRIVATE_REGISTRY_LOCATION}/concert/concert-installer-runner:${CONCERT_VERSION}" ;;
        prebuilt)         concert_die "CONCERT_RUNNER_IMAGE_SOURCE=prebuilt needs CONCERT_RUNNER_IMAGE." ;;
        *)                concert_die "Unknown CONCERT_RUNNER_IMAGE_SOURCE=$(concert_runner_image_source)" ;;
    esac
}

# IBM's installer creates namespaces and cluster-scoped RBAC, and the Istio
# script insists on `oc auth can-i '*' '*'`. The binding exists only while a
# runner Job runs, unless CONCERT_RUNNER_KEEP_ADMIN=true.
concert_runner_grant_admin() {
    oc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CONCERT_RUNNER_CRB}
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: ${CONCERT_RUNNER_SA}
  namespace: ${PROJECT_CONCERT_INSTALLER}
EOF
}

# Keeps the binding while another runner pod (a Job started from a second
# terminal, x_runner_shell.sh) is still running - revoking it would break that
# run halfway.
concert_runner_revoke_admin() {
    concert_is_true "${CONCERT_RUNNER_KEEP_ADMIN:-false}" && return 0
    local active
    active="$(oc get pods -n "${PROJECT_CONCERT_INSTALLER}" -l app.kubernetes.io/name=concert-installer-runner \
        --field-selector=status.phase=Running -o name 2>/dev/null || true)"
    if [[ -n "${active}" ]]; then
        concert_info "Other runner pods are still running - keeping ${CONCERT_RUNNER_CRB} for them."
        return 0
    fi
    oc delete clusterrolebinding "${CONCERT_RUNNER_CRB}" --ignore-not-found >/dev/null 2>&1 || true
}

# Path an IBM script receives for a file passed with `concert_run --file`.
concert_run_file_path() { print -r -- "/config/files/${1:t}"; }

# -----------------------------------------------------------------------------
# concert_run [--name <label>] [--env NAME[=SRC_VAR]]... [--file <path>]...
#             [--timeout <s>] [--] <script relative to ibm-concert/> [args...]
# -----------------------------------------------------------------------------
# Runs one IBM installer script in the configured runner and returns its exit
# code. --env passes a variable from the config (SRC_VAR, default NAME) into
# the runner as NAME - secrets never appear on the workstation command line.
# --file makes a file available at $(concert_run_file_path <file>); a file
# named params.ini is copied to etc/params.ini by the entrypoint.
concert_run() {
    setopt localoptions localtraps
    local label="run" timeout="${CONCERT_RUN_TIMEOUT:-10800}"
    local -a env_specs files
    while (( $# )); do
        case "$1" in
            --name)    label="$2"; shift 2 ;;
            --env)     env_specs+=("$2"); shift 2 ;;
            --file)    files+=("$2"); shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            --)        shift; break ;;
            *)         break ;;
        esac
    done
    (( $# )) || concert_die "concert_run: no script given"

    local stage
    stage="$(concert_private_tmpdir)"
    trap "rm -rf '${stage}'" EXIT

    # Env file: NAME=value lines, values verbatim (no shell quoting).
    local envfile="${stage}/env" spec name src
    print -r -- "CONCERT_VERSION=${CONCERT_VERSION}" > "${envfile}"
    for spec in "${env_specs[@]}"; do
        name="${spec%%=*}"
        src="${name}"
        [[ "${spec}" == *=* ]] && src="${spec#*=}"
        [[ -n "${(P)src:-}" ]] && print -r -- "${name}=${(P)src}" >> "${envfile}"
    done

    mkdir -p "${stage}/files"
    local f
    for f in "${files[@]}"; do
        [[ -f "${f}" ]] || concert_die "concert_run: file not found: ${f}"
        cp "${f}" "${stage}/files/"
    done

    local rc=0
    case "${CONCERT_RUNNER:-cluster}" in
        cluster)   _concert_run_cluster "${label}" "${timeout}" "${stage}" "$@" || rc=$? ;;
        container) _concert_run_container "${stage}" "$@" || rc=$? ;;
        native)    _concert_run_native "${stage}" "$@" || rc=$? ;;
        *)         concert_die "Unknown CONCERT_RUNNER=${CONCERT_RUNNER} (cluster|container|native)" ;;
    esac
    return ${rc}
}

_concert_run_cluster() {
    local label="$1" timeout="$2" stage="$3"
    shift 3
    local ns="${PROJECT_CONCERT_INSTALLER}" image
    image="$(concert_runner_image)"

    oc get serviceaccount "${CONCERT_RUNNER_SA}" -n "${ns}" >/dev/null 2>&1 \
        && oc get pvc "${CONCERT_RUNNER_PVC}" -n "${ns}" >/dev/null 2>&1 \
        || concert_die "Runner not prepared in ${ns} - run 0_initial_setup/0.2_prepare_installer_runner.sh first."

    local job="concert-${label:l}"
    job="${job//[^a-z0-9-]/-}"
    job="${job[1,40]}-$(date +%m%d%H%M%S)"

    # errexit does not apply here (callers use `|| rc=$?`), so check each step.
    oc create secret generic "${job}-env" -n "${ns}" --from-env-file="${stage}/env" \
        --dry-run=client -o yaml | oc apply -f - >/dev/null \
        || { concert_error "Could not create ${ns}/${job}-env"; return 1; }
    oc create secret generic "${job}-files" -n "${ns}" --from-file="${stage}/files" \
        --dry-run=client -o yaml | oc apply -f - >/dev/null \
        || { concert_error "Could not create ${ns}/${job}-files"; return 1; }

    local args_json
    args_json="$(jq -nc '$ARGS.positional' --args -- "$@")" \
        || { concert_error "jq is required on the workstation"; return 1; }

    concert_runner_grant_admin || { concert_error "Could not bind cluster-admin to ${CONCERT_RUNNER_SA}"; return 1; }
    concert_info "Runner Job ${ns}/${job}: ${1} (image ${image})"
    oc apply -f - >/dev/null <<EOF || { concert_error "Could not create Job ${ns}/${job}"; concert_runner_revoke_admin; return 1; }
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${ns}
  labels:
    app.kubernetes.io/name: concert-installer-runner
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${timeout}
  ttlSecondsAfterFinished: 604800
  template:
    metadata:
      labels:
        app.kubernetes.io/name: concert-installer-runner
      annotations:
        # cluster-admin would otherwise get anyuid (UID 1001, no fsGroup), which
        # cannot write the root-owned PVC; restricted-v2 sets a writable fsGroup.
        openshift.io/required-scc: restricted-v2
    spec:
      serviceAccountName: ${CONCERT_RUNNER_SA}
      restartPolicy: Never
      containers:
      - name: runner
        image: ${image}
        imagePullPolicy: Always
        args: ${args_json}
        envFrom:
        - secretRef:
            name: ${job}-env
        volumeMounts:
        - name: work
          mountPath: /work
        - name: files
          mountPath: /config/files
          readOnly: true
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            memory: 2Gi
      volumes:
      - name: work
        persistentVolumeClaim:
          claimName: ${CONCERT_RUNNER_PVC}
      - name: files
        secret:
          secretName: ${job}-files
EOF

    # Tie the per-run secrets to the Job so the TTL cleans them up even if this
    # workstation disappears mid-run.
    local uid
    uid="$(oc get job "${job}" -n "${ns}" -o jsonpath='{.metadata.uid}')"
    local s
    for s in "${job}-env" "${job}-files"; do
        oc patch secret "${s}" -n "${ns}" --type=merge -p \
            "{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"name\":\"${job}\",\"uid\":\"${uid}\"}]}}" >/dev/null
    done

    local rc=0
    _concert_job_follow "${ns}" "${job}" "${timeout}" || rc=$?

    oc delete secret "${job}-env" "${job}-files" -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
    concert_runner_revoke_admin
    return ${rc}
}

# Follow a runner Job's pod log until the Job finishes; re-attach if the log
# stream drops (laptop sleep, VPN blip). Returns the container's exit code.
_concert_job_follow() {
    local ns="$1" job="$2" timeout="$3" start=${SECONDS} pod="" phase="" reason=""
    while [[ -z "${pod}" ]]; do
        pod="$(oc get pods -n "${ns}" -l "job-name=${job}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        [[ -n "${pod}" ]] && break
        (( SECONDS - start > 300 )) && { concert_error "No pod for Job ${job} after 300s."; oc describe job "${job}" -n "${ns}" >&2; return 1; }
        sleep 3
    done

    while true; do
        phase="$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "${phase}" == (Running|Succeeded|Failed) ]] && break
        reason="$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
        if [[ "${reason}" == (ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError|CreateContainerError) ]]; then
            concert_error "Runner pod ${pod} cannot start: ${reason}"
            oc describe pod "${pod}" -n "${ns}" | tail -20 >&2
            return 1
        fi
        (( SECONDS - start > 900 )) && { concert_error "Runner pod ${pod} still ${phase:-Pending} after 900s."; oc describe pod "${pod}" -n "${ns}" | tail -20 >&2; return 1; }
        sleep 5
    done

    local since=""
    while true; do
        oc logs -f "${pod}" -n "${ns}" ${since:+--since-time=${since}} 2>/dev/null || true
        phase="$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "${phase}" == (Succeeded|Failed) ]] && break
        if [[ -z "${phase}" ]]; then
            concert_error "Runner pod ${pod} disappeared."
            return 1
        fi
        (( SECONDS - start > timeout + 300 )) && { concert_error "Runner Job ${job} exceeded ${timeout}s."; return 1; }
        since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        concert_warn "Log stream from ${pod} dropped - re-attaching (the Job keeps running in the cluster)."
        sleep 5
    done

    local code
    code="$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
    [[ "${phase}" == Succeeded ]] && return 0
    concert_error "Runner Job ${ns}/${job} failed (exit ${code:-?}). Logs: oc logs job/${job} -n ${ns}"
    return "${code:-1}"
}

_concert_run_container() {
    local stage="$1"
    shift
    local image
    image="$(concert_runner_image)"
    command -v podman >/dev/null 2>&1 || concert_die "CONCERT_RUNNER=container needs podman."
    podman image exists "${image}" \
        || concert_die "Runner image ${image} not found - run 0_initial_setup/0.2_prepare_installer_runner.sh first."

    (umask 077; oc config view --raw --minify --flatten > "${stage}/kubeconfig")
    local work="${CONCERT_WORKSPACE}/container-work"
    mkdir -p "${work}"

    # Root inside a rootless container maps to the workstation user, so the
    # bind-mounted work dir stays writable.
    podman run --rm --platform linux/amd64 --user 0:0 \
        -v "${work}:/work" \
        -v "${stage}/kubeconfig:/kube/config:ro" -e KUBECONFIG=/kube/config \
        -v "${stage}/files:/config/files:ro" \
        --env-file "${stage}/env" \
        "${image}" "$@"
}

_concert_run_native() {
    local stage="$1"
    shift
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] \
        || concert_die "CONCERT_RUNNER=native needs a Linux x86_64 host (IBM's installer reads the local architecture)."
    concert_require_local_installer
    # IBM scripts receive /config/files/<name>; point that at the staged copy.
    local -a args=("${@//\/config\/files\//${stage}/files/}")
    (
        local k v
        while IFS='=' read -r k v; do
            [[ -n "${k}" ]] && export "${k}=${v}"
        done < "${stage}/env"
        export CONCERT_WORK_DIR="${CONCERT_WORKSPACE}/native-work"
        export CONCERT_ARCHIVE_PATH="$(concert_archive_path)"
        export CONCERT_FILES_DIR="${stage}/files"
        mkdir -p "${CONCERT_WORK_DIR}"
        bash "${CONCERT_RUNNER_SRC_DIR}/entrypoint.sh" "${args[@]}"
    )
}

# =============================================================================
# Data stores
# =============================================================================
# Consumers IBM can point at an external store (see plan §6.1).
CONCERT_DS_CONSUMERS=(KEYCLOAK CONCERT_DB CONCERT_S3 CONCERT_NEO4J DATAAPPS_DB DATAAPPS_REDIS
                      WORKFLOWS_MYSQL WORKFLOWS_POSTGRES WORKFLOWS_S3 WORKFLOWS_RABBITMQ)
CONCERT_DS_SERVERS=(POSTGRES S3 MYSQL REDIS NEO4J RABBITMQ)

concert_ds_server_of() {
    case "$1" in
        KEYCLOAK|CONCERT_DB|DATAAPPS_DB|WORKFLOWS_POSTGRES) print -r -- POSTGRES ;;
        CONCERT_S3|WORKFLOWS_S3)                            print -r -- S3 ;;
        CONCERT_NEO4J)                                      print -r -- NEO4J ;;
        DATAAPPS_REDIS)                                     print -r -- REDIS ;;
        WORKFLOWS_MYSQL)                                    print -r -- MYSQL ;;
        WORKFLOWS_RABBITMQ)                                 print -r -- RABBITMQ ;;
    esac
}

# A consumer is active when its product is selected and it is set to external.
# Neo4j is special: no internal option exists, so it is active whenever the
# graph (VEIAS) is on.
concert_ds_consumer_active() {
    local c="$1" product var
    case "${c}" in
        KEYCLOAK)                                       product=hub ;;
        CONCERT_DB|CONCERT_S3)                          product=concert ;;
        CONCERT_NEO4J)                                  concert_product_enabled concert && concert_graph_enabled; return $? ;;
        DATAAPPS_DB|DATAAPPS_REDIS)                     product=dataapps ;;
        WORKFLOWS_MYSQL|WORKFLOWS_POSTGRES|WORKFLOWS_S3|WORKFLOWS_RABBITMQ) product=workflows ;;
        *) return 1 ;;
    esac
    concert_product_enabled "${product}" || return 1
    var="CONCERT_DS_${c}"
    [[ "${(P)var:-internal}" == external ]]
}

concert_ds_server_needed() {
    local server="$1" c
    for c in "${CONCERT_DS_CONSUMERS[@]}"; do
        concert_ds_consumer_active "${c}" && [[ "$(concert_ds_server_of "${c}")" == "${server}" ]] && return 0
    done
    return 1
}

concert_ds_server_provider() {
    local var="CONCERT_DS_${1}_PROVIDER" def=provision
    [[ "$1" == RABBITMQ ]] && def=existing
    print -r -- "${(P)var:-${def}}"
}

concert_ds_server_provisioned() {
    concert_ds_server_needed "$1" && [[ "$(concert_ds_server_provider "$1")" == provision ]]
}

# Generated datastore passwords live in one Secret in the datastores namespace.
# That Secret is the source of truth for 2.3.x (servers) and 2.4 (IBM secrets).
# Prints nothing (and succeeds) when the Secret or key does not exist yet - a
# failing `oc get | base64` pipeline would trip pipefail/errexit in callers.
concert_ds_cred_get() {
    local raw
    raw="$(oc get secret "${CONCERT_DS_CRED_SECRET}" -n "${PROJECT_CONCERT_DATASTORES}" \
        -o jsonpath="{.data.${1}}" 2>/dev/null || true)"
    [[ -n "${raw}" ]] && print -r -- "${raw}" | concert_b64d
    return 0
}

# Print the credential, generating and storing it on first use.
# Always assign the result to a variable (pw="$(concert_ds_cred_ensure X)"):
# inside a "KEY=$(...)" argument a failure would go unnoticed and leave an
# empty value behind.
concert_ds_cred_ensure() {
    local key="$1" len="${2:-24}" value
    value="$(concert_ds_cred_get "${key}")"
    if [[ -z "${value}" ]]; then
        value="$(concert_random_password "${len}")"
        if ! oc get secret "${CONCERT_DS_CRED_SECRET}" -n "${PROJECT_CONCERT_DATASTORES}" >/dev/null 2>&1; then
            oc create secret generic "${CONCERT_DS_CRED_SECRET}" -n "${PROJECT_CONCERT_DATASTORES}" >/dev/null
            oc label secret "${CONCERT_DS_CRED_SECRET}" -n "${PROJECT_CONCERT_DATASTORES}" \
                "app.kubernetes.io/managed-by=${CONCERT_MANAGED_BY}" --overwrite >/dev/null
        fi
        # Generated values are alphanumeric, so they are JSON-safe here.
        oc patch secret "${CONCERT_DS_CRED_SECRET}" -n "${PROJECT_CONCERT_DATASTORES}" --type=merge \
            -p "{\"stringData\":{\"${key}\":\"${value}\"}}" >/dev/null
    fi
    print -r -- "${value}"
}

# concert_apply_secret <namespace> <name> KEY=VALUE...  (empty values skipped)
# Values go through a private env file, not argv. Re-applying replaces the
# secret's data, so keys that are no longer passed disappear.
concert_apply_secret() {
    setopt localoptions localtraps
    local ns="$1" name="$2"
    shift 2
    local dir
    dir="$(concert_private_tmpdir)"
    trap "rm -rf '${dir}'" EXIT
    local kv
    : > "${dir}/data.env"
    for kv in "$@"; do
        [[ -n "${kv#*=}" ]] && print -r -- "${kv}" >> "${dir}/data.env"
    done
    oc create secret generic "${name}" -n "${ns}" --from-env-file="${dir}/data.env" --dry-run=client -o yaml \
        | oc label -f - --local --dry-run=client -o yaml "app.kubernetes.io/managed-by=${CONCERT_MANAGED_BY}" \
        | oc apply -f - >/dev/null
    concert_info "Secret ${ns}/${name} applied."
}

# =============================================================================
# Volumes of the StatefulSet data stores (MySQL, Redis, Neo4j)
# =============================================================================
# A StatefulSet's volumeClaimTemplates cannot change once it exists, so a re-run
# with a bigger CONCERT_DS_*_STORAGE_SIZE would make `oc apply` fail. Re-runs
# keep the template the StatefulSet was created with and grow the live PVC
# instead. Growing needs a StorageClass with allowVolumeExpansion (2.0 checks);
# volumes never shrink.

# concert_sts_template_size <namespace> <statefulset> <wanted size>
concert_sts_template_size() {
    local cur
    cur="$(oc get statefulset "$2" -n "$1" \
        -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}' 2>/dev/null || true)"
    print -r -- "${cur:-$3}"
}

# concert_sts_grow_volume <namespace> <pvc> <wanted size>
concert_sts_grow_volume() {
    local ns="$1" pvc="$2" want="$3" cur cmp
    cur="$(oc get pvc "${pvc}" -n "${ns}" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)"
    [[ -n "${cur}" ]] || return 0
    cmp="$(python3 -c '
import re, sys
def size(v):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([kKMGTP]i?)?", v.strip())
    if not m:
        sys.exit(f"Unsupported storage size {v!r}")
    f = {"": 1, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15,
         "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "Pi": 2**50}[m.group(2) or ""]
    return float(m.group(1)) * f
a, b = size(sys.argv[1]), size(sys.argv[2])
print((a > b) - (a < b))
' "${want}" "${cur}")"
    case "${cmp}" in
        1)  if oc patch pvc "${pvc}" -n "${ns}" --type=merge \
                   -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${want}\"}}}}" >/dev/null; then
                concert_info "PVC ${ns}/${pvc}: growing ${cur} -> ${want} (the storage driver finishes it online)."
            else
                concert_warn "PVC ${ns}/${pvc} could not grow to ${want} - its StorageClass must allow volume expansion."
            fi ;;
        -1) concert_warn "PVC ${ns}/${pvc} is ${cur}; ${want} is smaller and volumes cannot shrink - keeping ${cur}." ;;
    esac
    return 0
}

# =============================================================================
# Waits
# =============================================================================
# concert_wait_for <timeout-s> <description> <command...>
concert_wait_for() {
    local timeout="$1" desc="$2"
    shift 2
    local start=${SECONDS}
    until "$@" >/dev/null 2>&1; do
        if (( SECONDS - start >= timeout )); then
            concert_error "Timed out after ${timeout}s waiting for: ${desc}"
            return 1
        fi
        concert_info "Waiting for ${desc} ($(( SECONDS - start ))s)"
        sleep 10
    done
}

# Prints "kind/name ready/desired" for every Deployment/StatefulSet that is
# not fully ready; prints nothing when the namespace is healthy.
concert_ns_unready_workloads() {
    oc get deployments,statefulsets -n "$1" \
        -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.spec.replicas} {.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
        | awk 'NF>=2 { r = ($3 == "" ? 0 : $3); if ($2 > 0 && r < $2) print $1, r "/" $2 }'
}

# Wait for every MachineConfigPool to be Updated and not Updating.
concert_wait_mcp_updated() {
    local timeout="${1:-3600}" start=${SECONDS} pending
    sleep 20   # let the MCO notice the change first
    local raw
    while true; do
        # Control-plane nodes reboot during a rollout, so API errors are expected:
        # treat them as "still rolling", never as a failure of the caller.
        raw="$(oc get machineconfigpools -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Updated")].status} {.status.conditions[?(@.type=="Updating")].status}{"\n"}{end}' 2>/dev/null || true)"
        if [[ -z "${raw}" ]]; then
            pending="(API not reachable)"
        else
            pending="$(print -r -- "${raw}" | awk '$2 != "True" || $3 == "True" { print $1 }' | xargs)"
        fi
        [[ -z "${pending}" ]] && { concert_info "All MachineConfigPools are updated."; return 0; }
        if (( SECONDS - start >= timeout )); then
            concert_error "MachineConfigPools still updating after ${timeout}s: ${pending}"
            return 1
        fi
        concert_info "MachineConfigPools rolling out: ${pending} ($(( SECONDS - start ))s)"
        sleep 30
    done
}

# =============================================================================
# Capacity
# =============================================================================
# concert_worker_capacity <min vCPU> <min memory Gi>
# Prints "<qualifying> <schedulable>": schedulable worker nodes, and how many of
# them meet the per-node minimum. Allocatable is compared against 90% of the
# nominal size, because the kubelet reserves some CPU and memory.
concert_worker_capacity() {
    oc get nodes -o json | python3 -c '
import json, re, sys
min_cpu, min_mem = float(sys.argv[1]) * 0.9, float(sys.argv[2]) * 0.9
def cpu(v):
    return float(v[:-1]) / 1000 if v.endswith("m") else float(v)
def mem_gi(v):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([KMGT]i?)?", v)
    n, u = float(m.group(1)), (m.group(2) or "")
    f = {"": 1 / 1024**3, "Ki": 1 / 1024**2, "Mi": 1 / 1024, "Gi": 1, "Ti": 1024,
         "K": 1e3 / 1024**3, "M": 1e6 / 1024**3, "G": 1e9 / 1024**3, "T": 1e12 / 1024**3}[u]
    return n * f
ok = total = 0
for n in json.load(sys.stdin)["items"]:
    labels = n["metadata"].get("labels", {})
    if "node-role.kubernetes.io/worker" not in labels or n["spec"].get("unschedulable"):
        continue
    if any(t.get("effect") == "NoSchedule" for t in n["spec"].get("taints", [])):
        continue
    total += 1
    a = n["status"]["allocatable"]
    if cpu(a["cpu"]) >= min_cpu and mem_gi(a["memory"]) >= min_mem:
        ok += 1
print(ok, total)
' "$1" "$2"
}

# =============================================================================
# Operators
# =============================================================================
# concert_install_operator <namespace> <package> <channel> <source> <csv-prefix> [own|all]
# Idempotent Subscription install built on operator_install_helpers.sh.
concert_install_operator() {
    local ns="$1" pkg="$2" channel="$3" source="$4" csv_prefix="$5" scope="${6:-all}"
    local phase state
    phase="$(cp4d_csv_phase "${ns}" "${csv_prefix}")"
    if [[ "${phase}" == Succeeded ]]; then
        state="$(cp4d_reconcile_subscription_channel "${ns}" "${pkg}" "${channel}")" \
            || concert_die "${pkg} is on a channel incompatible with ${channel}; migrate it manually."
        case "${state}" in
            match)   concert_info "${pkg} already installed on channel ${channel} in ${ns}."; return 0 ;;
            patched) concert_info "${pkg} channel patched to ${channel}; waiting for OLM."
                     cp4d_wait_for_csv "${ns}" "${csv_prefix}" 900; return $? ;;
            absent)  concert_info "${pkg} CSV present without Subscription; reconciling." ;;
        esac
    fi

    cp4d_ensure_namespace "${ns}"
    if [[ "${ns}" != openshift-operators ]]; then
        if [[ "${scope}" == own ]]; then
            cp4d_ensure_operatorgroup "${ns}" "${ns}-og" "${ns}"
        else
            cp4d_ensure_operatorgroup "${ns}" "${ns}-og"
        fi
    fi

    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${pkg}
  namespace: ${ns}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: ${pkg}
  source: ${source}
  sourceNamespace: openshift-marketplace
EOF
    concert_info "Waiting for ${pkg} CSV in ${ns}..."
    cp4d_wait_for_csv "${ns}" "${csv_prefix}" 900
}
