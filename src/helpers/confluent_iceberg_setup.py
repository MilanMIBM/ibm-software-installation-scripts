"""Set up the optional Confluent-to-watsonx.data Iceberg integration.

The shell entry point loads product configuration. Credentials reach this
module through the environment and stdin, and generated JSON stays Git-ignored.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path

from softwarehub_service_instance_helpers import APIError, SoftwareHub, request_json


CONNECTOR_CLASS = "org.apache.iceberg.connect.IcebergSinkConnector"


def info(message):
    print("[INFO] " + message, flush=True)


def boolean(value):
    if value not in ("true", "false"):
        raise ValueError("Boolean settings must be 'true' or 'false'")
    return value == "true"


@dataclass
class Settings:
    root: Path
    env: dict = field(repr=False)

    def __post_init__(self):
        required = [
            "PROJECT_CONFLUENT_SERVER", "CPD_URL", "CPD_USERNAME",
            "ICEBERG_KAFKA_TOPIC", "ICEBERG_WATSONX_CATALOG", "ICEBERG_TABLE",
            "ICEBERG_WATSONX_REST_URI", "ICEBERG_COS_ENDPOINT", "ICEBERG_COS_REGION",
            "ICEBERG_COS_ACCESS_KEY_ID", "ICEBERG_COS_SECRET_ACCESS_KEY",
        ]
        missing = [name for name in required if not self.env.get(name) or "<" in self.env[name]]
        if missing:
            raise ValueError("Fill the setup configuration: " + ", ".join(missing))
        if not (self.env.get("CPD_APIKEY") or self.env.get("CPD_PASSWORD")):
            raise ValueError("Supply CPD_APIKEY or CPD_PASSWORD in the Software Hub details file")
        self.namespace = self.env["PROJECT_CONFLUENT_SERVER"]
        self.username = self.env.get("ICEBERG_SERVICE_ID", "svc-iceberg")
        self.name = self.env.get("ICEBERG_CONNECTOR_NAME", "iceberg-sink")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", self.name):
            raise ValueError("ICEBERG_CONNECTOR_NAME must use letters, digits, '.', '_' or '-'")
        if not self.username or re.search(r"[:\s]", self.username):
            raise ValueError("ICEBERG_SERVICE_ID must contain no ':' or whitespace")
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+", self.env["ICEBERG_TABLE"]):
            raise ValueError("ICEBERG_TABLE must be a namespace-qualified table name")
        for name in ["CPD_URL", "ICEBERG_WATSONX_REST_URI", "ICEBERG_COS_ENDPOINT"]:
            url = urllib.parse.urlsplit(self.env[name])
            if url.scheme != "https" or not url.hostname or url.username or url.query or url.fragment:
                raise ValueError(f"{name} must be an HTTPS URL without credentials, query or fragment")
        self.verify = boolean(self.env.get("ICEBERG_VERIFY_TLS", "true"))
        self.apply = boolean(self.env.get("ICEBERG_APPLY_CONNECTOR", "true"))
        self.interval = str(int(self.env.get("ICEBERG_COMMIT_INTERVAL_MS", "300000")))
        if int(self.interval) <= 0:
            raise ValueError("ICEBERG_COMMIT_INTERVAL_MS must be positive")
        boolean(self.env.get("ICEBERG_COS_PATH_STYLE_ACCESS", "false"))
        self.output = Path(self.env.get("ICEBERG_OUTPUT_FILE", str(self.root / "configs/confluent_platform_config/iceberg-sink.json"))).resolve()
        try:
            self.output.relative_to(self.root.resolve())
        except ValueError:
            raise ValueError("ICEBERG_OUTPUT_FILE must be inside this repository and ignored by Git") from None
        check = subprocess.run(["git", "check-ignore", "-q", "--", str(self.output)], cwd=self.root)
        if check.returncode:
            raise ValueError("ICEBERG_OUTPUT_FILE must be ignored by Git and must not be tracked")
        self.credentials = self.root / "configs/openshift_config/service_id_credentials.txt"
        self.instance_name = self.env.get("ICEBERG_WATSONX_INSTANCE", "lakehouse")
        self.port = str(int(self.env.get("CONFLUENT_CONNECT_PORT", "8083")))

    def config(self, password):
        path = self.root / "scripts/install_confluent_platform/connector_configs/iceberg-avro.example.json"
        config = json.loads(path.read_text())
        config.update({
            "name": self.name,
            "topics": self.env["ICEBERG_KAFKA_TOPIC"],
            "value.converter.schema.registry.url": self.env.get("ICEBERG_SCHEMA_REGISTRY_URL", f"http://schema-registry:{self.env.get('CONFLUENT_SCHEMA_REGISTRY_PORT', '8081')}"),
            "iceberg.catalog.uri": self.env["ICEBERG_WATSONX_REST_URI"].rstrip("/"),
            "iceberg.catalog.warehouse": self.env["ICEBERG_WATSONX_CATALOG"],
            "iceberg.catalog.rest.auth.basic.username": self.username,
            "iceberg.catalog.rest.auth.basic.password": password,
            "iceberg.catalog.s3.endpoint": self.env["ICEBERG_COS_ENDPOINT"],
            "iceberg.catalog.client.region": self.env["ICEBERG_COS_REGION"],
            "iceberg.catalog.s3.access-key-id": self.env["ICEBERG_COS_ACCESS_KEY_ID"],
            "iceberg.catalog.s3.secret-access-key": self.env["ICEBERG_COS_SECRET_ACCESS_KEY"],
            "iceberg.catalog.s3.path-style-access": self.env.get("ICEBERG_COS_PATH_STYLE_ACCESS", "false"),
            "iceberg.tables": self.env["ICEBERG_TABLE"],
            "iceberg.control.commit.interval-ms": self.interval,
        })
        return config


class Connect:
    """Reach the worker inside its pod; never put connector credentials in argv."""

    def __init__(self, settings):
        self.settings = settings

    def request(self, method, path, body=None):
        args = ["oc", "exec", "-i", "deployment/connect", "-n", self.settings.namespace, "--",
                "curl", "-sS", "--max-time", "30", "-X", method,
                "-H", "Content-Type: application/json", "-w", "\n%{http_code}"]
        if body is not None:
            args += ["--data-binary", "@-"]
        args += [f"http://localhost:{self.settings.port}" + path]
        response = subprocess.run(args, input="" if body is None else json.dumps(body), capture_output=True, text=True)
        if response.returncode:
            raise RuntimeError("Cannot reach the Connect worker; check deployment/connect and its REST service")
        try:
            raw, code = response.stdout.rsplit("\n", 1)
            return int(code), json.loads(raw) if raw else {}
        except ValueError:
            raise RuntimeError("The Connect worker returned an invalid REST response") from None

    def require(self, method, path, body=None):
        code, data = self.request(method, path, body)
        if not 200 <= code < 300:
            raise RuntimeError(f"Connect {method} {path}: HTTP {code}")
        return data

    def validate(self, config):
        result = self.require("PUT", f"/connector-plugins/{CONNECTOR_CLASS}/config/validate", config)
        if result.get("error_count", 0):
            names = [x.get("value", {}).get("name", "unknown") for x in result.get("configs", []) if x.get("value", {}).get("errors")]
            raise RuntimeError("Connector validation failed for: " + ", ".join(names))
        info("Connector configuration validation passed")


def saved_password(settings):
    if settings.env.get("ICEBERG_SERVICE_PASSWORD"):
        return settings.env["ICEBERG_SERVICE_PASSWORD"]
    if settings.credentials.exists():
        prefix = settings.username + ":"
        for line in settings.credentials.read_text().splitlines():
            if line.startswith(prefix):
                return line[len(prefix):]
    return ""


def password_works(settings, password):
    if not password:
        return False
    try:
        SoftwareHub.sign_in(settings.env["CPD_URL"], settings.username, password=password, verify=settings.verify)
        return True
    except APIError as exc:
        if exc.status == 401:
            return False
        raise


def prepare_identity(settings):
    """Run the existing account helper with an isolated CPD kubeconfig."""
    for command in ["oc", "zsh", "htpasswd", "openssl", "jq"]:
        if not shutil.which(command):
            raise RuntimeError(f"SID creation requires {command!r}")
    helper = settings.root / "src/utilities/redhat_openshift_utils/set_service_id_user_proxies.sh"
    current = subprocess.run(["oc", "config", "view", "--raw", "--flatten"], capture_output=True, text=True, check=True)
    with tempfile.TemporaryDirectory(prefix="iceberg-cpd-") as directory:
        kubeconfig = Path(directory) / "config"
        kubeconfig.touch(mode=0o600)
        kubeconfig.write_text(current.stdout)
        env = {**settings.env, "KUBECONFIG": str(kubeconfig),
               "ENV_TARGET": settings.env.get("ICEBERG_CPD_ENV_TARGET", "cpd")}
        # The helper prints newly issued passwords; retain them only in its private credentials file.
        result = subprocess.run(["zsh", str(helper), settings.username], env=env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f"SID setup failed (exit {result.returncode}); run {helper.name} for {settings.username} with the selected CPD environment to inspect it")
    password = saved_password(settings)
    if not password_works(settings, password):
        raise RuntimeError("The prepared SID cannot sign in to CPD_URL; check ICEBERG_CPD_ENV_TARGET and the Software Hub details file")
    return password


def catalog_config(settings, authorization):
    uri = settings.env["ICEBERG_WATSONX_REST_URI"].rstrip("/")
    query = urllib.parse.urlencode({"warehouse": settings.env["ICEBERG_WATSONX_CATALOG"]})
    return request_json(uri + "/v1/config?" + query, headers={"Authorization": authorization}, verify=settings.verify)


def write_config(path, config):
    """Atomically write private JSON, including when an older output was public."""
    if path.exists() and json.loads(path.read_text()) == config:
        path.chmod(0o600)
        return "unchanged"
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".iceberg-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(config, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return "written"


def setup(settings, *, dry_run=False, prepare_only=False):
    hub = SoftwareHub.sign_in(
        settings.env["CPD_URL"], settings.env["CPD_USERNAME"],
        password=settings.env.get("CPD_PASSWORD", ""), api_key=settings.env.get("CPD_APIKEY", ""),
        verify=settings.verify,
    )
    instance = hub.find_instance(settings.instance_name, "watsonx-data")
    catalog_config(settings, "Bearer " + hub.token)
    connect = Connect(settings)
    plugins = connect.require("GET", "/connector-plugins")
    installed = any(x["class"] == CONNECTOR_CLASS for x in plugins)
    path = "/connectors/" + urllib.parse.quote(settings.name, safe="") + "/config"
    code, existing = connect.request("GET", path)
    if code not in (200, 404):
        raise RuntimeError(f"Cannot inspect existing connector {settings.name!r}: HTTP {code}")
    if code == 200 and existing.get("connector.class") != CONNECTOR_CLASS:
        raise RuntimeError(f"Connector name {settings.name!r} is already used by another connector type")
    account = hub.user(settings.username)
    password = saved_password(settings)
    working = bool(account) and password_works(settings, password)
    if settings.env.get("ICEBERG_SERVICE_PASSWORD") and not working:
        raise RuntimeError("ICEBERG_SERVICE_PASSWORD cannot sign in; repair the supplied account or omit this setting to manage an htpasswd SID")
    member = hub.member(instance["id"], settings.username) if account else None
    role_matches = bool(member) and member["role"] == "Metastore Admin"
    if account and account.get("authenticator") != "external" and not working:
        raise RuntimeError("The selected account is not an external SID; supply its working password or choose a dedicated service ID")
    info(f"Target: Connect project {settings.namespace}, catalog {settings.env['ICEBERG_WATSONX_CATALOG']}, connector {settings.name}")
    info(f"Plugin: {'already loaded' if installed else 'installation required'}; SID: {settings.username} ({'working password reused' if working else 'creation/repair required'})")
    info(f"Lakehouse Metastore Admin: {'already assigned' if role_matches else 'assignment required'}")
    candidate = {**(existing if code == 200 else {}), **settings.config(password if working else "preflight-password")}
    if installed:
        connect.validate(candidate)
    if dry_run:
        if working and role_matches:
            authorization = "Basic " + base64.b64encode((settings.username + ":" + password).encode()).decode()
            catalog_config(settings, authorization)
            info("SID authentication to the Iceberg REST catalog passed")
        matches = code == 200 and working and existing == candidate
        info("Connector: " + ("configuration already matches" if matches else "would create" if code == 404 else "would update"))
        info(f"Dry run: would prepare {settings.output}; connector deployment {'enabled' if settings.apply and not prepare_only else 'disabled'}")
        return
    if not working:
        password = prepare_identity(settings)
    action = hub.ensure_role(instance["id"], settings.username, "Metastore Admin")
    info("Lakehouse role: " + action)
    authorization = "Basic " + base64.b64encode((settings.username + ":" + password).encode()).decode()
    catalog_config(settings, authorization)
    info("SID authentication to the Iceberg REST catalog passed")
    if not installed:
        helper = settings.root / "scripts/install_confluent_platform/utility_scripts_confluent_platform/x.3_confluent_add_connector.sh"
        result = subprocess.run(["zsh", str(helper), settings.env.get("ICEBERG_PLUGIN_SOURCE", "iceberg/iceberg-kafka-connect:1.9.2"), "--name", "iceberg"], env=settings.env)
        if result.returncode:
            raise RuntimeError(f"Iceberg plugin installation failed (exit {result.returncode})")
        if not any(x["class"] == CONNECTOR_CLASS for x in connect.require("GET", "/connector-plugins")):
            raise RuntimeError("Iceberg plugin was installed but is not loaded by the worker")
    config = {**(existing if code == 200 else {}), **settings.config(password)}
    if not installed:
        connect.validate(config)
    action = write_config(settings.output, config)
    info(f"Local connector configuration {action}: {settings.output} (0600, Git-ignored)")
    if prepare_only or not settings.apply:
        info("Prepared for Control Center upload; connector deployment disabled")
        return
    if code == 200 and existing == config:
        info("Connector configuration already matches; no update needed")
    else:
        connect.require("PUT", path, config)
        info(f"Connector {'created' if code == 404 else 'updated'}: {settings.name}")
    status_path = "/connectors/" + urllib.parse.quote(settings.name, safe="") + "/status"
    status = connect.require("GET", status_path)
    info("Connector state: " + status.get("connector", {}).get("state", "pending"))
    tasks = status.get("tasks", [])
    for task in tasks:
        info(f"Task {task['id']}: {task['state']}")
    if status.get("connector", {}).get("state") == "FAILED" or any(x["state"] == "FAILED" for x in tasks):
        raise RuntimeError("Connector or task failed; inspect its status in Control Center")
    info("COS authorization and ingestion must be verified after the first table commit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--service-id", help="Override ICEBERG_SERVICE_ID")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    env = dict(os.environ)
    if args.service_id:
        env["ICEBERG_SERVICE_ID"] = args.service_id
    try:
        settings = Settings(args.repo_root, env)
        setup(settings, dry_run=args.dry_run, prepare_only=args.prepare_only)
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as exc:
        print("[ERROR] " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
