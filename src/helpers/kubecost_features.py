#!/usr/bin/env python3
"""Kubecost optional features <-> configs/kubecost_config/<ns>/<cr>-features.yaml.

Used by generate_kubecost_features_config.sh and features/apply_kubecost_features.sh
(src/utilities/kubecost_utils/); they do the cluster work, this file only
converts:

  generate --ctx ctx.json   -> commented features YAML on stdout, filled from
                               the instance's effective Helm values
  plan --ctx ctx.json --file features.yaml
                            -> JSON on stdout: {"patch", "secrets", "summary",
                               "warnings", "errors"}; the patch is an RFC 7386
                               merge patch for the Kubecost CR (null = drop the
                               override, so the chart default applies)

ctx.json: {"instance", "namespace", "url", "keyLinked", "sso" (oidc|saml|""),
"ssoRbac", "ssoGroups", "nodes", "labelledNodes", "crSpec", "effective" (helm
values; {} if unknown), "secrets" ({name: {key: decoded value}} of the Secrets
the features use), "serviceCA" (PEM from the namespace's openshift-service-ca.crt
ConfigMap; "" if none)}.

Chart facts (kubecost 3.3.1, values.yaml + templates in the operator pod, and
the aggregator binary): alert-configs / budgets-configs / saved-report-configs
/ asset-report-configs / cloud-cost-report-configs ConfigMaps are read by the
aggregator; 3.x alerts support only type "health"; SMTP Secret key smtp.json;
plugin Secret keys <plugin>_config.json; federated storage Secret key
federated-store.yaml; network-costs needs topology region+zone node labels
unless its affinity is replaced; teams render only with SAML/OIDC rbac on and
no rbac groups; the bucket is read by aggregator, cloud-cost, finops-agent
(extraVolumes), cluster-controller (no extraVolumes; storageConfigSecret is
mounted as the directory /var/configs/actions/storage) and network-costs (no
extraVolumes), all via opencost storage (http_config.tls_config.ca_file /
insecure_skip_verify);
Actions on free tier needs an RSA signing key, with a product key it doesn't.
"""

import argparse
import copy
import json
import re
import sys

import yaml

MISSING = object()  # path absent in the CR
DELETE = object()  # drop the override: the chart default applies
NOCHANGE = object()

MANAGED_LABEL = "kubecost-features/managed"

# federatedStorage.trustServiceCA: the OpenShift service CA (ConfigMap
# openshift-service-ca.crt, which OpenShift creates and keeps current in every
# namespace) is mounted into the bucket readers that take extra volumes
# (aggregator, cloudCost, finopsagent), and the bucket config names it as
# http_config.tls_config.ca_file. The cluster controller has no extraVolumes in
# chart 3.3.1; it gets its own copy of the config plus the CA in the Secret
# clusterController.storageConfigSecret, which is mounted as a directory.
SERVICE_CA_CONFIGMAP = "openshift-service-ca.crt"
SERVICE_CA_KEY = "service-ca.crt"
SERVICE_CA_VOLUME = "kubecost-service-ca"
SERVICE_CA_DIR = "/var/run/kubecost-service-ca"
SERVICE_CA_FILE = f"{SERVICE_CA_DIR}/{SERVICE_CA_KEY}"
ACTIONS_STORE_DIR = "/var/configs/actions/storage"
ACTIONS_CA_FILE = f"{ACTIONS_STORE_DIR}/{SERVICE_CA_KEY}"
SERVICE_CA_COMPONENTS = ("aggregator", "cloudCost", "finopsagent")

# Chart 3.3.1 defaults for the scalar settings handled here. A setting equal to
# its default is dropped from the CR instead of written.
DEFAULT_LABEL_MAPPING = {
    "owner_label": "owner",
    "team_label": "team",
    "department_label": "dept",
    "product_label": "product",
    "environment_label": "env",
}
DEFAULTS = {
    "networkCosts.port": 3001,
    "networkCosts.trafficLogging": True,
    "aggregator.retention10m": 0,
    "aggregator.retention1h": 49,
    "aggregator.retention1d": 91,
    "kubecostProductConfigs.sharedNamespaces": "",
    "kubecostProductConfigs.sharedLabelNames": "",
    "kubecostProductConfigs.sharedLabelValues": "",
    "kubecostProductConfigs.sharedOverhead": 0,
    "kubecostProductConfigs.shareTenancyCosts": True,
    "kubecostProductConfigs.defaultIdle": False,
    "kubecostProductConfigs.clusterProfile": "production",
    "kubecostProductConfigs.labelMappingConfigs": DEFAULT_LABEL_MAPPING,
}
CHART_NC_AFFINITY = {
    "nodeAffinity": {
        "requiredDuringSchedulingIgnoredDuringExecution": {
            "nodeSelectorTerms": [
                {
                    "matchExpressions": [
                        {"key": "topology.kubernetes.io/region", "operator": "Exists"},
                        {"key": "topology.kubernetes.io/zone", "operator": "Exists"},
                    ]
                }
            ]
        }
    }
}
# Lists replace in Helm's merge, so this swaps the chart's region/zone term
# for "any Linux node".
ANY_NODE_AFFINITY = {
    "nodeAffinity": {
        "requiredDuringSchedulingIgnoredDuringExecution": {
            "nodeSelectorTerms": [
                {
                    "matchExpressions": [
                        {
                            "key": "kubernetes.io/os",
                            "operator": "In",
                            "values": ["linux"],
                        }
                    ]
                }
            ]
        }
    }
}
CONTROL_PLANE_TOLERATIONS = [
    {
        "key": "node-role.kubernetes.io/master",
        "operator": "Exists",
        "effect": "NoSchedule",
    },
    {
        "key": "node-role.kubernetes.io/control-plane",
        "operator": "Exists",
        "effect": "NoSchedule",
    },
]
CLUSTER_PROFILES = ("development", "production", "high-availability")
BUDGET_TYPES = ("allocations", "asset", "cloud", "collections")
DURATION = re.compile(r"^[0-9]+[mhd]$")


# --------------------------------------------------------------------------- helpers
def get_path(obj, path, default=MISSING):
    for part in path.split("."):
        if not isinstance(obj, dict) or part not in obj:
            return default
        obj = obj[part]
    return obj


def set_path(obj, path, value):
    parts = path.split(".")
    for part in parts[:-1]:
        obj = obj.setdefault(part, {})
    obj[parts[-1]] = value


def clean(des):
    """des without its DELETE entries (they have nothing to drop)."""
    if isinstance(des, dict):
        return {k: clean(v) for k, v in des.items() if v is not DELETE}
    return copy.deepcopy(des)


def merge_diff(cur, des):
    """Merge patch that turns cur into des (DELETE drops cur)."""
    if des is DELETE:
        return NOCHANGE if cur is MISSING else None
    if cur is MISSING or not isinstance(cur, dict) or not isinstance(des, dict):
        des = clean(des)
        return NOCHANGE if cur == des else des
    patch = {k: None for k in cur if k not in des}
    for k, v in des.items():
        d = merge_diff(cur.get(k, MISSING), v)
        if d is not NOCHANGE:
            patch[k] = d
    return patch or NOCHANGE


def y(value):
    """A value as inline YAML (JSON is valid YAML)."""
    return json.dumps(value)


def block(value, indent):
    """A list/map as block YAML under a key: ' []' / ' {}' or an indented block."""
    if not value:
        return " []" if isinstance(value, list) or value is None else " {}"
    text = yaml.safe_dump(
        value, sort_keys=False, default_flow_style=False, allow_unicode=True
    )
    pad = " " * indent
    return "\n" + "".join(
        pad + line + "\n" for line in text.rstrip("\n").split("\n")
    ).rstrip("\n")


