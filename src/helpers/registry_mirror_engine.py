"""Inventory, layout and cluster-resource engine for scripts/private_registry_mirroring/.

The zsh step scripts collect what each install needs (the per-segment `installs/<id>.sh`
hooks print JSON lines) and call this module for everything that is easier to get right
in Python: reference parsing, scope and target-path resolution, mapping files, the
oc-mirror ImageSetConfiguration, IDMS/ITMS objects, renaming oc-mirror's generated
resources, auth files and bundle checksums.

Standard library only (PyYAML is used when present, never required), so it also runs on
an air-gapped workstation without the repo's virtualenv.

Subcommands (all output paths are created as needed):
  normalize REF
  build --workspace WS --config FILE                    -> per-path targets/charts/files, ISC, report
  mapping --workspace WS --path P --phase PH [--root R]  -> oc image mirror mapping lines on stdout
  mirror-sets --workspace WS --root R --policy allow|never --out DIR [--extra PATH=SOURCE=SUBPATH]...
  catalog-resources --in DIR --out DIR --policy allow|never [--rename-defaults] [--clustercatalog]
                    [--rewrite PUSH_ROOT=PULL_ROOT]
  inspect --refs-file F [--authfile A] [--cert-dir D] [--tls-verify-false] [--sizes] [--out JSON]
  lookup --workspace WS --path P --source REF [--root R]
  authfile --out FILE [--entry HOST=USER_ENV:PASS_ENV]... [--merge FILE]...
  yaml-images                                            -> image refs found in YAML on stdin
  hauler FILE                                            -> JSON lines (images, charts) from a Hauler manifest
  bundle-manifest write|verify --dir D [--meta K=V]... [--quick]
  patch-diff [--old PATCH_YAML] --new PATCH_YAML [--components LIST]  -> changed components (TSV)
  cpd-collect --prefix TARGET [--resolve-authfile A] images-mapping.txt...  -> cpd mapping TSV
  cpd-delta --mapping TSV [--known TSV]... [--root R] [--authfile A] [--all|--check]
            [--out DELTA_TSV] [--summary JSON]           -> what still has to be copied
"""

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

MANAGED_BY = "private-registry-mirroring"

CATALOG_IMAGES = {
    "redhat-operators": "registry.redhat.io/redhat/redhat-operator-index",
    "certified-operators": "registry.redhat.io/redhat/certified-operator-index",
    "community-operators": "registry.redhat.io/redhat/community-operator-index",
    "redhat-marketplace": "registry.redhat.io/redhat/redhat-marketplace-index",
}
INDEX_TO_DEFAULT_NAME = {v.rsplit("/", 1)[1]: k for k, v in CATALOG_IMAGES.items()}


def die(msg, code=1):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(code)


def warn(msg):
    print(f"[WARN] {msg}", file=sys.stderr)


def _dur(s):
    """45s, 14m03s, 1h02m - like progress_panel_helpers.sh's ppanel_duration."""
    s = int(s)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m{s % 60:02d}s"
    return f"{s // 3600}h{s % 3600 // 60:02d}m"


class Progress:
    """'[INFO] <what>: done/total <unit> (pct%), elapsed, ~left' on stderr every
    MIRROR_PROGRESS_EVERY seconds (10); a run shorter than that prints nothing."""

    def __init__(self, what, total, unit, fmt=str):
        self.what, self.total, self.unit, self.fmt = what, total, unit, fmt
        self.every = float(os.environ.get("MIRROR_PROGRESS_EVERY") or 10)
        self.t0 = self.last = time.monotonic()

    def update(self, done, extra=""):
        now = time.monotonic()
        if now - self.last < self.every or not self.total or done >= self.total:
            return
        self.last = now
        el = now - self.t0
        left = f", ~{_dur(el * (self.total - done) / done)} left" if done else ""
        print(f"[INFO] {self.what}: {self.fmt(done)}/{self.fmt(self.total)} {self.unit} "
              f"({done * 100 // self.total}%){extra}, {_dur(el)}{left}", file=sys.stderr, flush=True)


# =============================================================================
# Image references
# =============================================================================
class Ref:
    """A container image reference split into domain / path / tag / digest."""

    __slots__ = ("domain", "path", "tag", "digest")

    def __init__(self, domain, path, tag="", digest=""):
        self.domain, self.path, self.tag, self.digest = domain, path, tag, digest

    @property
    def repo(self):
        return f"{self.domain}/{self.path}"

    def source(self):
        """Reference used as the mirroring source: by digest when known."""
        if self.digest:
            return f"{self.repo}@{self.digest}"
        return f"{self.repo}:{self.tag or 'latest'}"

    def target_tag(self):
        if self.tag:
            return self.tag
        if self.digest:
            return self.digest.replace(":", "-")   # oc-mirror's convention: sha256-<hex>
        return "latest"

    def __str__(self):
        s = self.repo
        if self.tag:
            s += f":{self.tag}"
        if self.digest:
            s += f"@{self.digest}"
        return s


def parse_ref(text):
    """Docker reference rules: the first component is a registry when it has a '.'
    or ':' or is 'localhost'; otherwise the image is on docker.io (library/ for
    single names)."""
    t = text.strip()
    for prefix in ("docker://", "oci://"):
        if t.startswith(prefix):
            t = t[len(prefix):]
    if not t:
        raise ValueError("empty image reference")
    digest = ""
    if "@" in t:
        t, digest = t.split("@", 1)
    first, _, rest = t.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        domain, remainder = first, rest
    else:
        domain, remainder = "docker.io", t
    tag = ""
    last = remainder.rsplit("/", 1)[-1]
    if ":" in last:
        remainder, tag = remainder.rsplit(":", 1)
    if domain in ("index.docker.io", "registry-1.docker.io"):
        domain = "docker.io"
    if domain == "docker.io" and "/" not in remainder:
        remainder = f"library/{remainder}"
    if not re.fullmatch(r"[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*", remainder):
        raise ValueError(f"invalid repository path in '{text}'")
    if digest and not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError(f"invalid digest in '{text}'")
    return Ref(domain.lower(), remainder, tag, digest)


