"""OpenAPI / swagger request schemas -> payload Fields (sub-plan §4.2, "everything discoverable").

Services that embed their API spec (go-swagger in zen-core-api and the watsonx.data
lakehouse v3 server) describe every create request: required fields, enums, examples,
descriptions, formats. `prototype_fields` turns one request schema into Fields under
("parameters", ...), the same place the zen forms put their fields, so the generated create
form, validation and payload builder work unchanged. Examples become placeholders; an
example that is one of the enum values becomes the default of a required field.
"""

from __future__ import annotations

from ..model import Field, Path, Role
from ..providers.cpd.extensions import humanise

MAX_DEPTH = 8
_SCALARS = {"string", "integer", "number", "boolean"}


def inline(schema: dict, defs: dict, depth: int = 0) -> dict:
    """Resolve $ref (and allOf) recursively, bounded."""
    if not isinstance(schema, dict) or depth > MAX_DEPTH:
        return schema or {}
    if "$ref" in schema:
        ref = schema["$ref"].rsplit("/", 1)[-1]
        return inline({**defs.get(ref, {}), **{k: v for k, v in schema.items() if k != "$ref"}}, defs, depth + 1)
    if "allOf" in schema:
        merged: dict = {"type": "object", "properties": {}, "required": []}
        for part in schema["allOf"]:
            p = inline(part, defs, depth + 1)
            merged["properties"].update(p.get("properties") or {})
            merged["required"] += p.get("required") or []
        return merged
    out = dict(schema)
    if "properties" in out:
        out["properties"] = {k: inline(v, defs, depth + 1) for k, v in out["properties"].items()}
    if "items" in out:
        out["items"] = inline(out["items"], defs, depth + 1)
    return out


def prototype_fields(schema: dict, defs: dict, prefix: Path = ("parameters",),
                     skip: set[str] | None = None) -> dict[Path, Field]:
    """Every settable leaf of a request schema. `skip` drops server-assigned names (id, status)."""
    skip = skip if skip is not None else {"id", "status"}
    out: dict[Path, Field] = {}
    order = [0]

    def rec(node: dict, path: tuple[str, ...], required: bool, step: str, depth: int) -> None:
        if depth > MAX_DEPTH:
            return
        props = node.get("properties") or {}
        req = set(node.get("required") or [])
        for name, child in props.items():
            if not path and name in skip:
                continue
            ctype = child.get("type") or ("object" if "properties" in child else "string")
            sub = path + (name,)
            if ctype == "object" and child.get("properties"):
                rec(child, sub, required and name in req, step or name, depth + 1)
                continue
            if ctype == "object":                      # free-form map: not a form field
                continue
            f = Field(path=prefix + sub, type=ctype if ctype in _SCALARS else "array",
                      label=humanise(name), description=(child.get("description") or "").strip(),
                      required=required and name in req, payload=True, step=step or "settings", order=order[0],
                      sources={"spec"})
            order[0] += 1
            if isinstance(child.get("enum"), list):
                f.enum = list(child["enum"])
            if child.get("default") is not None:
                f.default = child["default"]
            ex = child.get("example")
            if ex is not None:
                f.placeholder = ", ".join(map(str, ex)) if isinstance(ex, list) else str(ex)
                if f.default is None and f.required and (not f.enum or ex in f.enum) and not isinstance(ex, list):
                    f.default = ex
            if child.get("minimum") is not None:
                f.minimum = child["minimum"]
            if child.get("maximum") is not None:
                f.maximum = child["maximum"]
            if f.default is None and f.required and f.type == "integer" and f.minimum is not None:
                f.default = f.minimum                    # e.g. a required node quantity starts at its minimum
            if child.get("pattern"):
                f.pattern = child["pattern"]
            if child.get("format") == "password":
                f.role = Role.SECRET
            out[f.path] = f

    rec(schema, (), True, "", 0)
    return out


def body_from(fields: dict[Path, Field], values: dict[Path, object], coerce, prefix: Path = ("parameters",),
              exclude_steps: tuple[str, ...] = ()) -> dict:
    """Nested request body from form values (empty / unset values left out)."""
    body: dict = {}
    for path, f in fields.items():
        if path[:len(prefix)] != prefix or f.step in exclude_steps:
            continue
        v = values.get(path)
        if v is None or v == "":
            continue
        if f.type == "array" and isinstance(v, str):
            v = [x.strip() for x in v.split(",") if x.strip()]
        else:
            v = coerce(f, v)
        node = body
        for part in path[len(prefix):-1]:
            node = node.setdefault(part, {})
        node[path[-1]] = v
    return body
