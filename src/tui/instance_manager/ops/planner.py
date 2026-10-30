"""Build ActionPlans for create / edit / delete (plan §6). Nothing here changes the cluster
until a Step's run() is called by the executor; edit plans are dry-run on the server while
they are built.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import time
from collections.abc import Callable

from ...common.kube import KubeError
from ...common.state import State
from ..discovery.observed import flatten
from ..model import Field, FormModel, Instance, InstanceType, Mutability, Path, Role, path_str
from . import credentials, payload as pl
from .plan import ActionPlan, Log, Step

WATCH_EVERY = 15
WATCH_LOG_EVERY = 60
MERGE_PATCH = "application/merge-patch+json"
_NUM = re.compile(r"^([0-9]+(?:\.[0-9]+)?)([A-Za-z]*)$")


def addon_type(itype: InstanceType) -> str:
    return itype.key.split(":", 1)[1]


def cr_path(itype: InstanceType, inst: Instance) -> str:
    return f"{itype.list_path(inst.namespace)}/{inst.name}"


# -- watch -------------------------------------------------------------------------
def watch(provider, itype: InstanceType, done: Callable[[list[Instance]], tuple[bool, str]], timeout: int,
          log: Log, on_update: Callable[[list[Instance]], None] | None = None) -> bool:
    """Poll the type's instances until done() says so; log every change and a heartbeat with elapsed/limit."""
    t0, last_line, last_log = time.monotonic(), None, 0.0
    while True:
        provider.refresh_instances()
        insts = provider.list_instances(itype)
        if on_update:
            on_update(insts)
        ok, line = done(insts)
        el = int(time.monotonic() - t0)
        if line != last_line or time.monotonic() - last_log >= WATCH_LOG_EVERY:
            log(f"  [{el // 60}m{el % 60:02d}s / {timeout // 60}m] {line}")
            last_line, last_log = line, time.monotonic()
        if ok:
            return True
        if el >= timeout:
            log(f"  gave up waiting after {timeout // 60}m (the operation itself may still finish)")
            return False
        time.sleep(WATCH_EVERY)


def _find(insts: list[Instance], name: str) -> Instance | None:
    return next((i for i in insts if name in (i.name, i.display_name)), None)


# -- create ----------------------------------------------------------------------------
def plan_create(provider, itype: InstanceType, fm: FormModel, values: dict[Path, object], name: str,
                description: str = "", version: str | None = None, *, existing: list[Instance] | None = None,
                api_url: str = "", name_regex: str | None = None,
                on_update: Callable[[list[Instance]], None] | None = None,
                vault: bool | None = None, vault_members: list[str] | None = None) -> ActionPlan:
    existing = provider.list_instances(itype) if existing is None else existing
    names = [n for i in existing for n in {i.name, i.display_name} if n]
    plan = ActionPlan(op="create", target=f"{itype.display} {name}", type_key=itype.key)
    errs, warns = pl.validate(itype, fm, values, name, names, provider.storage_classes(), name_regex)
    plan.errors += errs
    plan.warnings += warns
    version = version or (itype.versions[-1] if itype.versions else None)
    payload = pl.build(itype, fm, values, name, description, provider.namespace, version)
    at = addon_type(itype)
    secret_vals = {f.path[-1]: str(values.get(f.path)) for f in pl.payload_fields(fm)
                   if f.role == Role.SECRET and values.get(f.path)}
    plan.summary += [f"namespace {provider.namespace}", f"version {version or '(zen default)'}",
                     f"credentials file {credentials.path_for(at, name)}"]
    for f in pl.payload_fields(fm):
        if pl.shown(f, values) and values.get(f.path) is not None:
            v = "****" if f.role == Role.SECRET else values[f.path]
            if f.role == Role.STORAGE_CLASS:
                info = provider.storage_classes().get(str(v))
                v = f"{v}  ({info.kind.label})" if info else v
            plan.summary.append(f"{f.label or f.key}: {v}")

    def save(log: Log) -> None:
        p = credentials.write(at, name, provider.namespace, api_url, {k.upper(): v for k, v in secret_vals.items()})
        log(f"  wrote {p} (0600)")

    def create(log: Log) -> None:
        tmpdir = tempfile.mkdtemp(prefix="sim-")                    # 0700
        try:
            path = os.path.join(tmpdir, "payload.json")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as fh:
                json.dump(payload, fh)
            out = provider.cli.run("service-instance", "create", f"--from-source={path}", timeout=600)
            for ln in out.strip().splitlines()[-5:]:
                log(f"  {ln}")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def wait(log: Log) -> None:
        def done(insts):
            i = _find(insts, name)
            if i is None:
                return False, "waiting for the instance to appear"
            return i.state == State.HEALTHY, f"{i.state.word}: {i.reason}"
        watch(provider, itype, done, 45 * 60, log, on_update)

    vmod = credentials.vault()
    use_vault = vmod.enabled(vault)
    members_ = vmod.member_names() if vault_members is None else vault_members

    def to_vault(log: Log) -> None:
        try:
            vmod.store(credentials.path_for(at, name), members_, log=log)
        except Exception as e:                 # the local file is saved; the vault is a copy
            log(f"  [WARN] vault: {str(e).splitlines()[0][:200]} (the credentials file is saved)")

    owner = os.environ.get("CPD_USERNAME", "?")
    others = [m for m in members_ if m.lower() != owner.lower()]
    who = f"owner {owner}" + (f", shared with {', '.join(others)}" if others else "")
    plan.summary.append(f"Software Hub vault: secret {vmod.secret_name(at, name)} ({who})" if use_vault
                        else "Software Hub vault: off")
    plan.steps = [
        Step("save the instance-details file", save, dry_run="local"),
        *([Step(f"save the credentials in the Software Hub vault ({who})", to_vault,
                dry_run="none: the secrets API has no dry-run")] if use_vault else []),
        Step("cpd-cli service-instance create", create,
             preview=json.dumps(pl.masked(payload, fm), indent=2),
             dry_run="local validation only: cpd-cli has no dry-run and zen renders the CR"),
        Step("watch until healthy (45m limit)", wait),
    ]
    return plan


