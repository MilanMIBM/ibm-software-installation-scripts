#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---
eval "${CPDM_OC_LOGIN}"

_has_icr=false
_has_private=false
_missing_private=()

[[ -n "${IBM_ENTITLEMENT_KEY:-}" ]] && _has_icr=true

[[ -z "${PRIVATE_REGISTRY_LOCATION:-}" ]]    && _missing_private+=(PRIVATE_REGISTRY_LOCATION)
[[ -z "${PRIVATE_REGISTRY_PULL_USER:-}" ]]   && _missing_private+=(PRIVATE_REGISTRY_PULL_USER)
[[ -z "${PRIVATE_REGISTRY_PULL_PASSWORD:-}" ]] && _missing_private+=(PRIVATE_REGISTRY_PULL_PASSWORD)
(( ${#_missing_private[@]} == 0 )) && _has_private=true

if ! $_has_icr && ! $_has_private; then
    echo "[ERROR] No credentials configured. Set IBM_ENTITLEMENT_KEY for the IBM registry," \
        "or set PRIVATE_REGISTRY_LOCATION, PRIVATE_REGISTRY_PULL_USER, and PRIVATE_REGISTRY_PULL_PASSWORD for a private registry." >&2
    exit 1
fi

if $_has_icr; then
    cpd-cli manage add-icr-cred-to-global-pull-secret \
        --entitled_registry_key=${IBM_ENTITLEMENT_KEY}
fi

if $_has_private; then
    cpd-cli manage add-cred-to-global-pull-secret \
        --registry=${PRIVATE_REGISTRY_LOCATION} \
        --registry_pull_user=${PRIVATE_REGISTRY_PULL_USER} \
        --registry_pull_password=${PRIVATE_REGISTRY_PULL_PASSWORD}
elif (( ${#_missing_private[@]} < 3 )); then
    echo "[ERROR] Private registry credentials incomplete. Missing: ${_missing_private[*]}" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Reconcile icr.io / cp.icr.io in the openshift-config global pull secret.
# Both registries should be present with identical auth values; if only one
# exists, copy its auth to the other.
# ------------------------------------------------------------------------------
REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
PULL_SECRET_FILE="${REPO_ROOT}/cp4d_config/pull-secret.dockerconfigjson"

_raw_secret="$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 --decode)" || true

if [[ -z "${_raw_secret}" ]]; then
    echo "[WARN] Could not retrieve pull-secret from openshift-config; skipping icr.io/cp.icr.io reconciliation." >&2
else
    _recon_file="$(mktemp)"
    # Returns updated JSON on stdout (pretty-printed) and prints a status line to stderr.
    _patched="$(echo "${_raw_secret}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
auths = d.setdefault('auths', {})
icr = auths.get('icr.io')
cp  = auths.get('cp.icr.io')

if icr and cp:
    if icr.get('auth') == cp.get('auth'):
        sys.stderr.write('present-equal')
    else:
        # Both present but differ - prefer cp.icr.io as source of truth.
        auths['icr.io'] = cp
        sys.stderr.write('synced-from-cp')
elif cp and not icr:
    auths['icr.io'] = cp
    sys.stderr.write('added-icr')
elif icr and not cp:
    auths['cp.icr.io'] = icr
    sys.stderr.write('added-cp')
else:
    sys.stderr.write('neither')

print(json.dumps(d, indent=2))
" 2>"${_recon_file}")"
    _recon_status="$(cat "${_recon_file}")"
    rm -f "${_recon_file}"

    case "${_recon_status}" in
        present-equal)
            echo "[INFO] icr.io and cp.icr.io both present with matching auth - no patch needed." ;;
        synced-from-cp)
            echo "[INFO] icr.io and cp.icr.io differed - synced icr.io from cp.icr.io." ;;
        added-icr)
            echo "[INFO] icr.io auth not found - copied from cp.icr.io." ;;
        added-cp)
            echo "[INFO] cp.icr.io auth not found - copied from icr.io." ;;
        neither)
            echo "[WARN] Neither icr.io nor cp.icr.io found in pull-secret; nothing to reconcile." >&2 ;;
    esac

    if [[ "${_recon_status}" == "synced-from-cp" || "${_recon_status}" == "added-icr" || "${_recon_status}" == "added-cp" ]]; then
        _patch_file="$(mktemp)"
        printf '%s' "${_patched}" | python3 -c "
import sys, json, base64
data = sys.stdin.read()
print(json.dumps({'data': {'.dockerconfigjson': base64.b64encode(data.encode()).decode()}}))
" > "${_patch_file}"
        oc patch secret pull-secret -n openshift-config \
            --type=merge \
            --patch-file="${_patch_file}"
        rm -f "${_patch_file}"
        echo "[INFO] openshift-config pull-secret patched."
    fi

    mkdir -p "$(dirname "${PULL_SECRET_FILE}")"
    echo "${_patched}" | python3 -c "import sys, json; print(json.dumps(json.load(sys.stdin), indent=2))" > "${PULL_SECRET_FILE}"
    echo "[INFO] pull-secret saved to ${PULL_SECRET_FILE}"

    # --------------------------------------------------------------------------
    # Distribute the global pull secret to every PROJECT_* namespace as a
    # dockerconfigjson secret named ${IMAGE_PULL_SECRET}.
    # --------------------------------------------------------------------------
    _secret_name="${IMAGE_PULL_SECRET:-pull-secret}"
    _dockercfg_b64="$(printf '%s' "${_patched}" | base64 | tr -d '\n')"

    # Collect all PROJECT_* variable values (zsh: ${(k)parameters} lists names).
    _project_ns=()
    for _var in ${(k)parameters}; do
        [[ "${_var}" == PROJECT_* ]] || continue
        _val="${(P)_var}"
        [[ -n "${_val}" ]] && _project_ns+=("${_val}")
    done

    if (( ${#_project_ns[@]} == 0 )); then
        echo "[WARN] No PROJECT_* namespaces found in environment; skipping pull-secret distribution." >&2
    else
        for _ns in "${_project_ns[@]}"; do
            if ! oc get namespace "${_ns}" &>/dev/null; then
                echo "[INFO] Namespace ${_ns} does not exist yet - skipping pull-secret copy."
                continue
            fi
            _ns_patch_file="$(mktemp)"
            cat > "${_ns_patch_file}" <<EOF
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": { "name": "${_secret_name}", "namespace": "${_ns}" },
  "type": "kubernetes.io/dockerconfigjson",
  "data": { ".dockerconfigjson": "${_dockercfg_b64}" }
}
EOF
            oc apply -f "${_ns_patch_file}"
            rm -f "${_ns_patch_file}"
            echo "[INFO] Applied pull-secret '${_secret_name}' to namespace ${_ns}."
        done
    fi
fi
