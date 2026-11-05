#!/usr/bin/env python3
"""Stand-in Software Hub instance for Control Center's "other workloads" account.

Control Center only measures registered Software Hub instances. It polls each one on
four zen-watchdog endpoints, so it cannot show what storage, monitoring or third-party
agents reserve. This server answers those endpoints with the totals of every project
outside Software Hub, so the reservation shows up in that account. It is an indicator
only: nothing here limits or schedules anything.

Deployed by x_debug_toggle_other_workloads_indicator.sh. Standard library only. Reads
the cluster with its service account, which can only list. Every request is logged,
without credentials, so unexpected calls from Control Center are easy to spot.

Environment:
    INDICATOR_USERNAME, INDICATOR_API_KEY  the login Control Center was given
    EXCLUDE_PROJECTS                       extra Software Hub projects, comma-separated
    QUOTA_CPU, QUOTA_MEMORY_GI             starting quota, until Control Center sends one
    PORT                                   default 8080
"""

import base64
import hmac
import json
import os
import ssl
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API = "https://kubernetes.default.svc"
ACCOUNT_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
CACHE_SECONDS = 60
UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "Pi": 2**50,
         "K": 10**3, "M": 10**6, "G": 10**9, "T": 10**12, "P": 10**15,
         "m": 1e-3, "u": 1e-6, "n": 1e-9}


def quantity(value):
    """A Kubernetes quantity as a float: '1500m' -> 1.5, '1Gi' -> 1073741824."""
    value = str(value or "0")
    for unit, factor in UNITS.items():
        if value.endswith(unit):
            return float(value[: -len(unit)]) * factor
    return float(value)


class Kube:
    """Read-only client for the API server, using the pod's service account."""

    def __init__(self, base=API, account_dir=ACCOUNT_DIR):
        self.base = base
        with open(os.path.join(account_dir, "token")) as token:
            self.token = token.read().strip()
        with open(os.path.join(account_dir, "namespace")) as namespace:
            self.namespace = namespace.read().strip()
        self.context = ssl.create_default_context(cafile=os.path.join(account_dir, "ca.crt"))

    def items(self, path):
        request = urllib.request.Request(self.base + path, headers={"Authorization": f"Bearer {self.token}"})
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=30) as response:
                return json.load(response).get("items", [])
        except Exception as error:  # an optional API (metrics, a CRD) may be missing
            log(f"read {path} failed: {error}")
            return []


def collect(kube, extra_projects=(), own_project=""):
    """Requests, limits, usage and volume capacity of everything outside Software Hub.

    Software Hub means any project with a ZenService or CommonService, plus the extra
    projects given, plus this one. Pods on nodes that are not workers are left out,
    because Control Center's cluster capacity only counts workers.
    """
    skip = {item["metadata"]["namespace"]
            for path in ("/apis/zen.cpd.ibm.com/v1/zenservices", "/apis/operator.ibm.com/v3/commonservices")
            for item in kube.items(path)}
    skip |= {p for p in extra_projects if p} | ({own_project} if own_project else set())
    workers = {node["metadata"]["name"] for node in kube.items("/api/v1/nodes")
               if "node-role.kubernetes.io/worker" in node["metadata"].get("labels", {})}

    totals = {"cpu_requests": 0.0, "cpu_limits": 0.0, "memory_requests": 0.0, "memory_limits": 0.0,
              "cpu_usage": 0.0, "memory_usage": 0.0, "volume_bytes": 0.0}
    counted = set()
    for pod in kube.items("/api/v1/pods"):
        meta, spec = pod["metadata"], pod["spec"]
        if meta["namespace"] in skip or spec.get("nodeName") not in workers:
            continue
        if pod.get("status", {}).get("phase") not in ("Running", "Pending"):
            continue
        counted.add((meta["namespace"], meta["name"]))
        for container in spec.get("containers", []):
            resources = container.get("resources", {})
            totals["cpu_requests"] += quantity(resources.get("requests", {}).get("cpu"))
            totals["memory_requests"] += quantity(resources.get("requests", {}).get("memory"))
            totals["cpu_limits"] += quantity(resources.get("limits", {}).get("cpu"))
            totals["memory_limits"] += quantity(resources.get("limits", {}).get("memory"))
    for metrics in kube.items("/apis/metrics.k8s.io/v1beta1/pods"):
        if (metrics["metadata"]["namespace"], metrics["metadata"]["name"]) in counted:
            for container in metrics.get("containers", []):
                totals["cpu_usage"] += quantity(container["usage"].get("cpu"))
                totals["memory_usage"] += quantity(container["usage"].get("memory"))
    for claim in kube.items("/api/v1/persistentvolumeclaims"):
        if claim["metadata"]["namespace"] not in skip and claim.get("status", {}).get("phase") == "Bound":
            totals["volume_bytes"] += quantity(claim["status"].get("capacity", {}).get("storage"))
    totals["projects"] = len({namespace for namespace, _ in counted})
    return totals


