"""Resizable panes: a Divider between two panes, dragged with the mouse or moved with the arrow keys.

The layout is locked by default (L toggles it, LayoutLock): locked dividers are hidden, so the
layout is exactly the stylesheet's. Unlocked, every divider shows as a 1-cell bar:
  drag it                 resizes the pane it belongs to (`target`, a selector of a sibling pane)
  focus it (Tab), ← → / ↑ ↓   the same by keyboard, 1 cell per press (shift: 5)
  double-click it, Enter  resets that pane to its stylesheet size
A dragged size is an inline style on the pane, so it wins over the stylesheet's classes until reset.
"""

from __future__ import annotations

from textual import events
from textual.binding import Binding
from textual.css.query import NoMatches
from textual.widget import Widget

MIN_PANE = 6


class Divider(Widget):
    """axis "x": between two columns, resizes target's width; "y": between two rows, its height.
    side: where the target sits relative to the divider ("before" = left / above)."""

    DEFAULT_CSS = """
    Divider { display: none; background: $panel-lighten-1; }
    Divider.-x { width: 1; height: 1fr; }
    Divider.-y { height: 1; width: 1fr; }
    Divider.-unlocked { display: block; }
    Divider:hover, Divider.-dragging { background: $accent; }
    Divider:focus { background: $accent-darken-1; }
    """
    BINDINGS = [Binding("left,up", "nudge(-1)", show=False), Binding("right,down", "nudge(1)", show=False),
                Binding("shift+left,shift+up", "nudge(-5)", show=False),
                Binding("shift+right,shift+down", "nudge(5)", show=False),
                Binding("enter", "reset", show=False)]

    def __init__(self, target: str, axis: str = "x", side: str = "before", minimum: int = MIN_PANE, **kw):
        super().__init__(**kw)
        self.target_sel, self.axis, self.side, self.minimum = target, axis, side, minimum
        self.add_class(f"-{axis}")
        self.can_focus = False
        self._drag: tuple[int, int] | None = None          # (pointer start, pane size at start)
        self.tooltip = "drag (or ← → ↑ ↓ when focused) to resize · double-click / Enter: reset"

    def render(self) -> str:
        return ""                          # a plain bar: the background colour is the whole look

    def set_locked(self, locked: bool) -> None:
        self.set_class(not locked, "-unlocked")
        self.can_focus = not locked
        if locked and self.has_focus:
            self.screen.set_focus(None)

    # -- the pane -----------------------------------------------------------------------------
    def _target(self) -> Widget | None:
        try:
            return self.parent.query_one(self.target_sel) if self.parent else None
        except NoMatches:
            return None

    def _extent(self, w: Widget) -> int:
        return w.outer_size.width if self.axis == "x" else w.outer_size.height

    def _room(self) -> int:
        """The most the target may take: the parent's size minus the other panes' minimums."""
        p = self.parent
        if p is None:
            return 10_000
        total = p.size.width if self.axis == "x" else p.size.height
        target = self._target()
        taken = sum(min(self._extent(c), self.minimum) if not isinstance(c, Divider) else self._extent(c)
                    for c in p.children if c.display and c is not target)
        return max(self.minimum, total - taken)

    def resize_to(self, cells: int) -> None:
        w = self._target()
        if w is None:
            return
        cells = max(self.minimum, min(cells, self._room()))
        if self.axis == "x":
            w.styles.width = cells
        else:
            w.styles.height = cells

    def action_nudge(self, step: int) -> None:
        w = self._target()
        if w is not None:
            self.resize_to(self._extent(w) + (step if self.side == "before" else -step))

    def action_reset(self) -> None:
        w = self._target()
        if w is not None:
            if self.axis == "x":
                w.styles.width = None
            else:
                w.styles.height = None

    # -- mouse ----------------------------------------------------------------------------------
    def on_mouse_down(self, event: events.MouseDown) -> None:
        w = self._target()
        if w is None or not self.has_class("-unlocked"):
            return
        event.stop()
        self._drag = (event.screen_x if self.axis == "x" else event.screen_y, self._extent(w))
        self.add_class("-dragging")
        self.capture_mouse()

    def on_mouse_move(self, event: events.MouseMove) -> None:
        if self._drag is None:
            return
        event.stop()
        start, size = self._drag
        delta = (event.screen_x if self.axis == "x" else event.screen_y) - start
        self.resize_to(size + (delta if self.side == "before" else -delta))

    def on_mouse_up(self, event: events.MouseUp) -> None:
        if self._drag is not None:
            event.stop()
            self._drag = None
            self.remove_class("-dragging")
            self.release_mouse()

    def on_click(self, event: events.Click) -> None:
        if event.chain >= 2 and self.has_class("-unlocked"):
            event.stop()
            self.action_reset()


class LayoutLock:
    """App mixin: `L` toggles the layout lock (locked at start); dividers follow it."""

    layout_locked: bool = True

    def action_toggle_layout_lock(self) -> None:
        self.layout_locked = not self.layout_locked
        self.apply_layout_lock()
        self.notify("layout unlocked: drag the bars between panes (Tab + arrows; double-click resets)"
                    if not self.layout_locked else "layout locked")

    def apply_layout_lock(self) -> None:
        for d in self.screen_stack[0].query(Divider):
            d.set_locked(self.layout_locked)