def csv_list(value):
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    return [
        v.strip() for v in str(value or "").replace("\\,", ",").split(",") if v.strip()
    ]


# --------------------------------------------------------------------------- bucket TLS
def bucket_tls(config):
    """http_config.tls_config of an objstore config {type, config: {...}} ({} if none)."""
    tls = get_path(config, "config.http_config.tls_config", {})
    return tls if isinstance(tls, dict) else {}


def with_ca_file(config, path):
    """A copy of the objstore config that verifies the endpoint against path."""
    out = copy.deepcopy(config)
    http = out["config"].setdefault("http_config", {})
    http.setdefault("tls_config", {})["ca_file"] = path
    return out


def without_service_ca(config):
    """A copy without the ca_file trustServiceCA adds; empty maps it leaves are dropped."""
    out = copy.deepcopy(config)
    inner = out.get("config") if isinstance(out, dict) else None
    http = inner.get("http_config") if isinstance(inner, dict) else None
    tls = http.get("tls_config") if isinstance(http, dict) else None
    if not isinstance(tls, dict) or tls.get("ca_file") not in (
        SERVICE_CA_FILE,
        ACTIONS_CA_FILE,
    ):
        return out
    del tls["ca_file"]
    if not tls:
        del http["tls_config"]
    if not http:
        del inner["http_config"]
    return out


def endpoint_host(endpoint):
    """Host part of an S3 endpoint (host[:port], maybe with a scheme)."""
    host = re.sub(r"^[a-z]+://", "", str(endpoint or "").strip().lower())
    return host.split("/")[0].rsplit(":", 1)[0] if host else ""


def is_service_host(host):
    return host.endswith(".svc") or host.endswith(".svc.cluster.local")


def volumes_with(cur, item, keep):
    """cur (a CR list) without entries named item["name"], plus item if keep."""
    out = [
        v
        for v in (cur if isinstance(cur, list) else [])
        if not (isinstance(v, dict) and v.get("name") == item["name"])
    ]
    if keep:
        out.append(item)
    return out or DELETE


# --------------------------------------------------------------------------- generate
def current_settings(ctx):
    """Feature settings now in force, from the effective values (CR spec as fallback)."""
    eff = ctx.get("effective") or {}
    spec = ctx.get("crSpec") or {}
    secrets = ctx.get("secrets") or {}
    cr = ctx["instance"]

    def val(path, default=None):
        v = get_path(eff, path)
        if v is MISSING:
            v = get_path(spec, path)
        if v is MISSING:
            v = DEFAULTS.get(path, default)
        return copy.deepcopy(v)

    s = {}
    affinity = val("networkCosts.affinity", CHART_NC_AFFINITY)
    tolerations = val("networkCosts.tolerations", []) or []
    s["networkCosts"] = {
        "enabled": bool(val("networkCosts.enabled", True)),
        "scheduleOn": "labelled-nodes"
        if (affinity or {}) == CHART_NC_AFFINITY
        else "any-node",
        "includeControlPlane": any(
            t.get("key")
            in (
                "node-role.kubernetes.io/master",
                "node-role.kubernetes.io/control-plane",
            )
            for t in tolerations
            if isinstance(t, dict)
        ),
        "port": int(val("networkCosts.port") or 3001),
        "trafficLogging": bool(val("networkCosts.trafficLogging")),
    }

    alert_cfg = val("global.notifications.alertConfigs") or {}
    health = next(
        (a for a in alert_cfg.get("alerts") or [] if a.get("type") == "health"), {}
    )
    smtp_vals = val("kubecostProductConfigs.smtp") or {}
    smtp = {
        "enabled": bool(smtp_vals),
        "existingSecret": "",
        "host": "",
        "port": 587,
        "senderEmail": "",
        "authentication": True,
        "username": "",
        "password": "",
        "secure": True,
    }
    smtp_json = None
    if smtp_vals.get("secretname"):
        name = smtp_vals["secretname"]
        if name == f"{cr}-smtp" and "smtp.json" in secrets.get(name, {}):
            smtp_json = secrets[name]["smtp.json"]
        else:
            smtp["existingSecret"] = name
    elif smtp_vals.get("config"):
        smtp_json = smtp_vals["config"]
    if smtp_json:
        try:
            j = json.loads(smtp_json)
            smtp.update(
                {
                    "host": j.get("host", ""),
                    "port": j.get("port", 587),
                    "senderEmail": j.get("sender_email", ""),
                    "authentication": j.get("authentication", True),
                    "username": j.get("username", ""),
                    "password": j.get("password", ""),
                    "secure": j.get("secure", True),
                }
            )
        except ValueError:
            pass
    s["alerts"] = {
        "enabled": bool(alert_cfg),
        "frontendUrl": alert_cfg.get("frontendUrl") or ctx.get("url") or "",
        "emails": alert_cfg.get("globalAlertEmails") or [],
        "emailSubject": alert_cfg.get("globalEmailSubject") or "",
        "slackWebhookUrl": alert_cfg.get("globalSlackWebhookUrl") or "",
        "msTeamsWebhookUrl": alert_cfg.get("globalMsTeamsWebhookUrl") or "",
        "health": {
            "enabled": bool(health) or not alert_cfg,
            "window": health.get("window", "1h"),
            "extraEmails": health.get("ownerContact") or [],
            "slackWebhookUrl": health.get("slackWebhookUrl") or "",
            "msTeamsWebhookUrl": health.get("msTeamsWebhookUrl") or "",
        },
        "smtp": smtp,
    }

    budgets = val("kubecostProductConfigs.budgets.budgetsConfig") or []
    s["budgets"] = {"enabled": bool(budgets), "budgets": budgets}

    s["savedReports"] = {}
    for key, path in (
        ("allocation", "global.savedReports"),
        ("assets", "global.assetReports"),
        ("cloudCosts", "global.cloudCostReports"),
    ):
        r = val(path) or {}
        on = bool(r.get("enabled"))
        # Off: the chart's example reports are not worth copying.
        s["savedReports"][key] = {
            "enabled": on,
            "reports": (r.get("reports") or []) if on else [],
        }

    s["dataRetention"] = {
        "tenMinute": int(val("aggregator.retention10m") or 0),
        "hourly": int(val("aggregator.retention1h") or 0),
        "daily": int(val("aggregator.retention1d") or 0),
    }
    s["carbonEstimates"] = {
        "enabled": bool(val("kubecostProductConfigs.carbonEstimates", False))
    }
    s["costEventsAudit"] = {"enabled": bool(val("costEventsAudit.enabled", False))}

    profiles = val("kubecostProductConfigs.savingsProfiles") or {}
    s["costAllocation"] = {
        "sharedNamespaces": csv_list(val("kubecostProductConfigs.sharedNamespaces")),
        "sharedLabelNames": csv_list(val("kubecostProductConfigs.sharedLabelNames")),
        "sharedLabelValues": csv_list(val("kubecostProductConfigs.sharedLabelValues")),
        "sharedOverhead": val("kubecostProductConfigs.sharedOverhead") or 0,
        "shareTenancyCosts": bool(val("kubecostProductConfigs.shareTenancyCosts")),
        "defaultIdle": bool(val("kubecostProductConfigs.defaultIdle")),
        "labelMapping": {
            **DEFAULT_LABEL_MAPPING,
            **(val("kubecostProductConfigs.labelMappingConfigs") or {}),
        },
        "clusterProfile": val("kubecostProductConfigs.clusterProfile") or "production",
        "savingsProfiles": {
            "requestSizing": profiles.get("requestSizing") or [],
            "resourceQuotaSizing": profiles.get("resourceQuotaSizing") or [],
        },
    }

    teams = val("teams.teamsConfig") or []
    s["teams"] = {"enabled": bool(teams), "teams": teams}

    turbo = val("global.integrations.turbonomic") or {}
    s["turbonomic"] = {
        "enabled": bool(turbo.get("enabled")),
        "host": turbo.get("host", ""),
        "role": turbo.get("role", ""),
        "clientId": turbo.get("clientId", ""),
        "clientSecret": turbo.get("clientSecret", ""),
        "insecureClient": bool(turbo.get("insecureClient")),
    }

    plugins = val("plugins") or {}
    configs = {}
    existing = ""
    pl_secret = (
        get_path(plugins, "existingCustomSecret.name", "")
        if get_path(plugins, "existingCustomSecret.enabled", False)
        else ""
    )
    if pl_secret and pl_secret != f"{cr}-plugins":
        existing = pl_secret
    else:
        for k, v in (secrets.get(pl_secret or f"{cr}-plugins") or {}).items():
            if k.endswith("_config.json"):
                try:
                    configs[k[: -len("_config.json")]] = json.loads(v)
                except ValueError:
                    configs[k[: -len("_config.json")]] = v
        for k, v in (plugins.get("configs") or {}).items():
            try:
                configs.setdefault(k, json.loads(v))
            except TypeError, ValueError:
                configs.setdefault(k, v)
    s["plugins"] = {
        "enabled": bool(plugins.get("enabled")),
        "version": plugins.get("version", "") or "",
        "plugins": plugins.get("enabledPlugins") or sorted(configs),
        "existingSecret": existing,
        "configs": configs,
    }

    fed = val("global.federatedStorage") or {}
    fed_cfg = {}
    fed_existing = fed.get("existingSecret") or ""
    fed_file = fed.get("fileName") or "federated-store.yaml"
    if fed_existing == f"{cr}-federated-storage":
        fed_existing = ""
        try:
            fed_cfg = (
                yaml.safe_load(
                    secrets.get(f"{cr}-federated-storage", {}).get(fed_file, "")
                )
                or {}
            )
        except yaml.YAMLError:
            fed_cfg = {}
    elif fed.get("config"):
        try:
            fed_cfg = yaml.safe_load(fed["config"]) or {}
        except yaml.YAMLError:
            fed_cfg = {}
    trust_ca = bucket_tls(fed_cfg).get("ca_file") == SERVICE_CA_FILE
    if trust_ca:
        fed_cfg = without_service_ca(fed_cfg)
    # type first, the bucket settings last: the commented http_config example
    # in the file goes right under them.
    if isinstance(fed_cfg, dict) and "config" in fed_cfg:
        fed_cfg = {
            **{k: v for k, v in fed_cfg.items() if k != "config"},
            "config": fed_cfg["config"],
        }
    s["federatedStorage"] = {
        "enabled": bool(fed_existing or fed_cfg),
        "existingSecret": fed_existing,
        "trustServiceCA": trust_ca,
        "config": fed_cfg,
    }
    s["actions"] = {
        "enabled": bool(val("kubecostProductConfigs.actions.enabled", False))
    }
    return s


