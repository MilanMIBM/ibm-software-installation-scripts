#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b

# ---

usage() {
    cat <<'EOF'
Render a Jinja2 CR template against the sourced cpd_vars.sh environment and
apply it to the cluster.

  create_cr_instance.sh <template.yaml.j2> [options]

A bare name is resolved against src/cr_yaml_examples/ (with or without the
.yaml.j2 suffix), so "ccs" and the full path both work.

Options:
  -n, --namespace NS   Override the namespace the CR is applied to
  -o, --output FILE    Also write the rendered YAML to FILE
      --dry-run        Render + server-side dry-run, change nothing
      --render-only    Print the rendered YAML and exit (no cluster contact)
  -y, --yes            Skip the confirmation prompt
  -w, --wait [SECS]    After applying, watch reconciliation until the CR
                       reports Completed/Failed (default timeout 1800s)
      --no-reconcile   Apply only; do not poke the operator or watch status
  -h, --help           Show this help
EOF
}

TEMPLATE=""
NAMESPACE=""
OUTPUT_FILE=""
DRY_RUN=false
RENDER_ONLY=false
ASSUME_YES=true
WAIT=false
WAIT_TIMEOUT=1800
RECONCILE=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)   NAMESPACE="${2:-}"; shift 2 ;;
        -o|--output)      OUTPUT_FILE="${2:-}"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --render-only)    RENDER_ONLY=true; shift ;;
        -y|--yes)         ASSUME_YES=true; shift ;;
        -w|--wait)
            WAIT=true
            if [[ "${2:-}" == <-> ]]; then WAIT_TIMEOUT="$2"; shift 2; else shift; fi ;;
        --no-reconcile)   RECONCILE=false; shift ;;
        -h|--help)        usage; exit 0 ;;
        -*)               echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [[ -n "${TEMPLATE}" ]]; then
                echo "[ERROR] Unexpected argument: $1 (template already set to ${TEMPLATE})" >&2
                exit 1
            fi
            TEMPLATE="$1"; shift ;;
    esac
done

if [[ -z "${TEMPLATE}" ]]; then
    echo "[ERROR] No template given." >&2
    usage >&2
    exit 1
fi

# Allow a bare template name: look it up in src/cr_yaml_examples/
if [[ ! -f "${TEMPLATE}" ]]; then
    for _cand in \
        "${REPO_ROOT}/src/cr_yaml_examples/${TEMPLATE}" \
        "${REPO_ROOT}/src/cr_yaml_examples/${TEMPLATE}.yaml.j2"; do
        if [[ -f "${_cand}" ]]; then TEMPLATE="${_cand}"; break; fi
    done
    unset _cand
fi

if [[ ! -f "${TEMPLATE}" ]]; then
    echo "[ERROR] Template not found: ${TEMPLATE}" >&2
    echo "[INFO] Available templates in src/cr_yaml_examples/:" >&2
    ls -1 "${REPO_ROOT}/src/cr_yaml_examples/" 2>/dev/null | sed 's/^/  - /' >&2
    exit 1
fi
TEMPLATE="$(cd "$(dirname "${TEMPLATE}")" && pwd)/$(basename "${TEMPLATE}")"

# A namespace override is just another template variable.
if [[ -n "${NAMESPACE}" ]]; then
    export PROJECT_CPD_INST_OPERANDS="${NAMESPACE}"
fi

# --- Render ------------------------------------------------------------------
# The helper resolves {{ VARS }} from os.environ (populated by cpd_vars.sh) and
# reports anything it could not resolve. Missing vars render as empty strings,
# which would silently produce a malformed CR, so treat them as fatal here.
RENDERED_FILE="$(mktemp -t cr_instance).yaml"
trap 'rm -f "${RENDERED_FILE}"' EXIT INT TERM

echo "[INFO] Rendering ${TEMPLATE#${REPO_ROOT}/}"

