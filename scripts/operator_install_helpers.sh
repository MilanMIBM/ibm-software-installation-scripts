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

autoload -Uz is-at-least

# -----------------------------------------------------------------------------
# cp4d_default_service_mesh_version
# -----------------------------------------------------------------------------
# Echo the Red Hat OpenShift Service Mesh major version (2 or 3) to install for
# the CP4D release in ${VERSION}: 3 from 5.4.0 onwards, 2 for earlier releases.
# Callers let an explicit SERVICE_MESH_VERSION override this, e.g.
#
#     SERVICE_MESH_VERSION="${SERVICE_MESH_VERSION:-$(cp4d_default_service_mesh_version)}"
#
# An unset VERSION falls back to 3 (the current default) with a warning on stderr.
cp4d_default_service_mesh_version() {
    if [[ -z "${VERSION:-}" ]]; then
        echo "[WARN] VERSION is not set; defaulting to Service Mesh 3." >&2
        echo "3"
    elif is-at-least 5.4.0 "${VERSION}"; then
        echo "3"
    else
        echo "2"
    fi
}

# -----------------------------------------------------------------------------
# cp4d_pkg_channel [--strict] <package> [preferred]
# -----------------------------------------------------------------------------
# Echo the Subscription channel for an OLM package, read from its PackageManifest
# in openshift-marketplace: <preferred> when the catalog offers it, else the
# catalog's default channel (with a warning when <preferred> was given). With
# --strict, a <preferred> the catalog does not offer fails instead, for pins
# where the default would be a major jump (RHOAI). Fails, printing nothing on
# stdout, when the PackageManifest cannot be read; callers then fall back to
# their literal (vr_operator_channel in src/helpers/version_resolver.sh).
cp4d_pkg_channel() {
    local strict=false
    [[ "${1:-}" == --strict ]] && { strict=true; shift; }
    local pkg="$1" preferred="${2:-}" raw default
    local -a channels
    raw="$(oc get packagemanifest "${pkg}" -n openshift-marketplace \
        -o jsonpath='{.status.defaultChannel}{" "}{.status.channels[*].name}' 2>/dev/null || true)"
    channels=(${=raw})
    default="${channels[1]:-}"
    channels=("${(@)channels[2,-1]}")
    [[ -n "${default}" ]] && (( ${#channels} )) || return 1
    if [[ -n "${preferred}" ]]; then
        if (( ${channels[(Ie)${preferred}]} )); then
            echo "[INFO] ${pkg}: channel ${preferred} (offered by the catalog)" >&2
            print -r -- "${preferred}"
            return 0
        fi
        if ${strict}; then
            echo "[WARN] ${pkg}: the catalog does not offer channel ${preferred} (it has: ${channels[*]})" >&2
            return 1
        fi
        echo "[WARN] ${pkg}: the catalog does not offer channel ${preferred}; using its default ${default}" >&2
    else
        echo "[INFO] ${pkg}: channel ${default} (the catalog's default)" >&2
    fi
    print -r -- "${default}"
}

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
    oc get clusterserviceversions.operators.coreos.com -n "${namespace}" --no-headers 2>/dev/null \
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
    existing=$(oc get operatorgroups.operators.coreos.com -n "${namespace}" -o name 2>/dev/null | head -1 || true)
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
    current=$(oc get subscriptions.operators.coreos.com "${subscription}" -n "${namespace}" \
        -o jsonpath='{.spec.channel}' 2>/dev/null || true)

    if [[ -z "${current}" ]]; then
        echo "absent"
        return 0
    fi

    if [[ "${current}" == "${target_channel}" ]]; then
        echo "match"
        return 0
    fi

    # Split "<family>-<version>" on the LAST dash so multi-dash families
    # (support-required-upgrade-3.5) parse correctly. A channel with no dash is
    # either a bare version (GPU Operator's "v26.3": empty family) or a bare
    # family ("stable": no version) - treating "v26.3" as a family made every
    # GPU minor bump (v26.3 -> v26.7) look like a cross-family migration.
    local current_family current_major target_family target_major
    _cp4d_split_channel() {
        local ch="$1" ver
        if [[ "${ch}" == *-* ]]; then
            REPLY_FAMILY="${ch%-*}"; ver="${ch##*-}"
        elif [[ "${ch}" == (v|)[0-9]* ]]; then
            REPLY_FAMILY=""; ver="${ch}"
        else
            REPLY_FAMILY="${ch}"; ver=""
        fi
        REPLY_MAJOR="${ver%%.*}"
    }
    _cp4d_split_channel "${current}"
    current_family="${REPLY_FAMILY}" current_major="${REPLY_MAJOR}"
    _cp4d_split_channel "${target_channel}"
    target_family="${REPLY_FAMILY}" target_major="${REPLY_MAJOR}"
    unset REPLY_FAMILY REPLY_MAJOR

    # A family/major mismatch is still safe when the installed CSV is itself an
    # entry of the target channel (e.g. RHOAI 2.25.12 on "fast" -> "stable-2.25"):
    # OLM keeps the same CSV and only follows a different upgrade graph.
    if [[ "${current_family}" != "${target_family}" || "${current_major}" != "${target_major}" ]]; then
        local pkg installed_csv target_entries
        pkg=$(oc get subscriptions.operators.coreos.com "${subscription}" -n "${namespace}" \
            -o jsonpath='{.spec.name}' 2>/dev/null || true)
        installed_csv=$(oc get subscriptions.operators.coreos.com "${subscription}" -n "${namespace}" \
            -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        target_entries=" $(oc get packagemanifest "${pkg:-${subscription}}" -n openshift-marketplace \
            -o jsonpath="{.status.channels[?(@.name==\"${target_channel}\")].entries[*].name}" 2>/dev/null || true) "
        if [[ -z "${installed_csv}" || "${target_entries}" != *" ${installed_csv} "* ]]; then
            echo "incompatible"
            return 1
        fi
        echo "[INFO] ${subscription}: ${installed_csv} is in channel ${target_channel}; switching from ${current}." >&2
    fi

    oc patch subscriptions.operators.coreos.com "${subscription}" -n "${namespace}" \
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
            oc get clusterserviceversions.operators.coreos.com -n "${namespace}" --no-headers 2>/dev/null \
                | CP4D_CSV_PREFIX="${csv_prefix}" awk '$1 ~ ("^" ENVIRON["CP4D_CSV_PREFIX"])' >&2 || true
            return 1
        fi

        if (( elapsed >= timeout )); then
            echo "[ERROR] CSV ${csv_prefix}* in ${namespace} did not reach Succeeded after ${timeout}s (phase: ${phase:-pending})." >&2
            oc get subscriptions.operators.coreos.com,installplans.operators.coreos.com,clusterserviceversions.operators.coreos.com -n "${namespace}" >&2 || true
            return 1
        fi

        sleep "${interval}"
        (( elapsed += interval ))
        echo "  [${elapsed}s] CSV ${csv_prefix}*: ${phase:-pending}"
    done
}

# -----------------------------------------------------------------------------
# cp4d_prereq_assess <gpu|rhoai|mcg|knative>
# -----------------------------------------------------------------------------
# Decide whether CPD_COMPONENTS needs a cluster prerequisite, from the install
# options the component install passes as --param-file (IBM's defaults where a
# service has none). The rules live in src/helpers/cp4d_prereq_requirements.py.
# Prints one [needed] / [not needed] line per relevant component and sets
# CP4D_PREREQ_NEEDED=true|false. If the options cannot be read it warns and sets
# true: an unneeded operator costs resources, a missing one breaks the install.
# Needs no cluster access, so callers can run it before logging in.
cp4d_prereq_assess() {
    local prereq="$1" opts_file="" verdicts
    if [[ "${INSTALL_OPTIONS:-}" == "true" && -n "${INSTALL_OPTIONS_FILE:-}" ]]; then
        opts_file="${CONFIG_DIR}/${INSTALL_OPTIONS_FILE}"
        if [[ ! -f "${opts_file}" ]]; then
            echo "[WARN] ${opts_file} not found - judging on IBM's default install options." >&2
            opts_file=""
        fi
    fi
    # Prefer the repo's virtualenv (it has PyYAML) over whatever python3 is on PATH.
    local python="python3"
    if [[ -x "${_CP4D_REPO_ROOT}/.venv/bin/python" ]]; then
        python="${_CP4D_REPO_ROOT}/.venv/bin/python"
    fi
    echo "[INFO] Checking CPD_COMPONENTS for the ${prereq} prerequisite (options: ${opts_file:-IBM defaults})..."
    if verdicts="$(CPD_COMPONENTS="${CPD_COMPONENTS:-}" \
            "${python}" "${_CP4D_REPO_ROOT}/src/helpers/cp4d_prereq_requirements.py" "${prereq}" "${opts_file}")"; then
        if [[ -n "${verdicts}" ]]; then
            print -r -- "${verdicts}" | sed 's/^/[INFO]   /'
        fi
        if grep -q '^\[needed\]' <<< "${verdicts}"; then
            CP4D_PREREQ_NEEDED=true
        else
            CP4D_PREREQ_NEEDED=false
        fi
    else
        echo "[WARN] Could not evaluate the install options - treating ${prereq} as needed to be safe." >&2
        CP4D_PREREQ_NEEDED=true
    fi
}

# -----------------------------------------------------------------------------
# cp4d_prereq_gate <gpu|rhoai|mcg|knative> <switch-variable-name> <label>
# -----------------------------------------------------------------------------
# Apply a SKIP_*_INSTALL switch for an operator install script:
#   auto  - install only if cp4d_prereq_assess finds a component needing it
#   true  - always skip
#   false - always install, whatever CPD_COMPONENTS holds
# With the switch unset, the default comes from CP4D_PREREQ_GATE_DEFAULT, which
# the callers that run whole flows export as "auto"
# (2.2_install_prerequisite_operators.sh, and through it the full installs, plus
# the fresh-cluster restore). Unset means the script was run directly: it then
# installs whatever CPD_COMPONENTS holds and says so in a banner.
# Returns 0 to install, 1 to skip; callers use `cp4d_prereq_gate ... || exit 0`.
cp4d_prereq_gate() {
    local prereq="$1" switch="$2" label="$3"
    local mode="${(P)switch:-}"
    if [[ -z "${mode}" && -z "${CP4D_PREREQ_GATE_DEFAULT:-}" ]]; then
        local script="${ZSH_ARGZERO:t}"
        echo ""
        echo "################################################################################"
        echo "##"
        echo "##  DIRECT RUN of ${script}"
        echo "##"
        echo "##  Installing ${label} WHATEVER CPD_COMPONENTS HOLDS."
        echo "##  This is the default when a 2.2.x script is run on its own."
        echo "##"
        echo "##  2.2_install_prerequisite_operators.sh and the full installs install it"
        echo "##  only when a selected component needs it. For this run, set:"
        echo "##    ${switch}=auto   install only if a component needs it"
        echo "##    ${switch}=true   skip it"
        echo "##"
        echo "################################################################################"
        echo ""
        return 0
    fi
    mode="${mode:-${CP4D_PREREQ_GATE_DEFAULT}}"
    case "${mode}" in
        true)
            echo "[INFO] ${switch}=true - skipping ${label}."
            return 1
            ;;
        false)
            echo "[INFO] ${switch}=false - installing ${label} whatever CPD_COMPONENTS holds."
            return 0
            ;;
        auto)
            cp4d_prereq_assess "${prereq}"
            [[ "${CP4D_PREREQ_NEEDED}" == "true" ]] && return 0
            echo "[INFO] No component in CPD_COMPONENTS needs ${label} - skipping (${switch}=false installs it anyway)."
            return 1
            ;;
        *)
            echo "[ERROR] ${switch} / CP4D_PREREQ_GATE_DEFAULT must be auto, true or false (got '${mode}')." >&2
            exit 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# cp4d_has_component <component> [comma-separated list]
# -----------------------------------------------------------------------------
# True when <component> is an exact entry of the list (default
# ${COMPLETE_COMPONENT_LIST}), so ibm_swhcc does not match e.g. ibm_swhcc_x.
cp4d_has_component() {
    [[ ",${2-${COMPLETE_COMPONENT_LIST:-}}," == *",$1,"* ]]
}

# -----------------------------------------------------------------------------
# cp4d_swhcc_operator_ns / cp4d_swhcc_operand_ns
# -----------------------------------------------------------------------------
# Echo the Software Hub Control Center projects when ibm_swhcc is in
# ${COMPLETE_COMPONENT_LIST} (cpd_vars.sh or the caller's environment win):
#   operators  ${PROJECT_SW_HUB_CONTROL_CENTER_OPERATORS}, else cpd-swhub-center
#   operands   ${PROJECT_SW_HUB_CONTROL_CENTER_OPERANDS}, else cpd-swhub-center-operands
# `cpd-cli manage case-download` refuses ibm_swhcc without --swhcc_operator_ns,
# and setup-control-center takes both. Echo nothing and return 1 when ibm_swhcc
# is not selected.
cp4d_swhcc_operator_ns() {
    cp4d_has_component ibm_swhcc || return 1
    echo "${PROJECT_SW_HUB_CONTROL_CENTER_OPERATORS:-cpd-swhub-center}"
}
cp4d_swhcc_operand_ns() {
    cp4d_has_component ibm_swhcc || return 1
    echo "${PROJECT_SW_HUB_CONTROL_CENTER_OPERANDS:-cpd-swhub-center-operands}"
}

# -----------------------------------------------------------------------------
# cp4d_olm_utils_is_premium
# -----------------------------------------------------------------------------
# True when ${OLM_UTILS_IMAGE} is the IBM Software Hub Premium olm-utils image
# (cp.icr.io/cp/cpd/olm-utils-premium-v4). Premium-only commands such as
# setup-control-center are stubs that exit 1 in the standard olm-utils-v4.
cp4d_olm_utils_is_premium() {
    [[ "${OLM_UTILS_IMAGE:-}" == */olm-utils-premium-v4:* ]]
}

# -----------------------------------------------------------------------------
# cp4d_offline_case_check
# -----------------------------------------------------------------------------
# CPD_CASE_SOURCE=offline (air-gapped; written to configs/cp4d_config/
# registry_overrides.sh by scripts/private_registry_mirroring/ for a local
# registry): the CASE packages come from the transfer bundle. `cpd-cli manage
# case-download` then reuses them without network - it only tries, and tolerates
# failing, to refresh the patch metadata - so check they are there before it
# runs. No-op unless CPD_CASE_SOURCE=offline. Returns 1 with a hint otherwise.
cp4d_offline_case_check() {
    [[ "${CPD_CASE_SOURCE:-online}" == offline ]] || return 0
    local cases="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}/offline/${VERSION}/.ibm-pak/data/cases"
    if [[ ! -d "${cases}" || -z "$(ls -A "${cases}" 2>/dev/null)" ]]; then
        echo "[ERROR] CPD_CASE_SOURCE=offline but ${cases} is empty - restore the transfer bundle" \
             "(scripts/private_registry_mirroring/2_download_and_mirror/2.6_restore_transfer_bundle.sh)." >&2
        return 1
    fi
    if [[ -n "${PATCH_ID:-}" ]]; then
        local patch="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}/offline/patch/patch-${VERSION}-${PATCH_ID}.yaml"
        if [[ ! -f "${patch}" ]]; then
            echo "[ERROR] CPD_CASE_SOURCE=offline but the patch metadata ${patch} is missing - restore the transfer bundle." >&2
            return 1
        fi
    fi
    echo "[INFO] CPD_CASE_SOURCE=offline - case-download reuses the CASE packages in ${cases}"
}
