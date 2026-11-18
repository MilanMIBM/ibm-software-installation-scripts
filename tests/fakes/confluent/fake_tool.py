#!/usr/bin/env python3
"""Fake cluster CLI for the Confluent operator-mode tests (contract §7.2). See README.md next to this file.

Copied (or symlinked) into a temp bin/ as oc, kubectl, helm, curl, confluent, podman, skopeo and sleep; the
name it is called by decides how it behaves. Nothing here talks to a cluster or the network.
"""

import json
import os
import re
import shlex
import stat
import sys

READ_VERBS = {"get", "describe", "explain", "whoami", "version", "auth", "api-resources"}
ALWAYS_OK = {"login", "project", "whoami"}
NOT_FOUND = 'Error from server (NotFound): the server could not find the requested resource\n'


def _log(tool, argv):
    path = os.environ.get("FAKE_LOG")
    if path:
        with open(path, "a") as fh:
            fh.write(f"{tool} {' '.join(shlex.quote(a) for a in argv)}\n".rstrip() + "\n")


def _drain_stdin():
    """Read piped stdin so the writer of a pipeline never sees SIGPIPE (the content is not recorded)."""
    try:
        mode = os.fstat(0).st_mode
    except OSError:
        return
    if stat.S_ISFIFO(mode) or stat.S_ISREG(mode):
        try:
            sys.stdin.buffer.read()
        except OSError:
            pass


def _response(tool, joined):
    """First FAKE_RESPONSES entry whose tool and regex match; honours "max" (uses per entry, counted on disk)."""
    path = os.environ.get("FAKE_RESPONSES")
    if not path or not os.path.exists(path):
        return None
    with open(path) as fh:
        entries = json.load(fh)
    counts_path = path + ".counts"
    counts = {}
    if os.path.exists(counts_path):
        with open(counts_path) as fh:
            counts = json.load(fh)
    for i, entry in enumerate(entries):
        if entry.get("tool", "oc") != tool:
            continue
        if not re.search(entry.get("match", ""), joined):
            continue
        limit = entry.get("max")
        if limit is not None:
            used = counts.get(str(i), 0)
            if used >= limit:
                continue
            counts[str(i)] = used + 1
            with open(counts_path, "w") as fh:
                json.dump(counts, fh)
        return entry
    return None


def _verb(argv):
    for a in argv:
        if not a.startswith("-"):
            return a
    return ""


def main():
    tool = os.path.basename(sys.argv[0])
    argv = sys.argv[1:]
    _log(tool, argv)
    if tool == "sleep":
        return 0
    entry = _response(tool, " ".join(argv))
    if entry is not None:
        _drain_stdin()
        if "body" in entry and "-o" in argv[:-1]:   # curl -o <file>: the response body goes to the file
            with open(argv[argv.index("-o") + 1], "w") as fh:
                fh.write(entry["body"])
        sys.stdout.write(entry.get("stdout", ""))
        sys.stderr.write(entry.get("stderr", ""))
        return int(entry.get("rc", 0))

    if tool in ("oc", "kubectl"):
        verb = _verb(argv)
        if verb in ALWAYS_OK:
            return 0
        if verb in READ_VERBS:
            if os.environ.get("FAKE_OC_GET_DEFAULT", "present") == "absent" and "--ignore-not-found" not in argv:
                sys.stderr.write(NOT_FOUND)
                return 1
            return 0
        _drain_stdin()   # apply create delete patch label annotate adm secrets exec rollout wait set scale replace ...
        return 0
    if tool == "helm":
        if _verb(argv) in ("list", "ls"):
            if "json" in argv or "-ojson" in argv or "--output=json" in argv:
                sys.stdout.write("[]\n")
            return 0
        return 0
    if tool == "curl":
        return 7
    if tool in ("confluent", "podman", "skopeo"):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
