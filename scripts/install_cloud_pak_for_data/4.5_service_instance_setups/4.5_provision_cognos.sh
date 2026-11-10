#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
repo_dir="${SCRIPT_DIR}"
while [[ "${repo_dir}" != / && ! -f "${repo_dir}/env_bootstrap.sh" ]]; do
    repo_dir="${repo_dir:h}"
done
[[ -f "${repo_dir}/env_bootstrap.sh" ]] || { print -u2 -- "Repository root not found"; exit 1; }
source "${repo_dir}/env_bootstrap.sh"

for argument in "$@"; do
    if [[ "${argument}" == --apply || "${argument}" == --wait-only ]]; then
        eval "${OC_LOGIN}"
        break
    fi
done
export PYTHONPATH="${repo_dir}/src${PYTHONPATH:+:${PYTHONPATH}}"
exec uv run --quiet python "${repo_dir}/src/helpers/cognos_provisioning.py" "$@"