set +e
HELPERS_DIR="${REPO_ROOT}/src/helpers" TEMPLATE_PATH="${TEMPLATE}" OUT_PATH="${RENDERED_FILE}" \
python3 <<'PY'
import os
import re
import sys

sys.path.insert(0, os.environ["HELPERS_DIR"])
from jinja2_template_rendering_helpers import render_template_from_environment, _TrackingUndefined

rendered = render_template_from_environment(
    template_path=os.environ["TEMPLATE_PATH"],
    print_missing=False,
)

# A var wrapped in `| default(...)` is deliberately optional - the tracker still
# records it as undefined, so filter those out and fail only on genuine gaps.
with open(os.environ["TEMPLATE_PATH"]) as fh:
    source = fh.read()

defaulted = set(
    re.findall(r"{{\s*(\w+)\s*\|\s*default\(", source)
)

missing = sorted(_TrackingUndefined._missing - defaulted)
if missing:
    print("[ERROR] Unresolved template variables (not set in cpd_vars.sh):", file=sys.stderr)
    for name in missing:
        print(f"  - {name}", file=sys.stderr)
    sys.exit(2)

with open(os.environ["OUT_PATH"], "w") as fh:
    fh.write(rendered)
PY
RENDER_RC=$?
set -e

if [[ ${RENDER_RC} -ne 0 ]]; then
    echo "[ERROR] Template rendering failed (exit ${RENDER_RC})." >&2
    exit ${RENDER_RC}
fi

if [[ -n "${OUTPUT_FILE}" ]]; then
    cp "${RENDERED_FILE}" "${OUTPUT_FILE}"
    echo "[INFO] Rendered YAML written to ${OUTPUT_FILE}"
fi

echo "--------------------------------------------------------------------"
cat "${RENDERED_FILE}"
echo "--------------------------------------------------------------------"

if [[ "${RENDER_ONLY}" == true ]]; then
    exit 0
fi

# --- Apply -------------------------------------------------------------------
if [[ -z "${OC_LOGIN:-}" ]]; then
    echo "[ERROR] OC_LOGIN is not set. Set it in ./cpd_vars.sh before running this script." >&2
    exit 1
fi

eval "${OC_LOGIN}"

CR_KIND="$(grep -m1 '^kind:' "${RENDERED_FILE}" | awk '{print $2}')"
CR_NAME="$(awk '/^metadata:/{m=1;next} m&&/^  name:/{print $2;exit}' "${RENDERED_FILE}")"
CR_NS="$(awk '/^metadata:/{m=1;next} m&&/^  namespace:/{print $2;exit}' "${RENDERED_FILE}")"

echo "[INFO] Target cluster: $(oc whoami --show-server 2>/dev/null || echo unknown)"
echo "[INFO] ${CR_KIND}/${CR_NAME} -> namespace ${CR_NS:-<none>}"

if [[ "${DRY_RUN}" == true ]]; then
    echo "[INFO] Dry run (server-side), nothing will be created."
    oc apply -f "${RENDERED_FILE}" --dry-run=server
    exit 0
fi

if [[ "${ASSUME_YES}" != true ]]; then
    echo -n "Apply this ${CR_KIND} to the cluster above? [y/N] "
    read -r _reply
    if [[ ! "${_reply}" =~ ^[Yy]$ ]]; then
        echo "[INFO] Aborted, nothing applied."
        exit 0
    fi
fi

oc apply -f "${RENDERED_FILE}"
echo "[INFO] Applied ${CR_KIND}/${CR_NAME}."

if [[ "${RECONCILE}" != true ]]; then
    echo "[INFO] --no-reconcile set; not poking the operator."
    exit 0
fi

# --- Reconcile ---------------------------------------------------------------
# An operator reconciles on spec change. Re-applying an unchanged CR bumps
# nothing, so touch an annotation to force a new generation and wake the
# controller. Harmless on a first create - it just makes re-runs behave the
# same as the initial apply.
echo "[INFO] Triggering reconciliation..."
oc annotate "${CR_KIND}" "${CR_NAME}" -n "${CR_NS}" --overwrite \
    "cpd.ibm.com/reconcile-requested-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null

