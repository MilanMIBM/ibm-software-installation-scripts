"""Store and retrieve IBM Software Hub config files in IBM Cloud Secrets Manager.

The two CLIs in ``src/utils/`` are thin wrappers around this module:

* ``ibmcloud-secrets-manager-upload-update-cpd-vars.py``  -> upload / update
* ``ibmcloud-secrets-manager-retrieve-cpd-vars.py``       -> retrieve / rebuild

Storage model
-------------
Every file becomes ONE key/value (``kv``) secret in a secret group, so the
values stay individually readable and editable in the Secrets Manager UI:

* ``cpd_vars.sh`` (and any other shell variable file, e.g.
  ``cpd_instance_details.sh``) is parsed into ``{VAR_NAME: value}``. The file
  layout - comments, blank lines, section banners, quoting style, trailing
  comments, ``export`` prefixes - is stored alongside the values under the
  reserved key ``_cpd_layout`` so the file can be rebuilt byte-for-byte with
  whatever values the secret currently holds.

* ``install-options.yml`` (multi-document YAML with meaningful comments) is
  stored verbatim under the reserved key ``_file_content``. Flattening it into
  key/value pairs would not round-trip, so it is kept whole.

Values are stored *unexpanded*. ``LOGIN_ARGUMENTS="--username=${OCP_USERNAME}
--password=${OCP_PASSWORD}"`` goes in as that literal string, so the rebuilt
file behaves exactly like the original when sourced.

Versioning
----------
Uploads never silently replace a config: a file whose payload is unchanged is
skipped, and a file that differs is kept in one of two ways.

``native`` (default) uses Secrets Manager's own versioning - ``create_secret_version``
on the same secret. The service keeps the payload of the current and previous
version, reachable through the ``current`` and ``previous`` aliases or by version
id; older versions remain listed with ``payload_available: false``. Each version
carries its own metadata saying which file it came from and what changed.

``iterations`` is the opt-in alternative: a sibling secret per change (``<base>``,
``<base>-v2``, ``<base>-v3``, ...). Nothing ages out, at the cost of more secrets
in the group; ``overwrite=True`` versions the current iteration in place instead
of adding one.

Each upload uses the requested mode, defaulting to ``native``. The mode is
recorded on the secret, so a bundle that was built with ``iterations`` still
reports that in its plan - a later ``native`` upload simply adds a version to the
newest iteration rather than another sibling.
"""

from __future__ import annotations

import json
import os
import re
from datetime import UTC, datetime
from typing import Any

# Reserved keys inside the kv payload. Everything else in the payload is a real
# variable belonging to the file.
LAYOUT_KEY = "_cpd_layout"
CONTENT_KEY = "_file_content"
RESERVED_KEYS = (LAYOUT_KEY, CONTENT_KEY)

# Keys used in the secret's custom_metadata (visible, non-encrypted metadata).
META_FILE = "cpd_config_file"
META_FORMAT = "cpd_config_format"
META_UPDATED = "cpd_config_updated_at"
META_TOOL = "cpd_config_tool"
# Which payload generation the secret currently holds: 1 for a freshly created
# secret, then +1 for every version written on top of it. In iterations mode the
# sibling's ``-v<N>`` suffix keeps saying which iteration it is; this says how
# many times that particular secret has been written.
META_ITERATION = "cpd_config_iteration"
META_VERSION_ID = "cpd_config_version_id"
META_VERSIONING = "cpd_config_versioning"

# Keys used in a secret *version's* custom metadata (per upload, not per secret).
VMETA_FILE = "cpd_config_file"
VMETA_UPDATED = "cpd_config_updated_at"
VMETA_CHANGE = "cpd_config_change"

FORMAT_SHELL = "shell-vars"
FORMAT_RAW = "raw"

# How repeat uploads of a changed file are kept.
#
# "native"     - Secrets Manager's own versioning: a new version of the same
#                secret (create_secret_version). The service keeps the payload of
#                the current and previous version, reachable through the
#                ``current`` / ``previous`` aliases; older versions stay listed
#                but without their data.
# "iterations" - a sibling secret per change (``<base>``, ``<base>-v2``, ...),
#                which keeps every config retrievable for as long as you keep the
#                secrets, at the cost of more secrets in the group.
VERSIONING_NATIVE = "native"
VERSIONING_ITERATIONS = "iterations"
VERSIONING_MODES = (VERSIONING_NATIVE, VERSIONING_ITERATIONS)
DEFAULT_VERSIONING = VERSIONING_NATIVE

# Version aliases the service understands wherever a version id is accepted.
VERSION_ALIASES = ("current", "previous")

