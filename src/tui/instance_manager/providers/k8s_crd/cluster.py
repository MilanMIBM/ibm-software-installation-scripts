"""Read side of L1: CRD index, kind -> REST path resolution, paged lists, the owner graph.

The owner graph is built bottom-up: PVCs and StatefulSets name their owners
(ownerReferences); only those owner kinds are listed, then their owners, and so on. That
reaches wrapper CRs (CPDEdbInstance -> EDB Cluster -> PVC) without knowing any kind in
advance. PVCs made from a StatefulSet volumeClaimTemplate carry no ownerReference; they
are matched by the `<template>-<statefulset>-<ordinal>` naming rule.
Everything stays in memory.
"""

from __future__ import annotations

import re
import threading
from concurrent.futures import ThreadPoolExecutor

from ....common.kube import METADATA_ONLY, Kube, KubeError

MAX_OWNER_ROUNDS = 6
PAGE = 500
PARALLEL = 16
# Aggregated discovery (k8s >= 1.27): every API resource with its kind, scope and plural in one call,
# instead of the full CRD list (MBs of schemas) or one discovery call per group.
AGGREGATED = "application/json;g=apidiscovery.k8s.io;v=v2;as=APIGroupDiscoveryList,application/json"
CRD_PATH = "/apis/apiextensions.k8s.io/v1/customresourcedefinitions"


def split_api_version(api_version: str) -> tuple[str, str]:
    return tuple(api_version.split("/", 1)) if "/" in api_version else ("", api_version)


