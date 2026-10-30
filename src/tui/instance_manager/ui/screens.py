"""Modal screens: profile panel (status, repair, auto-repair toggle), explain, legend."""

from __future__ import annotations

import io
from typing import ClassVar

from rich.console import Console
from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Label, Static

from ...common.glow_dot import GlowDot
from ...common.state import State
from ..model import FormModel, InstanceType, Kind
from .storage_kind_tag import KIND_COLORS

MODAL_CSS = """
{name} {{ align: center middle; }}
{name} > Vertical {{ width: 90%; max-width: 120; height: auto; max-height: 90%;
    border: round $accent; background: $surface; padding: 1 2; }}
{name} .title {{ text-style: bold; margin-bottom: 1; }}
{name} Horizontal {{ height: auto; margin-top: 1; }}
{name} Button {{ margin-right: 2; }}
"""


class ProfileScreen(ModalScreen):
    """D10: the cpd-cli profile. Toggling auto-repair saves it for this cluster + config."""

    DEFAULT_CSS = MODAL_CSS.format(name="ProfileScreen")
    BINDINGS: ClassVar[list[BindingType]] = [Binding("escape", "dismiss", "close")]

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("cpd-cli profile", classes="title")
            yield Static("", id="profile-body")
            with Horizontal():
                yield Button("Repair now", id="repair", variant="warning")
                yield Button("", id="toggle")
                yield Button("Close", id="close")

    def on_mount(self) -> None:
        self.refresh_body()

    def refresh_body(self) -> None:
        ctx = self.app.profile_ctx
        st = ctx.status
        t = Text()
        for k, v in (("state", st.tag if st else "unknown"), ("profile", st.profile if st else "-"),
                     ("profile url", (st.url if st else "") or "-"), ("cluster url", (st.live_url if st else "") or "-"),
                     ("detail", (st.detail if st else "") or "-"),
                     ("auto-repair", f"{'on' if ctx.auto else 'off'} ({ctx.source})")):
            t.append(f"{k:<13}", style="dim")
            t.append(f"{v}\n")
        t.append("\nAuto-repair is saved for this cluster + config until you switch it off. It only acts when the "
                 "profile is broken; a healthy profile is never touched.", style="dim")
        self.query_one("#profile-body", Static).update(t)
        self.query_one("#toggle", Button).label = f"Auto-repair: {'on' if ctx.auto else 'off'}"
        self.query_one("#repair", Button).disabled = bool(st and st.ok) or ctx.busy

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "close":
            self.dismiss()
        elif event.button.id == "toggle":
            self.app.action_toggle_auto_repair()
            self.refresh_body()
        elif event.button.id == "repair":
            self.app.action_repair_profile()
            self.refresh_body()


def _render_model(itype: InstanceType, fm: FormModel) -> Text:
    from ..report import _print_model
    buf = io.StringIO()
    con = Console(file=buf, force_terminal=True, color_system="truecolor", width=220, soft_wrap=True)
    _print_model(con, itype, fm, all_fields=False)
    return Text.from_ansi(buf.getvalue())


class ExplainScreen(ModalScreen):
    DEFAULT_CSS = MODAL_CSS.format(name="ExplainScreen") + "ExplainScreen VerticalScroll { height: 40; }"
    BINDINGS: ClassVar[list[BindingType]] = [Binding("escape", "dismiss", "close"), Binding("x", "dismiss", "close")]

    def __init__(self, itype: InstanceType, fm: FormModel):
        super().__init__()
        self.itype, self.fm = itype, fm

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label(f"discovered fields · {self.itype.display}  (esc to close)", classes="title")
            with VerticalScroll():
                yield Static(_render_model(self.itype, self.fm))


class LegendScreen(ModalScreen):
    DEFAULT_CSS = MODAL_CSS.format(name="LegendScreen") + """
    LegendScreen .row { height: 1; }
    LegendScreen .row Label { margin-left: 1; }
    """
    BINDINGS: ClassVar[list[BindingType]] = [Binding("escape", "dismiss", "close"),
                                             Binding("question_mark", "dismiss", "close")]

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("legend  (esc to close)", classes="title")
            for s in State:
                with Horizontal(classes="row"):
                    yield GlowDot(s, "ring" if s == State.INACTIVE else "filled")
                    yield Label(s.word)
            kinds = Text("\n")
            for k in Kind:
                kinds.append(f"{k.label}  ", style=f"bold {KIND_COLORS[k]}")
            kinds.append("\nthe kind of the selected StorageClass; red background = the field needs another kind\n",
                         style="dim")
            kinds.append("\nzen+cr  zen record and backing CR    zen-only  no CR (or none of this kind)\n"
                         "cr-only  CR without a zen record (invisible in the web console)\n", style="dim")
            kinds.append("\n{S1} zen form  {S3} existing CRs  {S4} zen-stored parameters  {S5} CRD schema  "
                         "{S8} name heuristics  {live} cluster evidence", style="dim")
            yield Static(kinds)
