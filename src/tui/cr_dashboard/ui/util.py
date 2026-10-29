"""Smooth updates: touch a widget only when what it shows changes, and keep row widgets
in place (reorder / insert / remove) instead of rebuilding a whole list on every refresh."""

from __future__ import annotations

from collections.abc import Callable, Hashable, Iterable

_UNSET = object()


def set_text(widget, value) -> bool:
    """widget.update(value) only when value differs from what it shows (Rich Text compares by
    text and spans). Returns True when it updated."""
    if getattr(widget, "_shown_value", _UNSET) == value:
        return False
    widget._shown_value = value
    widget.update(value)
    return True


def set_display(widget, on: bool) -> None:
    if widget.display != on:
        widget.display = on


def set_attr(obj, name: str, value) -> None:
    """Assign only on change (border titles and similar properties repaint when assigned)."""
    if getattr(obj, name) != value:
        setattr(obj, name, value)


def reconcile(container, current: list, wanted_keys: Iterable[Hashable], key_of: Callable,
              make: Callable, first_anchor=None) -> tuple[list, set]:
    """Bring `container`'s row widgets to `wanted_keys`, in that order, with the fewest DOM changes.

    Rows whose key is still wanted are reused, so they keep focus, scroll position and their
    glow, and are not repainted from scratch. Rows that disappeared are removed; new ones are
    made with `make(key)` and mounted next to their neighbours. `first_anchor` is a fixed
    child that stays above the rows (e.g. a header).
    Returns (rows in wanted order, set of newly made rows).
    """
    wanted_keys = list(wanted_keys)
    wanted = set(wanted_keys)
    by_key = {key_of(w): w for w in current}
    for w in current:
        if key_of(w) not in wanted:
            w.remove()
    rows, fresh = [], set()
    for k in wanted_keys:
        w = by_key.get(k)
        if w is None:
            w = make(k)
            fresh.add(w)
        rows.append(w)

    kept_now = [w for w in current if key_of(w) in wanted]
    kept_want = [w for w in rows if w not in fresh]
    if kept_now != kept_want:
        prev = first_anchor
        for w in kept_want:
            if prev is None:
                container.move_child(w, before=0)
            else:
                container.move_child(w, after=prev)
            prev = w

    prev = first_anchor
    for w in rows:
        if w in fresh:
            if prev is not None:
                container.mount(w, after=prev)
            elif container.children:
                container.mount(w, before=container.children[0])
            else:
                container.mount(w)
        prev = w
    return rows, fresh
