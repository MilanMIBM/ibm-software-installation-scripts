"""Inline panels of the default UI (cache plan §4): nothing here is a modal screen.

  FormContext   state panel (under the big panel) while a form is open: field help (label, bounds,
                provenance, storage evidence) | the checks and the live, masked payload preview
  PlanPanel     big panel: the ActionPlan with its gates (ack warnings, typed name) and Run
  ProfileStrip  under the status line (P): the cpd-cli profile, Repair now, Auto-repair on/off
  LegendStrip   above the footer (?): dot states, storage kinds, badges, sources
  BuildView     top of the big panel while the cache is built: a ProgressBar + one row per part
  state_text    state panel for an instance, a type or a sub-service item
"""

from __future__ import annotations

import json
from collections.abc import Callable

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.widgets import Button, Checkbox, Input, Label, ProgressBar, Static

from ...common.glow_dot import GlowDot
from ...common.state import State
from ...common.ui_util import reconcile, set_attr, set_text
from ..model import Field, Kind, Role, path_str
from ..ops import payload as pl
from ..ops.plan import ActionPlan
from .forms import plan_text
from .storage_kind_tag import KIND_COLORS, need_line


# -- form context -----------------------------------------------------------------------------------
def field_help(f: Field | None) -> Text:
    t = Text()
    if f is None:
        t.append("Name and description\n", style="bold")
        t.append("The name the platform shows. For CR-backed instance types it also becomes the Kubernetes "
                 "resource name.", style="dim")
        return t
    t.append(f"{f.label or f.key}\n", style="bold")
    t.append(f"{path_str(f.path)}  {f.type}", style="dim")
    if f.role != Role.OTHER:
        t.append(f"  role {f.role.value}", style="green")
    t.append("\n")
    if f.description:
        t.append(f"{f.description}\n")
    bounds = []
    if f.minimum is not None or f.maximum is not None:
        bounds.append(f"{f.minimum if f.minimum is not None else ''}..{f.maximum if f.maximum is not None else ''}")
    if f.enum and not f.enum_soft:
        labels = f.enum_labels or {}
        bounds.append("one of " + ", ".join(str(labels.get(v, v)) for v in f.enum[:8])
                      + (" ..." if len(f.enum) > 8 else ""))
    if f.required:
        bounds.append("required")
    if f.pattern:
        bounds.append(f"pattern {f.pattern}")
    if bounds:
        t.append("  ".join(bounds) + "\n", style="cyan")
    if f.default is not None and f.role != Role.SECRET:
        t.append(f"default {f.default}\n", style="dim")
    if f.observed and f.role != Role.SECRET:
        uniq = list(dict.fromkeys(str(v) for v in f.observed if not isinstance(v, (dict, list))))
        if uniq:
            t.append("existing instances use " + ", ".join(uniq[:5]) + "\n", style="dim")
    if f.placeholder:
        t.append(f"example {f.placeholder}\n", style="dim")
    if f.storage:
        t.append(need_line(f.storage) + "\n", style="magenta")
        for ev in f.storage.evidence[:4]:
            t.append(f"  - {ev}\n", style="dim")
        for m in f.storage.mismatches[:3]:
            t.append(f"  ! {m}\n", style="red")
    if f.aliases:
        t.append(f"changes together with {', '.join(path_str(a) for a in f.aliases)}\n", style="dim")
    for n in f.notices:
        t.append(f"! {n}\n", style="yellow")
    t.append("sources {" + ",".join(sorted(f.sources)) + "}", style="dim")
    return t


