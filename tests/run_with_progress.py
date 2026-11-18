#!/usr/bin/env python3
"""Run checks and pytest with live progress: done/total, %, average seconds per test and ETA.

Every shell check and every collected pytest test counts as one test. After each one the status is
rewritten to --status (JSON) and <status>.txt (one line), and a line is printed, for example:

  [12/40  30.0%] pass=12 fail=0 skip=0 avg=0.84s ETA=24s tests/test_x.py::test_y

Usage:
  .venv/bin/python tests/run_with_progress.py --status /tmp/run/status.json \
      --check "zsh -n scripts/a.sh" --check-glob "zsh -n {}" 'scripts/install_confluent_platform/**/*.sh' \
      -- tests/test_confluent_operator_render.py -k plain

Everything after "--" goes to pytest. Exit code: 0 when every check and test passed, 1 otherwise.
Watch from elsewhere:  cat <status>.txt   (or the JSON for the failure list)
"""

import argparse
import glob
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import progress_plugin


def count_pytest(pytest_args):
    """Number of tests pytest would run (collect-only, quiet)."""
    if pytest_args is None:
        return 0
    # Verbosity flags from the caller would change the collect-only format (-qq prints "file: N"), so drop them here.
    args = [a for a in pytest_args if a not in ("-q", "-qq", "-qqq", "--quiet", "-v", "-vv", "--verbose")]
    out = subprocess.run([sys.executable, "-m", "pytest", "--collect-only", "-q", *args],
                         cwd=REPO, capture_output=True, text=True, check=False)
    n = 0
    for line in out.stdout.splitlines():
        if "::" in line and not line.startswith(" "):
            n += 1
    if n == 0 and out.returncode not in (0, 5):
        sys.exit(f"[ERROR] pytest collection failed (rc={out.returncode}):\n{out.stdout[-2000:]}{out.stderr[-2000:]}")
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--status", required=True, help="status JSON path (a .txt line file sits next to it)")
    ap.add_argument("--check", action="append", default=[], help="shell command counted as one test")
    ap.add_argument("--check-glob", nargs=2, action="append", default=[], metavar=("CMD", "GLOB"),
                    help="run CMD once per file matching GLOB ({} = file); each run is one test")
    argv = sys.argv[1:]
    pytest_args = None
    if "--" in argv:
        i = argv.index("--")
        argv, pytest_args = argv[:i], argv[i + 1:]
    args = ap.parse_args(argv)

    checks = list(args.check)
    for cmd, pattern in args.check_glob:
        for f in sorted(glob.glob(pattern, recursive=True, root_dir=REPO)):
            checks.append(cmd.replace("{}", shlex.quote(f)))

    t0 = time.time()
    os.environ["PROGRESS_FILE"] = str(Path(args.status).resolve())
    os.environ["PROGRESS_T0"] = str(t0)
    n_py = count_pytest(pytest_args)
    state = {"total": len(checks) + n_py, "done": 0, "passed": 0, "failed": 0, "skipped": 0,
             "failures": [], "durations": []}
    print(progress_plugin.write_status(state, f"starting: {len(checks)} checks + {n_py} pytest tests"), flush=True)

    for cmd in checks:
        r = subprocess.run(cmd, shell=True, cwd=REPO, capture_output=True, text=True, check=False)
        state["done"] += 1
        if r.returncode == 0:
            state["passed"] += 1
        else:
            state["failed"] += 1
            state["failures"].append(f"check: {cmd} :: {(r.stderr or r.stdout).strip()[:300]}")
        print(progress_plugin.write_status(state, f"check: {cmd}"), flush=True)

    rc = 0
    if pytest_args is not None and n_py:
        env = dict(os.environ)
        env["PYTHONPATH"] = f"{HERE}{os.pathsep}{env.get('PYTHONPATH', '')}"
        env["PROGRESS_OFFSET"] = str(state["done"])
        env["PROGRESS_EXTRA"] = str(len(checks))
        env["PROGRESS_PREV"] = json.dumps({k: state[k] for k in ("passed", "failed", "skipped", "failures")})
        rc = subprocess.run([sys.executable, "-m", "pytest", "-p", "progress_plugin", "-q", "-rf",
                             *pytest_args], cwd=REPO, env=env, check=False).returncode
        doc = json.loads(Path(args.status).read_text())
        state.update({k: doc[k] for k in ("done", "passed", "failed", "skipped", "failures")})
        state["total"] = doc["total"]
    line = progress_plugin.write_status(state, "finished", finished=True)
    print(line, flush=True)
    for f in state["failures"]:
        print(f"FAILED: {f}")
    return 0 if state["failed"] == 0 and rc in (0, 5) else 1


if __name__ == "__main__":
    sys.exit(main())
