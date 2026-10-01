#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform for Apache Flink - OpenShift-backed authentication for CMF
# ------------------------------------------------------------------------------
# Puts the same openshift/oauth-proxy sidecar that guards Control Center (see
# ../x.2_confluent_add_auth_openshift.sh) in front of the 'cmf' route, so the
# CMF REST API is no longer open to anyone who can reach the cluster's ingress.
#
# What changes:
#   - the CMF deployment gains an 'oauth-proxy' container
#   - a second service, cmf-auth, points at that container
#   - the 'cmf' route is repointed from cmf-service to cmf-auth
#
# What does NOT change:
#   - cmf-service, the chart's own service. It still reaches CMF directly, so
#     in-cluster callers and the port-forward the x.* scripts open keep working
#     without credentials. Only the public route is gated.
#
# Two ways through the proxy:
#   browser   redirected to the OpenShift login page, then a session cookie
#   API/curl  Authorization: Bearer <OpenShift token>, e.g.
#               curl -H "Authorization: Bearer $(oc whoami -t)" \
#                    https://<route>/cmf/api/v1/environments
#
# The confluent CLI can do neither - it has no way to send an OpenShift token to
# CMF - so flink_cmf_connect.sh stops using the route once it is protected and
# port-forwards instead.
#
# Access is delegated to OpenShift RBAC exactly as for Control Center: a user is
# admitted when they can 'get services' in this namespace.
#
# The sidecar is a patch on a Helm-managed deployment. 1.1_flink_install.sh
# re-runs this script after every helm upgrade while auth is enabled, so a
# re-install neither drops the sidecar nor reopens the route.
#
# Usage:
#   ./x.2_flink_add_auth_openshift.sh [--disable] [--yes] [--dry-run] [--no-status]
#
#   --disable    remove OpenShift auth and point the route straight at CMF again
#   --yes        skip the --disable confirmation prompt
#   --dry-run    report what would change, change nothing
#   --no-status  skip the closing status report
# ==============================================================================

DISABLE=false
ASSUME_YES=false
DRY_RUN=false
RUN_STATUS=true

while (( $# > 0 )); do
    case "$1" in
        --disable)   DISABLE=true; shift ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --no-status) RUN_STATUS=false; shift ;;
        -h|--help)   sed -n '16,54p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

STATUS="${SCRIPT_DIR}/1.2_flink_status.sh"

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_FLINK}"
DEPLOY="confluent-manager-for-apache-flink"
# The CMF pod's own service account doubles as the OAuth client.
SA="confluent-manager-for-apache-flink"
: "${FLINK_AUTH_SECRET:=cmf-oauth}"
: "${FLINK_AUTH_SERVICE:=cmf-auth}"
: "${FLINK_CMF_GATEWAY_PORT:=8443}"
: "${FLINK_CMF_CONTAINER_PORT:=8080}"
# Same image as the Control Center gateway unless overridden.
: "${FLINK_CMF_OAUTH_PROXY_IMAGE:=${CONFLUENT_C3_OAUTH_PROXY_IMAGE:-image-registry.openshift-image-registry.svc:5000/openshift/oauth-proxy:v4.4}}"

if ! oc get deployment "${DEPLOY}" -n "${NS}" &>/dev/null; then
    echo "[ERROR] CMF is not installed in project '${NS}'. Run 1.1_flink_install.sh first." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Report the transition
# ------------------------------------------------------------------------------
_containers="$(oc get deployment "${DEPLOY}" -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || true)"
_route_svc="$(oc get route cmf -n "${NS}" -o jsonpath='{.spec.to.name}' 2>/dev/null || true)"
if [[ "${_containers}" == *oauth-proxy* && "${_route_svc}" == "${FLINK_AUTH_SERVICE}" ]]; then
    _current="OpenShift auth (oauth-proxy)"
elif [[ -n "${_route_svc}" ]]; then
    _current="none - the CMF route is unprotected"
else
    _current="no route (CMF is in-cluster only)"
fi

echo "=============================================================================="
echo " CMF route authentication - project '${NS}'"
echo "=============================================================================="
echo "  current : ${_current}"
if $DISABLE; then
    echo "  target  : disabled (route unprotected)"
else
    echo "  target  : OpenShift login via oauth-proxy"
    echo "  access  : any user who can 'get services' in ${NS}"
fi
echo "  affects : the 'cmf' route only (${FLINK_CMF_SERVICE} and running jobs are untouched)"
echo ""

