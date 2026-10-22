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
# 1.3 Capture a reference cluster (read-only)
# ------------------------------------------------------------------------------
# On a CONNECTED cluster where the products are already installed: every
# Subscription (package, channel, catalog) and every image the pods run, saved
# to inventory/reference-<cluster>.json and compared with 1.0's inventory.
# The cheapest way to find what the mapping rules miss (operator dependencies,
# images pulled at run time).
#
#   ./1.3_capture_reference_cluster.sh [--current] [--namespaces ns1,ns2]
#     --current     use the current oc session instead of logging in with the
#                   selected install's config
#     --namespaces  limit the image scan (default: every namespace except
#                   openshift-*, kube-* and default)
#
# IBM images (cp.icr.io, icr.io) are listed separately: cpd-cli / Concert 1.1
# mirror them from the CASE packages and image lists, not from 1.0's targets.
# ==============================================================================

CURRENT=false NSLIST=""
while (( $# )); do
    case "$1" in
        --current) CURRENT=true; shift ;;
        --namespaces) NSLIST="${2:?--namespaces needs a list}"; shift 2 ;;
        *) preg_die "Unknown argument: $1" ;;
    esac
done
WS="${MIRROR_WORKSPACE}"
[[ -f "${WS}/inventory/inventory.json" ]] || preg_die "No inventory - run 1.0_build_inventory.sh first."

${CURRENT} || preg_cluster_login
server="$(oc whoami --show-server)"
host="${${server#https://}%%:*}"
preg_info "Capturing ${server}"

RUN="$(preg_private_tmpdir)"
trap 'rm -rf "${RUN}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
oc get subscriptions.operators.coreos.com -A -o json > "${RUN}/subs.json"
oc get pods -A -o json > "${RUN}/pods.json"

OUT="${WS}/inventory/reference-${host}.json"
NSLIST="${NSLIST}" preg_python -I - "${RUN}/subs.json" "${RUN}/pods.json" "${WS}" "${OUT}" "${server}" <<'PY'
import json, os, re, sys
subs_f, pods_f, ws, out_f, server = sys.argv[1:6]
only = [n for n in os.environ.get("NSLIST", "").split(",") if n]

subs = [{"namespace": s["metadata"]["namespace"], "package": s["spec"].get("name", ""),
         "channel": s["spec"].get("channel", ""), "source": s["spec"].get("source", "")}
        for s in json.load(open(subs_f)).get("items", [])]

images = {}
for p in json.load(open(pods_f)).get("items", []):
    ns = p["metadata"]["namespace"]
    if only and ns not in only:
        continue
    if not only and (ns.startswith(("openshift-", "kube-")) or ns in ("openshift", "default")):
        continue
    for c in (p["spec"].get("containers") or []) + (p["spec"].get("initContainers") or []):
        images.setdefault(c.get("image", ""), set()).add(ns)

inv = json.load(open(os.path.join(ws, "inventory", "inventory.json")))
mapped_pkgs = {pkg for pkgs in inv.get("operators", {}).values() for pkg in pkgs}
mapped_repos = {i["repo"] for i in inv.get("images", [])}

def repo_of(ref):
    r = ref.split("@", 1)[0]
    first = r.split("/", 1)[0]
    if "/" in r and ("." in first or ":" in first or first == "localhost"):
        dom, rest = first, r.split("/", 1)[1]
    else:
        dom, rest = "docker.io", r
    if ":" in rest.rsplit("/", 1)[-1]:
        rest = rest.rsplit(":", 1)[0]
    if dom == "docker.io" and "/" not in rest:
        rest = "library/" + rest
    return f"{dom}/{rest}"

ibm, unmapped = [], []
for ref, nss in sorted(images.items()):
    if not ref:
        continue
    repo = repo_of(ref)
    if re.match(r"^(cp\.)?icr\.io/", repo):
        ibm.append(ref)
    elif repo not in mapped_repos and not repo.startswith("image-registry.openshift-image-registry.svc"):
        unmapped.append({"image": ref, "namespaces": sorted(nss)})
missing_ops = [s for s in subs if s["package"] not in mapped_pkgs]

json.dump({"server": server, "subscriptions": subs,
           "images": {k: sorted(v) for k, v in images.items()},
           "operators_not_mapped": missing_ops, "images_not_mapped": unmapped,
           "ibm_images": ibm}, open(out_f, "w"), indent=2)

print(f"Subscriptions: {len(subs)}   images in scanned namespaces: {len(images)}")
print(f"\nOperators running there but not in the inventory ({len(missing_ops)}):")
for s in missing_ops:
    print(f"   {s['package']:<40} {s['channel']:<16} {s['source']:<28} ns {s['namespace']}")
print(f"\nNon-IBM images running there but not in any targets.tsv ({len(unmapped)}):")
for u in unmapped:
    print(f"   {u['image']}   [{', '.join(u['namespaces'][:4])}{', ...' if len(u['namespaces']) > 4 else ''}]")
print(f"\nIBM images (mirrored by cpd-cli / Concert 1.1, not compared): {len(ibm)}")
PY
preg_info "Saved ${OUT#${_CP4D_REPO_ROOT}/}"
preg_info "Add what is missing through the selections (or MIRROR_SHARED_OPERATORS / MIRROR_SHARED_IMAGES / MIRROR_<ID>_EXTRA_IMAGES) and re-run 1.0."
