"""Cluster access (read-only): raw REST GETs, list+watch informers, exec, logs.

Uses the kubeconfig that `oc login` writes. Raw paths instead of the dynamic client
so no API-discovery cache file is written. Informers run on daemon threads and write
trimmed objects into an in-memory Hub; quitting never waits on an open watch.
"""

from __future__ import annotations

import json
import random
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

from kubernetes import client, config
from kubernetes.watch.watch import iter_resp_lines

from . import runner_events
from .model import OperatorState

WATCH_TIMEOUT = 25          # seconds per watch request (server side)
RELIST_EVERY = 300          # full relist as a safety net


class KubeError(Exception):
    def __init__(self, status: int, msg: str):
        super().__init__(f"HTTP {status}: {msg}")
        self.status = status


class Kube:
    def __init__(self, context: str | None = None, kubeconfig: str | None = None):
        config.load_kube_config(config_file=kubeconfig, context=context)
        self.api = client.ApiClient()
        self.host = self.api.configuration.host
        try:
            _, active = config.list_kube_config_contexts(config_file=kubeconfig)
            self.context_user = ((active or {}).get("context") or {}).get("user", "")
        except Exception:
            self.context_user = ""

    def _request(self, path: str, query: dict | None = None, timeout=None):
        q = [(k, str(v).lower() if isinstance(v, bool) else str(v)) for k, v in (query or {}).items()
             if v is not None]
        method, url, headers, _body, _post = self.api.param_serialize(
            "GET", path, query_params=q, header_params={"Accept": "application/json"},
            auth_settings=["BearerToken"])
        resp = self.api.call_api(method, url, header_params=headers, _request_timeout=timeout)
        if resp.status >= 400:
            resp.read()
            try:
                msg = json.loads(resp.data).get("message", "")
            except Exception:
                msg = (resp.data or b"")[:200].decode(errors="replace")
            raise KubeError(resp.status, msg)
        return resp

    def get(self, path: str, timeout=(5, 60), **query) -> dict:
        resp = self._request(path, query, timeout)
        resp.read()
        return json.loads(resp.data)

    def get_text(self, path: str, timeout=(5, 60), **query) -> str:
        resp = self._request(path, query, timeout)
        resp.read()
        return (resp.data or b"").decode(errors="replace")

    def watch(self, path: str, resource_version: str, timeout: int = WATCH_TIMEOUT):
        resp = self._request(path, {"watch": True, "resourceVersion": resource_version,
                                    "timeoutSeconds": timeout, "allowWatchBookmarks": True},
                             timeout=(5, timeout + 15))
        try:
            for line in iter_resp_lines(resp.response):
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
        finally:
            resp.response.release_conn()

    def whoami(self) -> str:
        try:
            return self.get("/apis/user.openshift.io/v1/users/~", timeout=(3, 10))["metadata"]["name"]
        except Exception:
            return self.context_user.split("/")[0] if self.context_user else "?"

    def exec(self, namespace: str, pod: str, command: list[str], timeout: int = 15,
             container: str | None = None) -> str:
        from kubernetes.stream import stream
        # stream() temporarily swaps the client's call_api for a WebSocket one; a dedicated client per
        # exec keeps the informers' and log GETs on other threads off that swap
        core = client.CoreV1Api(client.ApiClient(self.api.configuration))
        kwargs = {"command": command, "stderr": True, "stdin": False, "stdout": True, "tty": False,
                  "_preload_content": False}
        if container:
            kwargs["container"] = container
        ws = stream(core.connect_get_namespaced_pod_exec, pod, namespace, **kwargs)
        out, deadline = [], time.monotonic() + timeout
        try:
            while ws.is_open() and time.monotonic() < deadline:
                ws.update(timeout=1)
                if ws.peek_stdout():
                    out.append(ws.read_stdout())
            if ws.peek_stdout():
                out.append(ws.read_stdout())
        finally:
            ws.close()
        return "".join(out)

    def logs(self, namespace: str, pod: str, tail: int = 300, container: str | None = None) -> str:
        return self.get_text(f"/api/v1/namespaces/{namespace}/pods/{pod}/log", tailLines=tail,
                             container=container)


