"""Secrets never reach the cache (cache plan §2.6).

S4 create parameters: every non-empty string whose key matches the SECRET role rule
(discovery/roles.py SECRET_TOKENS) becomes "<redacted>". The key and the value's type stay,
so the payload shape is still learned, and such a key always gets the SECRET role, whose
values the forms and reports never show or reuse. The provider redacts right after the
cpd-cli call, so a run with and without the cache sees the same values.
"""

from __future__ import annotations

import re

from ..discovery.roles import SECRET_TOKENS

REDACTED = "<redacted>"
_SECRET_KEY = re.compile(SECRET_TOKENS)


def secret_key(key: str) -> bool:
    return bool(_SECRET_KEY.search(str(key).lower()))


def redact(obj, under_secret: bool = False):
    """A copy of obj with secret string values replaced (recursively)."""
    if isinstance(obj, dict):
        return {k: redact(v, under_secret or secret_key(k)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(v, under_secret) for v in obj]
    if under_secret and isinstance(obj, str) and obj != "":
        return REDACTED
    return obj
