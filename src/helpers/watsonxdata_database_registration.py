"""watsonx.data database registration (add / replace) with SaaS vs software routing.

    POST   {base}/database_registrations        -> Add/Create database
    PATCH  {base}/database_registrations/{id}   -> Update (replace) database
    GET    {base}/database_registrations        -> Get list of databases (resolves id)

Auth comes from auth_helper_functions:
    SaaS     -> get_iam_token            -> Authorization: Bearer <token>
    Software -> generate_zen_auth_header -> Authorization: ZenApiKey <b64 user:apikey>
"""

import base64
import json
import os
import re

import requests
from jinja2 import Template

from src.helpers.auth_helper_functions import (
    auth_iam_token,  # noqa: F401
    generate_zen_auth_header,
    get_iam_token,
)  # SDK alternative to get_iam_token


def load_properties(path):
    """Parse a Java/Confluent .properties file into a dict.

    Handles # and ! comments, '=' or ':' separators, and backslash line
    continuations. Repeated keys follow properties-file semantics: last wins,
    so the duplicated truststore/jaas block at the end of the file collapses
    onto the earlier one.
    """
    properties = {}
    key = None
    buffer = ""

    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not buffer and (not line or line.startswith(("#", "!"))):
                continue

            continued = line.endswith("\\")
            line = line[:-1].strip() if continued else line

            if buffer:
                buffer = f"{buffer} {line}"
            else:
                separator = min((line.find(c) for c in "=:" if c in line), default=-1)
                if separator == -1:
                    continue
                key = line[:separator].strip()
                buffer = line[separator + 1 :].strip()

            if not continued:
                properties[key] = buffer.strip()
                key, buffer = None, ""

    return properties


def parse_jaas_config(jaas):
    """Pull the key="value" pairs out of a sasl.jaas.config entry.

    Works for both ScramLoginModule and PlainLoginModule; the login module class
    and the trailing ';' are ignored, only the quoted pairs are returned.
    """
    return dict(re.findall(r'(\w+)\s*=\s*"([^"]*)"', jaas or ""))


def sasl_mechanism_to_auth_type(mechanism):
    """Map a Kafka SASL mechanism onto the registration's authentication type."""
    return {
        "PLAIN": "PLAIN",
        "SCRAM-SHA-256": "SCRAM_SHA_256",
        "SCRAM-SHA-512": "SCRAM_SHA_512",
    }.get(mechanism.upper(), mechanism.upper())


def load_ca_certificate(path, encode=True):
    """Read the PEM truststore. base64-encodes it by default, since the
    registration takes the certificate inline rather than as a file path."""
    with open(path, "rb") as handle:
        pem = handle.read()
    return base64.b64encode(pem).decode() if encode else pem.decode()


def load_template(template):
    """Accept either an inline Jinja2 string or a path to a .j2 file.

    A single-line value that resolves to an existing file is read from disk;
    anything else is returned as-is and treated as template source. Inline
    templates span multiple lines, so the newline check keeps a template body
    from ever being probed as a filename.
    """
    if "\n" not in template and os.path.isfile(template):
        with open(template, "r", encoding="utf-8") as handle:
            return handle.read()
    return template


METHOD_PATH = "/database_registrations"


def build_auth_headers(credentials):
    """Build request headers, routing to SaaS (IAM) or software (Zen) auth.

    Credential keys:
        api_key     : IBM Cloud API key (SaaS) or Zen API key (software)
        username    : Zen username - its presence selects the software path
        token       : pre-fetched token, used as-is
        instance_id : CRN (SaaS) or lakehouse instance id (software)
        flavor      : optional explicit "saas" / "software" override

    Args:
        credentials: dict of credential fields.

    Returns:
        dict: headers including Authorization and, if given, AuthInstanceId.
    """
    flavor = credentials.get("flavor")
    if not flavor:
        flavor = "software" if credentials.get("username") else "saas"

    token = credentials.get("token")

    if flavor == "software":
        auth = token or generate_zen_auth_header(
            credentials["username"], credentials["api_key"]
        )
        if not auth.startswith("ZenApiKey"):
            auth = f"ZenApiKey {auth}"
    else:
        auth = token or get_iam_token(credentials["api_key"])
        if not auth.startswith("Bearer "):
            auth = f"Bearer {auth}"

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": auth,
    }
    if credentials.get("instance_id"):
        headers["AuthInstanceId"] = str(credentials["instance_id"])

    return headers


