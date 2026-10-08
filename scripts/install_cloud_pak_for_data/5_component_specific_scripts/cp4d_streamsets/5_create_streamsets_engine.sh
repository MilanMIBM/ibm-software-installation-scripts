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
# 5_create_streamsets_engine.sh
# -----------------------------------------------------------------------------
# Creates a StreamSets Data Collector engine for an existing StreamSets
# environment (looked up by name) on Cloud Pak for Data.
#
#   - Auth          : CPD_URL + CPD_USERNAME + CPD_APIKEY (cpd_instance_details.sh),
#                     unless --cpd-url / --username / --api-key are passed. The
#                     engine runs as whichever user authenticates here.
#   - Cluster login : OC_LOGIN (cpd_vars.sh), unless --cluster-url /
#                     --cluster-apikey are passed. Not used with --local.
#   - Namespace     : cpd-streamsets-engine (created if missing, reused otherwise)
#   - Provider      : docker | podman, read from the environment's engine
#                     configuration (falls back to whichever CLI is installed)
#
# Default target is the OpenShift namespace: the environment's engine run
# command is translated into a Deployment there (same image, env vars and CPU
# limit). With --local the run command is executed on this workstation with
# docker or podman instead.
#
# Usage:
#   ./5_create_streamsets_engine.sh <environment_name> [options]
#
# Options:
#   --project <name|id>     project that owns the environment (default: search all)
#   --provider docker|podman  override the provider from the environment config
#   --local                 run the container locally instead of on OpenShift
#   --image-tag <tag>       engine image tag (default: from environment, else JDK17_7.7.0)
#   --cpus <n>              CPUs for the engine (default: from environment, else 4.0)
#   --project-id <id>       StreamSets project id      } both set = skip the
#   --environment-id <id>   StreamSets environment id  } lookup by name
#   --cpd-url <url>         CPD URL to auth against (default: CPD_URL)
#   --username <user>       CPD user to auth as (default: CPD_USERNAME)
#   --api-key <key>         API key for that user (default: CPD_APIKEY)
#   --cluster-url <url>     OpenShift API URL to log in to (default: OCP_URL)
#   --cluster-apikey <key>  OpenShift token (sha256~...) or IBM Cloud API key
#                           for that cluster (default: LOGIN_ARGUMENTS)
#
# Every option can also be passed as an env var (flags win):
#   SSET_PROJECT_ID, SSET_ENVIRONMENT_ID, SSET_PROJECT, SSET_PROVIDER,
#   SSET_LOCAL=1, SSET_IMAGE_TAG, SSET_CPUS, SSET_BASE_URL, SSET_API_USER,
#   SSET_API_KEY, SSET_CLUSTER_URL, SSET_CLUSTER_APIKEY
# =============================================================================

NAMESPACE="cpd-streamsets-engine"
IMAGE_REPO="cp.icr.io/cp/cpd/ibm-streamsets-datacollector"
LIBS_REPO="cp.icr.io/cp/cpd/ibm-streamsets-datacollector-libs"

ENV_NAME=""
PROJECT_FILTER="${SSET_PROJECT:-}"
PROVIDER="${SSET_PROVIDER:-}"
LOCAL="${SSET_LOCAL:-0}"
IMAGE_TAG="${SSET_IMAGE_TAG:-}"
CPUS="${SSET_CPUS:-}"
API_URL="${SSET_BASE_URL:-}"
API_USER="${SSET_API_USER:-}"
API_KEY="${SSET_API_KEY:-}"
CLUSTER_URL="${SSET_CLUSTER_URL:-}"
CLUSTER_APIKEY="${SSET_CLUSTER_APIKEY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT_FILTER="$2"; shift 2 ;;
    --provider)   PROVIDER="$2"; shift 2 ;;
    --local)      LOCAL=1; shift ;;
    --image-tag)  IMAGE_TAG="$2"; shift 2 ;;
    --cpus)       CPUS="$2"; shift 2 ;;
    --project-id)     SSET_PROJECT_ID="$2"; shift 2 ;;
    --environment-id) SSET_ENVIRONMENT_ID="$2"; shift 2 ;;
    --cpd-url)    API_URL="$2"; shift 2 ;;
    --username)   API_USER="$2"; shift 2 ;;
    --api-key)    API_KEY="$2"; shift 2 ;;
    --cluster-url)    CLUSTER_URL="$2"; shift 2 ;;
    --cluster-apikey) CLUSTER_APIKEY="$2"; shift 2 ;;
    -*) echo "[WARN] unknown argument: $1" >&2; shift ;;
    *)  ENV_NAME="$1"; shift ;;
  esac
