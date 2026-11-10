"""Multi-cluster state and where config folders live, for Python that does not get them
from the shell env loaders.

Standard library only and no imports from this repo, because it is loaded three ways:
src.helpers.multi_cluster_state (notebooks), helpers.multi_cluster_state (TUIs) and
multi_cluster_state (scripts with src/helpers on sys.path).

Python twin of src/helpers/multi_cluster_helpers.sh: same state file, same name rules,
compared by tests/test_mcm_state.py. Every function takes repo and env for callers that
hold their own repo root or environment mapping; they default to this checkout and
os.environ. Invalid names or state values raise ValueError naming the key or name.
"""

from __future__ import annotations

import datetime
import os
import re
import sys
import tempfile
from pathlib import Path

STATE_KEYS = (
    "MULTI_CLUSTER_MANAGEMENT",
    "MCM_CLUSTERS",
    "MCM_CURRENT_CLUSTER",
    "APPLY_TO_ALL",
    "MCM_TARGET_CLUSTERS",
    "MCM_STOP_INACTIVE_CONTAINERS",
    "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES",
    "MCM_STOP_IDLE_PODMAN_VM",
)
DEFAULT_STATE = {
    "MULTI_CLUSTER_MANAGEMENT": "false",
    "MCM_CLUSTERS": "",
    "MCM_CURRENT_CLUSTER": "",
    "APPLY_TO_ALL": "false",
    "MCM_TARGET_CLUSTERS": "",
    "MCM_STOP_INACTIVE_CONTAINERS": "true",
    "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES": "120",
    "MCM_STOP_IDLE_PODMAN_VM": "true",
}
_STATE_COMMENTS = {
    "MULTI_CLUSTER_MANAGEMENT": "true | false",
    "MCM_CLUSTERS": "registered clusters, space separated",
    "MCM_CURRENT_CLUSTER": "working cluster",
    "APPLY_TO_ALL": "run each command on every registered cluster",
    "MCM_TARGET_CLUSTERS": "or a specific list; beats APPLY_TO_ALL when set",
    "MCM_STOP_INACTIVE_CONTAINERS": "stop idle containers of clusters no longer targeted",
    "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES": "stop a container after this long with no commands; 0 = never",
    "MCM_STOP_IDLE_PODMAN_VM": "also shut down the podman VM once nothing at all is running",
}
_STATE_HEADER = (
    '# Generated. Safe to edit by hand; keep the KEY="value" form.\n'
    "# Manage with src/utilities/multi_cluster_management_utils/multi_cluster.sh or the notebooks.\n"
)
_BOOLEAN_KEYS = (
    "MULTI_CLUSTER_MANAGEMENT",
    "APPLY_TO_ALL",
    "MCM_STOP_INACTIVE_CONTAINERS",
    "MCM_STOP_IDLE_PODMAN_VM",
)

_ASSIGNMENT = re.compile(r'^\s*(export\s+)?([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"\s*(#.*)?$', re.ASCII)
_ASSIGNMENT_ANY = re.compile(r"^\s*(export\s+)?([A-Za-z_][A-Za-z0-9_]*)=", re.ASCII)
_COMMENT_OR_BLANK = re.compile(r"^\s*(#.*)?$", re.ASCII)
_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_]*", re.ASCII)
_NAME = re.compile(r"[a-z0-9][a-z0-9._-]*", re.ASCII)
_NUMBER = re.compile(r"[0-9]+", re.ASCII)
_RESERVED_NAMES = ("clusters", "old_configs")
_RESERVED_SUFFIXES = ("_config", "_workspace")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _environ(env):
    return os.environ if env is None else env


def _repo(repo):
    return Path(repo) if repo else repo_root()


def state_file(repo=None, env=None) -> Path:
    """MCM_STATE_FILE when set, otherwise <repo>/configs/multi_cluster_management.sh."""
    value = _environ(env).get("MCM_STATE_FILE")
    return Path(value) if value else _repo(repo) / "configs" / "multi_cluster_management.sh"


def clusters_root(repo=None) -> Path:
    return _repo(repo) / "configs" / "clusters"


def _name_error(name):
    if name in _RESERVED_NAMES or str(name).endswith(_RESERVED_SUFFIXES):
        return f"Invalid cluster name '{name}': reserved (clusters, old_configs, or ending in _config or _workspace)."
    return f"Invalid cluster name '{name}': must match [a-z0-9][a-z0-9._-]*."


def _name_ok(name):
    return (
        isinstance(name, str)
        and _NAME.fullmatch(name) is not None
        and name not in _RESERVED_NAMES
        and not name.endswith(_RESERVED_SUFFIXES)
    )


