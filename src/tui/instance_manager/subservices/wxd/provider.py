"""watsonx.data engines and services (sub-plan §4): every type the lakehouse API can create.

Everything per type is discovered:
  - types: the lakehouse v3 API's embedded spec (subservices/embedded_spec.py): every top-level
    `/<name>_engines` or `/<name>_services` collection; creatable when it has a POST
  - create form: that POST's request schema (`*Prototype`: required, enums, examples), with
    current values from the existing engines of the type (GET of the collection)
  - starter template + resize: when the request has no sizing fields of its own (presto,
    prestissimo), the operator's scale presets (/opt/ansible/config/scale/<size>.yaml, the
    meaning of each `size_config` value) and its documented customization fields
    (`<component>_replicas`, `<component>_resources_{requests,limits}_{cpu,memory}`) add per-
    component sizes; anything changed from the preset is patched onto the WxdEngine CR after
    the engine is registered (a CR made by hand is invisible to watsonx.data)
Adapter knowledge only: the API base path, its AuthInstanceId header and the parent kind.
"""

from __future__ import annotations

import json
import os
import time

from ....common.state import State
from ...discovery import roles
from ...discovery.observed import flatten
from ...discovery.openapi import body_from, inline, prototype_fields
from ...model import Evidence, Field, FormModel, Instance, InstanceType, Path, Role
from ...ops import payload as pl
from ...ops.plan import ActionPlan, Log, Step
from ...providers.k8s_crd.provider import type_from_crd
from ..base import Match, SubServiceProvider
from ..embedded_spec import find_spec
from .api import BASE, LakehouseAPI
from .operator import OperatorFacts

PARENT_KIND = "Wxd"
ENGINE_KIND = "WxdEngine"
CUSTOMIZATION_TASK = "/opt/ansible/roles/wxdEngine/tasks/get_engine_customization.yaml"
MERGE_PATCH = "application/merge-patch+json"
RESIZE_STEP = "resize (operator, after create)"
WHAT_ROLE = {"replicas": Role.REPLICAS, "cpu": Role.CPU, "memory": Role.MEMORY}


def api_state(status: str | None) -> State:
    s = (status or "").lower()
    if "run" in s:
        return State.HEALTHY
    if any(t in s for t in ("fail", "error")):
        return State.FAILING
    if any(t in s for t in ("stop", "paus", "suspend")):
        return State.INACTIVE
    return State.PROGRESS if s else State.INACTIVE


def component_values(scale: dict, comps: list[str]) -> dict[str, str]:
    """An operator preset -> resize-form values for the given components (operator format)."""
    out = {}
    for c in comps:
        node = scale.get(c) or {}
        req = ((node.get("resources") or {}).get("requests") or {})
        if node.get("replicas") is not None:
            out[f"{c}_replicas"] = str(node["replicas"])
        if req.get("cpu") is not None:
            out[f"{c}_cpu"] = str(req["cpu"])
        if req.get("memory") is not None:
            out[f"{c}_memory"] = str(req["memory"])
    return out


def preset_values(scale: dict) -> dict[str, str]:
    """Presto's coordinator + worker values (kept for callers and tests)."""
    vals = component_values(scale, ["presto_coordinator", "presto_worker"])
    vals.pop("presto_coordinator_replicas", None)
    return vals


