"""Opt-in timing spans (cache plan C0): `--timings` or INSTANCE_MANAGER_TIMINGS=1.

span("name") around a slow call records (name, start, duration, thread). Off by default and
then costs one flag check. report() prints one line per span name (count, total, max, first
start relative to process start) on stderr when the process ends, so stdout of the headless
modes stays unchanged.
"""

from __future__ import annotations

import atexit
import os
import sys
import threading
import time
from collections.abc import Callable
from contextlib import contextmanager
from functools import wraps

ENV = "INSTANCE_MANAGER_TIMINGS"
_T0 = time.monotonic()
_lock = threading.Lock()
_spans: list[tuple[str, float, float, str]] = []
_on = os.environ.get(ENV, "").strip().lower() in ("1", "true", "yes", "on")
_registered = False


def enable(on: bool = True) -> None:
    global _on, _registered
    _on = on
    if on and not _registered:
        _registered = True
        atexit.register(report)


def enabled() -> bool:
    return _on


def record(name: str, start: float, took: float) -> None:
    with _lock:
        _spans.append((name, start - _T0, took, threading.current_thread().name))


@contextmanager
def span(name: str):
    if not _on:
        yield
        return
    t = time.monotonic()
    try:
        yield
    finally:
        record(name, t, time.monotonic() - t)


def timed(name: str | Callable[..., str]):
    """Decorator; `name` may be a function of the call's arguments (e.g. the type key)."""
    def deco(fn):
        @wraps(fn)
        def wrapper(*a, **kw):
            if not _on:
                return fn(*a, **kw)
            label = name(*a, **kw) if callable(name) else name
            with span(label):
                return fn(*a, **kw)
        return wrapper
    return deco


def spans() -> list[tuple[str, float, float, str]]:
    with _lock:
        return list(_spans)


def reset() -> None:
    with _lock:
        _spans.clear()


def report(file=None) -> None:
    file = file or sys.stderr
    rows = spans()
    if not rows:
        return
    agg: dict[str, list] = {}
    for name, start, took, _thread in rows:
        a = agg.setdefault(name, [0, 0.0, 0.0, start])
        a[0] += 1
        a[1] += took
        a[2] = max(a[2], took)
        a[3] = min(a[3], start)
    wall = max(s + t for _, s, t, _ in rows)
    print(f"\ntimings: {len(rows)} span(s), {wall:.2f}s from start to the last span's end", file=file)
    print(f"  {'span':<44}{'n':>4}{'total':>9}{'max':>9}{'first@':>9}", file=file)
    for name, (n, total, mx, first) in sorted(agg.items(), key=lambda kv: kv[1][3]):
        print(f"  {name[:44]:<44}{n:>4}{total:>8.2f}s{mx:>8.2f}s{first:>8.2f}s", file=file)


if _on:
    enable(True)
