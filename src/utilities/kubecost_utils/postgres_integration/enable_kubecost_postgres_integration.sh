#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Turns on the Kubecost Postgres integration for an instance: the aggregator
# runs Kubecost queries (allocations, assets, cloud costs) every runInterval
# and writes the results to tables in your Postgres database. Rows are keyed
# on name + window, so reruns update rather than duplicate them.
# Kubecost Enterprise: without a linked product key it warns and stops unless
# --force. The database must be reachable from the aggregator, and the user
# needs CREATE, INSERT and UPDATE on it.
#
# Connection (host, port, databaseName, user, password) from, merged in this
# order, later wins:
#   -f <file>     a management-postgres.json; a bare name is also looked up in
#                 configs/kubecost_config/<ns>/ and configs/kubecost_config/.
#                 Also takes creds.json or chart values (global.integrations.
#                 postgres), and may hold runInterval and queryConfigs.
#   -s <secret>   a Secret with key creds.json, or flat keys host, port, dbname,
#                 user|username, password (CloudNativePG/EDB/Crunchy app Secrets)
#   --db-host/--db-port/--db-name/--db-user/--db-password   flags
# Nothing given: configs/kubecost_config/<ns>/<instance>-management-postgres.json,
# else the instance's current connection, else a prompt on a terminal.
#
# The credentials go into a Secret (key creds.json) that the CR names in
# databaseSecretName, so the password stays out of the CR. A -s Secret in the
# instance's namespace that already has creds.json is used as is; anything
# else is copied to <instance>-postgres-creds (re-run after a password change).
# The applied settings are saved to
# configs/kubecost_config/<ns>/<instance>-management-postgres.json.
#
# Queries: --queries <file>, else the file's queryConfigs, else the instance's
# current ones, else allocations by namespace and by cluster plus assets by
# cluster (7d windows). Values are passed to Kubecost's APIs as strings.
#
#   enable_kubecost_postgres_integration.sh [<kubecost name>] [options]
#     -n, --namespace <ns>         default: the namespace holding that Kubecost CR
#   No name: KUBECOST_INSTANCE_NAME from configs/kubecost_config/kubecost_vars.sh,
#   else the only instance on the cluster (asks which one when there are several)
#     -f, --creds-file <file>      management-postgres.json (see above)
#     -s, --secret <name>          Secret with the connection (see above)
#     --secret-namespace <ns>      the -s Secret's namespace (default: the instance's)
#     --db-host <host>             --db-port <port> (default 5432)
#     --db-name <database>         --db-user <user>
#     --db-password <password>     --db-password-stdin (read it from stdin)
#     --target-secret <name>       Secret to write (default <instance>-postgres-creds)
#     --run-interval <duration>    e.g. 30m, 6h (default: kept, else 12h)
#     --queries <file>             queryConfigs JSON ({allocations, assets, cloudCosts})
#     --default-queries            use the default queries, not the current ones
#     --template                   write configs/kubecost_config/<ns>/<instance>-management-
#                                  postgres.json to fill in (kept if present), change nothing
#     --disable                    turn the integration off (Secret kept)
#     --delete-secret              with --disable: also delete the <instance>-postgres-creds Secret
#     --no-check                   skip the TCP check from the aggregator pod
#     --force                      apply even without a linked product key
#     --dry-run                    show the change (password masked), change nothing
#     --no-wait                    don't wait for the rollout and the first run
#     --timeout <seconds>          wait at most this long (default 600)
#     --server/--token/-u/-p       log in first (see ocu_login); otherwise OC_LOGIN
#                                  from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Turns on the Kubecost Postgres/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

