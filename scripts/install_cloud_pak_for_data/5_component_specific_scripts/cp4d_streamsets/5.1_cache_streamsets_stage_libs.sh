#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# =============================================================================
# 5.1_cache_streamsets_stage_libs.sh   (optional)
# -----------------------------------------------------------------------------
# Copies the StreamSets stage libraries image (several GB) once into a shared
# ReadWriteMany volume in the engine namespace, so engines don't each pull it.
#
# Without this, every engine pod mounts ${LIBS_REPO}:<tag> as an image volume,
# so each node that runs an engine pulls the whole image from cp.icr.io before
# the engine can start (minutes on a fresh node). With it, a Job pulls the image
# once, copies it into the PVC sset-stagelibs-<tag>, and marks the PVC as ready.
# 5_create_streamsets_engine.sh then mounts that PVC read-only instead, on any
# node, for current and new engines alike. Re-run the engine script (or
# 5_setup_streamsets.sh) afterwards to move existing engines onto it.
#
# The engine image itself (${IMAGE_REPO}) is still pulled by each node. The cache
# holds every library; each engine links only its environment's ones from it.
#
# Progress is shown on one status line: elapsed time while the node pulls the
# image (OpenShift reports no byte counts for a pull), then a progress bar for
# the copy into the PVC.
#
# One PVC per tag. A PVC already marked ready for the tag is left alone, so
# re-running is safe; a copy that failed halfway is redone.
#
# Usage:
#   ./5.1_cache_streamsets_stage_libs.sh [--image-tag <tag>] [--storage-class <rwx class>] [--size <n>Gi]
#
# Env vars (flags win): SSET_IMAGE_TAG, SSET_STAGELIBS_STORAGE_CLASS, SSET_STAGELIBS_SIZE
# =============================================================================

NAMESPACE="cpd-streamsets-engine"
IMAGE_REPO="cp.icr.io/cp/cpd/ibm-streamsets-datacollector"
LIBS_REPO="cp.icr.io/cp/cpd/ibm-streamsets-datacollector-libs"
# Set on the PVC once the copy succeeded; 5_create_streamsets_engine.sh only uses
# a PVC whose value matches the libs image it would otherwise mount.
READY_ANNOTATION="streamsets/stagelibs-image"

IMAGE_TAG="${SSET_IMAGE_TAG:-JDK17_7.7.0}"
# Empty: the first CephFS / NFS / file storage class on the cluster.
STORAGE_CLASS="${SSET_STAGELIBS_STORAGE_CLASS:-}"
SIZE="${SSET_STAGELIBS_SIZE:-20Gi}"
COPY_TIMEOUT_MIN=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-tag)     IMAGE_TAG="$2"; shift 2 ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --size)          SIZE="$2"; shift 2 ;;
    *) echo "[ERROR] unknown argument: $1" >&2; exit 1 ;;
  esac
done

IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
LIBS_IMAGE="${LIBS_REPO}:${IMAGE_TAG}"
# Same name 5_create_streamsets_engine.sh looks for.
PVC_NAME="sset-stagelibs-$(print -r -- "${IMAGE_TAG:l}" | tr -c 'a-z0-9-' '-' | sed 's/-*$//')"
JOB_NAME="${PVC_NAME}-copy"

if ! oc whoami &>/dev/null; then
  if [[ -z "${OC_LOGIN:-}" ]]; then
    echo "[ERROR] oc is not logged in and OC_LOGIN is not set (configs/cp4d_config/cpd_vars.sh)." >&2
    exit 1
  fi
  eval "${OC_LOGIN}"
fi

if [[ "$(oc get pvc "${PVC_NAME}" -n "${NAMESPACE}" \
      -o jsonpath="{.metadata.annotations.${READY_ANNOTATION}}" 2>/dev/null || true)" == "${LIBS_IMAGE}" ]]; then
  echo "[INFO] ${NAMESPACE}/${PVC_NAME} already holds ${LIBS_IMAGE}; nothing to do."
  exit 0
fi

if [[ -z "${STORAGE_CLASS}" ]]; then
  STORAGE_CLASS="$(oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.provisioner}{"\n"}{end}' \
    | awk '$2 ~ /cephfs|nfs|file/ && $1 !~ /external/ { print $1; exit }')"
  if [[ -z "${STORAGE_CLASS}" ]]; then
    echo "[ERROR] No ReadWriteMany storage class (CephFS, NFS, file) found. Pass --storage-class." >&2
    exit 1
  fi
