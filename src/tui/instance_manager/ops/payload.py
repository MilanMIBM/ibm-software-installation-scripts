"""Form values <-> the zen create payload, plus validation (plan §6.1).

Values are keyed by field path; payload fields live under ("parameters", ...) and become
create_arguments.parameters. A field whose show_if isn't met is left out. Starting values
come from the form's default, else the value most instances use (learned from existing
instances), never for secrets.
"""

from __future__ import annotations

import re
import secrets as pysecrets
import string
from collections import Counter

from ..model import Field, FormModel, InstanceType, Path, Role, StorageClassInfo

DNS1123 = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
_ALNUM = string.ascii_letters + string.digits


def random_password(length: int = 24) -> str:
    """Alphanumeric (safe in URLs, conf files, JSON), like h_random_password."""
    return "".join(pysecrets.choice(_ALNUM) for _ in range(length))


def payload_fields(fm: FormModel) -> list[Field]:
    out = [f for f in fm.fields.values() if f.payload and f.path[:1] == ("parameters",) and len(f.path) >= 2
           and not any(p.startswith("[") for p in f.path)]
    return fm.representatives(out) if out else []


def shown(f: Field, values: dict[Path, object]) -> bool:
    return not f.show_if or all(values.get(p) in allowed for p, allowed in f.show_if.items())


def best_class(f: Field, sc: dict[str, StorageClassInfo]) -> str | None:
    """The StorageClass a storage field starts on: declared (cpd_vars) > cluster default > any, of a kind
    the field accepts; object classes never."""
    ok = [i for i in sc.values() if (f.storage.accepts(i.kind) if f.storage else i.kind.value != "object")]
    if not ok:
        return None
    ok.sort(key=lambda i: (0 if any(e.source == "config" for e in i.evidence) else 1, 0 if i.default else 1,
                           -i.pvc_count, i.name))
    return ok[0].name


def initial_values(fm: FormModel, sc: dict[str, StorageClassInfo] | None = None) -> dict[Path, object]:
    vals: dict[Path, object] = {}
    for f in payload_fields(fm):
        if f.role == Role.STORAGE_CLASS and sc:
            cur = f.default if f.default is not None else next(iter(f.observed), None)
            info = sc.get(str(cur)) if cur is not None else None
            vals[f.path] = cur if info and (not f.storage or f.storage.accepts(info.kind)) else best_class(f, sc)
            continue
        if f.role == Role.SECRET:
            vals[f.path] = None
        elif f.default is not None:
            vals[f.path] = f.default
        elif f.observed:
            common = Counter(str(v) for v in f.observed if not isinstance(v, (dict, list))).most_common(1)
            if common:
                raw = common[0][0]
                vals[f.path] = next(v for v in f.observed if str(v) == raw)
    return vals


def coerce(f: Field, value):
    if value is None or value == "":
        return None
    if f.type == "integer":
        return int(value)
    if f.type == "number":
        return float(value)
    if f.type == "boolean":
        return value if isinstance(value, bool) else str(value).lower() in ("true", "1", "yes", "on")
    sample = next((v for v in f.observed if v is not None), None)
    if isinstance(sample, bool) and isinstance(value, str):
        return value.lower() in ("true", "1", "yes", "on")
    if isinstance(sample, int) and not isinstance(sample, bool) and str(value).lstrip("-").isdigit():
        return int(value)
    return str(value) if not isinstance(value, (bool, int, float)) else value


def build(itype: InstanceType, fm: FormModel, values: dict[Path, object], name: str, description: str,
          namespace: str, version: str | None) -> dict:
    params: dict = {}
    for f in payload_fields(fm):
        if not shown(f, values):
            continue
        v = coerce(f, values.get(f.path))
        if v is None:
            continue
        node = params
        for part in f.path[1:-1]:
            node = node.setdefault(part, {})
        node[f.path[-1]] = v
    at = itype.key.split(":", 1)[1]
    payload = {"addon_type": at, "display_name": name, "namespace": namespace,
               "create_arguments": {"description": description, "parameters": params}}
    if version:
        payload["addon_version"] = version
    return payload


def masked(payload: dict, fm: FormModel) -> dict:
    secret_keys = {f.path[-1] for f in fm.fields.values() if f.role == Role.SECRET}

    def walk(x):
        if isinstance(x, dict):
            return {k: ("****" if k in secret_keys and v else walk(v)) for k, v in x.items()}
        if isinstance(x, list):
            return [walk(v) for v in x]
        return x
    return walk(payload)


def validate(itype: InstanceType, fm: FormModel, values: dict[Path, object], name: str,
             existing: list[str], sc: dict[str, StorageClassInfo],
             name_regex: str | None) -> tuple[list[str], list[str]]:
    """-> (errors, warnings)"""
    errors, warnings = [], []
    if not name:
        errors.append("name is required")
    elif name_regex and not re.fullmatch(name_regex, name):
        errors.append(f"name must match {name_regex}")
    if name and itype.crd and not DNS1123.match(name):
        errors.append("name becomes a Kubernetes resource name: lowercase letters, digits and '-' only")
    if name and name in existing:
        errors.append(f"an instance named {name} already exists")
    if itype.max_instances and len(existing) >= itype.max_instances:
        errors.append(f"{itype.display} allows at most {itype.max_instances} instance(s)")
    if not itype.creatable:
        errors.append(f"{itype.display} has no provisioning entry; it can't be created here")
    for f in payload_fields(fm):
        if not shown(f, values):
            continue
        label = f.label or f.key
        try:
            v = coerce(f, values.get(f.path))
        except (TypeError, ValueError):
            errors.append(f"{label}: not a valid {f.type}")
            continue
        if v is None:
            if f.required:
                errors.append(f"{label} is required")
            continue
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            if f.minimum is not None and v < f.minimum:
                errors.append(f"{label}: {v} is below the minimum {f.minimum}")
            if f.maximum is not None and v > f.maximum:
                errors.append(f"{label}: {v} is above the maximum {f.maximum}")
        if f.enum and not f.enum_soft and v not in f.enum and str(v) not in map(str, f.enum):
            errors.append(f"{label}: {v} is not one of {', '.join(map(str, f.enum))}")
        if f.pattern and isinstance(v, str) and not re.search(f.pattern, v):
            errors.append(f"{label}: does not match {f.pattern}")
        if f.role == Role.STORAGE_CLASS and isinstance(v, str):
            info = sc.get(v)
            if info is None:
                errors.append(f"{label}: no StorageClass {v}")
            elif f.storage and not f.storage.accepts(info.kind):
                warnings.append(f"{label}: {v} is {info.kind.label}, but the field needs {f.storage.need.value}")
            elif f.enum_soft and f.enum and v not in f.enum:
                warnings.append(f"{label}: {v} is outside the classes the form offers ({', '.join(f.enum)})")
    return errors, warnings
