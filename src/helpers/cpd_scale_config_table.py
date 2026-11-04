#!/usr/bin/env python3
"""cpd_scale_config_table.py - IBM Software Hub scale-config table (level_1..level_5).

Builds, per scale-capable component, what `cpd-cli manage apply-scale-config`
sets for each level, whether install-options.yml can set it at install time
(non_olm: <chart key>.<field>), and the resources the operator reserves at that
size. Used by src/utilities/cpd-cli_utils/cpd-cli_scale_config_table.sh through
src/helpers/cpd_scale_config_helpers.sh; the shell side does the downloads
(podman, curl, skopeo), this file only reads files.

Sources (nothing is read from a cluster):
  config-vars/   global.yml, service_features.yml, release-<VERSION>.yml copied out
                 of the olm-utils image: level -> CR value (scale_config_values),
                 CR field, dependencies, whether Helm installs it (support_non_olm)
  patch file     ${CPD_CLI_WORK_PATH}/offline/patch/patch-<VERSION>-<PATCH_ID>.yaml:
                 the patched CASE versions (= chart versions)
  charts         IBM/charts repo/ibm-helm: does the CR template render the field
                 from .Values (and what happens on a re-run), operator image
  operators      each operator's per-size files (<size>.yaml, resources_<size>.yml,
                 or one file keyed by size): replicas x requests / limits summed

Subcommands (JSON on stdout unless noted):
  plan     --config-vars D [--patch F] --index F (--cpd-components CSV | --components CSV | --all)
  scan     --plan F --charts-dir D
  extract  --image-dir D --out D           unpack only the yaml/yml/j2 files of a skopeo dir: image
  sizing   --fs D                          per-size totals found in one unpacked operator
  list     charts|operators --plan F [--missing-in D]
                                           lines for the shell: <chart> <version> <url> | <digest> <ref>
  render   --plan F --sizing-dir D [--md F] [--json F] [--print] [--title T]

Totals are an upper bound: every workload in a size file is counted, including
ones only deployed when an optional feature is on. Scale files from other
releases kept in the image are skipped (highest version wins).
"""

import argparse
import glob
import hashlib
import json
import os
import re
import sys
import tarfile

import yaml

LEVELS = ("level_1", "level_2", "level_3", "level_4", "level_5")
# Size names operators use for their per-size files.
SIZE_NAMES = ("small_mincpureq", "starterset", "production", "x-small", "xsmall", "xlarge",
              "starter", "default", "medium", "large", "small")
# Folders that hold sizes for optional features (multi-cluster, edge); listed, not summed.
OPTIONAL_SOURCE_RE = re.compile(r"/(spoke|mcscheduling|edge)/")
SKIP_DIR_RE = re.compile(r"(^|/)(proc|sys|dev|usr/share|usr/lib|usr/lib64|usr/include|etc/pki|var|"
                         r"site-packages|ansible_collections|tests?|__snapshots__|node_modules)(/|$)")
NON_X86_RE = re.compile(r"/(ppc64le|s390x)(/|$)")
KEEP_EXT = (".yaml", ".yml", ".j2")
# Bump when sizing() output changes: cached operators/<digest>.json of another format are redone.
SIZING_FORMAT = 2
MAX_FILE = 3_000_000


