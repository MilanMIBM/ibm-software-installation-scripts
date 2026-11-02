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
# A Job (running the cluster's own oc image, imagestream openshift/cli, for its
# python3 and tar) streams each layer of ${LIBS_REPO}:<tag> from the registry
# into the PVC sset-stagelibs-<tag>, then the PVC is marked as ready. 5.2_create_streamsets_engine.sh mounts that
# PVC read-only, on any node, for current and new engines alike. Re-run the
# engine script (or 5.x_full_streamsets_setup.sh) afterwards to move existing
# engines onto it.
#
# Required on clusters without the ImageVolume feature gate (OpenShift 4.19 and
# earlier): there the API server silently drops image volumes, so engines have
# no other way to get the libraries. Where image volumes work, engines can mount
# the libs image directly instead, but then every node running an engine pulls
# the whole image (several GB) before it can start.
#
# The engine image itself (${IMAGE_REPO}) is still pulled by each node. The cache
# holds every library; each engine links only its environment's ones from it.
#
# Progress is shown on one status line: elapsed time while the pod starts, then
# a progress bar of the download (compressed bytes) into the PVC.
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
# Set on the PVC once the copy succeeded; 5.2_create_streamsets_engine.sh only uses
# a PVC whose value matches the libs image it would otherwise mount.
READY_ANNOTATION="streamsets/stagelibs-image"

IMAGE_TAG="${SSET_IMAGE_TAG:-JDK17_7.7.0}"
# Empty: STG_CLASS_FILE from cpd_vars.sh, else the first CephFS / NFS / file storage class.
STORAGE_CLASS="${SSET_STAGELIBS_STORAGE_CLASS:-${STG_CLASS_FILE:-}}"
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
# Same name 5.2_create_streamsets_engine.sh looks for.
PVC_NAME="sset-stagelibs-$(print -r -- "${IMAGE_TAG:l}" | tr -c 'a-z0-9-' '-' | sed 's/-*$//')"
JOB_NAME="${PVC_NAME}-copy"

# OC_LOGIN skips the login when oc is already on OCP_URL, and switches over when it is on
# another cluster - a plain 'oc whoami' check would keep working against that other cluster.
if [[ -n "${OC_LOGIN:-}" ]]; then
  eval "${OC_LOGIN}"
elif ! oc whoami &>/dev/null; then
  echo "[ERROR] oc is not logged in and OC_LOGIN is not set (configs/cp4d_config/cpd_vars.sh)." >&2
  exit 1
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

# Same pull secrets as 5.2_create_streamsets_engine.sh.
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

# The libs image has no shell, and mounting it as an image volume needs the
# ImageVolume feature gate (off on OpenShift 4.19 and earlier, where the API
# server silently drops the volume and the copy finds nothing). 'oc image
# extract' can't be used either: the image ships directories read-only, and a
# non-root pod can't write the rest of a layer into them. So the Job streams each
# layer blob from the registry into GNU tar (which keeps directories writable
# until a layer is done), using the cluster's own oc image for python3 and tar.
CLI_IMAGE="$(oc get istag cli:latest -n openshift -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)"
CLI_IMAGE="${CLI_IMAGE:-image-registry.openshift-image-registry.svc:5000/openshift/cli:latest}"
# Registry auth for the download: the entitlement key if set, else the cluster pull secret.
if [[ "${PULL_SECRETS_YAML}" == *ibm-entitlement-key* ]]; then
  AUTH_SECRET="ibm-entitlement-key"
else
  AUTH_SECRET="pull-secret"
fi
ARCH="$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
ARCH="${ARCH:-amd64}"

oc create configmap "${JOB_NAME}-script" -n "${NAMESPACE}" --dry-run=client -o yaml \
  --from-file=extract.py=/dev/stdin <<'PY' | oc apply -f - >/dev/null
# Unpacks LIBS_IMAGE (registry/repo:tag) into /cache, layer by layer.
# Prints TOTAL_KB / COPIED_KB (compressed bytes downloaded) for the progress bar.
import base64, json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

