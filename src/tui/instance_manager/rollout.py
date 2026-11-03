"""Is a service instance really done? The rollout behind an instance's dot.

zen's provision_status says PROVISIONED as soon as zen has handed the request over (Informix
10.2.2: while its server pod was still 0/1 and its CR said InProgress), so it never decides
"healthy" alone. Like the CR dashboard (cr_dashboard.classifier.classify), the verdict combines:

  CR         the instance's own CR (zen+cr types), else the CRs that own its workloads (Informix and
             other kube-yaml add-ons), normalised by cr_dashboard.status_normalize; no status = no vote
  workloads  Deployments, StatefulSets, Jobs and pods labelled icpdsupport/serviceInstanceId=<zen id>
             (the CPD convention), plus pods whose controller is not a workload (EDB: its Cluster CR)
  zen        a floor: in progress or failed there is never healthy here

and names the stage the instance is in: waiting for the operator, scheduling, pulling images,
initialising, starting, provisioning, ready. Problems carry the message the cluster gives
(ImagePullBackOff: "unauthorized: ...", Unschedulable: "0/15 nodes are available: ...").
Textual-free: the provider attaches a Rollout to Instance.meta["rollout"], the UI draws it.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, replace
from datetime import datetime

from ..common.state import State
from ..cr_dashboard.classifier import Context, classify
from ..cr_dashboard.model import CRState, Phase, WorkloadHealth
from ..cr_dashboard.status_normalize import normalize
from ..cr_dashboard.workloads import BAD_WAITING, WorkloadIndex

LABEL = "icpdsupport/serviceInstanceId"
KINDS = {"deployments": "/apis/apps/v1/namespaces/{ns}/deployments",
         "statefulsets": "/apis/apps/v1/namespaces/{ns}/statefulsets",
         "replicasets": "/apis/apps/v1/namespaces/{ns}/replicasets",
         "jobs": "/apis/batch/v1/namespaces/{ns}/jobs",
         "pods": "/api/v1/namespaces/{ns}/pods"}
WORKLOAD_OWNERS = {"ReplicaSet", "StatefulSet", "Job", "DaemonSet", "Deployment"}
ZEN_BUSY = {"PENDING", "PROVISION_IN_PROGRESS", "PROVISIONING", "UPGRADE_IN_PROGRESS", "DELETING"}
ZEN_FAILED = {"FAILED", "PROVISION_FAILED"}
PULLING = {"ContainerCreating", "PodInitializing", "ErrImagePull", "ImagePullBackOff"}
# the stages in order: the earliest one any pod is in names the instance's stage
STAGES = ("waiting for the operator", "scheduling", "pulling images", "initialising", "starting",
          "provisioning", "ready")


@dataclass
class Unit:
    """One progress row: a workload, or the pods of a non-workload controller (EDB Cluster)."""
    kind: str
    name: str
    desired: int
    ready: int

    @property
    def done(self) -> bool:
        return self.ready >= self.desired


@dataclass
class Problem:
    name: str
    reason: str
    message: str = ""


@dataclass
class Rollout:
    state: State
    reason: str
    stage: str
    units: list[Unit] = field(default_factory=list)
    problems: list[Problem] = field(default_factory=list)
    crs: list[tuple[str, str]] = field(default_factory=list)   # ("Informix informix-1793…: InProgress · 100%", phase)
    zen_status: str | None = None
    evidence: bool = False                                # a workload, pod or CR was seen

    @property
    def ready(self) -> int:
        return sum(min(u.ready, u.desired) for u in self.units)

    @property
    def total(self) -> int:
        return sum(u.desired for u in self.units)

    @property
    def fraction(self) -> float:
        """Replicas ready, plus one step for the CR / zen saying done."""
        steps = self.total + 1
        return (self.ready + (1 if self.state == State.HEALTHY else 0)) / steps


# -- collection ---------------------------------------------------------------------------------------
@dataclass
class Snapshot:
    """The labelled objects of one namespace, grouped by zen instance id."""
    groups: dict[str, dict[str, list[dict]]] = field(default_factory=dict)

    def group(self, zid: str) -> dict[str, list[dict]]:
        return self.groups.get(zid) or {k: [] for k in KINDS}


def collect(cluster, namespace: str) -> Snapshot:
    """Five label-selected lists (the cluster client caches them until the next instance refresh)."""
    def one(kind: str) -> list[dict]:
        return cluster.try_list(KINDS[kind].format(ns=namespace), labelSelector=LABEL)

    with ThreadPoolExecutor(max_workers=len(KINDS)) as pool:
        lists = dict(zip(KINDS, pool.map(one, KINDS)))
    snap = Snapshot()
    for kind, items in lists.items():
        for o in items:
            zid = ((o.get("metadata") or {}).get("labels") or {}).get(LABEL)
            if zid and zid != "0":
                snap.groups.setdefault(zid, {k: [] for k in KINDS})[kind].append(o)
    return snap


# -- assessment -------------------------------------------------------------------------------------
def _meta(o: dict) -> dict:
    return o.get("metadata") or {}


def _controller(o: dict) -> dict | None:
    refs = _meta(o).get("ownerReferences") or []
    return next((r for r in refs if r.get("controller")), refs[0] if refs else None)


def _is_cr(ref: dict) -> bool:
    api = ref.get("apiVersion", "")
    return api != "v1" and not api.startswith(("apps/", "batch/"))


def _owner_crs(g: dict[str, list[dict]]) -> list[tuple[str, str, str]]:
    """(apiVersion, kind, name) of the CRs that own the instance's workloads and bare pods."""
    out: list[tuple[str, str, str]] = []
    for o in g["deployments"] + g["statefulsets"] + g["jobs"] + g["pods"]:
        ref = _controller(o)
        if ref and _is_cr(ref):
            key = (ref.get("apiVersion", ""), ref.get("kind", ""), ref.get("name", ""))
            if key not in out:
                out.append(key)
    return out[:6]


