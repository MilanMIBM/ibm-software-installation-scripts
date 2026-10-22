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
# 1.2 Mirror the non-IBM content the defaults need (mirrored|airgap only)
# ------------------------------------------------------------------------------
# External data stores (plan D4) and Istio (D8) bring OLM operators and images
# that IBM's image lists do not cover:
#   redhat-operators     servicemeshoperator3 (Istio on), ODF/MCG (S3 provisioned)
#   certified-operators  cloudnative-pg (PostgreSQL provisioned; the catalog is
#                        CONCERT_DS_PG_OPERATOR_SOURCE - community-operators before 4.21)
#   additional images    CNPG Postgres, MySQL, Redis, Neo4j (when provisioned)
#
# Renders an oc-mirror v2 ImageSetConfiguration and runs oc-mirror:
#   mirrored: registry -> registry
#   airgap:   --phase=save (mirror to disk) / --phase=load (disk to registry)
# 1.3 then applies the generated IDMS/ITMS/CatalogSources to the cluster.
#
# oc-mirror only ships for Linux: on Linux it runs natively when on PATH,
# otherwise inside the locally built runner image (0.2 builds it locally for
# mirrored/airgap) with the linux binary downloaded into concert_workspace/tools.
#
# Inputs:
#   CONCERT_OCP_MINOR (e.g. 4.18)  - catalog version; read from the cluster if unset
#   CONCERT_REDHAT_PULL_SECRET_FILE - registry.redhat.io creds (console.redhat.com
#                                     pull secret), default configs/concert_config/redhat-pull-secret.json
#   CONCERT_MIRROR_ODF=false        - skip ODF when it is already mirrored/installed
#   CONCERT_MIRROR_ODF_PACKAGES     - ODF package list (oc-mirror v2 does not
#                                     resolve operator dependencies)
# ==============================================================================

if [[ "${CONCERT_IMAGE_SOURCE}" == entitled ]]; then
    concert_info "CONCERT_IMAGE_SOURCE=entitled - operators come from the default catalogs, nothing to mirror."
    exit 0
fi
# The private registry mirroring track owns the cluster's mirrored catalogs (one
# union catalog for every install); it sets this in registry_overrides.sh.
if concert_is_true "${CONCERT_MIRROR_VIA_SHARED:-false}"; then
    concert_info "CONCERT_MIRROR_VIA_SHARED=true - operators and data-store images are mirrored by scripts/private_registry_mirroring (2.1/2.2)."
    exit 0
fi

PHASE="${CONCERT_AIRGAP_PHASE:-}"
for _arg in "$@"; do
    case "${_arg}" in
        --phase=*) PHASE="${_arg#*=}" ;;
        *) concert_die "Unknown argument: ${_arg} (only --phase=save|load)" ;;
    esac
done
[[ "${CONCERT_IMAGE_SOURCE}" == mirrored ]] && PHASE=mirror
[[ "${PHASE}" == (mirror|save|load) ]] || concert_die "airgap needs --phase=save or --phase=load."

MINOR="${CONCERT_OCP_MINOR:-}"
if [[ -z "${MINOR}" ]]; then
    eval "${OC_LOGIN}"
    MINOR="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2)"
fi
[[ "${MINOR}" == 4.<-> ]] || concert_die "Could not determine the OpenShift minor version - set CONCERT_OCP_MINOR=4.x."

# --- What is needed ---------------------------------------------------------------
redhat_pkgs=()
pg_pkgs=()
extra_images=()
if concert_product_enabled istio; then
    redhat_pkgs+=("servicemeshoperator3:${CONCERT_ISTIO_CHANNEL:-stable}")
fi
if concert_ds_server_provisioned S3 && concert_is_true "${CONCERT_MIRROR_ODF:-true}"; then
    for p in ${=CONCERT_MIRROR_ODF_PACKAGES:-odf-operator ocs-operator mcg-operator odf-csi-addons-operator ocs-client-operator odf-prometheus-operator recipe rook-ceph-operator cephcsi-operator odf-dependencies}; do
        redhat_pkgs+=("${p}:stable-${MINOR}")
    done
fi
if concert_ds_server_provisioned POSTGRES; then
    pg_pkgs+=("cloudnative-pg:${CONCERT_DS_PG_OPERATOR_CHANNEL:-stable-v1}")
fi
# The Postgres image also runs 2.3.2's init Job against an existing server.
concert_ds_server_needed POSTGRES && extra_images+=("${CONCERT_DS_PG_IMAGE}")
concert_ds_server_provisioned MYSQL && extra_images+=("${CONCERT_DS_MYSQL_IMAGE}")
concert_ds_server_provisioned REDIS && extra_images+=("${CONCERT_DS_REDIS_IMAGE}")
concert_ds_server_provisioned NEO4J && extra_images+=("${CONCERT_DS_NEO4J_IMAGE}")

WS="${CONCERT_WORKSPACE}/oc-mirror"
AIRGAP_DIR="${CONCERT_AIRGAP_DIR:-${CONCERT_WORKSPACE}/airgap}"
mkdir -p "${WS}"

