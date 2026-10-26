"""Assign Software Hub service-instance roles without changing platform roles.

Uses the v3 instance/member read APIs and the v2 membership write APIs. The
role PATCH endpoint remains available on Software Hub 5.4 even though its v2
member-list endpoint returns HTTP 410.
"""

from __future__ import annotations

import json
import ssl
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field


class APIError(RuntimeError):
    """An HTTP failure whose message omits credential-bearing response bodies."""

    def __init__(self, method: str, url: str, status: int):
        self.status = status
        super().__init__(f"{method} {url}: HTTP {status}")


def request_json(url, *, method="GET", body=None, headers=None, verify=True):
    """Send JSON with a bounded timeout; authentication stays in headers/body."""
    request_headers = {"Accept": "application/json", **(headers or {})}
    payload = None
    if body is not None:
        request_headers["Content-Type"] = "application/json"
        payload = json.dumps(body).encode()
    request = urllib.request.Request(url, data=payload, headers=request_headers, method=method)
    context = None if verify else ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(request, context=context, timeout=30) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        exc.close()
        raise APIError(method, url, exc.code) from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Cannot reach {url}: {exc.reason}") from None
    try:
        return json.loads(raw) if raw else {}
    except ValueError:
        raise RuntimeError(f"{method} {url}: expected a JSON response") from None


@dataclass
class SoftwareHub:
    url: str
    token: str = field(repr=False)
    verify: bool = True

    @classmethod
    def sign_in(cls, url, username, *, password="", api_key="", verify=True):
        """Use an administrator's existing credentials; never generate API keys."""
        url = url.rstrip("/")
        credentials = [("api_key", api_key), ("password", password)]
        available = [(kind, secret) for kind, secret in credentials if secret]
        if not username or not available:
            raise ValueError("Supply CPD_USERNAME and CPD_APIKEY or CPD_PASSWORD")
        for index, (kind, secret) in enumerate(available):
            try:
                result = request_json(
                    url + "/icp4d-api/v1/authorize",
                    method="POST",
                    body={"username": username, kind: secret},
                    verify=verify,
                )
            except APIError as exc:
                if exc.status == 401 and index + 1 < len(available):
                    continue
                raise
            if not result.get("token"):
                raise RuntimeError("Software Hub sign-in returned no bearer token")
            return cls(url, result["token"], verify)

    def request(self, path, *, method="GET", body=None):
        return request_json(
            self.url + path,
            method=method,
            body=body,
            headers={"Authorization": "Bearer " + self.token},
            verify=self.verify,
        )

    def collection(self, path, key):
        """Read all pages and reject a server that repeatedly returns one page."""
        rows, seen = [], set()
        separator = "&" if "?" in path else "?"
        while True:
            page = self.request(f"{path}{separator}offset={len(rows)}&limit=100")
            batch = page.get(key, [])
            if not batch:
                return rows
            marker = json.dumps(batch, sort_keys=True)
            if marker in seen:
                raise RuntimeError(f"Pagination did not advance for {path}")
            seen.add(marker)
            rows.extend(batch)
            total = page.get("total_count")
            if total is not None and len(rows) >= int(total):
                return rows
            if len(batch) < int(page.get("limit") or 100):
                return rows

    def find_instance(self, name, addon_type):
        query = urllib.parse.urlencode({"display_name": name, "addon_type": addon_type})
        rows = self.collection("/zen-data/v3/service_instances?" + query, "service_instances")
        matches = [x for x in rows if x["display_name"] == name and x["addon_type"] == addon_type]
        if len(matches) != 1:
            raise RuntimeError(f"Expected one {addon_type!r} instance named {name!r}; found {len(matches)}")
        return matches[0]

    def user(self, username):
        """Return an existing platform user, or None for HTTP 404."""
        path = "/usermgmt/v1/user/" + urllib.parse.quote(username, safe="")
        try:
            return self.request(path)
        except APIError as exc:
            if exc.status == 404:
                return None
            raise

    def member(self, instance_id, username):
        instance_id = urllib.parse.quote(str(instance_id), safe="")
        rows = self.collection(f"/zen-data/v3/service_instances/{instance_id}/users", "users")
        return next((x for x in rows if x["user_name"] == username), None)

    def ensure_role(self, instance_id, username, role, *, dry_run=False):
        """Add or update only this user's instance role; preserve other members."""
        current = self.member(instance_id, username)
        if current and current["role"] == role:
            return "unchanged"
        user = self.user(username)
        if not user:
            raise RuntimeError(f"Software Hub user {username!r} is not registered")
        uid = str(user["uid"])
        action = "updated" if current else "added"
        if dry_run:
            return action
        body = {"serviceInstanceID": str(instance_id)}
        if current:
            body["roles"] = [{"uid": uid, "username": username, "newrole": role}]
            self.request("/zen-data/v2/serviceInstance/users/role", method="PATCH", body=body)
        else:
            body["users"] = [{"uid": uid, "username": username, "role": role}]
            self.request("/zen-data/v2/serviceInstance/users", method="POST", body=body)
        member = self.member(instance_id, username)
        if not member or member["role"] != role:
            raise RuntimeError(f"Could not verify {role!r} for {username!r}")
        return action
