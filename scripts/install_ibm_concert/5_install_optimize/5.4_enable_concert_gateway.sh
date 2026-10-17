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
# 5.4 Switch Turbonomic to Concert mode (IBM's Optimize step 2, second half)
# ------------------------------------------------------------------------------
# What IBM's Optimize page does with charts_platform_gw_v1_xl_cr.yaml, for
# OpenShift:
#   1. TLS secret nginx-ingressgateway-certs, which nginx and concert-gateway
#      both serve. Generated from a private CA (secret optimize-gateway-ca) for
#      both services and the route host; renewed when the names change or it
#      expires within 30 days. A secret you created yourself is kept - it must
#      then carry ca.crt, which the route uses to verify the gateway.
#   2. The Xl in Concert mode: concert-gateway towards the Hub, productList
#      turbonomic, Turbonomic's UI off, Concert JWT header authentication.
#      Re-applied on every run, so config changes land here.
#   3. IBM's restart of api, auth, consul, nginx and oauth2 - only when the
#      spec or the certificate changed.
#   4. A Route "optimize" to concert-gateway. IBM's sample exposes the gateway
#      through a LoadBalancer Service and an nginx Ingress, which clusters
#      without a load balancer (bare metal, TechZone) cannot serve.
#      CONCERT_OPTIMIZE_ROUTE_TERMINATION=reencrypt (default) gives browsers
#      the router's certificate, like Concert's own routes, and verifies the
#      gateway with the CA from step 1; passthrough (what the chart's own
#      OpenShift route does) shows the gateway's certificate instead - use it
#      if the route answers 503 because the gateway does not serve step 1's.
# ==============================================================================

concert_product_enabled optimize || { concert_info "Optimize is not selected - nothing to do."; exit 0; }

eval "${OC_LOGIN}"
NS="$(concert_optimize_namespace)"
oc get xl "${CONCERT_OPTIMIZE_XL}" -n "${NS}" >/dev/null 2>&1 \
    || concert_die "No Xl ${NS}/${CONCERT_OPTIMIZE_XL} - run 5.2_deploy_turbonomic.sh and 5.3_initialize_turbonomic.sh first."
HOST="$(concert_optimize_route_host)" \
    || concert_die "Cannot read the cluster's apps domain - set CONCERT_OPTIMIZE_ROUTE_HOSTNAME."

STAGE="$(concert_private_tmpdir)"
trap 'rm -rf "${STAGE}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

# --- 1. TLS -----------------------------------------------------------------------
TLS="${CONCERT_OPTIMIZE_TLS_SECRET}"
CA="${CONCERT_OPTIMIZE_CA_SECRET}"
SANS=("concert-gateway.${NS}.svc" "concert-gateway.${NS}.svc.cluster.local"
      "nginx.${NS}.svc" "nginx.${NS}.svc.cluster.local" "${HOST}")
SAN_LIST="${(j:,:)SANS}"
TLS_CHANGED=false

_secret_field() {   # <secret> <jsonpath>
    oc get secret "$1" -n "${NS}" -o jsonpath="$2" 2>/dev/null || true
}

if oc get secret "${TLS}" -n "${NS}" >/dev/null 2>&1 \
   && [[ "$(_secret_field "${TLS}" '{.metadata.labels.app\.kubernetes\.io/managed-by}')" != "${CONCERT_MANAGED_BY}" ]]; then
    CA_PEM="$(_secret_field "${TLS}" '{.data.ca\.crt}' | concert_b64d)"
    [[ -n "${CA_PEM}" ]] || concert_die "Secret ${NS}/${TLS} was not created by these scripts and has no ca.crt - add its CA as ca.crt (the route verifies the gateway with it), or delete the secret so 5.4 generates one."
    concert_info "Keeping your TLS secret ${NS}/${TLS}."
