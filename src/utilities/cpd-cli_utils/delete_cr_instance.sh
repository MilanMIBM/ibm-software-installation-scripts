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
Delete a CP4D operand CR by name and, optionally, the resources its operator
created for it.

  delete_cr_instance.sh <Kind>/<name> [options]
  delete_cr_instance.sh <Kind> <name>  [options]
  delete_cr_instance.sh <template.yaml.j2> [options]

A template name is resolved the same way as create_cr_instance.sh: a bare name
is looked up in src/cr_yaml_examples/ and the kind/name/namespace are read out
of it, so "ccs" deletes whatever "create_cr_instance.sh ccs" created.

Deleting the CR is enough on a healthy install - the operator garbage-collects
the workloads it owns. --purge is the recovery path for when the operator is
already gone and its leftovers must be removed by hand.

Options:
  -n, --namespace NS   Namespace of the CR (default: PROJECT_CPD_INST_OPERANDS)
      --purge          Also delete ownerless leftovers labelled for this CR
                       (deployments, statefulsets, jobs, services, routes,
                       configmaps, secrets, serviceaccounts, PVCs)
      --purge-pvc      With --purge, include PersistentVolumeClaims.
                       DESTROYS DATA. Off by default.
      --force          Strip finalizers if the CR will not go away within
                       --timeout. Use only when the operator is already gone.
      --dry-run        Show what would be deleted, delete nothing
  -y, --yes            Skip the confirmation prompt
  -w, --wait [SECS]    Wait for the CR to actually disappear (default 600s)
      --timeout SECS   Alias for the --wait timeout
  -h, --help           Show this help
EOF
}

KIND=""
NAME=""
NAMESPACE=""
PURGE=false
PURGE_PVC=false
FORCE=false
DRY_RUN=false
ASSUME_YES=false
WAIT=false
WAIT_TIMEOUT=600
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)   NAMESPACE="${2:-}"; shift 2 ;;
        --purge)          PURGE=true; shift ;;
        --purge-pvc)      PURGE=true; PURGE_PVC=true; shift ;;
        --force)          FORCE=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -y|--yes)         ASSUME_YES=true; shift ;;
        -w|--wait)
            WAIT=true
            if [[ "${2:-}" == <-> ]]; then WAIT_TIMEOUT="$2"; shift 2; else shift; fi ;;
        --timeout)        WAIT=true; WAIT_TIMEOUT="${2:-600}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        -*)               echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                POSITIONAL+=("$1"); shift ;;
    esac
done

