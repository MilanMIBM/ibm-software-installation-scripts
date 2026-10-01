"""Helpers for talking to the IBM License Service that cp4d_config/ points at.

The License Service exposes two authentication methods, both of which this
module supports and neither of which excludes the other by default:

    URL token       ``<url>/products?token=<token>``
                    Backed by the ``ibm-licensing-token`` Opaque secret.
                    Gated on the CR by ``spec.features.auth.urlBasedEnabled``.

    Bearer token    ``Authorization: Bearer <service account token>``
                    Backed by a service-account-token secret, by default the
                    one for ``ibm-licensing-default-reader``. Authorisation is
                    a ClusterRole over ``nonResourceURLs``. Gated on the CR by
                    ``spec.features.kubeRBACAuthEnabled``.

Everything defaults from the environment that ``cp4d_config/`` exports
(``IBM_LICENSING_SERVICE_INSTANCE``, ``IBM_LICENSING_TOKEN``,
``PROJECT_LICENSE_SERVICE``), so in a shell that has sourced the repo env this
is enough::

    from src.helpers.ibm_licensing_operator_helpers import IBMLicensingClient

    client = IBMLicensingClient()
    client.products()

Any of it can equally be passed in explicitly, which is what you want from a
notebook or a test against a cluster you have not sourced::

    client = IBMLicensingClient(
        url="https://ibm-licensing-service-instance-ibm-licensing.apps.example.com",
        token="...",
        auth="url",
    )

Credentials can also be read straight off the cluster with ``oc``/``kubectl``,
which is how you bootstrap before ``3.3.1_get_instance_creds.sh`` has run::

    client = IBMLicensingClient.from_cluster(namespace="ibm-licensing")

Token lifecycle (create / refresh / delete) lives on ``LicensingTokenManager``
and is also reachable from the client as ``client.tokens``.

Any of the reporting endpoints can return a ``pandas.DataFrame`` instead of
parsed JSON. Set the default for a client and override it per call::

    client = IBMLicensingClient(as_dataframe=True)
    client.products()                    # DataFrame
    client.products(as_dataframe=False)  # list[dict]

pandas is imported only when a DataFrame is actually asked for, so the rest of
the module works on a machine without it.
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import shutil
import string
import subprocess
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path
from typing import Any, Iterable, Literal, Mapping, Sequence

import requests

__all__ = [
    "IBMLicensingClient",
    "IBMLicensingError",
    "IBMLicensingAPIError",
    "IBMLicensingAuthError",
    "IBMLicensingConfigError",
    "LicensingTokenManager",
    "LicensingAuth",
    "UrlTokenAuth",
    "BearerTokenAuth",
    "to_dataframe",
]

# Secret / resource names the operator creates. These are fixed by the
# operator, not by us, and the default-reader token secret really is unsuffixed
# on 4.2.x even though the documentation shows a random "-xxxxx" suffix.
TOKEN_SECRET = "ibm-licensing-token"
UPLOAD_TOKEN_SECRET = "ibm-licensing-upload-token"
DEFAULT_READER_SA = "ibm-licensing-default-reader"
DEFAULT_READER_TOKEN_SECRET = "ibm-licensing-default-reader-token"
SERVICE_ROUTE = "ibm-licensing-service-instance"
SERVICE_POD_LABEL = "app=ibm-licensing-service-instance"
DEFAULT_NAMESPACE = "ibm-licensing"
DEFAULT_CR_NAME = "instance"

# The token is passed as a URL query parameter, so anything with query-string
# meaning would silently truncate it. IBM documents ?, % and & as forbidden;
# whitespace is excluded for the same reason.
FORBIDDEN_TOKEN_CHARS = frozenset("?%& \t\n\r")

# Endpoints that return something other than JSON, so callers get bytes/str
# instead of a failed json() call.
_ZIP_PATHS = frozenset({"/snapshot"})
_HTML_PATHS = frozenset({"/status"})


class IBMLicensingError(Exception):
    """Base class for every error this module raises."""


class IBMLicensingConfigError(IBMLicensingError):
    """Configuration is missing or internally inconsistent."""


class IBMLicensingAPIError(IBMLicensingError):
    """The License Service returned a non-2xx response.

    The service returns an HTML error page rather than JSON, so ``message``
    carries the parsed-out status line where one could be found and the raw
    body otherwise.
    """

    def __init__(self, status_code: int, message: str, url: str = "") -> None:
        self.status_code = status_code
        self.message = message
        self.url = url
        super().__init__(f"HTTP {status_code} from {url or 'License Service'}: {message}")


class IBMLicensingAuthError(IBMLicensingAPIError):
    """Authentication or authorisation was rejected (401/403)."""


# ---------------------------------------------------------------------------
# Authentication strategies
# ---------------------------------------------------------------------------


class LicensingAuth:
    """How a request proves who it is. Subclasses mutate params or headers."""

    name: str = "none"

    def apply(self, params: dict[str, Any], headers: dict[str, str]) -> None:
        raise NotImplementedError

    def describe(self) -> str:
        return self.name


@dataclass
class UrlTokenAuth(LicensingAuth):
    """``?token=<token>`` — the License Service API token.

    Requires ``spec.features.auth.urlBasedEnabled`` to not be false on the CR.
    """

    token: str
    name: str = field(default="url", init=False)

    def apply(self, params: dict[str, Any], headers: dict[str, str]) -> None:
        params["token"] = self.token

    def describe(self) -> str:
        return f"url token (…{self.token[-4:]})" if self.token else "url token (empty)"


@dataclass
class BearerTokenAuth(LicensingAuth):
    """``Authorization: Bearer <token>`` — a Kubernetes service account token.

    Requires ``spec.features.kubeRBACAuthEnabled`` to not be false on the CR,
    and the service account to be bound to a ClusterRole granting ``get`` on
    the ``nonResourceURLs`` being called.
    """

    token: str
    name: str = field(default="bearer", init=False)

    def apply(self, params: dict[str, Any], headers: dict[str, str]) -> None:
        headers["Authorization"] = f"Bearer {self.token}"

    def describe(self) -> str:
        return f"bearer token (…{self.token[-4:]})" if self.token else "bearer token (empty)"


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def _kube_cli() -> str:
    """Return whichever of oc/kubectl is on PATH, preferring oc."""
    for candidate in ("oc", "kubectl"):
        found = shutil.which(candidate)
        if found:
            return found
    raise IBMLicensingConfigError(
        "Neither 'oc' nor 'kubectl' is on PATH; cannot read licensing credentials "
        "from the cluster. Pass url/token explicitly instead."
    )


def _run(args: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess:
    """Run a command, capturing both streams as text.

    Errors are never swallowed: a failing call surfaces the command's own
    stderr, because a silently empty result here looks identical to a genuinely
    absent secret and sends you looking in the wrong place.
    """
    proc = subprocess.run(args, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise IBMLicensingConfigError(
            f"Command failed ({' '.join(args[:3])}…, exit {proc.returncode}): "
            f"{proc.stderr.strip() or proc.stdout.strip() or 'no output'}"
        )
    return proc


def _decode_secret_field(raw: str) -> str:
    """base64-decode a ``.data`` field from a secret."""
    if not raw:
        return ""
    return base64.b64decode(raw).decode("utf-8").strip()


def _normalise_url(url: str) -> str:
    """Give a bare hostname a scheme and drop any trailing slash."""
    url = (url or "").strip().rstrip("/")
    if url and "://" not in url:
        url = f"https://{url}"
    return url


def _as_date_string(value: str | date | datetime | None) -> str | None:
    """Accept a date/datetime/string and return the YYYY-MM-DD the API wants."""
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    value = str(value).strip()
    if not value:
        return None
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError as exc:
        raise IBMLicensingConfigError(
            f"Date {value!r} is not in the YYYY-MM-DD format the API requires."
        ) from exc
    return value


def _extract_error_message(body: str) -> str:
    """Pull a human message out of the service's HTML error page.

    The service answers failures with an HTML page, not JSON, so a plain
    ``response.json()`` would raise and hide the real status.
    """
    body = (body or "").strip()
    if not body:
        return "empty response body"
    if body.lstrip().startswith("{"):
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            pass
        else:
            for key in ("message", "error", "detail"):
                if isinstance(parsed, dict) and parsed.get(key):
                    return str(parsed[key])
            return json.dumps(parsed)[:500]
    # <div>Message: <b>Unauthorized</b></div>
    marker = "Message:"
    if marker in body:
        tail = body.split(marker, 1)[1]
        for opener, closer in (("<b>", "</b>"), (">", "<")):
            if opener in tail and closer in tail.split(opener, 1)[1]:
                return tail.split(opener, 1)[1].split(closer, 1)[0].strip()
    return body[:500]


def generate_token(length: int = 24) -> str:
    """Generate a token that is safe to pass as a URL query parameter.

    Drawn from letters and digits only, so it can never contain the ``?``,
    ``%``, ``&`` or whitespace that would break ``?token=`` addressing.
    """
    if length < 8:
        raise IBMLicensingConfigError("Refusing to generate a token shorter than 8 characters.")
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def validate_token(token: str) -> str:
    """Reject tokens the service cannot address, before they are written."""
    token = (token or "").strip()
    if not token:
        raise IBMLicensingConfigError("Token is empty.")
    bad = sorted(FORBIDDEN_TOKEN_CHARS & set(token))
    if bad:
        shown = ", ".join(repr(c) for c in bad)
        raise IBMLicensingConfigError(
            f"Token contains characters that are invalid in a URL parameter: {shown}. "
            "IBM forbids '?', '%' and '&'; whitespace breaks the query string too."
        )
    return token


# ---------------------------------------------------------------------------
# DataFrame conversion
# ---------------------------------------------------------------------------

# Columns worth parsing to real dtypes rather than leaving as strings, so that
# sorting and filtering behave. Everything else is left exactly as the API
# sent it.
_DATE_COLUMNS = frozenset({"metricPeakDate", "metricDate"})
_NUMERIC_COLUMNS = frozenset(
    {
        "metricQuantity",
        "metricMeasuredQuantity",
        "metricConvertedQuantity",
        "serviceMetricValue",
        "count",
    }
)


def _require_pandas() -> Any:
    """Import pandas on demand, with an actionable error when it is absent.

    Imported lazily so that the JSON path of this module keeps working on an
    install without pandas; only asking for a DataFrame requires it.
    """
    try:
        import pandas as pd
    except ImportError as exc:  # pragma: no cover - depends on the install
        raise IBMLicensingConfigError(
            "as_dataframe=True requires pandas, which is not installed. "
            "Install it with 'uv pip install pandas' (or 'pip install pandas')."
        ) from exc
    return pd


def to_dataframe(
    payload: Any,
    *,
    parse_dtypes: bool = True,
    columns: Sequence[str] | None = None,
) -> Any:
    """Convert a License Service JSON payload into a ``pandas.DataFrame``.

    Handles the three shapes the API actually returns:

    * a list of flat records (``/products``, ``/bundled_products``,
      ``/services``) becomes one row per record;
    * ``/health`` is unwrapped to its ``incompleteAnnotations.pods`` list, so
      the frame holds the offending pods rather than a single summary row
      (``count`` is recoverable as ``len(df)``);
    * a single object (``/version``) becomes a one-row frame.

    An empty result still returns a frame with the expected columns where they
    are known, so downstream code can select columns without a KeyError on a
    cluster that happens to report nothing.
    """
    pd = _require_pandas()

    if payload is None:
        return pd.DataFrame(columns=list(columns) if columns else None)

    # Already a frame (e.g. re-converting) - leave it alone.
    if isinstance(payload, pd.DataFrame):
        return payload

    records: Any
    if isinstance(payload, Mapping):
        # /health nests the rows one level down; a bare summary row would be
        # useless next to a list of pods.
        annotations = payload.get("incompleteAnnotations")
        if isinstance(annotations, Mapping) and "pods" in annotations:
            records = annotations.get("pods") or []
        else:
            records = [payload]
    elif isinstance(payload, (list, tuple)):
        records = list(payload)
    else:
        raise IBMLicensingConfigError(
            f"Cannot convert {type(payload).__name__} to a DataFrame. CSV and "
            "snapshot responses are not JSON; request them without "
            "as_dataframe, or use output_format='csv' and parse it yourself."
        )

    frame = pd.DataFrame(records)

    if frame.empty and columns:
        frame = pd.DataFrame(columns=list(columns))

    if parse_dtypes and not frame.empty:
        for column in frame.columns:
            if column in _DATE_COLUMNS:
                # errors="coerce" keeps an unparseable date as NaT rather than
                # throwing away the whole response.
                frame[column] = pd.to_datetime(frame[column], errors="coerce")
            elif column in _NUMERIC_COLUMNS:
                frame[column] = pd.to_numeric(frame[column], errors="coerce")

    if columns:
        # Put known columns first in documented order, keep any extras the API
        # adds later rather than silently dropping them.
        ordered = [c for c in columns if c in frame.columns]
        ordered += [c for c in frame.columns if c not in ordered]
        frame = frame[ordered]

    return frame


# Documented column orders, used to shape empty frames and to give a stable
# column order regardless of dict ordering in the response.
_PRODUCT_COLUMNS = ("name", "id", "metricName", "metricQuantity", "metricPeakDate")
_BUNDLED_COLUMNS = (
    "productName",
    "productId",
    "cloudpakId",
    "cloudpakVersion",
    "cloudpakMetricName",
    "metricName",
    "metricPeakDate",
    "metricMeasuredQuantity",
    "metricConversion",
    "metricConvertedQuantity",
)
_SERVICE_COLUMNS = (
    "cloudpakId",
    "cloudpakMetricName",
    "productName",
    "productId",
    "metricName",
    "serviceName",
    "serviceId",
    "serviceMetricValue",
    "metricDate",
    "metricPeakDate",
)
_HEALTH_COLUMNS = ("name", "namespace")


# ---------------------------------------------------------------------------
# Token lifecycle
# ---------------------------------------------------------------------------


@dataclass
class LicensingTokenManager:
    """Create, read, refresh and delete License Service auth material.

    Everything here goes through ``oc``/``kubectl`` against the cluster you are
    currently logged in to; there is no API for token management, the secret is
    the source of truth.
    """

    namespace: str = DEFAULT_NAMESPACE
    cli: str | None = None
    cr_name: str = DEFAULT_CR_NAME

    def __post_init__(self) -> None:
        self.namespace = self.namespace or DEFAULT_NAMESPACE
        self._cli = self.cli or _kube_cli()

    # -- reading ----------------------------------------------------------

    def _get_secret_field(self, secret: str, key: str = "token") -> str:
        proc = _run(
            [self._cli, "get", "secret", secret, "-n", self.namespace,
             "-o", f"jsonpath={{.data.{key}}}"],
            check=False,
        )
        if proc.returncode != 0:
            raise IBMLicensingConfigError(
                f"Could not read secret {secret!r} in namespace {self.namespace!r}: "
                f"{proc.stderr.strip() or 'not found'}"
            )
        return _decode_secret_field(proc.stdout.strip())

    def get_api_token(self) -> str:
        """The URL-parameter API token from ``ibm-licensing-token``."""
        return self._get_secret_field(TOKEN_SECRET)

    def get_upload_token(self) -> str:
        """The upload token from ``ibm-licensing-upload-token``."""
        return self._get_secret_field(UPLOAD_TOKEN_SECRET)

    def get_service_account_token(
        self,
        service_account: str = DEFAULT_READER_SA,
        secret: str | None = None,
    ) -> str:
        """A service account bearer token.

        Looks for the conventional ``<sa>-token`` secret first. On 4.2.x that
        secret exists unsuffixed, but older builds append a random suffix, so
        fall back to scanning the namespace for a service-account-token secret
        annotated for this SA, and finally to minting one with ``create token``.
        """
        if secret:
            return self._get_secret_field(secret)

        conventional = f"{service_account}-token"
        proc = _run(
            [self._cli, "get", "secret", conventional, "-n", self.namespace,
             "-o", "jsonpath={.data.token}"],
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return _decode_secret_field(proc.stdout.strip())

        found = self._find_sa_token_secret(service_account)
        if found:
            return self._get_secret_field(found)

        # No long-lived secret (Kubernetes >=1.24 does not create one by
        # default); mint a short-lived one instead.
        proc = _run(
            [self._cli, "create", "token", service_account, "-n", self.namespace],
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()

        raise IBMLicensingConfigError(
            f"Could not obtain a token for service account {service_account!r} in "
            f"namespace {self.namespace!r}: no '{conventional}' secret, no annotated "
            f"service-account-token secret, and 'create token' failed "
            f"({proc.stderr.strip() or 'no output'})."
        )

    def _find_sa_token_secret(self, service_account: str) -> str | None:
        """Scan for a service-account-token secret belonging to this SA."""
        proc = _run(
            [self._cli, "get", "secrets", "-n", self.namespace,
             "--field-selector", "type=kubernetes.io/service-account-token",
             "-o", "json"],
            check=False,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError:
            return None
        annotation = "kubernetes.io/service-account.name"
        for item in payload.get("items", []):
            annotations = item.get("metadata", {}).get("annotations", {}) or {}
            if annotations.get(annotation) == service_account:
                name = item.get("metadata", {}).get("name")
                if name:
                    return name
        return None

    # -- writing ----------------------------------------------------------

    def set_api_token(self, token: str | None = None, *, restart: bool = True) -> str:
        """Write a new URL-parameter API token and return it.

        Applies the secret with the labels the operator expects, then restarts
        the service pod, which is what actually makes the new token take
        effect — the running process reads the token at startup.
        """
        token = validate_token(token) if token else generate_token()

        manifest = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": TOKEN_SECRET,
                "namespace": self.namespace,
                "labels": {
                    "app.kubernetes.io/component": "ibm-licensing-service-svc",
                    "app.kubernetes.io/instance": "ibm-licensing-service",
                    "app.kubernetes.io/managed-by": "operator",
                    "app.kubernetes.io/name": "ibm-licensing-service-instance",
                    "release": "ibm-licensing-service",
                },
            },
            "type": "Opaque",
            "stringData": {"token": token},
        }

        proc = subprocess.run(
            [self._cli, "apply", "-f", "-"],
            input=json.dumps(manifest),
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise IBMLicensingConfigError(
                f"Failed to apply secret {TOKEN_SECRET!r} in {self.namespace!r}: "
                f"{proc.stderr.strip() or proc.stdout.strip()}"
            )

        if restart:
            self.restart_service()
        return token

    # Refreshing is creating with a fresh value; named for what callers mean.
    def refresh_api_token(self, *, length: int = 24, restart: bool = True) -> str:
        """Replace the API token with a newly generated one and return it."""
        return self.set_api_token(generate_token(length), restart=restart)

    def delete_api_token(self, *, restart: bool = True) -> bool:
        """Delete the API token secret.

        The operator recreates it with a fresh random value, so this is a
        reset rather than a way to turn the URL token off; use
        ``set_url_auth_enabled(False)`` for that.
        """
        proc = _run(
            [self._cli, "delete", "secret", TOKEN_SECRET, "-n", self.namespace,
             "--ignore-not-found"],
            check=False,
        )
        if proc.returncode != 0:
            raise IBMLicensingConfigError(
                f"Failed to delete secret {TOKEN_SECRET!r}: {proc.stderr.strip()}"
            )
        deleted = "deleted" in proc.stdout.lower()
        if restart and deleted:
            self.restart_service()
        return deleted

    def restart_service(self) -> None:
        """Delete the License Service pod so it reloads its token."""
        _run(
            [self._cli, "delete", "pods", "-l", SERVICE_POD_LABEL, "-n", self.namespace],
            check=False,
        )

    # -- CR feature toggles ------------------------------------------------

    def _patch_cr(self, patch: Mapping[str, Any]) -> None:
        proc = _run(
            [self._cli, "patch", "ibmlicensing", self.cr_name, "-n", self.namespace,
             "--type", "merge", "-p", json.dumps(patch)],
            check=False,
        )
        if proc.returncode != 0:
            # The CR is cluster-scoped on some builds, where -n is rejected.
            proc = _run(
                [self._cli, "patch", "ibmlicensing", self.cr_name,
                 "--type", "merge", "-p", json.dumps(patch)],
                check=False,
            )
        if proc.returncode != 0:
            raise IBMLicensingConfigError(
                f"Failed to patch IBMLicensing/{self.cr_name}: "
                f"{proc.stderr.strip() or proc.stdout.strip()}"
            )

    def get_features(self) -> dict[str, Any]:
        """Return ``spec.features`` from the IBMLicensing CR."""
        proc = _run(
            [self._cli, "get", "ibmlicensing", self.cr_name, "-o", "jsonpath={.spec.features}"],
            check=False,
        )
        if proc.returncode != 0:
            raise IBMLicensingConfigError(
                f"Could not read IBMLicensing/{self.cr_name}: {proc.stderr.strip()}"
            )
        raw = proc.stdout.strip()
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {}

    def set_url_auth_enabled(self, enabled: bool) -> None:
        """Toggle ``spec.features.auth.urlBasedEnabled`` on the CR.

        Setting this false forces every caller onto bearer-token auth. Make
        sure a service account token works before you disable it, or you lock
        yourself out of the API.
        """
        self._patch_cr({"spec": {"features": {"auth": {"urlBasedEnabled": bool(enabled)}}}})

    def set_rbac_auth_enabled(self, enabled: bool) -> None:
        """Toggle ``spec.features.kubeRBACAuthEnabled`` on the CR.

        This gates the bearer-token path. Disabling it while
        ``urlBasedEnabled`` is also false leaves no working auth method.
        """
        self._patch_cr({"spec": {"features": {"kubeRBACAuthEnabled": bool(enabled)}}})

    def auth_methods_enabled(self) -> dict[str, bool]:
        """Which auth methods the CR currently permits.

        Both default to enabled, so an absent key means on, not off.
        """
        features = self.get_features()
        auth = features.get("auth") or {}
        return {
            "url": bool(auth.get("urlBasedEnabled", True)),
            "bearer": bool(features.get("kubeRBACAuthEnabled", True)),
        }

    # -- discovery ---------------------------------------------------------

    def get_service_url(self) -> str:
        """The License Service URL, from the OpenShift route or k8s Ingress."""
        proc = _run(
            [self._cli, "get", "route", SERVICE_ROUTE, "-n", self.namespace,
             "-o", "jsonpath={.spec.host}"],
            check=False,
        )
        host = proc.stdout.strip() if proc.returncode == 0 else ""
        if not host:
            proc = _run(
                [self._cli, "get", "ingress", SERVICE_ROUTE, "-n", self.namespace,
                 "-o", "jsonpath={.spec.rules[0].host}"],
                check=False,
            )
            host = proc.stdout.strip() if proc.returncode == 0 else ""
        if not host:
            raise IBMLicensingConfigError(
                f"Could not find route or ingress {SERVICE_ROUTE!r} in namespace "
                f"{self.namespace!r}. Is License Service deployed there?"
            )
        return _normalise_url(host)


# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------


class IBMLicensingClient:
    """Calls the IBM License Service APIs with either authentication method.

    Defaults come from the environment ``cp4d_config/`` exports, so the
    zero-argument form works in any shell that sourced the repo env::

        IBMLicensingClient().products()

    ``auth`` picks the method: ``"url"`` for the API token as a query
    parameter, ``"bearer"`` for a service account token in the header, and
    ``"auto"`` (the default) for a URL token when one is available and a
    bearer token otherwise.

    ``as_dataframe`` sets the client-wide default return type for the
    reporting endpoints; every one of those methods takes an ``as_dataframe``
    of its own to override it for a single call.
    """

    ENV_URL = "IBM_LICENSING_SERVICE_INSTANCE"
    ENV_TOKEN = "IBM_LICENSING_TOKEN"
    ENV_BEARER = "IBM_LICENSING_BEARER_TOKEN"
    ENV_NAMESPACE = "PROJECT_LICENSE_SERVICE"

    def __init__(
        self,
        url: str | None = None,
        token: str | None = None,
        bearer_token: str | None = None,
        *,
        auth: Literal["auto", "url", "bearer"] = "auto",
        namespace: str | None = None,
        verify: bool | str = False,
        timeout: float | tuple[float, float] = 60.0,
        env: Mapping[str, str] | None = None,
        session: requests.Session | None = None,
        cr_name: str = DEFAULT_CR_NAME,
        as_dataframe: bool = False,
    ) -> None:
        env = os.environ if env is None else env

        self.url = _normalise_url(url or env.get(self.ENV_URL, ""))
        self.namespace = namespace or env.get(self.ENV_NAMESPACE) or DEFAULT_NAMESPACE
        self.cr_name = cr_name
        # The route is re-encrypt with an internal CA, so verification is off by
        # default to match the curl -k the install scripts use. Pass verify=True
        # or a CA bundle path where the chain is trusted.
        self.verify = verify
        self.timeout = timeout
        self.session = session or requests.Session()
        # Client-wide default; each reporting method can override it per call.
        self.as_dataframe = bool(as_dataframe)

        self._url_token = (token if token is not None else env.get(self.ENV_TOKEN, "")) or ""
        self._bearer_token = (
            bearer_token if bearer_token is not None else env.get(self.ENV_BEARER, "")
        ) or ""

        if not self.url:
            raise IBMLicensingConfigError(
                f"No License Service URL. Pass url=… or set ${self.ENV_URL} "
                "(cp4d_config/cpd_instance_details.sh exports it), or build the "
                "client with IBMLicensingClient.from_cluster()."
            )

        self.auth = self._resolve_auth(auth)

    # -- construction ------------------------------------------------------

    def _resolve_auth(self, auth: str) -> LicensingAuth:
        if auth == "url":
            if not self._url_token:
                raise IBMLicensingConfigError(
                    f"auth='url' needs an API token. Pass token=… or set ${self.ENV_TOKEN}."
                )
            return UrlTokenAuth(self._url_token)
        if auth == "bearer":
            if not self._bearer_token:
                raise IBMLicensingConfigError(
                    f"auth='bearer' needs a service account token. Pass bearer_token=…, "
                    f"set ${self.ENV_BEARER}, or use IBMLicensingClient.from_cluster"
                    "(auth='bearer')."
                )
            return BearerTokenAuth(self._bearer_token)
        if auth == "auto":
            if self._url_token:
                return UrlTokenAuth(self._url_token)
            if self._bearer_token:
                return BearerTokenAuth(self._bearer_token)
            raise IBMLicensingConfigError(
                f"No credentials. Set ${self.ENV_TOKEN} or ${self.ENV_BEARER}, pass "
                "token=…/bearer_token=…, or use IBMLicensingClient.from_cluster()."
            )
        raise IBMLicensingConfigError(
            f"Unknown auth mode {auth!r}; expected 'auto', 'url' or 'bearer'."
        )

    @classmethod
    def from_cluster(
        cls,
        namespace: str | None = None,
        *,
        auth: Literal["auto", "url", "bearer"] = "auto",
        service_account: str = DEFAULT_READER_SA,
        env: Mapping[str, str] | None = None,
        **kwargs: Any,
    ) -> "IBMLicensingClient":
        """Build a client by reading the URL and tokens off the cluster.

        Use this before ``3.3.1_get_instance_creds.sh`` has populated
        ``cp4d_config/cpd_instance_details.sh``, or against a cluster whose
        env you have not sourced. Only the credential the chosen ``auth`` mode
        needs is fetched, except in ``auto`` where a missing URL token falls
        back to a service account token.
        """
        env = os.environ if env is None else env
        namespace = namespace or env.get(cls.ENV_NAMESPACE) or DEFAULT_NAMESPACE
        manager = LicensingTokenManager(namespace=namespace, cr_name=kwargs.get("cr_name", DEFAULT_CR_NAME))

        url = kwargs.pop("url", None) or manager.get_service_url()
        token = kwargs.pop("token", None)
        bearer_token = kwargs.pop("bearer_token", None)

        if auth in ("auto", "url") and token is None:
            try:
                token = manager.get_api_token()
            except IBMLicensingConfigError:
                if auth == "url":
                    raise
                token = ""
        if auth in ("auto", "bearer") and bearer_token is None and not token:
            bearer_token = manager.get_service_account_token(service_account)

        client = cls(
            url=url,
            token=token or "",
            bearer_token=bearer_token or "",
            auth=auth,
            namespace=namespace,
            env={},  # credentials are explicit here; do not fall back to env
            **kwargs,
        )
        client._manager = manager
        return client

    # -- auth switching ----------------------------------------------------

    @property
    def tokens(self) -> LicensingTokenManager:
        """Token lifecycle operations against this client's namespace."""
        manager = getattr(self, "_manager", None)
        if manager is None:
            manager = LicensingTokenManager(namespace=self.namespace, cr_name=self.cr_name)
            self._manager = manager
        return manager

    def use_url_token(self, token: str | None = None) -> "IBMLicensingClient":
        """Switch to URL-parameter auth, optionally with a new token."""
        if token is not None:
            self._url_token = token
        if not self._url_token:
            self._url_token = self.tokens.get_api_token()
        self.auth = UrlTokenAuth(self._url_token)
        return self

    def use_bearer_token(
        self, token: str | None = None, service_account: str = DEFAULT_READER_SA
    ) -> "IBMLicensingClient":
        """Switch to bearer auth, fetching the SA token if none is given."""
        if token is not None:
            self._bearer_token = token
        if not self._bearer_token:
            self._bearer_token = self.tokens.get_service_account_token(service_account)
        self.auth = BearerTokenAuth(self._bearer_token)
        return self

    def refresh_token(self, *, length: int = 24, restart: bool = True) -> str:
        """Rotate the API token on the cluster and adopt it on this client.

        The service reads its token at startup, so ``restart=False`` leaves
        the client holding a token the running pod does not accept yet.
        """
        token = self.tokens.refresh_api_token(length=length, restart=restart)
        self._url_token = token
        if isinstance(self.auth, UrlTokenAuth):
            self.auth = UrlTokenAuth(token)
        return token

    # -- request plumbing --------------------------------------------------

    def request(
        self,
        path: str,
        *,
        params: Mapping[str, Any] | None = None,
        raw: bool = False,
    ) -> Any:
        """Call ``path`` on the License Service and return the parsed body.

        Returns bytes for ``/snapshot``, str for ``/status`` and CSV output,
        and parsed JSON otherwise. ``raw=True`` forces the ``requests.Response``
        through untouched.
        """
        if not path.startswith("/"):
            path = f"/{path}"

        query: dict[str, Any] = {k: v for k, v in (params or {}).items() if v is not None}
        headers: dict[str, str] = {}
        self.auth.apply(query, headers)

        url = f"{self.url}{path}"
        try:
            response = self.session.get(
                url,
                params=query,
                headers=headers,
                verify=self.verify,
                timeout=self.timeout,
            )
        except requests.RequestException as exc:
            raise IBMLicensingError(f"Request to {url} failed: {exc}") from exc

        if response.status_code in (401, 403):
            raise IBMLicensingAuthError(
                response.status_code,
                f"{_extract_error_message(response.text)} "
                f"[auth: {self.auth.describe()}]",
                url,
            )
        if not response.ok:
            raise IBMLicensingAPIError(
                response.status_code, _extract_error_message(response.text), url
            )

        if raw:
            return response

        content_type = (response.headers.get("content-type") or "").lower()
        if path in _ZIP_PATHS or "application/zip" in content_type:
            return response.content
        if path in _HTML_PATHS or "text/html" in content_type:
            return response.text
        if "application/json" in content_type:
            return response.json()
        # CSV and anything else textual.
        return response.text

    def _maybe_frame(
        self,
        payload: Any,
        *,
        as_dataframe: bool | None,
        columns: Sequence[str],
        output_format: str | None = None,
    ) -> Any:
        """Return ``payload`` as-is, or converted to a DataFrame.

        ``as_dataframe=None`` defers to the client-wide default.
        """
        use_frame = self.as_dataframe if as_dataframe is None else as_dataframe
        if not use_frame:
            return payload
        if output_format and output_format.lower() == "csv":
            raise IBMLicensingConfigError(
                "as_dataframe cannot be combined with output_format='csv': the API "
                "returns CSV text, not JSON. Drop output_format to get a DataFrame "
                "built from the JSON response."
            )
        return to_dataframe(payload, columns=columns)

    @staticmethod
    def _date_params(
        start_date: str | date | datetime | None,
        end_date: str | date | datetime | None,
    ) -> dict[str, str]:
        """Validate and format the startDate/endDate pair.

        The API requires both or neither; sending one silently returns the
        default 30-day window instead of erroring.
        """
        start = _as_date_string(start_date)
        end = _as_date_string(end_date)
        if bool(start) != bool(end):
            raise IBMLicensingConfigError(
                "startDate and endDate must be given together; the API ignores one "
                "without the other and quietly returns the default 30-day window."
            )
        out: dict[str, str] = {}
        if start and end:
            if start > end:
                raise IBMLicensingConfigError(
                    f"startDate {start} is after endDate {end}."
                )
            out["startDate"] = start
            out["endDate"] = end
        return out

    # -- API surface -------------------------------------------------------

    def products(
        self,
        *,
        start_date: str | date | datetime | None = None,
        end_date: str | date | datetime | None = None,
        metric_name: str | None = None,
        group_name: str | None = None,
        output_format: Literal["json", "csv"] | None = None,
        as_dataframe: bool | None = None,
    ) -> Any:
        """License usage of Cloud Paks and stand-alone containerised products."""
        params = self._date_params(start_date, end_date)
        params.update(
            {"metricName": metric_name, "groupName": group_name, "format": output_format}
        )
        return self._maybe_frame(
            self.request("/products", params=params),
            as_dataframe=as_dataframe,
            columns=_PRODUCT_COLUMNS,
            output_format=output_format,
        )

    def bundled_products(
        self,
        *,
        start_date: str | date | datetime | None = None,
        end_date: str | date | datetime | None = None,
        metric_name: str | None = None,
        group_name: str | None = None,
        output_format: Literal["json", "csv"] | None = None,
        as_dataframe: bool | None = None,
    ) -> Any:
        """License usage of the products bundled inside each Cloud Pak."""
        params = self._date_params(start_date, end_date)
        params.update(
            {"metricName": metric_name, "groupName": group_name, "format": output_format}
        )
        return self._maybe_frame(
            self.request("/bundled_products", params=params),
            as_dataframe=as_dataframe,
            columns=_BUNDLED_COLUMNS,
            output_format=output_format,
        )

    def services(
        self,
        *,
        start_date: str | date | datetime | None = None,
        end_date: str | date | datetime | None = None,
        metric_name: str | None = None,
        group_name: str | None = None,
        output_format: Literal["json", "csv"] | None = None,
        as_dataframe: bool | None = None,
    ) -> Any:
        """How individual services contribute to their bundled product's usage.

        Only populated for products with three-layer reporting, which includes
        Cloud Pak for Data.
        """
        params = self._date_params(start_date, end_date)
        params.update(
            {"metricName": metric_name, "groupName": group_name, "format": output_format}
        )
        return self._maybe_frame(
            self.request("/services", params=params),
            as_dataframe=as_dataframe,
            columns=_SERVICE_COLUMNS,
            output_format=output_format,
        )

    def snapshot(
        self,
        *,
        start_date: str | date | datetime | None = None,
        end_date: str | date | datetime | None = None,
        metric_name: str | None = None,
        save_to: str | Path | None = None,
    ) -> bytes | Path:
        """Retrieve the audit snapshot as a zip.

        Returns the raw bytes, or the written ``Path`` when ``save_to`` is
        given. A directory there is filled in with the filename the service
        suggests via content-disposition.
        """
        params = self._date_params(start_date, end_date)
        params["metricName"] = metric_name
        response = self.request("/snapshot", params=params, raw=True)
        content: bytes = response.content

        if save_to is None:
            return content

        target = Path(save_to).expanduser()
        if target.is_dir():
            disposition = response.headers.get("content-disposition", "")
            filename = ""
            if "filename=" in disposition:
                filename = disposition.split("filename=", 1)[1].strip().strip('"')
            target = target / (filename or "audit_snapshot.zip")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        return target

    def health(self, *, as_dataframe: bool | None = None) -> Any:
        """Pods with incomplete or improper product annotations.

        As a DataFrame this is the list of offending pods, one per row, rather
        than the nested summary object; the reported ``count`` is then simply
        ``len(df)``.
        """
        return self._maybe_frame(
            self.request("/health"),
            as_dataframe=as_dataframe,
            columns=_HEALTH_COLUMNS,
        )

    def status(self) -> str:
        """The status page. Returns HTML, not JSON."""
        return self.request("/status")

    def version(self) -> Any:
        """License Service version, build date and commit.

        This endpoint needs no authentication, so it is the cheapest way to
        check that the URL itself is reachable.
        """
        return self.request("/version")

    # -- convenience -------------------------------------------------------

    def check_connection(self) -> dict[str, Any]:
        """Probe the service and report what actually works.

        Separates "the URL is wrong" from "the credentials are wrong" by
        calling the unauthenticated ``/version`` first and only then an
        authenticated endpoint.
        """
        result: dict[str, Any] = {
            "url": self.url,
            "namespace": self.namespace,
            "auth": self.auth.describe(),
            "reachable": False,
            "authenticated": False,
            "version": None,
            "error": None,
        }
        try:
            result["version"] = self.version()
            result["reachable"] = True
        except IBMLicensingError as exc:
            result["error"] = f"unreachable: {exc}"
            return result
        try:
            # Pinned to JSON: this result is a plain, serialisable dict and
            # must not change shape with the client's dataframe default.
            self.health(as_dataframe=False)
            result["authenticated"] = True
        except IBMLicensingError as exc:
            result["error"] = f"auth failed: {exc}"
        return result

    def usage_summary(
        self,
        *,
        start_date: str | date | datetime | None = None,
        end_date: str | date | datetime | None = None,
        as_dataframe: bool | None = None,
    ) -> dict[str, Any]:
        """Products, bundled products and services in one call.

        Returns a dict of three sections, each a list of records or a
        DataFrame depending on the toggle.

        A failing section is reported in place rather than aborting the whole
        summary, since ``/services`` is empty for products without three-layer
        reporting and a restricted ClusterRole may omit individual endpoints.
        A failed section is always the error dict, never a frame, so check for
        that before treating a section as tabular.
        """
        summary: dict[str, Any] = {}
        for key, method in (
            ("products", self.products),
            ("bundled_products", self.bundled_products),
            ("services", self.services),
        ):
            try:
                summary[key] = method(
                    start_date=start_date, end_date=end_date, as_dataframe=as_dataframe
                )
            except IBMLicensingError as exc:
                summary[key] = {"error": str(exc)}
        return summary

    def __repr__(self) -> str:
        return (
            f"{type(self).__name__}(url={self.url!r}, namespace={self.namespace!r}, "
            f"auth={self.auth.describe()!r}, as_dataframe={self.as_dataframe!r})"
        )


