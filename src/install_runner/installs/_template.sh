#!/bin/zsh
# =============================================================================
# In-cluster install runner: install hooks - TEMPLATE (copy to <id>.sh)
# -----------------------------------------------------------------------------
# Called from the workstation with the install's config loaded:
#
#   <id>.sh preflight [chain]
#                          extra checks; print why and exit non-zero to refuse.
#                          IR_STAGED_<LOCAL_VAR> holds the folder each
#                          RUNNER_STAGE_ROOTS entry stages: check that one.
#                          IR_HOOK_CHAIN is the chain (empty for
#                          x_install_runner.sh preflight), IR_HOOK_ARGS its
#                          arguments, one per line (sidecars gets both too)
#   <id>.sh sidecars [chain]
#                          a sidecar the slot pod needs for this chain: one
#                          "<name><TAB>..." line on stdout, nothing for none.
#                          The runner knows "swhcc<TAB><premium olm-utils image
#                          by tag><TAB><same|different>" (Control Center, see
#                          cpd.sh and manifests/swhcc-sidecar.fragments.tmpl).
#                          A pod without a sidecar renders as it always has
#   <id>.sh runner-inputs [chain]
#                          for a chain whose config lacks what the runner pod
#                          itself needs: "base_image=<olm-utils image>" (when
#                          RUNNER_BASE_IMAGE_VAR is empty) and/or
#                          "storage_class=default" (the cluster's default
#                          storage class, when RUNNER_STORAGE_CLASS_VAR is
#                          empty). Print nothing to keep them required
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
    runner-inputs) ;;
    sidecars)     ;;
    stage)        ;;
    post-collect) ;;
esac
