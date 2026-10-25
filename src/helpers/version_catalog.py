#!/usr/bin/env python3
"""version_catalog.py - values no installed artifact carries (version_catalog.json).

    from src.helpers.version_catalog import catalog_value
    catalog_value("helm/pinned_version")          # "v3.18.4"

Paths are '/'-separated keys into version_catalog.json. When the file, or the
key, cannot be read, the legacy literal (legacy_version_resolution.py) is used
with a warning on stderr, so callers keep working as they did before.

CLI (for the zsh side, vr_catalog in version_resolver.sh):
  version_catalog.py get <path>       value on stdout (objects as JSON); exit 1 when neither source has it
  version_catalog.py legacy <path>    only the legacy literal
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, "version_catalog.json")

try:
    from . import legacy_version_resolution as legacy
except ImportError:
    sys.path.insert(0, HERE)
    import legacy_version_resolution as legacy

_MISSING = object()


def _lookup(path):
    with open(CATALOG) as fh:
        node = json.load(fh)
    for part in path.split("/"):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(path)
        node = node[part]
    return node


def catalog_value(path, default=_MISSING):
    """Catalog value at <path>; else the legacy literal; else <default> (KeyError without one)."""
    try:
        return _lookup(path)
    except (OSError, ValueError, KeyError) as exc:
        reason = f"not in {os.path.basename(CATALOG)}" if isinstance(exc, KeyError) else f"{os.path.basename(CATALOG)} unreadable ({exc})"
    try:
        value = legacy.legacy_pin(path)
    except KeyError:
        if default is _MISSING:
            raise KeyError(f"{path}: {reason}, and no legacy value") from None
        return default
    print(f"[WARN] {path}: {reason}; using the legacy value {value}", file=sys.stderr)
    return value


def main(argv):
    if len(argv) != 2 or argv[0] not in ("get", "legacy"):
        print(__doc__.split("CLI")[1], file=sys.stderr)
        return 2
    cmd, path = argv
    try:
        value = catalog_value(path) if cmd == "get" else legacy.legacy_pin(path)
    except KeyError as exc:
        print(f"[ERROR] {exc.args[0] if cmd == 'get' else f'{path}: no legacy value'}", file=sys.stderr)
        return 1
    print(value if isinstance(value, str) else json.dumps(value))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
