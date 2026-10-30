"""D4: one instance-details file per instance, always written before the create call.

${CONFIG_DIR}/managed-service-instances/<addon_type>/<name>-instance_details.sh - the same
path and format as h_write_instance_details in src/helpers/common_helpers.sh, which the
4.5/5.x service-instance scripts use, so a TUI-made and a script-made instance leave
identical files. A header comment carries type / instance / namespace / cluster / writer /
time; values are `export KEY='value'` lines. source_env_setup.sh sources every file (oldest
first; a "# deleted" line skips it), so the keys are prefixed <TYPE>_<INSTANCE>_ and never
overwrite shared names. Directories 0700, files 0600, rewritten whole; host-side only.
"""

from __future__ import annotations

import os
import re
import shlex
from datetime import UTC, datetime
from pathlib import Path

from ..settings import managed_dir

_SAFE = re.compile(r"[^A-Za-z0-9_.-]")
_VAR = re.compile(r"[^A-Za-z0-9]")
WRITER = "instance-manager"


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def path_for(addon_type: str, name: str) -> Path:
    return managed_dir() / _SAFE.sub("_", addon_type) / f"{_SAFE.sub('_', name)}-instance_details.sh"


def var_prefix(addon_type: str, name: str) -> str:
    return _VAR.sub("_", f"{addon_type}_{name}").upper()


def _mkdirs(p: Path) -> None:
    for d in (p.parent.parent, p.parent):
        d.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(d, 0o700)


def write(addon_type: str, name: str, namespace: str, api_url: str, values: dict[str, str]) -> Path:
    """values: KEY -> value (secrets included); exported as <TYPE>_<NAME>_<KEY>. Replaces an older file."""
    prefix = var_prefix(addon_type, name)
    return write_exports(addon_type, name, namespace, api_url,
                         {f"{prefix}_{_VAR.sub('_', k).upper()}": v for k, v in values.items()})


def write_exports(addon_type: str, name: str, namespace: str, api_url: str, exports: dict[str, str],
                  writer: str = WRITER, trailer: list[str] | None = None) -> Path:
    """Exports as given (names already final), in the h_write_instance_details format."""
    p = path_for(addon_type, name)
    _mkdirs(p)
    lines = [f"# {addon_type} instance {name} in {namespace}, cluster {api_url or '?'}, written by {writer} on {_now()}"]
    lines += [f"export {k}={shlex.quote(str(v))}" for k, v in exports.items()]
    lines += trailer or []
    tmp = p.with_name(f"{p.name}.tmp.{os.getpid()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)
    return p


def vault():
    """src/helpers/instance_details_vault.py (shared with the shell scripts' h_vault_* helpers)."""
    import sys
    for parent in Path(__file__).resolve().parents:
        cand = parent / "helpers" / "instance_details_vault.py"
        if cand.is_file():
            if str(cand.parent) not in sys.path:
                sys.path.insert(0, str(cand.parent))
            import instance_details_vault
            return instance_details_vault
    raise ImportError("src/helpers/instance_details_vault.py not found")


def mark(addon_type: str, name: str, line: str) -> Path | None:
    """Append "# <line> <time>"; "deleted" makes source_env_setup.sh skip the file."""
    p = path_for(addon_type, name)
    if not p.is_file():
        return None
    with open(p, "a") as fh:
        fh.write(f"# {line} {_now()}\n")
    return p
