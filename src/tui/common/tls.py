"""TLS verification for the TUIs' HTTPS calls (Kubernetes API, Software Hub / zen, lakehouse, vault).

`oc login --insecure-skip-tls-verify` (what OC_LOGIN does) writes a kubeconfig without a CA, and the
zen helpers used to send `verify=False`. Both then talk to the cluster with a bearer token / API key
over unverified TLS, and urllib3 prints an InsecureRequestWarning per request onto stderr (where it
buries the progress bars).

verify_for(url) checks the server once per host:port with one TLS handshake, against
  1. OCP_CA_FILE (a PEM bundle, the same variable the oc login helpers take), then
  2. certifi's public CA bundle (TechZone API servers and routes carry Let's Encrypt certificates),
and returns the CA bundle path that verified, so the caller turns verification on. When nothing
verifies (a self-signed cluster) it returns False: the caller stays unverified as before, the
repeated warning is silenced, and one notice says verification is off and how to turn it on.
"""

from __future__ import annotations

import os
import socket
import ssl
import sys
import threading
import warnings
from urllib.parse import urlsplit

TIMEOUT = 5.0
NOTICES: list[str] = []        # drained by the TUI into its event log (ECHO off); printed on stderr otherwise
ECHO = True

_lock = threading.Lock()
_memo: dict[tuple[str, int], str | bool] = {}
_noted: set[str] = set()


def _bundles() -> list[str]:
    out = []
    ca = os.environ.get("OCP_CA_FILE", "").strip()
    if ca and os.path.isfile(os.path.expanduser(ca)):
        out.append(os.path.expanduser(ca))
    try:
        import certifi
        out.append(certifi.where())
    except ImportError:
        pass
    return out


def _handshake(host: str, port: int, cafile: str) -> str | None:
    """None when the certificate verifies against cafile, else the reason."""
    ctx = ssl.create_default_context(cafile=cafile)
    try:
        with socket.create_connection((host, port), timeout=TIMEOUT) as sock, \
                ctx.wrap_socket(sock, server_hostname=host):
            return None
    except ssl.SSLCertVerificationError as e:
        return e.verify_message or str(e)
    except (OSError, ssl.SSLError) as e:
        return f"{type(e).__name__}: {e}"


def notice(text: str) -> None:
    with _lock:
        if text in _noted:
            return
        _noted.add(text)
        NOTICES.append(text)
    if ECHO:
        print(f"[TLS] {text}", file=sys.stderr)


def quiet_insecure() -> None:
    """Silence the per-request InsecureRequestWarning (the notice already said verification is off)."""
    try:
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    except ImportError:
        pass
    warnings.filterwarnings("ignore", message="Unverified HTTPS request")


def verify_for(url: str, what: str = "") -> str | bool:
    """The CA bundle path to verify `url` with, or False when no bundle verifies it (memoized per host)."""
    parts = urlsplit(url if "://" in url else f"https://{url}")
    if parts.scheme != "https" or not parts.hostname:
        return False
    key = (parts.hostname, parts.port or 443)
    with _lock:
        hit = _memo.get(key)
    if hit is not None:
        return hit
    reasons = []
    result: str | bool = False
    for cafile in _bundles():
        why = _handshake(key[0], key[1], cafile)
        if why is None:
            result = cafile
            break
        reasons.append(why)
    with _lock:
        _memo[key] = result
    if result is False:
        quiet_insecure()
        label = what or f"{key[0]}:{key[1]}"
        notice(f"{label}: TLS certificate not verified ({'; '.join(dict.fromkeys(reasons)) or 'no CA bundle'}); "
               "continuing without verification. Set OCP_CA_FILE to the cluster's CA bundle (PEM) to verify it.")
    return result


def drain() -> list[str]:
    with _lock:
        out, NOTICES[:] = list(NOTICES), []
    return out
