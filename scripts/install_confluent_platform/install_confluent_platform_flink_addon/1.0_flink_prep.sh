#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: source confluent_vars.sh LAST so its cluster/storage values
# win over the CP4D ones defined in cpd_vars.sh. Override to point these
# scripts at a different config:  ENV_TARGET=<name|path> ./<script>.sh
: "${ENV_TARGET:=confluent}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform for Apache Flink - preparation
# ------------------------------------------------------------------------------
# Prepares the cluster for the CMF + Flink operator stack installed by
# 1.1_flink_install.sh:
#   - logs in to OpenShift
#   - validates the configuration and the local tooling (helm, confluent CLI)
#   - installs cert-manager if it is absent (the operator's webhook needs it)
#   - creates the target project
#   - grants the SCCs the Flink pods need
#   - adds the Confluent Helm repository
#   - provisions the checkpoint/savepoint storage
#   - stores the licence key, when one is configured
#
# Safe to re-run: everything is created only when missing.
#
# Options:
#   --skip-cert-manager   do not touch cert-manager (it is already managed)
#   --dry-run             report what would change, change nothing
# ==============================================================================

SKIP_CERT_MANAGER=false
DRY_RUN=false

while (( $# > 0 )); do
    case "$1" in
        --skip-cert-manager) SKIP_CERT_MANAGER=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '19,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

# ------------------------------------------------------------------------------
# run <cmd...> - executes, or just prints under --dry-run.
# ------------------------------------------------------------------------------
run() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY-RUN] $*"
    else
        "$@"
    fi
}

# ------------------------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------------------------
_missing=()
for _var in PROJECT_CONFLUENT_FLINK FLINK_HELM_REPO_NAME FLINK_HELM_REPO_URL \
            FLINK_CMF_CHART_VERSION FLINK_OPERATOR_CHART_VERSION \
            FLINK_CMF_STORAGE_CLASS FLINK_CMF_STORAGE_SIZE \
            FLINK_STATE_BACKEND FLINK_ENVIRONMENT FLINK_COMPUTE_POOL; do
    [[ -z "${(P)_var:-}" ]] && _missing+=("${_var}")
done
if (( ${#_missing[@]} > 0 )); then
    echo "[ERROR] Missing required variables in cp4d_config/confluent_vars.sh: ${_missing[*]}" >&2
    echo "[ERROR] Run flink_install/0_flink_prepare_template_config.sh first." >&2
    exit 1
fi

case "${FLINK_STATE_BACKEND}" in
    pvc|s3|none) ;;
    *)
        echo "[ERROR] FLINK_STATE_BACKEND must be one of: pvc, s3, none (got '${FLINK_STATE_BACKEND}')." >&2
        exit 1 ;;
esac

if [[ "${FLINK_STATE_BACKEND}" == "s3" ]]; then
    for _var in FLINK_S3_BUCKET FLINK_S3_ENDPOINT FLINK_S3_ACCESS_KEY FLINK_S3_SECRET_KEY; do
        [[ -z "${(P)_var:-}" ]] && {
            echo "[ERROR] FLINK_STATE_BACKEND=s3 requires ${_var} to be set." >&2
            exit 1
        }
    done
fi

# ------------------------------------------------------------------------------
# Local tooling. Both are hard requirements: the charts are installed with helm
# and every later script drives CMF through the confluent CLI.
# ------------------------------------------------------------------------------
if ! command -v helm &>/dev/null; then
    echo "[ERROR] helm is not on PATH. Install Helm 3 or newer:" >&2
    echo "[ERROR]   brew install helm     (macOS)" >&2
    echo "[ERROR]   https://helm.sh/docs/intro/install/" >&2
    exit 1
fi

_helm_major="$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')"
if [[ -n "${_helm_major}" ]] && (( _helm_major < 3 )); then
    echo "[ERROR] Helm 3 or newer is required (found v${_helm_major})." >&2
    exit 1
fi

if ! command -v confluent &>/dev/null; then
    echo "[WARN] The confluent CLI is not on PATH. The install itself will work," >&2
    echo "[WARN] but 1.1_flink_install.sh cannot create the environment and compute" >&2
    echo "[WARN] pool, and none of the x.* scripts will run. Install it with:" >&2
    echo "[WARN]   brew install confluentinc/tap/cli     (macOS)" >&2
    echo "[WARN]   curl -sL --http1.1 https://cnfl.io/cli | sh -s -- latest" >&2
else
    # v4 is where "confluent flink catalog/compute-pool/statement" appeared for
    # Confluent Platform. Older builds only speak to Confluent Cloud.
    _cli_ver="$(confluent version 2>/dev/null | sed -n 's/^Version:[[:space:]]*v\([0-9]*\).*/\1/p' | head -1)"
    if [[ -n "${_cli_ver}" ]] && (( _cli_ver < 4 )); then
        echo "[WARN] confluent CLI v${_cli_ver} found; v4 or newer is needed for the" >&2
        echo "[WARN] Confluent Platform flink subcommands (catalog, compute-pool, statement)." >&2
    fi
fi

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_FLINK}"
SA="flink"

