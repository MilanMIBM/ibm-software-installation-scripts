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
Link a pull secret to EVERY service account in a namespace, not just 'default'.

  set_namespace_pull_secret.sh [namespace] [options]

Why this exists alongside set_default_pull_secret.sh:
  set_default_pull_secret.sh links the secret to the 'default' service account.
  That only covers pods that actually run as 'default'. CP4D operands almost
  never do - they run under their own service accounts (zen-*, wxd-*, db2u,
  smarts-*, ...), so a secret linked only to 'default' never reaches them.
  This script covers all of them.

  A missing pull secret referenced by a service account is silently ignored by
  Kubernetes. Pods keep running on cached images and only fail later, on a new
  node or after an image GC, as ImagePullBackOff. So "nothing is broken right
  now" is not evidence that the secrets are correct.

Argument shapes:
  set_namespace_pull_secret.sh                   Act on PROJECT_CPD_INST_OPERANDS
                                                 from ./cpd_vars.sh.
  set_namespace_pull_secret.sh cpd-operands      Act on that namespace.
  set_namespace_pull_secret.sh ns1 ns2           Act on several namespaces.

Options:
  -s, --secret NAME        Secret to link (default: IMAGE_PULL_SECRET, else
                           'pull-secret')
  -f, --from-namespace NS  Namespace holding the source secret
                           (default: PULL_SECRET_NAMESPACE, else
                           'openshift-config')
      --operands           Target PROJECT_CPD_INST_OPERANDS (the default)
      --operators          Target PROJECT_CPD_INST_OPERATORS
      --prune-missing      Also remove imagePullSecrets entries that point at
                           secrets which do not exist in the namespace. These
                           are dead references (e.g. an ibm-entitlement-key
                           left behind by an install that never created it).
      --no-entitlement-key Do not create 'ibm-entitlement-key'. On by default:
                           CP4D operands and several operator-generated pods
                           reference that name directly, so the namespace needs
                           a secret under it as well as under the source name.
                           It is created with the same contents as the source
                           secret and linked to the same service accounts.
      --restart            Roll the namespace's workloads afterwards so pods
                           pick the change up. Off by default: linking a secret
                           to a service account only affects pods created after
                           the link, but restarting 300+ pods is disruptive and
                           should be a deliberate choice.
      --dry-run            Print what would be done, change nothing
  -y, --yes                Skip the confirmation prompt
  -h, --help               Show this help

Environment defaults (all overridable by the flags above):
  IMAGE_PULL_SECRET / PULL_SECRET_NAME   source secret name
  PULL_SECRET_NAMESPACE                  source namespace
  CREATE_ENTITLEMENT_KEY_SECRET          'false' implies --no-entitlement-key
EOF
}

DEFAULT_SECRET="${PULL_SECRET_NAME:-${IMAGE_PULL_SECRET:-pull-secret}}"
SECRET_NAME=""
SOURCE_NAMESPACE="${PULL_SECRET_NAMESPACE:-openshift-config}"
ENTITLEMENT_SECRET_NAME="ibm-entitlement-key"
CREATE_ENTITLEMENT_KEY="${CREATE_ENTITLEMENT_KEY_SECRET:-true}"
PRUNE_MISSING=false
RESTART=false
DRY_RUN=false
ASSUME_YES=true
TARGET_MODE=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--secret)          SECRET_NAME="${2:-}"; shift 2 ;;
        -f|--from-namespace)  SOURCE_NAMESPACE="${2:-}"; shift 2 ;;
        --operands)           TARGET_MODE="operands"; shift ;;
        --operators)          TARGET_MODE="operators"; shift ;;
        --no-entitlement-key) CREATE_ENTITLEMENT_KEY=false; shift ;;
        --prune-missing)      PRUNE_MISSING=true; shift ;;
        --restart)            RESTART=true; shift ;;
        --dry-run)            DRY_RUN=true; shift ;;
        -y|--yes)             ASSUME_YES=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        -*)                   echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                    POSITIONAL+=("$1"); shift ;;
    esac
done

SECRET_NAME="${SECRET_NAME:-${DEFAULT_SECRET}}"
if [[ -z "${SECRET_NAME}" ]]; then
    echo "[ERROR] No secret name given and no default could be worked out." >&2
    exit 1
fi

