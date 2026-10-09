#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform - publish the Kafka CA certificates to the Software Hub vault
# ------------------------------------------------------------------------------
# Finds the CA certificates of the running Confluent Platform and stores each
# one in the Software Hub (CPD) internal vault as a 'certificate' secret, shared
# with the built-in "All users" group, so any CPD user or service (watsonx.data,
# DataStage, notebooks, ...) can select it when connecting to Kafka over TLS.
#
# Safe to re-run, and meant to be re-run after a certificate changes: a missing
# secret is created, one holding an older certificate is updated in place, and
# one already holding the same certificate is left alone. Only certificates that
# actually exist on the cluster are published; with none, it does nothing.
#
#   Certificate (from the Confluent project)        Vault secret
#   EXTERNAL listener CA  CONFLUENT_EXTERNAL_TLS_SECRET   confluent-<project>-kafka-external-ca
#     created by x.4_confluent_add_external_access.sh (the passthrough routes)
#   in-cluster CA         CONFLUENT_INTERNAL_TLS_SECRET   confluent-<project>-kafka-internal-ca
#     created when CONFLUENT_SASL_PROTOCOL=SASL_SSL
#
# Only the CA certificate (ca.crt) is published - never a private key - so the
# secret holds {"certificate": {"cert": "<PEM>"}}.
#
# Access: the secrets are owned by the Software Hub admin (CPD_USERNAME) and
# shared with the group CONFLUENT_VAULT_GROUP (default "All users"). The vault
# only accepts members when a secret is CREATED; an update keeps whatever access
# list the secret was created with. --recreate deletes and re-creates the
# secrets to apply the group to ones made without it (e.g. by hand, or with
# --no-group). Anything referencing a secret by its URN keeps working, as the
# URN (<owner uid>:<name>) does not change.
#
# Software Hub credentials: CPD_URL, CPD_USERNAME and CPD_APIKEY (or
# CPD_PASSWORD) from the environment, else read from
# configs/cp4d_config/cpd_instance_details.sh (3.3.1_get_instance_creds.sh
# writes it). The Software Hub may be on another cluster: only its URL is used,
# while 'oc' talks to the Confluent cluster.
#
# Usage:
#   ./x.5_confluent_add_cert_to_vault.sh [--only external|internal]
#        [--group NAME | --no-group] [--recreate] [--cpd-url URL]
#        [--cpd-details FILE] [--dry-run] [-q]
#
#   --only external|internal  publish just that certificate (default: every one found)
#   --group NAME              share with this group (default: CONFLUENT_VAULT_GROUP,
#                             else "All users")
#   --no-group                share with nobody; only the owner can read them
#   --recreate                delete and re-create existing secrets, re-applying
#                             the group (members can only be set on create)
#   --cpd-url URL             Software Hub URL (default: CPD_URL)
#   --cpd-details FILE        file to read CPD_* from (default:
#                             configs/cp4d_config/cpd_instance_details.sh)
#   --dry-run                 sign in and report what would change, change nothing
#   -q, --quiet               do not print every API call
# ==============================================================================

ONLY=""
GROUP="${CONFLUENT_VAULT_GROUP:-All users}"
USE_GROUP=true
RECREATE=false
DRY_RUN=false
VERBOSE=true
CPD_DETAILS_FILE="${CPD_DETAILS_FILE:-${REPO_ROOT}/configs/cp4d_config/cpd_instance_details.sh}"
VAULT_URN="${VAULT_URN:-0000000000:internal}"
CLI_CPD_URL=""

_need_value() { [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }; }

while (( $# > 0 )); do
    case "$1" in
        --only)        _need_value "$1" "${2:-}"; ONLY="$2"; shift 2 ;;
        --group)       _need_value "$1" "${2:-}"; GROUP="$2"; USE_GROUP=true; shift 2 ;;
        --no-group)    USE_GROUP=false; shift ;;
        --recreate)    RECREATE=true; shift ;;
        --cpd-url)     _need_value "$1" "${2:-}"; CLI_CPD_URL="$2"; shift 2 ;;
        --cpd-details) _need_value "$1" "${2:-}"; CPD_DETAILS_FILE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -q|--quiet)    VERBOSE=false; shift ;;
        -h|--help)     sed -n '16,65p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

