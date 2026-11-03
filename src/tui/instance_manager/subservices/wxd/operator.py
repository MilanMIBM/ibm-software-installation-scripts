"""Read-only facts from the operator that reconciles a kind (sub-plan §4.2).

The operator pod is the one whose /opt/ansible/watches.yaml handles the kind (no pod-name
guessing). From it: the scale presets (/opt/ansible/config/scale/<preset>.yaml, the
"standard specs" the starter templates come from) and the customization fields a role
documents (`# - presto_worker_replicas` header lines). Everything is cached in memory, and
with a discovery cache attached also on disk (part subservices/wxd/facts), keyed by the
operator's image digest (cache plan C3):
  1. the cached ns/pod, when it still runs that image
  2. a restarted operator: a running pod with the cached image (V-C7)
  3. otherwise a scan, 8 pods at a time, stopping at the first that watches the kind
Presets and documented fields from the cache are used only when the image is unchanged.
"""

from __future__ import annotations

import re
import threading
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait

import yaml

from ....common.kube import Kube, KubeError
from ...timings import span

SCALE_DIR = "/opt/ansible/config/scale"
_DOC_FIELD = re.compile(r"^#\s*-\s*([a-z][a-z0-9_]*)\s*$", re.M)
PART = "subservices/wxd/facts"
SCAN_PARALLEL = 8


def image_id(pod: dict) -> str:
    """The pod's image digests (what it really runs), else its spec images."""
    st = (pod.get("status") or {}).get("containerStatuses") or []
    ids = sorted(c.get("imageID") or c.get("image") or "" for c in st)
    if not any(ids):
        ids = sorted(c.get("image", "") for c in ((pod.get("spec") or {}).get("containers") or []))
    return ",".join(i.rsplit("@", 1)[-1] for i in ids)


def _running(pod: dict) -> bool:
    return (pod.get("status") or {}).get("phase") == "Running"


class OperatorFacts:
    def __init__(self, kube: Kube, operator_ns: list[str], kind: str, sources=None):
        self.kube, self.namespaces, self.kind = kube, operator_ns, kind
        self.sources = sources
        self._lock = threading.Lock()
        self._pod: tuple[str, str] | None = None
        self._image = ""
        self._presets: dict[str, dict] | None = None
        self._fields: dict[str, set[str]] = {}
        self._cached: dict | None = None
        self.from_cache = False
        self.error: str | None = None
        if sources is not None:
            c = sources.get(PART)
            if isinstance(c, dict) and c.get("kind") == kind:
                self._cached = c

    def pod(self) -> tuple[str, str] | None:
        with self._lock:
            if self._pod is None:
                with span("wxd operator pod"):
                    self._pod = self._locate() or ("", "")
            return self._pod if self._pod[0] else None

    def _locate(self) -> tuple[str, str] | None:
        c = self._cached
        if c and c.get("pod") and c.get("image"):
            ns, name = c["pod"]
            try:
                p = self.kube.get(f"/api/v1/namespaces/{ns}/pods/{name}", timeout=(5, 15))
                if _running(p) and image_id(p) == c["image"]:
                    return self._hit(ns, name, c["image"])
            except KubeError:
                pass
            for ns in self.namespaces:                     # restarted: same image, new pod name
                for p in self._pods(ns):
                    if _running(p) and image_id(p) == c["image"]:
                        return self._hit(ns, p["metadata"]["name"], c["image"])
        found = self._find_pod()
        if found and c and self._image != c.get("image"):
            self._cached = None                            # another operator image: re-read its facts
        return found

    def _hit(self, ns: str, name: str, image: str) -> tuple[str, str]:
        self._image = image
        self.from_cache = True
        return ns, name

    def _pods(self, ns: str) -> list[dict]:
        try:
            return self.kube.get(f"/api/v1/namespaces/{ns}/pods").get("items") or []
        except KubeError:
            return []

    def _watches(self, ns: str, pod: dict) -> bool:
        try:
            doc = yaml.safe_load(self.kube.exec(ns, pod["metadata"]["name"], ["cat", "/opt/ansible/watches.yaml"])
                                 or "")
        except Exception:
            return False
        return any(isinstance(w, dict) and w.get("kind") == self.kind for w in doc or [])

    def _find_pod(self) -> tuple[str, str] | None:
        """Every running pod's watches.yaml, SCAN_PARALLEL execs at a time; the first match wins."""
        for ns in self.namespaces:
            pods = [p for p in self._pods(ns) if _running(p)]
            if not pods:
                continue
            pool = ThreadPoolExecutor(max_workers=min(SCAN_PARALLEL, len(pods)))
            try:
                pending = {pool.submit(self._watches, ns, p): p for p in pods}
                while pending:
                    done, _ = wait(pending, return_when=FIRST_COMPLETED)
                    for f in done:
                        p = pending.pop(f)
                        if f.result():
                            self._image = image_id(p)
                            return ns, p["metadata"]["name"]
            finally:
                pool.shutdown(wait=False, cancel_futures=True)
        return None

    def _usable_cache(self) -> dict | None:
        self.pod()
        return self._cached if self.from_cache else None

    def _save(self) -> None:
        if self.sources is None or not self._pod or not self._pod[0]:
            return
        with self._lock:
            doc = {"kind": self.kind, "pod": list(self._pod), "image": self._image, "presets": self._presets,
                   "documented": {k: sorted(v) for k, v in self._fields.items()}}
        self.sources.put(PART, doc, fp=self._image[:24])

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
        c = self._usable_cache()
        if c and isinstance(c.get("presets"), dict):
            with self._lock:
                self._presets = c["presets"]
            return self._presets
        out: dict[str, dict] = {}
        # one exec for every preset file (each exec is a websocket handshake)
        with span("wxd presets (exec)"):
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
        if out:
            self._save()
        return out

    def documented_fields(self, task_file: str) -> set[str]:
        """Customization keys a role lists in its header comments (`# - <key>`)."""
        with self._lock:
            if task_file in self._fields:
                return self._fields[task_file]
        c = self._usable_cache()
        if c and task_file in (c.get("documented") or {}):
            found = set(c["documented"][task_file])
        else:
            with span("wxd documented fields (exec)"):
                found = set(_DOC_FIELD.findall(self._run(["cat", task_file])))
        with self._lock:
            self._fields[task_file] = found
        if found and not (c and task_file in (c.get("documented") or {})):
            self._save()
        return found
