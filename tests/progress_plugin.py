"""pytest plugin: live progress (done/total, %, average time per test, ETA) in a status file and on stdout.

Loaded by tests/run_with_progress.py (``-p progress_plugin`` with tests/ on PYTHONPATH). It reads three
environment variables, which the runner sets:

  PROGRESS_FILE    status file to rewrite after every test (JSON, plus a one-line .txt next to it)
  PROGRESS_OFFSET  tests already done before pytest started (the runner's shell checks)
  PROGRESS_EXTRA   tests the runner adds to the total besides the collected ones
  PROGRESS_T0      unix time the whole run started (the ETA uses the average over the whole run)
"""

import json
import os
import time
from pathlib import Path

_state = {"total": 0, "done": 0, "passed": 0, "failed": 0, "skipped": 0, "failures": [], "durations": []}


def _status_path():
    p = os.environ.get("PROGRESS_FILE")
    return Path(p) if p else None


def write_status(state, current="", finished=False):
    """Writes the JSON + text status; shared with run_with_progress.py."""
    path = _status_path()
    total, done = state["total"], state["done"]
    t0 = float(os.environ.get("PROGRESS_T0", time.time()))
    elapsed = time.time() - t0
    avg = (elapsed / done) if done else 0.0
    eta = avg * max(total - done, 0) if done else None
    pct = (100.0 * done / total) if total else 100.0
    doc = {
        "total": total, "done": done, "percent": round(pct, 1),
        "passed": state["passed"], "failed": state["failed"], "skipped": state["skipped"],
        "elapsed_s": round(elapsed, 1), "avg_s_per_test": round(avg, 2),
        "eta_s": None if eta is None else round(eta, 1),
        "current": current, "finished": finished, "failures": state["failures"][-50:],
        "updated": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    line = (f"[{done}/{total} {pct:5.1f}%] pass={state['passed']} fail={state['failed']} skip={state['skipped']} "
            f"avg={avg:.2f}s ETA={'?' if eta is None else f'{eta:.0f}s'}"
            f"{' DONE' if finished else ''} {current}")
    if path:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(doc, indent=2))
        tmp.replace(path)
        path.with_suffix(".txt").write_text(line + "\n")
    return line


def pytest_collection_finish(session):
    """Runs after -k/-m deselection, so the total counts only tests that will really run."""
    _state["done"] = int(os.environ.get("PROGRESS_OFFSET", "0"))
    _state["total"] = len(session.items) + int(os.environ.get("PROGRESS_EXTRA", "0"))
    prev = os.environ.get("PROGRESS_PREV")
    if prev:
        for k, v in json.loads(prev).items():
            _state[k] = v
    write_status(_state, "collected")


_seen = {}  # nodeid -> outcome counted for it ("passed" | "skipped" | "failed")


def pytest_runtest_logreport(report):
    """Counts each test node exactly once. Subtest reports (same nodeid) only turn a pass into a fail."""
    if not (report.when == "call" or (report.when == "setup" and report.outcome != "passed")):
        return
    nid = report.nodeid
    outcome = "failed" if report.outcome not in ("passed", "skipped") else report.outcome
    if nid in _seen:
        if outcome == "failed" and _seen[nid] != "failed":
            _state[_seen[nid]] -= 1
            _state["failed"] += 1
            _state["failures"].append(nid)
            _seen[nid] = "failed"
            write_status(_state, nid)
        return
    _seen[nid] = outcome
    _state["done"] += 1
    _state[outcome] += 1
    if outcome == "failed":
        _state["failures"].append(nid)
    line = write_status(_state, nid)
    print(f"\n{line}", flush=True)


def pytest_sessionfinish(session, exitstatus):
    if os.environ.get("PROGRESS_FINAL", "1") == "1":
        write_status(_state, "pytest finished", finished=True)
