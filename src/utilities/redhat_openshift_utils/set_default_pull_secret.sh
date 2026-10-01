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
Copy a pull secret into one or more projects and link it to the 'default'
service account so pods there can pull images without naming it explicitly.

  set_default_pull_secret.sh [secret] [project ...] [options]

This is the standalone form of the pull-secret step in
2.0.1_preliminary_project_setup.sh, for the case where the projects already
exist and only the secret has to be (re)applied.

Argument shapes:
  set_default_pull_secret.sh                     Apply the default secret
                                                 (IMAGE_PULL_SECRET, else
                                                 'pull-secret') to every project
                                                 in the cluster. If that secret
                                                 does not exist in the source
                                                 namespace, do nothing.
  set_default_pull_secret.sh my-secret           Apply 'my-secret' to every
                                                 project in the cluster.
  set_default_pull_secret.sh my-secret ns1 ns2   Apply 'my-secret' to ns1, ns2.
  set_default_pull_secret.sh --cpd-projects      Apply to the CPD projects named
                                                 in ./cpd_vars.sh instead of all.

"Every project" excludes OpenShift's own namespaces (openshift*, kube*,
default) unless --include-system is given: those service accounts are managed
by the cluster and are not ours to change.

Options:
  -s, --secret NAME        Secret to copy (default: IMAGE_PULL_SECRET, else
                           'pull-secret'). Also accepted as the first
                           positional argument.
  -f, --from-namespace NS  Namespace holding the source secret
                           (default: PULL_SECRET_NAMESPACE, else
                           'openshift-config')
      --cpd-projects       Target the PROJECT_* namespaces from ./cpd_vars.sh
      --all-projects       Target every project in the cluster (the default
                           when no projects are named)
      --include-system     Do not skip openshift*/kube*/default namespaces
      --no-overwrite       Leave projects that already have the secret linked
                           alone (default is to re-apply; equivalent to
                           OVERWRITE_CURRENT_SECRET=false)
      --dry-run            Print what would be done, change nothing
  -y, --yes                Skip the confirmation prompt
  -h, --help               Show this help

Environment defaults (all overridable by the flags above):
  IMAGE_PULL_SECRET / PULL_SECRET_NAME   source secret name
  PULL_SECRET_NAMESPACE                  source namespace
  OVERWRITE_CURRENT_SECRET               'false' implies --no-overwrite
EOF
}

# The preliminary-setup script reads PULL_SECRET_NAME; cpd_vars.sh exports
# IMAGE_PULL_SECRET. Accept either so this util lines up with both.
DEFAULT_SECRET="${PULL_SECRET_NAME:-${IMAGE_PULL_SECRET:-pull-secret}}"
SECRET_NAME=""
SOURCE_NAMESPACE="${PULL_SECRET_NAMESPACE:-openshift-config}"
OVERWRITE="${OVERWRITE_CURRENT_SECRET:-true}"
INCLUDE_SYSTEM=false
DRY_RUN=false
ASSUME_YES=true
TARGET_MODE=""          # "" (infer), all, cpd, explicit
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--secret)          SECRET_NAME="${2:-}"; shift 2 ;;
        -f|--from-namespace)  SOURCE_NAMESPACE="${2:-}"; shift 2 ;;
        --cpd-projects)       TARGET_MODE="cpd"; shift ;;
        --all-projects)       TARGET_MODE="all"; shift ;;
        --include-system)     INCLUDE_SYSTEM=true; shift ;;
        --no-overwrite)       OVERWRITE=false; shift ;;
        --overwrite)          OVERWRITE=true; shift ;;
        --dry-run)            DRY_RUN=true; shift ;;
        -y|--yes)             ASSUME_YES=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        -*)                   echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                    POSITIONAL+=("$1"); shift ;;
    esac
done

