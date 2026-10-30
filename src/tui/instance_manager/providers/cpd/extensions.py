"""S1: a zen `service_provisioning` extension -> payload Fields (plan §1 F2).

Property keys are create_arguments.parameters keys, so they map to ("parameters", key),
the same place wrapper CRs echo them (spec.parameters). Types: range -> integer with
bounds, radio/enum -> enum, boolean, string (+validTextRegex), section_title skipped.
`dependencies.<field>.oneOf[]` branches become show_if conditions.
`hardware_configuration.scale_size[]` becomes size presets.
Labels that are i18n tokens ({{.global_x}}) fall back to a humanised key.
"""

from __future__ import annotations

import re

from ...model import Field, Path, Role

_TOKEN = re.compile(r"^\s*\{\{.*\}\}\s*$")
_CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")


def humanise(key: str) -> str:
    words = _CAMEL.sub(" ", key).replace("_", " ").replace(".", " ").split()
    return " ".join(words).capitalize() if words else key


def label_of(raw, key: str) -> str:
    if isinstance(raw, str) and raw.strip() and not _TOKEN.match(raw):
        return raw.strip()
    return humanise(key)


def _field(key: str, prop: dict, step: str, order: int, required: bool, sc_names: set[str]) -> Field | None:
    ptype = prop.get("type")
    if ptype == "section_title":
        return None
    f = Field(path=("parameters", key), label=label_of(prop.get("label"), key),
              description=label_of(prop.get("description"), "") if prop.get("description") else "",
              required=required, default=prop.get("default"), step=step, order=order, payload=True)
    f.sources.add("S1")
    if ptype == "range":
        f.type = "integer"
        f.minimum, f.maximum = prop.get("min"), prop.get("max")
    elif ptype == "radio":
        buttons = prop.get("buttons") or []
        f.enum = [b.get("value") for b in buttons]
        f.enum_labels = {b.get("value"): label_of(b.get("label"), str(b.get("value"))) for b in buttons}
        f.type = "string"
    elif ptype == "enum":
        items = prop.get("items") or []
        ids = [i.get("id") for i in items]
        texts = [i.get("text") for i in items]
        if prop.get("default") is not None and prop["default"] in texts and prop["default"] not in ids:
            f.enum = texts                          # the default is a text ("Gi" vs id "optiongb"): texts are sent
        else:
            f.enum = ids
            f.enum_labels = {i.get("id"): label_of(i.get("text"), str(i.get("id"))) for i in items}
        f.type = "string"
        handler = str(prop.get("items_handler") or "")
        if handler:
            f.description = (f.description + " " if f.description else "") + f"(options from {handler.rsplit('/', 1)[-1]})"
            if "storageclass" in handler.lower():
                f.role = Role.STORAGE_CLASS         # zen fills it from its storage-class list: a typed picker here
    elif ptype == "boolean":
        f.type = "boolean"
    else:
        f.type = "string"
        f.pattern = prop.get("validTextRegex") or prop.get("pattern")
        f.placeholder = str(prop.get("placeholder") or "")
    if f.enum and sc_names and all(v in sc_names for v in f.enum):
        f.enum_soft = True                      # operators bake in install-time defaults; a hint, not a list
        f.role = Role.STORAGE_CLASS
    return f


def provisioning_fields(ext: dict, sc_names: set[str] | None = None) -> tuple[dict[Path, Field], list[str]]:
    sc_names = sc_names or set()
    prov = ((ext.get("details") or {}).get("provisioning") or {})
    out: dict[Path, Field] = {}
    notices: list[str] = []
    order = 0
    for step in prov.get("custom_steps") or []:
        step_key = step.get("step_key", "")
        required = set(step.get("required") or [])
        props = step.get("properties") or {}
        ordered = [k for sec in (step.get("sections") or {}).values() for k in sec.get("items") or []]
        ordered += [k for k in props if k not in ordered]
        for key in ordered:
            if key in props:
                f = _field(key, props[key], step_key, order, key in required, sc_names)
                order += 1
                if f:
                    out[f.path] = f
        for ctrl, dep in (step.get("dependencies") or {}).items():
            for branch in dep.get("oneOf") or []:
                bprops = branch.get("properties") or {}
                cond = (bprops.get(ctrl) or {}).get("enum")
                for key, prop in bprops.items():
                    if key == ctrl:
                        continue
                    f = _field(key, prop, step_key, order, key in required, sc_names)
                    order += 1
                    if f is None:
                        continue
                    if cond is not None:
                        f.show_if = {("parameters", ctrl): list(cond)}
                    out.setdefault(f.path, f)
    hw = prov.get("hardware_configuration") or {}
    presets = [{"value": s.get("value"), "label": label_of(s.get("label"), str(s.get("value"))),
                "cpu": s.get("cpu_limit"), "memory": s.get("memory_limit"), "metadata": s.get("metadata") or {}}
               for s in hw.get("scale_size") or [] if isinstance(s, dict)]
    if presets:
        out[("__presets__",)] = Field(path=("__presets__",), type="string", role=Role.SIZE_PRESET,
                                      presets=presets, enum=[p["value"] for p in presets],
                                      label="Size", step="hardware", order=-1, payload=True,
                                      sources={"S1"})
    return out, notices


def attach_presets(fields: dict[Path, Field], notices: list[str]) -> None:
    """Move S1 presets onto the payload field that carries the preset (found by role/observed values)."""
    holder = fields.pop(("__presets__",), None)
    if holder is None:
        return
    values = set(holder.enum or [])
    target = next((f for f in fields.values() if f.path[:1] == ("parameters",)
                   and (f.role == Role.SIZE_PRESET or (f.observed and set(map(str, f.observed)) <= values))), None)
    if target is None:
        target = Field(path=("parameters", "scaleConfig"), type="string", sources={"S1"}, payload=True)
        fields[target.path] = target
        notices.append("size presets: no instance shows which parameter carries them; "
                       "assumed parameters.scaleConfig")
    target.role = Role.SIZE_PRESET
    target.presets, target.enum, target.label = holder.presets, holder.enum, target.label or "Size"
    target.enum_labels = {p["value"]: p["label"] for p in holder.presets}
    target.step, target.order = target.step or holder.step, min(target.order, holder.order)
    target.sources |= holder.sources


def reconcile_vocabulary(fields: dict[Path, Field]) -> None:
    """S1 option ids can be UI-only ("optiongb" while zen stores and the CR holds "Gi"). When every
    live value and the default fall outside an S1 enum, the live values are the payload vocabulary."""
    for f in fields.values():
        live = {str(v) for v in f.observed if not isinstance(v, (dict, list))}
        ids = set(map(str, f.enum or []))
        if not f.enum or f.enum_soft or "S1" not in f.sources or not live or live & ids or str(f.default) in ids:
            continue
        f.notices = [n for n in f.notices if not n.startswith("observed values outside the enum")]
        f.notices.append(f"form option ids {f.enum} are not payload values; using the live ones")
        f.enum = sorted(live | ({str(f.default)} if f.default is not None else set()))
        f.enum_labels, f.enum_soft = None, True
