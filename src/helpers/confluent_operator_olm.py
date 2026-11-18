#!/usr/bin/env python3
"""confluent_operator_olm.py - OLM and Helm facts for the Confluent operator install mode, from `oc`/`helm` JSON.

    from src.helpers.confluent_operator_olm import detect, version_gate, installplan_check

Pure functions over what `oc get ... -o json` and `helm list -o json` return, so every decision the shell side
(cfo_detect, cfo_install_ns, cfo_approve_installplans, ... in confluent_operator_helpers.sh) takes can be tested
from fixtures. Rules: implementation contract §3.4 (detect), §3.2 (the shell callers), plan §3.3 / §15.4.

CLI (JSON on stdout unless --format says otherwise; exit 0, or 1 on bad arguments):
  detect --package P --namespace N --csvs F --ogs F --subs F --helm F --helm-values F --owner ID [--format json|shell]
  version-gate --package P --wanted V --csvs F
  installplan-check --plan F --expect CSV...
  channel-info --pm F --package P --catalog C --channel CH --starting-csv CSV [--format json|shell]
  autoselect --cfk-pm F --fko-pm F [--helm-index F] [--format json|lines]
  og-check --ogs F --namespace N [--format json|shell]
  operator-rows --namespace N --subs F --csvs F --plans F --deploys F
  guard-flink --helm F                       lines "fko|cmf <release> <chart>"
  manifest-files --manifest F [--stage N]    lines "<path>\\t<kind>\\t<name>\\t<namespace>\\t<wait>"
  manifest-disabled --manifest F             lines "<kind>\\t<name>"
  front-proxy-mode --manifest F --name N     basic | openshift | none: the C3 front proxy the repo manifest holds
  list-crs --owner ID --json F [--json F ...]  lines "<Kind>/<name> <owned:true|false>"
  sub-env-merge --sub F --set NAME=VALUE...  shell lines CFO_ENV_STATE=present|patch|absent, CFO_ENV_PATCH=<json>
  related-images --csv F                     {"<repo basename>": "<image>"} of the CSV's RELATED_IMAGE_* env
  installplan-others --plan F --package P    lines "<csv>": CSVs of the plan that are not of package P (V23)
  retain-plan --pvcs F --cr Kind/name...     lines "<Kind/name>\\t<pvc>\\t<pv>" of the stateful CRs' data PVCs
  live-json --out F [--route-domain D] [--license-present B] [--pull-secret-present B] [--internal-tls-present B]
            [--external-tls-present B] [--ca-pair-present B] [--related-images F] [--connect-state F]
            [--flink-defaults F] [--flink-env F]
"""

import json
import os
import re
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
try:
    from .confluent_operator_config import operator_catalog
except ImportError:
    sys.path.insert(0, HERE)
    from confluent_operator_config import operator_catalog

OWNER_LABEL = "confluent.ibm-scripts/installed-by"
PKG_CFK = "confluent-for-kubernetes"
PKG_FKO = "cp-fko"
COMMUNITY_FKO_PREFIX = "flink-kubernetes-operator.v"
HELM_FKO_CHART_PREFIX = "flink-kubernetes-operator-"
HELM_CMF_CHART_PREFIX = "confluent-manager-for-apache-flink-"
HELM_CFK_CHART_PREFIX = "confluent-for-kubernetes-"
OPERATOR_DEPLOYMENTS = {PKG_CFK: "confluent-operator", PKG_FKO: "cp-fko"}
_PRERELEASE = re.compile(r"-(alpha|beta|rc|snapshot|dev)", re.IGNORECASE)


# ---------------------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------------------
def _items(doc):
    if not doc:
        return []
    if isinstance(doc, list):
        return doc
    return doc.get("items") or []


def _meta(obj, key, default=""):
    return (obj.get("metadata") or {}).get(key, default)


def _vtuple(text):
    return tuple(int(n) for n in re.findall(r"\d+", text or ""))


def csv_version(csv, package):
    """spec.version, else the part of the name after '<package>.v'."""
    version = (csv.get("spec") or {}).get("version") or ""
    if version:
        return str(version)
    name = _meta(csv, "name")
    prefix = f"{package}.v"
    return name.removeprefix(prefix)


