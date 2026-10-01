#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# NOTE: no `set -e` here. This script is normally SOURCED, and a failing command
# under `set -e` would kill the caller's interactive shell. Errors are checked
# explicitly and reported through _fail() instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"

# ==============================================================================
# Confluent Platform - connect the confluent CLI to this cluster
# ------------------------------------------------------------------------------
# Installs the confluent CLI if it is missing, logs in against the MDS endpoint
# of the deployed cluster, and leaves the shell configured so ordinary commands
# ("confluent kafka topic list", "confluent iam rbac role-binding list", ...)
# just work.
#
# SOURCE IT to keep the environment in your shell:
#
#     source src/scripts/confluent_install/confluent_cli_login.sh
#     confluent kafka topic list
#
# Running it directly (./confluent_cli_login.sh) still installs the CLI and
# performs the login - the CLI stores its token in ~/.confluent, so the session
# outlives this process - but the CONFLUENT_* environment variables are lost
# when it exits.
#
# Everything comes from cp4d_config/confluent_instance_details.sh, regenerated
# by 1.3_confluent_get_instance_details.sh. This script reads that file; it
# never writes credentials of its own.
#
# Requires MDS: run x.4_confluent_add_mds.sh first. Without it there is no
# endpoint to log in against ("confluent login" needs MDS, which is the whole
# reason that script exists).
#
# Usage:
#   source confluent_cli_login.sh [--refresh] [--no-install] [--status]
#
#   --refresh     re-run 1.3_confluent_get_instance_details.sh first, picking up
#                 endpoints or credentials that changed
#   --no-install  never install the CLI; fail if it is missing
#   --status      report what is configured and log in nothing
# ==============================================================================

# Sourced or executed? Needed so we return rather than exit when sourced.
_CLI_SOURCED=false
if [[ "${ZSH_EVAL_CONTEXT:-}" == *:file* ]] || [[ "${BASH_SOURCE[0]:-$0}" != "$0" ]]; then
    _CLI_SOURCED=true
fi

# Reports an error, then leaves the caller with a failing status: `return 1`
# when sourced (so an interactive shell survives) and `exit 1` when executed.
# Callers must not append `|| exit 1` - that would run in a subshell context
# where _fail's exit has already been decided, and would mask the status.
_fail() {
    echo "[ERROR] $*" >&2
    if $_CLI_SOURCED; then return 1; else exit 1; fi
}

REFRESH=false
NO_INSTALL=false
STATUS_ONLY=false

for _a in "$@"; do
    case "${_a}" in
        --refresh)    REFRESH=true ;;
        --no-install) NO_INSTALL=true ;;
        --status)     STATUS_ONLY=true ;;
        -h|--help)    sed -n '14,47p' "${SCRIPT_DIR}/confluent_cli_login.sh" | sed 's/^# \{0,1\}//'
                      if $_CLI_SOURCED; then return 0; else exit 0; fi ;;
        *) _fail "Unknown argument '${_a}'. Try --help."; return 1 ;;
    esac
done

# ------------------------------------------------------------------------------
# Locate the repo and the generated details file
# ------------------------------------------------------------------------------
REPO_ROOT="${SCRIPT_DIR}"
while [[ "${REPO_ROOT}" != "/" && ! -f "${REPO_ROOT}/pyproject.toml" ]]; do
    REPO_ROOT="$(dirname "${REPO_ROOT}")"
done
[[ -f "${REPO_ROOT}/pyproject.toml" ]] || _fail "Could not locate the repo root from ${SCRIPT_DIR}."

DETAILS="${REPO_ROOT}/cp4d_config/confluent_instance_details.sh"

if $REFRESH; then
    echo "[INFO] Refreshing instance details..."
    if ! "${SCRIPT_DIR}/1.3_confluent_get_instance_details.sh" >/dev/null 2>&1; then
        echo "[WARN] Could not refresh (is oc logged in?). Using the existing file."
    fi
fi

[[ -f "${DETAILS}" ]] || _fail "Not found: ${DETAILS##*/}
        Run: src/scripts/confluent_install/1.3_confluent_get_instance_details.sh"

source "${DETAILS}"