if $DRY_RUN; then
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi

if $DISABLE && ! $ASSUME_YES; then
    echo "This REMOVES authentication: anyone who can reach the route can create and delete Flink jobs."
    printf "Continue? [y/N] "
    read -r _reply
    case "${_reply}" in y|Y|yes|YES) ;; *) echo "[INFO] Aborted."; exit 0 ;; esac
    echo ""
fi

# ------------------------------------------------------------------------------
# apply_route <service> <targetPort> - (re)point the 'cmf' route.
# ------------------------------------------------------------------------------
apply_route() {
    local _host_line=""
    [[ -n "${CONFLUENT_ROUTE_DOMAIN:-}" ]] && _host_line="  host: cmf-${NS}.${CONFLUENT_ROUTE_DOMAIN}"
    oc apply -f - >/dev/null <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: cmf
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: confluent-flink
spec:
${_host_line}
  to:
    kind: Service
    name: ${1}
  port:
    targetPort: ${2}
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
}

# ------------------------------------------------------------------------------
# Step 1 - OpenShift OAuth plumbing
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo " Step 1/2: OpenShift OAuth resources"
echo "------------------------------------------------------------------------------"

if $DISABLE; then
    # Route first, so it never points at a service whose backend is going away.
    if [[ -n "${_route_svc}" ]]; then
        apply_route "${FLINK_CMF_SERVICE}" "${FLINK_CMF_CONTAINER_PORT}"
        echo "[INFO] Route 'cmf' points at ${FLINK_CMF_SERVICE} again."
    fi
    oc delete service "${FLINK_AUTH_SERVICE}" -n "${NS}" --ignore-not-found >/dev/null
    oc delete secret "${FLINK_AUTH_SECRET}" -n "${NS}" --ignore-not-found >/dev/null
    oc annotate serviceaccount "${SA}" -n "${NS}" \
        serviceaccounts.openshift.io/oauth-redirectreference.cmf- >/dev/null 2>&1 || true
    oc adm policy remove-cluster-role-from-user system:auth-delegator -z "${SA}" -n "${NS}" >/dev/null 2>&1 || true
    echo "[INFO] Removed OpenShift OAuth resources."
else
    # The redirect reference tells the OAuth server which route is allowed to
    # receive the callback; without it the login round-trip is rejected as an
    # unregistered client.
    oc annotate serviceaccount "${SA}" -n "${NS}" --overwrite \
        "serviceaccounts.openshift.io/oauth-redirectreference.cmf={\"kind\":\"OAuthRedirectReference\",\"apiVersion\":\"v1\",\"reference\":{\"kind\":\"Route\",\"name\":\"cmf\"}}" >/dev/null
    echo "[INFO] Annotated serviceaccount/${SA} as an OAuth client for route cmf."

    # Cookie secret encrypts the proxy's session cookie. Generated once and
    # reused, so existing sessions survive a redeploy.
    _cookie="$(oc get secret "${FLINK_AUTH_SECRET}" -n "${NS}" \
        -o jsonpath='{.data.cookie-secret}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
    if [[ -z "${_cookie}" ]]; then
        # oauth-proxy requires exactly 16, 24 or 32 bytes for AES.
        _cookie="$(LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32)"
        echo "[INFO] Generated a new session cookie secret."
    else
        echo "[INFO] Reusing the existing session cookie secret."
    fi
    oc create secret generic "${FLINK_AUTH_SECRET}" \
        --from-literal=cookie-secret="${_cookie}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null

    # The proxy verifies the user's token against the API server, so it needs
    # permission to create TokenReviews and SubjectAccessReviews.
    oc adm policy add-cluster-role-to-user system:auth-delegator -z "${SA}" -n "${NS}" >/dev/null 2>&1 \
        || echo "[WARN] Could not grant the system:auth-delegator cluster role; the proxy may fail to verify tokens."
fi

# ------------------------------------------------------------------------------
# Step 2 - sidecar, service, route
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 2/2: CMF deployment and route"
echo "------------------------------------------------------------------------------"

if $DISABLE; then
    # '$patch: delete' removes the list entries by name, wherever they sit.
    oc patch deployment "${DEPLOY}" -n "${NS}" --type=strategic -p '
spec:
  template:
    spec:
      containers:
        - name: oauth-proxy
          $patch: delete
      volumes:
        - name: oauth-secret
          $patch: delete
' >/dev/null
    echo "[INFO] Removed the oauth-proxy sidecar."