done

if [[ -z "${ENV_NAME}" ]]; then
  echo "Usage: $(basename $0) <environment_name> [--project <name|id>] [--provider docker|podman] [--local]" >&2
  exit 1
fi

# Fall back to the default CPD URL / credentials when none were passed in.
API_URL="${API_URL:-${CPD_URL:-}}"
if [[ -z "${API_URL}" ]]; then
  echo "[ERROR] No CPD URL. Pass --cpd-url, or set CPD_URL in configs/cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi

API_USER="${API_USER:-${CPD_USERNAME:-}}"
API_KEY="${API_KEY:-${CPD_APIKEY:-}}"
if [[ -z "${API_USER}" || -z "${API_KEY}" ]]; then
  echo "[ERROR] No credentials. Pass --username and --api-key, or set CPD_USERNAME / CPD_APIKEY" >&2
  echo "        in configs/cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi

CPD_BASE="${API_URL%/}"

# --- Authenticate against CPD ---
echo "[INFO] Authenticating to ${CPD_BASE} as ${API_USER}..."
TOKEN="$(curl -sk -X POST "${CPD_BASE}/icp4d-api/v1/authorize" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${API_USER}\",\"api_key\":\"${API_KEY}\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))')"
if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] Failed to get a bearer token from ${CPD_BASE}/icp4d-api/v1/authorize." >&2
  exit 1
fi

api_get() { curl -sk -H "Authorization: Bearer ${TOKEN}" -H 'Accept: application/json' "${CPD_BASE}$1"; }

# --- Resolve the environment (project id, environment id, engine config) ---
ENV_JSON="{}"
if [[ -n "${SSET_PROJECT_ID:-}" && -n "${SSET_ENVIRONMENT_ID:-}" ]]; then
  echo "[INFO] Using SSET_PROJECT_ID / SSET_ENVIRONMENT_ID from the environment."
  ENV_JSON="$(api_get "/sset/engine_manager/v1/streamsets_environments/${SSET_ENVIRONMENT_ID}?project_id=${SSET_PROJECT_ID}" || echo '{}')"
else
  echo "[INFO] Looking up StreamSets environment '${ENV_NAME}'..."
  PROJECTS="$(api_get "/v2/projects?limit=100" | python3 -c '
import sys, json
flt = sys.argv[1]
for r in json.load(sys.stdin).get("resources", []):
    guid, name = r["metadata"]["guid"], r["entity"]["name"]
    if not flt or flt in (guid, name):
        print(guid)
' "${PROJECT_FILTER}")"

  for pid in ${(f)PROJECTS}; do
    match="$(api_get "/sset/engine_manager/v1/streamsets_environments?project_id=${pid}" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = data if isinstance(data, list) else next((v for v in data.values() if isinstance(v, list)), [])
for e in items:
    if e.get("name") == sys.argv[1]:
        print(json.dumps(e)); break
' "${ENV_NAME}")"
    if [[ -n "${match}" ]]; then
      SSET_PROJECT_ID="${pid}"
      ENV_JSON="${match}"
      SSET_ENVIRONMENT_ID="$(python3 -c 'import sys,json; e=json.loads(sys.argv[1]); print(e.get("environment_id") or e.get("id") or e.get("metadata",{}).get("asset_id",""))' "${ENV_JSON}")"
      break
    fi
  done

  if [[ -z "${SSET_ENVIRONMENT_ID:-}" ]]; then
    echo "[ERROR] StreamSets environment '${ENV_NAME}' not found${PROJECT_FILTER:+ in project '${PROJECT_FILTER}'}." >&2
    echo "        Set SSET_PROJECT_ID and SSET_ENVIRONMENT_ID manually (Options > Get run command in the UI)." >&2
    exit 1
  fi
fi
echo "[INFO] Project id     : ${SSET_PROJECT_ID}"
echo "[INFO] Environment id : ${SSET_ENVIRONMENT_ID}"

# Pull provider / engine version / cpus out of the environment config, wherever they live.
env_field() {
  python3 -c '
import sys, json
try:
    e = json.loads(sys.argv[1] or "{}")
except Exception:
    e = {}
want = sys.argv[2]
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            kl = k.lower()
            if want == "provider" and ("provider" in kl or "container" in kl) and str(v).lower() in ("docker", "podman"):
                return str(v).lower()
            if want == "version" and kl in ("engine_version", "engine_image_tag", "image_tag") and v:
                return str(v)
            if want == "cpus" and ("cpu" in kl) and isinstance(v, (int, float, str)) and str(v):
                return str(v)
            r = walk(v)
            if r: return r
    elif isinstance(o, list):
        for i in o:
            r = walk(i)
            if r: return r
    return ""
print(walk(e))
' "${ENV_JSON}" "$1"
}

