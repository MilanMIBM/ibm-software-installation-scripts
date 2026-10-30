"""Move service-instance details out of cpd_instance_details.sh into per-instance files.

Before 2026-10-30 the 4.5/5.x scripts appended their results to configs/<product>/
cpd_instance_details.sh (and Db2 / early instance-manager runs wrote *-credentials.txt files).
They now write ${CONFIG_DIR}/managed-service-instances/<type>/<instance>-instance_details.sh.
This moves what an older run left behind, with the same variable names:

  "# Written by 5_prep_edb_postgres.sh"   -> edb/<instance>   (one file per "#--- EDB Postgres - <x>")
  "# Written by 5_prep_uifeatures_informix.sh" -> informix/<INFORMIX_INSTANCE>
  "# Written by 5_prep_wxd_opensearch.sh" -> opensearch/<cluster from OSEARCH_URL>
  "# Written by 5_prep_datastax_mc.sh" / "5_0_prep_datastax_mc.sh" -> datastax-hcd/<local DC>
  "# >>> cql-gateway <ns>/<name>" ... "# <<<"  -> datastax-hcd/<name>
  service_instances/*-credentials.txt (Db2), managed-service-instances/*/*-credentials.txt (TUI)

Everything else (3.3.1's platform credentials, unknown blocks) stays. Dry run by default;
--apply writes the files, keeps a 0600 backup of cpd_instance_details.sh and rewrites it
without the moved blocks. Values are only parsed, never printed.

Run: PYTHONPATH=src python -m tui.instance_manager.ops.migrate_details [--apply]
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

from ..settings import config_dir
from . import credentials

_WRITTEN = re.compile(r"^# Written by (\S+)")
_EDB = re.compile(r"^#--- EDB Postgres - (\S+)")
_GW_BEGIN = re.compile(r"^# >>> cql-gateway (\S+)/(\S+)")
_EXPORT = re.compile(r"^export ([A-Za-z_][A-Za-z0-9_]*)=")
WRITERS = {"5_prep_edb_postgres.sh": "edb", "5_prep_uifeatures_informix.sh": "informix",
           "5_prep_wxd_opensearch.sh": "opensearch", "5_prep_datastax_mc.sh": "datastax-hcd",
           "5_0_prep_datastax_mc.sh": "datastax-hcd"}


def _values(lines: list[str]) -> dict[str, str]:
    """Evaluate the block's export lines in a clean zsh and read the values back (no output shown)."""
    names = [m.group(1) for ln in lines if (m := _EXPORT.match(ln.strip()))]
    if not names:
        return {}
    script = "\n".join(ln for ln in lines if _EXPORT.match(ln.strip())) + "\n" + \
        "for _n in " + " ".join(names) + "; do print -rn -- \"${(P)_n}\"; print -n '\\0'; done"
    out = subprocess.run(["zsh", "-f", "-c", script], capture_output=True, text=True, check=True).stdout
    return dict(zip(names, out.split("\0")))


def _blocks(text: str) -> list[tuple[str, list[str]]]:
    """[(kind, lines)]: kind = writer script name, 'gateway', or '' (keep)."""
    out: list[tuple[str, list[str]]] = []
    kind, cur, in_gw = "", [], False
    for ln in text.splitlines():
        if in_gw:
            cur.append(ln)
            if ln.startswith("# <<< cql-gateway"):
                out.append(("gateway", cur))
                kind, cur, in_gw = "", [], False
            continue
        if _GW_BEGIN.match(ln):
            out.append((kind, cur))
            kind, cur, in_gw = "gateway", [ln], True
            continue
        m = _WRITTEN.match(ln)
        if m:
            out.append((kind, cur))
            kind, cur = m.group(1), [ln]
            continue
        cur.append(ln)
    out.append((kind, cur))
    return [(k, ls) for k, ls in out if ls]


