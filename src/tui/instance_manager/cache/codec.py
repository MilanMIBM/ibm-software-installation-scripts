"""JSON codec for the discovery data model (cache plan §2.7).

Lossless for what discovery produces: Path tuples become lists of segments (not path_str,
which can't be split back), sets become sorted lists, Enums their values, show_if
`[[path, values], ...]` and enum_labels `[[value, label], ...]` (enum values need not be
strings). decode(encode(x)) == x is a test. redact=True drops the observed values and the
default of SECRET fields before a model is written.
"""

from __future__ import annotations

from collections.abc import Callable

from ...common.state import State
from ..model import (
    Evidence,
    Field,
    FormModel,
    Instance,
    InstanceType,
    Kind,
    Mutability,
    Need,
    Role,
    StorageClassInfo,
    StorageNeed,
)
from ..providers.cpd.registry import AddonEntry


# -- small pieces ---------------------------------------------------------------------------
def enc_evidence(e: Evidence | None) -> dict | None:
    return None if e is None else {"source": e.source, "detail": e.detail, "confidence": e.confidence}


def dec_evidence(d: dict | None) -> Evidence | None:
    return None if d is None else Evidence(d["source"], d["detail"], d.get("confidence", 0.5))


def enc_need(sn: StorageNeed | None) -> dict | None:
    if sn is None:
        return None
    return {"need": sn.need.value, "evidence": [enc_evidence(e) for e in sn.evidence],
            "mismatches": list(sn.mismatches)}


def dec_need(d: dict | None) -> StorageNeed | None:
    if d is None:
        return None
    return StorageNeed(Need(d["need"]), [dec_evidence(e) for e in d.get("evidence") or []],
                       list(d.get("mismatches") or []))


def enc_sc(info: StorageClassInfo) -> dict:
    return {"name": info.name, "provisioner": info.provisioner, "kind": info.kind.value,
            "evidence": [enc_evidence(e) for e in info.evidence], "expandable": info.expandable,
            "default": info.default, "binding_mode": info.binding_mode, "access_modes": dict(info.access_modes),
            "raw_block": info.raw_block}


def dec_sc(d: dict) -> StorageClassInfo:
    return StorageClassInfo(name=d["name"], provisioner=d.get("provisioner", ""), kind=Kind(d.get("kind", "unknown")),
                            evidence=[dec_evidence(e) for e in d.get("evidence") or []],
                            expandable=d.get("expandable", False), default=d.get("default", False),
                            binding_mode=d.get("binding_mode", ""), access_modes=dict(d.get("access_modes") or {}),
                            raw_block=d.get("raw_block", False))


def enc_sc_map(sc: dict[str, StorageClassInfo]) -> list[dict]:
    return [enc_sc(i) for i in sc.values()]


def dec_sc_map(items: list[dict]) -> dict[str, StorageClassInfo]:
    return {d["name"]: dec_sc(d) for d in items}


# -- Field / FormModel ------------------------------------------------------------------------
def enc_field(f: Field, redact: bool = False) -> dict:
    secret = redact and f.role == Role.SECRET
    return {
        "path": list(f.path), "type": f.type, "label": f.label, "description": f.description,
        "enum": list(f.enum) if f.enum is not None else None, "minimum": f.minimum, "maximum": f.maximum,
        "pattern": f.pattern, "required": f.required, "default": None if secret else f.default,
        "observed": [] if secret else list(f.observed), "role": f.role.value,
        "role_evidence": enc_evidence(f.role_evidence), "mutability": f.mutability.value,
        "aliases": [list(a) for a in f.aliases], "alias_confirmed": f.alias_confirmed,
        "sources": sorted(f.sources), "notices": list(f.notices), "storage": enc_need(f.storage),
        "preserve_unknown": f.preserve_unknown, "placeholder": f.placeholder, "step": f.step, "order": f.order,
        "show_if": None if f.show_if is None else [[list(p), list(v)] for p, v in f.show_if.items()],
        "enum_labels": None if f.enum_labels is None else [[k, v] for k, v in f.enum_labels.items()],
        "enum_soft": f.enum_soft, "presets": f.presets, "payload": f.payload,
    }


