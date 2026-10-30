"""L1 CrdProvider: any CR-backed instance type (plan §2, §8). The cpd provider extends it.

Types come from `--kinds` (plural.group | Kind | kind.group). A type's FormModel merges
its CRD schema (S5/S6) with the specs of its existing CRs (S3); roles, alias groups and
per-field storage needs are inferred on top. State = the CR dashboard's classifier.
"""

from __future__ import annotations

import threading

from ....cr_dashboard.classifier import Context, classify
from ....cr_dashboard.model import Phase
from ....cr_dashboard.status_normalize import normalize
from ...discovery import aliases, roles
from ...discovery.merge import merge
from ...discovery.observed import observe
from ...discovery.schema_walk import served_version, walk_crd
from ...model import Field, FormModel, Instance, InstanceType, Kind, Mutability, Path, Role, StorageClassInfo
from ...storage import field_need, sc_classifier
from ..base import Provider
from .cluster import Cluster, OwnerGraph


def type_from_crd(crd: dict, *, key: str | None = None, display: str | None = None, provider: str = "k8s-crd",
                  status_path: str | None = None) -> InstanceType:
    spec = crd.get("spec") or {}
    names = spec.get("names") or {}
    v = served_version(crd) or {}
    return InstanceType(key=key or f"crd:{spec.get('group')}/{names.get('kind')}",
                        display=display or names.get("kind", "?"), group=spec.get("group", ""),
                        version=v.get("name", ""), kind=names.get("kind", ""), plural=names.get("plural", ""),
                        namespaced=spec.get("scope") == "Namespaced", crd=crd, status_path=status_path,
                        provider=provider)


