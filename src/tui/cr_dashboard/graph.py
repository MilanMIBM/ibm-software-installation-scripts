"""Edges between CRs, the displayed chain forest, the D11 scope filter and fold-up.

Edge priority for the tree: WAITS (live, from the operator's current task) > OWNS
(ownerReferences) > DEPENDS (static component dependencies, only when enabled).
Component CRs are shown at any depth; non-component CRs only to depth `max_depth`
(root = 1). Hidden CRs fold into their nearest shown ancestor.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .model import Edge, EdgeType

WAIT_PATTERNS = [
    re.compile(r"wait(?:ing)?\s+(?:until|for)\s+cr\s+(?:is\s+)?(?:completed|ready)\s*[:\-]\s*(?P<t>[\w.\-]+)", re.IGNORECASE),
    re.compile(r"wait(?:ing)?\s+(?:until|for)\s+(?P<t>[\w.\-]+)\s+(?:cr\s+)?(?:is\s+|to\s+be\s+|installation\s+to\s+)?"
               r"(?:completed?|ready|installed|available|reconciled|complete)", re.IGNORECASE),
    re.compile(r"wait(?:ing)?\s+(?:until|for)\s+(?P<t>[\w.\-]+)\s+(?:cr|instance|deployment)\b", re.IGNORECASE),
]
_STOP = {"the", "all", "cr", "crs", "pods", "pod", "deployment", "deployments", "services", "service", "jobs", "job",
         "resources", "it", "operator", "install", "installation"}


def wait_target(task: str | None) -> str | None:
    if not task:
        return None
    for pat in WAIT_PATTERNS:
        m = pat.search(task)
        if m and m.group("t").lower() not in _STOP:
            return m.group("t")
    return None


def reduce_depends(deps: dict[str, list[str]]) -> dict[str, list[str]]:
    """Transitive reduction of a component -> [dependencies] map (restricted to known keys)."""
    known = set(deps)
    closure: dict[str, set[str]] = {}

    def reach(c: str, seen: frozenset = frozenset()) -> set[str]:
        if c in closure:
            return closure[c]
        out: set[str] = set()
        for d in deps.get(c, []):
            if d in known and d not in seen and d != c:
                out.add(d)
                out |= reach(d, seen | {c})
        closure[c] = out
        return out

    reduced = {}
    for c, ds in deps.items():
        direct = [d for d in ds if d in known and d != c]
        reduced[c] = [d for d in direct if not any(d in reach(o) for o in direct if o != d)]
    return reduced


@dataclass
class Row:
    key: str
    depth: int
    parent: str | None
    ref_of: str | None = None          # set on reference rows ("→ X"): the key shown elsewhere


@dataclass
class Forest:
    rows: list[Row]                     # DFS order; a row's subtree = following rows with greater depth
    shown: set[str]
    folded: dict[str, str]              # hidden key -> nearest shown ancestor key
    parent_of: dict[str, str]           # primary parent per key (shown or hidden)
    depth_of: dict[str, int]


PRIORITY = {EdgeType.WAITS: 0, EdgeType.OWNS: 1, EdgeType.DEPENDS: 2}


def build_forest(keys: list[str], edges: list[Edge], *, is_component: dict[str, bool], max_depth: int | None,
                 sort_key=lambda k: k, use_types=(EdgeType.WAITS, EdgeType.OWNS),
                 priority: dict[EdgeType, int] | None = None) -> Forest:
    prio = priority or PRIORITY
    keyset = set(keys)
    cands: dict[str, list[Edge]] = {}
    for e in edges:
        if e.type in use_types and e.src in keyset and e.dst in keyset and e.src != e.dst:
            cands.setdefault(e.dst, []).append(e)

    parent_of: dict[str, str] = {}

    def creates_cycle(child: str, parent: str) -> bool:
        cur, hops = parent, 0
        while cur is not None and hops < 200:
            if cur == child:
                return True
            cur, hops = parent_of.get(cur), hops + 1
        return False

    extra: dict[str, list[str]] = {}
    for child in sorted(cands, key=sort_key):
        ordered = sorted(cands[child], key=lambda e: (prio[e.type], e.rank, sort_key(e.src)))
        chosen = None
        for e in ordered:
            if chosen is None and not creates_cycle(child, e.src):
                chosen = e.src
                parent_of[child] = chosen
            elif chosen is not None and e.src != chosen and e.type != EdgeType.DEPENDS:
                extra.setdefault(e.src, []).append(child)

    children: dict[str, list[str]] = {}
    for c, p in parent_of.items():
        children.setdefault(p, []).append(c)
    roots = sorted([k for k in keys if k not in parent_of], key=sort_key)

    depth_of: dict[str, int] = {}
    shown: set[str] = set()
    folded: dict[str, str] = {}
    rows: list[Row] = []

    def visit(key: str, depth: int, shown_parent: str | None, shown_depth: int, guard: set[str]):
        if key in guard:
            return
        guard = guard | {key}
        depth_of[key] = depth
        visible = is_component.get(key, False) or max_depth is None or depth <= max_depth
        next_shown_depth = shown_depth
        if visible:
            shown.add(key)
            rows.append(Row(key, shown_depth + 1, shown_parent))
            next_shown_depth = shown_depth + 1
            sp = key
        else:
            folded[key] = shown_parent if shown_parent else key
            sp = shown_parent
        for c in sorted(children.get(key, []), key=sort_key):
            visit(c, depth + 1, sp, next_shown_depth, guard)
        if visible:
            for ref in sorted(extra.get(key, []), key=sort_key):
                rows.append(Row(f"{key}->{ref}", next_shown_depth + 1, key, ref_of=ref))

    for r in roots:
        visit(r, 1, None, 0, set())
    # keys never reached (cycle leftovers) become roots
    for k in sorted(set(keys) - set(depth_of), key=sort_key):
        visit(k, 1, None, 0, set())
    # a hidden root has no shown ancestor: show it after all
    for k, anc in list(folded.items()):
        if anc == k:
            del folded[k]
    # drop reference rows that point at hidden keys
    rows = [r for r in rows if r.ref_of is None or r.ref_of in shown]
    return Forest(rows, shown, folded, parent_of, depth_of)