class Cluster:
    def __init__(self, kube: Kube):
        self.kube = kube
        self._lock = threading.RLock()
        self._crds: list[dict] | None = None
        self._index: list[dict] | None = None
        self._crd_by_name: dict[str, dict | None] = {}
        self._discovery: dict[str, list[dict]] = {}
        self._cache: dict[str, list[dict]] = {}

    # -- lists ---------------------------------------------------------------
    def list(self, path: str, *, accept: str | None = None, cache: bool = True, **query) -> list[dict]:
        key = f"{path}?{sorted(query.items())}|{accept}"
        with self._lock:
            if cache and key in self._cache:
                return self._cache[key]
        items, cont = [], None
        while True:
            kw = dict(query, limit=PAGE, **({"continue": cont} if cont else {}))
            data = self.kube.get(path, accept=accept, **kw) if accept else self.kube.get(path, **kw)
            items.extend(data.get("items") or [])
            cont = (data.get("metadata") or {}).get("continue")
            if not cont:
                break
        with self._lock:
            self._cache[key] = items
        return items

    def try_list(self, path: str, **kw) -> list[dict]:
        try:
            return self.list(path, **kw)
        except KubeError as e:
            if e.status in (403, 404):
                return []
            raise

    def drop_lists(self) -> None:
        """Forget listed objects (instances change); keep the CRD index and API discovery."""
        with self._lock:
            self._cache.clear()

    def invalidate(self) -> None:
        with self._lock:
            self._cache.clear()
            self._crds = None
            self._index = None
            self._crd_by_name.clear()

    # -- API resources / CRDs -------------------------------------------------------
    def index(self) -> list[dict]:
        """Every API resource: {group, version, kind, plural, singular, short, namespaced, preferred}."""
        with self._lock:
            if self._index is not None:
                return self._index
        out: list[dict] = []
        for path in ("/apis", "/api"):
            try:
                doc = self.kube.get(path, accept=AGGREGATED)
            except KubeError:
                continue
            for item in doc.get("items") or []:
                group = (item.get("metadata") or {}).get("name", "")
                for n, ver in enumerate(item.get("versions") or []):
                    for r in ver.get("resources") or []:
                        rk = r.get("responseKind") or {}
                        out.append({"group": group, "version": ver.get("version", ""), "kind": rk.get("kind", ""),
                                    "plural": r.get("resource", ""), "singular": r.get("singularResource", ""),
                                    "short": r.get("shortNames") or [], "namespaced": r.get("scope") == "Namespaced",
                                    "preferred": n == 0})
        with self._lock:
            self._index = out
        return out

    def get_crd(self, name: str) -> dict | None:
        """One CRD by name (<plural>.<group>), cached; None for built-in kinds."""
        with self._lock:
            if name in self._crd_by_name:
                return self._crd_by_name[name]
        try:
            crd = self.kube.get(f"{CRD_PATH}/{name}")
        except KubeError:
            crd = None
        with self._lock:
            self._crd_by_name[name] = crd
        return crd

    def crds(self) -> list[dict]:
        """The full CRD list (slow on big clusters; the hot paths use index() + get_crd())."""
        with self._lock:
            if self._crds is None:
                self._crds = self.list(CRD_PATH)
            return self._crds

    def _matches(self, token: str) -> list[dict]:
        t = token.strip().lower()
        name, _, group = t.partition(".")
        hits = {}
        for e in self.index():
            if not e["group"]:
                continue
            aliases = {e["kind"].lower(), e["plural"].lower(), e["singular"].lower(), *[x.lower() for x in e["short"]]}
            if t == f"{e['plural']}.{e['group']}".lower() or (name in aliases and (not group or group == e["group"].lower())):
                hits.setdefault((e["group"], e["plural"]), e)
        return list(hits.values())

    def find_crd(self, token: str) -> dict | None:
        """plural.group | kind.group | Kind | plural | singular | shortName (case-insensitive)."""
        hits = self._matches(token)
        if len(hits) != 1:
            return None
        return self.get_crd(f"{hits[0]['plural']}.{hits[0]['group']}")

    def find_crds(self, token: str) -> list[dict]:
        t = token.strip().lower()
        found = {(e["group"], e["plural"]) for e in self.index()
                 if e["group"] and t in (e["kind"].lower(), e["plural"].lower(), e["singular"].lower())}
        crds = [self.get_crd(f"{plural}.{group}") for group, plural in sorted(found)]
        return [c for c in crds if c]

    def kinds_in_group(self, group: str) -> list[dict]:
        """Index entries (preferred version) of one API group, e.g. a parent's sibling kinds."""
        seen, out = set(), []
        for e in self.index():
            if e["group"] == group and e["preferred"] and e["plural"] not in seen:
                seen.add(e["plural"])
                out.append(e)
        return out

    def _api_resources(self, api_version: str) -> list[dict]:
        with self._lock:
            if api_version not in self._discovery:
                group, version = split_api_version(api_version)
                path = f"/apis/{group}/{version}" if group else f"/api/{version}"
                try:
                    self._discovery[api_version] = self.kube.get(path).get("resources") or []
                except KubeError:
                    self._discovery[api_version] = []
            return self._discovery[api_version]

    def resource_path(self, api_version: str, kind: str, namespace: str | None) -> str | None:
        group, version = split_api_version(api_version)
        base = f"/apis/{group}/{version}" if group else f"/api/{version}"
        for e in self.index():
            if e["group"] == group and e["version"] == version and e["kind"] == kind:
                return f"{base}/namespaces/{namespace}/{e['plural']}" if e["namespaced"] and namespace \
                    else f"{base}/{e['plural']}"
        for r in self._api_resources(api_version):           # not in the aggregated index: ask the group
            if r.get("kind") == kind and "/" not in r.get("name", ""):
                if r.get("namespaced") and namespace:
                    return f"{base}/namespaces/{namespace}/{r['name']}"
                return f"{base}/{r['name']}"
        return None

    def list_many(self, paths: list[str]) -> dict[str, list[dict]]:
        """Several lists at once (independent GETs, run in parallel)."""
        if not paths:
            return {}
        with ThreadPoolExecutor(max_workers=min(PARALLEL, len(paths))) as pool:
            return dict(zip(paths, pool.map(self.try_list, paths)))

    # -- cluster-wide objects ------------------------------------------------
    def storage_classes(self) -> list[dict]:
        return self.list("/apis/storage.k8s.io/v1/storageclasses")

    def pvcs(self) -> list[dict]:
        return self.list("/api/v1/persistentvolumeclaims")

    def statefulsets(self) -> list[dict]:
        return self.list("/apis/apps/v1/statefulsets")

    def storage_profiles(self) -> list[dict]:
        return self.try_list("/apis/cdi.kubevirt.io/v1beta1/storageprofiles")

    def secret_names(self, namespace: str) -> set[str]:
        items = self.try_list(f"/api/v1/namespaces/{namespace}/secrets", accept=METADATA_ONLY)
        return {(i.get("metadata") or {}).get("name", "") for i in items}


def _controller(meta: dict) -> dict | None:
    refs = meta.get("ownerReferences") or []
    return next((r for r in refs if r.get("controller")), refs[0] if refs else None)