# ------------------------------------------------------------------------------
# Install the CLI if it is missing
# ------------------------------------------------------------------------------
# Preference order: an existing binary, then Homebrew (keeps it upgradeable via
# brew on macOS), then Confluent's official installer into ~/.confluent/bin.
install_cli() {
    echo "[INFO] The confluent CLI is not on PATH. Installing..."

    if command -v brew >/dev/null 2>&1; then
        echo "[INFO] Installing via Homebrew..."
        if brew install confluentinc/tap/cli >/dev/null 2>&1 || brew install confluent-cli >/dev/null 2>&1; then
            command -v confluent >/dev/null 2>&1 && { echo "[INFO] Installed $(confluent version 2>/dev/null | awk '/^Version/{print $2}')."; return 0; }
        fi
        echo "[WARN] Homebrew install failed; falling back to the official installer."
    fi

    # Official installer. -b chooses the install dir; it does not touch PATH,
    # so we add it below for this shell and tell the user how to persist it.
    local dest="${HOME}/.confluent/bin"
    mkdir -p "${dest}"
    if ! curl -fsSL https://cnfl.io/cli 2>/dev/null | sh -s -- -b "${dest}" >/dev/null 2>&1; then
        _fail "Could not install the confluent CLI automatically.
        Install it manually:  https://docs.confluent.io/confluent-cli/current/install.html"
        return 1
    fi
    export PATH="${dest}:${PATH}"
    echo "[INFO] Installed to ${dest}."
    echo "[INFO] Add it to your PATH permanently:"
    echo "         echo 'export PATH=\"${dest}:\$PATH\"' >> ~/.zshrc"
    return 0
}

if ! command -v confluent >/dev/null 2>&1; then
    # A previous run of this script may already have installed it here.
    [[ -x "${HOME}/.confluent/bin/confluent" ]] && export PATH="${HOME}/.confluent/bin:${PATH}"
fi

if ! command -v confluent >/dev/null 2>&1; then
    if $NO_INSTALL; then
        _fail "The confluent CLI is not installed and --no-install was given."
        return 1
    fi
    install_cli || return 1
fi

# ------------------------------------------------------------------------------
# Export what the CLI reads natively
# ------------------------------------------------------------------------------
# The CLI picks these up on its own, so a bare "confluent login" works, and so
# does a non-interactive re-login when the 6-hour token expires.
export CONFLUENT_PLATFORM_MDS_URL="${CONFLUENT_PLATFORM_MDS_URL:-${CONFLUENT_MDS_URL:-}}"
export CONFLUENT_PLATFORM_USERNAME="${CONFLUENT_PLATFORM_USERNAME:-${CONFLUENT_MDS_USER:-}}"
export CONFLUENT_PLATFORM_PASSWORD="${CONFLUENT_PLATFORM_PASSWORD:-${CONFLUENT_MDS_PASS:-}}"

# Kafka bootstrap for the subcommands that take one directly. Prefer the
# external routes when they exist, since this shell is usually off-cluster.
export CONFLUENT_BOOTSTRAP="${CONFLUENT_BOOTSTRAP_EXTERNAL:-${CONFLUENT_BOOTSTRAP_INTERNAL:-}}"

_ca="${REPO_ROOT}/cp4d_config/confluent_kafka_ca.crt"
[[ -f "${_ca}" ]] && export CONFLUENT_PLATFORM_CERTIFICATE_AUTHORITY_PATH="${_ca}"

# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo " Confluent CLI - project '${CONFLUENT_NAMESPACE:-?}'"
echo "=============================================================================="
echo "  cli          : $(command -v confluent) ($(confluent version 2>/dev/null | awk '/^Version/{print $2}'))"
echo "  mds url      : ${CONFLUENT_PLATFORM_MDS_URL:-<none - run x.4_confluent_add_mds.sh>}"
echo "  user         : ${CONFLUENT_PLATFORM_USERNAME:-<none>}"
echo "  kafka        : ${CONFLUENT_BOOTSTRAP:-<none>}"
[[ -n "${CONFLUENT_PLATFORM_CERTIFICATE_AUTHORITY_PATH:-}" ]] && \
    echo "  ca cert      : ${CONFLUENT_PLATFORM_CERTIFICATE_AUTHORITY_PATH##*/}"
echo ""

