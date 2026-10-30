"""InstanceManagerApp: type catalog | instances | detail (Config / Storage / Sub-services), event log.

All cluster and cpd-cli work happens on the DataHub's loader thread; the app polls the
hub's version every 0.5 s and reconciles rows in place. Phase 3 is browse-only: no action
here changes the cluster (profile repair is the one exception, behind its own button).
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import ClassVar

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Horizontal, VerticalScroll
from textual.css.query import NoMatches
from textual.events import Click
from textual.widgets import Footer, Header, Label, RichLog, TabbedContent

from ...common.glow_dot import DOT_COLORS, GlowDot
from ...common.pulse import PulseClock
from ...common.state import State
from ...common.ui_util import reconcile, set_attr, set_text
from ..hub import DataHub, instance_key
from ..model import FormModel, Instance, Kind
from .detail import Detail
from .rows import ALL, CatalogRow, InstanceRow, InstanceSelected, TypeSelected
from .screens import ExplainScreen, LegendScreen, ProfileScreen
from .storage_kind_tag import KIND_COLORS

EVENT_STYLE = {"info": "", "warn": "yellow", "error": "red", "state": "cyan"}


@dataclass
class ProfileCtx:
    """D10 state shared by the header tags, the profile panel and the repair task."""
    status: object                 # providers.cpd.profile.ProfileStatus
    auto: bool
    source: str
    api_url: str
    cli: object
    kube: object
    namespace: str
    busy: bool = False


def _truecolor() -> bool:
    if os.environ.get("COLORTERM", "").lower() in ("truecolor", "24bit"):
        return True
    return os.environ.get("TERM_PROGRAM", "") in ("iTerm.app", "WezTerm", "vscode", "ghostty", "Hyper", "tmux")


class InstanceManagerApp(App):
    CSS_PATH = "app.tcss"
    TITLE = "instance-manager"
    ENABLE_COMMAND_PALETTE = False
    BINDINGS: ClassVar[list[BindingType]] = [
        Binding("q", "quit", "quit"),
        Binding("n", "create", "new"),
        Binding("e", "edit", "edit capacity"),
        Binding("d", "delete", "delete"),
        Binding("r", "rename", "rename"),
        Binding("R", "rediscover", "re-discover"),
        Binding("x", "explain", "explain"),
        Binding("s", "subservices", "sub-services"),
        Binding("f", "problems", "problems only"),
        Binding("P", "profile", "profile"),
        Binding("question_mark", "legend", "legend"),
        Binding("1", "tab('tab-config')", show=False),
        Binding("2", "tab('tab-storage')", show=False),
        Binding("3", "tab('tab-sub')", show=False),
    ]

    def __init__(self, hub: DataHub, header: str, profile_ctx: ProfileCtx | None = None, *, plain: bool = False,
                 animate: bool = True, read_only: bool = False, api_url: str = ""):
        super().__init__()
        self.read_only = read_only
        self.api_url = api_url
        self.hub = hub
        self.header_text = header
        self.profile_ctx = profile_ctx
        self.plain = plain
        self.halo = _truecolor()
        animate = animate and os.environ.get("TEXTUAL_ANIMATIONS", "full").lower() != "none"
        self.pulse = PulseClock(self, animate)
        self.type_sel = ALL
        self.inst_sel: str | None = None
        self.problems_only = False
        self._seen = -1
        self._events_seen = 0
        self._cat_rows: list[CatalogRow] = []
        self._inst_rows: list[InstanceRow] = []

    def get_css_variables(self) -> dict[str, str]:
        variables = super().get_css_variables()
        variables.update({f"dot-{s.value}": c for s, c in DOT_COLORS.items()})
        variables.update({f"kind-{k.value}": c for k, c in KIND_COLORS.items()})
        return variables

    # ------------------------------------------------------------------
    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Horizontal(id="status"):
            yield Label("", id="profile-tag", classes="tag")
            yield Label("", id="auto-tag", classes="tag")
            for s in State:
                yield GlowDot(s, "ring" if s == State.INACTIVE else "filled")
                yield Label(f"0 {s.word}", id=f"cnt-{s.value}", classes="count")
            yield Label("discovering...", id="updated")
        with Horizontal(id="main"):
            yield VerticalScroll(id="catalog")
            yield VerticalScroll(id="instances")
            yield Detail(id="detail")
        yield RichLog(id="events", max_lines=500, wrap=False, markup=False)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = self.header_text.replace("instance-manager · ", "")
        self.query_one("#catalog").border_title = "instance types"
        self.query_one("#instances").border_title = "instances"
        self.query_one("#events", RichLog).border_title = "events"
        self._tags()
        self.hub.start()
        self.pulse.start()
        self.set_interval(0.5, self._tick)

    def on_unmount(self) -> None:
        self.hub.stop()

    @property
    def base(self):
        """The main screen. App.query_one searches the *active* screen, which is a modal while a form
        or plan is open; the 0.5 s refresh keeps updating the main screen underneath."""
        return self.screen_stack[0]

    # ------------------------------------------------------------------
    def _tick(self) -> None:
        if self.hub.version != self._seen:
            try:
                self._redraw()
            except NoMatches:            # widgets already gone (the app is shutting down): next tick, or never
                pass

    def _visible(self) -> list[tuple[Instance, str]]:
        hub = self.hub
        out = []
        for t in hub.types:
            if self.type_sel not in (ALL, t.key):
                continue
            for i in hub.instances.get(t.key, []):
                notes = self._notes(i)
                if self.problems_only and i.state == State.HEALTHY and not notes:
                    continue
                out.append((i, t.display))
        out.sort(key=lambda p: (p[0].state.severity, p[1], p[0].name))
        return out

    def _notes(self, inst: Instance) -> list[str]:
        fm = self.hub.models.get(inst.type_key)
        if not isinstance(fm, FormModel):
            return []
        bad = any(m.startswith(f"{inst.name}:") for f in fm.fields.values() if f.storage
                  for m in f.storage.mismatches)
        return ["storage!"] if bad else []

    def _redraw(self) -> None:
        hub = self.hub
        with hub.lock:
            self._seen = hub.version
        with self.batch_update():
            # catalog
            keys = [ALL] + [t.key for t in hub.types]
            box = self.base.query_one("#catalog", VerticalScroll)
            self._cat_rows, fresh = reconcile(box, self._cat_rows, keys, lambda w: w.key, CatalogRow)
            for row in self._cat_rows:
                t = hub.type_by_key(row.key)
                insts = [i for v in hub.instances.values() for i in v] if row.key == ALL \
                    else hub.instances.get(row.key, [])
                row.set_class(row.key == self.type_sel, "-selected")
                if row in fresh:
                    self.call_after_refresh(row.fill, t, insts)
                else:
                    row.fill(t, insts)
            # instances
            visible = self._visible()
            by_key = {instance_key(i): (i, d) for i, d in visible}
            box = self.base.query_one("#instances", VerticalScroll)
            self._inst_rows, fresh = reconcile(box, self._inst_rows, list(by_key), lambda w: w.key, InstanceRow)
            for row in self._inst_rows:
                inst, disp = by_key[row.key]
                row.set_class(row.key == self.inst_sel, "-selected")
                if row in fresh:
                    self.call_after_refresh(row.fill, inst, disp, self._notes(inst))
                else:
                    row.fill(inst, disp, self._notes(inst))
            if self.inst_sel is None and self._inst_rows:
                self.inst_sel = self._inst_rows[0].key
            total = sum(len(hub.instances.get(t.key, [])) for t in hub.types
                        if self.type_sel in (ALL, t.key))
            set_attr(box, "border_title", f"instances · {len(visible)} of {total} · problems only (f to show all)"
                     if self.problems_only else f"instances · {total} · all (f: problems only)")
            # counts
            all_insts = [i for v in hub.instances.values() for i in v]
            for s in State:
                set_text(self.base.query_one(f"#cnt-{s.value}", Label),
                         f"{sum(1 for i in all_insts if i.state == s)} {s.word}")
            upd = f"running: {hub.running}" if hub.running else "discovering..." if hub.loading else (
                f"updated {time.strftime('%H:%M:%S', time.localtime(hub.loaded_at))}" if hub.loaded_at else "")
            set_text(self.base.query_one("#updated", Label), upd)
            self._detail()
            self._events()
            self._tags()

    def _selected(self) -> Instance | None:
        if not self.inst_sel:
            return None
        for v in self.hub.instances.values():
            for i in v:
                if instance_key(i) == self.inst_sel:
                    return i
        return None

    def _detail(self) -> None:
        inst = self._selected()
        d = self.base.query_one(Detail)
        if inst is None:
            d.show(None, None, None, None, self.hub.sc)
            return
        self.hub.request_model(inst.type_key)
        self.hub.request_tab(inst)
        d.show(inst, self.hub.type_by_key(inst.type_key), self.hub.models.get(inst.type_key),
               self.hub.tabs.get(instance_key(inst)), self.hub.sc)

    def _events(self) -> None:
        log = self.base.query_one("#events", RichLog)
        with self.hub.lock:
            new = self.hub.events[self._events_seen:]
            self._events_seen = len(self.hub.events)
        for e in new:
            log.write(Text(f"{time.strftime('%H:%M:%S', time.localtime(e.at))}  {e.text}",
                           style=EVENT_STYLE.get(e.level, "")))

    def _tags(self) -> None:
        ctx = self.profile_ctx
        ptag = self.base.query_one("#profile-tag", Label)
        atag = self.base.query_one("#auto-tag", Label)
        if ctx is None:
            set_text(ptag, "")
            set_text(atag, "")
            return
        ok = bool(ctx.status and ctx.status.ok)
        ptag.set_class(ok, "-ok")
        ptag.set_class(ctx.status is not None and not ok, "-bad")
        label = "repairing profile..." if ctx.busy else (ctx.status.tag if ctx.status else "profile checking...")
        set_text(ptag, label + " ")
        atag.set_class(ctx.auto, "-on")
        set_text(atag, f"auto-repair {'on' if ctx.auto else 'off'} ({ctx.source}) ")

    # ------------------------------------------------------------------ messages / clicks
    def on_type_selected(self, msg: TypeSelected) -> None:
        if self.type_sel != msg.key:
            self.type_sel = msg.key
            self.inst_sel = None
            self._redraw()

    def on_instance_selected(self, msg: InstanceSelected) -> None:
        if self.inst_sel != msg.key:
            self.inst_sel = msg.key
            self._redraw()

    def on_click(self, event: Click) -> None:
        wid = getattr(event.widget, "id", None)
        if wid == "auto-tag":
            self.action_toggle_auto_repair()
        elif wid == "profile-tag":
            self.action_profile()
        elif wid == "sub-text":
            self.action_subservices()

    # ------------------------------------------------------------------ changes (plan -> preview -> run)
    def _can_change(self) -> bool:
        if self.read_only:
            self.notify("--read-only: changes are disabled", severity="warning")
            return False
        ctx = self.profile_ctx
        if ctx is not None and ctx.status is None:
            self.notify("still checking the cpd-cli profile; try again in a moment")
            return False
        if ctx is not None and not ctx.status.ok:
            self.notify(f"{ctx.status.tag}: repair the profile first (P)", severity="error")
            return False
        if self.hub.running:
            self.notify(f"wait: {self.hub.running} is still running", severity="warning")
            return False
        return True

    def _model(self, type_key: str) -> FormModel | None:
        fm = self.hub.models.get(type_key)
        if isinstance(fm, FormModel):
            return fm
        self.hub.request_model(type_key)
        self.notify("still discovering this type's fields; try again in a moment")
        return None

    def _show_plan(self, plan) -> None:
        from .forms import PlanScreen
        self.push_screen(PlanScreen(plan, self._run_plan))

    def _run_plan(self, plan) -> None:
        from .forms import CreateScreen, EditScreen
        from .subservice_screen import SubServiceScreen
        while isinstance(self.screen, (CreateScreen, EditScreen)):
            self.pop_screen()
        scr = self.screen                         # captured now: the callback runs later, on the hub thread
        done = (lambda ok: self.call_from_thread(scr.action_reload)) if isinstance(scr, SubServiceScreen) else None
        self.hub.execute(plan, done)
        self.notify(f"{plan.op} {plan.target}: running (progress in the event log)")

    def _plan_async(self, name: str, build) -> None:
        def task() -> None:
            plan = build()
            self.call_from_thread(self._show_plan, plan)
        self.hub.run_task(name, task)

    def action_create(self) -> None:
        if not self._can_change():
            return
        inst = self._selected()
        key = self.type_sel if self.type_sel != ALL else (inst.type_key if inst else None)
        t = self.hub.type_by_key(key) if key else None
        if t is None:
            self.notify("select an instance type in the left list first")
            return
        if not t.creatable:
            self.notify(f"{t.display} can't be created here: {'; '.join(t.notices) or 'no provisioning entry'}",
                        severity="warning")
            return
        fm = self._model(t.key)
        if fm is not None:
            from .forms import CreateScreen
            self.push_screen(CreateScreen(t, fm, self.hub.sc))

    def plan_create(self, itype, fm, values, name, description, version, vault: bool | None = None) -> None:
        from ..ops import planner
        entry = itype.meta.get("addon")
        prov = self.hub.provider
        self._plan_async("plan-create", lambda: planner.plan_create(
            prov, itype, fm, values, name, description, version, api_url=self.api_url,
            name_regex=entry.name_regex if entry else None,
            on_update=lambda insts: self.hub.update_instances(itype.key, insts), vault=vault))

    def action_edit(self) -> None:
        if not self._can_change():
            return
        inst = self._selected()
        if inst is None:
            self.notify("select an instance first")
            return
        fm = self._model(inst.type_key)
        if fm is not None:
            from .forms import EditScreen
            self.push_screen(EditScreen(self.hub.type_by_key(inst.type_key), inst, fm, self.hub.sc))

    def plan_edit(self, itype, inst, fm, changes) -> None:
        from ..ops import planner
        if not changes:
            self.notify("nothing changed")
            return
        prov = self.hub.provider
        self._plan_async("plan-edit", lambda: planner.plan_edit(
            prov, itype, inst, fm, changes, on_update=lambda insts: self.hub.update_instances(itype.key, insts)))

    def action_delete(self) -> None:
        if not self._can_change():
            return
        inst = self._selected()
        if inst is None:
            self.notify("select an instance first")
            return
        from ..ops import planner
        itype = self.hub.type_by_key(inst.type_key)
        prov = self.hub.provider
        self._plan_async("plan-delete", lambda: planner.plan_delete(
            prov, itype, inst, on_update=lambda insts: self.hub.update_instances(itype.key, insts)))

    def action_rename(self) -> None:
        inst = self._selected()
        if inst is None:
            self.notify("select an instance first")
            return
        from ..ops import planner
        self._show_plan(planner.plan_rename(self.hub.provider, self.hub.type_by_key(inst.type_key), inst, "..."))

    # ------------------------------------------------------------------ actions
    def action_rediscover(self) -> None:
        self.hub.event("info", "re-discovering (R)")
        self.hub.rediscover()

    def action_problems(self) -> None:
        self.problems_only = not self.problems_only
        self._redraw()

    def action_tab(self, tab: str) -> None:
        tabs = self.base.query_one("#tabs", TabbedContent)
        if not tabs.get_tab(tab).disabled:
            tabs.active = tab

    def action_legend(self) -> None:
        self.push_screen(LegendScreen())

    def action_explain(self) -> None:
        inst = self._selected()
        key = inst.type_key if inst else (self.type_sel if self.type_sel != ALL else None)
        if key is None:
            self.notify("select an instance type first")
            return
        fm, t = self.hub.models.get(key), self.hub.type_by_key(key)
        if isinstance(fm, FormModel) and t:
            self.push_screen(ExplainScreen(t, fm))
        else:
            self.hub.request_model(key)
            self.notify("still discovering this type's fields; try again in a moment")

    def action_subservices(self) -> None:
        inst = self._selected()
        tab = self.hub.tabs.get(instance_key(inst)) if inst else None
        if tab is None:
            self.notify("select an instance first" if inst is None else "still checking for sub-services")
        elif not tab.enabled:
            self.notify(f"sub-services: {tab.reason}", severity="warning")
        else:
            from .subservice_screen import SubServiceScreen
            self.push_screen(SubServiceScreen(tab.provider, self.hub.type_by_key(inst.type_key), inst))

    def action_profile(self) -> None:
        if self.profile_ctx is None:
            self.notify("this provider has no cpd-cli profile")
            return
        self.push_screen(ProfileScreen())

    def action_toggle_auto_repair(self) -> None:
        ctx = self.profile_ctx
        if ctx is None:
            return
        from ..providers.cpd import profile as prof
        ctx.auto, ctx.source = not ctx.auto, "saved"
        prof.save_auto_repair(ctx.api_url, ctx.auto)
        self.hub.event("info", f"auto-repair {'on' if ctx.auto else 'off'}: saved for this cluster + config")
        if ctx.auto and ctx.status is not None and not ctx.status.ok:
            self.action_repair_profile()
        self._tags()

    def action_repair_profile(self) -> None:
        ctx = self.profile_ctx
        if ctx is None or ctx.busy:
            return
        if ctx.status is not None and ctx.status.ok:
            self.notify("the profile is healthy: nothing to repair")
            return
        from ..providers.cpd import profile as prof
        ctx.busy = True
        self._tags()

        def task() -> None:
            try:
                ok, lines = prof.repair(ctx.cli.profile)
                for ln in lines:
                    self.hub.event("info" if ok else "error", f"repair: {ln}")
                ctx.status = prof.check(ctx.kube, ctx.namespace, ctx.cli)
                if ctx.status.ok:
                    ctx.status.detail = "repaired"
                    enable = getattr(self.hub.provider, "enable_zen", None)
                    if enable:
                        enable()
                    self.hub.rediscover()
            finally:
                ctx.busy = False
                self.hub.event("info", f"{ctx.status.tag}")

        self.hub.run_task("profile-repair", task)