def die(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


def read_json(path):
    with open(path) as f:
        return json.load(f)


def load_yaml(path):
    with open(path, errors="ignore") as f:
        return yaml.safe_load(f) or {}


# --------------------------------------------------------------------------- plan

def _merged_meta(config_vars, patch_file):
    g = load_yaml(os.path.join(config_vars, "global.yml")).get("global_components_meta") or {}
    f = load_yaml(os.path.join(config_vars, "service_features.yml")).get("features_component_meta") or {}
    rel = {}
    for p in sorted(glob.glob(os.path.join(config_vars, "release-*.yml"))):
        rel = load_yaml(p).get("release_components_meta") or rel   # newest file last
    ver = os.environ.get("VERSION", "")
    if ver and os.path.isfile(os.path.join(config_vars, f"release-{ver}.yml")):
        rel = load_yaml(os.path.join(config_vars, f"release-{ver}.yml")).get("release_components_meta") or {}
    pat = load_yaml(patch_file).get("patch_components_meta") or {} if patch_file else {}
    meta = {}
    for comp in set(g) | set(f):
        m = {}
        for src in (g, f, rel, pat):
            if isinstance(src.get(comp), dict):
                m.update(src[comp])
        meta[comp] = m
    return meta


def _with_deps(meta, seeds):
    out, todo = [], list(seeds)
    while todo:
        c = todo.pop(0)
        if c in out:
            continue
        out.append(c)
        todo.extend(d for d in (meta.get(c, {}).get("component_dependencies") or []) if d not in out)
    return out


def cmd_plan(a):
    meta = _merged_meta(a.config_vars, a.patch)
    scalable = [c for c, m in meta.items() if m.get("scale_config_supported")]
    if a.all:
        wanted, scope = scalable, "all scale-capable components"
    else:
        seeds = [c.strip() for c in (a.components or a.cpd_components or "").split(",") if c.strip()]
        if not seeds:
            die("No components: set CPD_COMPONENTS in cpd_vars.sh, pass --components, or use --all.")
        unknown = [c for c in seeds if c not in meta]
        if unknown:
            print(f"[WARN] Not in the olm-utils metadata (skipped): {', '.join(unknown)}", file=sys.stderr)
        if not a.components:   # the cpd_vars.sh list: add what install-components always installs
            seeds = ["cpfs", "cpd_platform", "zen"] + seeds
        wanted = [c for c in _with_deps(meta, seeds) if c in scalable]
        scope = "--components" if a.components else "CPD_COMPONENTS + dependencies"
    index = (load_yaml(a.index).get("entries") or {}) if a.index else {}
    rows = []
    for comp in sorted(wanted, key=lambda c: (c not in ("cpfs", "zen", "scheduler"), c)):
        m = meta[comp]
        vals = m.get("scale_config_values") or {}
        charts = []
        for ch in (m.get("namespacescoped_charts_list") or [comp.replace("_", "-")]):
            ents = index.get(ch) or []
            ver = str(m.get("case_version") or "")
            e = next((x for x in ents if ver and str(x.get("version", "")).split("+")[0] == ver), None)
            matched = e is not None
            e = e or (ents[0] if ents else None)
            url = ""
            if e and e.get("urls"):
                url = e["urls"][0]
                if not url.startswith("http"):
                    url = "https://raw.githubusercontent.com/IBM/charts/master/repo/ibm-helm/" + url
            charts.append({"chart": ch, "version": e.get("version") if e else None,
                           "version_matched": matched, "url": url})
        rows.append({
            "component": comp,
            "field": m.get("scale_config_field"),
            "levels": {lv: vals.get(lv) for lv in LEVELS},
            "default": vals.get("default"),
            "scale_all_instances": bool(m.get("scale_all_instances")),
            "helm": bool(m.get("support_non_olm")),
            "case_version": m.get("case_version"),
            "case_name": m.get("case_name"),
            "dependencies": [d for d in (m.get("component_dependencies") or [])],
            "charts": charts,
        })
    print(f"[INFO] Components: {len(rows)} scale-capable ({scope}): {', '.join(r['component'] for r in rows)}",
          file=sys.stderr)
    json.dump({"scope": scope, "version": os.environ.get("VERSION", ""),
               "patch_id": os.environ.get("PATCH_ID", ""), "rows": rows}, sys.stdout, indent=1)


# --------------------------------------------------------------------------- scan

def _get(d, dotted):
    for k in dotted.split("."):
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d


def _operator_ref(values, templates):
    """Operator image 'namespace/name@sha256:...' (amd64) from a chart, or None."""
    def ns_of(block):
        return (block.get("imageRegistryNamespaceOperator") or "cpopen").strip("/") if isinstance(block, dict) else "cpopen"

    for b in values.values():
        if not isinstance(b, dict):
            continue
        dg = b.get("operatorImageDigest")
        dg = dg.get("amd64") if isinstance(dg, dict) else dg
        name = (b.get("operatorImageName") or "").strip().strip("/")
        if dg and name:
            if "/" not in name:
                name = f"{ns_of(b)}/{name}"
            return f"{name}@{dg if str(dg).startswith('sha256:') else 'sha256:' + str(dg)}"
        oi = b.get("operatorImage")
        if isinstance(oi, str) and "@sha256:" in oi:
            return re.sub(r"^[^/]+\.[^/]+/", "", oi)   # drop the registry host
        op = b.get("operator") if isinstance(b.get("operator"), dict) else {}
        img = op.get("image") if isinstance(op.get("image"), dict) else {}
        if img.get("name") and img.get("digest"):
            return f"{img['name'].strip('/')}@{img['digest']}"
    # templates: .../<ns>/<name>@<digest literal | {{ .Values.x.y(.amd64) }} | sha256:{{ index .Values.x.y .Values.global.arch }}>
    for path in sorted(templates):
        if "operator" not in os.path.basename(path) or "odlm" in os.path.basename(path):
            continue
        for line in templates[path].splitlines():
            if "image" not in line:
                continue
            m = re.search(r"/([a-z0-9][a-z0-9._-]*)@(sha256:)?(\{\{[^}]*\}\}|[0-9a-f]{64})", line)
            if not m:
                continue
            name, dig = m.group(1), m.group(3)
            if dig.startswith("{{"):
                p = re.search(r"\.Values\.([A-Za-z0-9_.]+)", dig)
                v = _get(values, p.group(1)) if p else None
                v = v.get("amd64") if isinstance(v, dict) else v
                if not v:
                    continue
                dig = str(v)
            dig = dig if dig.startswith("sha256:") else "sha256:" + dig
            nsv = re.search(r"\.Values\.([A-Za-z0-9_]+)\.imageRegistryNamespaceOperator", line)
            lit = re.search(r"/(cp[a-z]+)/" + re.escape(name) + "@", line)
            ns = ns_of(values.get(nsv.group(1))) if nsv else (lit.group(1) if lit else "cpopen")
            return f"{ns}/{name}@{dig}"
    return None


def _scan_chart(chart_dir, field):
    vals = load_yaml(os.path.join(chart_dir, "values.yaml")) if os.path.isfile(os.path.join(chart_dir, "values.yaml")) else {}
    tpls = {}
    for p in glob.glob(os.path.join(chart_dir, "templates", "**", "*"), recursive=True):
        if os.path.isfile(p):
            with open(p, errors="ignore") as f:
                tpls[p] = f.read()
    res = {"operator": _operator_ref(vals, tpls), "mode": "none"}
    if not field:
        return res
    keys = [k for k, v in vals.items() if k != "global" and isinstance(v, dict)]
    fre = re.escape(field)
    # 1. template reads .Values.<key>.<field>
    for path, txt in sorted(tpls.items()):
        for k in keys + sorted(set(re.findall(r"\.Values\.([A-Za-z0-9_]+)\." + fre + r"\b", txt)) - set(keys)):
            if not re.search(r"\.Values\." + re.escape(k) + r"\." + fre + r"\b", txt) and \
               not re.search(r'hasKey\s+\.Values\.' + re.escape(k) + r'\s+"' + fre + '"', txt):
                continue
            dflt = _get(vals, f"{k}.{field}")
            inline = re.search(r"\.Values\." + re.escape(k) + r"\." + fre + r'\s*\|\s*default\s+"([^"]+)"', txt)
            if inline and not dflt:
                dflt = inline.group(1)
            keeps = bool(re.search(r"\$[A-Za-z]+\.spec\.?" + fre + r"\b|\$[A-Za-z]+\.spec\s+\"" + fre + '"'
                                   r'|hasKey \$[A-Za-z]+\.spec "' + fre + '"', txt))
            coalesce_cr_first = bool(re.search(r"coalesce\s+\$[A-Za-z]+\.spec\." + fre + r"\b", txt))
            if "operator-deployment" in os.path.basename(path):
                rerun = "only seeds the operator's first CR"
            elif coalesce_cr_first:
                rerun = "keeps the CR value when the key is absent"
            elif dflt not in (None, ""):
                rerun = f"resets to {dflt} when the key is absent"
            elif keeps:
                rerun = "keeps the CR value when the key is absent"
            else:
                rerun = "always writes the value (empty when absent)"
            res.update(mode="value", key=f"{k}.{field}", rerun=rerun, template=os.path.relpath(path, chart_dir))
            return res
    # 2. the whole values block is copied into the CR spec
    for path, txt in sorted(tpls.items()):
        m = re.search(r"\$spec\s*:=\s*omit\s+\.Values\.([A-Za-z0-9_]+)", txt)
        if m and re.search(r"\$spec\s*\|\s*toYaml", txt):
            res.update(mode="passthrough", key=f"{m.group(1)}.{field}",
                       rerun="keeps the CR value when the key is absent", template=os.path.relpath(path, chart_dir))
            return res
    # 3. fixed value in the CR template
    for path, txt in sorted(tpls.items()):
        if "-cr" not in os.path.basename(path) and "cr." not in os.path.basename(path):
            continue
        m = re.search(r"^\s*" + fre + r"\s*:\s*\"?([A-Za-z_-]+)\"?\s*$", txt, re.MULTILINE)
        if m:
            res.update(mode="hardcoded", value=m.group(1), template=os.path.relpath(path, chart_dir))
            return res
    return res


def cmd_scan(a):
    plan = read_json(a.plan)
    for r in plan["rows"]:
        r["install_options"] = {"mode": "olm" if not r["helm"] else "nochart"}
        r["operator"] = None
        found = []
        for c in r["charts"]:
            d = os.path.join(a.charts_dir, c["chart"])
            if os.path.isdir(d):
                found.append((c["chart"], _scan_chart(d, r["field"])))
        if not found:
            continue
        rank = {"value": 0, "passthrough": 1, "hardcoded": 2, "none": 3}
        found.sort(key=lambda x: rank[x[1]["mode"]])
        chart, best = found[0]
        r["operator"] = best.get("operator") or next((s["operator"] for _, s in found if s.get("operator")), None)
        if r["helm"]:
            r["install_options"] = {k: v for k, v in best.items() if k != "operator"} | {"chart": chart}
    # charts without an operator of their own (watsonx_data_premium) share the CASE's operator
    by_case = {r.get("case_name"): r["operator"] for r in plan["rows"] if r.get("operator") and r.get("case_name")}
    for r in plan["rows"]:
        if not r.get("operator") and by_case.get(r.get("case_name")):
            r["operator"] = by_case[r["case_name"]]
    json.dump(plan, sys.stdout, indent=1)


# --------------------------------------------------------------------------- extract

def cmd_extract(a):
    man = read_json(os.path.join(a.image_dir, "manifest.json"))
    os.makedirs(a.out, exist_ok=True)
    n = 0
    for layer in man.get("layers", []):
        blob = os.path.join(a.image_dir, layer["digest"].split(":", 1)[1])
        try:
            tf = tarfile.open(blob, "r:*")  # noqa: SIM115 - closed by the with below
        except (tarfile.TarError, OSError) as e:
            print(f"[WARN] {os.path.basename(blob)[:12]}: cannot read layer ({e})", file=sys.stderr)
            continue
        with tf:
            for mem in tf:
                name = mem.name.lstrip("./")
                if not mem.isfile() or mem.size > MAX_FILE or not name.endswith(KEEP_EXT):
                    continue
                if SKIP_DIR_RE.search(os.path.dirname(name)) or os.path.basename(name).startswith(".wh."):
                    continue
                try:
                    tf.extract(mem, a.out, filter="data")
                    n += 1
                except (tarfile.TarError, OSError, ValueError) as e:   # unsafe path, link, I/O
                    print(f"[WARN] {name}: not extracted ({e})", file=sys.stderr)
    print(json.dumps({"files": n}))


# --------------------------------------------------------------------------- sizing

def _cpu(v):
    s = str(v if v is not None else "").strip().strip('"')
    try:
        return float(s[:-1]) / 1000 if s.endswith("m") else float(s)
    except ValueError:
        return 0.0


_UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}


