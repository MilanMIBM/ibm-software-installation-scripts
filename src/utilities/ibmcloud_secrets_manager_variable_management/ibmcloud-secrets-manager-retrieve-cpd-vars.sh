#!/bin/zsh
# =============================================================================
# ibmcloud-secrets-manager-retrieve-cpd-vars.sh
# -----------------------------------------------------------------------------
# Wrapper around ibmcloud-secrets-manager-retrieve-cpd-vars.py: rebuilds
# cpd_vars.sh and install-options.yml from the key/value secrets stored in an
# IBM Cloud Secrets Manager instance. All arguments are passed straight through
# to the Python script; run with --help to see them.
#
#   ./ibmcloud-secrets-manager-retrieve-cpd-vars.sh \
#       --instance-id <guid> --region eu-de --secret-group cp4d-configs --list
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY_SCRIPT="${SCRIPT_DIR}/ibmcloud-secrets-manager-retrieve-cpd-vars.py"

if [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
    exec "${REPO_ROOT}/.venv/bin/python" "${PY_SCRIPT}" "$@"
elif command -v uv >/dev/null 2>&1; then
    exec uv run --project "${REPO_ROOT}" python "${PY_SCRIPT}" "$@"
else
    exec python3 "${PY_SCRIPT}" "$@"
fi
