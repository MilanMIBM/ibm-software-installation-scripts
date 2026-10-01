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
# Confluent Platform - identity provider for MDS
# ------------------------------------------------------------------------------
# MDS authenticates users against a user store. This script deploys the bundled
# one, selected by CONFLUENT_MDS_USER_STORE:
#
#   LDAP   OpenLDAP. Confluent's most-documented MDS store, and the one that
#          supports headless "confluent login -u user -p pass", so it is the
#          default and the right choice for CI.
#   OAUTH  Keycloak, an OIDC provider. Enables SSO and the device-code flow
#          ("confluent login --no-browser"), and can federate to a corporate
#          IdP later.
#
# Neither is deployed when CONFLUENT_MDS_OAUTH_JWKS_URL points at an external
# provider - that case needs no in-cluster identity at all.
#
# Why not the OpenShift login? The cluster's own OAuth server issues opaque
# tokens and publishes no JWKS endpoint, so MDS cannot validate what it hands
# out. The Kubernetes API server does publish JWKS but only signs ServiceAccount
# tokens, which no human logs in with. So MDS needs its own IdP even on a
# cluster that already has one. This is independent of the Control Center UI
# auth in x.2_confluent_add_auth_openshift.sh, which can keep using OpenShift.
#
# This script is called by x.4_confluent_add_mds.sh; run it directly only to
# re-provision or inspect the store on its own.
#
# Usage:
#   ./x.4_confluent_user_store.sh [--rotate] [--delete] [--yes] [--dry-run]
#
#   --rotate   regenerate every generated password
#   --delete   remove the deployed identity provider
#   --yes      skip the confirmation prompt
#   --dry-run  report what would change, change nothing
# ==============================================================================

ROTATE=false
DELETE=false
ASSUME_YES=true
DRY_RUN=false

_need_value() { [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }; }

while (( $# > 0 )); do
    case "$1" in
        --rotate)  ROTATE=true; shift ;;
        --delete)  DELETE=true; shift ;;
        --yes|-y)  ASSUME_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) sed -n '16,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
SA="confluent"
: "${CONFLUENT_MDS_USER_STORE:=LDAP}"
: "${CONFLUENT_MDS_SUPER_USER:=mds-admin}"
: "${CONFLUENT_MDS_USERS:=kafka-admin,kafka-user}"
: "${CONFLUENT_MDS_SECRET:=confluent-mds}"
: "${CONFLUENT_LDAP_IMAGE:=docker.io/bitnamilegacy/openldap:2.6.10}"
: "${CONFLUENT_LDAP_PORT:=1389}"
: "${CONFLUENT_LDAP_DOMAIN:=confluent.io}"
: "${CONFLUENT_LDAP_ADMIN_USER:=admin}"
: "${CONFLUENT_LDAP_SECRET:=confluent-ldap}"
: "${CONFLUENT_KEYCLOAK_IMAGE:=quay.io/keycloak/keycloak:26.0}"
: "${CONFLUENT_KEYCLOAK_PORT:=8080}"
: "${CONFLUENT_KEYCLOAK_REALM:=confluent}"
: "${CONFLUENT_KEYCLOAK_CLIENT_ID:=confluent-cli}"
: "${CONFLUENT_KEYCLOAK_ADMIN_USER:=admin}"
: "${CONFLUENT_KEYCLOAK_SECRET:=confluent-keycloak}"
: "${CONFLUENT_MDS_OAUTH_JWKS_URL:=}"
: "${CONFLUENT_CREATE_ROUTES:=true}"
: "${CONFLUENT_ROLLOUT_TIMEOUT:=600s}"

_store="${CONFLUENT_MDS_USER_STORE:u}"

oc get namespace "${NS}" &>/dev/null || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }

# Base DN from the domain: confluent.io -> dc=confluent,dc=io
LDAP_BASE_DN="dc=${CONFLUENT_LDAP_DOMAIN//./,dc=}"
LDAP_ADMIN_DN="cn=${CONFLUENT_LDAP_ADMIN_USER},${LDAP_BASE_DN}"

