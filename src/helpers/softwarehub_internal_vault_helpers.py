"""Manage secrets in the IBM Software Hub (Zen) vaults through ``/zen-data/v2/secrets``.

API reference: ``.claude/docs/softwarehub-secrets-api.md``. Used by
``src/utilities/softwarehub_utils/store_cpd_apikeys_in_vault.sh`` and
``scripts/install_confluent_platform/utility_scripts_confluent_platform/x.5_confluent_add_cert_to_vault.sh``.

Sign in, then work with the secrets the signed-in user owns or is a member of::

    from src.helpers.softwarehub_internal_vault_helpers import (
        SoftwareHubVault, key_secret, secret_name_for,
    )

    vault = SoftwareHubVault.sign_in(os.environ["CPD_URL"], "cpadmin", api_key=os.environ["CPD_APIKEY"])
    urn = vault.create_secret("artifactory-api-key", key_secret("..."), type="key")
    vault.get_secret_value(urn)                    # {"key": "..."}
    vault.update_secret(urn, secret=key_secret("new value"))
    vault.delete_secret(urn)

    # Create, update or leave alone, whatever is needed:
    vault.store_secret(secret_name_for("svc_a", "apikey"), key_secret("..."), type="key")

Things the API does that its docs don't say (seen on a live cluster):

* Secret names may only hold letters, digits and ``-`` (``secret_name_for`` makes one).
* Listing the owner in ``members`` makes the create fail with HTTP 500 *and*
  leaves an unlisted record behind that blocks the name (HTTP 409 from then on).
  ``store_secret`` drops the owner from ``members`` for that reason.
* The list also returns secrets the caller is only a member of. A secret's urn is
  ``<owner uid>:<secret_name>``, which is how ``find_secret`` picks the caller's own.
* ``members`` can only be set on create, and a secret's type can't be changed.
* A group's ``group_id`` must be sent as a string, though the groups API returns
  a number; ``members()`` converts it. Sharing with a group that contains the
  owner (e.g. "All Users", id 10000) is fine.
"""

from __future__ import annotations

import base64
import re
import warnings
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

import requests

# The internal vault every Software Hub has.
DEFAULT_VAULT_URN = "0000000000:internal"
SECRET_TYPES = ("certificate", "credentials", "generic", "key", "token", "kerberos_credentials")
SECRET_NAME_MAX_LENGTH = 110
SECRETS_PATH = "/zen-data/v2/secrets"
GROUPS_PATH = "/usermgmt/v4/groups"
# The built-in group every Software Hub user is implicitly part of.
ALL_USERS_GROUP_NAME = "All users"
ALL_USERS_GROUP_ID = 10000

# Keys whose values redact() hides, and those it shortens.
_HIDDEN_KEYS = frozenset({"secret", "generic", "key", "credentials", "certificate",
                          "api_key", "apiKey", "zen_api_key", "password"})
_TOKEN_KEYS = frozenset({"token", "accessToken"})

# Called after every API call with (method, path, status code, parsed body or text).
ResponseHook = Callable[[str, str, int, Any], None]


class VaultError(Exception):
    """Base class for every error this module raises."""


class VaultAPIError(VaultError):
    """An API call answered with a non-2xx status, or could not be made (status 0)."""

    def __init__(self, method: str, path: str, status_code: int, body: Any) -> None:
        self.method, self.path, self.status_code, self.body = method, path, status_code, body
        super().__init__(f"{method} {path}: HTTP {status_code}: {error_message(body)}")


class SecretNameTakenError(VaultAPIError):
    """Create got HTTP 409 for a name the caller has no secret under.

    Typically a record left behind by an earlier create that failed with HTTP
    500. The API can't list or delete it; it has to be removed from the
    Software Hub metastore before the name can be used again.
    """


# --- Secret payloads ---------------------------------------------------------------------
# The 'secret' object for each type in the internal vault, as in the API samples.

def generic_secret(values: Mapping[str, Any] | None = None, **more: Any) -> dict[str, Any]:
    """``{"generic": {...}}``: any key/value pairs."""
    return {"generic": {**(values or {}), **more}}