# ---------------------------------------------------------------------------
# trimming: keep only what the dashboard reads (memory + speed)
# ---------------------------------------------------------------------------
def _meta(o: dict, labels: tuple[str, ...] = ()) -> dict:
    m = o.get("metadata") or {}
    out = {k: m[k] for k in ("name", "namespace", "uid", "ownerReferences", "creationTimestamp",
                             "generation", "resourceVersion") if k in m}
    if labels:
        lab = m.get("labels") or {}
        out["labels"] = {k: lab[k] for k in labels if k in lab}
    return out


def trim_cr(o: dict) -> dict:
    spec = o.get("spec") or {}
    small = {k: v for k, v in spec.items()
             if isinstance(v, (str, int, float, bool)) or (isinstance(v, (dict, list)) and len(str(v)) < 200)}
    return {"apiVersion": o.get("apiVersion"), "kind": o.get("kind"), "metadata": _meta(o),
            "spec": small, "status": o.get("status") or {}}


def make_trim_workload(label_keys: tuple[str, ...]):
    def trim(o: dict) -> dict:
        out = {"metadata": _meta(o, label_keys)}
        spec = o.get("spec") or {}
        out["spec"] = {k: spec[k] for k in ("replicas", "scaleTargetRef") if k in spec}
        st = o.get("status") or {}
        keep = {}
        for k in ("phase", "reason", "startTime", "conditions", "readyReplicas", "updatedReplicas",
                  "currentReplicas", "desiredReplicas", "replicas", "availableReplicas"):
            if k in st:
                keep[k] = st[k]
        for k in ("containerStatuses", "initContainerStatuses"):
            if k in st:
                keep[k] = [{"name": c.get("name"), "state": c.get("state"), "lastState": c.get("lastState"),
                            "ready": c.get("ready"), "restartCount": c.get("restartCount")} for c in st[k]]
        out["status"] = keep
        return out
    return trim


# ---------------------------------------------------------------------------
# informers
# ---------------------------------------------------------------------------
@dataclass
class Resource:
    name: str                 # e.g. "cr:ds.cpd.ibm.com/v1/datastages" or "pods@cpdata-operands"
    path: str                 # list path
    trim: object
    fallback_paths: list[str] = field(default_factory=list)   # per-namespace paths if the cluster list is denied
    poll: float | None = None  # poll instead of watch (seconds)