def render_payload(config):
    """Build the request body from a config, optionally via a Jinja2 template.

        {
            "payload":   {...},               # used directly when no template
            "template":  "<jinja2 string>",   # renders to JSON
            "templates": {"<database_type>": "<jinja2 string>"},
            "variables": {...},               # values fed to the template
            "overrides": {...}                # merged over the result last
        }

    A config with none of these keys is treated as the payload itself.

    Args:
        config: dict as described above.

    Returns:
        dict: the request body.
    """
    keys = ("payload", "template", "templates", "variables", "overrides")
    if not any(k in config for k in keys):
        return dict(config)

    variables = config.get("variables") or {}
    template = config.get("template")

    if template is None and config.get("templates"):
        database_type = config.get("database_type") or variables.get("database_type")
        template = config["templates"][database_type]

    payload = dict(config.get("payload") or {})
    if template is not None:
        payload.update(json.loads(Template(template).render(**variables)))
    payload.update(config.get("overrides") or {})

    return payload


def render_connector_config(template, variables):
    """Render a connector template into the registration payload.

    Standalone counterpart to render_payload: takes a template (inline Jinja2
    source or a path to a .j2 file) plus the flat variables it expects, and
    returns the parsed body. Useful for rendering once up front and handing the
    result to register_database as 'rendered_config'.

    Note 'variables' is the template's own namespace - the values the template
    references by name - not a render_payload-style config wrapper.

    Args:
        template: inline Jinja2 string or path to a .j2 file.
        variables: dict of values fed to the template.

    Returns:
        dict: the rendered payload.
    """
    return json.loads(Template(load_template(template)).render(**variables))


def find_database_id(endpoint, credentials, display_name, timeout=60):
    """Resolve a registration id from its display name via GET /database_registrations."""
    response = requests.get(
        _url(endpoint), headers=build_auth_headers(credentials), timeout=timeout
    )
    response.raise_for_status()
    body = response.json()

    for database in body.get("database_registrations") or body.get("databases") or []:
        if database.get("display_name") == display_name:
            return database.get("id") or database.get("database_id")
    return None


def add_database(config, endpoint, credentials, timeout=60):
    """POST /database_registrations - add/create a database registration.

    Args:
        config: config/template dict (see render_payload).
        endpoint: instance endpoint.
        credentials: dict of credential fields; routes SaaS vs software.
        timeout: request timeout in seconds.

    Returns:
        requests.Response
    """
    return requests.post(
        _url(endpoint),
        headers=build_auth_headers(credentials),
        json=render_payload(config),
        timeout=timeout,
    )


def replace_database(config, endpoint, credentials, database_id=None, timeout=60):
    """PATCH /database_registrations/{id} - replace/update a registration.

    Args:
        config: config/template dict (see render_payload).
        endpoint: instance endpoint.
        credentials: dict of credential fields; routes SaaS vs software.
        database_id: registration id; resolved from 'database_display_name' if omitted.
        timeout: request timeout in seconds.

    Returns:
        requests.Response
    """
    payload = render_payload(config)

    if database_id is None:
        database_id = find_database_id(
            endpoint, credentials, payload["database_display_name"], timeout=timeout
        )
        if database_id is None:
            raise LookupError(
                f"No registration named '{payload['database_display_name']}'."
            )

    return requests.patch(
        f"{_url(endpoint)}/{database_id}",
        headers=build_auth_headers(credentials),
        json=payload,
        timeout=timeout,
    )


def register_database(
    config=None,
    endpoint=None,
    credentials=None,
    replace_existing=True,
    timeout=60,
    rendered_config=None,
):
    """Add a database registration, replacing it when the display name already exists.

    Single entry point: renders the config, picks the SaaS or software auth path
    from the credentials, then calls add or replace accordingly.

    Args:
        config: config/template dict (see render_payload).
        endpoint: instance endpoint.
        credentials: dict of credential fields; routes SaaS vs software.
        replace_existing: PATCH instead of POST when the name is already taken.
        timeout: request timeout in seconds.
        rendered_config: an already-rendered payload (see render_connector_config),
            used as-is instead of 'config'.

    Returns:
        requests.Response
    """
    if rendered_config is not None:
        payload = dict(rendered_config)
    else:
        payload = render_payload(config)
    display_name = payload.get("database_display_name")

    if replace_existing and display_name:
        database_id = find_database_id(
            endpoint, credentials, display_name, timeout=timeout
        )
        if database_id:
            return replace_database(
                payload, endpoint, credentials, database_id=database_id, timeout=timeout
            )

    return add_database(payload, endpoint, credentials, timeout=timeout)


def _url(endpoint):
    """Join the fully-qualified endpoint with the resource path."""
    return f"{endpoint.rstrip('/')}{METHOD_PATH}"