TOOL_NAME = "ibmcloud-secrets-manager-cpd-vars"

# Warn (do not fail) above this payload size - Secrets Manager caps how much
# data a single secret may hold and the exact limit depends on the plan.
PAYLOAD_WARN_BYTES = 256 * 1024


# ---------------------------------------------------------------------------
# Shell variable file parsing / rendering
# ---------------------------------------------------------------------------

_ASSIGN_RE = re.compile(r"([ \t]*)(export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=")


class ShellParseError(ValueError):
    """Raised when an assignment cannot be scanned (e.g. an unterminated quote)."""


def _scan_quoted(text: str, i: int) -> int:
    """Return the index just past the quoted string that starts at ``text[i]``.

    Handles backslash escapes and ``$( ... )`` command substitution inside
    double quotes, so ``"$(echo -n "cp:$KEY" | base64 -w 0)"`` scans as a
    single token instead of stopping at the inner quote.
    """
    quote = text[i]
    i += 1
    n = len(text)
    while i < n:
        char = text[i]
        if quote == '"':
            if char == "\\":
                i += 2
                continue
            if char == "$" and text[i + 1 : i + 2] == "(":
                i = _scan_cmd_sub(text, i + 1)
                continue
        if char == quote:
            return i + 1
        i += 1
    raise ShellParseError(f"unterminated {quote} quote")


def _scan_cmd_sub(text: str, i: int) -> int:
    """Return the index just past the ``$( ... )`` whose ``(`` sits at ``text[i]``."""
    depth = 0
    n = len(text)
    while i < n:
        char = text[i]
        if char == "\\":
            i += 2
            continue
        if char in "\"'":
            i = _scan_quoted(text, i)
            continue
        if char == "(":
            depth += 1
            i += 1
            continue
        if char == ")":
            depth -= 1
            i += 1
            if depth == 0:
                return i
            continue
        i += 1
    raise ShellParseError("unterminated command substitution")


def _scan_value(text: str, i: int) -> int:
    """Return the index just past the value token starting at ``text[i]``."""
    n = len(text)
    if i < n and text[i] in "\"'":
        return _scan_quoted(text, i)
    while i < n:
        char = text[i]
        if char == "\n":
            return i
        if char == "\\":
            i += 2
            continue
        if char == "$" and text[i + 1 : i + 2] == "(":
            i = _scan_cmd_sub(text, i + 1)
            continue
        if char in "\"'":
            i = _scan_quoted(text, i)
            continue
        i += 1
    return n


def parse_shell_vars(text: str) -> tuple[list[dict], dict[str, str], list[str]]:
    """Split a shell variable file into a layout, its values, and warnings.

    Args:
        text: Full contents of a file such as ``cpd_vars.sh``.

    Returns:
        (layout, values, warnings) where ``layout`` is a list of items -
        ``{"t": "l", "text": ...}`` for verbatim text and
        ``{"t": "v", "name": ..., ...}`` for an assignment - ``values`` maps
        variable names to their unexpanded values, and ``warnings`` lists
        anything that could not be represented as an editable key/value.
    """
    layout: list[dict] = []
    values: dict[str, str] = {}
    warnings: list[str] = []
    n = len(text)
    pos = 0
    literal_start = 0

    def flush_literal(end: int) -> None:
        if end > literal_start:
            layout.append({"t": "l", "text": text[literal_start:end]})

    while pos < n:
        line_end = text.find("\n", pos)
        next_pos = n if line_end < 0 else line_end + 1

        match = _ASSIGN_RE.match(text, pos)
        value_end = None
        if match:
            try:
                value_end = _scan_value(text, match.end())
            except ShellParseError as exc:
                warnings.append(
                    f"line {text.count(chr(10), 0, pos) + 1}: kept as literal text ({exc})"
                )
                match = None

        if match is None or value_end is None:
            pos = next_pos
            continue

        name = match.group(3)
        raw_value = text[match.end() : value_end]
        quote = ""
        value = raw_value
        if len(raw_value) >= 2 and raw_value[0] in "\"'" and raw_value[-1] == raw_value[0]:
            quote = raw_value[0]
            value = raw_value[1:-1]

        suffix_end = text.find("\n", value_end)
        has_newline = suffix_end >= 0
        suffix_end = n if suffix_end < 0 else suffix_end
        suffix = text[value_end:suffix_end]

        flush_literal(pos)
        layout.append(
            {
                "t": "v",
                "name": name,
                "indent": match.group(1),
                "export": bool(match.group(2)),
                "quote": quote,
                "suffix": suffix,
                "nl": has_newline,
                # Kept only for the duplicate pass below; stripped before storing.
                "_raw": text[pos : suffix_end + (1 if has_newline else 0)],
            }
        )
        values[name] = value
        pos = suffix_end + 1 if has_newline else n
        literal_start = pos

    flush_literal(n)
    layout = _demote_duplicate_assignments(layout, warnings)
    for item in layout:
        item.pop("_raw", None)
    return layout, values, warnings


