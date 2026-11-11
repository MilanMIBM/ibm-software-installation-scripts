#!/bin/zsh
# =============================================================================
# In-cluster install runner: install hooks - TEMPLATE (copy to <id>.sh)
# -----------------------------------------------------------------------------
# Called from the workstation with the install's config loaded:
#
#   <id>.sh preflight      extra checks; print why and exit non-zero to refuse.
#                          IR_STAGED_<LOCAL_VAR> holds the folder each
#                          RUNNER_STAGE_ROOTS entry stages: check that one
#   <id>.sh stage          extra files for the snapshot, beyond RUNNER_STAGE_ROOTS:
#                          one "<source>\t<snapshot path>" line each on stdout
#                          (source absolute or repo-relative, a file or a folder);
#                          anything else this verb says goes to stderr. Login
#                          folders, cluster markers, the multi-cluster state file
#                          and whole cluster folders are refused
#   <id>.sh post-collect   local follow-up once results are back
#
# Every verb is optional. An unknown verb must exit 0, so new verbs can be added
# to the core without touching every install.
# =============================================================================
set -euo pipefail
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

case "${1:-}" in
    preflight)    ;;
    stage)        ;;
    post-collect) ;;
esac