if (( ${#redhat_pkgs} + ${#pg_pkgs} + ${#extra_images} == 0 )); then
    concert_info "Nothing beyond IBM's images is needed for this configuration."
    print -r -- none > "${WS}/last-cluster-resources"   # tells 1.3 there is nothing to apply
    exit 0
fi

# --- ImageSetConfiguration ----------------------------------------------------------
ISC="${WS}/imageset-config.yaml"
{
    print -r -- "kind: ImageSetConfiguration"
    print -r -- "apiVersion: mirror.openshift.io/v2alpha1"
    print -r -- "mirror:"
    if (( ${#redhat_pkgs} + ${#pg_pkgs} )); then
        print -r -- "  operators:"
        if (( ${#redhat_pkgs} )); then
            print -r -- "  - catalog: registry.redhat.io/redhat/redhat-operator-index:v${MINOR}"
            print -r -- "    packages:"
            for p in "${redhat_pkgs[@]}"; do
                print -r -- "    - name: ${p%%:*}"
                print -r -- "      channels:"
                print -r -- "      - name: ${p#*:}"
            done
        fi
        if (( ${#pg_pkgs} )); then
            print -r -- "  - catalog: registry.redhat.io/redhat/${${CONCERT_DS_PG_OPERATOR_SOURCE:-certified-operators}%s}-index:v${MINOR}"
            print -r -- "    packages:"
            for p in "${pg_pkgs[@]}"; do
                print -r -- "    - name: ${p%%:*}"
                print -r -- "      channels:"
                print -r -- "      - name: ${p#*:}"
            done
        fi
    fi
    if (( ${#extra_images} )); then
        print -r -- "  additionalImages:"
        for i in "${extra_images[@]}"; do print -r -- "  - name: ${i}"; done
    fi
} > "${ISC}"
concert_info "ImageSetConfiguration: ${ISC}"
sed 's/^/    /' "${ISC}"

# --- Auth file: Red Hat pull secret + private registry push creds -------------------
RH_PS="${CONCERT_REDHAT_PULL_SECRET_FILE:-${CONCERT_CONFIG_DIR}/redhat-pull-secret.json}"
[[ "${PHASE}" == load || -f "${RH_PS}" ]] || concert_die "Red Hat pull secret not found: ${RH_PS} (download it from console.redhat.com)."
AUTH="${WS}/.auth.json"
_priv="$(concert_private_tmpdir)"
concert_write_dockerconfig "${_priv}/private.json" \
    "${PRIVATE_REGISTRY_LOCATION%%/*}=PRIVATE_REGISTRY_PUSH_USER:PRIVATE_REGISTRY_PUSH_PASSWORD"
(umask 077; python3 - "${RH_PS}" "${_priv}/private.json" > "${AUTH}" <<'PY'
import json, os, sys
merged = {"auths": {}}
for path in sys.argv[1:]:
    if os.path.isfile(path):
        merged["auths"].update(json.load(open(path)).get("auths", {}))
print(json.dumps(merged))
PY
)
rm -rf "${_priv}"
trap 'rm -f "${AUTH}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

# --- oc-mirror ----------------------------------------------------------------------
TARGET="docker://${PRIVATE_REGISTRY_LOCATION:-}/concert-deps"
case "${PHASE}" in
    mirror) OCM_ARGS=(--v2 -c /ws/imageset-config.yaml --workspace file:///ws "${TARGET}" --authfile /ws/.auth.json) ;;
    save)   OCM_ARGS=(--v2 -c /ws/imageset-config.yaml file:///airgap/oc-mirror --authfile /ws/.auth.json) ;;
    load)   OCM_ARGS=(--v2 -c /ws/imageset-config.yaml --from file:///airgap/oc-mirror "${TARGET}" --authfile /ws/.auth.json) ;;
esac
mkdir -p "${AIRGAP_DIR}"

if [[ "$(uname -s)" == Linux ]] && command -v oc-mirror >/dev/null 2>&1; then
    # Native: map the container paths onto the workspace
    OCM_ARGS=("${(@)OCM_ARGS//\/ws/${WS}}")
    OCM_ARGS=("${(@)OCM_ARGS//\/airgap/${AIRGAP_DIR}}")
    oc-mirror "${OCM_ARGS[@]}"
else
    TOOLS="${CONCERT_WORKSPACE}/tools"
    if [[ ! -x "${TOOLS}/oc-mirror" ]]; then
        concert_info "Downloading oc-mirror (linux amd64)..."
        mkdir -p "${TOOLS}"
        curl -fSL -o "${TOOLS}/oc-mirror.tar.gz" \
            "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-${MINOR}/oc-mirror.rhel9.tar.gz"
        tar -xzf "${TOOLS}/oc-mirror.tar.gz" -C "${TOOLS}" oc-mirror
        chmod +x "${TOOLS}/oc-mirror"
        rm -f "${TOOLS}/oc-mirror.tar.gz"
    fi
    IMAGE="$(CONCERT_RUNNER=container concert_runner_image)"
    podman image exists "${IMAGE}" || IMAGE="$(concert_runner_image)"
    podman image exists "${IMAGE}" || concert_die "No local runner image to run oc-mirror in - run 0.2 with CONCERT_RUNNER=container first."
    # HOME=/ws: oc-mirror keeps its (large) cache under $HOME/.oc-mirror
    podman run --rm --platform linux/amd64 --user 0:0 -e HOME=/ws \
        -v "${WS}:/ws" -v "${AIRGAP_DIR}:/airgap" -v "${TOOLS}/oc-mirror:/usr/local/bin/oc-mirror:ro" \
        --entrypoint /usr/local/bin/oc-mirror "${IMAGE}" "${OCM_ARGS[@]}"
fi

if [[ "${PHASE}" == save ]]; then
    concert_info "Saved to ${AIRGAP_DIR}/oc-mirror - transfer it (with imageset-config.yaml), then run --phase=load on the disconnected side."
else
    RES_DIR="${WS}/working-dir/cluster-resources"
    [[ "${PHASE}" == load ]] && RES_DIR="${AIRGAP_DIR}/oc-mirror/working-dir/cluster-resources"
    print -r -- "${RES_DIR}" > "${WS}/last-cluster-resources"
    concert_info "Cluster resources: ${RES_DIR} - next: 1.3_apply_datastore_mirror_config.sh"
fi
