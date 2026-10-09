#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
# configs/cp4d_config/cpd_vars.sh sets its own SCRIPT_DIR, so keep this script's folder separately.
HERE="${0:A:h}"

# =============================================================================
# 5_add_softwarehub_admins_to_project.sh
# -----------------------------------------------------------------------------
# Adds every Software Hub administrator to an existing project. An administrator
# is an enabled user with zen_administrator_role, given directly or through a
# Software Hub user group. Members are added by 5_create_cpd_project.sh
# (--no-create), so someone already in the project keeps their current role.
#
# People only exist in Software Hub once they have signed in (or were added,
# e.g. by grant_softwarehub_admin_to_ocp_admins.sh), so re-run this after new
# admins have signed in. Safe to re-run.
#
#   - Auth : CPD_URL + CPD_USERNAME + CPD_APIKEY (cpd_instance_details.sh). That
#            user must be an admin of the project.
#
# Usage:
#   ./5_add_softwarehub_admins_to_project.sh <project_name> [--role admin|editor|viewer]
#                                            [--exclude <user>]... [--dry-run]
#   --dry-run   only list who would be added
# =============================================================================

PROJECT_NAME=""
ROLE="admin"
EXCLUDE=()
DRY_RUN=false
ADMIN_ROLE_ID="zen_administrator_role"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)    ROLE="$2"; shift 2 ;;
    --exclude) EXCLUDE+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "[WARN] unknown argument: $1" >&2; shift ;;
    *)  PROJECT_NAME="$1"; shift ;;
  esac
done

if [[ -z "${PROJECT_NAME}" ]]; then
  echo "Usage: $(basename $0) <project_name> [--role admin|editor|viewer] [--exclude <user>]... [--dry-run]" >&2
  exit 1
fi
for var in CPD_URL CPD_USERNAME CPD_APIKEY; do
  if [[ -z "${(P)var:-}" ]]; then
    echo "[ERROR] ${var} is not set. Check configs/cp4d_config/cpd_instance_details.sh." >&2
    exit 1
  fi
done
CPD_BASE="${CPD_URL%/}"

echo "[INFO] Authenticating to ${CPD_BASE} as ${CPD_USERNAME}..."
TOKEN="$(curl -sk -X POST "${CPD_BASE}/icp4d-api/v1/authorize" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import sys,json; print(json.dumps({"username": sys.argv[1], "api_key": sys.argv[2]}))' "${CPD_USERNAME}" "${CPD_APIKEY}")" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] Failed to get a bearer token from ${CPD_BASE}/icp4d-api/v1/authorize." >&2
  exit 1
fi

# Collects the users, the groups with the admin role and those groups' members,
# paging through each list, and prints the admins' usernames.
ADMINS=("${(@f)$(CPD_BASE="${CPD_BASE}" TOKEN="${TOKEN}" python3 - "${ADMIN_ROLE_ID}" <<'PY'
import json, os, ssl, sys, urllib.request

base, token, role = os.environ["CPD_BASE"], os.environ["TOKEN"], sys.argv[1]
ctx = ssl._create_unverified_context()   # same as curl -k in the other scripts

def get(path):
    req = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
        return json.load(r)

def pages(path, key=None, size=100):
    offset = 0
    while True:
        d = get(f"{path}{'&' if '?' in path else '?'}offset={offset}&limit={size}")
        rows = d if isinstance(d, list) else d.get(key, [])
        yield from rows
        if len(rows) < size:
            return
        offset += size

users = {str(u["uid"]): u for u in pages("/usermgmt/v2/usermgmt/users")}
admin_uids = {uid for uid, u in users.items() if role in (u.get("user_roles") or [])}
for g in pages("/usermgmt/v4/groups", "results"):
    if any(r.get("role_id") == role for r in g.get("roles", [])):
        admin_uids |= {str(m["uid"]) for m in pages(f"/usermgmt/v4/groups/{g['group_id']}/members", "results")}

for uid in sorted(admin_uids):
    u = users.get(uid)
    if u and u.get("current_account_status", "enabled") == "enabled":
        print(u["username"])
PY
)}")
ADMINS=(${ADMINS:#})
for _x in "${EXCLUDE[@]}"; do ADMINS=(${ADMINS:#${_x}}); done
unset _x

if (( ${#ADMINS} == 0 )); then
  echo "[INFO] No Software Hub administrators found."
  exit 0
fi
echo "[INFO] Software Hub administrators (${#ADMINS}): ${ADMINS[*]}"

if [[ "${DRY_RUN}" == true ]]; then
  echo "[INFO] Dry run: would add them to '${PROJECT_NAME}' as ${ROLE} (existing members keep their role)."
  exit 0
fi

_members=()
for _a in "${ADMINS[@]}"; do _members+=(--member "${_a}:${ROLE}"); done
"${HERE}/5_create_cpd_project.sh" "${PROJECT_NAME}" --no-create "${_members[@]}"
