#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 2.3 Provision the external data stores (plan decision D4)
# ------------------------------------------------------------------------------
# Each step decides for itself whether it has work (its store is external and
# set to provision); the DO_* toggles only let you skip steps by hand:
#   DO_PG_OPERATOR=false ./2.3_full_step_2.3_provision_datastores.sh
# PostgreSQL also runs for an *existing* server (the init Job creates the
# databases, roles and pgvector there).
# ==============================================================================

DO_PG_OPERATOR="${DO_PG_OPERATOR:-true}"           # 2.3.1 CloudNativePG operator
DO_POSTGRES="${DO_POSTGRES:-true}"                 # 2.3.2 Postgres cluster + databases
DO_OBJECT_GATEWAY="${DO_OBJECT_GATEWAY:-true}"     # 2.3.3 Multicloud Object Gateway
DO_BUCKETS="${DO_BUCKETS:-true}"                   # 2.3.4 bucket claims
DO_MYSQL="${DO_MYSQL:-true}"                       # 2.3.5 MySQL (Workflows)
DO_REDIS="${DO_REDIS:-true}"                       # 2.3.6 Redis (Data Apps)
DO_NEO4J="${DO_NEO4J:-true}"                       # 2.3.7 Neo4j (VEIAS graph)

h_run_step "${DO_PG_OPERATOR}"    "2.3.1 CloudNativePG operator"        "${SCRIPT_DIR}/2.3.1_install_cloudnative_pg_operator.sh"
h_run_step "${DO_POSTGRES}"       "2.3.2 PostgreSQL cluster + databases" "${SCRIPT_DIR}/2.3.2_provision_postgres.sh"
h_run_step "${DO_OBJECT_GATEWAY}" "2.3.3 Multicloud Object Gateway"     "${SCRIPT_DIR}/2.3.3_install_object_gateway.sh"
h_run_step "${DO_BUCKETS}"        "2.3.4 S3 bucket claims"              "${SCRIPT_DIR}/2.3.4_provision_buckets.sh"
h_run_step "${DO_MYSQL}"          "2.3.5 MySQL for Workflows"           "${SCRIPT_DIR}/2.3.5_provision_mysql.sh"
h_run_step "${DO_REDIS}"          "2.3.6 Redis for Data Apps"           "${SCRIPT_DIR}/2.3.6_provision_redis.sh"
h_run_step "${DO_NEO4J}"          "2.3.7 Neo4j for the Concert graph"   "${SCRIPT_DIR}/2.3.7_provision_neo4j.sh"
