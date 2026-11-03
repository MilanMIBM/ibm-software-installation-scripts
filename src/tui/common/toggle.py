"""ToggleSetting: an on/off setting that reads without relying on colour.

Textual's own guidance for an on/off setting is the Switch widget (widget gallery,
docs/examples/widgets/switch.py: a label beside a Switch). Its knob sits left for off
and right for on, so the state shows in the shape, not only in a green tint the way a
Checkbox's X does. This adds an explicit ON / OFF word between the switch and the label.

  [▐▬▬  ] OFF  Also save the credentials in the Software Hub vault
  [  ▬▬▌] ON   Also save the credentials in the Software Hub vault

Click the switch, the word or the label, or press space/enter on the focused switch.
The inner Switch.Changed is stopped and ToggleSetting.Changed posted instead, so forms
that treat a bare Switch as a payload field never mistake a setting for one.
"""

from __future__ import annotations

from textual.app import ComposeResult
from textual.containers import Horizontal
from textual.events import Click
from textual.message import Message
from textual.widgets import Label, Switch

from .ui_util import set_text


class ToggleSetting(Horizontal):
    DEFAULT_CSS = """
    ToggleSetting { height: 3; width: 1fr; }
    ToggleSetting > Switch { margin: 0; }
    ToggleSetting > .ts-state { width: 5; height: 3; content-align: left middle; padding-left: 1;
        text-style: bold; color: $text-muted; }
    ToggleSetting.-on > .ts-state { color: $text-success; }
    ToggleSetting > .ts-label { width: 1fr; height: 3; content-align: left middle; padding-left: 1; }
    ToggleSetting.-compact > .ts-label { width: auto; padding-right: 2; }
    """

    class Changed(Message):
        """Posted when the value changes (handler: on_toggle_setting_changed)."""

        def __init__(self, toggle: ToggleSetting, value: bool) -> None:
            super().__init__()
            self.toggle = toggle
            self.value = value

        @property
        def control(self) -> ToggleSetting:
            return self.toggle

    def __init__(self, label: str, value: bool = False, *, on_word: str = "ON", off_word: str = "OFF",
                 compact: bool = False, tooltip: str | None = None, **kw):
        super().__init__(**kw)
        self.label, self._value = label, bool(value)
        self.on_word, self.off_word = on_word, off_word
        self.set_class(self._value, "-on")
        self.set_class(compact, "-compact")
        if tooltip:
            self.tooltip = tooltip

    def compose(self) -> ComposeResult:
        yield Switch(self._value, animate=False)
        yield Label(self._word(), classes="ts-state")
        yield Label(self.label, classes="ts-label")

    def _word(self) -> str:
        return self.on_word if self._value else self.off_word

    @property
    def value(self) -> bool:
        return self._value

    @value.setter
    def value(self, v: bool) -> None:
        """Set programmatically: no Changed message (like `with prevent(...)`)."""
        self._apply(bool(v), post=False)

    def toggle(self) -> None:
        self._apply(not self._value, post=True)

    def _apply(self, v: bool, post: bool) -> None:
        changed = v != self._value
        self._value = v
        self.set_class(v, "-on")
        found = self.query(Switch)
        if found and found.first().value != v:
            sw = found.first()
            with sw.prevent(Switch.Changed):
                sw.value = v
        if found:
            set_text(self.query_one(".ts-state", Label), self._word())
        if changed and post:
            self.post_message(self.Changed(self, v))

    def on_switch_changed(self, event: Switch.Changed) -> None:
        event.stop()
        if event.value != self._value:
            self._apply(event.value, post=True)

    def on_click(self, event: Click) -> None:
        # the Switch handles (and stops) its own clicks; the word and the label toggle too
        event.stop()
        self.toggle()
        self.query_one(Switch).focus()