def validate_name(name) -> str:
    """Returns name when allowed, raises ValueError otherwise."""
    if not _name_ok(name):
        raise ValueError(_name_error(name))
    return name


def cluster_root(name, repo=None) -> Path:
    return clusters_root(repo) / validate_name(name)


def name_from_url(url) -> str:
    """Label after "api." in the host, else the first label; IPv4 keeps all parts joined by dashes.

    Raises ValueError when no usable name comes out of the URL.
    """
    text = str(url or "").strip()
    host = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://", "", text)
    host = re.split(r"[/?#]", host, maxsplit=1)[0]
    host = host.rsplit("@", 1)[-1]
    host = host.split(":", 1)[0].lower()
    if not host:
        raise ValueError(f"Cannot derive a cluster name from '{text}': no host found. Give an explicit name.")
    parts = host.split(".")
    if len(parts) == 4 and all(re.fullmatch(r"[0-9]{1,3}", p) and int(p) <= 255 for p in parts):
        name = "-".join(parts)
    elif parts[0] == "api" and len(parts) > 1 and parts[1]:
        name = parts[1]
    else:
        name = parts[0]
    if not _name_ok(name):
        raise ValueError(f"{_name_error(name)} Cannot derive a usable cluster name from '{text}'. Give an explicit name.")
    return name


def _clusters_on_disk(repo):
    """Registered clusters found on disk: every marker except the retired ones."""
    names = []
    for marker in clusters_root(repo).glob("*/.cluster"):
        if marker.is_file():
            name = marker.parent.name
            if not _name_ok(name):
                print(f"[WARN] Skipping cluster folder with an invalid name: {marker.parent}", file=sys.stderr)
                continue
            if _marker_value(marker, "RETIRED") == "true":
                continue
            names.append(name)
    return " ".join(_byte_sorted(names))


def _byte_sorted(names):
    """Byte order, as the zsh twin sorts under LC_ALL=C."""
    return sorted(names, key=lambda n: n.encode("utf-8", "surrogateescape"))


def _parse_state(path, repo, malformed=None):
    """(values, unknown key names in file order, lines kept verbatim).

    With a malformed list (a read), a badly written line of a key other than the flag lands
    there instead of raising, so the caller can decide once the flag is known.
    """
    values = dict(DEFAULT_STATE)
    unknown, raw = [], []
    if not path.is_file():
        values["MCM_CLUSTERS"] = _clusters_on_disk(repo)
        return values, unknown, raw
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for line in lines:
        if _COMMENT_OR_BLANK.match(line):
            continue
        match = _ASSIGNMENT.match(line)
        if match:
            key, value = match.group(2), match.group(3)
            if key not in STATE_KEYS and key not in unknown:
                unknown.append(key)
            values[key] = value
            continue
        match = _ASSIGNMENT_ANY.match(line)
        if match and match.group(2) in STATE_KEYS:
            key = match.group(2)
            complaint = f'{key} must be written as export {key}="value" (found: {line})'
            if malformed is not None and key != "MULTI_CLUSTER_MANAGEMENT":
                malformed.append(complaint)
                continue
            raise ValueError(f"{path}: {complaint}")
        raw.append(line)
    return values, unknown, raw


def _key_complaint(key, values):
    """Why the value of a known key is not allowed; "" when it is fine."""
    value = values[key]
    if key in _BOOLEAN_KEYS:
        return "" if value in ("true", "false") else f"{key} must be true or false (found: '{value}')"
    if key == "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES":
        return "" if _NUMBER.fullmatch(value) else f"{key} must be a whole number of minutes, 0 to disable (found: '{value}')"
    if key in ("MCM_CLUSTERS", "MCM_TARGET_CLUSTERS"):
        for item in value.split():
            if not _name_ok(item):
                return f"{key} must be a space separated list of cluster names (bad entry: '{item}')"
        return ""
    if key == "MCM_CURRENT_CLUSTER" and value and not _name_ok(value):
        return f"{key} is not a valid cluster name (found: '{value}')"
    return ""


_CHECK_ORDER = (
    *_BOOLEAN_KEYS,
    "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES",
    "MCM_CLUSTERS",
    "MCM_TARGET_CLUSTERS",
    "MCM_CURRENT_CLUSTER",
)


def _validate_state(values, path):
    for key in _CHECK_ORDER:
        complaint = _key_complaint(key, values)
        if complaint:
            raise ValueError(f"{path}: {complaint}")


