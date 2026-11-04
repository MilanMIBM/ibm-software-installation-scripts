#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---
# Pull-secret compatibility linking: the namespace part of 1.1, run once the
# namespaces exist.
#
# 1.1_set_up_global_pull_credential.sh copies the global pull secret into every
# PROJECT_* namespace (as ${IMAGE_PULL_SECRET} and as 'ibm-entitlement-key') and
# links 'ibm-entitlement-key' to every service account there. On a new cluster
# it runs before 2.0.1 creates those namespaces, so it skips them all. This
# script does the same work afterwards. It runs at the end of
# 2.0_preliminary_setup.sh and can be run alone, e.g. again after steps 3 and 4,
# when operators and operands have created their own service accounts.
#
# Anything already in place (from 1.1 or an earlier run) is left alone: a
# secret whose contents already match the global pull secret is not re-applied,
# and a service account that already lists 'ibm-entitlement-key' is not
# re-linked. With nothing missing, the script changes nothing.
#
# Environment:
#   CREATE_ENTITLEMENT_KEY_SECRET=false  skip the whole script (same opt-out as 1.1)
#   IMAGE_PULL_SECRET                    name of the general copy (default: pull-secret)
# ---

ENTITLEMENT_SECRET_NAME="ibm-entitlement-key"
GLOBAL_SECRET_NAME="pull-secret"
GLOBAL_SECRET_NAMESPACE="openshift-config"

case "${1:-}" in
    -h|--help)
        sed -n '/^# Pull-secret compatibility linking/,/^# ---$/p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac

if [[ "${CREATE_ENTITLEMENT_KEY_SECRET:-true}" != true ]]; then
    echo "[INFO] CREATE_ENTITLEMENT_KEY_SECRET=${CREATE_ENTITLEMENT_KEY_SECRET} - skipping pull-secret compatibility linking."
    exit 0
fi

eval "${OC_LOGIN}"

# --- Source: the global pull secret as 1.1 left it ---------------------------
_dockercfg_b64="$(oc get secret "${GLOBAL_SECRET_NAME}" -n "${GLOBAL_SECRET_NAMESPACE}" \
    -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null || true)"
if [[ -z "${_dockercfg_b64}" ]]; then
    echo "[WARN] Could not read ${GLOBAL_SECRET_NAMESPACE}/${GLOBAL_SECRET_NAME}; nothing to distribute." \
        "Run 1.1_set_up_global_pull_credential.sh first." >&2
    exit 0
fi

# Contents are compared as normalised JSON, not as bytes: 1.1 writes the same
# auths pretty-printed, which would otherwise read as a difference every time.
normalise_dockercfg() {   # <base64 .dockerconfigjson>
    printf '%s' "$1" | base64 --decode 2>/dev/null | jq -S -c . 2>/dev/null || true
}
_source_norm="$(normalise_dockercfg "${_dockercfg_b64}")"
if [[ -z "${_source_norm}" ]]; then
    echo "[ERROR] ${GLOBAL_SECRET_NAMESPACE}/${GLOBAL_SECRET_NAME} does not hold valid dockerconfigjson." >&2
    exit 1
fi

_secret_names=("${IMAGE_PULL_SECRET:-pull-secret}")
[[ "${_secret_names[1]}" != "${ENTITLEMENT_SECRET_NAME}" ]] && _secret_names+=("${ENTITLEMENT_SECRET_NAME}")

# --- Targets: every PROJECT_* value, as in 1.1 (deduplicated) ----------------
_project_ns=()
for _var in ${(ko)parameters}; do
    [[ "${_var}" == PROJECT_* ]] || continue
    _val="${(P)_var}"
    [[ -n "${_val}" ]] && _project_ns+=("${_val}")
done
_project_ns=("${(u)_project_ns[@]}")

