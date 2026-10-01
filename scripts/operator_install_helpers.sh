#!/bin/zsh
# =============================================================================
# operator_install_helpers.sh - idempotency primitives for OLM operator installs
# -----------------------------------------------------------------------------
# Purpose:
#   Every operator install script in this repo must be safe to re-run against a
#   cluster that already has the operator. These helpers provide the three
#   checks that make that true, so each script does not re-implement them (and
#   re-implement them subtly wrong).
#
# How scripts use it (after the env_bootstrap line, before any oc call):
#
#     source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"
#
#   env_bootstrap.sh exports _CP4D_REPO_ROOT for exactly this purpose.
#
# Notes:
#   - Must be SOURCED, not executed.
#   - Safe to source multiple times (guarded via _CP4D_OPERATOR_HELPERS_LOADED).
#   - Every function assumes `oc` is already logged in by the caller.
# =============================================================================

[[ -n "${_CP4D_OPERATOR_HELPERS_LOADED:-}" ]] && return 0
_CP4D_OPERATOR_HELPERS_LOADED=1

# -----------------------------------------------------------------------------
# cp4d_csv_phase <namespace> <csv-name-prefix>
# -----------------------------------------------------------------------------
# Echo the phase (Succeeded / Installing / Failed / ...) of the CSV whose name
# starts with <csv-name-prefix>, or nothing if no such CSV exists.
#
# The prefix match matters. A namespace routinely holds CSVs for operators other
# than the one being installed - OpenShift installs DevWorkspace, External
# Secrets, Pipelines and Web Terminal into shared namespaces, and they report
# Succeeded independently. An unscoped `oc get csv | grep -q Succeeded` therefore
# reports "already installed" even when the operator we care about has failed or
# was never installed at all, and the script then skips a real install.
# The prefix is an extended-regex fragment, so a caller that needs a literal dot
# (to tell "servicemeshoperator." from "servicemeshoperator3.") passes "\.".
# It is handed to awk through the environment rather than through `awk -v`,
# because -v runs escape processing over the value a second time: "\." arrives
# at the regex engine as a bare ".", which matches any character and silently
# turns a literal-dot anchor back into a wildcard.
cp4d_csv_phase() {
    local namespace="$1" csv_prefix="$2"
    oc get csv -n "${namespace}" --no-headers 2>/dev/null \
        | CP4D_CSV_PREFIX="${csv_prefix}" awk '$1 ~ ("^" ENVIRON["CP4D_CSV_PREFIX"]) {print $NF; exit}' || true
}

