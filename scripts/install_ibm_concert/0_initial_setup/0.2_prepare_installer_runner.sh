#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

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
# 0.2 Prepare the runner that executes IBM's installer
# ------------------------------------------------------------------------------
# CONCERT_RUNNER=cluster (default) - Job in PROJECT_CONCERT_INSTALLER:
#   namespace, ServiceAccount concert-installer, PVC concert-installer-work and
#   the runner image, from CONCERT_RUNNER_IMAGE_SOURCE:
#     build-in-cluster  BuildConfig binary build -> ImageStream (entitled default)
#     build-local-push  podman build here -> push to PRIVATE_REGISTRY_LOCATION
#                       (mirrored/airgap default; airgap: --phase=save|load)
#     prebuilt          CONCERT_RUNNER_IMAGE as given
#   then a smoke-test Job (CONCERT_RUNNER_SMOKE_TEST=false to skip).
# CONCERT_RUNNER=container - podman build on this workstation.
# CONCERT_RUNNER=native    - checks the Linux bastion's tools.
#
# The image is rebuilt only when the Containerfile, entrypoint, oc wrapper, installer
# archive, helm version or base image changed (hash label/annotation).
# ==============================================================================

PHASE="${CONCERT_AIRGAP_PHASE:-}"
for _arg in "$@"; do
    case "${_arg}" in
        --phase=*) PHASE="${_arg#*=}" ;;
        *) concert_die "Unknown argument: ${_arg} (only --phase=save|load)" ;;
    esac
done

RUNNER="${CONCERT_RUNNER:-cluster}"
NS="${PROJECT_CONCERT_INSTALLER}"
HELM_TGZ="${CONCERT_WORKSPACE}/tools/helm-${CONCERT_HELM_VERSION}-linux-amd64.tar.gz"
CTX="${CONCERT_WORKSPACE}/runner-build/${CONCERT_VERSION}"
BASE_IMAGE="${CONCERT_RUNNER_BASE_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}"
AIRGAP_DIR="${CONCERT_AIRGAP_DIR:-${CONCERT_WORKSPACE}/airgap}"
RUNNER_TAR="${AIRGAP_DIR}/concert-installer-runner-${CONCERT_VERSION}.tar"

_runner_hash() {
    {
        cat "${CONCERT_RUNNER_SRC_DIR}/Containerfile" "${CONCERT_RUNNER_SRC_DIR}/entrypoint.sh" "${CONCERT_RUNNER_SRC_DIR}/bin/oc"
        cat "$(concert_archive_path).sha256" 2>/dev/null || true
        print -r -- "${CONCERT_HELM_VERSION} ${BASE_IMAGE}"
    } | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print substr($1,1,16)}'
}

_prepare_context() {
    concert_require_local_installer
    [[ -f "${HELM_TGZ}" ]] || concert_die "helm tarball missing (${HELM_TGZ}) - run 0.1_fetch_concert_installer.sh."
    rm -rf "${CTX}"
    mkdir -p "${CTX}"
    cp "${CONCERT_RUNNER_SRC_DIR}/Containerfile" "${CONCERT_RUNNER_SRC_DIR}/entrypoint.sh" "${CTX}/"
    cp "${CONCERT_RUNNER_SRC_DIR}/bin/oc" "${CTX}/oc-wrapper"
    cp "$(concert_archive_path)" "${CTX}/${CONCERT_ARCHIVE}"
    cp "${HELM_TGZ}" "${CTX}/helm-linux-amd64.tar.gz"
}

_local_build() {   # <image tag>
    local tag="$1" have
    command -v podman >/dev/null 2>&1 || concert_die "podman is required to build the runner image locally."
    have="$(podman image inspect --format '{{ index .Labels "concert.runner.hash" }}' "${tag}" 2>/dev/null || true)"
    if [[ "${have}" == "${HASH}" ]]; then
        concert_info "Runner image ${tag} is up to date (${HASH})."
        return 0
    fi
    _prepare_context
    local -a extra=()
    [[ -n "${CONCERT_RUNNER_OC_URL:-}" ]] && extra+=(--build-arg "OC_URL=${CONCERT_RUNNER_OC_URL}")
    concert_info "Building ${tag} (linux/amd64; slow under emulation on Apple Silicon)..."
    podman build --platform linux/amd64 -f "${CTX}/Containerfile" -t "${tag}" \
        --label "concert.runner.hash=${HASH}" \
        --build-arg "CONCERT_VERSION=${CONCERT_VERSION}" \
        --build-arg "CONCERT_ARCHIVE=${CONCERT_ARCHIVE}" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
        "${extra[@]}" \
        "${CTX}"
}