def package_csvs(package, csvs):
    """Non-Copied CSVs of <package> (name starts with '<package>.v')."""
    out = []
    for csv in _items(csvs):
        if (csv.get("status") or {}).get("reason") == "Copied":
            continue
        if _meta(csv, "name").startswith(f"{package}.v"):
            out.append(csv)
    return out


def _og_watch(og):
    """Namespaces an OperatorGroup's operators watch; None = all namespaces."""
    spec = og.get("spec") or {}
    targets = [t for t in (spec.get("targetNamespaces") or [])]
    if targets:
        return None if targets == [""] else sorted(set(targets))
    status = [t for t in ((og.get("status") or {}).get("namespaces") or [])]
    if status:
        return None if "" in status else sorted(set(status))
    if spec.get("selector"):
        return []          # a selector we cannot evaluate offline and OLM has not resolved yet
    return None             # no targets, no selector = AllNamespaces


def watch_set(csv, ogs):
    """Watch set of the operator a CSV runs: its namespace's OperatorGroup, else the CSV's olm.targetNamespaces."""
    ns = _meta(csv, "namespace")
    groups = [og for og in _items(ogs) if _meta(og, "namespace") == ns]
    if groups:
        return _og_watch(groups[0])
    annotations = _meta(csv, "annotations", {}) or {}
    if "olm.targetNamespaces" in annotations:
        value = annotations["olm.targetNamespaces"]
        return None if value == "" else sorted(set(value.split(",")))
    return None


def _watches(watch, namespace):
    return watch is None or namespace in watch


def _subscription_for(csv, package, subs):
    ns, name = _meta(csv, "namespace"), _meta(csv, "name")
    candidates = [s for s in _items(subs) if _meta(s, "namespace") == ns and (s.get("spec") or {}).get("name") == package]
    for sub in candidates:
        status = sub.get("status") or {}
        if name in (status.get("installedCSV"), status.get("currentCSV")):
            return sub
    return candidates[0] if candidates else None


def _helm_watch(values):
    """watchNamespaces of a Helm FKO release; None = all namespaces."""
    watch = (values or {}).get("watchNamespaces")
    if not watch:
        return None
    if isinstance(watch, str):
        watch = [w for w in re.split(r"[,\s]+", watch) if w]
    return sorted(set(watch))


def _release_chart(rel):
    return str(rel.get("chart") or "")