echo "[INFO] Preparing project '${NS}' for Confluent Platform for Apache Flink."

# ------------------------------------------------------------------------------
# Cluster-scoped permissions
# ------------------------------------------------------------------------------
# This install is not confined to one namespace: the operator chart installs
# CRDs, cert-manager installs its own ClusterRoles, and the SCC binding is a
# cluster-level grant. A namespace admin has none of those rights, and finding
# out halfway through leaves a partial install to unpick - so check up front.
_denied=()
oc auth can-i create customresourcedefinitions &>/dev/null || _denied+=("customresourcedefinitions (the Flink operator installs CRDs)")
oc auth can-i create clusterroles &>/dev/null || _denied+=("clusterroles (cert-manager and the SCC binding)")
if (( ${#_denied[@]} > 0 )); then
    echo "[ERROR] This account lacks the cluster-scoped permissions this install needs:" >&2
    for _d in "${_denied[@]}"; do echo "[ERROR]   - ${_d}" >&2; done
    echo "[ERROR] Log in as a cluster administrator, or have one install the Flink" >&2
    echo "[ERROR] operator and cert-manager once - after that, --skip-cert-manager" >&2
    echo "[ERROR] and 1.1's --skip-operator let a namespace admin do the rest." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Storage classes
# ------------------------------------------------------------------------------
if ! oc get storageclass "${FLINK_CMF_STORAGE_CLASS}" &>/dev/null; then
    echo "[ERROR] StorageClass '${FLINK_CMF_STORAGE_CLASS}' not found on the cluster." >&2
    oc get storageclass -o name >&2
    exit 1
fi

if [[ "${FLINK_STATE_BACKEND}" == "pvc" ]]; then
    if ! oc get storageclass "${FLINK_STATE_STORAGE_CLASS}" &>/dev/null; then
        echo "[ERROR] StorageClass '${FLINK_STATE_STORAGE_CLASS}' not found (FLINK_STATE_STORAGE_CLASS)." >&2
        oc get storageclass -o name >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# cert-manager
# ------------------------------------------------------------------------------
# The Flink operator ships a validating webhook whose certificate cert-manager
# issues. Without it the operator pod starts but every FlinkDeployment is
# rejected, which surfaces much later as an unexplained "no endpoints available
# for service flink-operator-webhook-service".
if [[ "${SKIP_CERT_MANAGER}" == "true" ]]; then
    echo "[INFO] --skip-cert-manager: not checking cert-manager."
elif oc get crd certificates.cert-manager.io &>/dev/null; then
    echo "[INFO] cert-manager is already installed - leaving it alone."
else
    echo "[INFO] cert-manager not found. Installing ${FLINK_CERT_MANAGER_VERSION}..."
    # Applied from the upstream release manifest, which is what Confluent's own
    # OpenShift instructions do. It creates its own namespace.
    run oc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${FLINK_CERT_MANAGER_VERSION}/cert-manager.yaml"

    if [[ "${DRY_RUN}" != "true" ]]; then
        echo "[INFO] Waiting for cert-manager to become available..."
        for _d in cert-manager cert-manager-webhook cert-manager-cainjector; do
            oc rollout status "deployment/${_d}" -n "${FLINK_CERT_MANAGER_NAMESPACE}" \
                --timeout="${FLINK_ROLLOUT_TIMEOUT}"
        done
        # The webhook's own serving certificate is issued asynchronously after
        # the deployment reports ready. Creating the operator's Issuer before
        # that lands fails with a connection refused, so wait for the API to
        # actually answer rather than trusting the rollout status alone.
        echo "[INFO] Waiting for the cert-manager webhook to answer..."
        _waited=0
        until oc get --raw '/apis/cert-manager.io/v1' &>/dev/null; do
            sleep 5; _waited=$(( _waited + 5 ))
            if (( _waited >= 180 )); then
                echo "[ERROR] cert-manager API not responding after ${_waited}s." >&2
                exit 1
            fi
        done
        echo "[INFO] cert-manager ready."
    fi
fi

# ------------------------------------------------------------------------------
# Project
# ------------------------------------------------------------------------------
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY-RUN] oc create namespace ${NS}"
else
    oc create namespace "${NS}" --dry-run=client -o yaml | oc apply -f -
    oc project "${NS}" >/dev/null
fi

# ------------------------------------------------------------------------------
# Service accounts + SCC
# ------------------------------------------------------------------------------
# Three identities are involved and they are easy to confuse:
#   flink-operator  the operator pod itself (created by its chart)
#   flink           the JobManager/TaskManager pods (created by its chart, and
#                   named in every FlinkDeployment's spec.serviceAccount)
#   confluent-manager-for-apache-flink  the CMF pod (created by its chart)
#
# The charts create all three, but the charts run AFTER this script, so the
# SCC binding has to be made against the names rather than the objects. An SCC
# binding to a service account that does not exist yet is valid and takes
# effect as soon as it does.
#
# Why anyuid: the upstream images pin numeric uids (9999 for the operator, 1001
# for CMF, 9999 for the Flink runtime) and OpenShift's restricted-v2 SCC
# rejects a pod that asks for a specific uid. Confluent's OpenShift page
# suggests nulling the securityContext instead so the pods take the
# namespace's assigned range - but the cp-flink image's /opt/flink directories
# are owned by 9999, so an arbitrary uid cannot write its own logs or unpack a
# jar. anyuid is the option that works with the images as published, and it is
# what the sibling Confluent scripts already grant.
for _sa in "${SA}" flink-operator confluent-manager-for-apache-flink; do
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY-RUN] oc create serviceaccount ${_sa} -n ${NS}"
        echo "  [DRY-RUN] oc adm policy add-scc-to-user anyuid -z ${_sa} -n ${NS}"
        continue
    fi
    oc create serviceaccount "${_sa}" -n "${NS}" --dry-run=client -o yaml | oc apply -f -
    oc adm policy add-scc-to-user anyuid -z "${_sa}" -n "${NS}"
done

# ------------------------------------------------------------------------------
# Registry pull secret - reuses the Confluent one when it is configured, so a
# mirrored registry only has to be described once.
# ------------------------------------------------------------------------------
if [[ -n "${CONFLUENT_REGISTRY_USER:-}" ]]; then
    _registry_host="${FLINK_IMAGE_REGISTRY:-${CONFLUENT_REGISTRY}}"
    _registry_host="${_registry_host%%/*}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY-RUN] oc create secret docker-registry ${CONFLUENT_PULL_SECRET} -n ${NS}"
    else
        oc create secret docker-registry "${CONFLUENT_PULL_SECRET}" \
            --docker-server="${_registry_host}" \
            --docker-username="${CONFLUENT_REGISTRY_USER}" \
            --docker-password="${CONFLUENT_REGISTRY_PASSWORD}" \
            -n "${NS}" --dry-run=client -o yaml | oc apply -f -
        for _sa in "${SA}" flink-operator confluent-manager-for-apache-flink; do
            oc secrets link "${_sa}" "${CONFLUENT_PULL_SECRET}" --for=pull -n "${NS}"
        done
        echo "[INFO] Pull secret '${CONFLUENT_PULL_SECRET}' created for ${_registry_host}."
    fi
else
    echo "[INFO] CONFLUENT_REGISTRY_USER is empty - pulling anonymously."
fi

# ------------------------------------------------------------------------------
# Licence
# ------------------------------------------------------------------------------
# CMF is a commercial component. With no key it runs a 30-day trial and then
# refuses to start new jobs, so the absence of a key is worth saying out loud.
if [[ -n "${FLINK_LICENSE_KEY:-}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY-RUN] oc create secret generic ${FLINK_LICENSE_SECRET} -n ${NS}"
    else
        oc create secret generic "${FLINK_LICENSE_SECRET}" \
            --from-literal=license.txt="${FLINK_LICENSE_KEY}" \
            -n "${NS}" --dry-run=client -o yaml | oc apply -f -
        echo "[INFO] Licence stored in secret '${FLINK_LICENSE_SECRET}'."
    fi
else
    echo "[WARN] FLINK_LICENSE_KEY is empty - CMF runs on the built-in 30-day trial."
    echo "[WARN] Set FLINK_LICENSE_KEY (or CONFLUENT_LICENSE_KEY) before relying on"
    echo "[WARN] this beyond evaluation."
fi

# ------------------------------------------------------------------------------
# Checkpoint / savepoint storage
# ------------------------------------------------------------------------------
case "${FLINK_STATE_BACKEND}" in
    pvc)
        # ReadWriteMany, not ReadWriteOnce: the JobManager and every TaskManager
        # mount the same volume, and they are not co-scheduled. An RWO claim
        # binds to one node and the rest of the pods stay Pending.
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "  [DRY-RUN] oc apply pvc/${FLINK_STATE_PVC_NAME} (${FLINK_STATE_STORAGE_SIZE}, RWX)"
        else
            oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${FLINK_STATE_PVC_NAME}
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: confluent-flink
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ${FLINK_STATE_STORAGE_CLASS}
  resources:
    requests:
      storage: ${FLINK_STATE_STORAGE_SIZE}
EOF
            echo "[INFO] Checkpoint PVC '${FLINK_STATE_PVC_NAME}' (${FLINK_STATE_STORAGE_SIZE}, RWX on ${FLINK_STATE_STORAGE_CLASS})."
        fi
        ;;
    s3)
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "  [DRY-RUN] oc create secret generic ${FLINK_S3_SECRET} -n ${NS}"
        else
            oc create secret generic "${FLINK_S3_SECRET}" \
                --from-literal=accesskey="${FLINK_S3_ACCESS_KEY}" \
                --from-literal=secretkey="${FLINK_S3_SECRET_KEY}" \
                -n "${NS}" --dry-run=client -o yaml | oc apply -f -
            echo "[INFO] S3 credentials stored in secret '${FLINK_S3_SECRET}' (bucket ${FLINK_S3_BUCKET})."
        fi
        ;;
    none)
        echo "[WARN] FLINK_STATE_BACKEND=none - no checkpoint storage."
        echo "[WARN] Jobs will run but cannot recover from failure, and stopping one"
        echo "[WARN] with a savepoint will not work."
        ;;