def _demote_duplicate_assignments(layout: list[dict], warnings: list[str]) -> list[dict]:
    """Keep only the LAST assignment of each name editable as a key/value.

    A shell file may assign the same variable twice; the last assignment wins
    when the file is sourced. Earlier ones are turned back into literal text so
    the rebuilt file keeps the same effective values.
    """
    last_index: dict[str, int] = {}
    for index, item in enumerate(layout):
        if item["t"] == "v":
            last_index[item["name"]] = index

    result: list[dict] = []
    for index, item in enumerate(layout):
        if item["t"] == "v" and last_index[item["name"]] != index:
            warnings.append(
                f"{item['name']} is assigned more than once; the earlier assignment is "
                "stored as literal text and only the last one is editable"
            )
            result.append({"t": "l", "text": item["_raw"]})
        else:
            result.append(item)
    return result


def _quote_for_shell(value: str, quote: str) -> str:
    """Make ``value`` safe to sit between two ``quote`` characters.

    Values that came out of the original file are already correct and pass
    through untouched. The escaping only matters for values that were edited in
    the Secrets Manager UI - and it deliberately leaves anything containing a
    command substitution alone, since that quoting is intentional.
    """
    if quote == '"' and '"' in value and "$(" not in value:
        return re.sub(r'(?<!\\)"', r"\\\"", value)
    if quote == "'" and "'" in value:
        return value.replace("'", "'\\''")
    return value


def render_shell_vars(layout: list[dict], values: dict[str, str]) -> str:
    """Rebuild a shell variable file from a stored layout and its values.

    Variables that were removed from the secret are skipped. Variables that
    were added to the secret (for example through the Secrets Manager UI) are
    appended at the end under their own banner.
    """
    out: list[str] = []
    rendered: set[str] = set()

    for item in layout:
        if item.get("t") == "l":
            out.append(item.get("text", ""))
            continue
        name = item.get("name", "")
        if name not in values:
            continue
        rendered.add(name)
        quote = item.get("quote", "")
        value = _quote_for_shell(str(values[name]), quote)
        prefix = "export " if item.get("export") else ""
        line = f"{item.get('indent', '')}{prefix}{name}={quote}{value}{quote}{item.get('suffix', '')}"
        out.append(line + ("\n" if item.get("nl", True) else ""))

    extras = [key for key in values if key not in rendered]
    if extras:
        if out and not out[-1].endswith("\n"):
            out.append("\n")
        out.append(
            "\n# ------------------------------------------------------------------------------\n"
            "# Added in Secrets Manager\n"
            "# ------------------------------------------------------------------------------\n\n"
        )
        for key in extras:
            out.append(f'export {key}="{_quote_for_shell(str(values[key]), chr(34))}"\n')

    return "".join(out)


def render_shell_vars_plain(values: dict[str, str]) -> str:
    """Render values as a flat ``export NAME="value"`` file (no stored layout)."""
    lines = [
        "#===============================================================================\n",
        "# Rebuilt from IBM Cloud Secrets Manager\n",
        "#===============================================================================\n\n",
    ]
    for key, value in values.items():
        lines.append(f'export {key}="{_quote_for_shell(str(value), chr(34))}"\n')
    return "".join(lines)


# ---------------------------------------------------------------------------
# Payload construction / reconstruction
# ---------------------------------------------------------------------------


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_payload(
    file_path: str,
    text: str,
    *,
    file_format: str | None = None,
    store_layout: bool = True,
) -> tuple[dict[str, str], dict[str, Any], list[str]]:
    """Turn a config file into a kv secret payload plus its custom metadata.

    Args:
        file_path: Path of the file being uploaded (only its basename is stored).
        text: File contents.
        file_format: ``shell-vars``, ``raw``, or None to detect from the suffix.
        store_layout: For shell files, also store the layout so the original
            comments and formatting survive the round trip.

    Returns:
        (data, custom_metadata, warnings)
    """
    file_name = os.path.basename(file_path)
    if file_format is None:
        file_format = FORMAT_SHELL if file_name.endswith((".sh", ".env")) else FORMAT_RAW

    warnings: list[str] = []
    if file_format == FORMAT_SHELL:
        layout, values, warnings = parse_shell_vars(text)
        if not values:
            warnings.append(f"{file_name}: no variable assignments found; storing it verbatim")
            file_format = FORMAT_RAW
        else:
            data = dict(values)
            if store_layout:
                data[LAYOUT_KEY] = json.dumps(layout, separators=(",", ":"))

    if file_format == FORMAT_RAW:
        data = {CONTENT_KEY: text}

    custom_metadata = {
        META_FILE: file_name,
        META_FORMAT: file_format,
        META_UPDATED: _now(),
        META_TOOL: TOOL_NAME,
    }
    return data, custom_metadata, warnings


