#!/usr/bin/env python3
"""Software Hub custom attribute provider: OpenShift RBAC as user attributes.

Runs in the CPD instance namespace (deployed by set_dynamic_user_group.sh).
usermgmt calls it on every login:

    GET /v1/external/usermgmt/attributes?username=<name>
    Authorization: Bearer <token>

and merges the returned flat JSON object into the user before it evaluates the
dynamic user group rules. Multi-valued attributes are returned as
",a,b,c," so a rule "match ,cluster-admin," cannot hit "cluster-admin-x" and
"match ,admin," cannot hit "cluster-admin". Every attribute is always
returned (as "," when empty) so "not match" rules work too.

Attributes come from sources (SOURCES env, comma separated). Each source is a
function (username, snapshot) -> {attribute: value}; add one to SOURCE_REGISTRY.

Python standard library only, so any python3 image works.
"""
import hmac
import json
import os
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API = f"https://{os.environ.get('KUBERNETES_SERVICE_HOST', 'kubernetes.default.svc')}:{os.environ.get('KUBERNETES_SERVICE_PORT', '443')}"
PORT = int(os.environ.get("PORT", "8443"))
TLS_CERT = os.environ.get("TLS_CERT", "/etc/tls/tls.crt")
TLS_KEY = os.environ.get("TLS_KEY", "/etc/tls/tls.key")
TOKEN_FILE = os.environ.get("TOKEN_FILE", "/etc/provider-token/token")
CACHE_SECONDS = float(os.environ.get("CACHE_SECONDS", "15"))
NAMESPACES = [n for n in os.environ.get("NAMESPACES", "").split(",") if n]
SOURCES = [s for s in os.environ.get("SOURCES", "openshift_rbac").split(",") if s]
# system:* ClusterRoles (discovery, basic-user, scc...) are bound to every user;
# leaving them out keeps the attribute readable.
INCLUDE_SYSTEM_ROLES = os.environ.get("INCLUDE_SYSTEM_ROLES", "false").lower() == "true"
# Every authenticated OAuth user is implicitly in these groups.
VIRTUAL_GROUPS = ("system:authenticated", "system:authenticated:oauth")


def log(msg):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", file=sys.stderr, flush=True)


def joined(values):
    return "," + ",".join(sorted(values)) + ("," if values else "")


# --- Kubernetes API ---------------------------------------------------------
_ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")


def kget(path):
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    with urllib.request.urlopen(req, context=_ctx, timeout=10) as r:
        return json.load(r)


class Snapshot:
    """Cluster RBAC state, refreshed at most every CACHE_SECONDS."""

    def __init__(self):
        self._lock = threading.Lock()
        self._at = 0.0
        self.users = {}            # lower(name) -> User
        self.groups = {}           # group -> set(lower(user))
        self.cluster_bindings = []
        self.ns_bindings = []

    def get(self):
        with self._lock:
            if time.monotonic() - self._at > CACHE_SECONDS:
                self.users = {u["metadata"]["name"].lower(): u for u in kget("/apis/user.openshift.io/v1/users")["items"]}
                self.groups = {g["metadata"]["name"]: {m.lower() for m in g.get("users") or []}
                               for g in kget("/apis/user.openshift.io/v1/groups")["items"]}
                self.cluster_bindings = kget("/apis/rbac.authorization.k8s.io/v1/clusterrolebindings")["items"]
                self.ns_bindings = [b for ns in NAMESPACES
                                    for b in kget(f"/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/rolebindings")["items"]]
                self._at = time.monotonic()
            return self


_snapshot = Snapshot()


# --- Sources ----------------------------------------------------------------
def source_openshift_rbac(username, snap):
    name = username.lower()
    user = snap.users.get(name)
    groups = {g for g, members in snap.groups.items() if name in members}
    if user:
        groups.update(VIRTUAL_GROUPS)

    def bound(binding):
        for s in binding.get("subjects") or []:
            if s.get("kind") == "User" and s.get("name", "").lower() == name:
                return True
            if s.get("kind") == "Group" and s.get("name") in groups:
                return True
        return False

    cluster_roles = {b["roleRef"]["name"] for b in snap.cluster_bindings
                     if b["roleRef"]["kind"] == "ClusterRole" and bound(b)
                     and (INCLUDE_SYSTEM_ROLES or not b["roleRef"]["name"].startswith("system:"))}
    ns_roles = {f"{b['metadata']['namespace']}/{b['roleRef']['name']}" for b in snap.ns_bindings if bound(b)}
    idps = {i.split(":", 1)[0] for i in (user or {}).get("identities") or []}
    return {
        "ocp_cluster_roles": joined(cluster_roles),
        "ocp_namespace_roles": joined(ns_roles),
        "ocp_groups": joined(groups - set(VIRTUAL_GROUPS)),
        "ocp_identity_providers": joined(idps),
    }


SOURCE_REGISTRY = {
    "openshift_rbac": source_openshift_rbac,
}


def attributes_for(username):
    snap = _snapshot.get()
    out = {}
    for s in SOURCES:
        out.update(SOURCE_REGISTRY[s](username, snap))
    return out


# --- HTTP -------------------------------------------------------------------
def expected_token():
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/healthz":
            return self._send(200, {"status": "ok"})
        if url.path != "/v1/external/usermgmt/attributes":
            return self._send(404, {"error": "not found"})
        token = expected_token()
        got = self.headers.get("Authorization", "")
        if not token or not hmac.compare_digest(got.encode(), f"Bearer {token}".encode()):
            log(f"401 from {self.client_address[0]}")
            return self._send(401, {"error": "unauthorized"})
        username = (urllib.parse.parse_qs(url.query).get("username") or [""])[0]
        if not username:
            return self._send(400, {"error": "username is required"})
        try:
            attrs = attributes_for(username)
        except Exception as e:  # noqa: BLE001 - report, never crash the server
            log(f"error resolving {username}: {e}")
            return self._send(500, {"error": "lookup failed"})
        log(f"{username} -> {json.dumps(attrs)}")
        return self._send(200, attrs)

    def log_message(self, *args):
        pass


def main():
    unknown = [s for s in SOURCES if s not in SOURCE_REGISTRY]
    if unknown:
        sys.exit(f"unknown SOURCES: {unknown}; known: {sorted(SOURCE_REGISTRY)}")
    server = ThreadingHTTPServer(("", PORT), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(TLS_CERT, TLS_KEY)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    log(f"listening on :{PORT}, sources={SOURCES}, namespaces={NAMESPACES}")
    server.serve_forever()


if __name__ == "__main__":
    main()