esac

# ------------------------------------------------------------------------------
# Helm repository
# ------------------------------------------------------------------------------
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY-RUN] helm repo add ${FLINK_HELM_REPO_NAME} ${FLINK_HELM_REPO_URL}"
else
    # --force-update makes this idempotent when the repo is already present
    # under the same name pointing somewhere else.
    helm repo add "${FLINK_HELM_REPO_NAME}" "${FLINK_HELM_REPO_URL}" --force-update >/dev/null
    helm repo update "${FLINK_HELM_REPO_NAME}" >/dev/null
    echo "[INFO] Helm repo '${FLINK_HELM_REPO_NAME}' -> ${FLINK_HELM_REPO_URL}"

    # Fail here rather than midway through the install if a pinned version was
    # withdrawn from the repository.
    for _c in "confluent-manager-for-apache-flink:${FLINK_CMF_CHART_VERSION}" \
              "flink-kubernetes-operator:${FLINK_OPERATOR_CHART_VERSION}"; do
        _chart="${_c%%:*}"; _ver="${_c##*:}"
        if ! helm show chart "${FLINK_HELM_REPO_NAME}/${_chart}" --version "${_ver}" &>/dev/null; then
            echo "[ERROR] Chart ${_chart} version ${_ver} is not available in the repository." >&2
            echo "[ERROR] Available versions:" >&2
            helm search repo "${FLINK_HELM_REPO_NAME}/${_chart}" --versions 2>/dev/null | head -6 >&2
            exit 1
        fi
    done
    echo "[INFO] Charts verified: CMF ${FLINK_CMF_CHART_VERSION}, operator ${FLINK_OPERATOR_CHART_VERSION}."
fi

# ------------------------------------------------------------------------------
# Report whether there is a Confluent cluster to attach to. Not an error: Flink
# is installable on its own and attached later with x.4_flink_connect_kafka.sh.
# ------------------------------------------------------------------------------
echo ""
if oc get statefulset broker -n "${PROJECT_CONFLUENT_SERVER}" &>/dev/null; then
    echo "[INFO] Confluent cluster found in '${PROJECT_CONFLUENT_SERVER}'."
    echo "[INFO] After the install, attach it with:  ./x.4_flink_connect_kafka.sh"
else
    echo "[INFO] No Confluent cluster found in '${PROJECT_CONFLUENT_SERVER}'."
    echo "[INFO] Flink will install standalone. Attach a Kafka cluster later with"
    echo "[INFO] ./x.4_flink_connect_kafka.sh, which also accepts an external one"
    echo "[INFO] via --bootstrap."
fi

echo ""
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[INFO] --dry-run complete. Nothing was changed."
else
    echo "[INFO] Preparation complete."
    echo "[INFO] Next: flink_install/1.1_flink_install.sh"
fi