def payload_to_file(
    data: dict[str, Any],
    custom_metadata: dict[str, Any] | None = None,
    *,
    secret_name: str = "",
) -> tuple[str, str]:
    """Rebuild ``(file_name, text)`` from a kv secret payload.

    Falls back to inspecting the payload when the secret has no custom metadata
    (for example a secret that was created by hand in the console).
    """
    custom_metadata = custom_metadata or {}
    file_format = custom_metadata.get(META_FORMAT)
    if file_format is None:
        file_format = FORMAT_RAW if CONTENT_KEY in data else FORMAT_SHELL

    if file_format == FORMAT_RAW:
        default_name = f"{secret_name or 'secret'}.txt"
        return custom_metadata.get(META_FILE, default_name), str(data.get(CONTENT_KEY, ""))

    values = {k: v for k, v in data.items() if k not in RESERVED_KEYS}
    raw_layout = data.get(LAYOUT_KEY)
    if raw_layout:
        try:
            layout = json.loads(raw_layout)
            text = render_shell_vars(layout, values)
        except (ValueError, TypeError):
            text = render_shell_vars_plain(values)
    else:
        text = render_shell_vars_plain(values)

    return custom_metadata.get(META_FILE, f"{secret_name or 'secret'}.sh"), text


def payload_size(data: dict[str, Any]) -> int:
    """Approximate wire size of a kv payload, in bytes."""
    return len(json.dumps(data).encode("utf-8"))


def variable_names(data: dict[str, Any]) -> list[str]:
    """Names of the real variables in a payload (reserved keys excluded)."""
    return [key for key in data if key not in RESERVED_KEYS]


def diff_payloads(old: dict[str, Any], new: dict[str, Any]) -> dict[str, Any]:
    """Compare two kv payloads.

    Returns a dict with the ``added`` / ``removed`` / ``changed`` variable names
    (values are never included, so the result is safe to print), a
    ``layout_changed`` flag for edits that only touched comments, formatting or
    the verbatim body of a raw file, and ``identical``.
    """
    old_vars = {k: v for k, v in old.items() if k not in RESERVED_KEYS}
    new_vars = {k: v for k, v in new.items() if k not in RESERVED_KEYS}

    added = sorted(set(new_vars) - set(old_vars))
    removed = sorted(set(old_vars) - set(new_vars))
    changed = sorted(k for k in set(old_vars) & set(new_vars) if old_vars[k] != new_vars[k])
    layout_changed = any(old.get(key) != new.get(key) for key in RESERVED_KEYS)

    return {
        "added": added,
        "removed": removed,
        "changed": changed,
        "layout_changed": layout_changed,
        "identical": not (added or removed or changed or layout_changed),
    }


def describe_diff(diff: dict[str, Any]) -> str:
    """One-line, value-free summary of a payload diff."""
    if diff["identical"]:
        return "no changes"
    parts = []
    for label in ("changed", "added", "removed"):
        if diff[label]:
            names = ", ".join(diff[label][:6])
            more = f", +{len(diff[label]) - 6} more" if len(diff[label]) > 6 else ""
            parts.append(f"{len(diff[label])} {label} ({names}{more})")
    if diff["layout_changed"]:
        parts.append("comments/formatting changed")
    return "; ".join(parts)


# ---------------------------------------------------------------------------
# Secret naming
# ---------------------------------------------------------------------------


def slugify(text: str) -> str:
    """Reduce a string to the characters Secrets Manager accepts in a name."""
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-._")
    return slug or "secret"


def secret_name_for(prefix: str, file_path: str) -> str:
    """Build the secret name used for a given config file.

    ``cp4d_config/cpd_vars.sh`` with prefix ``cpd-config`` becomes
    ``cpd-config-cpd-vars-sh``, which keeps every file of a bundle under a
    single, greppable prefix.
    """
    base = os.path.basename(file_path)
    return f"{slugify(prefix)}-{slugify(base.replace('.', '-').replace('_', '-'))}"