# All the human accounts MDS should know about: the super user plus the extras.
_user_list="${CONFLUENT_MDS_SUPER_USER} ${CONFLUENT_MDS_USERS//,/ }"
# De-duplicate while preserving order (super user must stay first).
typeset -a _users; _users=()
for _u in ${=_user_list}; do
    [[ -z "${_u}" ]] && continue
    (( ${_users[(Ie)${_u}]} )) || _users+=("${_u}")
done

# ------------------------------------------------------------------------------
# Delete
# ------------------------------------------------------------------------------
if $DELETE; then
    echo "=============================================================================="
    echo " Removing the MDS identity provider from project '${NS}'"
    echo "=============================================================================="
    if $DRY_RUN; then
        echo "[INFO] --dry-run: would delete the openldap and keycloak workloads."
        exit 0
    fi
    for _r in deployment/openldap svc/openldap route/openldap \
              deployment/keycloak svc/keycloak route/keycloak; do
        oc delete "${_r}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
    done
    echo "[INFO] Identity provider workloads removed."
    echo "[INFO] Secrets '${CONFLUENT_LDAP_SECRET}' and '${CONFLUENT_KEYCLOAK_SECRET}' are kept so"
    echo "[INFO] passwords survive a redeploy. Delete them to discard the accounts."
    exit 0
fi

if [[ -n "${CONFLUENT_MDS_OAUTH_JWKS_URL}" ]]; then
    echo "[INFO] CONFLUENT_MDS_OAUTH_JWKS_URL is set - using that external OIDC provider."
    echo "[INFO] No in-cluster identity provider is deployed."
    exit 0
fi

echo "=============================================================================="
echo " MDS identity provider - project '${NS}'"
echo "=============================================================================="
echo "  store   : ${_store}"
echo "  users   : ${_users[*]}"
echo "  super   : ${CONFLUENT_MDS_SUPER_USER}"
echo ""

if $DRY_RUN; then
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi

gen_pw() { LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24; }

# ------------------------------------------------------------------------------
# read_or_make <secret> <key> - reuse a stored password unless --rotate.
# Keeping passwords stable across re-runs is what lets this script be re-run to
# add a user without invalidating everyone else's credentials.
# ------------------------------------------------------------------------------
read_or_make() {
    local secret="$1" key="$2" existing=""
    existing="$(oc get secret "${secret}" -n "${NS}" -o jsonpath="{.data.${key}}" 2>/dev/null \
        | base64 --decode 2>/dev/null || true)"
    if [[ -n "${existing}" ]] && ! $ROTATE; then
        printf '%s' "${existing}"
    else
        gen_pw
    fi
}

case "${_store}" in
LDAP)
    # --------------------------------------------------------------------------
    # OpenLDAP
    # --------------------------------------------------------------------------
    echo "------------------------------------------------------------------------------"
    echo " Deploying OpenLDAP"
    echo "------------------------------------------------------------------------------"

    typeset -A _pw
    for _u in "${_users[@]}"; do _pw[$_u]="$(read_or_make "${CONFLUENT_LDAP_SECRET}" "${_u}")"; done
    _ldap_admin_pw="$(read_or_make "${CONFLUENT_LDAP_SECRET}" "${CONFLUENT_LDAP_ADMIN_USER}")"

    _args=(--from-literal="${CONFLUENT_LDAP_ADMIN_USER}=${_ldap_admin_pw}")
    for _u in "${_users[@]}"; do _args+=(--from-literal="${_u}=${_pw[$_u]}"); done
    oc create secret generic "${CONFLUENT_LDAP_SECRET}" "${_args[@]}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null
    echo "[INFO] Credentials stored in secret '${CONFLUENT_LDAP_SECRET}'."

    # Bitnami's OpenLDAP seeds users from LDAP_USERS/LDAP_PASSWORDS on an empty
    # volume. Passing them as a comma-separated pair keeps the whole directory
    # declarative - no ldapadd bootstrapping step.
    _ldap_users="$(IFS=,; echo "${_users[*]}")"
    _ldap_pws=""
    for _u in "${_users[@]}"; do _ldap_pws+="${_pw[$_u]},"; done
    _ldap_pws="${_ldap_pws%,}"

    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: openldap
  namespace: ${NS}
  labels: { app: openldap, app.kubernetes.io/part-of: confluent }
