#!/usr/bin/env python3
"""confluent_cfk_render.py - render the operator-mode (CFK) manifests of the Confluent installer.

Reads one input JSON on stdin (never a secret value: only secret names and presence flags), renders the
Jinja2 templates in confluent_cfk_jinja2_templates/, validates the result and writes one object per file.

    confluent_cfk_render.py list-inputs                         # one allowed var name per line
    confluent_cfk_render.py input-from-env [--live <live.json>] # stdout: input JSON from os.environ
    confluent_cfk_render.py validate [--set S] [--args F] < input.json
    confluent_cfk_render.py render --set <set> --out-dir <root> [--args <args.json>] < input.json

Sets: platform, repo, topic, connector, connect-plugins, flink, flink-app.
`render` first deletes every *.yaml, *.conf and manifest.json in <root>/<set>/ (stale-file safety), then
writes the files and <root>/<set>/manifest.json and prints the same manifest JSON on stdout. stderr carries
[INFO]/[WARN] lines. Any validation error: exit 1 with [ERROR] lines and nothing written. The trial-license
[WARN] is left off stderr (it stays in the manifest) when _CFO_LICENSE_WARNED=1: the shell printed it already.

Python API (confluent_iceberg_setup.py, tests):
    render(doc, set_name, out_dir=None, args=None) -> manifest dict
        out_dir=None returns the manifest with a "text" field per file and writes nothing.
    RenderError, ALLOWED_INPUT_VARS

Spec: .claude/plans/confluent-operator-install-mode/implementation-contract.md section 4.
"""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(HERE, "confluent_cfk_jinja2_templates")

try:
    import jinja2
    import yaml
except ImportError:  # pragma: no cover - the venv has both
    print("[ERROR] jinja2 and PyYAML are needed to render the CFK manifests - run `uv sync` in the repo.",
          file=sys.stderr)
    sys.exit(1)

try:
    from .version_catalog import catalog_value
except ImportError:
    sys.path.insert(0, HERE)
    from version_catalog import catalog_value


# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCHEMA_VERSION = 1
SETS = ("platform", "repo", "topic", "connector", "connect-plugins", "flink", "flink-app")
PLATFORM_FAMILY = ("platform", "repo", "topic", "connector", "connect-plugins")
FLINK_FAMILY = ("flink", "flink-app")
API_CFK = "platform.confluent.io/v1beta1"

# Names fixed by the contract (section 2.6, O10). The shell side holds the same values.
SASL_SERVER_SECRET = "confluent-sasl-cfk-server"
SASL_CLIENT_SECRET = "confluent-sasl-cfk-client"
LICENSE_SECRET = "confluent-license"
MDS_TOKEN_SECRET = "confluent-mds-cfk-token"
MDS_LDAP_SECRET = "confluent-ldap-cfk-bind"
MDS_CLIENT_SECRET = "confluent-mds-cfk-client"
FRONT_PROXY = "control-center-auth"
# Pod-template annotation on the front-proxy Deployment: sha256 of its secret's content (the rendered nginx.conf
# plus args.front_proxy_secret_digest, the shell's digest of the credentials), so a secret change rolls it.
FRONT_PROXY_CHECKSUM_ANNOTATION = "confluent.ibm-scripts/front-proxy-secret-checksum"
LICENSE_WARNING_PREFIX = "No CONFLUENT_LICENSE_KEY"
SERVICE_ACCOUNT = "confluent"
CR_NAMES = {"KRaftController": "kraftcontroller", "Kafka": "kafka", "SchemaRegistry": "schema-registry",
            "Connect": "connect", "KsqlDB": "ksqldb-server", "KafkaRestProxy": "rest-proxy",
            "ControlCenter": "control-center", "KafkaRestClass": "default",
            "ConfluentRolebinding": "mds-super-systemadmin"}
# CFK ports are fixed (V2/V18); the scripts-mode port vars are ignored.
PORTS = {"kafka_internal": 9071, "sr": 8081, "connect": 8083, "ksqldb": 8088, "c3": 9021,
         "prometheus": 9090, "alertmanager": 9093}
MDS_PORT = 8090  # Kafka's embedded REST / MDS (Service port name http-external)
KAFKA_NP_SAME_NS_PORTS = (9072, MDS_PORT, 7203, 7777, 7778)
INGRESS_NAMESPACE_SELECTORS = [
    {"namespaceSelector": {"matchLabels": {"network.openshift.io/policy-group": "ingress"}}},
    {"namespaceSelector": {"matchLabels": {"policy-group.network.openshift.io/host-network": ""}}},
]
CONNECT_PLUGIN_PATH = "/usr/share/java,/usr/share/confluent-hub-components,/mnt/plugins,/mnt/local-plugins"
LOCAL_PLUGINS_MOUNT = "/mnt/local-plugins"
SCRAM_LINKS = (
    "https://docs.confluent.io/operator/current/co-authenticate-overview.html",
    "https://docs.confluent.io/operator/current/co-configure-misc.html#co-config-overrides",
    "https://docs.confluent.io/operator/current/co-authenticate-kafka.html",
    "https://docs.confluent.io/platform/current/security/authentication/sasl/scram/overview.html",
)
SCRAM_PLAIN_ERROR = ("SCRAM needs CONFLUENT_OPERATOR_SASL_IMPL=scram (configOverrides; outside Confluent Support) "
                     "or use PLAIN")
FLINK_DEFAULT_JAR = "local:///opt/flink/examples/streaming/StateMachineExample.jar"

SECRET_VAR_RE = re.compile(r"(_PASSWORD|_PASS|_SECRET_KEY|_ACCESS_KEY|_LICENSE_KEY|_TOKEN|_CREDS)$")
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
CLUSTER_ID_RE = re.compile(r"^[A-Za-z0-9_-]{22}$")
KRAFT_STORAGE_RE = re.compile(r"^[0-9]+(Mi|Gi|Ti)$")
DNS1123_RE = re.compile(r"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$")
LABEL_VALUE_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$")
FLINK_VERSION_RE = re.compile(r"^v(\d+)_(\d+)$")
MECHANISMS = ("PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512")

# Every var a template or a check reads. None of them carries a secret value (section 4.4).
ALLOWED_INPUT_VARS = frozenset({
    # namespaces / storage
    "PROJECT_CONFLUENT_SERVER", "PROJECT_CONFLUENT_FLINK", "STG_CLASS_BLOCK", "STG_CLASS_FILE",
    "CONFLUENT_STORAGE_CLASS",
    # images
    "CONFLUENT_VERSION", "CONFLUENT_C3_VERSION", "CONFLUENT_REGISTRY", "CONFLUENT_BROKER_IMAGE",
    "CONFLUENT_CONNECT_IMAGE", "CONFLUENT_CONTROL_CENTER_IMAGE", "CONFLUENT_PROMETHEUS_IMAGE",
    "CONFLUENT_ALERTMANAGER_IMAGE", "CONFLUENT_PULL_SECRET", "CONFLUENT_OPERATOR_IMAGE_SOURCE",
    "CONFLUENT_OPERATOR_INIT_IMAGE",
    # component toggles
    "CONFLUENT_INSTALL_SCHEMA_REGISTRY", "CONFLUENT_INSTALL_CONNECT", "CONFLUENT_INSTALL_KSQLDB",
    "CONFLUENT_INSTALL_REST_PROXY", "CONFLUENT_INSTALL_CONTROL_CENTER",
    # sizing
    "CONFLUENT_CLUSTER_ID", "CONFLUENT_BROKER_REPLICAS", "CONFLUENT_REPLICATION_FACTOR",
    "CONFLUENT_MIN_INSYNC_REPLICAS", "CONFLUENT_PARTITIONS", "CONFLUENT_BROKER_STORAGE_SIZE",
    "CONFLUENT_BROKER_CPU_REQUEST", "CONFLUENT_BROKER_MEM_REQUEST", "CONFLUENT_BROKER_CPU_LIMIT",
    "CONFLUENT_BROKER_MEM_LIMIT", "CONFLUENT_COMPONENT_CPU_REQUEST", "CONFLUENT_COMPONENT_MEM_REQUEST",
    "CONFLUENT_COMPONENT_CPU_LIMIT", "CONFLUENT_COMPONENT_MEM_LIMIT",
    "CONFLUENT_KRAFT_REPLICAS", "CONFLUENT_KRAFT_STORAGE_SIZE", "CONFLUENT_KRAFT_CPU_REQUEST",
    "CONFLUENT_KRAFT_CPU_LIMIT", "CONFLUENT_KRAFT_MEM_REQUEST", "CONFLUENT_KRAFT_MEM_LIMIT",
    "CONFLUENT_KSQLDB_STORAGE_SIZE", "CONFLUENT_C3_STORAGE_SIZE", "CONFLUENT_PROMETHEUS_STORAGE_SIZE",
    # security
    "CONFLUENT_SASL_ENABLED", "CONFLUENT_SASL_PROTOCOL", "CONFLUENT_SASL_MECHANISM",
    "CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS", "CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS",
    "CONFLUENT_SASL_ADMIN_USER", "CONFLUENT_SASL_SECRET", "CONFLUENT_INTERNAL_TLS_SECRET",
    "CONFLUENT_OPERATOR_TLS_SOURCE", "CONFLUENT_OPERATOR_TLS_SOURCE_CLI", "CONFLUENT_OPERATOR_SASL_IMPL",
    # external access / routes
    "CONFLUENT_EXTERNAL_KAFKA_ENABLED", "CONFLUENT_EXTERNAL_TLS_SECRET", "CONFLUENT_EXTERNAL_KAFKA_BOOTSTRAP_PREFIX",
    "CONFLUENT_EXTERNAL_KAFKA_BROKER_PREFIX", "CONFLUENT_CREATE_ROUTES", "CONFLUENT_ROUTE_DOMAIN",
    # web UI front proxy
    "CONFLUENT_AUTH_ENABLED", "CONFLUENT_AUTH_MODE", "CONFLUENT_AUTH_SECRET", "CONFLUENT_C3_GATEWAY_PORT",
    "CONFLUENT_C3_OAUTH_PROXY_IMAGE", "CONFLUENT_C3_GATEWAY_IMAGE",
    # network policies / topics
    "CONFLUENT_MONITORING_NETWORK_POLICY", "CONFLUENT_OPERATOR_NETWORK_POLICIES", "CONFLUENT_AUTO_CREATE_TOPICS",
    # MDS (phase 5)
    "CONFLUENT_MDS_ENABLED", "CONFLUENT_MDS_USER_STORE", "CONFLUENT_MDS_SUPER_USER", "CONFLUENT_LDAP_PORT",
    "CONFLUENT_LDAP_DOMAIN", "CONFLUENT_MDS_OAUTH_JWKS_URL", "CONFLUENT_MDS_OAUTH_ISSUER",
    "CONFLUENT_MDS_OAUTH_AUDIENCE", "CONFLUENT_MDS_OAUTH_SUB_CLAIM", "CONFLUENT_MDS_OAUTH_GROUPS_CLAIM",
    # Connect
    "CONFLUENT_CONNECTOR_MANAGEMENT", "CONFLUENT_CONNECT_PLUGINS_PVC", "CONFLUENT_CONNECT_PLUGINS_PVC_SIZE",
    "CONFLUENT_CONNECT_PLUGINS_LOADER_IMAGE",
    # Flink
    "FLINK_CFK_NAMESPACE", "FLINK_CMF_RESTCLASS_NAME", "FLINK_CMF_SERVICE", "FLINK_CMF_PORT", "FLINK_ENVIRONMENT",
    "FLINK_APPLICATION_IMAGE", "FLINK_APPLICATION_VERSION", "FLINK_TASK_SLOTS", "FLINK_JOBMANAGER_CPU",
    "FLINK_JOBMANAGER_MEMORY", "FLINK_TASKMANAGER_CPU", "FLINK_TASKMANAGER_MEMORY", "FLINK_OPERATOR_SOURCE",
    "FLINK_CMF_RESOURCE_MODE",
})
assert not [v for v in ALLOWED_INPUT_VARS if SECRET_VAR_RE.search(v) or v == "OCP_PASSWORD"]