_ITERATION_RE = re.compile(r"^(?P<base>.+)-v(?P<iteration>\d+)$")


def iteration_name(base_name: str, iteration: int) -> str:
    """Secret name for an iteration of a file.

    Iteration 1 keeps the plain base name; later iterations get a ``-v<N>``
    suffix, so a bundle reads as ``cpd-config-cpd-vars-sh``,
    ``cpd-config-cpd-vars-sh-v2``, ``cpd-config-cpd-vars-sh-v3``.
    """
    return base_name if iteration <= 1 else f"{base_name}-v{iteration}"


def split_iteration(secret_name: str, custom_metadata: dict[str, Any] | None = None) -> tuple[str, int]:
    """Return ``(base_name, iteration)`` for a secret name.

    The ``-v<N>`` suffix is authoritative, because that is what the iterations
    scheme actually creates. Secrets without a suffix fall back to the version
    number recorded in custom metadata, so a natively versioned secret reports
    the version it currently holds.
    """
    match = _ITERATION_RE.match(secret_name)
    if match:
        return match.group("base"), int(match.group("iteration"))

    recorded = (custom_metadata or {}).get(META_ITERATION)
    try:
        return secret_name, max(int(recorded), 1)
    except (TypeError, ValueError):
        return secret_name, 1


# ---------------------------------------------------------------------------
# Secrets Manager client
# ---------------------------------------------------------------------------


def load_env_file(env_file: str | None = None, repo_root: str | None = None) -> str | None:
    """Load a ``.env`` file so credentials can live outside the command line.

    Looks at ``env_file`` when given, otherwise ``<repo_root>/.env`` and
    ``<repo_root>/cp4d_config/.env``. Returns the file that was loaded.
    """
    try:
        from dotenv import load_dotenv
    except ImportError:
        return None

    candidates = []
    if env_file:
        candidates.append(env_file)
    elif repo_root:
        candidates.append(os.path.join(repo_root, ".env"))
        candidates.append(os.path.join(repo_root, "cp4d_config", ".env"))

    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            load_dotenv(candidate, override=False)
            return candidate
    return None


def resolve_service_url(
    service_url: str | None = None,
    instance_id: str | None = None,
    region: str | None = None,
) -> str:
    """Return the Secrets Manager endpoint for an instance."""
    from ibm_secrets_manager_sdk.secrets_manager_v2 import SecretsManagerV2

    service_url = service_url or os.environ.get("SECRETS_MANAGER_URL")
    if service_url:
        return service_url.rstrip("/")

    instance_id = instance_id or os.environ.get("SECRETS_MANAGER_INSTANCE_ID")
    region = region or os.environ.get("SECRETS_MANAGER_REGION") or "us-south"
    if not instance_id:
        raise ValueError(
            "No Secrets Manager instance. Pass --instance-id (with --region) or --service-url, "
            "or set SECRETS_MANAGER_INSTANCE_ID / SECRETS_MANAGER_REGION."
        )
    return SecretsManagerV2.construct_service_url(instance_id=instance_id, region=region)


def build_client(
    apikey: str | None = None,
    *,
    service_url: str | None = None,
    instance_id: str | None = None,
    region: str | None = None,
):
    """Create an authenticated ``SecretsManagerV2`` client."""
    from ibm_cloud_sdk_core.authenticators import IAMAuthenticator
    from ibm_secrets_manager_sdk.secrets_manager_v2 import SecretsManagerV2

    apikey = (
        apikey
        or os.environ.get("SECRETS_MANAGER_APIKEY")
        or os.environ.get("IBM_CLOUD_API_KEY")
        or os.environ.get("IBMCLOUD_API_KEY")
    )
    if not apikey:
        raise ValueError(
            "No IBM Cloud API key. Pass --apikey or set SECRETS_MANAGER_APIKEY / "
            "IBM_CLOUD_API_KEY / IBMCLOUD_API_KEY."
        )

    client = SecretsManagerV2(authenticator=IAMAuthenticator(apikey))
    client.set_service_url(resolve_service_url(service_url, instance_id, region))
    return client


