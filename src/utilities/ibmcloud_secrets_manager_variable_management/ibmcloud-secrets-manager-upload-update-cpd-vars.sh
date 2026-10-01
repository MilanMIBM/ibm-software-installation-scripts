#!/bin/zsh
# =============================================================================
# ibmcloud-secrets-manager-upload-update-cpd-vars.sh
# -----------------------------------------------------------------------------
# Wrapper around ibmcloud-secrets-manager-upload-update-cpd-vars.py: uploads
# cpd_vars.sh and install-options.yml into an IBM Cloud Secrets Manager instance
# as key/value secrets. All arguments are passed straight through to the Python
# script; run with --help to see them.
#
#   ./ibmcloud-secrets-manager-upload-update-cpd-vars.sh \
#       --instance-id <guid> --region eu-de --secret-group cp4d-configs
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY_SCRIPT="${SCRIPT_DIR}/ibmcloud-secrets-manager-upload-update-cpd-vars.py"

if [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
    exec "${REPO_ROOT}/.venv/bin/python" "${PY_SCRIPT}" "$@"
elif command -v uv >/dev/null 2>&1; then
    exec uv run --project "${REPO_ROOT}" python "${PY_SCRIPT}" "$@"
else
    exec python3 "${PY_SCRIPT}" "$@"
fi