spec:
  selector: { app: openldap }
  ports:
    - name: ldap
      port: ${CONFLUENT_LDAP_PORT}
      targetPort: ${CONFLUENT_LDAP_PORT}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openldap
  namespace: ${NS}
  labels: { app: openldap, app.kubernetes.io/part-of: confluent }
spec:
  replicas: 1
  selector:
    matchLabels: { app: openldap }
  template:
    metadata:
      labels: { app: openldap, app.kubernetes.io/part-of: confluent }
    spec:
      # Same service account as the rest of the stack: it carries the anyuid
      # SCC. Under OpenShift's default restricted-v2 the Bitnami entrypoint
      # cannot exec slappasswd ("Operation not permitted") and the pod crashes.
      serviceAccountName: ${SA}
      containers:
        - name: openldap
          image: ${CONFLUENT_LDAP_IMAGE}
          ports:
            - containerPort: ${CONFLUENT_LDAP_PORT}
          env:
            - name: LDAP_PORT_NUMBER
              value: '${CONFLUENT_LDAP_PORT}'
            - name: LDAP_ROOT
              value: '${LDAP_BASE_DN}'
            - name: LDAP_ADMIN_USERNAME
              value: '${CONFLUENT_LDAP_ADMIN_USER}'
            - name: LDAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef: { name: ${CONFLUENT_LDAP_SECRET}, key: ${CONFLUENT_LDAP_ADMIN_USER} }
            - name: LDAP_USERS
              value: '${_ldap_users}'
            - name: LDAP_PASSWORDS
              value: '${_ldap_pws}'
          readinessProbe:
            tcpSocket: { port: ${CONFLUENT_LDAP_PORT} }
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 30
          resources:
            requests: { cpu: "100m", memory: "256Mi" }
            limits:   { cpu: "500m", memory: "512Mi" }
EOF
    echo "[INFO] Applied openldap."
    oc rollout status deployment/openldap -n "${NS}" --timeout="${CONFLUENT_ROLLOUT_TIMEOUT}"

    echo ""
    echo "[INFO] LDAP is reachable in-cluster at ldap://openldap:${CONFLUENT_LDAP_PORT}"
    echo "[INFO]   base DN : ${LDAP_BASE_DN}"
    echo "[INFO]   user DN : cn=<user>,ou=users,${LDAP_BASE_DN}"
    ;;

OAUTH)
    # --------------------------------------------------------------------------
    # Keycloak
    # --------------------------------------------------------------------------
    echo "------------------------------------------------------------------------------"
    echo " Deploying Keycloak"
    echo "------------------------------------------------------------------------------"

    if [[ "${CONFLUENT_CREATE_ROUTES}" != "true" ]]; then
        echo "[ERROR] CONFLUENT_MDS_USER_STORE=OAUTH needs CONFLUENT_CREATE_ROUTES=true: the CLI" >&2
        echo "[ERROR] must reach Keycloak from outside the cluster to complete a login." >&2
        exit 1
    fi

    typeset -A _pw
    for _u in "${_users[@]}"; do _pw[$_u]="$(read_or_make "${CONFLUENT_KEYCLOAK_SECRET}" "${_u}")"; done
    _kc_admin_pw="$(read_or_make "${CONFLUENT_KEYCLOAK_SECRET}" "${CONFLUENT_KEYCLOAK_ADMIN_USER}")"

    _args=(--from-literal="${CONFLUENT_KEYCLOAK_ADMIN_USER}=${_kc_admin_pw}")
    for _u in "${_users[@]}"; do _args+=(--from-literal="${_u}=${_pw[$_u]}"); done
    oc create secret generic "${CONFLUENT_KEYCLOAK_SECRET}" "${_args[@]}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null
    echo "[INFO] Credentials stored in secret '${CONFLUENT_KEYCLOAK_SECRET}'."

    _kc_host=""
    if [[ -n "${CONFLUENT_ROUTE_DOMAIN:-}" ]]; then
        _kc_host="keycloak-${NS}.${CONFLUENT_ROUTE_DOMAIN}"
    else
        _kc_host="keycloak-${NS}.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
    fi

    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${NS}
  labels: { app: keycloak, app.kubernetes.io/part-of: confluent }