class FormContext(Horizontal):
    """The state panel under the big panel while a form is open: field help on the left, the
    checks and the masked payload preview (scrollable) on the right."""

    DEFAULT_CSS = """
    FormContext { padding: 0 1; }
    FormContext #fc-left { width: 45%; padding-right: 1; }
    FormContext #fc-title { text-style: bold; height: 1; }
    FormContext #fc-help { height: auto; }
    FormContext #fc-right { width: 1fr; padding-left: 1; border-left: solid $panel-lighten-2; }
    FormContext #fc-checks { height: auto; }
    FormContext #fc-preview { height: auto; margin-top: 1; }
    """

    def compose(self) -> ComposeResult:
        with VerticalScroll(id="fc-left"):
            yield Label("", id="fc-title")
            yield Static("", id="fc-help")
        with VerticalScroll(id="fc-right"):
            yield Static("", id="fc-checks")
            yield Static("", id="fc-preview")

    def show_field(self, f: Field | None) -> None:
        set_text(self.query_one("#fc-help", Static), field_help(f))

    def show(self, view, preview: dict | None, extra_errors: list[str] | None = None,
             extra_warnings: list[str] | None = None) -> None:
        """view: the FormView; preview: the masked payload or patch (None = none to show)."""
        set_text(self.query_one("#fc-title", Label), view.spec.title)
        errors = list(extra_errors or []) + [e for e in view.errors if e not in (extra_errors or [])]
        warnings = list(extra_warnings or []) + [w for w in view.warnings if w not in (extra_warnings or [])]
        t = Text()
        t.append("checks\n", style="bold underline")
        if not errors and not warnings:
            t.append("  ok so far (the plan adds the server-side checks)\n", style="green")
        for e in errors:
            t.append(f"  x {e}\n", style="red")
        for w in warnings:
            t.append(f"  ! {w}\n", style="yellow")
        set_text(self.query_one("#fc-checks", Static), t)
        p = Text()
        if preview is not None:
            p.append("payload preview (secrets masked)\n" if view.spec.mode == "create" else "changes\n",
                     style="bold underline")
            p.append(json.dumps(preview, indent=2, default=str), style="dim")
        set_text(self.query_one("#fc-preview", Static), p)


def state_text(inst, itype, tab=None, mismatches: list[str] | None = None, plain: bool = False,
               what: str = "instance") -> Text:
    """The state panel for a selected instance (or sub-service item); with no instance, the type."""
    from ...common.glow_dot import as_content
    t = Text()
    if inst is None:
        if itype is None:
            t.append("pick a service in the dropdown (top left); its instances are listed below it", style="dim")
            return t
        t.append(f"{itype.display}", style="bold")
        t.append(f"  {'creatable' if itype.creatable else 'list only'}", style="green" if itype.creatable else "yellow")
        if itype.max_instances:
            t.append(f"  at most {itype.max_instances} instance(s)", style="dim")
        t.append("\n")
        if itype.kind:
            t.append(f"  resource  {itype.kind}" + (f".{itype.group}" if itype.group else "") + "\n", style="dim")
        for n in itype.notices:
            t.append(f"  ! {n}\n", style="yellow")
        t.append(f"no {what} selected" + (": + New creates one" if itype.creatable else ""), style="dim")
        return t
    t.append_text(as_content(inst.state, plain=plain))
    t.append(f" {inst.display_name or inst.name}", style="bold")
    t.append(f"  {inst.state.word}\n")
    if inst.reason:
        t.append(f"  {inst.reason}\n", style="dim")
    if inst.meta.get("cached"):
        t.append("  from the discovery cache: the live state is loading (changes wait for it)\n", style="italic yellow")
    zen = inst.meta.get("zen") or {}
    facts = [("view", " ".join(inst.badges))] if inst.badges else []
    if zen:
        facts += [("zen", f"{zen.get('provision_status')} · id {zen.get('id')} · {zen.get('service_version')}")]
    if inst.namespace:
        facts.append(("namespace", inst.namespace))
    for k, v in facts:
        t.append(f"  {k:<10}", style="dim")
        t.append(f"{v}\n")
    for m in mismatches or []:
        t.append(f"  ! storage: {m}\n", style="red")
    if tab is not None and tab.state != "none":
        t.append(f"  sub-services  {tab.reason}\n", style="dim" if tab.enabled else "yellow")
    return t


def create_preview(view) -> dict | None:
    spec = view.spec
    try:
        payload = pl.build(spec.itype, spec.fm, view.values(), view.name, view.description, "<namespace>",
                           view.version)
    except (TypeError, ValueError):
        return None
    payload.pop("namespace", None)
    return pl.masked(payload, spec.fm)


def edit_preview(view) -> dict:
    out = {}
    for path, new in view.changes().items():
        f = view.spec.fm.fields.get(path)
        out[path_str(path)] = f"{view.spec.current.get(path)} -> {new}"
        for a in (f.aliases if f else []):
            if a in view.spec.current:
                out[path_str(a)] = f"{view.spec.current.get(a)} -> {new} (alias)"
    return out


