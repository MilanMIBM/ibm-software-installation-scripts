#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 1.3 Apply the mirror configuration from 1.2 (mirrored|airgap only)
# ------------------------------------------------------------------------------
# - ImageDigestMirrorSet / ImageTagMirrorSet: applied as generated (the MCO
#   rolls them to every node; recent OpenShift does this without reboots).
# - CatalogSources: renamed to redhat-operators / certified-operators /
#   community-operators, so every
#   Subscription in this repo (including the reused CP4D Service Mesh script)
#   resolves unchanged. That requires the default OperatorHub sources to be
#   off (CONCERT_DISABLE_DEFAULT_CATALOGS=true, the default here): every other
#   operator on the cluster must then come from mirrored catalogs too.
# - Optional: PRIVATE_REGISTRY_CA_FILE is added to image.config additionalTrustedCA.
#
# Usage: ./1.3_apply_datastore_mirror_config.sh [<cluster-resources dir>]
# ==============================================================================

if [[ "${CONCERT_IMAGE_SOURCE}" == entitled ]]; then
    concert_info "CONCERT_IMAGE_SOURCE=entitled - nothing to apply."
    exit 0
fi

RES_DIR="${1:-$(cat "${CONCERT_WORKSPACE}/oc-mirror/last-cluster-resources" 2>/dev/null || true)}"
if [[ "${RES_DIR}" == none ]]; then
    concert_info "1.2 found nothing to mirror beyond IBM's images - nothing to apply."
    exit 0
fi
[[ -d "${RES_DIR}" ]] || concert_die "Cluster resources directory not found (${RES_DIR:-unset}) - run 1.2 first or pass the directory."

eval "${OC_LOGIN}"

if concert_is_true "${CONCERT_DISABLE_DEFAULT_CATALOGS:-true}"; then
    current="$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}' 2>/dev/null || true)"
    if [[ "${current}" != true ]]; then
        concert_warn "Disabling the default OperatorHub sources (mirrored catalogs take over their names)."
        oc patch operatorhub cluster --type=merge -p '{"spec":{"disableAllDefaultSources":true}}' >/dev/null
    fi
fi

mcp_change=false
catalogs=()
for f in "${RES_DIR}"/*.y*ml(N); do
    kind="$(awk '/^kind:/ {print $2; exit}' "${f}")"
    case "${kind}" in
        ImageDigestMirrorSet|ImageTagMirrorSet)
            if ! oc diff -f "${f}" >/dev/null 2>&1; then mcp_change=true; fi
            oc apply -f "${f}"
            ;;
        CatalogSource)
            image="$(awk '/image:/ {print $2; exit}' "${f}")"
            case "${image}" in
                *redhat-operator-index*)    name=redhat-operators ;;
                *certified-operator-index*) name=certified-operators ;;
                *community-operator-index*) name=community-operators ;;
                *)                          name="" ;;
            esac
            if [[ -n "${name}" ]] && concert_is_true "${CONCERT_DISABLE_DEFAULT_CATALOGS:-true}"; then
                # first "  name:" line = metadata.name (awk: BSD sed lacks 0,/re/)
                awk -v n="${name}" '!done && /^  name:/ { print "  name: " n; done = 1; next } { print }' "${f}" \
                    | oc apply -f -
            else
                name="$(awk '/^  name:/ {print $2; exit}' "${f}")"
                oc apply -f "${f}"
            fi
            catalogs+=("${name}")
            ;;
        "") ;;
        *) concert_info "Skipping ${f:t} (kind ${kind})" ;;
    esac
done

if [[ -n "${PRIVATE_REGISTRY_CA_FILE:-}" ]]; then
    [[ -f "${PRIVATE_REGISTRY_CA_FILE}" ]] || concert_die "PRIVATE_REGISTRY_CA_FILE not found: ${PRIVATE_REGISTRY_CA_FILE}"
    host="${PRIVATE_REGISTRY_LOCATION%%/*}"
    oc create configmap concert-registry-ca -n openshift-config \
        --from-file="${host//:/..}=${PRIVATE_REGISTRY_CA_FILE}" --dry-run=client -o yaml | oc apply -f -
    existing="$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.additionalTrustedCA.name}' 2>/dev/null || true)"
    if [[ -n "${existing}" && "${existing}" != concert-registry-ca ]]; then
        concert_warn "image.config already trusts ConfigMap '${existing}' - add ${host//:/..} to it yourself."
    else
        oc patch image.config.openshift.io cluster --type=merge -p '{"spec":{"additionalTrustedCA":{"name":"concert-registry-ca"}}}' >/dev/null
    fi
fi

for c in "${catalogs[@]}"; do
    concert_wait_for 600 "CatalogSource ${c} READY" \
        zsh -c "[[ \"\$(oc get catalogsource '${c}' -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}')\" == READY ]]"
done

if ${mcp_change}; then
    concert_wait_mcp_updated 3600
fi
concert_info "Mirror configuration applied."