spec:
  selector: { app: keycloak }
  ports:
    - name: http
      port: ${CONFLUENT_KEYCLOAK_PORT}
      targetPort: ${CONFLUENT_KEYCLOAK_PORT}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
  namespace: ${NS}
  labels: { app.kubernetes.io/part-of: confluent }
spec:
  host: ${_kc_host}
  to: { kind: Service, name: keycloak }
  port: { targetPort: http }
  tls: { termination: edge, insecureEdgeTerminationPolicy: Redirect }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: ${NS}
  labels: { app: keycloak, app.kubernetes.io/part-of: confluent }
spec:
  replicas: 1
  selector:
    matchLabels: { app: keycloak }
  template:
    metadata:
      labels: { app: keycloak, app.kubernetes.io/part-of: confluent }
    spec:
      serviceAccountName: ${SA}
      containers:
        - name: keycloak
          image: ${CONFLUENT_KEYCLOAK_IMAGE}
          args: ["start-dev", "--http-port=${CONFLUENT_KEYCLOAK_PORT}"]
          ports:
            - containerPort: ${CONFLUENT_KEYCLOAK_PORT}
          env:
            # The route terminates TLS, so Keycloak itself speaks HTTP but must
            # advertise the https:// route in issuer/JWKS URLs or the tokens it
            # mints will not match what MDS expects.
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              value: '${CONFLUENT_KEYCLOAK_ADMIN_USER}'
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef: { name: ${CONFLUENT_KEYCLOAK_SECRET}, key: ${CONFLUENT_KEYCLOAK_ADMIN_USER} }
            - name: KC_HOSTNAME
              value: 'https://${_kc_host}'
            - name: KC_HTTP_ENABLED
              value: 'true'
            - name: KC_PROXY_HEADERS
              value: 'xforwarded'
            - name: KC_HEALTH_ENABLED
              value: 'true'
          readinessProbe:
            httpGet: { path: /realms/master, port: ${CONFLUENT_KEYCLOAK_PORT} }
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 30
          resources:
            requests: { cpu: "200m", memory: "512Mi" }
            limits:   { cpu: "1", memory: "1Gi" }
EOF
    echo "[INFO] Applied keycloak."
    oc rollout status deployment/keycloak -n "${NS}" --timeout="${CONFLUENT_ROLLOUT_TIMEOUT}"

    # --------------------------------------------------------------------------
    # Realm, client and users, via kcadm inside the pod.
    # Every step is idempotent: create-or-update, so re-runs converge.
    # --------------------------------------------------------------------------
    echo "[INFO] Configuring realm '${CONFLUENT_KEYCLOAK_REALM}'..."
    _kc_pod="$(oc get pod -n "${NS}" -l app=keycloak -o jsonpath='{.items[0].metadata.name}')"

    _kc_users_csv="$(IFS=,; echo "${_users[*]}")"
    _kc_pws_csv=""
    for _u in "${_users[@]}"; do _kc_pws_csv+="${_pw[$_u]},"; done
    _kc_pws_csv="${_kc_pws_csv%,}"

    oc exec "${_kc_pod}" -n "${NS}" -- env \
        KC_REALM="${CONFLUENT_KEYCLOAK_REALM}" \
        KC_CLIENT="${CONFLUENT_KEYCLOAK_CLIENT_ID}" \
        KC_ADMIN="${CONFLUENT_KEYCLOAK_ADMIN_USER}" \
        KC_ADMIN_PW="${_kc_admin_pw}" \
        KC_PORT="${CONFLUENT_KEYCLOAK_PORT}" \
        KC_USERS="${_kc_users_csv}" \
        KC_PWS="${_kc_pws_csv}" \
        bash -s <<'KCEOF'