# -- plan ---------------------------------------------------------------------------------------------
class PlanPanel(Vertical):
    DEFAULT_CSS = """
    PlanPanel { padding: 0 1; }
    PlanPanel #pp-title { text-style: bold; height: 1; }
    PlanPanel #pp-gates { height: auto; }
    PlanPanel #pp-buttons { height: 3; }
    PlanPanel #pp-buttons Button { margin-right: 2; }
    """

    class Closed(Message):
        pass

    def __init__(self, **kw):
        super().__init__(**kw)
        self.plan: ActionPlan | None = None
        self.on_run: Callable[[ActionPlan], None] | None = None

    def compose(self) -> ComposeResult:
        yield Label("", id="pp-title")
        with VerticalScroll():
            yield Static("", id="pp-body")
        with Vertical(id="pp-gates"):
            yield Checkbox("I have read the warnings above", id="ack")
            yield Input(id="confirm")
        with Horizontal(id="pp-buttons"):
            yield Button("Run", id="run", variant="primary", disabled=True)
            yield Button("Back", id="pp-back")

    def show(self, plan: ActionPlan, on_run: Callable[[ActionPlan], None]) -> None:
        self.plan, self.on_run = plan, on_run
        set_text(self.query_one("#pp-title", Label), f"plan · {plan.op} {plan.target}  (esc: back)")
        self.query_one("#pp-body", Static).update(plan_text(plan))
        ack = self.query_one("#ack", Checkbox)
        ack.value = False
        ack.display = bool(plan.warnings)
        conf = self.query_one("#confirm", Input)
        conf.value = ""
        conf.placeholder = f"type {plan.confirm_name} to confirm" if plan.confirm_name else ""
        conf.display = bool(plan.confirm_name)
        run = self.query_one("#run", Button)
        run.variant = "error" if plan.op == "delete" else "primary"
        self._update()
        if plan.confirm_name:
            conf.focus()

    def _update(self) -> None:
        p = self.plan
        ok = bool(p and p.runnable)
        if p and p.warnings:
            ok = ok and self.query_one("#ack", Checkbox).value
        if p and p.confirm_name:
            ok = ok and self.query_one("#confirm", Input).value.strip() == p.confirm_name
        self.query_one("#run", Button).disabled = not ok

    def on_checkbox_changed(self, event) -> None:
        event.stop()
        self._update()

    def on_input_changed(self, event) -> None:
        event.stop()
        self._update()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "run" and not event.button.disabled and self.plan and self.on_run:
            event.stop()
            plan, self.plan = self.plan, None
            self.on_run(plan)
            self.post_message(self.Closed())
        elif event.button.id == "pp-back":
            event.stop()
            self.post_message(self.Closed())


# -- strips ---------------------------------------------------------------------------------------------
class ProfileStrip(Horizontal):
    """D10 inline: state, URLs, detail; Repair now; Auto-repair on/off (saved per cluster + config)."""

    DEFAULT_CSS = """
    ProfileStrip { height: auto; padding: 0 1; background: $panel; display: none; }
    ProfileStrip.-open { display: block; }
    ProfileStrip #ps-body { width: 1fr; height: auto; }
    ProfileStrip Button { margin-left: 1; }
    """

    def compose(self) -> ComposeResult:
        yield Static("", id="ps-body")
        yield Button("Repair now", id="repair", variant="warning")
        yield Button("", id="toggle")
        yield Button("Close", id="ps-close")

    def refresh_body(self, ctx) -> None:
        if ctx is None:
            return
        st = ctx.status
        t = Text()
        for k, v in (("state", st.tag if st else "checking..."), ("profile", st.profile if st else "-"),
                     ("profile url", (st.url if st else "") or "-"),
                     ("cluster url", (st.live_url if st else "") or "-"),
                     ("detail", (st.detail if st else "") or "-"),
                     ("auto-repair", f"{'on' if ctx.auto else 'off'} ({ctx.source}); saved per cluster + config, "
                                     "acts only on a broken profile")):
            t.append(f"{k:<13}", style="dim")
            t.append(f"{v}\n")
        set_text(self.query_one("#ps-body", Static), t)
        set_attr(self.query_one("#toggle", Button), "label", f"Auto-repair: {'on' if ctx.auto else 'off'}")
        set_attr(self.query_one("#repair", Button), "disabled", bool(st and st.ok) or ctx.busy)


