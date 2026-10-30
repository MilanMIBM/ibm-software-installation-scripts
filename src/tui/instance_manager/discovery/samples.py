"""D6 fallback samples, used only when no live source gives a type's payload shape.

Order: samples/docs/<type>.json (curated from the IBM docs page at implementation time)
-> samples/scripts/<type>.json (extracted from a 4.5_provision_*.sh) -> a user --seed.
Live sources still merge on top (storage needs, bounds, versions). Format:

  {"addon_type": "db2oltp", "source": "docs" | "script",
   "source_url" | "source_script": "...", "docs_version": "5.4.x", "retrieved": "2026-10-30",
   "payload": {<zen envelope, ${PLACEHOLDERS} allowed>},
   "fields": {"<parameter key>": {"label": .., "min": .., "max": .., "enum": [..],
                                  "description": .., "storage_need": "file|block-preferred|either"}}}
A --seed file is a bare zen envelope (what `cpd-cli service-instance create -s` takes).
"""

from __future__ import annotations

import json
from pathlib import Path

from ..model import Evidence, Field, Need, Path as FPath, Role, StorageNeed
from .observed import observe

SAMPLES = Path(__file__).resolve().parent.parent / "samples"
_SEEDS: dict[str, Path] = {}


def set_seed(addon_type: str, path: str) -> None:
    _SEEDS[addon_type] = Path(path).expanduser()


def _parameters(payload: dict) -> dict:
    ca = payload.get("create_arguments") or {}
    return ca.get("parameters") if isinstance(ca.get("parameters"), dict) else {}


def _from(doc: dict, source: str, where: str) -> dict[FPath, Field]:
    fields, _ = observe([_parameters(doc.get("payload", doc))], source=source)
    out: dict[FPath, Field] = {}
    for p, f in fields.items():
        f.path, f.payload = ("parameters",) + p, True
        f.observed = [v for v in f.observed if not (isinstance(v, str) and v.startswith("${"))]
        out[f.path] = f
    for key, spec in (doc.get("fields") or {}).items():
        f = out.setdefault(("parameters", key), Field(path=("parameters", key), payload=True, sources={source}))
        f.label = spec.get("label", f.label)
        f.description = spec.get("description", f.description)
        f.minimum, f.maximum = spec.get("min", f.minimum), spec.get("max", f.maximum)
        f.enum = spec.get("enum", f.enum)
        if spec.get("storage_need"):
            f.role = Role.STORAGE_CLASS
            f.storage = StorageNeed(Need(spec["storage_need"]), [Evidence(source, f"documented in {where}", 0.8)])
    return out


def load_sample(addon_type: str) -> dict[FPath, Field] | None:
    for kind in ("docs", "scripts"):
        path = SAMPLES / kind / f"{addon_type}.json"
        if path.is_file():
            doc = json.loads(path.read_text())
            where = doc.get("source_url") or doc.get("source_script") or path.name
            return _from(doc, "docs" if kind == "docs" else "script", where)
    seed = _SEEDS.get(addon_type)
    if seed and seed.is_file():
        return _from({"payload": json.loads(seed.read_text())}, "seed", str(seed))
    return None