if (( ${#POSITIONAL[@]} == 0 )); then
    echo "[ERROR] No CR given." >&2
    usage >&2
    exit 1
fi

# --- Resolve the target ------------------------------------------------------
# Three accepted spellings: a template (bare name or path), "Kind/name", or
# "Kind name". A template is the authoritative source for the namespace too, so
# check for it first.
_target="${POSITIONAL[1]}"
TEMPLATE=""

if [[ -f "${_target}" ]]; then
    TEMPLATE="${_target}"
else
    for _cand in \
        "${REPO_ROOT}/src/cr_yaml_examples/${_target}" \
        "${REPO_ROOT}/src/cr_yaml_examples/${_target}.yaml.j2"; do
        if [[ -f "${_cand}" ]]; then TEMPLATE="${_cand}"; break; fi
    done
    unset _cand
fi

if [[ -n "${TEMPLATE}" ]]; then
    # Only the identity fields are needed, and those are plain literals in the
    # templates, so read them directly rather than pulling in Jinja2. The one
    # exception is the namespace, which is a variable - fall back to the env.
    KIND="$(grep -m1 '^kind:' "${TEMPLATE}" | awk '{print $2}')"
    NAME="$(awk '/^metadata:/{m=1;next} m&&/^  name:/{print $2;exit}' "${TEMPLATE}")"
    _tmpl_ns="$(awk '/^metadata:/{m=1;next} m&&/^  namespace:/{print $2;exit}' "${TEMPLATE}")"
    if [[ -z "${NAMESPACE}" && "${_tmpl_ns}" != *'{{'* ]]; then
        NAMESPACE="${_tmpl_ns}"
    fi
    echo "[INFO] Resolved ${TEMPLATE#${REPO_ROOT}/} -> ${KIND}/${NAME}"
elif [[ "${_target}" == */* ]]; then
    KIND="${_target%%/*}"
    NAME="${_target#*/}"
else
    KIND="${_target}"
    NAME="${POSITIONAL[2]:-}"
fi

if [[ -z "${KIND}" || -z "${NAME}" ]]; then
    echo "[ERROR] Could not work out kind and name from: ${POSITIONAL[*]}" >&2
    echo "[INFO] Available templates in src/cr_yaml_examples/:" >&2
    ls -1 "${REPO_ROOT}/src/cr_yaml_examples/" 2>/dev/null | sed 's/^/  - /' >&2
    exit 1
fi

NAMESPACE="${NAMESPACE:-${PROJECT_CPD_INST_OPERANDS:-}}"
if [[ -z "${NAMESPACE}" ]]; then
    echo "[ERROR] No namespace: pass -n, or set PROJECT_CPD_INST_OPERANDS in ./cpd_vars.sh." >&2
    exit 1
fi

# Stripping finalizers only ever happens after the wait loop gives the operator
# its chance, so --force without --wait would silently do nothing. Imply it.
if [[ "${FORCE}" == true && "${WAIT}" != true ]]; then
    WAIT=true
    echo "[INFO] --force implies --wait (${WAIT_TIMEOUT}s before stripping finalizers)."
fi

# Same for --purge: the sweep runs after the CR is gone, and on a CR held by a
# finalizer an immediate re-scan finds nothing because teardown has not started.
if [[ "${PURGE}" == true && "${WAIT}" != true ]]; then
    WAIT=true
    echo "[INFO] --purge implies --wait (${WAIT_TIMEOUT}s) so teardown can finish first."
fi

# --- Connect -----------------------------------------------------------------
if [[ -z "${OC_LOGIN:-}" ]]; then
    echo "[ERROR] OC_LOGIN is not set. Set it in ./cpd_vars.sh before running this script." >&2
    exit 1
fi

eval "${OC_LOGIN}"

echo "[INFO] Target cluster: $(oc whoami --show-server 2>/dev/null || echo unknown)"
echo "[INFO] ${KIND}/${NAME} in namespace ${NAMESPACE}"

if ! oc get "${KIND}" "${NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "[WARN] ${KIND}/${NAME} not found in ${NAMESPACE}; nothing to delete."
    CR_PRESENT=false
else
    CR_PRESENT=true
fi

# --- Work out what --purge would take ----------------------------------------
# The operator owns what it created, so a CR delete cascades on its own. What
# survives is anything whose ownerRef was lost or never set - that is what the
# label sweep is for. Two label conventions appear on CP4D operands, so match
# either.
PURGE_KINDS=(deployment statefulset daemonset job cronjob service route
             configmap secret serviceaccount rolebinding role)
if [[ "${PURGE_PVC}" == true ]]; then
    PURGE_KINDS+=(persistentvolumeclaim)
fi

# CP4D operands do NOT label their workloads with the CR's own name: AE's
# deployments carry app.kubernetes.io/instance=ibm-analyticsengine-prod (the
# chart release) and icpdsupport/addOnId=spark (the addon, not the kind). So a
# selector built from ${NAME}/${KIND} matches nothing. Derive the selectors from
# what actually carries the CR's ownerReference instead, and keep the guessed
# ones only as an additional net.
LABEL_SELECTORS=(
    "app.kubernetes.io/instance=${NAME}"
    "icpdsupport/addOnId=${KIND:l}"
)

# Everything the operator created points back at the CR via ownerReferences, so
# ask the cluster which objects those are rather than guessing labels. This is
# the reliable path; it only needs the CR's uid, which survives until the CR is
# actually gone.
owned_targets() {
    local _uid _kinds
    _uid="$(oc get "${KIND}" "${NAME}" -n "${NAMESPACE}" \
                -o jsonpath='{.metadata.uid}' 2>/dev/null || echo '')"
    [[ -z "${_uid}" ]] && return 0
    _kinds="${(j:,:)PURGE_KINDS}"
    oc get "${_kinds}" -n "${NAMESPACE}" \
        -o "jsonpath={range .items[?(@.metadata.ownerReferences[0].uid=='${_uid}')]}{.kind}/{.metadata.name}{\"\n\"}{end}" \
        2>/dev/null | tr '[:upper:]' '[:lower:]' | sed '/^$/d' || true
}

purge_targets() {
    # Print "kind/name" for every leftover matching any selector, deduped.
    local _sel _kinds
    _kinds="${(j:,:)PURGE_KINDS}"
    {
        # Owned objects recorded before the CR went away, plus a live lookup
        # while the uid still resolves.
        [[ -n "${OWNED_SNAPSHOT:-}" ]] && echo "${OWNED_SNAPSHOT}"
        owned_targets
        for _sel in "${LABEL_SELECTORS[@]}"; do
            oc get "${_kinds}" -n "${NAMESPACE}" -l "${_sel}" \
                -o name --ignore-not-found 2>/dev/null || true
        done
    } | sed '/^$/d' | sort -u
}

# Capture ownership while the CR still exists - after it is deleted the uid is
# unresolvable and the only remaining handle on orphans would be the labels.
OWNED_SNAPSHOT=""
if [[ "${PURGE}" == true && "${CR_PRESENT}" == true ]]; then
    OWNED_SNAPSHOT="$(owned_targets)"
fi

if [[ "${PURGE}" == true ]]; then
    echo "[INFO] Scanning for labelled leftovers..."
    PURGE_LIST="$(purge_targets)"
    if [[ -n "${PURGE_LIST}" ]]; then
        echo "[INFO] --purge would also delete:"
        echo "${PURGE_LIST}" | sed 's/^/    /'
    else
        echo "[INFO] No labelled leftovers found."
    fi
    if [[ "${PURGE_PVC}" == true ]]; then
        echo "[WARN] --purge-pvc is set: PersistentVolumeClaims above will be"
        echo "[WARN] deleted and their data is NOT recoverable."
    fi
fi

if [[ "${DRY_RUN}" == true ]]; then
    echo "[INFO] Dry run; nothing was deleted."
    exit 0
fi

if [[ "${CR_PRESENT}" == false && "${PURGE}" != true ]]; then
    exit 0
fi

# --- Confirm -----------------------------------------------------------------
if [[ "${ASSUME_YES}" != true ]]; then
    echo -n "Delete ${KIND}/${NAME} from the cluster above? [y/N] "
    read -r _reply
    if [[ ! "${_reply}" =~ ^[Yy]$ ]]; then
        echo "[INFO] Aborted, nothing deleted."
        exit 0
    fi
fi

# --- Delete the CR -----------------------------------------------------------
# --wait=false returns as soon as the delete is accepted; the operator then
# tears down its children while its finalizer holds the CR. Waiting is handled
# below so a stuck finalizer is reported rather than hanging oc forever.
if [[ "${CR_PRESENT}" == true ]]; then
    oc delete "${KIND}" "${NAME}" -n "${NAMESPACE}" --wait=false
    echo "[INFO] Delete requested for ${KIND}/${NAME}."
fi

if [[ "${WAIT}" == true && "${CR_PRESENT}" == true ]]; then
    echo "[INFO] Waiting up to ${WAIT_TIMEOUT}s for ${KIND}/${NAME} to disappear."
    _deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
    _gone=false
    while (( $(date +%s) < _deadline )); do
        if ! oc get "${KIND}" "${NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            _gone=true
            break
        fi
        sleep 10
    done

    if [[ "${_gone}" == true ]]; then
        echo "[INFO] ${KIND}/${NAME} is gone."
    else
        echo "[WARN] ${KIND}/${NAME} is still present after ${WAIT_TIMEOUT}s."
        _finalizers="$(oc get "${KIND}" "${NAME}" -n "${NAMESPACE}" \
                        -o jsonpath='{.metadata.finalizers}' 2>/dev/null || echo '')"
        echo "[WARN] Finalizers: ${_finalizers:-<none>}"
        if [[ "${FORCE}" == true ]]; then
            # A finalizer is the operator's promise to clean up first. Removing
            # it makes the CR vanish while whatever it owned stays behind, which
            # is why this is opt-in and why --purge exists to mop up after.
            #
            # The dangerous case is a CR stuck mid-INSTALL rather than
            # mid-teardown: the operator is alive and still creating things, so
            # forcing orphans a live workload set with no controller. Count what
            # the CR still owns and make the user look at it first.
            _owned="$(owned_targets)"
            _owned_n=0
            [[ -n "${_owned}" ]] && _owned_n="$(echo "${_owned}" | wc -l | tr -d ' ')"
            if (( _owned_n > 0 )); then
                echo "[WARN] ${KIND}/${NAME} still owns ${_owned_n} object(s):"
                echo "${_owned}" | sed 's/^/    /'
                echo "[WARN] Stripping the finalizer now ORPHANS these - no controller"
                echo "[WARN] will own or clean them up afterwards."
                if [[ "${PURGE}" != true ]]; then
                    echo "[ERROR] Refusing to strip finalizers while ${_owned_n} owned object(s)"
                    echo "[ERROR] remain and --purge was not given. Either add --purge to"
                    echo "[ERROR] delete them too, or fix the operator so it can finish." >&2
                    exit 1
                fi
                if [[ "${ASSUME_YES}" != true ]]; then
                    echo -n "Strip finalizers and orphan/purge the ${_owned_n} object(s) above? [y/N] "
                    read -r _freply
                    if [[ ! "${_freply}" =~ ^[Yy]$ ]]; then
                        echo "[INFO] Aborted; finalizers left in place."
                        exit 1
                    fi
                fi
            fi
            echo "[WARN] --force set; stripping finalizers."
            oc patch "${KIND}" "${NAME}" -n "${NAMESPACE}" \
                --type=merge -p '{"metadata":{"finalizers":null}}'
        else
            echo "[WARN] The operator is probably still tearing things down, or is"
            echo "[WARN] no longer running. If the operator is gone, re-run with --force."
            exit 1
        fi
    fi
fi

# --- Purge leftovers ---------------------------------------------------------
if [[ "${PURGE}" == true ]]; then
    # Re-scan: the CR delete has run since the earlier scan, so most of the
    # first list is already gone and deleting from it would just print errors.
    echo "[INFO] Re-scanning for leftovers..."
    PURGE_LIST="$(purge_targets)"
    if [[ -z "${PURGE_LIST}" ]]; then
        echo "[INFO] Nothing left to purge."
    else
        echo "${PURGE_LIST}" | sed 's/^/    /'
        echo "${PURGE_LIST}" | xargs oc delete -n "${NAMESPACE}" --ignore-not-found
        echo "[INFO] Purge complete."
    fi
fi

# A CR held by a finalizer still lists with its last-known status, which reads
# exactly like a delete that never happened. Say plainly which it is.
if oc get "${KIND}" "${NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    _deleting="$(oc get "${KIND}" "${NAME}" -n "${NAMESPACE}" \
                    -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo '')"
    if [[ -n "${_deleting}" ]]; then
        echo "[WARN] ${KIND}/${NAME} is TERMINATING (deletionTimestamp ${_deleting})."
        echo "[WARN] It still lists below with its last-known status until the"
        echo "[WARN] operator releases its finalizer:"
        oc get "${KIND}" "${NAME}" -n "${NAMESPACE}" \
            -o jsonpath='{"  finalizers: "}{.metadata.finalizers}{"\n"}' 2>/dev/null || true
        echo "[WARN] Re-run with --force to strip them if the operator is gone."
    else
        echo "[WARN] ${KIND}/${NAME} still exists and is NOT marked for deletion."
    fi
else
    echo "[INFO] ${KIND}/${NAME} is gone."
fi

echo "[INFO] Remaining ${KIND} in ${NAMESPACE}:"
oc get "${KIND}" -n "${NAMESPACE}" 2>/dev/null || echo "  (none)"