if [[ -n "${ONLY}" && "${ONLY}" != (external|internal) ]]; then
    echo "[ERROR] --only takes 'external' or 'internal', not '${ONLY}'." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Software Hub credentials
# ------------------------------------------------------------------------------
# ENV_TARGET=confluent loads only the Confluent config, so the CPD values are
# read from their own file - in a subshell, one at a time, so nothing else in it
# (OC_LOGIN, OCP_URL, ...) can replace the Confluent cluster's settings.
cpd_var() {
    [[ -f "${CPD_DETAILS_FILE}" ]] || return 0
    ( source "${CPD_DETAILS_FILE}" >/dev/null 2>&1; print -r -- "${(P)1:-}" )
}
CPD_URL="${CLI_CPD_URL:-${CPD_URL:-$(cpd_var CPD_URL)}}"
CPD_USERNAME="${CPD_USERNAME:-$(cpd_var CPD_USERNAME)}"
CPD_APIKEY="${CPD_APIKEY:-$(cpd_var CPD_APIKEY)}"
CPD_PASSWORD="${CPD_PASSWORD:-$(cpd_var CPD_PASSWORD)}"

if [[ -z "${CPD_URL}" || -z "${CPD_USERNAME}" || ( -z "${CPD_APIKEY}" && -z "${CPD_PASSWORD}" ) ]]; then
    echo "[ERROR] Software Hub credentials are incomplete: need CPD_URL, CPD_USERNAME and" >&2
    echo "[ERROR] CPD_APIKEY or CPD_PASSWORD, in the environment or in" >&2
    echo "[ERROR]   ${CPD_DETAILS_FILE}" >&2
    echo "[ERROR] Run 3.3.1_get_instance_creds.sh against the Software Hub cluster, or pass --cpd-url." >&2
    exit 1
fi
CPD_URL="${CPD_URL%/}"
[[ "${CPD_URL}" == http* ]] || CPD_URL="https://${CPD_URL}"

# ------------------------------------------------------------------------------
# Find the certificates on the Confluent cluster
# ------------------------------------------------------------------------------
eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_EXTERNAL_TLS_SECRET:=confluent-kafka-tls}"
: "${CONFLUENT_INTERNAL_TLS_SECRET:=confluent-kafka-internal-tls}"
: "${CONFLUENT_VAULT_SECRET_PREFIX:=confluent-${NS}-kafka}"

oc get namespace "${NS}" &>/dev/null || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }

# kind | k8s secret | vault secret name | what it is
typeset -a CANDIDATES
CANDIDATES=(
    "external|${CONFLUENT_EXTERNAL_TLS_SECRET}|${CONFLUENT_VAULT_SECRET_PREFIX}-external-ca|EXTERNAL listener (passthrough routes, port 443)"
    "internal|${CONFLUENT_INTERNAL_TLS_SECRET}|${CONFLUENT_VAULT_SECRET_PREFIX}-internal-ca|in-cluster listeners (SASL_SSL)"
)