def _soften_state(values, malformed, path):
    """Mode off: a bad value of an unused setting becomes its default, with a warning."""
    for complaint in malformed:
        print(f"[WARN] {path}: {complaint}. Ignored while multi-cluster mode is off.", file=sys.stderr)
    for key in _CHECK_ORDER:
        complaint = _key_complaint(key, values)
        if complaint:
            print(f"[WARN] {path}: {complaint}. Using the default while multi-cluster mode is off.", file=sys.stderr)
            values[key] = DEFAULT_STATE[key]


def read_state(repo=None, env=None) -> dict:
    """Every known key plus any unknown KEY="value" lines, all as strings. Never writes.

    A missing file reads as the defaults with MCM_CLUSTERS rebuilt from the .cluster markers.
    With the flag exactly false, a bad value of another key warns and reads as its default.
    """
    path = state_file(repo, env)
    malformed = []
    values, _, _ = _parse_state(path, repo, malformed)
    if values["MULTI_CLUSTER_MANAGEMENT"] == "false":
        _soften_state(values, malformed, path)
    else:
        if malformed:
            raise ValueError(f"{path}: {malformed[0]}")
        _validate_state(values, path)
    return values


def _render_state(values, unknown, raw):
    out = [_STATE_HEADER]
    for key in STATE_KEYS:
        line = f'export {key}="{values[key]}"'
        out.append(f"{line}{' ' * max(2, 45 - len(line))}# {_STATE_COMMENTS[key]}\n")
    out.extend(f'export {key}="{values[key]}"\n' for key in unknown)
    out.extend(f"{line}\n" for line in raw)
    return "".join(out)


def _write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f"{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as handle:
            handle.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _as_state_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def write_state(updates=None, repo=None, env=None, **keys) -> Path:
    """Read, change keys, re-render, atomic rename, 0600. Unknown keys are preserved.

    Keys come from the updates mapping or as keyword arguments. True and False become
    "true" and "false"; numbers become their text form.
    """
    path = state_file(repo, env)
    values, unknown, raw = _parse_state(path, repo)
    for key, value in {**(updates or {}), **keys}.items():
        if not _KEY.fullmatch(str(key)):
            raise ValueError(f"write_state: invalid key name '{key}'")
        text = _as_state_value(value)
        if '"' in text or "\n" in text:
            raise ValueError(f"write_state: {key}: value may not contain a double quote or a newline")
        if key not in STATE_KEYS and key not in unknown:
            unknown.append(key)
        values[key] = text
    _validate_state(values, path)
    _write_atomic(path, _render_state(values, unknown, raw))
    return path


def ensure_state_file(repo=None, env=None) -> Path:
    """Writes the default file when missing; MCM_CLUSTERS is rebuilt from the markers."""
    path = state_file(repo, env)
    if not path.is_file():
        write_state({}, repo, env)
    return path


def is_on(repo=None, env=None) -> bool:
    return read_state(repo, env)["MULTI_CLUSTER_MANAGEMENT"] == "true"


def current_cluster(repo=None, env=None):
    """MCM_CLUSTER, then the current cluster, then the only registered one; None if none applies.

    The raw selection, whatever the flag says. configs_root() is the mode-aware lookup.
    """
    state = read_state(repo, env)
    name = _environ(env).get("MCM_CLUSTER") or state["MCM_CURRENT_CLUSTER"]
    if not name:
        registered = state["MCM_CLUSTERS"].split()
        name = registered[0] if len(registered) == 1 else None
    return name or None


def pinned_cluster(repo=None, env=None):
    """The cluster the env loaders pin this process to through MCM_CLUSTER, or None.

    Mode on: MCM_CLUSTER as given. Mode off: MCM_CLUSTER only when it names a delineated,
    not retired cluster (a delineated cluster never goes back to the flat layout); any other
    value is a stale pin the loaders drop. Raises ValueError for a retired one, as they do.
    """
    name = _environ(env).get("MCM_CLUSTER") or None
    if not name or is_on(repo, env):
        return name
    if not is_delineated(name, repo):
        return None
    if is_retired(name, repo):
        raise ValueError(
            f"Cluster '{name}' (MCM_CLUSTER) is retired. Add it back with multi_cluster.sh add {name}, or unset MCM_CLUSTER."
        )
    return name