# An operand CR only progresses if a controller is actually watching its kind.
# A non-OLM install may have no operator for this kind at all, in which case the
# CR sits at an empty status forever - report that rather than waiting on it.
CR_GROUP="$(grep -m1 '^apiVersion:' "${RENDERED_FILE}" | awk '{print $2}' | cut -d/ -f1)"
CR_KIND_LC="${CR_KIND:l}"
# Plurals are not derivable (CCS -> ccs, not ccss), so ask the API for the real
# resource name rather than guessing.
if ! oc api-resources --api-group="${CR_GROUP}" -o name 2>/dev/null | grep -qE "^${CR_KIND_LC}s?\.${CR_GROUP}$"; then
    echo "[WARN] No CRD registered for ${CR_KIND} in group ${CR_GROUP}."
fi

sleep 5
CR_STATUS_JSON="$(oc get "${CR_KIND}" "${CR_NAME}" -n "${CR_NS}" -o jsonpath='{.status}' 2>/dev/null || echo '')"
if [[ -z "${CR_STATUS_JSON}" || "${CR_STATUS_JSON}" == "{}" ]]; then
    echo "[WARN] ${CR_KIND}/${CR_NAME} still reports an empty status."
    echo "[WARN] Nothing appears to be reconciling it. Check that an operator for"
    echo "[WARN] ${CR_KIND} is running and watching namespace ${CR_NS}:"
    echo "         oc get pods -n \${PROJECT_CPD_INST_OPERATORS} | grep -i ${CR_KIND:l}"
    echo "[WARN] On a non-OLM install (non_olm_deploy: true) the operator must be"
    echo "[WARN] deployed by the install step for this component before the CR runs."
fi

if [[ "${WAIT}" != true ]]; then
    echo "[INFO] Check progress with:"
    echo "  oc get ${CR_KIND} ${CR_NAME} -n ${CR_NS}"
    exit 0
fi

# --- Watch -------------------------------------------------------------------
# CP4D operands report state in a kind-specific field - analyticsengineStatus,
# ccsStatus, and so on - so derive the key from the kind rather than guessing a
# single common field name.
STATUS_KEY="${CR_KIND_LC}Status"

echo "[INFO] Watching reconciliation (timeout ${WAIT_TIMEOUT}s). Ctrl-C to stop; the operator keeps running."
_deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
_last=""
while (( $(date +%s) < _deadline )); do
    _state="$(oc get "${CR_KIND}" "${CR_NAME}" -n "${CR_NS}" \
                -o jsonpath="{.status.${STATUS_KEY}}" 2>/dev/null || echo '')"
    _prog="$(oc get "${CR_KIND}" "${CR_NAME}" -n "${CR_NS}" \
                -o jsonpath='{.status.progress}{" "}{.status.progressMessage}' 2>/dev/null || echo '')"
    _s="${_state:-<none>} ${_prog}"

    if [[ -n "${_prog// /}" || -n "${_state}" ]] && [[ "${_s}" != "${_last}" ]]; then
        echo "[$(date -u +%H:%M:%S)] ${_s}"
        _last="${_s}"
    fi

    case "${_state}" in
        Completed|Ready)
            echo "[INFO] ${CR_KIND}/${CR_NAME} reconciled successfully."
            exit 0 ;;
        Failed|Error)
            echo "[ERROR] ${CR_KIND}/${CR_NAME} reconciliation failed." >&2
            oc get "${CR_KIND}" "${CR_NAME}" -n "${CR_NS}" \
                -o jsonpath='{.status.errorHistory}' 2>/dev/null || true
            echo
            exit 1 ;;
    esac
    sleep 15
done

echo "[WARN] Timed out after ${WAIT_TIMEOUT}s; reconciliation is still running."
echo "[WARN] Last reported state: ${_last:-<empty>}"
echo "  oc get ${CR_KIND} ${CR_NAME} -n ${CR_NS}"
exit 1