# =============================================================================
# build: scope + target resolution
# =============================================================================
def _apply_override(ref, overrides):
    """overrides: {source-prefix: subpath}, e.g. {"quay.io/keycloak": "quay.io/keycloak"}.
    The longest matching prefix is replaced by its subpath; no match keeps the
    source path (registry host dropped)."""
    best, sub = "", ""
    for prefix, subpath in overrides.items():
        p = prefix.strip().rstrip("/")
        if p and (ref.repo == p or ref.repo.startswith(p + "/")) and len(p) > len(best):
            best, sub = p, subpath.strip().strip("/")
    if not best:
        return ref.path
    rest = ref.repo[len(best):].lstrip("/")
    return "/".join(x for x in (sub, rest) if x)


def _declared_shared(ref, declare):
    """A declaration is a full reference (exact match) or a repository prefix."""
    full = str(ref)
    for d in declare:
        d = d.strip()
        if not d:
            continue
        if ":" in d.rsplit("/", 1)[-1] or "@" in d:
            try:
                if str(parse_ref(d)) == full:
                    return True
            except ValueError:
                pass
            continue
        p = d.rstrip("/")
        if ref.repo == p or ref.repo.startswith(p + "/"):
            return True
    return False


def _reserved_ok(ref, rel_repo_in_path):
    first = rel_repo_in_path.split("/", 1)[0]
    if first == "cp":
        return ref.domain == "cp.icr.io" and ref.path.startswith("cp/")
    if first == "cpopen":
        return ref.domain in ("icr.io", "cp.icr.io") and ref.path.startswith("cpopen/")
    return True


