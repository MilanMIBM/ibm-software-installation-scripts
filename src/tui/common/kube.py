"""Cluster access shared by the TUIs: raw REST GETs, watches, exec, logs.

Uses the kubeconfig that `oc login` writes. Raw paths instead of the dynamic client
so no API-discovery cache file is written.
"""

from __future__ import annotations

import json
import time

from kubernetes import client, config
from kubernetes.watch.watch import iter_resp_lines

WATCH_TIMEOUT = 25          # seconds per watch request (server side)
METADATA_ONLY = "application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1,application/json"


class KubeError(Exception):
    def __init__(self, status: int, msg: str):
        super().__init__(f"HTTP {status}: {msg}")
        self.status = status


class Kube:
    def __init__(self, context: str | None = None, kubeconfig: str | None = None):
        config.load_kube_config(config_file=kubeconfig, context=context)
        self.api = client.ApiClient()
        self.host = self.api.configuration.host
        try:
            _, active = config.list_kube_config_contexts(config_file=kubeconfig)
            self.context_user = ((active or {}).get("context") or {}).get("user", "")
        except Exception:
            self.context_user = ""

    def _request(self, path: str, query: dict | None = None, timeout=None, accept: str = "application/json"):
        q = [(k, str(v).lower() if isinstance(v, bool) else str(v)) for k, v in (query or {}).items()
             if v is not None]
        method, url, headers, _body, _post = self.api.param_serialize(
            "GET", path, query_params=q, header_params={"Accept": accept},
            auth_settings=["BearerToken"])
        resp = self.api.call_api(method, url, header_params=headers, _request_timeout=timeout)
        if resp.status >= 400:
            resp.read()
            try:
                msg = json.loads(resp.data).get("message", "")
            except Exception:
                msg = (resp.data or b"")[:200].decode(errors="replace")
            raise KubeError(resp.status, msg)
        return resp

    def get(self, path: str, timeout=(5, 60), accept: str = "application/json", **query) -> dict:
        """`accept` = e.g. METADATA_ONLY to list objects without their data (Secrets)."""
        resp = self._request(path, query, timeout, accept)
        resp.read()
        return json.loads(resp.data)

    def send(self, method: str, path: str, body=None, *, content_type: str = "application/json",
             timeout=(5, 60), **query) -> dict:
        """POST / PUT / PATCH / DELETE with a JSON body (dict). `dryRun="All"` validates server-side
        (admission + schema) without persisting. Only the instance manager writes; cr_dashboard never calls this."""
        q = [(k, str(v)) for k, v in query.items() if v is not None]
        m, url, headers, body_, _post = self.api.param_serialize(
            method, path, query_params=q, header_params={"Accept": "application/json", "Content-Type": content_type},
            body=body, auth_settings=["BearerToken"])
        resp = self.api.call_api(m, url, header_params=headers, body=body_, _request_timeout=timeout)
        resp.read()
        if resp.status >= 400:
            try:
                msg = json.loads(resp.data).get("message", "")
            except Exception:
                msg = (resp.data or b"")[:300].decode(errors="replace")
            raise KubeError(resp.status, msg)
        return json.loads(resp.data) if resp.data else {}

    def get_text(self, path: str, timeout=(5, 60), **query) -> str:
        resp = self._request(path, query, timeout)
        resp.read()
        return (resp.data or b"").decode(errors="replace")

    def watch(self, path: str, resource_version: str, timeout: int = WATCH_TIMEOUT):
        resp = self._request(path, {"watch": True, "resourceVersion": resource_version,
                                    "timeoutSeconds": timeout, "allowWatchBookmarks": True},
                             timeout=(5, timeout + 15))
        try:
            for line in iter_resp_lines(resp.response):
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
        finally:
            resp.response.release_conn()

    def whoami(self) -> str:
        try:
            return self.get("/apis/user.openshift.io/v1/users/~", timeout=(3, 10))["metadata"]["name"]
        except Exception:
            return self.context_user.split("/")[0] if self.context_user else "?"

    def exec(self, namespace: str, pod: str, command: list[str], timeout: int = 15,
             container: str | None = None) -> str:
        from kubernetes.stream import stream
        # stream() temporarily swaps the client's call_api for a WebSocket one; a dedicated client per
        # exec keeps the informers' and log GETs on other threads off that swap
        core = client.CoreV1Api(client.ApiClient(self.api.configuration))
        kwargs = {"command": command, "stderr": True, "stdin": False, "stdout": True, "tty": False,
                  "_preload_content": False}
        if container:
            kwargs["container"] = container
        ws = stream(core.connect_get_namespaced_pod_exec, pod, namespace, **kwargs)
        out, deadline = [], time.monotonic() + timeout
        try:
            while ws.is_open() and time.monotonic() < deadline:
                ws.update(timeout=1)
                if ws.peek_stdout():
                    out.append(ws.read_stdout())
            if ws.peek_stdout():
                out.append(ws.read_stdout())
        finally:
            ws.close()
        return "".join(out)

    def logs(self, namespace: str, pod: str, tail: int = 300, container: str | None = None) -> str:
        return self.get_text(f"/api/v1/namespaces/{namespace}/pods/{pod}/log", tailLines=tail,
                             container=container)
