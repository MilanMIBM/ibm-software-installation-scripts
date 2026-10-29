"""GlowDot: the state dot, drawn and animated by Textual (no emoji).

Colour comes from the widget's CSS state class (-healthy, -failing, ...), which reads
the $dot-* variables the app registers. The glow is computed with textual.color.Color
blends against the background actually behind the widget:

  small  (3x1)  [halo][● core][halo]         chain view, CR list, header counts
  mini   (1x1)  [●]                           worst-descendant marker, no halo
  large  (8x3)  radial orb from half-blocks   detail header, legend screen
  plain  (5x1)  [ERR] text tag                NO_COLOR / --no-color

`glow` (0..1) is driven by the app's single PulseClock so every dot of a state pulses
in phase. Glyphs: U+25CF ●, U+25CB ○, U+2580 ▀ - one cell wide everywhere.
"""

from __future__ import annotations

import math

from rich.segment import Segment
from rich.style import Style
from rich.text import Text
from textual.color import Color
from textual.reactive import reactive
from textual.strip import Strip
from textual.widget import Widget

from ..model import State

DOT_COLORS = {
    State.HEALTHY: "#22c55e",
    State.PROGRESS: "#3b82f6",
    State.SCALING: "#a855f7",
    State.STUCK: "#eab308",
    State.FAILING: "#ef4444",
    State.INACTIVE: "#6b7280",
}
SHIMMER = "#c084fc"   # purple core tone at each peak
PERIOD = {State.FAILING: 1.0, State.STUCK: 2.5, State.SCALING: 1.6, State.PROGRESS: 2.0}
HALO = {State.HEALTHY: (0.18, 0.18), State.PROGRESS: (0.10, 0.22), State.SCALING: (0.10, 0.24),
        State.STUCK: (0.08, 0.22), State.FAILING: (0.12, 0.28), State.INACTIVE: (0.0, 0.0)}
STEADY = {State.HEALTHY: 0.6, State.INACTIVE: 0.0}


def css_class(state: State) -> str:
    return f"-{state.value}"


def glow_at(state: State, t: float) -> float:
    period = PERIOD.get(state)
    if period is None:
        return STEADY.get(state, 0.5)
    return 0.5 - 0.5 * math.cos(2 * math.pi * t / period)


def dot_colors(state: State, glow: float, base: Color, bg: Color, halo: bool = True):
    """(core_fg, core_bg, halo_bg) for one frame."""
    lo, hi = HALO[state]
    a = (lo + (hi - lo) * glow) if halo else 0.0
    if state == State.INACTIVE:
        core = base
    elif state == State.SCALING and glow > 0.85:
        core = Color.parse(SHIMMER)
    else:
        core = base.lighten(0.30 * glow)
    return core, bg.blend(base, a), bg.blend(base, a * 0.55)


def orb_pixels(state: State, glow: float, base: Color, bg: Color, cols: int = 8, rows: int = 6) -> list[list[Color]]:
    """Radial glow on a cols x rows pixel grid (2 pixels per terminal row, so pixels are ~square).

    Even dimensions keep the centre between pixels, giving a symmetric 2x2 hot core."""
    cx, cy = (cols - 1) / 2, (rows - 1) / 2
    radius = min(cx, cy) + 1.2
    scale = (0.62 + 0.38 * glow) if state != State.INACTIVE else 0.45
    hot = Color(255, 255, 255)
    grid = []
    for y in range(rows):
        line = []
        for x in range(cols):
            r = math.hypot(x - cx, y - cy)
            i = max(0.0, 1 - r / radius) ** 1.5 * scale
            c = bg.blend(base, min(1.0, i * 1.5))
            if r < 1.0 and state != State.INACTIVE:
                c = c.blend(hot, 0.20 + 0.30 * glow)
            line.append(c)
        grid.append(line)
    return grid


def as_content(state: State, badge: str = "filled", plain: bool = False) -> Text:
    """Static dot for text-only places (RichLog, compact mode): same colours, no pulse."""
    if plain:
        return Text(state.tag)
    glyph = "○" if badge == "ring" else "●"
    t = Text(glyph, style=Style(color=DOT_COLORS[state], bold=True))
    if badge == "unknown":
        t.append("?", style="dim")
    return t


