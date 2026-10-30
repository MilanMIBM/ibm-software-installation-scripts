"""Field -> Role (plan §4). Generic evidence only; first hit wins, confidence drops down the list:

  1. explicit  (S1 form type, S6 scale subresource, S7 x-descriptor) - already set on the Field
  2. shape     (ResourceRequirements, cpu/memory leaves under one)
  3. value     (observed value is a StorageClass / Secret name / addon version on this cluster)
  4. tokens    (the leaf name; low confidence, never against 1-3)
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from ..model import UNIT_RE, Evidence, Field, Path, Role

_NUMERIC = re.compile(r"^[0-9]+(\.[0-9]+)?([a-zA-Z]{1,2})?$")
_CAPACITY = (Role.REPLICAS, Role.CPU, Role.MEMORY, Role.STORAGE_SIZE)

# (role, leaf-name patterns) in check order: memory/cpu before replicas ("memorypernode", "corespernode")
_TOKENS: list[tuple[Role, re.Pattern]] = [(role, re.compile(rx)) for role, rx in [
    (Role.SECRET, r"password|passwd|token"),
    (Role.SECRET_REF, r"secret"),
    (Role.STORAGE_CLASS, r"storageclass|storage_class"),
    (Role.SIZE_PRESET, r"scaleconfig|scale_config|sizeconfig|size_config|scalesize|tshirt"),
    (Role.LIFECYCLE, r"shutdown"),
    (Role.MEMORY, r"memory|mem(?!ber)"),
    (Role.CPU, r"cpu|core"),
    (Role.REPLICAS, r"replica|members|nodes|numberof|instances|workers"),
    (Role.STORAGE_SIZE, r"storagesize|volumesize|disksize|ssize|pvsize"),
    (Role.VERSION, r"version"),
]]
_STORAGE_PARENTS = ("storage", "persistence", "volume", "pvc", "disk")


@dataclass
class RoleContext:
    storage_classes: set[str] = field(default_factory=set)
    secret_names: set[str] = field(default_factory=set)
    versions: set[str] = field(default_factory=set)


def leaf_name(path: Path) -> str:
    for p in reversed(path):
        if not p.startswith("["):
            return p
    return ""


def _numeric_like(f: Field) -> bool:
    if f.type in ("integer", "number", "quantity"):
        return True
    vals = [v for v in f.observed if not isinstance(v, bool)]
    return bool(vals) and all(isinstance(v, (int, float)) or (isinstance(v, str) and _NUMERIC.match(v))
                              for v in vals)


def _under_resources(path: Path, fields: dict[Path, Field]) -> bool:
    return any(fields.get(path[:i]) is not None and fields[path[:i]].type == "resources"
               for i in range(1, len(path))) or any(p in ("limits", "requests") for p in path[:-1])


def infer(f: Field, fields: dict[Path, Field], ctx: RoleContext) -> None:
    if f.role != Role.OTHER:
        return
    leaf = leaf_name(f.path).lower()
    strings = [v for v in f.observed if isinstance(v, str)]

    def set_role(role: Role, source: str, detail: str, conf: float) -> None:
        f.role, f.role_evidence = role, Evidence(source, detail, conf)

    # 2. shape
    if f.type == "resources":
        return set_role(Role.RESOURCES, "S5", "ResourceRequirements shape", 0.9)
    if _under_resources(f.path, fields) and leaf in ("cpu", "memory"):
        return set_role(Role.CPU if leaf == "cpu" else Role.MEMORY, "S5", f"{leaf} under limits/requests", 0.9)
    # 3. value cross-check against the cluster
    if strings and ctx.storage_classes and all(s in ctx.storage_classes for s in strings):
        return set_role(Role.STORAGE_CLASS, "live", f"value is a StorageClass ({strings[0]})", 0.85)
    if strings and ctx.secret_names and all(s in ctx.secret_names for s in strings):
        return set_role(Role.SECRET_REF, "live", f"value is a Secret name ({strings[0]})", 0.8)
    # 4. tokens
    for role, rx in _TOKENS:
        m = rx.search(leaf)
        if not m:
            continue
        if role in _CAPACITY and not _numeric_like(f):
            continue
        if role == Role.REPLICAS and f.type == "quantity":
            continue
        if role == Role.VERSION and strings and ctx.versions and any(s in ctx.versions for s in strings):
            return set_role(role, "live", f"value is a known version ({strings[0]})", 0.8)
        return set_role(role, "S8", f"name token '{m.group(0)}'", 0.5)
    parents = [p.lower() for p in f.path[:-1]]
    if ("size" in leaf and _numeric_like(f)
            and (any(s in leaf for s in _STORAGE_PARENTS) or any(s in p for p in parents for s in _STORAGE_PARENTS))):
        return set_role(Role.STORAGE_SIZE, "S8", "size under a storage/persistence object", 0.5)
    if ("unit" in leaf and strings and all(UNIT_RE.match(s) for s in strings)):
        return set_role(Role.UNIT, "S8", "unit of a sibling size", 0.5)
    if f.type == "quantity":
        return set_role(Role.QUANTITY, "S5", "Kubernetes quantity", 0.6)


def infer_all(fields: dict[Path, Field], ctx: RoleContext) -> None:
    for f in fields.values():
        infer(f, fields, ctx)
