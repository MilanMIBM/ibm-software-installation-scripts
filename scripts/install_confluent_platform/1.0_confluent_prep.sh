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
# Confluent Platform - preparation
# ------------------------------------------------------------------------------
# Prepares the cluster for the cp-all-in-one stack installed by
# 1.1_confluent_install.sh:
#   - logs in to OpenShift
#   - validates the confluent_vars.sh configuration
#   - creates the target project
#   - creates the registry pull secret (if credentials are configured)
#   - grants the anyuid SCC to the service account (cp-* images run as a fixed uid)
#   - provisions the basic-auth credentials for the web UIs
#   - creates the broker's PersistentVolumeClaim
#
# Options:
#   --regenerate-password   discard the stored basic-auth password and mint a
#                           new one (components must be redeployed afterwards)
# ==============================================================================

REGENERATE_PASSWORD=false
while (( $# > 0 )); do
    case "$1" in
        --regenerate-password) REGENERATE_PASSWORD=true; shift ;;
        -h|--help)
            echo "Usage: $(basename $0) [--regenerate-password]"
            exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
SA="confluent"

# ------------------------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------------------------
_missing=()
for _var in PROJECT_CONFLUENT_SERVER CONFLUENT_VERSION CONFLUENT_REGISTRY \
            CONFLUENT_CONNECT_IMAGE CONFLUENT_CLUSTER_ID CONFLUENT_STORAGE_CLASS \
            CONFLUENT_BROKER_STORAGE_SIZE CONFLUENT_REPLICATION_FACTOR \
            CONFLUENT_BROKER_REPLICAS; do
    [[ -z "${(P)_var:-}" ]] && _missing+=("${_var}")