else
    _sar="{\"namespace\":\"${NS}\",\"resource\":\"services\",\"verb\":\"get\"}"
    # A strategic merge patch keys containers and volumes by name, so this adds
    # the sidecar on the first run and is a no-op (no rollout) on later ones.
    oc patch deployment "${DEPLOY}" -n "${NS}" --type=strategic -p "
spec:
  template:
    spec:
      containers:
        - name: oauth-proxy
          image: ${FLINK_CMF_OAUTH_PROXY_IMAGE}
          args:
            - --provider=openshift
            - --https-address=
            - --http-address=:${FLINK_CMF_GATEWAY_PORT}
            - --upstream=http://127.0.0.1:${FLINK_CMF_CONTAINER_PORT}
            - --openshift-service-account=${SA}
            - --openshift-sar=${_sar}
            # CMF is a REST API first: this admits a request carrying an
            # OpenShift bearer token, subject to the same check as a browser
            # session, instead of redirecting it to a login page.
            - --openshift-delegate-urls={\"/\":${_sar}}
            - --cookie-secret-file=/etc/proxy/secrets/cookie-secret
            - --skip-provider-button=true
            - --pass-access-token=false
          ports:
            - containerPort: ${FLINK_CMF_GATEWAY_PORT}
              name: proxy
          volumeMounts:
            - name: oauth-secret
              mountPath: /etc/proxy/secrets
              readOnly: true
          readinessProbe:
            httpGet:
              path: /oauth/healthz
              port: ${FLINK_CMF_GATEWAY_PORT}
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 30
          resources:
            requests:
              cpu: '50m'
              memory: '64Mi'
            limits:
              cpu: '200m'
              memory: '256Mi'
      volumes:
        - name: oauth-secret
          secret:
            secretName: ${FLINK_AUTH_SECRET}
" >/dev/null
    echo "[INFO] oauth-proxy sidecar configured on deployment/${DEPLOY}."

    # A service of its own rather than a change to cmf-service: that one
    # belongs to the Helm release, and it is the unauthenticated in-cluster
    # path the port-forward depends on.
    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${FLINK_AUTH_SERVICE}
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: confluent-flink
spec:
  selector:
    app.kubernetes.io/name: confluent-manager-for-apache-flink
  ports:
    - name: proxy
      port: ${FLINK_CMF_GATEWAY_PORT}
      targetPort: ${FLINK_CMF_GATEWAY_PORT}
EOF
fi

# The deployment uses the Recreate strategy (its volume is RWO), so CMF is
# briefly down here. Running Flink jobs are not affected.
echo "[INFO] Waiting for CMF to roll out..."
if ! oc rollout status "deployment/${DEPLOY}" -n "${NS}" --timeout="${FLINK_ROLLOUT_TIMEOUT:-600s}" >/dev/null; then
    echo "[ERROR] CMF did not become ready. The route has NOT been changed." >&2
    echo "[ERROR] Check:  oc logs deployment/${DEPLOY} -c oauth-proxy -n ${NS}" >&2
    exit 1
fi

if ! $DISABLE; then
    # Last, once the proxy is serving, so the route never points at nothing.
    apply_route "${FLINK_AUTH_SERVICE}" "proxy"
    echo "[INFO] Route 'cmf' now points at ${FLINK_AUTH_SERVICE} (oauth-proxy)."
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
_host="$(oc get route cmf -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
echo ""
echo "=============================================================================="
if $DISABLE; then
    echo "[WARN] The CMF route is now UNAUTHENTICATED${_host:+: https://${_host}}"
else
    echo "[INFO] CMF now uses OpenShift login: https://${_host}"
    echo "[INFO] Sign in with any OpenShift account that can read services in ${NS}."
    echo "[INFO] Grant another user access with:"
    echo "[INFO]   oc policy add-role-to-user view <username> -n ${NS}"
    echo "[INFO] API access with a token:"
    echo "[INFO]   curl -H \"Authorization: Bearer \$(oc whoami -t)\" https://${_host}/cmf/api/v1/environments"
    echo "[INFO] The confluent CLI cannot log in through the proxy; the x.* scripts"
    echo "[INFO] port-forward to ${FLINK_CMF_SERVICE} instead."
fi
echo "=============================================================================="

if [[ "${RUN_STATUS}" == "true" && -f "${STATUS}" ]]; then
    echo ""
    "${STATUS}" || echo "[WARN] Status reported one or more components not ready (see above)."
fi
