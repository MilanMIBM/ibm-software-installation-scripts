#!/bin/zsh
# Load the env into the current shell and log in to the cluster.
#
#     source s_env.sh [TARGET] [KEY=VALUE ...]
#
#   TARGET     config to load (same as ENV_TARGET): a bare name (cpd, confluent,
#              concert) or a path to a *_vars.sh file. Omitted: uses ENV_TARGET
#              from the shell if set, otherwise loads every config.
#   KEY=VALUE  variables to override after the config is loaded (and before the
#              login commands are built, so e.g. OCP_URL=... is honoured).
#
# Examples:
#     source s_env.sh cpd
#     source s_env.sh confluent OCP_URL=https://api.other:6443
#     source s_env.sh PROJECT_CPD_INST_OPERANDS=cpd-test
#
# Always reloads, even if the env was already loaded in this shell.

_s_env_target=""
_ENV_OVERRIDES=()
for _a in "$@"; do
    case "${_a}" in
        -h|--help)
            sed -n '2,17p' "${${(%):-%x}:A}" | sed 's/^# \{0,1\}//'
            unset _a _s_env_target _ENV_OVERRIDES
            return 0 ;;
        *=*)
            if [[ ! "${_a%%=*}" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]]; then
                echo "[ERROR] Invalid variable name in '${_a}'" >&2
                unset _a _s_env_target _ENV_OVERRIDES
                return 1
            fi
            _ENV_OVERRIDES+=("${_a}") ;;
        *)
            if [[ -n "${_s_env_target}" ]]; then
                echo "[ERROR] Only one target allowed (got '${_s_env_target}' and '${_a}')" >&2
                unset _a _s_env_target _ENV_OVERRIDES
                return 1
            fi
            _s_env_target="${_a}" ;;
    esac
done

unset _CP4D_ENV_LOADED
ENV_TARGET="${_s_env_target:-${ENV_TARGET:-}}" source "${${(%):-%x}:A:h}/scripts/source_env_setup.sh" || {
    unset _a _s_env_target _ENV_OVERRIDES
    return 1
}
unset _a _s_env_target _ENV_OVERRIDES

eval "${CPDM_OC_LOGIN}"

eval "${OC_LOGIN}"
