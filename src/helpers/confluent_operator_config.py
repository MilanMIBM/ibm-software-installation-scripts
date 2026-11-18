#!/usr/bin/env python3
"""confluent_operator_config.py - Confluent operator install mode: settings, checks and operator targets.

    from src.helpers.confluent_operator_config import check, plan_operator_targets, KRAFT_PRESETS
    check({"CONFLUENT_DEPLOY_MODE": "operator", ...}, scope="platform", license_present=False)

The rules of the implementation contract (.claude/plans/confluent-operator-install-mode/implementation-contract.md
§2, §3.3) live here once; the shell side (cfo_check_config, cfo_plan_targets in confluent_operator_helpers.sh),
the vars generators and the notebook call this module. It reads values from a dict (import) or from os.environ
limited to ALLOWED_VARS (CLI). It never reads a secret value: the license is passed as a boolean.

CLI (exit 0, or 1 on bad arguments):
  confluent_operator_config.py check --scope <platform|flink|all> --license-present <true|false> [--format json|text]
  confluent_operator_config.py plan [--scope <platform|flink|all>]       lines "<ns> <pkg> [<pkg>]"
  confluent_operator_config.py resolve <deploy-mode|flink-source|cmf-mode>
  confluent_operator_config.py kraft-preset <size>                       NAME="value" lines
  confluent_operator_config.py fko-for-cmf <cmf-chart-version>           "channel csv"
  confluent_operator_config.py subscription-env --namespace <ns> --package <pkg>   JSON list [{"name","value"}]
  confluent_operator_config.py list-vars                                 one allowed var name per line
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
try:
    from .version_catalog import catalog_value
except ImportError:
    sys.path.insert(0, HERE)
    from version_catalog import catalog_value

PKG_CFK = "confluent-for-kubernetes"
PKG_FKO = "cp-fko"
PACKAGES = (PKG_CFK, PKG_FKO)

# The catalog values this module falls back to when version_catalog.json cannot be read (same literals).
_OPERATOR_DEFAULTS = {
    "cfk_channel": "3.4",
    "cfk_csv": "confluent-for-kubernetes.v3.4.0",
    "cfk_version": "3.4.0",
    "cfk_init_tag": "3.4.0",
    "fko_channel": "stable-v1.16",
    "fko_csv": "cp-fko.v1.16.1-cp1",
    "cmf_chart": "2.5.0",
    "flink_sql_image": "confluentinc/cp-flink-sql:1.19-cmf2.5-cp1",
    "flink_version_max": "v2_2",
    "compat": {
        "cfk": {"3.4": {"csv": "confluent-for-kubernetes.v3.4.0", "init_tag": "3.4.0", "cp_min": "7.6.0",
                        "cp_max_exclusive": "8.5.0", "c3_min": "2.4.0", "c3_max_exclusive": "2.8.0"}},
        "cmf": {"2.4": {"fko_channel": "stable-v1.15", "fko_csv": "cp-fko.v1.15.0-cp4", "min_cfk": "3.4"},
                "2.5": {"fko_channel": "stable-v1.16", "fko_csv": "cp-fko.v1.16.1-cp1", "min_cfk": "3.4"}},
    },
}

# §2.3 - one place for the presets (0_, the notebook and the renderer fallback read them from here).
KRAFT_PRESETS = {
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

# §2.1, §2.2, §2.3, §2.5 and the §2.4 vars the checks read. No secret value is ever in here.
ALLOWED_VARS = frozenset({
    # 2.1
    "CONFLUENT_DEPLOY_MODE", "FLINK_OPERATOR_SOURCE", "FLINK_CMF_RESOURCE_MODE", "CONFLUENT_CLUSTER_PLATFORM",
    # 2.2
    "CONFLUENT_OPERATOR_SOURCE", "CONFLUENT_OPERATOR_PACKAGE", "CONFLUENT_OPERATOR_SUBSCRIPTION_NAME",
    "CONFLUENT_OPERATOR_CHANNEL", "CONFLUENT_OPERATOR_STARTING_CSV", "CONFLUENT_OPERATOR_CATALOG_SOURCE",
    "CONFLUENT_OPERATOR_CATALOG_SOURCE_NAMESPACE", "CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL",
    "CONFLUENT_OPERATOR_INSTALL_IN_PLATFORM_NS", "CONFLUENT_OPERATOR_INSTALL_IN_FLINK_NS",
    "CONFLUENT_OPERATOR_EXTRA_NAMESPACES", "CONFLUENT_OPERATOR_PACKAGES_PER_NS",
    "CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING", "CONFLUENT_OPERATOR_ENABLE_CMF_DAY2_OPS",
    "CONFLUENT_OPERATOR_RESTRICT_CROSS_NS_RESTCLASS", "CONFLUENT_OPERATOR_IMAGE_SOURCE",
    "CONFLUENT_OPERATOR_INIT_IMAGE", "CONFLUENT_OPERATOR_TLS_SOURCE", "CONFLUENT_OPERATOR_TLS_SOURCE_CLI",
    "CONFLUENT_OPERATOR_SASL_IMPL", "CONFLUENT_CONNECTOR_MANAGEMENT", "CONFLUENT_AUTO_CREATE_TOPICS",
    "CONFLUENT_OPERATOR_NETWORK_POLICIES", "CONFLUENT_EXTERNAL_KAFKA_BOOTSTRAP_PREFIX",
    "CONFLUENT_EXTERNAL_KAFKA_BROKER_PREFIX", "CONFLUENT_OPERATOR_CSV_TIMEOUT",
    "CONFLUENT_OPERATOR_INSTALLPLAN_TIMEOUT", "CONFLUENT_OPERATOR_KAFKA_TIMEOUT",
    "CONFLUENT_OPERATOR_COMPONENT_TIMEOUT", "CONFLUENT_OPERATOR_CONNECT_TIMEOUT",
    "CONFLUENT_CONNECT_PLUGINS_PVC", "CONFLUENT_CONNECT_PLUGINS_PVC_SIZE", "CONFLUENT_CONNECT_PLUGINS_LOADER_IMAGE",
    # superseded but checked (§2.2 "not written")
    "CONFLUENT_OPERATOR_SCOPE", "CONFLUENT_OPERATOR_NAMESPACE",
    # 2.3
    *KRAFT_PRESETS["small"].keys(),
    # 2.4 (the ones the checks read)
    "PROJECT_CONFLUENT_SERVER", "CONFLUENT_VERSION", "CONFLUENT_C3_VERSION", "CONFLUENT_INSTALL_CONTROL_CENTER",
    "CONFLUENT_SASL_ENABLED", "CONFLUENT_SASL_PROTOCOL", "CONFLUENT_SASL_MECHANISM",
    "CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS", "CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS",
    "CONFLUENT_EXTERNAL_KAFKA_ENABLED", "CONFLUENT_AUTH_ENABLED", "CONFLUENT_AUTH_MODE", "CONFLUENT_MDS_ENABLED",
    # 2.5 + the Flink add-on vars the rules read
    "PROJECT_CONFLUENT_FLINK", "FLINK_CMF_CHART_VERSION", "FLINK_APPLICATION_VERSION",
    "FLINK_OLM_PACKAGE", "FLINK_OLM_SUBSCRIPTION_NAME", "FLINK_OLM_CHANNEL", "FLINK_OLM_STARTING_CSV",
    "FLINK_OLM_CATALOG_SOURCE", "FLINK_OLM_CATALOG_SOURCE_NAMESPACE", "FLINK_OLM_INSTALL_PLAN_APPROVAL",
    "FLINK_CFK_NAMESPACE", "FLINK_CMF_RESTCLASS_NAME", "FLINK_ENVIRONMENT_DELETE_WAIT", "FLINK_OLM_SCOPE",
})

SCRAM_LINKS = (
    "https://docs.confluent.io/operator/current/co-authenticate-overview.html",
    "https://docs.confluent.io/operator/current/co-configure-misc.html#co-config-overrides",
    "https://docs.confluent.io/operator/current/co-authenticate-kafka.html",
    "https://docs.confluent.io/platform/current/security/authentication/sasl/scram/overview.html",
)
SCRAM_PLAIN_ERROR = ("SCRAM needs CONFLUENT_OPERATOR_SASL_IMPL=scram (configOverrides; outside Confluent Support) "
                     "or use PLAIN")
KNOWN_MECHANISMS = ("PLAIN", "SCRAM-SHA-512", "SCRAM-SHA-256")
_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
_SIZE_RE = re.compile(r"^[0-9]+(Mi|Gi|Ti)$")
_DNS1123_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


# ---------------------------------------------------------------------------------------------------------------
# Small value helpers
# ---------------------------------------------------------------------------------------------------------------
def _get(values, name, default=""):
    v = values.get(name)
    return default if v is None else str(v)


def _trim(value):
    return "" if value is None else str(value).strip()


def _is_true(value):
    """Same set as h_is_true (common_helpers.sh): true / yes / y / 1, any case."""
    return _trim(value).lower() in ("true", "yes", "y", "1")


def _bool(values, name, default):
    v = _trim(values.get(name))
    return default if v == "" else _is_true(v)


def _vtuple(version):
    """'8.4.0' -> (8, 4, 0); 'cp-fko.v1.16.1-cp1' -> (1, 16, 1, 1)."""
    return tuple(int(n) for n in re.findall(r"\d+", version or ""))


def _minor(version):
    parts = _trim(version).split(".")
    return ".".join(parts[:2]) if len(parts) >= 2 else _trim(version)


def operator_catalog(catalog=None):
    """The confluent/operator catalog object (version_catalog.json), falling back to the same literals."""
    if catalog is not None:
        return catalog
    try:
        value = catalog_value("confluent/operator", default=None)
    except Exception:  # noqa: BLE001 - an unreadable catalog must not break the checks
        value = None
    return value if isinstance(value, dict) else _OPERATOR_DEFAULTS


# ---------------------------------------------------------------------------------------------------------------
# Resolvers (shell twins: cf_resolve_deploy_mode, cf_flink_operator_source, cf_flink_cmf_resource_mode)
# ---------------------------------------------------------------------------------------------------------------
def resolve_deploy_mode(value):
    """(mode, warning or None). scripts / operator (case-insensitive, trimmed); unset/empty/invalid -> operator."""
    v = _trim(value)
    low = v.lower()
    if low == "scripts":
        return "scripts", None
    if low in ("operator", ""):
        return "operator", None
    return "operator", f"CONFLUENT_DEPLOY_MODE='{v}' is not scripts|operator - using operator"


def resolve_flink_operator_source(value, deploy_mode):
    """(source, warning). helm / olm / existing; unset -> olm in operator mode else helm; invalid -> olm + warning."""
    v = _trim(value)
    low = v.lower()
    if low in ("helm", "olm", "existing"):
        return low, None
    if low == "":
        return ("olm" if deploy_mode == "operator" else "helm"), None
    return "olm", f"FLINK_OPERATOR_SOURCE='{v}' is not helm|olm|existing - using olm"


def resolve_flink_cmf_resource_mode(value, flink_source):
    """(mode, warning). cli / cfk; unset -> cfk when the Flink source is not helm, else cli; invalid -> that + warning."""
    default = "cfk" if flink_source != "helm" else "cli"
    v = _trim(value)
    low = v.lower()
    if low in ("cli", "cfk"):
        return low, None
    if low == "":
        return default, None
    return default, f"FLINK_CMF_RESOURCE_MODE='{v}' is not cli|cfk - using {default}"


def resolve_choice(name, value, allowed, default):
    """(canonical value, warning). Case-insensitive match against <allowed>; unset -> default; invalid -> default + warning."""
    v = _trim(value)
    if v == "":
        return default, None
    for a in allowed:
        if v.lower() == a.lower():
            return a, None
    return default, f"{name}='{v}' is not {'|'.join(allowed)} - using {default}"


def _modes(values):
    deploy, _ = resolve_deploy_mode(values.get("CONFLUENT_DEPLOY_MODE"))
    flink_source, _ = resolve_flink_operator_source(values.get("FLINK_OPERATOR_SOURCE"), deploy)
    cmf_mode, _ = resolve_flink_cmf_resource_mode(values.get("FLINK_CMF_RESOURCE_MODE"), flink_source)
    return deploy, flink_source, cmf_mode


def flink_configured(values):
    """Same rule as full_installprocess-confluent_platform.sh:91 (and cf_flink_configured)."""
    return bool(_trim(values.get("PROJECT_CONFLUENT_FLINK")) and _trim(values.get("FLINK_CMF_CHART_VERSION")))


# ---------------------------------------------------------------------------------------------------------------
# Catalog lookups
# ---------------------------------------------------------------------------------------------------------------
def compat(catalog=None):
    """confluent/operator/compat ({"cfk": {...}, "cmf": {...}})."""
    return operator_catalog(catalog).get("compat", _OPERATOR_DEFAULTS["compat"])


def fko_for_cmf(cmf_chart_version, catalog=None):
    """{"channel", "csv", "min_cfk"} of the cp-fko line a CMF chart version needs; KeyError for an unknown CMF line."""
    entry = compat(catalog).get("cmf", {}).get(_minor(cmf_chart_version))
    if not entry:
        raise KeyError(f"CMF {_minor(cmf_chart_version)} has no cp-fko pairing in the version catalog")
    return {"channel": entry["fko_channel"], "csv": entry["fko_csv"], "min_cfk": entry.get("min_cfk", "")}


def kraft_preset(size):
    """The §2.3 values of <size> (KeyError for an unknown size)."""
    return dict(KRAFT_PRESETS[size])


# ---------------------------------------------------------------------------------------------------------------
# Operator targets (§3.3 plan_operator_targets, §15.4, §8 D8)
# ---------------------------------------------------------------------------------------------------------------
def _parse_packages_per_ns(text):
    """'ns=pkg[,pkg] ns2=pkg' -> ([(ns, [pkg...])], [errors])."""
    out, errors = [], []
    for token in _trim(text).split():
        if "=" not in token:
            errors.append(f"CONFLUENT_OPERATOR_PACKAGES_PER_NS: '{token}' is not ns=pkg[,pkg]")
            continue
        ns, pkgs = token.split("=", 1)
        if not _DNS1123_RE.match(ns):
            errors.append(f"CONFLUENT_OPERATOR_PACKAGES_PER_NS: '{ns}' is not a namespace name")
            continue
        names = [p for p in pkgs.split(",") if p]
        bad = [p for p in names if p not in PACKAGES]
        if bad:
            errors.append(f"CONFLUENT_OPERATOR_PACKAGES_PER_NS: unknown package(s) {','.join(bad)} for {ns} "
                          f"(allowed: {', '.join(PACKAGES)})")
            continue
        out.append((ns, names))
    return out, errors


def _ordered(pkgs):
    return [p for p in PACKAGES if p in set(pkgs)]


def plan_operator_targets(values, scope="all"):
    """[(namespace, [packages])] in the order platform, Flink, extras, then per-ns override additions.

    scope "flink" keeps only the Flink operator namespaces (Flink 1.0o), "platform" only the platform ones.
    """
    deploy, flink_source, cmf_mode = _modes(values)
    with_flink = flink_configured(values)
    platform_ns = _trim(values.get("PROJECT_CONFLUENT_SERVER"))
    flink_ns = _trim(values.get("PROJECT_CONFLUENT_FLINK"))
    cfk_ns = _trim(values.get("FLINK_CFK_NAMESPACE")) or flink_ns

    platform_set = [PKG_CFK] + ([PKG_FKO] if with_flink and flink_source == "olm" else [])
    entries = []  # [(ns, set, origin)]

    def add(ns, pkgs, origin):
        if not ns or not pkgs:
            return
        for i, (have_ns, have_pkgs, have_origin) in enumerate(entries):
            if have_ns == ns:
                entries[i] = (ns, _ordered(have_pkgs + pkgs), have_origin | {origin})
                return
        entries.append((ns, _ordered(pkgs), {origin}))

    if deploy == "operator" and _bool(values, "CONFLUENT_OPERATOR_INSTALL_IN_PLATFORM_NS", True):
        add(platform_ns, platform_set, "platform")
    if with_flink and _bool(values, "CONFLUENT_OPERATOR_INSTALL_IN_FLINK_NS", True) \
            and (flink_source == "olm" or cmf_mode == "cfk"):
        flink_set = ([PKG_CFK] if (cmf_mode == "cfk" or deploy == "operator") else []) \
            + ([PKG_FKO] if flink_source == "olm" else [])
        add(flink_ns, flink_set, "flink")
        # CONTRACT-DEVIATION: the contract puts CFK for the CMF resources into the Flink namespace only; a user who
        # moves FLINK_CFK_NAMESPACE elsewhere needs the CFK there (that is where the CMF CRs are reconciled).
        if cmf_mode == "cfk" and cfk_ns != flink_ns:
            add(cfk_ns, [PKG_CFK], "flink")
    if deploy == "operator":
        for ns in _trim(values.get("CONFLUENT_OPERATOR_EXTRA_NAMESPACES")).split():
            add(ns, platform_set, "platform")

    overrides, _ = _parse_packages_per_ns(values.get("CONFLUENT_OPERATOR_PACKAGES_PER_NS"))
    for ns, pkgs in overrides:
        for i, (have_ns, _pkgs, origin) in enumerate(entries):
            if have_ns == ns:
                entries[i] = (ns, _ordered(pkgs), origin)
                break
        else:
            entries.append((ns, _ordered(pkgs), {"platform", "flink"}))

    want = {"all": {"platform", "flink"}, "platform": {"platform"}, "flink": {"flink"}}[scope]
    return [(ns, pkgs) for ns, pkgs, origin in entries if pkgs and origin & want]


def cmf_day2_ops_wanted(values, namespace, package):
    """True when the CFK Subscription in <namespace> gets ENABLE_CMF_DAY2_OPS=true (§2.2)."""
    if package != PKG_CFK:
        return False
    cmf_mode = _modes(values)[2]
    cfk_ns = _trim(values.get("FLINK_CFK_NAMESPACE")) or _trim(values.get("PROJECT_CONFLUENT_FLINK"))
    if namespace != cfk_ns or not flink_configured(values):
        return False
    explicit = _trim(values.get("CONFLUENT_OPERATOR_ENABLE_CMF_DAY2_OPS"))
    if explicit:
        return _is_true(explicit)
    return cmf_mode == "cfk"


def subscription_env(values, namespace, package):
    """spec.config.env entries our Subscription of <package> in <namespace> carries."""
    env = []
    if package != PKG_CFK:
        return env
    if cmf_day2_ops_wanted(values, namespace, package):
        env.append({"name": "ENABLE_CMF_DAY2_OPS", "value": "true"})
    if _bool(values, "CONFLUENT_OPERATOR_RESTRICT_CROSS_NS_RESTCLASS", False):
        env.append({"name": "RESTRICT_CROSS_NAMESPACE_KAFKARESTCLASS_USAGE", "value": "true"})
        env.append({"name": "RESTRICT_CROSS_NAMESPACE_CMFRESTCLASS_USAGE", "value": "true"})
    return env


# ---------------------------------------------------------------------------------------------------------------
# check (§3.3 rules, §3.5 as revised by §15)
# ---------------------------------------------------------------------------------------------------------------
def _mechanisms(text):
    return [m.strip().upper() for m in _trim(text).split(",") if m.strip()]


def _in_range(version, low, high_exclusive):
    return _vtuple(low) <= _vtuple(version) < _vtuple(high_exclusive)


def _flink_version_key(text):
    m = re.match(r"^v(\d+)_(\d+)$", _trim(text))
    return (int(m.group(1)), int(m.group(2))) if m else None


def _check_platform(values, errors, warnings, info, license_present, catalog):
    if _trim(values.get("CONFLUENT_CLUSTER_PLATFORM")).lower() == "kubernetes":
        errors.append("operator mode is OpenShift-only in v1")

    source = _trim(values.get("CONFLUENT_OPERATOR_SOURCE"))
    if source.lower() == "helm":
        errors.append("CONFLUENT_OPERATOR_SOURCE=helm is reserved for Kubernetes mode (v1: olm|existing)")
    elif source and source.lower() not in ("olm", "existing"):
        errors.append(f"CONFLUENT_OPERATOR_SOURCE='{source}' is not olm|existing")

    scope = _trim(values.get("CONFLUENT_OPERATOR_SCOPE"))
    if scope and scope.lower() != "own":
        errors.append(f"CONFLUENT_OPERATOR_SCOPE='{scope}': v1 supports own (OwnNamespace) only")
    if _trim(values.get("CONFLUENT_OPERATOR_NAMESPACE")):
        warnings.append("CONFLUENT_OPERATOR_NAMESPACE is ignored: each target namespace gets its own OwnNamespace "
                        "operator (CONFLUENT_OPERATOR_INSTALL_IN_PLATFORM_NS / _EXTRA_NAMESPACES)")

    approval, w = resolve_choice("CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL",
                                 values.get("CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL"), ("Manual", "Automatic"), "Manual")
    if w:
        warnings.append(w)
    if approval == "Automatic":
        warnings.append("CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL=Automatic: minor bumps roll the cluster without "
                        "block-reconcile")
    tls_value = _trim(values.get("CONFLUENT_OPERATOR_TLS_SOURCE_CLI")) or values.get("CONFLUENT_OPERATOR_TLS_SOURCE")
    _, w = resolve_choice("CONFLUENT_OPERATOR_TLS_SOURCE", tls_value, ("repo", "cfk"), "repo")
    if w:
        warnings.append(w)
    impl, w = resolve_choice("CONFLUENT_OPERATOR_SASL_IMPL", values.get("CONFLUENT_OPERATOR_SASL_IMPL"),
                             ("plain", "scram"), "plain")
    if w:
        warnings.append(w)
    _, w = resolve_choice("CONFLUENT_CONNECTOR_MANAGEMENT", values.get("CONFLUENT_CONNECTOR_MANAGEMENT"),
                          ("rest", "cr"), "rest")
    if w:
        warnings.append(w)
    image_source, w = resolve_choice("CONFLUENT_OPERATOR_IMAGE_SOURCE", values.get("CONFLUENT_OPERATOR_IMAGE_SOURCE"),
                                     ("tags", "csv"), "tags")
    if w:
        warnings.append(w)

    for name, default in (("CONFLUENT_OPERATOR_CSV_TIMEOUT", 600), ("CONFLUENT_OPERATOR_INSTALLPLAN_TIMEOUT", 300),
                          ("CONFLUENT_OPERATOR_KAFKA_TIMEOUT", 900), ("CONFLUENT_OPERATOR_COMPONENT_TIMEOUT", 600),
                          ("CONFLUENT_OPERATOR_CONNECT_TIMEOUT", 900)):
        v = _trim(values.get(name))
        if v and not v.isdigit():
            warnings.append(f"{name}='{v}' is not a number of seconds - using {default}")

    _, packages_errors = _parse_packages_per_ns(values.get("CONFLUENT_OPERATOR_PACKAGES_PER_NS"))
    errors.extend(packages_errors)

    # SASL (§8 D10, §15.6)
    sasl_on = _bool(values, "CONFLUENT_SASL_ENABLED", False)
    external_on = _bool(values, "CONFLUENT_EXTERNAL_KAFKA_ENABLED", False)
    if sasl_on:
        mech = _trim(values.get("CONFLUENT_SASL_MECHANISM"))
        if mech and mech.upper() != "PLAIN":
            errors.append(f"CONFLUENT_SASL_MECHANISM={mech}: operator mode needs PLAIN (the CFK components "
                          "authenticate with CFK's native SASL/PLAIN only)")
        scram_seen = False
        for name in ("CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS", "CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS"):
            mechs = _mechanisms(values.get(name))
            unknown = [m for m in mechs if m not in KNOWN_MECHANISMS]
            if unknown:
                errors.append(f"{name}: unknown mechanism(s) {','.join(unknown)} (allowed: {', '.join(KNOWN_MECHANISMS)})")
            if any(m.startswith("SCRAM-") for m in mechs):
                scram_seen = True
        if scram_seen and impl == "plain":
            errors.append(SCRAM_PLAIN_ERROR)
        if impl == "scram":
            warnings.append("SCRAM through configOverrides is documented by Confluent but outside Confluent Support: "
                            + " ".join(SCRAM_LINKS))
    if external_on and not sasl_on:
        errors.append("CONFLUENT_EXTERNAL_KAFKA_ENABLED=true needs CONFLUENT_SASL_ENABLED=true in operator mode "
                      "(the external listener always authenticates)")

    # Versions (§2.4)
    cfk_channel = _trim(values.get("CONFLUENT_OPERATOR_CHANNEL")) or operator_catalog(catalog).get("cfk_channel", "3.4")
    cfk_compat = compat(catalog).get("cfk", {}).get(_minor(cfk_channel))
    version = _trim(values.get("CONFLUENT_VERSION"))
    if image_source == "tags" and not _VERSION_RE.match(version):
        errors.append(f"CONFLUENT_VERSION='{version}' must be a concrete X.Y.Z image tag in operator mode "
                      "(CONFLUENT_OPERATOR_IMAGE_SOURCE=tags)")
    elif _VERSION_RE.match(version) and cfk_compat \
            and not _in_range(version, cfk_compat["cp_min"], cfk_compat["cp_max_exclusive"]):
        errors.append(f"CONFLUENT_VERSION={version} is outside what CFK {cfk_channel} supports "
                      f"({cfk_compat['cp_min']} up to, not including, {cfk_compat['cp_max_exclusive']})")
    if not cfk_compat:
        warnings.append(f"CONFLUENT_OPERATOR_CHANNEL={cfk_channel} has no compatibility data in the version catalog - "
                        "Confluent Platform and Control Center versions are not checked")
    if _bool(values, "CONFLUENT_INSTALL_CONTROL_CENTER", True):
        c3 = _trim(values.get("CONFLUENT_C3_VERSION"))
        if c3 and not _VERSION_RE.match(c3):
            errors.append(f"CONFLUENT_C3_VERSION='{c3}' must be a concrete X.Y.Z image tag in operator mode")
        elif c3 and cfk_compat and not _in_range(c3, cfk_compat["c3_min"], cfk_compat["c3_max_exclusive"]):
            errors.append(f"CONFLUENT_C3_VERSION={c3} is outside what CFK {cfk_channel} supports "
                          f"({cfk_compat['c3_min']} up to, not including, {cfk_compat['c3_max_exclusive']})")

    # KRaft (§2.3, item 13)
    kraft = _trim(values.get("CONFLUENT_KRAFT_REPLICAS"))
    if kraft:
        if not kraft.isdigit() or int(kraft) < 1 or int(kraft) % 2 == 0:
            errors.append(f"CONFLUENT_KRAFT_REPLICAS='{kraft}' must be an odd number >= 1")
        elif int(kraft) == 1:
            warnings.append("CONFLUENT_KRAFT_REPLICAS=1: a single KRaft controller has no redundancy")
    kraft_size = _trim(values.get("CONFLUENT_KRAFT_STORAGE_SIZE"))
    if kraft_size and not _SIZE_RE.match(kraft_size):
        errors.append(f"CONFLUENT_KRAFT_STORAGE_SIZE='{kraft_size}' must look like 10Gi (Mi, Gi or Ti)")

    if _bool(values, "CONFLUENT_AUTH_ENABLED", False) and _trim(values.get("CONFLUENT_AUTH_MODE")).lower() == "openshift":
        info.append("CONFLUENT_AUTH_MODE=openshift: Control Center sits behind the repo's oauth-proxy front proxy "
                    "(CFK has no OpenShift login)")
    if license_present is False:
        warnings.append("No CONFLUENT_LICENSE_KEY - Confluent Platform runs on the 30-day trial license.")
    if _bool(values, "CONFLUENT_MDS_ENABLED", False):
        info.append("MDS/RBAC in operator mode is phase 5 (unverified: V5, V21)")


def _check_flink(values, errors, warnings, info, catalog, flink_source):
    if _trim(values.get("CONFLUENT_CLUSTER_PLATFORM")).lower() == "kubernetes":
        errors.append("operator mode is OpenShift-only in v1")
    scope = _trim(values.get("FLINK_OLM_SCOPE"))
    if scope and scope.lower() != "own":
        errors.append(f"FLINK_OLM_SCOPE='{scope}': v1 supports own (OwnNamespace) only")
    approval, w = resolve_choice("FLINK_OLM_INSTALL_PLAN_APPROVAL", values.get("FLINK_OLM_INSTALL_PLAN_APPROVAL"),
                                 ("Manual", "Automatic"), "Manual")
    if w:
        warnings.append(w)
    if approval == "Automatic" and flink_source == "olm":
        warnings.append("FLINK_OLM_INSTALL_PLAN_APPROVAL=Automatic: minor bumps roll the cluster without "
                        "block-reconcile")
    cmf = _trim(values.get("FLINK_CMF_CHART_VERSION"))
    try:
        fko = fko_for_cmf(cmf, catalog)
    except KeyError:
        known = ", ".join(sorted(compat(catalog).get("cmf", {})))
        errors.append(f"FLINK_CMF_CHART_VERSION={cmf}: CMF {_minor(cmf)} has no cp-fko pairing in the version "
                      f"catalog (known CMF lines: {known})")
        fko = None
    channel = _trim(values.get("FLINK_OLM_CHANNEL"))
    if fko and channel and channel != fko["channel"] and flink_source == "olm":
        errors.append(f"FLINK_OLM_CHANNEL={channel} does not match CMF {cmf}, which needs cp-fko {fko['channel']} "
                      "(CMF/FKO lock, plan O7) - unset FLINK_OLM_CHANNEL or change FLINK_CMF_CHART_VERSION")
    app_version = _trim(values.get("FLINK_APPLICATION_VERSION"))
    vmax = operator_catalog(catalog).get("flink_version_max", "v2_2")
    if app_version:
        key, key_max = _flink_version_key(app_version), _flink_version_key(vmax)
        if key is None:
            errors.append(f"FLINK_APPLICATION_VERSION='{app_version}' is not of the form v<major>_<minor>")
        elif key_max and key > key_max:
            errors.append(f"FLINK_APPLICATION_VERSION={app_version} is above {vmax}, the newest flinkVersion the CFK "
                          "FlinkApplication CRD accepts")
    if _trim(values.get("PROJECT_CONFLUENT_FLINK")) == _trim(values.get("PROJECT_CONFLUENT_SERVER")):
        warnings.append("PROJECT_CONFLUENT_FLINK equals PROJECT_CONFLUENT_SERVER: both uninstallers keep the namespace")


def check(values, *, scope="all", license_present=None, catalog=None):
    """{"errors": [...], "warnings": [...], "info": [...]} for the operator-mode settings in <values>."""
    if scope not in ("platform", "flink", "all"):
        raise ValueError(f"scope must be platform, flink or all (got {scope!r})")
    errors, warnings, info = [], [], []
    deploy, w = resolve_deploy_mode(values.get("CONFLUENT_DEPLOY_MODE"))
    if w:
        warnings.append(w)
    flink_source, flink_warning = resolve_flink_operator_source(values.get("FLINK_OPERATOR_SOURCE"), deploy)
    cmf_mode, cmf_warning = resolve_flink_cmf_resource_mode(values.get("FLINK_CMF_RESOURCE_MODE"), flink_source)

    if scope in ("platform", "all") and deploy == "operator":
        _check_platform(values, errors, warnings, info, license_present, catalog)
    with_flink = flink_configured(values)
    if scope == "flink" and not with_flink:
        errors.append("the Flink add-on is not configured (PROJECT_CONFLUENT_FLINK and FLINK_CMF_CHART_VERSION are "
                      "needed) - run 0_flink_prepare_template_config.sh or the notebook")
    if scope in ("flink", "all") and with_flink:
        for warning in (flink_warning, cmf_warning):
            if warning:
                warnings.append(warning)
        if flink_source != "helm" or cmf_mode == "cfk":
            _check_flink(values, errors, warnings, info, catalog, flink_source)
    # one copy of each message, order kept (the Kubernetes refusal comes from both scopes)
    return {k: list(dict.fromkeys(v)) for k, v in (("errors", errors), ("warnings", warnings), ("info", info))}


# ---------------------------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------------------------
def _env_values():
    return {k: v for k, v in os.environ.items() if k in ALLOWED_VARS}


def _usage(msg=None):
    if msg:
        print(f"[ERROR] {msg}", file=sys.stderr)
    print(__doc__.split("CLI")[1], file=sys.stderr)
    return 1


def _opts(argv, names):
    """--name value pairs (only <names>); returns dict or raises ValueError."""
    out = {}
    i = 0
    while i < len(argv):
        key = argv[i]
        if not key.startswith("--") or key[2:] not in names or i + 1 >= len(argv):
            raise ValueError(f"bad argument {key!r}")
        out[key[2:]] = argv[i + 1]
        i += 2
    return out


def main(argv):
    if not argv:
        return _usage()
    cmd, rest = argv[0], argv[1:]
    values = _env_values()
    try:
        if cmd == "check":
            o = _opts(rest, {"scope", "license-present", "format"})
            lic = o.get("license-present")
            if lic not in (None, "true", "false"):
                raise ValueError("--license-present takes true or false")
            result = check(values, scope=o.get("scope", "all"),
                           license_present=None if lic is None else lic == "true")
            if o.get("format", "json") == "text":
                for prefix, key in (("[ERROR]", "errors"), ("[WARN]", "warnings"), ("[INFO]", "info")):
                    for msg in result[key]:
                        print(f"{prefix} {msg}")
            else:
                print(json.dumps(result, indent=2))
            return 0
        if cmd == "plan":
            o = _opts(rest, {"scope"})
            for ns, pkgs in plan_operator_targets(values, o.get("scope", "all")):
                print(ns, *pkgs)
            return 0
        if cmd == "resolve":
            if len(rest) != 1:
                raise ValueError("resolve takes one of deploy-mode, flink-source, cmf-mode")
            deploy, flink_source, cmf_mode = _modes(values)
            print({"deploy-mode": deploy, "flink-source": flink_source, "cmf-mode": cmf_mode}[rest[0]])
            return 0
        if cmd == "kraft-preset":
            if len(rest) != 1 or rest[0] not in KRAFT_PRESETS:
                raise ValueError(f"kraft-preset takes one of {', '.join(KRAFT_PRESETS)}")
            for name, value in kraft_preset(rest[0]).items():
                print(f'{name}="{value}"')
            return 0
        if cmd == "fko-for-cmf":
            if len(rest) != 1:
                raise ValueError("fko-for-cmf takes a CMF chart version")
            try:
                fko = fko_for_cmf(rest[0])
            except KeyError as exc:
                print(f"[ERROR] {exc.args[0]}", file=sys.stderr)
                return 1
            print(fko["channel"], fko["csv"])
            return 0
        if cmd == "subscription-env":
            o = _opts(rest, {"namespace", "package"})
            print(json.dumps(subscription_env(values, o["namespace"], o["package"])))
            return 0
        if cmd == "list-vars":
            print("\n".join(sorted(ALLOWED_VARS)))
            return 0
    except (ValueError, KeyError) as exc:
        return _usage(str(exc))
    return _usage(f"unknown command {cmd!r}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
