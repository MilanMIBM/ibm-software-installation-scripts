#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# x_watch_install.sh - tap into an install running in cluster, as if it ran here.
# Read-only: Ctrl-C only stops watching. Same options as x_install_runner.sh attach.
# Watching needs no local olm-utils container and no lease (x_install_runner.sh sets
# the same; set here too, so the intent sits with the watcher).
export MCM_SYNC_MODE=stop-only
exec "${0:A:h}/x_install_runner.sh" attach "$@"
