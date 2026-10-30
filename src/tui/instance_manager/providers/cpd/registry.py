"""S2: the zen add-on registry (configmaps labelled icpdata_addon=true, key add-ons.json).

An add-on can create instances when its details carry any of provisioning_type,
service_provider_url, provisionURL or custom_resource_kind, or a `service_provisioning`
extension names it. JSON is parsed leniently (one live cm had trailing commas); an entry
that still doesn't parse becomes a notice, never a crash.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from urllib.parse import parse_qs, urlparse

_TRAILING_COMMA = re.compile(r",(\s*[}\]])")


def lenient_json(text: str):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return json.loads(_TRAILING_COMMA.sub(r"\1", text))


@dataclass
class AddonEntry:
    addon_type: str
    configmap: str
    details: dict = field(default_factory=dict)
    versions: list[str] = field(default_factory=list)
    max_instances: int | None = None
    display: str = ""

    def d(self, key: str):
        v = self.details.get(key)
        return None if v in (None, "", "null") else v

    @property
    def provisioning_type(self) -> str | None:
        return self.d("provisioning_type")

    @property
    def cr_kind(self) -> str | None:
        return self.d("custom_resource_kind")

    @property
    def status_field(self) -> str | None:
        return self.d("custom_resource_status_field")

    @property
    def name_regex(self) -> str | None:
        return self.d("nameValidation")

    @property
    def extension_name(self) -> str | None:
        url = self.d("provisionURL") or ""
        q = parse_qs(urlparse(url.replace("#/", "/", 1)).query)
        return (q.get("extensionName") or [None])[0]

    @property
    def instance_capable(self) -> bool:
        return any(self.d(k) for k in ("provisioning_type", "service_provider_url", "provisionURL",
                                       "custom_resource_kind"))


def _int(v) -> int | None:
    try:
        return int(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


def parse_addon_cms(cms: list[dict]) -> tuple[dict[str, AddonEntry], list[str]]:
    entries: dict[str, AddonEntry] = {}
    notices: list[str] = []
    for cm in cms:
        name = (cm.get("metadata") or {}).get("name", "?")
        text = (cm.get("data") or {}).get("add-ons.json")
        if not text:
            continue
        try:
            doc = lenient_json(text)
        except json.JSONDecodeError as e:
            notices.append(f"add-on cm {name}: add-ons.json does not parse ({e.msg} at line {e.lineno})")
            continue
        for addon_type, body in (doc or {}).items():
            if not isinstance(body, dict):
                continue
            details = body.get("details") if isinstance(body.get("details"), dict) else {}
            versions = list((body.get("versions") or {}).keys()) if isinstance(body.get("versions"), dict) else []
            entry = AddonEntry(addon_type=addon_type, configmap=name, details=details, versions=versions,
                               max_instances=_int(body.get("max_instances")),
                               display=body.get("display_name") or details.get("display_name") or addon_type)
            prev = entries.get(addon_type)
            # several cms may describe one add-on (wkc): keep the one that says how to provision
            if prev is None or (entry.instance_capable and not prev.instance_capable):
                entries[addon_type] = entry
    return entries, notices


def parse_extensions(cms: list[dict]) -> tuple[dict[str, dict], dict[str, dict], list[str]]:
    """-> (service_provisioning by extension_name, service_instance_details by instance id, notices)"""
    prov: dict[str, dict] = {}
    details: dict[str, dict] = {}
    notices: list[str] = []
    for cm in cms:
        text = (cm.get("data") or {}).get("extensions")
        if not text:
            continue
        try:
            items = lenient_json(text)
        except json.JSONDecodeError:
            notices.append(f"add-on cm {(cm.get('metadata') or {}).get('name')}: extensions do not parse")
            continue
        for ext in items if isinstance(items, list) else []:
            point = ext.get("extension_point_id")
            if point == "service_provisioning" and ext.get("extension_name"):
                prov[ext["extension_name"]] = ext
            elif point == "service_instance_details" and ext.get("match_instance_id") is not None:
                details[str(ext["match_instance_id"])] = ext
    return prov, details, notices