def _mem(v):
    m = re.match(r"^([0-9.]+)\s*([A-Za-z]*)$", str(v if v is not None else "").strip().strip('"'))
    return float(m.group(1)) * _UNITS.get(m.group(2), 1) / 2**30 if m else 0.0


def _int(v, dflt=1):
    try:
        return max(int(float(str(v).strip('"'))), 0)
    except (TypeError, ValueError):
        return dflt


def _load_tolerant(path):
    with open(path, errors="ignore") as f:
        txt = f.read()
    txt = re.sub(r"\{#.*?#\}", "", txt, flags=re.DOTALL)
    txt = re.sub(r"\{%.*?%\}", "", txt, flags=re.DOTALL)
    # "{{ x | default('500m', true) }}" -> 500m; any other expression -> 0
    txt = re.sub(r"\{\{[^{}]*?default\(\s*['\"]?([^'\",)]+?)['\"]?\s*[,)][^{}]*?\}\}", r"\1", txt, flags=re.DOTALL)
    txt = re.sub(r"\{\{.*?\}\}", "0", txt, flags=re.DOTALL)
    try:
        return [d for d in yaml.safe_load_all(txt) if d is not None]
    except (yaml.YAMLError, ValueError):   # a template that is not YAML once Jinja is stripped
        return None


