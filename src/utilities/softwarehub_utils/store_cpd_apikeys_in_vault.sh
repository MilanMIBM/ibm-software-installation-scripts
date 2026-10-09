#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Stores Software Hub (Zen) users' API keys (and optionally their username and
# password) as secrets in the Software Hub internal vault (/zen-data/v2/secrets).
# Safe to re-run: a missing secret is created, one holding other values is
# updated (PATCH), one already holding the same values is left alone.
#
# --format picks the secrets, one or more, comma-separated (VAULT_SECRET_FORMATS):
#
#   key          (default) '<username>-apikey', type 'key':  {"key": "<api key>"}
#   credentials  '<username>-credentials', type 'credentials':
#                {"credentials": {"username": "<user>", "password": "<password>"}}
#   generic      '<username>-apikey', type 'generic': {"generic": {"username",
#                "api_key", "zen_api_key" (base64 of user:api key), "cpd_url"}}
#
# Secret names may only hold letters, digits and '-', so any other character in
# the username becomes '-' (cpd_service_id_1 -> 'cpd-service-id-1-apikey'). The
# exact username is in the secret's description.
#
# --owner picks who owns them (VAULT_SECRET_OWNER):
#
#   user   (default) the user the key belongs to, who signs in with that key. The
#          Software Hub admin (CPD_USERNAME) is added as a member, so it can
#          read the secret too.
#   admin  the Software Hub admin (CPD_USERNAME), no other members.
#
# --legacy is '--owner admin --format generic', the setup of the first version
# of this script. 'key' and 'generic' share a name, so they can't be combined.
# If a secret with the name exists with another type (switching formats), it is
# deleted and created again, since a secret's type can't be changed.
#
# The admin always signs in (with CPD_APIKEY, or else CPD_PASSWORD, from
# cpd_instance_details.sh), to look up its uid or to own the secrets. Members
# can only be set when a secret is created: a secret made before the admin was
# added keeps its member list.
#
# Keys are read from stdin as 'username:apikey' lines, 'username:apikey:password'
# for 'credentials' (never from the command line, so they don't show up in the
# process list), or with --from-credentials-file from the file
# generate_service_id_cpd_apikeys.sh writes ('user:password' lines, each with an
# 'apikey=' line under it).
#
# The API calls are made by src/helpers/softwarehub_internal_vault_helpers.py,
# run with the repo's .venv (or uv).
#
# Software Hub URL: --cpd-url, else CPD_URL. VAULT_URN picks the vault
# (default '0000000000:internal', the internal vault).
#
#   printf '%s:%s\n' svc-a "$KEY" | store_cpd_apikeys_in_vault.sh
#   store_cpd_apikeys_in_vault.sh --from-credentials-file             every key in the file
#   store_cpd_apikeys_in_vault.sh --from-credentials-file svc-a svc-b only these users
#   store_cpd_apikeys_in_vault.sh --from-credentials-file --format key,credentials
#   store_cpd_apikeys_in_vault.sh --from-credentials-file --legacy
#   store_cpd_apikeys_in_vault.sh --cpd-url https://cpd-<ns>.apps.<cluster> ...
#   store_cpd_apikeys_in_vault.sh -q ...                              no API responses

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b

# Same file and default as generate_service_id_cpd_apikeys.sh.
CREDENTIALS_FILE="${SERVICE_ID_CREDENTIALS_FILE:-${REPO_ROOT}/configs/openshift_config/service_id_credentials.txt}"
VAULT_URN="${VAULT_URN:-0000000000:internal}"
SECRET_FORMATS="${VAULT_SECRET_FORMATS:-key}"
SECRET_OWNER="${VAULT_SECRET_OWNER:-user}"

SH_URL="${CPD_URL:-}"
VERBOSE=true
FROM_FILE=false
CLI_USERS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpd-url)               SH_URL="${2:?--cpd-url needs the Software Hub URL}"; shift 2 ;;
        --format)                SECRET_FORMATS="${2:?--format needs key, credentials and/or generic}"; shift 2 ;;
        --owner)                 SECRET_OWNER="${2:?--owner needs user or admin}"; shift 2 ;;
        --legacy)                SECRET_OWNER=admin; SECRET_FORMATS=generic; shift ;;
        --from-credentials-file) FROM_FILE=true; shift ;;
        -v|--verbose)            VERBOSE=true; shift ;;
        -q|--quiet)              VERBOSE=false; shift ;;
        -h|--help)               sed -n '9,61p' "$0"; exit 0 ;;
        -*)                      echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
        *)                       CLI_USERS+=("$1"); shift ;;
    esac
done

FORMATS=(${(s:,:)SECRET_FORMATS})
for _f in "${FORMATS[@]}"; do
    if [[ "${_f}" != (key|credentials|generic) ]]; then
        echo "[ERROR] Unknown secret format '${_f}' (key, credentials, generic)." >&2
        exit 1
    fi