class WxdEngines(SubServiceProvider):
    id = "wxd-engines"
    display_name = "watsonx.data engines"

    def __init__(self, cluster, operator_ns: list[str] | None = None):
        self.cluster = cluster
        self.operator_ns = operator_ns or [n for n in (os.environ.get("PROJECT_CPD_INST_OPERATORS"),) if n]
        self.facts: OperatorFacts | None = None
        self.notices: list[str] = []
        self.namespace: str | None = None
        self.spec: dict | None = None
        self._api: dict[str, LakehouseAPI] = {}
        self._crd: dict | None = None

    # -- matching / plumbing -------------------------------------------------------------
    def matches(self, parent_type: InstanceType, parent: Instance) -> Match | None:
        if parent_type.kind != PARENT_KIND:
            return None
        if not parent.meta.get("zen") and not parent.spec.get("zenServiceInstanceId"):
            return Match(False, "the watsonx.data instance has no zen id yet")
        if not LakehouseAPI("").configured:
            return Match(False, "CPD_URL / CPD_USERNAME / CPD_APIKEY are not set (cpd_instance_details.sh)")
        return Match(True)

    def bind(self, parent: Instance) -> None:
        self.parent = parent
        self.namespace = parent.namespace
        if self.facts is None:
            self.facts = OperatorFacts(self.cluster.kube, self.operator_ns or [parent.namespace or ""], ENGINE_KIND)
        if self.spec is None:
            self.spec = find_spec(self.cluster.kube, parent.namespace or "", BASE) or {}
            if not self.spec:
                self.notices.append("the lakehouse API spec was not found; engine types can't be discovered")

    def api(self) -> LakehouseAPI:
        zid = str((self.parent.meta.get("zen") or {}).get("id") or self.parent.spec.get("zenServiceInstanceId"))
        if zid not in self._api:
            self._api[zid] = LakehouseAPI(zid)
        return self._api[zid]

    def engine_crd(self) -> dict | None:
        if self._crd is None:
            self._crd = self.cluster.find_crd(ENGINE_KIND) or {}
        return self._crd or None

    def refresh_instances(self) -> None:
        self.cluster.drop_lists()

    def storage_classes(self):
        return {}

    # -- the spec -------------------------------------------------------------------------
    def collections(self) -> dict[str, dict]:
        """kind -> {collection, get, post, delete}: every top-level /<x>_engines | /<x>_services collection."""
        paths = (self.spec or {}).get("paths") or {}
        out = {}
        for path, ops in paths.items():
            name = path.strip("/")
            if "/" in name or not (name.endswith("_engines") or name.endswith("_services")) or "get" not in ops:
                continue
            item = next((o for p, o in paths.items() if p.startswith(f"/{name}/{{") and p.count("/") == 2), {})
            out[name.rsplit("_", 1)[0]] = {"collection": name, "get": ops.get("get"), "post": ops.get("post"),
                                           "delete": item.get("delete")}
        return dict(sorted(out.items()))

    def request_schema(self, kind: str) -> dict:
        post = (self.collections().get(kind) or {}).get("post") or {}
        body = next((p for p in post.get("parameters") or [] if p.get("in") == "body"), None)
        return inline((body or {}).get("schema") or {}, (self.spec or {}).get("definitions") or {})

    def itype(self, kind: str) -> InstanceType:
        crd = self.engine_crd()
        label = kind.replace("_", " ")
        it = type_from_crd(crd, key=f"wxd:{kind}", display=label, provider=self.id) if crd else \
            InstanceType(key=f"wxd:{kind}", display=label, group="", version="", kind="", plural="", provider=self.id)
        it.status_path = ".status.engineStatus"
        it.creatable = bool((self.collections().get(kind) or {}).get("post"))
        return it

    def kinds(self) -> list[tuple[str, int | None]]:
        return [(kind, len(self._rows(kind))) for kind in self.collections()]

    def _rows(self, kind: str) -> list[dict]:
        coll = (self.collections().get(kind) or {}).get("collection")
        if not coll:
            return []
        try:
            data = self.api().request("GET", f"/{coll}")
        except Exception:
            return []
        return list((data or {}).get(coll) or [])

    def _crs(self) -> list[dict]:
        crd = self.engine_crd()
        return self.cluster.try_list(type_from_crd(crd).list_path(self.namespace)) if crd else []

    # -- listing ----------------------------------------------------------------------------
    def list_instances(self, itype: InstanceType) -> list[Instance]:
        kind = itype.key.split(":", 1)[1]
        crs = {(c.get("spec") or {}).get("engineName"): c for c in self._crs()}
        out = []
        for r in self._rows(kind):
            eid = r.get("id") or r.get("engine_id") or r.get("service_id")
            cr = crs.pop(eid, None)
            st = api_state(r.get("status"))
            reason = f"api: {r.get('status')}"
            if cr is not None:
                eng = str((cr.get("status") or {}).get("engineStatus") or "")
                reason += f", operator: {eng or '?'}"
                if "fail" in eng.lower():
                    st = State.FAILING
                elif st == State.HEALTHY and eng and "complet" not in eng.lower():
                    st = State.SCALING
            out.append(Instance(itype.key, (cr or {}).get("metadata", {}).get("name") or r.get("display_name", eid),
                                self.namespace, (cr or {}).get("metadata", {}).get("uid", ""), cr or {}, st, reason,
                                badges=["api+cr" if cr else "api"], display_name=r.get("display_name"),
                                meta={"engine": r, "engine_id": eid}))
        for eid, cr in crs.items():
            if (cr.get("spec") or {}).get("type") == kind:
                out.append(Instance(itype.key, cr["metadata"]["name"], self.namespace, cr["metadata"]["uid"], cr,
                                    State.INACTIVE, "CR without a lakehouse engine (invisible to watsonx.data)",
                                    badges=["cr-only"], display_name=(cr.get("spec") or {}).get("engineDisplayName"),
                                    meta={"engine_id": eid}))
        return out

    # -- form -----------------------------------------------------------------------------
    def _documented(self) -> set[str]:
        return self.facts.documented_fields(CUSTOMIZATION_TASK) if self.facts else set()

    def components(self, kind: str) -> list[str]:
        """Operator preset components of this engine type that the operator lets you size."""
        presets = self.facts.presets() if self.facts else {}
        doc = self._documented()
        names = {c for p in presets.values() for c in p if c.startswith(f"{kind}_")}
        return sorted(c for c in names if any(f"{c}_{x}" in doc for x in
                                              ("replicas", "resources_requests_cpu", "resources_requests_memory")))

    def form_model(self, itype: InstanceType) -> FormModel:
        kind = itype.key.split(":", 1)[1]
        fm = FormModel(itype.key)
        schema = self.request_schema(kind)
        if not schema:
            fm.notices.append(f"no create request in the lakehouse API spec for {kind}")
            return fm
        fields = prototype_fields(schema, (self.spec or {}).get("definitions") or {})
        fields.pop(("parameters", "display_name"), None)        # the form's own Name field
        # current values from existing engines of the type (what works on this cluster)
        flats = [flatten(r) for r in self._rows(kind)]
        for p, f in fields.items():
            vals = [fl.get(p[1:]) for fl in flats if fl.get(p[1:]) is not None]
            f.observed = vals
            if vals and not isinstance(vals[-1], (dict, list)) and f.required:
                f.default = vals[-1]
        roles.infer_all(fields, roles.RoleContext())
        api_sizes = any(f.role in (Role.REPLICAS, Role.CPU, Role.MEMORY) and "quantity" not in f.path[-1]
                        for f in fields.values())
        size = next((f for f in fields.values() if f.role == Role.SIZE_PRESET), None)
        comps = [] if api_sizes else self.components(kind)
        presets = self.facts.presets() if self.facts else {}
        if size is not None and size.enum:
            size.presets = []
            for v in size.enum:
                meta = component_values(presets[v], comps) if v in presets else {}
                for p in fields:                               # API quantities follow the preset too
                    seg = p[-2] if len(p) > 2 else ""
                    if p[-1] == "quantity" and f"{kind}_{seg}" in presets.get(v, {}):
                        meta[".".join(p[1:])] = str(presets[v][f"{kind}_{seg}"].get("replicas", ""))
                worker = presets.get(v, {}).get(f"{kind}_worker") or {}
                req = (worker.get("resources") or {}).get("requests") or {}
                size.presets.append({"value": v, "label": v, "metadata": meta, "cpu": req.get("cpu"),
                                     "memory": req.get("memory")})
            size.description = (size.description + " - " if size.description else "") + \
                "the starter template: choosing one fills in the sizes, which stay editable"
        start_name = str(size.default) if size and size.default is not None else "small"
        start_meta = next((p["metadata"] for p in (size.presets or []) if p["value"] == start_name), {}) if size else {}
        for p, f in fields.items():                           # the default template fills the API sizes too
            if ".".join(p[1:]) in start_meta and not f.observed:
                f.default = start_meta[".".join(p[1:])]
        start = component_values(presets.get(start_name, {}), comps)
        doc = self._documented()
        order = 1000
        for c in comps:
            for what in ("replicas", "cpu", "memory"):
                key = f"{c}_{what}"
                if what == "replicas" and key not in doc:
                    continue
                f = Field(path=("parameters", key), type="integer" if what == "replicas" else "quantity",
                          role=WHAT_ROLE[what], label=f"{c.replace('_', ' ')} {what}"
                          + ("" if what == "replicas" else " (request = limit)"), default=start.get(key),
                          step=RESIZE_STEP, order=order, payload=True, minimum=1 if what == "replicas" else None,
                          sources={"operator"})
                f.role_evidence = Evidence("operator", f"documented customization field of {c}", 0.9)
                order += 1
                fields[f.path] = f
        if comps:
            fm.notices.append(f"sizes of {', '.join(comps)} come from the operator presets; values that differ "
                              "from the chosen size are applied to the WxdEngine CR after it registers")
        fm.fields = fields
        return fm

    # -- plans ------------------------------------------------------------------------------
    @staticmethod
    def _cr_keys(key: str) -> list[str]:
        comp, what = key.rsplit("_", 1)
        if what == "replicas":
            return [key]
        return [f"{comp}_resources_requests_{what}", f"{comp}_resources_limits_{what}"]

    def _find_cr(self, engine_id: str, timeout: int, log: Log) -> dict | None:
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            self.cluster.drop_lists()
            for c in self._crs():
                if (c.get("spec") or {}).get("engineName") == engine_id:
                    return c
            log(f"  waiting for the WxdEngine CR of {engine_id} ({int(time.monotonic() - t0)}s / {timeout}s)")
            time.sleep(5)
        return None

    def _watch(self, itype: InstanceType, engine_id: str, workers: int | None, log: Log, timeout: int = 40 * 60,
               on_update=None) -> bool:
        t0, last = time.monotonic(), None
        while True:
            el = int(time.monotonic() - t0)
            insts = self.list_instances(itype)
            if on_update:
                on_update(insts)
            inst = next((i for i in insts if i.meta.get("engine_id") == engine_id), None)
            ready = want = None
            if inst and inst.uid and workers is not None:
                for s in self.cluster.try_list(f"/apis/apps/v1/namespaces/{self.namespace}/statefulsets", cache=False):
                    refs = (s.get("metadata") or {}).get("ownerReferences") or []
                    if any(r.get("uid") == inst.uid for r in refs) and "worker" in s["metadata"]["name"]:
                        want = (s.get("spec") or {}).get("replicas")
                        ready = (s.get("status") or {}).get("readyReplicas") or 0
            line = (inst.reason if inst else "not listed yet") + (f", workers {ready}/{want}" if want is not None
                                                                  else "")
            if line != last or el % 60 < 15:
                log(f"  [{el // 60}m{el % 60:02d}s / {timeout // 60}m] {line}")
                last = line
            if inst is not None and inst.state == State.HEALTHY and (
                    workers is None or (want == workers and ready == workers)):
                return True
            if el >= timeout:
                log(f"  gave up waiting after {timeout // 60}m (it may still finish)")
                return False
            time.sleep(15)

    def _patch(self, cr: dict, spec: dict, log: Log) -> None:
        path = f"{type_from_crd(self.engine_crd()).list_path(self.namespace)}/{cr['metadata']['name']}"
        body = {"spec": spec}
        self.cluster.kube.send("PATCH", path, body, content_type=MERGE_PATCH, dryRun="All")
        log("  server-side dry-run passed")
        self.cluster.kube.send("PATCH", path, body, content_type=MERGE_PATCH)
        log(f"  patched {cr['metadata']['name']}: " + " ".join(f"{k}={v}" for k, v in spec.items()))

    def plan_create(self, itype: InstanceType, fm: FormModel, values: dict[Path, object], name: str,
                    on_update=None) -> ActionPlan:
        kind = itype.key.split(":", 1)[1]
        coll = (self.collections().get(kind) or {}).get("collection", "")
        plan = ActionPlan(op="create", target=f"{kind} {name}", type_key=itype.key)
        if not itype.creatable:
            plan.errors.append(f"the lakehouse API has no create operation for {kind}")
        if not name:
            plan.errors.append("name is required")
        if name and name in [i.display_name for i in self.list_instances(itype)]:
            plan.errors.append(f"{kind} {name} already exists")
        for f in fm.fields.values():
            v = values.get(f.path)
            if f.required and (v is None or v == "") and f.step != RESIZE_STEP:
                plan.errors.append(f"{f.label or f.key} is required")
            elif f.enum and v not in (None, "") and str(v) not in map(str, f.enum):
                plan.errors.append(f"{f.label or f.key}: {v} is not one of {', '.join(map(str, f.enum))}")
            if f.role == Role.REPLICAS and v not in (None, "") and f.minimum is not None:
                try:
                    if int(v) < f.minimum:
                        plan.errors.append(f"{f.label or f.key} must be at least {f.minimum}")
                except ValueError:
                    plan.errors.append(f"{f.label or f.key}: {v} is not a number")
        body = body_from(fm.fields, values, pl.coerce, exclude_steps=(RESIZE_STEP,))
        body["display_name"] = name
        size = next((f for f in fm.fields.values() if f.role == Role.SIZE_PRESET), None)
        chosen = str(values.get(size.path)) if size else ""
        preset = next((p["metadata"] for p in (size.presets or []) if p["value"] == chosen), {}) if size else {}
        custom: dict[str, str] = {}
        for f in fm.fields.values():
            if f.step != RESIZE_STEP or values.get(f.path) in (None, ""):
                continue
            key = f.path[-1]
            changed = str(values[f.path]) != str(preset.get(key))
            plan.summary.append(f"{f.label}: {values[f.path]}" + (f"  (changed from {chosen}: {preset.get(key, '-')})"
                                                                  if changed else ""))
            if changed:
                for ck in self._cr_keys(key):
                    custom[ck] = str(values[f.path])
        workers = None
        for p, v in values.items():
            if p[-1].endswith("worker_replicas") and v not in (None, ""):
                try:
                    workers = int(v)
                except ValueError:
                    pass
        plan.summary.insert(0, f"watsonx.data instance {self.parent.display_name or self.parent.name}"
                            + (f", size {chosen}" if chosen else ""))
        state: dict = {}

        def register(log: Log) -> None:
            try:
                res = self.api().request("POST", f"/{coll}", body)
                state["id"] = (res or {}).get("id") or (res or {}).get("engine_id") or (res or {}).get("service_id")
            except Exception as e:
                log(f"  the create call answered {e}; checking whether it exists")
            if not state.get("id"):
                state["id"] = next((r.get("id") for r in self._rows(kind) if r.get("display_name") == name), None)
            if not state.get("id"):
                raise RuntimeError(f"{kind} {name} was not created")
            log(f"  registered {state['id']}")

        def resize(log: Log) -> None:
            cr = self._find_cr(state["id"], 180, log)
            if cr is None:
                raise RuntimeError(f"no WxdEngine CR with engineName {state['id']} after 180s")
            self._patch(cr, custom, log)

        plan.steps = [Step(f"POST {BASE}/{coll}", register, preview=json.dumps(body, indent=2),
                           dry_run="none: the lakehouse API has no dry-run")]
        if custom:
            plan.steps.append(Step("resize the WxdEngine CR to the values changed from the template", resize,
                                   preview=json.dumps({"spec": custom}, indent=2),
                                   dry_run="server-side, right before the patch (the CR exists only after step 1)"))
            plan.warnings.append(f"the operator may start on the {chosen} template sizes for a few minutes before "
                                 "the resize lands")
        plan.steps.append(Step("watch until running" + (f" with {workers} ready worker(s)" if custom and workers
                                                        else "") + " (40m limit)",
                               lambda log: self._watch(itype, state["id"], workers if custom else None, log,
                                                       on_update=on_update)))
        return plan

    def edit_model(self, itype: InstanceType, inst: Instance, fm: FormModel) -> tuple[Instance, FormModel]:
        """The operator's resize fields as CR keys; current value = CR customization, else its preset."""
        kind = itype.key.split(":", 1)[1]
        spec = dict(inst.spec)
        presets = self.facts.presets() if self.facts else {}
        effective = component_values(presets.get(str(spec.get("scaleConfig")), {}), self.components(kind))
        edit = FormModel(itype.key)
        for key, val in effective.items():
            keys = self._cr_keys(key)
            what = key.rsplit("_", 1)[1]
            for ck in keys:
                spec.setdefault(ck, val)
            label = key.replace("_", " ")
            first = Field(path=(keys[0],), type="integer" if what == "replicas" else "quantity", role=WHAT_ROLE[what],
                          label=label, aliases=[(k,) for k in keys[1:]], alias_confirmed=True,
                          minimum=1 if what == "replicas" else None, sources={"operator"})
            edit.fields[first.path] = first
            for ck in keys[1:]:
                edit.fields[(ck,)] = Field(path=(ck,), type=first.type, role=first.role, label=label,
                                           aliases=[first.path], alias_confirmed=True, sources={"operator"})
        if not edit.fields:
            edit.notices.append(f"the operator documents no resize fields for {kind}")
        view = Instance(inst.type_key, inst.name, inst.namespace, inst.uid, {**inst.obj, "spec": spec}, inst.state,
                        inst.reason, inst.badges, inst.display_name, inst.meta)
        return view, edit

    def plan_edit(self, itype: InstanceType, inst: Instance, fm: FormModel, changes: dict[Path, object],
                  on_update=None) -> ActionPlan:
        from ...ops import planner
        view, edit = self.edit_model(itype, inst, fm)
        changes = {(p[-1],) if (p[-1],) in edit.fields else p: v for p, v in changes.items()}
        plan = planner.plan_edit(self, itype, view, edit, changes, on_update=on_update)
        workers = next((v for p, v in changes.items() if p[-1].endswith("worker_replicas")), None)
        if plan.steps:
            eid = inst.meta.get("engine_id")
            plan.steps[-1] = Step(f"watch until running{f' with {workers} worker(s)' if workers else ''} (40m limit)",
                                  lambda log: self._watch(itype, eid, int(workers) if workers else None, log,
                                                          on_update=on_update))
        return plan

    def plan_delete(self, itype: InstanceType, inst: Instance, on_update=None) -> ActionPlan:
        kind = itype.key.split(":", 1)[1]
        col = self.collections().get(kind) or {}
        coll, eid = col.get("collection", ""), inst.meta.get("engine_id")
        plan = ActionPlan(op="delete", target=f"{kind} {inst.display_name or inst.name}", type_key=itype.key,
                          confirm_name=inst.display_name or inst.name)
        if not inst.meta.get("engine"):
            plan.errors.append("cr-only: watsonx.data doesn't know it; delete the CR with oc if unwanted")
            return plan
        if not col.get("delete"):
            plan.errors.append(f"the lakehouse API has no delete operation for {kind}")
            return plan
        plan.summary.append(f"{eid}; its WxdEngine CR, pods and volumes go with it (the operator removes them)")

        def run(log: Log) -> None:
            self.api().request("DELETE", f"/{coll}/{eid}")
            log(f"  deleted {eid}")

        def wait(log: Log) -> None:
            t0 = time.monotonic()
            while time.monotonic() - t0 < 20 * 60:
                insts = self.list_instances(itype)
                if on_update:
                    on_update(insts)
                if not any(i.meta.get("engine_id") == eid for i in insts):
                    log(f"  gone ({int(time.monotonic() - t0)}s)")
                    return
                log(f"  still there ({int(time.monotonic() - t0)}s / 1200s)")
                time.sleep(15)

        plan.steps = [Step(f"DELETE {BASE}/{coll}/{eid}", run, dry_run="none: no dry-run in the API"),
                      Step("watch until it is gone (20m limit)", wait)]
        return plan
