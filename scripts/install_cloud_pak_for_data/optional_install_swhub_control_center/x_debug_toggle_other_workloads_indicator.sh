#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_api_helpers.sh"

usage() {
    cat <<'USAGE'
Debug: turn the other workloads indicator on or off.

Control Center only measures Software Hub instances, so the other workloads account
shows its allocation but no requests or usage. The indicator is a small stand-in
instance that reports what everything outside the instances reserves: storage,
monitoring, third-party agents and Control Center itself, on the workers. It limits
nothing. Unsupported by IBM.

  x_debug_toggle_other_workloads_indicator.sh [on|off|status] [--yes]

With no argument it follows CONTROL_OTHER_WORKLOADS_INDICATOR, as the full install
does: on when true (the default), off when false.

  on      Deploy it in CONTROL_OTHER_WORKLOADS_INDICATOR_PROJECT, register it in the
          other workloads account, set its quota to that account's allocation, and save
          CONTROL_OTHER_WORKLOADS_INDICATOR="true". Needs autodetect_instances.sh first.
  off     Remove it from Control Center, delete its project and cluster role, and save
          "false".
  status  Show what is deployed and registered, and its recent requests.

Its route is usually private inside the cluster, so registering it briefly maps the
route on zen-core-api, restarting Control Center's API twice.
USAGE
}

ACTION=""; YES=false
while (( $# )); do
    case "$1" in
        on|off|status) ACTION="$1"; shift ;;
        --yes)         YES=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) usage >&2; h_die "Unknown option: $1" ;;
    esac
done
SAVE=true
if [[ -z "${ACTION}" ]]; then
    h_is_true "${CONTROL_OTHER_WORKLOADS_INDICATOR:-true}" && ACTION=on || ACTION=off
    SAVE=false YES=true
fi

PROJECT="${CONTROL_OTHER_WORKLOADS_INDICATOR_PROJECT:-swhcc-other-workloads}"
IMAGE="${CONTROL_OTHER_WORKLOADS_INDICATOR_IMAGE:-image-registry.openshift-image-registry.svc:5000/openshift/python:3.11-ubi9}"
ACCOUNT="${CONTROL_AUTODETECT_OTHER_ACCOUNT_NAME-other-reserved-workloads}"
NAME=other-workloads-indicator
LABEL="app.kubernetes.io/name=${NAME}"
SERVER="${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_indicator_server.py"

eval "${OC_LOGIN:-${CONTROL_OC_LOGIN}}"
HOST="cpd-${PROJECT}.$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}')"
URL="https://${HOST}"

save_setting() {   # <true|false>
    [[ "${SAVE}" == true ]] || return 0
    if grep -q '^export CONTROL_OTHER_WORKLOADS_INDICATOR=' "${ENV_TARGET_FILE}"; then
        VALUE="$1" perl -pi -e 's/^export CONTROL_OTHER_WORKLOADS_INDICATOR=.*/export CONTROL_OTHER_WORKLOADS_INDICATOR="$ENV{VALUE}"/' "${ENV_TARGET_FILE}"
    else
        print -r -- "export CONTROL_OTHER_WORKLOADS_INDICATOR=\"$1\"" >> "${ENV_TARGET_FILE}"
    fi
    h_info "CONTROL_OTHER_WORKLOADS_INDICATOR is now \"$1\" in ${ENV_TARGET_FILE}"
}

if [[ "${ACTION}" == status ]]; then
    oc get deployment "${NAME}" -n "${PROJECT}" -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image 2>/dev/null \
        || h_info "Not deployed in ${PROJECT}."
    swhcc_api_login
    if swhcc_find_instance "${URL}"; then
        h_info "Registered in Control Center as ${URL} (ID ${REPLY})."
        cpdapi GET "${SWHCC_WATCHDOG}/instances/metrics/${REPLY}"
        swhcc_api_ok && h_info "Last metrics: $(print -r -- "${API_BODY}" | jq -c '.requestObj | {Time, Accessible, CPURequests, MemoryRequests, CPUUtilization, MemoryUtilization}')"
    else
        h_info "Not registered in Control Center."
    fi
    oc logs -n "${PROJECT}" "deployment/${NAME}" --tail=10 2>/dev/null | sed 's/^/    /' || true
    exit 0