def _usable_configs_root(repo, env):
    """CONFIGS_ROOT from the environment when it applies to this checkout and cluster, else None.

    MCM_CLUSTER names the cluster for this call, so a CONFIGS_ROOT a shell exported for another
    one is ignored. With the mode off and no delineated cluster pinned only this checkout's flat
    tree applies: a shell loaded from another checkout, or one still pinned to a cluster, exports
    somewhere else.
    """
    environ = _environ(env)
    value = environ.get("CONFIGS_ROOT")
    if not value:
        return None
    try:
        on = is_on(repo, env)
    except ValueError:
        return Path(value)
    resolved = Path(value).resolve()
    if on:
        name = environ.get("MCM_CLUSTER")
        if name and resolved != cluster_root(name, repo).resolve():
            return None
        return Path(value)
    pinned = pinned_cluster(repo, env)
    if pinned:
        return Path(value) if resolved == cluster_root(pinned, repo).resolve() else None
    flat = (_repo(repo) / "configs").resolve()
    if resolved.is_relative_to(flat) and not resolved.is_relative_to(clusters_root(repo).resolve()):
        return Path(value)
    return None


def configs_root(repo=None, env=None) -> Path:
    """CONFIGS_ROOT when it applies; with the mode on, the selected cluster's folder; with it off,
    a delineated MCM_CLUSTER's folder; else <repo>/configs."""
    usable = _usable_configs_root(repo, env)
    if usable is not None:
        return usable
    if is_on(repo, env):
        name = current_cluster(repo, env)
        if name:
            return cluster_root(name, repo)
    else:
        name = pinned_cluster(repo, env)
        if name:
            return cluster_root(name, repo)
    return _repo(repo) / "configs"


def writable_configs_root(repo=None, env=None) -> Path:
    """configs_root for code about to write a file.

    With the mode on and no cluster selected, configs_root falls back to the flat folder,
    which no run reads in that state, so a file written there would be lost or stale.
    Raises ValueError with the ways to pick a cluster. A CONFIGS_ROOT from the env
    loaders is already that cluster's folder.
    """
    root = configs_root(repo, env)
    if _usable_configs_root(repo, env) is None and is_on(repo, env) and not current_cluster(repo, env):
        raise ValueError(
            "Multi-cluster management is on but no cluster is selected, so there is no cluster "
            "folder to write to. Select one with multi_cluster.sh use NAME or MCM_CLUSTER=NAME."
        )
    return root


def config_dir(product_dir, cluster=None, repo=None, env=None) -> Path:
    """Folder of one product's config. An explicit cluster wins, in any mode: a notebook
    saves into the named cluster's folder before it turns the mode on."""
    if cluster:
        return cluster_root(cluster, repo) / product_dir
    return configs_root(repo, env) / product_dir


def _marker_value(path, key):
    if not path.is_file():
        return ""
    prefix = f'{key}="'
    for line in path.read_text(encoding="utf-8", errors="surrogateescape").splitlines():
        if line.startswith(prefix) and line.endswith('"'):
            return line[len(prefix):-1]
    return ""


def url_key(url) -> str:
    """The key two OCP URLs are compared by: "host:port", lowercase, with the scheme, userinfo,
    path, query, fragment and trailing dots of the host dropped and the port defaulting to 6443
    (the OpenShift API port). "" when there is no host. Twin of _mcm_url_key in the zsh helpers."""
    text = str(url or "").strip().lower()
    text = re.sub(r"^[a-z][a-z0-9+.-]*://", "", text)
    text = re.split(r"[/?#]", text, maxsplit=1)[0]
    text = text.rsplit("@", 1)[-1]
    if text.startswith("["):
        inner, closed, rest = text[1:].partition("]")
        host = f"[{inner}]"
        port = rest[1:] if closed and rest.startswith(":") else ""
    else:
        host, _, port = text.partition(":")
    host = host.rstrip(".")
    if not host or host == "[]":
        return ""
    return f"{host}:{port or '6443'}"


# ---- delineation (one-way per cluster) --------------------------------------------------
# A cluster folder with a .cluster marker is delineated for good: it never goes back to the
# flat layout. Every marker counts, also one without DELINEATED and a retired one.
# RETIRED="true" means unregistered on purpose (multi_cluster.sh remove without --purge):
# still delineated, not targetable, and left out when MCM_CLUSTERS is rebuilt.

_MARKER_HEADER = (
    "# Multi-cluster management marker: this folder is a delineated cluster. Delineation is\n"
    "# one-way: this cluster never goes back to the flat configs/ layout.\n"
)
_MARKER_FIELDS = ("NAME", "OCP_URL", "CREATED", "DELINEATED", "RETIRED")
# Same test as the zsh twin's glob [A-Za-z_]*=\"*\": a letter first, a =" somewhere, a closing quote.
_MARKER_LINE = re.compile(r'[A-Za-z_].*=".*"', re.ASCII | re.DOTALL)