def generate(ctx):
    s = current_settings(ctx)
    cr, ns = ctx["instance"], ctx["namespace"]
    nc, al, ca = s["networkCosts"], s["alerts"], s["costAllocation"]
    sm, hl = al["smtp"], al["health"]
    nodes, labelled = ctx.get("nodes", 0), ctx.get("labelledNodes", 0)
    sso = ctx.get("sso") or ""
    key = "linked" if ctx.get("keyLinked") else "NOT linked"
    nc_note = ""
    if nc["enabled"] and nc["scheduleOn"] == "labelled-nodes" and labelled < nodes:
        nc_note = (
            f"\n# NOW: only {labelled} of {nodes} nodes have both labels, so network-costs runs on"
            f"\n# {labelled} node(s). Set scheduleOn: any-node to run it everywhere."
        )
    sr = s["savedReports"]
    t = s["turbonomic"]
    pl = s["plugins"]
    fs = s["federatedStorage"]
    # Commented TLS skip under the bucket settings, unless they already have
    # an http_config (then it is shown as set).
    fs_inner = fs["config"].get("config") if isinstance(fs["config"], dict) else None
    fs_tls_hint = ""
    if isinstance(fs_inner, dict) and "http_config" not in fs_inner:
        fs_tls_hint = (
            "\n      # Self-signed or private-CA endpoint: skip the certificate check"
            "\n      # (in-cluster .svc endpoint: trustServiceCA: true above verifies it instead)"
            "\n      # http_config:"
            "\n      #   tls_config:"
            "\n      #     insecure_skip_verify: true"
        )

    return f"""\
# Kubecost optional features for {cr} ({ns})
# Pulled from the cluster by generate_kubecost_features_config.sh; edit, then
# apply: features/apply_kubecost_features.sh {cr}   (--dry-run shows the change first)
#
# Every section is applied as written: "enabled: false" turns a feature off and
# drops its settings from the CR. Settings equal to the chart default are left
# out of the CR. Product key: {key}. SSO login: {sso or "none"}.
# Secrets (SMTP password, plugin API keys, bucket keys) go into Secrets the
# apply script creates; this file is private (0600) and gitignored.
version: 1
instance: {y(cr)}
namespace: {y(ns)}

# --- Network costs: traffic between pods, zones, regions and the internet ------
# A DaemonSet on the host network. The chart only schedules it on nodes that
# have the topology.kubernetes.io/region and .../zone labels (on-prem and
# TechZone nodes usually don't).{nc_note}
networkCosts:
  enabled: {y(nc["enabled"])}
  # labelled-nodes (chart default) | any-node
  scheduleOn: {y(nc["scheduleOn"])}
  # Also run on control-plane nodes (tolerates their NoSchedule taint)
  includeControlPlane: {y(nc["includeControlPlane"])}
  # Host port, also set on the finops agent that scrapes it. The chart's
  # OpenShift values use 9009 (cloud OpenShift opens 9000-9999 between nodes).
  port: {y(nc["port"])}
  # Log the top 5 destinations per source every 30 minutes
  trafficLogging: {y(nc["trafficLogging"])}

# --- Alerts -----------------------------------------------------------------------
# Kubecost 3.x supports one alert type: health (Kubecost's own diagnostics).
# Spend is watched with budgets (next section). Alerts set here replace alerts
# made in the UI. Emails go through Kubecost's hosted mail service (needs
# internet) unless smtp is enabled.
alerts:
  enabled: {y(al["enabled"])}
  # Link back to the UI in notifications (default: the instance's Route)
  frontendUrl: {y(al["frontendUrl"])}
  emails:{block(al["emails"], 4)}
  emailSubject: {y(al["emailSubject"])}
  slackWebhookUrl: {y(al["slackWebhookUrl"])}
  msTeamsWebhookUrl: {y(al["msTeamsWebhookUrl"])}
  health:
    enabled: {y(hl["enabled"])}
    # How often to check (e.g. 10m, 1h)
    window: {y(hl["window"])}
    # Added to the global recipients for this alert only
    extraEmails:{block(hl["extraEmails"], 6)}
    slackWebhookUrl: {y(hl["slackWebhookUrl"])}
    msTeamsWebhookUrl: {y(hl["msTeamsWebhookUrl"])}
  # Your own mail server, for alert and budget emails (Secret <instance>-smtp,
  # key smtp.json), or name an existing Secret with that key.
  smtp:
    enabled: {y(sm["enabled"])}
    existingSecret: {y(sm["existingSecret"])}
    host: {y(sm["host"])}
    port: {y(sm["port"])}
    senderEmail: {y(sm["senderEmail"])}
    authentication: {y(sm["authentication"])}
    username: {y(sm["username"])}
    password: {y(sm["password"])}
    # TLS
    secure: {y(sm["secure"])}

# --- Budgets ------------------------------------------------------------------------
# Spend limits with email/Slack/Teams actions. Replace budgets made in the UI.
# Amounts are compared with costs as Kubecost shows them (no currency conversion).
#   - name: "Team A weekly"
#     budgetType: allocations        # allocations | asset | cloud | collections
#     interval: weekly               # weekly | monthly
#     intervalDay: 1                 # weekly: 1-7 (1 = Monday); monthly: 1-31
#     spendLimit: 500
#     values:                        # what the budget covers
#       namespace: ["team-a", "team-a-dev"]
#       # cluster: ["{get_path(ctx.get("effective") or {}, "global.clusterId", "") or "cluster-one"}"]
#       # label: ["team:a"]
#     actions:                       # notify at a percentage of the limit
#       - percentage: 80
#         emails: ["finops@example.com"]
#         # slackWebhooks: ["https://hooks.slack.com/services/..."]
#         # msTeamsWebhooks: ["https://xxxxx.webhook.office.com/..."]
budgets:
  enabled: {y(s["budgets"]["enabled"])}
  budgets:{block(s["budgets"]["budgets"], 4)}

# --- Saved reports -------------------------------------------------------------------
# Reports defined here replace the ones saved in the UI for that report kind.
# Example (allocation; assets/cloudCosts reports take title, window,
# aggregateBy, accumulate and filters of {{property, value}}):
#     reports:
#       - title: "Namespaces this month"
#         window: month          # today, week, month, 7d, 30d, or "start,end" (RFC 3339)
#         aggregateBy: namespace # namespace, controllerKind, service, label:<name>, ...
#         chartDisplay: category
#         idle: separate         # separate | share | hide
#         rate: cumulative       # cumulative | monthly | daily | hourly
#         accumulate: false      # false = daily points, true = one total
#         filters:
#           - {{key: namespace, operator: "!:", value: kubecost}}
savedReports:
  allocation:
    enabled: {y(sr["allocation"]["enabled"])}
    reports:{block(sr["allocation"]["reports"], 6)}
  assets:
    enabled: {y(sr["assets"]["enabled"])}
    reports:{block(sr["assets"]["reports"], 6)}
  cloudCosts:
    enabled: {y(sr["cloudCosts"]["enabled"])}
    reports:{block(sr["cloudCosts"]["reports"], 6)}

# --- Data retention in the aggregator --------------------------------------------------
# Number of points kept per resolution. tenMinute 0 = no 10-minute data;
# 36 = 6 hours (the chart's suggested start). More points = more DB space.
dataRetention:
  tenMinute: {y(s["dataRetention"]["tenMinute"])}
  # hours
  hourly: {y(s["dataRetention"]["hourly"])}
  # days
  daily: {y(s["dataRetention"]["daily"])}

# --- Beta views -----------------------------------------------------------------------------
# Carbon estimates (assets/allocations carbon). Uses cloud region data, so
# on-prem nodes may show little.
carbonEstimates:
  enabled: {y(s["carbonEstimates"]["enabled"])}
# Recent cluster changes with their estimated cost impact (off by default only
# for very large clusters).
costEventsAudit:
  enabled: {y(s["costEventsAudit"]["enabled"])}

# --- Cost allocation -------------------------------------------------------------------------
costAllocation:
  # Namespaces whose cost is spread over all others (e.g. openshift-monitoring, {ns})
  sharedNamespaces:{block(ca["sharedNamespaces"], 4)}
  # Workloads with these label names/values are shared too (pairs, same order)
  sharedLabelNames:{block(ca["sharedLabelNames"], 4)}
  sharedLabelValues:{block(ca["sharedLabelValues"], 4)}
  # Fixed external cost per month spread over everything (licenses, fees)
  sharedOverhead: {y(ca["sharedOverhead"])}
  # Share costs such as cluster management fees
  shareTenancyCosts: {y(ca["shareTenancyCosts"])}
  # Share idle cost by default in the UI
  defaultIdle: {y(ca["defaultIdle"])}
  # Labels (or annotations) that mean owner/team/department/product/environment
  labelMapping:{block(ca["labelMapping"], 4)}
  # Savings recommendations profile: development | production | high-availability
  clusterProfile: {y(ca["clusterProfile"])}
  # Custom rightsizing profiles, e.g.
  #   requestSizing:
  #     - name: p95
  #       algorithmCPU: quantileOfAverages
  #       algorithmRAM: quantileOfAverages
  #       quantileCPU: 0.95
  #       quantileRAM: 0.95
  #       targetUtilizationCPU: 0.7
  #       targetUtilizationRAM: 0.7
  #   resourceQuotaSizing:
  #     - name: tight
  #       cpuRequestMetric: request.p95
  #       cpuRequestHeadroom: 0.25
  #       ramRequestMetric: request.p95
  #       ramRequestHeadroom: 0.25
  savingsProfiles:
    requestSizing:{block(ca["savingsProfiles"]["requestSizing"], 6)}
    resourceQuotaSizing:{block(ca["savingsProfiles"]["resourceQuotaSizing"], 6)}

# --- Teams (Enterprise): per-team pages, permissions and cost filters ----------------------------
# Needs SAML or OIDC login with <sso>.rbac.enabled and no <sso>.rbac.groups (the
# chart won't combine simple RBAC groups with teams); the OpenShift login
# doesn't pass claims. Replaces teams made in the UI.
#   teams:
#     - name: team-a
#       roles:
#         - name: viewer
#           permissions: read
#           pages:
#             showAllocation: true
#             showBudgets: true
#           allocationFilters:
#             - {{key: namespace, operator: ":", value: team-a}}
#       claims:                    # IdP claims that put a user in the team
#         NameID: user@example.com
teams:
  enabled: {y(s["teams"]["enabled"])}
  teams:{block(s["teams"]["teams"], 4)}

# --- Turbonomic integration ---------------------------------------------------------------------
# OAuth client made in Turbonomic. The chart has no Secret reference for it,
# so clientSecret is stored in the CR.
turbonomic:
  enabled: {y(t["enabled"])}
  host: {y(t["host"])}
  role: {y(t["role"])}
  clientId: {y(t["clientId"])}
  clientSecret: {y(t["clientSecret"])}
  insecureClient: {y(t["insecureClient"])}

# --- Plugins: external costs (e.g. Datadog) -------------------------------------------------------
# Downloaded at start-up (needs internet). Each plugin's config goes into the
# Secret <instance>-plugins as <name>_config.json, e.g.
#   configs:
#     datadog:
#       datadog_site: datadoghq.com
#       datadog_api_key: "..."
#       datadog_app_key: "..."
plugins:
  enabled: {y(pl["enabled"])}
  # empty = latest
  version: {y(pl["version"])}
  plugins:{block(pl["plugins"], 4)}
  # Use an existing Secret (<name>_config.json keys) instead of configs
  existingSecret: {y(pl["existingSecret"])}
  configs:{block(pl["configs"], 4)}

# --- Federated storage: object storage for multi-cluster and long-term data -----------------------
# Off = the chart's in-cluster store (the local-store PVC, Secret
# <instance>-federated-storage-config). On moves the agent's data to a bucket:
# history in the local store is not carried over. Bucket config as in the IBM docs, e.g.
#   config:
#     type: S3                  # S3 | GCS | AZURE
#     config:
#       bucket: kubecost
#       endpoint: s3.openshift-storage.svc:443
#       region: us-east-1
#       access_key: "..."
#       secret_key: "..."
#       # TLS. The Kubecost images only trust public CAs, so an endpoint with a
#       # self-signed or private-CA certificate fails with "x509: certificate
#       # signed by unknown authority" (the aggregator then crash-loops). Either
#       # skip the check:
#       http_config:
#         tls_config:
#           insecure_skip_verify: true
#       # or, for an endpoint on this cluster, use trustServiceCA below instead.
# (a flat map with type next to bucket is accepted too)
# Written to the Secret <instance>-federated-storage, or name an existing
# Secret with a federated-store.yaml key.
federatedStorage:
  enabled: {y(fs["enabled"])}
  existingSecret: {y(fs["existingSecret"])}
  # Verify an in-cluster S3 endpoint (*.svc, e.g. the ODF/NooBaa
  # s3.openshift-storage.svc) against the OpenShift service CA, instead of
  # skipping the check. Needs the bucket on this cluster and config below (not
  # existingSecret). Mounts the namespace's {SERVICE_CA_CONFIGMAP} ConfigMap
  # (kept current by OpenShift) into the aggregator, cloud-cost and finops-agent pods,
  # and gives the cluster controller its own copy in the Secret
  # <instance>-actions-storage (re-apply after a service CA rotation).
  trustServiceCA: {y(fs["trustServiceCA"])}
  config:{block(fs["config"], 4)}{fs_tls_hint}

# --- Actions (v2): scheduled rightsizing / turndown run by the cluster controller ------------------
# Needs the product key. Stores its state in the federated storage (the
# in-cluster store when federatedStorage is off).
actions:
  enabled: {y(s["actions"]["enabled"])}
"""