_registry_login() {
    local host="${PRIVATE_REGISTRY_LOCATION%%/*}"
    concert_require_vars PRIVATE_REGISTRY_LOCATION PRIVATE_REGISTRY_PUSH_USER PRIVATE_REGISTRY_PUSH_PASSWORD
    print -r -- "${PRIVATE_REGISTRY_PUSH_PASSWORD}" \
        | podman login --username "${PRIVATE_REGISTRY_PUSH_USER}" --password-stdin "${host}" >/dev/null
}

HASH="$(_runner_hash)"

# ------------------------------------------------------------------------------
case "${RUNNER}" in
native)
    concert_info "Checking this bastion's tools for CONCERT_RUNNER=native..."
    [[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || concert_die "native runner needs Linux x86_64 (this is $(uname -s)/$(uname -m))."
    missing=()
    for t in bash oc kubectl helm jq openssl envsubst sha256sum timeout tar; do
        command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
    done
    (( ${#missing} == 0 )) || concert_die "Missing tools: ${missing[*]} (helm: tar -xzf ${HELM_TGZ} linux-amd64/helm)"
    (( $(bash -c 'echo ${BASH_VERSINFO[0]}') >= 4 )) || concert_die "bash >= 4 required."
    concert_require_local_installer
    concert_info "Native runner ready."
    exit 0
    ;;
container)
    _local_build "$(concert_runner_image)"
    concert_info "Container runner ready: $(concert_runner_image)"
    exit 0
    ;;
cluster) ;;
*) concert_die "Unknown CONCERT_RUNNER=${RUNNER}" ;;
esac

# --- cluster runner -------------------------------------------------------------
SOURCE="$(concert_runner_image_source)"
IMAGE="$(concert_runner_image)"

# Air-gap save phase runs on the connected side: build and save, no cluster.
if [[ "${SOURCE}" == build-local-push && "${CONCERT_IMAGE_SOURCE}" == airgap && "${PHASE}" == save ]]; then
    _local_build "${IMAGE}"
    mkdir -p "${AIRGAP_DIR}"
    podman save -o "${RUNNER_TAR}" "${IMAGE}"
    concert_info "Saved ${IMAGE} to ${RUNNER_TAR} - transfer it with the other air-gap files, then run with --phase=load."
    exit 0
fi

eval "${OC_LOGIN}"

concert_info "Preparing runner namespace ${NS}"
cp4d_ensure_namespace "${NS}"
oc create serviceaccount "${CONCERT_RUNNER_SA}" -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null

if ! oc get pvc "${CONCERT_RUNNER_PVC}" -n "${NS}" >/dev/null 2>&1; then
    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${CONCERT_RUNNER_PVC}
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${CONCERT_STG_CLASS_DATASTORES:-${CONCERT_STG_CLASS_BLOCK}}
  resources:
    requests:
      storage: ${CONCERT_RUNNER_PVC_SIZE:-5Gi}
EOF
    concert_info "PVC ${NS}/${CONCERT_RUNNER_PVC} created."
fi

case "${SOURCE}" in
build-in-cluster)
    state="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || true)"
    [[ "${state}" == Managed ]] || concert_die "The internal image registry is '${state:-unknown}', not Managed. Use CONCERT_RUNNER_IMAGE_SOURCE=build-local-push or CONCERT_RUNNER=container."

    # `oc create imagestream --dry-run=client` drops -n from its output, so the
    # namespace goes on the apply (otherwise it lands in the current project).
    oc create imagestream concert-installer-runner --dry-run=client -o yaml | oc apply -n "${NS}" -f - >/dev/null
    oc apply -f - >/dev/null <<EOF
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: concert-installer-runner
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  runPolicy: Serial
  source:
    type: Binary
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Containerfile
      buildArgs:
      - name: CONCERT_VERSION
        value: "${CONCERT_VERSION}"
      - name: CONCERT_ARCHIVE
        value: "${CONCERT_ARCHIVE}"
      - name: BASE_IMAGE
        value: "${BASE_IMAGE}"
      - name: OC_URL
        value: "${CONCERT_RUNNER_OC_URL:-http://downloads.openshift-console.svc.cluster.local/amd64/linux/oc.tar}"
  output:
    to:
      kind: ImageStreamTag
      name: concert-installer-runner:${CONCERT_VERSION}
EOF
    hash_key="concert.ibm.com/runner-hash-${CONCERT_VERSION//[^0-9A-Za-z]/-}"
    have="$(oc get imagestream concert-installer-runner -n "${NS}" -o jsonpath="{.metadata.annotations.${hash_key//./\\.}}" 2>/dev/null || true)"
    if [[ "${have}" == "${HASH}" ]] && oc get istag "concert-installer-runner:${CONCERT_VERSION}" -n "${NS}" >/dev/null 2>&1; then
        concert_info "Runner image ${IMAGE} is up to date (${HASH})."
    else
        _prepare_context
        concert_info "Starting in-cluster build (uploads ~$(du -sh "${CTX}" | awk '{print $1}'))..."
        oc start-build concert-installer-runner -n "${NS}" --from-dir="${CTX}" --follow --wait
        oc annotate imagestream concert-installer-runner -n "${NS}" "${hash_key}=${HASH}" --overwrite >/dev/null
        concert_info "Runner image built: ${IMAGE}"
    fi
    ;;
build-local-push)
    concert_require_vars PRIVATE_REGISTRY_LOCATION PRIVATE_REGISTRY_PULL_USER PRIVATE_REGISTRY_PULL_PASSWORD
    if [[ "${CONCERT_IMAGE_SOURCE}" == airgap ]]; then
        # Disconnected side. Without --phase (e.g. from the full wrapper) this is
        # the load phase; an image loaded earlier is reused.
        if ! podman image exists "${IMAGE}"; then
            [[ -f "${RUNNER_TAR}" ]] || concert_die "Air-gap: no ${RUNNER_TAR} - run with --phase=save on the connected side and transfer it."
            podman load -i "${RUNNER_TAR}"
        fi
    else
        _local_build "${IMAGE}"
    fi
    _registry_login
    podman push "${IMAGE}"
    concert_info "Pushed ${IMAGE}"
    # Let the runner ServiceAccount pull from the private registry.
    _pull_cfg="$(concert_private_tmpdir)"
    concert_write_dockerconfig "${_pull_cfg}/config.json" \
        "${PRIVATE_REGISTRY_LOCATION%%/*}=PRIVATE_REGISTRY_PULL_USER:PRIVATE_REGISTRY_PULL_PASSWORD"
    oc create secret generic concert-runner-pull -n "${NS}" --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="${_pull_cfg}/config.json" --dry-run=client -o yaml | oc apply -f - >/dev/null
    rm -rf "${_pull_cfg}"
    oc secrets link "${CONCERT_RUNNER_SA}" concert-runner-pull --for=pull -n "${NS}"
    ;;
prebuilt)
    concert_require_vars CONCERT_RUNNER_IMAGE
    concert_info "Using prebuilt runner image ${IMAGE}"
    ;;
*) concert_die "Unknown CONCERT_RUNNER_IMAGE_SOURCE=${SOURCE}" ;;
esac

# --- Smoke test -----------------------------------------------------------------
if concert_is_true "${CONCERT_RUNNER_SMOKE_TEST:-true}"; then
    concert_info "Smoke-testing the runner (Job in ${NS})..."
    concert_run --name smoke --timeout 900 -- __shell__ \
        'set -e; echo "arch: $(uname -m)"; bash --version | head -1; oc version --client | head -1; helm version --short; jq --version; envsubst --version | head -1; oc whoami; test -x bin/setup && echo "installer: $(cat etc/build_version)"'
    concert_info "Runner ready: ${IMAGE}"
fi