def _bare_pod_units(pods: list[dict]) -> list[Unit]:
    """Pods whose controller is not a workload (EDB: the Cluster CR runs them directly)."""
    by: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for p in pods:
        if (p.get("status") or {}).get("phase") in ("Succeeded",):
            continue
        ref = _controller(p)
        if ref is None or ref.get("kind") not in WORKLOAD_OWNERS:
            by[(ref or {}).get("kind", "Pod"), (ref or {}).get("name", _meta(p).get("name", "?"))].append(p)
    return [Unit(kind, name, len(ps), sum(1 for p in ps if _ready(p))) for (kind, name), ps in sorted(by.items())]


def _ready(pod: dict) -> bool:
    return any(c.get("type") == "Ready" and c.get("status") == "True"
               for c in (pod.get("status") or {}).get("conditions") or [])


def _pod_stage(pod: dict) -> int:
    """Index into STAGES for one live pod (len(STAGES)-1 = ready)."""
    st = pod.get("status") or {}
    if st.get("phase") == "Succeeded" or _ready(pod):
        return len(STAGES) - 1
    sched = next((c for c in st.get("conditions") or [] if c.get("type") == "PodScheduled"), None)
    if st.get("phase") == "Pending" and (sched is None or sched.get("status") != "True"):
        return STAGES.index("scheduling")
    statuses = (st.get("initContainerStatuses") or []) + (st.get("containerStatuses") or [])
    if any(((c.get("state") or {}).get("waiting") or {}).get("reason") in PULLING for c in statuses):
        return STAGES.index("pulling images")
    inits = st.get("initContainerStatuses") or []
    if any(((c.get("state") or {}).get("terminated") or {}).get("exitCode") != 0 for c in inits):
        return STAGES.index("initialising")
    return STAGES.index("starting")


def _problems(pods: list[dict], wl: WorkloadHealth) -> list[Problem]:
    out: list[Problem] = []
    for p in pods:
        st = p.get("status") or {}
        name = _meta(p).get("name", "?")
        hit = None
        for c in (st.get("initContainerStatuses") or []) + (st.get("containerStatuses") or []):
            w = (c.get("state") or {}).get("waiting") or {}
            if w.get("reason") in BAD_WAITING:
                hit = Problem(name, w["reason"], (w.get("message") or "").strip())
                break
        if hit is None and st.get("phase") == "Pending":
            sched = next((c for c in st.get("conditions") or [] if c.get("type") == "PodScheduled"), None)
            if sched and sched.get("status") == "False":
                hit = Problem(name, sched.get("reason") or "Unschedulable", (sched.get("message") or "").strip())
        if hit:
            out.append(hit)
    out += [Problem(j.name, j.reason) for j in wl.failed_jobs]
    return out


def _combine(states: list[tuple[str, CRState]]) -> tuple[CRState | None, str | None]:
    """The worst CR that has a status: failed > in progress > completed > shut down (a disabled
    optional part, wxd's lakehouse, doesn't outvote a completed sibling). UNKNOWN = no vote."""
    voting = [(n, c) for n, c in states if c.phase not in (Phase.UNKNOWN, Phase.NOT_CREATED)]
    for want in (Phase.FAILED, Phase.IN_PROGRESS, Phase.COMPLETED, Phase.SHUTDOWN):
        hit = next(((n, c) for n, c in voting if c.phase == want), None)
        if hit:
            return hit[1], hit[0]
    return None, None