# Section 2.3 presets. They live in confluent_operator_config.KRAFT_PRESETS; this copy is only used while that
# module cannot be imported (or lacks a key), so a renderer run never depends on it.
_FALLBACK_KRAFT_PRESETS = {
    "xsmall": {"CONFLUENT_KRAFT_REPLICAS": "1", "CONFLUENT_KRAFT_STORAGE_SIZE": "10Gi",
               "CONFLUENT_KRAFT_CPU_REQUEST": "250m", "CONFLUENT_KRAFT_CPU_LIMIT": "1",
               "CONFLUENT_KRAFT_MEM_REQUEST": "512Mi", "CONFLUENT_KRAFT_MEM_LIMIT": "1Gi",
               "CONFLUENT_KSQLDB_STORAGE_SIZE": "10Gi", "CONFLUENT_C3_STORAGE_SIZE": "10Gi",
               "CONFLUENT_PROMETHEUS_STORAGE_SIZE": "10Gi"},
    "small": {"CONFLUENT_KRAFT_REPLICAS": "3", "CONFLUENT_KRAFT_STORAGE_SIZE": "10Gi",
              "CONFLUENT_KRAFT_CPU_REQUEST": "250m", "CONFLUENT_KRAFT_CPU_LIMIT": "1",
              "CONFLUENT_KRAFT_MEM_REQUEST": "1Gi", "CONFLUENT_KRAFT_MEM_LIMIT": "2Gi",
              "CONFLUENT_KSQLDB_STORAGE_SIZE": "10Gi", "CONFLUENT_C3_STORAGE_SIZE": "10Gi",
              "CONFLUENT_PROMETHEUS_STORAGE_SIZE": "10Gi"},
    "medium": {"CONFLUENT_KRAFT_REPLICAS": "3", "CONFLUENT_KRAFT_STORAGE_SIZE": "20Gi",
               "CONFLUENT_KRAFT_CPU_REQUEST": "500m", "CONFLUENT_KRAFT_CPU_LIMIT": "1",
               "CONFLUENT_KRAFT_MEM_REQUEST": "2Gi", "CONFLUENT_KRAFT_MEM_LIMIT": "4Gi",
               "CONFLUENT_KSQLDB_STORAGE_SIZE": "20Gi", "CONFLUENT_C3_STORAGE_SIZE": "20Gi",
               "CONFLUENT_PROMETHEUS_STORAGE_SIZE": "20Gi"},
    "large": {"CONFLUENT_KRAFT_REPLICAS": "3", "CONFLUENT_KRAFT_STORAGE_SIZE": "50Gi",
              "CONFLUENT_KRAFT_CPU_REQUEST": "1", "CONFLUENT_KRAFT_CPU_LIMIT": "2",
              "CONFLUENT_KRAFT_MEM_REQUEST": "4Gi", "CONFLUENT_KRAFT_MEM_LIMIT": "8Gi",
              "CONFLUENT_KSQLDB_STORAGE_SIZE": "50Gi", "CONFLUENT_C3_STORAGE_SIZE": "50Gi",
              "CONFLUENT_PROMETHEUS_STORAGE_SIZE": "50Gi"},
}


def _small_preset(name):
    """The 'small' preset value of <name>, from confluent_operator_config.KRAFT_PRESETS when importable."""
    try:
        try:
            from . import confluent_operator_config as coc
        except ImportError:
            if HERE not in sys.path:
                sys.path.insert(0, HERE)
            import confluent_operator_config as coc
        value = coc.KRAFT_PRESETS["small"][name]
        if isinstance(value, (str, int)) and str(value):
            return str(value)
    except Exception:  # noqa: BLE001 - any failure there falls back to the contract's table
        return _FALLBACK_KRAFT_PRESETS["small"][name]
    return _FALLBACK_KRAFT_PRESETS["small"][name]


class RenderError(Exception):
    """Validation failed; .errors holds every message (without the [ERROR] prefix)."""

    def __init__(self, errors):
        self.errors = list(errors)
        super().__init__("; ".join(self.errors))


# ------------------------------------------------------------------------------
# Input access
# ------------------------------------------------------------------------------
class Ctx:
    """The input vars and live facts plus the info/warning/error lists of one render."""

    def __init__(self, doc, args):
        self.doc = doc
        self.vars = doc.get("vars") or {}
        self.live = doc.get("live") or {}
        self.args = args or {}
        self.info, self.warnings, self.errors = [], [], []

    def note(self, msg):
        if msg not in self.info:
            self.info.append(msg)

    def warn(self, msg):
        if msg not in self.warnings:
            self.warnings.append(msg)

    def error(self, msg):
        if msg not in self.errors:
            self.errors.append(msg)

    def get(self, name, default=None):
        """Var value; empty or missing = <default>."""
        value = self.vars.get(name)
        return default if value is None or value == "" else value

    def flag(self, name, default):
        """Shell parity: "true" (any case) is on, any other set value is off, missing = <default>."""
        value = self.get(name)
        return default if value is None else value.strip().lower() == "true"

    def choice(self, name, allowed, default):
        value = self.get(name)
        if value is None:
            return default
        norm = value.strip().lower()
        for option in allowed:
            if option.lower() == norm:
                return option
        self.warn(f"{name}='{value}' is not {'|'.join(allowed)} - using {default}")
        return default

    def preset(self, name):
        """Operator sizing var with the 'small' preset as fallback (section 2.3)."""
        value = self.get(name)
        if value is None:
            value = _small_preset(name)
            self.note(f"{name} unset - using {value}")
        return value

    def integer(self, name, default=None, minimum=None):
        raw = self.get(name)
        if raw is None:
            if default is None:
                self.error(f"{name} is not set")
            return default
        try:
            value = int(str(raw).strip())
        except ValueError:
            self.error(f"{name}='{raw}' is not an integer")
            return default
        if minimum is not None and value < minimum:
            self.error(f"{name}={value} must be >= {minimum}")
        return value

    def live_flag(self, key):
        return self.live.get(key) is True


def _labels(owner):
    return {"app.kubernetes.io/part-of": "confluent", "confluent.ibm-scripts/installed-by": owner,
            "confluent.ibm-scripts/deploy-mode": "operator"}


def _mechs(ctx, name):
    raw = ctx.get(name, "PLAIN")
    out = []
    for item in raw.split(","):
        mech = item.strip().upper()
        if not mech:
            continue
        if mech not in MECHANISMS:
            ctx.error(f"{name}: unknown SASL mechanism '{item.strip()}' (allowed: {', '.join(MECHANISMS)})")
            continue
        if mech not in out:
            out.append(mech)
    return out or ["PLAIN"]


def _cpu_cores(value):
    value = str(value).strip()
    try:
        return float(value[:-1]) / 1000 if value.endswith("m") else float(value)
    except ValueError:
        return None


def _resources(ctx, prefix, preset=False):
    """{requests, limits} from <prefix>_CPU_REQUEST / _MEM_REQUEST / _CPU_LIMIT / _MEM_LIMIT."""
    get = ctx.preset if preset else ctx.get
    out = {}
    for kind, suffix in (("requests", "REQUEST"), ("limits", "LIMIT")):
        part = {}
        for field, key in (("cpu", "CPU"), ("memory", "MEM")):
            value = get(f"{prefix}_{key}_{suffix}")
            if value:
                part[field] = str(value)
        if part:
            out[kind] = part
    return out


