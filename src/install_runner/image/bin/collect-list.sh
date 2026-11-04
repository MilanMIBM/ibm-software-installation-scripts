#!/bin/bash
# =============================================================================
# collect-list.sh <path>... - what a run changed under the given snapshot paths
# -----------------------------------------------------------------------------
# Prints "<baseline sha256 or ->\t<current sha256>\t<path>" for every new or
# changed file. The workstation uses the baseline to spot local edits it must
# not overwrite.
# =============================================================================
set -euo pipefail
work="${IR_WORK:-/work}"
run="$(readlink -f "${work}/current")"
snapshot="${work}/snapshots/$(basename "${run}")"
cd "${snapshot}"

declare -A base=()
while read -r hash path; do base["${path}"]="${hash}"; done < "${run}/baseline.sha256"

for root in "$@"; do
    [[ -e "${root}" ]] || continue
    while IFS= read -r -d '' file; do
        hash="$(sha256sum "${file}" | awk '{print $1}')"
        old="${base[${file}]:--}"
        [[ "${hash}" == "${old}" ]] || printf '%s\t%s\t%s\n' "${old}" "${hash}" "${file#./}"
    done < <(find "./${root}" -type f -print0)
done
