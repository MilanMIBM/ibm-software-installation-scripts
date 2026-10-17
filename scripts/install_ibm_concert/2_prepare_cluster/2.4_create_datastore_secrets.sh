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
# 2.4 IBM's external data store secrets
# ------------------------------------------------------------------------------
# IBM's installer decides "external vs built-in" ONLY by whether these secrets
# exist in the product namespaces when a product is first installed - and the
# choice cannot be changed afterwards. This is the single place that writes
# them, from the provisioned servers (2.3.x) or the existing-server values:
#
#   hub        app-cfg-byo-secret (+ app-cfg-byo-tls)       Keycloak DB
#   concert    concert-appdb-creds, concert-configdb-creds  (both or neither)
#              concert-lzbucket-creds, concert-elbucket-creds
#              concert-neo4j-creds                          (VEIAS / graph)
#   dataapps   dataapps-database-creds, dataapps-redis-creds
#   workflows  cw-secrets (MYSQLDB_* / POSTGRESQL_* / CW_* / RABBITMQ_*)
#
# With cross-product integration (ITOM) and external Postgres, also the AI
# databases IBM's 3.1.0 installer only wires for its built-in Postgres:
#   hub        app-cfg-oob-secret (IBM's; 4 keys merged in)  ITOM DB
#              ITOM's deploy-k8s.sh builds itom-secrets from OOB_POSTGRES_USER/
#              _PASSWORD + KC_DB_URL_HOST/_DATABASE and stops when they are
#              empty. Keycloak and solis-core load app-cfg-byo-secret after
#              this secret, so their own database settings are unaffected.
#   concert    rojacore-secrets (COORDINATORDB_*)            AI coordinator DB
#              mounted (optional) by ibm-roja-ai-coordinator; nothing else
#              creates it in external-DB mode.
#
# A consumer switched to internal gets its secret removed (only if these
# scripts created it) - safe before the first install only.
# ==============================================================================

eval "${OC_LOGIN}"

DS_NS="${PROJECT_CONCERT_DATASTORES}"

_require_ns() {
    oc get namespace "$1" >/dev/null 2>&1 || concert_die "Namespace $1 does not exist - run 2.1_create_projects.sh first."
}

# Delete a secret only if these scripts created it.
_remove_managed() {   # <namespace> <name>
    local owner
    oc get secret "$2" -n "$1" >/dev/null 2>&1 || return 0
    owner="$(oc get secret "$2" -n "$1" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
    if [[ "${owner}" == "${CONCERT_MANAGED_BY}" ]]; then
        oc delete secret "$2" -n "$1" >/dev/null
        concert_info "Removed ${1}/${2} (consumer set to internal)."
    else
        concert_warn "${1}/${2} exists but was not created by these scripts - left as is (IBM will treat that store as external)."
    fi
}

_cred() {   # <key> - a generated credential that 2.3.x must have created
    local v
    v="$(concert_ds_cred_get "$1")"
    [[ -n "${v}" ]] || concert_die "Credential $1 not found in ${DS_NS}/${CONCERT_DS_CRED_SECRET} - run the 2.3 provisioning step first."
    print -r -- "${v}"
}

_tf() { concert_is_true "$1" && print -r -- true || print -r -- false; }

# --- PostgreSQL connection ----------------------------------------------------------------
if concert_ds_server_needed POSTGRES; then
    if [[ "$(concert_ds_server_provider POSTGRES)" == provision ]]; then
        PG_HOST="concert-pg-rw.${DS_NS}.svc.cluster.local"
        PG_PORT=5432
        PG_SSLMODE=require
        PG_SECURE="$(_tf "${CONCERT_DS_PG_SECURE:-true}")"
    else
        PG_HOST="${CONCERT_DS_PG_HOST}"
        PG_PORT="${CONCERT_DS_PG_PORT:-5432}"
        PG_SSLMODE="${CONCERT_DS_PG_SSLMODE:-require}"
        [[ "${PG_SSLMODE}" == disable ]] && PG_SECURE=false || PG_SECURE=true
    fi
fi