# -- edit ----------------------------------------------------------------------------------
def coerce_like(new, old):
    """New value in the format of an alias's current value ("5" next to "4Gi" -> "5Gi", int stays int)."""
    m_new = _NUM.match(str(new).strip())
    if isinstance(old, bool):
        return str(new).lower() in ("true", "1", "yes", "on") if not isinstance(new, bool) else new
    if isinstance(old, int) and m_new and not m_new.group(2):
        return int(float(m_new.group(1)))
    if isinstance(old, float) and m_new and not m_new.group(2):
        return float(m_new.group(1))
    if isinstance(old, str):
        m_old = _NUM.match(old.strip())
        if m_old and m_new:
            n = float(m_new.group(1))
            num = str(int(n)) if n.is_integer() else str(n)
            return num + (m_new.group(2) or m_old.group(2))
        return str(new)
    return new


def _nested(changes: dict[Path, object]) -> dict:
    root: dict = {}
    for path, v in changes.items():
        node = root
        for part in path[:-1]:
            node = node.setdefault(part, {})
        node[path[-1]] = v
    return {"spec": root}


def plan_edit(provider, itype: InstanceType, inst: Instance, fm: FormModel, changes: dict[Path, object],
              on_update: Callable[[list[Instance]], None] | None = None) -> ActionPlan:
    plan = ActionPlan(op="edit", target=f"{itype.display} {inst.display_name or inst.name}", type_key=itype.key)
    if not inst.obj or not itype.crd:
        plan.errors.append("no backing CR to patch; the cpd-cli upgrade --merge-override path is not "
                           "verified yet (plan V3)")
        return plan
    flat = flatten(inst.spec)
    patch: dict[Path, object] = {}
    for path, new in changes.items():
        f: Field | None = fm.fields.get(path)
        if f is None:
            plan.errors.append(f"unknown field {path_str(path)}")
            continue
        old = flat.get(path)
        label = f.label or f.key
        if f.mutability == Mutability.IMMUTABLE:
            plan.errors.append(f"{label} can't change on an existing instance ({'; '.join(f.notices) or 'immutable'})")
            continue
        if not f.role.capacity:
            plan.errors.append(f"{label} is not a scale/capacity field")
            continue
        if f.minimum is not None and _num(new) is not None and _num(new) < f.minimum:
            plan.errors.append(f"{label}: {new} is below the minimum {f.minimum}")
        if f.maximum is not None and _num(new) is not None and _num(new) > f.maximum:
            plan.errors.append(f"{label}: {new} is above the maximum {f.maximum}")
        if f.enum and not f.enum_soft and str(new) not in map(str, f.enum):
            plan.errors.append(f"{label}: {new} is not one of {', '.join(map(str, f.enum))}")
        if f.role == Role.STORAGE_SIZE:
            plan.errors += _storage_growth(provider, inst, label, old, new)
        group = [path] + [a for a in f.aliases if a in flat]
        for p in group:
            if any(seg.startswith("[") for seg in p):
                plan.errors.append(f"{path_str(p)} sits in a list; list items can't be merge-patched safely")
                continue
            patch[p] = coerce_like(new, flat.get(p)) if flat.get(p) is not None else new
            plan.diff.append((path_str(p), str(flat.get(p)), str(patch[p])))
        if f.aliases and not f.alias_confirmed:
            plan.warnings.append(f"{label}: its alias group ({', '.join(path_str(a) for a in f.aliases)}) was "
                                 "inferred from one instance; check the changes below")
    if plan.errors or not patch:
        if not patch and not plan.errors:
            plan.errors.append("nothing changes")
        return plan
    body = _nested(patch)
    path = cr_path(itype, inst)
    kube = provider.cluster.kube
    try:
        kube.send("PATCH", path, body, content_type=MERGE_PATCH, dryRun="All")
        dry = "server-side dry-run passed (schema + admission)"
    except KubeError as e:
        plan.errors.append(f"server-side dry-run rejected the change: {e}")
        dry = f"rejected: {e}"

    def apply(log: Log) -> None:
        kube.send("PATCH", path, body, content_type=MERGE_PATCH)
        log(f"  patched {itype.kind}/{inst.name}")

    def wait(log: Log) -> None:
        t_start = time.monotonic()

        def done(insts):
            i = _find(insts, inst.name)
            if i is None:
                return False, "instance not listed"
            settled = i.state == State.HEALTHY and time.monotonic() - t_start > 2 * WATCH_EVERY
            return settled, f"{i.state.word}: {i.reason}"
        watch(provider, itype, done, 30 * 60, log, on_update)

    plan.summary.append(f"merge patch on {itype.kind}/{inst.name} (the operator reconciles the rest; "
                        "sinks are never patched directly)")
    plan.steps = [Step(f"patch {itype.kind}/{inst.name}", apply, preview=json.dumps(body, indent=2), dry_run=dry),
                  Step("watch the reconcile (30m limit)", wait)]
    return plan


