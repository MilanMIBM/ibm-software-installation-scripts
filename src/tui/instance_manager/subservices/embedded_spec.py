"""Find the API spec a service embeds, by following the platform's own routing (read-only).

Software Hub routes add-on APIs through ZenExtension nginx snippets; a console pod may route
further with its own nginx. From a base path (e.g. /lakehouse/api/v3):
  1. ZenExtension `location <prefix>` with the longest matching prefix -> proxy_pass host
  2. host -> Service -> its pods; if a pod's nginx has a more specific location for the base
     path, follow that proxy_pass too (a few hops at most)
  3. in the final pod, the executables at / that embed a go-swagger document
     ("swagger": "2.0"); the document whose basePath is the base path wins.
Reads happen through pod exec, at most a few MB; the result is cached for the session.
"""

from __future__ import annotations

import json
import re
import threading

from ...common.kube import Kube, KubeError

MAX_HOPS = 3
_LOC = re.compile(r"location\s+(?:[=~^*]+\s*)?\"?([^\s{\"]+)\"?\s*\{(.*?)\n\s*\}", re.S)
_PASS = re.compile(r"proxy_pass\s+https?://([A-Za-z0-9.-]+)")
_cache: dict[tuple[str, str], dict | None] = {}
_lock = threading.Lock()


def _best_upstream(conf: str, base_path: str) -> str | None:
    best, host = -1, None
    for prefix, body in _LOC.findall(conf):
        if "(" in prefix or not base_path.startswith(prefix.rstrip("$")):
            continue
        m = _PASS.search(body)
        if m and len(prefix) > best:
            best, host = len(prefix), m.group(1)
    return host


def _pods_for_service(kube: Kube, ns: str, host: str) -> list[str]:
    svc = host.split(".")[0]
    try:
        sel = (kube.get(f"/api/v1/namespaces/{ns}/services/{svc}").get("spec") or {}).get("selector") or {}
    except KubeError:
        return []
    if not sel:
        return []
    label = ",".join(f"{k}={v}" for k, v in sel.items())
    pods = kube.get(f"/api/v1/namespaces/{ns}/pods", labelSelector=label).get("items") or []
    return [p["metadata"]["name"] for p in pods if (p.get("status") or {}).get("phase") == "Running"]


def _exec(kube: Kube, ns: str, pod: str, cmd: str, timeout: int = 60) -> str:
    try:
        return kube.exec(ns, pod, ["sh", "-c", cmd], timeout=timeout)
    except Exception:
        return ""


def _embedded_docs(kube: Kube, ns: str, pod: str) -> list[dict]:
    files = _exec(kube, ns, pod, "find / -maxdepth 2 -xdev -type f -size +1M -perm -u+x 2>/dev/null "
                                 "| grep -vE '^/(proc|sys|usr|lib|lib64|bin|sbin|etc)/' | head -20").split()
    docs = []
    for f in files:
        lines = _exec(kube, ns, pod, f"grep -a -n '\"swagger\": \"2.0\"' {f} | cut -d: -f1 | head -4").split()
        for ln in lines:
            if not ln.isdigit():
                continue
            raw = _exec(kube, ns, pod, f"awk 'NR>={int(ln) - 1}' {f} | head -c 6000000", timeout=120)
            i = raw.find('"swagger": "2.0"')
            if i < 0:
                continue
            try:
                doc, _ = json.JSONDecoder().raw_decode("{" + raw[i:])
            except ValueError:
                continue
            docs.append(doc)
    return docs


def find_spec(kube: Kube, namespace: str, base_path: str) -> dict | None:
    key = (namespace, base_path)
    with _lock:
        if key in _cache:
            return _cache[key]
    spec = None
    try:
        zx = kube.get(f"/apis/zen.cpd.ibm.com/v1/namespaces/{namespace}/zenextensions").get("items") or []
    except KubeError:
        zx = []
    conf = "\n".join(json.dumps(z.get("spec") or {}).replace("\\n", "\n").replace('\\"', '"') for z in zx)
    host = _best_upstream(conf, base_path)
    seen: set[str] = set()
    for _ in range(MAX_HOPS):
        if not host or host in seen:
            break
        seen.add(host)
        pods = _pods_for_service(kube, namespace, host)
        if not pods:
            break
        pod = pods[0]
        nginx = _exec(kube, namespace, pod, "cat /etc/nginx/conf.d/*.conf /etc/nginx/nginx.conf 2>/dev/null")
        nxt = _best_upstream(nginx, base_path) if nginx else None
        if nxt and nxt not in seen:
            host = nxt
            continue
        for doc in _embedded_docs(kube, namespace, pod):
            if (doc.get("basePath") or "").rstrip("/") == base_path.rstrip("/"):
                spec = doc
                break
        break
    with _lock:
        _cache[key] = spec
    return spec