set -e
K=/opt/keycloak/bin/kcadm.sh
$K config credentials --server "http://localhost:${KC_PORT}" \
    --realm master --user "${KC_ADMIN}" --password "${KC_ADMIN_PW}" >/dev/null

$K get "realms/${KC_REALM}" >/dev/null 2>&1 \
  || $K create realms -s realm="${KC_REALM}" -s enabled=true >/dev/null

# A public client with the device-code flow on: that is what lets
# "confluent login --no-browser" work without shipping a client secret.
CID=$($K get clients -r "${KC_REALM}" -q clientId="${KC_CLIENT}" --fields id --format csv --noquotes 2>/dev/null | tail -n1)
if [ -z "$CID" ]; then
  $K create clients -r "${KC_REALM}" \
    -s clientId="${KC_CLIENT}" -s enabled=true -s publicClient=true \
    -s directAccessGrantsEnabled=true \
    -s 'attributes."oauth2.device.authorization.grant.enabled"=true' \
    -s 'redirectUris=["http://localhost:*","https://localhost:*"]' >/dev/null
else
  $K update "clients/$CID" -r "${KC_REALM}" \
    -s directAccessGrantsEnabled=true \
    -s 'attributes."oauth2.device.authorization.grant.enabled"=true' >/dev/null
fi

# MDS reads group membership from a "groups" claim, which Keycloak does not put
# in tokens by default; this mapper adds it.
CID=$($K get clients -r "${KC_REALM}" -q clientId="${KC_CLIENT}" --fields id --format csv --noquotes | tail -n1)
if ! $K get "clients/$CID/protocol-mappers/models" -r "${KC_REALM}" --fields name --format csv --noquotes 2>/dev/null | grep -qx groups; then
  $K create "clients/$CID/protocol-mappers/models" -r "${KC_REALM}" \
    -s name=groups -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."claim.name"=groups' \
    -s 'config."full.path"=false' \
    -s 'config."access.token.claim"=true' \
    -s 'config."id.token.claim"=true' >/dev/null
fi

IFS=',' read -ra US <<< "${KC_USERS}"
IFS=',' read -ra PS <<< "${KC_PWS}"
i=0
for u in "${US[@]}"; do
  UID_=$($K get users -r "${KC_REALM}" -q username="$u" --fields id --format csv --noquotes 2>/dev/null | tail -n1)
  [ -z "$UID_" ] && $K create users -r "${KC_REALM}" -s username="$u" -s enabled=true >/dev/null
  UID_=$($K get users -r "${KC_REALM}" -q username="$u" --fields id --format csv --noquotes | tail -n1)
  $K set-password -r "${KC_REALM}" --userid "$UID_" --new-password "${PS[$i]}" >/dev/null
  i=$((i+1))
done
KCEOF

    echo "[INFO] Realm, client and users configured."
    echo ""
    echo "[INFO] Keycloak issuer : https://${_kc_host}/realms/${CONFLUENT_KEYCLOAK_REALM}"
    echo "[INFO] JWKS           : https://${_kc_host}/realms/${CONFLUENT_KEYCLOAK_REALM}/protocol/openid-connect/certs"
    ;;

*)
    echo "[ERROR] CONFLUENT_MDS_USER_STORE must be LDAP or OAUTH (got '${_store}')." >&2
    exit 1
    ;;
esac

echo ""
echo "[INFO] Identity provider ready. Passwords:"
case "${_store}" in
    LDAP)  echo "[INFO]   oc get secret ${CONFLUENT_LDAP_SECRET} -n ${NS} -o jsonpath='{.data.<user>}' | base64 --decode" ;;
    OAUTH) echo "[INFO]   oc get secret ${CONFLUENT_KEYCLOAK_SECRET} -n ${NS} -o jsonpath='{.data.<user>}' | base64 --decode" ;;
esac
