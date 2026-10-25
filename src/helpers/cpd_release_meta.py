#!/usr/bin/env python3
"""cpd_release_meta.py - IBM Software Hub release metadata and downloaded CASEs.

Reads what cpd-cli itself works from, so versions and image tags follow
VERSION / PATCH_ID instead of lookup tables in the scripts:

  patch-<VERSION>-<PATCH_ID>.yaml   ${CPD_CLI_WORK_PATH}/offline/patch/ (case-download)
                                    patch_components_meta: the patched components
  release-<VERSION>.yml             olm-utils container, config-vars/
                                    release_components_meta: every component
  service_features.yml              olm-utils container, config-vars/ (scale config, add-on ids)
  <case>/<version>/*-images.csv     ${CPD_CLI_WORK_PATH}/offline/<VERSION>/.ibm-pak/data/cases/

Files from the container are read with `podman exec <container> cat` (never a
`cpd-cli manage` command: that recreates the container and kills a running
job) and cached under ${CPD_CLI_WORK_PATH}/offline/release-meta/, so a later
lookup works while the container is down.

Usage (results on stdout, where they came from on stderr; exit 1 when not found):
  cpd_release_meta.py meta <component> <field>
  cpd_release_meta.py case-dir <case> [--component C | --case-version V]
  cpd_release_meta.py case-images <case> [--component C | --case-version V] [--repo REGEX] [--arch A|all]
  cpd_release_meta.py image-tag <case> --repo REGEX [--component C | --case-version V] [--arch A]
  cpd_release_meta.py case-groups [<case>...]
  cpd_release_meta.py features <component> [<field>]
  cpd_release_meta.py cache

Environment: VERSION (required), PATCH_ID, CPD_CLI_WORK_PATH (~/cpd-cli/work),
OLM_UTILS_CONTAINER (olm-utils-play-v4), IMAGE_ARCH (amd64).
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys

CONFIG_VARS = "/opt/ansible/ansible-play/config-vars"
META_FIELDS = ("case_version", "csv_version", "cr_version", "sub_channel", "operator_version")


class MetaError(Exception):
    pass


def _work():
    return os.environ.get("CPD_CLI_WORK_PATH") or os.path.expanduser("~/cpd-cli/work")


def _version():
    v = os.environ.get("VERSION", "").strip()
    if not v:
        raise MetaError("VERSION is not set")
    return v


def _say(msg):
    print(f"[meta] {msg}", file=sys.stderr)


# -----------------------------------------------------------------------------
# YAML: every scalar as the string it was written as ("5.10" must not become 5.1)
# -----------------------------------------------------------------------------
def _section_by_lines(text, section):
    """{component: {key: value}} under a top-level <section>:; scalars only."""
    out, comp, inside, comp_ind = {}, None, False, None
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        ind = len(line) - len(line.lstrip())
        if ind == 0:
            inside, comp, comp_ind = stripped == f"{section}:", None, None
            continue
        if not inside or stripped.startswith("-"):
            continue
        key, _, val = stripped.partition(":")
        val = val.split(" #", 1)[0].strip().strip("'\"")
        if comp_ind is None or ind <= comp_ind:
            comp, comp_ind = key, ind
            out.setdefault(comp, {})
        elif comp and val:
            out[comp].setdefault(key, val)
    return out


def section(text, section_name):
    """Component map of a top-level section, with scalar fields only, as strings."""
    try:
        import yaml
    except ImportError:
        return _section_by_lines(text, section_name)
    doc = yaml.load(text, Loader=yaml.BaseLoader) or {}
    raw = doc.get(section_name) or {}
    if not isinstance(raw, dict):
        return {}
    return {comp: {k: v for k, v in fields.items() if isinstance(v, str)}
            for comp, fields in raw.items() if isinstance(fields, dict)}


def section_from_file(path, section_name):
    with open(path) as fh:
        return section(fh.read(), section_name)


# -----------------------------------------------------------------------------
# Sources
# -----------------------------------------------------------------------------
def _cache_dir():
    return os.path.join(_work(), "offline", "release-meta")


def _container_file(name, cache_name):
    """config-vars/<name> from the olm-utils container, cached as <cache_name>."""
    cached = os.path.join(_cache_dir(), cache_name)
    container = os.environ.get("OLM_UTILS_CONTAINER") or "olm-utils-play-v4"
    try:
        res = subprocess.run(["podman", "exec", container, "cat", f"{CONFIG_VARS}/{name}"],
                             capture_output=True, text=True, timeout=60)
        text = res.stdout if res.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        text = ""
    if text.strip():
        os.makedirs(_cache_dir(), exist_ok=True)
        with open(cached, "w") as fh:
            fh.write(text)
        return text, f"{name} in {container}"
    if os.path.isfile(cached):
        with open(cached) as fh:
            return fh.read(), f"{cache_name} (cached; {container} not readable)"
    raise MetaError(f"{name} is neither readable in {container} nor cached in {_cache_dir()}")


def patch_file():
    pid = os.environ.get("PATCH_ID", "").strip()
    if not pid:
        return None
    return os.path.join(_work(), "offline", "patch", f"patch-{_version()}-{pid}.yaml")


def patch_meta():
    """(patch_components_meta, source) - empty when no PATCH_ID or no file."""
    path = patch_file()
    if not path or not os.path.isfile(path):
        return {}, None
    meta = section_from_file(path, "patch_components_meta")
    meta.pop("patch_info", None)
    return meta, os.path.basename(path)


def release_meta():
    text, src = _container_file(f"release-{_version()}.yml", f"release-{_version()}.yml")
    return section(text, "release_components_meta"), src


def meta(component, field):
    """(value, source): the patch file wins for the components it lists."""
    pm, psrc = patch_meta()
    if field in pm.get(component, {}):
        return pm[component][field], psrc
    rm, rsrc = release_meta()
    if field in rm.get(component, {}):
        return rm[component][field], rsrc
    where = f"{psrc} or {rsrc}" if psrc else rsrc
    raise MetaError(f"no {component}.{field} in {where}")


def features():
    text, src = _container_file("service_features.yml", f"service_features-{_version()}.yml")
    try:
        import yaml
        doc = yaml.load(text, Loader=yaml.BaseLoader) or {}
    except ImportError as exc:
        raise MetaError("service_features.yml needs PyYAML (run uv sync)") from exc
    return doc, src


# -----------------------------------------------------------------------------
# CASEs
# -----------------------------------------------------------------------------
def _vkey(v):
    return [int(p) if p.isdigit() else p for p in re.split(r"[.+-]", v)]


def case_root():
    return os.path.join(_work(), "offline", _version(), ".ibm-pak", "data", "cases")


def case_dir(case, component=None, case_version=None):
    """(dir, how): the CASE version the metadata names for <component>, an explicit
    version, or else the newest one downloaded."""
    base = os.path.join(case_root(), case)
    if component and not case_version:
        case_version, src = meta(component, "case_version")
        how = f"{component} case_version {case_version} from {src}"
    elif case_version:
        how = f"case version {case_version}"
    else:
        found = sorted((d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d))), key=_vkey) \
            if os.path.isdir(base) else []
        if not found:
            raise MetaError(f"no {case} CASE downloaded under {case_root()} - run 2.0.2 (case-download) first")
        case_version, how = found[-1], f"newest downloaded ({found[-1]})"
    path = os.path.join(base, case_version)
    if not os.path.isdir(path):
        raise MetaError(f"{case} {case_version} is not downloaded ({path}) - run 2.0.2 (case-download) first")
    return path, how


def case_images(path, repo=None, arch=None):
    """Rows of the CASE's *-images.csv as dicts (CRLF stripped). arch: None = image
    rows of any arch, 'all' = every row incl. manifest lists, else that arch."""
    rx = re.compile(repo) if repo else None
    rows = []
    for name in sorted(os.listdir(path)):
        if not name.endswith("-images.csv"):
            continue
        with open(os.path.join(path, name), newline="") as fh:
            for row in csv.DictReader(line.replace("\r", "") for line in fh):
                if rx and not rx.search(row.get("image_name", "")):
                    continue
                if arch != "all" and row.get("mtype") != "IMAGE":
                    continue
                if arch not in (None, "all") and row.get("arch") != arch:
                    continue
                rows.append(row)
    return rows


def case_groups(cases=None):
    """{group id: [cases]} from the groups column of the newest downloaded version of each CASE."""
    root = case_root()
    if not os.path.isdir(root):
        raise MetaError(f"no CASEs downloaded under {root} - run 2.0.2 (case-download) first")
    out = {}
    for case in cases or sorted(os.listdir(root)):
        try:
            path, _ = case_dir(case)
        except MetaError:
            continue
        for row in case_images(path, arch="all"):
            for grp in re.split(r"[ ;|]+", row.get("groups", "") or ""):
                if grp:
                    out.setdefault(grp, [])
                    if case not in out[grp]:
                        out[grp].append(case)
    return out


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("meta")
    p.add_argument("component")
    p.add_argument("field", choices=META_FIELDS)
    for name in ("case-dir", "case-images", "image-tag"):
        p = sub.add_parser(name)
        p.add_argument("case")
        p.add_argument("--component")
        p.add_argument("--case-version")
        if name != "case-dir":
            p.add_argument("--repo", required=name == "image-tag")
            p.add_argument("--arch", default=None if name == "case-images" else os.environ.get("IMAGE_ARCH") or "amd64")
    p = sub.add_parser("case-groups")
    p.add_argument("cases", nargs="*")
    p = sub.add_parser("features")
    p.add_argument("component")
    p.add_argument("field", nargs="?")
    sub.add_parser("cache")
    a = ap.parse_args(argv)

    try:
        if a.cmd == "meta":
            value, src = meta(a.component, a.field)
            _say(f"{a.component}.{a.field} = {value} (from {src})")
            print(value)
        elif a.cmd == "case-dir":
            path, how = case_dir(a.case, a.component, a.case_version)
            _say(f"{a.case}: {how}")
            print(path)
        elif a.cmd in ("case-images", "image-tag"):
            path, how = case_dir(a.case, a.component, a.case_version)
            rows = case_images(path, a.repo, a.arch)
            if not rows:
                raise MetaError(f"no {a.repo or ''} {a.arch or ''} image in {path}".replace("  ", " "))
            if a.cmd == "image-tag":
                _say(f"{a.case}: {how} -> {rows[0]['image_name']}:{rows[0]['tag']}")
                print(rows[0]["tag"])
            else:
                for r in rows:
                    print("\t".join(r.get(k, "") or "" for k in ("image_name", "tag", "digest", "arch", "groups")))
        elif a.cmd == "case-groups":
            for grp, cases in sorted(case_groups(a.cases).items()):
                print(f"{grp}\t{','.join(cases)}")
        elif a.cmd == "features":
            doc, src = features()
            entry = doc.get(a.component)
            if entry is None:
                raise MetaError(f"no {a.component} in {src}")
            value = entry.get(a.field) if a.field else entry
            if value is None:
                raise MetaError(f"no {a.component}.{a.field} in {src}")
            print(value if isinstance(value, str) else json.dumps(value, indent=2))
        elif a.cmd == "cache":
            _, src = release_meta()
            _say(f"cached {src}")
            _, src = features()
            _say(f"cached {src}")
    except (MetaError, OSError) as exc:
        print(f"[meta] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