REPLICA_KEYS = ("replicas", "replica", "replicaCount", "replica_count", "minReplicas", "min_replicas")


def _replicas(stack, prefix, parent):
    if prefix and isinstance(parent, dict):
        for suf in ("_replicas", "_replica", "_replica_count", "_min_replicas", "_minReplicas"):
            if prefix + suf in parent:
                return _int(parent[prefix + suf])
    for anc in reversed(stack):
        if isinstance(anc, dict):
            for k in REPLICA_KEYS:
                if k in anc and not isinstance(anc[k], (dict, list)):
                    return _int(anc[k])
    return 1


# Keys whose resources are runtime definitions (notebook / job environments), not deployed pods.
SKIP_KEY_RE = re.compile(r"rtdef|runtime_def", re.IGNORECASE)


def _walk(node, stack, names, out):
    """Collect [workload, replicas, cpu_req, mem_req, cpu_lim, mem_lim] for every resources block."""
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(k, str) and SKIP_KEY_RE.search(k):
                continue
            if isinstance(v, dict) and isinstance(v.get("requests"), dict):
                prefix = k[:-10] if isinstance(k, str) and k.endswith("_resources") else None
                name = prefix or (names[-1] if k == "resources" and names else str(k))
                r = _replicas(stack + [node], prefix, node)
                rq = v.get("requests") or {}
                lm = v.get("limits") if isinstance(v.get("limits"), dict) else {}
                out.append([name, r, round(r * _cpu(rq.get("cpu")), 3), round(r * _mem(rq.get("memory")), 3),
                            round(r * _cpu(lm.get("cpu")), 3), round(r * _mem(lm.get("memory")), 3)])
            elif isinstance(v, (dict, list)):
                _walk(v, stack + [node], names + [str(k)], out)
    elif isinstance(node, list):
        for x in node:
            _walk(x, stack, names, out)