def credentials_secret(username: str, password: str) -> dict[str, Any]:
    """``{"credentials": {"username", "password"}}``."""
    return {"credentials": {"username": username, "password": password}}


def certificate_secret(cert: str, key: str | None = None) -> dict[str, Any]:
    """``{"certificate": {"cert", "key"}}``, the private key being optional."""
    return {"certificate": {"cert": cert, **({"key": key} if key is not None else {})}}


def key_secret(value: str) -> dict[str, Any]:
    """``{"key": "<value>"}``."""
    return {"key": value}


def token_secret(value: str) -> dict[str, Any]:
    """``{"token": "<value>"}``."""
    return {"token": value}


def members(users: Sequence[str | Mapping[str, str]] = (),
            groups: Sequence[str | Mapping[str, str]] = ()) -> dict[str, Any]:
    """The ``members`` object of a new secret.

    A user is ``{"uid", "username", "email"}`` (any of them) or just a username;
    a group is ``{"group_id", "group_name"}`` or just a group id.

    ``group_id`` is sent as a string: the secrets API rejects a number with
    HTTP 400 ("cannot unmarshal number ... group_id of type string"), although
    the groups API (/usermgmt/v4/groups) returns it as one.
    """
    out: dict[str, Any] = {}
    if users:
        out["users"] = [{"username": u} if isinstance(u, str) else dict(u) for u in users]
    if groups:
        out["groups"] = [{"group_id": str(g)} if isinstance(g, (str, int)) else
                         {**g, "group_id": str(g["group_id"])} for g in groups]
    return out


def secret_name_for(text: str, suffix: str = "") -> str:
    """A valid secret name from TEXT (e.g. a username) and an optional SUFFIX.

    Every character other than a letter, digit or '-' becomes '-':
    ``secret_name_for("cpd_service_id_1", "apikey") == "cpd-service-id-1-apikey"``.
    """
    name = re.sub(r"[^A-Za-z0-9-]", "-", f"{text}-{suffix}" if suffix else text)
    if not name or len(name) > SECRET_NAME_MAX_LENGTH:
        raise VaultError(f"Secret name '{name}' must be 1-{SECRET_NAME_MAX_LENGTH} characters.")
    return name


def zen_api_key(username: str, api_key: str) -> str:
    """The token for ``Authorization: ZenApiKey <token>``: base64 of 'username:api_key'."""
    return base64.b64encode(f"{username}:{api_key}".encode()).decode()


# --- Showing responses -----------------------------------------------------------------------

def redact(value: Any) -> Any:
    """A copy of VALUE with secret contents hidden and tokens shortened, for printing."""
    if isinstance(value, Mapping):
        out = {}
        for k, v in value.items():
            if k in _TOKEN_KEYS and isinstance(v, str):
                out[k] = f"{v[:12]}... ({len(v)} chars)"
            elif k in _HIDDEN_KEYS:
                out[k] = "(hidden)"
            else:
                out[k] = redact(v)
        return out
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


def error_message(body: Any) -> str:
    """The error text in an API response body, else the body itself (shortened)."""
    if isinstance(body, Mapping):
        errors = body.get("errors")
        if isinstance(errors, list) and errors and isinstance(errors[0], Mapping):
            e = errors[0]
            return str(e.get("message") or e.get("code") or e)
        for k in ("message", "_messageCode_", "error", "exception"):
            if body.get(k):
                return str(body[k])
    text = body if isinstance(body, str) else repr(redact(body))
    return text[:2000] if text else "(empty response)"


# --- Client ------------------------------------------------------------------------------------

@dataclass
class StoreResult:
    """What ``store_secret`` did: 'created', 'updated', 'unchanged' or 'replaced'
    (deleted and created again, because the existing secret had another type)."""

    action: str
    urn: str
    previous_type: str | None = None