# -----------------------------------------------------------------------------
# cp4d_ensure_operatorgroup <namespace> <name> [target-namespace ...]
# -----------------------------------------------------------------------------
# Create an OperatorGroup in <namespace> only if that namespace has none.
#
# OLM fails every CSV in a namespace that holds more than one OperatorGroup
# (TooManyOperatorGroups), and it will not resolve itself - the operator simply
# never installs until a human deletes the extra group. A pre-existing group is
# frequently under a different name than the one a script would apply (the
# namespace-default group, or one an earlier OpenShift version created), so a
# blind `oc apply` of a named group ADDS a second group rather than updating the
# first. That is the single most common way these scripts used to break a re-run,
# so the existence check is on the namespace, never on the name.
#
# With no target namespaces, an own-namespace group is created (spec omitted,
# which OLM treats as watching its own namespace).
cp4d_ensure_operatorgroup() {
    local namespace="$1" og_name="$2"
    shift 2
    local targets=("$@")

    local existing
    existing=$(oc get operatorgroup -n "${namespace}" -o name 2>/dev/null | head -1 || true)
    if [[ -n "${existing}" ]]; then
        echo "[INFO] OperatorGroup ${existing#*/} already present in ${namespace}, leaving it as-is."
        return 0
    fi

    {
        echo "apiVersion: operators.coreos.com/v1"
        echo "kind: OperatorGroup"
        echo "metadata:"
        echo "  name: ${og_name}"
        echo "  namespace: ${namespace}"
        if (( ${#targets[@]} > 0 )); then
            echo "spec:"
            echo "  targetNamespaces:"
            local t
            for t in "${targets[@]}"; do
                echo "  - ${t}"
            done
        fi
    } | oc apply -f -
}

# -----------------------------------------------------------------------------
# cp4d_ensure_namespace <namespace> [label=value ...]
# -----------------------------------------------------------------------------
# Create the namespace if absent. Labels are applied on creation only; an
# existing namespace is left untouched, since it may carry deliberate local
# changes (quotas, monitoring opt-outs, node selectors) that this script has no
# business overwriting on a re-run.
cp4d_ensure_namespace() {
    local namespace="$1"
    shift
    local labels=("$@")

    if oc get namespace "${namespace}" >/dev/null 2>&1; then
        echo "[INFO] Namespace ${namespace} already exists, leaving it as-is."
        return 0
    fi

    {
        echo "apiVersion: v1"
        echo "kind: Namespace"
        echo "metadata:"
        echo "  name: ${namespace}"
        if (( ${#labels[@]} > 0 )); then
            echo "  labels:"
            local l
            for l in "${labels[@]}"; do
                echo "    ${l%%=*}: \"${l#*=}\""
            done
        fi
    } | oc apply -f -
}

# -----------------------------------------------------------------------------
# cp4d_reconcile_subscription_channel <namespace> <subscription> <target-channel>
# -----------------------------------------------------------------------------
# Compare the live Subscription's channel to the target and reconcile it.
#
# Echoes one of:
#   match    - already on the target channel, nothing to do
#   absent   - no such Subscription, the caller should create it
#   patched  - channel differed and was patched; OLM will roll the upgrade
#
# Returns non-zero (and echoes "incompatible") when the channels are not in the
# same family and major version - e.g. stable -> fast, or 2.x -> 3.x. Those are
# not in-place upgrades OLM can roll unattended, so the caller must stop rather
# than silently migrate a working operator across a major version.
cp4d_reconcile_subscription_channel() {
    local namespace="$1" subscription="$2" target_channel="$3"

    local current
    current=$(oc get subscription "${subscription}" -n "${namespace}" \
        -o jsonpath='{.spec.channel}' 2>/dev/null || true)

    if [[ -z "${current}" ]]; then
        echo "absent"
        return 0
    fi

    if [[ "${current}" == "${target_channel}" ]]; then
        echo "match"
        return 0
    fi

    local current_family="${current%%-*}" target_family="${target_channel%%-*}"
    local current_major="${${current#*-}%%.*}" target_major="${${target_channel#*-}%%.*}"

    if [[ "${current_family}" != "${target_family}" || "${current_major}" != "${target_major}" ]]; then
        echo "incompatible"
        return 1
    fi

    oc patch subscription "${subscription}" -n "${namespace}" \
        --type=merge -p "{\"spec\":{\"channel\":\"${target_channel}\"}}" >/dev/null
    echo "patched"
    return 0
}

# -----------------------------------------------------------------------------
# cp4d_wait_for_csv <namespace> <csv-name-prefix> <timeout-seconds>
# -----------------------------------------------------------------------------
# Poll until the matching CSV reaches Succeeded. Fails fast on a Failed phase
# rather than burning the whole timeout on a CSV that will never recover.
cp4d_wait_for_csv() {
    local namespace="$1" csv_prefix="$2" timeout="$3"
    local elapsed=0 interval=10 phase

    while true; do
        phase="$(cp4d_csv_phase "${namespace}" "${csv_prefix}")"
        [[ "${phase}" == "Succeeded" ]] && return 0

        if [[ "${phase}" == "Failed" ]]; then
            echo "[ERROR] CSV ${csv_prefix}* in ${namespace} entered phase Failed." >&2
            oc get csv -n "${namespace}" --no-headers 2>/dev/null \
                | CP4D_CSV_PREFIX="${csv_prefix}" awk '$1 ~ ("^" ENVIRON["CP4D_CSV_PREFIX"])' >&2 || true
            return 1
        fi

        if (( elapsed >= timeout )); then
            echo "[ERROR] CSV ${csv_prefix}* in ${namespace} did not reach Succeeded after ${timeout}s (phase: ${phase:-pending})." >&2
            oc get subscription,installplan,csv -n "${namespace}" >&2 || true
            return 1
        fi

        sleep "${interval}"
        (( elapsed += interval ))
        echo "  [${elapsed}s] CSV ${csv_prefix}*: ${phase:-pending}"
    done
}
