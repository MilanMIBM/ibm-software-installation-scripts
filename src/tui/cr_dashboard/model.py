"""Data model shared by the sources, the classifier, the graph and the UI."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import Enum

from ..common.state import State


def now_utc() -> datetime:
    return datetime.now(UTC)


def parse_ts(value) -> datetime | None:
    """Kubernetes / ansible-runner timestamps -> aware datetime (None when unparseable)."""
    if not value or not isinstance(value, str):
        return None
    text = value.strip().replace("Z", "+00:00")
    if "_" in text and "T" not in text:  # 2026-10-29_16:50:32
        text = text.replace("_", "T") + "+00:00"
    try:
        ts = datetime.fromisoformat(text)
    except ValueError:
        return None
    return ts if ts.tzinfo else ts.replace(tzinfo=UTC)


class Phase(str, Enum):
    """The CR's own status, normalised."""

    NOT_CREATED = "NotCreated"
    IN_PROGRESS = "InProgress"
    COMPLETED = "Completed"
    FAILED = "Failed"
    SHUTDOWN = "Shutdown"
    UNKNOWN = "Unknown"


@dataclass(frozen=True, order=True)
class CRRef:
    group: str
    version: str
    kind: str
    plural: str
    namespace: str | None
    name: str

    @property
    def key(self) -> str:
        return f"{self.kind}/{self.namespace or '-'}/{self.name}"

    @property
    def gvk(self) -> tuple[str, str]:
        return (self.group, self.kind)

    @property
    def short(self) -> str:
        return f"{self.kind}/{self.name}"


@dataclass
class CRState:
    exists: bool = False
    uid: str | None = None
    owner_uids: tuple[str, ...] = ()
    controller_uid: str | None = None
    phase: Phase = Phase.UNKNOWN
    raw_status: str | None = None
    progress: int | None = None
    message: str | None = None
    reconciled_version: str | None = None
    conditions: list[dict] = field(default_factory=list)
    reconcile_history: list[str] = field(default_factory=list)
    spec_scale: dict[str, str] = field(default_factory=dict)
    shutdown: bool = False
    generation: int | None = None
    created: datetime | None = None
    last_transition: datetime | None = None
    # ansible-operator conditions (no exec needed)
    reconciling: bool | None = None          # Running condition reason == Running
    reconcile_failed: bool = False           # Failure=True / last ansibleResult had failures
    reconcile_failed_msg: str | None = None
    last_reconcile_end: datetime | None = None


@dataclass
class PodIssue:
    name: str
    reason: str
    since: datetime | None


@dataclass
class WorkloadInfo:
    kind: str
    name: str
    desired: int
    ready: int
    updated: int
    since: datetime | None  # when it last changed readiness

    @property
    def diverging(self) -> bool:
        return self.ready != self.desired or self.updated < self.desired


@dataclass
class WorkloadHealth:
    workloads: list[WorkloadInfo] = field(default_factory=list)
    bad_pods: list[PodIssue] = field(default_factory=list)
    pending_pods: list[PodIssue] = field(default_factory=list)
    failed_jobs: list[PodIssue] = field(default_factory=list)
    hpa_scaling: list[str] = field(default_factory=list)

    def merge(self, other: WorkloadHealth) -> None:
        self.workloads += other.workloads
        self.bad_pods += other.bad_pods
        self.pending_pods += other.pending_pods
        self.failed_jobs += other.failed_jobs
        self.hpa_scaling += other.hpa_scaling

    @property
    def diverging(self) -> list[WorkloadInfo]:
        return [w for w in self.workloads if w.diverging]

    @property
    def ready_summary(self) -> str:
        if not self.workloads:
            return "no workloads"
        ok = sum(1 for w in self.workloads if not w.diverging)
        return f"{ok}/{len(self.workloads)} workloads ready"


@dataclass
class OperatorState:
    deployment: str | None = None
    namespace: str | None = None
    pod: str | None = None
    leader: bool | None = None
    ready: bool | None = None
    introspection: str = "off"  # ok | unsupported | denied | off | error | pending
    job_id: str | None = None
    job_running: bool | None = None
    job_started_at: datetime | None = None
    job_failed: bool | None = None          # newest finished job ended with failures
    task: str | None = None
    role: str | None = None
    task_started_at: datetime | None = None
    retry: tuple[int, int] | None = None    # (attempts, retries) of the current task
    last_failed: tuple[datetime | None, str, str, str] | None = None  # ts, task, msg, task_path
    last_event_at: datetime | None = None


@dataclass
class Verdict:
    state: State
    reason: str
    since: datetime | None = None
    badge: str = "filled"  # filled | ring | unknown
    notices: list[str] = field(default_factory=list)
    blocked_by: str | None = None


class EdgeType(str, Enum):
    WAITS = "waits"
    OWNS = "owns"
    DEPENDS = "depends"


@dataclass(frozen=True)
class Edge:
    src: str  # CRRef.key
    dst: str
    type: EdgeType
    rank: int = 0  # tie-breaker among edges of one type (lower wins), e.g. the controller owner
