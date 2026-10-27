#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/cpd_api_helpers.sh"

# =============================================================================
# 5_create_wxd_presto_engine.sh
# -----------------------------------------------------------------------------
# Creates a custom-sized Presto (Java) engine in a watsonx.data instance, or
# re-sizes the engine that already has this display name. The last line printed
# is ENGINE_ID=<id>, for scripts that chain on to this one.
#
# How: the engine is registered through the lakehouse API
# (POST /lakehouse/api/v3/presto_engines), which creates its WxdEngine CR; the
# sizing then goes onto that CR as the operator's presto_worker_* /
# presto_coordinator_* customization fields. A CR created by hand gets pods but
# no engine: watsonx.data only knows engines in its own metadata database, so it
# could not be associated with catalogs or used from the console. Scaling the
# StatefulSet directly does not stick either - the operator waits for the CR's
# replica count and puts it back.
#
#   - Instance : --instance <Wxd CR name | instance id>, else the only Wxd
#                instance in PROJECT_CPD_INST_OPERANDS.
#   - Sizing   : the template (default
#                src/helpers/watsonxdata_engine_jinja2_templates/presto_engine_template.json.j2:
#                1 coordinator + 3 workers, 6 CPU / 16G each), filled from the
#                flags / env vars below (flags win). --template uses your own.
#   - Auth     : CPD_URL + CPD_USERNAME + CPD_APIKEY (cpd_instance_details.sh),
#                unless --cpd-url / --username / --api-key are passed; oc via OC_LOGIN.
#
# Usage:
#   ./5_create_wxd_presto_engine.sh [--name <display name>] [--workers <n>]
#       [--worker-cpu <cpu>] [--worker-memory <mem>]
#       [--coordinator-cpu <cpu>] [--coordinator-memory <mem>]
#       [--catalog <name>]... [--template <file.json.j2>] [--set <key>=<value>]...
#   --worker-cpu / --worker-memory (and the coordinator ones) set request and
#   limit together; --worker-cpu-request, --worker-cpu-limit,
#   --worker-memory-request, --worker-memory-limit (and coordinator-*) set one.
#   --worker-jvm-xmx / --coordinator-jvm-xmx   pin the heap (default: derived)
#   --description <text>, --tag <tag>...       shown in the console
#   --set <key>=<value>                        any other template variable
#   --dry-run    render and print the API body and CR fields, change nothing
#   --no-wait    return after the CR is patched instead of waiting for RUNNING
#   --timeout <s> how long to wait for RUNNING (default 2400)
#
# Units: CPU 6 / 1.5 / 6000m; memory 12G / 512M (operator format - not 12Gi).
#
# Env vars: WXD_INSTANCE, WXD_PRESTO_ENGINE_NAME, WXD_PRESTO_ENGINE_DESCRIPTION,
#   WXD_PRESTO_ENGINE_CATALOGS (space/comma-separated), WXD_PRESTO_ENGINE_TEMPLATE,
#   WXD_PRESTO_WORKERS, WXD_PRESTO_WORKER_CPU, WXD_PRESTO_WORKER_MEMORY,
#   WXD_PRESTO_COORDINATOR_CPU, WXD_PRESTO_COORDINATOR_MEMORY
# =============================================================================

DEFAULT_TEMPLATE="${_CP4D_REPO_ROOT}/src/helpers/watsonxdata_engine_jinja2_templates/presto_engine_template.json.j2"