def _workloads(docs, name=None):
    out = []
    for d in docs:
        _walk(d, [], [name] if name else [], out)
    return out


def sum_workloads(wls, keep=None):
    """Totals of [name, replicas, cpu_req, mem_req, cpu_lim, mem_lim] rows; keep(name) filters."""
    t = {"containers": 0, "cpu_req": 0.0, "mem_req": 0.0, "cpu_lim": 0.0, "mem_lim": 0.0}
    for name, r, cr, mr, cl, ml in wls:
        if keep and not keep(name):
            continue
        t["containers"] += r
        t["cpu_req"] += cr
        t["mem_req"] += mr
        t["cpu_lim"] += cl
        t["mem_lim"] += ml
    return {k: round(v, 2) if isinstance(v, float) else v for k, v in t.items()}


def _size_of(stem):
    """'small' / 'resources_small_mincpureq' / 'medium-config' -> (size, family) or None."""
    for s in SIZE_NAMES:   # longest / most specific names first
        if stem == s:
            return s, ""
        if stem.endswith(("_" + s, "-" + s)):
            return s, stem[: -len(s) - 1]
    for s in SIZE_NAMES:
        if stem.startswith((s + "_", s + "-")):
            return s, stem[len(s) + 1:]
    return None


_VER_SEG = r"(?:\d+(?:\.\d+){1,3}|v\d+m\d+p\d+)"


def _vtuple(path):
    vs = re.findall(r"/(" + _VER_SEG + r")(?=[/:]|$)", path)
    if not vs:
        return ()
    return tuple(int(x) for x in re.findall(r"\d+", vs[-1]))


def _norm(path):
    p = re.sub(r"^/(opt/ansible|usr/local/bin|opt/operator|opt)(?=/)", "", path)
    return re.sub(r"/" + _VER_SEG + r"(?=[/:]|$)", "/V", p)