else
    if ! oc get secret "${CA}" -n "${NS}" >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=Concert Optimize gateway CA" \
            -keyout "${STAGE}/ca.key" -out "${STAGE}/ca.crt" 2>/dev/null
        oc create secret tls "${CA}" -n "${NS}" --cert="${STAGE}/ca.crt" --key="${STAGE}/ca.key" >/dev/null
        oc label secret "${CA}" -n "${NS}" "app.kubernetes.io/managed-by=${CONCERT_MANAGED_BY}" --overwrite >/dev/null
        concert_info "CA secret ${NS}/${CA} created."
    fi
    _secret_field "${CA}" '{.data.tls\.crt}' | concert_b64d > "${STAGE}/ca.crt"
    (umask 077; _secret_field "${CA}" '{.data.tls\.key}' | concert_b64d > "${STAGE}/ca.key")
    CA_PEM="$(<"${STAGE}/ca.crt")"

    _secret_field "${TLS}" '{.data.tls\.crt}' | concert_b64d > "${STAGE}/current.crt"
    if [[ "$(_secret_field "${TLS}" '{.metadata.annotations.concert\.ibm\.com/optimize-sans}')" == "${SAN_LIST}" ]] \
       && openssl x509 -checkend 2592000 -noout -in "${STAGE}/current.crt" >/dev/null 2>&1; then
        concert_info "TLS secret ${NS}/${TLS} is current."
    else
        san_ext=()
        for s in "${SANS[@]}"; do san_ext+=("DNS:${s}"); done
        print -r -- "subjectAltName=${(j:,:)san_ext}" > "${STAGE}/ext.cnf"
        print -r -- "extendedKeyUsage=serverAuth" >> "${STAGE}/ext.cnf"
        print -r -- "keyUsage=digitalSignature,keyEncipherment" >> "${STAGE}/ext.cnf"
        openssl req -newkey rsa:2048 -nodes -subj "/CN=concert-gateway.${NS}.svc" \
            -keyout "${STAGE}/tls.key" -out "${STAGE}/tls.csr" 2>/dev/null
        openssl x509 -req -in "${STAGE}/tls.csr" -CA "${STAGE}/ca.crt" -CAkey "${STAGE}/ca.key" -CAcreateserial \
            -days 825 -sha256 -extfile "${STAGE}/ext.cnf" -out "${STAGE}/tls.crt" 2>/dev/null
        oc create secret generic "${TLS}" -n "${NS}" --type=kubernetes.io/tls \
            --from-file=tls.crt="${STAGE}/tls.crt" --from-file=tls.key="${STAGE}/tls.key" --from-file=ca.crt="${STAGE}/ca.crt" \
            --dry-run=client -o yaml \
            | oc label -f - --local --dry-run=client -o yaml "app.kubernetes.io/managed-by=${CONCERT_MANAGED_BY}" \
            | oc annotate -f - --local --dry-run=client -o yaml "concert.ibm.com/optimize-sans=${SAN_LIST}" \
            | oc apply -f - >/dev/null
        TLS_CHANGED=true
        concert_info "TLS secret ${NS}/${TLS} issued for ${SAN_LIST}."
    fi
fi

# --- 2. Xl in Concert mode ----------------------------------------------------------
FSGROUP=""
if [[ "${CONCERT_OPTIMIZE_SCC:-restricted}" != anyuid ]]; then
    FSGROUP="$(concert_optimize_fsgroup)" \
        || concert_die "Namespace ${NS} has no UID range annotation - set CONCERT_OPTIMIZE_SCC=anyuid and re-run 5.1."
fi
HASH="$(concert_optimize_render_cr concert "${STAGE}/xl.json" "${FSGROUP}")"
cp "${STAGE}/xl.json" "${CONCERT_CONFIG_DIR}/optimize-xl.json"
OLD_HASH="$(concert_optimize_xl_annotation "${CONCERT_OPTIMIZE_HASH_ANNOTATION}")"
BEFORE="$(concert_optimize_release_digest)"

oc apply -f "${STAGE}/xl.json" >/dev/null
concert_info "Xl ${NS}/${CONCERT_OPTIMIZE_XL} applied (Concert mode, Hub $(concert_optimize_hub_url), spec ${HASH}; copy in configs/concert_config/optimize-xl.json)."