def resolve_secret_group(client, group: str | None, create: bool = False) -> tuple[str, str]:
    """Resolve a secret group given by name or id.

    Returns:
        (group_id, group_name). The default group is looked up too, so callers
        always get its real id - listing secrets by group needs the id, not the
        ``default`` alias.
    """
    group = group or os.environ.get("SECRETS_MANAGER_GROUP") or "default"

    groups = client.list_secret_groups().get_result().get("secret_groups", [])
    if group == "default":
        for entry in groups:
            if entry.get("name") == "default":
                return entry["id"], "default"
        return "default", "default"

    for entry in groups:
        if entry.get("name") == group or entry.get("id") == group:
            return entry["id"], entry.get("name", group)

    if not create:
        known = ", ".join(sorted(e.get("name", "?") for e in groups)) or "(none)"
        raise ValueError(f"Secret group '{group}' not found. Existing groups: {known}")

    created = client.create_secret_group(
        name=group, description="Created by " + TOOL_NAME
    ).get_result()
    return created["id"], created.get("name", group)


def get_kv_secret(client, name: str, group_name: str) -> dict | None:
    """Return a kv secret by name within a group, or None when it does not exist."""
    from ibm_cloud_sdk_core import ApiException

    try:
        return (
            client.get_secret_by_name_type(
                secret_type="kv", name=name, secret_group_name=group_name
            )
            .get_result()
        )
    except ApiException as exc:
        if exc.code == 404:
            return None
        raise


def find_iterations(client, group_id: str, base_name: str) -> list[tuple[int, dict]]:
    """Return ``[(iteration, secret_metadata), ...]`` for a base name, oldest first."""
    candidates = list_kv_secrets(client, group_id, base_name)
    found: list[tuple[int, dict]] = []
    for meta in candidates:
        name = str(meta.get("name", ""))
        if name != base_name and not _ITERATION_RE.match(name):
            continue
        iteration_base, iteration = split_iteration(name, meta.get("custom_metadata"))
        if iteration_base != base_name:
            continue
        found.append((iteration, meta))
    return sorted(found, key=lambda item: item[0])


def stored_versioning(metadata: dict[str, Any] | None) -> str | None:
    """The versioning mode recorded on a secret, when it was written by this tool."""
    mode = (metadata or {}).get(META_VERSIONING)
    return mode if mode in VERSIONING_MODES else None


def plan_kv_upload(
    client,
    *,
    base_name: str,
    group_id: str,
    data: dict[str, Any],
    versioning: str | None = None,
    overwrite: bool = False,
) -> dict[str, Any]:
    """Decide what uploading ``data`` would do, without changing anything.

    Args:
        versioning: ``native``, ``iterations``, or None for
            :data:`DEFAULT_VERSIONING`. The mode a bundle was previously uploaded
            with is reported as ``stored_versioning`` but does not override this.
        overwrite: Only meaningful in ``iterations`` mode, where it turns a change
            into a new version of the current iteration instead of a new one.

    The rules, in order:

    * nothing stored yet          -> ``create`` the secret
    * stored payload is identical -> ``unchanged``, nothing is written
    * native mode                 -> ``version``: a new version of the same secret
      via ``create_secret_version``; the service keeps the previous version's
      payload under the ``previous`` alias
    * iterations mode, overwrite  -> ``version`` of the current iteration
    * iterations mode             -> ``iterate``: a new sibling secret at the next
      iteration, leaving the current one exactly as it is

    Returns:
        A dict with ``action``, ``versioning``, ``stored_versioning`` (the mode the
        bundle was last uploaded with, None when new), ``target_name``,
        ``iteration``, ``latest`` (iteration currently stored, 0 when none),
        ``version_number`` (which version the target secret will hold once this
        upload lands), ``secret_id`` of the secret that would be written to (None
        for a new one) and ``diff``.
    """
    mode = versioning or DEFAULT_VERSIONING

    iterations = find_iterations(client, group_id, base_name)
    if not iterations:
        return {
            "action": "create",
            "versioning": mode,
            "stored_versioning": None,
            "target_name": iteration_name(base_name, 1),
            "iteration": 1,
            "latest": 0,
            "version_number": 1,
            "stored_version_number": 0,
            "secret_id": None,
            "diff": None,
        }

    latest_iteration, latest_meta = iterations[-1]
    previous_mode = stored_versioning(latest_meta.get("custom_metadata"))

    current = client.get_secret(id=latest_meta["id"]).get_result()
    diff = diff_payloads(current.get("data") or {}, data)
    versions_total = int(current.get("versions_total") or 1)

    if diff["identical"]:
        action, iteration, secret_id = "unchanged", latest_iteration, latest_meta["id"]
        version_number = versions_total
    elif mode == VERSIONING_NATIVE or overwrite:
        # A new version of the secret that already holds this file.
        action, iteration, secret_id = "version", latest_iteration, latest_meta["id"]
        version_number = versions_total + 1
    else:
        # A brand new sibling secret, so it starts at its own version 1.
        action, iteration, secret_id = "iterate", latest_iteration + 1, None
        version_number = 1

    return {
        "action": action,
        "versioning": mode,
        "stored_versioning": previous_mode,
        # Writing to the existing secret keeps its real name; only a new sibling
        # gets a name derived from the iteration number.
        "target_name": (
            iteration_name(base_name, iteration)
            if action == "iterate"
            else str(latest_meta.get("name") or iteration_name(base_name, iteration))
        ),
        "iteration": iteration,
        "latest": latest_iteration,
        "version_number": version_number,
        "stored_version_number": versions_total,
        "secret_id": secret_id,
        "diff": diff,
    }