def sizing(fs):
    groups = []   # (source, family, {size: [workload rows]})
    for dp, dns, fns in os.walk(fs):
        rel = "/" + os.path.relpath(dp, fs)
        if SKIP_DIR_RE.search(rel.lstrip("/")) or NON_X86_RE.search(rel + "/"):
            dns[:] = []
            continue
        fam = {}
        for fn in fns:
            stem, ext = os.path.splitext(fn)
            if ext == ".j2":
                stem, ext = os.path.splitext(stem)
            if ext not in (".yaml", ".yml"):
                continue
            hit = _size_of(stem)
            if hit:
                fam.setdefault(hit[1], {})[hit[0]] = os.path.join(dp, fn)
        for family, files in fam.items():
            if len(files) < 2:
                continue
            sizes = {}
            for s, p in files.items():
                docs = _load_tolerant(p)
                if docs:
                    sizes[s] = _workloads(docs)
            if any(sizes.values()):
                groups.append((rel, family, sizes))
        # single files keyed by size (small: {...} medium: {...}), at top level or one level down
        for fn in fns:
            if not fn.endswith((".yaml", ".yml")) or _size_of(os.path.splitext(fn)[0]):
                continue
            p = os.path.join(dp, fn)
            try:
                if os.path.getsize(p) > MAX_FILE:
                    continue
                with open(p, errors="ignore") as f:
                    if "requests" not in f.read():
                        continue
            except OSError:
                continue
            for d in _load_tolerant(p) or []:
                if not isinstance(d, dict):
                    continue
                for base, sub in [("", d)] + [(k, v) for k, v in d.items() if isinstance(v, dict)]:
                    ks = [k for k in sub if isinstance(k, str) and k in SIZE_NAMES and isinstance(sub[k], dict)]
                    if len(ks) >= 2:
                        sizes = {k: _workloads([sub[k]], name=base or fn) for k in ks}
                        if any(sizes.values()):
                            groups.append((f"{rel}/{fn}" + (f":{base}" if base else ""), "", sizes))
    # drop identical copies, then keep the highest version of each source
    seen, uniq = set(), []
    for src, fam, sizes in sorted(groups, key=lambda g: (-len(_vtuple(g[0])), g[0])):
        h = hashlib.md5(json.dumps(sizes, sort_keys=True).encode()).hexdigest()
        if h not in seen:
            seen.add(h)
            uniq.append((src, fam, sizes))
    best = {}
    for src, fam, sizes in uniq:
        k = (_norm(src), fam)
        if k not in best or _vtuple(src) > _vtuple(best[k][0]):
            best[k] = (src, fam, sizes)
    sources = [{"source": s + (f" [{f}]" if f else ""), "optional": bool(OPTIONAL_SOURCE_RE.search(s + "/")),
                "workloads": z} for s, f, z in sorted(best.values())]
    # Sources sharing most workload names are alternatives (e.g. openscale scale/ vs scale/wos for
    # standalone): keep the shallowest, mark the others optional so they are listed but not summed.
    kept = []
    for src in sorted(sources, key=lambda x: (x["source"].count("/"), x["source"])):
        if src["optional"]:
            continue
        names = {w[0] for wls in src["workloads"].values() for w in wls}
        for k_names, k_src in kept:
            if names and len(names & k_names) / len(names) >= 0.5:
                src["optional"] = True
                src["alternative_of"] = k_src
                break
        else:
            kept.append((names, src["source"]))
    return {"format": SIZING_FORMAT, "sources": sources}


def cmd_sizing(a):
    json.dump(sizing(a.fs), sys.stdout, indent=1)


# --------------------------------------------------------------------------- render

def _digest(ref):
    return ref.split("@sha256:")[-1] if ref and "@sha256:" in ref else None


def _fmt_num(x):
    if x == 0:
        return "0"
    if x < 1:
        return f"{x:.2f}".rstrip("0").rstrip(".")
    return f"{x:.1f}".rstrip("0").rstrip(".") if x < 10 else f"{x:.0f}"


def _cell(value, tot):
    if not value:
        return "-"
    if not tot:
        return f"{value}"
    return f"{value}: {_fmt_num(tot['cpu_req'])} CPU / {_fmt_num(tot['mem_req'])} GiB"


def _lim(value, tot):
    if not value:
        return "-"
    if not tot:
        return f"{value}"
    return f"{value}: {_fmt_num(tot['cpu_lim'])} CPU / {_fmt_num(tot['mem_lim'])} GiB"


def _status(io):
    m = io.get("mode")
    return {
        "value": ("yes", io.get("key", "")),
        "passthrough": ("yes (passthrough)", io.get("key", "")),
        "hardcoded": ("no: fixed in chart", f"({io.get('value')})"),
        "none": ("no: chart has no input", ""),
        "olm": ("no: not Helm-installed", ""),
        "nochart": ("no: chart not found", ""),
    }.get(m, ("?", ""))


# Workloads that exist only after a later action (an engine, a model) are left out of a
# component's totals: (include|exclude, regex on the workload name, what is left out).
ON_DEMAND = {
    "watsonx_data": ("exclude", r"^(presto|prestissimo|milvus|acl_manager)",
                     "Presto / Milvus engine pods (sized per engine when you add one)"),
    "watsonx_data_premium": ("exclude", r"^(presto|prestissimo|milvus|acl_manager)",
                             "Presto / Milvus engine pods (sized per engine when you add one)"),
    "watsonx_ai_ifm": ("include", r"^(wx_|portal_wx|agent_tools_api|vllm_router|watsonx_router|rediscp)",
                       "foundation models, guardrails and WDU (deployed only when requested)"),
}


