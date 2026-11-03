"""L2 CpdProvider(CrdProvider): Software Hub / CP4D service instances (plan §2, §3, §6).

Types: zen add-ons that can create instances (S2), each linked to its CR kind when the
registry names one. Instances: zen records (cpd-cli service-instance list) joined with the
CRs of that kind through the CR's own zen link (spec.zenServiceInstanceId or label
icpdsupport/serviceInstanceId) -> badges zen+cr / zen-only / cr-only.
Form: S1 extension + S4 (zen-stored create parameters, `service-instance get`) ranked above
the L1 sources (S3 wrapper CR specs, S5 CRD schema); D6 samples only when nothing else
gives a payload shape.
"""

from __future__ import annotations

import threading

from ....common.state import State
from ...discovery.observed import observe
from ...discovery.samples import load_sample
from ...model import Field, FormModel, Instance, InstanceType, Path
from ...timings import span
from ..k8s_crd.cluster import Cluster
from ..k8s_crd.provider import CrdProvider, type_from_crd
from . import extensions, registry
from .cpdcli import CpdCli, CpdCliError

S4_SAMPLE = 3
ZEN_STATE = {"PROVISIONED": State.HEALTHY, "PROVISION_IN_PROGRESS": State.PROGRESS, "PENDING": State.PROGRESS,
             "PROVISIONING": State.PROGRESS, "UPGRADE_IN_PROGRESS": State.PROGRESS, "FAILED": State.FAILING,
             "PROVISION_FAILED": State.FAILING, "DELETING": State.PROGRESS}


def _scalars(x, out: set[str]) -> set[str]:
    if isinstance(x, dict):
        for v in x.values():
            _scalars(v, out)
    elif isinstance(x, list):
        for v in x:
            _scalars(v, out)
    elif x not in (None, "") and not isinstance(x, bool):
        out.add(str(x))
    return out


def zen_link(obj: dict, zen_ids: set[str] | None = None) -> str | None:
    """The zen instance id a CR carries. Where it sits differs per service (spec.zenServiceInstanceId,
    label icpdsupport/serviceInstanceId, status.instance_id), so any spec/status/label/annotation
    value equal to a known zen id counts; without ids, the conventional places are read."""
    meta = obj.get("metadata") or {}
    if zen_ids:
        vals = _scalars([obj.get("spec"), obj.get("status"), meta.get("labels"), meta.get("annotations")], set())
        hits = vals & zen_ids
        return next(iter(hits)) if len(hits) == 1 else None
    v = (obj.get("spec") or {}).get("zenServiceInstanceId") or (meta.get("labels") or {}).get(
        "icpdsupport/serviceInstanceId")
    return str(v) if v not in (None, "") else None


def _prefixed(fields: dict[Path, Field], prefix: Path, source: str) -> dict[Path, Field]:
    out = {}
    for p, f in fields.items():
        f.path = prefix + p
        f.sources = {source}
        f.payload = True
        out[f.path] = f
    return out