fi

if [[ "${ACTION}" == off ]]; then
    if ! oc get project "${PROJECT}" >/dev/null 2>&1; then
        h_info "The indicator is not deployed - nothing to remove."
        save_setting false
        exit 0
    fi
    if [[ "${YES}" != true ]]; then
        h_confirm "Remove the other workloads indicator and delete project ${PROJECT}?" || { h_info "Nothing changed."; exit 0; }
    fi
    swhcc_api_login
    if swhcc_find_instance "${URL}"; then
        cpdapi DELETE "${SWHCC_PLATFORM}/namespaces/${REPLY}"
        swhcc_api_ok && h_info "Removed it from Control Center." || h_warn "Could not remove it from Control Center ($(swhcc_api_error))."
    fi
    oc delete clusterrolebinding,clusterrole -l "${LABEL}" --ignore-not-found
    oc delete project "${PROJECT}" --ignore-not-found
    save_setting false
    h_info "Indicator removed."
    exit 0
fi

# --- on ---------------------------------------------------------------------------
[[ -f "${SERVER}" ]] || h_die "${SERVER} is missing."
swhcc_api_login
[[ -n "${ACCOUNT}" ]] && swhcc_find_account "${ACCOUNT}" \
    || h_die "Account '${ACCOUNT:-<none>}' not found. Run autodetect_instances.sh first, with CONTROL_AUTODETECT_OTHER_ACCOUNT_NAME set."
ACCOUNT_ID="${SWHCC_ACCOUNT_ID}"
cpdapi GET "${SWHCC_WATCHDOG}/resource_group/resources/policies/${ACCOUNT_ID}"
read -r QUOTA_CPU QUOTA_MEMORY <<< "$(print -r -- "${API_BODY}" | jq -r '[.requestObj.Resources[]?][0].Resources // {} | "\(.CPU.Allocated // 0) \(.Memory.Allocated // 0)"')"

# Projects the indicator leaves out: the instances'. Control Center's own are counted.
EXCLUDE="${(j:,:)${(@f)$(swhcc_instance_projects)}}"
INCLUDE="${CONTROL_PROJECT_OPERATORS},${CONTROL_PROJECT_OPERANDS}"

oc get project "${PROJECT}" >/dev/null 2>&1 || oc new-project "${PROJECT}" --skip-config-write >/dev/null
oc label namespace "${PROJECT}" "${LABEL}" --overwrite >/dev/null

# The login Control Center uses. Kept in a secret, so re-runs keep the same key.
API_KEY="$(oc get secret "${NAME}" -n "${PROJECT}" -o jsonpath='{.data.INDICATOR_API_KEY}' 2>/dev/null | base64 -d || true)"
[[ -n "${API_KEY}" ]] || API_KEY="$(LC_ALL=C openssl rand -hex 24)"
INDICATOR_USER="${NAME}"
oc create secret generic "${NAME}" -n "${PROJECT}" --from-literal=INDICATOR_USERNAME="${INDICATOR_USER}" \
    --from-file=INDICATOR_API_KEY=<(print -rn -- "${API_KEY}") --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create configmap "${NAME}" -n "${PROJECT}" --from-file=server.py="${SERVER}" --dry-run=client -o yaml | oc apply -f - >/dev/null

oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NAME}
  namespace: ${PROJECT}
  labels: {app.kubernetes.io/name: ${NAME}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${NAME}-reader
  labels: {app.kubernetes.io/name: ${NAME}}
rules:
  - apiGroups: [""]
    resources: [pods, nodes, persistentvolumeclaims]
    verbs: [get, list]
  - apiGroups: [metrics.k8s.io]
    resources: [pods]
    verbs: [get, list]
  - apiGroups: [zen.cpd.ibm.com]
    resources: [zenservices]
    verbs: [get, list]
  - apiGroups: [operator.ibm.com]
    resources: [commonservices]
    verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NAME}-reader-${PROJECT}
  labels: {app.kubernetes.io/name: ${NAME}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: ${NAME}-reader}