def _cr_line(name: str, c: CRState) -> str:
    bits = [c.raw_status or c.phase.value]
    if c.progress is not None and c.phase != Phase.COMPLETED:
        bits.append(f"{c.progress}%")
    if c.message:
        bits.append(c.message[:120])
    return f"{name}: {' · '.join(bits)}"


def assess(zid: str, zen_status: str | None, cr_obj: dict | None, snap: Snapshot,
           owner_cr: Callable[[str, str, str], dict | None] | None = None,
           now: datetime | None = None) -> Rollout:
    g = snap.group(zid)
    zen = (zen_status or "").upper() or None
    wl = WorkloadIndex(deployments=g["deployments"], statefulsets=g["statefulsets"], replicasets=g["replicasets"],
                       jobs=g["jobs"], pods=g["pods"], hpas=[], tracked_uids=set(), label_key=LABEL,
                       label_only=True).health().get(zid) or WorkloadHealth()
    units = [Unit(w.kind, w.name, w.desired, w.ready) for w in wl.workloads] + _bare_pod_units(g["pods"])
    # CR evidence: the instance's own CR, else whatever owns its workloads
    named: list[tuple[str, CRState]] = []
    if cr_obj:
        named.append((f"{cr_obj.get('kind', 'CR')} {_meta(cr_obj).get('name', '?')}",
                      normalize(cr_obj, cr_obj.get("kind", ""), None, None)))
    elif owner_cr is not None:
        for api, kind, name in _owner_crs(g):
            obj = owner_cr(api, kind, name)
            if obj:
                named.append((f"{kind} {name}", normalize(obj, kind, None, None)))
    cr, cr_name = _combine(named)
    live = [p for p in g["pods"] if (p.get("status") or {}).get("phase") not in ("Succeeded", "Failed")]
    evidence = bool(units or named or live)
    all_done = all(u.done for u in units)
    if cr is None:
        # no CR status: zen and the workloads decide; PROVISIONED counts only once every replica is ready
        cr = CRState(exists=True, raw_status=f"zen {zen or '?'}", message=None)
        if zen in ZEN_FAILED:
            cr.phase = Phase.FAILED
            cr.message = f"zen: {zen}"
        elif zen == "PROVISIONED" and all_done:
            cr.phase = Phase.COMPLETED
        else:
            cr.phase = Phase.IN_PROGRESS
    elif zen in ZEN_BUSY and cr.phase == Phase.COMPLETED:
        cr = replace(cr, phase=Phase.IN_PROGRESS)                      # zen hasn't caught up yet
    elif zen in ZEN_FAILED and cr.phase != Phase.FAILED:
        cr = replace(cr, phase=Phase.FAILED, message=f"zen: {zen}")
    verdict = classify(cr, wl, None, Context(now=now) if now else Context())
    problems = _problems(g["pods"], wl)

    if not evidence:
        stage = STAGES[0] if zen in ZEN_BUSY or zen is None else "ready"
    elif live:
        stage = STAGES[min(_pod_stage(p) for p in live)]
    else:
        stage = "provisioning"
    if stage == "ready" and verdict.state != State.HEALTHY:
        stage = "provisioning"
    ro = Rollout(verdict.state, verdict.reason, stage, units, problems,
                 [(_cr_line(n, c), c.phase.value) for n, c in named], zen, evidence)
    if not evidence:
        # nothing on the cluster to check (yet): zen alone, and never healthy while zen is busy
        ro.state = {"PROVISIONED": State.HEALTHY}.get(zen or "", State.FAILING if zen in ZEN_FAILED
                                                        else State.PROGRESS)
        ro.reason = (f"zen: {zen} (no labelled workloads or CR found to check)" if zen == "PROVISIONED"
                     else f"{stage} · zen: {zen or 'no record yet'}")
        return ro
    ready = f"{ro.ready}/{ro.total} ready" if units else ""
    if ro.state == State.PROGRESS:
        bits = [stage] + ([ready] if ready else []) + ([_cr_line(cr_name, cr).split(': ', 1)[1]] if cr_name else [])
        ro.reason = " · ".join(bits)
    elif ro.state == State.HEALTHY:
        ro.reason = f"ready · {ro.total} replica(s)" if units else (cr.message or "completed")
    elif problems and problems[0].message:
        ro.reason = f"{verdict.reason}: {problems[0].message[:140]}"
    return ro
