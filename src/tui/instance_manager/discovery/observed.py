"""S3: existing CR specs of a type -> Fields with observed values (the real payload shape).

Schema-less wrapper CRDs (CPDEdbInstance, PXRuntime) only become editable through this.
Lists of objects that all carry a `name` are keyed by it ([name=data]); other object
lists by index. Template leftovers such as "<no value>" count as unset.
"""

from __future__ import annotations

from ..model import QUANTITY_RE, Field, Path, is_unset

Flat = dict[Path, object]


def flatten(obj, path: Path = ()) -> Flat:
    out: Flat = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.update(flatten(v, path + (str(k),)))
        return out
    if isinstance(obj, list) and obj and all(isinstance(x, dict) for x in obj):
        named = all(isinstance(x.get("name"), str) for x in obj) and len({x["name"] for x in obj}) == len(obj)
        for i, x in enumerate(obj):
            out.update(flatten(x, path + (f"[name={x['name']}]" if named else f"[{i}]",)))
        return out
    if path:
        out[path] = None if is_unset(obj) else obj
    return out


def infer_type(values: list) -> str:
    kinds = set()
    for v in values:
        if isinstance(v, bool):
            kinds.add("boolean")
        elif isinstance(v, int):
            kinds.add("integer")
        elif isinstance(v, float):
            kinds.add("number")
        elif isinstance(v, list):
            kinds.add("array")
        elif isinstance(v, str) and QUANTITY_RE.match(v) and not v.replace(".", "").isdigit():
            kinds.add("quantity")
        else:
            kinds.add("string")
    if len(kinds) == 1:
        return kinds.pop()
    if kinds <= {"integer", "number"}:
        return "number"
    if kinds <= {"integer", "quantity", "string"} and "quantity" in kinds:
        return "quantity"
    return "string"


def observe(specs: list[dict], source: str = "S3") -> tuple[dict[Path, Field], list[Flat]]:
    flats = [flatten(s or {}) for s in specs]
    values: dict[Path, list] = {}
    for flat in flats:
        for p, v in flat.items():
            values.setdefault(p, [])
            if v is not None:
                values[p].append(v)
    fields: dict[Path, Field] = {}
    for p, vals in values.items():
        f = Field(path=p, type=infer_type(vals) if vals else "string", observed=vals)
        f.sources.add(source)
        fields[p] = f
    return fields, flats