# --------------------------------------------------------------------------- plan
class Plan:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cr = ctx["instance"]
        self.spec = ctx.get("crSpec") or {}
        self.settings = []  # (feature, path, desired)
        self.secrets = []  # {"name", "data", "purpose"}
        self.summary = []  # (feature, text)
        self.warnings = []
        self.errors = []

    def set(self, feature, path, value):
        if value is not DELETE and path in DEFAULTS and value == DEFAULTS[path]:
            value = DELETE
        self.settings.append((feature, path, value))

    def err(self, feature, msg):
        self.errors.append(f"{feature}: {msg}")

    def warn(self, feature, msg):
        self.warnings.append(f"{feature}: {msg}")


def section(cfg, name, plan):
    v = cfg.get(name)
    if v is None:
        return {}
    if not isinstance(v, dict):
        plan.err(name, "must be a map")
        return {}
    return v


def flag(sec, key, plan, feature, default=False):
    v = sec.get(key, default)
    if not isinstance(v, bool):
        plan.err(feature, f"{key} must be true or false, not {v!r}")
        return default
    return v


def num(sec, key, plan, feature, default=0, minimum=0, integer=True):
    v = sec.get(key, default)
    if (
        isinstance(v, bool)
        or not isinstance(v, (int, float))
        or (integer and not isinstance(v, int))
        or v < minimum
    ):
        plan.err(
            feature,
            f"{key} must be a{'n integer' if integer else ' number'} >= {minimum}, not {v!r}",
        )
        return default
    return v


