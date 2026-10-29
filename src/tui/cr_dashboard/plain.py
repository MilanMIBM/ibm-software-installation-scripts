"""--once / --exit-when-settled output: the current view as text on stdout (writes no files)."""

from __future__ import annotations

import os
import sys

from rich.console import Console
from rich.text import Text

from .display import display_rows
from .model import State
from .store import View

DOT_HEX = {State.HEALTHY: "#22c55e", State.PROGRESS: "#3b82f6", State.SCALING: "#a855f7",
           State.STUCK: "#eab308", State.FAILING: "#ef4444", State.INACTIVE: "#6b7280"}


def _dot(state: State, badge: str, color: bool) -> Text:
    if not color:
        return Text(state.tag)
    glyph = "○" if badge == "ring" else "●"
    t = Text(glyph, style=f"bold {DOT_HEX[state]}")
    if badge == "unknown":
        t.append("?", style="dim")
    return t


def render(view: View, header: str, color: bool | None = None, width: int | None = None) -> None:
    if color is None:
        color = sys.stdout.isatty() and "NO_COLOR" not in os.environ
    con = Console(highlight=False, emoji=False, no_color=not color, width=width or None,
                  force_terminal=color or None, soft_wrap=True)   # one line per CR, even when piped
    con.print(Text(header, style="bold" if color else ""))
    counts = Text()
    for st in State:
        counts.append_text(_dot(st, "filled", color))
        counts.append(f" {view.counts.get(st, 0)} {st.word}   ")
    con.print(counts)
    if view.loading:
        con.print("(some resources were still loading)")
    for k in view.root_problems:
        n = view.nodes[k]
        line = Text("ROOT PROBLEM ")
        line.append_text(_dot(n.verdict.state, n.verdict.badge, color))
        line.append(f" {n.label}: {n.verdict.reason}")
        con.print(line)
    con.print()
    in_tree = set()
    for d in display_rows(view.rows, view.nodes):
        line = Text("  " * (d.depth - 1))
        if d.kind == "group":
            in_tree |= set(d.members)
            line.append_text(_dot(State.HEALTHY, "filled", color))
            line.append(f" +{d.summary}", style="dim" if color else "")
            con.print(line)
            continue
        n = view.nodes.get(d.key)
        if n is None:
            continue
        in_tree.add(d.key)
        if d.kind == "ref":
            line.append(f"→ {n.label} (shown elsewhere)", style="dim")
            con.print(line)
            continue
        line.append_text(_dot(n.verdict.state, n.verdict.badge, color))
        line.append(f" {n.label}")
        if n.cr.progress is not None and n.verdict.state not in (State.HEALTHY, State.INACTIVE):
            line.append(f" {n.cr.progress}%")
        line.append(f"  {n.verdict.reason}", style="dim" if color else "")
        if n.worst_desc and n.worst_desc.severity < n.verdict.state.severity:
            line.append("  (below: ")
            line.append_text(_dot(n.worst_desc, "filled", color))
            line.append(")")
        for note in n.verdict.notices:
            line.append(f"  [{note}]", style="yellow" if color else "")
        con.print(line)
    rest = [k for k in view.list_keys if k not in in_tree]
    if rest:
        con.print()
        con.print("Not in the chain view:")
        for k in sorted(rest, key=lambda k: view.nodes[k].label):
            n = view.nodes[k]
            line = Text("  ")
            line.append_text(_dot(n.verdict.state, n.verdict.badge, color))
            line.append(f" {n.component or n.label}  {n.verdict.reason}")
            con.print(line)
    for note in view.notes:
        con.print(f"[note] {note}", markup=False)
    for err in view.errors:
        con.print(f"[source] {err}", markup=False)
