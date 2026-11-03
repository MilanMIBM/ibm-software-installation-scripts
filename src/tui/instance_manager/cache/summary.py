"""cpd_vars summary (cache plan §2.9, decisions C-D2 + F1): what a cache was built against.

An allowlist of the cpd_vars keys that change discovery, never a denylist: passwords, keys and
login commands (OCP_PASSWORD, IBM_ENTITLEMENT_KEY, OC_LOGIN, CPD_APIKEY, ...) are never read.
Plus:
  - the configured patch level ${VERSION}${PATCH_ID:+.${PATCH_ID}} (5.4.0.8; 5.4.0 without PATCH_ID)
  - install-options.yml as hashes only: the whole file + one sha256 per `non_olm` component
    section (the file may hold passwords; only hashes and component names are stored)
  - the cluster patch level (probe.py): Ibmcpd spec.version + the operator Deployment image digests
  - the storage flags in effect (--file-sc / --block-sc / --sc-kind)
diff() names every changed key with the parts it invalidates; the manager rebuilds those.
"""

from __future__ import annotations

import hashlib
import os
import time
from dataclasses import dataclass, field
from pathlib import Path

import yaml

# key -> (where it comes from, the groups of parts a change invalidates)
ALLOWLIST: dict[str, tuple[str, tuple[str, ...]]] = {
    "OCP_URL": ("cpd_vars.sh", ("scope",)),
    "PROJECT_CPD_INST_OPERANDS": ("cpd_vars.sh", ("scope",)),
    "PROJECT_CPD_INST_OPERATORS": ("cpd_vars.sh", ("wxd",)),
    "VERSION": ("cpd_vars.sh", ("catalog",)),
    "PATCH_ID": ("cpd_vars.sh", ("catalog",)),
    "INSTALL_OPTIONS": ("cpd_vars.sh", ("catalog",)),
    "INSTALL_OPTIONS_FILE": ("cpd_vars.sh", ("catalog",)),
    "CPD_COMPONENTS": ("cpd_vars.sh", ("catalog",)),
    "STG_CLASS_FILE": ("cpd_vars.sh", ("storage",)),
    "STG_CLASS_BLOCK": ("cpd_vars.sh", ("storage",)),
    "CPD_URL": ("cpd_instance_details.sh", ("zen_ext",)),
    "CPD_USERNAME": ("cpd_instance_details.sh", ("zen_ext",)),
    "CPD_PROFILE_NAME": ("env", ("zen_ext",)),
}
# what each group rebuilds, for the diff lines
GROUP_WORDS = {"scope": "everything (another cache scope)", "catalog": "catalog + every model + zen forms",
               "storage": "storage classes + every model's storage needs", "zen_ext": "zen forms + wxd API spec",
               "wxd": "watsonx.data operator facts"}


def patch_level(version: str | None, patch_id: str | None) -> str | None:
    if not version:
        return None
    return f"{version}.{patch_id}" if patch_id else version


def install_options(env: dict[str, str], config_dir: Path) -> dict | None:
    """Hashes of install-options.yml: whole file + per non_olm component. Values are never kept."""
    if (env.get("INSTALL_OPTIONS") or "").strip().lower() not in ("true", "1", "yes", "on"):
        return None
    name = env.get("INSTALL_OPTIONS_FILE") or "install-options.yml"
    path = Path(name) if Path(name).is_absolute() else config_dir / name
    try:
        raw = path.read_bytes()
    except OSError:
        return {"file": name, "sha256": None, "components": {}}
    comps: dict[str, str] = {}
    try:
        for doc in yaml.safe_load_all(raw):
            if not isinstance(doc, dict):
                continue
            for top, body in doc.items():
                if isinstance(body, dict):
                    for comp, section in body.items():
                        text = yaml.safe_dump(section, sort_keys=True)
                        comps[f"{comp}" if top == "non_olm" else f"{top}.{comp}"] = \
                            hashlib.sha256(text.encode()).hexdigest()[:16]
    except yaml.YAMLError:
        comps = {"<unparsable>": hashlib.sha256(raw).hexdigest()[:16]}
    return {"file": name, "sha256": hashlib.sha256(raw).hexdigest()[:16], "components": comps}


def current(env: dict[str, str] | None = None, config_dir: Path | None = None, storage_flags: dict | None = None,
            cluster_patch: dict | None = None) -> dict:
    from ..settings import config_dir as default_config_dir
    env = dict(os.environ) if env is None else env
    values = {k: {"value": env.get(k), "source": src} for k, (src, _) in ALLOWLIST.items()}
    return {"recorded_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "values": values,
            "patch_level": patch_level(env.get("VERSION"), env.get("PATCH_ID")),
            "install_options": install_options(env, config_dir or default_config_dir()),
            "storage_flags": storage_flags or {}, "cluster_patch": cluster_patch}


@dataclass
class Change:
    key: str
    text: str
    groups: set[str] = field(default_factory=set)


def _val(summary: dict | None, key: str):
    return ((summary or {}).get("values") or {}).get(key, {}).get("value")


def diff(old: dict | None, new: dict) -> list[Change]:
    """One Change per changed key, in a stable order. old=None (no summary yet) -> no changes."""
    if old is None:
        return []
    out: list[Change] = []
    for key, (_src, groups) in ALLOWLIST.items():
        a, b = _val(old, key), _val(new, key)
        if a != b:
            out.append(Change(key, f"cpd_vars changed: {key} {a or '(unset)'} -> {b or '(unset)'}", set(groups)))
    if old.get("patch_level") != new.get("patch_level"):
        out.append(Change("patch_level", f"patch level {old.get('patch_level') or '(unset)'} -> "
                                         f"{new.get('patch_level') or '(unset)'}", {"catalog"}))
    io_a, io_b = old.get("install_options"), new.get("install_options")
    if (io_a or {}).get("sha256") != (io_b or {}).get("sha256") or bool(io_a) != bool(io_b):
        ca, cb = (io_a or {}).get("components") or {}, (io_b or {}).get("components") or {}
        moved = sorted(k for k in set(ca) | set(cb) if ca.get(k) != cb.get(k))
        what = ", ".join(moved) if moved else ("turned off" if not io_b else "turned on" if not io_a
                                               else "file changed outside the component sections")
        out.append(Change("install_options", f"install options changed: {what}", {"catalog"}))
    if (old.get("storage_flags") or {}) != (new.get("storage_flags") or {}):
        out.append(Change("storage_flags", "storage flags changed (--file-sc / --block-sc / --sc-kind)", {"storage"}))
    cp_a, cp_b = old.get("cluster_patch"), new.get("cluster_patch")
    if cp_a and cp_b and cp_a.get("hash") != cp_b.get("hash"):
        out.append(Change("cluster_patch", cluster_patch_line(cp_a, cp_b), {"catalog"}))
    return out


def cluster_patch_line(a: dict, b: dict) -> str:
    parts = []
    if a.get("ibmcpd_version") != b.get("ibmcpd_version"):
        parts.append(f"Ibmcpd {a.get('ibmcpd_version') or '?'} -> {b.get('ibmcpd_version') or '?'}")
    oa, ob = a.get("operators") or {}, b.get("operators") or {}
    moved = sorted(k for k in set(oa) | set(ob) if oa.get(k) != ob.get(k))
    if moved:
        parts.append(f"{len(moved)} operator(s) ({', '.join(moved[:4])}{', ...' if len(moved) > 4 else ''})")
    return "cluster patch level changed: " + ("; ".join(parts) or "operator images")


def groups_of(changes: list[Change]) -> set[str]:
    return {g for c in changes for g in c.groups}