def plan(details: Path) -> tuple[list[tuple[str, str, dict[str, str], str]], str]:
    """-> ([(type, instance, exports, origin)], the text that stays in cpd_instance_details.sh)"""
    moves, keep = [], []
    for kind, lines in _blocks(details.read_text() if details.is_file() else ""):
        typ = "gateway" if kind == "gateway" else WRITERS.get(kind)
        if typ is None:
            keep += lines
            continue
        if kind == "gateway":
            ns, name = _GW_BEGIN.match(lines[0]).groups()
            moves.append(("datastax-hcd", name, _values(lines), "cql-gateway block"))
        elif typ == "edb":
            inst, sub = None, []
            for ln in lines[1:] + ["#--- EDB Postgres - __end__"]:
                m = _EDB.match(ln)
                if m:
                    if inst and sub:
                        moves.append(("edb", inst, _values(sub), kind))
                    inst, sub = m.group(1), []
                else:
                    sub.append(ln)
        else:
            vals = _values(lines)
            if typ == "informix":
                name = vals.get("INFORMIX_INSTANCE") or "informix"
            elif typ == "opensearch":
                host = vals.get("OSEARCH_URL", "").split("//")[-1]
                name = host.split("-backend")[0] if "-backend" in host else "opensearch"
            else:
                name = vals.get("DATASTAX_HCD_CQL_LOCAL_DC") or "mission-control"
            moves.append((typ, name, vals, kind))
    return moves, "\n".join(keep).rstrip("\n") + "\n"


def legacy_files(repo: Path, managed: Path) -> list[tuple[Path, str, str, dict[str, str], list[str]]]:
    """Old KEY=VALUE credential files -> (path, type, instance, exports (prefixed), trailer comments)."""
    out = []
    cands = sorted((repo / "service_instances").glob("*-credentials.txt")) + sorted(managed.glob("*/*-credentials.txt"))
    for f in cands:
        kv, trailer = {}, []
        for ln in f.read_text().splitlines():
            if ln.startswith("# ") and (ln.startswith("# deleted") or ln.startswith("# renamed")):
                trailer.append(ln)
            elif "=" in ln and not ln.startswith("#"):
                k, _, v = ln.partition("=")
                kv[k.strip()] = v
        if "DB2_INSTANCE_NAME" in kv:
            typ, name = "db2oltp", kv.pop("DB2_INSTANCE_NAME")
            keys = {k.removeprefix("DB2_"): v for k, v in kv.items()}
            keys["INSTANCE_NAME"] = name
        else:
            typ = kv.pop("INSTANCE_TYPE", f.parent.name)
            name = kv.pop("INSTANCE_NAME", f.name.removesuffix("-credentials.txt"))
            kv.pop("NAMESPACE", None)
            keys = kv
        prefix = credentials.var_prefix(typ, name)
        out.append((f, typ, name, {f"{prefix}_{k.upper()}": v for k, v in keys.items()}, trailer))
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Move service-instance details into managed-service-instances/")
    ap.add_argument("--apply", action="store_true", help="write the files (default: show what would move)")
    args = ap.parse_args(argv)
    cfg = config_dir()
    details = cfg / "cpd_instance_details.sh"
    repo = next((p for p in Path(__file__).resolve().parents if (p / "env_bootstrap.sh").is_file()), Path.cwd())
    ns = os.environ.get("PROJECT_CPD_INST_OPERANDS", "?")
    api = ""
    try:
        api = subprocess.run(["oc", "whoami", "--show-server"], capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:
        pass
    moves, rest = plan(details)
    olds = legacy_files(repo, cfg / "managed-service-instances")
    if not moves and not olds:
        print("nothing to migrate")
        return 0
    for typ, name, vals, origin in moves:
        print(f"{'move' if args.apply else 'would move'} {len(vals)} value(s) from {details.name} ({origin}) -> "
              f"{credentials.path_for(typ, name).relative_to(repo)}")
    for f, typ, name, vals, trailer in olds:
        print(f"{'convert' if args.apply else 'would convert'} {f.relative_to(repo)} -> "
              f"{credentials.path_for(typ, name).relative_to(repo)}{' (deleted instance)' if trailer else ''}")
    if not args.apply:
        print("\n(dry run: add --apply)")
        return 0
    if moves:
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
        backup = details.with_name(f"{details.name}.pre-migration-{stamp}")
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(details.read_text())
        for typ, name, vals, origin in moves:
            credentials.write_exports(typ, name, ns, api, vals, writer=f"migrate_details (from {origin})")
        with open(details, "w") as fh:                    # in place: keeps the file's permissions
            fh.write(rest)
        print(f"backup of the old file: {backup.relative_to(repo)} (0600; delete it once you're happy)")
    for f, typ, name, vals, trailer in olds:
        credentials.write_exports(typ, name, ns, api, vals, writer=f"migrate_details (from {f.name})", trailer=trailer)
        f.unlink()
    return 0


if __name__ == "__main__":
    sys.exit(main())
