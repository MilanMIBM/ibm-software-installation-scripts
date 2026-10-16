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
Add registry credentials to the cluster-wide pull secret (openshift-config/pull-secret)
using only `oc` - no cpd-cli / olm-utils container needed.

  set_global_pull_secret.sh [options]

What it does (each step is skipped when there is nothing to change):
  1. IBM entitled registry: adds cp.icr.io and icr.io (user 'cp', key IBM_ENTITLEMENT_KEY).
  2. Private registry: adds PRIVATE_REGISTRY_LOCATION with PRIVATE_REGISTRY_PULL_USER /
     PRIVATE_REGISTRY_PULL_PASSWORD.
  3. Reconciles icr.io and cp.icr.io so both carry the same auth (cp.icr.io wins).
  4. Saves the merged pull secret to <config-dir>/pull-secret.dockerconfigjson.
  5. Copies it into every existing PROJECT_* namespace as IMAGE_PULL_SECRET.

Shared by the install tracks that must not depend on cpd-cli (IBM Concert, ...).
The CP4D track keeps its own cpd-cli based
scripts/install_cloud_pak_for_data/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh.

Options:
  --config-dir DIR     Where to save the merged copy (default: CONFIG_DIR)
  --secret-name NAME   Name of the per-namespace copies (default: IMAGE_PULL_SECRET,
                       else 'pull-secret')
  --no-distribute      Do not copy the secret into the PROJECT_* namespaces
  --skip-icr           Ignore IBM_ENTITLEMENT_KEY even if set
  --skip-private       Ignore the PRIVATE_REGISTRY_* values even if set
  --dry-run            Show what would change, change nothing
  -h, --help           Show this help

Changing openshift-config/pull-secret makes the Machine Config Operator roll the
new credentials out to every node. Recent OpenShift releases do this without
draining or rebooting nodes.
EOF
}

CONFIG_OUT_DIR="${CONFIG_DIR:-${REPO_ROOT}/configs/cp4d_config}"
SECRET_NAME="${IMAGE_PULL_SECRET:-pull-secret}"
DISTRIBUTE=true
USE_ICR=true
USE_PRIVATE=true
DRY_RUN=false

while (( $# )); do
    case "$1" in
        --config-dir)    CONFIG_OUT_DIR="$2"; shift 2 ;;
        --secret-name)   SECRET_NAME="$2"; shift 2 ;;
        --no-distribute) DISTRIBUTE=false; shift ;;
        --skip-icr)      USE_ICR=false; shift ;;
        --skip-private)  USE_PRIVATE=false; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

eval "${OC_LOGIN}"

