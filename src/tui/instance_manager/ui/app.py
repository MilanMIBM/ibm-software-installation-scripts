"""InstanceManagerApp: selectors + lists on the left, the big work panel and a state panel on the right.

Default UI, nothing opens a modal:
  top left     the service dropdown (all services, or one type with its state dot and count); when
               the selected instance's service has sub-services (watsonx.data engines and
               services), a sub-service dropdown next to it lists their kinds
  left         the service's instances with + New at the bottom; when a sub-service kind is chosen,
               a second small list right of it holds that kind's items with its own + New
  big panel    everything that manages or creates: the instance overview (Config | Storage |
               Sub-services | Fields, Scale / Delete / Rename), New forms (kept mounted per type,
               LRU 6, drafts survive switching), the Scale form, sub-service items and forms, the
               plan with its gates and Run; breadcrumb + Esc back
  state panel  under the big panel, scrollable: the selection's state, or the open form's field
               help + checks + payload preview
  strips       profile (P) under the status line, legend (?) above the footer; events collapse (l)
--classic-ui keeps the earlier catalog | instances | detail layout and its pop-ups (Create/Edit/
Plan/Explain/Legend/Profile/SubService screens) on the same hub (decision F3).
All cluster and cpd-cli work runs on the DataHub's lanes; the app polls the hub's change
counters every 0.25 s and repaints only the areas whose counter moved.
"""

from __future__ import annotations

import os
import re
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import ClassVar

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.css.query import NoMatches
from textual.events import Click
from textual.widgets import (
    Button,
    ContentSwitcher,
    Footer,
    Header,
    Label,
    RichLog,
    Select,
    Static,
    TabbedContent,
)

from ...common import tls
from ...common.glow_dot import DOT_COLORS, GlowDot, as_content
from ...common.pulse import PulseClock
from ...common.state import State
from ...common.ui_util import reconcile, set_attr, set_display, set_text
from ..hub import DataHub, instance_key
from ..model import FormModel, Instance, InstanceType
from .detail import Detail
from .rows import ALL, CatalogRow, InstanceRow, InstanceSelected, TypeSelected
from .storage_kind_tag import KIND_COLORS

EVENT_STYLE = {"info": "", "warn": "yellow", "error": "red", "state": "cyan"}
FORM_LRU = 6
TICK = 0.25
FORM_VIEWS = ("form-", "edit-", "subform-")


STARTUP_KEY_GRACE = 2.0      # s after mount in which no key binding runs (stray terminal replies)


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


def _wid(prefix: str, key: str) -> str:
    return f"{prefix}-" + re.sub(r"[^A-Za-z0-9_-]", "_", key)


def _short(text: str, n: int = 34) -> str:
    return text if len(text) <= n else text[:n - 1] + "…"


