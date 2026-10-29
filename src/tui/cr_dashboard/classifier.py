"""Evidence -> Verdict (the dot). Pure function; plan §2.2 / §2.3.

D8: the dot is the CR's own state. A Completed CR with healthy workloads stays green;
operator trouble, periodic or failed reconciles and version drift are notices. Operator
evidence only escalates a CR whose own status is not Completed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from .model import CRState, OperatorState, Phase, State, Verdict, WorkloadHealth, now_utc

_SCALING_MSG = re.compile(r"\bscal(e|es|ed|ing)\b", re.IGNORECASE)


@dataclass
class Thresholds:
    stall_after: timedelta = timedelta(minutes=15)
    debounce: timedelta = timedelta(seconds=30)
    scale_grace: timedelta = timedelta(minutes=10)
    retry_warn: float = 0.8


@dataclass
class Context:
    now: datetime = field(default_factory=now_utc)
    th: Thresholds = field(default_factory=Thresholds)
    last_change: datetime | None = None        # newest observed change (progress/message/task/replicas)
    scale_changed_at: datetime | None = None   # a scale field changed during the session
    expected_version: str | None = None
    blocked_by: list[tuple[str, State]] = field(default_factory=list)  # WAITS targets that are red/yellow
    hidden_issues: list[str] = field(default_factory=list)             # sub! notices from hidden sub-CRs
    note: str | None = None                                             # profile note (e.g. "no CR metadata")


def _age(ctx: Context, ts: datetime | None) -> timedelta:
    return ctx.now - ts if ts else timedelta(days=365)


def _dur(td: timedelta) -> str:
    s = int(td.total_seconds())
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    return f"{s // 3600}h{(s % 3600) // 60:02d}m"


def _hhmm(ts: datetime | None) -> str:
    return ts.astimezone().strftime("%H:%M") if ts else "?"


def classify(cr: CRState, wl: WorkloadHealth | None, op: OperatorState | None, ctx: Context) -> Verdict:
    wl = wl or WorkloadHealth()
    th = ctx.th
    notices = list(ctx.hidden_issues)
    completed = cr.phase == Phase.COMPLETED

    # ---- notices that never change a Completed CR's colour (D8)
    if op is not None and op.ready is False:
        notices.append("op! operator not ready")
    if completed and cr.reconcile_failed:
        notices.append("op! last reconcile failed" + (f": {cr.reconcile_failed_msg}" if cr.reconcile_failed_msg else ""))
    if completed and op is not None and op.job_failed and not op.job_running and op.last_failed:
        notices.append(f"op! reconcile failed {_hhmm(op.last_failed[0])}: {op.last_failed[1]}")
    if (completed and ctx.expected_version and cr.reconciled_version
            and cr.reconciled_version != ctx.expected_version):
        notices.append(f"drift: reconciled {cr.reconciled_version} ≠ expected {ctx.expected_version}")

    def v(state: State, reason: str, since=None, badge="filled", blocked=None) -> Verdict:
        return Verdict(state, reason, since, badge, notices, blocked)

    # ---- not created / shutdown / explicit failure
    if not cr.exists:
        return v(State.INACTIVE, ctx.note or "registered, not created", badge="ring")
    if cr.phase == Phase.FAILED:
        return v(State.FAILING, cr.message or f"status {cr.raw_status}", cr.last_transition)
    if cr.phase == Phase.SHUTDOWN:
        return v(State.INACTIVE, "shut down" + (f" ({cr.raw_status})" if cr.raw_status else ""), cr.last_transition)

    # ---- FAILING: workload evidence (applies to Completed CRs too)
    crash = [p for p in wl.bad_pods if _age(ctx, p.since) >= th.debounce]
    if crash:
        names = ", ".join(sorted({p.name.rsplit("-", 2)[0] for p in crash})[:2])
        reasons = sorted({p.reason for p in crash})
        return v(State.FAILING, f"{len(crash)} pod{'s' if len(crash) > 1 else ''} {'/'.join(reasons)} ({names})",
                 min((p.since for p in crash if p.since), default=None))
    if wl.failed_jobs:
        j = wl.failed_jobs[0]
        return v(State.FAILING, f"job {j.name} {j.reason}", j.since)

    # ---- FAILING: operator evidence, only while the CR itself is not Completed
    if not completed:
        if op is not None and op.introspection == "ok" and op.job_failed and not op.job_running and op.last_failed:
            ts, task, msg, _path = op.last_failed
            return v(State.FAILING, f"reconcile failed {_hhmm(ts)}: {task}" + (f": {msg}" if msg else ""), ts)
        if (op is None or op.introspection != "ok") and cr.reconcile_failed and cr.reconciling is False:
            return v(State.FAILING, cr.reconcile_failed_msg or "last reconcile failed", cr.last_reconcile_end)

    # ---- STUCK
    pending = [p for p in wl.pending_pods if _age(ctx, p.since) >= th.debounce]
    if pending:
        return v(State.STUCK, f"{len(pending)} pod{'s' if len(pending) > 1 else ''} pending: {pending[0].reason}",
                 min((p.since for p in pending if p.since), default=None))
    if not completed:
        bad = [b for b in ctx.blocked_by if b[1] in (State.FAILING, State.STUCK)]
        if bad:
            name, state = bad[0]
            return v(State.STUCK, f"blocked by {name} ({state.word})", blocked=name)
        if op is not None and op.retry and op.retry[1] > 0 and op.retry[0] / op.retry[1] >= th.retry_warn:
            return v(State.STUCK, f"wait loop {op.retry[0]}/{op.retry[1]} retries: {op.task}", op.task_started_at)
        if op is not None and op.ready is False:
            return v(State.STUCK, "operator not ready, nothing is reconciling")

    # ---- SCALING / workload divergence
    diverging = wl.diverging
    div_since = min((w.since for w in diverging if w.since), default=None)
    at_expected = (not ctx.expected_version or not cr.reconciled_version
                   or cr.reconciled_version == ctx.expected_version)
    scale_recent = ctx.scale_changed_at is not None and _age(ctx, ctx.scale_changed_at) < th.scale_grace * 3
    scaling_reason = None
    if wl.hpa_scaling:
        scaling_reason = "autoscaling " + ", ".join(wl.hpa_scaling[:2])
    elif scale_recent and (not completed or diverging):
        scaling_reason = "scale change" + (f": {_ready(wl)}" if diverging else "")
    elif cr.message and _SCALING_MSG.search(cr.message) and not completed:
        scaling_reason = cr.message
    elif diverging and (completed or (at_expected and cr.phase != Phase.IN_PROGRESS)):
        if _age(ctx, div_since) < th.scale_grace or scale_recent:
            scaling_reason = _ready(wl)
        else:
            return v(State.FAILING, f"{_ready(wl)} for {_dur(_age(ctx, div_since))}", div_since)

    in_progress = cr.phase == Phase.IN_PROGRESS or (not completed and bool(diverging))
    last_change = ctx.last_change
    if scaling_reason or in_progress:
        if last_change and _age(ctx, last_change) >= th.stall_after:
            what = "scaling" if scaling_reason else "in progress"
            return v(State.STUCK, f"{what}, no change for {_dur(_age(ctx, last_change))}"
                     + (f": {cr.message}" if cr.message else ""), last_change)
        if scaling_reason:
            return v(State.SCALING, scaling_reason, ctx.scale_changed_at or div_since)
        reason = cr.message or ("reconciling" if cr.reconciling else f"status {cr.raw_status}")
        if op is not None and op.task and op.introspection == "ok" and op.job_running:
            reason = f"{reason} · task: {op.task}"
        return v(State.PROGRESS, reason, last_change)

    if completed:
        return v(State.HEALTHY, cr.message or "completed", cr.last_transition)

    # UNKNOWN status with no other evidence
    return v(State.INACTIVE, f"status unknown ({cr.raw_status})" if cr.raw_status else "status unknown",
             badge="unknown")


def _ready(wl: WorkloadHealth) -> str:
    div = wl.diverging
    if not div:
        return wl.ready_summary
    w = div[0]
    more = f" +{len(div) - 1}" if len(div) > 1 else ""
    return f"{w.name} {w.ready}/{w.desired} ready{more}"
