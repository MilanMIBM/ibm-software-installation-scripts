"""DiscoveryCache: what is stale, seeding the providers, the build with progress, saving (cache plan §2).

  check()    fingerprint probe + cpd_vars summary diff + code hash -> drop exactly the stale parts
  attach()   the providers read through the remaining sources (sources.py)
  build()    run discovery part by part with weighted progress, save sources + paint snapshot
  snapshot() catalog, models, StorageClass kinds and the last instance list, for an instant paint
  finish()   write what this run fetched, the summary, the manifest and last_used.json
Nothing here talks to cpd-cli itself; only the provider does, through its own guarded wrapper.
"""

from __future__ import annotations

import re
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass, field

from ..model import FormModel, Instance, InstanceType, StorageClassInfo
from ..timings import span
from . import codec
from . import summary as sm
from .codehash import code_hash
from .probe import ProbeResult
from .probe import run as run_probe
from .progress import Part, Progress
from .sources import SourceCache, trim_cm
from .store import CacheStore, scope_name, sha

SUMMARY = "cpd_vars_summary"
LAST_USED = "last_used.json"
# expected seconds per part when no earlier build says otherwise (cache plan §1 baseline)
BASELINE = {"addons": 0.6, "zen_ext": 0.9, "zen": 1.6, "catalog": 0.7, "instances": 0.6, "storage": 0.6,
            "s4": 1.2, "model": 0.15, "graph": 2.2, "needs": 0.3, "subservices": 30.0}
PAINT_PARTS = ("catalog", "storage", "instances")


def model_part(type_key: str) -> str:
    return "models/" + re.sub(r"[^A-Za-z0-9._-]", "_", type_key)


def instances_fp(insts: list[Instance]) -> str:
    return sha(repr(sorted((i.name, i.uid, str((i.meta.get("zen") or {}).get("id")),
                            sha(repr(sorted(_flat(i.spec).items(), key=str)))) for i in insts)))[:16]


def _flat(spec: dict) -> dict:
    from ..discovery.observed import flatten
    return flatten(spec or {})


@dataclass
class Staleness:
    cold: bool = False
    need_build: bool = False
    lines: list[str] = field(default_factory=list)
    changes: list[sm.Change] = field(default_factory=list)
    dropped: list[str] = field(default_factory=list)


@dataclass
class Snapshot:
    types: list[InstanceType]
    notices: list[str]
    models: dict[str, FormModel]
    sc: dict[str, StorageClassInfo]
    instances: dict[str, list[Instance]]
    instances_at: str | None = None
    built_at: str | None = None