class CpdProvider(CrdProvider):
    id = "cpd"

    def __init__(self, cluster: Cluster, namespace: str, cli: CpdCli, **kw):
        super().__init__(cluster, [], namespace, **kw)
        self.cli = cli
        self.zen_ok = True
        self._zen_disabled: str | None = None
        self._zen: list[dict] | None = None
        self._zen_get: dict[tuple[str, str], dict] = {}
        self._addons: dict[str, registry.AddonEntry] | None = None
        self._prov_ext: dict[str, dict] = {}
        self._details_ext: dict[str, dict] = {}
        self._cpd_lock = threading.RLock()            # the add-on registry
        self._zen_lock = threading.RLock()            # zen records + gets: separate, so both load at once
        self.sources = None                           # cache.sources.SourceCache (read-through), or None

    # -- registry / zen ----------------------------------------------------------
    def addons(self) -> dict[str, registry.AddonEntry]:
        with self._cpd_lock:
            if self._addons is None:
                cms = self._addon_cms()
                self._addons, notes = registry.parse_addon_cms(cms)
                self._prov_ext, self._details_ext, notes2 = registry.parse_extensions(cms)
                self.notices.extend(notes + notes2)
                # zen's extensions API is authoritative: add-ons also register forms outside configmaps
                # (Informix's lives only there); configmaps stay the fallback without credentials
                for ext in self._zen_extensions("service_provisioning"):
                    if ext.get("extension_name"):
                        self._prov_ext[ext["extension_name"]] = ext
            return self._addons

    def _addon_cms(self) -> list[dict]:
        from ...cache.sources import cms_from_part, trim_cm
        part = self.sources.get("sources/addons") if self.sources else None
        if part is not None:
            return cms_from_part(part)
        with span("addons (configmaps)"):
            cms = self.cluster.try_list(f"/api/v1/namespaces/{self.namespace}/configmaps",
                                        labelSelector="icpdata_addon=true")
        trimmed = [trim_cm(c) for c in cms]
        if self.sources is not None:
            self.sources.put("sources/addons", {"cms": trimmed})
        return cms_from_part({"cms": trimmed})

    def _zen_extensions(self, point: str) -> list[dict]:
        part = f"sources/zen_ext/{point}"
        hit = self.sources.get(part) if self.sources else None
        if hit is not None:
            return list(hit.get("items") or [])
        try:
            items = self._fetch_zen_extensions(point)
        except Exception as e:
            self.notices.append(f"zen extensions API: {str(e)[:120]}; using the add-on configmaps only")
            return []
        if items is None:
            return []
        if self.sources is not None:                   # a failed call is never cached: retried next run
            self.sources.put(part, {"items": items})
        return items

    @staticmethod
    def _fetch_zen_extensions(point: str) -> list[dict] | None:
        """The zen extensions API (None without CPD_URL / CPD_USERNAME / CPD_APIKEY); raises on failure."""
        from ...subservices.wxd.api import LakehouseAPI, _helpers
        api = LakehouseAPI("")
        if not api.configured:
            return None
        with span(f"zen extensions {point} (sign-in + GET)"):
            h = _helpers()
            hub = h.SoftwareHub.sign_in(api.url, api._user, api_key=api._key, verify=api.verify)
            return list((hub.request(f"/zen-data/v1/extensions?extension_point_id={point}") or {}).get("data")
                        or [])

    def revalidate_zen_extensions(self, point: str = "service_provisioning") -> bool | None:
        """V-C2: forms registered only through the zen API (Informix) can change while no configmap does.
        Re-read them, bypassing the cache. True = changed (cached anew; the registry is re-read on next
        use), False = unchanged, None = nothing cached or the API not reachable."""
        from ...cache.store import dumps
        part = f"sources/zen_ext/{point}"
        cached = self.sources.get(part) if self.sources else None
        if cached is None:
            return None
        try:
            live = self._fetch_zen_extensions(point)
        except Exception:
            return None
        if live is None or dumps(live) == dumps(cached.get("items") or []):
            return None if live is None else False
        self.sources.put(part, {"items": live})
        with self._cpd_lock:
            self._addons = None
        return True

    def seed_zen(self, records: list[dict] | None) -> None:
        """Zen records the profile preflight already listed (the same cpd-cli call): no second list."""
        if records is None:
            return
        with self._zen_lock:
            if self._zen is None and not self._zen_disabled:
                self._zen = self._in_namespace(records)
                self.zen_ok = True

    def _in_namespace(self, records: list[dict]) -> list[dict]:
        return [r for r in records if not self.namespace or r.get("namespace") in (None, "", self.namespace)]

    def zen_records(self) -> list[dict]:
        with self._zen_lock:
            if self._zen is None:
                try:
                    with span("zen records (cpd-cli list)"):
                        recs = self.cli.list_instances()
                    self._zen = self._in_namespace(recs)
                    self.zen_ok = True
                except (CpdCliError, OSError, ValueError) as e:
                    self._zen, self.zen_ok = [], False
                    self.notices.append(f"zen records unavailable ({str(e)[:160]}); showing CRs only")
            return self._zen

    def zen_get(self, name: str, service_type: str) -> dict:
        key = (name, service_type)
        with self._zen_lock:
            if key not in self._zen_get:
                try:
                    with span(f"s4 get {service_type}/{name}"):
                        self._zen_get[key] = self.cli.get_instance(name, service_type)
                except (CpdCliError, OSError, ValueError) as e:
                    self._zen_get[key] = {}
                    self.notices.append(f"service-instance get {name}: {str(e)[:120]}")
            return self._zen_get[key]

    def disable_zen(self, reason: str) -> None:
        """Profile not usable: show CRs only, mutations stay blocked (survives refresh until enable_zen)."""
        with self._zen_lock:
            self._zen_disabled = reason
            self._zen, self.zen_ok = [], False
            self.notices.append(f"zen records unavailable ({reason})")

    def enable_zen(self) -> None:
        """The profile works again (repaired): read zen records on the next discovery."""
        with self._zen_lock:
            self._zen_disabled = None
            self._zen, self.zen_ok = None, True

    def refresh_instances(self) -> None:
        super().refresh_instances()
        with self._zen_lock:
            if self.zen_ok:
                self._zen = None

    def refresh(self) -> None:
        super().refresh()
        with self._cpd_lock:
            self._addons = None
        with self._zen_lock:
            self._zen = None
            self._zen_get.clear()
            if self._zen_disabled:                          # still no usable profile: keep showing CRs only
                self._zen, self.zen_ok = [], False
                self.notices.append(f"zen records unavailable ({self._zen_disabled})")

    # -- types ---------------------------------------------------------------------
    def _crd_for(self, entry: registry.AddonEntry) -> tuple[dict | None, str | None]:
        """The add-on's CRD, read through the cache (`sources/crd_for/<addon>` names it)."""
        from ...cache.codec import crd_name
        if not entry.cr_kind:
            return None, None
        part = f"sources/crd_for/{entry.addon_type}"
        hit = self.sources.get(part) if self.sources else None
        if hit is not None:
            crd = self.cluster.get_crd(hit["crd"]) if hit.get("crd") else None
            if crd is not None or not hit.get("crd"):
                return crd, hit.get("note")
        crd, note = self._resolve_crd(entry)
        if self.sources is not None:
            self.sources.put(part, {"kind": entry.cr_kind, "crd": crd_name(crd), "note": note})
        return crd, note

    def _resolve_crd(self, entry: registry.AddonEntry) -> tuple[dict | None, str | None]:
        cands = self.cluster.find_crds(entry.cr_kind)
        if len(cands) == 1:
            return cands[0], None
        for c in cands:   # several CRDs share the kind: the one whose CRs carry zen links
            it = type_from_crd(c)
            if any(zen_link(o) for o in self.cluster.try_list(it.list_path(self.namespace))):
                return c, None
        return None, (f"custom_resource_kind {entry.cr_kind}: " +
                      ("no CRD" if not cands else f"{len(cands)} CRDs, none with zen-linked CRs"))

    def discover_types(self) -> list[InstanceType]:
        with span("discover_types"):
            return self._discover_types()

    def _discover_types(self) -> list[InstanceType]:
        # independent sources at once: zen records (cpd-cli, ~1.5 s), the add-on configmaps, the API index
        # (the index only when the add-on -> CRD links aren't cached)
        from concurrent.futures import ThreadPoolExecutor
        cached = self.sources is not None and self.sources.get("sources/addons") is not None
        with ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(self.zen_records), pool.submit(self.addons)]
            if not cached:
                futures.append(pool.submit(self.cluster.index))
            for f in futures:
                f.result()
        addons = self.addons()
        zen_types = {r.get("service_type") for r in self.zen_records()}
        out: list[InstanceType] = []
        for at, entry in sorted(addons.items()):
            capable = entry.instance_capable or (entry.extension_name in self._prov_ext)
            if not capable:
                continue
            crd, note = self._crd_for(entry)
            status = f".status.{entry.status_field}" if entry.status_field else None
            if crd:
                it = type_from_crd(crd, key=f"cpd:{at}", display=at, provider="cpd", status_path=status)
            else:
                it = InstanceType(key=f"cpd:{at}", display=at, group="", version="", kind="", plural="",
                                  provider="cpd")
            if note:
                it.notices.append(note)
            it.max_instances = entry.max_instances
            it.versions = entry.versions
            it.meta = {"addon": entry}
            out.append(it)
        for st in sorted(t for t in zen_types - set(addons) if t):
            out.append(InstanceType(key=f"cpd:{st}", display=st, group="", version="", kind="", plural="",
                                    provider="cpd", creatable=False,
                                    notices=["zen records only; the add-on registry has no provisioning entry"]))
        return out

    def known_versions(self, itype: InstanceType) -> set[str]:
        return set(itype.versions)

    # -- instances -------------------------------------------------------------------
    def list_instances(self, itype: InstanceType) -> list[Instance]:
        with span(f"list {itype.display}"):
            return self._list_instances(itype)

    def _list_instances(self, itype: InstanceType) -> list[Instance]:
        at = itype.key.split(":", 1)[1]
        zen = [r for r in self.zen_records() if r.get("service_type") == at]
        crs = [self.instance_from(itype, o) for o in self.cluster.try_list(itype.list_path(self.namespace))] \
            if itype.crd else []
        by_id = {str(r.get("id")): r for r in zen}
        out: list[Instance] = []
        seen: set[str] = set()
        for inst in crs:
            zid = zen_link(inst.obj, set(by_id))
            rec = by_id.get(zid) if zid else None
            if rec:
                seen.add(zid)
                inst.badges.append("zen+cr")
                inst.display_name = rec.get("display_name")
                inst.meta = {"zen": rec}
                zstate = ZEN_STATE.get(str(rec.get("provision_status", "")).upper())
                if zstate == State.FAILING and inst.state.severity > State.FAILING.severity:
                    inst.state, inst.reason = zstate, f"zen: {rec.get('provision_status')}"
            else:
                inst.badges.append("cr-only" if self.zen_ok else "zen?")
            out.append(inst)
        for zid, rec in by_id.items():
            if zid in seen:
                continue
            st = ZEN_STATE.get(str(rec.get("provision_status", "")).upper(), State.INACTIVE)
            out.append(Instance(type_key=itype.key, name=rec.get("display_name", zid), namespace=rec.get("namespace"),
                                uid="", obj={}, state=st, reason=f"zen: {rec.get('provision_status')}",
                                badges=["zen-only"] if itype.crd else [], display_name=rec.get("display_name"),
                                meta={"zen": rec}))
        self._attach_rollouts(out)
        return out

    def _attach_rollouts(self, insts: list[Instance]) -> None:
        """The dot follows the instance's rollout (rollout.py: its CR, its labelled workloads, zen),
        never zen's provision_status alone. The lists are cached until the next instance refresh."""
        from ... import rollout
        snaps: dict[str, rollout.Snapshot | None] = {}
        for inst in insts:
            rec = inst.meta.get("zen") or {}
            ns = inst.namespace or self.namespace
            if rec.get("id") is None or not ns:
                continue
            if ns not in snaps:
                try:
                    snaps[ns] = rollout.collect(self.cluster, ns)
                except Exception:               # no rights / API trouble: the zen + CR state stays
                    snaps[ns] = None
            if snaps[ns] is None:
                continue
            try:
                ro = rollout.assess(str(rec["id"]), rec.get("provision_status"), inst.obj or None, snaps[ns],
                                    lambda api, kind, name, ns=ns: self._owner_cr(api, kind, name, ns))
            except Exception:  # noqa: BLE001, S112 - one instance's odd objects never break the list
                continue
            inst.meta["rollout"] = ro
            inst.state, inst.reason = ro.state, ro.reason

    def _owner_cr(self, api: str, kind: str, name: str, namespace: str) -> dict | None:
        path = self.cluster.resource_path(api, kind, namespace)
        if not path:
            return None
        return next((o for o in self.cluster.try_list(path) if (o.get("metadata") or {}).get("name") == name), None)

    # -- form ------------------------------------------------------------------------------
    def zen_params(self, rec: dict, addon_type: str, name: str) -> dict | None:
        """S4: the create parameters zen stored for an instance (a create-time snapshot, so it is
        cached per zen id), secrets redacted right after the cpd-cli call in every mode."""
        from ...cache.redact import redact
        zid = rec.get("id")
        part = f"sources/s4/{addon_type}/{zid}" if zid is not None and self.sources is not None else None
        hit = self.sources.get(part) if part else None
        if hit is not None:
            return hit.get("params")
        got = self.zen_get(rec.get("display_name", name), addon_type)
        params = redact(got["parameters"]) if isinstance(got.get("parameters"), dict) else None
        if got and part:                               # a failed get is never cached
            self.sources.put(part, {"name": rec.get("display_name", name), "params": params})
        return params

    def extra_sources(self, itype: InstanceType, instances: list[Instance]) -> tuple[list, list]:
        entry: registry.AddonEntry | None = itype.meta.get("addon")
        self.addons()                       # the S1 forms (a type may come from the cached catalog)
        above: list[dict[Path, Field]] = []
        if entry and entry.extension_name in self._prov_ext:
            s1, notes = extensions.provisioning_fields(self._prov_ext[entry.extension_name],
                                                       set(self.storage_classes()))
            itype.notices.extend(n for n in notes if n not in itype.notices)
            above.append(s1)
        at = itype.key.split(":", 1)[1]
        params = []
        # S4 only teaches the payload shape: types that can't be created don't need it, and a few
        # instances are enough (each `service-instance get` is a ~1 s cpd-cli run)
        sample = [i for i in instances if i.meta.get("zen")][:S4_SAMPLE] if itype.creatable else []
        for inst in sample:
            rec = inst.meta.get("zen")
            if rec:
                got = self.zen_params(rec, at, inst.name)
                if isinstance(got, dict):
                    params.append(got)
        if params:
            s4, _ = observe(params, source="S4")
            above.append(_prefixed(s4, ("parameters",), "S4"))
        if not above and not any(i.spec for i in instances):
            sample = load_sample(at)
            if sample:
                above.append(sample)
                itype.notices.append(f"no live spec source: using the {next(iter(next(iter(sample.values())).sources))} sample")
            else:
                itype.notices.append("needs a sample: no form extension, no existing instance, no docs/script "
                                     "sample (D6); pass --seed")
        return above, []

    def form_model(self, itype: InstanceType, instances: list[Instance] | None = None,
                   storage: bool = True) -> FormModel:
        fm = super().form_model(itype, instances, storage=storage)
        extensions.attach_presets(fm.fields, fm.notices)
        extensions.reconcile_vocabulary(fm.fields)
        entry: registry.AddonEntry | None = itype.meta.get("addon")
        if entry and entry.name_regex:
            fm.notices.append(f"instance names must match {entry.name_regex}")
        return fm