def _dns_name(ctx, what, name):
    if not isinstance(name, str) or not DNS1123_RE.match(name):
        ctx.error(f"{what} '{name}' is not a valid Kubernetes name (lowercase DNS-1123)")
        return False
    return True


# ------------------------------------------------------------------------------
# Platform-family model (platform, repo, topic, connector, connect-plugins)
# ------------------------------------------------------------------------------
def _common(ctx):
    """Toggles and security settings every platform-family set needs."""
    doc = ctx.doc
    ns = doc["namespace"]
    owner = doc["owner_id"]
    m = {"ns": ns, "owner": owner, "labels": _labels(owner),
         "inject_labels": {"app.kubernetes.io/part-of": "confluent"},
         "license_present": ctx.live_flag("license_present"), "license_secret": LICENSE_SECRET,
         "kraft_name": CR_NAMES["KRaftController"]}
    m["on"] = {
        "sr": ctx.flag("CONFLUENT_INSTALL_SCHEMA_REGISTRY", True),
        "connect": ctx.flag("CONFLUENT_INSTALL_CONNECT", True),
        "ksqldb": ctx.flag("CONFLUENT_INSTALL_KSQLDB", True),
        "krp": ctx.flag("CONFLUENT_INSTALL_REST_PROXY", True),
        "c3": ctx.flag("CONFLUENT_INSTALL_CONTROL_CENTER", True),
    }
    mds = ctx.flag("CONFLUENT_MDS_ENABLED", False)
    sasl = ctx.flag("CONFLUENT_SASL_ENABLED", False)
    if mds and not sasl:
        # Same rule and wording as 1.1_confluent_install.sh:131-137.
        ctx.note("CONFLUENT_MDS_ENABLED=true implies SASL; enabling it (MDS requires it).")
        sasl = True
    m["mds"], m["sasl"] = mds, sasl
    if mds:
        ctx.note("MDS/RBAC in operator mode is phase 5 (unverified: V5, V21)")

    protocol = ctx.get("CONFLUENT_SASL_PROTOCOL", "SASL_PLAINTEXT").strip().upper()
    if sasl and protocol not in ("SASL_PLAINTEXT", "SASL_SSL"):
        ctx.error(f"CONFLUENT_SASL_PROTOCOL='{protocol}' is not SASL_PLAINTEXT|SASL_SSL")
    m["tls_internal"] = sasl and protocol == "SASL_SSL"

    m["impl"] = ctx.choice("CONFLUENT_OPERATOR_SASL_IMPL", ("plain", "scram"), "plain")
    m["internal_mechs"] = _mechs(ctx, "CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS")
    m["external_mechs"] = _mechs(ctx, "CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS")
    if sasl:
        mechanism = ctx.get("CONFLUENT_SASL_MECHANISM", "PLAIN").strip().upper()
        if mechanism != "PLAIN":
            ctx.error(f"CONFLUENT_SASL_MECHANISM={mechanism}: operator mode authenticates the components with "
                      "CFK's native PLAIN - set it to PLAIN (plan O9, contract D10)")
        # CONTRACT-DEVIATION: contract 4.4 lists "SCRAM with impl plain" without a SASL condition; without SASL
        # the mechanism lists are unused, so a legacy SCRAM list must not block a no-SASL install.
        has_scram = any(x.startswith("SCRAM") for x in m["internal_mechs"] + m["external_mechs"])
        if has_scram and m["impl"] == "plain":
            ctx.error(SCRAM_PLAIN_ERROR)
        if m["impl"] == "scram":
            ctx.warn("SCRAM through configOverrides is documented by Confluent but outside Confluent Support: "
                     + " ".join(SCRAM_LINKS))

    tls_source = ctx.get("CONFLUENT_OPERATOR_TLS_SOURCE_CLI")
    if tls_source is not None:
        m["tls_source"] = ctx.choice("CONFLUENT_OPERATOR_TLS_SOURCE_CLI", ("repo", "cfk"), "repo")
    else:
        m["tls_source"] = ctx.choice("CONFLUENT_OPERATOR_TLS_SOURCE", ("repo", "cfk"), "repo")

    m["external"] = ctx.flag("CONFLUENT_EXTERNAL_KAFKA_ENABLED", False)
    if m["external"] and not sasl:
        ctx.error("CONFLUENT_EXTERNAL_KAFKA_ENABLED=true needs CONFLUENT_SASL_ENABLED=true (the external "
                  "listener is never left unauthenticated)")
    m["internal_tls_secret"] = ctx.get("CONFLUENT_INTERNAL_TLS_SECRET", "confluent-kafka-internal-tls")
    m["external_tls_secret"] = ctx.get("CONFLUENT_EXTERNAL_TLS_SECRET", "confluent-kafka-tls")
    m["cfk_tls"] = m["tls_source"] == "cfk" and (m["tls_internal"] or m["external"])

    svc = f"{ns}.svc.cluster.local"
    m["bootstrap"] = f"kafka.{svc}:{PORTS['kafka_internal']}"
    m["urls"] = {
        "sr": f"http://schema-registry.{svc}:{PORTS['sr']}",
        "connect": f"http://connect.{svc}:{PORTS['connect']}",
        "ksqldb": f"http://ksqldb-server.{svc}:{PORTS['ksqldb']}",
        "c3": f"http://control-center.{svc}:{PORTS['c3']}",
        "prometheus": f"http://control-center.{svc}:{PORTS['prometheus']}",
        "alertmanager": f"http://control-center.{svc}:{PORTS['alertmanager']}",
    }
    return m


def _kafka_dependency(m):
    """dependencies.kafka of every component CR (contract 4.5, client dependency macro)."""
    dep = {"bootstrapEndpoint": m["bootstrap"]}
    if m["sasl"]:
        dep["authentication"] = {"type": "plain", "jaasConfig": {"secretRef": SASL_CLIENT_SECRET}}
    if m["tls_internal"]:
        if m["tls_source"] == "repo":
            dep["tls"] = {"enabled": True, "secretRef": m["internal_tls_secret"]}
        else:
            dep["tls"] = {"enabled": True}
    return dep


def _component_tls(m):
    """Component spec.tls: CFK-generated certs so the component trusts the CFK CA (cfk + SASL_SSL)."""
    return {"autoGeneratedCerts": True} if m["tls_source"] == "cfk" and m["tls_internal"] else None


def _images(ctx, m):
    source = ctx.choice("CONFLUENT_OPERATOR_IMAGE_SOURCE", ("tags", "csv"), "tags")
    reg = ctx.get("CONFLUENT_REGISTRY")
    if reg is None:
        reg = "docker.io/confluentinc"
        ctx.note(f"CONFLUENT_REGISTRY unset - using {reg}")
    version = ctx.get("CONFLUENT_VERSION")
    if version is None:
        version = str(catalog_value("confluent/version", default="8.2.0"))
        ctx.note(f"CONFLUENT_VERSION unset - using {version}")
    if source == "tags" and not VERSION_RE.match(version):
        ctx.error(f"CONFLUENT_VERSION='{version}' must be a concrete X.Y.Z version in tags image mode")
    c3_version = ctx.get("CONFLUENT_C3_VERSION") or str(catalog_value("confluent/c3_version", default="2.5.0"))
    init_tag = str(catalog_value("confluent/operator/cfk_init_tag", default="3.4.0"))
    related = ctx.live.get("related_images") or {}

    def pick(var, basename, tag_default):
        value = ctx.get(var) if var else None
        if value:
            return value
        if source == "csv":
            return str(related.get(basename) or "")
        return tag_default

    images = {
        "init": pick("CONFLUENT_OPERATOR_INIT_IMAGE", "confluent-init-container",
                     f"{reg}/confluent-init-container:{init_tag}"),
        "server": pick("CONFLUENT_BROKER_IMAGE", "cp-server", f"{reg}/cp-server:{version}"),
        "sr": pick(None, "cp-schema-registry", f"{reg}/cp-schema-registry:{version}"),
        "connect": pick("CONFLUENT_CONNECT_IMAGE", "cp-server-connect", f"{reg}/cp-server-connect:{version}"),
        "ksqldb": pick(None, "cp-ksqldb-server", f"{reg}/cp-ksqldb-server:{version}"),
        "krp": pick(None, "cp-kafka-rest", f"{reg}/cp-kafka-rest:{version}"),
        "c3": pick("CONFLUENT_CONTROL_CENTER_IMAGE", "cp-enterprise-control-center-next-gen",
                   f"{reg}/cp-enterprise-control-center-next-gen:{c3_version}"),
        "prometheus": pick("CONFLUENT_PROMETHEUS_IMAGE", "cp-enterprise-prometheus",
                           f"{reg}/cp-enterprise-prometheus:{c3_version}"),
        "alertmanager": pick("CONFLUENT_ALERTMANAGER_IMAGE", "cp-enterprise-alertmanager",
                             f"{reg}/cp-enterprise-alertmanager:{c3_version}"),
    }
    m["image_source"] = source
    pull = ctx.get("CONFLUENT_PULL_SECRET")
    m["pull_secret_ref"] = [pull] if pull and ctx.live_flag("pull_secret_present") else []
    return images


def _image_block(ctx, m, kind, application, init):
    for field, value in (("application", application), ("init", init)):
        if not value:
            hint = (" (image source csv: set the image var or provide live.related_images)"
                    if m["image_source"] == "csv" else "")
            ctx.error(f"{kind} image.{field} is empty{hint}")
    block = {"application": application, "init": init}
    if m["pull_secret_ref"]:
        block["pullSecretRef"] = list(m["pull_secret_ref"])
    return block


