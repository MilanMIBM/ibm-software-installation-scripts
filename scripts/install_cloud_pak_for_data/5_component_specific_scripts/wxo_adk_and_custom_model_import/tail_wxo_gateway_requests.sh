#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# tail_wxo_gateway_requests.sh
# -----------------------------------------------------------------------------
# Auto-detects the watsonx Orchestrate AI-gateway / model-inferencing pod in the
# CPD instance namespace and tails its logs, filtered for the upstream LLM call
# (e.g. the request/response to the ICA custom_host). Use this to see the exact
# request body / upstream error when a virtual model returns a 400 at prompt time.
#
# Reproduce the failing prompt in the WXO UI *after* this starts tailing.
#
# Auto-detection:
#   - Namespace  : NAMESPACE env / --namespace, else PROJECT_CPD_INST_OPERANDS
#                  (sourced from cp4d_config), else the current `oc` project.
#   - Pod(s)     : pods whose name matches a gateway/llm/inference pattern.
#
# Optional flags:
#   --namespace <ns>   override the namespace
#   --grep <regex>     override the log filter (default matches the ICA host / 400s)
#   --no-filter        stream all logs unfiltered
#   --list             just list the candidate pods and exit (no tailing)
# =============================================================================

# --- Defaults ---
NAMESPACE="${NAMESPACE:-}"
# Default filter: the ICA host, the model name, and common error markers.
FILTER_REGEX='nextgen|chat-models|claude-haiku|virtual-model|[Bb]ad[ ]?[Rr]equest|40[0-9] |status_code|payload|request body'
DO_FILTER=1
LIST_ONLY=0

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --grep)      FILTER_REGEX="$2"; shift 2 ;;
    --no-filter) DO_FILTER=0; shift ;;
    --list)      LIST_ONLY=1; shift ;;
    *) echo "[WARN] unknown argument: $1" >&2; shift ;;
  esac
done

command -v oc >/dev/null 2>&1 || { echo "[ERROR] 'oc' CLI not found on PATH." >&2; exit 1; }

# --- Resolve the namespace ---
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE="${PROJECT_CPD_INST_OPERANDS:-}"
fi
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE="$(oc project -q 2>/dev/null || true)"
fi
if [[ -z "${NAMESPACE}" ]]; then
  echo "[ERROR] Could not determine a namespace. Pass --namespace <ns>." >&2
  exit 1
fi
echo "[NS] using namespace: ${NAMESPACE}"

# --- Auto-detect candidate gateway / inferencing pods ---
# Match common naming for the AI gateway, model proxy, LLM and inferencing pods.
POD_REGEX='(ai-?gateway|model-?gateway|llm-?gateway|litellm|model-?proxy|inference|inferenc|wo-.*gateway|orchestrate.*gateway)'
echo "[POD] searching for gateway/inferencing pods matching: ${POD_REGEX}"

typeset -a PODS
PODS=("${(@f)$(oc get pods -n "${NAMESPACE}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
  | grep -iE "${POD_REGEX}" || true)}")
# Drop any empty entries.
PODS=("${(@)PODS:#}")

if (( ${#PODS} == 0 )); then
  echo "[WARN] No pod matched '${POD_REGEX}' in '${NAMESPACE}'." >&2
  echo "       Pods containing 'gateway', 'model', 'llm' or 'inference':" >&2
  oc get pods -n "${NAMESPACE}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
    | grep -iE 'gateway|model|llm|inferenc' >&2 || echo "       (none found)" >&2
  echo "       Re-run with --namespace <ns> and/or inspect 'oc get pods -n <ns>'." >&2
  exit 1
fi

echo "[POD] matched ${#PODS} candidate pod(s):"
for _p in "${PODS[@]}"; do echo "    - ${_p}"; done

if (( LIST_ONLY == 1 )); then
  echo "[DONE] --list given; not tailing."
  exit 0
fi

# --- Tail the pod(s) ---
# If exactly one pod, tail it directly. If several, tail them in parallel and
# prefix each line with the pod name so you can tell them apart.
echo "[TAIL] now streaming logs. Reproduce the failing prompt in the WXO UI."
if (( DO_FILTER == 1 )); then
  echo "[TAIL] filter: ${FILTER_REGEX}  (use --no-filter to see everything)"
fi
echo "----------------------------------------------------------------------"

_stream_one() {
  local pod="$1"
  if (( DO_FILTER == 1 )); then
    oc logs -f "${pod}" -n "${NAMESPACE}" --all-containers=true 2>&1 \
      | grep --line-buffered -iE "${FILTER_REGEX}" \
      | sed "s|^|[${pod}] |"
  else
    oc logs -f "${pod}" -n "${NAMESPACE}" --all-containers=true 2>&1 \
      | sed "s|^|[${pod}] |"
  fi
}

if (( ${#PODS} == 1 )); then
  _stream_one "${PODS[1]}"
else
  typeset -a _pids
  for _p in "${PODS[@]}"; do
    _stream_one "${_p}" &
    _pids+=($!)
  done
  trap 'kill ${_pids[@]} 2>/dev/null' INT TERM
  wait
fi
