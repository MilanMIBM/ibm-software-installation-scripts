"""DataHub: two loader lanes feed an in-memory snapshot; the UI polls change counters (cache plan §3).

  interactive lane  what the user asked for: a clicked type's model, plan building (after the
                    type's storage needs are re-checked, C-D1), running a plan, profile repair,
                    sub-service loads. It never waits behind background work.
  background lane   start-up (profile preflight and the cache's fingerprint check side by side,
                    then the build when one is needed), the 30 s poll, model re-checks one type
                    per chunk, cache saves, the sub-service warmup.
With a discovery cache the hub starts painted: types, models, StorageClass kinds and the last
instance list come from the cache snapshot at once; those instances are marked cached until the
first live poll replaces them (changes on them wait for it).
Granular counters (catalog_v, instances_v, models_v, sc_v, events_v, cache_v, tabs_v) let the
UI repaint only what moved; `version` is their sum. cpd-cli calls serialise in CpdCli.
Nothing is written except the cache and the plans the user runs.
"""

from __future__ import annotations

import queue
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

from ..common.state import State
from .model import FormModel, Instance, InstanceType, StorageNeed
from .providers.base import Provider
from .subservices import TabState, tab_state
from .timings import span

POLL = 30.0


def instance_key(i: Instance) -> str:
    return f"{i.type_key}|{i.namespace or '-'}|{i.name}|{i.uid}"


@dataclass
class Event:
    at: float
    level: str          # info | warn | error | state
    text: str


def _needs(fm: FormModel) -> dict:
    return {p: (f.storage.need, tuple(f.storage.mismatches)) for p, f in fm.fields.items()
            if isinstance(f.storage, StorageNeed)}