# One JSON object per certificate found, handed to Python on stdin.
CERTS_JSON=""
for _c in "${CANDIDATES[@]}"; do
    IFS='|' read -r _kind _k8s _name _what <<< "${_c}"
    [[ -n "${ONLY}" && "${ONLY}" != "${_kind}" ]] && continue

    _pem="$(oc get secret "${_k8s}" -n "${NS}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
    if [[ "${_pem}" != *"-----BEGIN CERTIFICATE-----"* ]]; then
        echo "[INFO] No ${_kind} CA on the cluster (secret '${_k8s}' in '${NS}') - skipping."
        continue
    fi

    # Expiry and fingerprint go into the description, so the vault shows which
    # certificate a secret holds without opening it. Optional: without openssl
    # the description just leaves them out.
    _detail=""
    if command -v openssl &>/dev/null; then
        _end="$(print -r -- "${_pem}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
        _fp="$(print -r -- "${_pem}" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2- || true)"
        [[ -n "${_end}" ]] && _detail+=" Expires ${_end}."
        [[ -n "${_fp}" ]] && _detail+=" SHA-256 ${_fp}."
    fi
    _desc="Confluent Platform Kafka CA for the ${_what}, project '${NS}' (from secret ${_k8s}).${_detail}"

    CERTS_JSON+="$(_KIND="${_kind}" _NAME="${_name}" _PEM="${_pem}" _DESC="${_desc}" \
        python3 -c 'import json, os; print(json.dumps({k: os.environ["_" + k.upper()] for k in ("kind", "name", "pem", "desc")}))')"$'\n'
    echo "[INFO] Found the ${_kind} CA in secret '${_k8s}' -> vault secret '${_name}'."
done

if [[ -z "${CERTS_JSON}" ]]; then
    echo "[INFO] No Confluent CA certificates on the cluster; nothing to publish."
    echo "[INFO] They are created by x.4_confluent_add_external_access.sh (external) and"
    echo "[INFO] by CONFLUENT_SASL_PROTOCOL=SASL_SSL (in-cluster)."
    exit 0
fi

# ------------------------------------------------------------------------------
# Store them (src/helpers/softwarehub_internal_vault_helpers.py)
# ------------------------------------------------------------------------------
read -r -d '' STORE_PY <<'PY' || true
import json, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"])
from src.helpers.softwarehub_internal_vault_helpers import (
    SoftwareHubVault, SecretNameTakenError, VaultError, certificate_secret, members, redact,
    secret_name_for)

env = os.environ
url, vault_urn, admin = env["CPD_URL"], env["VAULT_URN"], env["CPD_USERNAME"]
group_name = env["GROUP"] if env["USE_GROUP"] == "true" else ""
recreate, dry_run, verbose = env["RECREATE"] == "true", env["DRY_RUN"] == "true", env["VERBOSE"] == "true"

def show(method, path, status, body):
    """With VERBOSE, every API call and its response, secrets hidden."""
    if not verbose:
        return
    shown = json.dumps(redact(body), indent=2) if isinstance(body, (dict, list)) else str(body)[:2000]
    print(f"[API]  {method} {path.split('?')[0]}: HTTP {status}", file=sys.stderr)
    print("\n".join("         " + line for line in shown.splitlines()), file=sys.stderr)

def error(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)

certs = [json.loads(line) for line in sys.stdin.read().splitlines() if line.strip()]

try:
    if env.get("CPD_APIKEY"):
        vault = SoftwareHubVault.sign_in(url, admin, api_key=env["CPD_APIKEY"], on_response=show)
    else:
        vault = SoftwareHubVault.sign_in(url, admin, password=env["CPD_PASSWORD"], on_response=show)
    uid = vault.current_uid()
except VaultError as e:
    error(f"Sign-in as '{admin}' at {url} failed: {e}")
    sys.exit(1)

access = None
if group_name:
    try:
        group = vault.find_group(group_name)
    except VaultError as e:
        error(f"Looking up the group '{group_name}' failed: {e}")
        sys.exit(1)
    if not group:
        error(f"No user group named '{group_name}' in {url}. Pass --group with an existing "
              "group, or --no-group.")
        sys.exit(1)
    access = members(groups=[{"group_id": group["group_id"], "group_name": group.get("name", group_name)}])
    print(f"[INFO] Sharing with group '{group.get('name', group_name)}' (id {group['group_id']}).")
else:
    print("[INFO] --no-group: only the owner can read the secrets.")

print(f"[INFO] Software Hub: {url}, vault {vault_urn}, owner '{admin}'"
      + (" (dry run - nothing is changed)" if dry_run else ""))