def _num(v):
    m = _NUM.match(str(v).strip()) if v is not None else None
    return float(m.group(1)) if m else None


def _storage_growth(provider, inst: Instance, label: str, old, new) -> list[str]:
    errs = []
    o, n = _num(old), _num(new)
    if o is not None and n is not None and n < o:
        errs.append(f"{label}: volumes can't shrink ({old} -> {new})")
    graph = provider.graph({inst.namespace} if inst.namespace else set())
    sc = provider.storage_classes()
    classes = {p["spec"].get("storageClassName") for p in graph.pvcs_under(inst.uid)}
    fixed = sorted(c for c in classes if c in sc and not sc[c].expandable)
    if fixed:
        errs.append(f"{label}: StorageClass {', '.join(fixed)} does not allow volume expansion")
    return errs


def _exists(provider, path: str) -> bool:
    try:
        provider.cluster.kube.get(path, timeout=(5, 20))
        return True
    except KubeError as e:
        return e.status != 404


def _kind_of(obj: dict) -> str:
    """List items carry no kind; PVCs and StatefulSets are recognised by their spec."""
    spec = obj.get("spec") or {}
    if obj.get("kind"):
        return obj["kind"]
    if "accessModes" in spec:
        return "PersistentVolumeClaim"
    if "volumeClaimTemplates" in spec or "serviceName" in spec:
        return "StatefulSet"
    return "?"


# -- rename ------------------------------------------------------------------------------
RENAME_UNSUPPORTED = (
    "Software Hub has no API to rename a service instance: in zen-core-api's own API spec (embedded in the "
    "5.4 server) only the provision request carries display_name; PATCH /zen-data/v3/service_instances/{id} "
    "takes runtime args/resources and the /meta patch (for service providers) description/metadata. "
    "Kubernetes resource names can't change either. Create a new instance with the wanted name instead.")


def plan_rename(provider, itype: InstanceType, inst: Instance, new_name: str) -> ActionPlan:
    """D7: rename = the zen display name only. Verified unsupported on 5.4 (plan V1), so the plan explains
    that instead of trying an undocumented call."""
    plan = ActionPlan(op="rename", target=f"{itype.display} {inst.display_name or inst.name}", type_key=itype.key)
    plan.summary.append(f"{inst.display_name or inst.name} -> {new_name}")
    plan.errors.append(RENAME_UNSUPPORTED)
    return plan


