#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config

# ==============================================================================
# 1.0 Build the inventory (mapping): what is mirrored, and where it lands
# ------------------------------------------------------------------------------
# For every install in MIRROR_INSTALLS (plus "shared") runs
# 1_map_content/installs/<id>.sh map with the install's own config loaded, then
# resolves the layout:
#
#   <root>/<install path>/<source path without registry host>   (cpd, confluent, ...)
#   <root>/shared/...    operator catalogs + content declared shared
#
# Writes registry_mirror_workspace/:
#   inventory/inventory.json, inventory/report.txt
#   <path>/targets.tsv   images: source, target, ...    (2.1 mirrors these)
#   <path>/charts.tsv    Helm charts                     (2.3)
#   <path>/files.tsv     plain downloads                 (2.3)
#   <path>/native.jsonl  work for the install's own tools (2.0: cpd-cli, Concert 1.1)
#   shared/imageset-config.yaml  union of all operators  (2.2, oc-mirror)
#
# Nothing selected -> nothing mapped. Fails on target collisions or IBM-reserved
# paths (cp/, cpopen/) used by other content; fix with MIRROR_<ID>_PATH_OVERRIDES.
# Operators need the OpenShift minor: MIRROR_OCP_MINOR, else read from the
# cluster (logs in with the selected install's config).
# ==============================================================================

WS="${MIRROR_WORKSPACE}"
mkdir -p "${WS}/inventory"
export PREG_SKIP_REGISTRY_OVERRIDES=1     # map hooks must see the original image names