def sink_key(ref: dict | None) -> str | None:
    if not ref:
        return None
    group, _ = split_api_version(ref.get("apiVersion", ""))
    return f"{group}/{ref.get('kind', '')}"


class OwnerGraph:
    """uid -> parent uids for the cluster's PVCs (+ StatefulSets) and the owners above them.

    Every PVC is tagged with `_sink` (group/Kind of its controller, or of its StatefulSet's
    controller) cluster-wide, for peer evidence; owner chains are only climbed in the
    namespaces asked for."""

    def __init__(self, cluster: Cluster):
        self.cluster = cluster
        self.parents: dict[str, set[str]] = {}
        self.objects: dict[str, dict] = {}
        self.pvcs: list[dict] = []
        self._annotated = False
        self._climbed: set[str] = set()

    def build(self, namespaces: set[str] | None = None) -> OwnerGraph:
        """namespaces=None -> climb everywhere."""
        if not self._annotated:
            self._annotate()
        todo = {"*"} if namespaces is None else set(namespaces)
        if "*" in self._climbed:
            return self
        todo -= self._climbed
        if todo:
            self._climbed |= todo
            self._climb(None if "*" in todo else todo)
        return self

    def _annotate(self) -> None:
        self._annotated = True
        tpl: list[tuple[str, re.Pattern, dict]] = []
        for s in self.cluster.statefulsets():
            m = s.get("metadata") or {}
            self._add(s)
            for t in (s.get("spec") or {}).get("volumeClaimTemplates") or []:
                tname = (t.get("metadata") or {}).get("name", "")
                tpl.append((m.get("namespace", ""),
                            re.compile(rf"^{re.escape(tname)}-{re.escape(m.get('name', ''))}-\d+$"), s))
        for p in self.cluster.pvcs():
            meta = p.get("metadata") or {}
            self._add(p)
            self.pvcs.append(p)
            ctrl = _controller(meta)
            if ctrl is None:
                for ns, rx, s in tpl:
                    if ns == meta.get("namespace") and rx.match(meta.get("name", "")):
                        self.parents.setdefault(meta["uid"], set()).add(s["metadata"]["uid"])
                        ctrl = _controller(s.get("metadata") or {}) or {"apiVersion": "apps/v1",
                                                                      "kind": "StatefulSet"}
                        break
            p["_sink"] = sink_key(ctrl)

    def _add(self, obj: dict) -> None:
        meta = obj.get("metadata") or {}
        uid = meta.get("uid")
        if not uid:
            return
        self.objects[uid] = obj
        for r in meta.get("ownerReferences") or []:
            if r.get("uid"):
                self.parents.setdefault(uid, set()).add(r["uid"])

    def _climb(self, namespaces: set[str] | None) -> None:
        listed: set[tuple[str, str, str]] = set()
        for _ in range(MAX_OWNER_ROUNDS):
            wanted: set[tuple[str, str, str]] = set()
            for uid, obj in list(self.objects.items()):
                ns = (obj.get("metadata") or {}).get("namespace") or ""
                if namespaces is not None and ns not in namespaces:
                    continue
                for r in (obj.get("metadata") or {}).get("ownerReferences") or []:
                    if r.get("uid") not in self.objects:
                        wanted.add((r.get("apiVersion", ""), r.get("kind", ""), ns))
            wanted -= listed
            if not wanted:
                return
            listed |= wanted
            paths = {}
            for api_version, kind, ns in wanted:
                path = self.cluster.resource_path(api_version, kind, ns or None)
                if path:
                    paths[path] = (api_version, kind)
            for path, items in self.cluster.list_many(list(paths)).items():   # one round, in parallel
                api_version, kind = paths[path]
                for o in items:
                    o.setdefault("apiVersion", api_version)
                    o.setdefault("kind", kind)
                    self._add(o)

    def ancestors(self, uid: str) -> set[str]:
        seen, stack = set(), [uid]
        while stack:
            for p in self.parents.get(stack.pop(), ()):
                if p not in seen:
                    seen.add(p)
                    stack.append(p)
        return seen

    def pvcs_under(self, uid: str) -> list[dict]:
        return [p for p in self.pvcs if uid in self.ancestors(p["metadata"]["uid"])]

    def peer_pvcs(self, sink_keys: set[str], exclude_uids: set[str]) -> list[dict]:
        return [p for p in self.pvcs if p.get("_sink") in sink_keys
                and (p.get("metadata") or {}).get("uid") not in exclude_uids]