INSTANCE="${WXD_INSTANCE:-}"
TEMPLATE="${WXD_PRESTO_ENGINE_TEMPLATE:-}"
CATALOGS=(${=${WXD_PRESTO_ENGINE_CATALOGS:-}//,/ })
TAGS=()
DRY_RUN=false
WAIT=true
TIMEOUT=2400
API_URL=""
API_USER=""
API_KEY=""
# Template variables; empty ones fall back to the template defaults.
typeset -A TVARS=(
  display_name               "${WXD_PRESTO_ENGINE_NAME:-}"
  description                "${WXD_PRESTO_ENGINE_DESCRIPTION:-}"
  worker_replicas            "${WXD_PRESTO_WORKERS:-}"
  worker_cpu_request         "${WXD_PRESTO_WORKER_CPU:-}"
  worker_cpu_limit           "${WXD_PRESTO_WORKER_CPU:-}"
  worker_memory_request      "${WXD_PRESTO_WORKER_MEMORY:-}"
  worker_memory_limit        "${WXD_PRESTO_WORKER_MEMORY:-}"
  coordinator_cpu_request    "${WXD_PRESTO_COORDINATOR_CPU:-}"
  coordinator_cpu_limit      "${WXD_PRESTO_COORDINATOR_CPU:-}"
  coordinator_memory_request "${WXD_PRESTO_COORDINATOR_MEMORY:-}"
  coordinator_memory_limit   "${WXD_PRESTO_COORDINATOR_MEMORY:-}"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)       h_need_value "$1" "${2:-}"; INSTANCE="$2"; shift 2 ;;
    --name)           h_need_value "$1" "${2:-}"; TVARS[display_name]="$2"; shift 2 ;;
    --description)    h_need_value "$1" "${2:-}"; TVARS[description]="$2"; shift 2 ;;
    --catalog)        h_need_value "$1" "${2:-}"; CATALOGS+=("$2"); shift 2 ;;
    --tag)            h_need_value "$1" "${2:-}"; TAGS+=("$2"); shift 2 ;;
    --workers)        h_need_value "$1" "${2:-}"; TVARS[worker_replicas]="$2"; shift 2 ;;
    --worker-cpu)     h_need_value "$1" "${2:-}"; TVARS[worker_cpu_request]="$2"; TVARS[worker_cpu_limit]="$2"; shift 2 ;;
    --worker-memory)  h_need_value "$1" "${2:-}"; TVARS[worker_memory_request]="$2"; TVARS[worker_memory_limit]="$2"; shift 2 ;;
    --coordinator-cpu)    h_need_value "$1" "${2:-}"; TVARS[coordinator_cpu_request]="$2"; TVARS[coordinator_cpu_limit]="$2"; shift 2 ;;
    --coordinator-memory) h_need_value "$1" "${2:-}"; TVARS[coordinator_memory_request]="$2"; TVARS[coordinator_memory_limit]="$2"; shift 2 ;;
    --(worker|coordinator)-(cpu|memory)-(request|limit)|--(worker|coordinator)-jvm-xmx)
                      h_need_value "$1" "${2:-}"; TVARS[${${1#--}//-/_}]="$2"; shift 2 ;;
    --template)       h_need_value "$1" "${2:-}"; TEMPLATE="$2"; shift 2 ;;
    --set)            h_need_value "$1" "${2:-}"
                      [[ "$2" == *=* ]] || h_die "--set expects <key>=<value>, got '$2'."
                      TVARS[${2%%=*}]="${2#*=}"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --no-wait)        WAIT=false; shift ;;
    --timeout)        h_need_value "$1" "${2:-}"; TIMEOUT="$2"; shift 2 ;;
    --cpd-url)        h_need_value "$1" "${2:-}"; API_URL="$2"; shift 2 ;;
    --username)       h_need_value "$1" "${2:-}"; API_USER="$2"; shift 2 ;;
    --api-key)        h_need_value "$1" "${2:-}"; API_KEY="$2"; shift 2 ;;
    -h|--help)        sed -n '/^# 5_create_wxd_presto_engine.sh/,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) h_die "Unknown argument: $1 (see --help)" ;;
  esac
done
TVARS[catalogs]="${(j:,:)CATALOGS}"
TVARS[tags]="${(j:,:)TAGS}"
[[ "${TIMEOUT}" == <-> ]] || h_die "--timeout must be a number of seconds, got '${TIMEOUT}'."

# --- Render the engine definition ---
TEMPLATE="${TEMPLATE:-${DEFAULT_TEMPLATE}}"
[[ -f "${TEMPLATE}" ]] || h_die "Template not found: ${TEMPLATE}"
python_bin="python3"
[[ -x "${_CP4D_REPO_ROOT}/.venv/bin/python" ]] && python_bin="${_CP4D_REPO_ROOT}/.venv/bin/python"
set_args=()
for _k in "${(@k)TVARS}"; do set_args+=(--set "${_k}=${TVARS[${_k}]}"); done
unset _k
RENDERED="$("${python_bin}" "${_CP4D_REPO_ROOT}/src/helpers/watsonxdata_presto_engine_render.py" \
  --template "${TEMPLATE}" "${set_args[@]}")" || exit 1

API_BODY_JSON="$(jq -c '.api_body' <<<"${RENDERED}")"
CR_SPEC_JSON="$(jq -c '.cr_spec' <<<"${RENDERED}")"
ENGINE_NAME="$(jq -r '.api_body.display_name' <<<"${RENDERED}")"
WORKERS="$(jq -r '.cr_spec.presto_worker_replicas' <<<"${RENDERED}")"

h_info "Template : ${TEMPLATE#${_CP4D_REPO_ROOT}/}"
h_info "Engine   : ${ENGINE_NAME}"
jq -r '.summary[] | "[INFO]   " + .' <<<"${RENDERED}"