# First positional is the secret unless -s already named one; the rest are
# projects. This keeps the documented "set_default_pull_secret.sh my-secret ns1"
# shape working without a flag.
if (( ${#POSITIONAL[@]} > 0 )); then
    if [[ -z "${SECRET_NAME}" ]]; then
        SECRET_NAME="${POSITIONAL[1]}"
        PROJECTS=("${POSITIONAL[@]:1}")
    else
        PROJECTS=("${POSITIONAL[@]}")
    fi
else
    PROJECTS=()
fi

# No secret named anywhere: fall back to the environment/'pull-secret'. This is
# the "if neither is provided" case, and it is the one where a missing source
# secret is not an error - there is nothing the caller asked for.
SECRET_WAS_NAMED=true
if [[ -z "${SECRET_NAME}" ]]; then
    SECRET_NAME="${DEFAULT_SECRET}"
    SECRET_WAS_NAMED=false
fi

if [[ -z "${SECRET_NAME}" ]]; then
    echo "[ERROR] No secret name given and no default could be worked out." >&2
    exit 1
fi

if (( ${#PROJECTS[@]} > 0 )); then
    if [[ -n "${TARGET_MODE}" && "${TARGET_MODE}" != "explicit" ]]; then
        echo "[ERROR] Projects were named on the command line; drop --${TARGET_MODE}-projects." >&2
        exit 1
    fi
    TARGET_MODE="explicit"
fi
TARGET_MODE="${TARGET_MODE:-all}"

# --- Connect -----------------------------------------------------------------
if [[ -z "${OC_LOGIN:-}" ]]; then
    echo "[ERROR] OC_LOGIN is not set. Set it in ./cpd_vars.sh before running this script." >&2
    exit 1
fi

eval "${OC_LOGIN}"

echo "[INFO] Target cluster: $(oc whoami --show-server 2>/dev/null || echo unknown)"

# --- Source secret -----------------------------------------------------------
if ! oc get secret "${SECRET_NAME}" -n "${SOURCE_NAMESPACE}" &>/dev/null; then
    if [[ "${SECRET_WAS_NAMED}" == false ]]; then
        # Nobody asked for this secret by name - it was only the default guess,
        # so its absence means "nothing to do", not a failure.
        echo "[INFO] Default secret '${SECRET_NAME}' not found in '${SOURCE_NAMESPACE}'; nothing to do."
        exit 0
    fi
    echo "[ERROR] Secret '${SECRET_NAME}' not found in namespace '${SOURCE_NAMESPACE}'." >&2
    echo "[ERROR] Pass -f/--from-namespace if it lives somewhere else." >&2
    exit 1
fi

_secret_type="$(oc get secret "${SECRET_NAME}" -n "${SOURCE_NAMESPACE}" \
                    -o jsonpath='{.type}' 2>/dev/null || echo '')"
if [[ "${_secret_type}" != "kubernetes.io/dockerconfigjson" && "${_secret_type}" != "kubernetes.io/dockercfg" ]]; then
    # Linking a non-pull secret with --for=pull is accepted by oc but the
    # kubelet will never use it, so the failure would only show up as
    # ImagePullBackOff much later. Say so now.
    echo "[WARN] Secret '${SECRET_NAME}' has type '${_secret_type:-<none>}', not a docker"
    echo "[WARN] config secret. Linking it for pull will not make image pulls work."
fi

# --- Work out the target projects --------------------------------------------
SYSTEM_NS_PATTERN='^(openshift($|-)|kube($|-)|default$)'

case "${TARGET_MODE}" in
    explicit)
        : # PROJECTS already holds exactly what was asked for.
        ;;
    cpd)
        for _v in PROJECT_LICENSE_SERVICE PROJECT_SCHEDULING_SERVICE \
                  PROJECT_IBM_EVENTS PROJECT_PRIVILEGED_MONITORING_SERVICE \
                  PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS; do
            _ns="${(P)_v:-}"
            [[ -n "${_ns}" ]] && PROJECTS+=("${_ns}")
        done
        unset _v _ns
        if (( ${#PROJECTS[@]} == 0 )); then
            echo "[ERROR] --cpd-projects was given but no PROJECT_* variables are set." >&2
            echo "[ERROR] Check ./cpd_vars.sh." >&2
            exit 1
        fi
        # The same namespace is often reused for several roles (operators and
        # operands, say), so collapse duplicates before reporting a count.
        PROJECTS=("${(@u)PROJECTS}")
        ;;
    all)
        echo "[INFO] Listing projects in the cluster..."
        _all=("${(@f)$(oc get projects -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)}")
        for _ns in "${_all[@]}"; do
            [[ -z "${_ns}" ]] && continue
            if [[ "${INCLUDE_SYSTEM}" != true && "${_ns}" =~ ${SYSTEM_NS_PATTERN} ]]; then
                continue
            fi
            PROJECTS+=("${_ns}")
        done
        unset _all _ns
        if (( ${#PROJECTS[@]} == 0 )); then
            echo "[WARN] No projects to act on."
            exit 0
        fi
        ;;
esac

echo "[INFO] Secret:  ${SECRET_NAME} (from ${SOURCE_NAMESPACE})"
echo "[INFO] Targets: ${#PROJECTS[@]} project(s)"
printf '    %s\n' "${PROJECTS[@]}"

if [[ "${DRY_RUN}" != true && "${ASSUME_YES}" != true ]]; then
    echo -n "Apply '${SECRET_NAME}' as the default pull secret on the ${#PROJECTS[@]} project(s) above? [y/N] "
    read -r _reply
    if [[ ! "${_reply}" =~ ^[Yy]$ ]]; then
        echo "[INFO] Aborted, nothing changed."
        exit 0
    fi
fi

# --- Apply -------------------------------------------------------------------
# Read the source once: the copy is identical for every target, and re-reading
# it per namespace would be one API call per project for no gain.
SECRET_BODY="$(oc get secret "${SECRET_NAME}" -n "${SOURCE_NAMESPACE}" -o json \
    | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.ownerReferences)')"

APPLIED=0
SKIPPED=0
FAILED=0
FAILED_NS=()

set_default_pull_secret() {
    local ns="$1"

    if ! oc get namespace "${ns}" &>/dev/null; then
        echo "[ERROR] Project '${ns}' does not exist, skipping."
        return 1
    fi

    local existing
    existing=$(oc get serviceaccount default -n "${ns}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || true)

    if echo "${existing}" | grep -qw "${SECRET_NAME}"; then
        if [[ "${OVERWRITE}" != "true" ]]; then
            echo "[INFO] Project '${ns}' already has pull secret '${SECRET_NAME}' as default, skipping (drop --no-overwrite to re-apply)."
            return 2
        fi
        echo "[INFO] Pull secret '${SECRET_NAME}' already set on '${ns}', overwriting as requested."
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY-RUN] Would copy '${SECRET_NAME}' into '${ns}' and link it to the default service account."
        return 0
    fi

    echo "${SECRET_BODY}" | oc apply -n "${ns}" -f - >/dev/null
    oc secrets link default "${SECRET_NAME}" --for=pull -n "${ns}"
    echo "[INFO] Default pull secret '${SECRET_NAME}' set on project '${ns}'."
    return 0
}

for _ns in "${PROJECTS[@]}"; do
    # One bad namespace must not abandon the rest of the list, so absorb the
    # non-zero exit here rather than letting set -e end the run.
    _rc=0
    set_default_pull_secret "${_ns}" || _rc=$?
    case "${_rc}" in
        0) (( ++APPLIED )) ;;
        2) (( ++SKIPPED )) ;;
        *) (( ++FAILED )); FAILED_NS+=("${_ns}") ;;
    esac
done
unset _ns _rc

echo "[INFO] ---"
if [[ "${DRY_RUN}" == true ]]; then
    echo "[INFO] Dry run: ${APPLIED} project(s) would be updated, ${SKIPPED} skipped, ${FAILED} unreachable."
    exit 0
fi

echo "[INFO] Applied: ${APPLIED}  Skipped: ${SKIPPED}  Failed: ${FAILED}"
if (( FAILED > 0 )); then
    printf '[ERROR] Failed on: %s\n' "${FAILED_NS[*]}" >&2
    exit 1
fi