def _write_marker(marker, name, url, created, retired):
    """The known fields in a fixed order, then any other KEY="value" lines; RETIRED only when true."""
    kept = []
    if marker.is_file():
        for line in marker.read_text(encoding="utf-8", errors="surrogateescape").splitlines():
            if _MARKER_LINE.fullmatch(line) and line.split("=", 1)[0] not in _MARKER_FIELDS:
                kept.append(line)
    lines = [f'NAME="{name}"', f'OCP_URL="{url}"', f'CREATED="{created}"', 'DELINEATED="true"']
    if retired:
        lines.append('RETIRED="true"')
    text = _MARKER_HEADER + "".join(f"{line}\n" for line in [*lines, *kept])
    fd, tmp = tempfile.mkstemp(dir=marker.parent, prefix=f"{marker.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as handle:
            handle.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, marker)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def is_delineated(name, repo=None) -> bool:
    """True when configs/clusters/<name>/.cluster exists (retired included). Invalid names are False."""
    return _name_ok(name) and (clusters_root(repo) / name / ".cluster").is_file()


def is_retired(name, repo=None) -> bool:
    return is_delineated(name, repo) and _marker_value(clusters_root(repo) / name / ".cluster", "RETIRED") == "true"


def delineated_clusters(include_retired=True, repo=None) -> list:
    """Delineated cluster names in byte order."""
    names = []
    for marker in clusters_root(repo).glob("*/.cluster"):
        name = marker.parent.name
        if not marker.is_file() or not _name_ok(name):
            continue
        if not include_retired and _marker_value(marker, "RETIRED") == "true":
            continue
        names.append(name)
    return _byte_sorted(names)


def cluster_for_url(url, repo=None) -> str:
    """The delineated cluster owning url: the first (byte order) whose marker holds it (compared by
    url_key), else the name derived from url when that name's marker records no URL. A marker with
    another URL is a different cluster whose URL derives the same name. "" when none."""
    key = url_key(url)
    if not key:
        return ""
    for name in delineated_clusters(True, repo):
        if url_key(_marker_value(clusters_root(repo) / name / ".cluster", "OCP_URL")) == key:
            return name
    try:
        name = name_from_url(url)
    except ValueError:
        return ""
    marker = clusters_root(repo) / name / ".cluster"
    return name if marker.is_file() and not url_key(_marker_value(marker, "OCP_URL")) else ""


def _set_retired(name, retired, repo):
    marker = cluster_root(name, repo) / ".cluster"
    if not marker.is_file():
        raise ValueError(f"Cluster '{name}' is not delineated: {marker} does not exist.")
    current = _marker_value(marker, "RETIRED") or "false"
    want = "true" if retired else "false"
    if current == want and _marker_value(marker, "DELINEATED") == "true":
        return marker
    _write_marker(marker, name, _marker_value(marker, "OCP_URL"), _marker_value(marker, "CREATED"), retired)
    return marker


def mark_retired(name, repo=None) -> Path:
    """RETIRED="true" on the marker (multi_cluster.sh remove without --purge). The state file is untouched."""
    return _set_retired(name, True, repo)


def unretire(name, repo=None) -> Path:
    """Clears RETIRED on the marker. The state file is untouched; register_cluster also unretires."""
    return _set_retired(name, False, repo)


def register_cluster(name, url=None, repo=None, env=None) -> Path:
    """Creates the folder and .cluster marker (DELINEATED="true", any RETIRED cleared) and adds
    the cluster to MCM_CLUSTERS."""
    root = cluster_root(name, repo)
    url = url or ""
    if '"' in url or "\n" in url:
        raise ValueError("register_cluster: the URL may not contain a double quote or a newline")
    root.mkdir(parents=True, exist_ok=True)
    marker = root / ".cluster"
    old_url = _marker_value(marker, "OCP_URL")
    url = url or old_url
    if (
        not marker.is_file()
        or url != old_url
        or _marker_value(marker, "DELINEATED") != "true"
        or _marker_value(marker, "RETIRED")
    ):
        created = _marker_value(marker, "CREATED") or datetime.datetime.now(datetime.UTC).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        _write_marker(marker, name, url, created, False)
    key = url_key(url)
    if key:
        for other in clusters_root(repo).glob("*/.cluster"):
            if other.parent.name != name and url_key(_marker_value(other, "OCP_URL")) == key:
                print(f"[WARN] Clusters '{other.parent.name}' and '{name}' point at the same URL ({url}).", file=sys.stderr)
    state = read_state(repo, env)
    registered = state["MCM_CLUSTERS"].split()
    if name not in registered:
        registered.append(name)
    write_state({"MCM_CLUSTERS": " ".join(registered)}, repo, env)
    return root
