"""Headless changes: --create / --edit / --delete print the ActionPlan; --yes runs it.

The same planner as the TUI, so a scripted change gets the same validation, storage
filtering, dry-run and progress lines.
"""

from __future__ import annotations

import sys

from ..model import FormModel, Instance, InstanceType, Path, Role, path_str
from ..report import find_type
from . import payload as pl
from . import planner
from .plan import ActionPlan


def _log(msg: str) -> None:
    print(msg, flush=True)


def resolve_field(fm: FormModel, key: str, payload_only: bool) -> Path | None:
    pool = pl.payload_fields(fm) if payload_only else list(fm.fields.values())
    k = key.strip().lower()
    for test in (lambda f: path_str(f.path).lower() == k, lambda f: f.path[-1].lower() == k,
                 lambda f: (f.label or "").lower() == k):
        hits = [f for f in pool if test(f)]
        if hits:
            return fm.representatives(hits)[0].path
    return None


def _sets(fm: FormModel, pairs: list[str], payload_only: bool) -> tuple[dict[Path, str], list[str]]:
    out, errs = {}, []
    for pair in pairs:
        key, sep, value = pair.partition("=")
        if not sep:
            errs.append(f"--set {pair}: expected FIELD=VALUE")
            continue
        path = resolve_field(fm, key, payload_only)
        if path is None:
            errs.append(f"--set {key}: no such field (see --explain)")
        else:
            out[path] = value
    return out, errs


def _instance(provider, types: list[InstanceType], token: str) -> tuple[InstanceType, Instance] | None:
    tname, _, iname = token.rpartition("/")
    for t in types:
        if tname and find_type([t], tname) is None:
            continue
        for i in provider.list_instances(t):
            if iname in (i.name, i.display_name):
                return t, i
    return None


def run_change(provider, args, api_url: str, plain: bool) -> int:
    if args.read_only:
        print("--read-only: refusing to change anything", file=sys.stderr)
        return 2
    types = provider.discover_types()
    plan: ActionPlan
    if args.create:
        itype = find_type(types, args.create)
        if itype is None:
            print(f"no instance type '{args.create}'", file=sys.stderr)
            return 2
        fm = provider.form_model(itype)
        values = pl.initial_values(fm, provider.storage_classes())
        sets, errs = _sets(fm, args.set, payload_only=True)
        values.update(sets)
        if args.generate_secrets:
            for f in pl.payload_fields(fm):
                if f.role == Role.SECRET and pl.shown(f, values) and not values.get(f.path):
                    values[f.path] = pl.random_password()
        entry = itype.meta.get("addon")
        plan = planner.plan_create(provider, itype, fm, values, args.name or "", args.description, args.version,
                                   api_url=api_url, name_regex=entry.name_regex if entry else None,
                                   vault=getattr(args, "vault", None))
        plan.errors = errs + plan.errors
    else:
        found = _instance(provider, types, args.edit or args.delete)
        if found is None:
            print(f"no instance '{args.edit or args.delete}'", file=sys.stderr)
            return 2
        itype, inst = found
        if args.delete:
            plan = planner.plan_delete(provider, itype, inst, force=args.force)
        else:
            fm = provider.form_model(itype)
            sets, errs = _sets(fm, args.set, payload_only=False)
            plan = planner.plan_edit(provider, itype, inst, fm, sets)
            plan.errors = errs + plan.errors
    return execute(plan, args)


def execute(plan: ActionPlan, args) -> int:
    """Print the plan; run it only with --yes (and --confirm / --ack-warnings where it needs them)."""
    print(plan.text())
    if not args.yes:
        print("\n(plan only: add --yes to run it)")
        return 0 if plan.runnable else 1
    if not plan.runnable:
        print("\nnot running: the plan has errors", file=sys.stderr)
        return 1
    if plan.confirm_name and args.confirm != plan.confirm_name:
        print(f"\nnot running: confirm with --confirm {plan.confirm_name}", file=sys.stderr)
        return 1
    if plan.warnings and not args.ack_warnings:
        print("\nnot running: the plan has warnings; add --ack-warnings to accept them", file=sys.stderr)
        return 1
    print()
    for n, step in enumerate(plan.steps, 1):
        _log(f"[{n}/{len(plan.steps)}] {step.title}")
        try:
            step.run(_log)
        except Exception as e:
            _log(f"FAILED: {e}")
            return 1
    _log(f"{plan.op} {plan.target}: done")
    return 0
