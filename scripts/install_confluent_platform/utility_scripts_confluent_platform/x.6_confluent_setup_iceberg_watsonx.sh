#!/bin/zsh
set -euo pipefail
umask 077

usage() {
    cat <<'USAGE'
Usage: x.6_confluent_setup_iceberg_watsonx.sh [--config FILE] [--service-id USER]
                                          [--dry-run] [--prepare-only]

Creates or reuses a Software Hub SID, grants lakehouse Metastore Admin, installs
the Iceberg plugin if missing, and creates or updates the configured connector.
Run after Confluent and the external COS-backed watsonx.data catalog are ready.

--config FILE   Shell configuration containing exported ICEBERG_* settings.
                Default: configs/confluent_platform_config/iceberg_watsonx_setup.sh
--service-id    Override the configured SID (default: svc-iceberg).
--dry-run       Validate prerequisites and report work without changing resources
                or writing connector JSON. Environment loading, sign-in and
                stateless validation still run.
--prepare-only  Prepare a private JSON for Control Center upload without creating
                or updating a connector. Identity/role/plugin setup still runs.

The standard Confluent full installer calls this script when
DO_ICEBERG_WATSONX_SETUP=true. It can also be run directly later.
USAGE
}

for _arg in "$@"; do
    if [[ "${_arg}" == -h || "${_arg}" == --help ]]; then usage; exit 0; fi
done
unset _arg

SCRIPT_DIR="${0:A:h}"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"
while [[ "${_b}" != / && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="${_b:h}"; done
source "${_b}/env_bootstrap.sh"
unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

_setup_config="${ICEBERG_WATSONX_CONFIG_FILE:-${_CP4D_REPO_ROOT}/configs/confluent_platform_config/iceberg_watsonx_setup.sh}"
_setup_args=()
while (( $# )); do
    case "$1" in
        --config) h_need_value "$1" "${2:-}"; _setup_config="$2"; shift 2 ;;
        --service-id) h_need_value "$1" "${2:-}"; _setup_args+=("$1" "$2"); shift 2 ;;
        --dry-run|--prepare-only) _setup_args+=("$1"); shift ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

if [[ ! -f "${_setup_config}" ]]; then
    echo "[ERROR] Setup config not found: ${_setup_config}" >&2
    echo "[ERROR] Copy connector_configs/iceberg-watsonx.example.sh into the ignored configs directory and fill its values." >&2
    exit 1
fi
source "${_setup_config}"

# Read only CPD credentials in a subshell so Confluent's cluster settings stay in scope.
_details="${ICEBERG_CPD_DETAILS_FILE:-${_CP4D_REPO_ROOT}/configs/cp4d_config/cpd_instance_details.sh}"
for _key in CPD_URL CPD_USERNAME CPD_APIKEY CPD_PASSWORD; do
    if [[ -z "${(P)_key:-}" && -f "${_details}" ]]; then
        _value="$(source "${_details}" >/dev/null 2>&1; print -r -- "${(P)_key:-}")"
        export "${_key}=${_value}"
    fi
done
unset _key _value _details

for _tool in python3 oc git; do
    command -v "${_tool}" >/dev/null || { echo "[ERROR] '${_tool}' is required." >&2; exit 1; }
done
unset _tool

if [[ -n "${OC_LOGIN:-}" ]]; then eval "${OC_LOGIN}"; fi
exec python3 "${_CP4D_REPO_ROOT}/src/helpers/confluent_iceberg_setup.py" \
    --repo-root "${_CP4D_REPO_ROOT}" "${_setup_args[@]}"
