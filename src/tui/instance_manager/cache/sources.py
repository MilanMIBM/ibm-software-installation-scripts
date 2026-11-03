"""SourceCache: the read-through layer the providers consult (cache plan §2.2).

A provider asks get(part) before a slow call and put(part, value) after it; with no cache
attached (--no-cache) it simply calls the cluster, so both paths run the same code on the
same data. Parts are read lazily from the store, after the manager has dropped the stale
ones; puts are kept in memory and written by flush().

  sources/addons                       the icpdata_addon configmaps (name, rv, sha, the two data keys)
  sources/zen_ext/<point>              zen extensions API items (service_provisioning)
  sources/crd_for/<addon_type>         which CRD an add-on's custom_resource_kind resolved to
  sources/crd/<plural.group>           a trimmed CRD (the served version only)
  sources/s4/<addon_type>/<zen_id>     zen-stored create parameters, secrets redacted
"""

from __future__ import annotations

import threading

from .store import CacheStore, dumps, sha

CM_KEYS = ("add-ons.json", "extensions")
CRD_VERSION_KEYS = ("name", "served", "storage", "schema", "subresources", "additionalPrinterColumns")


def trim_crd(crd: dict | None) -> dict | None:
    """Everything discovery reads from a CRD: names, scope and the served version (lossless for
    type_from_crd, walk_crd and the status columns), without the other versions or status."""
    if not crd:
        return crd
    from ..discovery.schema_walk import served_version
    meta, spec = crd.get("metadata") or {}, crd.get("spec") or {}
    v = served_version(crd)
    return {"metadata": {"name": meta.get("name"), "resourceVersion": meta.get("resourceVersion")},
            "spec": {"group": spec.get("group"), "names": spec.get("names") or {}, "scope": spec.get("scope"),
                     "versions": [{k: v[k] for k in CRD_VERSION_KEYS if k in v}] if v else []}}


def trim_cm(cm: dict) -> dict:
    meta = cm.get("metadata") or {}
    data = {k: v for k, v in (cm.get("data") or {}).items() if k in CM_KEYS}
    return {"name": meta.get("name"), "rv": meta.get("resourceVersion", ""), "sha": sha(dumps(data))[:16],
            "data": data}


def cms_from_part(part: dict) -> list[dict]:
    return [{"metadata": {"name": c["name"], "resourceVersion": c.get("rv", "")}, "data": c.get("data") or {}}
            for c in part.get("cms") or []]


class SourceCache:
    def __init__(self, store: CacheStore | None = None):
        self.store = store
        self._lock = threading.Lock()
        self._mem: dict[str, object] = {}
        self._dirty: dict[str, tuple[object, str, float | None]] = {}
        self._dropped: set[str] = set()
        self.hits: list[str] = []
        self.misses: list[str] = []

    def get(self, part: str):
        with self._lock:
            if part in self._mem:
                return self._mem[part]
            if part in self._dropped:
                self.misses.append(part)
                return None
        obj = self.store.read(part) if self.store else None
        with self._lock:
            if obj is None:
                self.misses.append(part)
            else:
                self._mem[part] = obj
                self.hits.append(part)
        return obj

    def put(self, part: str, obj, fp: str = "", took: float | None = None) -> None:
        with self._lock:
            self._mem[part] = obj
            self._dirty[part] = (obj, fp, took)
            self._dropped.discard(part)

    def drop(self, part: str) -> None:
        with self._lock:
            self._mem.pop(part, None)
            self._dirty.pop(part, None)
            self._dropped.add(part)
        if self.store:
            self.store.drop(part)

    def drop_prefix(self, prefix: str) -> list[str]:
        names = set(self.store.parts() if self.store else []) | {p for p in list(self._mem) if p.startswith(prefix)}
        gone = sorted(p for p in names if p.startswith(prefix))
        for p in gone:
            self.drop(p)
        return gone

    def names(self, prefix: str) -> list[str]:
        """Parts under a prefix that exist (store or memory), without reading them."""
        with self._lock:
            mem = {p for p in self._mem if p.startswith(prefix)}
            dropped = set(self._dropped)
        stored = {p for p in (self.store.parts() if self.store else []) if p.startswith(prefix)}
        return sorted((mem | stored) - dropped)

    @property
    def dirty(self) -> list[str]:
        with self._lock:
            return sorted(self._dirty)

    def flush(self) -> int:
        """Write the parts put since the last flush; the manifest is saved by the caller."""
        with self._lock:
            pending, self._dirty = self._dirty, {}
        if self.store:
            for part, (obj, fp, took) in pending.items():
                self.store.write(part, obj, fp=fp, took_s=took)
        return len(pending)