class CrdProvider(Provider):
    id = "k8s-crd"

    def __init__(self, cluster: Cluster, kinds: list[str] | None = None, namespace: str | None = None,
                 declared_sc: dict[str, Kind] | None = None, sc_overrides: dict[str, Kind] | None = None):
        self.cluster = cluster
        self.kinds = kinds or []
        self.namespace = namespace
        self.declared_sc = declared_sc or {}
        self.sc_overrides = sc_overrides or {}
        self.notices: list[str] = []
        self._lock = threading.RLock()
        self._sc: dict[str, StorageClassInfo] | None = None
        self._graph: OwnerGraph | None = None

    # -- types / instances ---------------------------------------------------
    def discover_types(self) -> list[InstanceType]:
        out = []
        for token in self.kinds:
            crd = self.cluster.find_crd(token)
            if crd is None:
                many = self.cluster.find_crds(token)
                self.notices.append(f"--kinds {token}: " + (
                    "ambiguous, use plural.group: " + ", ".join(c["metadata"]["name"] for c in many)
                    if many else "no such CRD"))
                continue
            out.append(type_from_crd(crd))
        return out

    def instance_from(self, itype: InstanceType, obj: dict) -> Instance:
        meta = obj.get("metadata") or {}
        v = served_version(itype.crd or {}) or {}
        cr = normalize(obj, itype.kind, v.get("additionalPrinterColumns"),
                       {"status": itype.status_path} if itype.status_path else None)
        if cr.phase == Phase.UNKNOWN:
            # free-text status ("Cluster in healthy state"): the standard conditions decide
            conds = {c.get("type"): c.get("status") for c in cr.conditions}
            if "True" in (conds.get("Failed"), conds.get("Failure")):
                cr.phase = Phase.FAILED
            elif "True" in (conds.get("Ready"), conds.get("Available")):
                cr.phase = Phase.COMPLETED
            elif conds.get("Ready") == "False":
                cr.phase = Phase.IN_PROGRESS
        verdict = classify(cr, None, None, Context())
        return Instance(type_key=itype.key, name=meta.get("name", "?"), namespace=meta.get("namespace"),
                        uid=meta.get("uid", ""), obj=obj, state=verdict.state, reason=verdict.reason)

    def list_instances(self, itype: InstanceType) -> list[Instance]:
        items = self.cluster.try_list(itype.list_path(self.namespace))
        return [self.instance_from(itype, o) for o in items]

    # -- storage ---------------------------------------------------------------
    def storage_classes(self) -> dict[str, StorageClassInfo]:
        with self._lock:
            if self._sc is None:
                self._sc = sc_classifier.classify(self.cluster.storage_classes(), self.cluster.pvcs(),
                                                  self.cluster.storage_profiles(), self.declared_sc,
                                                  self.sc_overrides)
            return self._sc

    def graph(self, namespaces: set[str]) -> OwnerGraph:
        with self._lock:
            if self._graph is None:
                self._graph = OwnerGraph(self.cluster)
            return self._graph.build(namespaces)

    def refresh_instances(self) -> None:
        self.cluster.drop_lists()

    def refresh(self) -> None:
        with self._lock:
            self.cluster.invalidate()
            self._sc = None
            self._graph = None
            self.notices.clear()

    # -- form model ----------------------------------------------------------------
    def role_context(self, instances: list[Instance], itype: InstanceType) -> roles.RoleContext:
        secrets: set[str] = set()
        for ns in {i.namespace for i in instances if i.namespace} | ({self.namespace} if self.namespace else set()):
            secrets |= self.cluster.secret_names(ns)
        return roles.RoleContext(storage_classes=set(self.storage_classes()), secret_names=secrets,
                                 versions=self.known_versions(itype))

    def known_versions(self, itype: InstanceType) -> set[str]:
        return set()

    def extra_sources(self, itype: InstanceType, instances: list[Instance]) -> tuple[list, list]:
        """(sources ranked above S3, sources ranked below S5) - the cpd layer adds S1/S2/samples."""
        return [], []

    def form_model(self, itype: InstanceType, instances: list[Instance] | None = None,
                   storage: bool = True) -> FormModel:
        """storage=False skips the storage-need analysis (it needs the owner graph); the hub publishes
        the fields first and calls assess_storage() right after, so the detail pane doesn't wait."""
        instances = self.list_instances(itype) if instances is None else instances
        observed, flats = observe([i.spec for i in instances])
        schema = walk_crd(itype.crd) if itype.crd else {}
        above, below = self.extra_sources(itype, instances)
        fields = merge([*above, observed, schema, *below])
        roles.infer_all(fields, self.role_context(instances, itype))
        aliases.detect(fields, flats)
        fm = FormModel(type_key=itype.key, fields=fields, instance_count=len(instances),
                       notices=list(itype.notices))
        if storage:
            self.assess_storage(fm, instances, flats)
        return fm

    def assess_storage(self, fm: FormModel, instances: list[Instance], flats: list | None = None) -> None:
        if flats is None:
            flats = observe([i.spec for i in instances])[1]
        sc_fields: list[Field] = fm.by_role(Role.STORAGE_CLASS)
        if not sc_fields:
            return
        sc = self.storage_classes()
        graph = self.graph({i.namespace for i in instances if i.namespace})
        under = {i.name: graph.pvcs_under(i.uid) for i in instances}
        own = {(p.get("metadata") or {}).get("uid") for ps in under.values() for p in ps}
        named = [(i.name, flat) for i, flat in zip(instances, flats)]
        for f in sc_fields:
            f.storage = field_need.assess(f, fm.fields, named, lambda n: under.get(n, []), sc,
                                          lambda keys, ex: graph.peer_pvcs(keys, ex | own))
            traced = any(ev.source == "live" and "PVC(s) on" in ev.detail for ev in f.storage.evidence)
            if traced:
                f.mutability = Mutability.IMMUTABLE
                f.notices.append("flows into existing PVCs: the class can't change on an existing instance")

    @staticmethod
    def flat_value(instance: Instance, path: Path):
        from ...discovery.observed import flatten
        return flatten(instance.spec).get(path)