def cmd_build(a):
    cfg = json.load(open(a.config))
    ws = a.workspace
    shared_path = cfg.get("shared_path", "shared")
    declare = [d for d in cfg.get("shared_declare", []) if d.strip()]
    minor = cfg.get("ocp_minor", "")
    installs = cfg.get("installs", [])
    path_of = {i["id"]: i["path"] for i in installs}
    path_of.setdefault("shared", shared_path)
    overrides_of = {i["path"]: i.get("path_overrides", {}) for i in installs}
    overrides_of.setdefault(shared_path, cfg.get("shared_path_overrides", {}))

    entries = []
    for inst in installs:
        f = inst.get("inventory", "")
        if not f or not os.path.isfile(f):
            continue
        with open(f) as fh:
            for n, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError as ex:
                    die(f"{f}:{n}: not valid JSON from the map hook ({ex})")
                e["install"] = inst["id"]
                entries.append(e)

    problems, images, charts, files, natives, operators = [], {}, {}, {}, {}, {}
    seen_sources = {}            # normalized source -> set(install ids) at install scope
    for e in entries:
        kind = e.get("kind")
        inst = e["install"]
        comp = e.get("component", "")
        if kind == "native":
            natives.setdefault(path_of[inst], []).append(e)
            continue
        if kind == "operator":
            cat = e.get("catalog", "redhat-operators")
            pkg = e.get("package", "")
            if not pkg:
                problems.append(f"{inst}: operator entry without package")
                continue
            d = operators.setdefault(cat, {}).setdefault(pkg, {"channels": set(), "default": False, "by": set()})
            ch = e.get("channel", "")
            if ch:
                d["channels"].add(ch)
            else:
                d["default"] = True
            d["by"].add(f"{inst}:{comp}" if comp else inst)
            continue
        scope = e.get("scope", "install")
        if kind == "image":
            try:
                ref = parse_ref(e["source"])
            except (KeyError, ValueError) as ex:
                problems.append(f"{inst}: {ex}")
                continue
            if scope != "shared" and _declared_shared(ref, declare):
                scope = "shared"
            path = shared_path if scope == "shared" else path_of[inst]
            rel_repo_in_path = _apply_override(ref, overrides_of.get(path, {}))
            if not _reserved_ok(ref, rel_repo_in_path):
                problems.append(f"{inst}: {ref} would land under '{path}/{rel_repo_in_path.split('/', 1)[0]}/', "
                                f"which is reserved for IBM's own layout; add a path override")
                continue
            rel_repo = f"{path}/{rel_repo_in_path}"
            key = (path, ref.repo, ref.target_tag())
            item = images.setdefault(key, {
                "path": path, "source": ref.source(), "display": str(ref), "repo": ref.repo,
                "rel_repo": rel_repo, "tag": ref.target_tag(), "components": set(), "installs": set(),
            })
            if item["source"] != ref.source():
                problems.append(f"{path}: {ref.repo}:{ref.target_tag()} requested with two different digests")
            item["components"].add(f"{inst}:{comp}" if comp else inst)
            item["installs"].add(inst)
            if scope != "shared":
                seen_sources.setdefault(str(ref), set()).add(inst)
        elif kind == "chart":
            path = shared_path if scope == "shared" else path_of[inst]
            src = e.get("source", "")
            name = e.get("chart") or src.rstrip("/").rsplit("/", 1)[-1]
            version = e.get("version", "")
            if src.startswith("oci://"):
                rel_dir = f"{path}/" + "/".join(src[len("oci://"):].split("/")[1:-1])
                rel_dir = rel_dir.rstrip("/")
                if rel_dir == path:
                    rel_dir = f"{path}/charts"
            else:
                rel_dir = f"{path}/charts"
            key = (path, name, version)
            charts.setdefault(key, {"path": path, "source": src, "chart": name, "version": version,
                                    "rel_dir": rel_dir, "components": set()})["components"].add(comp or inst)
        elif kind == "file":
            path = path_of[inst]
            url = e.get("source", "")
            dest = e.get("dest") or url.rstrip("/").rsplit("/", 1)[-1]
            files.setdefault((path, dest), {"path": path, "source": url, "dest": dest,
                                            "components": set()})["components"].add(comp or inst)
        else:
            problems.append(f"{inst}: unknown entry kind '{kind}'")

    # Collisions: two different source repos landing in the same target repo.
    by_target = {}
    for item in images.values():
        by_target.setdefault(item["rel_repo"], set()).add(item["repo"])
    for rel, repos in sorted(by_target.items()):
        if len(repos) > 1:
            problems.append(f"collision: {', '.join(sorted(repos))} all map to '{rel}' - "
                            f"add MIRROR_<ID>_PATH_OVERRIDES (source-prefix=subpath) for one of them")

    candidates = {s: ids for s, ids in seen_sources.items() if len(ids) > 1}

    # ---- write outputs ----------------------------------------------------------
    os.makedirs(os.path.join(ws, "inventory"), exist_ok=True)
    paths = sorted({p for p in path_of.values()} | {i["path"] for i in images.values()})
    for p in paths:
        pdir = os.path.join(ws, p)
        os.makedirs(pdir, exist_ok=True)
        with open(os.path.join(pdir, "targets.tsv"), "w") as out:
            for item in sorted((i for i in images.values() if i["path"] == p), key=lambda i: (i["rel_repo"], i["tag"])):
                out.write("\t".join([item["source"], f"{item['rel_repo']}:{item['tag']}", item["repo"],
                                     item["rel_repo"], ",".join(sorted(item["components"]))]) + "\n")
        with open(os.path.join(pdir, "charts.tsv"), "w") as out:
            for c in sorted((c for c in charts.values() if c["path"] == p), key=lambda c: (c["chart"], c["version"])):
                out.write("\t".join([c["source"], c["chart"], c["version"], c["rel_dir"],
                                     ",".join(sorted(c["components"]))]) + "\n")
        with open(os.path.join(pdir, "files.tsv"), "w") as out:
            for f in sorted((f for f in files.values() if f["path"] == p), key=lambda f: f["dest"]):
                out.write("\t".join([f["source"], f["dest"], ",".join(sorted(f["components"]))]) + "\n")
        with open(os.path.join(pdir, "native.jsonl"), "w") as out:
            for n in natives.get(p, []):
                out.write(json.dumps(n, sort_keys=True) + "\n")

    isc_path = os.path.join(ws, shared_path, "imageset-config.yaml")
    if operators:
        if not minor:
            die("operators are selected but the OpenShift minor version is unknown - set MIRROR_OCP_MINOR (e.g. 4.20) "
                "or log in to the cluster first")
        lines = ["kind: ImageSetConfiguration", "apiVersion: mirror.openshift.io/v2alpha1", "mirror:", "  operators:"]
        for cat in sorted(operators):
            image = CATALOG_IMAGES.get(cat)
            catalog = f"{image}:v{minor}" if image else cat
            lines += [f"  - catalog: {catalog}", "    packages:"]
            for pkg in sorted(operators[cat]):
                d = operators[cat][pkg]
                lines.append(f"    - name: {pkg}")
                if d["channels"]:
                    if d["default"]:
                        warn(f"{pkg}: some installs want its default channel, others {sorted(d['channels'])}; "
                             f"only the named channels are mirrored")
                    # oc-mirror v2 refuses to filter out the catalog's default channel unless the
                    # package names a new one (rhods-operator: catalog default stable-3.x, Software
                    # Hub 5.4.0 pins stable-2.25). With several channels the highest one wins.
                    top = max(d["channels"], key=lambda c: [int(t) if t.isdigit() else t
                                                            for t in re.split(r"(\d+)", c)])
                    lines.append(f"      defaultChannel: {top}")
                    lines.append("      channels:")
                    lines += [f"      - name: {ch}" for ch in sorted(d["channels"])]
        with open(isc_path, "w") as out:
            out.write("\n".join(lines) + "\n")
    elif os.path.exists(isc_path):
        os.remove(isc_path)

    inv = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ocp_minor": minor,
        "images": [{**{k: v for k, v in i.items() if k not in ("components", "installs")},
                    "components": sorted(i["components"]), "installs": sorted(i["installs"])}
                   for i in sorted(images.values(), key=lambda i: (i["path"], i["rel_repo"], i["tag"]))],
        "charts": [{**{k: v for k, v in c.items() if k != "components"}, "components": sorted(c["components"])}
                   for c in charts.values()],
        "files": [{**{k: v for k, v in f.items() if k != "components"}, "components": sorted(f["components"])}
                  for f in files.values()],
        "operators": {cat: {pkg: {"channels": sorted(d["channels"]), "default_channel": d["default"],
                                  "required_by": sorted(d["by"])} for pkg, d in pkgs.items()}
                      for cat, pkgs in operators.items()},
        "native": natives,
        "shared_candidates": {s: sorted(ids) for s, ids in candidates.items()},
        "problems": problems,
    }
    with open(os.path.join(ws, "inventory", "inventory.json"), "w") as out:
        json.dump(inv, out, indent=2, sort_keys=True)

    # ---- human report ------------------------------------------------------------
    rep = []
    for p in paths:
        imgs = [i for i in images.values() if i["path"] == p]
        chs = [c for c in charts.values() if c["path"] == p]
        fls = [f for f in files.values() if f["path"] == p]
        nat = natives.get(p, [])
        if not (imgs or chs or fls or nat or (p == shared_path and operators)):
            continue
        rep.append(f"== <root>/{p}")
        for n in nat:
            rep.append(f"   native  {n.get('handler', '?')}: {n.get('summary', '')}".rstrip())
        for i in sorted(imgs, key=lambda i: i["rel_repo"]):
            rep.append(f"   image   {i['display']}  ->  {i['rel_repo']}:{i['tag']}   [{', '.join(sorted(i['components']))}]")
        for c in sorted(chs, key=lambda c: c["chart"]):
            rep.append(f"   chart   {c['chart']} {c['version']}  ->  oci://<root>/{c['rel_dir']}/{c['chart']}")
        for f in sorted(fls, key=lambda f: f["dest"]):
            rep.append(f"   file    {f['source']}  ->  {p}/files/{f['dest']}")
        if p == shared_path:
            for cat in sorted(operators):
                for pkg, d in sorted(operators[cat].items()):
                    chans = ",".join(sorted(d["channels"])) or "(default channel)"
                    rep.append(f"   operator {cat}/{pkg} {chans}   [{', '.join(sorted(d['by']))}]")
    if candidates:
        rep.append("== shared candidates (mirrored separately by several installs; add to MIRROR_SHARED_DECLARE to share)")
        for s, ids in sorted(candidates.items()):
            rep.append(f"   {s}   [{', '.join(sorted(ids))}]")
    if problems:
        rep.append("== PROBLEMS")
        rep += [f"   {p}" for p in problems]
    if not rep:
        rep.append("Nothing selected - MIRROR_INSTALLS or the per-install COMPONENTS/CONTENT lists are empty.")
    report = "\n".join(rep) + "\n"
    with open(os.path.join(ws, "inventory", "report.txt"), "w") as out:
        out.write(report)
    sys.stdout.write(report)
    return 3 if problems else 0