CR_NAME=""
NAMESPACE=""
CREDS_FILE=""
SRC_SECRET=""
SRC_SECRET_NS=""
OPT_HOST=""
OPT_PORT=""
OPT_DATABASE=""
OPT_USER=""
OPT_PASSWORD=""
PASSWORD_STDIN=false
TARGET_SECRET=""
RUN_INTERVAL=""
QUERIES_FILE=""
DEFAULT_QUERIES=false
TEMPLATE=false
DISABLE=false
DELETE_SECRET=false
CHECK=true
FORCE=false
DRY_RUN=false
WAIT=true
TIMEOUT=600
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)      NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        -f|--creds-file)     CREDS_FILE="${2:?$1 needs a value}"; shift 2 ;;
        -s|--secret)         SRC_SECRET="${2:?$1 needs a value}"; shift 2 ;;
        --secret-namespace)  SRC_SECRET_NS="${2:?$1 needs a value}"; shift 2 ;;
        --db-host)           OPT_HOST="${2:?$1 needs a value}"; shift 2 ;;
        --db-port)           OPT_PORT="${2:?$1 needs a value}"; shift 2 ;;
        --db-name)           OPT_DATABASE="${2:?$1 needs a value}"; shift 2 ;;
        --db-user)           OPT_USER="${2:?$1 needs a value}"; shift 2 ;;
        --db-password)       OPT_PASSWORD="${2:?$1 needs a value}"; shift 2 ;;
        --db-password-stdin) PASSWORD_STDIN=true; shift ;;
        --target-secret)     TARGET_SECRET="${2:?$1 needs a value}"; shift 2 ;;
        --run-interval)      RUN_INTERVAL="${2:?$1 needs a value}"; shift 2 ;;
        --queries)           QUERIES_FILE="${2:?$1 needs a value}"; shift 2 ;;
        --default-queries)   DEFAULT_QUERIES=true; shift ;;
        --template)          TEMPLATE=true; shift ;;
        --disable)           DISABLE=true; shift ;;
        --delete-secret)     DELETE_SECRET=true; shift ;;
        --no-check)          CHECK=false; shift ;;
        --force)             FORCE=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        --no-wait)           WAIT=false; shift ;;
        --timeout)           TIMEOUT="${2:?$1 needs a value}"; shift 2 ;;
        --server)            LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)             LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)       LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)       LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        -*)                  echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                   [[ -z "${CR_NAME}" ]] || die "Unexpected argument: $1"; CR_NAME="$1"; shift ;;
    esac
done
[[ "${TIMEOUT}" == <-> ]] || die "--timeout needs a number of seconds."
[[ -z "${CREDS_FILE}" || -z "${SRC_SECRET}" ]] || die "Use -f or -s, not both."
[[ "${DELETE_SECRET}" != true || "${DISABLE}" == true ]] || die "--delete-secret goes with --disable."
[[ -z "${RUN_INTERVAL}" || "${RUN_INTERVAL}" =~ '^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$' ]] \
    || die "--run-interval '${RUN_INTERVAL}' is not a duration like 30m, 6h or 1h30m."
if [[ "${PASSWORD_STDIN}" == true ]]; then
    OPT_PASSWORD="$(cat)"
    OPT_PASSWORD="${OPT_PASSWORD%$'\n'}"
    [[ -n "${OPT_PASSWORD}" ]] || die "--db-password-stdin: nothing on stdin."
fi

ocu_login
kc_resolve_instance || exit 1
CR_JSON="$(oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null)" \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
echo "[INFO] Kubecost instance: ${NAMESPACE}/${CR_NAME}"

TARGET_SECRET="${TARGET_SECRET:-${CR_NAME}-postgres-creds}"
SRC_SECRET_NS="${SRC_SECRET_NS:-${NAMESPACE}}"
AGGREGATOR="statefulset/${CR_NAME}-aggregator"
kc_postgres_file "${NAMESPACE}" "${CR_NAME}"; LOCAL_FILE="${REPLY}"
CURRENT_PG="$(jq -c '.spec.global.integrations.postgres // {}' <<<"${CR_JSON}")"
kc_postgres_status "${CR_JSON}" "${NAMESPACE}"

# The chart's commented examples, with this instance's namespace shared out.
DEFAULT_QUERY_CONFIGS="$(jq -cn --arg ns "${NAMESPACE}" '{
    allocations: [
        {databaseTable: "kubecost_allocation_data", window: "7d", aggregate: "namespace",
         idle: "true", shareIdle: "true", shareNamespaces: "\($ns),kube-system", shareLabels: ""},
        {databaseTable: "kubecost_allocation_data_by_cluster", window: "7d", aggregate: "cluster",
         idle: "true", shareIdle: "false", shareNamespaces: "", shareLabels: ""}],
    assets: [{databaseTable: "kubecost_assets_data", window: "7d", aggregate: "cluster"}],
    cloudCosts: []}')"

rel() { print -r -- "${1#${_CP4D_REPO_ROOT}/}"; }