# -- delete -------------------------------------------------------------------------------------
def plan_delete(provider, itype: InstanceType, inst: Instance, force: bool = False,
                on_update: Callable[[list[Instance]], None] | None = None) -> ActionPlan:
    plan = ActionPlan(op="delete", target=f"{itype.display} {inst.display_name or inst.name}", type_key=itype.key,
                      confirm_name=inst.display_name or inst.name)
    zen = inst.meta.get("zen")
    at = addon_type(itype)
    gc_pvcs: list[tuple[str, str]] = []          # (namespace, name) the garbage collector should remove
    if inst.uid:
        graph = provider.graph({inst.namespace} if inst.namespace else set())
        owned = [o for uid, o in graph.objects.items() if inst.uid in graph.ancestors(uid)]
        kinds: dict[str, list[str]] = {}
        for o in owned:
            kinds.setdefault(_kind_of(o), []).append((o.get("metadata") or {}).get("name", "?"))
        plan.summary.append(f"{itype.kind}/{inst.name} and what it owns:")
        for k, names in sorted(kinds.items()):
            plan.summary.append(f"  {k} x{len(names)}: {', '.join(sorted(names)[:6])}{' ...' if len(names) > 6 else ''}")
        under = graph.pvcs_under(inst.uid)
        kept = [p["metadata"]["name"] for p in under if not p["metadata"].get("ownerReferences")]
        gc_pvcs = [(p["metadata"]["namespace"], p["metadata"]["name"]) for p in under
                   if p["metadata"].get("ownerReferences")]
        if kept:
            plan.warnings.append(f"{len(kept)} PVC(s) have no owner and will stay after the delete "
                                 f"({', '.join(kept[:5])}); remove them separately if the data isn't needed")
    if zen:
        plan.summary.insert(0, f"zen record {zen.get('id')} ({at})")
        args = ["service-instance", "delete", zen.get("display_name") or inst.name, f"--service-type={at}"]
        if force:
            args.append("--force")
            plan.warnings.append("--force: use only after a normal delete failed or hung")

        def run(log: Log) -> None:
            out = provider.cli.run(*args, timeout=900)
            for ln in out.strip().splitlines()[-5:]:
                log(f"  {ln}")
        step = Step(f"cpd-cli {' '.join(args[:3])} {args[3]}{' --force' if force else ''}", run,
                    dry_run="none: cpd-cli has no dry-run")
    elif inst.obj:
        path = cr_path(itype, inst)
        kube = provider.cluster.kube
        try:
            kube.send("DELETE", path, dryRun="All")
            dry = "server-side dry-run passed"
        except KubeError as e:
            plan.errors.append(f"server-side dry-run rejected the delete: {e}")
            dry = f"rejected: {e}"

        def run(log: Log) -> None:
            kube.send("DELETE", path)
            log(f"  deleted {itype.kind}/{inst.name}")
        step = Step(f"delete {itype.kind}/{inst.name} (cr-only, no zen record)", run, dry_run=dry)
    else:
        plan.errors.append("nothing to delete")
        return plan

    def wait(log: Log) -> None:
        def done(insts):
            i = _find(insts, inst.name)
            fin = ((i.obj.get("metadata") or {}).get("finalizers") if i and i.obj else None) or []
            return i is None, ("gone" if i is None else f"still there ({i.reason})"
                                + (f", finalizers: {', '.join(fin)}" if fin else ""))
        if not watch(provider, itype, done, 20 * 60, log, on_update):
            return
        credentials.mark(at, inst.display_name or inst.name, "deleted")
        vmod = credentials.vault()
        if vmod.enabled(None):
            try:
                vmod.delete(at, inst.display_name or inst.name, log=log)
            except Exception as e:
                log(f"  [WARN] vault: {str(e).splitlines()[0][:200]}")
        t0 = time.monotonic()
        left = list(gc_pvcs)
        while left and time.monotonic() - t0 < 5 * 60:
            left = [(ns, n) for ns, n in left if _exists(provider, f"/api/v1/namespaces/{ns}/persistentvolumeclaims/{n}")]
            if left:
                log(f"  waiting for {len(left)}/{len(gc_pvcs)} PVC(s) to be garbage-collected "
                    f"({int(time.monotonic() - t0)}s / 300s)")
                time.sleep(WATCH_EVERY)
        if left:
            log(f"  still there after 5m: {', '.join(n for _, n in left)}")
        elif gc_pvcs:
            log(f"  {len(gc_pvcs)} PVC(s) removed")

    plan.steps = [step, Step("watch until it is gone (20m limit)", wait)]
    return plan
