"""Value-alias groups (plan §3): paths of one CR that always carry the same value.

Wrapper CRs copy the create payload to several places (EDB: parameters.numberofnodes =
numberofnodes = members; ssize+sunit = storageSize; corespernode = resources.limits.cpu).
An edit must change the whole group. A pair counts when, on every instance that has both:
  A  same leaf name and equal value
  B  equal distinctive strings (non-numeric, >= 4 chars)
  C  equal numbers and the same (non-OTHER) role
  D  number == the number part of a quantity, same role ("4" ~ "4Gi")
Held on >= 2 instances -> confirmed; on one -> candidate (the preview asks).
"""

from __future__ import annotations

import re

from ..model import Field, Path, Role
from .observed import Flat
from .roles import leaf_name

_NUM = re.compile(r"^([0-9]+(?:\.[0-9]+)?)([a-zA-Z]{0,2})$")
_GROUP_ROLES = (Role.REPLICAS, Role.CPU, Role.MEMORY, Role.STORAGE_SIZE, Role.UNIT, Role.SIZE_PRESET,
                Role.STORAGE_CLASS, Role.VERSION, Role.SECRET_REF, Role.LIFECYCLE)


def _num(v) -> tuple[float, str] | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v), ""
    if isinstance(v, str):
        m = _NUM.match(v.strip())
        if m:
            return float(m.group(1)), m.group(2)
    return None


def _pair_holds(a: Path, b: Path, va, vb, fields: dict[Path, Field]) -> bool:
    fa, fb = fields.get(a), fields.get(b)
    ra = fa.role if fa else Role.OTHER
    rb = fb.role if fb else Role.OTHER
    if leaf_name(a) == leaf_name(b) and va == vb:
        return True                                                       # A
    na, nb = _num(va), _num(vb)
    if na is None and nb is None:
        return (isinstance(va, str) and va == vb and len(va) >= 4
                and va.lower() not in ("true", "false", "none", "default"))  # B
    if na is None or nb is None or ra != rb or ra == Role.OTHER:
        return False
    if na[0] != nb[0]:
        return False
    return na[1] == nb[1] or not na[1] or not nb[1]                       # C / D


def detect(fields: dict[Path, Field], flats: list[Flat]) -> list[list[Path]]:
    cand = [p for p, f in fields.items() if f.role in _GROUP_ROLES or f.type in ("string", "integer", "number")]
    cand = [p for p in cand if any(flat.get(p) is not None for flat in flats)]
    held: dict[tuple[Path, Path], int] = {}
    broken: set[tuple[Path, Path]] = set()
    for flat in flats:
        present = [p for p in cand if flat.get(p) is not None]
        for i, a in enumerate(present):
            for b in present[i + 1:]:
                key = (a, b)
                if key in broken:
                    continue
                if _pair_holds(a, b, flat[a], flat[b], fields):
                    held[key] = held.get(key, 0) + 1
                else:
                    broken.add(key)
                    held.pop(key, None)
    # keep pairs where at least one side has a meaningful role (the rest is noise for editing)
    pairs = {k: n for k, n in held.items() if k not in broken
             and (fields[k[0]].role in _GROUP_ROLES or fields[k[1]].role in _GROUP_ROLES)}
    parent: dict[Path, Path] = {}

    def find(x: Path) -> Path:
        while parent.get(x, x) != x:
            x = parent[x]
        return x

    for a, b in pairs:
        parent[find(a)] = find(b)
    groups: dict[Path, list[Path]] = {}
    for p in {p for k in pairs for p in k}:
        groups.setdefault(find(p), []).append(p)
    out = []
    for members in groups.values():
        members.sort(key=lambda p: (len(p), p))
        confirmed = all(pairs.get((a, b), pairs.get((b, a), 0)) >= 2
                        for i, a in enumerate(members) for b in members[i + 1:]
                        if (a, b) in pairs or (b, a) in pairs)
        for p in members:
            fields[p].aliases = [q for q in members if q != p]
            fields[p].alias_confirmed = confirmed
        out.append(members)
    return out