PROVIDER="${PROVIDER:-$(env_field provider)}"
IMAGE_TAG="${IMAGE_TAG:-$(env_field version)}"
IMAGE_TAG="${IMAGE_TAG:-JDK17_7.7.0}"
if [[ -z "${CPUS}" ]]; then
  CPUS="$(env_field cpus)"
  CPUS="${CPUS:-4.0}"
  # With 2 CPUs the engines stop answering the control plane within minutes of
  # flow-editor use; the same image with 4 CPUs (IBM's default) does not. Only an
  # explicit --cpus goes below 4.
  if (( CPUS < 4 )); then
    echo "[WARN] Environment allocates ${CPUS} CPUs per engine; using 4.0 instead (pass --cpus to override)."
    CPUS=4.0
  fi
fi

if [[ -z "${PROVIDER}" ]]; then
  if command -v docker &>/dev/null; then PROVIDER=docker
  elif command -v podman &>/dev/null; then PROVIDER=podman
  else PROVIDER=docker; fi
  echo "[WARN] No container provider in the environment config, defaulting to ${PROVIDER}."
fi
if [[ "${PROVIDER}" != "docker" && "${PROVIDER}" != "podman" ]]; then
  echo "[ERROR] Unsupported provider '${PROVIDER}' (expected docker or podman)." >&2
  exit 1
fi

ENGINE_NAME="sset-engine-$(echo "${ENV_NAME}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//' | cut -c1-40)"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
LIBS_IMAGE="${LIBS_REPO}:${IMAGE_TAG}"

echo "[INFO] Provider       : ${PROVIDER}"
echo "[INFO] Image          : ${IMAGE}"
echo "[INFO] CPUs           : ${CPUS}"

export SSET_API_KEY="${API_KEY}"

# =============================================================================
# Local run with docker / podman
# =============================================================================
if (( LOCAL )); then
  if ! command -v "${PROVIDER}" &>/dev/null; then
    echo "[ERROR] ${PROVIDER} is not installed on this workstation." >&2
    exit 1
  fi
  if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
    echo "${IBM_ENTITLEMENT_KEY}" | ${PROVIDER} login cp.icr.io -u cp --password-stdin >/dev/null
  fi

  # The UI command mounts ~/.docker for registry auth; podman keeps its auth elsewhere.
  mount_args=()
  [[ "${PROVIDER}" == "docker" && -d "${HOME}/.docker" ]] && \
    mount_args=(--mount "type=bind,source=${HOME}/.docker/,target=/home/default/.docker,readonly")

  ${PROVIDER} rm -f "${ENGINE_NAME}" &>/dev/null || true
  CONTAINER_ID="$(${PROVIDER} run \
    "${mount_args[@]}" \
    -d \
    --name "${ENGINE_NAME}" \
    --cpus "${CPUS}" \
    -e SSET_PROJECT_ID="${SSET_PROJECT_ID}" \
    -e SSET_ENVIRONMENT_ID="${SSET_ENVIRONMENT_ID}" \
    -e SSET_BASE_URL="${CPD_BASE}" \
    -e SSET_API_USER="${API_USER}" \
    -e SSET_JUMPSTART_SYNC_REPOSITORY="${LIBS_IMAGE}" \
    -e SSET_API_KEY="${SSET_API_KEY}" \
    "${IMAGE}")"

  echo "[INFO] Engine container started: ${CONTAINER_ID}"
  echo "[INFO] Logs: ${PROVIDER} logs -f ${ENGINE_NAME}"
  exit 0
fi

# =============================================================================
# OpenShift run in the cpd-streamsets-engine namespace
# =============================================================================
# Either cluster flag alone falls back to cpd_vars.sh for the other half.
if [[ -n "${CLUSTER_APIKEY}" ]]; then
  CLUSTER_URL="${CLUSTER_URL:-${OCP_URL:-}}"
  if [[ -z "${CLUSTER_URL}" ]]; then
    echo "[ERROR] No cluster URL. Pass --cluster-url, or set OCP_URL in ./cpd_vars.sh." >&2
    exit 1
  fi
  echo "[INFO] Logging in to ${CLUSTER_URL}..."
  if [[ "${CLUSTER_APIKEY}" == sha256~* ]]; then
    # OpenShift API token (oc whoami -t / "Copy login command" in the console)
    oc login --server="${CLUSTER_URL}" --token="${CLUSTER_APIKEY}"
  else
    # IBM Cloud API key (ROKS clusters log in via IAM as user "apikey")
    oc login --server="${CLUSTER_URL}" --username=apikey --password="${CLUSTER_APIKEY}"
  fi
