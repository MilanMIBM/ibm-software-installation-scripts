"""ChainView: the dependency / ownership chains as widget rows, each with a GlowDot."""

from __future__ import annotations

from typing import ClassVar

from textual import events
from textual.app import ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Horizontal, VerticalScroll
from textual.message import Message
from textual.widgets import Label, ProgressBar, Static

from ..display import DRow
from ..model import State
from .glow_dot import GlowDot


class RowFocused(Message):
    def __init__(self, key: str | None):
        super().__init__()
        self.key = key


def guides(rows: list[DRow]) -> list[str]:
    """Tree guide prefixes (│ ├ └) for rows in DFS order."""
    n = len(rows)
    last = [True] * n
    for i, r in enumerate(rows):
        for j in range(i + 1, n):
            if rows[j].depth < r.depth:
                break
            if rows[j].depth == r.depth:
                last[i] = False
                break
    out, stack = [], []   # stack[d] = is the ancestor at depth d+1 the last child
    for i, r in enumerate(rows):
        d = r.depth
        stack = stack[:d - 1]
        prefix = "".join("  " if l else "│ " for l in stack[1:]) if d > 1 else ""
        if d > 1:
            prefix += "└ " if last[i] else "├ "
        out.append(prefix)
        stack.append(last[i])
    return out


class ToggleArrow(Static):
    """The ▶ / ▼ in front of a row: click it to expand or collapse the row's chain or sub-CR group."""

    DEFAULT_CSS = """
    ToggleArrow { width: 2; color: $text-muted; }
    ToggleArrow.-active { color: $text; }
    ToggleArrow.-active:hover { color: $accent; text-style: bold; background: $boost; }
    """

    def on_click(self, event: events.Click) -> None:
        event.stop()
        row = self.parent
        if isinstance(row, ChainRow) and row.drow.has_children:
            self.post_message(ChainView.Toggle(row.drow, None))


class ChainRow(Horizontal, can_focus=True):
    DEFAULT_CSS = """
    ChainRow { height: 1; width: 1fr; }
    ChainRow:focus { background: $boost; }
    ChainRow:focus .name { text-style: bold; }
    ChainRow .guide { width: auto; color: $text-muted; }
    ChainRow .name { width: auto; max-width: 48; text-wrap: nowrap; text-overflow: ellipsis; }
    ChainRow .why { width: 1fr; color: $text-muted; text-wrap: nowrap; text-overflow: ellipsis; margin-left: 1; }
    ChainRow ProgressBar { width: auto; margin-left: 1; }
    ChainRow ProgressBar Bar { width: 10; }
    ChainRow .badge { width: auto; color: $warning; margin-left: 1; }
    ChainRow.-ref .name, ChainRow.-group .name { color: $text-muted; text-style: italic; }
    """

    def __init__(self, drow: DRow):
        super().__init__()
        self.drow = drow
        self.key = drow.key

    def compose(self) -> ComposeResult:
        yield Static("", classes="guide")
        yield ToggleArrow("", classes="toggle")
        yield GlowDot()
        yield Label("", classes="name")
        yield Label("", classes="why")
        yield ProgressBar(total=100, show_eta=False, show_percentage=True)
        yield GlowDot(size="mini", classes="worst")
        yield Label("", classes="badge")

    def on_focus(self) -> None:
        self.post_message(RowFocused(self.drow.key if self.drow.kind != "group" else None))

    def fill(self, drow: DRow, guide: str, nodes: dict, collapsed: bool) -> None:
        self.drow = drow
        self.key = drow.key
        self.set_class(drow.kind == "ref", "-ref")
        self.set_class(drow.kind == "group", "-group")
        self.query_one(".guide", Static).update(guide)
        toggle = ("▶" if collapsed or (drow.kind == "group" and not drow.expanded) else "▼") if drow.has_children else " "
        arrow = self.query_one(ToggleArrow)
        arrow.update(toggle + " ")
        arrow.set_class(drow.has_children, "-active")
        dot = self.query_one(GlowDot)
        bar = self.query_one(ProgressBar)
        worst = self.query_one(".worst", GlowDot)
        name, why, badge = self.query_one(".name", Label), self.query_one(".why", Label), self.query_one(".badge", Label)
        if drow.kind == "group":
            dot.set_state(State.HEALTHY)
            name.update(f"+{drow.summary}" if not drow.expanded else drow.summary)
            why.update("")
            bar.display = False
            worst.display = False
            badge.update("")
            return
        n = nodes.get(drow.key)
        if n is None or n.verdict is None:
            return
        v = n.verdict
        dot.set_state(v.state, v.badge)
        if drow.kind == "ref":
            name.update(f"→ {n.label}")
            why.update("shown elsewhere")
            bar.display = False
            worst.display = False
            badge.update("")
            return
        name.update(n.label)
        why.update("" if v.state == State.HEALTHY else v.reason)
        show_bar = n.cr.progress is not None and v.state not in (State.HEALTHY, State.INACTIVE)
        bar.display = show_bar
        if show_bar:
            bar.update(progress=n.cr.progress)
        w = n.worst_desc
        worst.display = bool(w and w.severity < v.state.severity)   # something below is worse
        if worst.display:
            worst.set_state(w)
        tags = sorted({note.split(" ", 1)[0] for note in v.notices if note.split(" ", 1)[0].endswith("!")}
                      | ({"drift"} if any(nt.startswith("drift") for nt in v.notices) else set()))
        badge.update(" ".join(tags))


