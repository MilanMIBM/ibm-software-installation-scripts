#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# x_confluent_cr_dashboard.sh - live terminal dashboard of the Confluent CFK CRs
# -----------------------------------------------------------------------------
# Operator mode (CONFLUENT_DEPLOY_MODE=operator, docs/confluent-operator-mode.md):
# shows the Confluent for Kubernetes custom resources of the configured install
# as glowing dots (healthy / in progress / stuck / failing / inactive):
#   Kafka KRaftController SchemaRegistry Connect KsqlDB KafkaRestProxy
#   ControlCenter in PROJECT_CONFLUENT_SERVER, plus FlinkEnvironment and
#   FlinkApplication in FLINK_CFK_NAMESPACE when the Flink add-on keeps its CMF
#   resources as CFK CRs (FLINK_CMF_RESOURCE_MODE=cfk).
# Components that are switched off simply have no CR and do not show.
#
# Read-only: it never changes the cluster and writes no files. Without a
# terminal (a pipe, a CI log) it prints the current state once and exits.
# Status overrides: confluent_cr_dashboard_profile.yaml next to this script.
#
# Scripts mode (CONFLUENT_DEPLOY_MODE=scripts) has no CFK CRs; use
# 1.2_confluent_status.sh there.
#
# Usage:
#   ./x_confluent_cr_dashboard.sh                      # live dashboard
#   ./x_confluent_cr_dashboard.sh --once               # print the state and exit
#   ./x_confluent_cr_dashboard.sh --exit-when-settled  # exit once all green/gray for 5m
#   ./x_confluent_cr_dashboard.sh --help               # this text
# Every other option goes to the dashboard (python -m tui.cr_dashboard cr --help).
# Keys: q quit · f problems only · t tree mode · s sort · ? legend
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_helpers.sh"

for _a in "$@"; do
    case "${_a}" in
        -h|--help) sed -n '6,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done
unset _a

if ! cf_is_operator_mode; then
    echo "[ERROR] $(basename "$0") shows the CFK custom resources of operator mode; CONFLUENT_DEPLOY_MODE=scripts has none - use ${SCRIPT_DIR}/1.2_confluent_status.sh." >&2
    exit 1
fi
[[ -n "${PROJECT_CONFLUENT_SERVER:-}" ]] || { echo "[ERROR] PROJECT_CONFLUENT_SERVER is not set - generate confluent_vars.sh first." >&2; exit 1; }

# The dashboard reads the local kubeconfig only.
eval "${OC_LOGIN}"

# Every ref is looked up in every -n namespace (the cr profile takes the refs first, then the
# namespaces), so the Flink kinds are listed once and the Flink namespace is added once.
# Refs are <Kind>.<group>: a bare "Kafka" also matches Strimzi / Event Streams CRDs, and the
# dashboard would then pick whichever CRD it lists first.
CFK_GROUP=platform.confluent.io
REFS=(Kafka KRaftController SchemaRegistry Connect KsqlDB KafkaRestProxy ControlCenter)
NAMESPACES=(-n "${PROJECT_CONFLUENT_SERVER}")
if cf_flink_configured && [[ "$(cf_flink_cmf_resource_mode)" == cfk ]]; then
    REFS+=(FlinkEnvironment FlinkApplication)
    _flink_ns="${FLINK_CFK_NAMESPACE:-${PROJECT_CONFLUENT_FLINK}}"
    [[ "${_flink_ns}" != "${PROJECT_CONFLUENT_SERVER}" ]] && NAMESPACES+=(-n "${_flink_ns}")
    unset _flink_ns
fi

cd "${_CP4D_REPO_ROOT}"
export PYTHONPATH="${_CP4D_REPO_ROOT}/src${PYTHONPATH:+:${PYTHONPATH}}"
# --no-exec: the dashboard would exec into every Deployment's pod looking for an Ansible
# operator's runner events; CFK, cp-fko and CMF are Go/Java operators with none, so it only reads.
exec uv run --quiet python -m tui.cr_dashboard cr "${^REFS[@]}.${CFK_GROUP}" "${NAMESPACES[@]}" \
    --no-exec --profile-file "${SCRIPT_DIR}/confluent_cr_dashboard_profile.yaml" "$@"