class DiscoveryCache:
    def __init__(self, provider, kube, namespace: str | None, *, kinds_key: str | None = None,
                 storage_flags: dict | None = None, operators_ns: str | None = None, root=None,
                 env: dict | None = None):
        self.cpd = hasattr(provider, "addons")
        suffix = "" if kinds_key is None else f"--crd-{sha(kinds_key)[:8]}"
        self.scope = scope_name(kube.host, namespace, suffix)
        self.store = CacheStore(self.scope, root)
        self.sources = SourceCache(self.store)
        self.provider, self.kube, self.namespace = provider, kube, namespace
        self.operators_ns = operators_ns
        self.env = env
        self.storage_flags = storage_flags or {}
        self.probe: ProbeResult | None = None
        self.summary: dict | None = None
        self.stale: Staleness | None = None
        self.built = False
        self.dry = False                 # --check-cache: report what is stale, change nothing
        self.build_notices: list[str] = []

    # -- wiring ------------------------------------------------------------------------------
    def attach(self) -> None:
        from . import subservices
        self.provider.sources = self.sources
        self.provider.cluster.sources = self.sources
        subservices.attach(self.sources)

    def detach(self) -> None:
        from . import subservices
        self.provider.sources = None
        self.provider.cluster.sources = None
        subservices.attach(None)

    # -- staleness ------------------------------------------------------------------------------
    def _drop(self, st: Staleness, *names: str) -> None:
        """Drop parts: a name ending in / is a prefix, anything else one part."""
        for n in names:
            if self.dry:
                gone = [p for p in self.sources.names(n) if n.endswith("/") or p == n]
            elif n.endswith("/"):
                gone = self.sources.drop_prefix(n)
            else:
                gone = [n] if n in self.sources.names(n) else []
                self.sources.drop(n)
            st.dropped += [g for g in gone if g not in st.dropped]

    def drop_all(self) -> Staleness:
        """--rebuild-cache / the R key: everything is rebuilt."""
        st = self.stale or Staleness()
        self._drop_all(st)
        st.need_build = True
        return st

    def _drop_all(self, st: Staleness) -> None:
        self._drop(st, "sources/", "models/", "subservices/", "catalog", "storage", "instances", SUMMARY)

    def check(self, probe: ProbeResult | None = None) -> Staleness:
        """Decide what is stale and drop it (the store keeps the rest). Writes nothing new."""
        st = Staleness()
        store = self.store
        crd_names = [p.split("/", 2)[2] for p in self.sources.names("sources/crd/")]
        self.probe = probe or run_probe(self.kube, self.namespace if self.cpd else None, crd_names,
                                        self.operators_ns if self.cpd else None, addons=self.cpd)
        self.summary = sm.current(self.env, storage_flags=self.storage_flags,
                                  cluster_patch=self.probe.cluster_patch if self.cpd else None)
        last = store.read_root(LAST_USED)
        if isinstance(last, dict) and last.get("scope") not in (None, self.scope):
            moved = [c.text for c in sm.diff(last.get("summary"), self.summary) if "scope" in c.groups]
            if moved:
                st.lines += moved + [f"cache scope {self.scope} (last used: {last.get('scope')})"]
        self.stale = st
        if not store.parts():
            st.cold = st.need_build = True
            st.lines.append(f"no discovery cache yet for this cluster + namespace: building "
                            f"{store.root.name}/{store.scope}")
            return st
        cid = (store.manifest().get("cluster") or {}).get("cluster_id")
        if cid and self.probe.cluster_id and cid != self.probe.cluster_id:
            st.lines.append(f"another cluster answers at this URL (id {cid[:12]} -> {self.probe.cluster_id[:12]}): "
                            "rebuilding everything")
            self._drop_all(st)
            st.cold = st.need_build = True
            return st
        saved = store.read(SUMMARY)
        if saved is None:
            st.lines.append("no cpd_vars summary saved with this cache: rebuilding")
            self._drop(st, "catalog", "models/", "storage")
            st.need_build = True
        changes = sm.diff(saved, self.summary)
        st.changes = changes
        groups = sm.groups_of(changes)
        for c in changes:
            st.lines.append(f"{c.text} (rebuilding {'; '.join(sm.GROUP_WORDS[g] for g in sorted(c.groups))})")
        if "scope" in groups:
            self._drop_all(st)
        if "catalog" in groups:
            self._drop(st, "sources/addons", "sources/zen_ext/", "sources/crd_for/", "catalog", "models/")
        if "storage" in groups:
            self._drop(st, "storage", "models/")
        if "zen_ext" in groups:
            self._drop(st, "sources/zen_ext/", "subservices/wxd/spec")
        if "wxd" in groups:             # (a patch keeps them: they are re-checked by the operator's image digest)
            self._drop(st, "subservices/wxd/facts")
        if changes:
            st.need_build = True
        if store.manifest().get("code_hash") not in (None, code_hash()):
            self._drop(st, "catalog", "models/")
            st.lines.append("discovery code changed: re-deriving the catalog and models from the cached sources")
        if self.cpd and "catalog" not in groups:
            self._check_addons(st)
        for name in crd_names:
            meta = store.meta(f"sources/crd/{name}") or {}
            rv = self.probe.crd_rvs.get(name)
            if rv is None:
                st.lines.append(f"CRD {name} is gone: re-resolving the catalog")
                self._drop(st, f"sources/crd/{name}", "sources/crd_for/", "catalog", "models/")
            elif meta.get("fp") and rv != meta.get("fp"):
                st.lines.append(f"CRD {name} changed (rv {meta.get('fp')} -> {rv})")
                self._drop(st, f"sources/crd/{name}", "catalog", "models/")
        saved_sc = (store.meta("storage") or {}).get("fp")
        if saved_sc and self.probe.sc_hash and saved_sc != self.probe.sc_hash:
            st.lines.append("StorageClasses changed: re-classifying them and every storage need")
            self._drop(st, "storage", "models/")
        return st

    def _check_addons(self, st: Staleness) -> None:
        """rv moved -> compare contents (V-C1): a re-saved configmap with the same data changes nothing."""
        part = self.sources.get("sources/addons")
        if part is None or self.probe.addon_rvs is None:
            return
        cached = {c["name"]: c.get("rv") for c in part.get("cms") or []}
        if cached == self.probe.addon_rvs:
            return
        cms = [trim_cm(c) for c in self.provider.cluster.try_list(
            f"/api/v1/namespaces/{self.namespace}/configmaps", labelSelector="icpdata_addon=true", cache=False)]
        # only what discovery reads counts: instances add labelled configmaps of their own (edb
        # <name>-details, informix <name>-aux-monitoring-cm) whose extensions never change the catalog
        from ..providers.cpd.registry import registry_digest
        old = {c["name"]: d for c in part.get("cms") or [] if (d := registry_digest(c.get("data") or {}))}
        new = {c["name"]: d for c in cms if (d := registry_digest(c.get("data") or {}))}
        moved = sorted(n for n in set(old) | set(new) if old.get(n) != new.get(n))
        if not self.dry:
            self.sources.put("sources/addons", {"cms": cms})
        if not moved:
            n = sum(1 for k in new if cached.get(k) != self.probe.addon_rvs.get(k))
            if n:
                st.lines.append(f"add-on registry: {n} configmap(s) re-saved with the same content")
            return
        st.lines.append(f"add-on registry changed: {', '.join(moved[:4])}{' ...' if len(moved) > 4 else ''}")
        self._drop(st, "sources/crd_for/", "catalog", "models/")
        st.need_build = True

    def missing_paint(self) -> list[str]:
        """Snapshot parts an instant paint needs that aren't cached (the TUI builds them with the bar)."""
        miss = [p for p in ("catalog", "storage") if self.store.read(p) is None]
        cat = self.store.read("catalog")
        for d in (cat or {}).get("types") or []:
            if d.get("creatable", True) and self.store.read(model_part(d["key"])) is None:
                miss.append(model_part(d["key"]))
        return miss

    # -- build ----------------------------------------------------------------------------------
    def _weight(self, key: str, default_key: str | None = None) -> float:
        took = (self.store.manifest().get("build_times") or {}).get(key)
        return float(took or BASELINE.get(default_key or key, 0.5))

    def _hit(self, part: str) -> bool:
        return self.sources.get(part) is not None

    def build(self, sink: Callable[[Progress], None] | None = None, include_subservices: bool | None = None,
              on_types: Callable | None = None, on_instances: Callable | None = None,
              on_sc: Callable | None = None, on_model: Callable | None = None) -> Progress:
        """Discovery, part by part, with weighted progress. Read-through hits finish at once; every
        result is saved as soon as it lands. on_* hand results to the TUI as they arrive."""
        p = self.provider
        before = list(p.notices)
        cpd = self.cpd
        quick = 0.05
        parts: list[Part] = []
        if cpd:
            parts += [Part("addons", "add-on registry", "configmaps",
                           quick if self._hit("sources/addons") else self._weight("addons")),
                      Part("zen_ext", "zen forms", "zen extensions API",
                           quick if self._hit("sources/zen_ext/service_provisioning") else self._weight("zen_ext")),
                      Part("zen", "zen records", "cpd-cli service-instance list",
                           quick if p._zen is not None else self._weight("zen"))]
        cat_cached = self.store.read("catalog")
        n_types = len((cat_cached or {}).get("types") or []) or 6
        parts += [Part("catalog", "catalog", "the add-ons' CRDs", self._weight("catalog")),
                  Part("instances", "instances", "CR lists", self._weight("instances")),
                  Part("storage", "storage classes", "SC + PVC census", self._weight("storage")),
                  Part("models", "field models", "S4 + CRD + specs",
                       self._weight("models") if "models" in (self.store.manifest().get("build_times") or {})
                       else n_types * (BASELINE["s4"] + BASELINE["model"])),
                  Part("graph", "owner graph", "PVCs and their owners", self._weight("graph")),
                  Part("needs", "storage needs", "value-flow + peers", self._weight("needs"))]
        want_sub = include_subservices
        if want_sub is not False:
            parts.append(Part("subservices", "sub-services", "watsonx.data operator + API spec",
                              self._weight("subservices")))
        pr = Progress(parts, sink)
        self.built = True
        if cpd:
            pr.run("addons", p._addon_cms)
            pr.run("zen_ext", lambda: p._zen_extensions("service_provisioning"))
            pr.run("zen", p.zen_records)
        types = pr.run("catalog", p.discover_types) or []
        self.save_types(types, [n for n in p.notices if n not in before])
        if on_types:
            on_types(types, [n for n in p.notices if n not in before])
        insts = pr.run("instances", lambda: {t.key: p.list_instances(t) for t in types}) or {}
        if on_instances:
            on_instances(insts)
        self.save_instances(insts)
        sc = pr.run("storage", p.storage_classes) or {}
        self.save_storage(sc)
        if on_sc:
            on_sc(sc)
        # the models placeholder becomes one part per type, with the same total weight
        holder = pr.part("models")
        todo = [t for t in types if t.creatable or insts.get(t.key)]
        sub = []
        for t in todo:
            s4 = self._s4_missing(t, insts.get(t.key, []))
            w = s4 * self._weight("s4") + BASELINE["model"]
            sub.append(Part(f"model:{t.key}", f"fields {t.display}",
                            f"cpd-cli service-instance get x{s4}" if s4 else "CRD + specs", w))
        scale = (holder.weight / (sum(x.weight for x in sub) or 1.0)) if holder else 1.0
        if sub and holder:
            idx = pr.parts.index(holder)
            for x in sub:
                x.weight *= scale
            pr.parts[idx:idx + 1] = sub
        elif holder:
            pr.skip("models")
        models: dict[str, FormModel] = {}
        for t in todo:
            fm = pr.run(f"model:{t.key}", lambda t=t: self._form(t, insts.get(t.key, [])))
            if isinstance(fm, FormModel):
                models[t.key] = fm
                if on_model:
                    on_model(t.key, fm, False)
        nss = {i.namespace for v in insts.values() for i in v if i.namespace} | (
            {self.namespace} if self.namespace else set())
        pr.run("graph", lambda: p.graph(nss))

        def needs() -> None:
            for key, fm in models.items():
                if hasattr(p, "assess_storage"):
                    p.assess_storage(fm, insts.get(key, []))
                self.save_model(fm, insts.get(key, []))
                if on_model:
                    on_model(key, fm, True)
        pr.run("needs", needs)
        if pr.part("subservices"):
            from . import subservices as warm_sub
            if want_sub or any(warm_sub.applies(t, insts.get(t.key, [])) for t in types):
                pr.run("subservices", lambda: warm_sub.warm(self, types, insts))
            else:
                pr.skip("subservices")
        times = self.store.manifest().setdefault("build_times", {})
        for part in pr.parts:            # the next build's weights (read-through hits don't count)
            if part.took is not None and part.state == "done" and not part.key.startswith("model:") \
                    and part.weight > quick:
                times[part.key] = round(part.took, 3)
        model_s = [x.took for x in pr.parts if x.key.startswith("model:") and x.took is not None]
        if model_s:
            times["models"] = round(sum(model_s), 3)
        self.build_notices = [n for n in p.notices if n not in before]
        p.notices[:] = before            # headless output never shows build-time notices
        pr.finish()
        self.finish()
        return pr

    def _s4_missing(self, t: InstanceType, insts: list[Instance]) -> int:
        if not self.cpd or not t.creatable:
            return 0
        from ..providers.cpd.provider import S4_SAMPLE
        at = t.key.split(":", 1)[1]
        recs = [i.meta.get("zen") for i in insts if i.meta.get("zen")][:S4_SAMPLE]
        return sum(1 for r in recs if r.get("id") is None or not self._hit(f"sources/s4/{at}/{r.get('id')}"))

    def _form(self, t: InstanceType, insts: list[Instance]) -> FormModel:
        p = self.provider
        try:
            return p.form_model(t, insts, storage=False)
        except TypeError:                    # a provider without the two-phase signature
            return p.form_model(t, insts)

    # -- snapshot -----------------------------------------------------------------------------
    def save_types(self, types: list[InstanceType], notices: list[str]) -> None:
        self.store.write("catalog", {"types": [codec.enc_type(t) for t in types], "notices": notices})

    def save_instances(self, insts: dict[str, list[Instance]]) -> None:
        self.store.write("instances", {"items": [codec.enc_instance(i) for v in insts.values() for i in v],
                                       "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")})

    def save_storage(self, sc: dict[str, StorageClassInfo]) -> None:
        if sc:
            self.store.write("storage", {"classes": codec.enc_sc_map(sc)}, fp=(self.probe.sc_hash or "")
                             if self.probe else "")

    def save_model(self, fm: FormModel, insts: list[Instance]) -> None:
        self.store.write(model_part(fm.type_key), {"model": codec.enc_model(fm, redact=True),
                                                   "instances_fp": instances_fp(insts)})

    def snapshot(self) -> Snapshot | None:
        """Everything an instant paint needs, decoded; None without a catalog."""
        with span("cache snapshot"):
            cat = self.store.read("catalog")
            if cat is None:
                return None
            types = [codec.dec_type(d, lambda n: self.sources.get(f"sources/crd/{n}")) for d in cat.get("types") or []]
            models = {}
            for t in types:
                m = self.store.read(model_part(t.key))
                if m:
                    models[t.key] = codec.dec_model(m["model"])
            sc_part = self.store.read("storage")
            inst_part = self.store.read("instances") or {}
            insts: dict[str, list[Instance]] = {t.key: [] for t in types}
            for d in inst_part.get("items") or []:
                insts.setdefault(d["type_key"], []).append(codec.dec_instance(d))
            return Snapshot(types, list(cat.get("notices") or []), models,
                            codec.dec_sc_map(sc_part["classes"]) if sc_part else {}, insts,
                            inst_part.get("at"), (self.store.meta("catalog") or {}).get("built_at"))

    # -- persist ------------------------------------------------------------------------------
    def gc_s4(self) -> list[str]:
        """Drop the S4 parameters of zen instances that are gone (only with a good zen list)."""
        p = self.provider
        recs = getattr(p, "_zen", None)
        if not self.cpd or recs is None or not getattr(p, "zen_ok", False):
            return []
        live = {str(r.get("id")) for r in recs}
        gone = [n for n in self.sources.names("sources/s4/") if n.rsplit("/", 1)[-1] not in live]
        for n in gone:
            self.sources.drop(n)
        return gone

    def finish(self) -> None:
        """Write this run's new sources, the summary, the manifest and last_used.json."""
        if self.summary is None:
            return
        self.gc_s4()
        self.sources.flush()
        st = self.stale
        if self.built or not (st and st.need_build):
            self.store.write(SUMMARY, self.summary)
        self.store.set_info(code_hash=code_hash(),
                            cluster={"api_url": self.kube.host,
                                     "cluster_id": self.probe.cluster_id if self.probe else None},
                            storage_flags=self.storage_flags, namespace=self.namespace)
        self.store.save_manifest()
        self.store.write_root(LAST_USED, {"scope": self.scope, "summary": self.summary})

    # -- reports ---------------------------------------------------------------------------------
    def describe(self) -> list[str]:
        """--check-cache: one line per cached part with its age."""
        out = [f"cache {self.store.dir}"]
        for name in self.store.parts():
            meta = self.store.meta(name) or {}
            out.append(f"  {name:<52} {meta.get('built_at', '')}")
        return out


def log_lines(lines: list[str], stream=None) -> None:
    stream = stream or sys.stderr
    for ln in lines:
        print(f"[cache] {ln}", file=stream)
