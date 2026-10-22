#!/bin/zsh
# Segment 1 hook: datastax_mc (contract: _template.sh)
#   chart   oci://icr.io/mission-control-helm/mission-control:${MC_VERSION}
#   images  - MIRROR_DATASTAX_MC_HAULER_MANIFEST set: DataStax's own list (authoritative)
#           - otherwise: the chart rendered with the repo's values
#             (configs/datastax_mc_config/helm-values-files.txt), plus the images
#             Mission Control creates at run time from global.imageConfig
#             (HCD/DSE at the versions listed, cql-router, cqlsh, data-api,
#             k8ssandra-client). HCD without MIRROR_DATASTAX_MC_HCD_VERSIONS: the
#             newest MIRROR_DATASTAX_MC_HCD_LATEST (default 3) versions tagged in
#             the registry the chart names (cp.icr.io/cp/ibm-ds-mission-control/hcd)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in map) ;; check) exit 0 ;; *) preg_die "usage: $0 map|check" ;; esac
COMPS="${MIRROR_DATASTAX_MC_COMPONENTS:-}"
CONTENT="${MIRROR_DATASTAX_MC_CONTENT:-}"
[[ -n "${COMPS}" && -n "${CONTENT}" ]] || exit 0
has() { preg_in_list "$1" "${CONTENT}"; }
comp() { preg_in_list "$1" "${COMPS}"; }

CHART="oci://icr.io/mission-control-helm/mission-control"
VER="${MC_VERSION:-}"

# --- DataStax's Hauler manifest wins when given ----------------------------------------
if [[ -n "${MIRROR_DATASTAX_MC_HAULER_MANIFEST:-}" ]]; then
    [[ -f "${MIRROR_DATASTAX_MC_HAULER_MANIFEST}" ]] || preg_die "MIRROR_DATASTAX_MC_HAULER_MANIFEST not found: ${MIRROR_DATASTAX_MC_HAULER_MANIFEST}"
    preg_engine hauler "${MIRROR_DATASTAX_MC_HAULER_MANIFEST}" | while IFS= read -r line; do
        case "${line}" in
            *'"kind": "image"'*) has images && print -r -- "${line%\}}, \"component\": \"hauler\"}" >&3 ;;
            *'"kind": "chart"'*) has chart && print -r -- "${line%\}}, \"component\": \"hauler\"}" >&3 ;;
        esac
    done
    exit 0
fi

[[ -n "${VER}" ]] || preg_die "MC_VERSION is empty - generate configs/datastax_mc_config/datastax_mc_vars.sh first"
has chart && preg_emit_chart "${CHART}" mission-control "${VER}" control-plane

has images || exit 0