done
unset _f
FORMATS=(${(u)FORMATS})
if (( ${FORMATS[(Ie)key]} && ${FORMATS[(Ie)generic]} )); then
    echo "[ERROR] 'key' and 'generic' secrets are both named '<username>-apikey'; pick one." >&2
    exit 1
fi
if [[ "${SECRET_OWNER}" != (user|admin) ]]; then
    echo "[ERROR] Unknown owner '${SECRET_OWNER}' (user, admin)." >&2
    exit 1
fi

if [[ -z "${SH_URL}" ]]; then
    echo "[ERROR] No Software Hub URL. Pass --cpd-url or set CPD_URL." >&2
    exit 1
fi
SH_URL="${SH_URL%/}"
[[ "${SH_URL}" == http* ]] || SH_URL="https://${SH_URL}"

: "${CPD_USERNAME:?CPD_USERNAME is not set, run 3.3.1_get_instance_creds.sh first}"
if [[ -z "${CPD_APIKEY:-}" && -z "${CPD_PASSWORD:-}" ]]; then
    echo "[ERROR] Neither CPD_APIKEY nor CPD_PASSWORD is set, run 3.3.1_get_instance_creds.sh first." >&2
    exit 1
fi

# --- Read the keys -----------------------------------------------------------------
typeset -A KEYS PASSWORDS
USERS=()
if [[ "${FROM_FILE}" == true ]]; then
    if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
        echo "[ERROR] ${CREDENTIALS_FILE} not found." >&2
        exit 1
    fi
    _cur=""
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ "${_line}" == apikey=* ]]; then
            [[ -n "${_cur}" ]] && KEYS[${_cur}]="${_line#apikey=}"
        elif [[ -n "${_line}" && "${_line}" != \#* && "${_line}" == *:* ]]; then
            _cur="${_line%%:*}"
            PASSWORDS[${_cur}]="${_line#*:}"
        fi
    done < "${CREDENTIALS_FILE}"
    unset _cur _line
    if (( ${#CLI_USERS} > 0 )); then
        for _u in "${CLI_USERS[@]}"; do
            if [[ -z "${KEYS[${_u}]:-}" ]]; then
                echo "[ERROR] No API key for '${_u}' in ${CREDENTIALS_FILE}." >&2
                exit 1
            fi
        done
        unset _u
        USERS=("${CLI_USERS[@]}")
    else
        USERS=(${(ok)KEYS})
    fi
else
    if (( ${#CLI_USERS} > 0 )); then
        echo "[ERROR] User names on the command line only go with --from-credentials-file; pipe 'username:apikey' lines instead." >&2
        exit 1
    fi
    if [[ -t 0 ]]; then
        echo "[ERROR] Pipe 'username:apikey[:password]' lines on stdin, or use --from-credentials-file." >&2
        exit 1
    fi
    # API keys have no ':', so everything after the second ':' is the password.
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        [[ -z "${_line}" || "${_line}" == \#* ]] && continue
        if [[ "${_line}" != *:* ]]; then
            echo "[ERROR] Not a 'username:apikey[:password]' line on stdin (contents hidden)." >&2
            exit 1
        fi
        _u="${_line%%:*}" _rest="${_line#*:}"
        [[ -z "${KEYS[${_u}]+x}" ]] && USERS+=("${_u}")
        KEYS[${_u}]="${_rest%%:*}"
        [[ "${_rest}" == *:* ]] && PASSWORDS[${_u}]="${_rest#*:}"
    done
    unset _line _u _rest
fi
if (( ${#USERS} == 0 )); then
    echo "[ERROR] No API keys to store." >&2
    exit 1
fi


# --- Store the secrets (src/helpers/softwarehub_internal_vault_helpers.py) -----------
# The keys go to Python as 'username:apikey:password' lines on stdin, so they stay
# out of the process list; the settings go in the environment.
read -r -d '' STORE_PY <<'PY' || true
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"])
from src.helpers.softwarehub_internal_vault_helpers import (
    SoftwareHubVault, SecretNameTakenError, VaultAPIError, VaultError, credentials_secret,
    generic_secret, key_secret, members, redact, secret_name_for, zen_api_key)
import json

env = os.environ
url, vault_urn, admin = env["SH_URL"], env["VAULT_URN"], env["CPD_USERNAME"]
formats, owner, verbose = env["FORMATS"].split(), env["SECRET_OWNER"], env["VERBOSE"] == "true"

def show(method, path, status, body):
    """With VERBOSE, every API call and its response, secrets hidden."""
    if not verbose:
        return
    shown = json.dumps(redact(body), indent=2) if isinstance(body, (dict, list)) else str(body)[:2000]
    print(f"[API]  {method} {path.split('?')[0]}: HTTP {status}", file=sys.stderr)
    print("\n".join("         " + line for line in shown.splitlines()), file=sys.stderr)

def error(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)

# API keys have no ':', so everything after the second ':' is the password.
users = []
for line in sys.stdin.read().splitlines():
    user, key, *pw = line.split(":", 2)
    users.append((user, key, pw[0] if pw else ""))

try:
    if env.get("CPD_APIKEY"):
        admin_vault = SoftwareHubVault.sign_in(url, admin, api_key=env["CPD_APIKEY"], on_response=show)
    else:
        admin_vault = SoftwareHubVault.sign_in(url, admin, password=env["CPD_PASSWORD"], on_response=show)
    admin_uid = admin_vault.current_uid()
except VaultError as e:
    error(f"Sign-in as '{admin}' at {url} failed: {e}")
    sys.exit(1)

admin_member = None
if owner == "user":
    if not admin_uid:
        error(f"Could not look up the uid of '{admin}', needed to add it to the secrets.")
        sys.exit(1)
    admin_member = members(users=[{"uid": admin_uid, "username": admin}])

print(f"[INFO] Software Hub: {url}, vault {vault_urn}, secrets: {', '.join(formats)}")
print(f"[INFO] Each secret is owned by its user, with '{admin}' as a member." if owner == "user"
      else f"[INFO] Secrets owned by '{admin}'.")

def wanted(user, key, password, fmt):
    """(name, type, secret, description) of USER's secret in format FMT."""
    if fmt == "key":
        return secret_name_for(user, "apikey"), "key", key_secret(key), f"Software Hub API key for {user}"
    if fmt == "credentials":
        return (secret_name_for(user, "credentials"), "credentials", credentials_secret(user, password),
                f"Software Hub username and password for {user}")
    return (secret_name_for(user, "apikey"), "generic",
            generic_secret(username=user, api_key=key, zen_api_key=zen_api_key(user, key), cpd_url=url),
            f"Software Hub API key for {user}")

done = {"created": [], "updated": [], "unchanged": [], "failed": []}
for user, key, password in users:
    if owner == "user":
        try:
            vault = SoftwareHubVault.sign_in(url, user, api_key=key, on_response=show)
            if not vault.current_uid():
                print(f"[WARN] '{user}': uid unknown, matching existing secrets by name only.", file=sys.stderr)
        except VaultError as e:
            error(f"Sign-in as '{user}' failed: {e}")
            done["failed"] += [f"{user} ({fmt})" for fmt in formats]
            continue
    else:
        vault = admin_vault
    for fmt in formats:
        name, type_, secret, desc = wanted(user, key, password, fmt)
        if fmt == "credentials" and not password:
            error(f"'{user}': no password to store in '{name}' (pipe 'username:apikey:password' lines, or use --from-credentials-file).")
            done["failed"].append(name)
            continue
        try:
            result = vault.store_secret(name, secret, type=type_, vault_urn=vault_urn,
                                        description=desc, members=admin_member)
        except SecretNameTakenError as e:
            error(f"'{user}': creating secret '{name}' failed: {e}")
            print(f"       The name is taken but '{user}' has no such secret: probably left behind by a failed create. "
                  "It has to be removed from the Software Hub metastore before this name can be used again.", file=sys.stderr)
            done["failed"].append(name)
            continue
        except VaultError as e:
            error(f"'{user}': storing secret '{name}' failed: {e}")
            done["failed"].append(name)
            continue
        if result.action == "replaced":
            print(f"[WARN] '{user}': secret '{name}' was of type '{result.previous_type}', replaced it with a '{type_}' secret.", file=sys.stderr)
            done["created"].append(name)
        else:
            done[result.action].append(name)
            print({"created": f"[INFO] '{user}': stored as new {type_} secret '{name}'.",
                   "updated": f"[INFO] '{user}': secret '{name}' updated.",
                   "unchanged": f"[INFO] '{user}': secret '{name}' is already up to date."}[result.action])

print(f"[INFO] Vault secrets: {len(done['created'])} created, {len(done['updated'])} updated, "
      f"{len(done['unchanged'])} unchanged, {len(done['failed'])} failed.")
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

for _u in "${USERS[@]}"; do
    print -r -- "${_u}:${KEYS[${_u}]}:${PASSWORDS[${_u}]:-}"
done | REPO_ROOT="${REPO_ROOT}" SH_URL="${SH_URL}" VAULT_URN="${VAULT_URN}" FORMATS="${FORMATS[*]}" \
    SECRET_OWNER="${SECRET_OWNER}" VERBOSE="${VERBOSE}" CPD_USERNAME="${CPD_USERNAME}" \
    CPD_APIKEY="${CPD_APIKEY:-}" CPD_PASSWORD="${CPD_PASSWORD:-}" \
    "${PYTHON_CMD[@]}" -c "${STORE_PY}"
