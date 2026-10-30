"""Per target cluster + config settings (D10): ${CONFIG_DIR}/managed-service-instances/settings.json.

Keyed by the cluster API server URL, so one config folder can serve several clusters and a
setting follows the cluster it was made on. The directory is 0700 and the file 0600; it is
host-side only (source_env_setup.sh copies just top-level config files into the cpd-cli
work dir). Holds no secrets.
"""

from __future__ import annotations

import json
import os
import tempfile
from datetime import UTC, datetime
from pathlib import Path

SUBDIR = "managed-service-instances"


def config_dir() -> Path:
    env = os.environ.get("CONFIG_DIR")
    if env:
        return Path(env).resolve()
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "env_bootstrap.sh").is_file():
            return parent / "configs" / "cp4d_config"
    return Path.cwd() / "configs" / "cp4d_config"


def managed_dir(create: bool = False) -> Path:
    d = config_dir() / SUBDIR
    if create:
        d.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(d, 0o700)
    return d


class Settings:
    def __init__(self, path: Path | None = None):
        self.path = path or managed_dir() / "settings.json"

    def _load(self) -> dict:
        try:
            return json.loads(self.path.read_text())
        except (OSError, json.JSONDecodeError):
            return {}

    def cluster(self, api_url: str) -> dict:
        return (self._load().get("clusters") or {}).get(api_url.rstrip("/"), {})

    def set(self, api_url: str, key: str, value) -> None:
        data = self._load()
        entry = data.setdefault("clusters", {}).setdefault(api_url.rstrip("/"), {})
        entry[key] = value
        entry["changed"] = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".settings-")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(data, fh, indent=2, sort_keys=True)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
