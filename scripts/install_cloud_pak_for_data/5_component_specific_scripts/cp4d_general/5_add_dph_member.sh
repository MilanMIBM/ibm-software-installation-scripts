#!/bin/zsh
# Add existing Software Hub users or groups to the initialized DPH community.
#
# Environment: env_bootstrap.sh loads the selected cluster's CPD configuration,
# including cpd_instance_details.sh. No manual sourcing is required. Standard
# --target-cluster / --env-target options are handled by the shared bootstrap.
#
# Authentication: CPD_URL + CPD_USERNAME + CPD_APIKEY, with CPD_PASSWORD as a
# fallback, through /icp4d-api/v1/authorize and the shared SoftwareHub helper.
# The authenticating account needs administrator access to the hub catalog.
# This uses the Software Hub HTTP API; no oc login or cpd-cli profile is needed.
#
# Access: --role admin = community administrator, editor = producer,
# viewer = consumer. Members also need the corresponding DPH platform role,
# assigned separately in Access control. This script adds community membership
# only: existing roles, users, groups and group membership are preserved.
# Missing users/groups are errors; groups must be created in Access control.
#
# Usage (from this directory):
#   ./5_add_dph_member.sh --user person@example.com --role viewer
#   ./5_add_dph_member.sh --user first@example.com --user second@example.com --role editor
#   ./5_add_dph_member.sh --group "DPH Consumers" --role viewer --dry-run
#   ./5_add_dph_member.sh --group "DPH Consumers" --role viewer
#
# --user and --group are mutually exclusive; either may be repeated. A single
# explicit --role applies to all requested additions. Existing members keep
# their role, even when a different role is requested. --dry-run authenticates
# and reads identities/catalog membership but makes no membership changes.
# See docs/data-product-hub.md for the complete access setup and limitations.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
_b="${SCRIPT_DIR}"
while [[ "${_b}" != / && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="${_b:h}"; done
if [[ ! -f "${_b}/env_bootstrap.sh" ]]; then
    echo "[ERROR] Cannot locate env_bootstrap.sh from ${SCRIPT_DIR}" >&2
    exit 1
fi
source "${_b}/env_bootstrap.sh"
unset _b

python3 "${_CP4D_REPO_ROOT}/src/helpers/dph_membership.py" "$@"