# ---------------------------------------------------------------------------------------------------------------
# detect (§3.4)
# ---------------------------------------------------------------------------------------------------------------
def detect(package, namespace, csvs, ogs, subs, helm_releases, helm_values, owner_id):
    """What already runs <package> for <namespace>: none / reuse / conflict, with the details the shell prints."""
    result = {"result": "none", "ns": "", "csv": "", "version": "", "channel": "", "sub": "", "owned": False,
              "reason": "", "phase": "", "others": []}
    watchers, others, foreign_scope = [], [], []
    for csv in package_csvs(package, csvs):
        watch = watch_set(csv, ogs)
        entry = {"ns": _meta(csv, "namespace"), "csv": _meta(csv, "name"), "version": csv_version(csv, package),
                 "phase": (csv.get("status") or {}).get("phase", ""),
                 "watch": "all" if watch is None else ",".join(watch)}
        if _watches(watch, namespace):
            watchers.append((csv, entry))
        else:
            others.append(entry)
            if entry["ns"] == namespace:
                foreign_scope.append(entry)
    result["others"] = others

    def conflict(reason, entry=None):
        result["result"] = "conflict"
        result["reason"] = reason
        if entry:
            result.update({k: entry[k] for k in ("ns", "csv", "version", "phase")})
        return result

    if package == PKG_FKO:
        for csv in _items(csvs):
            if (csv.get("status") or {}).get("reason") == "Copied":
                continue
            if _meta(csv, "name").startswith(COMMUNITY_FKO_PREFIX) and _watches(watch_set(csv, ogs), namespace):
                return conflict(f"the community flink-kubernetes-operator ({_meta(csv, 'name')} in "
                                f"{_meta(csv, 'namespace')}) watches {namespace}; it must never run next to cp-fko")
        for rel in helm_releases or []:
            if not _release_chart(rel).startswith(HELM_FKO_CHART_PREFIX):
                continue
            key = f"{rel.get('namespace', '')}/{rel.get('name', '')}"
            watch = _helm_watch((helm_values or {}).get(key))
            if _watches(watch, namespace):
                return conflict(f"the Helm Flink operator release {rel.get('name')} ({_release_chart(rel)}) in "
                                f"{rel.get('namespace')} watches {namespace}")
    if package == PKG_CFK:
        for rel in helm_releases or []:
            if _release_chart(rel).startswith(HELM_CFK_CHART_PREFIX) and rel.get("namespace") == namespace:
                return conflict(f"a Helm Confluent for Kubernetes release {rel.get('name')} ({_release_chart(rel)}) "
                                f"runs in {namespace}")

    if len(watchers) >= 2:
        names = ", ".join(f"{e['ns']}/{e['csv']}" for _, e in watchers)
        return conflict(f"two operators watch {namespace} ({names})", watchers[0][1])
    if foreign_scope:
        e = foreign_scope[0]
        return conflict(f"foreign OperatorGroup scope: {e['csv']} in {namespace} watches {e['watch']}, not {namespace}",
                        e)
    if not watchers:
        return result

    csv, entry = watchers[0]
    sub = _subscription_for(csv, package, subs)
    labels = (_meta(sub, "labels", {}) or {}) if sub else {}
    result.update({k: entry[k] for k in ("ns", "csv", "version", "phase")})
    result["owned"] = bool(owner_id) and labels.get(OWNER_LABEL) == owner_id
    if sub:
        result["sub"] = _meta(sub, "name")
        result["channel"] = (sub.get("spec") or {}).get("channel", "")
    if entry["phase"] == "Succeeded":
        result["result"] = "reuse"
        result["reason"] = f"{entry['csv']} in {entry['ns']} watches {namespace}"
        return result
    # Gap fill (not in the contract table): our own OwnNamespace install that has not finished yet is resumed by the
    # install path (every step there is idempotent); anything else that is not Succeeded is a conflict.
    if result["owned"] and entry["ns"] == namespace and entry["phase"] != "Failed":
        result["result"] = "none"
        result["reason"] = f"our install {entry['csv']} in {namespace} is {entry['phase'] or 'pending'} - resuming"
        return result
    return conflict(f"{entry['csv']} in {entry['ns']} watches {namespace} but is {entry['phase'] or 'not ready'}", entry)


def version_gate(package, wanted_version, csvs):
    """Every non-Copied CSV of <package> on the cluster must have <wanted_version> (shared CRDs, rule C1)."""
    found = [{"ns": _meta(c, "namespace"), "csv": _meta(c, "name"), "version": csv_version(c, package)}
             for c in package_csvs(package, csvs)]
    # The shell passes the CSV name minus "<package>.v"; spec.version may drop a suffix the name carries
    # (e.g. "1.16.1" for cp-fko.v1.16.1-cp1), so the CSV name counts as a match too.
    wanted_csv = f"{package}.v{wanted_version}"
    return {"ok": all(f["version"] == wanted_version or f["csv"] == wanted_csv for f in found), "found": found}


def installplan_check(plan, expected_csvs):
    """Approve only when the plan installs nothing but the CSVs we asked for (OLM bundles a namespace's plans)."""
    spec = plan.get("spec") or {}
    csvs = list(spec.get("clusterServiceVersionNames") or [])
    expected = [c for c in expected_csvs if c]
    extra = [c for c in csvs if c not in expected]
    return {"approve": bool(csvs) and not extra, "extra": extra, "csvs": csvs,
            "approved": bool(spec.get("approved")), "phase": (plan.get("status") or {}).get("phase", "")}


def channel_info(packagemanifests, package, catalog, channel, starting_csv):
    """Is <package> offered by <catalog>, with <channel>, and does that channel list <starting_csv>?"""
    out = {"found": False, "default_channel": "", "channels": [], "channel": channel, "channel_found": False,
           "head": "", "entries": [], "starting_csv_ok": not starting_csv}
    for pm in _items(packagemanifests):
        status = pm.get("status") or {}
        if _meta(pm, "name") != package:
            continue
        if catalog and status.get("catalogSource") not in (None, "", catalog):
            continue
        out["found"] = True
        out["default_channel"] = status.get("defaultChannel", "")
        chans = status.get("channels") or []
        out["channels"] = [c.get("name", "") for c in chans]
        want = channel or out["default_channel"]
        out["channel"] = want
        for c in chans:
            if c.get("name") != want:
                continue
            out["channel_found"] = True
            out["head"] = c.get("currentCSV", "")
            entries = [e.get("name", "") for e in (c.get("entries") or [])] or [out["head"]]
            out["entries"] = entries
            out["starting_csv_ok"] = (not starting_csv) or starting_csv in entries
        break
    return out