# --- S3 bucket values ------------------------------------------------------------------------
# _s3 <claim/bucket name> -> sets S3_HOST S3_PORT S3_BUCKET S3_ACCESS S3_SECRET
_s3() {
    if [[ "$(concert_ds_server_provider S3)" == provision ]]; then
        local cm
        cm="$(oc get configmap "$1" -n "${DS_NS}" -o json 2>/dev/null)" \
            || concert_die "Bucket claim $1 not found in ${DS_NS} - run 2.3.4_provision_buckets.sh."
        S3_HOST="$(jq -r '.data.BUCKET_HOST' <<<"${cm}")"
        S3_PORT="${CONCERT_DS_S3_PORT:-$(jq -r '.data.BUCKET_PORT' <<<"${cm}")}"
        S3_BUCKET="$(jq -r '.data.BUCKET_NAME' <<<"${cm}")"
        S3_ACCESS="$(oc get secret "$1" -n "${DS_NS}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | concert_b64d)"
        S3_SECRET="$(oc get secret "$1" -n "${DS_NS}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | concert_b64d)"
    else
        S3_HOST="${CONCERT_DS_S3_HOST}"
        S3_PORT="${CONCERT_DS_S3_PORT:-}"
        S3_BUCKET="$1"
        S3_ACCESS="${CONCERT_DS_S3_ACCESS_KEY}"
        S3_SECRET="${CONCERT_DS_S3_SECRET_KEY}"
    fi
}
S3_SECURE="$(_tf "${CONCERT_DS_S3_SECURE:-true}")"

# ============================================================================
# Hub / Keycloak
# ============================================================================
if concert_product_enabled hub; then
    HUB_NS="${PROJECT_CONCERT_HUB}"
    _require_ns "${HUB_NS}"
    if concert_ds_consumer_active KEYCLOAK; then
        props=""
        # sslmode only: IBM's own "?ssl=true&sslmode=..." also reaches solis-core
        # (TB_DB_URL_PROPERTIES), whose Go lib/pq sends "ssl" as a server
        # parameter -> "parameter ssl cannot be changed now (55P02)". pgjdbc
        # (Keycloak) enables TLS from sslmode alone.
        [[ "${PG_SECURE}" == true ]] && props="?sslmode=${PG_SSLMODE}"
        if [[ "$(concert_ds_server_provider POSTGRES)" == existing && -n "${CONCERT_DS_PG_CA_CERT:-}" ]]; then
            [[ -f "${CONCERT_DS_PG_CA_CERT}" ]] || concert_die "CONCERT_DS_PG_CA_CERT not found: ${CONCERT_DS_PG_CA_CERT}"
            oc create secret generic app-cfg-byo-tls -n "${HUB_NS}" --from-file=ca.crt="${CONCERT_DS_PG_CA_CERT}" \
                --dry-run=client -o yaml | oc label -f - --local --dry-run=client -o yaml "app.kubernetes.io/managed-by=${CONCERT_MANAGED_BY}" \
                | oc apply -f - >/dev/null
            props="${props}&sslrootcert=/tmp/kc-db/ca.crt"
        fi
        kc_pw="$(_cred PG_PASSWORD_CONCERT_KEYCLOAK)"
        # Hub Keycloak AND solis-core (mounted as TB_DB_*) both use this database.
        concert_apply_secret "${HUB_NS}" app-cfg-byo-secret \
            "KC_DB_URL_HOST=${PG_HOST}" \
            "KC_DB_URL_PORT=${PG_PORT}" \
            "KC_DB_URL_DATABASE=${CONCERT_DS_PG_DB_KEYCLOAK:-keycloak}" \
            "KC_DB_USERNAME=concert_keycloak" \
            "KC_DB_PASSWORD=${kc_pw}" \
            "KC_DB_SCHEMA=public" \
            "KC_DB_URL_PROPERTIES=${props}"

        if concert_product_enabled itom; then
            # ITOM hard-codes port 5432 and sslmode=require (Context Forge).
            [[ "${PG_PORT}" == 5432 ]] || concert_warn "ITOM always connects on port 5432 - PostgreSQL listens on ${PG_PORT}."
            ai_pw="$(_cred PG_PASSWORD_CONCERT_PLATFORM_AI)"
            # IBM owns this secret (Keycloak bootstrap admin): merge, never replace.
            # Created here before the first Hub install, the Hub keeps it and only
            # adds its missing bootstrap keys.
            oc get secret app-cfg-oob-secret -n "${HUB_NS}" >/dev/null 2>&1 || {
                oc create secret generic app-cfg-oob-secret -n "${HUB_NS}" >/dev/null
                oc label secret app-cfg-oob-secret -n "${HUB_NS}" ibmsupport/app=solis-hub >/dev/null
            }
            patch_dir="$(concert_private_tmpdir)"
            jq -n --arg u concert_platform_ai --arg p "${ai_pw}" --arg h "${PG_HOST}" \
                  --arg d "${CONCERT_DS_PG_DB_PLATFORM_AI:-platform_ai}" \
                '{data: {OOB_POSTGRES_USER: ($u|@base64), OOB_POSTGRES_PASSWORD: ($p|@base64),
                         KC_DB_URL_HOST: ($h|@base64), KC_DB_URL_DATABASE: ($d|@base64)}}' > "${patch_dir}/patch.json"
            oc patch secret app-cfg-oob-secret -n "${HUB_NS}" --type=merge --patch-file="${patch_dir}/patch.json" >/dev/null
            rm -rf "${patch_dir}"
            concert_info "ITOM database merged into ${HUB_NS}/app-cfg-oob-secret."
        fi
    else
        _remove_managed "${HUB_NS}" app-cfg-byo-secret
        _remove_managed "${HUB_NS}" app-cfg-byo-tls
    fi