class DataHub:
    IDLE_GRACE = 0.8          # after a (re)load, give the UI time to ask for what it shows first

    def __init__(self, provider: Provider, poll: float = POLL, before_load: Callable[[], None] | None = None,
                 cache=None, include_subservices: bool | None = None):
        self.provider = provider
        self.cache = cache
        self.include_subservices = include_subservices
        self.before_load = before_load          # e.g. the cpd-cli profile preflight: off the UI thread
        self.poll = poll
        self.lock = threading.RLock()
        # change counters (the UI repaints only the area whose counter moved)
        self.catalog_v = self.instances_v = self.sc_v = self.events_v = self.cache_v = self.tabs_v = 0
        self.models_v: dict[str, int] = {}
        self.loading = True
        self.types: list[InstanceType] = []
        self.instances: dict[str, list[Instance]] = {}
        self.models: dict[str, FormModel | Exception] = {}
        self.model_state: dict[str, str] = {}   # cached | building | fresh | stale | error
        self.tabs: dict[str, TabState] = {}
        self.sc: dict = {}
        self.events: list[Event] = []
        self.loaded_at: float | None = None
        self.live = cache is None               # instances come from a live poll (not the cached snapshot)
        self.cached_at: str | None = None
        self.cache_status = ""
        self.build = None                       # cache.progress.Progress of the running / last build
        self.build_big = False                  # first build or a cpd_vars change: the full progress view
        self.running: str | None = None
        self._checked = threading.Event()
        if cache is None:
            self._checked.set()
        self._states: dict[str, State] = {}
        self._ui_q: queue.Queue = queue.Queue()
        self._bg_q: queue.Queue = queue.Queue()
        self._pending: set[tuple] = set()
        self._stop = threading.Event()
        self._loaded_mono = 0.0
        self._model_locks: dict[str, threading.Lock] = {}
        self._fps: dict[str, str] = {}
        self._dirty_cache = False
        self._sub_warmed = False
        self._ext_checked = cache is None
        self._threads: list[threading.Thread] = []
        if cache is not None:
            self._paint_from_cache()

    # -- counters --------------------------------------------------------------------
    @property
    def version(self) -> int:
        with self.lock:
            return (self.catalog_v + self.instances_v + sum(self.models_v.values()) + self.sc_v + self.events_v
                    + self.cache_v + self.tabs_v)

    def _bump(self, *what: str, model: str | None = None) -> None:
        with self.lock:
            for w in what or ("instances",):
                setattr(self, f"{w}_v", getattr(self, f"{w}_v") + 1)
            if model is not None:
                self.models_v[model] = self.models_v.get(model, 0) + 1

    # -- UI side -------------------------------------------------------------------------
    def start(self) -> None:
        for name, target in (("instance-hub-bg", self._bg_run), ("instance-hub-ui", self._ui_run)):
            t = threading.Thread(target=target, daemon=True, name=name)
            t.start()
            self._threads.append(t)

    def stop(self) -> None:
        self._stop.set()
        self._ui_q.put(None)
        self._bg_q.put(None)

    def _enqueue(self, key: tuple, fn: Callable[[], None], lane: str = "ui") -> None:
        with self.lock:
            if key in self._pending:
                return
            self._pending.add(key)
        (self._ui_q if lane == "ui" else self._bg_q).put((key, fn))

    def request_model(self, type_key: str) -> None:
        """A model the UI needs now and doesn't have (a cached one is re-checked in the background)."""
        if type_key not in self.models:
            self._enqueue(("model", type_key), lambda: self._derive(type_key))

    def request_tab(self, inst: Instance) -> None:
        key = instance_key(inst)
        if key not in self.tabs:
            self._enqueue(("tab", key), lambda: self._load_tab(inst))

    def rediscover(self) -> None:
        """The R key: with a cache, rebuild every part (with the progress view); else discover again."""
        self._enqueue(("full",), self._rebuild if self.cache is not None else self._full, lane="bg")

    def run_task(self, name: str, fn: Callable[[], None]) -> None:
        """Run fn on the interactive lane, e.g. a profile repair or a plan build."""
        self._enqueue(("task", name), fn)

    def ensure_fresh(self, type_key: str) -> FormModel | Exception | None:
        """The type's model with storage needs re-checked this run (C-D1): called before a create or
        edit plan is built, on the interactive lane. Waits for the cache check first."""
        self._checked.wait(timeout=120)
        return self._derive(type_key)

    def update_instances(self, type_key: str, insts: list[Instance]) -> None:
        """A running plan's watch loop pushes fresh instance states (the UI shows the dot moving)."""
        with self.lock:
            self.instances[type_key] = insts
            for i in insts:
                self._states[instance_key(i)] = i.state
        self._bump("instances")

    def execute(self, plan, done: Callable[[bool], None] | None = None) -> None:
        """Run an ActionPlan's steps in order on the interactive lane; stop at the first failure."""
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
                self.running = None            # the next change may start as soon as "done" shows
                self._bump("cache")
                self._poll_instances()
                if done:
                    done(ok)
        self.running = plan.target
        self._bump("cache")
        self._enqueue(("plan", plan.target), task)

    def event(self, level: str, text: str) -> None:
        with self.lock:
            self.events.append(Event(time.time(), level, text))
            self.events_v += 1

    def type_by_key(self, key: str) -> InstanceType | None:
        return next((t for t in self.types if t.key == key), None)

    # -- lanes ---------------------------------------------------------------------------
    def _run_job(self, job) -> None:
        key, fn = job
        try:
            fn()
        except Exception as e:   # one failed job is a log line, never a dead lane
            self.event("error", f"{key[0]} {key[1] if len(key) > 1 else ''}: {e}")
        finally:
            with self.lock:
                self._pending.discard(key)

    def _ui_run(self) -> None:
        while not self._stop.is_set():
            job = self._ui_q.get()
            if job is None:
                return
            self._run_job(job)

    def _bg_run(self) -> None:
        try:
            self._startup()
        except Exception as e:
            self.event("error", f"start-up: {e}")
            with self.lock:
                self.loading = False
            self._bump("catalog")
        next_poll = time.monotonic() + self.poll
        while not self._stop.is_set():
            wait = 0.2 if self._idle_pending() else max(0.1, min(1.0, next_poll - time.monotonic()))
            try:
                job = self._bg_q.get(timeout=wait)
            except queue.Empty:
                if self._idle_work():
                    continue
                if time.monotonic() >= next_poll:
                    self._poll_instances()
                    next_poll = time.monotonic() + self.poll
                continue
            if job is None:
                return
            self._run_job(job)

    # -- start-up ------------------------------------------------------------------------
    def _paint_from_cache(self) -> None:
        """The cache snapshot, before anything talks to the cluster (JSON only, milliseconds)."""
        try:
            snap = self.cache.snapshot()
        except Exception as e:      # a damaged cache paints nothing; the build makes a new one
            self.event("warn", f"cache snapshot unreadable ({e}); discovering live")
            return
        if snap is None:
            self.cache_status = "no cache yet"
            return
        self.types = snap.types
        self.models = dict(snap.models)
        self.model_state = {k: "cached" for k in snap.models}
        self.sc = snap.sc
        self.instances = snap.instances
        self._states = {instance_key(i): i.state for v in snap.instances.values() for i in v}
        self.cached_at = snap.instances_at
        self.loading = False
        self._loaded_mono = time.monotonic()
        self.cache_status = f"cached {self._hhmm(snap.instances_at)}"
        self._bump("catalog", "instances", "sc", "cache")

    @staticmethod
    def _hhmm(stamp: str | None) -> str:
        return stamp[11:16] if stamp and len(stamp) >= 16 else "?"

    def _startup(self) -> None:
        stale = None
        checker = None
        if self.cache is not None:
            box: dict = {}

            def check() -> None:
                try:
                    box["st"] = self.cache.check()
                except Exception as e:
                    box["err"] = e
            checker = threading.Thread(target=check, daemon=True, name="instance-hub-check")
            checker.start()
        if self.before_load:
            try:
                self.before_load()
            except Exception as e:
                self.event("error", f"preflight: {e}")
            self._bump("cache")
        if checker is not None:
            checker.join()
            stale = box.get("st")
            if box.get("err"):
                self.event("error", f"cache check: {box['err']}")
            for ln in (stale.lines if stale else []):
                self.event("info", f"cache: {ln}")
            self._checked.set()
            from .cache.manager import model_part
            dropped = set(stale.dropped if stale else [])
            with self.lock:                 # painted from the cache, but the check says they're out of date
                for key in list(self.model_state):
                    if model_part(key) in dropped:
                        self.model_state[key] = "stale"
            self._bump("cache")
            if stale and (stale.need_build or not self.types or self.cache.missing_paint()):
                self._build(big=bool(stale.cold or stale.changes or not self.types))
                return
        self._full(refresh=False)          # nothing is loaded yet: keep the zen list the preflight handed over

    def _build(self, big: bool) -> None:
        """A cache build on the background lane; results are published as each part lands."""
        cache = self.cache
        with self.lock:
            self.build_big = big
            self.cache_status = "building"
            for k in self.model_state:
                if self.model_state[k] in ("cached", "stale"):
                    self.model_state[k] = "building"
        self._bump("cache")

        def sink(pr) -> None:
            with self.lock:
                self.build = pr
                self.cache_status = "building" if not pr.finished else "fresh"
            self._bump("cache")

        def on_types(types, notices) -> None:
            with self.lock:
                self.types = types
                self.loading = False
                self._loaded_mono = time.monotonic()
            for n in notices:
                self.event("warn", n)
            self._bump("catalog")

        def on_instances(insts) -> None:
            self._publish_instances(insts, announce=False)

        def on_sc(sc) -> None:
            with self.lock:
                self.sc = sc
            self._bump("sc")

        def on_model(key, fm, with_storage) -> None:
            with self.lock:
                old = self.models.get(key)
                if with_storage or not isinstance(old, FormModel):
                    self.models[key] = fm
                    self.model_state[key] = "fresh" if with_storage else "building"
            self._bump(model=key)

        t0 = time.monotonic()
        with span("cache build"):
            pr = cache.build(sink=sink, include_subservices=self.include_subservices, on_types=on_types,
                             on_instances=on_instances, on_sc=on_sc, on_model=on_model)
        failed = [p for p in pr.parts if p.state == "failed"]
        for p in failed:
            self.event("error", f"cache: {p.label} failed: {p.error}")
        self._sub_warmed = bool(pr.part("subservices") and pr.part("subservices").state == "done")
        with self.lock:
            self.loading = False
            self.cache_status = "fresh"
            self.build_big = False
            for key, st in self.model_state.items():
                if st == "building":
                    self.model_state[key] = "stale"
        self.event("info", f"cache: built {pr.done_count}/{pr.total} part(s) in {time.monotonic() - t0:.1f}s"
                           + (f", {len(failed)} failed" if failed else ""))
        self._bump("cache", "catalog")

    def _rebuild(self) -> None:
        self.event("info", "re-discovering everything (R): rebuilding the cache")
        self.cache.drop_all()
        self.provider.refresh()
        with self.lock:
            self.tabs, self._fps = {}, {}
            self.model_state = {k: "stale" for k in self.models}
            self.live = False
        self._bump("tabs")
        self._build(big=True)

    def _full(self, refresh: bool = True) -> None:
        """Discover types and instances (no cache, or a cache that needed no build)."""
        with self.lock:
            if not self.types:
                self.loading = True
        self._bump("catalog")
        t0 = time.monotonic()
        with span("discover (full)"):
            if refresh:
                self.provider.refresh()
            types = self.provider.discover_types()
        with self.lock:
            cached = {t.key for t in self.types}
            self.types = types
            if refresh:
                self.models, self.tabs, self.model_state = {}, {}, {}
            else:   # models of types that are gone go with them
                keep = {t.key for t in types}
                self.models = {k: v for k, v in self.models.items() if k in keep}
            if not refresh:
                for t in types:
                    if t.key not in cached:
                        self.model_state.pop(t.key, None)
        for n in getattr(self.provider, "notices", []):
            self.event("warn", n)
        self._bump("catalog")
        self._poll_instances(announce=False, refresh=refresh)
        with self.lock:
            self.loading = False
            self._loaded_mono = time.monotonic()
        n = sum(len(v) for v in self.instances.values())
        self.event("info", f"discovered {len(types)} instance type(s), {n} instance(s) "
                           f"in {time.monotonic() - t0:.1f}s")
        if self.cache is not None:
            self.cache.save_types(types, [])
            self._dirty_cache = True

    # -- background chunks ------------------------------------------------------------------
    def _todo(self) -> list[str]:
        """Types whose model the background still re-checks this run."""
        return [t.key for t in self.types if self.model_state.get(t.key) not in ("fresh", "error")
                and (t.creatable or self.instances.get(t.key)) and ("model", t.key) not in self._pending]

    def _idle_pending(self) -> bool:
        return not self.loading and self.live and bool(self._todo())

    def _idle_work(self) -> bool:
        """One chunk of background work: a type's model (re-)derived with its storage needs, then the
        cache saved once, then the sub-service warmup (C-D3) when the build didn't do it."""
        if self.loading or not self.live or time.monotonic() - self._loaded_mono < self.IDLE_GRACE:
            return False
        todo = self._todo()
        if todo:
            self._derive(todo[0])
            return True
        if not self._ext_checked:
            self._ext_checked = True
            self._revalidate_forms()
            return True
        if self.cache is not None and self._dirty_cache:
            self._dirty_cache = False
            self._persist()
            return True
        if self.cache is not None and not self._sub_warmed:
            self._sub_warmed = True
            self._warm_subservices()
            return True
        return False

    def _revalidate_forms(self) -> None:
        """V-C2, once per run after the first paint: zen-API-only forms re-read past the cache."""
        check = getattr(self.provider, "revalidate_zen_extensions", None)
        if check is None or self.build is not None and not self.build.finished:
            return
        try:
            with span("zen forms re-check"):
                changed = check()
        except Exception as e:
            self.event("warn", f"zen forms re-check: {e}")
            return
        if changed:
            self.event("info", "zen forms changed since the cache was built: re-deriving the types and models")
            self._full(refresh=False)
            with self.lock:
                for key in self.model_state:
                    self.model_state[key] = "stale"
            self._dirty_cache = True
            self._bump("catalog", "cache")

    def _persist(self) -> None:
        try:
            with span("cache save"):
                self.cache.finish()
            with self.lock:
                self.cache_status = "fresh"
            self._bump("cache")
        except Exception as e:
            self.event("warn", f"cache: could not save ({e})")

    def _warm_subservices(self) -> None:
        if self.include_subservices is False:
            return
        from .cache import subservices as warm_sub
        types = list(self.types)
        insts = dict(self.instances)
        if not (self.include_subservices or any(warm_sub.applies(t, insts.get(t.key, [])) for t in types)):
            return
        with self.lock:
            self.cache_status = "warming sub-services"
        self._bump("cache")
        try:
            with span("sub-service warmup"):
                warm_sub.warm(self.cache, types, insts)
            self.cache.sources.flush()
            self.cache.store.save_manifest()
        except Exception as e:
            self.event("warn", f"sub-service warmup: {e}")
        with self.lock:
            self.cache_status = "fresh"
        self._bump("cache")

    def _model_lock(self, type_key: str) -> threading.Lock:
        with self.lock:
            return self._model_locks.setdefault(type_key, threading.Lock())

    def _derive(self, type_key: str) -> FormModel | Exception | None:
        """The type's model with storage needs, unless this run already has it (per-type lock: both
        lanes may ask). A cached model stays on screen until the new one is complete."""
        with self._model_lock(type_key):
            if self.model_state.get(type_key) == "fresh":
                return self.models.get(type_key)
            t = self.type_by_key(type_key)
            if t is None:
                return None
            insts = self.instances.get(type_key) if self.live else None
            old = self.models.get(type_key)
            with self.lock:
                self.model_state[type_key] = "building"
            self._bump(model=type_key)
            two_phase = hasattr(self.provider, "assess_storage")
            try:
                fm: FormModel | Exception = (self.provider.form_model(t, insts, storage=False) if two_phase
                                             else self.provider.form_model(t, insts))
            except Exception as e:
                fm = e
                self.event("error", f"discovering {t.display}: {e}")
            if isinstance(fm, Exception) or not isinstance(old, FormModel):
                with self.lock:                    # nothing better on screen: fields first
                    self.models[type_key] = fm
                    self.model_state[type_key] = "error" if isinstance(fm, Exception) else "building"
                self._bump(model=type_key)
            if isinstance(fm, Exception):
                return fm
            sc = self.sc
            try:
                if two_phase:
                    live = insts if insts is not None else self.provider.list_instances(t)
                    self.provider.assess_storage(fm, live)
                    insts = live
                sc = self.provider.storage_classes()
            except Exception as e:
                self.event("warn", f"storage analysis of {t.display}: {e}")
            if isinstance(old, FormModel) and _needs(old) != _needs(fm):
                self.event("info", f"{t.display}: storage needs changed since the cache was built; updated")
            with self.lock:
                self.models[type_key] = fm
                self.model_state[type_key] = "fresh"
                sc_changed = sc != self.sc
                self.sc = sc
            self._bump(model=type_key)
            if sc_changed:
                self._bump("sc")
            if self.cache is not None:
                try:
                    self.cache.save_model(fm, insts or [])
                    if sc_changed:
                        self.cache.save_storage(sc)
                    self._dirty_cache = True
                except Exception as e:
                    self.event("warn", f"cache: could not save {t.display} ({e})")
            return fm

    # -- polling ------------------------------------------------------------------------------
    def _prefetch_lists(self, types: list[InstanceType]) -> None:
        """CR lists and the zen list at once (each type's list_instances then joins in memory)."""
        cluster = getattr(self.provider, "cluster", None)
        ns = getattr(self.provider, "namespace", None)
        paths = [t.list_path(ns) for t in types if t.crd and t.plural]
        jobs = []
        with ThreadPoolExecutor(max_workers=2) as pool:
            if cluster is not None and paths and hasattr(cluster, "list_many"):
                jobs.append(pool.submit(cluster.list_many, paths))
            if hasattr(self.provider, "zen_records"):
                jobs.append(pool.submit(self.provider.zen_records))
            for j in jobs:
                try:
                    j.result()
                except Exception:
                    pass                    # list_instances reports it per type

    def _poll_instances(self, announce: bool = True, refresh: bool = True) -> None:
        with span("poll instances"):
            if refresh:
                self.provider.refresh_instances()
            types = list(self.types)
            self._prefetch_lists(types)
            fresh: dict[str, list[Instance]] = {}
            for t in types:
                try:
                    fresh[t.key] = self.provider.list_instances(t)
                except Exception as e:
                    self.event("error", f"listing {t.display}: {e}")
                    fresh[t.key] = self.instances.get(t.key, [])
        self._publish_instances(fresh, announce=announce and self.live)

    def _publish_instances(self, fresh: dict[str, list[Instance]], announce: bool) -> None:
        states = {instance_key(i): i.state for v in fresh.values() for i in v}
        first_live = not self.live
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
        from .cache.manager import instances_fp
        changed_types = []
        for key, insts in fresh.items():
            fp = instances_fp(insts)
            if self._fps.get(key) not in (None, fp):
                changed_types.append(key)
            self._fps[key] = fp
        with self.lock:
            self.instances = fresh
            self._states = states
            self.loaded_at = time.time()
            self.live = True
            self.tabs = {k: v for k, v in self.tabs.items() if k in states}
            for key in changed_types:            # S4 of a new instance, new value-flow evidence
                if self.model_state.get(key) == "fresh":
                    self.model_state[key] = "stale"
            if first_live and self.cache is not None:
                self.cache_status = self.cache_status if self.cache_status.startswith(("building", "warming")) \
                    else "revalidating"
        if first_live and self.cache is not None:
            n = sum(len(v) for v in fresh.values())
            self.event("info", f"live: {n} instance(s) (the cached list is replaced)")
        if self.cache is not None and (first_live or changed_types or announce):
            try:
                self.cache.save_instances(fresh)
                self._dirty_cache = True
            except Exception:
                pass
        self._bump("instances", "cache")

    def _load_tab(self, inst: Instance) -> None:
        t = self.type_by_key(inst.type_key)
        cluster = getattr(self.provider, "cluster", None)
        ns = inst.namespace or getattr(self.provider, "namespace", None)
        with span("tab state"):
            st = tab_state(cluster, t, inst, ns) if (t and cluster) else TabState("none", "no sub-services")
        with self.lock:
            self.tabs[instance_key(inst)] = st
        self._bump("tabs")