def og_check(ogs, namespace):
    """The namespace's OperatorGroup: none / own (OwnNamespace for <namespace>) / foreign / multiple."""
    groups = [og for og in _items(ogs) if _meta(og, "namespace") == namespace]
    if not groups:
        return {"result": "none", "name": "", "targets": ""}
    if len(groups) > 1:
        return {"result": "multiple", "name": ",".join(_meta(g, "name") for g in groups), "targets": ""}
    og = groups[0]
    targets = (og.get("spec") or {}).get("targetNamespaces") or []
    watch = _og_watch(og)
    result = "own" if targets == [namespace] or watch == [namespace] else "foreign"
    return {"result": result, "name": _meta(og, "name"),
            "targets": "all" if watch is None else ",".join(watch)}


# ---------------------------------------------------------------------------------------------------------------
# autoselect (§15.5)
# ---------------------------------------------------------------------------------------------------------------
def _pm_for(pms, package):
    for pm in _items(pms):
        if _meta(pm, "name") == package:
            return pm
    return None


def _pm_heads(pm):
    """{channel: head CSV} of a PackageManifest."""
    return {c.get("name", ""): c.get("currentCSV", "") for c in ((pm or {}).get("status") or {}).get("channels") or []}


def _newest_cmf(helm_index, cmf_compat):
    entries = ((helm_index or {}).get("entries") or {}).get("confluent-manager-for-apache-flink") or []
    versions = []
    for e in entries:
        v = str(e.get("version", ""))
        if not v or _PRERELEASE.search(v):
            continue
        if ".".join(v.split(".")[:2]) in cmf_compat:
            versions.append(v)
    return max(versions, key=_vtuple) if versions else ""


def autoselect(cfk_pm, fko_pm, helm_index, catalog):
    """The newest operator set the compat table allows, next to the catalog pins. <catalog> = confluent/operator."""
    comp = catalog.get("compat") or {}
    cfk_compat, cmf_compat = comp.get("cfk") or {}, comp.get("cmf") or {}
    pinned = {
        "CONFLUENT_OPERATOR_CHANNEL": catalog.get("cfk_channel", ""),
        "CONFLUENT_OPERATOR_STARTING_CSV": catalog.get("cfk_csv", ""),
        "FLINK_CMF_CHART_VERSION": catalog.get("cmf_chart", ""),
        "FLINK_OLM_CHANNEL": catalog.get("fko_channel", ""),
        "FLINK_OLM_STARTING_CSV": catalog.get("fko_csv", ""),
    }
    chosen, notes = dict(pinned), []

    cfk = _pm_for(cfk_pm, PKG_CFK)
    heads = _pm_heads(cfk)
    known = [c for c in heads if c in cfk_compat]
    if known:
        channel = max(known, key=_vtuple)
        chosen["CONFLUENT_OPERATOR_CHANNEL"] = channel
        chosen["CONFLUENT_OPERATOR_STARTING_CSV"] = heads[channel] or cfk_compat[channel].get("csv", "")
        newer = [c for c in heads if _vtuple(c) > _vtuple(channel) and c not in cfk_compat]
        if newer:
            notes.append(f"CFK channel(s) {', '.join(sorted(newer, key=_vtuple))} are offered but have no "
                         "compatibility data in the version catalog - not chosen")
    else:
        notes.append("no CFK PackageManifest channel with compatibility data - keeping the pinned CFK set")

    cfk_minor = chosen["CONFLUENT_OPERATOR_CHANNEL"]
    allowed_cmf = {k: v for k, v in cmf_compat.items() if _vtuple(v.get("min_cfk", "0")) <= _vtuple(cfk_minor)}
    if helm_index is None:
        notes.append("no Helm index read - keeping the pinned CMF chart")
        cmf = pinned["FLINK_CMF_CHART_VERSION"]
    else:
        cmf = _newest_cmf(helm_index, allowed_cmf) or pinned["FLINK_CMF_CHART_VERSION"]
    fko_heads = _pm_heads(_pm_for(fko_pm, PKG_FKO))
    line = cmf_compat.get(".".join(cmf.split(".")[:2]))
    if line:
        if fko_heads and line["fko_channel"] not in fko_heads:
            notes.append(f"cp-fko channel {line['fko_channel']} (for CMF {cmf}) is not offered by the catalog - "
                         "keeping the pinned Flink set")
        else:
            chosen["FLINK_CMF_CHART_VERSION"] = cmf
            chosen["FLINK_OLM_CHANNEL"] = line["fko_channel"]
            chosen["FLINK_OLM_STARTING_CSV"] = fko_heads.get(line["fko_channel"]) or line["fko_csv"]
    return {"chosen": chosen, "pinned": pinned, "notes": notes}