@dataclass
class SoftwareHubVault:
    """A Software Hub user's view of the vaults.

    ``url`` is the Software Hub URL (``https://cpd-<ns>.apps.<cluster>``) and
    ``token`` a bearer token, or with ``auth_scheme="ZenApiKey"`` the base64
    token from ``zen_api_key()``. Use ``sign_in`` or ``from_api_key`` rather than
    building one by hand. Certificates aren't checked unless ``verify`` is set
    (a CA bundle path or True), like ``curl -k`` in the shell scripts.
    """

    url: str
    token: str
    auth_scheme: str = "Bearer"
    verify: bool | str = False
    timeout: float = 60
    on_response: ResponseHook | None = None
    _uid: str | None = field(default=None, init=False, repr=False)
    _session: requests.Session = field(default_factory=requests.Session, init=False, repr=False)

    def __post_init__(self) -> None:
        self.url = _normalise_url(self.url)
        if self.verify is False:
            warnings.filterwarnings("ignore", message="Unverified HTTPS request")

    # -- Sign-in --

    @classmethod
    def sign_in(cls, url: str, username: str, *, api_key: str | None = None,
                password: str | None = None, **kwargs: Any) -> SoftwareHubVault:
        """Sign in with an API key or a password (POST /icp4d-api/v1/authorize)."""
        if (api_key is None) == (password is None):
            raise VaultError("Pass exactly one of api_key and password.")
        payload = {"username": username, **({"api_key": api_key} if api_key is not None else {"password": password})}
        client = cls(url, token="", **kwargs)
        body = client._request("POST", "/icp4d-api/v1/authorize", json=payload, auth=False)
        token = (body or {}).get("token") or (body or {}).get("accessToken")
        if not token:
            raise VaultAPIError("POST", "/icp4d-api/v1/authorize", 200, body)
        client.token = token
        return client

    @classmethod
    def from_api_key(cls, url: str, username: str, api_key: str, **kwargs: Any) -> SoftwareHubVault:
        """Use an API key directly (``Authorization: ZenApiKey``), without signing in."""
        return cls(url, token=zen_api_key(username, api_key), auth_scheme="ZenApiKey", **kwargs)

    def current_user(self) -> dict[str, Any]:
        """The signed-in user (GET /usermgmt/v1/user/currentUserInfo)."""
        return self._request("GET", "/usermgmt/v1/user/currentUserInfo") or {}

    def current_uid(self) -> str | None:
        """The signed-in user's uid, the owner part of its secrets' urns."""
        if self._uid is None:
            info = self.current_user()
            uid = info.get("uid") or (info.get("UserInfo") or {}).get("uid")
            self._uid = str(uid) if uid is not None else None
        return self._uid

    # -- User groups (for a secret's members) --

    def iter_groups(self, *, page_size: int = 100) -> Iterator[dict[str, Any]]:
        """Every user group (GET /usermgmt/v4/groups): ``{"group_id", "name", "roles", ...}``."""
        offset = 0
        while True:
            page = self._request("GET", GROUPS_PATH, params={"offset": offset, "limit": page_size}) or {}
            items = page if isinstance(page, list) else page.get("results") or []
            yield from items
            offset += len(items)
            if len(items) < page_size:
                return

    def find_group(self, name: str) -> dict[str, Any] | None:
        """The group named NAME (case-insensitive), or None.

        The built-in 'All users' group is also looked up by its fixed id, in
        case the list leaves it out.
        """
        for g in self.iter_groups():
            if str(g.get("name", "")).casefold() == name.casefold():
                return g
        if name.casefold() == ALL_USERS_GROUP_NAME.casefold():
            try:
                g = self._request("GET", f"{GROUPS_PATH}/{ALL_USERS_GROUP_ID}") or {}
            except VaultAPIError:
                return None
            g = g.get("results", g) if isinstance(g, Mapping) else g
            g = g[0] if isinstance(g, list) and g else g
            if isinstance(g, Mapping) and g.get("group_id") is not None:
                return dict(g)
        return None

    # -- The secrets API --

    def list_secrets(self, *, offset: int = 0, limit: int = 50, include_secrets_preview: bool = False,
                     sort: str | None = None, type: str | None = None, secret_name: str | None = None,
                     match: str | None = None, include_secrets_for_management: bool = False) -> dict[str, Any]:
        """One page of secrets (GET /zen-data/v2/secrets): ``{"secrets", "total_count", ...}``.

        ``sort`` is a column (secret_name, type, description, created_by,
        vault_name, updated_at), '-' in front for descending. ``match`` is
        'any' or 'all'. ``include_secrets_for_management`` returns every
        secret when the caller may manage vaults and secrets.
        """
        params = {
            "offset": offset, "limit": limit, "sort": sort, "type": type, "secret_name": secret_name,
            "match": match, "include_secrets_preview": include_secrets_preview or None,
            "include_secrets_for_management": include_secrets_for_management or None,
        }
        return self._request("GET", SECRETS_PATH, params=params) or {}

    def iter_secrets(self, *, page_size: int = 100, **filters: Any) -> Iterator[dict[str, Any]]:
        """Every secret ``list_secrets`` returns for FILTERS, page by page."""
        offset = 0
        while True:
            page = self.list_secrets(offset=offset, limit=page_size, **filters)
            items = page.get("secrets") or []
            yield from items
            offset += len(items)
            if len(items) < page_size or offset >= int(page.get("total_count") or 0):
                return

    def get_secret(self, urn: str, *, exclude_secret_data: bool = False) -> dict[str, Any]:
        """A secret (GET /zen-data/v2/secrets/{urn}): ``{"data": {"secret"}, "metadata": {...}}``.

        ``exclude_secret_data=True`` is refused (HTTP 400) for secrets in the
        internal vault; it only works for references to external vaults.
        """
        return self._request("GET", f"{SECRETS_PATH}/{urn}",
                             params={"exclude_secret_data": str(exclude_secret_data).lower()}) or {}

    def get_secret_value(self, urn: str) -> dict[str, Any]:
        """Just the secret object, e.g. ``{"key": "..."}``."""
        return (self.get_secret(urn).get("data") or {}).get("secret") or {}

    def get_secret_metadata(self, urn: str) -> dict[str, Any]:
        """Name, type, owner_uid, description, timestamps... without the secret itself.

        Fetches the whole secret: exclude_secret_data is refused for the internal vault.
        """
        return self.get_secret(urn).get("metadata") or {}

    def create_secret(self, name: str, secret: Mapping[str, Any], *, type: str = "generic",
                      vault_urn: str = DEFAULT_VAULT_URN, description: str | None = None,
                      members: Mapping[str, Any] | None = None, validate: bool = False,
                      validate_and_save: bool = False) -> str:
        """Create a secret (POST /zen-data/v2/secrets) and return its urn.

        For a reference to an external vault, ``secret`` is the reference
        (e.g. ``{"path": ...}`` for HashiCorp) and ``validate`` /
        ``validate_and_save`` check it.
        """
        if type not in SECRET_TYPES:
            raise VaultError(f"Unknown secret type '{type}' ({', '.join(SECRET_TYPES)}).")
        payload: dict[str, Any] = {"secret_name": name, "secret": dict(secret), "type": type, "vault_urn": vault_urn}
        if description is not None:
            payload["description"] = description
        if members:
            payload["members"] = dict(members)
        body = self._request("POST", SECRETS_PATH, json=payload,
                             params=_validate_params(validate, validate_and_save))
        return (body or {}).get("secret_urn") or f"{self.current_uid()}:{name}"

    def update_secret(self, urn: str, *, secret: Mapping[str, Any] | None = None,
                      description: str | None = None, validate: bool = False,
                      validate_and_save: bool = False) -> dict[str, Any]:
        """Replace a secret's value and/or description (PATCH /zen-data/v2/secrets/{urn}).

        The name, vault and type can't be changed; members can't be either.
        """
        payload = {k: v for k, v in (("secret", dict(secret) if secret is not None else None),
                                     ("description", description)) if v is not None}
        if not payload:
            raise VaultError("Nothing to update: pass secret and/or description.")
        return self._request("PATCH", f"{SECRETS_PATH}/{urn}", json=payload,
                             params=_validate_params(validate, validate_and_save)) or {}

    def delete_secret(self, urn: str) -> None:
        """Delete a secret, or a reference to an external vault (DELETE /zen-data/v2/secrets/{urn})."""
        self._request("DELETE", f"{SECRETS_PATH}/{urn}")

    # -- Higher level --

    def find_secret(self, name: str, *, owner_uid: str | None = None,
                    vault_urn: str = DEFAULT_VAULT_URN) -> dict[str, Any] | None:
        """The list entry of the secret named exactly NAME in the vault, owned by
        OWNER_UID (default: the signed-in user), or None."""
        owner_uid = owner_uid or self.current_uid()
        vault_name = vault_urn.split(":", 1)[-1]
        for s in self.iter_secrets(secret_name=name):
            if (s.get("secret_name") == name and s.get("vault_name", vault_name) == vault_name
                    and (not owner_uid or str(s.get("secret_urn", "")).startswith(f"{owner_uid}:"))):
                return s
        return None

    def store_secret(self, name: str, secret: Mapping[str, Any], *, type: str = "generic",
                     vault_urn: str = DEFAULT_VAULT_URN, description: str | None = None,
                     members: Mapping[str, Any] | None = None,
                     replace_other_type: bool = True) -> StoreResult:
        """Make the signed-in user's secret NAME hold SECRET: create it, update it,
        or leave it alone if it already does.

        A secret's type can't be changed, so one of another type is deleted and
        created again (``replace_other_type``), or else VaultError is raised.
        ``members`` only applies when the secret is created; the owner is taken
        out of it, since listing the owner breaks the create (see module docs).
        """
        uid = self.current_uid()
        existing = self.find_secret(name, owner_uid=uid, vault_urn=vault_urn)
        previous_type = None
        if existing and existing.get("type") and existing["type"] != type:
            if not replace_other_type:
                raise VaultError(f"Secret '{name}' is of type '{existing['type']}', not '{type}'.")
            previous_type = existing["type"]
            self.delete_secret(existing["secret_urn"])
            existing = None

        if existing is None:
            if members and uid:
                users = [u for u in members.get("users") or [] if str(u.get("uid")) != uid]
                members = {k: v for k, v in (("users", users), ("groups", members.get("groups"))) if v} or None
            try:
                urn = self.create_secret(name, secret, type=type, vault_urn=vault_urn,
                                         description=description, members=members)
            except VaultAPIError as e:
                if e.status_code == 409:
                    raise SecretNameTakenError(e.method, e.path, e.status_code, e.body) from e
                raise
            return StoreResult("replaced" if previous_type else "created", urn, previous_type)

        urn = existing["secret_urn"]
        current = self.get_secret(urn)
        meta = current.get("metadata") or {}
        if (current.get("data") or {}).get("secret") == dict(secret) and (
                description is None or "description" not in meta or meta["description"] == description):
            return StoreResult("unchanged", urn)
        self.update_secret(urn, secret=secret, description=description)
        return StoreResult("updated", urn)

    # -- Plumbing --

    def _request(self, method: str, path: str, *, params: Mapping[str, Any] | None = None,
                 json: Any = None, auth: bool = True) -> Any:
        headers = {"Accept": "application/json"}
        if auth:
            headers["Authorization"] = f"{self.auth_scheme} {self.token}"
        params = {k: v for k, v in (params or {}).items() if v is not None}
        try:
            resp = self._session.request(method, self.url + path, params=params, json=json,
                                         headers=headers, verify=self.verify, timeout=self.timeout)
        except requests.RequestException as e:
            body = f"(no response: could not reach {self.url}, or it timed out: {e})"
            if self.on_response:
                self.on_response(method, path, 0, body)
            raise VaultAPIError(method, path, 0, body) from e
        try:
            body = resp.json() if resp.content else None
        except ValueError:
            body = resp.text
        if self.on_response:
            self.on_response(method, path, resp.status_code, body)
        if not 200 <= resp.status_code < 300:
            raise VaultAPIError(method, path, resp.status_code, body)
        return body


def _normalise_url(url: str) -> str:
    url = url.strip().rstrip("/")
    if not url:
        raise VaultError("No Software Hub URL.")
    return url if url.startswith(("http://", "https://")) else f"https://{url}"


def _validate_params(validate: bool, validate_and_save: bool) -> dict[str, str]:
    return {k: "true" for k, v in (("validate", validate), ("validate_and_save", validate_and_save)) if v}