fi

# ============================================================================
# Concert
# ============================================================================
if concert_product_enabled concert; then
    C_NS="${PROJECT_CONCERT}"
    _require_ns "${C_NS}"
    if concert_ds_consumer_active CONCERT_DB; then
        pw="$(_cred PG_PASSWORD_CONCERT_APP)"
        for db in appdb configdb; do
            P="${db:u}"
            concert_apply_secret "${C_NS}" "concert-${db}-creds" \
                "${P}_HOST=${PG_HOST}" "${P}_PORT=${PG_PORT}" "${P}_DBNAME=${db}" \
                "${P}_USER=concert_app" "${P}_PASSWORD=${pw}" "${P}_SECURE=${PG_SECURE}"
        done
    else
        _remove_managed "${C_NS}" concert-appdb-creds
        _remove_managed "${C_NS}" concert-configdb-creds
    fi

    if concert_ds_consumer_active CONCERT_DB && concert_product_enabled itom; then
        co_pw="$(_cred PG_PASSWORD_CONCERT_COORDINATOR)"
        concert_apply_secret "${C_NS}" rojacore-secrets \
            "COORDINATORDB_HOST=${PG_HOST}" "COORDINATORDB_PORT=${PG_PORT}" \
            "COORDINATORDB_DBNAME=${CONCERT_DS_PG_DB_COORDINATOR:-concert_coordinator}" \
            "COORDINATORDB_USER=concert_coordinator" "COORDINATORDB_PASSWORD=${co_pw}"
    else
        _remove_managed "${C_NS}" rojacore-secrets
    fi

    if concert_ds_consumer_active CONCERT_S3 && [[ "$(concert_ds_server_provider S3)" == provision ]]; then
        # The MCG S3 service is signed by the OpenShift service CA, which Concert's
        # Go services (SSL_CERT_FILE bundle) do not trust: uploads to the landing
        # zone fail (CNCRTRCOELO10013E) and discovery/ingestion jobs never run.
        # IBM appends every cert in app-cfg-custom-ca-certs to that bundle (it only
        # creates the Secret when missing, so pre-creating it here is safe).
        svc_ca="$(oc get configmap openshift-service-ca.crt -n "${C_NS}" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true)"
        [[ -n "${svc_ca}" ]] || concert_die "configmap openshift-service-ca.crt not found in ${C_NS}."
        have="$(oc get secret app-cfg-custom-ca-certs -n "${C_NS}" -o jsonpath='{.data.openshift-service-ca\.crt}' 2>/dev/null | concert_b64d || true)"
        if [[ "${have}" != "${svc_ca}" ]]; then
            oc get secret app-cfg-custom-ca-certs -n "${C_NS}" >/dev/null 2>&1 \
                || oc create secret generic app-cfg-custom-ca-certs -n "${C_NS}" >/dev/null
            oc label secret app-cfg-custom-ca-certs -n "${C_NS}" ibmsupport/app=roja --overwrite >/dev/null
            oc patch secret app-cfg-custom-ca-certs -n "${C_NS}" --type=merge \
                -p "{\"data\":{\"openshift-service-ca.crt\":\"$(print -rn -- "${svc_ca}" | base64 | tr -d '\n')\"}}" >/dev/null
            concert_info "Added the OpenShift service CA to ${C_NS}/app-cfg-custom-ca-certs."
            if oc get secret app-cfg-internal-tls -n "${C_NS}" >/dev/null 2>&1; then
                "${_CP4D_REPO_ROOT}/scripts/install_ibm_concert/4_post_install/4.4_refresh_concert_ca_bundle.sh"
            fi
        fi
    fi

    if concert_ds_consumer_active CONCERT_S3; then
        for pair in "LZ:${CONCERT_DS_S3_BUCKET_LZ:-concert-lz}:lzbucket" "EL:${CONCERT_DS_S3_BUCKET_EL:-concert-el}:elbucket"; do
            P="${pair%%:*}" rest="${pair#*:}"
            claim="${rest%%:*}" sname="${rest#*:}"
            _s3 "${claim}"
            # IBM's connect-bucket.sh: [[ ${LZ_SECURE} == True* ]] -> https, anything
            # else (including lowercase "true") -> http. Capitalised on purpose.
            concert_apply_secret "${C_NS}" "concert-${sname}-creds" \
                "${P}_HOST=${S3_HOST}" "${P}_PORT=${S3_PORT}" "${P}_BUCKET=${S3_BUCKET}" \
                "${P}_ACCESS_KEY=${S3_ACCESS}" "${P}_SECRET_KEY=${S3_SECRET}" "${P}_SECURE=${(C)S3_SECURE}" \
                "${P}_AUTH_TYPE=${CONCERT_DS_S3_AUTH_TYPE:-}" "${P}_REGION=${CONCERT_DS_S3_AUTH_TYPE:+${CONCERT_DS_S3_REGION:-}}"
        done
    else
        _remove_managed "${C_NS}" concert-lzbucket-creds
        _remove_managed "${C_NS}" concert-elbucket-creds
    fi

    if concert_ds_consumer_active CONCERT_NEO4J; then
        if [[ "$(concert_ds_server_provider NEO4J)" == provision ]]; then
            neo4j_pw="$(_cred NEO4J_PASSWORD)"
            concert_apply_secret "${C_NS}" concert-neo4j-creds \
                "NEO4J_HOST=concert-neo4j.${DS_NS}.svc.cluster.local" "NEO4J_PORT=7687" "NEO4J_TLS=false" \
                "NEO4J_USERNAME=neo4j" "NEO4J_PASSWORD=${neo4j_pw}" "NEO4J_DATABASE=neo4j"
        else
            concert_require_vars CONCERT_DS_NEO4J_HOST CONCERT_DS_NEO4J_USERNAME CONCERT_DS_NEO4J_PASSWORD
            concert_apply_secret "${C_NS}" concert-neo4j-creds \
                "NEO4J_HOST=${CONCERT_DS_NEO4J_HOST}" "NEO4J_PORT=${CONCERT_DS_NEO4J_PORT:-7687}" \
                "NEO4J_TLS=$(_tf "${CONCERT_DS_NEO4J_TLS:-false}")" "NEO4J_USERNAME=${CONCERT_DS_NEO4J_USERNAME}" \
                "NEO4J_PASSWORD=${CONCERT_DS_NEO4J_PASSWORD}" "NEO4J_DATABASE=${CONCERT_DS_NEO4J_DATABASE:-neo4j}"
        fi
    else
        _remove_managed "${C_NS}" concert-neo4j-creds
    fi
