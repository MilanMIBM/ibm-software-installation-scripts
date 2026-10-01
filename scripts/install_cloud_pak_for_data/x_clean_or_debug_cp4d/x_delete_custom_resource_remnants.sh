#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# --- Options
# Full cluster-scoped teardown of CPD remnants. The Helm-based CPD uninstall
# leaves three kinds of orphans behind once the projects/namespaces are gone:
#
#   1. The cluster-scoped objects listed in cluster_scoped_resources_uninstall_list.yaml
#      (ClusterRoles, ClusterRoleBindings, webhook configurations, ...).
#   2. CustomResourceDefinitions -- Helm does NOT delete CRDs on `helm uninstall`,
#      and they are almost never written into the uninstall list, so they survive
#      both the Helm uninstall and the namespace deletion. We discover these live
#      from the cluster (every CRD whose group ends in the configured suffix).
#   3. Helm release records (secrets/configmaps of type helm.sh/release.v1) -- the
#      bookkeeping Helm keeps for each installed chart.
#
# This script removes all three. It is the cleanup for the case where a plain
# `oc delete -f cluster_scoped_resources_uninstall_list.yaml` leaves orphaned
# CRDs and Helm state behind.
#
#   --preview=true        ->  only report what would be deleted
#   --preview=false       ->  actually delete the resources (default)
#   --timeout=<sec>       ->  per-object wait before force-clearing finalizers
#   --file=<path>         ->  override the deletion list location
#   --crd-group-suffix=X  ->  delete CRDs whose API group ends with X (default: ibm.com)
#   --skip-crds=true      ->  do not touch CRDs (only the YAML resources + Helm)
#   --skip-helm=true      ->  do not touch Helm release records
PREVIEW=false
DELETE_TIMEOUT=30
UNINSTALL_LIST="${CPD_CLI_WORK_PATH}/cluster_scoped_resources_uninstall_list.yaml"
CRD_GROUP_SUFFIX="ibm.com"
SKIP_CRDS=false
SKIP_HELM=false

for arg in "$@"; do
    case "${arg}" in
        --preview=true)       PREVIEW=true ;;
        --preview=false)      PREVIEW=false ;;
        --timeout=*)          DELETE_TIMEOUT="${arg#--timeout=}" ;;
        --file=*)             UNINSTALL_LIST="${arg#--file=}" ;;
        --crd-group-suffix=*) CRD_GROUP_SUFFIX="${arg#--crd-group-suffix=}" ;;
        --skip-crds=true)     SKIP_CRDS=true ;;
        --skip-helm=true)     SKIP_HELM=true ;;
    esac
done

# --- Colours & formatting
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
preview() { echo -e "${DIM}[PREVIEW]${RESET} $*"; }