def default_policy(cpu=0, memory_gi=0):
    return {"ID": "platform", "Enable": True, "Alert": False, "Enforce": False, "EnforcementSupported": True,
            "Policies": {"Quota": {"CPU": {"Maximum": cpu, "Warning": -1, "Unit": "c"},
                                   "Memory": {"Maximum": memory_gi, "Warning": -1, "Unit": "Gi"},
                                   "GPU": {"Maximum": 0, "Warning": -1, "Unit": "gpu"},
                                   "PolicyType": "request"}}}


def merge_policy(policy, body):
    """Apply a quota Control Center sent. Unknown fields are ignored."""
    merged = json.loads(json.dumps(policy))
    for key in ("Enable", "Alert", "Enforce"):
        if key in body:
            merged[key] = body[key]
    quota = (body.get("Policies") or {}).get("Quota") or {}
    for kind in ("CPU", "Memory", "GPU"):
        if isinstance(quota.get(kind), dict):
            merged["Policies"]["Quota"][kind].update(quota[kind])
    if quota.get("PolicyType"):
        merged["Policies"]["Quota"]["PolicyType"] = quota["PolicyType"]
    return merged


def _gi(value):
    return value / 2**30


def _percent(used, maximum):
    return used / maximum * 100 if maximum and maximum > 0 else 0


def overview(totals, policy, now):
    """GET /zen-watchdog/v3/instance/overview, in the real instance's format."""
    quota = policy["Policies"]["Quota"]
    return {"_messageCode_": "success", "message": "Success in getting platform details", "requestObj": {
        "UpdateTime": int(now),
        "Resources": {
            "ResourcePlan": policy,
            "InUse": {
                "CPU": {"Requests": totals["cpu_requests"], "Utilization": totals["cpu_usage"], "Capacity": 0,
                        "Units": "c", "Limits": totals["cpu_limits"]},
                "Memory": {"Requests": _gi(totals["memory_requests"]), "Utilization": _gi(totals["memory_usage"]),
                           "Capacity": 0, "Units": "Gi", "Limits": _gi(totals["memory_limits"])},
                "Network": {"TransmittedBps": 0, "ReceivedBps": 0, "Unit": "B/s"},
                "GPU": {"Requests": 0, "Utilization": 0, "Capacity": 0, "Units": "unit", "Limits": 0},
                "Volume": {"Capacity": totals["volume_bytes"] / 1e9, "Utilization": 0, "Units": "GB"},
            },
            "Quota": {"PercentCPU": _percent(totals["cpu_requests"], quota["CPU"]["Maximum"]),
                      "PercentMemory": _percent(_gi(totals["memory_requests"]), quota["Memory"]["Maximum"]),
                      "PercentGPU": 0},
        },
        "AlertsAndEvents": {"Events": [], "CriticalStatus": {"Total": 0, "Alerts": 0},
                            "WarningStatus": {"Total": 0, "Alerts": 0}},
        "PrivilegedWatchdog": False,
    }}