def put_kv_secret(
    client,
    *,
    name: str,
    group_id: str,
    data: dict[str, Any],
    description: str | None = None,
    labels: list[str] | None = None,
    custom_metadata: dict[str, Any] | None = None,
    versioning: str | None = None,
    overwrite: bool = False,
    plan: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Store a payload under ``name`` without losing what is already there.

    Args:
        name: Base secret name for the file (without any ``-v<N>`` suffix).
        versioning: ``native``, ``iterations``, or None to follow the bundle.
        overwrite: In ``iterations`` mode, version the current iteration in place
            rather than creating the next one.
        plan: A plan from :func:`plan_kv_upload` to reuse; recomputed when None.

    Returns:
        The plan, with ``secret`` set to the secret that was written and
        ``version`` to the version that was created (both None when the action
        was ``unchanged``).
    """
    from ibm_secrets_manager_sdk.secrets_manager_v2 import (
        KVSecretMetadataPatch,
        KVSecretPrototype,
        KVSecretVersionPrototype,
    )

    if plan is None:
        plan = plan_kv_upload(
            client,
            base_name=name,
            group_id=group_id,
            data=data,
            versioning=versioning,
            overwrite=overwrite,
        )

    if plan["action"] == "unchanged":
        return {**plan, "secret": None, "version": None}

    custom_metadata = {
        **(custom_metadata or {}),
        META_ITERATION: str(plan["version_number"]),
        META_VERSIONING: plan["versioning"],
    }
    # Per-version metadata: what this particular upload carried, so the version
    # history reads as a changelog rather than a list of timestamps.
    version_custom_metadata = {
        VMETA_FILE: custom_metadata.get(META_FILE, ""),
        VMETA_UPDATED: _now(),
        VMETA_CHANGE: describe_diff(plan["diff"]) if plan["diff"] else "initial upload",
    }

    if plan["action"] in ("create", "iterate"):
        prototype = KVSecretPrototype(
            secret_type="kv",
            name=plan["target_name"],
            data=data,
            description=description,
            secret_group_id=group_id,
            labels=labels,
            custom_metadata=custom_metadata,
            version_custom_metadata=version_custom_metadata,
        )
        created = client.create_secret(secret_prototype=prototype).get_result()
        return {**plan, "secret": created, "version": None}

    # A new version of the secret that already holds this file.
    secret_id = plan["secret_id"]
    version = client.create_secret_version(
        secret_id=secret_id,
        secret_version_prototype=KVSecretVersionPrototype(
            data=data, version_custom_metadata=version_custom_metadata
        ),
    ).get_result()
    # Keep the searchable metadata in step with the version that was just created,
    # so the secret says which version it is at now.
    if version.get("id"):
        custom_metadata[META_VERSION_ID] = version["id"]
    patch = KVSecretMetadataPatch(
        description=description,
        labels=labels,
        custom_metadata=custom_metadata,
    )
    updated = client.update_secret_metadata(
        id=secret_id, secret_metadata_patch=patch.to_dict()
    ).get_result()
    return {**plan, "secret": updated, "version": version}


# ---------------------------------------------------------------------------
# Secret versions (Secrets Manager's own version history)
# ---------------------------------------------------------------------------


def list_secret_versions(client, secret_id: str) -> list[dict]:
    """Version metadata for a secret, newest first.

    Secrets Manager keeps the *payload* of the current and previous version of a
    kv secret; older versions stay listed with ``payload_available: false``, so
    check that flag before trying to read one.
    """
    versions = client.list_secret_versions(secret_id=secret_id).get_result().get("versions", [])
    return sorted(versions, key=lambda v: str(v.get("created_at", "")), reverse=True)


def get_secret_version_data(client, secret_id: str, version: str) -> dict[str, Any]:
    """Payload of one secret version.

    Args:
        version: A version id, or the ``current`` / ``previous`` alias.
    """
    result = client.get_secret_version(secret_id=secret_id, id=version).get_result()
    return result.get("data") or {}


def describe_version(version: dict[str, Any]) -> str:
    """One line describing a version for --list output."""
    alias = version.get("alias")
    marker = f" ({alias})" if alias else ""
    note = (version.get("version_custom_metadata") or {}).get(VMETA_CHANGE, "")
    payload = "" if version.get("payload_available", True) else " [payload no longer stored]"
    created = str(version.get("created_at", ""))[:19].replace("T", " ")
    line = f"{version.get('id', '?')}{marker}  {created}{payload}"
    return f"{line}  {note}" if note else line


def list_kv_secrets(client, group_id: str, name_prefix: str | None = None) -> list[dict]:
    """List kv secret metadata in a group, optionally filtered by name prefix."""
    secrets: list[dict] = []
    offset = 0
    while True:
        page = client.list_secrets(
            offset=offset, limit=200, groups=[group_id], secret_types=["kv"]
        ).get_result()
        batch = page.get("secrets", [])
        secrets.extend(batch)
        offset += len(batch)
        if not batch or offset >= page.get("total_count", 0):
            break

    if name_prefix:
        secrets = [s for s in secrets if str(s.get("name", "")).startswith(name_prefix)]
    return sorted(secrets, key=lambda s: str(s.get("name", "")))


def group_iterations(secrets: list[dict]) -> dict[str, dict[int, dict]]:
    """Group listed kv secret metadata into ``{base_name: {iteration: metadata}}``."""
    grouped: dict[str, dict[int, dict]] = {}
    for meta in secrets:
        base, iteration = split_iteration(str(meta.get("name", "")), meta.get("custom_metadata"))
        grouped.setdefault(base, {})[iteration] = meta
    return grouped


# ---------------------------------------------------------------------------
# Shared CLI plumbing
# ---------------------------------------------------------------------------


def repo_root_from(script_path: str) -> str:
    """Repo root for a script living in ``src/utils/``."""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(script_path))))


def add_connection_args(parser) -> None:
    """Add the Secrets Manager connection / addressing flags shared by both CLIs."""
    group = parser.add_argument_group("Secrets Manager connection")
    group.add_argument(
        "--apikey",
        help="IBM Cloud API key (env: SECRETS_MANAGER_APIKEY, IBM_CLOUD_API_KEY, IBMCLOUD_API_KEY).",
    )
    group.add_argument(
        "--instance-id",
        help="Secrets Manager instance GUID (env: SECRETS_MANAGER_INSTANCE_ID).",
    )
    group.add_argument(
        "--region",
        help="Region of the instance, e.g. eu-de (env: SECRETS_MANAGER_REGION, default us-south).",
    )
    group.add_argument(
        "--service-url",
        help="Full instance endpoint; overrides --instance-id/--region (env: SECRETS_MANAGER_URL).",
    )
    group.add_argument(
        "--secret-group",
        help="Secret group name or id (env: SECRETS_MANAGER_GROUP, default 'default').",
    )
    group.add_argument(
        "--prefix",
        help="Secret name prefix that groups the files of one bundle "
        "(env: CPD_SECRETS_PREFIX, default 'cpd-config').",
    )
    group.add_argument("--env-file", help="Load this .env file before reading the variables above.")


def resolve_prefix(prefix: str | None) -> str:
    return slugify(prefix or os.environ.get("CPD_SECRETS_PREFIX") or "cpd-config")


def run_cli(main_func, argv: list[str]) -> int:
    """Run a CLI entry point, turning SDK/config failures into readable messages."""
    try:
        return main_func(argv)
    except ValueError as error:
        raise SystemExit(f"ERROR: {error}")
    except ImportError as error:
        raise SystemExit(
            f"ERROR: {error}\nInstall the dependencies first, e.g. "
            "'uv sync' or 'pip install ibm-secrets-manager-sdk'."
        )
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as error:
        api_exception = _api_exception_type()
        if api_exception is not None and isinstance(error, api_exception):
            detail = getattr(error, "message", None) or str(error)
            raise SystemExit(f"ERROR: Secrets Manager returned {error.code}: {detail}")
        raise


def _api_exception_type():
    try:
        from ibm_cloud_sdk_core import ApiException

        return ApiException
    except ImportError:
        return None


def redact(value: str, keep: int = 3) -> str:
    """Shorten a value for terminal output so secrets are not printed in full."""
    text = str(value)
    if len(text) <= keep:
        return "*" * len(text)
    return f"{text[:keep]}{'*' * min(len(text) - keep, 8)} ({len(text)} chars)"