# --- Chart images (control / data plane) ------------------------------------------------
if comp control-plane || comp data-plane; then
    values=()
    vf="${DATASTAX_MC_CONFIG_DIR:-${CONFIGS_ROOT}/datastax_mc_config}/helm-values-files.txt"
    if [[ -f "${vf}" ]]; then
        for f in "${(@f)$(< "${vf}")}"; do [[ -n "${f}" && -f "${f}" ]] && values+=(-f "${f}"); done
    fi
    (( ${#values} )) || preg_warn "No rendered MC values (run 2.0_render_values.sh of the MC track) - rendering with chart defaults."
    plane=()
    comp control-plane || plane=(--set controlPlane=false)
    found=0
    for img in $(preg_chart_images mission-control "${CHART}" --version "${VER}" -n "${MC_NAMESPACE:-mission-control}" "${values[@]}" "${plane[@]}"); do
        preg_emit_image "${img}" "$(comp control-plane && print -rn -- control-plane || print -rn -- data-plane)"
        (( found += 1 ))
    done
    (( found )) || preg_die "helm template of ${CHART}:${VER} rendered no images (helm 3.14-3.18 on PATH? icr.io reachable?)"
fi

# --- Images Mission Control creates at run time (global.imageConfig) ------------------
VALUES="$(helm show values "${CHART}" --version "${VER}" 2>/dev/null)" || preg_die "Could not read the values of ${CHART}:${VER}"

# HCD versions: the explicit list, otherwise the newest N "<x.y.z><suffix>" tags.
HCD_VERSIONS="${MIRROR_DATASTAX_MC_HCD_VERSIONS:-}"
if comp hcd && [[ -z "${HCD_VERSIONS}" ]]; then
    N="${MIRROR_DATASTAX_MC_HCD_LATEST:-3}"
    [[ "${N}" == <1-> ]] || preg_die "MIRROR_DATASTAX_MC_HCD_LATEST must be a positive number (got '${N}')"
    hcd="$(print -r -- "${VALUES}" | preg_python -c '
import sys, yaml
t = (((yaml.safe_load(sys.stdin) or {}).get("global") or {}).get("imageConfig") or {}).get("types", {}).get("hcd") or {}
print("/".join(p for p in (t.get("registry") or "docker.io", t.get("repository") or "", t.get("name") or "") if p) + "\t" + (t.get("suffix") or ""))')"
    hcd_repo="${hcd%%$'\t'*}" hcd_sfx="${hcd#*$'\t'}"
    tmp="$(preg_private_tmpdir)"
    preg_write_authfile "${tmp}/auth.json" none --sources
    tags="$(skopeo list-tags --authfile "${tmp}/auth.json" "docker://${hcd_repo}" 2>"${tmp}/err")" || {
        err="$(tail -1 "${tmp}/err")"; rm -rf "${tmp}"
        preg_die "hcd: could not list the tags of ${hcd_repo} (${err}) - check MIRROR_IBM_ENTITLEMENT_KEY, or set MIRROR_DATASTAX_MC_HCD_VERSIONS"
    }
    rm -rf "${tmp}"
    HCD_VERSIONS="$(print -r -- "${tags}" | SFX="${hcd_sfx}" N="${N}" preg_python -c '
import json, os, re, sys
sfx = os.environ["SFX"]
pat = re.compile(r"^(\d+)\.(\d+)\.(\d+)" + re.escape(sfx) + "$")
vs = sorted({tuple(map(int, m.groups())) for m in map(pat.match, json.load(sys.stdin).get("Tags") or []) if m})
print(",".join(".".join(map(str, v)) for v in vs[-int(os.environ["N"]):]))')"
    [[ -n "${HCD_VERSIONS}" ]] || preg_die "hcd: no <x.y.z>${hcd_sfx} tags found in ${hcd_repo} - set MIRROR_DATASTAX_MC_HCD_VERSIONS"
    preg_info "hcd: MIRROR_DATASTAX_MC_HCD_VERSIONS empty - the newest ${N} in ${hcd_repo}: ${HCD_VERSIONS}"
fi

runtime="$(print -r -- "${VALUES}" | \
    HCD="${HCD_VERSIONS}" DSE="${MIRROR_DATASTAX_MC_DSE_VERSIONS:-}" preg_python -c '
import os, sys
try:
    import yaml
except ImportError:
    sys.exit("PyYAML needed (repo .venv)")
cfg = ((yaml.safe_load(sys.stdin) or {}).get("global") or {}).get("imageConfig") or {}
def ref(d, tag):
    parts = [d.get("registry") or "docker.io", d.get("repository") or "", d.get("name") or ""]
    return "/".join(p for p in parts if p) + ":" + tag
names = {"cql-router": "cql-gateway", "cqlsh": "cqlsh", "data-api": "data-api", "k8ssandra-client": "k8ssandra-client"}
for key, d in (cfg.get("images") or {}).items():
    if key in names and d.get("tag"):
        print(names[key] + "\t" + ref(d, str(d["tag"])))
for kind, env in (("hcd", "HCD"), ("dse", "DSE")):
    t = (cfg.get("types") or {}).get(kind)
    for v in [x for x in os.environ.get(env, "").replace(",", " ").split() if x]:
        if t:
            print(kind + "\t" + ref(t, v + (t.get("suffix") or "")))
')" || preg_die "Could not read global.imageConfig from ${CHART}:${VER}"
for line in "${(@f)runtime}"; do
    [[ -n "${line}" ]] || continue
    c="${line%%$'\t'*}" img="${line#*$'\t'}"
    comp "${c}" && preg_emit_image "${img}" "${c}"
done
if comp dse && [[ -z "${MIRROR_DATASTAX_MC_DSE_VERSIONS:-}" ]]; then
    preg_warn "dse selected but MIRROR_DATASTAX_MC_DSE_VERSIONS is empty - no database server images mapped."
fi
exit 0