class ChainView(VerticalScroll, can_focus=False):
    BINDINGS: ClassVar[list[BindingType]] = [
        Binding("up,k", "move(-1)", "up", show=False),
        Binding("down,j", "move(1)", "down", show=False),
        Binding("left,h", "fold(True)", "collapse", show=False),
        Binding("right,l", "fold(False)", "expand", show=False),
        Binding("enter,space", "toggle", "expand/collapse", show=False),
    ]
    DEFAULT_CSS = """
    ChainView { border: round $panel-lighten-2; border-title-color: $text-muted; }
    ChainView:focus-within { border: round $primary; }
    """

    class Toggle(Message):
        def __init__(self, drow: DRow, collapse: bool | None):
            super().__init__()
            self.drow = drow
            self.collapse = collapse

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._ids: list[str] = []
        self._rows: list[ChainRow] = []
        self.border_title = "chains"
        self.border_subtitle = "click ▶ / ▼ (or ← →, enter) to expand / collapse"

    def rows(self) -> list[ChainRow]:
        return self._rows

    def show(self, drows: list[DRow], nodes: dict, collapsed: set[str]) -> None:
        visible: list[DRow] = []
        cut: int | None = None
        for d in drows:
            if cut is not None and d.depth > cut:
                continue
            cut = None
            visible.append(d)
            if d.row_id in collapsed and d.has_children:
                cut = d.depth
        ids = [d.row_id for d in visible]
        gl = guides(visible)
        if ids != self._ids:
            focused = self.app.focused
            keep = focused.drow.row_id if isinstance(focused, ChainRow) else None
            with self.app.batch_update():
                for r in self._rows:
                    r.remove()
                self._rows = [ChainRow(d) for d in visible]
                self.mount_all(self._rows)
            self._ids = ids
            self.call_after_refresh(self._fill_all, visible, gl, nodes, collapsed, keep)
        else:
            self._fill_all(visible, gl, nodes, collapsed, None)

    def _fill_all(self, visible, gl, nodes, collapsed, keep):
        for row, d, g in zip(self._rows, visible, gl):
            if row.is_mounted:
                row.fill(d, g, nodes, d.row_id in collapsed)
        if keep:
            for row in self._rows:
                if row.drow.row_id == keep:
                    row.focus(scroll_visible=False)
                    break

    def _index(self) -> int | None:
        f = self.app.focused
        return self._rows.index(f) if isinstance(f, ChainRow) and f in self._rows else None

    def action_move(self, delta: int) -> None:
        i = self._index()
        if not self._rows:
            return
        j = 0 if i is None else max(0, min(len(self._rows) - 1, i + delta))
        self._rows[j].focus()
        self._rows[j].scroll_visible()

    def action_fold(self, collapse: bool) -> None:
        i = self._index()
        if i is not None:
            self.post_message(self.Toggle(self._rows[i].drow, collapse))

    def action_toggle(self) -> None:
        i = self._index()
        if i is not None:
            self.post_message(self.Toggle(self._rows[i].drow, None))