subjects:
  - {kind: ServiceAccount, name: ${NAME}, namespace: ${PROJECT}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  namespace: ${PROJECT}
  labels: {app.kubernetes.io/name: ${NAME}}
spec:
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: ${NAME}}
  template:
    metadata:
      labels: {app.kubernetes.io/name: ${NAME}}
      annotations: {swhcc/server-sha: "$(shasum -a 256 "${SERVER}" | cut -c1-16)"}
    spec:
      serviceAccountName: ${NAME}
      containers:
        - name: server
          image: ${IMAGE}
          command: [python3, /app/server.py]
          ports: [{containerPort: 8080, name: http}]
          envFrom: [{secretRef: {name: ${NAME}}}]
          env:
            - {name: EXCLUDE_PROJECTS, value: "${EXCLUDE}"}
            - {name: INCLUDE_PROJECTS, value: "${INCLUDE}"}
            - {name: QUOTA_CPU, value: "${QUOTA_CPU}"}
            - {name: QUOTA_MEMORY_GI, value: "${QUOTA_MEMORY}"}
          readinessProbe:
            httpGet: {path: /zen-watchdog/v1/monitor, port: 8080}
            periodSeconds: 10
          resources:
            requests: {cpu: 20m, memory: 64Mi}
            limits: {cpu: 200m, memory: 256Mi}
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities: {drop: [ALL]}
            seccompProfile: {type: RuntimeDefault}
          volumeMounts: [{name: app, mountPath: /app, readOnly: true}]
      volumes:
        - {name: app, configMap: {name: ${NAME}}}
---
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}
  namespace: ${PROJECT}
  labels: {app.kubernetes.io/name: ${NAME}}
spec:
  selector: {app.kubernetes.io/name: ${NAME}}
  ports: [{name: http, port: 8080, targetPort: 8080}]
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${NAME}
  namespace: ${PROJECT}
  labels: {app.kubernetes.io/name: ${NAME}}
spec:
  host: ${HOST}
  to: {kind: Service, name: ${NAME}}
  port: {targetPort: http}
  tls: {termination: edge, insecureEdgeTerminationPolicy: Redirect}
YAML
h_info "Deployed the indicator in ${PROJECT}; waiting for it"
oc rollout restart "deployment/${NAME}" -n "${PROJECT}" >/dev/null
oc rollout status "deployment/${NAME}" -n "${PROJECT}" --timeout=300s

if swhcc_find_instance "${URL}"; then
    INSTANCE_ID="${REPLY}"
    h_info "Already registered in Control Center (ID ${INSTANCE_ID})."
else
    register() { swhcc_register_instance "${NAME}" "${URL}" "${INDICATOR_USER}" "${API_KEY}" "${ACCOUNT_ID}" OTHER_WL; }
    if swhcc_route_is_private "${HOST}"; then
        swhcc_with_route_mapping "$(dig +short "${HOST}" | tail -1)" "${HOST}" -- register \
            || h_die "Registering failed. See: oc logs -n ${PROJECT} deployment/${NAME}"
    else
        register || h_die "Registering failed. See: oc logs -n ${PROJECT} deployment/${NAME}"
    fi
    swhcc_api_login
    swhcc_find_instance "${URL}" || h_die "Registered, but Control Center does not list ${URL}."
    INSTANCE_ID="${REPLY}"
    h_info "Registered ${NAME} in account '${ACCOUNT}'."
fi

# Its quota is the whole account, so the reservation reads as allocated there.
swhcc_set_instance_quota "${INSTANCE_ID}" "${QUOTA_CPU}" "${QUOTA_MEMORY}"
swhcc_api_ok || h_warn "Could not set its quota ($(swhcc_api_error))."
h_info "Quota: ${QUOTA_CPU} vCPU, ${QUOTA_MEMORY} Gi memory. Figures appear on the next metrics cycle, within 10 minutes."
save_setting true