fi
echo "[INFO] Stage libraries : ${LIBS_IMAGE}"
echo "[INFO] PVC             : ${NAMESPACE}/${PVC_NAME} (${SIZE}, ${STORAGE_CLASS}, ReadWriteMany)"

if ! oc get namespace "${NAMESPACE}" &>/dev/null; then
  echo "[INFO] Creating namespace ${NAMESPACE}..."
  oc create namespace "${NAMESPACE}"
fi

# Same pull secrets as 5_create_streamsets_engine.sh.
PULL_SECRETS_YAML=""
if oc get secret pull-secret -n openshift-config &>/dev/null; then
  oc create secret generic pull-secret -n "${NAMESPACE}" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=<(oc get secret pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d) \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  PULL_SECRETS_YAML+=$'\n        - name: pull-secret'
fi
if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
  oc create secret docker-registry ibm-entitlement-key -n "${NAMESPACE}" \
    --docker-server=cp.icr.io --docker-username=cp --docker-password="${IBM_ENTITLEMENT_KEY}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  PULL_SECRETS_YAML+=$'\n        - name: ibm-entitlement-key'
fi
if [[ -z "${PULL_SECRETS_YAML}" ]]; then
  echo "[ERROR] No pull secret available for cp.icr.io (no cluster pull-secret, no IBM_ENTITLEMENT_KEY)." >&2
  exit 1
fi

# A PVC left by a failed copy is reused (the Job empties it first).
if ! oc get pvc "${PVC_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${SIZE}
EOF
fi

oc delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=true >/dev/null

# The engine image provides the shell; the libs image is only data.
oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 1
  activeDeadlineSeconds: $(( COPY_TIMEOUT_MIN * 60 ))
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:${PULL_SECRETS_YAML}
      volumes:
        - name: libs-image
          image:
            reference: ${LIBS_IMAGE}
            pullPolicy: IfNotPresent
        - name: cache
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
      containers:
        - name: copy
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - |
              set -e
              # Apparent sizes, so the copy's total matches the source's on any filesystem.
              size_kb() { s=\$(du -sk --apparent-size "\$1" 2>/dev/null) || s=\$(du -sk "\$1" 2>/dev/null) || true; echo "\${s%%[[:space:]]*}"; }
              rm -rf /cache/streamsets-datacollector-*
              # TOTAL_KB / COPIED_KB lines drive the progress bar on the workstation.
              echo "TOTAL_KB=\$(size_kb /libs)"
              cp -R /libs/. /cache/ &
              cp_pid=\$!
              while kill -0 "\$cp_pid" 2>/dev/null; do
                echo "COPIED_KB=\$(size_kb /cache)"
                sleep 5
              done
              wait "\$cp_pid"
              echo "COPIED_KB=\$(size_kb /cache)"
              n=\$(ls /cache/streamsets-datacollector-*/streamsets-libs | wc -l)
              [ "\$n" -gt 0 ] || { echo "no stage libraries found in the image"; exit 1; }
              echo "copied \$n stage libraries (\$(du -sh /cache | cut -f1))"
          volumeMounts:
            - name: libs-image
              mountPath: /libs
              readOnly: true
            - name: cache
              mountPath: /cache
          resources:
            requests:
              cpu: 500m
              memory: 256Mi
EOF

# --- Wait, with a status line ------------------------------------------------------
# On a terminal the line is redrawn in place; otherwise (CI, a log file) it is
# printed at most every 30s.
[[ -t 1 ]] && TTY=true || TTY=false
_last_plain=-30
status_line() {
  if [[ "${TTY}" == true ]]; then
    printf '\r\033[K%s' "$1"
  elif (( SECONDS - _last_plain >= 30 )); then
    print -r -- "$1"
    _last_plain=${SECONDS}
  fi
}
# Ends the status line, so the next message starts on its own line.
end_status_line() { [[ "${TTY}" == true ]] && echo || true; }
fmt_time() { (( $1 >= 60 )) && print -r -- "$(( $1 / 60 ))m$(( $1 % 60 ))s" || print -r -- "$1s"; }
progress_bar() {
  local done_kb=$1 total_kb=$2 width=30 pct filled
  (( done_kb > total_kb )) && done_kb=${total_kb}
  pct=$(( done_kb * 100 / total_kb ))
  filled=$(( pct * width / 100 ))
  printf '[%s%s] %3d%%  %.1f / %.1f GB' "${(l:filled::#:)}" "${(l:width-filled::.:)}" \
    "${pct}" "$(( done_kb / 1048576.0 ))" "$(( total_kb / 1048576.0 ))"
}