image, arch, dest = os.environ["LIBS_IMAGE"], os.environ.get("ARCH", "amd64"), "/cache"
registry, rest = image.split("/", 1)
repo, tag = rest.rsplit(":", 1)
auths = json.load(open("/auth/config.json")).get("auths", {})
entry = auths.get(registry) or auths.get("https://" + registry) or {}
basic = entry.get("auth") or base64.b64encode(
    ("%s:%s" % (entry.get("username", ""), entry.get("password", ""))).encode()).decode()

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None
opener = urllib.request.build_opener(NoRedirect)
token = None

def get(path, accept=None):
    """GET https://<registry>/v2/<path>, signing in on a Bearer challenge and
    following redirects (to blob storage) without the registry credentials."""
    global token
    url = "https://%s/v2/%s" % (registry, path)
    for _ in range(2):
        req = urllib.request.Request(url)
        if accept:
            req.add_header("Accept", accept)
        if token:
            req.add_header("Authorization", "Bearer " + token)
        try:
            return opener.open(req, timeout=300)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308):
                return urllib.request.urlopen(e.headers["Location"], timeout=300)
            if e.code != 401 or token:
                raise
            ch = dict(re.findall(r'(\w+)="([^"]*)"', e.headers.get("WWW-Authenticate", "")))
            q = urllib.parse.urlencode({k: ch[k] for k in ("service", "scope") if k in ch})
            treq = urllib.request.Request(ch["realm"] + "?" + q)
            treq.add_header("Authorization", "Basic " + basic)
            body = json.load(urllib.request.urlopen(treq, timeout=60))
            token = body.get("token") or body.get("access_token")
    raise SystemExit("could not sign in to " + registry)

