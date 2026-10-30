"""Read-only facts from the operator that reconciles a kind (sub-plan §4.2).

The operator pod is the one whose /opt/ansible/watches.yaml handles the kind (no pod-name
guessing). From it: the scale presets (/opt/ansible/config/scale/<preset>.yaml, the
"standard specs" the starter templates come from) and the customization fields a role
documents (`# - presto_worker_replicas` header lines). Everything is cached in memory.
"""

from __future__ import annotations

import re
import threading
import time

import yaml

from ....common.kube import Kube, KubeError

SCALE_DIR = "/opt/ansible/config/scale"
_DOC_FIELD = re.compile(r"^#\s*-\s*([a-z][a-z0-9_]*)\s*$", re.M)


class OperatorFacts:
    def __init__(self, kube: Kube, operator_ns: list[str], kind: str):
        self.kube, self.namespaces, self.kind = kube, operator_ns, kind
        self._lock = threading.Lock()
        self._pod: tuple[str, str] | None = None
        self._presets: dict[str, dict] | None = None
        self._fields: dict[str, set[str]] = {}
        self.error: str | None = None

    def pod(self) -> tuple[str, str] | None:
        with self._lock:
            if self._pod is None:
                self._pod = self._find_pod() or ("", "")
            return self._pod if self._pod[0] else None

    def _find_pod(self) -> tuple[str, str] | None:
        for ns in self.namespaces:
            try:
                pods = self.kube.get(f"/api/v1/namespaces/{ns}/pods").get("items") or []
            except KubeError:
                continue
            for p in pods:
                if (p.get("status") or {}).get("phase") != "Running":
                    continue
                name = p["metadata"]["name"]
                try:
                    watches = yaml.safe_load(self.kube.exec(ns, name, ["cat", "/opt/ansible/watches.yaml"]) or "")
                except Exception:
                    continue
                if any(isinstance(w, dict) and w.get("kind") == self.kind for w in watches or []):
                    return ns, name
        return None

    def _run(self, cmd: list[str], tries: int = 3) -> str:
        """Exec with retries: a websocket handshake can be refused transiently (seen: 401 in a burst)."""
        pod = self.pod()
        if pod is None:
            return ""
        for n in range(tries):
            try:
                return self.kube.exec(pod[0], pod[1], cmd, timeout=30)
            except Exception as e:
                if n + 1 == tries:
                    self.error = f"exec into {pod[1]} failed: {str(e).splitlines()[0][:120]}"
                    return ""
                time.sleep(1.5 * (n + 1))
        return ""

    def presets(self) -> dict[str, dict]:
        """preset name -> its `scale:` mapping (component -> replicas / resources / jvm ...)."""
        with self._lock:
            cached = self._presets
        if cached is not None:
            return cached
        out: dict[str, dict] = {}
        # one exec for every preset file (each exec is a websocket handshake)
        raw = self._run(["sh", "-c", f'for f in {SCALE_DIR}/*.yaml; do echo "#@@FILE $f"; cat "$f"; done'])
        for chunk in raw.split("#@@FILE ")[1:]:
            path, _, body = chunk.partition("\n")
            name = path.strip().rsplit("/", 1)[-1].removesuffix(".yaml")
            try:
                doc = yaml.safe_load(body) or {}
            except yaml.YAMLError:
                continue
            if isinstance(doc, dict) and isinstance(doc.get("scale"), dict):
                out[name] = doc["scale"]
        with self._lock:
            self._presets = out
        return out

    def documented_fields(self, task_file: str) -> set[str]:
        """Customization keys a role lists in its header comments (`# - <key>`)."""
        with self._lock:
            if task_file in self._fields:
                return self._fields[task_file]
        found = set(_DOC_FIELD.findall(self._run(["cat", task_file])))
        with self._lock:
            self._fields[task_file] = found
        return found
