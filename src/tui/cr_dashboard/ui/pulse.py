"""PulseClock: one timer drives every GlowDot, so dots of a state pulse in phase."""

from __future__ import annotations

import time
import weakref

from .glow_dot import PERIOD, STEADY, GlowDot, glow_at

FPS = 8
FPS_BUSY = 4
BUSY_ABOVE = 150


class PulseClock:
    def __init__(self, app, animate: bool = True):
        self.app = app
        self.animate = animate
        self.dots: weakref.WeakSet[GlowDot] = weakref.WeakSet()
        self.t0 = time.monotonic()
        self._timer = None
        self._fps = FPS

    def register(self, dot: GlowDot) -> None:
        self.dots.add(dot)

    def unregister(self, dot: GlowDot) -> None:
        self.dots.discard(dot)

    def start(self) -> None:
        self._timer = self.app.set_interval(1 / self._fps, self.tick)

    def set_animate(self, on: bool) -> None:
        self.animate = on
        if not on:
            for d in list(self.dots):
                d.glow = 0.5 if d.state in PERIOD else STEADY.get(d.state, 0.5)

    def tick(self, t: float | None = None) -> None:
        if not self.animate:
            return
        t = (time.monotonic() - self.t0) if t is None else t
        animated = [d for d in list(self.dots) if d.state in PERIOD and d.is_mounted and d.display]
        want = FPS_BUSY if len(animated) > BUSY_ABOVE else FPS
        if want != self._fps and self._timer is not None:
            self._fps = want
            self._timer.stop()
            self._timer = self.app.set_interval(1 / want, self.tick)
        for d in animated:
            d.glow = glow_at(d.state, t)