class InstanceManagerApp(App):
    CSS_PATH = "app.tcss"
    TITLE = "instance-manager"
    ENABLE_COMMAND_PALETTE = False
    BINDINGS: ClassVar[list[BindingType]] = [
        Binding("q", "quit", "quit"),
        Binding("t", "service", "service"),
        Binding("n", "create", "new"),
        Binding("i", "instances", "instances", show=False),
        Binding("e", "edit", "scale"),
        Binding("d", "delete", "delete"),
        Binding("r", "rename", "rename"),
        Binding("R", "rediscover", "re-discover"),
        Binding("x", "explain", "fields"),
        Binding("s", "subservices", "sub-services"),
        Binding("f", "problems", "problems only"),
        Binding("P", "profile", "profile"),
        Binding("question_mark", "legend", "legend"),
        Binding("l", "events", "events", show=False),
        Binding("escape", "back", "back", show=False),
        Binding("1", "tab('tab-config')", show=False),
        Binding("2", "tab('tab-storage')", show=False),
        Binding("3", "tab('tab-sub')", show=False),
        Binding("4", "tab('tab-fields')", show=False),
    ]

    def __init__(self, hub: DataHub, header: str, profile_ctx: ProfileCtx | None = None, *, plain: bool = False,
                 animate: bool = True, read_only: bool = False, api_url: str = "", classic_ui: bool = False):
        super().__init__()
        self.classic = classic_ui
        # nothing focused at start: a stray terminal reply would type into the service dropdown and
        # its type-to-search would leave All services (Tab / t focus it)
        self.AUTO_FOCUS = "*" if classic_ui else ""
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
        self._seen_v: tuple | None = None
        self._events_seen = 0
        self._cat_rows: list[CatalogRow] = []
        self._inst_rows: list[InstanceRow] = []
        self._mismatch: dict[str, tuple[int, set[str]]] = {}
        # inline UI state
        self._forms: OrderedDict[str, object] = OrderedDict()     # type key -> FormView (LRU)
        self._form_v: dict[str, int] = {}
        self._stack: list[str] = ["overview"]                     # big-panel views, Esc pops
        self._transient = 0
        self._plan_open = False
        self._pending_form: str | None = None
        self._area = "inst"                                       # where n / e / d act: inst | sub
        self._subs = None                                         # sub_view.SubServices of the selected instance
        self._sub_rows: list = []
        self._svc_sig: tuple | None = None
        self._kind_sig: tuple | None = None
        self._has_subs: dict[str, bool] = {}

    def get_css_variables(self) -> dict[str, str]:
        variables = super().get_css_variables()
        variables.update({f"dot-{s.value}": c for s, c in DOT_COLORS.items()})
        variables.update({f"kind-{k.value}": c for k, c in KIND_COLORS.items()})
        return variables

    # ------------------------------------------------------------------ layout
    def compose(self) -> ComposeResult:
        from .context import (
            BuildView,
            FormContext,
            LegendStrip,
            PlanPanel,
            ProfileStrip,
        )
        from .sub_view import SubDetail
        yield Header(show_clock=False)
        with Horizontal(id="status"):
            yield Label("", id="profile-tag", classes="tag")
            yield Label("", id="auto-tag", classes="tag")
            for s in State:
                yield GlowDot(s, "ring" if s == State.INACTIVE else "filled")
                yield Label(f"0 {s.word}", id=f"cnt-{s.value}", classes="count")
            yield Label("", id="cache-tag", classes="tag")
            yield Label("discovering...", id="updated")
        if self.classic:
            with Horizontal(id="main"):
                yield VerticalScroll(id="catalog")
                yield VerticalScroll(id="instances")
                yield Detail(id="detail")
        else:
            yield ProfileStrip(id="profile-strip")
            with Horizontal(id="main"):
                with Vertical(id="left"):
                    with Horizontal(id="selectors"):
                        yield Select([], prompt="service", id="svc-select",
                                     tooltip="the service whose instances are listed below (t)")
                        yield Select([], prompt="sub-service", id="sub-select", disabled=True,
                                     tooltip="the sub-service kind of the selected instance (s)")
                    with Horizontal(id="lists"):
                        with VerticalScroll(id="inst-panel"):
                            yield Button("+ New instance", id="new-inst", compact=True, classes="new-btn")
                        with VerticalScroll(id="sub-panel"):
                            yield Button("+ New", id="new-sub", compact=True, classes="new-btn")
                with Vertical(id="right"):
                    with Vertical(id="work"):
                        yield Label("", id="crumb")
                        yield Label("", id="type-banner")
                        yield BuildView(id="build")
                        with ContentSwitcher(id="switcher", initial="overview"):
                            with Vertical(id="overview"):
                                with Horizontal(id="actions"):
                                    yield Button("Scale (e)", id="act-edit", compact=True)
                                    yield Button("Delete (d)", id="act-delete", variant="error", compact=True)
                                    yield Button("Rename (r)", id="act-rename", compact=True)
                                    yield Button("Fields (x)", id="act-fields", compact=True)
                                yield Detail(id="detail", with_fields=True)
                            yield SubDetail(id="sub-detail")
                            yield PlanPanel(id="plan")
                    with ContentSwitcher(id="state", initial="st-info"):
                        with VerticalScroll(id="st-info"):
                            yield Static("", id="st-text")
                        yield FormContext(id="ctx-form")
            yield LegendStrip(id="legend-strip")
        yield RichLog(id="events", max_lines=500, wrap=False, markup=False)
        yield Footer()

    def on_mount(self) -> None:
        self._mounted_at = time.monotonic()
        self.set_timer(STARTUP_KEY_GRACE + 0.1, self.refresh_bindings)   # the footer shows them again
        self.sub_title = self.header_text.replace("instance-manager · ", "")
        self.query_one("#events", RichLog).border_title = "events (l: collapse)"
        if self.classic:
            self.query_one("#catalog").border_title = "instance types"
            self.query_one("#instances").border_title = "instances"
        else:
            self.query_one("#work").border_title = "overview"
            self.query_one("#state").border_title = "state"
        tls.ECHO = False                 # stderr would draw over the screen; _tick moves notices to the log
        self._tags()
        self.hub.start()
        self.pulse.start()
        self._redraw(force=True)                 # the cache snapshot paints before any cluster call
        self.set_interval(TICK, self._tick)

    def on_unmount(self) -> None:
        self.hub.stop()

    @property
    def base(self):
        """The main screen. App.query_one searches the *active* screen, which is a modal while a form
        or plan is open (--classic-ui); the refresh keeps updating the main screen underneath."""
        return self.screen_stack[0]

    # ------------------------------------------------------------------ refresh
    def _counters(self) -> tuple:
        h = self.hub
        with h.lock:
            return (h.catalog_v, h.instances_v, tuple(sorted(h.models_v.items())), h.sc_v, h.events_v,
                    h.cache_v, h.tabs_v)

    def _tick(self) -> None:
        if tls.NOTICES:                  # e.g. "TLS certificate not verified": the event log, not stderr
            for text in tls.drain():
                self.hub.event("warn", f"TLS: {text}")
        v = self._counters()
        if v != self._seen_v:
            try:
                self._redraw(v)
            except NoMatches:            # widgets already gone (the app is shutting down): next tick, or never
                pass

    def _mismatches(self, type_key: str) -> set[str]:
        """Instance names with a storage-class mismatch, computed once per model version."""
        ver = self.hub.models_v.get(type_key, 0)
        hit = self._mismatch.get(type_key)
        if hit and hit[0] == ver:
            return hit[1]
        fm = self.hub.models.get(type_key)
        names: set[str] = set()
        if isinstance(fm, FormModel):
            for f in fm.fields.values():
                if f.storage:
                    names |= {m.split(":", 1)[0] for m in f.storage.mismatches}
        self._mismatch[type_key] = (ver, names)
        return names

    def _notes(self, inst: Instance) -> list[str]:
        return ["storage!"] if inst.name in self._mismatches(inst.type_key) else []

    def _visible(self) -> list[tuple[Instance, str]]:
        hub = self.hub
        out = []
        for t in hub.types:
            if self.type_sel not in (ALL, t.key):
                continue
            for i in hub.instances.get(t.key, []):
                if self.problems_only and i.state == State.HEALTHY and not self._notes(i):
                    continue
                out.append((i, t.display))
        out.sort(key=lambda p: (p[0].state.severity, p[1], p[0].name))
        return out

    def _redraw(self, v: tuple | None = None, force: bool = False) -> None:
        v = v or self._counters()
        old = self._seen_v or (None,) * 7
        self._seen_v = v
        cat, inst, models, sc, events, cache, tabs = (force or a != b for a, b in zip(v, old, strict=True))
        with self.batch_update():
            if self.classic and (cat or inst or models):
                self._draw_catalog()
            if not self.classic and (cat or inst or models):
                self._draw_services()
            if cat or inst or models:
                self._draw_instances()
            if inst:
                self._draw_counts()
            if not self.classic and (cat or inst or tabs or models):
                self._sync_subs()
            if cat or inst or models or sc or tabs or cache:
                self._detail()
            if events:
                self._events()
            if cache or inst:
                self._draw_status()
            if not self.classic:
                if cache:
                    self._draw_build()
                if models or cat:
                    self._refresh_forms()
                self._draw_work_header()
                self._draw_state()
            self._tags()

    # -- classic catalog ---------------------------------------------------------------------------
    def _draw_catalog(self) -> None:
        hub = self.hub
        keys = [ALL] + [t.key for t in hub.types]
        box = self.base.query_one("#catalog", VerticalScroll)
        self._cat_rows, fresh = reconcile(box, self._cat_rows, keys, lambda w: w.key, CatalogRow)
        for row in self._cat_rows:
            t = hub.type_by_key(row.key)
            insts = [i for v in hub.instances.values() for i in v] if row.key == ALL \
                else hub.instances.get(row.key, [])
            row.set_class(row.key == self.type_sel, "-selected")
            row.rebuilding = hub.model_state.get(row.key) in ("building", "stale") and row.key != ALL
            if row in fresh:
                self.call_after_refresh(row.fill, t, insts)
            else:
                row.fill(t, insts)

    # -- the service dropdown ------------------------------------------------------------------------
    def _service_options(self) -> tuple[list[tuple[Text, str]], tuple]:
        hub = self.hub
        everything = [i for v in hub.instances.values() for i in v]
        opts: list[tuple[Text, str]] = []
        sig = []
        label = Text("All services  ", style="bold")
        label.append(str(len(everything)), style="dim")
        opts.append((label, ALL))
        sig.append((ALL, len(everything)))
        for t in hub.types:
            insts = hub.instances.get(t.key, [])
            worst = min((i.state for i in insts), key=lambda s: s.severity, default=State.INACTIVE)
            rebuilding = hub.model_state.get(t.key) in ("building", "stale")
            label = as_content(worst, "filled" if insts else "ring", plain=self.plain)
            label.append(f" {t.display}  ", style="" if t.creatable else "dim")
            cap = f"/{t.max_instances}" if t.max_instances else ""
            label.append(f"{len(insts)}{cap}", style="dim")
            if not t.creatable:
                label.append("  list only", style="dim italic")
            if rebuilding:
                label.append("  ...", style="yellow")
            opts.append((label, t.key))
            sig.append((t.key, t.display, len(insts), cap, worst.value, t.creatable, rebuilding))
        return opts, tuple(sig)

    def _draw_services(self) -> None:
        sel = self.base.query_one("#svc-select", Select)
        opts, sig = self._service_options()
        if self.type_sel != ALL and self.hub.type_by_key(self.type_sel) is None and self.hub.types:
            self.type_sel = ALL                     # the type is gone (re-discovery)
        if sig == self._svc_sig or sel.expanded:      # never reshuffle an open dropdown under the pointer
            return
        self._svc_sig = sig
        with sel.prevent(Select.Changed):
            sel.set_options(opts)
            sel.value = self.type_sel

    def _select_type(self, key: str) -> None:
        if key == self.type_sel:
            return
        self.type_sel = key
        self.inst_sel = None
        self._area = "inst"
        self._back_to_overview()
        self._redraw(force=True)
        t = self.hub.type_by_key(key)
        if t is not None and t.creatable and not self.hub.instances.get(key):
            self.open_create_form(t)            # nothing to manage yet: the New form at once

    # -- the instance list -----------------------------------------------------------------------------
    def _draw_instances(self) -> None:
        hub = self.hub
        visible = self._visible()
        by_key = {instance_key(i): (i, d) for i, d in visible}
        box = self.base.query_one("#instances" if self.classic else "#inst-panel", VerticalScroll)
        self._inst_rows, fresh = reconcile(box, self._inst_rows, list(by_key), lambda w: w.key, InstanceRow)
        if self.inst_sel not in by_key:
            self.inst_sel = self._inst_rows[0].key if self._inst_rows else None
        for row in self._inst_rows:
            inst, disp = by_key[row.key]
            row.set_class(row.key == self.inst_sel, "-selected")
            if row in fresh:
                self.call_after_refresh(row.fill, inst, disp, self._notes(inst))
            else:
                row.fill(inst, disp, self._notes(inst))
        t = hub.type_by_key(self.type_sel) if self.type_sel != ALL else None
        total = sum(len(hub.instances.get(x.key, [])) for x in hub.types if self.type_sel in (ALL, x.key))
        if self.classic:
            set_attr(box, "border_title", f"instances · {len(visible)} of {total} · problems only (f to show all)"
                     if self.problems_only else f"instances · {total} · all (f: problems only)")
            return
        what = f"{t.display} instances" if t else "instances"
        set_attr(box, "border_title", f"{what} · {len(visible)} of {total} · problems only"
                 if self.problems_only else f"{what} · {total}")
        set_attr(box, "border_subtitle", "f: show all · n: new" if self.problems_only else "f: problems only · n: new")
        box.set_class(t is not None, "-one-type")
        btn = self.base.query_one("#new-inst", Button)
        set_attr(btn, "label", f"+ New {t.display} instance" if t else "+ New instance")
        set_attr(btn, "disabled", t is None or not t.creatable)
        set_attr(btn, "tooltip", None if t and t.creatable else (
            "pick a service in the dropdown first" if t is None else
            f"{t.display} can't be created here: {'; '.join(t.notices) or 'no provisioning entry'}"))

    def _draw_counts(self) -> None:
        all_insts = [i for v in self.hub.instances.values() for i in v]
        for s in State:
            set_text(self.base.query_one(f"#cnt-{s.value}", Label),
                     f"{sum(1 for i in all_insts if i.state == s)} {s.word}")

    def _draw_status(self) -> None:
        hub = self.hub
        cache = ""
        if hub.cache is not None:
            pr = hub.build
            if pr is not None and not pr.finished:
                cache = f"cache: building {pr.done_count}/{pr.total}"
            elif not hub.live:
                cache = f"cache: cached {hub._hhmm(hub.cached_at)}" if hub.cached_at else "cache: loading"
            else:
                todo = len(hub._todo())
                cache = f"cache: {hub.cache_status}" + (f" · re-checking {todo}" if todo and hub.cache_status
                                                       not in ("building",) else "")
        set_text(self.base.query_one("#cache-tag", Label), cache)
        upd = f"running: {hub.running}" if hub.running else "discovering..." if hub.loading else (
            f"updated {time.strftime('%H:%M:%S', time.localtime(hub.loaded_at))}" if hub.loaded_at else
            ("cached view" if hub.types else ""))
        set_text(self.base.query_one("#updated", Label), upd)

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
            key = self.type_sel if self.type_sel != ALL else None
            if key and not self.classic:
                d.show_fields(self.hub.type_by_key(key), self.hub.models.get(key), self.hub.models_v.get(key, 0))
            return
        self.hub.request_model(inst.type_key)
        if not inst.meta.get("cached"):
            self.hub.request_tab(inst)
        fm = self.hub.models.get(inst.type_key)
        d.show(inst, self.hub.type_by_key(inst.type_key), fm, self.hub.tabs.get(instance_key(inst)), self.hub.sc)
        if not self.classic:
            d.show_fields(self.hub.type_by_key(inst.type_key), fm, self.hub.models_v.get(inst.type_key, 0))

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
        if not self.classic:
            strip = self.base.query_one("#profile-strip")
            if strip.has_class("-open"):
                strip.refresh_body(ctx)

    # ------------------------------------------------------------------ sub-services (selector + list)
    def _type_has_subs(self, t: InstanceType | None) -> bool:
        """A sub-service provider exists for the type (decided by type, before any instance exists)."""
        if t is None:
            return False
        hit = self._has_subs.get(t.key)
        if hit is None:
            from ..subservices import REGISTRY
            probe = Instance(t.key, "", None, "", {})
            hit = False
            for prov in REGISTRY:
                try:
                    if prov.matches(t, probe) is not None:
                        hit = True
                        break
                except Exception:              # a provider that can't judge without an instance
                    continue
            self._has_subs[t.key] = hit
        return hit

    def _sync_subs(self) -> None:
        """Which sub-service selector the selected instance gets, and bind its SubServices."""
        inst = self._selected()
        t = self.hub.type_by_key(inst.type_key if inst else self.type_sel) if (inst or self.type_sel != ALL) \
            else None
        tab = self.hub.tabs.get(instance_key(inst)) if inst else None
        show, prompt, tip = False, "sub-service", None
        if inst is None:
            if self._type_has_subs(t):
                show, prompt, tip = True, "create an instance first", "sub-services live inside an instance"
        elif tab is None:
            if self._type_has_subs(t):
                show, prompt = True, ("live state loading..." if inst.meta.get("cached") else "checking...")
        elif tab.enabled:
            show = True
            if self._subs is None or self._subs.parent_key != instance_key(inst):
                self._bind_subs(tab.provider, t, inst)
            elif self._subs.parent_inst is not inst:
                self._subs.parent_inst = inst          # a newer poll of the same instance
        elif tab.provider is not None:          # a manager exists, the instance isn't usable yet
            show, prompt, tip = True, _short(tab.reason), tab.reason
        # tab "no-provider" (kinds detected, no manager yet) and "none": no selector; the state panel says why
        if not (tab and tab.enabled) and self._subs is not None:
            self._drop_subs()
        left = self.base.query_one("#left")
        left.set_class(show, "-sub-select")
        sel = self.base.query_one("#sub-select", Select)
        if self._subs is None:
            set_attr(sel, "prompt", prompt)
            set_attr(sel, "tooltip", tip)
            set_attr(sel, "disabled", True)
            if self._kind_sig is not None:
                self._kind_sig = None
                with sel.prevent(Select.Changed):
                    sel.set_options([])
        self._draw_subs()

    def _bind_subs(self, provider, itype: InstanceType, inst: Instance) -> None:
        from .sub_view import SubServices
        self._drop_subs()
        self._subs = SubServices(self, provider, itype, inst, on_change=self._subs_changed)
        self._subs.reload()

    def _drop_subs(self) -> None:
        if self._subs is None:
            return
        self._subs = None
        self._kind_sig = None
        if self._area == "sub":
            self._area = "inst"
        if any(v == "sub-detail" or v.startswith("subform-") for v in self._stack):
            self._back_to_overview()

    def _subs_changed(self) -> None:
        if not self.is_running:
            return
        with self.batch_update():
            self._draw_subs()
            self._draw_work_header()
            self._draw_state()

    def _draw_subs(self) -> None:
        subs = self._subs
        left = self.base.query_one("#left")
        sel = self.base.query_one("#sub-select", Select)
        panel = self.base.query_one("#sub-panel", VerticalScroll)
        if subs is not None:
            if not subs.loaded:
                set_attr(sel, "prompt", f"loading {subs.display_name}...")
                set_attr(sel, "disabled", True)
            elif subs.error:
                set_attr(sel, "prompt", _short(f"failed: {subs.error}"))
                set_attr(sel, "tooltip", subs.error)
                set_attr(sel, "disabled", True)
            else:
                opts, sig = [], []
                for k, _ in subs.kinds:
                    it = subs.itype(k)
                    n = subs.count(k)
                    label = Text(f"{k.replace('_', ' ')}  ", style="" if it.creatable else "dim")
                    label.append(str(n), style="dim")
                    if not it.creatable:
                        label.append("  list only", style="dim italic")
                    opts.append((label, k))
                    sig.append((k, n, it.creatable))
                set_attr(sel, "prompt", subs.display_name)
                set_attr(sel, "tooltip", f"{subs.display_name} of {subs.parent_inst.display_name or subs.parent_inst.name}"
                                         " (s)")
                set_attr(sel, "disabled", not opts)
                if tuple(sig) != self._kind_sig and not sel.expanded:
                    self._kind_sig = tuple(sig)
                    with sel.prevent(Select.Changed):
                        sel.set_options(opts)
                        sel.value = subs.kind_sel if subs.kind_sel else Select.NULL
                elif sel.value != (subs.kind_sel or Select.NULL) and not sel.expanded:
                    with sel.prevent(Select.Changed):
                        sel.value = subs.kind_sel if subs.kind_sel else Select.NULL
        show_list = bool(subs and subs.loaded and not subs.error and subs.kind_sel)
        left.set_class(show_list, "-sub")
        set_display(panel, show_list)
        if not show_list:
            if self._sub_rows:
                for r in self._sub_rows:
                    r.remove()
                self._sub_rows = []
            return
        from .sub_view import SubItemRow
        items = subs.current_items()
        by = {instance_key(i): i for i in items}
        self._sub_rows, fresh = reconcile(panel, self._sub_rows, list(by), lambda w: w.key, SubItemRow)
        kind = subs.kind_sel.replace("_", " ")
        for row in self._sub_rows:
            args = (by[row.key], kind, [])
            row.set_class(row.key == subs.sel, "-selected")
            if row in fresh:
                self.call_after_refresh(row.fill, *args)
            else:
                row.fill(*args)
        it = subs.itype()
        set_attr(panel, "border_title", f"{kind} · {len(items)}")
        set_attr(panel, "border_subtitle", "n: new · e: resize · d: delete" if it.creatable else "list only")
        btn = self.base.query_one("#new-sub", Button)
        set_attr(btn, "label", f"+ New {kind}")
        set_attr(btn, "disabled", not it.creatable)
        set_attr(btn, "tooltip", None if it.creatable else f"{kind}: list only here (no create request in the API)")
        if self._stack[-1] == "sub-detail":
            self._draw_sub_detail()

    def _draw_sub_detail(self) -> None:
        from .sub_view import engine_text
        subs = self._subs
        if subs is None:
            return
        set_text(self.base.query_one("#sd-text", Static), engine_text(subs.selected(), subs.kind_sel))
        it = subs.itype()
        creatable = bool(it and it.creatable)
        set_attr(self.base.query_one("#act-sub-edit", Button), "disabled", not creatable or subs.selected() is None)
        set_attr(self.base.query_one("#act-sub-delete", Button), "disabled", not creatable or subs.selected() is None)

    # ------------------------------------------------------------------ big panel + state panel
    def _switcher(self) -> ContentSwitcher:
        return self.base.query_one("#switcher", ContentSwitcher)

    def _sync_view(self) -> None:
        """The big panel shows the plan (while open) or the top of the view stack; the state panel
        follows (form context for forms, the selection's state otherwise)."""
        cur = self._stack[-1]
        sw = self._switcher()
        target = "plan" if self._plan_open else cur
        if sw.current != target:
            sw.current = target
        state = self.base.query_one("#state", ContentSwitcher)
        want = "ctx-form" if cur.startswith(FORM_VIEWS) else "st-info"
        if state.current != want:
            state.current = want
        set_attr(state, "border_title", "form · field help · checks · payload" if want == "ctx-form" else "state")
        if cur == "sub-detail":
            self._draw_sub_detail()
        self._draw_work_header()
        self._draw_state()

    def _show_view(self, view_id: str, push: bool = True) -> None:
        if push:
            if view_id in self._stack:
                self._stack = self._stack[:self._stack.index(view_id) + 1]
            else:
                if self._stack[-1].startswith("form-") and view_id.startswith("form-"):
                    self._stack.pop()              # one New form at a time on the stack
                self._stack.append(view_id)
        self._plan_open = False
        self._sync_view()

    def _draw_work_header(self) -> None:
        if self.classic:
            return
        cur = self._stack[-1]
        inst = self._selected()
        t = self.hub.type_by_key(self.type_sel) if self.type_sel != ALL else (
            self.hub.type_by_key(inst.type_key) if inst else None)
        crumb = Text()
        title = "overview"
        subs = self._subs
        if cur == "sub-detail" or cur.startswith("subform-"):
            crumb.append(subs.crumb if subs else "sub-services", style="bold")
            if subs and subs.kind_sel:
                crumb.append(f" › {subs.kind_sel.replace('_', ' ')}")
            if cur.startswith("subform-"):
                form = self._current_form()
                crumb.append(f" › {form.spec.title if form else 'form'}")
                title = "form"
            else:
                item = subs.selected() if subs else None
                crumb.append(f" › {(item.display_name or item.name) if item else '-'}")
                title = "sub-service"
        elif cur.startswith("edit-"):
            form = self._current_form()
            spec_inst = form.spec.inst if form else None
            crumb.append(f"{form.spec.itype.display if form else ''} › "
                         f"{(spec_inst.display_name or spec_inst.name) if spec_inst else ''} › Scale", style="bold")
            title = "form"
        elif cur.startswith("form-"):
            form = self._current_form()
            crumb.append(f"{form.spec.itype.display if form else ''} › New instance", style="bold")
            title = "form"
        else:
            it = self.hub.type_by_key(inst.type_key) if inst else t
            crumb.append(f"{it.display if it else 'All services'} › "
                         f"{(inst.display_name or inst.name) if inst else 'no instance selected'}", style="bold")
        if self._plan_open:
            crumb.append(" › plan")
            title = "plan"
        if len(self._stack) > 1 or self._plan_open:
            crumb.append("   esc: back", style="dim")
        set_text(self.base.query_one("#crumb", Label), crumb)
        banner = ""
        if t is not None and not t.creatable and cur == "overview":
            banner = f"can't be created here: {'; '.join(t.notices) or 'no provisioning entry'}"
        elif t is not None and self.hub.model_state.get(t.key) in ("building", "stale"):
            banner = "re-checking this type's fields..."
        set_text(self.base.query_one("#type-banner", Label), banner)
        set_display(self.base.query_one("#type-banner", Label), bool(banner))
        set_attr(self.base.query_one("#work"), "border_title", title)
        live = inst is not None and not inst.meta.get("cached")
        set_attr(self.base.query_one("#act-edit", Button), "disabled", not live)
        set_attr(self.base.query_one("#act-delete", Button), "disabled", not live)
        set_attr(self.base.query_one("#act-rename", Button), "disabled", inst is None)
        set_attr(self.base.query_one("#act-fields", Button), "disabled", inst is None and t is None)

    def _draw_state(self) -> None:
        if self.classic:
            return
        from .context import state_text
        cur = self._stack[-1]
        if cur.startswith(FORM_VIEWS):
            return                                       # the FormContext follows the form itself
        if cur == "sub-detail" and self._subs is not None:
            subs = self._subs
            text = state_text(subs.selected(), subs.itype(), plain=self.plain,
                              what=subs.kind_sel.replace("_", " ") if subs.kind_sel else "item")
        else:
            inst = self._selected()
            t = self.hub.type_by_key(inst.type_key) if inst else (
                self.hub.type_by_key(self.type_sel) if self.type_sel != ALL else None)
            mism = []
            if inst is not None:
                fm = self.hub.models.get(inst.type_key)
                if isinstance(fm, FormModel):
                    mism = [m.split(": ", 1)[1] for f in fm.fields.values() if f.storage
                            for m in f.storage.mismatches if m.split(":", 1)[0] == inst.name]
                    mism = list(dict.fromkeys(mism))
            text = state_text(inst, t, self.hub.tabs.get(instance_key(inst)) if inst else None, mism,
                              plain=self.plain)
        set_text(self.base.query_one("#st-text", Static), text)

    def _draw_build(self) -> None:
        hub = self.hub
        view = self.base.query_one("#build")
        pr = hub.build
        show = bool(pr is not None and hub.build_big and not pr.finished)
        view.set_class(show, "-open")
        if show:
            view.update_from(pr)

    def _current_form(self):
        from .form_view import FormView
        cur = self._stack[-1]
        try:
            w = self._switcher().get_child_by_id(cur)
        except NoMatches:
            return None
        return w if isinstance(w, FormView) else None

    def _vault_args(self) -> tuple[bool | None, str]:
        from ..ops import credentials
        vmod = credentials.vault()
        who = ", ".join(vmod.member_names()) or "nobody else"
        return vmod.enabled(None), f"Also save the credentials in the Software Hub vault (shared with {who})"

    def _existing_names(self, type_key: str):
        def names() -> list[str]:
            return [n for i in self.hub.instances.get(type_key, []) for n in {i.name, i.display_name} if n]
        return names

    def open_create_form(self, t: InstanceType) -> None:
        """The type's New form in the big panel (mounted once, then only switched to)."""
        from .form_view import FormView, create_spec
        fm = self.hub.models.get(t.key)
        if not isinstance(fm, FormModel):
            self.hub.request_model(t.key)
            self._pending_form = t.key
            self.notify(f"loading {t.display}'s fields; the form opens when they arrive")
            return
        wid = _wid("form", t.key)
        form = self._forms.get(t.key)
        if form is None:
            vault_on, vault_label = self._vault_args()
            entry = t.meta.get("addon")
            form = FormView(create_spec(t, fm, self.hub.sc, offers_vault=getattr(self, "offers_vault", True)),
                            self.hub.sc, owner=None, existing=self._existing_names(t.key),
                            name_regex=entry.name_regex if entry else None, vault_default=vault_on,
                            vault_label=vault_label, id=wid)
            self._switcher().mount(form)
            self._forms[t.key] = form
            self._form_v[t.key] = self.hub.models_v.get(t.key, 0)
            while len(self._forms) > FORM_LRU:
                key, old = self._forms.popitem(last=False)
                if old.id not in self._stack:
                    old.remove()
                self._form_v.pop(key, None)
        else:
            self._forms.move_to_end(t.key)
        self._pending_form = None
        self._area = "inst"
        self._stack = ["overview"]
        self._show_view(wid)
        self.call_after_refresh(self._form_focus, form)

    def _form_focus(self, form, tries: int = 5) -> None:
        if not form.is_attached:
            return
        if not form.query("FieldRow") and form.spec.rows and tries:
            self.call_after_refresh(self._form_focus, form, tries - 1)      # still composing
            return
        found = form.query("#name")
        target = found.first() if found else next(iter(form.query("Input, Select")), None)
        if target is not None and not self._in(self.focused, form):
            target.focus()
        self._update_form_context(form)

    @staticmethod
    def _in(widget, parent) -> bool:
        return widget is not None and any(a is parent for a in widget.ancestors_with_self)

    def _refresh_forms(self) -> None:
        """A model re-checked in the background: rebuild a mounted New form the user hasn't touched."""
        pending = self._pending_form
        if pending and isinstance(self.hub.models.get(pending), FormModel) and self.type_sel == pending:
            t = self.hub.type_by_key(pending)
            if t is not None:
                self.open_create_form(t)
        from ..ops import payload as pl
        for key, form in list(self._forms.items()):
            ver = self.hub.models_v.get(key, 0)
            fm = self.hub.models.get(key)
            if ver == self._form_v.get(key) or not isinstance(fm, FormModel):
                continue
            self._form_v[key] = ver
            if form.dirty or {f.path for _, f in form.spec.rows} == {f.path for f in pl.payload_fields(fm)}:
                form.spec.fm = fm             # same fields (or a draft in progress): keep the widgets
                continue
            current = self._stack[-1] == form.id
            self._forms.pop(key)
            if form.id in self._stack:
                self._stack.remove(form.id)
            form.remove()
            if current:
                t = self.hub.type_by_key(key)
                if t is not None:
                    self.open_create_form(t)

    def _update_form_context(self, form, focused=None, field_set: bool = False) -> None:
        from .context import FormContext, create_preview, edit_preview
        ctx = self.base.query_one("#ctx-form", FormContext)
        if field_set:
            ctx.show_field(focused)
        if form.owner is not None and form.spec.mode == "create" and hasattr(form.owner, "preview"):
            preview = form.owner.preview(form)
        else:
            preview = create_preview(form) if form.spec.mode == "create" and form.owner is None else (
                edit_preview(form) if form.spec.mode == "edit" else None)
        extra = []
        t = form.spec.itype
        if form.spec.mode == "create" and form.owner is None:
            n = len(self.hub.instances.get(t.key, []))
            if t.max_instances and n >= t.max_instances:
                extra.append(f"{t.display} allows at most {t.max_instances} instance(s)")
            if not form.name:
                extra.append("name is required")
        ctx.show(form, preview, extra)

    def on_form_view_changed(self, msg) -> None:
        if not self.classic:
            self._update_form_context(msg.view)

    def on_form_view_field_focused(self, msg) -> None:
        if not self.classic:
            self._update_form_context(msg.view, msg.field, field_set=True)

    def on_form_view_submit(self, msg) -> None:
        self._submit(msg.view)

    def _submit(self, form) -> None:
        if form is None or not self._can_change():
            return
        spec = form.spec
        owner = form.owner
        if spec.mode == "create":
            if owner is not None:
                self._plan_async("sub-plan-create", owner.plan_create(spec.itype, spec.fm, form.values(), form.name,
                                                                      form.description, form.version))
            else:
                self.plan_create(spec.itype, spec.fm, form.values(), form.name, form.description, form.version,
                                 vault=form.vault)
        else:
            changes = form.changes()
            if not changes:
                self.notify("nothing changed")
                return
            if owner is not None:
                self._plan_async("sub-plan-edit", owner.plan_edit(spec.itype, spec.inst, spec.fm, changes))
            else:
                self.plan_edit(spec.itype, spec.inst, spec.fm, changes)

    # ------------------------------------------------------------------ messages / clicks
    def on_select_changed(self, event: Select.Changed) -> None:
        sid = event.select.id
        if sid == "svc-select":
            if event.value is not Select.NULL:
                self._select_type(str(event.value))
        elif sid == "sub-select" and self._subs is not None:
            kind = None if event.value is Select.NULL else str(event.value)
            if self._subs.choose_kind(kind):
                self._area = "sub"
                if self._stack[-1] == "sub-detail" or self._stack[-1].startswith("subform-"):
                    self._back_to_overview()
                self._subs_changed()

    def on_type_selected(self, msg: TypeSelected) -> None:          # --classic-ui catalog rows
        if self.type_sel != msg.key:
            self.type_sel = msg.key
            self.inst_sel = None
            self._redraw(force=True)

    def on_instance_selected(self, msg: InstanceSelected) -> None:
        changed = self.inst_sel != msg.key
        self.inst_sel = msg.key
        self._area = "inst"
        if not self.classic and (self._stack[-1] != "overview" or self._plan_open) and (
                changed or not self._stack[-1].startswith(FORM_VIEWS)):
            self._back_to_overview()
        if changed:
            self._redraw(force=True)

    def on_sub_item_selected(self, msg) -> None:
        subs = self._subs
        if subs is None:
            return
        self._area = "sub"
        if subs.sel != msg.key:
            subs.sel = msg.key
            subs.v += 1
        self._stack = ["overview", "sub-detail"]
        self._show_view("sub-detail", push=False)
        self._draw_subs()

    def on_click(self, event: Click) -> None:
        wid = getattr(event.widget, "id", None)
        if wid == "auto-tag":
            self.action_toggle_auto_repair()
        elif wid == "profile-tag":
            self.action_profile()
        elif wid == "sub-text":
            self.action_subservices()
        elif wid == "cache-tag" and not self.classic and self.hub.build is not None:
            self.base.query_one("#build").toggle_class("-open")

    def on_button_pressed(self, event) -> None:
        if self.classic:                  # the pop-ups handle their own buttons
            return
        bid = event.button.id
        actions = {"new-inst": self._new_instance, "new-sub": self._sub_create, "act-edit": self._edit_instance,
                   "act-delete": self._delete_instance, "act-rename": self.action_rename,
                   "act-fields": self.action_explain, "act-sub-edit": self._sub_edit,
                   "act-sub-delete": self._sub_delete, "repair": self.action_repair_profile,
                   "toggle": self.action_toggle_auto_repair}
        if bid in actions:
            event.stop()
            if bid.startswith(("new-sub", "act-sub")):
                self._area = "sub"
            elif bid.startswith(("new-inst", "act-")):
                self._area = "inst"
            actions[bid]()
        elif bid == "ps-close":
            self.base.query_one("#profile-strip").remove_class("-open")

    def on_plan_panel_closed(self, msg) -> None:
        self._plan_open = False
        self._sync_view()

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
        if self.classic:
            from .forms import PlanScreen
            self.push_screen(PlanScreen(plan, self._run_plan))
            return
        from .context import PlanPanel
        self.base.query_one("#plan", PlanPanel).show(plan, self._run_plan)
        self._plan_open = True
        self._sync_view()

    def _run_plan(self, plan) -> None:
        if self.classic:
            from .forms import CreateScreen, EditScreen
            from .subservice_screen import SubServiceScreen
            while isinstance(self.screen, (CreateScreen, EditScreen)):
                self.pop_screen()
            scr = self.screen                         # captured now: the callback runs later, on the hub thread
            done = (lambda ok: self.call_from_thread(scr.action_reload)) if isinstance(scr, SubServiceScreen) \
                else None
            self.hub.execute(plan, done)
            self.notify(f"{plan.op} {plan.target}: running (progress in the event log)")
            return
        self._plan_open = False
        cur = self._stack[-1]
        sub = self._subs if (cur == "sub-detail" or cur.startswith("subform-")) else None
        done = None
        if sub is not None:
            done = lambda ok: self.call_from_thread(sub.reload)          # noqa: E731
        elif plan.op == "create":
            key = plan.type_key
            done = lambda ok: self.call_from_thread(self._created, key, ok)  # noqa: E731
        self.hub.execute(plan, done)
        self.notify(f"{plan.op} {plan.target}: running (progress in the event log)")
        if cur.startswith(FORM_VIEWS):
            self.action_back()
        else:
            self._sync_view()

    def _created(self, type_key: str, ok: bool) -> None:
        """UI-D4: after a successful create the draft resets and the list shows the new row."""
        form = self._forms.get(type_key)
        if ok and form is not None:
            form.reset()

    def _plan_async(self, name: str, build, type_key: str | None = None) -> None:
        def task() -> None:
            if type_key:
                self.hub.ensure_fresh(type_key)     # storage needs re-checked before any plan (C-D1)
            plan = build()
            self.call_from_thread(self._show_plan, plan)
        self.hub.run_task(name, task)

    def _fresh(self, type_key: str, fm):
        cur = self.hub.models.get(type_key)
        return cur if isinstance(cur, FormModel) else fm

    def _sub_area(self) -> bool:
        return not self.classic and self._area == "sub" and self._subs is not None

    def action_create(self) -> None:
        if self._sub_area():
            return self._sub_create()
        self._new_instance()

    def _new_instance(self) -> None:
        if self.classic and not self._can_change():
            return
        inst = self._selected()
        key = self.type_sel if self.type_sel != ALL else (inst.type_key if inst else None)
        t = self.hub.type_by_key(key) if key else None
        if t is None:
            self.notify("pick a service in the dropdown first (t)")
            return
        if not t.creatable:
            self.notify(f"{t.display} can't be created here: {'; '.join(t.notices) or 'no provisioning entry'}",
                        severity="warning")
            return
        if not self.classic:
            if self.type_sel != t.key:
                self.type_sel = t.key
                self._redraw(force=True)
            self.open_create_form(t)
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
            prov, itype, self._fresh(itype.key, fm), values, name, description, version, api_url=self.api_url,
            name_regex=entry.name_regex if entry else None,
            on_update=lambda insts: self.hub.update_instances(itype.key, insts), vault=vault), type_key=itype.key)

    def _live_selected(self, what: str) -> Instance | None:
        inst = self._selected()
        if inst is None:
            self.notify("select an instance first")
            return None
        if inst.meta.get("cached"):
            self.notify(f"{inst.display_name or inst.name}: the live state is still loading; {what} in a moment")
            return None
        return inst

    def action_edit(self) -> None:
        if self._sub_area():
            return self._sub_edit()
        self._edit_instance()

    def _edit_instance(self) -> None:
        if not self._can_change():
            return
        inst = self._live_selected("scale it")
        if inst is None:
            return
        fm = self._model(inst.type_key)
        if fm is None:
            return
        if self.classic:
            from .forms import EditScreen
            self.push_screen(EditScreen(self.hub.type_by_key(inst.type_key), inst, fm, self.hub.sc))
            return
        from .form_view import FormView, edit_spec
        self._stack = ["overview"]
        self._open_transient(FormView(edit_spec(self.hub.type_by_key(inst.type_key), inst, fm), self.hub.sc,
                                      id=f"edit-{self._next_id()}"))

    def _next_id(self) -> int:
        self._transient += 1
        return self._transient

    def _open_transient(self, widget) -> None:
        """A view that goes away when Esc leaves it (Scale form, a sub-service form)."""
        self._drop_transients()
        self._switcher().mount(widget)
        self._show_view(widget.id)
        self.call_after_refresh(self._form_focus_any, widget)

    def _form_focus_any(self, widget) -> None:
        from .form_view import FormView
        if isinstance(widget, FormView):
            target = next(iter(widget.query("Input, Select")), None)
            if target is not None:
                target.focus()
            self._update_form_context(widget)

    def _drop_transients(self) -> None:
        """Remove transient views (Scale and sub-service forms) that aren't on the stack any more."""
        sw = self._switcher()
        for child in list(sw.children):
            cid = child.id or ""
            if cid.startswith(("edit-", "subform-")) and cid not in self._stack:
                child.remove()

    def plan_edit(self, itype, inst, fm, changes) -> None:
        from ..ops import planner
        if not changes:
            self.notify("nothing changed")
            return
        prov = self.hub.provider
        self._plan_async("plan-edit", lambda: planner.plan_edit(
            prov, itype, inst, self._fresh(itype.key, fm), changes,
            on_update=lambda insts: self.hub.update_instances(itype.key, insts)), type_key=itype.key)

    def action_delete(self) -> None:
        if self._sub_area():
            return self._sub_delete()
        self._delete_instance()

    def _delete_instance(self) -> None:
        if not self._can_change():
            return
        inst = self._live_selected("delete it")
        if inst is None:
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

    # ------------------------------------------------------------------ sub-services (actions)
    def _sub_create(self) -> None:
        subs = self._subs
        if subs is None or not subs.kind_sel or not self._can_change():
            return
        it = subs.itype()
        if not it.creatable:
            self.notify(f"{subs.kind_sel}: list only here", severity="warning")
            return
        sc = self.hub.sc

        def task() -> None:
            from ..storage.field_need import assess_static
            fm = subs.sp.form_model(it)
            assess_static(fm.fields, sc, it.key)          # every storage field gets a filtered picker
            self.call_from_thread(self._open_sub_form, it, fm, None)
        self.hub.run_task("sub-form", task)

    def _sub_edit(self) -> None:
        subs = self._subs
        inst = subs.selected() if subs else None
        if subs is None or not self._can_change():
            return
        if inst is None:
            self.notify("select an item in the sub-service list first")
            return
        it = subs.itype()

        def task() -> None:
            view, edit = subs.sp.edit_model(it, inst, subs.sp.form_model(it))
            self.call_from_thread(self._open_sub_form, it, edit, view)
        self.hub.run_task("sub-edit-form", task)

    def _sub_delete(self) -> None:
        subs = self._subs
        if subs is None or not self._can_change():
            return
        build = subs.plan_delete()
        if build is None:
            self.notify("select an item in the sub-service list first")
            return
        self._plan_async("sub-plan-delete", build)

    def _open_sub_form(self, it, fm, inst) -> None:
        from .form_view import FormView, create_spec, edit_spec
        if self._subs is None:
            return
        sc = self.hub.sc
        spec = edit_spec(it, inst, fm) if inst is not None else create_spec(it, fm, sc, offers_vault=False)
        base = ["overview", "sub-detail"] if inst is not None else ["overview"]
        self._stack = base
        self._open_transient(FormView(spec, sc, owner=self._subs, id=f"subform-{self._next_id()}"))

    # ------------------------------------------------------------------ actions
    def action_service(self) -> None:
        if self.classic:
            return
        sel = self.base.query_one("#svc-select", Select)
        sel.focus()
        sel.action_show_overlay()

    def action_instances(self) -> None:
        if self.classic:
            return
        self._back_to_overview()
        row = next((r for r in self._inst_rows if r.key == self.inst_sel), None)
        if row is not None:
            row.focus()

    def _back_to_overview(self) -> None:
        if self.classic:
            return
        self._stack = ["overview"]
        self._plan_open = False
        self._sync_view()
        self._drop_transients()

    def action_back(self) -> None:
        if self.classic:
            return
        strip = self.base.query_one("#profile-strip")
        legend = self.base.query_one("#legend-strip")
        if self._plan_open:
            self._plan_open = False
            self._sync_view()
        elif len(self._stack) > 1:
            self._stack.pop()
            self._show_view(self._stack[-1], push=False)
            self._drop_transients()
        elif strip.has_class("-open"):
            strip.remove_class("-open")
        elif legend.has_class("-open"):
            legend.remove_class("-open")

    def action_rediscover(self) -> None:
        self.hub.event("info", "re-discovering (R)")
        self._has_subs.clear()
        self.hub.rediscover()

    def check_action(self, action: str, parameters: tuple[object, ...]) -> bool | None:
        """A terminal's reply to a start-up query (e.g. its colours, "rgb:1f1f/...") can arrive as typed
        keys: in the first seconds no key binding runs (they used to toggle the problems filter)."""
        if action != "quit" and time.monotonic() - getattr(self, "_mounted_at", 0.0) < STARTUP_KEY_GRACE:
            return False
        return super().check_action(action, parameters)

    def action_problems(self) -> None:
        self.problems_only = not self.problems_only
        self._redraw(force=True)

    def action_events(self) -> None:
        self.base.query_one("#events").toggle_class("-collapsed")

    def action_tab(self, tab: str) -> None:
        tabs = self.base.query_one("#tabs", TabbedContent)
        try:
            pane = tabs.get_tab(tab)
        except Exception:
            return
        if not pane.disabled:
            if not self.classic and self._stack[-1] != "overview":
                self._back_to_overview()
            tabs.active = tab

    def action_legend(self) -> None:
        if self.classic:
            from .screens import LegendScreen
            self.push_screen(LegendScreen())
            return
        self.base.query_one("#legend-strip").toggle_class("-open")

    def action_explain(self) -> None:
        inst = self._selected()
        key = inst.type_key if inst else (self.type_sel if self.type_sel != ALL else None)
        if key is None:
            self.notify("pick a service first")
            return
        fm, t = self.hub.models.get(key), self.hub.type_by_key(key)
        if not self.classic:
            self.action_tab("tab-fields")
            if not isinstance(fm, FormModel):
                self.hub.request_model(key)
            return
        if isinstance(fm, FormModel) and t:
            from .screens import ExplainScreen
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
        elif self.classic:
            from .subservice_screen import SubServiceScreen
            self.push_screen(SubServiceScreen(tab.provider, self.hub.type_by_key(inst.type_key), inst))
        else:
            sel = self.base.query_one("#sub-select", Select)
            if sel.disabled:
                self.notify(f"{tab.reason}: still loading")
                return
            self._area = "sub"
            sel.focus()
            sel.action_show_overlay()

    def action_profile(self) -> None:
        if self.profile_ctx is None:
            self.notify("this provider has no cpd-cli profile")
            return
        if self.classic:
            from .screens import ProfileScreen
            self.push_screen(ProfileScreen())
            return
        strip = self.base.query_one("#profile-strip")
        strip.toggle_class("-open")
        if strip.has_class("-open"):
            strip.refresh_body(self.profile_ctx)

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