# Namespaces named positionally win over --operands/--operators, and mixing the
# two is a contradiction rather than something to silently resolve.
NAMESPACES=()
if (( ${#POSITIONAL[@]} > 0 )); then
    if [[ -n "${TARGET_MODE}" ]]; then
        echo "[ERROR] Namespaces were named on the command line; drop --${TARGET_MODE}." >&2
        exit 1
    fi
    NAMESPACES=("${POSITIONAL[@]}")
else
    case "${TARGET_MODE:-operands}" in
        operands)  _ns="${PROJECT_CPD_INST_OPERANDS:-}" ;;
        operators) _ns="${PROJECT_CPD_INST_OPERATORS:-}" ;;
    esac
    if [[ -z "${_ns}" ]]; then
        echo "[ERROR] No namespace given and PROJECT_CPD_INST_* is not set in ./cpd_vars.sh." >&2
        exit 1
    fi
    NAMESPACES=("${_ns}")
    unset _ns
fi

# --- Connect -----------------------------------------------------------------
if [[ -z "${OC_LOGIN:-}" ]]; then
    echo "[ERROR] OC_LOGIN is not set. Set it in ./cpd_vars.sh before running this script." >&2
    exit 1
fi

eval "${OC_LOGIN}"

echo "[INFO] Target cluster: $(oc whoami --show-server 2>/dev/null || echo unknown)"

# --- Source secret -----------------------------------------------------------
if ! oc get secret "${SECRET_NAME}" -n "${SOURCE_NAMESPACE}" &>/dev/null; then
    echo "[ERROR] Secret '${SECRET_NAME}' not found in namespace '${SOURCE_NAMESPACE}'." >&2
    echo "[ERROR] Pass -f/--from-namespace if it lives somewhere else." >&2
    exit 1
fi

_secret_type="$(oc get secret "${SECRET_NAME}" -n "${SOURCE_NAMESPACE}" \
                    -o jsonpath='{.type}' 2>/dev/null || echo '')"
if [[ "${_secret_type}" != "kubernetes.io/dockerconfigjson" && "${_secret_type}" != "kubernetes.io/dockercfg" ]]; then
    echo "[WARN] Secret '${SECRET_NAME}' has type '${_secret_type:-<none>}', not a docker"
    echo "[WARN] config secret. Linking it for pull will not make image pulls work."
fi

SECRET_BODY="$(oc get secret "${SECRET_NAME}" -n "${SOURCE_NAMESPACE}" -o json \
    | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.ownerReferences)')"

# The entitlement key is the same credential under a second name: CP4D operands
# and operator-generated pods reference 'ibm-entitlement-key' literally, so a
# namespace that only has the source secret still ends in ImagePullBackOff.
# Renaming a copy of the source body is enough - the contents are identical.
SECRET_NAMES=("${SECRET_NAME}")
ENTITLEMENT_BODY=""
if [[ "${CREATE_ENTITLEMENT_KEY}" == true && "${SECRET_NAME}" != "${ENTITLEMENT_SECRET_NAME}" ]]; then
    ENTITLEMENT_BODY="$(echo "${SECRET_BODY}" \
        | jq --arg n "${ENTITLEMENT_SECRET_NAME}" '.metadata.name = $n')"
    SECRET_NAMES+=("${ENTITLEMENT_SECRET_NAME}")
fi

# Look a body up by name rather than keeping two parallel arrays in step.
secret_body_for() {
    case "$1" in
        "${ENTITLEMENT_SECRET_NAME}") [[ -n "${ENTITLEMENT_BODY}" ]] && { echo "${ENTITLEMENT_BODY}"; return 0; } ;;
    esac
    echo "${SECRET_BODY}"
}

echo "[INFO] Secret:  ${SECRET_NAME} (from ${SOURCE_NAMESPACE})"
if [[ -n "${ENTITLEMENT_BODY}" ]]; then
    echo "[INFO] Also creating '${ENTITLEMENT_SECRET_NAME}' with the same contents."
fi
echo "[INFO] Targets: ${NAMESPACES[*]}"

if [[ "${DRY_RUN}" != true && "${ASSUME_YES}" != true ]]; then
    echo -n "Link ${SECRET_NAMES[*]} to every service account in the namespace(s) above? [y/N] "
    read -r _reply
    if [[ ! "${_reply}" =~ ^[Yy]$ ]]; then
        echo "[INFO] Aborted, nothing changed."
        exit 0
    fi
fi

LINKED=0
ALREADY=0
PRUNED=0
FAILED=0
FAILED_SA=()