# Operators whose size files cover only part of their pods (the rest is sized in operator code).
PARTIAL = {
    "watsonx_orchestrate": "partial: only containers with per-size overrides in its sizing.yaml files; "
                           "the rest are sized in operator code",
}


def _keep_fn(component):
    rule = ON_DEMAND.get(component)
    if not rule:
        return None, ""
    mode, rx, why = rule
    rc = re.compile(rx)
    return ((lambda n: bool(rc.search(n))) if mode == "include" else (lambda n: not rc.search(n))), why


def component_totals(sz, component):
    keep, why = _keep_fn(component)
    total = {}
    for src in (sz or {}).get("sources", []):
        if src["optional"]:
            continue
        for size, wls in src["workloads"].items():
            t = sum_workloads(wls, keep)
            acc = total.setdefault(size, {"containers": 0, "cpu_req": 0.0, "mem_req": 0.0, "cpu_lim": 0.0, "mem_lim": 0.0})
            for k, v in t.items():
                acc[k] = round(acc[k] + v, 2)
    return total, why


def build(plan, sizing_dir):
    rows, has_sizes = [], set()
    for r in plan["rows"]:
        dg = _digest(r.get("operator"))
        sz = None
        if dg and os.path.isfile(os.path.join(sizing_dir, f"{dg}.json")):
            sz = read_json(os.path.join(sizing_dir, f"{dg}.json"))
        total, why = component_totals(sz, r["component"])
        if total:
            has_sizes.add(r["component"])
        rows.append((r, sz, total, why))
    out = []
    for r, sz, total, why in rows:
        io = r.get("install_options") or {}
        can, key = _status(io)
        notes = []
        if sz is None:
            notes.append("operator not analysed" if r.get("operator") else "no operator image found")
        elif not total:
            subs = [d for d in r.get("dependencies", []) if d in has_sizes]
            notes.append("no size files in its operator (sizes set in templates/code"
                         + (f", or by its dependencies: {', '.join(subs)})" if subs else ")"))
        if why and total:
            notes.append("excludes " + why)
        if total and r["component"] in PARTIAL:
            notes.append(PARTIAL[r["component"]])
        missing = sorted({r["levels"][lv] for lv in LEVELS if r["levels"].get(lv) and total and r["levels"][lv] not in total})
        if missing:
            notes.append("no size file for: " + ", ".join(missing))
        out.append({
            "component": r["component"], "field": r["field"], "install_options": can, "key": key,
            "rerun": io.get("rerun", ""), "levels": r["levels"], "default": r["default"],
            "requests": {lv: (total.get(r["levels"][lv]) if r["levels"].get(lv) else None) for lv in LEVELS},
            "note": "; ".join(notes), "operator": r.get("operator"),
            "sources": [{"source": s["source"], "optional": s["optional"], "alternative_of": s.get("alternative_of")}
                        for s in (sz or {}).get("sources", [])],
        })
    return out


