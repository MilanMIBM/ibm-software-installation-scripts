#!/bin/zsh
# Live progress bar for tests/run_with_progress.py status files. Ctrl-C stops it.
#
#   tests/watch_progress.sh <status.json | status.txt | dir-with-status.json> [more ...] [-n SECONDS]
#   tests/watch_progress.sh "$SP/tests/final" "$SP/tests/final-r1"     # several runs at once
#
# Each target shows: [green=passed red=failed ░=left] done/total %, pass/fail, avg s/test, ETA, current test, last 5 failures.
# A target that does not exist yet shows "(not started)".
emulate -L zsh
local interval=2; local -a targets
while (( $# )); do
    case "$1" in
        -n) interval="$2"; shift 2 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) targets+=("$1"); shift ;;
    esac
done
(( ${#targets} )) || { print -u2 "usage: $0 <status.json|status.txt|dir> [...] [-n seconds]"; exit 2; }
local py="${0:A:h:h}/.venv/bin/python"; [[ -x "$py" ]] || py=python3
while :; do
    clear; date +%T
    for t in "${targets[@]}"; do
        local f="$t"
        [[ -d "$f" ]] && f="$f/status.json"
        [[ "$f" == *.txt ]] && f="${f%.txt}.json"
        "$py" - "$t" "$f" <<'PY'
import json, os, sys
name, path = os.path.basename(sys.argv[1].rstrip("/")) or sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print(f"{name:12} (not started)"); sys.exit()
try:
    j = json.load(open(path))
except Exception:
    print(f"{name:12} (updating...)"); sys.exit()
W = 40; t = max(j["total"], 1); ok, ko = j["passed"], j["failed"]
g, r = int(W * ok / t), int(W * ko / t)
e = j.get("eta_s")
eta = "?" if e is None else f"{int(e // 60)}m{int(e % 60):02d}s"
bar = f"\033[32m{'█' * g}\033[31m{'█' * r}\033[0m{'░' * max(W - g - r, 0)}"
print(f"{name:12} [{bar}] {j['done']}/{j['total']} {j['percent']:5.1f}%  pass={ok} fail={ko}  "
      f"avg {j['avg_s_per_test']}s  ETA {eta}{'  DONE' if j['finished'] else ''}")
print(f"{'':12} {str(j.get('current', ''))[-90:]}")
for x in j.get("failures", [])[-5:]:
    print(f"{'':12} \033[31mFAIL\033[0m {x[-110:]}")
PY
    done
    sleep "$interval"
done
