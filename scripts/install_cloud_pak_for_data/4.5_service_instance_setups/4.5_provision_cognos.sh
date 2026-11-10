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
# Payloads belong in the service-instance folder: <repo>/service_instances with
# multi-cluster mode off, configs/clusters/<cluster>/service_instances when the
# run's cluster has its own folder. A bare file name, or a relative path under
# service_instances/, resolves there, so one command writes one payload per
# cluster on a multi-cluster run. Absolute and other relative paths are kept.
_cognos_output_path() {
    local value="$1"
    if [[ -n "${value}" && "${value}" != /* && "${value}" != */* ]]; then
        print -r -- "${SERVICE_INSTANCE_FILE_DIR}/${value}"
    elif [[ "${value}" == service_instances/?* ]]; then
        print -r -- "${SERVICE_INSTANCE_FILE_DIR}/${value#service_instances/}"
    else
        print -r -- "${value}"
    fi
}
if [[ -n "${SERVICE_INSTANCE_FILE_DIR:-}" ]]; then
    typeset -a _cognos_argv
    while (( $# )); do
        case "$1" in
            --output=*) _cognos_argv+=("--output=$(_cognos_output_path "${1#--output=}")") ;;
            --output)
                _cognos_argv+=("$1")
                if (( $# > 1 )); then
                    shift
                    _cognos_argv+=("$(_cognos_output_path "$1")")
                fi
                ;;
            *) _cognos_argv+=("$1") ;;
        esac
        shift
    done
    set -- "${_cognos_argv[@]}"
    unset _cognos_argv
fi
export PYTHONPATH="${repo_dir}/src${PYTHONPATH:+:${PYTHONPATH}}"
exec uv run --quiet python "${repo_dir}/src/helpers/cognos_provisioning.py" "$@"
