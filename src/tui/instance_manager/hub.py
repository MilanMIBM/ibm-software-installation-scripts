"""DataHub: one daemon loader thread feeds an in-memory snapshot; the UI polls `version`.

Every provider call runs on that single thread, in order (cpd-cli calls must not overlap,
and the cluster caches are simplest single-writer). The UI asks for work with request_*()
and never blocks. Instance lists are re-polled every POLL seconds; state transitions are
announced in the event log. Nothing is written anywhere.
"""

from __future__ import annotations

import queue
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

from ..common.state import State
from .model import FormModel, Instance, InstanceType
from .providers.base import Provider
from .subservices import TabState, tab_state

POLL = 30.0


def instance_key(i: Instance) -> str:
    return f"{i.type_key}|{i.namespace or '-'}|{i.name}|{i.uid}"


@dataclass
class Event:
    at: float
    level: str          # info | warn | error | state
    text: str


class DataHub:
    def __init__(self, provider: Provider, poll: float = POLL, before_load: Callable[[], None] | None = None):
        self.provider = provider
        self.before_load = before_load          # e.g. the cpd-cli profile preflight: off the UI thread
        self.poll = poll
        self.lock = threading.RLock()
        self.version = 0
        self.loading = True
        self.types: list[InstanceType] = []
        self.instances: dict[str, list[Instance]] = {}
        self.models: dict[str, FormModel | Exception] = {}
        self.tabs: dict[str, TabState] = {}
        self.sc: dict = {}                      # StorageClass kinds, filled with the first model
        self.events: list[Event] = []
        self.loaded_at: float | None = None
        self._states: dict[str, State] = {}
        self._jobs: queue.Queue = queue.Queue()
        self._pending: set[tuple] = set()
        self._stop = threading.Event()
        self._loaded_mono = 0.0
        self.running: str | None = None
        self._thread: threading.Thread | None = None

    # -- UI side -------------------------------------------------------------
    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True, name="instance-hub")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._jobs.put(None)

    def _enqueue(self, key: tuple, fn: Callable[[], None]) -> None:
        with self.lock:
            if key in self._pending:
                return
            self._pending.add(key)
        self._jobs.put((key, fn))

    def request_model(self, type_key: str) -> None:
        if type_key not in self.models:
            self._enqueue(("model", type_key), lambda: self._load_model(type_key))

    def request_tab(self, inst: Instance) -> None:
        key = instance_key(inst)
        if key not in self.tabs:
            self._enqueue(("tab", key), lambda: self._load_tab(inst))

    def rediscover(self) -> None:
        self._enqueue(("full",), self._full)

    def run_task(self, name: str, fn: Callable[[], None]) -> None:
        """Run fn on the loader thread (serialised with discovery), e.g. a profile repair."""
        self._enqueue(("task", name), fn)

    def update_instances(self, type_key: str, insts: list[Instance]) -> None:
        """A running plan's watch loop pushes fresh instance states (the UI shows the dot moving)."""
        with self.lock:
            self.instances[type_key] = insts
            for i in insts:
                self._states[instance_key(i)] = i.state
        self._bump()

    def execute(self, plan, done: Callable[[bool], None] | None = None) -> None:
        """Run an ActionPlan's steps in order on the loader thread; stop at the first failure."""
        def task() -> None:
            ok = False
            self.event("info", f"{plan.op} {plan.target}: starting ({len(plan.steps)} steps)")
            try:
                for n, step in enumerate(plan.steps, 1):
                    self.event("info", f"[{n}/{len(plan.steps)}] {step.title}")
                    step.run(lambda m: self.event("info", m))
                ok = True
                self.event("info", f"{plan.op} {plan.target}: done")
            except Exception as e:
                self.event("error", f"{plan.op} {plan.target}: failed: {e}")
            finally:
                self._poll_instances()
                if done:
                    done(ok)
        self.running = plan.target
        self._enqueue(("plan", plan.target), lambda: (task(), setattr(self, "running", None)))

    def event(self, level: str, text: str) -> None:
        with self.lock:
            self.events.append(Event(time.time(), level, text))
            self.version += 1

    def type_by_key(self, key: str) -> InstanceType | None:
        return next((t for t in self.types if t.key == key), None)

    # -- loader thread -------------------------------------------------------------
    def _bump(self) -> None:
        with self.lock:
            self.version += 1

    IDLE_GRACE = 0.8          # after a (re)load, give the UI time to ask for what it shows first

    def _idle_pending(self) -> bool:
        return not self.loading and any(t.key not in self.models for t in self.types)

    def _idle_work(self) -> bool:
        """Background prefetch while nothing is queued, one type per call so a click never waits on a
        batch: each type's field model (the first storage analysis also builds the owner graph)."""
        if not self._idle_pending() or time.monotonic() - self._loaded_mono < self.IDLE_GRACE:
            return False
        for t in list(self.types):
            if t.key not in self.models and ("model", t.key) not in self._pending:
                self._load_model(t.key)
                return True
        return False

    def _run(self) -> None:
        if self.before_load:
            try:
                self.before_load()
            except Exception as e:
                self.event("error", f"preflight: {e}")
            self._bump()
        self._full()
        next_poll = time.monotonic() + self.poll
        while not self._stop.is_set():
            wait = 0.2 if self._idle_pending() else max(0.1, next_poll - time.monotonic())
            try:
                job = self._jobs.get(timeout=wait)
            except queue.Empty:
                if self._idle_work():
                    continue
                if time.monotonic() >= next_poll:
                    self._poll_instances()
                    next_poll = time.monotonic() + self.poll
                continue
            if job is None:
                return
            key, fn = job
            try:
                fn()
            except Exception as e:   # one failed job is a log line, never a dead loader
                self.event("error", f"{key[0]} {key[1] if len(key) > 1 else ''}: {e}")
            finally:
                with self.lock:
                    self._pending.discard(key)

    def _full(self) -> None:
        with self.lock:
            self.loading = True
        self._bump()
        t0 = time.monotonic()
        self.provider.refresh()
        types = self.provider.discover_types()
        with self.lock:
            self.types, self.models, self.tabs = types, {}, {}
        for n in getattr(self.provider, "notices", []):
            self.event("warn", n)
        self._poll_instances(announce=False)
        with self.lock:
            self.loading = False
            self._loaded_mono = time.monotonic()
        n = sum(len(v) for v in self.instances.values())
        self.event("info", f"discovered {len(types)} instance type(s), {n} instance(s) "
                           f"in {time.monotonic() - t0:.1f}s")

    def _poll_instances(self, announce: bool = True) -> None:
        self.provider.refresh_instances()
        fresh: dict[str, list[Instance]] = {}
        for t in list(self.types):
            try:
                fresh[t.key] = self.provider.list_instances(t)
            except Exception as e:
                self.event("error", f"listing {t.display}: {e}")
                fresh[t.key] = self.instances.get(t.key, [])
        states = {instance_key(i): i.state for v in fresh.values() for i in v}
        if announce:
            for k, st in states.items():
                old = self._states.get(k)
                name = k.split("|")[2]
                if old is None:
                    self.event("state", f"new instance {name}: {st.word}")
                elif old != st:
                    self.event("state", f"{name}: {old.word} -> {st.word}")
            for k in set(self._states) - set(states):
                self.event("state", f"instance {k.split('|')[2]} is gone")
        with self.lock:
            self.instances = fresh
            self._states = states
            self.loaded_at = time.time()
            self.tabs = {k: v for k, v in self.tabs.items() if k in states}
        self._bump()

    def _load_model(self, type_key: str) -> None:
        t = self.type_by_key(type_key)
        if t is None or type_key in self.models:
            return
        insts = self.instances.get(type_key)
        two_phase = hasattr(self.provider, "assess_storage")
        try:
            fm: FormModel | Exception = (self.provider.form_model(t, insts, storage=False) if two_phase
                                         else self.provider.form_model(t, insts))
        except Exception as e:
            fm = e
            self.event("error", f"discovering {t.display}: {e}")
        with self.lock:
            self.models[type_key] = fm                     # fields first: the detail pane can show them
        self._bump()
        if isinstance(fm, Exception):
            return
        try:
            if two_phase:
                self.provider.assess_storage(fm, insts or [])
            sc = self.provider.storage_classes()
        except Exception as e:
            self.event("warn", f"storage analysis of {t.display}: {e}")
            sc = self.sc
        with self.lock:
            self.sc = sc
        self._bump()

    def _load_tab(self, inst: Instance) -> None:
        t = self.type_by_key(inst.type_key)
        cluster = getattr(self.provider, "cluster", None)
        ns = inst.namespace or getattr(self.provider, "namespace", None)
        st = tab_state(cluster, t, inst, ns) if (t and cluster) else TabState("none", "no sub-services")
        with self.lock:
            self.tabs[instance_key(inst)] = st
        self._bump()
