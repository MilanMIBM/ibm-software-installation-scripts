"""CacheStore: one scope directory, atomic JSON parts, a manifest and a write lock (plan §2.1, §2.7).

  root   ${CONFIG_DIR}/instance_manager_cache            0700
  scope  <root>/<api-host>--<namespace>                  0700, files 0600
Every part is written to a temp file and moved into place with os.replace; the manifest
(written last) holds each part's sha256. A part whose content doesn't match the manifest
counts as missing, never as an error. Writers take an fcntl.flock on <scope>/.lock (the TUI
and the standalone builder may overlap); readers never block.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import urlparse

from ..settings import config_dir
from . import CACHE_DIRNAME, CACHE_SCHEMA

MANIFEST = "manifest.json"


def cache_root() -> Path:
    return config_dir() / CACHE_DIRNAME


def scope_name(api_url: str, namespace: str | None, suffix: str = "") -> str:
    host = urlparse(api_url if "//" in api_url else f"https://{api_url}").netloc or api_url
    raw = f"{host.replace(':', '_')}--{namespace or 'all'}{suffix}"
    return re.sub(r"[^A-Za-z0-9._-]", "_", raw)


def dumps(obj) -> str:
    return json.dumps(obj, indent=1, sort_keys=True, ensure_ascii=False, default=str)


def sha(text: str | bytes) -> str:
    return hashlib.sha256(text.encode() if isinstance(text, str) else text).hexdigest()


def _mkdir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def atomic_write(path: Path, text: str) -> None:
    _mkdir(path.parent)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}-")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


class CacheStore:
    def __init__(self, scope: str, root: Path | None = None):
        self.root = root or cache_root()
        self.scope = scope
        self.dir = self.root / scope
        self._manifest: dict | None = None
        self._mlock = threading.RLock()          # the TUI's two hub lanes write parts concurrently

    # -- manifest -------------------------------------------------------------------------
    @property
    def exists(self) -> bool:
        return (self.dir / MANIFEST).is_file()

    def manifest(self) -> dict:
        with self._mlock:
            if self._manifest is None:
                m = read_json(self.dir / MANIFEST)
                self._manifest = m if isinstance(m, dict) and m.get("schema") == CACHE_SCHEMA else \
                    {"schema": CACHE_SCHEMA, "parts": {}}
            return self._manifest

    def meta(self, part: str) -> dict | None:
        with self._mlock:
            return (self.manifest().get("parts") or {}).get(part)

    def parts(self) -> list[str]:
        with self._mlock:
            return sorted((self.manifest().get("parts") or {}))

    def set_info(self, **kw) -> None:
        with self._mlock:
            self.manifest().update(kw)

    def save_manifest(self) -> None:
        with self._mlock:
            m = self.manifest()
            m["schema"] = CACHE_SCHEMA
            m["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            text = dumps(m)
        with self.lock():
            atomic_write(self.dir / MANIFEST, text)

    # -- parts ------------------------------------------------------------------------------
    def _path(self, part: str) -> Path:
        if part.startswith("/") or ".." in Path(part).parts:
            raise ValueError(f"bad cache part {part!r}")
        return self.dir / f"{part}.json"

    def read(self, part: str):
        """The part's content, or None when missing or not matching the manifest."""
        info = self.meta(part)
        if not info:
            return None
        try:
            raw = self._path(part).read_text()
        except OSError:
            return None
        if sha(raw) != info.get("sha"):
            return None
        try:
            return json.loads(raw)
        except ValueError:
            return None

    def write(self, part: str, obj, fp: str = "", took_s: float | None = None) -> None:
        """Write a part and record it in the in-memory manifest (save_manifest() persists it)."""
        text = dumps(obj)
        with self.lock():
            atomic_write(self._path(part), text)
        entry = {"sha": sha(text), "fp": fp, "built_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
        if took_s is not None:
            entry["took_s"] = round(took_s, 3)
        with self._mlock:
            self.manifest().setdefault("parts", {})[part] = entry

    def drop(self, part: str) -> None:
        with self._mlock:
            self.manifest().setdefault("parts", {}).pop(part, None)
        try:
            self._path(part).unlink()
        except OSError:
            pass

    def drop_prefix(self, prefix: str) -> list[str]:
        gone = [p for p in self.parts() if p.startswith(prefix)]
        for p in gone:
            self.drop(p)
        return gone

    def clear(self) -> bool:
        if not self.dir.exists():
            return False
        shutil.rmtree(self.dir)
        with self._mlock:
            self._manifest = None
        return True

    @contextmanager
    def lock(self):
        _mkdir(self.dir)
        fd = os.open(self.dir / ".lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    # -- root-level files (last_used.json) -----------------------------------------------
    def read_root(self, name: str):
        return read_json(self.root / name)

    def write_root(self, name: str, obj) -> None:
        _mkdir(self.root)
        atomic_write(self.root / name, dumps(obj))
