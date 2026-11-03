"""Weighted build progress (cache plan §2.8): every part reports done/total/%.

Weights are the expected seconds of each part (its took_s from the last build, else the §1
baseline), so the bar moves evenly although one S4 get takes 1.2 s and a CRD read 0.1 s.
Sinks:
  TerminalBar  stderr; a redrawn bar on a TTY, plain `[k/N  pct%] part ... took` lines otherwise
  a callable   the TUI: called with the Progress after every change (from the build thread)
stdout is never touched, so the headless modes' output stays byte-identical.
"""

from __future__ import annotations

import sys
import time
from collections.abc import Callable
from dataclasses import dataclass

BAR = 24


@dataclass
class Part:
    key: str
    label: str
    what: str = ""
    weight: float = 1.0
    state: str = "queued"          # queued | running | done | failed | skipped
    took: float | None = None
    error: str = ""


class Progress:
    def __init__(self, parts: list[Part], sink: Callable[[Progress], None] | None = None, title: str = "cache"):
        self.parts = parts
        self.sink = sink
        self.title = title
        self.t0 = time.monotonic()
        self.current: Part | None = None
        self.finished = False

    # -- numbers ------------------------------------------------------------------------
    @property
    def total(self) -> int:
        return len(self.parts)

    @property
    def done_count(self) -> int:
        return sum(1 for p in self.parts if p.state in ("done", "failed", "skipped"))

    @property
    def fraction(self) -> float:
        total = sum(p.weight for p in self.parts) or 1.0
        done = sum(p.weight for p in self.parts if p.state in ("done", "failed", "skipped"))
        return min(1.0, done / total)

    @property
    def elapsed(self) -> float:
        return time.monotonic() - self.t0

    @property
    def eta(self) -> float | None:
        f = self.fraction
        if f <= 0.02 or f >= 1.0:
            return None
        return self.elapsed * (1 - f) / f

    def part(self, key: str) -> Part | None:
        return next((p for p in self.parts if p.key == key), None)

    # -- updates ----------------------------------------------------------------------------
    def add(self, part: Part) -> Part:
        self.parts.append(part)
        self._emit()
        return part

    def start(self, key: str) -> None:
        p = self.part(key)
        if p:
            p.state = "running"
            self.current = p
            self._emit()

    def done(self, key: str, took: float, ok: bool = True, error: str = "") -> None:
        p = self.part(key)
        if p:
            p.state, p.took, p.error = ("done" if ok else "failed"), took, error
            self._emit()

    def skip(self, key: str) -> None:
        p = self.part(key)
        if p:
            p.state, p.took = "skipped", 0.0
            self._emit()

    def finish(self) -> None:
        self.finished = True
        self.current = None
        self._emit()

    def _emit(self) -> None:
        if self.sink:
            self.sink(self)

    def run(self, key: str, fn: Callable[[], object]):
        """start -> fn() -> done (or failed, re-raised as a part error, never fatal)."""
        self.start(key)
        t = time.monotonic()
        try:
            out = fn()
        except Exception as e:      # noqa: BLE001 - a failed part is reported, the build goes on
            self.done(key, time.monotonic() - t, ok=False, error=str(e).splitlines()[0][:160] if str(e) else
                      type(e).__name__)
            return None
        self.done(key, time.monotonic() - t)
        return out


def bar_line(pr: Progress) -> str:
    f = pr.fraction
    filled = int(round(f * BAR))
    cur = pr.current
    what = f"  {cur.label}" + (f" ({cur.what})" if cur and cur.what else "") if cur else ""
    eta = f"  eta {pr.eta:.0f}s" if pr.eta is not None else ""
    return (f"[{'█' * filled}{'░' * (BAR - filled)}] {pr.done_count}/{pr.total}  {int(f * 100):3d}%"
            f"{what}  {pr.elapsed:.1f}s{eta}")


class TerminalBar:
    """stderr sink. TTY: one redrawn bar line, and a line per finished part. Else: plain lines."""

    def __init__(self, stream=None, tty: bool | None = None):
        self.stream = stream or sys.stderr
        self.tty = self.stream.isatty() if tty is None else tty
        self._reported: set[str] = set()
        self._width = 0

    def __call__(self, pr: Progress) -> None:
        for p in pr.parts:
            if p.state in ("done", "failed") and p.key not in self._reported:
                self._reported.add(p.key)
                n = len(self._reported)
                pct = int(pr.fraction * 100)
                tail = f" FAILED: {p.error}" if p.state == "failed" else ""
                self._line(f"[{pr.title} {n}/{pr.total} {pct:3d}%] {p.label}"
                           + (f" ({p.what})" if p.what else "") + f" took {p.took:.1f}s{tail}")
        if self.tty and not pr.finished:
            line = bar_line(pr)
            self.stream.write("\r" + line.ljust(self._width))
            self._width = len(line)
            self.stream.flush()
        if pr.finished and self.tty:
            self.stream.write("\r" + " " * self._width + "\r")
            self.stream.flush()

    def _line(self, text: str) -> None:
        if self.tty:
            self.stream.write("\r" + text.ljust(self._width) + "\n")
            self._width = 0
        else:
            self.stream.write(text + "\n")
        self.stream.flush()