# ---------------------------------------------------------------------------------------------------------------
# status rows, manifests, CR lists, Subscription env, live JSON
# ---------------------------------------------------------------------------------------------------------------
def operator_rows(namespace, subs, csvs, plans, deploys):
    """One row per CFK / cp-fko Subscription in <namespace> for 1.2's "Operators" table."""
    rows = []
    csv_phase = {_meta(c, "name"): (c.get("status") or {}).get("phase", "") for c in _items(csvs)
                 if _meta(c, "namespace") in ("", namespace)}
    plan_by_name = {_meta(p, "name"): p for p in _items(plans)}
    ready = {}
    for d in _items(deploys):
        st = d.get("status") or {}
        ready[_meta(d, "name")] = f"{st.get('readyReplicas', 0) or 0}/{(d.get('spec') or {}).get('replicas', 0) or 0}"
    for sub in _items(subs):
        if _meta(sub, "namespace") not in ("", namespace):
            continue
        spec, status = sub.get("spec") or {}, sub.get("status") or {}
        package = spec.get("name", "")
        if package not in OPERATOR_DEPLOYMENTS:
            continue
        installed = status.get("installedCSV", "")
        plan_name = (status.get("installPlanRef") or {}).get("name", "")
        plan = plan_by_name.get(plan_name) or {}
        pending = plan_name if plan and not (plan.get("spec") or {}).get("approved", True) else "-"
        starting = spec.get("startingCSV", "")
        rows.append({
            "subscription": _meta(sub, "name"), "package": package, "state": status.get("state", "-") or "-",
            "installed_csv": installed or "-", "csv_phase": csv_phase.get(installed, "-") or "-",
            "pending_plan": pending, "deployment": OPERATOR_DEPLOYMENTS[package],
            "ready": ready.get(OPERATOR_DEPLOYMENTS[package], "-"),
            "vs_starting": "-" if not starting else ("=" if starting == installed else f"starting {starting}"),
            "channel": spec.get("channel", ""), "approval": spec.get("installPlanApproval", ""),
            "owned": bool((_meta(sub, "labels", {}) or {}).get(OWNER_LABEL)),
        })
    return rows


def guard_flink(helm_releases):
    """Helm releases that make a Flink namespace a scripts-mode install: ("fko"|"cmf", name, chart)."""
    out = []
    for rel in helm_releases or []:
        chart = _release_chart(rel)
        if chart.startswith(HELM_FKO_CHART_PREFIX):
            out.append(("fko", rel.get("name", ""), chart))
        elif chart.startswith(HELM_CMF_CHART_PREFIX):
            out.append(("cmf", rel.get("name", ""), chart))
    return out


def manifest_files(manifest, stage=None):
    files = [f for f in manifest.get("files") or [] if f.get("apply", True)]
    if stage is not None:
        files = [f for f in files if str(f.get("stage", "")) == str(stage)]
    return sorted(files, key=lambda f: (int(f.get("order", 0)), f.get("path", "")))


def front_proxy_mode(manifest, name):
    """The front-proxy mode a rendered repo manifest holds: Deployment <name> plus its nginx.conf File = basic,
    the Deployment alone = openshift (oauth-proxy), no Deployment = none."""
    files = manifest.get("files") or []
    dep = any(f.get("kind") == "Deployment" and f.get("name") == name for f in files)
    conf = any(f.get("kind") == "File" and f.get("name") == f"{name}-nginx.conf" for f in files)
    if not dep:
        return "none"
    return "basic" if conf else "openshift"


