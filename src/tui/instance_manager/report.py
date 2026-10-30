"""Headless output: --once, --explain TYPE, --storage-report (read-only, no TTY needed)."""

from __future__ import annotations

from rich.console import Console
from rich.text import Text

from ..common.glow_dot import as_content
from .model import Field, FormModel, InstanceType, Kind, Need, Role, path_str
from .providers.base import Provider

KIND_STYLE = {Kind.FILE: "cyan", Kind.BLOCK: "magenta", Kind.OBJECT: "yellow", Kind.UNKNOWN: "dim"}
NEED_STYLE = {Need.FILE: "cyan", Need.BLOCK: "magenta", Need.EITHER: "green", Need.UNKNOWN: "dim"}


def _console(plain: bool) -> Console:
    return Console(soft_wrap=True, no_color=plain, highlight=False)


def find_type(types: list[InstanceType], token: str) -> InstanceType | None:
    t = token.lower()
    for it in types:
        if t in (it.key.lower(), it.display.lower(), it.kind.lower(), f"{it.plural}.{it.group}".lower(),
                 it.key.split(":", 1)[-1].lower()):
            return it
    return None


def print_once(provider: Provider, header: str, plain: bool) -> None:
    con = _console(plain)
    con.print(header)
    for note in getattr(provider, "notices", []):
        con.print(Text(f"! {note}", style="yellow"))
    types = provider.discover_types()
    if not types:
        con.print("no instance types found")
    for it in types:
        insts = provider.list_instances(it)
        cap = f"  (max {it.max_instances})" if it.max_instances else ""
        addon = it.meta.get("addon")
        backing = f"{it.kind}.{it.group}" if it.kind else (
            f"zen {addon.provisioning_type or 'provider'}" if addon else "zen")
        flag = "" if it.creatable else "  (not managed)"
        con.print(Text.assemble((f"\n{it.display}", "bold"), f"  {backing}  ",
                                f"{len(insts)} instance(s){cap}{flag}"))
        for note in it.notices:
            con.print(Text(f"  ! {note}", style="yellow"))
        for i in sorted(insts, key=lambda x: (x.state.severity, x.name)):
            line = Text("  ")
            line.append_text(as_content(i.state, plain=plain))
            line.append(f" {i.name}")
            if i.display_name and i.display_name != i.name:
                line.append(f" ({i.display_name})", style="dim")
            if i.namespace:
                line.append(f"  ns={i.namespace}", style="dim")
            if i.badges:
                line.append("  " + " ".join(f"[{b}]" for b in i.badges), style="yellow")
            line.append(f"  {i.reason}", style="dim")
            con.print(line)


def _value(f: Field, v) -> str:
    if f.role == Role.SECRET:
        return "****"
    s = str(v)
    return s if len(s) <= 40 else s[:37] + "..."


def _field_line(f: Field) -> Text:
    t = Text(f"  {f.key}", style="bold" if f.role != Role.OTHER else "")
    t.append(f"  {f.type}", style="dim")
    if f.role != Role.OTHER:
        t.append(f"  role={f.role.value}", style="green")
        if f.role_evidence:
            t.append(f" ({f.role_evidence})", style="dim")
    bounds = []
    if f.minimum is not None:
        bounds.append(f"min {f.minimum}")
    if f.maximum is not None:
        bounds.append(f"max {f.maximum}")
    if f.enum:
        bounds.append("enum " + "|".join(map(str, f.enum[:8])) + ("|..." if len(f.enum) > 8 else ""))
    if f.required:
        bounds.append("required")
    if f.default is not None:
        bounds.append(f"default {_value(f, f.default)}")
    if bounds:
        t.append("  [" + ", ".join(bounds) + "]")
    if f.observed:
        uniq = list(dict.fromkeys(_value(f, v) for v in f.observed if not isinstance(v, (dict, list))))
        if uniq:
            t.append("  observed=" + ", ".join(uniq[:5]) + (" ..." if len(uniq) > 5 else ""), style="cyan")
    if f.mutability.value != "unknown":
        t.append(f"  {f.mutability.value}", style="yellow" if f.mutability.value == "immutable" else "")
    t.append("  {" + ",".join(sorted(f.sources)) + "}", style="dim")
    return t


def print_explain(provider: Provider, token: str, plain: bool, all_fields: bool) -> int:
    con = _console(plain)
    types = provider.discover_types()
    it = find_type(types, token)
    if it is None:
        con.print(f"no instance type matches '{token}'. Known: " + ", ".join(t.display for t in types))
        return 2
    fm = provider.form_model(it)
    _print_model(con, it, fm, all_fields)
    return 0


def _print_model(con: Console, it: InstanceType, fm: FormModel, all_fields: bool) -> None:
    shown = [f for f in fm.fields.values() if all_fields or f.prominent]
    con.print(Text.assemble((it.display, "bold"), f"  {it.kind}.{it.group}/{it.version}  ",
                            f"{fm.instance_count} instance(s) observed  ",
                            (f"{len(shown)}/{len(fm.fields)} fields shown"
                             + ("" if all_fields else " (--all-fields for the rest)"), "dim")))
    for n in fm.notices:
        con.print(Text(f"! {n}", style="yellow"))
    for f in shown:
        con.print(_field_line(f))
        if f.aliases:
            state = "confirmed" if f.alias_confirmed else "candidate"
            con.print(Text(f"      alias group ({state}): " + ", ".join(path_str(p) for p in f.aliases), style="dim"))
        if f.storage:
            _print_need(con, f, indent="      ")
        for n in f.notices:
            con.print(Text(f"      ! {n}", style="yellow"))


def _print_need(con: Console, f: Field, indent: str) -> None:
    sn = f.storage
    con.print(Text.assemble(indent, "needs: ", (sn.need.value, NEED_STYLE[sn.need])))
    for ev in sn.evidence:
        con.print(Text(f"{indent}  - {ev}", style="dim"))
    for m in sn.mismatches:
        con.print(Text(f"{indent}  ! mismatch {m}", style="red"))


def print_storage_report(provider: Provider, plain: bool) -> None:
    con = _console(plain)
    con.print(Text("StorageClasses", style="bold"))
    for info in sorted(provider.storage_classes().values(), key=lambda i: i.name):
        t = Text(f"  {info.name}  ")
        t.append(info.kind.label, style=KIND_STYLE[info.kind])
        flags = [f for f, on in (("default", info.default), ("expandable", info.expandable),
                                 ("raw-block", info.raw_block)) if on]
        t.append(f"  {info.provisioner}  pvcs={info.pvc_count}" + (f"  {' '.join(flags)}" if flags else ""),
                 style="dim")
        con.print(t)
        for ev in info.evidence:
            con.print(Text(f"      - {ev}", style="dim"))
    con.print(Text("\nStorage-class fields", style="bold"))
    for it in provider.discover_types():
        fm = provider.form_model(it)
        sc_fields = fm.by_role(Role.STORAGE_CLASS)
        if not sc_fields:
            continue
        con.print(Text.assemble((f"  {it.display}", "bold"), f"  ({fm.instance_count} instance(s))"))
        for f in sc_fields:
            con.print(Text(f"    {f.key}" + (f"  (aliases: {', '.join(path_str(p) for p in f.aliases)})"
                                             if f.aliases else ""), style=""))
            if f.storage:
                _print_need(con, f, indent="      ")