def _scram_overrides(m):
    lines = []
    if m["impl"] != "scram":
        return lines
    listeners = [("internal", m["internal_mechs"])]
    if m["sasl"]:  # listeners.external is always rendered when SASL is on (E1)
        listeners.append(("external", m["external_mechs"]))
    for listener, mechs in listeners:
        scram = [x for x in mechs if x.startswith("SCRAM")]
        if not scram:
            continue
        lines.append(f"listener.name.{listener}.sasl.enabled.mechanisms={','.join(scram)},PLAIN")
        for mech in scram:
            lines.append(f"listener.name.{listener}.{mech.lower()}.sasl.jaas.config="
                         "org.apache.kafka.common.security.scram.ScramLoginModule required;")
    return lines


def _connect_state(ctx):
    state = ctx.live.get("connect_state") or {}
    plugins = state.get("plugins") or {}
    if not isinstance(plugins, dict) or not isinstance(state.get("local_plugins") or {}, dict):
        ctx.error("connect_state.plugins and connect_state.local_plugins must be objects")
        plugins, state = {}, {}
    hub = []
    for entry in plugins.get("confluentHub") or []:
        item = {"owner": str(entry.get("owner", "")), "name": str(entry.get("name", "")),
                "version": str(entry.get("version") or "latest")}
        if not item["name"] or not item["owner"]:
            ctx.error(f"connect_state.plugins.confluentHub entry needs owner and name: {json.dumps(entry)}")
        hub.append(item)
    url = []
    for entry in plugins.get("url") or []:
        if not entry.get("checksum"):
            ctx.error(f"Connect onDemand url plugin '{entry.get('name', '?')}' has no checksum (the CRD requires it)")
        if not entry.get("name") or not entry.get("archivePath"):
            ctx.error(f"connect_state.plugins.url entry needs name and archivePath: {json.dumps(entry)}")
        url.append({"name": str(entry.get("name", "")), "archivePath": str(entry.get("archivePath", "")),
                    "checksum": str(entry.get("checksum", ""))})
    local = state.get("local_plugins") or {}
    secrets = [str(s) for s in state.get("mounted_secrets") or [] if s]
    return {"hub": hub, "url": url, "local": local.get("enabled") is True,
            "local_pvc": local.get("pvc") or ctx.get("CONFLUENT_CONNECT_PLUGINS_PVC", "connect-plugins"),
            "mounted_secrets": secrets}


def _platform_items(ctx):
    m = _common(ctx)
    images = _images(ctx, m)
    on = m["on"]
    ns = m["ns"]

    storage_class = ctx.get("CONFLUENT_STORAGE_CLASS") or ctx.get("STG_CLASS_BLOCK")
    if not storage_class:
        ctx.error("storage class is empty (CONFLUENT_STORAGE_CLASS / STG_CLASS_BLOCK)")
    m["storage_class"] = storage_class or ""
    cluster_id = ctx.get("CONFLUENT_CLUSTER_ID", "")
    if not CLUSTER_ID_RE.match(cluster_id):
        ctx.error(f"CONFLUENT_CLUSTER_ID='{cluster_id}' must be 22 characters of [A-Za-z0-9_-] "
                  "(KRaftController.spec.clusterID is immutable)")
    m["cluster_id"] = cluster_id

    replicas = ctx.integer("CONFLUENT_BROKER_REPLICAS", minimum=1)
    rf = ctx.integer("CONFLUENT_REPLICATION_FACTOR", minimum=1)
    min_isr = ctx.integer("CONFLUENT_MIN_INSYNC_REPLICAS", default=1, minimum=1)
    partitions = ctx.integer("CONFLUENT_PARTITIONS", minimum=1)
    if replicas is not None and rf is not None and rf > replicas:
        ctx.error(f"CONFLUENT_REPLICATION_FACTOR={rf} is larger than CONFLUENT_BROKER_REPLICAS={replicas}")

    # Secrets the CRs reference must exist (the caller creates them first and reports presence).
    if m["tls_internal"] and m["tls_source"] == "repo" and not ctx.live_flag("internal_tls_secret_present"):
        ctx.error(f"SASL_SSL with TLS source repo needs secret {m['internal_tls_secret']} "
                  "(live.internal_tls_secret_present is not true)")
    if m["cfk_tls"] and not ctx.live_flag("ca_pair_present"):
        ctx.error("TLS source cfk needs the CA secret ca-pair-sslcerts (live.ca_pair_present is not true)")
    domain = ctx.live.get("route_domain") or ""
    if m["external"]:
        if not domain:
            ctx.error("CONFLUENT_EXTERNAL_KAFKA_ENABLED=true needs live.route_domain (externalAccess.route.domain)")
        if not ctx.live_flag("external_tls_secret_present"):
            ctx.error(f"CONFLUENT_EXTERNAL_KAFKA_ENABLED=true needs secret {m['external_tls_secret']} "
                      "(live.external_tls_secret_present is not true)")
    if m["tls_source"] == "cfk" and m["external"]:
        ctx.note("TLS source cfk: CFK-generated certificates carry no route SANs, so the external listener "
                 f"uses the repo certificate in {m['external_tls_secret']} (mixed mode, plan 15.13 item 7)")
    if not m["license_present"]:
        ctx.warn(f"{LICENSE_WARNING_PREFIX} - Confluent Platform runs on the 30-day trial license.")

    component_res = _resources(ctx, "CONFLUENT_COMPONENT")
    comp_tls = _component_tls(m)
    kafka_dep = _kafka_dependency(m)
    items = []

    # ---- KRaftController ---------------------------------------------------
    kraft_replicas_raw = ctx.preset("CONFLUENT_KRAFT_REPLICAS")
    try:
        kraft_replicas = int(kraft_replicas_raw)
    except ValueError:
        kraft_replicas = None
    if kraft_replicas is None or kraft_replicas < 1 or kraft_replicas % 2 == 0:
        ctx.error(f"CONFLUENT_KRAFT_REPLICAS='{kraft_replicas_raw}' must be an odd integer >= 1")
    elif kraft_replicas == 1:
        ctx.warn("CONFLUENT_KRAFT_REPLICAS=1 - no KRaft controller redundancy (demo only)")
    kraft_storage = ctx.preset("CONFLUENT_KRAFT_STORAGE_SIZE")
    if not KRAFT_STORAGE_RE.match(kraft_storage):
        ctx.error(f"CONFLUENT_KRAFT_STORAGE_SIZE='{kraft_storage}' must match <n>Mi|Gi|Ti")
    metrics = {"metricsClient": {"url": m["urls"]["prometheus"]}} if on["c3"] else {}
    items.append(_item(10, 1, "KRaftController", "kraftcontroller.yaml.j2", "phase", m, {
        "name": CR_NAMES["KRaftController"], "replicas": kraft_replicas or 0,
        "image": _image_block(ctx, m, "KRaftController", images["server"], images["init"]),
        "storage": kraft_storage, "resources": _resources(ctx, "CONFLUENT_KRAFT", preset=True),
        "tls": None, "dependencies": metrics}))

    # ---- Kafka -------------------------------------------------------------
    broker_storage = ctx.get("CONFLUENT_BROKER_STORAGE_SIZE", "")
    if not broker_storage:
        ctx.error("Kafka dataVolumeCapacity is empty (CONFLUENT_BROKER_STORAGE_SIZE)")
    listeners = {}
    if m["sasl"]:
        server_auth = {"type": "plain", "jaasConfig": {"secretRef": SASL_SERVER_SECRET}}
        for name in ("internal", "replication"):
            listeners[name] = {"authentication": server_auth}
            if m["tls_internal"]:
                listeners[name]["tls"] = {"enabled": True}
        external = {"authentication": server_auth}
        if m["external"]:
            ns_prefix = ctx.get("CONFLUENT_EXTERNAL_KAFKA_BOOTSTRAP_PREFIX", f"kafka-{ns}")
            broker_prefix = ctx.get("CONFLUENT_EXTERNAL_KAFKA_BROKER_PREFIX", f"kafka-{ns}-b")
            # K8S-EXTENSION(K5): Kubernetes mode would use loadBalancer/nodePort/staticFor*Routing here.
            external["external_access"] = {
                "domain": domain, "bootstrapPrefix": ns_prefix, "brokerPrefix": broker_prefix,
                "labels": {"app.kubernetes.io/part-of": "confluent", "confluent.ibm-scripts/installed-by": m["owner"]}}
            external["tls"] = {"enabled": True, "secretRef": m["external_tls_secret"]}
        listeners["external"] = external
    kafka_tls = None
    if m["tls_internal"] and m["tls_source"] == "repo":
        kafka_tls = {"secretRef": m["internal_tls_secret"]}
    elif m["cfk_tls"]:
        kafka_tls = {"autoGeneratedCerts": True}

    overrides = []
    if rf is not None and min_isr is not None and partitions is not None:
        overrides = [
            f"default.replication.factor={rf}", f"min.insync.replicas={min_isr}", f"num.partitions={partitions}",
            f"offsets.topic.replication.factor={rf}", f"transaction.state.log.replication.factor={rf}",
            f"transaction.state.log.min.isr={min_isr}", "transaction.max.timeout.ms=3600000",
            "group.initial.rebalance.delay.ms=0", f"confluent.license.topic.replication.factor={rf}",
            f"confluent.balancer.topic.replication.factor={rf}", f"confluent.metadata.topic.replication.factor={rf}",
            "confluent.consumer.lag.emitter.enabled=true",
        ]
        if on["sr"]:
            overrides.append(f"confluent.schema.registry.url={m['urls']['sr']}")
        if ctx.flag("CONFLUENT_AUTO_CREATE_TOPICS", True):
            overrides.append("auto.create.topics.enable=true")
        overrides += _scram_overrides(m)

    authorization, services, kafka_rest_dep = None, None, None
    if m["mds"]:
        admin = ctx.get("CONFLUENT_SASL_ADMIN_USER", "confluent-admin")
        super_user = _mds_super_user(ctx)
        authorization = {"type": "rbac", "superUsers": [f"User:{admin}", f"User:{super_user}"]}
        services = {"mds": {"tokenKeyPair": {"secretRef": MDS_TOKEN_SECRET}, "provider": _mds_provider(ctx, m)}}
        # CFK 3.4 refuses an RBAC Kafka without it: "ApplyFailed: .spec.dependencies.kafkaRest.authentication must be
        # configured" (seen in a live install test). Kafka's embedded REST client authenticates to MDS with a
        # bearer secret (bearer.txt = username/password), as in Confluent's production-secure-deploy example
        # (confluent-kubernetes-examples, security/production-secure-deploy). The same secret the KafkaRestClass uses.
        kafka_rest_dep = {"authentication": {"type": "bearer", "bearer": {"secretRef": MDS_CLIENT_SECRET}}}
    items.append(_item(20, 1, "Kafka", "kafka.yaml.j2", "phase", m, {
        "name": CR_NAMES["Kafka"], "replicas": replicas or 0,
        "image": _image_block(ctx, m, "Kafka", images["server"], images["init"]),
        "storage": broker_storage, "resources": _resources(ctx, "CONFLUENT_BROKER"), "tls": kafka_tls,
        "listeners": listeners, "authorization": authorization, "services": services, "kafka_rest_dep": kafka_rest_dep,
        "metrics_url": m["urls"]["prometheus"] if on["c3"] else None, "server_overrides": overrides}))

    disabled = []
    # ---- MDS: KafkaRestClass (stage 2) -------------------------------------
    if m["mds"]:
        items.append(_item(30, 2, "KafkaRestClass", "kafkarestclass.yaml.j2", "none", m, {
            "name": CR_NAMES["KafkaRestClass"],
            "authentication": {"type": "bearer", "bearer": {"secretRef": MDS_CLIENT_SECRET}}}))
    else:
        disabled.append(("KafkaRestClass", CR_NAMES["KafkaRestClass"]))

    def component(order, kind, key, template, extra):
        if not on[key]:
            disabled.append((kind, CR_NAMES[kind]))
            return
        c = {"name": CR_NAMES[kind], "resources": component_res, "tls": comp_tls, "kafka": kafka_dep}
        c.update(extra)
        stage = 4 if kind == "ControlCenter" else 3
        items.append(_item(order, stage, kind, template, "phase", m, c))

    sr_dep = {"url": m["urls"]["sr"]} if on["sr"] else None
    component(40, "SchemaRegistry", "sr", "schemaregistry.yaml.j2", {
        "image": _image_block(ctx, m, "SchemaRegistry", images["sr"], images["init"]) if on["sr"] else None,
        "server_overrides": [f"kafkastore.topic.replication.factor={rf}"]})
    if on["connect"]:
        component(50, "Connect", "connect", "connect.yaml.j2", _connect_extra(ctx, m, images, component_res, rf, sr_dep))
    else:
        disabled.append(("Connect", CR_NAMES["Connect"]))
    if on["ksqldb"]:
        ksql_storage = ctx.preset("CONFLUENT_KSQLDB_STORAGE_SIZE")
        component(60, "KsqlDB", "ksqldb", "ksqldb.yaml.j2", {
            "image": _image_block(ctx, m, "KsqlDB", images["ksqldb"], images["init"]),
            "storage": ksql_storage, "sr": sr_dep,
            # ksqldbs.spec.dependencies.connect {url, tls, authentication} exists in the CFK 3.4.0 CRD (chart
            # 0.2038.1, checked offline 2026-11-18); parity with scripts mode's KSQL_KSQL_CONNECT_URL (1.1:1463).
            "connect": {"url": m["urls"]["connect"]} if on["connect"] else None,
            "server_overrides": ["ksql.cache.max.bytes.buffering=0"]})
    else:
        disabled.append(("KsqlDB", CR_NAMES["KsqlDB"]))
    component(70, "KafkaRestProxy", "krp", "kafkarestproxy.yaml.j2", {
        "image": _image_block(ctx, m, "KafkaRestProxy", images["krp"], images["init"]) if on["krp"] else None,
        "sr": sr_dep})
    if on["c3"]:
        c3_storage = ctx.preset("CONFLUENT_C3_STORAGE_SIZE")
        prom_storage = ctx.preset("CONFLUENT_PROMETHEUS_STORAGE_SIZE")
        for what, value in (("Prometheus", images["prometheus"]), ("Alertmanager", images["alertmanager"])):
            if not value:
                ctx.error(f"ControlCenter {what} image is empty")
        deps = {"kafka": kafka_dep}
        if on["sr"]:
            deps["schemaRegistry"] = {"url": m["urls"]["sr"]}
        if on["connect"]:
            deps["connect"] = [{"name": "connect", "url": m["urls"]["connect"]}]
        if on["ksqldb"]:
            deps["ksqldb"] = [{"name": "ksqldb", "url": m["urls"]["ksqldb"]}]
        deps["prometheusClient"] = {"url": m["urls"]["prometheus"]}
        deps["alertManagerClient"] = {"url": m["urls"]["alertmanager"]}
        component(80, "ControlCenter", "c3", "controlcenter.yaml.j2", {
            "image": _image_block(ctx, m, "ControlCenter", images["c3"], images["init"]),
            "storage": c3_storage, "prometheus_image": images["prometheus"], "prometheus_storage": prom_storage,
            "alertmanager_image": images["alertmanager"], "dependencies": deps})
    else:
        disabled.append(("ControlCenter", CR_NAMES["ControlCenter"]))

    # ---- MDS: ConfluentRolebinding (stage 5) -------------------------------
    if m["mds"]:
        items.append(_item(90, 5, "ConfluentRolebinding", "confluentrolebinding.yaml.j2", "state", m, {
            "name": CR_NAMES["ConfluentRolebinding"], "principal": _mds_super_user(ctx)}))
    else:
        disabled.append(("ConfluentRolebinding", CR_NAMES["ConfluentRolebinding"]))
    for c in items:
        if c["kind"] in ("KsqlDB", "ControlCenter") and not c["ctx"]["c"].get("storage"):
            ctx.error(f"{c['kind']} dataVolumeCapacity is empty")
    return m, items, disabled