if $STATUS_ONLY; then
    confluent context list 2>/dev/null || true
    return 0 2>/dev/null || exit 0
fi

# ------------------------------------------------------------------------------
# Log in
# ------------------------------------------------------------------------------
if [[ -z "${CONFLUENT_PLATFORM_MDS_URL}" ]]; then
    echo "[WARN] No MDS endpoint, so there is nothing to log in to."
    echo "[WARN] MDS is what makes 'confluent login' work. Enable it with:"
    echo "[WARN]   ${SCRIPT_DIR}/x.4_confluent_add_mds.sh"
    echo ""
    echo "[INFO] The CLI is installed and on PATH, but every confluent subcommand"
    echo "[INFO] requires an active login - even ones given an explicit --endpoint."
    echo "[INFO] Until MDS is enabled, use the REST endpoints directly instead:"
    echo "[INFO]   curl -s \"\${CONFLUENT_SCHEMA_REGISTRY_URL}/subjects\""
    echo "[INFO]   curl -s \"\${CONFLUENT_CONNECT_URL}/connectors\""
    echo "[INFO] or run kafka-* tools inside a broker pod:"
    echo "[INFO]   oc exec broker-0 -n \${CONFLUENT_NAMESPACE} -- kafka-topics \\"
    echo "[INFO]     --bootstrap-server localhost:29092 --list"
    return 0 2>/dev/null || exit 0
fi

if [[ -z "${CONFLUENT_PLATFORM_USERNAME}" || -z "${CONFLUENT_PLATFORM_PASSWORD}" ]]; then
    _fail "MDS is reachable but no credentials are in ${DETAILS##*/}.
        Regenerate them:  ${SCRIPT_DIR}/1.3_confluent_get_instance_details.sh"
    return 1
fi

# An explicit port is required. Given a URL without one the CLI does NOT fall
# back to the scheme default: it prints "Assuming default MDS port 8090" and
# dials :8090, which on an OpenShift route hangs until it times out - the router
# only listens on 80/443 and nothing is published on 8090 externally. Adding
# :443 (the port the edge-terminated route actually serves) is what makes the
# hostname resolve to a reachable endpoint.
_mds_login_url="${CONFLUENT_PLATFORM_MDS_URL}"
if [[ "${_mds_login_url}" == https://* && "${_mds_login_url#https://}" != *:* ]]; then
    _mds_login_url="${_mds_login_url}:443"
elif [[ "${_mds_login_url}" == http://* && "${_mds_login_url#http://}" != *:* ]]; then
    _mds_login_url="${_mds_login_url}:80"
fi

# A self-signed MDS certificate needs the CA passed explicitly; the route is
# normally edge-terminated with the cluster's own cert, which the system trust
# store already covers.
_login_args=(--url "${_mds_login_url}")
[[ -n "${CONFLUENT_PLATFORM_CERTIFICATE_AUTHORITY_PATH:-}" ]] && \
    _login_args+=(--certificate-authority-path "${CONFLUENT_PLATFORM_CERTIFICATE_AUTHORITY_PATH}")

echo "[INFO] Logging in as '${CONFLUENT_PLATFORM_USERNAME}'..."
if confluent login "${_login_args[@]}" --save 2>&1 | sed 's/^/         /'; then
    echo ""
    echo "[INFO] Logged in. The token is saved in ~/.confluent and lasts 6 hours;"
    echo "[INFO] --save lets the CLI renew it non-interactively after that."
    echo ""
    echo "  Try:"
    echo "    confluent iam rbac role-binding list --principal User:${CONFLUENT_PLATFORM_USERNAME} \\"
    echo "      --kafka-cluster ${CONFLUENT_RUNNING_CLUSTER_ID:-<cluster-id>}"
    echo "    confluent cluster list"
else
    echo ""
    echo "[WARN] Login failed. Common causes:"
    echo "[WARN]   - the brokers are still restarting after x.4_confluent_add_mds.sh"
    echo "[WARN]   - the MDS 30-day trial expired (set CONFLUENT_LICENSE_KEY)"
    echo "[WARN]   - the user store has no '${CONFLUENT_PLATFORM_USERNAME}' account"
    echo "[WARN] Check MDS:  oc logs broker-0 -n ${CONFLUENT_NAMESPACE:-?} | grep -i metadata"
fi