_rolled_out() {
    local now
    now="$(concert_optimize_release_digest)"
    [[ -n "${now}" && "${now}" != "${BEFORE}" ]]
}
SPEC_CHANGED=false
if [[ "${OLD_HASH}" != "${HASH}" ]]; then
    SPEC_CHANGED=true
    concert_wait_for 1200 "the t8c-operator to roll out the new spec" _rolled_out \
        || concert_warn "The deployed Helm manifest did not change - continuing (oc logs deploy/t8c-operator -n ${NS})."
fi
concert_optimize_wait_xl_deployed 1800
concert_optimize_wait_deployments 2700 concert-gateway api auth consul nginx oauth2

# --- 3. IBM's restarts ------------------------------------------------------------
if ${SPEC_CHANGED} || ${TLS_CHANGED}; then
    restart=(api auth consul nginx oauth2)
    ${TLS_CHANGED} && restart+=(concert-gateway)
    for d in "${restart[@]}"; do
        oc rollout restart "deployment/${d}" -n "${NS}" >/dev/null
    done
    concert_info "Restarted ${restart[*]} - waiting for the rollouts."
    for d in "${restart[@]}"; do
        oc rollout status "deployment/${d}" -n "${NS}" --timeout=1800s >/dev/null
    done
fi

# --- 4. Route -----------------------------------------------------------------------
TERMINATION="${CONCERT_OPTIMIZE_ROUTE_TERMINATION:-reencrypt}"
[[ "${TERMINATION}" == (reencrypt|passthrough) ]] \
    || concert_die "CONCERT_OPTIMIZE_ROUTE_TERMINATION must be reencrypt or passthrough."
# oc apply would keep a destinationCACertificate from an earlier reencrypt run
if [[ "${TERMINATION}" == passthrough ]] && [[ -n "$(oc get route "${CONCERT_OPTIMIZE_ROUTE}" -n "${NS}" \
        -o jsonpath='{.spec.tls.destinationCACertificate}' 2>/dev/null || true)" ]]; then
    oc delete route "${CONCERT_OPTIMIZE_ROUTE}" -n "${NS}" >/dev/null
fi
jq -n --arg ns "${NS}" --arg name "${CONCERT_OPTIMIZE_ROUTE}" --arg host "${HOST}" --arg ca "${CA_PEM}" \
      --arg mb "${CONCERT_MANAGED_BY}" --arg term "${TERMINATION}" '{
    apiVersion: "route.openshift.io/v1", kind: "Route",
    metadata: {name: $name, namespace: $ns,
               labels: {"app.kubernetes.io/managed-by": $mb},
               annotations: {"haproxy.router.openshift.io/timeout": "300s"}},
    spec: {host: $host,
           to: {kind: "Service", name: "concert-gateway", weight: 100},
           port: {targetPort: "https-nginx"},
           tls: ({termination: $term, insecureEdgeTerminationPolicy: "Redirect"}
                 + (if $term == "reencrypt" then {destinationCACertificate: $ca} else {} end)),
           wildcardPolicy: "None"}}' | oc apply -f - >/dev/null
_route_admitted() {
    [[ "$(oc get route "${CONCERT_OPTIMIZE_ROUTE}" -n "${NS}" \
        -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null)" == True ]]
}
concert_wait_for 300 "route ${NS}/${CONCERT_OPTIMIZE_ROUTE} admitted" _route_admitted

code="$(curl -sk -o /dev/null --max-time 15 -w '%{http_code}' "https://${HOST}/" || true)"
concert_info "Optimize gateway: https://${HOST} (HTTP ${code}, ${TERMINATION})"
[[ "${code}" == 503 && "${TERMINATION}" == reencrypt ]] \
    && concert_warn "HTTP 503 through the reencrypt route - if concert-gateway is up, it may not serve ${TLS}: try CONCERT_OPTIMIZE_ROUTE_TERMINATION=passthrough and re-run 5.4."
concert_info "Next: 5.5_attach_optimize_to_hub.sh"
