"""S5/S6: a CRD's openAPIV3Schema -> Fields (types, enums, bounds, required, immutability).

Generic Kubernetes knowledge only: ResourceRequirements is recognised by shape (limits +
requests maps of int-or-string), immutability by `x-kubernetes-validations` rules that
compare self with oldSelf, replicas by the `scale` subresource.
"""

from __future__ import annotations

import re

from ..model import Field, Mutability, Path, Role

MAX_DEPTH = 14
_IMMUTABLE_RULE = re.compile(r"\bself\s*==\s*oldSelf\b|\boldSelf\s*==\s*self\b")


def served_version(crd: dict) -> dict | None:
    """The storage version if served, else the first served one."""
    versions = [v for v in (crd.get("spec") or {}).get("versions") or [] if v.get("served")]
    return next((v for v in versions if v.get("storage")), versions[0] if versions else None)


def spec_schema(crd: dict) -> dict:
    v = served_version(crd) or {}
    return (((v.get("schema") or {}).get("openAPIV3Schema") or {}).get("properties") or {}).get("spec") or {}


def scale_replicas_path(crd: dict) -> Path | None:
    v = served_version(crd) or {}
    p = ((v.get("subresources") or {}).get("scale") or {}).get("specReplicasPath")
    if not p or not p.startswith(".spec."):
        return None
    return tuple(p[len(".spec."):].split("."))


def _int_or_string(node: dict) -> bool:
    if node.get("x-kubernetes-int-or-string"):
        return True
    types = {a.get("type") for a in node.get("anyOf") or [] if isinstance(a, dict)}
    return types == {"integer", "string"}


def _is_resources(node: dict) -> bool:
    props = node.get("properties") or {}
    if not {"limits", "requests"} <= set(props):
        return False
    return all(_int_or_string((props[k].get("additionalProperties") or {})) for k in ("limits", "requests"))


def _immutable(node: dict) -> bool:
    return any(_IMMUTABLE_RULE.search(str(r.get("rule", ""))) for r in node.get("x-kubernetes-validations") or [])


def walk(schema: dict, source: str = "S5") -> dict[Path, Field]:
    out: dict[Path, Field] = {}

    def leaf(path: Path, node: dict, required: bool, immutable: bool, ftype: str) -> None:
        f = Field(path=path, type=ftype, description=(node.get("description") or "").strip(),
                  enum=list(node["enum"]) if isinstance(node.get("enum"), list) else None,
                  minimum=node.get("minimum"), maximum=node.get("maximum"), pattern=node.get("pattern"),
                  required=required, default=node.get("default"),
                  preserve_unknown=bool(node.get("x-kubernetes-preserve-unknown-fields")))
        f.sources.add(source)
        if immutable:
            f.mutability = Mutability.IMMUTABLE
        out[path] = f

    def rec(node: dict, path: Path, required: bool, immutable: bool, depth: int) -> None:
        if not isinstance(node, dict) or depth > MAX_DEPTH:
            return
        immutable = immutable or _immutable(node)
        if _int_or_string(node):
            leaf(path, node, required, immutable, "quantity")
            return
        ntype = node.get("type")
        if ntype == "object" or "properties" in node:
            if _is_resources(node):
                leaf(path, node, required, immutable, "resources")
                out[path].role = Role.RESOURCES
                return
            props = node.get("properties") or {}
            if path and (not props or node.get("x-kubernetes-preserve-unknown-fields")):
                leaf(path, node, required, immutable, "object")
            req = set(node.get("required") or [])
            for name, child in props.items():
                rec(child, path + (name,), name in req, immutable, depth + 1)
            return
        if ntype == "array":
            items = node.get("items") or {}
            if items.get("type") == "object" or "properties" in items:
                leaf(path, node, required, immutable, "array")
                rec(items, path + ("[]",), False, immutable, depth + 1)
            else:
                leaf(path, node, required, immutable, "array")
            return
        if path:
            leaf(path, node, required, immutable, ntype or "string")

    rec(schema, (), False, False, 0)
    return out


def walk_crd(crd: dict) -> dict[Path, Field]:
    fields = walk(spec_schema(crd))
    rp = scale_replicas_path(crd)
    if rp:
        f = fields.get(rp) or Field(path=rp, type="integer")
        f.role = Role.REPLICAS
        f.sources.add("S6")
        fields[rp] = f
    return fields