class Hub:
    """Thread-safe in-memory store of trimmed objects per resource, plus operator state."""

    def __init__(self, kube: Kube):
        self.kube = kube
        self.lock = threading.RLock()
        self.data: dict[str, dict[str, dict]] = {}
        self.synced: set[str] = set()
        self.errors: dict[str, str] = {}
        self.version = 0
        self.stop = threading.Event()
        self.ops: dict[str, OperatorState] = {}
        self.op_note: str | None = None
        self._threads: list[threading.Thread] = []
        self._relist = threading.Event()

    # -- writers --------------------------------------------------------
    def _bump(self):
        self.version += 1

    def _sync(self, name: str, items: dict[str, dict]):
        with self.lock:
            self.data[name] = items
            self.synced.add(name)
            self.errors.pop(name, None)
            self._bump()

    def _event(self, name: str, typ: str, obj: dict):
        uid = (obj.get("metadata") or {}).get("uid")
        if not uid:
            return
        with self.lock:
            coll = self.data.setdefault(name, {})
            if typ == "DELETED":
                coll.pop(uid, None)
            else:
                coll[uid] = obj
            self._bump()

    def _error(self, name: str, msg: str):
        with self.lock:
            if self.errors.get(name) != msg:
                self.errors[name] = msg
                self._bump()

    # -- readers --------------------------------------------------------
    def items(self, name: str) -> list[dict]:
        with self.lock:
            return list((self.data.get(name) or {}).values())

    def all_synced(self, names) -> bool:
        with self.lock:
            return all(n in self.synced or n in self.errors for n in names)

    # -- running --------------------------------------------------------
    def start(self, resources: list[Resource]):
        for r in resources:
            t = threading.Thread(target=self._run_resource, args=(r,), daemon=True, name=f"inf-{r.name}")
            t.start()
            self._threads.append(t)

    def request_relist(self):
        self._relist.set()

    def _list(self, r: Resource, paths: list[str]) -> tuple[dict[str, dict], list[str]]:
        items, rvs = {}, []
        for p in paths:
            lst = self.kube.get(p, timeout=(5, 120))
            rvs.append((lst.get("metadata") or {}).get("resourceVersion", ""))
            for o in lst.get("items") or []:
                t = r.trim(o)
                uid = (t.get("metadata") or {}).get("uid")
                if uid:
                    items[uid] = t
        return items, rvs

    def _run_resource(self, r: Resource):
        backoff = 1.0
        paths = [r.path]
        while not self.stop.is_set():
            try:
                try:
                    items, rvs = self._list(r, paths)
                except KubeError as e:
                    if e.status == 403 and r.fallback_paths and paths == [r.path]:
                        paths = r.fallback_paths
                        continue
                    if e.status == 404:
                        self._sync(r.name, {})
                        self.stop.wait(60)
                        continue
                    raise
                self._sync(r.name, items)
                backoff = 1.0
                if r.poll:
                    self._sleep(r.poll)
                    continue
                if len(paths) > 1:  # several namespaces: poll them (a watch per namespace is not worth it)
                    self._sleep(5)
                    continue
                rv, t0 = rvs[0], time.monotonic()
                while not self.stop.is_set() and time.monotonic() - t0 < RELIST_EVERY and not self._relist.is_set():
                    for ev in self.kube.watch(paths[0], rv):
                        if self.stop.is_set():
                            return
                        typ, obj = ev.get("type"), ev.get("object") or {}
                        if typ == "BOOKMARK":
                            rv = (obj.get("metadata") or {}).get("resourceVersion", rv)
                            continue
                        if typ == "ERROR":
                            raise KubeError(int(obj.get("code") or 500), obj.get("message", "watch error"))
                        rv = (obj.get("metadata") or {}).get("resourceVersion", rv)
                        self._event(r.name, typ, r.trim(obj))
                self._relist.clear()
            except KubeError as e:
                if e.status == 410:   # resourceVersion too old: relist now
                    continue
                self._error(r.name, str(e))
                self._sleep(min(60.0, backoff) + random.random())
                backoff *= 2
            except Exception as e:  # network blips, timeouts
                self._error(r.name, f"{type(e).__name__}: {e}"[:200])
                self._sleep(min(60.0, backoff) + random.random())
                backoff *= 2

    def _sleep(self, seconds: float):
        end = time.monotonic() + seconds
        while not self.stop.is_set() and not self._relist.is_set() and time.monotonic() < end:
            self.stop.wait(0.5)


# ---------------------------------------------------------------------------
# operator introspection (S3)
# ---------------------------------------------------------------------------
def norm_id(value: str | None) -> str:
    """Component ids use '_' (watsonx_dataintelligence), operator labels '-' (watsonx-dataintelligence)."""
    return (value or "").strip().lower().replace("_", "-")


@dataclass
class IntroTarget:
    key: str
    group: str
    version: str
    kind: str
    namespace: str | None
    name: str
    component: str | None = None


