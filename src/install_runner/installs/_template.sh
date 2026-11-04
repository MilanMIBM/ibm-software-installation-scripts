#!/bin/zsh
# =============================================================================
# In-cluster install runner: install hooks - TEMPLATE (copy to <id>.sh)
# -----------------------------------------------------------------------------
# Called from the workstation with the install's config loaded:
#
#   <id>.sh preflight      extra checks; print why and exit non-zero to refuse
#   <id>.sh post-collect   local follow-up once results are back
#
# Every verb is optional. An unknown verb must exit 0, so new verbs can be added
# to the core without touching every install.
# =============================================================================
set -euo pipefail
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

case "${1:-}" in
    preflight)    ;;
    post-collect) ;;
esac
