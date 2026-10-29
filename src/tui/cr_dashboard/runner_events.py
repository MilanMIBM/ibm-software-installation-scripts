"""ansible-operator introspection: what an operator pod is doing for each CR.

Per CR, ansible-operator keeps runner artifacts in the pod:
  /tmp/ansible-operator/runner/<group>/<version>/<Kind>/<ns>/<name>/artifacts/<job>/job_events/<n>-<uuid>.json
The newest job dir is the current/last run; a run is finished once it has a
playbook_on_stats event. READER_SCRIPT runs read-only inside the pod (python3 -c),
reads only the tail of each job, and prints one JSON line after MARKER.
"""

from __future__ import annotations

import json

from .model import OperatorState, parse_ts

RUNNER_ROOT = "/tmp/ansible-operator/runner"
WATCHES_FILE = "/opt/ansible/watches.yaml"
MARKER = "@@CRDASH@@"

READER_SCRIPT = r'''
import json, os, sys
M = "@@CRDASH@@"
def ev_files(d):
    try:
        names = [n for n in os.listdir(d) if n.endswith(".json")]
    except Exception:
        return []
    def num(n):
        try: return int(n.split("-", 1)[0])
        except Exception: return 0
    return sorted(names, key=num)
def load(d, n):
    try:
        with open(os.path.join(d, n)) as fh: return json.load(fh)
    except Exception: return None
def scan(art, job, tail):
    d = os.path.join(art, job, "job_events")
    files = ev_files(d)
    r = {"id": job, "events": len(files), "finished": False, "failures": None,
         "task": None, "role": None, "task_path": None, "task_start": None,
         "retry": None, "failed": None, "final": None, "first": None, "last": None}
    if not files: return r
    f0 = load(d, files[0])
    if f0: r["first"] = f0.get("created")
    for n in reversed(files[-tail:]):
        e = load(d, n)
        if not e: continue
        ev = e.get("event"); ed = e.get("event_data") or {}
        if r["last"] is None: r["last"] = e.get("created")
        if ev == "playbook_on_stats":
            r["finished"] = True
            fl = ed.get("failures") or {}
            r["failures"] = sum(v for v in fl.values() if isinstance(v, int)) if isinstance(fl, dict) else 0
        elif ev in ("playbook_on_task_start", "runner_on_start") and r["task"] is None:
            r["task"] = ed.get("task"); r["role"] = ed.get("role"); r["task_path"] = ed.get("task_path")
            r["task_start"] = e.get("created")
        elif ev == "runner_retry" and r["retry"] is None and r["task"] is None:
            res = ed.get("res") or {}
            r["retry"] = [res.get("attempts"), res.get("retries")]
        if ev in ("runner_on_ok", "runner_on_failed", "runner_on_skipped", "runner_on_unreachable") \
                and r["final"] is None:
            r["final"] = ev
        if ev == "runner_on_failed" and r["failed"] is None and not ed.get("ignore_errors"):
            res = ed.get("res") or {}
            msg = res.get("msg") or res.get("stderr") or ""
            r["failed"] = {"ts": e.get("created"), "task": ed.get("task"), "msg": str(msg)[:400],
                           "task_path": ed.get("task_path"), "ignored": bool(ed.get("ignore_errors"))}
        if r["task"] is None:
            continue
        if not r["finished"]:
            break
        if r["final"] is not None and (r["failed"] is not None or not r["failures"]):
            break
    return r
out = {}
for path in sys.argv[1:]:
    art = os.path.join(path, "artifacts")
    try:
        jobs = [j for j in os.listdir(art) if j != "latest" and os.path.isdir(os.path.join(art, j))]
    except Exception as e:
        out[path] = {"error": type(e).__name__}; continue
    jobs.sort(key=lambda j: os.path.getmtime(os.path.join(art, j)), reverse=True)
    res = {"jobs": len(jobs)}
    if jobs:
        res["newest"] = scan(art, jobs[0], 600)
        if not res["newest"]["finished"] and len(jobs) > 1:
            res["previous"] = scan(art, jobs[1], 300)
    out[path] = res
print(M + json.dumps(out))
'''

WATCHES_SCRIPT = r'''
import json, os
M = "@@CRDASH@@"
p = "/opt/ansible/watches.yaml"
print(M + json.dumps({"exists": os.path.isfile(p), "text": open(p).read() if os.path.isfile(p) else ""}))
'''


def runner_path(group: str, version: str, kind: str, namespace: str | None, name: str) -> str:
    return f"{RUNNER_ROOT}/{group}/{version}/{kind}/{namespace or ''}/{name}".replace("//", "/")


def parse_marker(stdout: str) -> dict | None:
    for line in (stdout or "").splitlines():
        if line.startswith(MARKER):
            try:
                return json.loads(line[len(MARKER):])
            except json.JSONDecodeError:
                return None
    return None


def parse_watches(text: str) -> list[tuple[str, str, str]]:
    """watches.yaml -> [(group, version, kind)]."""
    try:
        import yaml
        doc = yaml.safe_load(text) or []
    except Exception:
        return []
    out = []
    for w in doc if isinstance(doc, list) else []:
        if isinstance(w, dict) and w.get("kind") and w.get("group") is not None:
            out.append((str(w.get("group")), str(w.get("version", "")), str(w["kind"])))
    return out


def apply_runner_result(op: OperatorState, res: dict | None) -> OperatorState:
    """Fold one READER_SCRIPT result (for one CR) into an OperatorState."""
    if res is None:
        op.introspection = "error"
        return op
    if "error" in res:
        op.introspection = "ok" if res["error"] == "FileNotFoundError" else "error"
        op.job_id = None
        return op
    op.introspection = "ok"
    new = res.get("newest")
    if not new:
        return op
    op.job_id = new.get("id")
    op.job_running = not new.get("finished")
    op.job_started_at = parse_ts(new.get("first"))
    op.last_event_at = parse_ts(new.get("last"))
    op.task = new.get("task")
    op.role = new.get("role")
    op.task_started_at = parse_ts(new.get("task_start"))
    r = new.get("retry")
    op.retry = (int(r[0]), int(r[1])) if r and r[0] is not None and r[1] else None
    if op.job_running:
        op.job_failed = None
        prev = res.get("previous") or {}
        failed = prev.get("failed") if prev.get("failures") else None
    else:
        # only non-ignored failures count: some plays end on an ignored failure every run
        # (DataStage 'Synchronize global hardwarespec'), which is routine, not a failed reconcile
        op.job_failed = bool(new.get("failures"))
        failed = new.get("failed") if op.job_failed else None
        op.retry = None
    op.last_failed = ((parse_ts(failed.get("ts")), failed.get("task") or "?", failed.get("msg") or "",
                       failed.get("task_path") or "") if failed else None)
    return op