class GlowDot(Widget):
    DEFAULT_CSS = """
    GlowDot { width: 3; height: 1; }
    GlowDot.-mini { width: 1; }
    GlowDot.-large { width: 8; height: 3; }
    GlowDot.-plain { width: 5; }
    GlowDot.-healthy { color: $dot-healthy; }
    GlowDot.-progress { color: $dot-progress; }
    GlowDot.-scaling { color: $dot-scaling; }
    GlowDot.-stuck { color: $dot-stuck; }
    GlowDot.-failing { color: $dot-failing; }
    GlowDot.-inactive { color: $dot-inactive; }
    """

    state: reactive[State] = reactive(State.INACTIVE)
    glow: reactive[float] = reactive(0.5)
    badge: reactive[str] = reactive("filled")

    def __init__(self, state: State = State.INACTIVE, badge: str = "filled", *, size: str = "small",
                 **kwargs):
        super().__init__(**kwargs)
        self.size_variant = size
        if size != "small":
            self.add_class(f"-{size}")
        self.set_reactive(GlowDot.state, state)
        self.set_reactive(GlowDot.badge, badge)
        self.add_class(css_class(state))
        self.set_reactive(GlowDot.glow, STEADY.get(state, 0.5))

    # -- lifecycle ---------------------------------------------------------
    def on_mount(self) -> None:
        if getattr(self.app, "plain", False) and self.size_variant != "large":
            self.add_class("-plain")
        clock = getattr(self.app, "pulse", None)
        if clock is not None:
            clock.register(self)

    def on_unmount(self) -> None:
        clock = getattr(self.app, "pulse", None)
        if clock is not None:
            clock.unregister(self)

    def watch_state(self, old: State, new: State) -> None:
        self.remove_class(css_class(old))
        self.add_class(css_class(new))
        if new not in PERIOD:
            self.glow = STEADY.get(new, 0.5)

    def set_state(self, state: State, badge: str = "filled") -> None:
        self.state = state
        self.badge = badge

    # -- drawing -------------------------------------------------------------
    def _colors(self) -> tuple[Color, Color]:
        base = self.styles.color
        if base is None or base.a == 0:
            base = Color.parse(DOT_COLORS[self.state])
        bg = self.background_colors[1]
        if bg.a < 1:
            bg = Color.parse(getattr(self.app, "dot_background", "#0c0f14")).blend(bg, bg.a)
        return base, bg

    def render_line(self, y: int) -> Strip:
        width = self.size.width
        if "-plain" in self.classes:
            if y:
                return Strip.blank(width)
            return Strip([Segment(self.state.tag.ljust(width)[:width])])
        base, bg = self._colors()
        halo = getattr(self.app, "halo", True)
        if self.size_variant == "large":
            return self._orb_line(y, base, bg, width)
        if y:
            return Strip.blank(width)
        core_fg, core_bg, halo_bg = dot_colors(self.state, self.glow, base, bg, halo and self.size_variant != "mini")
        glyph = "○" if self.badge == "ring" else "●"
        core = Segment(glyph, Style(color=core_fg.rich_color, bgcolor=core_bg.rich_color, bold=True))
        if self.size_variant == "mini":
            segs = [Segment(glyph, Style(color=core_fg.rich_color, bgcolor=bg.rich_color))]
        else:
            side = Style(bgcolor=halo_bg.rich_color)
            right = Segment("?" if self.badge == "unknown" else " ",
                            Style(color=base.rich_color, bgcolor=halo_bg.rich_color, dim=True))
            segs = [Segment(" ", side), core, right]
        return Strip(segs).extend_cell_length(width, Style(bgcolor=bg.rich_color)).crop(0, width)

    def _orb_line(self, y: int, base: Color, bg: Color, width: int) -> Strip:
        grid = orb_pixels(self.state, self.glow, base, bg)
        if y >= len(grid) // 2:
            return Strip.blank(width, Style(bgcolor=bg.rich_color))
        top, bottom = grid[2 * y], grid[2 * y + 1]
        segs = []
        for x in range(min(width, len(top))):
            segs.append(Segment("▀", Style(color=top[x].rich_color, bgcolor=bottom[x].rich_color)))
        if self.badge == "ring" and y == 1 and len(segs) > 4:
            for x in (3, 4):
                segs[x] = Segment("▀", Style(color=bg.blend(base, 0.15).rich_color,
                                             bgcolor=bg.blend(base, 0.15).rich_color))
        return Strip(segs).extend_cell_length(width, Style(bgcolor=bg.rich_color))