fi

# ============================================================================
# Data Apps
# ============================================================================
if concert_product_enabled dataapps; then
    D_NS="${PROJECT_CONCERT_DATAAPPS}"
    _require_ns "${D_NS}"
    if concert_ds_consumer_active DATAAPPS_DB; then
        da_pw="$(_cred PG_PASSWORD_CONCERT_DATAAPPS)"
        concert_apply_secret "${D_NS}" dataapps-database-creds \
            "POSTGRES_HOST=${PG_HOST}" "POSTGRES_PORT=${PG_PORT}" "POSTGRES_DBNAME=${CONCERT_DS_PG_DB_DATAAPPS:-dataapps}" \
            "POSTGRES_USER=concert_dataapps" "POSTGRES_PASSWORD=${da_pw}" \
            "POSTGRES_SECURE=${PG_SECURE}"
    else
        _remove_managed "${D_NS}" dataapps-database-creds
    fi

    if concert_ds_consumer_active DATAAPPS_REDIS; then
        if [[ "$(concert_ds_server_provider REDIS)" == provision ]]; then
            tls=no
            concert_is_true "${CONCERT_DS_REDIS_TLS:-yes}" && tls=yes
            redis_pw="$(_cred REDIS_PASSWORD_DATAAPPS)"
            concert_apply_secret "${D_NS}" dataapps-redis-creds \
                "DA_REDIS_HOST=concert-redis.${DS_NS}.svc.cluster.local" "DA_REDIS_PORT=6379" \
                "DA_REDIS_USER=dataapps" "DA_REDIS_PASSWORD=${redis_pw}" \
                "DA_REDIS_TLS_ENABLED=${tls}" "DA_REDIS_TLS_AUTH_CLIENTS=no"
        else
            concert_require_vars CONCERT_DS_REDIS_HOST CONCERT_DS_REDIS_USER
            concert_apply_secret "${D_NS}" dataapps-redis-creds \
                "DA_REDIS_HOST=${CONCERT_DS_REDIS_HOST}" "DA_REDIS_PORT=${CONCERT_DS_REDIS_PORT:-6379}" \
                "DA_REDIS_USER=${CONCERT_DS_REDIS_USER}" "DA_REDIS_PASSWORD=${CONCERT_DS_REDIS_PASSWORD:-}" \
                "DA_REDIS_TLS_ENABLED=${CONCERT_DS_REDIS_TLS:-yes}" "DA_REDIS_TLS_AUTH_CLIENTS=no"
        fi
    else
        _remove_managed "${D_NS}" dataapps-redis-creds
    fi