def text(sec, key, plan, feature):
    v = sec.get(key, "")
    if v is None:
        return ""
    if not isinstance(v, (str, int, float)) or isinstance(v, bool):
        plan.err(feature, f"{key} must be text, not {v!r}")
        return ""
    return str(v).strip()


def str_list(sec, key, plan, feature):
    v = sec.get(key) or []
    if isinstance(v, str):
        v = csv_list(v)
    if not isinstance(v, list) or not all(
        isinstance(i, (str, int)) and not isinstance(i, bool) for i in v
    ):
        plan.err(feature, f"{key} must be a list of text")
        return []
    return [str(i).strip() for i in v if str(i).strip()]


def map_list(sec, key, plan, feature, required=()):
    v = sec.get(key) or []
    if not isinstance(v, list) or not all(isinstance(i, dict) for i in v):
        plan.err(feature, f"{key} must be a list of maps")
        return []
    for i, item in enumerate(v, 1):
        missing = [r for r in required if item.get(r) in (None, "")]
        if missing:
            plan.err(feature, f"{key}[{i}] lacks {', '.join(missing)}")
    return v


def plan_network_costs(cfg, p):
    f = "networkCosts"
    s = section(cfg, f, p)
    on = flag(s, "enabled", p, f, True)
    where = s.get("scheduleOn", "labelled-nodes")
    if where not in ("labelled-nodes", "any-node"):
        p.err(f, f"scheduleOn must be labelled-nodes or any-node, not {where!r}")
    cp = flag(s, "includeControlPlane", p, f)
    port = num(s, "port", p, f, 3001, 1)
    if port > 65535:
        p.err(f, "port must be 1-65535")
    logging = flag(s, "trafficLogging", p, f, True)
    p.set(f, "networkCosts.enabled", DELETE if on else False)
    p.set(
        f, "networkCosts.affinity", ANY_NODE_AFFINITY if where == "any-node" else DELETE
    )
    p.set(f, "networkCosts.tolerations", CONTROL_PLANE_TOLERATIONS if cp else DELETE)
    p.set(f, "networkCosts.port", port)
    p.set(
        f,
        "finopsagent.agent.collectorDataSource.networkPort",
        DELETE if port == 3001 else port,
    )
    p.set(f, "networkCosts.trafficLogging", logging)
    if on:
        nodes, labelled = p.ctx.get("nodes", 0), p.ctx.get("labelledNodes", 0)
        if where == "labelled-nodes" and labelled < nodes:
            p.warn(
                f,
                f"only {labelled} of {nodes} nodes have the region/zone labels; scheduleOn: any-node runs it on all",
            )
        p.summary.append(
            (f, f"on, {where}{', incl. control plane' if cp else ''}, port {port}")
        )
    else:
        p.summary.append((f, "off"))


