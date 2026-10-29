"""Detail panel for the selected CR: large GlowDot, reason, operator step, workloads, history."""

from __future__ import annotations

from datetime import datetime

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import ProgressBar, Sparkline, Static

from .cr_list import ago
from .glow_dot import GlowDot
from .util import set_attr, set_display, set_text


def _hhmm(ts: datetime | None) -> str:
    return ts.astimezone().strftime("%H:%M:%S") if ts else "?"


class Detail(Horizontal):
    DEFAULT_CSS = """
    Detail { height: 9; border: round $panel-lighten-2; border-title-color: $text-muted; padding: 0 1; }
    Detail GlowDot.-large { margin: 1 2 0 0; }
    Detail #d-body { width: 1fr; height: 7; }
    Detail #d-side { width: 26; height: 7; }
    Detail #d-side ProgressBar Bar { width: 14; }
    Detail #d-side Sparkline { height: 3; margin-top: 1; }
    Detail #d-side Static { color: $text-muted; }
    """

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.border_title = "detail"

    def compose(self) -> ComposeResult:
        yield GlowDot(size="large")
        yield Static("select a CR", id="d-body")
        with Vertical(id="d-side"):
            yield Static("progress")
            yield ProgressBar(total=100, show_eta=False)
            yield Sparkline([], summary_function=max)

    def show(self, n, now: datetime) -> None:
        if n is None or n.verdict is None:
            return
        v = n.verdict
        self.query_one(GlowDot).set_state(v.state, v.badge)
        set_attr(self, "border_title", f"{n.label} · {v.state.word}" + (f" since {_hhmm(v.since)}" if v.since else ""))
        t = Text()
        t.append(v.reason + "\n", style="bold")
        op = n.op
        if op is not None:
            line = f"operator {op.deployment or '?'}"
            if op.pod:
                line += f" · pod {op.pod}"
            line += f" · {'ready' if op.ready else 'NOT READY' if op.ready is False else 'readiness ?'}"
            if op.introspection not in ("ok",):
                line += f" · step: {op.introspection}"
            t.append(line + "\n")
            if op.introspection == "ok" and op.job_id:
                state = "running" if op.job_running else ("failed" if op.job_failed else "finished")
                job = f"job {op.job_id} {state}"
                if op.job_started_at:
                    job += f" since {_hhmm(op.job_started_at)}"
                t.append(job + "\n")
                if op.task:
                    step = f"step  {op.task}"
                    if op.task_started_at:
                        step += f" ({ago(op.task_started_at, now)})"
                    if op.retry:
                        step += f" · retry {op.retry[0]}/{op.retry[1]}"
                    t.append(step + "\n", style="bold" if op.job_running else "")
            if op.last_failed:
                ts, task, msg, _path = op.last_failed
                t.append(f"last failure {_hhmm(ts)}: {task}: {msg}"[:400] + "\n", style="red")
        wl = n.wl
        line = wl.ready_summary
        if wl.bad_pods:
            line += " · bad pods: " + ", ".join(f"{p.name} {p.reason}" for p in wl.bad_pods[:3])
        if wl.pending_pods:
            line += " · pending: " + ", ".join(f"{p.name} ({p.reason})" for p in wl.pending_pods[:2])
        if wl.failed_jobs:
            line += " · failed jobs: " + ", ".join(j.name for j in wl.failed_jobs[:2])
        t.append(line + "\n")
        bits = []
        if n.cr.reconciled_version or n.expected_version:
            bits.append(f"version {n.cr.reconciled_version or '?'}"
                        + (f" (expected {n.expected_version})" if n.expected_version else ""))
        if n.cr.spec_scale:
            bits.append("scale " + ", ".join(f"{k}={v}" for k, v in list(n.cr.spec_scale.items())[:3]))
        if n.cr.raw_status:
            bits.append(f"status {n.cr.raw_status}")
        if bits:
            t.append(" · ".join(bits) + "\n", style="dim")
        for note in v.notices[:3]:
            t.append(note + "\n", style="yellow")
        if n.cr.reconcile_history:
            t.append("history " + n.cr.reconcile_history[-1][:160] + "\n", style="dim")
        set_text(self.query_one("#d-body", Static), t)
        bar = self.query_one(ProgressBar)
        pct = n.cr.progress if n.cr.progress is not None else 0
        if bar.progress != pct:
            bar.update(progress=pct)
        spark = self.query_one(Sparkline)
        set_display(spark, len(n.history) >= 2)      # one point draws as solid bars
        if list(spark.data or []) != n.history:
            spark.data = list(n.history)