# =============================================================================
# mapping / lookup
# =============================================================================
def _targets(ws, path):
    f = os.path.join(ws, path, "targets.tsv")
    rows = []
    if os.path.isfile(f):
        with open(f) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 4:
                    rows.append(parts)
    return rows


def cmd_mapping(a):
    for src, rel, _repo, _rel_repo, *_ in _targets(a.workspace, a.path):
        if a.phase == "mirror":
            print(f"{src}={a.root.rstrip('/')}/{rel}")
        elif a.phase == "save":
            print(f"{src}=file://{rel}")
        elif a.phase == "load":
            print(f"file://{rel}={a.root.rstrip('/')}/{rel}")
        elif a.phase == "targets":
            print(f"{a.root.rstrip('/')}/{rel}")
    return 0


def cmd_lookup(a):
    want = parse_ref(a.source)
    rows = _targets(a.workspace, a.path)
    exact = [r for r in rows if r[2] == want.repo and (r[1].rsplit(":", 1)[-1] == want.target_tag())]
    same_repo = [r for r in rows if r[2] == want.repo]
    hit = exact[0] if exact else (same_repo[0] if len(same_repo) == 1 else None)
    if not hit:
        return 1
    print(f"{a.root.rstrip('/')}/{hit[1]}" if a.root else hit[1])
    return 0


# =============================================================================
# mirror-sets: IDMS + ITMS per registry path
# =============================================================================
def _mirror_set_doc(kind, name, entries, policy, path):
    spec_key = "imageDigestMirrors" if kind == "ImageDigestMirrorSet" else "imageTagMirrors"
    lines = ["apiVersion: config.openshift.io/v1", f"kind: {kind}", "metadata:", f"  name: {name}",
             "  labels:", f"    app.kubernetes.io/managed-by: {MANAGED_BY}",
             f"    private-registry-mirroring/path: {path}", "spec:", f"  {spec_key}:"]
    for source, mirror in entries:
        lines += ["  - mirrors:", f"    - {mirror}", f"    source: {source}"]
        if policy == "never":
            lines.append("    mirrorSourcePolicy: NeverContactSource")
    return "\n".join(lines) + "\n"


def cmd_mirror_sets(a):
    os.makedirs(a.out, exist_ok=True)
    root = a.root.rstrip("/")
    extras = {}
    for x in a.extra or []:
        try:
            path, source, sub = x.split("=", 2)
        except ValueError:
            die(f"--extra must be PATH=SOURCE=SUBPATH (got '{x}')")
        extras.setdefault(path, []).append((source, f"{root}/{sub}".rstrip("/")))
    paths = sorted({d for d in os.listdir(a.workspace)
                    if os.path.isfile(os.path.join(a.workspace, d, "targets.tsv"))} | set(extras))
    written = []
    for p in paths:
        pairs = {}
        for _src, _rel, repo, rel_repo, *_ in _targets(a.workspace, p):
            pairs[repo] = f"{root}/{rel_repo}"
        entries = sorted(pairs.items()) + sorted(extras.get(p, []))
        out = os.path.join(a.out, f"mirror-{p}.yaml")
        if not entries:
            if os.path.exists(out):
                os.remove(out)
            continue
        name = f"mirror-{p}"
        with open(out, "w") as fh:
            fh.write(_mirror_set_doc("ImageDigestMirrorSet", name, entries, a.policy, p))
            fh.write("---\n")
            fh.write(_mirror_set_doc("ImageTagMirrorSet", name, entries, a.policy, p))
        written.append(out)
    for w in written:
        print(w)
    return 0


# =============================================================================
# catalog-resources: rename oc-mirror's generated objects
# =============================================================================
def _split_docs(text):
    docs, cur = [], []
    for line in text.splitlines():
        if line.strip() == "---":
            if any(x.strip() for x in cur):
                docs.append(cur)
            cur = []
        else:
            cur.append(line)
    if any(x.strip() for x in cur):
        docs.append(cur)
    return docs


def _set_name_and_labels(doc, name):
    out, in_meta, done = [], False, False
    for line in doc:
        if line.startswith("metadata:"):
            in_meta = True
            out.append(line)
            out += ["  labels:", f"    app.kubernetes.io/managed-by: {MANAGED_BY}",
                    "    private-registry-mirroring/path: shared"]
            continue
        if in_meta and not done and re.match(r"^  name:\s", line):
            out.append(f"  name: {name}")
            done = True
            continue
        if in_meta and re.match(r"^  labels:\s*$", line):
            continue   # oc-mirror sets none today; ours replaces any
        if not line.startswith(" ") and not line.startswith("metadata:"):
            in_meta = False
        out.append(line)
    return out


