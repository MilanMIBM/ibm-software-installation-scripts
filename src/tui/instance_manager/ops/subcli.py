"""Headless sub-services: --sub [TYPE/]INSTANCE with --once / --explain / --create / --edit / --delete.

Same plans as the TUI's sub-screen. Example (the watsonx.data acceptance test):
  --sub lakehouse --create presto --name presto-small --set presto_worker_replicas=3 --yes --ack-warnings
"""

from __future__ import annotations

import sys

from rich.console import Console
from rich.text import Text

from ...common.glow_dot import as_content
from ..model import Path, Role
from ..subservices import REGISTRY
from . import payload as pl
from .cli import _instance, _sets
from .plan import ActionPlan


def _bind(provider, token: str):
    found = _instance(provider, provider.discover_types(), token)
    if found is None:
        raise SystemExit(f"no instance '{token}'")
    itype, parent = found
    for sp in REGISTRY:
        m = sp.matches(itype, parent)
        if m is None:
            continue
        if not m.enabled:
            raise SystemExit(f"{sp.display_name}: {m.reason}")
        sp.bind(parent)
        return sp, parent
    raise SystemExit(f"{parent.display_name or parent.name}: no sub-service manager for {itype.display}")


def start_values(fm, sets: dict[Path, str]) -> dict[Path, object]:
    """Form defaults, then the chosen starter preset's values, then explicit --set values."""
    vals = pl.initial_values(fm)
    pf = next((f for f in fm.fields.values() if f.role == Role.SIZE_PRESET and f.presets), None)
    chosen = sets.get(pf.path) if pf else None
    if chosen and pf and pf.presets:
        meta = next((p["metadata"] for p in pf.presets if p["value"] == chosen), {})
        for k, v in meta.items():
            vals[("parameters",) + tuple(k.split("."))] = v
    vals.update(sets)
    return vals


def run_sub(provider, args, plain: bool) -> int:
    sp, parent = _bind(provider, args.sub)
    con = Console(soft_wrap=True, no_color=plain, highlight=False)
    if args.explain:
        from ..report import _print_model
        it = sp.itype(args.explain)
        _print_model(con, it, sp.form_model(it), args.all_fields)
        return 0
    if not (args.create or args.edit or args.delete):
        con.print(Text.assemble((f"{sp.display_name}", "bold"), f" of {parent.display_name or parent.name}"))
        for kind, n in sp.kinds():
            it = sp.itype(kind)
            con.print(Text.assemble((f"\n{kind}", "bold"), f"  {n} engine(s)",
                                    "" if it.creatable else ("  (list only)", "dim")))
            for i in sp.list_instances(it):
                line = Text("  ")
                line.append_text(as_content(i.state, plain=plain))
                line.append(f" {i.display_name or i.name}  [{' '.join(i.badges)}]  {i.reason}")
                con.print(line)
        return 0
    if args.read_only:
        print("--read-only: refusing to change anything", file=sys.stderr)
        return 2
    plan: ActionPlan
    if args.create:
        it = sp.itype(args.create)
        fm = sp.form_model(it)
        sets, errs = _sets(fm, args.set, payload_only=True)
        plan = sp.plan_create(it, fm, start_values(fm, sets), args.name or "")
        plan.errors = errs + plan.errors
    else:
        kind, _, name = (args.edit or args.delete).partition("/")
        it = sp.itype(kind)
        inst = next((i for i in sp.list_instances(it) if name in (i.name, i.display_name)), None)
        if inst is None:
            print(f"no {kind} engine '{name}'", file=sys.stderr)
            return 2
        if args.delete:
            plan = sp.plan_delete(it, inst)
        else:
            view, edit = sp.edit_model(it, inst, sp.form_model(it))
            sets, errs = _sets(edit, args.set, payload_only=False)
            plan = sp.plan_edit(it, inst, edit, sets)
            plan.errors = errs + plan.errors
    from .cli import execute
    return execute(plan, args)