def policy_details(totals, policy):
    """GET /zen-watchdog/v3/resources/policies/platform."""
    details = dict(policy, Name="Platform",
                   CPUUsage=totals["cpu_usage"], CPUAllocated=totals["cpu_requests"], CPULimit=totals["cpu_limits"],
                   MemoryUsage=_gi(totals["memory_usage"]), MemoryAllocated=_gi(totals["memory_requests"]),
                   MemoryLimit=_gi(totals["memory_limits"]), GPULimit=0)
    return {"_messageCode_": "success", "message": "Success in getting quota details", "requestObj": details}


def authorized(header, username, api_key):
    """Control Center sends 'ZenApiKey base64(username:api_key)'."""
    scheme, _, value = (header or "").partition(" ")
    if scheme != "ZenApiKey" or not username or not api_key:
        return False
    expected = base64.b64encode(f"{username}:{api_key}".encode()).decode()
    return hmac.compare_digest(value.strip(), expected)


def log(message):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), message, flush=True)


class State:
    def __init__(self, kube, extra_projects, own_project, policy):
        self.kube, self.extra, self.own = kube, extra_projects, own_project
        self.policy = policy
        self.lock = threading.Lock()
        self._totals, self._at = None, 0.0

    def totals(self):
        with self.lock:
            if self._totals is None or time.time() - self._at > CACHE_SECONDS:
                self._totals, self._at = collect(self.kube, self.extra, self.own), time.time()
            return self._totals


def make_handler(state, username, api_key):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            scheme = (self.headers.get("Authorization") or "none").split(" ", 1)[0]
            log(f"{self.command} {self.path} -> {code} (auth: {scheme}, from {self.client_address[0]})")

        def _route(self):
            path = self.path.split("?", 1)[0].rstrip("/")
            if path == "/zen-watchdog/v1/monitor":
                return self._send(200, {"_messageCode_": "200", "message": "Server up and running"})
            if not authorized(self.headers.get("Authorization"), username, api_key):
                return self._send(401, {"_messageCode_": "unauthorized", "message": "Invalid credentials"})
            if self.command == "GET" and path == "/zen-watchdog/v3/instance/overview":
                return self._send(200, overview(state.totals(), state.policy, time.time()))
            if self.command == "GET" and path == "/zen-watchdog/v3/cluster/information":
                host = os.environ.get("KUBERNETES_SERVICE_HOST", "172.30.0.1")
                return self._send(200, {"_messageCode_": "success", "message": "Success in getting cluster information",
                                        "requestObj": {"Hostname": host, "PrivilegedWatchdog": False}})
            if path == "/zen-watchdog/v3/resources/policies/platform":
                if self.command in ("POST", "PUT", "PATCH"):
                    length = int(self.headers.get("Content-Length") or 0)
                    try:
                        body = json.loads(self.rfile.read(length) or b"{}")
                    except ValueError:
                        return self._send(400, {"_messageCode_": "bad_request", "message": "Invalid JSON"})
                    state.policy = merge_policy(state.policy, body)
                    log(f"quota now {json.dumps(state.policy['Policies']['Quota'])}")
                    return self._send(200, {"_messageCode_": "success", "message": "Success in updating quota details"})
                return self._send(200, policy_details(state.totals(), state.policy))
            return self._send(404, {"_messageCode_": "not_found", "message": f"Not served by the indicator: {path}"})

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _route

        def log_message(self, *args):  # _send logs instead
            pass

    return Handler


def main():
    kube = Kube()
    extra = os.environ.get("EXCLUDE_PROJECTS", "").split(",")
    policy = default_policy(float(os.environ.get("QUOTA_CPU") or 0), float(os.environ.get("QUOTA_MEMORY_GI") or 0))
    state = State(kube, extra, kube.namespace, policy)
    handler = make_handler(state, os.environ.get("INDICATOR_USERNAME", ""), os.environ.get("INDICATOR_API_KEY", ""))
    port = int(os.environ.get("PORT", "8080"))
    log(f"serving on :{port}, leaving out {len([p for p in extra if p])} configured projects and {kube.namespace}")
    ThreadingHTTPServer(("", port), handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
