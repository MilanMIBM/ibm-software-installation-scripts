#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ------------------------------------------------------------------------------
# Bump the spec.version of every component CR that "Needs Service Upgrade".
#
# Why this script (and not `cpd-cli manage update-cr --patch='{"version":...}'`):
# update-cr sends a *minimal* patch to the API server, which then re-validates
# the whole CR. Some CRDs (e.g. WSPipelines) have gained newly-required spec
# fields between releases (spec.license.license). Older CRs created before that
# field existed only carry {license:{accept:true}}, so the minimal patch is
# rejected with:
#     spec.license: Required value   (HTTP 422)
#
# Instead we:
#   1. Ask `cpd-cli manage get-cr-status` which components are out of date and
#      learn each CR's kind / name / namespace / expected version.
#   2. Fetch the *full existing* CR spec with `oc`.
#   3. Set .spec.version to the expected version, leaving every other field
#      (including required ones) intact.
#   4. Re-apply the full spec with a server-side `oc patch --type=merge`.
#
# Because the full, already-valid spec is sent back, no required field can be
# dropped, so the 422 never happens.
#
# IMPORTANT (per IBM docs): update-cr / a manual version bump only edits the CR
# spec. The operator then performs the actual service upgrade by reconciling.
# Only run this when you have been instructed to upgrade.
# ------------------------------------------------------------------------------

for var in PROJECT_CPD_INST_OPERANDS; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

command -v oc >/dev/null 2>&1 || { echo "Error: 'oc' CLI not found on PATH."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: 'jq' is required to merge CR specs but was not found on PATH."; exit 1; }

# Authenticate the cpd-cli container's OpenShift context (used by get-cr-status)
# and ensure the local `oc` is logged in for the patch step.
eval "${CPDM_OC_LOGIN}"

# DRY_RUN=true  -> show the diff that would be applied, but do not patch.
DRY_RUN="${DRY_RUN:-false}"

# Namespaces to inspect. The instance namespace holds most component CRs; the
# cluster component namespace (if set) holds cluster-wide ones.
NS_FLAGS=(--cpd_instance_ns="${PROJECT_CPD_INST_OPERANDS}")
if [[ -n "${PROJECT_CPD_INST_OPERATORS:-}" ]]; then
    NS_FLAGS+=(--cluster_component_ns="${PROJECT_CPD_INST_OPERATORS}")
fi

# ------------------------------------------------------------------------------
# 1. Discover components that need an upgrade.
#
# We request a fixed column order via --filter so the table is parseable. Each
# data row is: cr_kind  cr_name  namespace  expected_version  reconciled_version
# Rows where expected != reconciled (and both look like versions) need a bump.
# ------------------------------------------------------------------------------
echo "==> Querying CR status..."
FILTER="cr_kind,cr_name,namespace,expected_version,reconciled_version"
status_out="$(cpd-cli manage get-cr-status "${NS_FLAGS[@]}" --filter="${FILTER}" 2>/dev/null)" || {
    echo "Error: get-cr-status failed. Check that login-to-ocp succeeded."
    exit 1
}

# Keep only rows that have all five fields, where the last two columns look like
# versions (digits/dots, optionally with a build suffix) and differ.
typeset -a TO_UPGRADE
while IFS= read -r line; do
    # Collapse whitespace and split into fields.
    set -- ${(z)line}
    (( $# >= 5 )) || continue
    local kind="$1" name="$2" ns="$3" expected="$4" reconciled="$5"
    # Skip the header / non-version rows.
    [[ "${expected}"   == <->.* || "${expected}"   == <-> ]] || continue
    [[ "${reconciled}" == <->.* || "${reconciled}" == <-> ]] || continue
    [[ "${expected}" != "${reconciled}" ]] || continue
    TO_UPGRADE+=("${kind}|${name}|${ns}|${expected}|${reconciled}")
done <<< "${status_out}"

if (( ${#TO_UPGRADE[@]} == 0 )); then
    echo "All component CRs are already at their expected version. Nothing to do."
    exit 0
fi

echo ""
echo "The following component CRs will have spec.version bumped:"
printf '  %-28s %-30s %-18s %s\n' "KIND" "NAME" "NAMESPACE" "CHANGE"
for entry in "${TO_UPGRADE[@]}"; do
    IFS='|' read -r kind name ns expected reconciled <<< "${entry}"
    printf '  %-28s %-30s %-18s %s -> %s\n' "${kind}" "${name}" "${ns}" "${reconciled}" "${expected}"
done
echo ""

# ------------------------------------------------------------------------------
# 2-4. For each CR: fetch full spec, set spec.version, re-apply full spec.
# ------------------------------------------------------------------------------
failures=0
for entry in "${TO_UPGRADE[@]}"; do
    IFS='|' read -r kind name ns expected reconciled <<< "${entry}"
    echo "==> ${kind}/${name} (${ns}): ${reconciled} -> ${expected}"

    # Fetch the existing spec (full, already-valid object).
    if ! current_spec="$(oc get "${kind}" "${name}" -n "${ns}" -o jsonpath='{.spec}' 2>/dev/null)" \
        || [[ -z "${current_spec}" ]]; then
        echo "    [SKIP] could not read .spec for ${kind}/${name} in ${ns}"
        (( failures++ ))
        continue
    fi

    # Build the new full spec with only .version changed. Sending the entire
    # spec back guarantees no newly-required field (e.g. license.license) is
    # lost during server-side re-validation.
    new_spec="$(jq -c --arg v "${expected}" '.version = $v' <<< "${current_spec}")" || {
        echo "    [SKIP] failed to construct patched spec"
        (( failures++ ))
        continue
    }
    merge_patch="$(jq -c -n --argjson spec "${new_spec}" '{spec: $spec}')"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "    [DRY_RUN] would apply merge patch:"
        echo "${merge_patch}" | jq .
        continue
    fi

    if oc patch "${kind}" "${name}" -n "${ns}" --type=merge -p "${merge_patch}"; then
        echo "    [OK] spec.version set to ${expected}"
    else
        echo "    [FAIL] patch rejected for ${kind}/${name}"
        (( failures++ ))
    fi
done

echo ""
if (( failures > 0 )); then
    echo "Completed with ${failures} failure(s). Review the output above."
    exit 1
fi
echo "All targeted CRs patched. The operators will now reconcile to the new versions."
