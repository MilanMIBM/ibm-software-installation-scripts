#!/usr/bin/env python3
"""Detect and repair empty OpenResty *_by_lua_block directives in ConfigMaps.

Some operators (seen with watsonx Orchestrate 8.0.2, wo-uiproxy) render nginx
configs containing `access_by_lua_block '';`. OpenResty refuses to start on it
("has no opening {"), and also on an empty `{}` block ("no runnable Lua code"),
so the proxy pod crash-loops. The intended no-op is `access_by_lua_block { return }`.

This script scans every ConfigMap in the given namespaces for that pattern,
rewrites it, and deletes the controller-owned pods that mount the ConfigMap so
they pick up the fixed file (subPath mounts never refresh in place). It also
reports crash-looping pods whose logs show a Lua-block parse error that the
scan did not repair.

Only stdlib + the `oc` CLI are used, so the same file runs locally and inside
the in-cluster watcher (openshift/cli image, which has python3 but no jq).
"""
import argparse
import json
import re
import subprocess
import sys
import time

# Directive followed by an empty Lua body: '' / "" / {} (optionally ending in ';').
BROKEN = re.compile(
    r"\b((?:access|rewrite|header_filter|body_filter|log)_by_lua_block)\s*(?:''|\"\"|\{\s*\})\s*;?"
)
FIXED = r"\1 { return }"
LOG_ERRORS = ("_by_lua_block\" has no opening", "no runnable Lua code")


def log(level, msg):
    print(f"[{level}] {msg}", flush=True)


def oc(*args, check=True):
    res = subprocess.run(["oc", *args], capture_output=True, text=True)
    if check and res.returncode != 0:
        raise RuntimeError(f"oc {' '.join(args)}: {res.stderr.strip()}")
    return res


def oc_json(*args):
    return json.loads(oc(*args, "-o", "json").stdout)


def pod_configmaps(pod):
    names = set()
    for vol in pod["spec"].get("volumes", []):
        if "configMap" in vol:
            names.add(vol["configMap"]["name"])
        for src in vol.get("projected", {}).get("sources", []):
            if "configMap" in src:
                names.add(src["configMap"]["name"])
    return names


def is_crashing(pod):
    for cs in pod.get("status", {}).get("containerStatuses", []):
        waiting = cs.get("state", {}).get("waiting", {}).get("reason")
        if waiting in ("CrashLoopBackOff", "Error") or cs.get("lastState", {}).get("terminated"):
            if not cs.get("ready"):
                return True
    return False


def restart_pods(ns, pods, preview):
    for pod in pods:
        name = pod["metadata"]["name"]
        if not pod["metadata"].get("ownerReferences"):
            log("WARN", f"{ns}/{name} has no controller; not deleting it, restart it manually")
        elif preview:
            log("PREVIEW", f"would delete pod {ns}/{name}")
        else:
            oc("-n", ns, "delete", "pod", name, "--wait=false")
            log("OK", f"deleted pod {ns}/{name}")


def scan_namespace(ns, preview):
    """Returns the number of problems found (fixed or not)."""
    problems = 0
    cms = oc_json("-n", ns, "get", "configmaps")["items"]
    pods = oc_json("-n", ns, "get", "pods")["items"]
    fixed_cms = set()

    for cm in cms:
        name = cm["metadata"]["name"]
        broken_keys = {k: v for k, v in (cm.get("data") or {}).items() if BROKEN.search(v)}
        if not broken_keys:
            continue
        problems += 1
        for key, value in broken_keys.items():
            for m in BROKEN.finditer(value):
                line = value.count("\n", 0, m.start()) + 1
                log("FOUND", f"{ns}/configmap/{name} [{key}:{line}] {m.group(0).strip()}")
        if preview:
            log("PREVIEW", f"would rewrite to '<directive> {{ return }}' in configmap {ns}/{name}")
        else:
            patch = {"data": {k: BROKEN.sub(FIXED, v) for k, v in broken_keys.items()}}
            oc("-n", ns, "patch", "configmap", name, "--type=merge", "-p", json.dumps(patch))
            log("OK", f"patched configmap {ns}/{name}")
        fixed_cms.add(name)

    if fixed_cms:
        consumers = [p for p in pods if pod_configmaps(p) & fixed_cms]
        restart_pods(ns, consumers, preview)

    # Crash-looping pods with a Lua-block parse error that the scan didn't cover.
    for pod in pods:
        name = pod["metadata"]["name"]
        if not is_crashing(pod) or pod_configmaps(pod) & fixed_cms:
            continue
        for cs in pod["status"].get("containerStatuses", []):
            out = oc("-n", ns, "logs", name, "-c", cs["name"], "--previous", "--tail=50", check=False).stdout
            if any(e in out for e in LOG_ERRORS):
                problems += 1
                err = next(l for l in out.splitlines() if any(e in l for e in LOG_ERRORS))
                log("WARN", f"{ns}/{name} [{cs['name']}] has an unrecognised Lua-block error, not auto-fixed: {err.strip()}")
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--namespace", action="append", required=True, help="namespace to scan (repeatable)")
    ap.add_argument("--preview", action="store_true", help="report only, change nothing")
    ap.add_argument("--loop", type=int, default=0, metavar="SECONDS", help="re-scan forever at this interval (watcher mode)")
    args = ap.parse_args()

    while True:
        found = 0
        for ns in args.namespace:
            try:
                found += scan_namespace(ns, args.preview)
            except RuntimeError as e:
                log("ERROR", str(e))
        if not args.loop:
            if not found:
                log("OK", f"no empty *_by_lua_block directives in: {', '.join(args.namespace)}")
            return 0
        time.sleep(args.loop)


if __name__ == "__main__":
    sys.exit(main())