def plan_alerts(cfg, p):
    f = "alerts"
    s = section(cfg, f, p)
    on = flag(s, "enabled", p, f)
    h = s.get("health") or {}
    sm = s.get("smtp") or {}
    if not isinstance(h, dict) or not isinstance(sm, dict):
        p.err(f, "health and smtp must be maps")
        h, sm = {}, {}
    smtp_on = on and flag(sm, "enabled", p, f + ".smtp")
    if not on:
        p.set(f, "global.notifications.alertConfigs", DELETE)
        p.set(f, "kubecostProductConfigs.smtp", DELETE)
        p.summary.append((f, "off"))
        return
    emails = str_list(s, "emails", p, f)
    slack = text(s, "slackWebhookUrl", p, f)
    teams = text(s, "msTeamsWebhookUrl", p, f)
    cfg_out = {"frontendUrl": text(s, "frontendUrl", p, f) or p.ctx.get("url") or ""}
    if not cfg_out["frontendUrl"]:
        del cfg_out["frontendUrl"]
    if slack:
        cfg_out["globalSlackWebhookUrl"] = slack
    if teams:
        cfg_out["globalMsTeamsWebhookUrl"] = teams
    if emails:
        cfg_out["globalAlertEmails"] = emails
    subject = text(s, "emailSubject", p, f)
    if subject:
        cfg_out["globalEmailSubject"] = subject
    alerts = []
    h_on = flag(h, "enabled", p, f + ".health", True)
    if h_on:
        window = text(h, "window", p, f + ".health") or "1h"
        if not DURATION.match(window):
            p.err(f, f"health.window must look like 10m, 1h or 1d, not {window!r}")
        a = {"type": "health", "window": window}
        extra = str_list(h, "extraEmails", p, f + ".health")
        if extra:
            a["ownerContact"] = extra
        for k in ("slackWebhookUrl", "msTeamsWebhookUrl"):
            v = text(h, k, p, f + ".health")
            if v:
                a[k] = v
        alerts.append(a)
        if not (
            emails
            or slack
            or teams
            or extra
            or a.get("slackWebhookUrl")
            or a.get("msTeamsWebhookUrl")
        ):
            p.err(
                f,
                "health alert has nowhere to go: set emails, slackWebhookUrl or msTeamsWebhookUrl",
            )
    else:
        p.warn(f, "enabled with no alert; only budgets will notify")
    cfg_out["alerts"] = alerts
    p.set(f, "global.notifications.alertConfigs", cfg_out)

    dest = []
    if emails or any("ownerContact" in a for a in alerts):
        dest.append("email")
    if slack or any("slackWebhookUrl" in a for a in alerts):
        dest.append("Slack")
    if teams or any("msTeamsWebhookUrl" in a for a in alerts):
        dest.append("Teams")
    if smtp_on:
        existing = text(sm, "existingSecret", p, f + ".smtp")
        if existing:
            p.set(f, "kubecostProductConfigs.smtp", {"secretname": existing})
            smtp_desc = f"SMTP via Secret {existing}"
        else:
            host = text(sm, "host", p, f + ".smtp")
            sender = text(sm, "senderEmail", p, f + ".smtp")
            if not host or not sender:
                p.err(f, "smtp needs host and senderEmail (or existingSecret)")
            auth = flag(sm, "authentication", p, f + ".smtp", True)
            user, pw = (
                text(sm, "username", p, f + ".smtp"),
                text(sm, "password", p, f + ".smtp"),
            )
            if auth and not (user and pw):
                p.err(f, "smtp authentication needs username and password")
            smtp_json = {
                "sender_email": sender,
                "host": host,
                "port": num(sm, "port", p, f + ".smtp", 587, 1),
                "authentication": auth,
                "username": user,
                "password": pw,
                "secure": flag(sm, "secure", p, f + ".smtp", True),
            }
            name = f"{p.cr}-smtp"
            p.secrets.append(
                {
                    "name": name,
                    "data": {"smtp.json": json.dumps(smtp_json, indent=2)},
                    "purpose": "SMTP",
                }
            )
            p.set(f, "kubecostProductConfigs.smtp", {"secretname": name})
            smtp_desc = f"SMTP {host}"
    else:
        p.set(f, "kubecostProductConfigs.smtp", DELETE)
        smtp_desc = "Kubecost mail service" if "email" in dest else ""
    p.summary.append(
        (
            f,
            "on: "
            + (f"health every {alerts[0]['window']}" if alerts else "no alerts")
            + (f" -> {', '.join(dest)}" if dest else "")
            + (f" ({smtp_desc})" if smtp_desc else ""),
        )
    )


def plan_budgets(cfg, p):
    f = "budgets"
    s = section(cfg, f, p)
    on = flag(s, "enabled", p, f)
    if not on:
        p.set(f, "kubecostProductConfigs.budgets.budgetsConfig", DELETE)
        p.summary.append((f, "off"))
        return
    items = map_list(
        s, "budgets", p, f, ("name", "budgetType", "interval", "spendLimit")
    )
    for i, b in enumerate(items, 1):
        if b.get("budgetType") and b["budgetType"] not in BUDGET_TYPES:
            p.err(
                f, f"budgets[{i}].budgetType must be one of {', '.join(BUDGET_TYPES)}"
            )
        if b.get("interval") and b["interval"] not in ("weekly", "monthly"):
            p.err(f, f"budgets[{i}].interval must be weekly or monthly")
        if b.get("spendLimit") not in (None, "") and (
            isinstance(b["spendLimit"], bool)
            or not isinstance(b["spendLimit"], (int, float))
        ):
            p.err(f, f"budgets[{i}].spendLimit must be a number")
    if not items:
        p.warn(f, "enabled with no budgets listed; applied as an empty list")
    p.set(f, "kubecostProductConfigs.budgets.budgetsConfig", items)
    p.summary.append((f, f"on: {len(items)} budget(s)"))


def plan_reports(cfg, p):
    f = "savedReports"
    s = section(cfg, f, p)
    parts = []
    for key, path in (
        ("allocation", "global.savedReports"),
        ("assets", "global.assetReports"),
        ("cloudCosts", "global.cloudCostReports"),
    ):
        r = s.get(key) or {}
        if not isinstance(r, dict):
            p.err(f, f"{key} must be a map")
            continue
        if flag(r, "enabled", p, f"{f}.{key}"):
            reports = map_list(r, "reports", p, f"{f}.{key}", ("title", "window"))
            if not reports:
                p.warn(f, f"{key} enabled with no reports listed; applied as an empty list")
            p.set(f, path, {"enabled": True, "reports": reports})
            parts.append(f"{key} {len(reports)}")
        else:
            p.set(f, path, DELETE)
    p.summary.append((f, "on: " + ", ".join(parts) if parts else "off"))


def plan_retention(cfg, p):
    f = "dataRetention"
    s = section(cfg, f, p)
    ten = num(s, "tenMinute", p, f, 0)
    hourly = num(s, "hourly", p, f, 49, 1)
    daily = num(s, "daily", p, f, 91, 1)
    p.set(f, "aggregator.retention10m", ten)
    p.set(f, "aggregator.retention1h", hourly)
    p.set(f, "aggregator.retention1d", daily)
    p.summary.append(
        (f, f"10-minute {ten} ({ten * 10 // 60} h), hourly {hourly} h, daily {daily} d")
    )


def plan_toggles(cfg, p):
    for f, path in (
        ("carbonEstimates", "kubecostProductConfigs.carbonEstimates"),
        ("costEventsAudit", "costEventsAudit.enabled"),
    ):
        on = flag(section(cfg, f, p), "enabled", p, f)
        p.set(f, path, True if on else DELETE)
        p.summary.append((f, "on" if on else "off"))


def plan_allocation(cfg, p):
    f = "costAllocation"
    s = section(cfg, f, p)
    names, values = (
        str_list(s, "sharedLabelNames", p, f),
        str_list(s, "sharedLabelValues", p, f),
    )
    if len(names) != len(values):
        p.err(f, "sharedLabelNames and sharedLabelValues must pair up (same length)")
    shared = str_list(s, "sharedNamespaces", p, f)
    p.set(f, "kubecostProductConfigs.sharedNamespaces", ",".join(shared))
    p.set(f, "kubecostProductConfigs.sharedLabelNames", ",".join(names))
    p.set(f, "kubecostProductConfigs.sharedLabelValues", ",".join(values))
    overhead = num(s, "sharedOverhead", p, f, 0, 0, integer=False)
    p.set(f, "kubecostProductConfigs.sharedOverhead", overhead)
    p.set(
        f,
        "kubecostProductConfigs.shareTenancyCosts",
        flag(s, "shareTenancyCosts", p, f, True),
    )
    p.set(f, "kubecostProductConfigs.defaultIdle", flag(s, "defaultIdle", p, f))
    lm = s.get("labelMapping") or {}
    if not isinstance(lm, dict) or set(lm) - set(DEFAULT_LABEL_MAPPING):
        p.err(f, f"labelMapping keys: {', '.join(DEFAULT_LABEL_MAPPING)}")
        lm = {}
    p.set(
        f,
        "kubecostProductConfigs.labelMappingConfigs",
        {**DEFAULT_LABEL_MAPPING, **{k: str(v) for k, v in lm.items()}},
    )
    profile = s.get("clusterProfile", "production")
    if profile not in CLUSTER_PROFILES:
        p.err(f, f"clusterProfile must be one of {', '.join(CLUSTER_PROFILES)}")
    p.set(f, "kubecostProductConfigs.clusterProfile", profile)
    sp = s.get("savingsProfiles") or {}
    rs = (
        map_list(sp, "requestSizing", p, f + ".savingsProfiles", ("name",))
        if isinstance(sp, dict)
        else []
    )
    rq = (
        map_list(sp, "resourceQuotaSizing", p, f + ".savingsProfiles", ("name",))
        if isinstance(sp, dict)
        else []
    )
    out = {}
    if rs:
        out["requestSizing"] = rs
    if rq:
        out["resourceQuotaSizing"] = rq
    p.set(f, "kubecostProductConfigs.savingsProfiles", out or DELETE)
    bits = (
        [f"shared ns {len(shared)}"]
        + ([f"shared labels {len(names)}"] if names else [])
        + ([f"overhead {overhead}/month"] if overhead else [])
        + [f"profile {profile}"]
        + ([f"{len(rs) + len(rq)} savings profile(s)"] if out else [])
    )
    p.summary.append((f, ", ".join(bits)))


