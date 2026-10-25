#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"


export INSTALL_MODE=agentic
export INTERNAL_IFM=false

eval "${OC_LOGIN}"

# Reports problems but does not stop the install.
if ! sh "${_CP4D_REPO_ROOT}/src/utilities/softwarehub_utils/wxo-prereq-check.sh" \
    --version ${VERSION}\
    --installation-type $INSTALL_MODE \
    --internal-ifm $INTERNAL_IFM \
    --operator-ns ${PROJECT_CPD_INST_OPERATORS} \
    --operand-ns ${PROJECT_CPD_INST_OPERANDS}; then
    echo "[WARN] watsonx Orchestrate prerequisite check reported errors - review them above. Continuing."
fi

# --- Temporary docproc watcher -------------------------------------------------
# The docproc cache-init job (wo_doc_processing_cache_rds_init) runs Flyway on an IBM Semeru JVM
# whose FIPS profile RestrictedSecurity.NSS.140-2 expired on 2026-09-21. Java refuses to start,
# the docproc tables are never created, and the WatsonxOrchestrate CR stalls on
# "unverified components: docprocV3" until install-components times out.
#
# The watcher pod execs into each cache-init pod that hits the expiry and prepends
# -Dsemeru.restrictedsecurity.ignoresunsetexpiration=true to JAVA_ARGS in its Flyway launcher,
# so the job's own next retry succeeds. Once the CR is Completed (or after the timeout) the pod
# deletes itself; its ServiceAccount, Role, RoleBinding and ConfigMap are owned by the pod and
# are garbage-collected with it.
#
# Deployed when WXO_DOCPROC_WATCHER=true (set in 4.0_full_step_4_installprocess-cpd.sh),
# PREP_WXO=true and watsonx_orchestrate is in CPD_COMPONENTS.
WXO_DOCPROC_WATCHER="${WXO_DOCPROC_WATCHER:-true}"
WATCHER_NAME="wxo-docproc-watcher"
WATCHER_NS="${PROJECT_CPD_INST_OPERANDS}"
WATCHER_TIMEOUT_SECONDS="${WXO_DOCPROC_WATCHER_TIMEOUT_SECONDS:-43200}"
WO_CR_NAME="wo"