def _connect_extra(ctx, m, images, component_res, rf, sr_dep):
    state = _connect_state(ctx)
    res = json.loads(json.dumps(component_res))
    raised = False
    requests, limits = res.setdefault("requests", {}), res.setdefault("limits", {})
    req = _cpu_cores(requests.get("cpu", "0"))
    if req is None or req < 1:
        requests["cpu"], raised = "1", True
    lim = _cpu_cores(limits.get("cpu", "0"))
    if lim is None or lim < 2:
        limits["cpu"], raised = "2", True
    if raised:
        ctx.note("Connect CPU raised to the operator-mode minimum (1 request / 2 limit)")
    deps = {"kafka": _kafka_dependency(m)}
    for client in ("producer", "consumer", "admin"):
        deps[client] = _kafka_dependency(m)
    if sr_dep:
        deps["schemaRegistry"] = dict(sr_dep)
    build = None
    if state["hub"] or state["url"]:
        plugins = {}
        if state["hub"]:
            plugins["confluentHub"] = state["hub"]
        if state["url"]:
            plugins["url"] = state["url"]
        build = {"type": "onDemand", "onDemand": {"plugins": plugins}}
    mounted_volumes = None
    overrides = []
    if state["local"]:
        mounted_volumes = {
            "volumes": [{"name": "local-plugins", "persistentVolumeClaim": {"claimName": state["local_pvc"]}}],
            "volumeMounts": [{"name": "local-plugins", "mountPath": LOCAL_PLUGINS_MOUNT}]}
        overrides.append(f"plugin.path={CONNECT_PLUGIN_PATH}")
    if state["mounted_secrets"]:
        overrides += ["config.providers=file",
                      "config.providers.file.class=org.apache.kafka.common.config.provider.FileConfigProvider"]
    return {"image": _image_block(ctx, m, "Connect", images["connect"], images["init"]),
            "resources": res, "rf": rf if rf is not None else 0, "build": build,
            "mounted_volumes": mounted_volumes,
            "mounted_secrets": [{"secretRef": s} for s in state["mounted_secrets"]],
            "dependencies": deps, "server_overrides": overrides}


def _mds_super_user(ctx):
    name = ctx.args.get("super_user") or ctx.get("CONFLUENT_MDS_SUPER_USER", "mds-admin")
    return str(name)


