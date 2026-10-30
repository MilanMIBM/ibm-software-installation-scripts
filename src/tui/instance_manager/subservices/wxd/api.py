"""The lakehouse REST API of one watsonx.data instance (sub-plan §4.2).

Auth: the Software Hub bearer token (CPD_URL / CPD_USERNAME / CPD_APIKEY, the same
credentials 5_create_wxd_presto_engine.sh uses; never printed) plus the header
AuthInstanceId = the Wxd instance's zen id. Reuses src/helpers' request_json.
The engine types and their requests come from the API's embedded spec (embedded_spec.py).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

BASE = "/lakehouse/api/v3"


def _helpers():
    for parent in Path(__file__).resolve().parents:
        cand = parent / "helpers" / "softwarehub_service_instance_helpers.py"
        if cand.is_file():
            if str(cand.parent) not in sys.path:
                sys.path.insert(0, str(cand.parent))
            import softwarehub_service_instance_helpers as h
            return h
    raise ImportError("src/helpers/softwarehub_service_instance_helpers.py not found")


class LakehouseAPI:
    def __init__(self, instance_id: str, url: str | None = None, username: str | None = None,
                 api_key: str | None = None, verify: bool = False):
        self.instance_id = str(instance_id)
        self.url = (url or os.environ.get("CPD_URL") or "").rstrip("/")
        self._user = username or os.environ.get("CPD_USERNAME") or ""
        self._key = api_key or os.environ.get("CPD_APIKEY") or ""
        self.verify = verify
        self._token: str | None = None

    @property
    def configured(self) -> bool:
        return bool(self.url and self._user and self._key)

    def _sign_in(self) -> str:
        if self._token is None:
            h = _helpers()
            self._token = h.SoftwareHub.sign_in(self.url, self._user, api_key=self._key, verify=self.verify).token
        return self._token

    def request(self, method: str, path: str, body=None):
        h = _helpers()
        headers = {"Authorization": "Bearer " + self._sign_in(), "AuthInstanceId": self.instance_id}
        return h.request_json(self.url + BASE + path, method=method, body=body, headers=headers, verify=self.verify)

    def status_of(self, exc) -> int | None:
        return getattr(exc, "status", None)
