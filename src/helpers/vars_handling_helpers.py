"""Helpers the *_vars_generation.py notebooks share for turning widget values into vars-file values.

Plain functions with no marimo imports (imported in each notebook's app.setup block), so the
notebooks stay small and type checkers can see what each one returns. Rows are sortable_kv
rows: {"key": str, "value": str} dicts.
"""

import base64
import json
import urllib.request
import uuid
from typing import Sequence


# ------------------------------------------------------------------------------
# Key/value rows
# ------------------------------------------------------------------------------


def records_to_dict(records: Sequence[dict]) -> dict[str, str]:
    """``{key: value}`` from a sortable_kv widget's rows (``widget.value.get("value")``)."""
    return {r["key"]: r["value"] for r in records}


def without_keys(records, keys):
    # Keys set by a dedicated widget are dropped from the editable key/value lists
    return [r for r in records if r["key"] not in keys]


def dict_to_records(values):
    return [{"key": k, "value": v} for k, v in values.items()]


def kv_value(kv_widget):
    return records_to_dict(kv_widget.value.get("value"))


def ordered_values(default_records, kv_widget=None, overrides=None):
    # Keeps the defaults' order: widget overrides win, then the edited key/value list
    edited = kv_value(kv_widget) if kv_widget is not None else {}
    overrides = overrides or {}
    return {
        r["key"]: overrides.get(r["key"], edited.get(r["key"], r["value"]))
        for r in default_records
    }


def bool_str(value):
    return "true" if value else "false"


# ------------------------------------------------------------------------------
# Kubernetes quantities (Concert sizing checks)
# ------------------------------------------------------------------------------


def quantity_cpu(value):
    # Kubernetes CPU quantity ("4", "250m") -> cores; unparsable -> 0
    v = str(value or "").strip()
    try:
        return float(v[:-1]) / 1000 if v.endswith("m") else float(v)
    except ValueError:
        return 0.0


def quantity_gi(value):
    # Kubernetes memory/storage quantity ("12Gi", "512Mi", "1Ti") -> Gi; unparsable -> 0
    v = str(value or "").strip()
    for suffix, factor in (
        ("Ti", 1024),
        ("Gi", 1),
        ("Mi", 1 / 1024),
        ("Ki", 1 / 1024**2),
    ):
        if v.endswith(suffix):
            try:
                return float(v[: -len(suffix)]) * factor
            except ValueError:
                return 0.0
    try:
        return float(v) / 1024**3
    except ValueError:
        return 0.0


# ------------------------------------------------------------------------------
# Generated and looked-up defaults
# ------------------------------------------------------------------------------


def generate_cluster_id():
    # KRaft cluster id: base64url-encoded 16-byte UUID, 22 chars of [A-Za-z0-9_-]
    return base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip("=")


def fetch_live_releases(fallback, excludes):
    # On-prem releases with an x86 archive, newest first; offline -> fallback
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/IBM/Concert/releases?per_page=30",
            headers={"Accept": "application/vnd.github+json"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            releases = json.load(resp)
    except Exception:
        return fallback
    live = []
    for rel in releases:
        name = rel.get("name") or rel.get("tag_name", "")
        if rel.get("draft") or any(x.lower() in name.lower() for x in excludes):
            continue
        assets = {a.get("name") for a in rel.get("assets", [])}
        if "ibm-concert-x86.tar.gz" not in assets:
            continue
        tag = rel["tag_name"]
        live.append(
            {
                "release_name": f"{name} ({rel.get('published_at', '')[:10]})",
                "CONCERT_VERSION": tag.lstrip("v"),
                "CONCERT_RELEASE_TAG": tag,
                "CONCERT_ARCHIVE": "ibm-concert-x86.tar.gz",
            }
        )
    return live or fallback
