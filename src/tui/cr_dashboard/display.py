"""Forest rows -> display rows: groups runs of healthy non-component sub-CRs into one
expandable "+N healthy sub-CRs" row, so components stay readable. Problems are never grouped."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field

from .graph import Row
from .model import State

QUIET = (State.HEALTHY, State.INACTIVE)


@dataclass
class DRow:
    kind: str                 # node | ref | group
    key: str                  # node key (node/ref) or group id
    depth: int
    row_id: str
    members: list[str] = field(default_factory=list)   # group: member node keys (incl. their subtrees)
    summary: str = ""
    expanded: bool = False
    has_children: bool = False


def _tree(rows: list[Row]):
    """children[i] = indices of direct children of row i (-1 = virtual root)."""
    children: dict[int, list[int]] = {-1: []}
    stack: list[tuple[int, int]] = []
    for i, r in enumerate(rows):
        while stack and stack[-1][0] >= r.depth:
            stack.pop()
        parent = stack[-1][1] if stack else -1
        children.setdefault(parent, []).append(i)
        children.setdefault(i, [])
        stack.append((r.depth, i))
    return children


def display_rows(rows: list[Row], nodes: dict, expanded_groups: set[str] | None = None,
                 group_min: int = 2) -> list[DRow]:
    expanded_groups = expanded_groups or set()
    children = _tree(rows)
    out: list[DRow] = []

    def quiet_subtree(i: int) -> bool:
        r = rows[i]
        if r.ref_of is not None:
            return True
        n = nodes.get(r.key)
        if n is None or n.is_component or n.verdict is None or n.verdict.state not in QUIET:
            return False
        return all(quiet_subtree(c) for c in children[i])

    def subtree_keys(i: int) -> list[str]:
        r = rows[i]
        keys = [] if r.ref_of is not None else [r.key]
        for c in children[i]:
            keys += subtree_keys(c)
        return keys

    def emit(i: int, path: str, off: int):
        r = rows[i]
        rid = f"{path}>{r.ref_of or r.key}" + ("@ref" if r.ref_of else "")
        if r.ref_of is not None:
            out.append(DRow("ref", r.ref_of, r.depth + off, rid))
            return
        out.append(DRow("node", r.key, r.depth + off, rid, has_children=bool(children[i])))
        emit_children(i, rid, off)

    def emit_children(i: int, path: str, off: int):
        kids = children[i]
        quiet = [c for c in kids if quiet_subtree(c)]
        if len(quiet) >= group_min:
            gid = f"{path}#quiet"
            members = [k for c in quiet for k in subtree_keys(c)]
            kinds = Counter(nodes[rows[c].key].ref.kind for c in quiet if rows[c].ref_of is None)
            summary = ", ".join(f"{k} ×{n}" if n > 1 else k for k, n in kinds.most_common(4))
            exp = gid in expanded_groups
            for c in kids:
                if c not in quiet:
                    emit(c, path, off)
            out.append(DRow("group", gid, rows[quiet[0]].depth + off, gid, members=members, expanded=exp,
                            has_children=True, summary=f"{len(quiet)} healthy sub-CRs ({summary})"))
            if exp:
                for c in quiet:
                    emit(c, gid, off + 1)
            return
        for c in kids:
            emit(c, path, off)

    emit_children(-1, "", 0)
    return out