def plan_teams(cfg, p):
    f = "teams"
    s = section(cfg, f, p)
    if not flag(s, "enabled", p, f):
        p.set(f, "teams.teamsConfig", DELETE)
        p.summary.append((f, "off"))
        return
    items = map_list(s, "teams", p, f, ("name",))
    if not items:
        p.warn(f, "enabled with no teams listed; applied as an empty list")
    # Chart: teams render with SSO + <sso>.rbac.enabled and no <sso>.rbac.groups
    # (groups = simple RBAC, which the chart refuses to combine with teams).
    sso = p.ctx.get("sso")
    if not sso:
        p.err(
            f,
            "needs SAML or OIDC login (ui_login/enable_kubecost_ui_login.sh --mode oidc|saml)",
        )
    elif p.ctx.get("ssoGroups"):
        p.err(
            f,
            f"{sso}.rbac.groups is set (simple RBAC, e.g. the admin groups ui_login/enable_kubecost_ui_login.sh adds); "
            "the chart can't combine it with teams: remove the groups first",
        )
    elif not p.ctx.get("ssoRbac"):
        p.err(f, f"{sso}.rbac.enabled is false; teams need it on")
    if not p.ctx.get("keyLinked"):
        p.warn(f, "teams are an Enterprise feature; no product key is linked")
    p.set(f, "teams.teamsConfig", items)
    p.summary.append((f, f"on: {len(items)} team(s)"))


def plan_turbonomic(cfg, p):
    f = "turbonomic"
    s = section(cfg, f, p)
    if not flag(s, "enabled", p, f):
        p.set(f, "global.integrations.turbonomic", DELETE)
        p.summary.append((f, "off"))
        return
    out = {"enabled": True}
    for k in ("host", "role", "clientId", "clientSecret"):
        out[k] = text(s, k, p, f)
        if not out[k]:
            p.err(f, f"{k} is required")
    if out["host"] and not out["host"].startswith("https://"):
        p.err(f, "host must be an https:// URL")
    out["insecureClient"] = flag(s, "insecureClient", p, f)
    p.set(f, "global.integrations.turbonomic", out)
    p.warn(
        f,
        "clientSecret is stored in the Kubecost CR (the chart has no Secret reference for it)",
    )
    p.summary.append((f, f"on: {out['host']}"))


def plan_plugins(cfg, p):
    f = "plugins"
    s = section(cfg, f, p)
    if not flag(s, "enabled", p, f):
        p.set(f, "plugins", DELETE)
        p.summary.append((f, "off"))
        return
    names = str_list(s, "plugins", p, f)
    existing = text(s, "existingSecret", p, f)
    configs = s.get("configs") or {}
    if not isinstance(configs, dict):
        p.err(f, "configs must be a map of plugin name -> config")
        configs = {}
    names = names or sorted(configs)
    if not names:
        p.warn(f, "enabled with no plugins listed; applied with none")
    if existing:
        secret = existing
    else:
        secret = f"{p.cr}-plugins"
        missing = [n for n in names if n not in configs]
        if missing:
            p.err(
                f,
                f"no config for {', '.join(missing)} (configs.<name>) and no existingSecret",
            )
        data = {
            f"{n}_config.json": (c if isinstance(c, str) else json.dumps(c, indent=2))
            for n, c in configs.items()
        }
        p.secrets.append({"name": secret, "data": data, "purpose": "plugins"})
    out = {
        "enabled": True,
        "install": {"enabled": True},
        "enabledPlugins": names,
        "existingCustomSecret": {"enabled": True, "name": secret},
    }
    version = text(s, "version", p, f)
    if version:
        out["version"] = version
    p.set(f, "plugins", out)
    p.warn(
        f,
        "plugins are downloaded when the pods start (curlimages/curl from Docker Hub, files from GitHub): needs internet",
    )
    p.summary.append((f, f"on: {', '.join(names) or 'none'} (Secret {secret})"))


def plan_service_ca_checks(cfg, config, p):
    """True if trustServiceCA can be used for this bucket config (errors otherwise)."""
    f = "federatedStorage"
    host = endpoint_host(config["config"].get("endpoint"))
    ok = True
    if config["type"] != "S3":
        p.err(f, f"trustServiceCA is for an in-cluster S3 endpoint, not type {config['type']}")
        ok = False
    elif not is_service_host(host):
        p.err(
            f,
            f"trustServiceCA needs an in-cluster service endpoint (*.svc or *.svc.cluster.local), "
            f"not {host or 'none'}: the service CA only signs service certificates. For a route "
            "or external endpoint with a private CA use http_config.tls_config.insecure_skip_verify",
        )
        ok = False
    if not (p.ctx.get("serviceCA") or "").strip():
        p.err(
            f,
            f"trustServiceCA: no ConfigMap {SERVICE_CA_CONFIGMAP} (key {SERVICE_CA_KEY}) in "
            f"{p.ctx['namespace']}; OpenShift creates it in every namespace (not OpenShift?)",
        )
        ok = False
    tls = bucket_tls(config)
    if tls.get("ca_file"):
        p.err(f, f"trustServiceCA sets http_config.tls_config.ca_file; remove {tls['ca_file']!r}")
        ok = False
    if tls.get("insecure_skip_verify") is True or get_path(
        config, "config.http_config.insecure_skip_verify", False
    ) is True:
        p.warn(f, "insecure_skip_verify is also set, so the service CA is never checked; drop it")
    cc = get_path(p.spec, "clusterController.storageConfigSecret", "")
    if (cc and cc != f"{p.cr}-actions-storage") or get_path(
        p.spec, "clusterController.storageConfig", ""
    ):
        p.err(
            f,
            "trustServiceCA sets clusterController.storageConfigSecret, but the CR already has its own "
            "cluster controller bucket config",
        )
        ok = False
    nc = cfg.get("networkCosts")
    if isinstance(nc, dict) and nc.get("enabled") is True:
        p.warn(
            f,
            "network-costs writes to the bucket too, but chart 3.3.1 can't mount the CA into it: "
            "its uploads will fail TLS (use insecure_skip_verify instead if you need both)",
        )
    return ok