class LegendStrip(Static):
    DEFAULT_CSS = """
    LegendStrip { height: auto; padding: 0 1; background: $panel; display: none; }
    LegendStrip.-open { display: block; }
    """

    def on_mount(self) -> None:
        from ...common.glow_dot import as_content
        t = Text()
        for s in State:
            t.append_text(as_content(s, plain=False))
            t.append(f" {s.word}   ")
        t.append("\n")
        for k in Kind:
            t.append(f"{k.label}  ", style=f"bold {KIND_COLORS[k]}")
        t.append("  red background = the field needs another kind\n", style="dim")
        t.append("zen+cr  zen record and backing CR   zen-only  no CR   cr-only  CR without a zen record "
                 "(invisible in the web console)\n", style="dim")
        t.append("{S1} zen form  {S3} existing CRs  {S4} zen-stored parameters  {S5} CRD schema  {S8} name heuristics"
                 "  {live} cluster evidence   cached = from the discovery cache, live state loading", style="dim")
        self.update(t)


# -- build progress ---------------------------------------------------------------------------------------
PART_STATE = {"queued": (State.INACTIVE, "ring"), "running": (State.PROGRESS, "filled"),
              "done": (State.HEALTHY, "filled"), "failed": (State.FAILING, "filled"),
              "skipped": (State.INACTIVE, "ring")}


class BuildPartRow(Horizontal):
    DEFAULT_CSS = """
    BuildPartRow { height: 1; }
    BuildPartRow Label { margin-left: 1; text-wrap: nowrap; text-overflow: ellipsis; }
    BuildPartRow .bp-label { width: 1fr; }
    BuildPartRow .bp-took { width: 10; color: $text-muted; content-align: right middle; }
    """

    def __init__(self, key: str):
        super().__init__()
        self.key = key

    def compose(self) -> ComposeResult:
        yield GlowDot(State.INACTIVE, "ring", size="mini")
        yield Label("", classes="bp-label")
        yield Label("", classes="bp-took")

    def fill(self, part) -> None:
        if not self.is_mounted or not self.query(".bp-label"):
            self.call_after_refresh(self.fill, part)
            return
        state, style = PART_STATE.get(part.state, PART_STATE["queued"])
        self.query_one(GlowDot).set_state(state, style)
        text = part.label + (f" ({part.what})" if part.what else "") + (f"  {part.error}" if part.error else "")
        set_text(self.query_one(".bp-label", Label), text)
        set_text(self.query_one(".bp-took", Label), f"{part.took:.1f}s" if part.took is not None else
                 ("..." if part.state == "running" else ""))


class BuildView(Vertical):
    DEFAULT_CSS = """
    BuildView { height: auto; max-height: 22; padding: 0 1; border-bottom: solid $panel-lighten-2; display: none; }
    BuildView.-open { display: block; }
    BuildView #bv-title { height: 1; text-style: bold; }
    BuildView ProgressBar { width: 100%; margin: 0 0 1 0; }
    BuildView ProgressBar #bar { width: 1fr; }
    BuildView #bv-parts { height: auto; max-height: 16; }
    """

    def __init__(self, **kw):
        super().__init__(**kw)
        self._rows: list[BuildPartRow] = []

    def compose(self) -> ComposeResult:
        yield Label("", id="bv-title")
        yield ProgressBar(total=100, show_eta=False, id="bv-bar")
        yield VerticalScroll(id="bv-parts")

    def update_from(self, pr) -> None:
        cur = pr.current
        eta = f" · eta {pr.eta:.0f}s" if pr.eta is not None else ""
        now = f" · {cur.label}" + (f" ({cur.what})" if cur.what else "") if cur and not pr.finished else ""
        set_text(self.query_one("#bv-title", Label),
                 f"building the discovery cache · {pr.done_count}/{pr.total} · {int(pr.fraction * 100)}%"
                 f" · {pr.elapsed:.0f}s{eta}{now}")
        self.query_one("#bv-bar", ProgressBar).update(progress=round(pr.fraction * 100, 1))
        box = self.query_one("#bv-parts", VerticalScroll)
        parts = {p.key: p for p in pr.parts}
        self._rows, fresh = reconcile(box, self._rows, list(parts), lambda w: w.key, BuildPartRow)
        for row in self._rows:
            if row in fresh:
                self.call_after_refresh(row.fill, parts[row.key])
            else:
                row.fill(parts[row.key])