# Waits for the aggregator after a CR patch (<start rev> <start ts>) or restarts it.
roll_out() {   # <cr patch json or ""> <start revision> <start ts>
    if [[ -n "$1" ]]; then
        oc patch "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" --type merge -p "$1" >/dev/null
        echo "[OK] Kubecost CR updated (global.integrations.postgres)."
        [[ "${WAIT}" == true ]] || return 0
        kc_wait_for_release "${CR_NAME}" "${NAMESPACE}" "$2" "$3" "${TIMEOUT}" || exit 1
    else
        # The chart's config checksum doesn't cover a Secret it only names.
        oc rollout restart "${AGGREGATOR}" -n "${NAMESPACE}" >/dev/null
        echo "[OK] CR unchanged; restarted ${AGGREGATOR} to load the new credentials."
        [[ "${WAIT}" == true ]] || return 0
    fi
    echo "[INFO] Waiting for ${AGGREGATOR} (up to ${TIMEOUT}s)..."
    oc rollout status "${AGGREGATOR}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s" 2>&1 | sed 's/^/  /' \
        || die "${AGGREGATOR} did not become ready."
}

# --- Template ------------------------------------------------------------------
if [[ "${TEMPLATE}" == true ]]; then
    if [[ -f "${LOCAL_FILE}" ]]; then
        echo "[OK] $(rel "${LOCAL_FILE}") already exists; kept (delete it to start over)."
    else
        jq -n --argjson q "${DEFAULT_QUERY_CONFIGS}" --arg cr "${CR_NAME}" '{
            _comment: "Kubecost Postgres integration for \($cr). Fill in the connection, then: enable_kubecost_postgres_integration.sh \($cr). The user needs CREATE, INSERT and UPDATE. Query values are strings passed to the Kubecost APIs.",
            host: "<postgres host, e.g. my-db-rw.my-namespace.svc>",
            port: "5432",
            databaseName: "<database>",
            user: "<user>",
            password: "<password>",
            runInterval: "12h",
            queryConfigs: $q}' | _kc_write_private "${LOCAL_FILE}"
        echo "[OK] Template: $(rel "${LOCAL_FILE}")"
    fi
    echo "Fill it in, then: enable_kubecost_postgres_integration.sh ${CR_NAME}"
    exit 0
fi

# --- Disable -------------------------------------------------------------------
if [[ "${DISABLE}" == true ]]; then
    managed_secret=false
    oc get secret "${TARGET_SECRET}" -n "${NAMESPACE}" -o json 2>/dev/null \
        | jq -e '.metadata.labels["kubecost-postgres/managed"] == "true"' >/dev/null && managed_secret=true
    if [[ "${KC_PG_ENABLED}" != true ]]; then
        echo "[OK] The Postgres integration is already off on '${CR_NAME}'."
    elif [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY-RUN] Would set global.integrations.postgres.enabled=false on '${CR_NAME}'."
    else
        start_rev="$(kc_release_revision "${CR_NAME}" "${NAMESPACE}")"
        start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        roll_out '{"spec":{"global":{"integrations":{"postgres":{"enabled":false}}}}}' "${start_rev}" "${start_ts}"
        echo "[OK] Postgres integration off. The tables in the database are left as they are."
    fi
    if [[ "${DELETE_SECRET}" == true ]]; then
        if [[ "${managed_secret}" != true ]]; then
            echo "[INFO] No Secret ${TARGET_SECRET} made by this script; nothing to delete."
        elif [[ "${DRY_RUN}" == true ]]; then
            echo "[DRY-RUN] Would delete Secret ${TARGET_SECRET}."
        else
            oc delete secret "${TARGET_SECRET}" -n "${NAMESPACE}" >/dev/null
            echo "[OK] Secret ${TARGET_SECRET} deleted."
        fi
    fi
    [[ "${DRY_RUN}" == true ]] || kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
    exit 0
fi