def cmd_catalog_resources(a):
    os.makedirs(a.out, exist_ok=True)
    for f in os.listdir(a.out):
        if f.endswith(".yaml"):
            os.remove(os.path.join(a.out, f))
    # oc-mirror writes the registry it PUSHED to; the cluster pulls through the
    # pull root (ICR: private.<region>.icr.io vs <region>.icr.io).
    rewrites = []
    for r in a.rewrite or []:
        if "=" not in r:
            die(f"--rewrite must be FROM=TO (got '{r}')")
        src, dst = r.split("=", 1)
        if src and src != dst:
            rewrites.append((src.rstrip("/") + "/", dst.rstrip("/") + "/"))
    counters, written, skipped = {}, [], []
    for fname in sorted(os.listdir(a.indir)):
        if not fname.endswith((".yaml", ".yml")):
            continue
        text = open(os.path.join(a.indir, fname)).read()
        for src, dst in rewrites:
            text = text.replace(src, dst)
        for doc in _split_docs(text):
            kind = next((l.split(":", 1)[1].strip() for l in doc if l.startswith("kind:")), "")
            if kind in ("ImageDigestMirrorSet", "ImageTagMirrorSet"):
                n = counters.get(kind, 0)
                counters[kind] = n + 1
                name = "mirror-shared-operators" + (f"-{n}" if n else "")
                doc = _set_name_and_labels(doc, name)
                if a.policy == "never":
                    out = []
                    for line in doc:
                        out.append(line)
                        if re.match(r"^    source:\s", line):
                            out.append("    mirrorSourcePolicy: NeverContactSource")
                    doc = out
                short = "idms" if kind == "ImageDigestMirrorSet" else "itms"
                target = os.path.join(a.out, f"{short}-{name}.yaml")
            elif kind == "CatalogSource":
                image = next((l.split(":", 1)[1].strip() for l in doc if re.match(r"^\s+image:\s", l)), "")
                index = image.split("@", 1)[0].rsplit(":", 1)[0].rsplit("/", 1)[-1]
                orig = next((l.split(":", 1)[1].strip() for l in doc if re.match(r"^  name:\s", l)), "catalog")
                if a.rename_defaults and index in INDEX_TO_DEFAULT_NAME:
                    name = INDEX_TO_DEFAULT_NAME[index]
                else:
                    name = "mirror-" + re.sub(r"^cs-", "", orig)
                doc = _set_name_and_labels(doc, name)
                target = os.path.join(a.out, f"catalogsource-{name}.yaml")
            elif kind == "ClusterCatalog":
                if not a.clustercatalog:
                    skipped.append(f"{fname} (ClusterCatalog, OLM v1)")
                    continue
                orig = next((l.split(":", 1)[1].strip() for l in doc if re.match(r"^  name:\s", l)), "catalog")
                name = "mirror-" + re.sub(r"^cc-", "", orig)
                doc = _set_name_and_labels(doc, name)
                target = os.path.join(a.out, f"clustercatalog-{name}.yaml")
            else:
                skipped.append(f"{fname} ({kind or 'no kind'})")
                continue
            with open(target, "w") as fh:
                fh.write("\n".join(doc) + "\n")
            written.append(target)
    for w in written:
        print(w)
    for s in skipped:
        print(f"[INFO] skipped {s}", file=sys.stderr)
    return 0


# =============================================================================
# authfile
# =============================================================================
def cmd_authfile(a):
    auths = {}
    for m in a.merge or []:
        if m and os.path.isfile(m):
            try:
                auths.update(json.load(open(m)).get("auths", {}))
            except (OSError, json.JSONDecodeError) as ex:
                die(f"cannot read auth file {m}: {ex}")
    for spec in a.entry or []:
        try:
            host, pair = spec.split("=", 1)
            uvar, pvar = pair.split(":", 1)
        except ValueError:
            die(f"--entry must be HOST=USER_ENV:PASS_ENV (got '{spec}')")
        user, pw = os.environ.get(uvar, ""), os.environ.get(pvar, "")
        if host and user and pw:
            auths[host] = {"auth": base64.b64encode(f"{user}:{pw}".encode()).decode()}
    old = os.umask(0o077)
    try:
        with open(a.out, "w") as fh:
            json.dump({"auths": auths}, fh)
    finally:
        os.umask(old)
    os.chmod(a.out, 0o600)
    print(",".join(sorted(auths)))
    return 0


# =============================================================================
# YAML helpers that work without PyYAML
# =============================================================================
IMAGE_LINE = re.compile(r"""^\s*(?:-\s+)?image:\s*["']?([^"'\s#]+)["']?\s*$""")


def cmd_yaml_images(_a):
    seen = []
    for line in sys.stdin:
        m = IMAGE_LINE.match(line)
        if m and m.group(1) not in seen and "{{" not in m.group(1):
            seen.append(m.group(1))
    for s in seen:
        print(s)
    return 0


def cmd_hauler(a):
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        die("reading a Hauler manifest needs PyYAML (use the repo's .venv)")
    for doc in yaml.safe_load_all(open(a.file)):
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind", "")
        spec = doc.get("spec") or {}
        if kind == "Images":
            for img in spec.get("images", []):
                print(json.dumps({"kind": "image", "source": img.get("name", "")}))
        elif kind == "Charts":
            for ch in spec.get("charts", []):
                repo = ch.get("repoURL", "")
                src = f"{repo.rstrip('/')}/{ch.get('name')}" if repo.startswith("oci://") else repo
                print(json.dumps({"kind": "chart", "source": src, "chart": ch.get("name", ""),
                                  "version": ch.get("version", "")}))
    return 0


# =============================================================================
# inspect: existence (and sizes) of many images, concurrently, via skopeo
# =============================================================================
LIST_TYPES = ("application/vnd.docker.distribution.manifest.list.v2+json",
              "application/vnd.oci.image.index.v1+json")


def _skopeo_raw(ref, opts):
    import subprocess  # noqa: PLC0415
    cmd = ["skopeo", "inspect", "--raw", "--retry-times", "2"] + opts + [f"docker://{ref}"]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if p.returncode != 0:
        err = (p.stderr or "").strip().splitlines()
        return None, (err[-1] if err else f"skopeo exit {p.returncode}")
    try:
        return json.loads(p.stdout), ""
    except json.JSONDecodeError:
        return None, "manifest is not JSON"


def _classify(err):
    # The message repeats the reference, whose tag may contain "401" / "403" / "404"
    # (5.4.8-4039): registry phrases first, status codes only as whole numbers.
    e = err.lower()
    if "manifest unknown" in e or "name unknown" in e or "not found" in e:
        return "MISSING"
    if "unauthorized" in e or "authentication required" in e or "denied" in e or re.search(r"(?<![\w.-])40[13](?![\w.-])", e):
        return "AUTH"
    if re.search(r"(?<![\w.-])404(?![\w.-])", e):
        return "MISSING"
    if "x509" in e or "certificate" in e or "tls" in e:
        return "TLS"
    return "NETWORK"