INSTALLS=("${(@f)$(preg_installs)}")
INSTALLS=(${INSTALLS:#})
if (( ${#INSTALLS} == 0 )) && [[ -z "${MIRROR_SHARED_OPERATORS:-}${MIRROR_SHARED_IMAGES:-}" ]]; then
    preg_info "MIRROR_INSTALLS is empty - nothing to map (that is the default: select what to mirror in ${MIRROR_CONFIG_FILE_PATH#${_CP4D_REPO_ROOT}/})."
fi

# Unknown COMPONENTS / CONTENT ids are an error: a typo would silently mirror nothing
# for that item. Components are checked against the install's segment-0 catalog.
VAL_TMP="$(preg_private_tmpdir)"
trap 'rm -rf "${VAL_TMP}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
validate_selection() {   # <id> <components> <content>
    local id="$1" x f="${VAL_TMP}/components.$1" known bad=()
    local kinds="$(preg_install_conf "${id}" INSTALL_CONTENT_KINDS)"
    for x in ${(s: :)${3//,/ }}; do preg_in_list "${x}" "${kinds}" || bad+=("CONTENT '${x}'"); done
    preg_run_hook 0_initial_setup "${id}" components 3>"${f}" >/dev/null 2>&1 || true
    if [[ -s "${f}" ]]; then
        known="$(awk -F'\t' '$1 == "component" { printf "%s ", $2 }' "${f}")"
        for x in ${(s: :)${2//,/ }}; do preg_in_list "${x}" "${known}" || bad+=("COMPONENTS '${x}'"); done
    fi
    (( ${#bad} == 0 )) || preg_die "${id}: unknown ${(j:, :)bad} - the valid ids are listed above MIRROR_$(preg_id_upper "${id}")_COMPONENTS in the mirror config (content kinds: ${kinds})"
    if [[ "${id}" == cpd ]] && preg_has_content cpd ibm-images && ! preg_in_list cpd_platform "$2"; then
        preg_warn "cpd: cpd_platform is not in MIRROR_CPD_COMPONENTS - Software Hub itself will not be mirrored (nothing is added automatically)"
    fi
    return 0
}

typeset -A INV
for id in shared "${INSTALLS[@]}"; do
    rpath="$(preg_install_path "${id}")"     # not "path": zsh ties that to PATH
    [[ -n "${rpath}" ]] || preg_die "No registry path for install '${id}'"
    mkdir -p "${WS}/${rpath}"
    INV[${id}]="${WS}/${rpath}/inventory.jsonl"
    if [[ "${id}" != shared ]]; then
        sel_c="$(preg_install_selection "${id}" COMPONENTS)" sel_k="$(preg_install_selection "${id}" CONTENT)"
        if [[ -z "${sel_c}" || -z "${sel_k}" ]]; then
            preg_info "${id}: COMPONENTS or CONTENT empty - nothing mapped"
            : > "${INV[${id}]}"
            continue
        fi
        validate_selection "${id}" "${sel_c}" "${sel_k}"
    fi
    preg_info "Mapping ${id} -> <root>/${rpath}"
    preg_run_hook 1_map_content "${id}" map 3>"${INV[${id}]}" || preg_die "1_map_content/installs/${id}.sh map failed"
    preg_info "  $(wc -l < "${INV[${id}]}" | tr -d ' ') item(s)"
done

# OpenShift minor, only when operators were selected.
MINOR="${MIRROR_OCP_MINOR:-}"
if [[ -z "${MINOR}" ]] && grep -q '"kind":"operator"' "${(@v)INV}" 2>/dev/null; then
    preg_info "Operators selected and MIRROR_OCP_MINOR is empty - reading it from the cluster"
    preg_cluster_login
    MINOR="$(preg_ocp_minor)"
    [[ "${MINOR}" == 4.<-> ]] || preg_die "Could not read the OpenShift version - set MIRROR_OCP_MINOR (e.g. 4.20)."
    preg_info "OpenShift minor: ${MINOR}"
fi

# Engine config (values via the environment, never interpolated into code).
CFG="${WS}/inventory/build-config.json"
PATHS_SPEC="" OVR_SPEC="" INV_SPEC=""
for id in "${INSTALLS[@]}"; do
    up="$(preg_id_upper "${id}")"
    ovr_var="MIRROR_${up}_PATH_OVERRIDES"
    PATHS_SPEC+="${id}=$(preg_install_path "${id}")"$'\n'
    INV_SPEC+="${id}=${INV[${id}]}"$'\n'
    OVR_SPEC+="${id}=${(P)ovr_var:-}"$'\n'
done
PATHS_SPEC="${PATHS_SPEC}" INV_SPEC="${INV_SPEC}" OVR_SPEC="${OVR_SPEC}" MINOR="${MINOR}" \
SHARED_PATH="$(preg_install_path shared)" SHARED_INV="${INV[shared]}" \
DECLARE="${MIRROR_SHARED_DECLARE:-}" SHARED_OVR="${MIRROR_SHARED_PATH_OVERRIDES:-}" \
preg_python -I - "${CFG}" <<'PY'
import json, os, sys
def kv(name):
    out = {}
    for line in os.environ.get(name, "").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out
def overrides(text):
    return dict(p.split("=", 1) for p in text.split() if "=" in p)
paths, invs, ovrs = kv("PATHS_SPEC"), kv("INV_SPEC"), kv("OVR_SPEC")
installs = [{"id": "shared", "path": os.environ["SHARED_PATH"], "inventory": os.environ["SHARED_INV"],
             "path_overrides": overrides(os.environ.get("SHARED_OVR", ""))}]
installs += [{"id": i, "path": paths[i], "inventory": invs[i], "path_overrides": overrides(ovrs.get(i, ""))}
             for i in paths]
cfg = {"ocp_minor": os.environ.get("MINOR", ""), "shared_path": os.environ["SHARED_PATH"],
       "shared_declare": os.environ.get("DECLARE", "").split(), "installs": installs,
       "shared_path_overrides": overrides(os.environ.get("SHARED_OVR", ""))}
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY

print -r -- ""
rc=0
preg_engine build --workspace "${WS}" --config "${CFG}" || rc=$?
print -r -- ""
preg_info "Inventory: ${WS#${_CP4D_REPO_ROOT}/}/inventory/inventory.json (report: inventory/report.txt)"
(( rc == 0 )) || preg_die "Fix the problems above, then re-run."