def dec_field(d: dict) -> Field:
    return Field(
        path=tuple(d["path"]), type=d.get("type", "string"), label=d.get("label", ""),
        description=d.get("description", ""), enum=d.get("enum"), minimum=d.get("minimum"),
        maximum=d.get("maximum"), pattern=d.get("pattern"), required=d.get("required", False),
        default=d.get("default"), observed=list(d.get("observed") or []), role=Role(d.get("role", "other")),
        role_evidence=dec_evidence(d.get("role_evidence")), mutability=Mutability(d.get("mutability", "unknown")),
        aliases=[tuple(a) for a in d.get("aliases") or []], alias_confirmed=d.get("alias_confirmed", False),
        sources=set(d.get("sources") or []), notices=list(d.get("notices") or []), storage=dec_need(d.get("storage")),
        preserve_unknown=d.get("preserve_unknown", False), placeholder=d.get("placeholder", ""),
        step=d.get("step", ""), order=d.get("order", 10_000),
        show_if=None if d.get("show_if") is None else {tuple(p): list(v) for p, v in d["show_if"]},
        enum_labels=None if d.get("enum_labels") is None else {k: v for k, v in d["enum_labels"]},
        enum_soft=d.get("enum_soft", False), presets=d.get("presets"), payload=d.get("payload", False))


def enc_model(fm: FormModel, redact: bool = True) -> dict:
    return {"type_key": fm.type_key, "fields": [enc_field(f, redact) for f in fm.fields.values()],
            "notices": list(fm.notices), "instance_count": fm.instance_count}


def dec_model(d: dict) -> FormModel:
    fields = [dec_field(x) for x in d.get("fields") or []]
    return FormModel(d["type_key"], {f.path: f for f in fields}, list(d.get("notices") or []),
                     d.get("instance_count", 0))


# -- catalog -------------------------------------------------------------------------------------
def enc_addon(e: AddonEntry) -> dict:
    return {"addon_type": e.addon_type, "configmap": e.configmap, "details": e.details, "versions": list(e.versions),
            "max_instances": e.max_instances, "display": e.display}


def dec_addon(d: dict) -> AddonEntry:
    return AddonEntry(addon_type=d["addon_type"], configmap=d.get("configmap", ""), details=d.get("details") or {},
                      versions=list(d.get("versions") or []), max_instances=d.get("max_instances"),
                      display=d.get("display", ""))


def crd_name(crd: dict | None) -> str | None:
    return ((crd or {}).get("metadata") or {}).get("name")


def enc_type(it: InstanceType) -> dict:
    """The CRD is stored once under sources/crd/ and referenced by name."""
    meta = {k: v for k, v in it.meta.items() if k != "addon"}
    return {"key": it.key, "display": it.display, "group": it.group, "version": it.version, "kind": it.kind,
            "plural": it.plural, "namespaced": it.namespaced, "crd_ref": crd_name(it.crd),
            "status_path": it.status_path, "max_instances": it.max_instances, "provider": it.provider,
            "notices": list(it.notices), "creatable": it.creatable, "versions": list(it.versions),
            "addon": enc_addon(it.meta["addon"]) if isinstance(it.meta.get("addon"), AddonEntry) else None,
            "meta": meta}


def dec_type(d: dict, crd_of: Callable[[str], dict | None] = lambda n: None) -> InstanceType:
    it = InstanceType(key=d["key"], display=d["display"], group=d.get("group", ""), version=d.get("version", ""),
                      kind=d.get("kind", ""), plural=d.get("plural", ""), namespaced=d.get("namespaced", True),
                      crd=crd_of(d["crd_ref"]) if d.get("crd_ref") else None, status_path=d.get("status_path"),
                      max_instances=d.get("max_instances"), provider=d.get("provider", "k8s-crd"),
                      notices=list(d.get("notices") or []), creatable=d.get("creatable", True),
                      versions=list(d.get("versions") or []), meta=dict(d.get("meta") or {}))
    if d.get("addon"):
        it.meta["addon"] = dec_addon(d["addon"])
    return it


# -- instance snapshot (paint only: no CR body, no secrets) ---------------------------------------
ZEN_KEYS = ("id", "display_name", "provision_status", "service_version", "namespace", "service_type")


def enc_instance(i: Instance) -> dict:
    zen = i.meta.get("zen") or {}
    return {"type_key": i.type_key, "name": i.name, "namespace": i.namespace, "uid": i.uid, "state": i.state.value,
            "reason": i.reason, "badges": list(i.badges), "display_name": i.display_name,
            "zen": {k: zen[k] for k in ZEN_KEYS if k in zen} or None}


def dec_instance(d: dict) -> Instance:
    meta = {"cached": True}
    if d.get("zen"):
        meta["zen"] = dict(d["zen"])
    return Instance(type_key=d["type_key"], name=d["name"], namespace=d.get("namespace"), uid=d.get("uid", ""),
                    obj={}, state=State(d.get("state", "inactive")), reason=d.get("reason", ""),
                    badges=list(d.get("badges") or []), display_name=d.get("display_name"), meta=meta)