process_namespace() {
    local ns="$1"

    if ! oc get namespace "${ns}" &>/dev/null; then
        echo "[ERROR] Namespace '${ns}' does not exist, skipping."
        return 1
    fi

    echo "[INFO] --- ${ns} ---"

    # Copy the secret in first: linking a service account to a secret that is
    # not in the namespace would create exactly the dangling reference this
    # script is meant to clean up.
    local want
    for want in "${SECRET_NAMES[@]}"; do
        if [[ "${DRY_RUN}" == true ]]; then
            echo "[DRY-RUN] Would copy '${want}' into '${ns}'."
        else
            secret_body_for "${want}" | oc apply -n "${ns}" -f - >/dev/null
        fi
    done

    # Secrets that actually exist here, used to spot dead references below. On a
    # dry run nothing was copied, so add the names a real run would have created
    # - otherwise --dry-run reports pruning the very secrets it would create.
    local -a existing_secrets
    existing_secrets=("${(@f)$(oc get secrets -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)}")
    [[ "${DRY_RUN}" == true ]] && existing_secrets+=("${SECRET_NAMES[@]}")

    local -a service_accounts
    service_accounts=("${(@f)$(oc get sa -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)}")

    local sa
    for sa in "${service_accounts[@]}"; do
        [[ -z "${sa}" ]] && continue

        local current
        current=$(oc get sa "${sa}" -n "${ns}" -o jsonpath='{range .imagePullSecrets[*]}{.name}{"\n"}{end}' 2>/dev/null || true)

        # Drop references to secrets that no longer exist. Kubernetes ignores
        # these silently, so they survive indefinitely and make it look like a
        # service account has credentials it does not have.
        if [[ "${PRUNE_MISSING}" == true ]]; then
            local dead
            for dead in ${(f)current}; do
                [[ -z "${dead}" ]] && continue
                # The SA's own auto-generated dockercfg token is managed by the
                # cluster; it can lag behind a rotation and must not be touched.
                [[ "${dead}" == "${sa}-dockercfg-"* || "${dead}" == *-dockercfg-* ]] && continue
                if [[ " ${existing_secrets[*]} " != *" ${dead} "* ]]; then
                    if [[ "${DRY_RUN}" == true ]]; then
                        echo "[DRY-RUN] Would remove dead reference '${dead}' from sa/${sa}."
                    else
                        # No 'oc secrets unlink --for=pull', so patch the list
                        # directly, filtering out just the dead entry.
                        local patched
                        patched=$(oc get sa "${sa}" -n "${ns}" -o json \
                            | jq --arg d "${dead}" '{imagePullSecrets: [(.imagePullSecrets // [])[] | select(.name != $d)]}')
                        oc patch sa "${sa}" -n "${ns}" --type=merge -p "${patched}" >/dev/null
                        echo "[INFO] Removed dead pull-secret reference '${dead}' from sa/${sa}."
                    fi
                    (( ++PRUNED ))
                fi
            done
        fi

        local link
        for link in "${SECRET_NAMES[@]}"; do
            if echo "${current}" | grep -qx "${link}"; then
                (( ++ALREADY ))
                continue
            fi

            if [[ "${DRY_RUN}" == true ]]; then
                echo "[DRY-RUN] Would link '${link}' to sa/${sa}."
                (( ++LINKED ))
                continue
            fi

            if oc secrets link "${sa}" "${link}" --for=pull -n "${ns}" 2>/dev/null; then
                echo "[INFO] Linked '${link}' to sa/${sa}."
                (( ++LINKED ))
            else
                echo "[ERROR] Could not link '${link}' to sa/${sa}."
                FAILED_SA+=("${ns}/${sa} (${link})")
                (( ++FAILED ))
            fi
        done
    done

    if [[ "${RESTART}" == true ]]; then
        if [[ "${DRY_RUN}" == true ]]; then
            echo "[DRY-RUN] Would restart deployments and statefulsets in '${ns}'."
        else
            echo "[INFO] Restarting workloads in '${ns}' so pods pick up the new secret..."
            oc rollout restart deployment -n "${ns}" 2>/dev/null || true
            oc rollout restart statefulset -n "${ns}" 2>/dev/null || true
        fi
    fi

    return 0
}

for _ns in "${NAMESPACES[@]}"; do
    _rc=0
    process_namespace "${_ns}" || _rc=$?
    (( _rc != 0 )) && (( ++FAILED ))
done
unset _ns _rc

echo "[INFO] ---"
if [[ "${DRY_RUN}" == true ]]; then
    echo "[INFO] Dry run: ${LINKED} service account(s) would be linked, ${ALREADY} already correct, ${PRUNED} dead reference(s) would be removed."
    exit 0
fi

echo "[INFO] Linked: ${LINKED}  Already correct: ${ALREADY}  Pruned: ${PRUNED}  Failed: ${FAILED}"
if (( FAILED > 0 )); then
    printf '[ERROR] Failed on: %s\n' "${FAILED_SA[*]}" >&2
    exit 1
fi

if [[ "${RESTART}" != true ]]; then
    echo "[INFO] Note: existing pods keep their old pull secrets until they are"
    echo "[INFO] recreated. Re-run with --restart to roll the workloads now."
fi