# ---
eval "${OC_LOGIN}"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  CPD Remnant Teardown (CRDs + cluster-scoped + Helm)${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# ----------------------------------------------------------------------------
# Source 1: resources flagged in the uninstall list (ClusterRoles, webhooks...).
# Parsed into TAB-separated `<selector>\t<name>\t<kind>` rows, where <selector>
# is the kind[.group] form `oc` understands. CRDs found here are merged with the
# live-discovered set below.
# ----------------------------------------------------------------------------
RESOURCE_LIST=""
if [[ -f "${UNINSTALL_LIST}" ]]; then
    info "Reading deletion list: ${BOLD}${UNINSTALL_LIST}${RESET}"
    RESOURCE_LIST=$(python3 -c "
import sys, yaml

def selector(kind, api_version):
    grp = ''
    if api_version and '/' in api_version:
        grp = api_version.split('/', 1)[0]
    k = kind.lower()
    return f'{k}.{grp}' if grp else k

seen = set()
rows = []
with open('${UNINSTALL_LIST}') as fh:
    for doc in yaml.safe_load_all(fh):
        if not isinstance(doc, dict):
            continue
        kind = doc.get('kind')
        name = (doc.get('metadata') or {}).get('name')
        if not kind or not name:
            continue
        sel = selector(kind, doc.get('apiVersion', ''))
        key = (sel, name)
        if key in seen:
            continue
        seen.add(key)
        rows.append((sel, name, kind))

for sel, name, kind in rows:
    print(f'{sel}\t{name}\t{kind}')
" 2>/dev/null || true)
else
    warn "Deletion list not found: ${BOLD}${UNINSTALL_LIST}${RESET}"
    warn "Continuing with live CRD discovery and Helm cleanup only."
fi

# Partition the YAML resources into "still present" (SEL/NAME) vs already gone.
# CRDs named in the YAML go straight into the CRD name set.
SEL=(); NAME=()
typeset -A CRD_SET           # set of CRD full names (dedups YAML + live discovery)
YAML_MISSING=0; YAML_TOTAL=0

if [[ -n "${RESOURCE_LIST}" ]]; then
    while IFS=$'\t' read -r sel name kind; do
        [[ -z "${sel}" || -z "${name}" ]] && continue
        YAML_TOTAL=$((YAML_TOTAL + 1))
        if [[ "${kind}" == "CustomResourceDefinition" ]]; then
            CRD_SET[${name}]=1
            continue
        fi
        if ! oc get "${sel}" "${name}" &>/dev/null; then
            YAML_MISSING=$((YAML_MISSING + 1))
            continue
        fi
        SEL+=("${sel}"); NAME+=("${name}")
    done <<< "${RESOURCE_LIST}"
fi

# ----------------------------------------------------------------------------
# Source 2: live CRD discovery. Helm leaves CRDs behind and they are absent from
# the uninstall list, so we pull every CRD whose group ends with the suffix.
# ----------------------------------------------------------------------------
if [[ "${SKIP_CRDS}" != "true" ]]; then
    info "Discovering CRDs with group ending in ${BOLD}${CRD_GROUP_SUFFIX}${RESET}"
    LIVE_CRDS=$(oc get crd \
        -o jsonpath="{range .items[?(@.spec.group)]}{.metadata.name}{'\t'}{.spec.group}{'\n'}{end}" 2>/dev/null \
        | awk -v sfx="${CRD_GROUP_SUFFIX}" 'index($2, sfx) && substr($2, length($2)-length(sfx)+1) == sfx {print $1}' || true)
    while IFS= read -r crd; do
        [[ -z "${crd}" ]] && continue
        CRD_SET[${crd}]=1
    done <<< "${LIVE_CRDS}"
fi

# Resolve the CRD set to those actually present on the cluster.
CRD_NAME=()
for crd in "${(@k)CRD_SET}"; do
    if oc get crd "${crd}" &>/dev/null; then
        CRD_NAME+=("${crd}")
    fi
done

# ----------------------------------------------------------------------------
# Source 3: Helm release records (secrets/configmaps of type helm.sh/release.v1).
# Stored as `<namespace>\t<kind>\t<name>` rows.
# ----------------------------------------------------------------------------
HELM_NS=(); HELM_KIND=(); HELM_NAME=()
if [[ "${SKIP_HELM}" != "true" ]]; then
    info "Discovering Helm release records (type=helm.sh/release.v1)"
    HELM_SECRETS=$(oc get secret -A --field-selector type=helm.sh/release.v1 \
        -o jsonpath="{range .items[*]}{.metadata.namespace}{'\t'}{.metadata.name}{'\n'}{end}" 2>/dev/null || true)
    while IFS=$'\t' read -r ns name; do
        [[ -z "${name}" ]] && continue
        HELM_NS+=("${ns}"); HELM_KIND+=("secret"); HELM_NAME+=("${name}")
    done <<< "${HELM_SECRETS}"
    # Older Helm 2 / configmap-backed releases.
    HELM_CMS=$(oc get configmap -A -l owner=helm \
        -o jsonpath="{range .items[*]}{.metadata.namespace}{'\t'}{.metadata.name}{'\n'}{end}" 2>/dev/null || true)
    while IFS=$'\t' read -r ns name; do
        [[ -z "${name}" ]] && continue
        HELM_NS+=("${ns}"); HELM_KIND+=("configmap"); HELM_NAME+=("${name}")
    done <<< "${HELM_CMS}"
fi

PRESENT=$(( ${#SEL[@]} + ${#CRD_NAME[@]} + ${#HELM_NAME[@]} ))

echo ""
echo -e "  ${BOLD}YAML cluster-scoped resources : ${#SEL[@]}${RESET} present  ${DIM}(${YAML_MISSING} already gone of ${YAML_TOTAL} listed)${RESET}"
echo -e "  ${BOLD}CRDs (${CRD_GROUP_SUFFIX})              : ${#CRD_NAME[@]}${RESET} present"
echo -e "  ${BOLD}Helm release records          : ${#HELM_NAME[@]}${RESET} present"
echo -e "  ${GREEN}Total to delete               : ${PRESENT}${RESET}"
echo ""

if [[ ${PRESENT} -eq 0 ]]; then
    success "Nothing to clean up - no CPD remnants found."
    exit 0
fi

# --- Listing
echo -e "  ${BOLD}To remove${RESET}"
for (( i = 1; i <= ${#SEL[@]}; i++ )); do
    echo -e "    ${YELLOW}✗${RESET}  ${SEL[$i]}/${NAME[$i]}"
done
for (( i = 1; i <= ${#HELM_NAME[@]}; i++ )); do
    echo -e "    ${YELLOW}✗${RESET}  helm ${HELM_KIND[$i]}/${HELM_NAME[$i]}  ${DIM}(ns: ${HELM_NS[$i]})${RESET}"
done
for (( i = 1; i <= ${#CRD_NAME[@]}; i++ )); do
    echo -e "    ${YELLOW}✗${RESET}  crd/${CRD_NAME[$i]}  ${DIM}(deleted last)${RESET}"
done
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

if [[ "${PREVIEW}" == "true" ]]; then
    for (( i = 1; i <= ${#SEL[@]}; i++ )); do
        preview "Would delete: ${BOLD}${SEL[$i]}/${NAME[$i]}${RESET}"
    done
    for (( i = 1; i <= ${#HELM_NAME[@]}; i++ )); do
        preview "Would delete Helm ${HELM_KIND[$i]}: ${BOLD}${HELM_NAME[$i]}${RESET} (ns: ${HELM_NS[$i]})"
    done
    for (( i = 1; i <= ${#CRD_NAME[@]}; i++ )); do
        preview "Would delete CRD: ${BOLD}${CRD_NAME[$i]}${RESET}"
    done
    echo ""
    info "Preview complete - nothing was deleted (run with --preview=false to apply)."
    exit 0
fi

# Generic cluster-scoped delete with finalizer fallback.
delete_resource() {
    local sel="$1" name="$2" label="$3"

    echo -e "  ${label} Deleting ${BOLD}${sel}/${name}${RESET}"
    oc delete "${sel}" "${name}" --wait=false --ignore-not-found=true &>/dev/null || true

    local deadline=$(( SECONDS + DELETE_TIMEOUT ))
    while oc get "${sel}" "${name}" &>/dev/null && (( SECONDS < deadline )); do
        sleep 1
    done

    if ! oc get "${sel}" "${name}" &>/dev/null; then
        success "    ${sel}/${name} removed."
        return 0
    fi

    warn "    ${sel}/${name} stuck - clearing finalizers."
    oc patch "${sel}" "${name}" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' &>/dev/null || true

    local fdeadline=$(( SECONDS + DELETE_TIMEOUT ))
    while oc get "${sel}" "${name}" &>/dev/null && (( SECONDS < fdeadline )); do
        sleep 1
    done

    if oc get "${sel}" "${name}" &>/dev/null; then
        warn "    ${sel}/${name} still present after clearing finalizers - inspect manually."
        return 0
    fi
    success "    ${sel}/${name} removed."
}

# CRD delete: clear finalizers on any surviving instances (across all namespaces)
# first so the CRD can finish terminating, then on the CRD object itself.
delete_crd() {
    local crd="$1" label="$2"

    echo -e "  ${label} Deleting CRD ${BOLD}${crd}${RESET}"
    oc delete crd "${crd}" --wait=false --ignore-not-found=true &>/dev/null || true

    local deadline=$(( SECONDS + DELETE_TIMEOUT ))
    while oc get crd "${crd}" &>/dev/null && (( SECONDS < deadline )); do
        sleep 1
    done

    if ! oc get crd "${crd}" &>/dev/null; then
        success "    ${crd} removed."
        return 0
    fi

    warn "    ${crd} stuck in Terminating - clearing finalizers on lingering instances."

    local resource
    resource=$(oc get crd "${crd}" \
        -o jsonpath='{.spec.names.plural}.{.spec.group}' 2>/dev/null || true)

    if [[ -n "${resource}" && "${resource}" != "." ]]; then
        local instances
        instances=$(oc get "${resource}" --all-namespaces \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
        while IFS=' ' read -r ns iname; do
            [[ -z "${iname}" ]] && continue
            if [[ -n "${ns}" ]]; then
                oc patch "${resource}" "${iname}" -n "${ns}" \
                    --type=merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null \
                    && success "    cleared finalizers on ${resource}/${iname} (ns: ${ns})" \
                    || warn "    failed to clear ${resource}/${iname} (ns: ${ns})"
            else
                oc patch "${resource}" "${iname}" \
                    --type=merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null \
                    && success "    cleared finalizers on ${resource}/${iname}" \
                    || warn "    failed to clear ${resource}/${iname}"
            fi
        done <<< "${instances}"
    fi

    oc patch crd "${crd}" --type=merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null || true

    local fdeadline=$(( SECONDS + DELETE_TIMEOUT ))
    while oc get crd "${crd}" &>/dev/null && (( SECONDS < fdeadline )); do
        sleep 1
    done

    if oc get crd "${crd}" &>/dev/null; then
        warn "    ${crd} still present after clearing finalizers - inspect manually."
        return 0
    fi
    success "    ${crd} removed."
}

idx=0

# 1. YAML cluster-scoped resources (ClusterRoles/Bindings/webhooks).
for (( i = 1; i <= ${#SEL[@]}; i++ )); do
    (( idx++ )) || true
    delete_resource "${SEL[$i]}" "${NAME[$i]}" "${BOLD}[${idx}/${PRESENT}]${RESET}"
done

# 2. Helm release records.
for (( i = 1; i <= ${#HELM_NAME[@]}; i++ )); do
    (( idx++ )) || true
    echo -e "  ${BOLD}[${idx}/${PRESENT}]${RESET} Deleting Helm ${HELM_KIND[$i]} ${BOLD}${HELM_NAME[$i]}${RESET} (ns: ${HELM_NS[$i]})"
    oc delete "${HELM_KIND[$i]}" "${HELM_NAME[$i]}" -n "${HELM_NS[$i]}" --ignore-not-found=true &>/dev/null \
        && success "    helm ${HELM_KIND[$i]}/${HELM_NAME[$i]} removed." \
        || warn "    failed to remove helm ${HELM_KIND[$i]}/${HELM_NAME[$i]}"
done

# 3. CRDs last (deleting a CRD garbage-collects any remaining instances).
for (( i = 1; i <= ${#CRD_NAME[@]}; i++ )); do
    (( idx++ )) || true
    delete_crd "${CRD_NAME[$i]}" "${BOLD}[${idx}/${PRESENT}]${RESET}"
done

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
success "CPD remnant teardown complete (${PRESENT} processed)."
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
