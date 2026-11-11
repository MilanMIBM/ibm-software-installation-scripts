#!/bin/bash
# =============================================================================
# finalize-stage.sh <run id> - make a staged snapshot the slot's current run
# -----------------------------------------------------------------------------
# Called once the workstation has finished every stream (the code, one per
# config root, the extras) and written run.env and path_map. baseline.sha256
# records the snapshot's files, so collect can tell what the chain changed.
# The state file comes last: it is what the supervisor waits for.
# =============================================================================
set -euo pipefail
work="${IR_WORK:-/work}"
id="${1:?run id}"
run="${work}/runs/${id}"
snapshot="${work}/snapshots/${id}"
[[ -f "${run}/run.env" && -d "${snapshot}" ]] || { echo "[ERROR] Run ${id} is not staged." >&2; exit 1; }

( cd "${snapshot}" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) > "${run}/baseline.sha256"
ln -sfn "${run}" "${work}/current.new"
mv -Tf "${work}/current.new" "${work}/current"
echo staged > "${run}/state.new"
mv -f "${run}/state.new" "${run}/state"