def _inspect_one(ref, opts, sizes):
    man, err = _skopeo_raw(ref, opts)
    if man is None:
        return {"ref": ref, "status": _classify(err), "error": err}
    out = {"ref": ref, "status": "OK"}
    if not sizes:
        return out
    blobs = {}
    try:
        repo = parse_ref(ref).repo
    except ValueError:
        return {"ref": ref, "status": "INVALID", "error": "not an image reference"}
    children = []
    if man.get("mediaType") in LIST_TYPES or "manifests" in man:
        children = [m.get("digest") for m in man.get("manifests", []) if m.get("digest")]
        out["arches"] = len(children)
    else:
        children = [None]
        out["arches"] = 1
    for d in children:
        m = man if d is None else _skopeo_raw(f"{repo}@{d}", opts)[0]
        if not m:
            continue
        for layer in (m.get("layers") or []) + ([m["config"]] if isinstance(m.get("config"), dict) else []):
            if layer.get("digest"):
                blobs[layer["digest"]] = int(layer.get("size") or 0)
    out["blobs"] = blobs
    out["bytes"] = sum(blobs.values())
    return out


def cmd_inspect(a):
    from concurrent.futures import ThreadPoolExecutor, as_completed  # noqa: PLC0415
    refs = [l.strip() for l in open(a.refs_file) if l.strip() and not l.startswith("#")]
    opts = []
    if a.authfile:
        opts += ["--authfile", a.authfile]
    if a.cert_dir:
        opts += ["--cert-dir", a.cert_dir]
    if a.tls_verify_false:
        opts += ["--tls-verify=false"]
    results = [None] * len(refs)
    progress, problems = Progress("inspect", len(refs), "image(s)"), 0
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futures = {ex.submit(_inspect_one, r, opts, a.sizes): i for i, r in enumerate(refs)}
        for n, f in enumerate(as_completed(futures), 1):
            results[futures[f]] = f.result()
            problems += results[futures[f]]["status"] != "OK"
            progress.update(n, f", {problems} problem(s)" if problems else "")
    unique, bad = {}, []
    for r in results:
        if r["status"] != "OK":
            bad.append(r)
        for dgst, size in (r.pop("blobs", None) or {}).items():
            unique[dgst] = size
    summary = {"checked": len(results), "ok": len(results) - len(bad), "problems": len(bad)}
    if a.sizes:
        summary["unique_bytes"] = sum(unique.values())
        big = [r for r in results if r.get("bytes", 0) > 40e9]
        summary["over_40gb"] = [r["ref"] for r in big]
    if a.out:
        with open(a.out, "w") as fh:
            json.dump({"summary": summary, "results": results}, fh, indent=2)
    for r in bad:
        print(f"{r['status']:<8} {r['ref']}  ({r['error'][:160]})")
    if a.sizes:
        print(f"SIZE {summary['unique_bytes']} bytes unique across {summary['ok']} images")
        for ref in summary["over_40gb"]:
            print(f"OVER40GB {ref}")
    print(f"CHECKED {summary['checked']} ok={summary['ok']} problems={summary['problems']}")
    return 1 if bad else 0


# =============================================================================
# cpd patch updates (4_update_cpd_patch): patch metadata, mapping, delta
# =============================================================================
# Mapping TSV (one line per oc image mirror mapping line of cpd-cli's mirror-images):
#   case  version  source (repo@sha256:...)  target relative to <root>/cpd (repo:tag)
# Delta TSV: the same four columns plus status (missing | moved) and the digest the
# tag points at now (moved only).
PATCH_KEYS = ("case_version", "csv_version", "cr_version", "sub_channel")


def _patch_meta(path):
    """patch_components_meta of cpd-cli's patch-<release>-<n>.yaml as {component: {key: value}};
    scalar keys only (list items such as block_upgrade_patch are skipped)."""
    meta, comp, inside = {}, None, False
    with open(path) as fh:
        for raw in fh:
            line = raw.rstrip()
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            ind = len(line) - len(line.lstrip())
            if ind == 0:
                inside, comp = text == "patch_components_meta:", None
                continue
            if not inside or text.startswith("-"):
                continue
            key, _, val = text.partition(":")
            val = val.strip().strip("'\"")
            if ind == 2:
                comp = key
                meta.setdefault(comp, {})
            elif ind == 4 and comp and val:
                meta[comp][key] = val
    meta.pop("patch_info", None)
    return meta


def cmd_patch_diff(a):
    old = _patch_meta(a.old) if a.old else {}
    new = _patch_meta(a.new)
    sel = set(filter(None, (a.components or "").split(",")))
    for comp in sorted(set(old) | set(new)):
        o, n = old.get(comp, {}), new.get(comp, {})
        changed = [k for k in PATCH_KEYS if o.get(k) != n.get(k)]
        if not changed:
            continue
        print("\t".join([comp, "selected" if comp in sel else "other",
                         o.get("case_version", "-"), n.get("case_version", "-"), ",".join(changed)]))
    return 0


def _read_tsv(path, cols):
    rows = []
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= cols and not parts[0].startswith("#"):
                rows.append(parts)
    return rows


def _split_tag(ref):
    """repo:tag -> (repo, tag); the tag is after the last ':' that follows the last '/'."""
    head, _, last = ref.rpartition("/")
    if ":" not in last:
        return ref, ""
    name, tag = last.split(":", 1)
    return f"{head}/{name}" if head else name, tag