elif [[ -n "${CLUSTER_URL}" ]]; then
  if [[ -z "${LOGIN_ARGUMENTS:-}" ]]; then
    echo "[ERROR] No cluster credentials. Pass --cluster-apikey, or set LOGIN_ARGUMENTS in ./cpd_vars.sh." >&2
    exit 1
  fi
  echo "[INFO] Logging in to ${CLUSTER_URL}..."
  eval "oc login --server=\"${CLUSTER_URL}\" ${LOGIN_ARGUMENTS}"
else
  if [[ -z "${OC_LOGIN:-}" ]]; then
    echo "[ERROR] OC_LOGIN is not set. Set it in ./cpd_vars.sh, or pass --cluster-url / --cluster-apikey." >&2
    exit 1
  fi
  eval "${OC_LOGIN}"
fi

if oc get namespace "${NAMESPACE}" &>/dev/null; then
  echo "[INFO] Namespace ${NAMESPACE} already exists, reusing it."
else
  echo "[INFO] Creating namespace ${NAMESPACE}..."
  oc create namespace "${NAMESPACE}"
fi

# Copy the cluster's default pull secret (openshift-config/pull-secret) into the
# namespace so the engine pods get the same registry creds as the rest of the cluster.
PULL_SECRETS_YAML=""
if oc get secret pull-secret -n openshift-config &>/dev/null; then
  echo "[INFO] Copying cluster pull secret into ${NAMESPACE}..."
  oc create secret generic pull-secret -n "${NAMESPACE}" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=<(oc get secret pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d) \
    --dry-run=client -o yaml | oc apply -f -
  PULL_SECRETS_YAML+=$'\n        - name: pull-secret'
else
  echo "[WARN] openshift-config/pull-secret not found (or no access), skipping copy."
fi

# Dedicated cp.icr.io secret from the entitlement key, if one is set.
if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
  oc create secret docker-registry ibm-entitlement-key -n "${NAMESPACE}" \
    --docker-server=cp.icr.io --docker-username=cp --docker-password="${IBM_ENTITLEMENT_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
  PULL_SECRETS_YAML+=$'\n        - name: ibm-entitlement-key'
fi

if [[ -z "${PULL_SECRETS_YAML}" ]]; then
  echo "[ERROR] No pull secret available for cp.icr.io (no cluster pull-secret, no IBM_ENTITLEMENT_KEY)." >&2
  exit 1
fi

# The engine also pulls stage libraries from cp.icr.io itself at startup, using
# /home/default/.docker/config.json (the UI command mounts ~/.docker there).
# Mount a pull secret at that path: the entitlement key if set, else the cluster one.
if [[ "${PULL_SECRETS_YAML}" == *ibm-entitlement-key* ]]; then
  DOCKER_CONFIG_SECRET="ibm-entitlement-key"
else
  DOCKER_CONFIG_SECRET="pull-secret"
fi

oc create secret generic "${ENGINE_NAME}-apikey" -n "${NAMESPACE}" \
  --from-literal=SSET_API_KEY="${SSET_API_KEY}" \
  --dry-run=client -o yaml | oc apply -f -

# Jumpstart only looks for the stage libraries as OCI referrers of the engine
# image, which cp.icr.io does not serve (404), so it silently installs nothing
# and the engine starts with just basic/dataformats/dev (CONTAINER_0901 on any
# other stage). The libraries ship as a plain image (${LIBS_IMAGE}) laid out as
# streamsets-datacollector-<ver>/streamsets-libs/<lib>, so mount it as an image
# volume and symlink every library into the engine's streamsets-libs dir; jumpstart
# then sees them as already installed.
SDC_HOME="/opt/streamsets-datacollector-${IMAGE_TAG##*_}"