def _mds_provider(ctx, m):
    """Kafka spec.services.mds.provider per matrix I16 (phase 5, unverified V5/V21)."""
    store = ctx.get("CONFLUENT_MDS_USER_STORE", "LDAP").strip().upper()
    if store == "OAUTH":
        jwks, issuer = ctx.get("CONFLUENT_MDS_OAUTH_JWKS_URL"), ctx.get("CONFLUENT_MDS_OAUTH_ISSUER")
        if not jwks or not issuer:
            ctx.error("MDS user store OAUTH needs CONFLUENT_MDS_OAUTH_JWKS_URL and CONFLUENT_MDS_OAUTH_ISSUER "
                      "(the caller resolves the Keycloak route into them)")
        return {"oauth": {"configurations": {
            "jwksEndpointUri": jwks or "", "expectedIssuer": issuer or "",
            "audience": ctx.get("CONFLUENT_MDS_OAUTH_AUDIENCE", "Confluent"),
            "subClaimName": ctx.get("CONFLUENT_MDS_OAUTH_SUB_CLAIM", "preferred_username"),
            "groupsClaimName": ctx.get("CONFLUENT_MDS_OAUTH_GROUPS_CLAIM", "groups")}}}
    domain = ctx.get("CONFLUENT_LDAP_DOMAIN", "confluent.io")
    base_dn = "dc=" + domain.replace(".", ",dc=")
    port = ctx.get("CONFLUENT_LDAP_PORT", "1389")
    return {"ldap": {
        "address": f"ldap://openldap.{m['ns']}.svc.cluster.local:{port}",
        "authentication": {"type": "simple", "simple": {"secretRef": MDS_LDAP_SECRET}},
        "configurations": {
            "userSearchBase": f"ou=users,{base_dn}", "userNameAttribute": "cn", "userObjectClass": "inetOrgPerson",
            "groupSearchBase": f"ou=groups,{base_dn}", "groupNameAttribute": "cn",
            "groupObjectClass": "groupOfNames", "groupMemberAttribute": "member",
            # CFK writes ldap.group.member.attribute.pattern even when unset and then refuses the empty value
            # ("failed config validation: missing value for key ldap.group.member.attribute.pattern", seen in a
            # live install test). The bundled OpenLDAP lists members as cn=<user>,ou=users,<base dn>.
            "groupMemberAttributePattern": f"cn=(.*),ou=users,{base_dn}"}}}


def _item(order, stage, kind, template, wait, m, c, apply=True, name=None, path=None):
    return {"order": order, "stage": stage, "kind": kind, "template": template, "wait": wait,
            "ctx": {"m": m, "c": c}, "apply": apply, "name": name or c.get("name"), "path": path}


# ---- repo set ----------------------------------------------------------------
ROUTES = (  # name, toggle key (None = always with its gate), order
    ("connect", "connect", 30), ("control-center", "c3", 31), ("ksqldb-server", "ksqldb", 32),
    ("mds", "mds", 33), ("rest-proxy", "krp", 34), ("schema-registry", "sr", 35),
)


def _front_proxy_mode(ctx, m):
    mode = ctx.args.get("front_proxy_mode")
    if mode is None:
        if not ctx.flag("CONFLUENT_AUTH_ENABLED", True):
            mode = "none"
        else:
            # Same split as the scripts-mode gateway (1.1_confluent_install.sh:1911/1970).
            mode = "openshift" if ctx.get("CONFLUENT_AUTH_MODE", "openshift").strip().lower() == "openshift" else "basic"
    if mode not in ("basic", "openshift", "none"):
        ctx.error(f"args.front_proxy_mode='{mode}' is not basic|openshift|none")
        mode = "none"
    if mode != "none" and not m["on"]["c3"]:
        ctx.note("Control Center is disabled - no front proxy")
        mode = "none"
    return mode


def _repo_items(ctx):
    m = _common(ctx)
    ns, on = m["ns"], m["on"]
    items, disabled = [], []
    mode = _front_proxy_mode(ctx, m)
    gw_port = ctx.integer("CONFLUENT_C3_GATEWAY_PORT", default=8443, minimum=1)
    auth_secret = ctx.get("CONFLUENT_AUTH_SECRET", "confluent-auth")

    create_routes = ctx.flag("CONFLUENT_CREATE_ROUTES", True)
    if ctx.flag("CONFLUENT_OPERATOR_NETWORK_POLICIES", True):
        ingress = [{"ports": [{"protocol": "TCP", "port": PORTS["kafka_internal"]}]},
                   {"from": [{"podSelector": {}}],
                    "ports": [{"protocol": "TCP", "port": p} for p in KAFKA_NP_SAME_NS_PORTS]}]
        router_ports = []
        if m["external"]:
            router_ports.append(9092)
        if m["mds"] and create_routes:
            # CONTRACT-DEVIATION (approved 2026-11-18 wave 1.5, contract 4.5): the Route `mds` targets kafka:http-external (8090) through the router,
            # but its NetworkPolicy admits 8090 from this namespace only, so the route would always time out.
            # 8090 is opened to the router only with MDS on, when MDS authenticates it (plan 15.13 item 4).
            router_ports.append(MDS_PORT)
        if router_ports:
            ingress.append({"from": json.loads(json.dumps(INGRESS_NAMESPACE_SELECTORS)),
                            "ports": [{"protocol": "TCP", "port": p} for p in router_ports]})
        items.append(_item(10, 1, "NetworkPolicy", "repo/networkpolicy-kafka.yaml.j2", "none", m, {
            "name": "cfk-kafka-listeners", "ingress": ingress}))
    else:
        disabled.append(("NetworkPolicy", "cfk-kafka-listeners"))

    if on["c3"] and ctx.flag("CONFLUENT_MONITORING_NETWORK_POLICY", True):
        ui_from = ([{"podSelector": {"matchLabels": {"app": FRONT_PROXY}}}] if mode != "none"
                   else json.loads(json.dumps(INGRESS_NAMESPACE_SELECTORS)))
        ingress = [{"from": [{"podSelector": {"matchLabels": {"confluent-platform": "true"}}}],
                    "ports": [{"protocol": "TCP", "port": PORTS["prometheus"]},
                              {"protocol": "TCP", "port": PORTS["alertmanager"]}]},
                   {"from": ui_from, "ports": [{"protocol": "TCP", "port": PORTS["c3"]}]}]
        items.append(_item(11, 1, "NetworkPolicy", "repo/networkpolicy-monitoring.yaml.j2", "none", m, {
            "name": "cfk-monitoring-internal", "ingress": ingress}))
    else:
        disabled.append(("NetworkPolicy", "cfk-monitoring-internal"))

    proxy_labels = dict(m["labels"], app=FRONT_PROXY)
    proxy = {"name": FRONT_PROXY, "labels": proxy_labels, "port": gw_port or 8443,
             "service_account": SERVICE_ACCOUNT, "upstream": m["urls"]["c3"], "auth_secret": auth_secret}
    secret_digest = str(ctx.args.get("front_proxy_secret_digest") or "")
    if mode == "basic":
        items.append(_item(20, 1, "File", "repo/front-proxy-nginx.conf.j2", "none", m,
                           {"name": f"{FRONT_PROXY}-nginx.conf", "gateway_port": proxy["port"],
                            "upstream": m["urls"]["c3"]},
                           apply=False, path=f"{FRONT_PROXY}-nginx.conf"))
        proxy["image"] = ctx.get("CONFLUENT_C3_GATEWAY_IMAGE") or str(
            catalog_value("confluent/c3_gateway_image", default="registry.access.redhat.com/ubi9/nginx-124:latest"))
        items.append(_item(21, 1, "Deployment", "repo/front-proxy-nginx.yaml.j2", "rollout", m,
                           dict(proxy, checksum_files=[f"{FRONT_PROXY}-nginx.conf"], checksum_extra=secret_digest)))
    elif mode == "openshift":
        proxy["image"] = ctx.get("CONFLUENT_C3_OAUTH_PROXY_IMAGE",
                                 "image-registry.openshift-image-registry.svc:5000/openshift/oauth-proxy:v4.4")
        proxy["sar"] = json.dumps({"namespace": ns, "resource": "services", "verb": "get"}, separators=(",", ":"))
        items.append(_item(21, 1, "Deployment", "repo/front-proxy-oauth.yaml.j2", "rollout", m,
                           dict(proxy, checksum_files=[], checksum_extra=secret_digest)))
    if mode != "none":
        items.append(_item(22, 1, "Service", "repo/front-proxy-service.yaml.j2", "none", m, proxy))
    else:
        disabled += [("Deployment", FRONT_PROXY), ("Service", FRONT_PROXY)]

    route_domain = ctx.get("CONFLUENT_ROUTE_DOMAIN")
    on_with_mds = dict(on, mds=m["mds"])
    for name, key, order in ROUTES:
        if not (create_routes and on_with_mds[key]):
            disabled.append(("Route", name))
            continue
        if name == "control-center" and mode != "none":
            service, port = FRONT_PROXY, "http"
        elif name == "mds":
            service, port = "kafka", "http-external"
        else:
            service, port = name, "external"
        items.append(_item(order, 1, "Route", "repo/route.yaml.j2", "none", m, {
            "name": name, "host": f"{name}-{ns}.{route_domain}" if route_domain else None,
            "service": service, "port": port}))
    return m, items, disabled


# ---- topic / connector / connect-plugins -------------------------------------
def _stringify_configs(ctx, what, configs):
    if configs is None:
        return {}
    if not isinstance(configs, dict):
        ctx.error(f"{what} must be an object")
        return {}
    out = {}
    for key, value in configs.items():
        if isinstance(value, bool):
            value = "true" if value else "false"
        out[str(key)] = str(value)
    return out


def _topic_items(ctx):
    m = _common(ctx)
    a = ctx.args
    name = a.get("name")
    if not name:
        ctx.error("topic set needs args.name")
    else:
        _dns_name(ctx, "topic name", name)

    def number(key, var):
        raw = a.get(key)
        if raw is None:
            return ctx.integer(var, minimum=1)
        try:
            value = int(raw)
        except (TypeError, ValueError):
            ctx.error(f"args.{key}='{raw}' is not an integer")
            return None
        if value < 1:
            ctx.error(f"args.{key}={value} must be >= 1")
        return value

    c = {"name": name or "", "partitions": number("partitions", "CONFLUENT_PARTITIONS") or 0,
         "replicas": number("replicas", "CONFLUENT_REPLICATION_FACTOR") or 0,
         "configs": _stringify_configs(ctx, "args.configs", a.get("configs"))}
    return m, [_item(10, 1, "KafkaTopic", "kafkatopic.yaml.j2", "state", m, c)], []