if [[ "${DRY_RUN}" == true ]]; then
  echo ""
  echo "--- POST /lakehouse/api/v3/presto_engines body ---"
  jq . <<<"${API_BODY_JSON}"
  echo "--- WxdEngine spec fields ---"
  jq . <<<"${CR_SPEC_JSON}"
  h_info "Dry run: nothing was changed."
  exit 0
fi

# --- Cluster login ---
if ! h_missing_vars OC_LOGIN PROJECT_CPD_INST_OPERANDS; then
  h_die "Not set: ${REPLY}. Set them in ./cpd_vars.sh before running this script."
fi
eval "${OC_LOGIN}"
NS="${PROJECT_CPD_INST_OPERANDS}"

# --- watsonx.data instance ---
WXD_ROWS=("${(@f)$(oc get wxd -n "${NS}" -o json \
  | jq -r '.items[] | "\(.metadata.name)\t\(.spec.zenServiceInstanceId // "")"')}")
WXD_ROWS=(${WXD_ROWS:#})
(( ${#WXD_ROWS} > 0 )) || h_die "No watsonx.data (Wxd) instance in ${NS}."

INSTANCE_ID=""
for _row in "${WXD_ROWS[@]}"; do
  _name="${_row%%$'\t'*}"; _id="${_row#*$'\t'}"
  if [[ -z "${INSTANCE}" && ${#WXD_ROWS} -eq 1 ]] || [[ -n "${INSTANCE}" && "${INSTANCE}" == ("${_name}"|"${_id}") ]]; then
    WXD_NAME="${_name}"; INSTANCE_ID="${_id}"
  fi
done
unset _row _name _id
if [[ -z "${INSTANCE_ID}" ]]; then
  echo "[ERROR] ${INSTANCE:+No instance '${INSTANCE}'. }Pick one with --instance <name|id>:" >&2
  for _row in "${WXD_ROWS[@]}"; do echo "        ${_row%%$'\t'*} (id ${_row#*$'\t'})" >&2; done
  exit 1
fi
h_info "Instance : ${WXD_NAME} (id ${INSTANCE_ID}) in ${NS}"

# --- CPD API login ---
API_URL="${API_URL:-${CPD_URL:-}}"
API_USER="${API_USER:-${CPD_USERNAME:-}}"
API_KEY="${API_KEY:-${CPD_APIKEY:-}}"
if [[ -z "${API_URL}" || -z "${API_USER}" || -z "${API_KEY}" ]]; then
  echo "[ERROR] No CPD URL or credentials. Pass --cpd-url / --username / --api-key, or set" >&2
  echo "        CPD_URL / CPD_USERNAME / CPD_APIKEY in configs/cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi
cpdapi_login "${API_URL}" "${API_USER}" api_key "${API_KEY}" \
  || h_die "Failed to get a bearer token from ${API_URL%/}/icp4d-api/v1/authorize."
CPDAPI_HEADERS=("AuthInstanceId: ${INSTANCE_ID}")

# --- Find or register the engine ---
cpdapi GET "/lakehouse/api/v3/presto_engines"
[[ "${API_CODE}" == 200 ]] || h_die "Listing Presto engines failed (HTTP ${API_CODE}): ${API_BODY}"
MATCHES=("${(@f)$(jq -r --arg n "${ENGINE_NAME}" '.presto_engines[]? | select(.display_name == $n) | .id' <<<"${API_BODY}")}")
MATCHES=(${MATCHES:#})

if (( ${#MATCHES} > 1 )); then
  h_die "${#MATCHES} engines are named '${ENGINE_NAME}': ${MATCHES[*]}. Rename or delete the extras."
elif (( ${#MATCHES} == 1 )); then
  ENGINE_ID="${MATCHES[1]}"
  h_info "Engine '${ENGINE_NAME}' already exists (${ENGINE_ID}); applying the sizing to it."
else
  h_info "Registering engine '${ENGINE_NAME}'..."
  cpdapi POST "/lakehouse/api/v3/presto_engines" "${API_BODY_JSON}"
  if [[ "${API_CODE}" == 20[012] ]]; then
    ENGINE_ID="$(jq -r '.id // .engine_id // empty' <<<"${API_BODY}" 2>/dev/null || true)"
  else
    # The 2.4.5 API can fail after it has already created the engine (e.g. HTTP 400
    # 'wxdengines ... "lakehouse-" not found'), so look before giving up.
    _create_error="HTTP ${API_CODE}: ${API_BODY}"
    cpdapi GET "/lakehouse/api/v3/presto_engines"
    ENGINE_ID="$(jq -r --arg n "${ENGINE_NAME}" '[.presto_engines[]? | select(.display_name == $n) | .id][0] // empty' <<<"${API_BODY}" 2>/dev/null || true)"
    [[ -n "${ENGINE_ID}" ]] || h_die "Creating the engine failed (${_create_error})"
    h_warn "The create call failed (${_create_error}), but the engine was created; continuing."
    unset _create_error
  fi
  [[ -n "${ENGINE_ID}" ]] || h_die "The create call returned no engine id: ${API_BODY}"
  h_info "Registered engine ${ENGINE_ID}."
fi

# --- Size the WxdEngine CR ---
# The API creates the CR asynchronously; match it on spec.engineName.
_find_cr() {
  oc get wxdengine -n "${NS}" -o json 2>/dev/null \
    | jq -r --arg id "${ENGINE_ID}" '.items[] | select(.spec.engineName == $id) | .metadata.name' | head -1
}
CR_NAME=""
for _i in {1..36}; do
  CR_NAME="$(_find_cr)"
  [[ -n "${CR_NAME}" ]] && break
  h_info "Waiting for the WxdEngine CR of ${ENGINE_ID} ($(( _i * 5 ))s/180s)"
  sleep 5
done
unset _i
[[ -n "${CR_NAME}" ]] || h_die "No WxdEngine CR with engineName ${ENGINE_ID} in ${NS} after 180s."

CURRENT_SPEC="$(oc get wxdengine "${CR_NAME}" -n "${NS}" -o json | jq -c '.spec')"
CHANGES="$(jq -c --argjson want "${CR_SPEC_JSON}" '. as $have | $want | with_entries(select($have[.key] != .value))' <<<"${CURRENT_SPEC}")"
if [[ "${CHANGES}" == "{}" ]]; then
  echo "[SKIP] ${CR_NAME} already has this sizing."
else
  oc patch wxdengine "${CR_NAME}" -n "${NS}" --type merge -p "$(jq -c '{spec: .}' <<<"${CHANGES}")" >/dev/null
  h_info "Patched ${CR_NAME}: $(jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' <<<"${CHANGES}")"
fi

if [[ "${WAIT}" != true ]]; then
  h_info "Not waiting (--no-wait). Watch it with: oc get wxdengine ${CR_NAME} -n ${NS} -w"
  echo "ENGINE_ID=${ENGINE_ID}"
  exit 0
fi

# --- Wait for RUNNING ---
# Ready means: the API reports RUNNING, the operator's last reconcile completed,
# and the worker StatefulSet runs the requested count. A patch only starts a new
# reconcile once the operator picks it up, so the first checks get a grace period
# in which a stale "Completed" does not count.
WORKER_STS="ibm-lh-${CR_NAME}-presto-worker"
GRACE=60
[[ "${CHANGES}" == "{}" ]] && GRACE=0
START=${SECONDS}
while true; do
  ELAPSED=$(( SECONDS - START ))
  cpdapi GET "/lakehouse/api/v3/presto_engines/${ENGINE_ID}"
  API_STATUS="$(jq -r '.status // "?"' <<<"${API_BODY}" 2>/dev/null || echo "?")"
  CR_STATUS="$(oc get wxdengine "${CR_NAME}" -n "${NS}" -o jsonpath='{.status.engineStatus}' 2>/dev/null || true)"
  read -r STS_WANT STS_READY <<<"$(oc get sts "${WORKER_STS}" -n "${NS}" \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>/dev/null || true)"
  STS_READY="${STS_READY:-0}"
  PCT=$(( WORKERS > 0 ? (STS_READY > WORKERS ? WORKERS : STS_READY) * 100 / WORKERS : 0 ))
  h_info "Workers ready ${STS_READY}/${WORKERS} (${PCT}%) | engine ${API_STATUS} | reconcile ${CR_STATUS:-?} | ${ELAPSED}s/${TIMEOUT}s"

  if (( ELAPSED >= GRACE )) && [[ "${API_STATUS}" == RUNNING && "${CR_STATUS}" == Completed \
        && "${STS_WANT:-}" == "${WORKERS}" && "${STS_READY}" == "${WORKERS}" ]]; then
    break
  fi
  if (( ELAPSED >= TIMEOUT )); then
    h_error "Engine ${ENGINE_ID} is not RUNNING after ${TIMEOUT}s."
    h_error "If the workers are all ready but the reconcile is still InProgress, the operator is"
    h_error "finishing a replica wait from before the patch (up to 15 min) and will pick the new"
    h_error "sizing up next. Check: oc get wxdengine ${CR_NAME} -n ${NS} -w"
    exit 1
  fi
  sleep 20
done

HOST="$(jq -r '.external_host_name // empty' <<<"${API_BODY}" 2>/dev/null || true)"
h_info "Engine '${ENGINE_NAME}' (${ENGINE_ID}) is RUNNING with ${WORKERS} workers.${HOST:+ Host: ${HOST}}"
echo "ENGINE_ID=${ENGINE_ID}"