# --- Connection ----------------------------------------------------------------
CREDS='{}'
SOURCE=""
USE_SECRET=""   # an existing Secret used as is
if [[ -n "${CREDS_FILE}" ]]; then
    if [[ ! -f "${CREDS_FILE}" && "${CREDS_FILE}" != */* ]]; then
        for f in "${KC_CONFIG_DIR}/${NAMESPACE}/${CREDS_FILE}" "${KC_CONFIG_DIR}/${CREDS_FILE}"; do
            [[ -f "${f}" ]] && { CREDS_FILE="${f}"; break; }
        done
    fi
    [[ -r "${CREDS_FILE}" ]] || die "No file ${CREDS_FILE} (also looked in $(rel "${KC_CONFIG_DIR}")/${NAMESPACE}/ and $(rel "${KC_CONFIG_DIR}")/)."
    CREDS="$(kc_postgres_normalize < "${CREDS_FILE}" 2>/dev/null)" || die "${CREDS_FILE} is not valid JSON."
    SOURCE="file $(rel "${CREDS_FILE:A}")"
elif [[ -n "${SRC_SECRET}" ]]; then
    CREDS="$(kc_postgres_from_secret "${SRC_SECRET_NS}" "${SRC_SECRET}" "${NAMESPACE}")" \
        || die "No Secret ${SRC_SECRET} in namespace ${SRC_SECRET_NS} (or it is not readable)."
    SOURCE="Secret ${SRC_SECRET_NS}/${SRC_SECRET}"
    if [[ "${SRC_SECRET_NS}" == "${NAMESPACE}" ]] \
       && oc get secret "${SRC_SECRET}" -n "${NAMESPACE}" -o json | jq -e '.data["creds.json"]' >/dev/null; then
        USE_SECRET="${SRC_SECRET}"
    fi
elif [[ -z "${OPT_HOST}${OPT_PORT}${OPT_DATABASE}${OPT_USER}${OPT_PASSWORD}" && -f "${LOCAL_FILE}" ]]; then
    CREDS="$(kc_postgres_normalize < "${LOCAL_FILE}" 2>/dev/null)" || die "$(rel "${LOCAL_FILE}") is not valid JSON."
    SOURCE="file $(rel "${LOCAL_FILE}")"
elif [[ "${KC_PG_ENABLED}" == true && "$(jq -r '.host' <<<"${KC_PG}")" != "" ]]; then
    CREDS="${KC_PG}"
    SOURCE="the instance's current connection (Secret ${KC_PG_SECRET})"
    [[ "${KC_PG_SECRET}" != kubecost-integrations-postgres ]] && USE_SECRET="${KC_PG_SECRET}"
fi

# Flags win over the file/Secret.
flags="$(jq -cn --arg host "${OPT_HOST}" --arg port "${OPT_PORT}" --arg databaseName "${OPT_DATABASE}" \
    --arg user "${OPT_USER}" --arg password "${OPT_PASSWORD}" '$ARGS.named | with_entries(select(.value != ""))')"
if [[ "${flags}" != "{}" ]]; then
    CREDS="$(jq -c --argjson f "${flags}" '. + $f' <<<"${CREDS}")"
    SOURCE="${SOURCE:+${SOURCE} + }flags ($(jq -r 'keys | join(", ")' <<<"${flags}"))"
    USE_SECRET=""
fi
CREDS="$(jq -c 'if (.port // "") == "" then .port = "5432" else . end' <<<"${CREDS}")"

# Ask for what's missing, on a terminal.
typeset -A PROMPTS=(host "Postgres host" port "Port" databaseName "Database" user "User" password "Password")
for field in host port databaseName user password; do
    value="$(jq -r --arg k "${field}" '.[$k] // ""' <<<"${CREDS}")"
    [[ -z "${value}" || "${value}" == \<*\> ]] || continue
    if [[ -t 0 ]]; then
        if [[ "${field}" == password ]]; then
            echo -n "${PROMPTS[${field}]}: "; read -rs value; echo
        else
            echo -n "${PROMPTS[${field}]}: "; read -r value
        fi
        [[ -n "${value}" ]] || die "${PROMPTS[${field}]} is required."
        CREDS="$(jq -c --arg k "${field}" --arg v "${value}" '.[$k] = $v' <<<"${CREDS}")"
        [[ "${SOURCE}" == *prompt ]] || SOURCE="${SOURCE:+${SOURCE} + }prompt"
        USE_SECRET=""
    else
        typeset -A FLAG=(host --db-host port --db-port databaseName --db-name user --db-user password --db-password)
        hint="${FLAG[${field}]}"
        [[ "${value}" == \<*\> ]] && die "${field} in ${SOURCE} is still a placeholder (${value}); fill it in or pass ${hint}."
        die "No ${field} for the Postgres connection${SOURCE:+ in ${SOURCE}}. Pass -f, -s or ${hint} (--template writes a file to fill in)."
    fi
done
PG_HOST="$(jq -r '.host' <<<"${CREDS}")"
PG_PORT="$(jq -r '.port' <<<"${CREDS}")"
[[ "${PG_PORT}" == <1-65535> ]] || die "Port '${PG_PORT}' is not a port number."
[[ "${PG_HOST}" != *[[:space:]/:]* ]] || die "Host '${PG_HOST}' should be a bare host name (no scheme, port or path)."
CREDS_JSON="$(jq -c '{host, port, databaseName, user, password}' <<<"${CREDS}")"
echo "[INFO] Connection from ${SOURCE}: $(jq -r '"\(.user)@\(.host):\(.port)/\(.databaseName)"' <<<"${CREDS_JSON}")"

# --- Run interval and queries --------------------------------------------------
RUN_INTERVAL="${RUN_INTERVAL:-$(jq -r '.runInterval // ""' <<<"${CREDS}")}"
RUN_INTERVAL="${RUN_INTERVAL:-$(jq -r '.runInterval // "12h"' <<<"${CURRENT_PG}")}"
[[ "${RUN_INTERVAL}" =~ '^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$' ]] \
    || die "runInterval '${RUN_INTERVAL}' is not a duration like 30m, 6h or 1h30m."

if [[ -n "${QUERIES_FILE}" ]]; then
    [[ -r "${QUERIES_FILE}" ]] || die "No file ${QUERIES_FILE}."
    QUERIES="$(jq -c '.queryConfigs // .' "${QUERIES_FILE}" 2>/dev/null)" || die "${QUERIES_FILE} is not valid JSON."
    QSOURCE="$(rel "${QUERIES_FILE:A}")"
elif jq -e '.queryConfigs' <<<"${CREDS}" >/dev/null; then
    QUERIES="$(jq -c '.queryConfigs' <<<"${CREDS}")"; QSOURCE="${SOURCE%% + *}"
elif [[ "${DEFAULT_QUERIES}" != true ]] && jq -e '[.queryConfigs // {} | .[]? | .[]?] | length > 0' <<<"${CURRENT_PG}" >/dev/null; then
    QUERIES="$(jq -c '.queryConfigs' <<<"${CURRENT_PG}")"; QSOURCE="the instance's current queries"
else
    QUERIES="${DEFAULT_QUERY_CONFIGS}"; QSOURCE="defaults"
fi
QCHECK="$(jq -c '
    (if type == "object" then . else {} end) as $q
    | {queries: {allocations: ($q.allocations // []), assets: ($q.assets // []), cloudCosts: ($q.cloudCosts // [])}
                | map_values(map(map_values(if type == "string" then . else tojson end))),
       errors: ([if type != "object" then "queryConfigs must be an object {allocations, assets, cloudCosts}" else empty end]
         + [($q | keys[]? | select(IN("allocations", "assets", "cloudCosts") | not)) | "unknown query type \(.)"])}
    | .errors += [.queries | to_entries[] | .key as $t | .value | to_entries[] | .key as $i | .value
         | (if (.databaseTable // "" | test("^[A-Za-z_][A-Za-z0-9_]{0,62}$")) | not
              then "\($t)[\($i)]: databaseTable \(.databaseTable // "" | tojson) is not a plain table name" else empty end),
           (if (.window // "") == "" then "\($t)[\($i)]: window is missing" else empty end)]
    | .errors += [[.queries[][] | .databaseTable] | group_by(.)[] | select(length > 1) | "table \(.[0]) is used by more than one query"]
    | .errors += (if ([.queries[][]] | length) == 0 then ["no queries"] else [] end)' <<<"${QUERIES}")"
if [[ "$(jq '.errors | length' <<<"${QCHECK}")" != 0 ]]; then
    echo "[ERROR] Queries (${QSOURCE}):" >&2
    jq -r '.errors[] | "  \(.)"' <<<"${QCHECK}" >&2
    exit 1
fi
QUERIES="$(jq -c '.queries' <<<"${QCHECK}")"
echo "[INFO] Every ${RUN_INTERVAL}, ${QSOURCE}: $(jq -r '[to_entries[] | .key as $t | .value[] | "\($t)/\(.aggregate // "-")/\(.window) -> \(.databaseTable)"] | join(", ")' <<<"${QUERIES}")"

# --- Product key ---------------------------------------------------------------
kc_product_key_status "${CR_JSON}" "${NAMESPACE}"
if [[ "${KC_KEY_LINKED}" != true ]]; then
    echo "[WARN] The Postgres integration is a Kubecost Enterprise feature, and no product key is linked"
    echo "[WARN] to '${CR_NAME}' (${KC_KEY_SOURCE}). Link one first: product_key/link_kubecost_product_key.sh ${CR_NAME} -k <key>"
    [[ "${FORCE}" == true ]] || die "Stopped. --force applies it anyway."
    echo "[WARN] --force: applying anyway."
else
    echo "[INFO] Product key: ${KC_KEY_SOURCE}"
fi
oc get "${AGGREGATOR}" -n "${NAMESPACE}" &>/dev/null \
    || echo "[WARN] No ${AGGREGATOR}: the integration runs in the aggregator StatefulSet (kubecostAggregator.deployMethod: statefulset)."

# --- Reachability --------------------------------------------------------------
if [[ "${CHECK}" == true ]]; then
    pod="${CR_NAME}-aggregator-0"
    if ! oc get pod "${pod}" -n "${NAMESPACE}" &>/dev/null; then
        echo "[WARN] No pod ${pod} to check the connection from; skipped."
    else
        echo "[INFO] Checking that ${PG_HOST}:${PG_PORT} answers from ${pod} (TCP only)..."
        if oc exec "${pod}" -n "${NAMESPACE}" -c aggregator -- \
                timeout 8 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "${PG_HOST}" "${PG_PORT}" &>/dev/null; then
            echo "[OK] ${PG_HOST}:${PG_PORT} is reachable."
        else
            die "${PG_HOST}:${PG_PORT} is not reachable from ${pod} (DNS, network policy or port). --no-check skips this."
        fi
    fi
fi

# --- Secret --------------------------------------------------------------------
SECRET_CHANGED=false
if [[ -n "${USE_SECRET}" ]]; then
    SECRET_NAME="${USE_SECRET}"
    echo "[INFO] Credentials: existing Secret ${SECRET_NAME} (creds.json), used as is."
else
    SECRET_NAME="${TARGET_SECRET}"
    existing="$(oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null || true)"
    if [[ -n "${existing}" ]]; then
        [[ "$(jq -r '.metadata.labels["kubecost-postgres/managed"] // ""' <<<"${existing}")" == true ]] \
            || die "Secret ${SECRET_NAME} exists and was not made by this script. Use it with -s ${SECRET_NAME}, or name another with --target-secret."
        current_creds="$(jq -c '.data["creds.json"] // "" | @base64d | fromjson? // {}' <<<"${existing}")"
        [[ "$(jq -cS . <<<"${current_creds}")" == "$(jq -cS . <<<"${CREDS_JSON}")" ]] || SECRET_CHANGED=true
    else
        SECRET_CHANGED=true
    fi
    echo "[INFO] Credentials: Secret ${SECRET_NAME} (creds.json)$([[ "${SECRET_CHANGED}" == true ]] && echo ", to be written" || echo ", unchanged")."
fi

# --- CR ------------------------------------------------------------------------
DESIRED_PG="$(jq -cn --arg i "${RUN_INTERVAL}" --arg s "${SECRET_NAME}" --argjson q "${QUERIES}" '{
    enabled: true, runInterval: $i, databaseSecretName: $s, queryConfigs: $q,
    databaseHost: "", databasePort: "", databaseName: "", databaseUser: "", databasePassword: ""}')"
PATCH="$(jq -cn --argjson p "${DESIRED_PG}" '{spec: {global: {integrations: {postgres: $p}}}}')"
CR_CHANGED=true
[[ "$(jq -cS --argjson d "${DESIRED_PG}" '. * $d' <<<"${CURRENT_PG}")" == "$(jq -cS . <<<"${CURRENT_PG}")" ]] && CR_CHANGED=false

if [[ "${DRY_RUN}" == true ]]; then
    if [[ "${SECRET_CHANGED}" == true ]]; then
        echo "[DRY-RUN] Would write Secret ${SECRET_NAME} -n ${NAMESPACE}, creds.json: $(jq -c '.password = "****"' <<<"${CREDS_JSON}")"
    fi
    if [[ "${CR_CHANGED}" == true ]]; then
        echo "[DRY-RUN] Would merge-patch ${KC_RESOURCE}/${CR_NAME} -n ${NAMESPACE}:"
        jq . <<<"${PATCH}"
    elif [[ "${SECRET_CHANGED}" == true ]]; then
        echo "[DRY-RUN] CR unchanged; would restart ${AGGREGATOR}."
    else
        echo "[DRY-RUN] Nothing to change."
    fi
    exit 0
fi

if [[ "${SECRET_CHANGED}" == true ]]; then
    jq -n --arg n "${SECRET_NAME}" --arg ns "${NAMESPACE}" --arg c "${CREDS_JSON}" '{
        apiVersion: "v1", kind: "Secret", type: "Opaque",
        metadata: {name: $n, namespace: $ns, labels: {"kubecost-postgres/managed": "true"}},
        data: {"creds.json": ($c | @base64)}}' | oc apply -f - >/dev/null
    echo "[OK] Secret ${SECRET_NAME} written."
fi

START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "${CR_CHANGED}" == true ]]; then
    roll_out "${PATCH}" "$(kc_release_revision "${CR_NAME}" "${NAMESPACE}")" "${START_TS}"
elif [[ "${SECRET_CHANGED}" == true ]]; then
    roll_out "" "" ""
else
    echo "[OK] '${CR_NAME}' already has this Postgres integration; nothing to change."
fi

# --- Local copy ----------------------------------------------------------------
LOCAL_JSON="$(jq -n --argjson c "${CREDS_JSON}" --arg i "${RUN_INTERVAL}" --arg s "${SECRET_NAME}" --argjson q "${QUERIES}" \
    '$c + {runInterval: $i, secretName: $s, queryConfigs: $q}')"
if [[ ! -f "${LOCAL_FILE}" ]] \
   || [[ "$(kc_postgres_normalize < "${LOCAL_FILE}" 2>/dev/null | jq -cS . || true)" != "$(kc_postgres_normalize <<<"${LOCAL_JSON}" | jq -cS .)" ]]; then
    [[ -f "${LOCAL_FILE}" ]] && cp -p "${LOCAL_FILE}" "${LOCAL_FILE}.$(date -u +%Y%m%dT%H%M%SZ).bak"
    print -r -- "${LOCAL_JSON}" | _kc_write_private "${LOCAL_FILE}"
    echo "[OK] Settings saved to $(rel "${LOCAL_FILE}")"
fi

# --- First run -----------------------------------------------------------------
if [[ "${WAIT}" == true && ( "${CR_CHANGED}" == true || "${SECRET_CHANGED}" == true ) ]]; then
    pod="${CR_NAME}-aggregator-0"
    log_wait=180 elapsed=0 log=""
    echo "[INFO] Watching ${pod} for the integration's first run (up to ${log_wait}s)..."
    while (( elapsed < log_wait )); do
        log="$(oc logs "${pod}" -n "${NAMESPACE}" -c aggregator --since-time="${START_TS}" 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' | grep -i -E 'integration|postgres' || true)"
        [[ -n "${log}" ]] && break
        sleep 10; (( elapsed += 10 ))
        echo "  [${elapsed}/${log_wait}s $(( elapsed * 100 / log_wait ))%] no integration log yet"
    done
    if [[ -n "${log}" ]]; then
        echo "[INFO] Aggregator log (integrations):"
        print -r -- "${log}" | tail -8 | cut -c1-220 | sed 's/^/  /'
        print -r -- "${log}" | grep -q -i -E 'error|fail|denied' \
            && echo "[WARN] The log shows errors; check the connection, the user's rights and the queries."
    else
        echo "[INFO] Nothing logged yet. Check later: oc logs ${pod} -n ${NAMESPACE} -c aggregator | grep -i integrations"
    fi
fi

kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
echo "[OK] Done. Postgres integration on '${CR_NAME}': every ${RUN_INTERVAL} into $(jq -r '"\(.host):\(.port)/\(.databaseName)"' <<<"${CREDS_JSON}")."