def _connector_items(ctx):
    m = _common(ctx)
    a = ctx.args
    name, klass = a.get("name"), a.get("class")
    if not name:
        ctx.error("connector set needs args.name")
    else:
        _dns_name(ctx, "connector name", name)
    if not klass:
        ctx.error("connector set needs args.class")
    try:
        tasks = int(a.get("tasks_max", 1))
    except (TypeError, ValueError):
        ctx.error(f"args.tasks_max='{a.get('tasks_max')}' is not an integer")
        tasks = 1
    configs = _stringify_configs(ctx, "args.configs", a.get("configs"))
    mounted = set(_connect_state(ctx)["mounted_secrets"])
    for ref in a.get("secret_refs") or []:
        secret, key, prop = ref.get("secret"), ref.get("key"), ref.get("property")
        if not secret or not key or not prop:
            ctx.error(f"args.secret_refs entry needs secret, key and property: {json.dumps(ref)}")
            continue
        if secret not in mounted:
            ctx.warn(f"secret {secret} is not in connect_state.mounted_secrets - Connect cannot read it until x.3/x.6 "
                     "mounts it")
        configs[str(prop)] = f"${{file:/mnt/secrets/{secret}/{key}:{prop}}}"
    c = {"name": name or "", "class": klass or "", "tasks_max": tasks, "configs": configs}
    return m, [_item(10, 1, "Connector", "connector.yaml.j2", "state", m, c)], []


def _connect_plugins_items(ctx):
    m = _common(ctx)
    pvc = ctx.get("CONFLUENT_CONNECT_PLUGINS_PVC", "connect-plugins")
    _dns_name(ctx, "CONFLUENT_CONNECT_PLUGINS_PVC", pvc)
    file_class = ctx.get("STG_CLASS_FILE")
    if file_class:
        access, storage_class = "ReadWriteMany", file_class
    else:
        access, storage_class = "ReadWriteOnce", ctx.get("CONFLUENT_STORAGE_CLASS") or ctx.get("STG_CLASS_BLOCK")
        if not storage_class:
            ctx.error("storage class is empty (STG_CLASS_FILE / CONFLUENT_STORAGE_CLASS / STG_CLASS_BLOCK)")
        ctx.note("STG_CLASS_FILE unset - the connect-plugins PVC is ReadWriteOnce (Connect replicas = 1)")
    job = ctx.args.get("job_name", "connect-plugins-loader")
    _dns_name(ctx, "args.job_name", job)
    items = [
        _item(10, 1, "PersistentVolumeClaim", "repo/connect-plugins-pvc.yaml.j2", "none", m, {
            "name": pvc, "access_mode": access, "storage_class": storage_class or "",
            "size": ctx.get("CONFLUENT_CONNECT_PLUGINS_PVC_SIZE", "5Gi")}),
        _item(20, 1, "Pod", "repo/connect-plugins-loader.yaml.j2", "none", m, {
            "name": job, "labels": dict(m["labels"], app=job), "pvc": pvc, "mount": LOCAL_PLUGINS_MOUNT,
            "image": ctx.get("CONFLUENT_CONNECT_PLUGINS_LOADER_IMAGE",
                             "registry.access.redhat.com/ubi9/ubi:latest")}),
    ]
    return m, items, []


# ------------------------------------------------------------------------------
# Flink-family model (flink, flink-app)
# ------------------------------------------------------------------------------
def _flink_common(ctx):
    owner = ctx.doc["owner_id"]
    ns = ctx.get("FLINK_CFK_NAMESPACE") or ctx.doc["flink_namespace"]
    flink_project = ctx.get("PROJECT_CONFLUENT_FLINK")
    env = ctx.get("FLINK_ENVIRONMENT")
    if not flink_project:
        ctx.error("flink sets need PROJECT_CONFLUENT_FLINK")
    if not env:
        ctx.error("flink sets need FLINK_ENVIRONMENT")
    else:
        _dns_name(ctx, "FLINK_ENVIRONMENT", env)
    restclass = ctx.get("FLINK_CMF_RESTCLASS_NAME", "default")
    _dns_name(ctx, "FLINK_CMF_RESTCLASS_NAME", restclass)
    return {"ns": ns, "owner": owner, "labels": _labels(owner), "flink_project": flink_project or "",
            "environment": env or "", "restclass": restclass}


def _contains_key(node, key):
    if isinstance(node, dict):
        return key in node or any(_contains_key(v, key) for v in node.values())
    if isinstance(node, list):
        return any(_contains_key(v, key) for v in node)
    return False


def _flink_items(ctx):
    m = _flink_common(ctx)
    service = ctx.get("FLINK_CMF_SERVICE", "cmf-service")
    port = ctx.get("FLINK_CMF_PORT", "80")
    defaults = ctx.live.get("flink_defaults") or {}
    if not isinstance(defaults, dict):
        ctx.error("live.flink_defaults must be an object")
        defaults = {}
    # CONTRACT-NOTE: a top-level 'metadata' is refused as well - that is exactly what CMF rejected (V8).
    if "metadata" in defaults or _contains_key(defaults.get("spec") or {}, "metadata"):
        ctx.error("CMF rejects metadata.labels in flinkApplicationDefaults")
    secrets = ctx.live.get("flink_env_secrets") or {}
    if not isinstance(secrets, dict):
        ctx.error("live.flink_env_secrets must be an object")
        secrets = {}
    items = [
        _item(10, 1, "CMFRestClass", "cmfrestclass.yaml.j2", "none", m, {
            "name": m["restclass"],
            "endpoint": f"http://{service}.{m['flink_project']}.svc.cluster.local:{port}"}),
        _item(20, 1, "FlinkEnvironment", "flinkenvironment.yaml.j2", "cmfSync", m, {
            "name": m["environment"], "defaults": defaults, "secrets": {str(k): str(v) for k, v in secrets.items()}}),
    ]
    return m, items, []


def _flink_version(ctx):
    value = ctx.get("FLINK_APPLICATION_VERSION")
    if value is None:
        value = "v2_0"
        ctx.note(f"FLINK_APPLICATION_VERSION unset - using {value}")
    cap = str(catalog_value("confluent/operator/flink_version_max", default="v2_2"))
    got, top = FLINK_VERSION_RE.match(value), FLINK_VERSION_RE.match(cap)
    if not got:
        ctx.error(f"FLINK_APPLICATION_VERSION='{value}' is not v<major>_<minor>")
    elif top and (int(got[1]), int(got[2])) > (int(top[1]), int(top[2])):
        ctx.error(f"FLINK_APPLICATION_VERSION={value} is above {cap}, the highest flinkVersion the "
                  "FlinkApplication CRD accepts (CFK 3.4, V9)")
    return value


def _flink_app_items(ctx):
    m = _flink_common(ctx)
    a = ctx.args
    name = a.get("name")
    if not name:
        ctx.error("flink-app set needs args.name")
    else:
        _dns_name(ctx, "flink application name", name)
    image = ctx.get("FLINK_APPLICATION_IMAGE")
    if image is None:
        image = str(catalog_value("flink/application_image", default=""))
        if not image:
            ctx.error("FLINK_APPLICATION_IMAGE is empty")
        else:
            ctx.note(f"FLINK_APPLICATION_IMAGE unset - using {image}")
    try:
        parallelism = int(a.get("parallelism", 1))
    except (TypeError, ValueError):
        ctx.error(f"args.parallelism='{a.get('parallelism')}' is not an integer")
        parallelism = 1

    def resource(prefix, cpu_default, mem_default):
        # cpu must be a string (or an integer): the CRD refuses 0.5 as a number (V9).
        return {"cpu": str(ctx.get(f"FLINK_{prefix}_CPU", cpu_default)),
                "memory": str(ctx.get(f"FLINK_{prefix}_MEMORY", mem_default))}

    c = {"name": name or "", "environment": m["environment"], "restclass": m["restclass"], "image": image,
         "flink_version": _flink_version(ctx), "slots": str(ctx.get("FLINK_TASK_SLOTS", "1")),
         "jobmanager": resource("JOBMANAGER", "0.5", "1024m"), "taskmanager": resource("TASKMANAGER", "0.5", "1024m"),
         "job": {"jarURI": str(a.get("jar_uri") or FLINK_DEFAULT_JAR), "parallelism": parallelism,
                 "upgradeMode": str(a.get("upgrade_mode") or "stateless"), "state": str(a.get("state") or "running")}}
    return m, [_item(10, 1, "FlinkApplication", "flinkapplication.yaml.j2", "jobStatus", m, c)], []


BUILDERS = {"platform": _platform_items, "repo": _repo_items, "topic": _topic_items, "connector": _connector_items,
            "connect-plugins": _connect_plugins_items, "flink": _flink_items, "flink-app": _flink_app_items}