done = {"created": [], "updated": [], "unchanged": [], "recreated": [], "failed": []}
for c in certs:
    name = secret_name_for(c["name"])
    secret = certificate_secret(c["pem"])
    try:
        existing = vault.find_secret(name, owner_uid=uid, vault_urn=vault_urn)

        if dry_run:
            if existing is None:
                print(f"[INFO] {c['kind']}: would create certificate secret '{name}'.")
            elif recreate:
                print(f"[INFO] {c['kind']}: would delete and re-create '{name}' (re-applying access).")
            else:
                same = vault.get_secret_value(existing["secret_urn"]) == secret
                print(f"[INFO] {c['kind']}: '{name}' " + ("is already up to date." if same
                      else "holds another certificate - would update it."))
            continue

        if existing is not None and recreate:
            vault.delete_secret(existing["secret_urn"])
            existing = None
            action = "recreated"
        else:
            action = None

        result = vault.store_secret(name, secret, type="certificate", vault_urn=vault_urn,
                                    description=c["desc"], members=access)
        action = action or ("created" if result.action == "replaced" else result.action)
        done[action].append(name)
        print({
            "created":   f"[INFO] {c['kind']}: stored as new certificate secret '{name}' ({result.urn}).",
            "recreated": f"[INFO] {c['kind']}: re-created '{name}' with the current access list ({result.urn}).",
            "updated":   f"[INFO] {c['kind']}: '{name}' updated with the current certificate.",
            "unchanged": f"[INFO] {c['kind']}: '{name}' is already up to date.",
        }[action])
        if result.action == "replaced":
            print(f"[WARN] {c['kind']}: '{name}' was a '{result.previous_type}' secret; replaced it "
                  "with a certificate secret.", file=sys.stderr)
    except SecretNameTakenError as e:
        error(f"{c['kind']}: creating '{name}' failed: {e}")
        print(f"       The name is taken but '{admin}' has no such secret: probably left behind by a "
              "failed create. It has to be removed from the Software Hub metastore before this "
              "name can be used again.", file=sys.stderr)
        done["failed"].append(name)
    except VaultError as e:
        error(f"{c['kind']}: storing '{name}' failed: {e}")
        done["failed"].append(name)

if not dry_run:
    print(f"[INFO] Vault secrets: {len(done['created'])} created, {len(done['recreated'])} re-created, "
          f"{len(done['updated'])} updated, {len(done['unchanged'])} unchanged, {len(done['failed'])} failed.")
    if done["updated"] or done["unchanged"]:
        print("[INFO] Existing secrets keep the access list they were created with; "
              "--recreate re-applies the group.")
if done["failed"]:
    error(f"Could not store: {' '.join(done['failed'])}")
    sys.exit(1)
PY

# The repo's virtualenv has 'requests'; otherwise let uv provide it.
if [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
    PYTHON_CMD=("${REPO_ROOT}/.venv/bin/python")
elif command -v uv &>/dev/null; then
    PYTHON_CMD=(uv run --quiet --project "${REPO_ROOT}" python)
else
    echo "[ERROR] No Python environment: create ${REPO_ROOT}/.venv (uv sync) or install uv." >&2
    exit 1
fi

# Credentials go in the environment, never on a command line.
print -rn -- "${CERTS_JSON}" | REPO_ROOT="${REPO_ROOT}" CPD_URL="${CPD_URL}" VAULT_URN="${VAULT_URN}" \
    CPD_USERNAME="${CPD_USERNAME}" CPD_APIKEY="${CPD_APIKEY}" CPD_PASSWORD="${CPD_PASSWORD}" \
    GROUP="${GROUP}" USE_GROUP="${USE_GROUP}" RECREATE="${RECREATE}" DRY_RUN="${DRY_RUN}" \
    VERBOSE="${VERBOSE}" "${PYTHON_CMD[@]}" -c "${STORE_PY}"
