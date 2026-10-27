"""Render a watsonx.data Presto engine definition (called by
5_component_specific_scripts/wxd_presto_engines/5_create_wxd_presto_engine.sh).

    python3 watsonxdata_presto_engine_render.py --template FILE [--set KEY=VALUE ...]

- Renders the Jinja2 template (format: watsonxdata_engine_jinja2_templates/
  presto_engine_template.json.j2) with the --set values. Empty values are
  dropped so the template defaults apply; "catalogs" and "tags" are split on
  commas / spaces into lists.
- Validates the result and prints one JSON object on stdout:
      api_body : the POST /lakehouse/api/v3/presto_engines body
      cr_spec  : the presto_coordinator_* / presto_worker_* (+ cr_overrides)
                 fields to merge into the WxdEngine CR spec, all strings
      summary  : one line per node role, for the log
- Exits 1 with an [ERROR] line on stderr when the template or values are bad.
"""

import argparse
import json
import re
import sys

try:
    import jinja2
except ImportError:
    print("[ERROR] jinja2 is needed to render the engine template - run `uv sync` in the repo "
          "or `pip install jinja2`.", file=sys.stderr)
    sys.exit(1)

LIST_KEYS = {"catalogs", "tags"}
# What the operator's human_to_bytes / the pod spec both accept.
MEMORY_RE = re.compile(r"^\d+(\.\d+)?[KMGT]$")
CPU_RE = re.compile(r"^\d+(\.\d+)?m?$")
MEMORY_UNITS = {"K": 1, "M": 2, "G": 3, "T": 4}
# Software has no "custom" size: the API only takes the console's standard sizes,
# with their fixed node counts (starter is single-node, so it is not offered).
API_SIZE_WORKERS = {"small": 10, "medium": 10, "large": 10}


def die(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


def parse_sets(pairs):
    values = {}
    for pair in pairs:
        key, sep, value = pair.partition("=")
        if not sep or not key:
            die(f"--set expects KEY=VALUE, got '{pair}'.")
        if value == "":
            continue
        values[key] = [v for v in re.split(r"[,\s]+", value) if v] if key in LIST_KEYS else value
    return values


def cpu_cores(value):
    return float(value[:-1]) / 1000 if value.endswith("m") else float(value)


def memory_bytes(value):
    return float(value[:-1]) * 1024 ** MEMORY_UNITS[value[-1]]


def check_node(role, node):
    res = node.get("resources") or {}
    for kind in ("requests", "limits"):
        for field, pattern, hint in (("cpu", CPU_RE, "6, 1.5 or 6000m"),
                                     ("memory", MEMORY_RE, "12G or 512M; not 12Gi")):
            value = str((res.get(kind) or {}).get(field, ""))
            if not pattern.match(value):
                die(f"{role} {kind}.{field} '{value}' is not valid ({hint}).")
    if cpu_cores(str(res["requests"]["cpu"])) > cpu_cores(str(res["limits"]["cpu"])):
        die(f"{role} CPU request {res['requests']['cpu']} is above its limit {res['limits']['cpu']}.")
    if memory_bytes(str(res["requests"]["memory"])) > memory_bytes(str(res["limits"]["memory"])):
        die(f"{role} memory request {res['requests']['memory']} is above its limit {res['limits']['memory']}.")
    xmx = str(node.get("jvm_xmx") or "")
    if xmx and not MEMORY_RE.match(xmx):
        die(f"{role} jvm_xmx '{xmx}' is not valid (e.g. 9G).")


def cr_fields(prefix, node):
    res = node["resources"]
    spec = {
        f"{prefix}_resources_requests_cpu": str(res["requests"]["cpu"]),
        f"{prefix}_resources_requests_memory": str(res["requests"]["memory"]),
        f"{prefix}_resources_limits_cpu": str(res["limits"]["cpu"]),
        f"{prefix}_resources_limits_memory": str(res["limits"]["memory"]),
    }
    if node.get("jvm_xmx"):
        spec[f"{prefix}_jvm_Xmx"] = str(node["jvm_xmx"])
    return spec


def describe(role, count, node):
    res = node["resources"]
    return (f"{role}: {count} x cpu {res['requests']['cpu']}/{res['limits']['cpu']}, "
            f"memory {res['requests']['memory']}/{res['limits']['memory']} (request/limit)"
            + (f", Xmx {node['jvm_xmx']}" if node.get("jvm_xmx") else ""))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--set", action="append", default=[], dest="sets")
    args = parser.parse_args()

    try:
        with open(args.template) as fh:
            text = fh.read()
        rendered = jinja2.Environment(keep_trailing_newline=True).from_string(text).render(**parse_sets(args.sets))
    except OSError as exc:
        die(f"Cannot read template {args.template}: {exc}")
    except jinja2.TemplateError as exc:
        die(f"Template {args.template} failed to render: {exc}")
    try:
        engine = json.loads(rendered)
    except json.JSONDecodeError as exc:
        die(f"Template {args.template} did not render valid JSON ({exc}).")

    for key in ("display_name", "coordinator", "worker"):
        if not engine.get(key):
            die(f"The rendered template has no '{key}'.")
    coordinator, worker = engine["coordinator"], engine["worker"]
    try:
        replicas = int(worker.get("replicas", 0))
    except (TypeError, ValueError):
        die(f"worker.replicas '{worker.get('replicas')}' is not a number.")
    if replicas < 1:
        die("worker.replicas must be at least 1.")
    check_node("coordinator", coordinator)
    check_node("worker", worker)

    overrides = engine.get("cr_overrides") or {}
    if not isinstance(overrides, dict):
        die("cr_overrides must be an object.")

    # The API only registers the engine, with the same body the console sends for
    # a standard size; the CR fields below then do the actual sizing.
    api_size = str(engine.get("api_size_config") or "small")
    if api_size not in API_SIZE_WORKERS:
        die(f"api_size_config '{api_size}' must be one of {', '.join(API_SIZE_WORKERS)}.")
    node_type = str(engine.get("node_type") or "bx2.4x16")
    api_body = {
        "display_name": engine["display_name"],
        "origin": "native",
        "description": engine.get("description", ""),
        "associated_catalogs": engine.get("associated_catalogs") or [],
        "tags": engine.get("tags") or [],
        "configuration": {
            "size_config": api_size,
            "coordinator": {"node_type": node_type, "quantity": 1},
            "worker": {"node_type": node_type, "quantity": API_SIZE_WORKERS[api_size]},
        },
    }
    cr_spec = {"presto_worker_replicas": str(replicas)}
    cr_spec.update(cr_fields("presto_coordinator", coordinator))
    cr_spec.update(cr_fields("presto_worker", worker))
    cr_spec.update({k: v if isinstance(v, (dict, list)) else str(v) for k, v in overrides.items()})

    print(json.dumps({
        "api_body": api_body,
        "cr_spec": cr_spec,
        "summary": [describe("coordinator", 1, coordinator), describe("worker", replicas, worker)],
    }))


if __name__ == "__main__":
    main()
