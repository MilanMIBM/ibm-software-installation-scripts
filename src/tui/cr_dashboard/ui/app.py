"""DashboardApp: header counts, root problem, chain view, CR list, detail, event log.

Sources run on daemon threads that write into the in-memory Hub; the app polls the
hub's change counter every 0.5 s and recomputes on the UI thread (at most once a
second, and at least every 5 s so time-based states like "stuck" advance).
"""

from __future__ import annotations

import os
import time
from typing import ClassVar

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Horizontal
from textual.widgets import Footer, Header, Input, Label, RichLog, Static

from ..display import display_rows
from ..model import State
from .chain_view import ChainView, RowFocused
from .cr_list import SORTS, CRList, sort_keys
from .detail import Detail
from .glow_dot import DOT_COLORS, GlowDot, as_content
from .pulse import PulseClock
from .screens import LegendScreen, OpLogScreen
from .util import set_attr, set_text

TREE_MODES = ("live", "owns", "deps")


def _truecolor() -> bool:
    if os.environ.get("COLORTERM", "").lower() in ("truecolor", "24bit"):
        return True
    return os.environ.get("TERM_PROGRAM", "") in ("iTerm.app", "WezTerm", "vscode", "ghostty", "Hyper", "tmux")


class DashboardApp(App):
    CSS_PATH = "app.tcss"
    TITLE = "cr-dashboard"
    BINDINGS: ClassVar[list[BindingType]] = [
        Binding("q", "quit", "quit"),
        Binding("r", "relist", "refresh"),
        Binding("f", "problems", "problems only"),
        Binding("t", "tree_mode", "tree mode"),
        Binding("d", "deps", "deps"),
        Binding("s", "sort", "sort"),
        Binding("l", "oplog", "op log"),
        Binding("slash", "search", "search"),
        Binding("a", "animation", "animation"),
        Binding("question_mark", "legend", "legend"),
        Binding("escape", "close_search", show=False),
    ]

    def __init__(self, *, kube, profile, hub, engine, intro, resources, user: str, header: str,
                 animate: bool = True, plain: bool = False, exit_when_settled=None):
        super().__init__()
        self.kube, self.profile, self.hub, self.engine, self.intro = kube, profile, hub, engine, intro
        self.resources = resources
        self.user = user
        self.header_text = header
        self.plain = plain
        self.halo = _truecolor()
        animate = animate and os.environ.get("TEXTUAL_ANIMATIONS", "full").lower() != "none"
        self.pulse = PulseClock(self, animate)
        self.exit_when_settled = exit_when_settled
        self.view = None
        self.selected: str | None = None
        self.collapsed: set[str] = set()
        self.expanded_groups: set[str] = set()
        self.problems_only = False
        self.sort_mode = "severity"
        self.search = ""
        self._seen = -1
        self._last = 0.0
        self._events_seen = 0
        self._notified: set[tuple[str, State]] = set()
        self._errors_seen: set[str] = set()
        self.settled_view = None

    def get_css_variables(self) -> dict[str, str]:
        variables = super().get_css_variables()
        variables.update({f"dot-{s.value}": c for s, c in DOT_COLORS.items()})
        return variables

    # ------------------------------------------------------------------
    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Horizontal(id="status"):
            for s in State:
                yield GlowDot(s, "ring" if s == State.INACTIVE else "filled")
                yield Label(f"0 {s.word}", id=f"cnt-{s.value}", classes="count")
            yield Label("starting…", id="updated")
        yield Static("loading…", id="root-problem")
        with Horizontal(id="main"):
            yield ChainView(id="chains")
            yield CRList(id="crlist")
        yield Detail(id="detail")
        yield RichLog(id="events", max_lines=500, wrap=False, markup=False)
        yield Input(placeholder="filter by name (esc to close)", id="search")
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = self.header_text.replace("cr-dashboard · ", "")
        self.query_one("#events", RichLog).border_title = "events"
        self.hub.start(self.resources)
        self.intro.start()
        self.pulse.start()
        log = self.query_one("#events", RichLog)
        for note in self.profile.notes:
            log.write(Text(f"note  {note}", style="yellow"))
        if not self.intro.enabled:
            log.write(Text("note  operator introspection off (--no-exec): no current step", style="dim"))
        self.set_interval(0.5, self._tick)

    # ------------------------------------------------------------------
    def _tick(self) -> None:
        now = time.monotonic()
        changed = self.hub.version != self._seen
        if (changed and now - self._last >= 1.0) or now - self._last >= 5.0:
            self._recompute()
        elif self.view is not None:
            self._update_clock()

    def _recompute(self) -> None:
        self._seen = self.hub.version
        self._last = time.monotonic()
        view = self.engine.compute(self.intro)
        self.view = view
        targets, green = self.engine.intro_targets(view)
        self.intro.set_targets(targets, green)
        self._render_view()
        if (self.exit_when_settled and view.settled_since and not view.loading
                and view.computed_at - view.settled_since >= self.exit_when_settled):
            self.settled_view = view
            self.exit()

    def _update_clock(self) -> None:
        v = self.view
        age = int(time.monotonic() - self._last)
        bits = [f"live · updated {age}s ago"]
        if v.loading:
            bits.append("loading…")
        if v.errors:
            bits.append(f"{len(v.errors)} source error{'s' if len(v.errors) > 1 else ''}")
        if not self.pulse.animate:
            bits.append("animation off")
        set_text(self.query_one("#updated", Label), " · ".join(bits))

    def _render_view(self) -> None:
        # one repaint per refresh, and only the widgets whose content changed are touched
        with self.batch_update():
            self._render_view_now()

    def _render_view_now(self) -> None:
        v = self.view
        nodes, now = v.nodes, v.computed_at
        for s in State:
            set_text(self.query_one(f"#cnt-{s.value}", Label), f"{v.counts.get(s, 0)} {s.word}")
        self._update_clock()
        rp = self.query_one("#root-problem", Static)
        if v.root_problems:
            t = Text()
            for k in v.root_problems[:2]:
                n = nodes[k]
                t.append("ROOT PROBLEM ", style="bold")
                t.append_text(as_content(n.verdict.state, n.verdict.badge, self.plain))
                t.append(f" {n.label}: {n.verdict.reason}\n")
            if len(v.root_problems) > 2:
                t.append(f"… and {len(v.root_problems) - 2} more (f: problems only)")
            t.rstrip()
            set_text(rp, t)
            rp.set_class(False, "-none")
        else:
            set_text(rp, "loading…" if v.loading else "no problems: every component is healthy, in progress or inactive")
            rp.set_class(True, "-none")
        drows = display_rows(v.rows, nodes, self.expanded_groups)
        self.query_one(ChainView).show(drows, nodes, self.collapsed)
        # the list shows components, plus sub-CRs only when they need attention (healthy ones are
        # folded in the chain view)
        keys = [k for k in v.list_keys if nodes[k].verdict is not None and
                (nodes[k].is_component or nodes[k].verdict.state not in (State.HEALTHY, State.INACTIVE))]
        if self.problems_only:
            keys = [k for k in keys if nodes[k].verdict.state in (State.FAILING, State.STUCK)]
        if self.search:
            q = self.search.lower()
            keys = [k for k in keys if q in nodes[k].label.lower() or q in (nodes[k].component or "").lower()]
        crlist = self.query_one(CRList)
        set_attr(crlist, "border_title", f"all CRs · sort {self.sort_mode}"
                 + (" · problems only" if self.problems_only else "") + (f" · '{self.search}'" if self.search else ""))
        crlist.show(sort_keys(keys, nodes, self.sort_mode, now), nodes, now)
        if self.selected not in nodes:
            ordered = sort_keys(v.list_keys, nodes, "severity", now)
            self.selected = v.root_problems[0] if v.root_problems else (ordered[0] if ordered else None)
        if self.selected in nodes:
            self.query_one(Detail).show(nodes[self.selected], now)
        set_attr(self.query_one(ChainView), "border_title",
                 f"chains · {self.engine.tree_mode}" + (" + deps" if self.engine.show_deps else ""))
        self._log_events(v)

    def _log_events(self, v) -> None:
        log = self.query_one("#events", RichLog)
        total = self.engine.event_count
        new = list(self.engine.event_log)[-(total - self._events_seen):] if total > self._events_seen else []
        self._events_seen = total
        for e in new:
            t = Text(e.ts.astimezone().strftime("%H:%M:%S "), style="dim")
            if e.old is not None and e.new is not None:
                t.append_text(as_content(e.old, plain=self.plain))
                t.append("→")
                t.append_text(as_content(e.new, plain=self.plain))
                t.append(f" {e.label} {e.new.word}: {e.text}")
                self._maybe_notify(e)
            else:
                t.append(f"   {e.label} {e.text}")
            log.write(t)
        for err in v.errors:
            if err not in self._errors_seen:
                self._errors_seen.add(err)
                log.write(Text(f"source  {err}", style="red"))

    def _maybe_notify(self, e) -> None:
        if e.new not in (State.FAILING, State.STUCK) or (e.key, e.new) in self._notified:
            return
        self._notified.add((e.key, e.new))
        self.notify(f"{e.label}: {e.text}", title=e.new.word, severity="error" if e.new == State.FAILING else "warning",
                    timeout=8)

    # ------------------------------------------------------------------
    def on_row_focused(self, msg: RowFocused) -> None:
        if msg.key and self.view and msg.key in self.view.nodes:
            self.selected = msg.key
            self.intro.priority = msg.key
            self.intro.slow.pop(msg.key, None)   # re-read its operator step on the next tick
            self.query_one(Detail).show(self.view.nodes[msg.key], self.view.computed_at)

    def on_chain_view_toggle(self, msg: ChainView.Toggle) -> None:
        d = msg.drow
        if d.kind == "group":
            want = not d.expanded if msg.collapse is None else not msg.collapse
            (self.expanded_groups.add if want else self.expanded_groups.discard)(d.row_id)
        elif d.has_children:
            collapse = (d.row_id not in self.collapsed) if msg.collapse is None else msg.collapse
            (self.collapsed.add if collapse else self.collapsed.discard)(d.row_id)
        if self.view:
            self._render_view()

    def on_input_changed(self, msg: Input.Changed) -> None:
        self.search = msg.value.strip()
        if self.view:
            self._render_view()

    # ------------------------------------------------------------------
    def action_relist(self) -> None:
        self.hub.request_relist()
        self.notify("re-listing all resources", timeout=2)

    def action_problems(self) -> None:
        self.problems_only = not self.problems_only
        if self.view:
            self._render_view()

    def action_tree_mode(self) -> None:
        self.engine.tree_mode = TREE_MODES[(TREE_MODES.index(self.engine.tree_mode) + 1) % len(TREE_MODES)]
        self._recompute()

    def action_deps(self) -> None:
        self.engine.show_deps = not self.engine.show_deps
        self._recompute()

    def action_sort(self) -> None:
        self.sort_mode = SORTS[(SORTS.index(self.sort_mode) + 1) % len(SORTS)]
        if self.view:
            self._render_view()

    def action_animation(self) -> None:
        self.pulse.set_animate(not self.pulse.animate)
        if self.view:
            self._update_clock()

    def action_legend(self) -> None:
        self.push_screen(LegendScreen())

    def action_search(self) -> None:
        box = self.query_one("#search", Input)
        box.add_class("-visible")
        box.focus()

    def action_close_search(self) -> None:
        box = self.query_one("#search", Input)
        if box.has_class("-visible"):
            box.remove_class("-visible")
            box.value = ""
            self.search = ""
            if self.view:
                self._render_view()

    def action_oplog(self) -> None:
        n = self.view.nodes.get(self.selected) if self.view and self.selected else None
        op = n.op if n else None
        if op is None or not (op.pod or op.deployment):
            self.notify("no operator known for the selected CR", severity="warning", timeout=3)
            return
        ns, pod = op.namespace, op.pod
        if not pod:
            for ons in self.profile.operator_namespaces():
                d = next((x for x in self.hub.items(f"deployments@{ons}") if x["metadata"]["name"] == op.deployment),
                         None)
                if d is not None:
                    pods = self.intro._running_pods(ons, d)
                    if pods:
                        ns, pod = ons, pods[0]
                        break
        if not pod:
            self.notify(f"no running pod for {op.deployment}", severity="warning", timeout=3)
            return
        self.push_screen(OpLogScreen(self.kube, ns, pod, n.ref.name))
