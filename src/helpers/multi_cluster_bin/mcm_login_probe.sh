#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# =============================================================================
# mcm_login_probe.sh - podman exec for the login check in CPDM_OC_LOGIN
# -----------------------------------------------------------------------------
# Runs "podman exec CONTAINER COMMAND..." and logs it as one of this feature's own
# exec calls, so the idle watcher does not count a login check as use of the
# container (plan 5.7.1). Runs pinned to a cluster only; source_env_setup.sh puts it
# in the wrapped CPDM_OC_LOGIN.
#
# Usage:
#   zsh mcm_login_probe.sh CONTAINER COMMAND [ARGS...]
#   zsh mcm_login_probe.sh --help
# =============================================================================

set -uo pipefail

case "${1:-}" in
    -h|--help)
        sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "")
        print -r -- "[ERROR] Missing container name (see --help)" >&2
        exit 1
        ;;
esac

podman exec "$@"
_rc=$?
# 125: podman could not start the exec, so no event exists to take out of the count.
if (( _rc != 125 )); then
    source "${0:A:h:h}/multi_cluster_helpers.sh" && _mcm_note_own_scan "$1"
fi
exit "${_rc}"