deploy_docproc_watcher() {
    # The cluster's own oc image from the release payload: pullable with the global pull
    # secret and covered by the release mirror on disconnected clusters.
    local image="${WXO_DOCPROC_WATCHER_IMAGE:-}"
    if [[ -z "${image}" ]]; then
        image="$(oc get istag cli:latest -n openshift -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)"
    fi
    if [[ -z "${image}" ]]; then
        echo "[ERROR] Could not resolve the cluster's cli image (istag openshift/cli:latest). Set WXO_DOCPROC_WATCHER_IMAGE."
        return 1
    fi

    echo "[INFO] Removing any previous ${WATCHER_NAME} from ${WATCHER_NS}."
    oc delete pod,configmap,rolebinding,role,serviceaccount "${WATCHER_NAME}" -n "${WATCHER_NS}" \
        --ignore-not-found --wait=true >/dev/null || return 1

    local watch_script
    watch_script="$(mktemp)"
    cat > "${watch_script}" <<'EOF'
#!/bin/bash
# Runs inside the wxo-docproc-watcher pod - deployed by 4.0_wxo_install_preverification.sh.
set -u
export HOME=/tmp

FLAG="-Dsemeru.restrictedsecurity.ignoresunsetexpiration=true"
MARKER="wxo-docproc-watcher"
declare -A patched=()

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

# Rewrites the launcher in place (cat >) rather than with sed -i so its owner and mode stay as-is.
patch_pod() {
    oc exec -n "${NAMESPACE}" "$1" -c cache-init -- env FLAG="${FLAG}" MARKER="${MARKER}" bash -c '
        f="$(readlink -f "$(command -v flyway)")" || exit 1
        grep -q "${MARKER}" "${f}" && exit 0
        { head -n 1 "${f}"
          printf "JAVA_ARGS=\"%s \${JAVA_ARGS:-}\" # %s\n" "${FLAG}" "${MARKER}"
          tail -n +2 "${f}"; } > /tmp/flyway.patched && cat /tmp/flyway.patched > "${f}"'
}

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
last_status=""
log "Watching WatsonxOrchestrate/${WO_CR_NAME} and job ${DOCPROC_JOB} in ${NAMESPACE} (timeout ${TIMEOUT_SECONDS}s)"

while (( $(date +%s) < deadline )); do
    status="$(oc get watsonxorchestrates.wo.watsonx.ibm.com "${WO_CR_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.watsonxOrchestrateStatus}' 2>/dev/null || true)"
    if [[ "${status}" != "${last_status}" ]]; then
        log "WatsonxOrchestrate/${WO_CR_NAME} status: ${status:-<not found yet>}"
        last_status="${status}"
    fi
    [[ "${status}" == "Completed" ]] && break

    for pod in $(oc get pods -n "${NAMESPACE}" -l "job-name=${DOCPROC_JOB}" \
        --field-selector=status.phase=Running -o name 2>/dev/null); do
        pod="${pod#pod/}"
        [[ -n "${patched[${pod}]:-}" ]] && continue
        logs="$(oc logs -n "${NAMESPACE}" "${pod}" -c cache-init --tail=200 2>/dev/null || true)"
        [[ "${logs}" == *"restricted security profile"*"expired on"* ]] || continue
        log "${pod}: Semeru FIPS profile expiry detected - patching the Flyway launcher"
        if patch_pod "${pod}"; then
            patched[${pod}]=1
            log "${pod}: patched - the job's next migration attempt should succeed"
        else
            log "${pod}: patch failed - retrying next poll"
        fi
    done
    sleep "${POLL_SECONDS}"
done

(( $(date +%s) >= deadline )) && log "Timed out before WatsonxOrchestrate/${WO_CR_NAME} reached Completed"
log "Deleting ${POD_NAME} (its ServiceAccount, Role, RoleBinding and ConfigMap are garbage-collected with it)"
oc delete pod "${POD_NAME}" -n "${NAMESPACE}" --wait=false
EOF

    oc create configmap "${WATCHER_NAME}" -n "${WATCHER_NS}" --from-file=watch.sh="${watch_script}" >/dev/null
    local rc=$?
    rm -f "${watch_script}"
    (( rc == 0 )) || return 1

    oc apply -f - <<EOF || return 1
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${WATCHER_NAME}
  namespace: ${WATCHER_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${WATCHER_NAME}
  namespace: ${WATCHER_NS}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods"]
    resourceNames: ["${WATCHER_NAME}"]
    verbs: ["delete"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create", "get"]
  - apiGroups: ["wo.watsonx.ibm.com"]
    resources: ["watsonxorchestrates"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${WATCHER_NAME}
  namespace: ${WATCHER_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${WATCHER_NAME}
subjects:
  - kind: ServiceAccount
    name: ${WATCHER_NAME}
    namespace: ${WATCHER_NS}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${WATCHER_NAME}
  namespace: ${WATCHER_NS}
  labels:
    app.kubernetes.io/name: ${WATCHER_NAME}
spec:
  serviceAccountName: ${WATCHER_NAME}
  restartPolicy: OnFailure
  containers:
    - name: watcher
      image: ${image}
      command: ["/bin/bash", "/scripts/watch.sh"]
      env:
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: WO_CR_NAME
          value: "${WO_CR_NAME}"
        - name: DOCPROC_JOB
          value: "${WO_CR_NAME}-docproc-cache-init"
        - name: TIMEOUT_SECONDS
          value: "${WATCHER_TIMEOUT_SECONDS}"
        - name: POLL_SECONDS
          value: "30"
      resources:
        requests:
          cpu: 10m
          memory: 64Mi
        limits:
          memory: 256Mi
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      volumeMounts:
        - name: scripts
          mountPath: /scripts
  volumes:
    - name: scripts
      configMap:
        name: ${WATCHER_NAME}
        defaultMode: 0555
EOF

    # Owned by the pod, so they go away when the watcher deletes itself.
    local uid
    uid="$(oc get pod "${WATCHER_NAME}" -n "${WATCHER_NS}" -o jsonpath='{.metadata.uid}')" || return 1
    local owner="{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"name\":\"${WATCHER_NAME}\",\"uid\":\"${uid}\"}]}}"
    for kind in serviceaccount role rolebinding configmap; do
        oc patch "${kind}" "${WATCHER_NAME}" -n "${WATCHER_NS}" --type=merge -p "${owner}" >/dev/null || return 1
    done

    echo "[OK] ${WATCHER_NAME} deployed in ${WATCHER_NS}. Follow it with: oc logs -f ${WATCHER_NAME} -n ${WATCHER_NS}"
}

if [[ "${WXO_DOCPROC_WATCHER}" == "true" && "${PREP_WXO:-}" == "true" ]] \
    && (( ${${(s:,:)CPD_COMPONENTS}[(Ie)watsonx_orchestrate]} )); then
    if ! deploy_docproc_watcher; then
        echo "[WARN] ${WATCHER_NAME} could not be deployed - the install continues without it."
        echo "[WARN] If docprocV3 stalls on the Semeru FIPS profile expiry, patch the cache-init pods by hand."
    fi
else
    echo "[SKIP] ${WATCHER_NAME} (needs WXO_DOCPROC_WATCHER=true, PREP_WXO=true and watsonx_orchestrate in CPD_COMPONENTS)."
fi