# ------------------------------------------------------------------------------
# Document checks, rendering, output
# ------------------------------------------------------------------------------
def _check_doc(doc, set_name):
    errors = []
    if not isinstance(doc, dict):
        return ["input must be a JSON object"]
    if doc.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"schema_version must be {SCHEMA_VERSION} (got {doc.get('schema_version')!r})")
    if set_name is not None and set_name not in SETS:
        errors.append(f"unknown set '{set_name}' (sets: {', '.join(SETS)})")
    required = ["owner_id"]
    if set_name in PLATFORM_FAMILY:
        required.append("namespace")
    if set_name in FLINK_FAMILY:
        required.append("flink_namespace")
    for key in required:
        if not isinstance(doc.get(key), str) or not doc.get(key):
            errors.append(f"required key '{key}' is missing")
    owner = doc.get("owner_id")
    if isinstance(owner, str) and owner and not LABEL_VALUE_RE.match(owner):
        errors.append(f"owner_id '{owner}' is not a valid label value")
    for key in ("vars", "live"):
        if key in doc and not isinstance(doc[key], dict):
            errors.append(f"'{key}' must be an object")
    live = doc.get("live") if isinstance(doc.get("live"), dict) else {}
    for key in ("related_images", "connect_state", "flink_defaults", "flink_env_secrets"):
        # cfo_live_json fills these from cluster JSON; a wrong shape must be an [ERROR], not a traceback.
        if live.get(key) is not None and not isinstance(live[key], dict):
            errors.append(f"live.{key} must be an object")
    for name, value in (doc.get("vars") or {}).items() if isinstance(doc.get("vars"), dict) else ():
        if SECRET_VAR_RE.search(name) or name == "OCP_PASSWORD":
            errors.append(f"secret values must never reach the renderer: {name}")
        elif name not in ALLOWED_INPUT_VARS:
            errors.append(f"unknown input var {name}")
        elif not isinstance(value, str):
            errors.append(f"vars.{name} must be a string")
    return errors


def _environment():
    env = jinja2.Environment(loader=jinja2.FileSystemLoader(TEMPLATE_DIR), undefined=jinja2.StrictUndefined,
                             trim_blocks=True, lstrip_blocks=True, keep_trailing_newline=True, autoescape=False)
    env.filters["q"] = lambda v: json.dumps(str(v))
    env.filters["j"] = lambda v: json.dumps(v, ensure_ascii=False)
    return env


def _dump(obj):
    return yaml.safe_dump(obj, sort_keys=False, default_flow_style=False, width=4096)


def _build(doc, set_name, args):
    errors = _check_doc(doc, set_name)
    if set_name is None:
        raise RenderError(errors or ["no set given"])
    if errors:
        raise RenderError(errors)
    ctx = Ctx(doc, args)
    m, items, disabled = BUILDERS[set_name](ctx)
    if ctx.errors:
        raise RenderError(ctx.errors)
    env = _environment()
    files = []
    texts = {}  # item name -> rendered text, for the checksum of a later item
    for it in sorted(items, key=lambda i: i["order"]):
        c = it["ctx"]["c"]
        if "checksum_files" in c:
            h = hashlib.sha256()
            for name in c["checksum_files"]:
                h.update(texts.get(name, "").encode("utf-8") + b"\0")
            h.update(str(c.get("checksum_extra") or "").encode("utf-8"))
            it["ctx"]["c"] = dict(c, checksum=h.hexdigest(), checksum_annotation=FRONT_PROXY_CHECKSUM_ANNOTATION)
        text = env.get_template(it["template"]).render(**it["ctx"])
        texts[it["name"]] = text
        if it["apply"]:
            try:
                docs = [d for d in yaml.safe_load_all(text) if d is not None]
            except yaml.YAMLError as exc:
                raise RenderError([f"template {it['template']} produced invalid YAML: {exc}"]) from None
            if len(docs) != 1 or not isinstance(docs[0], dict):
                raise RenderError([f"template {it['template']} must render a single YAML mapping"])
            obj = docs[0]
            meta = obj.get("metadata") or {}
            entry = {"order": it["order"], "stage": it["stage"],
                     "path": f"{set_name}/{it['order']:02d}-{str(obj.get('kind', '')).lower()}-{meta.get('name')}.yaml",
                     "apiVersion": obj.get("apiVersion"), "kind": obj.get("kind"), "name": meta.get("name"),
                     "namespace": meta.get("namespace"), "wait": it["wait"], "apply": True}
            text = _dump(obj)
        else:
            text = text if text.endswith("\n") else text + "\n"
            entry = {"order": it["order"], "stage": it["stage"], "path": f"{set_name}/{it['path']}",
                     "apiVersion": None, "kind": it["kind"], "name": it["name"], "namespace": m["ns"],
                     "wait": "none", "apply": False}
        files.append((entry, text))
    manifest = {"set": set_name, "namespace": m["ns"], "files": [e for e, _ in files],
                "disabled": [{"kind": k, "name": n} for k, n in disabled],
                "info": list(ctx.info), "warnings": list(ctx.warnings)}
    return manifest, files


def _manifest_text(manifest):
    return json.dumps(manifest, indent=2) + "\n"


def render(doc, set_name, out_dir=None, args=None):
    """Render <set_name>. Writes into <out_dir>/<set_name>/ unless out_dir is None. Raises RenderError."""
    manifest, files = _build(doc, set_name, args or {})
    if out_dir is None:
        result = json.loads(json.dumps(manifest))
        for entry, (_, text) in zip(result["files"], files):
            entry["text"] = text
        return result
    target = Path(out_dir) / set_name
    target.mkdir(parents=True, exist_ok=True)
    for stale in [*target.glob("*.yaml"), *target.glob("*.conf"), target / "manifest.json"]:
        if stale.is_file():
            stale.unlink()
    for entry, text in files:
        (Path(out_dir) / entry["path"]).write_text(text, encoding="utf-8", newline="\n")
    (target / "manifest.json").write_text(_manifest_text(manifest), encoding="utf-8", newline="\n")
    return manifest


def validate(doc, set_name=None, args=None):
    """Errors for <set_name>; without a set: the document checks plus platform and repo (when it has a
    namespace) and flink (when it has a flink_namespace and FLINK_ENVIRONMENT). The sets that need --args
    (topic, connector, connect-plugins, flink-app) are only checked when named."""
    if set_name is not None:
        try:
            _build(doc, set_name, args or {})
        except RenderError as exc:
            return exc.errors
        return []
    errors = _check_doc(doc, None)
    if errors:
        return errors
    sets = []
    if doc.get("namespace"):
        sets += ["platform", "repo"]
    if doc.get("flink_namespace") and (doc.get("vars") or {}).get("FLINK_ENVIRONMENT"):
        sets.append("flink")
    for name in sets:
        try:
            _build(doc, name, args or {})
        except RenderError as exc:
            errors += [e for e in exc.errors if e not in errors]
    return errors


# ------------------------------------------------------------------------------
# input-from-env
# ------------------------------------------------------------------------------
def owner_id_from_env(environ):
    """Same rule as cfo_owner_id: ${MCM_CLUSTER:-local}.${PROJECT_CONFLUENT_SERVER}, label-safe, <= 63 chars."""
    raw = f"{environ.get('MCM_CLUSTER') or 'local'}.{environ.get('PROJECT_CONFLUENT_SERVER', '')}"
    value = re.sub(r"[^A-Za-z0-9._-]", "-", raw)[:63]
    return re.sub(r"[^A-Za-z0-9]+$", "", re.sub(r"^[^A-Za-z0-9]+", "", value))


def input_from_env(environ, live):
    vars_ = {k: environ[k] for k in sorted(ALLOWED_INPUT_VARS) if k in environ}
    doc = {"schema_version": SCHEMA_VERSION,
           "namespace": environ.get("PROJECT_CONFLUENT_SERVER", ""),
           "flink_namespace": environ.get("FLINK_CFK_NAMESPACE") or environ.get("PROJECT_CONFLUENT_FLINK", ""),
           "owner_id": environ.get("CFO_OWNER_ID") or owner_id_from_env(environ),
           "vars": vars_, "live": live}
    return doc


# ------------------------------------------------------------------------------
# CLI
# ------------------------------------------------------------------------------
def _read_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        raise RenderError([f"cannot read {what} {path}: {exc}"]) from None


def _read_stdin():
    try:
        return json.load(sys.stdin)
    except ValueError as exc:
        raise RenderError([f"input on stdin is not JSON: {exc}"]) from None


def _print_notes(manifest):
    for msg in manifest.get("info", []):
        print(f"[INFO] {msg}", file=sys.stderr)
    license_warned = os.environ.get("_CFO_LICENSE_WARNED") == "1"
    for msg in manifest.get("warnings", []):
        if license_warned and msg.startswith(LICENSE_WARNING_PREFIX):
            continue  # cfo_license_warning printed it once already (plan item 14)
        print(f"[WARN] {msg}", file=sys.stderr)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="confluent_cfk_render.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list-inputs")
    p_env = sub.add_parser("input-from-env")
    p_env.add_argument("--live")
    p_val = sub.add_parser("validate")
    p_val.add_argument("--set", choices=SETS)
    p_val.add_argument("--args")
    p_ren = sub.add_parser("render")
    p_ren.add_argument("--set", required=True, choices=SETS)
    p_ren.add_argument("--out-dir", required=True)
    p_ren.add_argument("--args")
    ns = ap.parse_args(argv)
    try:
        if ns.cmd == "list-inputs":
            for name in sorted(ALLOWED_INPUT_VARS):
                print(name)
            return 0
        if ns.cmd == "input-from-env":
            live = _read_json(ns.live, "live JSON") if ns.live else {}
            print(json.dumps(input_from_env(os.environ, live), indent=2))
            return 0
        args = _read_json(ns.args, "args JSON") if ns.args else {}
        doc = _read_stdin()
        if ns.cmd == "validate":
            errors = validate(doc, ns.set, args)
            for msg in errors:
                print(f"[ERROR] {msg}", file=sys.stderr)
            return 1 if errors else 0
        manifest = render(doc, ns.set, ns.out_dir, args)
        _print_notes(manifest)
        sys.stdout.write(_manifest_text(manifest))
        return 0
    except RenderError as exc:
        for msg in exc.errors:
            print(f"[ERROR] {msg}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
