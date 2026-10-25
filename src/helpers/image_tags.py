#!/usr/bin/env python3
"""image_tags.py - pick version tags from a registry tag listing.

Reads `skopeo list-tags` JSON ({"Tags": [...]}) or one tag per line on stdin and
prints the matching tags, oldest first, comma-separated.

  image_tags.py --pattern REGEX [--n N] [--min V] [--max-exclusive V]

  --pattern        every capture group must be a number; the groups give the
                   version that tags are ordered by, e.g. '^(\\d+)\\.(\\d+)\\.(\\d+)-ubi$'
  --n              keep only the newest N (0 = all, the default)
  --min            drop versions below V (dotted, compared group by group)
  --max-exclusive  drop versions at or above V

Exit 1 when no tag matches.
"""

import argparse
import json
import re
import sys


def _ver(text):
    return tuple(int(p) for p in text.split("."))


def select(tags, pattern, n=0, vmin=None, vmax=None):
    rx = re.compile(pattern)
    found = []
    for tag in tags:
        m = rx.match(tag)
        if not m or not m.groups():
            continue
        try:
            key = tuple(int(g) for g in m.groups())
        except (TypeError, ValueError):
            continue
        if vmin and key < _ver(vmin):
            continue
        if vmax and key >= _ver(vmax):
            continue
        found.append((key, tag))
    found.sort()
    picked = found[-n:] if n else found
    return [t for _, t in picked]


def _read_tags(text):
    text = text.strip()
    if text.startswith("{"):
        return json.loads(text).get("Tags") or []
    return [line.strip() for line in text.splitlines() if line.strip()]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--pattern", required=True)
    ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--min")
    ap.add_argument("--max-exclusive")
    a = ap.parse_args(argv)
    tags = select(_read_tags(sys.stdin.read()), a.pattern, a.n, a.min, a.max_exclusive)
    if not tags:
        return 1
    print(",".join(tags))
    return 0


if __name__ == "__main__":
    sys.exit(main())