if (( ${#_project_ns[@]} == 0 )); then
    echo "[WARN] No PROJECT_* namespaces found in environment; nothing to do." >&2
    exit 0
fi

# --- Per namespace -----------------------------------------------------------
_total=${#_project_ns[@]}
_i=0
_ns_done=0 _ns_missing=0 _ns_changed=0
_secrets_applied=0 _sa_linked=0 _failed=0

for _ns in "${_project_ns[@]}"; do
    (( ++_i ))
    _prefix="[INFO] [${_i}/${_total}] ${_ns}:"

    if ! oc get namespace "${_ns}" &>/dev/null; then
        echo "${_prefix} namespace does not exist - skipping."
        (( ++_ns_missing ))
        continue
    fi

    _changes=0

    # Secrets: create when missing, update when contents differ, else leave.
    for _name in "${_secret_names[@]}"; do
        _existing="$(oc get secret "${_name}" -n "${_ns}" \
            -o jsonpath='{.type}{"|"}{.data.\.dockerconfigjson}' 2>/dev/null || true)"
        _type="${_existing%%|*}"
        _data="${_existing#*|}"

        if [[ -n "${_existing}" && "${_type}" != "kubernetes.io/dockerconfigjson" ]]; then
            # A secret's type cannot be changed in place; replacing it means
            # deleting it, which is left to the user.
            echo "[WARN] ${_ns}/${_name} exists with type '${_type}', not kubernetes.io/dockerconfigjson - left as is." \
                "Delete it and re-run to replace it." >&2
            (( ++_failed ))
            continue
        fi
        if [[ -n "${_existing}" && "$(normalise_dockercfg "${_data}")" == "${_source_norm}" ]]; then
            continue
        fi

        _action="created"; [[ -n "${_existing}" ]] && _action="updated"
        if oc apply -f - >/dev/null <<EOF
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": { "name": "${_name}", "namespace": "${_ns}" },
  "type": "kubernetes.io/dockerconfigjson",
  "data": { ".dockerconfigjson": "${_dockercfg_b64}" }
}
EOF
        then
            echo "${_prefix} ${_action} secret '${_name}'."
            (( ++_secrets_applied, ++_changes ))
        else
            echo "[WARN] ${_ns}: could not apply secret '${_name}'." >&2
            (( ++_failed ))
        fi
    done

    # Service accounts without 'ibm-entitlement-key' in imagePullSecrets (one call).
    if oc get secret "${ENTITLEMENT_SECRET_NAME}" -n "${_ns}" &>/dev/null; then
        _unlinked=("${(@f)$(oc get sa -n "${_ns}" -o json 2>/dev/null \
            | jq -r --arg s "${ENTITLEMENT_SECRET_NAME}" \
                '.items[] | select([(.imagePullSecrets // [])[].name] | index($s) | not) | .metadata.name' \
            2>/dev/null)}")
        for _sa in "${_unlinked[@]}"; do
            [[ -z "${_sa}" ]] && continue
            if oc secrets link "${_sa}" "${ENTITLEMENT_SECRET_NAME}" --for=pull -n "${_ns}" 2>/dev/null; then
                (( ++_sa_linked, ++_changes ))
            else
                echo "[WARN] ${_ns}: could not link '${ENTITLEMENT_SECRET_NAME}' to sa/${_sa}." >&2
                (( ++_failed ))
            fi
        done
    fi

    if (( _changes == 0 )); then
        echo "${_prefix} already in place (1.1 or an earlier run) - nothing to change."
        (( ++_ns_done ))
    else
        echo "${_prefix} ${_changes} change(s)."
        (( ++_ns_changed ))
    fi
done

echo "[INFO] ---"
echo "[INFO] Namespaces: ${_ns_changed} updated, ${_ns_done} already in place, ${_ns_missing} not present."
echo "[INFO] Secrets applied: ${_secrets_applied}  Service accounts linked: ${_sa_linked}  Problems: ${_failed}"
if (( _sa_linked > 0 )); then
    echo "[INFO] Only pods created from now on pick up new links; existing pods keep their pull secrets."
fi
echo "[INFO] Re-run this script after steps 3 and 4 to link service accounts created by operators and operands."
(( _failed == 0 )) || exit 1
