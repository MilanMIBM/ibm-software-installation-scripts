"""Engine: hub objects -> nodes, edges, forest, verdicts, events (UI-thread only).

Session tracking (last change, scale changes, progress history, recovery debounce,
event log) lives in memory here and is gone on exit; nothing is persisted.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from datetime import datetime

from . import graph
from .classifier import Context, Thresholds, classify
from .k8s_source import Hub, IntroTarget, Resource, make_trim_workload, norm_id, trim_cr
from .model import CRRef, CRState, Edge, EdgeType, OperatorState, Phase, State, Verdict, WorkloadHealth, now_utc
from .profiles import CRDInfo, Profile, TargetSpec
from .status_normalize import normalize
from .workloads import WorkloadIndex

WORKLOAD_KINDS = {
    "deployments": "/apis/apps/v1/namespaces/{ns}/deployments",
    "statefulsets": "/apis/apps/v1/namespaces/{ns}/statefulsets",
    "replicasets": "/apis/apps/v1/namespaces/{ns}/replicasets",
    "jobs": "/apis/batch/v1/namespaces/{ns}/jobs",
    "pods": "/api/v1/namespaces/{ns}/pods",
    "hpas": "/apis/autoscaling/v2/namespaces/{ns}/horizontalpodautoscalers",
}
LABEL_KEYS = ("icpdsupport/addOnId", "component-id", "app.kubernetes.io/instance")


@dataclass
class Node:
    key: str
    ref: CRRef
    component: str | None
    is_component: bool
    cr: CRState
    spec: TargetSpec | None = None
    wl: WorkloadHealth = field(default_factory=WorkloadHealth)
    op: OperatorState | None = None
    verdict: Verdict | None = None
    hidden: bool = False
    fold_into: str | None = None
    waits_on: str | None = None
    placeholder: bool = False
    expected_version: str | None = None
    worst_desc: State | None = None
    last_change: datetime | None = None
    history: list[int] = field(default_factory=list)
    note: str | None = None
    label: str = ""


@dataclass
class Event:
    ts: datetime
    key: str
    label: str
    old: State | None
    new: State | None
    text: str


@dataclass
class View:
    nodes: dict[str, Node]
    rows: list[graph.Row]
    list_keys: list[str]
    counts: dict[State, int]
    root_problems: list[str]
    events: list[Event]
    errors: list[str]
    notes: list[str]
    computed_at: datetime
    loading: bool
    settled_since: datetime | None


@dataclass
class _Track:
    sig: tuple | None = None
    changed_at: datetime | None = None
    scale_sig: tuple | None = None
    scale_changed_at: datetime | None = None
    progress: int | None = None
    history: deque = field(default_factory=lambda: deque(maxlen=60))
    state: State | None = None
    recovering_since: datetime | None = None
    notices: frozenset = frozenset()


# ---------------------------------------------------------------------------
def build_resources(specs: list[TargetSpec], profile: Profile, crds: dict[tuple[str, str], CRDInfo],
                    scan: bool = True) -> tuple[list[Resource], list[TargetSpec]]:
    """Hub resources: one watch per CR kind (cluster-wide, per-namespace fallback), workloads per
    namespace, and a slow poll over the other kinds of the component API groups (follow owned)."""
    res, seen = [], set()
    for s in specs:
        if s.missing_crd or s.collection in seen:
            continue
        seen.add(s.collection)
        base = f"/apis/{s.group}/{s.version}"
        if s.namespaced:
            nss = s.namespaces or profile.namespaces()
            res.append(Resource(s.collection, f"{base}/{s.plural}", trim_cr,
                                fallback_paths=[f"{base}/namespaces/{ns}/{s.plural}" for ns in nss]))
        else:
            res.append(Resource(s.collection, f"{base}/{s.plural}", trim_cr))
    trim_wl = make_trim_workload(LABEL_KEYS)
    for ns in profile.namespaces():
        for kind, path in WORKLOAD_KINDS.items():
            res.append(Resource(f"{kind}@{ns}", path.format(ns=ns), trim_wl))
    for ns in profile.operator_namespaces():
        for kind in ("deployments", "replicasets", "pods"):
            if f"{kind}@{ns}" not in {r.name for r in res}:
                res.append(Resource(f"{kind}@{ns}", WORKLOAD_KINDS[kind].format(ns=ns), trim_wl))
    scan_specs = []
    if scan:
        groups = profile.scan_groups(specs)
        have = {(s.group, s.kind) for s in specs}
        for (group, kind), info in crds.items():
            if group not in groups or (group, kind) in have:
                continue
            ver = info.version()
            sp = TargetSpec(group=group, version=ver, kind=kind, plural=info.plural, namespaced=info.namespaced,
                            name=None, namespaces=profile.namespaces() if info.namespaced else None,
                            is_component=False, printer_columns=info.printer_columns.get(ver, []))
            name = "scan:" + sp.collection[3:]
            base = f"/apis/{group}/{ver}"
            res.append(Resource(name, f"{base}/{info.plural}", trim_cr, poll=30.0,
                                fallback_paths=[f"{base}/namespaces/{ns}/{info.plural}"
                                                for ns in profile.namespaces()] if info.namespaced else []))
            scan_specs.append(sp)
    return res, scan_specs


class Engine:
    def __init__(self, profile: Profile, hub: Hub, crds: dict[tuple[str, str], CRDInfo], specs: list[TargetSpec],
                 scan_specs: list[TargetSpec], *, th: Thresholds | None = None, max_depth: int | None = 3,
                 tree_mode: str = "live", show_deps: bool = False):
        self.profile, self.hub, self.crds = profile, hub, crds
        self.specs, self.scan_specs = specs, scan_specs
        self.th = th or Thresholds()
        self.max_depth = max_depth
        self.tree_mode = tree_mode
        self.show_deps = show_deps
        self.session_start = now_utc()
        self.tracks: dict[str, _Track] = {}
        self.event_log: deque[Event] = deque(maxlen=500)
        self.event_count = 0
        self.last_activity = self.session_start
        self.first = True
        self.ops_ready: dict[str, bool] = {}

    # ------------------------------------------------------------------
    def _ns_ok(self, spec: TargetSpec, obj: dict) -> bool:
        ns = (obj.get("metadata") or {}).get("namespace")
        if not spec.namespaced:
            return True
        nss = spec.namespaces if spec.namespaces is not None else self.profile.namespaces()
        return not nss or ns in nss

    @staticmethod
    def _ref(spec: TargetSpec, obj: dict | None) -> CRRef:
        if obj:
            m = obj["metadata"]
            return CRRef(spec.group, spec.version, spec.kind, spec.plural, m.get("namespace"), m.get("name", "?"))
        ns = (spec.namespaces or [None])[0] if spec.namespaced else None
        return CRRef(spec.group, spec.version, spec.kind, spec.plural, ns, spec.name or "-")

    def _nodes(self) -> dict[str, Node]:
        nodes: dict[str, Node] = {}
        uids: set[str] = set()
        pool: list[tuple[TargetSpec, dict]] = []     # candidates for "follow owned"
        for spec in self.specs:
            objs = [] if spec.missing_crd else [o for o in self.hub.items(spec.collection) if self._ns_ok(spec, o)]
            exact = [o for o in objs if spec.name is None or o["metadata"].get("name") == spec.name]
            chosen = exact or (objs if spec.allow_any_name and spec.name else [])
            pool += [(spec, o) for o in objs if o not in chosen and o["metadata"].get("ownerReferences")]
            if not chosen:
                ref = self._ref(spec, None)
                cr = CRState(exists=False, phase=Phase.NOT_CREATED)
                node = Node(ref.key, ref, spec.component, True, cr, spec, expected_version=spec.expected_version)
                if objs and not spec.note:
                    node.note = f"no own CR ({len(objs)} {spec.kind} under other components)"
                nodes.setdefault(ref.key, node)
                continue
            for o in chosen:
                uid = o["metadata"].get("uid")
                if uid in uids:
                    continue
                uids.add(uid)
                ref = self._ref(spec, o)
                cr = normalize(o, spec.kind, spec.printer_columns, spec.override)
                nodes[ref.key] = Node(ref.key, ref, spec.component, spec.is_component, cr, spec,
                                      expected_version=spec.expected_version)
        # a component spec without a CR name matches every instance; instances owned by another
        # tracked CR are that CR's sub-CRs, not components
        for n in nodes.values():
            if n.spec is not None and n.spec.name is None and n.cr.exists and any(u in uids for u in n.cr.owner_uids):
                n.is_component = False
        # follow owned: sub-CRs whose owner chain reaches a tracked CR
        for sp in self.scan_specs:
            for o in self.hub.items("scan:" + sp.collection[3:]):
                if o["metadata"].get("ownerReferences") and self._ns_ok(sp, o):
                    pool.append((sp, o))
        for _ in range(8):
            added = False
            for sp, o in pool:
                uid = o["metadata"].get("uid")
                if uid in uids:
                    continue
                if any(r.get("uid") in uids for r in o["metadata"].get("ownerReferences") or []):
                    uids.add(uid)
                    ref = self._ref(sp, o)
                    nodes[ref.key] = Node(ref.key, ref, None, False,
                                          normalize(o, sp.kind, sp.printer_columns, sp.override), None)
                    added = True
            if not added:
                break
        for ph in self.profile.placeholders:
            ref = CRRef("", "", "-", "", None, ph.component)
            cr = CRState(exists=False, phase=Phase.NOT_CREATED)
            nodes[ref.key] = Node(ref.key, ref, ph.component, True, cr, None, placeholder=True)
        return nodes

    def _workloads(self, nodes: dict[str, Node]) -> None:
        uid_key = {n.cr.uid: k for k, n in nodes.items() if n.cr.uid}
        coll = {k: [] for k in WORKLOAD_KINDS}
        for ns in self.profile.namespaces():
            for k in WORKLOAD_KINDS:
                coll[k] += self.hub.items(f"{k}@{ns}")
        idx = WorkloadIndex(deployments=coll["deployments"], statefulsets=coll["statefulsets"],
                            replicasets=coll["replicasets"], jobs=coll["jobs"], pods=coll["pods"],
                            hpas=coll["hpas"], tracked_uids=set(uid_key), label_key=self.profile.label_key)
        for uid, health in idx.health().items():
            key = uid_key.get(uid)
            if key:
                nodes[key].wl = health

    def _operators(self, nodes: dict[str, Node], intro) -> None:
        deps = []
        for ns in self.profile.operator_namespaces():
            deps += [(ns, d) for d in self.hub.items(f"deployments@{ns}")]
        by_comp: dict[str, list[dict]] = {}
        by_name: dict[tuple[str, str], dict] = {}
        for ns, d in deps:
            by_name[(ns, d["metadata"]["name"])] = d
            cid = norm_id((d["metadata"].get("labels") or {}).get("component-id"))
            if cid:
                by_comp.setdefault(cid, []).append(d)
        with self.hub.lock:
            ops = {k: OperatorState(**vars(v)) for k, v in self.hub.ops.items()}
        for key, n in nodes.items():
            op = ops.get(key)
            cands = []
            if intro is not None and n.spec is not None:
                for ns, dep in intro.kind_ops.get((n.ref.group, n.ref.kind), []) or []:
                    if (ns, dep) in by_name:
                        cands.append(by_name[(ns, dep)])
            if not cands and n.component:
                cands = by_comp.get(norm_id(n.component), [])
            if cands:
                ready = any(int((d.get("status") or {}).get("readyReplicas") or 0) > 0 for d in cands)
                op = op or OperatorState(introspection="off" if intro is None or not intro.enabled else "pending")
                op.ready = ready
                op.deployment = op.deployment or cands[0]["metadata"]["name"]
            n.op = op

    def _edges(self, nodes: dict[str, Node]) -> list[Edge]:
        live = {k: n for k, n in nodes.items() if not n.placeholder}
        uid_key = {n.cr.uid: k for k, n in live.items() if n.cr.uid}
        edges = []
        for k, n in live.items():
            child = n.ref.name.lower()
            for u in n.cr.owner_uids:
                parent = uid_key.get(u)
                if not parent or parent == k:
                    continue
                p = live[parent]
                # several owners: the controller owner wins, then the one the child is named after
                named = any(t and t in child for t in (p.ref.kind.lower(), (p.component or "").lower(),
                                                        p.ref.name.lower().removesuffix("-cr")))
                rank = 0 if u == n.cr.controller_uid else (1 if named else 2)
                edges.append(Edge(parent, k, EdgeType.OWNS, rank))
        # WAITS: resolve the target token of the operator's current wait task
        by_token: dict[str, list[str]] = {}
        for k, n in live.items():
            info = self.crds.get((n.ref.group, n.ref.kind))
            toks = {n.ref.kind.lower()}
            if info:
                toks |= {info.plural.lower(), info.singular.lower(), *[s.lower() for s in info.short_names]}
            if n.component:
                toks |= {n.component.lower(), n.component.lower().replace("_", "-")}
            for t in toks:
                by_token.setdefault(t, []).append(k)
        for k, n in live.items():
            if not n.op or not n.op.task or n.op.job_running is False:
                continue
            tok = graph.wait_target(n.op.task)
            if not tok:
                continue
            cands = [c for c in by_token.get(tok.lower(), []) if c != k]
            if not cands:
                n.waits_on = tok
                continue
            cands.sort(key=lambda c: (not live[c].is_component, live[c].ref.namespace != n.ref.namespace, c))
            edges.append(Edge(k, cands[0], EdgeType.WAITS))
        # DEPENDS: static, transitively reduced
        comp_key: dict[str, str] = {}
        for k, n in live.items():
            if n.component and n.component not in comp_key and n.is_component:
                comp_key[n.component] = k
        for comp, ds in graph.reduce_depends(self.profile.depends).items():
            for d in ds:
                if comp in comp_key and d in comp_key:
                    edges.append(Edge(comp_key[comp], comp_key[d], EdgeType.DEPENDS))
        return edges

    def _track(self, n: Node, now: datetime) -> _Track:
        t = self.tracks.setdefault(n.key, _Track())
        wl_sig = tuple(sorted((w.name, w.ready, w.desired) for w in n.wl.workloads))
        sig = (n.cr.progress, n.cr.message, wl_sig, n.cr.phase)
        if t.sig is not None and sig != t.sig:
            t.changed_at = now
            self.last_activity = now
        t.sig = sig
        scale_sig = tuple(sorted(n.cr.spec_scale.items()))
        if t.scale_sig is not None and scale_sig != t.scale_sig:
            t.scale_changed_at = now
            self._log(now, n, None, None, "scale change: " + ", ".join(f"{k}={v}" for k, v in scale_sig)[:120])
        t.scale_sig = scale_sig
        if n.cr.progress is not None and n.cr.progress != t.progress:
            if t.progress is not None:
                self._log(now, n, None, None, f"{t.progress}→{n.cr.progress}%")
            t.progress = n.cr.progress
            t.history.append(n.cr.progress)
        n.history = list(t.history)
        cands = [t.changed_at, n.cr.last_transition]
        if n.op is not None:
            cands += [n.op.task_started_at, n.op.job_started_at]
        if n.op is None or n.op.introspection != "ok":
            cands.append(self.session_start)
        cands = [c for c in cands if c]
        n.last_change = max(cands) if cands else None
        return t

    def _log(self, ts: datetime, n: Node, old: State | None, new: State | None, text: str):
        if self.first:
            return
        self.event_log.append(Event(ts, n.key, n.label, old, new, text))
        self.event_count += 1

    # ------------------------------------------------------------------
    @staticmethod
    def _labels(nodes: dict[str, Node]) -> None:
        base = {k: (n.component or n.ref.name) if n.placeholder else
                (n.ref.kind if n.ref.name in ("", "-") else f"{n.ref.kind}/{n.ref.name}") for k, n in nodes.items()}
        seen: dict[str, int] = {}
        for b in base.values():
            seen[b] = seen.get(b, 0) + 1
        for k, n in nodes.items():
            n.label = base[k] + (f" ({n.ref.namespace})" if seen[base[k]] > 1 and n.ref.namespace else "")

    def compute(self, intro=None) -> View:
        now = now_utc()
        nodes = self._nodes()
        self._labels(nodes)
        self._workloads(nodes)
        self._operators(nodes, intro)
        edges = self._edges(nodes)
        prio = {EdgeType.WAITS: 0, EdgeType.OWNS: 1, EdgeType.DEPENDS: 2}
        if self.tree_mode == "owns":
            use = (EdgeType.OWNS,)
        elif self.tree_mode == "deps":
            use, prio = (EdgeType.DEPENDS, EdgeType.OWNS), {EdgeType.DEPENDS: 0, EdgeType.OWNS: 1, EdgeType.WAITS: 2}
        else:
            use = (EdgeType.WAITS, EdgeType.OWNS) + ((EdgeType.DEPENDS,) if self.show_deps else ())
        tree_keys = [k for k, n in nodes.items() if not n.placeholder]
        sort_key = lambda k: (nodes[k].ref.kind.lower(), nodes[k].ref.namespace or "", nodes[k].ref.name)
        forest = graph.build_forest(tree_keys, edges, is_component={k: n.is_component for k, n in nodes.items()},
                                    max_depth=self.max_depth, sort_key=sort_key, use_types=use, priority=prio)
        for k, anc in forest.folded.items():
            nodes[k].hidden, nodes[k].fold_into = True, anc
        waits = {e.src: e.dst for e in edges if e.type == EdgeType.WAITS}

        tracks = {k: self._track(n, now) for k, n in nodes.items()}

        def ctx_for(n: Node, blocked=None, hidden_issues=None) -> Context:
            t = tracks[n.key]
            return Context(now=now, th=self.th, last_change=n.last_change, scale_changed_at=t.scale_changed_at,
                           expected_version=n.expected_version, blocked_by=blocked or [],
                           hidden_issues=hidden_issues or [],
                           note=n.note or (n.spec.note if n.spec and n.spec.note else None) or
                                (next((p.note for p in self.profile.placeholders if p.component == n.component), None)
                                 if n.placeholder else None))

        # hidden first (their own state), then fold their workloads/issues into the shown ancestor
        issues: dict[str, list[str]] = {}
        for k, n in nodes.items():
            if n.hidden:
                n.verdict = classify(n.cr, n.wl, n.op, ctx_for(n))
                anc = nodes.get(n.fold_into or "")
                if anc is not None:
                    anc.wl.merge(n.wl)
                    if n.verdict.state not in (State.HEALTHY, State.INACTIVE):
                        issues.setdefault(anc.key, []).append(f"sub! {n.label} {n.verdict.state.word}: {n.verdict.reason}")
        shown = [k for k, n in nodes.items() if not n.hidden]
        for k in shown:
            n = nodes[k]
            n.verdict = classify(n.cr, n.wl, n.op, ctx_for(n, hidden_issues=issues.get(k)))
        for _ in range(4):
            changed = False
            for src, dst in waits.items():
                if src not in nodes or nodes[src].hidden or dst not in nodes:
                    continue
                tgt = nodes[dst]
                blocked = [(tgt.label, tgt.verdict.state)] if tgt.verdict else []
                v = classify(nodes[src].cr, nodes[src].wl, nodes[src].op,
                             ctx_for(nodes[src], blocked, issues.get(src)))
                if v.state != nodes[src].verdict.state or v.reason != nodes[src].verdict.reason:
                    nodes[src].verdict, changed = v, True
            if not changed:
                break
        for k, n in nodes.items():
            if n.waits_on and n.verdict and not n.verdict.blocked_by:
                n.verdict.notices.append(f"waiting on {n.waits_on} (not tracked)")

        # recovery debounce + transitions
        for k, n in nodes.items():
            t = tracks[k]
            v = n.verdict
            if (t.state in (State.FAILING, State.STUCK) and v.state == State.HEALTHY):
                t.recovering_since = t.recovering_since or now
                if now - t.recovering_since < self.th.debounce:
                    n.verdict = Verdict(t.state, "recovering: " + v.reason, v.since, v.badge, v.notices, v.blocked_by)
                    continue
            t.recovering_since = None
            if t.state is not None and v.state != t.state and not n.hidden:
                self._log(now, n, t.state, v.state, v.reason)
                self.last_activity = now
            new_notices = frozenset(v.notices)
            for note in sorted(new_notices - t.notices):
                if t.state is not None and not n.hidden:
                    self._log(now, n, None, None, note)
            t.notices = new_notices
            t.state = v.state

        # worst descendant per shown row
        rows = forest.rows
        stack: list[tuple[int, str]] = []
        worst: dict[str, State] = {}

        def bump(key: str, st: State):
            if key not in worst or st.severity < worst[key].severity:
                worst[key] = st

        for r in rows:
            while stack and stack[-1][0] >= r.depth:
                stack.pop()
            target = r.ref_of or r.key
            st = nodes[target].verdict.state if target in nodes else None
            if st is not None:
                for _d, anc in stack:
                    bump(anc, st)
            if r.ref_of is None:
                stack.append((r.depth, r.key))
        for k, n in nodes.items():
            if n.hidden and n.fold_into in nodes:
                bump(n.fold_into, n.verdict.state)
        for k, st in worst.items():
            nodes[k].worst_desc = st

        list_keys = [k for k, n in nodes.items() if not n.hidden]
        counts = {s: 0 for s in State}
        for k in list_keys:
            counts[nodes[k].verdict.state] += 1
        roots = [k for k in list_keys if nodes[k].verdict.state == State.FAILING or
                 (nodes[k].verdict.state == State.STUCK and not nodes[k].verdict.blocked_by)]
        roots.sort(key=lambda k: (nodes[k].verdict.state.severity, nodes[k].label))
        settled = all(nodes[k].verdict.state in (State.HEALTHY, State.INACTIVE) for k in list_keys)
        errors = sorted({f"{name}: {msg}" for name, msg in self.hub.errors.items()})
        if self.hub.op_note:
            errors.append(self.hub.op_note)
        names = [s.collection for s in self.specs if not s.missing_crd]
        loading = not self.hub.all_synced(names)
        self.first = False
        return View(nodes, rows, list_keys, counts, roots, list(self.event_log), errors, list(self.profile.notes),
                    now, loading, self.last_activity if settled else None)

    def intro_targets(self, view: View) -> tuple[list[IntroTarget], set[str]]:
        out, green = [], set()
        for k, n in view.nodes.items():
            if n.placeholder or not n.cr.exists or n.hidden or n.verdict is None:
                continue
            if n.verdict.state == State.INACTIVE:
                continue
            out.append(IntroTarget(k, n.ref.group, n.ref.version, n.ref.kind, n.ref.namespace, n.ref.name,
                                   n.component))
            if n.verdict.state == State.HEALTHY:
                green.add(k)
        return out, green