class Introspector:
    """Maps CR kinds to operator pods (watches.yaml) and reads runner events by exec.

    Operator deployments/pods/leases are read from the Hub collections named
    `deployments@<ns>`, `pods@<ns>` for each operator namespace.
    """

    def __init__(self, kube: Kube, hub: Hub, operator_ns: list[str], *, enabled: bool = True,
                 interval: float = 10.0, max_workers: int = 4):
        self.kube, self.hub = kube, hub
        self.operator_ns = operator_ns
        self.enabled = enabled
        self.interval = interval
        self.pool = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix="exec")
        self.watches: dict[str, list[tuple[str, str, str]] | None] = {}  # pod -> watched GVKs (None = not ansible)
        self.kind_ops: dict[tuple[str, str], list[tuple[str, str]]] = {}   # (group, kind) -> [(ns, deployment)]
        self.kind_version: dict[tuple[str, str], str] = {}                  # version the operator watches
        self.targets: list[IntroTarget] = []
        self.slow: dict[str, float] = {}   # key -> next check time for green CRs
        self.lock = threading.Lock()
        self.denied = False
        self.priority: str | None = None   # the CR selected in the UI goes first

    def set_targets(self, targets: list[IntroTarget], green: set[str]):
        with self.lock:
            self.targets = targets
            self._green = set(green)

    def start(self):
        if self.enabled:
            threading.Thread(target=self._loop, daemon=True, name="introspect").start()

    # -- helpers --------------------------------------------------------
    def _deployments(self):
        out = []
        for ns in self.operator_ns:
            for d in self.hub.items(f"deployments@{ns}"):
                out.append((ns, d))
        return out

    def _running_pods(self, ns: str, deploy: dict) -> list[str]:
        uid = deploy["metadata"].get("uid")
        rs_uids = {r["metadata"]["uid"] for r in self.hub.items(f"replicasets@{ns}")
                   if any(o.get("uid") == uid for o in r["metadata"].get("ownerReferences") or [])}
        pods = []
        for p in self.hub.items(f"pods@{ns}"):
            owners = {o.get("uid") for o in p["metadata"].get("ownerReferences") or []}
            if owners & rs_uids and (p.get("status") or {}).get("phase") == "Running":
                pods.append(p["metadata"]["name"])
        return sorted(pods)

    def _leader_pods(self, ns: str) -> set[str]:
        try:
            leases = self.kube.get(f"/apis/coordination.k8s.io/v1/namespaces/{ns}/leases", timeout=(5, 20))
        except Exception:
            return set()
        out = set()
        for l in leases.get("items") or []:
            holder = (l.get("spec") or {}).get("holderIdentity") or ""
            if holder:
                out.add(holder.split("_")[0])
        return out

    def _watches_of(self, ns: str, pod: str):
        if pod in self.watches:
            return self.watches[pod]
        try:
            out = self.kube.exec(ns, pod, ["python3", "-c", runner_events.WATCHES_SCRIPT], timeout=10)
            res = runner_events.parse_marker(out)
            gvks = runner_events.parse_watches(res["text"]) if res and res.get("exists") else None
        except Exception as e:
            if "403" in str(e) or "Forbidden" in str(e):
                self.denied = True
            gvks = None
        self.watches[pod] = gvks
        return gvks

    def _score(self, d: dict, t: IntroTarget) -> int:
        name = norm_id(d["metadata"].get("name", "")).replace("-", "")
        labels = d["metadata"].get("labels") or {}
        comp = norm_id(t.component)
        score = 0
        if comp and norm_id(labels.get("component-id")) == comp:
            score += 10
        if t.kind.lower() in name:
            score += 6
        if comp and comp.replace("-", "") in name:
            score += 4
        if "operator" in name or "controller" in name:
            score += 1
        return score

    def _map_kind(self, t: IntroTarget, budget: list[int]) -> list[tuple[str, str]]:
        """Operator deployments whose watches.yaml lists this kind. Probes the best-scoring
        candidates' pods in parallel; unprobed candidates (budget used up) are retried next tick."""
        gk = (t.group, t.kind)
        if gk in self.kind_ops:
            return self.kind_ops[gk]
        probes = []
        for ns, d in sorted(self._deployments(), key=lambda nd: -self._score(nd[1], t))[:12]:
            pods = self._running_pods(ns, d)
            if pods:
                probes.append((ns, d, pods[0]))
        todo = [(ns, p) for ns, _d, p in probes if p not in self.watches][:max(0, budget[0])]
        budget[0] -= len(todo)
        if todo:
            list(self.pool.map(lambda np: self._watches_of(*np), todo))
        found, complete = [], True
        for ns, d, p in probes:
            if p not in self.watches:
                complete = False
                continue
            hit = [v for g, v, k in self.watches[p] or [] if g == t.group and k == t.kind]
            if hit:
                found.append((ns, d["metadata"]["name"]))
                self.kind_version[gk] = hit[0] or t.version
        if found or complete:
            self.kind_ops[gk] = found
        return found

    def operator_for(self, t: IntroTarget) -> tuple[str, str] | None:
        ops = self.kind_ops.get((t.group, t.kind))
        return ops[0] if ops else None

    # -- loop -----------------------------------------------------------
    def _loop(self):
        while not self.hub.stop.is_set():
            t0 = time.monotonic()
            try:
                self._tick()
            except Exception as e:
                self.hub.op_note = f"introspection error: {type(e).__name__}: {e}"[:160]
            self.hub.stop.wait(max(1.0, self.interval - (time.monotonic() - t0)))

    def _tick(self):
        with self.lock:
            targets, green = list(self.targets), set(getattr(self, "_green", set()))
        now = time.monotonic()
        due = []
        for t in targets:
            if t.key in green:
                if self.slow.get(t.key, 0) > now:
                    continue
                self.slow[t.key] = now + 300
            due.append(t)
        if not due:
            return
        due.sort(key=lambda t: (t.key != self.priority, t.key in green))
        budget = [12]
        by_pod: dict[tuple[str, str], list[IntroTarget]] = {}
        leaders: dict[str, set[str]] = {}
        unsupported = []
        for t in due:
            ops = self._map_kind(t, budget)
            if not ops:
                if (t.group, t.kind) not in self.kind_ops:   # exec budget used up: try next tick
                    self._set(t.key, introspection="pending")
                else:
                    unsupported.append(t)
                continue
            chosen = None
            for ns, dep in ops:
                d = next((x for n, x in self._deployments() if n == ns and x["metadata"]["name"] == dep), None)
                if d is None:
                    continue
                pods = self._running_pods(ns, d)
                if not pods:
                    continue
                if len(ops) > 1:
                    if ns not in leaders:
                        leaders[ns] = self._leader_pods(ns)
                    lead = [p for p in pods if p in leaders[ns]]
                    if lead:
                        chosen = (ns, lead[0], dep)
                        break
                chosen = chosen or (ns, pods[0], dep)
            if chosen:
                by_pod.setdefault((chosen[0], chosen[1]), []).append(t)
                self._set(t.key, deployment=chosen[2], namespace=chosen[0], pod=chosen[1])
            else:
                unsupported.append(t)
        for t in unsupported:
            self._set(t.key, introspection="denied" if self.denied else "unsupported")
        futures = {self.pool.submit(self._read, ns, pod, ts): (ns, pod, ts) for (ns, pod), ts in by_pod.items()}
        for f in futures:
            try:
                f.result(timeout=30)
            except Exception:
                pass
        self.hub._bump()

    def _set(self, key: str, **fields):
        with self.hub.lock:
            op = self.hub.ops.setdefault(key, OperatorState())
            for k, v in fields.items():
                setattr(op, k, v)

    def _read(self, ns: str, pod: str, targets: list[IntroTarget]):
        paths = {runner_events.runner_path(t.group, self.kind_version.get((t.group, t.kind), t.version), t.kind,
                                           t.namespace, t.name): t for t in targets}
        try:
            out = self.kube.exec(ns, pod, ["python3", "-c", runner_events.READER_SCRIPT, *paths], timeout=20)
            res = runner_events.parse_marker(out)
        except Exception as e:
            res = None
            if "403" in str(e) or "Forbidden" in str(e):
                self.denied = True
        with self.hub.lock:
            for path, t in paths.items():
                op = self.hub.ops.setdefault(t.key, OperatorState())
                if res is None:
                    op.introspection = "denied" if self.denied else "error"
                    continue
                runner_events.apply_runner_result(op, res.get(path))
                op.leader = True