def _iter_env_files(config_dir: Path) -> Iterable[Path]:
    for name in ("cpd_instance_details.sh", "cpd_vars.sh"):
        candidate = config_dir / name
        if candidate.is_file():
            yield candidate


def load_config_env(config_dir: str | Path | None = None) -> dict[str, str]:
    """Read the ``export NAME="value"`` lines out of ``cp4d_config/``.

    For Python entry points that were not launched from a shell which sourced
    the repo env. Only plain literal exports are picked up; anything with
    command substitution or variable references is left alone, because
    evaluating it would mean running the shell.
    """
    if config_dir is None:
        config_dir = Path(__file__).resolve().parents[2] / "cp4d_config"
    config_dir = Path(config_dir).expanduser()
    if not config_dir.is_dir():
        raise IBMLicensingConfigError(f"No such config directory: {config_dir}")

    values: dict[str, str] = {}
    for path in _iter_env_files(config_dir):
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line.startswith("export ") or "=" not in line:
                continue
            name, _, raw = line[len("export "):].partition("=")
            name = name.strip()
            raw = raw.strip()
            if raw[:1] in ("'", '"') and raw[-1:] == raw[:1] and len(raw) >= 2:
                raw = raw[1:-1]
            # Unexpanded shell syntax would be a lie if stored verbatim.
            if "$" in raw or "`" in raw:
                continue
            values[name] = raw
    return values
