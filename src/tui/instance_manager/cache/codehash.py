"""The discovery code's hash (cache plan §2.3 "code"): when it changes, derived models are
re-derived from the cached sources with no cluster calls. UI, ops and cache code don't count."""

from __future__ import annotations

import hashlib
from functools import lru_cache
from pathlib import Path

from . import CACHE_SCHEMA

PKG = Path(__file__).resolve().parents[1]
INPUTS = ("model.py", "discovery", "storage", "providers", "subservices")


@lru_cache(maxsize=1)
def code_hash() -> str:
    h = hashlib.sha256(f"schema={CACHE_SCHEMA}".encode())
    for name in INPUTS:
        p = PKG / name
        files = sorted(p.rglob("*.py")) if p.is_dir() else [p]
        for f in files:
            h.update(str(f.relative_to(PKG)).encode())
            h.update(f.read_bytes())
    return h.hexdigest()[:16]