# --- Which credentials to add ------------------------------------------------
_has_icr=false
_has_private=false
$USE_ICR && [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]] && _has_icr=true
if $USE_PRIVATE; then
    _missing_private=()
    [[ -z "${PRIVATE_REGISTRY_LOCATION:-}" ]]      && _missing_private+=(PRIVATE_REGISTRY_LOCATION)
    [[ -z "${PRIVATE_REGISTRY_PULL_USER:-}" ]]     && _missing_private+=(PRIVATE_REGISTRY_PULL_USER)
    [[ -z "${PRIVATE_REGISTRY_PULL_PASSWORD:-}" ]] && _missing_private+=(PRIVATE_REGISTRY_PULL_PASSWORD)
    if (( ${#_missing_private[@]} == 0 )); then
        _has_private=true
    elif (( ${#_missing_private[@]} < 3 )); then
        echo "[ERROR] Private registry credentials incomplete. Missing: ${_missing_private[*]}" >&2
        exit 1
    fi
fi

if ! $_has_icr && ! $_has_private; then
    echo "[ERROR] No credentials configured. Set IBM_ENTITLEMENT_KEY and/or PRIVATE_REGISTRY_LOCATION," \
         "PRIVATE_REGISTRY_PULL_USER and PRIVATE_REGISTRY_PULL_PASSWORD." >&2
    exit 1
fi

_raw_secret="$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode)"
[[ -n "${_raw_secret}" ]] || { echo "[ERROR] Could not read openshift-config/pull-secret." >&2; exit 1; }

# --- Merge (python: the credentials travel via the environment, not argv) ----
_work="$(mktemp -d)"
chmod 700 "${_work}"
trap 'rm -rf "${_work}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
printf '%s' "${_raw_secret}" > "${_work}/current.json"

_status="$(
    MERGE_ICR="$($_has_icr && echo 1 || echo 0)" \
    MERGE_PRIVATE="$($_has_private && echo 1 || echo 0)" \
    ICR_KEY="${IBM_ENTITLEMENT_KEY:-}" \
    PRIV_LOCATION="${PRIVATE_REGISTRY_LOCATION:-}" \
    PRIV_USER="${PRIVATE_REGISTRY_PULL_USER:-}" \
    PRIV_PASSWORD="${PRIVATE_REGISTRY_PULL_PASSWORD:-}" \
    python3 - "${_work}/current.json" "${_work}/merged.json" <<'PY'
import base64, json, os, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    data = json.load(f)
auths = data.setdefault("auths", {})
changes = []

def entry(user, password):
    return {"auth": base64.b64encode(f"{user}:{password}".encode()).decode()}

def put(registry, value):
    if auths.get(registry, {}).get("auth") != value["auth"]:
        auths[registry] = {**auths.get(registry, {}), **value}
        changes.append(registry)

if os.environ.get("MERGE_ICR") == "1":
    icr = entry("cp", os.environ["ICR_KEY"])
    put("cp.icr.io", icr)
    put("icr.io", icr)
if os.environ.get("MERGE_PRIVATE") == "1":
    put(os.environ["PRIV_LOCATION"], entry(os.environ["PRIV_USER"], os.environ["PRIV_PASSWORD"]))

# icr.io and cp.icr.io must carry the same auth; cp.icr.io is the source of truth.
icr, cp = auths.get("icr.io"), auths.get("cp.icr.io")
if cp and (not icr or icr.get("auth") != cp.get("auth")):
    auths["icr.io"] = cp
    changes.append("icr.io (synced from cp.icr.io)")
elif icr and not cp:
    auths["cp.icr.io"] = icr
    changes.append("cp.icr.io (copied from icr.io)")

with open(dst, "w") as f:
    json.dump(data, f, indent=2)
print(", ".join(dict.fromkeys(changes)) if changes else "")
PY
)"

if [[ -z "${_status}" ]]; then
    echo "[INFO] openshift-config/pull-secret already holds the configured credentials - no change."
elif $DRY_RUN; then
    echo "[DRY-RUN] Would update openshift-config/pull-secret entries: ${_status}"
else
    python3 - "${_work}/merged.json" > "${_work}/patch.json" <<'PY'
import base64, json, sys
with open(sys.argv[1], "rb") as f:
    print(json.dumps({"data": {".dockerconfigjson": base64.b64encode(f.read()).decode()}}))
PY
    oc patch secret pull-secret -n openshift-config --type=merge --patch-file="${_work}/patch.json" >/dev/null
    echo "[INFO] openshift-config/pull-secret updated: ${_status}"
fi

if ! $DRY_RUN; then
    mkdir -p "${CONFIG_OUT_DIR}"
    (umask 077; cp "${_work}/merged.json" "${CONFIG_OUT_DIR}/pull-secret.dockerconfigjson")
    echo "[INFO] Copy saved to ${CONFIG_OUT_DIR}/pull-secret.dockerconfigjson"
fi

# --- Distribute to PROJECT_* namespaces --------------------------------------
$DISTRIBUTE || exit 0

_project_ns=()
for _var in ${(k)parameters}; do
    [[ "${_var}" == PROJECT_* ]] || continue
    _val="${(P)_var}"
    [[ -n "${_val}" ]] && _project_ns+=("${_val}")
done
_project_ns=(${(u)_project_ns})

if (( ${#_project_ns[@]} == 0 )); then
    echo "[WARN] No PROJECT_* namespaces found in the environment; nothing to distribute." >&2
    exit 0
fi

for _ns in "${_project_ns[@]}"; do
    if ! oc get namespace "${_ns}" &>/dev/null; then
        echo "[INFO] Namespace ${_ns} does not exist yet - skipping."
        continue
    fi
    if $DRY_RUN; then
        echo "[DRY-RUN] Would apply secret '${SECRET_NAME}' to ${_ns}."
        continue
    fi
    oc create secret generic "${SECRET_NAME}" -n "${_ns}" --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="${_work}/merged.json" --dry-run=client -o yaml | oc apply -f - >/dev/null
    echo "[INFO] Applied pull secret '${SECRET_NAME}' to ${_ns}."
done
