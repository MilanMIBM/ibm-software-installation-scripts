"""cpd-cli wrapper: `service-instance` and `config` only.

Both are native and talk to zen over HTTPS from the host; they never touch the olm-utils
container (verified with podman events, plan §1 F10). `cpd-cli manage` recreates that
container and kills any running job, so it is refused here outright.
Calls are serialised: they share the profile's token cache.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
from pathlib import Path

ALLOWED = {"service-instance", "config"}


class CpdCliError(Exception):
    def __init__(self, args: list[str], code: int, output: str):
        super().__init__(f"cpd-cli {' '.join(args[:2])} failed (exit {code}): {output.strip()[-300:]}")
        self.code = code
        self.output = output


def find_binary() -> str | None:
    for cand in (os.environ.get("CPD_CLI"), shutil.which("cpd-cli"), str(Path.home() / "cpd-cli" / "cpd-cli")):
        if cand and Path(cand).is_file() and os.access(cand, os.X_OK):
            return cand
    return None


class CpdCli:
    _lock = threading.Lock()

    def __init__(self, profile: str, binary: str | None = None):
        self.profile = profile
        self.binary = binary or find_binary()

    @property
    def available(self) -> bool:
        return bool(self.binary)

    def run(self, *args: str, timeout: int = 180, profile: bool = True) -> str:
        if not args or args[0] not in ALLOWED:
            raise ValueError(f"refusing cpd-cli {args[:1]}: only {sorted(ALLOWED)} are allowed")
        if not self.binary:
            raise CpdCliError(list(args), 127, "cpd-cli not found (PATH, $CPD_CLI or ~/cpd-cli/cpd-cli)")
        argv = [self.binary, *args] + ([f"--profile={self.profile}"] if profile else [])
        with self._lock:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                                  stdin=subprocess.DEVNULL)
        if proc.returncode != 0:
            raise CpdCliError(list(args), proc.returncode, (proc.stdout or "") + (proc.stderr or ""))
        return proc.stdout

    def json(self, *args: str, timeout: int = 180):
        out = self.run(*args, "-o", "json", timeout=timeout)
        start = min((i for i in (out.find("{"), out.find("[")) if i >= 0), default=-1)
        if start < 0:
            raise CpdCliError(list(args), 0, f"no JSON in output: {out[:200]}")
        return json.loads(out[start:])

    # -- service-instance ------------------------------------------------------
    def list_instances(self) -> list[dict]:
        data = self.json("service-instance", "list", "--exclude-user-count")
        return data.get("service_instances", []) if isinstance(data, dict) else list(data or [])

    def get_instance(self, name: str, service_type: str) -> dict:
        data = self.json("service-instance", "get", name, f"--service-type={service_type}")
        return data.get("service_instance", data) if isinstance(data, dict) else {}
