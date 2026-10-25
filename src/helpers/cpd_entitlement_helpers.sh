#!/bin/zsh
# =============================================================================
# cpd_entitlement_helpers.sh - cluster-side preparation for cpd-cli apply-entitlement
# -----------------------------------------------------------------------------
# How scripts use it (after the env_bootstrap line, once oc is logged in):
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/cpd_entitlement_helpers.sh"
#     cpdent_ensure_service_meter_addon_labels "${PROJECT_CPD_INST_OPERANDS}"
#
# Sections:
#   - IBMServiceMeterDefinition addOnId labels
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _CPDENT_HELPERS_LOADED.
#   - Every function assumes `oc` is already logged in by the caller.
# =============================================================================

[[ -n "${_CPDENT_HELPERS_LOADED:-}" ]] && return 0
_CPDENT_HELPERS_LOADED=1

source "${${(%):-%x}:A:h}/common_helpers.sh"

# =============================================================================
# IBMServiceMeterDefinition addOnId labels
# =============================================================================
# apply_entitlement.py (entitlement_utils.delete_service_meter_yaml) reads
# metadata.labels["icpdsupport/addOnId"] on every IBMServiceMeterDefinition in
# the instance namespace without checking it exists, so one unlabeled CR (e.g.
# watsonx-ai-runtime-inference from the watsonxaiifm operator) aborts the whole
# run with KeyError 'icpdsupport/addOnId'.

# Kinds searched for sibling resources that already carry the addOnId label.
CPDENT_ADDON_LOOKUP_KINDS="deployments,statefulsets,configmaps,services,jobs"

# Most frequent non-empty line on stdin, or nothing.
_cpdent_most_common() { grep -v '^$' | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}'; }

# cpdent_ensure_service_meter_addon_labels <namespace>
# Labels every IBMServiceMeterDefinition in <namespace> that lacks
# icpdsupport/addOnId. The value is derived from the cluster: the addOnId most
# commonly carried by resources sharing the CR's icpdsupport/module label, else
# by resources with the same owner. If neither yields one, a non-matching
# placeholder (unmapped-<module or owner kind>) is applied so the lookup no
# longer crashes; apply-entitlement then leaves that CR alone.
# Call it before each apply-entitlement: that command may delete a matching CR,
# and the owning operator recreates it without the label.
cpdent_ensure_service_meter_addon_labels() {
    local ns="$1" rows name addon module owner_uid owner_kind target source
    rows=$(oc get ibmservicemeterdefinitions -n "${ns}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.icpdsupport/addOnId}{"|"}{.metadata.labels.icpdsupport/module}{"|"}{.metadata.ownerReferences[0].uid}{"|"}{.metadata.ownerReferences[0].kind}{"\n"}{end}' \
        2>/dev/null) || return 0
    # '|' rather than a tab: zsh collapses runs of whitespace IFS characters,
    # which would swallow the empty addOnId field.
    while IFS='|' read -r name addon module owner_uid owner_kind; do
        [[ -z "${name}" || -n "${addon}" ]] && continue
        target="" source=""
        if [[ -n "${module}" ]]; then
            target=$(oc get "${CPDENT_ADDON_LOOKUP_KINDS}" -n "${ns}" -l "icpdsupport/module=${module},icpdsupport/addOnId" \
                -o jsonpath='{range .items[*]}{.metadata.labels.icpdsupport/addOnId}{"\n"}{end}' 2>/dev/null | _cpdent_most_common)
            source="resources labeled icpdsupport/module=${module}"
        fi
        if [[ -z "${target}" && -n "${owner_uid}" ]]; then
            target=$(oc get "${CPDENT_ADDON_LOOKUP_KINDS}" -n "${ns}" -l "icpdsupport/addOnId" \
                -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].uid}{"|"}{.metadata.labels.icpdsupport/addOnId}{"\n"}{end}' 2>/dev/null \
                | awk -F'|' -v uid="${owner_uid}" '$1 == uid {print $2}' | _cpdent_most_common)
            source="resources owned by ${owner_kind} ${owner_uid}"
        fi
        if [[ -z "${target}" ]]; then
            target="unmapped-${module:-${owner_kind:l}}"
            h_warn "Could not derive an addOnId for IBMServiceMeterDefinition ${name}; using placeholder '${target}'."
        else
            h_info "IBMServiceMeterDefinition ${name} has no icpdsupport/addOnId label; derived '${target}' from ${source}."
        fi
        oc label ibmservicemeterdefinition "${name}" -n "${ns}" "icpdsupport/addOnId=${target}" --overwrite
    done <<< "${rows}"
}
