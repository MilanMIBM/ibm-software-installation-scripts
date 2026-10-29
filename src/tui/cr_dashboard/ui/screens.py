"""Modal screens: colour legend and operator log tail."""

from __future__ import annotations

import re
from typing import ClassVar

from textual.app import ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Grid, Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Label, Log, Static

from ..model import State
from .glow_dot import GlowDot

LEGEND = {
    State.HEALTHY: ("healthy", "Completed, every owned workload ready. Stays green after the install until something breaks."),
    State.PROGRESS: ("in progress", "The CR's own status says it is installing / reconciling / upgrading, and it is moving."),
    State.SCALING: ("scaling", "A scale change or autoscaler is converging: replicas not yet ready, no crash reasons."),
    State.STUCK: ("stuck", "Not Completed and nothing changed past --stall-after, blocked by a failing CR, pods unschedulable."),
    State.FAILING: ("failing", "Status Failed, pods crash-looping / image pull errors / failed jobs, or a failed reconcile."),
    State.INACTIVE: ("inactive", "Registered but not active: CR not created (ring), shut down, or status unknown (?)."),
}
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class LegendScreen(ModalScreen):
    BINDINGS: ClassVar[list[BindingType]] = [Binding("escape,q,question_mark", "app.pop_screen", "close")]
    DEFAULT_CSS = """
    LegendScreen { align: center middle; }
    #legend { width: 96; height: auto; padding: 1 2; background: $panel; border: round $primary; }
    #legend-grid { grid-size: 2; grid-columns: 1fr 1fr; grid-gutter: 1 2; height: auto; }
    .legend-item { height: auto; min-height: 3; }
    .legend-item GlowDot { margin-right: 2; }
    .legend-name { text-style: bold; }
    .legend-text { color: $text-muted; }
    #legend-foot { margin-top: 1; color: $text-muted; }
    """

    def compose(self) -> ComposeResult:
        with Vertical(id="legend"):
            yield Label("[b]Dot legend[/b]  ·  the dot is the CR's own state; problems elsewhere show as notices")
            with Grid(id="legend-grid"):
                for state, (name, text) in LEGEND.items():
                    with Horizontal(classes="legend-item"):
                        yield GlowDot(state, "ring" if state == State.INACTIVE else "filled", size="large")
                        with Vertical():
                            yield Label(name, classes="legend-name")
                            yield Static(text, classes="legend-text")
            yield Static("Notices: op! operator · sub! hidden sub-CR · drift: version  ·  esc to close",
                         id="legend-foot")


class OpLogScreen(ModalScreen):
    BINDINGS: ClassVar[list[BindingType]] = [Binding("escape,q,l", "app.pop_screen", "close"), Binding("f", "toggle_filter", "filter on CR")]
    DEFAULT_CSS = """
    OpLogScreen { align: center middle; }
    #oplog { width: 95%; height: 90%; background: $panel; border: round $primary; }
    #oplog-title { height: 1; padding: 0 1; }
    #oplog Log { height: 1fr; }
    """

    def __init__(self, kube, namespace: str, pod: str, cr_name: str):
        super().__init__()
        self.kube, self.ns, self.pod, self.cr_name = kube, namespace, pod, cr_name
        self.lines: list[str] = []
        self.filtered = False

    def compose(self) -> ComposeResult:
        with Vertical(id="oplog"):
            yield Label(f"operator log · {self.ns}/{self.pod} · last 300 lines · f: filter on {self.cr_name}",
                        id="oplog-title")
            yield Log(highlight=False, max_lines=2000)

    def on_mount(self) -> None:
        self.run_worker(self._load, thread=True, exit_on_error=False)

    def _load(self) -> None:
        try:
            text = self.kube.logs(self.ns, self.pod, tail=300)
        except Exception as e:
            text = f"(could not read the log: {e})"
        self.lines = [ANSI.sub("", ln) for ln in text.splitlines()]
        self.app.call_from_thread(self._show)

    def _show(self) -> None:
        log = self.query_one(Log)
        log.clear()
        lines = [ln for ln in self.lines if self.cr_name in ln] if self.filtered else self.lines
        log.write_lines(lines or ["(no matching lines)"])

    def action_toggle_filter(self) -> None:
        self.filtered = not self.filtered
        self._show()
