#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
repo_dir="${SCRIPT_DIR}"
while [[ "${repo_dir}" != / && ! -f "${repo_dir}/env_bootstrap.sh" ]]; do
    repo_dir="${repo_dir:h}"
done
[[ -f "${repo_dir}/env_bootstrap.sh" ]] || { print -u2 -- "Repository root not found"; exit 1; }

# Keep --check free of bootstrap side effects, including Podman startup and config execution.
exec python3 "${repo_dir}/src/helpers/cognos_content_store.py" "$@"