def list_crs(docs, owner_id):
    out = []
    for doc in docs:
        for obj in _items(doc):
            labels = _meta(obj, "labels", {}) or {}
            out.append((f"{obj.get('kind', '')}/{_meta(obj, 'name')}", labels.get(OWNER_LABEL) == owner_id))
    return sorted(set(out))


def sub_env_merge(sub, wanted):
    """('present'|'patch'|'absent', merge patch) to make Subscription <sub> carry every NAME=VALUE in <wanted>."""
    if not sub or not sub.get("metadata"):
        return "absent", None
    env = list(((sub.get("spec") or {}).get("config") or {}).get("env") or [])
    current = {e.get("name"): e.get("value") for e in env}
    if all(current.get(k) == v for k, v in wanted.items()):
        return "present", None
    merged, seen = [], set()
    for e in env:
        name = e.get("name")
        if name in wanted:
            merged.append({"name": name, "value": wanted[name]})
            seen.add(name)
        else:
            merged.append(e)
    merged.extend({"name": k, "value": v} for k, v in wanted.items() if k not in seen)
    return "patch", {"spec": {"config": {"env": merged}}}


def installplan_others(plan, package):
    """CSVs an InstallPlan carries that do not belong to <package> (OLM colocation puts every Subscription of a
    namespace into one plan, V23 / plan 15.14 item 4): approving the plan moves those operators too."""
    csvs = list(((plan or {}).get("spec") or {}).get("clusterServiceVersionNames") or [])
    return [c for c in csvs if not c.startswith(f"{package}.v")]


# Data PVCs CFK creates per stateful CR (V15): data0-<cr>-<N> (Kafka, KRaftController, ControlCenter),
# data-<cr>-<N> (KsqlDB), prometheus-data-<cr>-<N> / alertmanager-data-<cr>-<N> (ControlCenter next-gen).
STATEFUL_KINDS = ("Kafka", "KRaftController", "KsqlDB", "ControlCenter")
_PVC_PREFIXES = r"(?:data\d*|prometheus-data|alertmanager-data)"


def retain_plan(pvcs, crs):
    """[(Kind/name, pvc, pv)] for the data PVCs of the stateful CRs in <crs> ("Kind/name"); pv is "" while unbound.
    A CR with no matching PVC gives (Kind/name, "", "") so the caller can say so."""
    items = _items(pvcs)
    out = []
    for ref in crs:
        kind, _, name = ref.partition("/")
        if kind not in STATEFUL_KINDS or not name:
            continue
        rx = re.compile(rf"^{_PVC_PREFIXES}-{re.escape(name)}-\d+$")
        found = []
        for pvc in items:
            pname = _meta(pvc, "name")
            if rx.match(pname):
                found.append((ref, pname, str((pvc.get("spec") or {}).get("volumeName") or "")))
        out.extend(sorted(found) or [(ref, "", "")])
    return out