def cmd_cpd_collect(a):
    """images-mapping.txt files (.../mirror/<case>/<version>/...) -> mapping TSV on stdout.
    Sources by tag (the CASE packages and Helm charts as OCI artifacts) are resolved
    to the digest the tag has now (--resolve-authfile), so every line is by digest."""
    from concurrent.futures import ThreadPoolExecutor  # noqa: PLC0415
    prefix = a.prefix.rstrip("/") + "/"
    rows, bad = [], 0
    for f in a.files:
        version = os.path.basename(os.path.dirname(f))
        case = os.path.basename(os.path.dirname(os.path.dirname(f)))
        with open(f) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                src, dst = line.split("=", 1)
                if not dst.startswith(prefix):
                    bad += 1
                    warn(f"{case}: unexpected mapping line skipped: {line[:160]}")
                    continue
                rows.append([case, version, src, dst[len(prefix):]])
    by_tag = sorted({r[2] for r in rows if "@sha256:" not in r[2]})
    resolved = {}
    if by_tag:
        opts = ["--authfile", a.resolve_authfile] if a.resolve_authfile else []
        progress, failed = Progress("resolve tags", len(by_tag), "source(s)"), []
        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            for n, (src, (digest, err)) in enumerate(zip(by_tag, ex.map(lambda s: _manifest_digest(s, opts), by_tag)), 1):
                if digest:
                    resolved[src] = f"{_split_tag(src)[0]}@{digest}"
                else:
                    failed.append(f"{src} ({err[:120]})")
                progress.update(n)
        for f in failed:
            warn(f"cannot resolve {f}")
        bad += len(failed)
    seen = set()
    for r in rows:
        src = r[2] if "@sha256:" in r[2] else resolved.get(r[2])
        row = (r[0], r[1], src, r[3]) if src else None
        if row and row not in seen:
            seen.add(row)
            print("\t".join(row))
    return 1 if bad else 0


def _manifest_digest(ref, opts):
    """Digest of the manifest <ref> points at (sha256 of skopeo inspect --raw's bytes)."""
    import subprocess  # noqa: PLC0415
    cmd = ["skopeo", "inspect", "--raw", "--retry-times", "2"] + opts + [f"docker://{ref}"]
    p = subprocess.run(cmd, capture_output=True, timeout=180)
    if p.returncode != 0:
        err = p.stderr.decode(errors="replace").strip().splitlines()
        return None, (err[-1] if err else f"skopeo exit {p.returncode}")
    return "sha256:" + hashlib.sha256(p.stdout).hexdigest(), ""


def cmd_cpd_delta(a):
    """Which mapping lines still have to be copied. Lines also in a --known mapping
    (a patch recorded earlier) are taken as present unless --all; the rest are probed in
    <root> (present: the tag points at the source digest; moved: at another one) or,
    without --root, counted as missing (moved when a --known mapping had the tag with
    another digest). --check: probe every line, exit 1 unless all are present."""
    from concurrent.futures import ThreadPoolExecutor, as_completed  # noqa: PLC0415
    rows = _read_tsv(a.mapping, 4)
    known, known_rel = set(), {}
    for f in a.known or []:
        if os.path.isfile(f):
            for r in _read_tsv(f, 4):
                known.add((r[2], r[3]))
                known_rel[r[3]] = r[2].split("@", 1)[1]
    # one probe per target; the first CASE that maps it owns it
    by_rel, conflicts = {}, []
    for r in rows:
        prev = by_rel.setdefault(r[3], r)
        if prev[2].split("@", 1)[1] != r[2].split("@", 1)[1]:
            conflicts.append(f"{r[3]}: {prev[0]} and {r[0]} map different digests")
    for c in conflicts:
        warn(c)
    todo = [r for rel, r in by_rel.items() if a.check or a.all or (r[2], rel) not in known]
    recorded = len(by_rel) - len(todo)
    status = {}
    opts = []
    if a.authfile:
        opts += ["--authfile", a.authfile]
    if a.cert_dir:
        opts += ["--cert-dir", a.cert_dir]
    if a.tls_verify_false:
        opts += ["--tls-verify=false"]
    errors = []
    if a.root and todo:
        root = a.root.rstrip("/")
        progress = Progress("probe", len(todo), "image(s)")
        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            futures = {ex.submit(_manifest_digest, f"{root}/{r[3]}", opts): r for r in todo}
            for n, fut in enumerate(as_completed(futures), 1):
                r = futures[fut]
                digest, err = fut.result()
                want = r[2].split("@", 1)[1]
                if digest == want:
                    status[r[3]] = ("present", "")
                elif digest:
                    status[r[3]] = ("moved", digest)
                elif _classify(err) == "MISSING":
                    status[r[3]] = ("missing", "")
                else:
                    errors.append(f"{_classify(err):<8} {root}/{r[3]}  ({err[:160]})")
                progress.update(n, f", {len(errors)} error(s)" if errors else "")
    else:
        status = {r[3]: ("moved", known_rel[r[3]]) if r[3] in known_rel else ("missing", "") for r in todo}
    for e in errors[:20]:
        print(e, file=sys.stderr)
    counts = {"desired": len(by_rel), "recorded": recorded, "probed": len(todo) if a.root else 0,
              "present": 0, "missing": 0, "moved": 0, "errors": len(errors), "conflicts": len(conflicts)}
    per_case = {}
    with open(a.out, "w") if a.out else open(os.devnull, "w") as out:
        for rel, r in by_rel.items():
            if rel not in status:   # recorded (not probed), or a probe error
                continue
            st, old = status[rel]
            counts[st] += 1
            if st != "present":
                out.write("\t".join(r[:4] + [st, old]) + "\n")
                per_case[r[0]] = per_case.get(r[0], 0) + 1
    counts["present"] += recorded
    if a.summary:
        with open(a.summary, "w") as fh:
            json.dump({"counts": counts, "per_case": per_case}, fh, indent=2, sort_keys=True)
    print(" ".join(f"{k}={v}" for k, v in counts.items()))
    if errors:
        return 2
    return 1 if a.check and (counts["missing"] or counts["moved"]) else 0


# =============================================================================
# bundle-manifest
# =============================================================================
SKIP = {"bundle-manifest.json", "SHA256SUMS"}