MANIFESTS = ",".join([
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json"])
manifest = json.load(get("%s/manifests/%s" % (repo, tag), MANIFESTS))
if "manifests" in manifest:
    pick = [m for m in manifest["manifests"]
            if m.get("platform", {}).get("os") == "linux" and m.get("platform", {}).get("architecture") == arch]
    if not pick:
        raise SystemExit("no linux/%s image in %s" % (arch, image))
    manifest = json.load(get("%s/manifests/%s" % (repo, pick[0]["digest"]), MANIFESTS))
layers = manifest["layers"]
total = sum(l["size"] for l in layers)
print("TOTAL_KB=%d" % (total // 1024), flush=True)
print("%d layers, %.2f GB compressed" % (len(layers), total / 1e9), flush=True)

done, last = 0, 0.0
for i, layer in enumerate(layers, 1):
    if "zstd" in layer["mediaType"]:
        raise SystemExit("zstd layers are not supported: " + layer["digest"])
    flags = ["-xzf" if "gzip" in layer["mediaType"] else "-xf", "-", "-C", dest,
             "--no-same-owner", "--no-same-permissions", "--delay-directory-restore"]
    tar = subprocess.Popen(["tar"] + flags, stdin=subprocess.PIPE)
    resp = get("%s/blobs/%s" % (repo, layer["digest"]))
    while True:
        chunk = resp.read(1 << 20)
        if not chunk:
            break
        tar.stdin.write(chunk)
        done += len(chunk)
        if time.time() - last >= 5:
            print("COPIED_KB=%d" % (done // 1024), flush=True)
            last = time.time()
    tar.stdin.close()
    if tar.wait() != 0:
        raise SystemExit("tar failed on layer %d (%s)" % (i, layer["digest"]))
    # Whiteouts: '.wh.<name>' deletes <name> from earlier layers.
    for root, dirs, files in os.walk(dest):
        for f in files:
            if f.startswith(".wh."):
                if f != ".wh..wh..opq":
                    subprocess.run(["rm", "-rf", os.path.join(root, f[4:])])
                os.remove(os.path.join(root, f))
    # Read-only directories would block the next layer.
    subprocess.run(["find", dest, "-type", "d", "!", "-perm", "-u+w", "-exec", "chmod", "u+w", "{}", "+"])
print("COPIED_KB=%d" % (done // 1024), flush=True)
PY

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
        - name: registry-auth
          secret:
            secretName: ${AUTH_SECRET}
            items:
              - key: .dockerconfigjson
                path: config.json
        - name: script
          configMap:
            name: ${JOB_NAME}-script
        - name: cache
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
      containers:
        - name: copy
          image: ${CLI_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: HOME
              value: /tmp
            - name: LIBS_IMAGE
              value: ${LIBS_IMAGE}
            - name: ARCH
              value: ${ARCH}
          command: ["sh", "-c"]
          args:
            - |
              set -e
              chmod -R u+w /cache 2>/dev/null || true
              rm -rf /cache/* /cache/.[!.]* 2>/dev/null || true
              python3 -u /script/extract.py
              n=\$(ls -d /cache/streamsets-datacollector-*/streamsets-libs/* 2>/dev/null | wc -l)
              [ "\$n" -gt 0 ] || { echo "no stage libraries found in the image:"; ls -la /cache; exit 1; }
              echo "copied \$n stage libraries (\$(du -sh /cache | cut -f1)); volume: \$(df -h /cache | awk 'NR==2 { print \$3 " used, " \$4 " free" }')"
          volumeMounts:
            - name: registry-auth
              mountPath: /auth
              readOnly: true
            - name: script
              mountPath: /script
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
  local done_kb=$1 total_kb=$2 width=30 pct filled pad=""
  (( done_kb > total_kb )) && done_kb=${total_kb}
  pct=$(( done_kb * 100 / total_kb ))
  filled=$(( pct * width / 100 ))
  # Padding a named empty parameter: an unnamed one fails under set -u.
  printf '[%s%s] %3d%%  %.1f / %.1f GB' "${(l:filled::#:)pad}" "${(l:width-filled::.:)pad}" \
    "${pct}" "$(( done_kb / 1048576.0 ))" "$(( total_kb / 1048576.0 ))"
}

echo "[INFO] Extracting ${LIBS_IMAGE} into the PVC (up to ${COPY_TIMEOUT_MIN} min)..."
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
  elif [[ "${_phase}" == (Succeeded|Failed) ]]; then
    # The pod is done; the Job's condition follows within seconds.
    status_line "[INFO] Finishing... ${_elapsed}"
  else
    # Pending: the node is pulling the oc image or mounting the PVC. Warn (once
    # per message) about pull or mount errors; the Job keeps retrying them until
    # COPY_TIMEOUT_MIN.
    _event="$(oc get events -n "${NAMESPACE}" --field-selector "involvedObject.name=${_pod}" \
      --sort-by=.lastTimestamp -o jsonpath='{range .items[*]}{.reason}{"\t"}{.message}{"\n"}{end}' 2>/dev/null \
      | tail -n 1 || true)"
    if [[ "${_event%%$'\t'*}" == (Failed|BackOff|FailedMount|FailedScheduling) && "${_event}" != "${_warned}" ]]; then
      end_status_line
      echo "[WARN] ${_event%%$'\t'*}: ${_event#*$'\t'}" >&2
      _warned="${_event}"
    fi
    status_line "[INFO] Starting the extract pod on ${_node:-(not scheduled yet)}... ${_elapsed}"
  fi
  sleep 3
done
end_status_line
unset _status _elapsed _pod _node _phase _logs _copied_kb _event _warned

unset _total_kb
oc logs "job/${JOB_NAME}" -n "${NAMESPACE}" --tail=50 | grep -v '_KB=' | sed 's/^/[INFO]   /' || true
oc annotate pvc "${PVC_NAME}" -n "${NAMESPACE}" --overwrite "${READY_ANNOTATION}=${LIBS_IMAGE}" >/dev/null

echo "[INFO] Stage libraries cached in ${NAMESPACE}/${PVC_NAME}."
echo "[INFO] Re-run 5.2_create_streamsets_engine.sh (or 5.x_full_streamsets_setup.sh) to move engines onto it."
