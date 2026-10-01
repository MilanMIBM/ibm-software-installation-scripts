#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# -----------------------------------------------------------------------------
# Creates one or more keyspaces in a DataStax HyperConvergedDatabase (HCD) via
# its DataAPI endpoint, mirroring the astrapy initialize_hcd_database() flow:
#   token  = UsernamePasswordTokenProvider(user, password)
#   client = DataAPIClient(environment=DataStaxEnvironment.HCD)
#   db     = client.get_database(endpoint, token=token, keyspace=<name>)
#   db.get_database_admin().create_keyspace(<name>, update_db_keyspace=True)
#
# Connection details are read from cp4d_config/cpd_instance_details.sh (written
# by 5_prep_datastax_mc.sh):
#   DATASTAX_HCD_ENDPOINT, DATASTAX_HCD_API_USER, DATASTAX_HCD_API_PASSWORD
#
# Which keyspaces get created:
#   - Default: the single keyspace named by DATASTAX_HCD_KEYSPACE (falls back to
#     "default_keyspace" when that var is empty/unset).
#   - When keyspace names are passed as positional arguments, OR the boolean
#     USE_ARG_KEYSPACES=true is set, the script instead creates the list defined
#     below in KEYSPACES (default_keyspace is always included). Positional
#     arguments override the in-script KEYSPACES list when both are present.
#
# Usage:
#   ./5_1_prep_datastax_hcd_keyspace.sh
#   ./5_1_prep_datastax_hcd_keyspace.sh my_keyspace another_keyspace
#   USE_ARG_KEYSPACES=true ./5_1_prep_datastax_hcd_keyspace.sh
# -----------------------------------------------------------------------------

# --- Local keyspace list, used when USE_ARG_KEYSPACES=true and no positional
#     arguments are given. default_keyspace is always present (see below).
USE_ARG_KEYSPACES="${USE_ARG_KEYSPACES:-false}"
KEYSPACES=(
    default_keyspace
)

# Normalise a flag value to a lowercase truthiness check.
_is_true() {
    case "${1:l}" in
        1|true|yes|y) return 0 ;;
        *) return 1 ;;
    esac
}

# Locate the repo root (marker: pyproject.toml).
REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/cpd_instance_details.sh"

# --- Source the HCD connection details if the instance details file exists.
if [[ -f "${VARS_FILE}" ]]; then
    echo "[INFO] Sourcing HCD connection details from ${VARS_FILE##*/}"
    source "${VARS_FILE}"
else
    echo "[WARN] Instance details file not found: ${VARS_FILE}"
    echo "[WARN] Expecting DATASTAX_HCD_ENDPOINT / DATASTAX_HCD_API_USER /"
    echo "       DATASTAX_HCD_API_PASSWORD to be set in the environment instead."
fi

# --- Verify the required connection variables are present.
_MISSING=()
for var in DATASTAX_HCD_ENDPOINT DATASTAX_HCD_API_USER DATASTAX_HCD_API_PASSWORD; do
    if [[ -z "${(P)var:-}" ]]; then
        _MISSING+=("${var}")
    fi
done
if (( ${#_MISSING[@]} > 0 )); then
    echo "[ERROR] Missing required HCD connection variable(s): ${_MISSING[*]}"
    echo "[ERROR] Run 5_prep_datastax_mc.sh first (it writes these to"
    echo "        ${VARS_FILE##*/}), or export them before running this script."
    exit 1
fi

# --- Decide the set of keyspaces to create.
if (( $# > 0 )); then
    # Positional arguments take precedence over everything else.
    KEYSPACES=("$@")
    echo "[INFO] Using keyspace list from command-line arguments."
elif _is_true "${USE_ARG_KEYSPACES}"; then
    echo "[INFO] USE_ARG_KEYSPACES is true - using the in-script KEYSPACES list."
else
    # Single keyspace from config, defaulting to default_keyspace.
    KEYSPACES=("${DATASTAX_HCD_KEYSPACE:-default_keyspace}")
    echo "[INFO] Using DATASTAX_HCD_KEYSPACE from config (defaulting to default_keyspace)."
fi

# Always ensure default_keyspace is part of the set (de-duplicated).
typeset -aU _FINAL_KEYSPACES
_FINAL_KEYSPACES=("default_keyspace" "${KEYSPACES[@]}")
KEYSPACES=("${_FINAL_KEYSPACES[@]}")

echo "[INFO] Endpoint : ${DATASTAX_HCD_ENDPOINT}"
echo "[INFO] User     : ${DATASTAX_HCD_API_USER}"
echo "[INFO] Keyspaces: ${KEYSPACES[*]}"
echo ""

# --- Pick the repo's virtualenv python if present, otherwise fall back to python3.
if [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
    PYTHON="${REPO_ROOT}/.venv/bin/python"
else
    PYTHON="python3"
fi

# --- astrapy provides the DataAPI client used to create HCD keyspaces. Ensure
#     it is importable, installing it into the repo venv via uv when missing.
if ! "${PYTHON}" -c "import astrapy" 2>/dev/null; then
    echo "[INFO] astrapy not found - installing it into the environment via uv..."
    if command -v uv >/dev/null 2>&1; then
        ( cd "${REPO_ROOT}" && uv pip install astrapy )
    else
        "${PYTHON}" -m pip install astrapy
    fi
fi

# --- Create the keyspaces. The keyspace names are passed as arguments to the
#     Python helper so credentials are only handled via the environment.
echo "[INFO] Creating keyspace(s) on the HCD DataAPI endpoint using ${PYTHON}..."
echo ""

DATASTAX_HCD_ENDPOINT="${DATASTAX_HCD_ENDPOINT}" \
DATASTAX_HCD_API_USER="${DATASTAX_HCD_API_USER}" \
DATASTAX_HCD_API_PASSWORD="${DATASTAX_HCD_API_PASSWORD}" \
"${PYTHON}" - "${KEYSPACES[@]}" <<'PY'
import os
import sys

from astrapy import DataAPIClient
from astrapy.authentication import UsernamePasswordTokenProvider
from astrapy.constants import Environment as DataStaxEnvironment


def initialize_hcd_database(api_endpoint, username, password, keyspace=None):
    """Initialize a DataStax HCD Database client; return None when required inputs are missing."""
    if not api_endpoint or not username or not password:
        return None

    keyspace = keyspace or "default_keyspace"
    token = UsernamePasswordTokenProvider(username, password)
    client = DataAPIClient(environment=DataStaxEnvironment.HCD)
    db = client.get_database(api_endpoint, token=token, keyspace=keyspace)
    db.get_database_admin().create_keyspace(
        keyspace,
        update_db_keyspace=True,
    )
    return db


def main():
    api_endpoint = os.environ.get("DATASTAX_HCD_ENDPOINT")
    username = os.environ.get("DATASTAX_HCD_API_USER")
    password = os.environ.get("DATASTAX_HCD_API_PASSWORD")

    keyspaces = sys.argv[1:] or ["default_keyspace"]

    failures = 0
    for keyspace in keyspaces:
        try:
            db = initialize_hcd_database(api_endpoint, username, password, keyspace)
            if db is None:
                print(f"[ERROR] Missing endpoint/user/password; cannot create '{keyspace}'.")
                failures += 1
                continue
            print(f"[OK] Keyspace '{keyspace}' is present.")
        except Exception as exc:  # noqa: BLE001 - surface any DataAPI error per keyspace
            print(f"[ERROR] Failed to create keyspace '{keyspace}': {exc}")
            failures += 1

    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
PY

echo ""
echo "=== Done ==="