echo "[INFO] Pulling ${LIBS_IMAGE} once and copying it into the PVC (up to ${COPY_TIMEOUT_MIN} min)..."
_t0=${SECONDS}
_total_kb=""
_warned=""
while true; do
  # 'Complete' or 'Failed' (out of retries, or past activeDeadlineSeconds) once the Job is done.
  _status="$(oc get job "${JOB_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null || true)"
  [[ "${_status}" == *Complete* ]] && break
  if [[ "${_status}" == *Failed* ]]; then
    end_status_line
    echo "[ERROR] The copy failed. Job logs:" >&2
    oc logs "job/${JOB_NAME}" -n "${NAMESPACE}" --tail=50 2>&1 | grep -v '_KB=' >&2 || true
    oc get events -n "${NAMESPACE}" --field-selector involvedObject.kind=Pod --sort-by=.lastTimestamp 2>/dev/null \
      | grep "${JOB_NAME}" | tail -n 5 >&2 || true
    exit 1
  fi

  _elapsed="$(fmt_time $(( SECONDS - _t0 )))"
  read -r _pod _node _phase <<< "$(oc get pods -n "${NAMESPACE}" -l job-name="${JOB_NAME}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name} {.items[-1:].spec.nodeName} {.items[-1:].status.phase}' 2>/dev/null || true)"

  if [[ -z "${_pod:-}" ]]; then
    status_line "[INFO] Starting the copy pod... ${_elapsed}"
  elif [[ "${_phase}" == Running ]]; then
    _logs="$(oc logs "${_pod}" -n "${NAMESPACE}" 2>/dev/null || true)"
    [[ -n "${_total_kb}" ]] || _total_kb="$(sed -n 's/^TOTAL_KB=//p' <<< "${_logs}" | tail -n 1)"
    _copied_kb="$(sed -n 's/^COPIED_KB=//p' <<< "${_logs}" | tail -n 1)"
    if [[ "${_total_kb}" == <1-> ]]; then
      status_line "[INFO] Copying $(progress_bar "${_copied_kb:-0}" "${_total_kb}")  ${_elapsed}"
    else
      status_line "[INFO] Measuring the stage libraries... ${_elapsed}"
    fi
  else
    # Pending: the node is pulling. Warn (once per message) about pull or mount
    # errors; the Job keeps retrying them until COPY_TIMEOUT_MIN.
    _event="$(oc get events -n "${NAMESPACE}" --field-selector "involvedObject.name=${_pod}" \
      --sort-by=.lastTimestamp -o jsonpath='{range .items[*]}{.reason}{"\t"}{.message}{"\n"}{end}' 2>/dev/null \
      | tail -n 1 || true)"
    if [[ "${_event%%$'\t'*}" == (Failed|BackOff|FailedMount|FailedScheduling) && "${_event}" != "${_warned}" ]]; then
      end_status_line
      echo "[WARN] ${_event%%$'\t'*}: ${_event#*$'\t'}" >&2
      _warned="${_event}"
    fi
    status_line "[INFO] Pulling the image on ${_node:-(not scheduled yet)}... ${_elapsed}"
  fi
  sleep 3
done
end_status_line
unset _status _elapsed _pod _node _phase _logs _copied_kb _event _warned

# The pull's duration and image size, from the kubelet's 'Pulled' event.
_pod="$(oc get pods -n "${NAMESPACE}" -l job-name="${JOB_NAME}" --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
if [[ -n "${_pod}" ]]; then
  oc get events -n "${NAMESPACE}" --field-selector "involvedObject.name=${_pod},reason=Pulled" \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -F "${LIBS_REPO}" | sed 's/^/[INFO] /' || true
fi
unset _pod _total_kb
oc logs "job/${JOB_NAME}" -n "${NAMESPACE}" --tail=50 | grep -v '_KB=' | sed 's/^/[INFO]   /' || true
oc annotate pvc "${PVC_NAME}" -n "${NAMESPACE}" --overwrite "${READY_ANNOTATION}=${LIBS_IMAGE}" >/dev/null

echo "[INFO] Stage libraries cached in ${NAMESPACE}/${PVC_NAME}."
echo "[INFO] Re-run 5_create_streamsets_engine.sh (or 5_setup_streamsets.sh) to move engines onto it."
