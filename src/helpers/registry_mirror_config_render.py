"""Render configs/registry_mirror_config/registry_mirror_vars.sh for the private
registry mirroring track (called by 0_initial_setup/0.0_generate_mirror_config.sh).

    python3 registry_mirror_config_render.py --template FILE --installs-dir DIR
        --out FILE [--existing FILE] [--prefill FILE] [--catalogs-dir DIR]
        [--installs id,id,...]

- The base template gets one section per install from <installs-dir>/<id>.sh.j2,
  rendered with the install's .conf values and its catalogs
  (<catalogs-dir>/<id>.tsv: "catalog<TAB>id<TAB>description" lines from the
  segment-0 hook, verb "components").
- Merge: for every `export KEY=...` line, the value from --prefill wins (explicit
  request), then the value already in --existing, then the template default.
  Keys of the existing file the template no longer has are kept at the end.
- Writes atomically with mode 0600 (the file holds registry credentials).
"""

import argparse
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

try:
    import jinja2
except ImportError:
    print("[ERROR] jinja2 is needed to render the mirror config - run `uv sync` in the repo "
          "(or pip install jinja2)", file=sys.stderr)
    sys.exit(2)

EXPORT_RE = re.compile(r"^(\s*export\s+)([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def read_conf(path):
    vals = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip().strip('"')
    return vals


def read_exports(path):
    """KEY -> raw right-hand side (as written, quotes included)."""
    out = {}
    if path and os.path.isfile(path):
        with open(path) as f:
            for line in f:
                m = EXPORT_RE.match(line.rstrip("\n"))
                if m:
                    out[m.group(2)] = m.group(3)
    return out


def shell_quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def _wrap_ids(ids, width=96, lead="#  "):
    lines, cur = [], lead
    for i in ids:
        piece = f" {i},"
        if len(cur) + len(piece) > width and cur != lead:
            lines.append(cur.rstrip(","))
            cur = lead
        cur += piece
    lines.append(cur.rstrip(","))
    return lines


def catalog_comment(rows, width=96):
    """rows: [(id, description)] -> comment lines: described ids one per line,
    the rest wrapped compactly after them."""
    if not rows:
        return "#   (none)"
    described = [(i, d) for i, d in rows if d]
    plain = [i for i, d in rows if not d]
    lines = []
    if described:
        w = min(max(len(i) for i, _ in described), 32)
        lines += [f"#   {i:<{w}}  {d}".rstrip() for i, d in described]
    if plain:
        if described:
            lines.append("#   also:")
        lines += _wrap_ids(plain, width)
    return "\n".join(lines)


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--template", required=True)
    p.add_argument("--installs-dir", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--existing", default="")
    p.add_argument("--prefill", default="")
    p.add_argument("--catalogs-dir", default="")
    p.add_argument("--installs", default="")
    a = p.parse_args(argv[1:])

    ids = [i for i in a.installs.split(",") if i] if a.installs else sorted(
        f[:-5] for f in os.listdir(a.installs_dir) if f.endswith(".conf") and not f.startswith("_"))
    # shared first, then the rest in the given order
    ids = (["shared"] if "shared" in ids else []) + [i for i in ids if i != "shared"]

    env = jinja2.Environment(loader=jinja2.FileSystemLoader(a.installs_dir),
                             undefined=jinja2.StrictUndefined, keep_trailing_newline=False)
    sections = []
    for iid in ids:
        conf = read_conf(os.path.join(a.installs_dir, f"{iid}.conf"))
        catalogs = {}
        tsv = os.path.join(a.catalogs_dir, f"{iid}.tsv") if a.catalogs_dir else ""
        if tsv and os.path.isfile(tsv):
            with open(tsv) as f:
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) >= 2 and parts[1]:
                        catalogs.setdefault(parts[0], []).append((parts[1], parts[2] if len(parts) > 2 else ""))
        comments = {k: catalog_comment(v) for k, v in catalogs.items()}
        part_name = f"{iid}.sh.j2" if os.path.isfile(os.path.join(a.installs_dir, f"{iid}.sh.j2")) else "_template.sh.j2"
        text = env.get_template(part_name).render(
            install=conf, ID=iid.upper().replace("-", "_"),
            components_comment=comments.get("component", "#   (none)"),
            catalogs=_Defaulting(comments))
        sections.append({"id": iid, "partial": text.strip("\n")})

    base_env = jinja2.Environment(loader=jinja2.FileSystemLoader(os.path.dirname(a.template)),
                                  undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
    rendered = base_env.get_template(os.path.basename(a.template)).render(
        generated_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        installs=sections, install_ids=[s["id"] for s in sections if s["id"] != "shared"])

    existing = read_exports(a.existing)
    prefill = {}
    if a.prefill and os.path.isfile(a.prefill):
        with open(a.prefill) as f:
            for line in f:
                if "\t" in line:
                    k, v = line.rstrip("\n").split("\t", 1)
                    prefill[k] = v

    out_lines, seen = [], set()
    for line in rendered.splitlines():
        m = EXPORT_RE.match(line)
        if m:
            key = m.group(2)
            seen.add(key)
            if key in prefill:
                line = f"{m.group(1)}{key}={shell_quote(prefill[key])}"
            elif key in existing:
                line = f"{m.group(1)}{key}={existing[key]}"
        out_lines.append(line)
    leftovers = [k for k in existing if k not in seen]
    if leftovers:
        out_lines += ["", "# ------------------------------------------------------------------------------",
                      "# Kept from the previous version of this file (no longer in the template)",
                      "# ------------------------------------------------------------------------------"]
        out_lines += [f"export {k}={existing[k]}" for k in leftovers]

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".registry_mirror_vars.", dir=os.path.dirname(os.path.abspath(a.out)))
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(out_lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, a.out)
    print(f"kept={len([k for k in existing if k in seen and k not in prefill])} "
          f"prefilled={len([k for k in prefill if k in seen])} carried_over={len(leftovers)}")
    return 0


class _Defaulting(dict):
    """catalogs.<name> -> comment text, '#   (none)' when the hook printed none."""
    def __getattr__(self, name):
        return self.get(name, "#   (none)")

    def __getitem__(self, name):
        return self.get(name, "#   (none)")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
