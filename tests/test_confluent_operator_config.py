"""confluent_operator_config.py: resolvers (with the zsh twins), checks, operator targets (contract §3.1, §3.3)."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src/helpers"))
import confluent_operator_config as cfg

HELPERS = REPO / "src/helpers/confluent_helpers.sh"
CFK, FKO = cfg.PKG_CFK, cfg.PKG_FKO

# (CONFLUENT_DEPLOY_MODE or None for unset, mode, warns)
DEPLOY_CASES = [
    (None, "operator", False), ("", "operator", False), ("   ", "operator", False),
    ("scripts", "scripts", False), (" Scripts ", "scripts", False), ("SCRIPTS", "scripts", False),
    ("operator", "operator", False), ("Operator\t", "operator", False),
    ("script", "operator", True), ("helm", "operator", True), ("operators", "operator", True),
]
# (FLINK_OPERATOR_SOURCE, deploy mode, source, warns)
FLINK_CASES = [
    (None, "operator", "olm", False), (None, "scripts", "helm", False), ("helm", "operator", "helm", False),
    (" OLM ", "scripts", "olm", False), ("existing", "operator", "existing", False), ("bogus", "scripts", "olm", True),
]
# (FLINK_CMF_RESOURCE_MODE, flink source, mode, warns)
CMF_CASES = [
    (None, "olm", "cfk", False), (None, "helm", "cli", False), ("CLI", "olm", "cli", False),
    ("cfk", "helm", "cfk", False), ("nope", "helm", "cli", True), ("nope", "existing", "cfk", True),
]


def _zsh(script, env):
    full = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/tmp")}
    full.update(env)
    return subprocess.run(["zsh", "-c", script], check=False, env=full, capture_output=True, text=True, timeout=30)


@pytest.mark.parametrize("value,mode,warns", DEPLOY_CASES)
def test_deploy_mode_python_and_zsh_agree(value, mode, warns):
    got, warning = cfg.resolve_deploy_mode(value)
    assert got == mode and bool(warning) == warns
    env = {} if value is None else {"CONFLUENT_DEPLOY_MODE": value}
    r = _zsh(f"source {HELPERS}; cf_resolve_deploy_mode; cf_resolve_deploy_mode; "
             "cf_is_operator_mode && echo yes || echo no", env)
    assert r.returncode == 0, r.stderr
    assert r.stdout.split() == [mode, mode, "yes" if mode == "operator" else "no"]
    if warns:
        # same text in both, printed once per process tree
        assert r.stderr.count("[WARN]") == 1
        assert r.stderr.strip() == f"[WARN] {warning}"
    else:
        assert r.stderr == ""


def test_deploy_mode_warning_is_once_per_process_tree():
    r = _zsh(f"source {HELPERS}; cf_resolve_deploy_mode >/dev/null; zsh -c 'source {HELPERS}; cf_is_operator_mode'",
             {"CONFLUENT_DEPLOY_MODE": "oops"})
    assert r.stderr.count("[WARN]") == 1


@pytest.mark.parametrize("value,deploy,source,warns", FLINK_CASES)
def test_flink_source_python_and_zsh_agree(value, deploy, source, warns):
    got, warning = cfg.resolve_flink_operator_source(value, deploy)
    assert got == source and bool(warning) == warns
    env = {"CONFLUENT_DEPLOY_MODE": deploy}
    if value is not None:
        env["FLINK_OPERATOR_SOURCE"] = value
    r = _zsh(f"source {HELPERS}; cf_flink_operator_source; cf_flink_is_olm && echo olm-ish || echo helm", env)
    assert r.stdout.split() == [source, "helm" if source == "helm" else "olm-ish"]
    assert ("[WARN]" in r.stderr) == warns


@pytest.mark.parametrize("value,source,mode,warns", CMF_CASES)
def test_cmf_mode_python_and_zsh_agree(value, source, mode, warns):
    got, warning = cfg.resolve_flink_cmf_resource_mode(value, source)
    assert got == mode and bool(warning) == warns
    env = {"FLINK_OPERATOR_SOURCE": source}
    if value is not None:
        env["FLINK_CMF_RESOURCE_MODE"] = value
    r = _zsh(f"source {HELPERS}; cf_flink_cmf_resource_mode; cf_flink_operator_mode && echo op || echo no", env)
    expect_op = source != "helm" or mode == "cfk"
    assert r.stdout.split() == [mode, "op" if expect_op else "no"]


def test_resolve_choice_is_case_insensitive_and_canonical():
    assert cfg.resolve_choice("X", "manual", ("Manual", "Automatic"), "Manual") == ("Manual", None)
    assert cfg.resolve_choice("X", "", ("Manual", "Automatic"), "Manual") == ("Manual", None)
    value, warning = cfg.resolve_choice("X", "sometimes", ("Manual", "Automatic"), "Manual")
    assert value == "Manual" and warning == "X='sometimes' is not Manual|Automatic - using Manual"


# ---------------------------------------------------------------------------------------------------------------
# plan_operator_targets
# ---------------------------------------------------------------------------------------------------------------
BASE = {"CONFLUENT_DEPLOY_MODE": "operator", "PROJECT_CONFLUENT_SERVER": "confluent"}
FLINK = {"PROJECT_CONFLUENT_FLINK": "confluent-flink", "FLINK_CMF_CHART_VERSION": "2.5.0"}


@pytest.mark.parametrize("extra,expected", [
    pytest.param({}, [("confluent", [CFK])], id="no-flink"),
    pytest.param(FLINK, [("confluent", [CFK, FKO]), ("confluent-flink", [CFK, FKO])], id="flink-olm"),
    pytest.param({**FLINK, "FLINK_OPERATOR_SOURCE": "helm"}, [("confluent", [CFK])], id="flink-helm"),
    pytest.param({**FLINK, "FLINK_OPERATOR_SOURCE": "existing"},
                 [("confluent", [CFK]), ("confluent-flink", [CFK])], id="flink-existing"),
    pytest.param({**FLINK, "PROJECT_CONFLUENT_FLINK": "confluent"}, [("confluent", [CFK, FKO])], id="shared-ns"),
    pytest.param({"CONFLUENT_OPERATOR_EXTRA_NAMESPACES": "team-a team-b"},
                 [("confluent", [CFK]), ("team-a", [CFK]), ("team-b", [CFK])], id="extras"),
    pytest.param({**FLINK, "CONFLUENT_OPERATOR_PACKAGES_PER_NS": f"confluent={CFK} other={FKO}"},
                 [("confluent", [CFK]), ("confluent-flink", [CFK, FKO]), ("other", [FKO])], id="per-ns-override"),
    pytest.param({**FLINK, "CONFLUENT_OPERATOR_INSTALL_IN_PLATFORM_NS": "false"},
                 [("confluent-flink", [CFK, FKO])], id="flink-ns-only"),
    pytest.param({**FLINK, "CONFLUENT_DEPLOY_MODE": "scripts", "FLINK_OPERATOR_SOURCE": "olm"},
                 [("confluent-flink", [CFK, FKO])], id="scripts-platform-olm-flink"),
])
def test_plan_operator_targets(extra, expected):
    assert cfg.plan_operator_targets({**BASE, **extra}) == expected


def test_plan_scope_flink_keeps_only_flink_namespaces():
    assert cfg.plan_operator_targets({**BASE, **FLINK}, scope="flink") == [("confluent-flink", [CFK, FKO])]


def test_subscription_env_day2_ops_only_in_the_cfk_namespace():
    values = {**BASE, **FLINK}
    assert cfg.subscription_env(values, "confluent-flink", CFK) == [{"name": "ENABLE_CMF_DAY2_OPS", "value": "true"}]
    assert cfg.subscription_env(values, "confluent", CFK) == []
    assert cfg.subscription_env(values, "confluent-flink", FKO) == []
    values["CONFLUENT_OPERATOR_RESTRICT_CROSS_NS_RESTCLASS"] = "true"
    names = [e["name"] for e in cfg.subscription_env(values, "confluent", CFK)]
    assert names == ["RESTRICT_CROSS_NAMESPACE_KAFKARESTCLASS_USAGE", "RESTRICT_CROSS_NAMESPACE_CMFRESTCLASS_USAGE"]


# ---------------------------------------------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------------------------------------------
GOOD = {**BASE, **FLINK, "CONFLUENT_VERSION": "8.4.0", "CONFLUENT_C3_VERSION": "2.7.0", "CONFLUENT_SASL_ENABLED": "true",
        "CONFLUENT_SASL_MECHANISM": "PLAIN", "CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS": "PLAIN",
        "CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS": "PLAIN", "CONFLUENT_KRAFT_REPLICAS": "3",
        "FLINK_APPLICATION_VERSION": "v2_0"}


def test_check_good_config_is_clean():
    r = cfg.check(GOOD, license_present=True)
    assert r == {"errors": [], "warnings": [], "info": []}


@pytest.mark.parametrize("change,kind,needle", [
    ({"CONFLUENT_DEPLOY_MODE": "bogus"}, "warnings", "CONFLUENT_DEPLOY_MODE='bogus' is not scripts|operator"),
    ({"CONFLUENT_CLUSTER_PLATFORM": "kubernetes"}, "errors", "operator mode is OpenShift-only in v1"),
    ({"CONFLUENT_OPERATOR_SOURCE": "helm"}, "errors", "reserved for Kubernetes mode (v1: olm|existing)"),
    ({"CONFLUENT_OPERATOR_SCOPE": "all"}, "errors", "v1 supports own (OwnNamespace) only"),
    ({"FLINK_OLM_SCOPE": "single"}, "errors", "FLINK_OLM_SCOPE='single'"),
    ({"CONFLUENT_SASL_MECHANISM": "SCRAM-SHA-512"}, "errors", "operator mode needs PLAIN"),
    ({"CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS": "PLAIN,SCRAM-SHA-512"}, "errors", cfg.SCRAM_PLAIN_ERROR),
    ({"CONFLUENT_OPERATOR_SASL_IMPL": "scram", "CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS": "PLAIN,SCRAM-SHA-512"},
     "warnings", "outside Confluent Support"),
    ({"CONFLUENT_VERSION": "latest"}, "errors", "must be a concrete X.Y.Z"),
    ({"CONFLUENT_VERSION": "7.5.3"}, "errors", "outside what CFK 3.4 supports"),
    ({"CONFLUENT_VERSION": "8.5.0"}, "errors", "outside what CFK 3.4 supports"),
    ({"CONFLUENT_C3_VERSION": "2.8.0"}, "errors", "CONFLUENT_C3_VERSION=2.8.0 is outside"),
    ({"CONFLUENT_KRAFT_REPLICAS": "2"}, "errors", "must be an odd number"),
    ({"CONFLUENT_KRAFT_REPLICAS": "1"}, "warnings", "no redundancy"),
    ({"CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL": "Automatic"}, "warnings", "without block-reconcile"),
    ({"CONFLUENT_OPERATOR_TLS_SOURCE": "vault"}, "warnings", "CONFLUENT_OPERATOR_TLS_SOURCE='vault'"),
    ({"CONFLUENT_SASL_ENABLED": "false", "CONFLUENT_EXTERNAL_KAFKA_ENABLED": "true"}, "errors",
     "needs CONFLUENT_SASL_ENABLED=true"),
    ({"FLINK_OLM_CHANNEL": "stable-v1.15"}, "errors", "CMF/FKO lock"),
    ({"FLINK_CMF_CHART_VERSION": "2.3.1"}, "errors", "CMF 2.3 has no cp-fko pairing"),
    ({"FLINK_APPLICATION_VERSION": "v2_4"}, "errors", "above v2_2"),
    ({"PROJECT_CONFLUENT_FLINK": "confluent"}, "warnings", "both uninstallers keep the namespace"),
    ({"CONFLUENT_AUTH_ENABLED": "true", "CONFLUENT_AUTH_MODE": "openshift"}, "info", "front proxy"),
    ({"CONFLUENT_MDS_ENABLED": "true"}, "info", "MDS/RBAC in operator mode is phase 5"),
    ({"CONFLUENT_OPERATOR_NAMESPACE": "x"}, "warnings", "CONFLUENT_OPERATOR_NAMESPACE is ignored"),
    ({"CONFLUENT_OPERATOR_PACKAGES_PER_NS": "confluent=kafka"}, "errors", "unknown package(s) kafka"),
])
def test_check_rules(change, kind, needle):
    r = cfg.check({**GOOD, **change}, license_present=True)
    assert any(needle in m for m in r[kind]), r


def test_check_license_warning_and_scripts_mode_skips_platform_rules():
    assert any("30-day trial" in w for w in cfg.check(GOOD, license_present=False)["warnings"])
    scripts = {**GOOD, "CONFLUENT_DEPLOY_MODE": "scripts", "CONFLUENT_SASL_MECHANISM": "SCRAM-SHA-512",
               "FLINK_OPERATOR_SOURCE": "helm"}
    assert cfg.check(scripts, license_present=False) == {"errors": [], "warnings": [], "info": []}


def test_check_kubernetes_refusal_reported_once_for_scope_all():
    r = cfg.check({**GOOD, "CONFLUENT_CLUSTER_PLATFORM": "kubernetes"}, scope="all", license_present=True)
    assert r["errors"].count("operator mode is OpenShift-only in v1") == 1


# ---------------------------------------------------------------------------------------------------------------
# presets, catalog, CLI
# ---------------------------------------------------------------------------------------------------------------
def test_kraft_presets_and_fko_pairs():
    assert cfg.kraft_preset("xsmall")["CONFLUENT_KRAFT_REPLICAS"] == "1"
    assert set(cfg.KRAFT_PRESETS) == {"xsmall", "small", "medium", "large"}
    assert all(set(p) == set(cfg.KRAFT_PRESETS["small"]) for p in cfg.KRAFT_PRESETS.values())
    assert cfg.fko_for_cmf("2.5.0") == {"channel": "stable-v1.16", "csv": "cp-fko.v1.16.1-cp1", "min_cfk": "3.4"}
    assert cfg.fko_for_cmf("2.4.2")["channel"] == "stable-v1.15"
    with pytest.raises(KeyError):
        cfg.fko_for_cmf("9.9.0")


def test_no_secret_names_in_allowed_vars():
    assert not [v for v in cfg.ALLOWED_VARS
                if v.endswith(("_PASSWORD", "_PASS", "_SECRET_KEY", "_ACCESS_KEY", "_LICENSE_KEY", "_TOKEN", "_CREDS"))]


def _cli(*args, env=None):
    full = {"PATH": "/usr/bin:/bin"}
    full.update(env or {})
    return subprocess.run([sys.executable, "-I", str(REPO / "src/helpers/confluent_operator_config.py"), *args],
                          check=False, env=full, capture_output=True, text=True, timeout=30)


def test_cli_commands():
    env = {**BASE, **FLINK}
    assert _cli("plan", env=env).stdout.splitlines() == [f"confluent {CFK} {FKO}", f"confluent-flink {CFK} {FKO}"]
    assert _cli("resolve", "cmf-mode", env=env).stdout.strip() == "cfk"
    assert _cli("fko-for-cmf", "2.5.0").stdout.strip() == "stable-v1.16 cp-fko.v1.16.1-cp1"
    assert 'CONFLUENT_KRAFT_REPLICAS="3"' in _cli("kraft-preset", "small").stdout
    out = _cli("check", "--scope", "platform", "--license-present", "true", env={**GOOD, "CONFLUENT_KRAFT_REPLICAS": "4"})
    assert json.loads(out.stdout)["errors"] == ["CONFLUENT_KRAFT_REPLICAS='4' must be an odd number >= 1"]
    # a secret in the environment is never read (not in ALLOWED_VARS)
    out = _cli("check", "--scope", "platform", "--license-present", "true", "--format", "text",
               env={**GOOD, "CONFLUENT_LICENSE_KEY": "s3cr3t"})
    assert "s3cr3t" not in out.stdout + out.stderr and out.returncode == 0
    assert _cli("kraft-preset", "huge").returncode == 1
    assert _cli("bogus").returncode == 1