done
if (( ${#_missing[@]} > 0 )); then
    echo "[ERROR] Missing required variables in cp4d_config/confluent_vars.sh: ${_missing[*]}" >&2
    exit 1
fi

if (( CONFLUENT_REPLICATION_FACTOR > CONFLUENT_BROKER_REPLICAS )); then
    echo "[ERROR] CONFLUENT_REPLICATION_FACTOR (${CONFLUENT_REPLICATION_FACTOR}) exceeds CONFLUENT_BROKER_REPLICAS (${CONFLUENT_BROKER_REPLICAS})." >&2
    exit 1
fi

# The KRaft cluster id must be a 16-byte UUID in url-safe base64 without
# padding (22 chars). Catch a malformed value here rather than in a
# CrashLoopBackOff when the broker fails to format its log dir.
if [[ ! "${CONFLUENT_CLUSTER_ID}" =~ ^[A-Za-z0-9_-]{22}$ ]]; then
    echo "[ERROR] CONFLUENT_CLUSTER_ID must be 22 characters of [A-Za-z0-9_-] (a base64url-encoded 16-byte UUID)." >&2
    echo "[ERROR] Got '${CONFLUENT_CLUSTER_ID}' (${#CONFLUENT_CLUSTER_ID} chars). Generate one with:" >&2
    echo "[ERROR]   python3 -c \"import base64,uuid;print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip('='))\"" >&2
    exit 1
fi

if ! oc get storageclass "${CONFLUENT_STORAGE_CLASS}" &>/dev/null; then
    echo "[ERROR] StorageClass '${CONFLUENT_STORAGE_CLASS}' not found on the cluster." >&2
    echo "[ERROR] Available storage classes:" >&2
    oc get storageclass -o name >&2
    exit 1
fi

echo "[INFO] Configuration validated. Installing Confluent Platform ${CONFLUENT_VERSION} into project '${NS}'."

# ------------------------------------------------------------------------------
# Project
# ------------------------------------------------------------------------------
oc create namespace "${NS}" --dry-run=client -o yaml | oc apply -f -
oc project "${NS}" >/dev/null

# ------------------------------------------------------------------------------
# Service account + registry pull secret
# ------------------------------------------------------------------------------
oc create serviceaccount "${SA}" -n "${NS}" --dry-run=client -o yaml | oc apply -f -

if [[ -n "${CONFLUENT_REGISTRY_USER:-}" ]]; then
    _registry_host="${CONFLUENT_REGISTRY%%/*}"
    oc create secret docker-registry "${CONFLUENT_PULL_SECRET}" \
        --docker-server="${_registry_host}" \
        --docker-username="${CONFLUENT_REGISTRY_USER}" \
        --docker-password="${CONFLUENT_REGISTRY_PASSWORD}" \
        -n "${NS}" \
        --dry-run=client -o yaml | oc apply -f -
    oc secrets link "${SA}" "${CONFLUENT_PULL_SECRET}" --for=pull -n "${NS}"
    echo "[INFO] Registry pull secret '${CONFLUENT_PULL_SECRET}' created for ${_registry_host} and linked to serviceaccount/${SA}."
else
    echo "[INFO] CONFLUENT_REGISTRY_USER is empty - pulling anonymously from ${CONFLUENT_REGISTRY}."
fi

# ------------------------------------------------------------------------------
# SCC - the confluentinc/cp-* images run as a fixed non-root uid (appuser),
# which the default restricted-v2 SCC forbids.
# ------------------------------------------------------------------------------
oc adm policy add-scc-to-user anyuid -z "${SA}" -n "${NS}"
echo "[INFO] Granted anyuid SCC to serviceaccount/${SA} in ${NS}."

# ------------------------------------------------------------------------------
# Basic-auth credentials for the web UIs
# ------------------------------------------------------------------------------
# Upstream cp-all-in-one exposes Control Center, Prometheus and Alertmanager
# with no authentication whatsoever; its only secured variant is
# cp-all-in-one-security/oauth, which requires a Keycloak IdP. We use HTTP basic
# auth instead, which every one of those three components supports natively.
#
# The password is generated once and stored in the '${CONFLUENT_AUTH_SECRET}'
# secret, then reused on later runs so redeploys don't invalidate the
# credentials people already have.
: "${CONFLUENT_AUTH_MODE:=openshift}"
if [[ "${CONFLUENT_AUTH_ENABLED}" == "true" && "${CONFLUENT_AUTH_MODE}" == "basic" ]]; then
    _auth_user="${CONFLUENT_AUTH_USERNAME}"
    if [[ -z "${_auth_user}" ]]; then
        echo "[ERROR] CONFLUENT_AUTH_USERNAME is empty (it defaults to \$OCP_USERNAME)." >&2
        exit 1
    fi

    # bcrypt is what the C3 nginx auth-gateway requires for its htpasswd file.
    # htpasswd ships with Apache tools and is the only dependency here; the
    # python bcrypt module is not installed in this repo's venv.
    if ! command -v htpasswd >/dev/null 2>&1; then
        echo "[ERROR] 'htpasswd' is required to hash the basic-auth password but was not found." >&2
        echo "[ERROR] Install it with: brew install httpd   (macOS)  |  dnf install httpd-tools  (RHEL)" >&2
        exit 1
    fi

    _existing_pw="$(oc get secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode 2>/dev/null || true)"

    if [[ -n "${CONFLUENT_AUTH_PASSWORD}" ]]; then
        _auth_pw="${CONFLUENT_AUTH_PASSWORD}"
        _pw_origin="taken from CONFLUENT_AUTH_PASSWORD"
    elif $REGENERATE_PASSWORD || [[ -z "${_existing_pw}" ]]; then
        # Alphanumeric plus a small punctuation set: strong, but safe to paste
        # into a URL, a shell, or a YAML file without quoting surprises.
        #
        # Read a bounded chunk BEFORE filtering. Piping /dev/urandom into `tr`
        # and closing the pipe with `head -c` kills tr with SIGPIPE, which
        # `set -o pipefail` turns into exit 141 and aborts the script. 4096
        # random bytes yield far more than enough usable characters.
        _auth_pw="$(LC_ALL=C head -c 4096 /dev/urandom \
            | LC_ALL=C tr -dc 'A-Za-z0-9._~-' \
            | cut -c1-"${CONFLUENT_AUTH_PASSWORD_LENGTH}")"
        if $REGENERATE_PASSWORD && [[ -n "${_existing_pw}" ]]; then
            _pw_origin="regenerated (previous password discarded)"
            echo "[WARN] Regenerating the basic-auth password. Redeploy the components afterwards:"
            echo "[WARN]   oc rollout restart deployment -n ${NS} -l app.kubernetes.io/part-of=confluent"
        else
            _pw_origin="generated"
        fi
    else
        _auth_pw="${_existing_pw}"
        _pw_origin="reused from existing secret"
    fi

    if (( ${#_auth_pw} < 16 )); then
        echo "[WARN] Basic-auth password is only ${#_auth_pw} characters; 16 or more is recommended."
    fi

    # bcrypt hash for the C3 nginx auth-gateway's htpasswd file.
    _auth_bcrypt="$(htpasswd -bnBC 10 "${_auth_user}" "${_auth_pw}" 2>/dev/null | cut -d: -f2)"
    # A `case` glob, not [[ =~ ]]: in zsh an unquoted \$ inside a regex is not
    # treated as a literal '$', so the pattern never matches a real bcrypt hash.
    case "${_auth_bcrypt}" in
        \$2[aby]\$*) ;;
        *)
            echo "[ERROR] htpasswd did not produce a bcrypt hash (got: '${_auth_bcrypt}')." >&2
            exit 1 ;;
    esac

    oc create secret generic "${CONFLUENT_AUTH_SECRET}" \
        --from-literal=username="${_auth_user}" \
        --from-literal=password="${_auth_pw}" \
        --from-literal=bcrypt="${_auth_bcrypt}" \
        -n "${NS}" \
        --dry-run=client -o yaml | oc apply -f -

    echo "[INFO] Basic-auth credentials ready in secret '${CONFLUENT_AUTH_SECRET}' (${_pw_origin})."
    echo "[INFO]   username: ${_auth_user}"
    echo "[INFO]   password: read it with -"
    echo "[INFO]     oc get secret ${CONFLUENT_AUTH_SECRET} -n ${NS} -o jsonpath='{.data.password}' | base64 --decode"
elif [[ "${CONFLUENT_AUTH_ENABLED}" == "true" && "${CONFLUENT_AUTH_MODE}" == "openshift" ]]; then
    # OpenShift-backed UI auth: the service account doubles as the OAuth client.
    # The redirect reference names the route allowed to receive the callback;
    # without it the login round-trip is rejected as an unregistered client.
    oc annotate serviceaccount "${SA}" -n "${NS}" --overwrite \
        "serviceaccounts.openshift.io/oauth-redirectreference.c3={\"kind\":\"OAuthRedirectReference\",\"apiVersion\":\"v1\",\"reference\":{\"kind\":\"Route\",\"name\":\"control-center\"}}" >/dev/null
    oc adm policy add-cluster-role-to-user auth-delegator -z "${SA}" -n "${NS}" >/dev/null 2>&1 \
        || echo "[WARN] Could not grant the auth-delegator cluster role; oauth-proxy may fail to verify tokens."

    # Session cookie key: generated once, reused so sessions survive redeploys.
    # oauth-proxy requires exactly 16, 24 or 32 bytes for AES.
    _cookie="$(oc get secret "${CONFLUENT_AUTH_SECRET}-oauth" -n "${NS}" \
        -o jsonpath='{.data.cookie-secret}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
    if [[ -z "${_cookie}" ]]; then
        _cookie="$(LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32)"
        _cookie_origin="generated"
    else
        _cookie_origin="reused"
    fi
    oc create secret generic "${CONFLUENT_AUTH_SECRET}-oauth" \
        --from-literal=cookie-secret="${_cookie}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null

    echo "[INFO] OpenShift UI auth ready (oauth-proxy; session key ${_cookie_origin})."
    echo "[INFO]   Users sign in with their OpenShift accounts."
    echo "[INFO]   Grant access with: oc policy add-role-to-user view <user> -n ${NS}"
else
    echo "[WARN] CONFLUENT_AUTH_ENABLED=false - the web UIs will be exposed without authentication."
fi

# ------------------------------------------------------------------------------
# SASL credentials for Kafka clients
# ------------------------------------------------------------------------------
# The admin credential every platform component authenticates as. SCRAM entries
# must exist in Kafka metadata before the brokers come up as SASL, but on a
# fresh install there is no cluster to register them against yet - so only the
# secret is created here. 1.1 registers the SCRAM users once the brokers are up,
# on the still-PLAINTEXT listener, before switching the listeners over.
: "${CONFLUENT_SASL_ENABLED:=true}"
: "${CONFLUENT_SASL_ADMIN_USER:=confluent-admin}"
: "${CONFLUENT_SASL_SECRET:=confluent-sasl}"
: "${CONFLUENT_SASL_CLIENTS:=app-client}"

if [[ "${CONFLUENT_SASL_ENABLED}" == "true" ]]; then
    _sasl_args=()
    _sasl_new=0
    for _u in "${CONFLUENT_SASL_ADMIN_USER}" ${=CONFLUENT_SASL_CLIENTS//,/ }; do
        _p="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" \
            -o jsonpath="{.data.${_u}}" 2>/dev/null | base64 --decode 2>/dev/null || true)"
        if [[ -z "${_p}" ]]; then
            _p="$(LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9._~-' | cut -c1-24)"
            _sasl_new=$(( _sasl_new + 1 ))
        fi
        _sasl_args+=(--from-literal="${_u}=${_p}")
    done
    oc create secret generic "${CONFLUENT_SASL_SECRET}" "${_sasl_args[@]}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null
    echo "[INFO] SASL credentials ready in secret '${CONFLUENT_SASL_SECRET}' (${_sasl_new} newly generated)."
    echo "[INFO]   admin: ${CONFLUENT_SASL_ADMIN_USER}   clients: ${CONFLUENT_SASL_CLIENTS}"
else
    echo "[WARN] CONFLUENT_SASL_ENABLED=false - Kafka will accept unauthenticated clients."
fi

# ------------------------------------------------------------------------------
# Monitoring network policy
# ------------------------------------------------------------------------------
# Prometheus and Alertmanager run unauthenticated, matching upstream
# cp-all-in-one: their images take no credentials and C3 queries them with
# none. Neither gets a route, so they are pod-network-only - but OpenShift
# permits cross-namespace pod traffic by default, which would let any pod on
# the cluster read the metrics and, more importantly, POST to Alertmanager's
# API to create silences.
#
# Restricting ingress to the Confluent pods closes that without introducing a
# credential to render, rotate, or get wrong. The selector covers both callers:
# C3's queries and the brokers' OTLP push both carry part-of=confluent.
#
# Set CONFLUENT_MONITORING_NETWORK_POLICY=false if something outside this
# namespace must scrape these (a cluster monitoring stack, an external
# Grafana); that traffic would otherwise be dropped.
: "${CONFLUENT_MONITORING_NETWORK_POLICY:=true}"
# Defaulted rather than assumed present: set -u is active, and a config file
# generated before this key existed would otherwise abort the run.
: "${CONFLUENT_INSTALL_CONTROL_CENTER:=true}"
if [[ "${CONFLUENT_INSTALL_CONTROL_CENTER}" == "true" \
   && "${CONFLUENT_MONITORING_NETWORK_POLICY}" == "true" ]]; then
    oc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: monitoring-internal
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: confluent
spec:
  podSelector:
    matchExpressions:
      - key: app
        operator: In
        values: [prometheus, alertmanager]
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/part-of: confluent
EOF
    echo "[INFO] NetworkPolicy 'monitoring-internal' applied: Prometheus/Alertmanager accept traffic from Confluent pods only."
else
    oc delete networkpolicy monitoring-internal -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
    if [[ "${CONFLUENT_INSTALL_CONTROL_CENTER}" == "true" ]]; then
        echo "[WARN] CONFLUENT_MONITORING_NETWORK_POLICY=false - Prometheus/Alertmanager are reachable from any pod on the cluster."
    fi
fi

# ------------------------------------------------------------------------------
# Broker storage
# ------------------------------------------------------------------------------
# No PVC is created here: the broker StatefulSet declares a volumeClaimTemplate
# so each broker gets its own ${CONFLUENT_BROKER_STORAGE_SIZE} claim. Verify the
# storage class can bind that shape instead.
if [[ "$(oc get storageclass "${CONFLUENT_STORAGE_CLASS}" -o jsonpath='{.provisioner}' 2>/dev/null)" == "kubernetes.io/no-provisioner" ]]; then
    echo "[WARN] StorageClass '${CONFLUENT_STORAGE_CLASS}' has no dynamic provisioner;" \
         "${CONFLUENT_BROKER_REPLICAS} broker PVC(s) must be pre-provisioned manually." >&2
fi

echo "[INFO] Broker storage: ${CONFLUENT_BROKER_REPLICAS} x ${CONFLUENT_BROKER_STORAGE_SIZE} from '${CONFLUENT_STORAGE_CLASS}' (created by the StatefulSet)."
echo "[INFO] Preparation complete. Run 1.1_confluent_install.sh next."