# Engines can stop answering the control plane while staying "online": after a
# few flow-editor requests are tunnelled to an engine at once, every sync-up to
# the engine gateway times out (logged every 15s with a consecutive-error count)
# and only a restart recovers it. The liveness probe restarts the container once
# that has gone on for 12 errors (~3 min), or once the engine passes 2500
# threads: every tunnelled request also leaks an HttpClient with its own thread
# pool, and around 3500 threads the 1 GB heap is full. /data (holds sdc.id) and /logs are
# emptyDirs, so the engine comes back under the same engine ID and keeps its log
# from before the restart.
SYNCUP_PROBE='t=$(sed -n "s/^Threads:[[:space:]]*//p" /proc/1/status)
if [ "${t:-0}" -gt 2500 ]; then echo "engine has $t threads (leaked HTTP clients)"; exit 1; fi
l=$(grep "Error sending sync-up request (consecutive errors:" /logs/sdc.log 2>/dev/null | tail -n 1)
[ -n "$l" ] || exit 0
n=$(echo "$l" | sed -E "s/.*consecutive errors: ([0-9]+).*/\1/")
age=$(( $(date +%s) - $(date -d "$(echo "$l" | cut -c1-19)" +%s) ))
if [ "$age" -le 60 ] && [ "$n" -ge 12 ]; then echo "gateway sync-up failing: $n consecutive errors"; exit 1; fi'
# Indented to sit inside the YAML block scalar below.
NL=$'\n'
SYNCUP_PROBE_YAML="${SYNCUP_PROBE//${NL}/${NL}                  }"

# Keep a replica count that was scaled up after the first run.
REPLICAS="$(oc get deployment "${ENGINE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
REPLICAS="${REPLICAS:-1}"

oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${ENGINE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${ENGINE_NAME}
    streamsets/environment-id: "${SSET_ENVIRONMENT_ID}"
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${ENGINE_NAME}
  template:
    metadata:
      labels:
        app: ${ENGINE_NAME}
    spec:
      imagePullSecrets:${PULL_SECRETS_YAML}
      volumes:
        - name: docker-config
          secret:
            secretName: ${DOCKER_CONFIG_SECRET}
            items:
              - key: .dockerconfigjson
                path: config.json
        - name: stagelibs-image
          image:
            reference: ${LIBS_IMAGE}
            pullPolicy: IfNotPresent
        - name: stage-libs
          emptyDir: {}
        - name: sdc-data
          emptyDir: {}
        - name: sdc-logs
          emptyDir: {}
      initContainers:
        # Seed streamsets-libs with the image's built-in libs, then link in the rest.
        - name: link-stage-libs
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - |
              set -e
              cp -R ${SDC_HOME}/streamsets-libs/* /target/
              for lib in /stagelibs/streamsets-datacollector-*/streamsets-libs/*; do
                [ -e "/target/\$(basename "\$lib")" ] || ln -s "\$lib" /target/
              done
              echo "streamsets-libs now has \$(ls /target | wc -l) stage libraries"
              cp -R /data/. /seed-data/
              cp -R /logs/. /seed-logs/
          volumeMounts:
            - name: stagelibs-image
              mountPath: /stagelibs
              readOnly: true
            - name: stage-libs
              mountPath: /target
            - name: sdc-data
              mountPath: /seed-data
            - name: sdc-logs
              mountPath: /seed-logs
      containers:
        - name: datacollector
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: SSET_PROJECT_ID
              value: "${SSET_PROJECT_ID}"
            - name: SSET_ENVIRONMENT_ID
              value: "${SSET_ENVIRONMENT_ID}"
            - name: SSET_BASE_URL
              value: "${CPD_BASE}"
            - name: SSET_API_USER
              value: "${API_USER}"
            - name: SSET_JUMPSTART_SYNC_REPOSITORY
              value: "${LIBS_IMAGE}"
            # OpenShift runs the pod as a random UID, so point at the mounted creds explicitly.
            - name: DOCKER_CONFIG
              value: /home/default/.docker
            - name: SSET_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ${ENGINE_NAME}-apikey
                  key: SSET_API_KEY
          volumeMounts:
            - name: docker-config
              mountPath: /home/default/.docker
              readOnly: true
            - name: stagelibs-image
              mountPath: /stagelibs
              readOnly: true
            - name: stage-libs
              mountPath: ${SDC_HOME}/streamsets-libs
            - name: sdc-data
              mountPath: /data
            - name: sdc-logs
              mountPath: /logs
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - |
                  ${SYNCUP_PROBE_YAML}
            initialDelaySeconds: 120
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 2
          resources:
            limits:
              cpu: "${CPUS}"
EOF

echo "[INFO] Waiting for ${ENGINE_NAME} to become ready..."
oc rollout status deployment/"${ENGINE_NAME}" -n "${NAMESPACE}" --timeout=10m
echo "[INFO] Engine running. Logs: oc logs -f deployment/${ENGINE_NAME} -n ${NAMESPACE}"