fi

# ============================================================================
# Workflows (one secret, independent groups)
# ============================================================================
if concert_product_enabled workflows; then
    W_NS="${PROJECT_CONCERT_WORKFLOWS}"
    _require_ns "${W_NS}"
    kv=()
    if concert_ds_consumer_active WORKFLOWS_MYSQL; then
        if [[ "$(concert_ds_server_provider MYSQL)" == provision ]]; then
            mysql_pw="$(_cred MYSQL_PASSWORD_WORKFLOWS)"
            kv+=("MYSQLDB_HOST=concert-mysql.${DS_NS}.svc.cluster.local" "MYSQLDB_PORT=3306" "MYSQLDB_USER=workflows"
                 "MYSQLDB_PASSWORD=${mysql_pw}" "MYSQLDB_DBNAME=${CONCERT_DS_MYSQL_DBNAME:-pliant}")
        else
            concert_require_vars CONCERT_DS_MYSQL_HOST CONCERT_DS_MYSQL_USER CONCERT_DS_MYSQL_PASSWORD
            kv+=("MYSQLDB_HOST=${CONCERT_DS_MYSQL_HOST}" "MYSQLDB_PORT=${CONCERT_DS_MYSQL_PORT:-3306}" "MYSQLDB_USER=${CONCERT_DS_MYSQL_USER}"
                 "MYSQLDB_PASSWORD=${CONCERT_DS_MYSQL_PASSWORD}" "MYSQLDB_DBNAME=${CONCERT_DS_MYSQL_DBNAME:-pliant}")
        fi
    fi
    if concert_ds_consumer_active WORKFLOWS_POSTGRES; then
        wf_pw="$(_cred PG_PASSWORD_CONCERT_WORKFLOWS)"
        kv+=("POSTGRESQL_HOST=${PG_HOST}" "POSTGRESQL_PORT=${PG_PORT}" "POSTGRESQL_USER=concert_workflows"
             "POSTGRESQL_PASSWORD=${wf_pw}" "POSTGRESQL_DBNAME=${CONCERT_DS_PG_DB_WORKFLOWS:-pliant_ai}")
    fi
    if concert_ds_consumer_active WORKFLOWS_S3; then
        _s3 "${CONCERT_DS_S3_BUCKET_WORKFLOWS:-concert-workflows}"
        # Workflows' Node.js services force SSL and trust only public CAs, so the
        # MCG service certificate (OpenShift service CA) fails with
        # SELF_SIGNED_CERT_IN_CHAIN. Use the MCG route when its certificate is
        # publicly trusted (CONCERT_DS_S3_CW_ENDPOINT=auto|route|service).
        if [[ "$(concert_ds_server_provider S3)" == provision ]]; then
            mode="${CONCERT_DS_S3_CW_ENDPOINT:-auto}"
            route="$(oc get route s3 -n openshift-storage -o jsonpath='{.spec.host}' 2>/dev/null || true)"
            if [[ "${mode}" == auto ]]; then
                if [[ -n "${route}" ]] && curl -s --max-time 10 -o /dev/null "https://${route}/"; then
                    mode=route
                else
                    mode=service
                    concert_warn "Workflows S3: MCG route ${route:-<none>} has no publicly trusted certificate - using the service, which Workflows will likely reject (SELF_SIGNED_CERT_IN_CHAIN). Give the ingress a trusted certificate or set CONCERT_DS_S3_CW_ENDPOINT."
                fi
            fi
            if [[ "${mode}" == route ]]; then
                [[ -n "${route}" ]] || concert_die "CONCERT_DS_S3_CW_ENDPOINT=route but openshift-storage has no 's3' route."
                S3_HOST="${route}" S3_PORT=443
                concert_info "Workflows S3 endpoint: route ${route}:443"
            fi
        fi
        auth="${CONCERT_DS_S3_AUTH_TYPE:-${CONCERT_DS_S3_CW_AUTH_TYPE:-}}"
        [[ "$(concert_ds_server_provider S3)" == provision ]] && auth="${CONCERT_DS_S3_CW_AUTH_TYPE:-}"
        [[ -n "${S3_PORT}" ]] || S3_PORT=443
        kv+=("CW_HOST=${S3_HOST}" "CW_PORT=${S3_PORT}" "CW_BUCKET=${S3_BUCKET}" "CW_ACCESS_KEY=${S3_ACCESS}"
             "CW_SECRET_KEY=${S3_SECRET}" "CW_AUTH_TYPE=${auth}" "CW_REGION=${CONCERT_DS_S3_REGION:-us-east-1}")
        [[ -n "${auth}" ]] || concert_die "CW_AUTH_TYPE is empty - set CONCERT_DS_S3_CW_AUTH_TYPE (Workflows needs all 7 CW_* keys)."
    fi
    if concert_ds_consumer_active WORKFLOWS_RABBITMQ; then
        concert_require_vars CONCERT_DS_RABBITMQ_HOST CONCERT_DS_RABBITMQ_USER CONCERT_DS_RABBITMQ_PASSWORD
        kv+=("RABBITMQ_HOST=${CONCERT_DS_RABBITMQ_HOST}" "RABBITMQ_PORT=${CONCERT_DS_RABBITMQ_PORT:-5672}"
             "RABBITMQ_USER=${CONCERT_DS_RABBITMQ_USER}" "RABBITMQ_PASSWORD=${CONCERT_DS_RABBITMQ_PASSWORD}")
    fi
    if (( ${#kv} )); then
        concert_apply_secret "${W_NS}" cw-secrets "${kv[@]}"
    else
        _remove_managed "${W_NS}" cw-secrets
    fi
fi

concert_info "External data store secrets are in place. IBM fixes this choice at the first install of each product."
