#!/bin/zsh
# Segment 0 hook: shared (contract: _template.sh). Nothing to select or prefill -
# shared content comes from the installs' declarations and MIRROR_SHARED_*.
set -euo pipefail
case "${1:-}" in
    components|prefill) exit 0 ;;
    *) print -r -- "usage: $0 components|prefill" >&2; exit 1 ;;
esac

exit 0