def _walk(root):
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            full = os.path.join(dp, f)
            rel = os.path.relpath(full, root)
            if rel not in SKIP and not os.path.islink(full):
                yield rel, full


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(4 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_bundle_manifest(a):
    root = a.dir
    gb = lambda n: f"{n / 1e9:.1f}"  # noqa: E731
    if a.action == "write":
        sums = {}
        files = sorted(_walk(root))
        total, progress = 0, Progress("checksums", sum(os.path.getsize(full) for _, full in files), "GB", gb)
        for rel, full in files:
            sums[rel] = _sha256(full)
            total += os.path.getsize(full)
            progress.update(total)
        with open(os.path.join(root, "SHA256SUMS"), "w") as fh:
            for rel, s in sorted(sums.items()):
                fh.write(f"{s}  {rel}\n")
        meta = dict(x.split("=", 1) for x in (a.meta or []) if "=" in x)
        meta.update({"created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                     "files": len(sums), "bytes": total})
        with open(os.path.join(root, "bundle-manifest.json"), "w") as fh:
            json.dump(meta, fh, indent=2, sort_keys=True)
        print(f"{len(sums)} files, {total / 1e9:.2f} GB")
        return 0
    sums_file = os.path.join(root, "SHA256SUMS")
    if not os.path.isfile(sums_file):
        die(f"{sums_file} not found - not a bundle written by 2.5_build_transfer_bundle.sh")
    expected = {}
    with open(sums_file) as fh:
        for line in fh:
            s, rel = line.rstrip("\n").split("  ", 1)
            expected[rel] = s
    bad = []
    present = [os.path.join(root, rel) for rel in expected if os.path.isfile(os.path.join(root, rel))]
    done, progress = 0, Progress("checksums", 0 if a.quick else sum(map(os.path.getsize, present)), "GB", gb)
    for rel, s in expected.items():
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            bad.append(f"missing  {rel}")
        elif not a.quick:
            if _sha256(full) != s:
                bad.append(f"changed  {rel}")
            done += os.path.getsize(full)
            progress.update(done)
    extra = sorted(set(r for r, _ in _walk(root)) - set(expected))
    for b in bad:
        print(b)
    for e in extra:
        print(f"extra    {e}")
    print(f"{len(expected)} files checked{' (sizes skipped, --quick)' if a.quick else ''}: "
          f"{len(bad)} problem(s), {len(extra)} extra")
    return 1 if bad else 0


# =============================================================================
def main(argv):
    p = argparse.ArgumentParser(prog="registry_mirror_engine.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("normalize")
    s.add_argument("ref")
    s = sub.add_parser("build")
    s.add_argument("--workspace", required=True)
    s.add_argument("--config", required=True)
    s = sub.add_parser("mapping")
    s.add_argument("--workspace", required=True)
    s.add_argument("--path", required=True)
    s.add_argument("--phase", required=True, choices=["mirror", "save", "load", "targets"])
    s.add_argument("--root", default="")
    s = sub.add_parser("mirror-sets")
    s.add_argument("--workspace", required=True)
    s.add_argument("--root", required=True)
    s.add_argument("--policy", choices=["allow", "never"], default="allow")
    s.add_argument("--out", required=True)
    s.add_argument("--extra", action="append")
    s = sub.add_parser("catalog-resources")
    s.add_argument("--in", dest="indir", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--policy", choices=["allow", "never"], default="allow")
    s.add_argument("--rename-defaults", action="store_true")
    s.add_argument("--clustercatalog", action="store_true")
    s.add_argument("--rewrite", action="append")
    s = sub.add_parser("lookup")
    s.add_argument("--workspace", required=True)
    s.add_argument("--path", required=True)
    s.add_argument("--source", required=True)
    s.add_argument("--root", default="")
    s = sub.add_parser("authfile")
    s.add_argument("--out", required=True)
    s.add_argument("--entry", action="append")
    s.add_argument("--merge", action="append")
    sub.add_parser("yaml-images")
    s = sub.add_parser("hauler")
    s.add_argument("file")
    s = sub.add_parser("inspect")
    s.add_argument("--refs-file", required=True)
    s.add_argument("--authfile", default="")
    s.add_argument("--cert-dir", default="")
    s.add_argument("--tls-verify-false", action="store_true")
    s.add_argument("--sizes", action="store_true")
    s.add_argument("--jobs", type=int, default=8)
    s.add_argument("--out", default="")
    s = sub.add_parser("patch-diff")
    s.add_argument("--old", default="")
    s.add_argument("--new", required=True)
    s.add_argument("--components", default="")
    s = sub.add_parser("cpd-collect")
    s.add_argument("--prefix", required=True)
    s.add_argument("--resolve-authfile", default="")
    s.add_argument("--jobs", type=int, default=16)
    s.add_argument("files", nargs="*")
    s = sub.add_parser("cpd-delta")
    s.add_argument("--mapping", required=True)
    s.add_argument("--known", action="append")
    s.add_argument("--root", default="")
    s.add_argument("--authfile", default="")
    s.add_argument("--cert-dir", default="")
    s.add_argument("--tls-verify-false", action="store_true")
    s.add_argument("--jobs", type=int, default=16)
    s.add_argument("--all", action="store_true")
    s.add_argument("--check", action="store_true")
    s.add_argument("--out", default="")
    s.add_argument("--summary", default="")
    s = sub.add_parser("bundle-manifest")
    s.add_argument("action", choices=["write", "verify"])
    s.add_argument("--dir", required=True)
    s.add_argument("--meta", action="append")
    s.add_argument("--quick", action="store_true")

    a = p.parse_args(argv[1:])
    if a.cmd == "normalize":
        try:
            r = parse_ref(a.ref)
        except ValueError as ex:
            die(str(ex))
        print(r)
        return 0
    return {
        "build": cmd_build, "mapping": cmd_mapping, "mirror-sets": cmd_mirror_sets,
        "catalog-resources": cmd_catalog_resources, "lookup": cmd_lookup, "authfile": cmd_authfile,
        "yaml-images": cmd_yaml_images, "hauler": cmd_hauler, "bundle-manifest": cmd_bundle_manifest,
        "inspect": cmd_inspect, "patch-diff": cmd_patch_diff, "cpd-collect": cmd_cpd_collect,
        "cpd-delta": cmd_cpd_delta,
    }[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