def related_images(csv):
    """{"cp-server": "<image>", ...} from the RELATED_IMAGE_* env of a CSV's deployments (csv image source, O11)."""
    out = {}
    deployments = (((csv or {}).get("spec") or {}).get("install") or {}).get("spec", {}).get("deployments") or []
    for dep in deployments:
        containers = (((dep.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []
        for c in containers:
            for e in c.get("env") or []:
                if str(e.get("name", "")).startswith("RELATED_IMAGE_") and e.get("value"):
                    image = e["value"]
                    base = image.split("@")[0].split(":")[0].rsplit("/", 1)[-1]
                    out[base] = image
    for r in ((csv or {}).get("spec") or {}).get("relatedImages") or []:
        image = r.get("image", "")
        if image:
            out.setdefault(image.split("@")[0].split(":")[0].rsplit("/", 1)[-1], image)
    return out


# ---------------------------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------------------------
def _load(path, yaml_ok=False):
    """JSON (or YAML) file; empty or missing -> {}."""
    if not path or not os.path.exists(path):
        return {}
    with open(path) as fh:
        text = fh.read()
    if not text.strip():
        return {}
    try:
        return json.loads(text)
    except ValueError:
        if not yaml_ok:
            raise
        import yaml  # PyYAML is in the venv; only the Helm index needs it

        return yaml.safe_load(text) or {}


def _shell(prefix, mapping):
    for k, v in mapping.items():
        if isinstance(v, bool):
            v = "true" if v else "false"
        elif isinstance(v, (list, dict)):
            v = json.dumps(v)
        print(f"{prefix}{k.upper()}={shlex.quote(str(v))}")


def _parse(argv, single, multi=()):
    out = {k: [] for k in multi}
    i = 0
    while i < len(argv):
        key = argv[i]
        name = key[2:] if key.startswith("--") else None
        if name in multi:
            i += 1
            while i < len(argv) and not argv[i].startswith("--"):
                out[name].append(argv[i])
                i += 1
            continue
        if name not in single or i + 1 >= len(argv):
            raise ValueError(f"bad argument {key!r}")
        out[name] = argv[i + 1]
        i += 2
    return out


def _b(text):
    return str(text).lower() == "true"


def main(argv):
    if not argv:
        print(__doc__.split("CLI")[1], file=sys.stderr)
        return 1
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "detect":
            o = _parse(rest, {"package", "namespace", "csvs", "ogs", "subs", "helm", "helm-values", "owner", "format"})
            helm = _load(o.get("helm"))
            r = detect(o["package"], o["namespace"], _load(o.get("csvs")), _load(o.get("ogs")), _load(o.get("subs")),
                       helm if isinstance(helm, list) else _items(helm), _load(o.get("helm-values")), o.get("owner", ""))
            if o.get("format") == "shell":
                others = " ".join(f"{e['ns']}/{e['csv']}" for e in r["others"])
                _shell("CFO_", {"result": r["result"], "ns": r["ns"], "csv": r["csv"], "version": r["version"],
                                "channel": r["channel"], "sub": r["sub"], "owned": r["owned"], "reason": r["reason"],
                                "phase": r["phase"], "others": others})
            else:
                print(json.dumps(r, indent=2))
            return 0
        if cmd == "version-gate":
            o = _parse(rest, {"package", "wanted", "csvs"})
            print(json.dumps(version_gate(o["package"], o["wanted"], _load(o.get("csvs")))))
            return 0
        if cmd == "installplan-check":
            o = _parse(rest, {"plan"}, {"expect"})
            print(json.dumps(installplan_check(_load(o["plan"]), o["expect"])))
            return 0
        if cmd == "channel-info":
            o = _parse(rest, {"pm", "package", "catalog", "channel", "starting-csv", "format"})
            r = channel_info(_load(o.get("pm")), o["package"], o.get("catalog", ""), o.get("channel", ""),
                             o.get("starting-csv", ""))
            if o.get("format") == "shell":
                _shell("CFO_CI_", {k: (" ".join(v) if isinstance(v, list) else v) for k, v in r.items()})
            else:
                print(json.dumps(r))
            return 0
        if cmd == "autoselect":
            o = _parse(rest, {"cfk-pm", "fko-pm", "helm-index", "format", "catalog"})
            index = _load(o["helm-index"], yaml_ok=True) if o.get("helm-index") else None
            catalog = _load(o["catalog"]) if o.get("catalog") else operator_catalog()
            r = autoselect(_load(o.get("cfk-pm")), _load(o.get("fko-pm")), index, catalog)
            if o.get("format") == "lines":
                for k in r["chosen"]:
                    print(f"{k}\t{r['pinned'][k]}\t{r['chosen'][k]}")
                for note in r["notes"]:
                    print(f"NOTE\t{note}")
            else:
                print(json.dumps(r, indent=2))
            return 0
        if cmd == "og-check":
            o = _parse(rest, {"ogs", "namespace", "format"})
            r = og_check(_load(o.get("ogs")), o["namespace"])
            if o.get("format") == "shell":
                _shell("CFO_OG_", r)
            else:
                print(json.dumps(r))
            return 0
        if cmd == "operator-rows":
            o = _parse(rest, {"namespace", "subs", "csvs", "plans", "deploys"})
            for row in operator_rows(o["namespace"], _load(o.get("subs")), _load(o.get("csvs")),
                                     _load(o.get("plans")), _load(o.get("deploys"))):
                print("\t".join(str(row[k]) for k in ("subscription", "package", "channel", "approval", "state",
                                                     "installed_csv", "csv_phase", "pending_plan", "deployment",
                                                     "ready", "vs_starting")))
            return 0
        if cmd == "guard-flink":
            o = _parse(rest, {"helm"})
            helm = _load(o.get("helm"))
            for kind, name, chart in guard_flink(helm if isinstance(helm, list) else _items(helm)):
                print(kind, name, chart)
            return 0
        if cmd == "manifest-files":
            o = _parse(rest, {"manifest", "stage"})
            for f in manifest_files(_load(o["manifest"]), o.get("stage")):
                print("\t".join(str(f.get(k, "")) for k in ("path", "kind", "name", "namespace", "wait")))
            return 0
        if cmd == "manifest-disabled":
            o = _parse(rest, {"manifest"})
            for d in _load(o["manifest"]).get("disabled") or []:
                print(f"{d.get('kind', '')}\t{d.get('name', '')}")
            return 0
        if cmd == "front-proxy-mode":
            o = _parse(rest, {"manifest", "name"})
            print(front_proxy_mode(_load(o["manifest"]), o["name"]))
            return 0
        if cmd == "list-crs":
            o = _parse(rest, {"owner"}, {"json"})
            for ref, owned in list_crs([_load(p) for p in o["json"]], o.get("owner", "")):
                print(ref, "true" if owned else "false")
            return 0
        if cmd == "sub-env-merge":
            o = _parse(rest, {"sub"}, {"set"})
            wanted = dict(item.split("=", 1) for item in o["set"])
            state, patch = sub_env_merge(_load(o.get("sub")), wanted)
            _shell("CFO_ENV_", {"state": state, "patch": json.dumps(patch, separators=(",", ":")) if patch else ""})
            return 0
        if cmd == "installplan-others":
            o = _parse(rest, {"plan", "package"})
            for c in installplan_others(_load(o["plan"]), o["package"]):
                print(c)
            return 0
        if cmd == "retain-plan":
            o = _parse(rest, {"pvcs"}, {"cr"})
            for ref, pvc, pv in retain_plan(_load(o["pvcs"]), o["cr"]):
                print(f"{ref}\t{pvc}\t{pv}")
            return 0
        if cmd == "related-images":
            o = _parse(rest, {"csv"})
            print(json.dumps(related_images(_load(o.get("csv"))), sort_keys=True))
            return 0
        if cmd == "live-json":
            o = _parse(rest, {"out", "route-domain", "license-present", "pull-secret-present", "internal-tls-present",
                              "external-tls-present", "ca-pair-present", "related-images", "connect-state",
                              "flink-defaults", "flink-env"})
            live = {}
            if o.get("route-domain"):
                live["route_domain"] = o["route-domain"]
            for key, opt in (("license_present", "license-present"), ("pull_secret_present", "pull-secret-present"),
                             ("internal_tls_secret_present", "internal-tls-present"),
                             ("external_tls_secret_present", "external-tls-present"),
                             ("ca_pair_present", "ca-pair-present")):
                if opt in o:
                    live[key] = _b(o[opt])
            # Every object-valued live key is a JSON object or absent (never a list, string or null).
            for key, opt in (("related_images", "related-images"), ("connect_state", "connect-state"),
                             ("flink_defaults", "flink-defaults")):
                doc = _load(o.get(opt))
                if doc and not isinstance(doc, dict):
                    print(f"[WARN] live-json: {o.get(opt)} is not a JSON object - {key} left out", file=sys.stderr)
                elif doc:
                    live[key] = doc
            env = _load(o.get("flink-env"))
            secrets = ((env.get("spec") or {}).get("secrets") if isinstance(env, dict) else None) or {}
            if isinstance(secrets, dict) and secrets:
                live["flink_env_secrets"] = secrets
            with open(o["out"], "w") as fh:
                json.dump(live, fh, indent=2, sort_keys=True)
                fh.write("\n")
            return 0
    except (ValueError, KeyError) as exc:
        print(f"[ERROR] {cmd}: {exc}", file=sys.stderr)
        return 1
    print(f"[ERROR] unknown command {cmd!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