def to_markdown(table, plan, title):
    L = []
    L.append(f"# {title}\n")
    L.append(f"Software Hub {plan['version']}" + (f" patch {plan['patch_id']}" if plan.get("patch_id") else "")
             + f", scope: {plan['scope']}. Cells: CR value: total CPU / memory requests (replicas x requests "
               "over every workload in the operator's size file; optional workloads included, so an upper "
               "bound). Set at install time with `non_olm: <key>: <value>` in install-options.yml, or after "
               "install with `cpd-cli manage apply-scale-config`.\n")
    L.append("## Requests per level\n")
    L.append("| Component | install-options | Key | level_1 | level_2 | level_3 | level_4 | level_5 | Note |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for t in table:
        cells = [_cell(t["levels"].get(lv), t["requests"].get(lv)) for lv in LEVELS]
        key = f"`{t['key']}`" if t["key"] and t["key"][0] != "(" else t["key"]
        L.append(f"| {t['component']} | {t['install_options']} | {key} | " + " | ".join(cells) + f" | {t['note']} |")
    L.append("\n## Limits per level\n")
    L.append("| Component | level_1 | level_2 | level_3 | level_4 | level_5 |")
    L.append("|---|---|---|---|---|---|")
    for t in table:
        if any(t["requests"].values()):
            L.append(f"| {t['component']} | " + " | ".join(_lim(t["levels"].get(lv), t["requests"].get(lv)) for lv in LEVELS) + " |")
    L.append("\n## Re-running install-components\n")
    L.append("| Component | Key | When install-options has no value |")
    L.append("|---|---|---|")
    for t in table:
        if t["rerun"]:
            L.append(f"| {t['component']} | `{t['key']}` | {t['rerun']} |")
    L.append("\n## Size files used\n")
    for t in table:
        if t["sources"]:
            src = "; ".join(s["source"] + ((" (alternative copy, not summed)" if s.get("alternative_of") else
                                            " (optional feature, not summed)") if s["optional"] else "")
                            for s in t["sources"])
            L.append(f"- **{t['component']}** (`{t['operator']}`): {src}")
    return "\n".join(L) + "\n"


def to_console(table, plan, title):
    try:
        from rich.console import Console
        from rich.table import Table
    except ImportError:
        print(to_markdown(table, plan, title))
        return
    con = Console()
    tb = Table(title=f"{title} - {plan['version']}" + (f" patch {plan['patch_id']}" if plan.get("patch_id") else "")
               + f" ({plan['scope']})", show_lines=True, title_justify="left")
    for col in ("Component", "install-options key", *LEVELS, "Note"):
        tb.add_column(col, overflow="fold")
    for t in table:
        key = t["key"] if t["install_options"].startswith("yes") else f"[red]{t['install_options']}[/red] {t['key']}"
        if t["rerun"].startswith(("resets", "always")):
            key += f"\n[yellow]re-run: {t['rerun']}[/yellow]"
        cells = []
        for lv in LEVELS:
            v, tot = t["levels"].get(lv), t["requests"].get(lv)
            cells.append("-" if not v else (f"{v}\n[dim]{_fmt_num(tot['cpu_req'])} CPU / {_fmt_num(tot['mem_req'])} GiB[/dim]" if tot else v))
        tb.add_row(t["component"], key, *cells, f"[dim]{t['note']}[/dim]")
    con.print(tb)
    con.print("[dim]CPU / GiB = total requests at that size (replicas x requests, optional workloads included).[/dim]")


def cmd_render(a):
    plan = read_json(a.plan)
    table = build(plan, a.sizing_dir)
    title = a.title or "Software Hub scale-config table"
    if a.md:
        with open(a.md, "w") as f:
            f.write(to_markdown(table, plan, title))
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"version": plan["version"], "patch_id": plan.get("patch_id"), "scope": plan["scope"],
                       "components": table}, f, indent=1)
    if a.print:
        to_console(table, plan, title)


# --------------------------------------------------------------------------- list

def cmd_list(a):
    """Lines for the shell side: 'charts' -> <chart> <version> <url>; 'operators' -> <digest> <ref>."""
    plan = read_json(a.plan)
    seen = set()
    for r in plan["rows"]:
        if a.what == "charts":
            for c in r.get("charts", []):
                if c.get("url") and c["chart"] not in seen:
                    seen.add(c["chart"])
                    print(c["chart"], c["version"], c["url"])
        else:
            dg = _digest(r.get("operator"))
            if dg and dg not in seen:
                seen.add(dg)
                if a.missing_in:
                    f = os.path.join(a.missing_in, f"{dg}.json")
                    try:
                        if read_json(f).get("format") == SIZING_FORMAT:
                            continue
                    except (OSError, ValueError):
                        pass
                print(dg, r["operator"])


# --------------------------------------------------------------------------- main

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("plan")
    s.add_argument("--config-vars", required=True)
    s.add_argument("--patch")
    s.add_argument("--index")
    s.add_argument("--cpd-components", default="")
    s.add_argument("--components", default="")
    s.add_argument("--all", action="store_true")
    s.set_defaults(fn=cmd_plan)
    s = sp.add_parser("scan")
    s.add_argument("--plan", required=True)
    s.add_argument("--charts-dir", required=True)
    s.set_defaults(fn=cmd_scan)
    s = sp.add_parser("extract")
    s.add_argument("--image-dir", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_extract)
    s = sp.add_parser("sizing")
    s.add_argument("--fs", required=True)
    s.set_defaults(fn=cmd_sizing)
    s = sp.add_parser("list")
    s.add_argument("what", choices=("charts", "operators"))
    s.add_argument("--plan", required=True)
    s.add_argument("--missing-in", help="operators: only those without a current result in this dir")
    s.set_defaults(fn=cmd_list)
    s = sp.add_parser("render")
    s.add_argument("--plan", required=True)
    s.add_argument("--sizing-dir", required=True)
    s.add_argument("--md")
    s.add_argument("--json")
    s.add_argument("--print", action="store_true")
    s.add_argument("--title")
    s.set_defaults(fn=cmd_render)
    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