def plan_service_ca_wiring(p, on):
    """Mount (or remove) the service CA in the bucket readers, and point the cluster
    controller at its own config; only our own list entries are touched."""
    f = "federatedStorage"
    volume = {
        "name": SERVICE_CA_VOLUME,
        "configMap": {
            "name": SERVICE_CA_CONFIGMAP,
            "items": [{"key": SERVICE_CA_KEY, "path": SERVICE_CA_KEY}],
        },
    }
    mount = {"name": SERVICE_CA_VOLUME, "mountPath": SERVICE_CA_DIR, "readOnly": True}
    for comp in SERVICE_CA_COMPONENTS:
        for key, item in (("extraVolumes", volume), ("extraVolumeMounts", mount)):
            path = f"{comp}.{key}"
            cur = get_path(p.spec, path, [])
            ours = isinstance(cur, list) and any(
                isinstance(v, dict) and v.get("name") == SERVICE_CA_VOLUME for v in cur
            )
            if on or ours:
                p.set(f, path, volumes_with(cur, item, on))
    actions = f"{p.cr}-actions-storage"
    path = "clusterController.storageConfigSecret"
    if on:
        p.set(f, path, actions)
    elif get_path(p.spec, path, "") == actions:
        p.set(f, path, DELETE)


def plan_federated(cfg, p):
    f = "federatedStorage"
    s = section(cfg, f, p)
    on = flag(s, "enabled", p, f)
    trust = flag(s, "trustServiceCA", p, f) and on
    use_ca = False  # the service CA wiring below goes in
    if on:
        existing = text(s, "existingSecret", p, f)
        config = s.get("config") or {}
        # Accept the flat form {type: S3, bucket: ..., ...} as well as the
        # objstore form {type: S3, config: {bucket: ...}}.
        if (
            isinstance(config, dict)
            and config.get("type")
            and not isinstance(config.get("config"), dict)
        ):
            flat = {k: v for k, v in config.items() if k != "type"}
            config = {"type": config["type"], "config": flat} if flat else config
        if isinstance(config, dict) and isinstance(config.get("type"), str):
            config = {**config, "type": config["type"].upper()}
        if isinstance(config, dict) and isinstance(config.get("config"), dict):
            config = without_service_ca(config)
        if existing and config:
            p.err(f, "set existingSecret or config, not both")
        elif existing:
            if trust:
                p.err(
                    f,
                    "trustServiceCA needs the bucket settings in config (it adds the CA file to them), "
                    "not existingSecret",
                )
            p.set(f, "global.federatedStorage", {"existingSecret": existing})
            p.summary.append((f, f"on: Secret {existing}"))
        elif (
            isinstance(config, dict)
            and config.get("type")
            and isinstance(config.get("config"), dict)
        ):
            name = f"{p.cr}-federated-storage"
            store = config
            if trust:
                use_ca = plan_service_ca_checks(cfg, config, p)
                if use_ca:
                    store = with_ca_file(config, SERVICE_CA_FILE)
                    actions = f"{p.cr}-actions-storage"
                    p.secrets.append(
                        {
                            "name": actions,
                            "data": {
                                "actions-store.yaml": yaml.safe_dump(
                                    with_ca_file(config, ACTIONS_CA_FILE),
                                    sort_keys=False,
                                ),
                                SERVICE_CA_KEY: p.ctx["serviceCA"],
                            },
                            "purpose": "cluster controller bucket config + service CA",
                        }
                    )
            elif bucket_tls(config).get("insecure_skip_verify") is not True:
                host = endpoint_host(config["config"].get("endpoint"))
                if config["type"] == "S3" and is_service_host(host):
                    p.warn(
                        f,
                        f"{host} serves a certificate from the OpenShift service CA, which the Kubecost "
                        "images don't trust: set trustServiceCA: true, or http_config.tls_config."
                        "insecure_skip_verify: true in config",
                    )
            p.secrets.append(
                {
                    "name": name,
                    "data": {
                        "federated-store.yaml": yaml.safe_dump(store, sort_keys=False)
                    },
                    "purpose": "federated storage",
                }
            )
            p.set(
                f, "global.federatedStorage", {"existingSecret": name, "config": DELETE}
            )
            bucket = (
                config["config"].get("bucket")
                or config["config"].get("container")
                or "?"
            )
            p.summary.append(
                (
                    f,
                    f"on: {config['type']} bucket {bucket} (Secret {name})"
                    + (", verified with the service CA" if use_ca else ""),
                )
            )
        else:
            p.err(
                f, "needs existingSecret or config: {type: S3|GCS|AZURE, config: {...}}"
            )
        p.warn(
            f,
            "moves Kubecost's data from the in-cluster local store to the bucket (history there is not "
            "carried over); untested with this operator",
        )
    else:
        p.set(f, "global.federatedStorage", DELETE)
        p.summary.append((f, "off"))
    plan_service_ca_wiring(p, use_ca)

    a = "actions"
    if flag(section(cfg, a, p), "enabled", p, a):
        if not p.ctx.get("keyLinked"):
            p.warn(
                a,
                "no product key is linked: actions need it (free tier needs an RSA signing key pair, "
                "not handled here); applying anyway",
            )
        p.set(a, "kubecostProductConfigs.actions", {"enabled": True})
        p.summary.append((a, "on"))
    else:
        p.set(a, "kubecostProductConfigs.actions", DELETE)
        p.summary.append((a, "off"))


PLANNERS = (
    plan_network_costs,
    plan_alerts,
    plan_budgets,
    plan_reports,
    plan_retention,
    plan_toggles,
    plan_allocation,
    plan_teams,
    plan_turbonomic,
    plan_plugins,
    plan_federated,
)
KNOWN = {
    "version",
    "instance",
    "namespace",
    "networkCosts",
    "alerts",
    "budgets",
    "savedReports",
    "dataRetention",
    "carbonEstimates",
    "costEventsAudit",
    "costAllocation",
    "teams",
    "turbonomic",
    "plugins",
    "federatedStorage",
    "actions",
}


def plan(ctx, path):
    p = Plan(ctx)
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError) as e:
        return {"errors": [f"cannot read {path}: {e}"]}
    if not isinstance(cfg, dict):
        return {"errors": [f"{path}: expected a map at the top"]}
    # An empty or foreign file would turn every feature off.
    if "version" not in cfg:
        return {
            "errors": [
                f"{path}: no 'version:' line; not a features config (generate_kubecost_features_config.sh makes one)"
            ]
        }
    unknown = sorted(set(cfg) - KNOWN)
    if unknown:
        p.errors.append(f"unknown section(s): {', '.join(unknown)}")
    if cfg.get("version", 1) != 1:
        p.errors.append(f"version {cfg.get('version')!r} not supported (1)")
    for k in ("instance", "namespace"):
        if cfg.get(k) and cfg[k] != ctx[k]:
            p.warnings.append(f"file is for {k} {cfg[k]!r}, applying to {ctx[k]!r}")
    for planner in PLANNERS:
        planner(cfg, p)

    patch, changed = {}, set()
    for feature, path_, desired in p.settings:
        cur = get_path(p.spec, path_)
        d = merge_diff(cur, desired)
        if d is not NOCHANGE:
            set_path(patch, path_, d)
            changed.add(feature)
    return {
        "patch": {"spec": patch} if patch else {},
        "secrets": p.secrets,
        "summary": [
            {"feature": f, "state": s, "changed": f in changed} for f, s in p.summary
        ],
        "warnings": p.warnings,
        "errors": p.errors,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("command", choices=("generate", "plan"))
    ap.add_argument("--ctx", required=True)
    ap.add_argument("--file")
    a = ap.parse_args()
    with open(a.ctx, encoding="utf-8") as fh:
        ctx = json.load(fh)
    if a.command == "generate":
        sys.stdout.write(generate(ctx))
    else:
        if not a.file:
            ap.error("plan needs --file")
        json.dump(plan(ctx, a.file), sys.stdout, indent=1)
        sys.stdout.write("\n")


if __name__ == "__main__":
    main()
