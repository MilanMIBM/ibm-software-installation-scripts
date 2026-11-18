"""WP-G: private-registry mirroring hooks in the Confluent operator install mode (contract §5.7, §7.1).

Lean: the hooks run in throwaway sandbox repos (tests/mcm_harness.py) with a fake config, never against
configs/. They write their results to fd 3, which each run captures. The scripts-mode baseline of the
segment-0 hook comes from `git show 0efad5f:<path>`.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))

from mcm_harness import make_sandbox

BASE_REF = "0efad5f"
SEG0 = "scripts/private_registry_mirroring/0_initial_setup/installs/confluent.sh"
MAP = "scripts/private_registry_mirroring/1_map_content/installs/confluent.sh"
EXTRAS = [
    "pyproject.toml",
    "src/helpers/version_catalog.json",
    "scripts/private_registry_mirroring/0_initial_setup/installs",
    "scripts/private_registry_mirroring/1_map_content/installs",
]
DIGEST = "sha256:" + "ab" * 32

# A scripts-mode install with every component and the Flink add-on (what prefill reads).
PLATFORM = {
    "PROJECT_CONFLUENT_SERVER": "confluent",
    "CONFLUENT_VERSION": "8.2.0",
    "CONFLUENT_C3_VERSION": "2.5.0",
    "CONFLUENT_INSTALL_SCHEMA_REGISTRY": "true",
    "CONFLUENT_INSTALL_CONNECT": "true",
    "CONFLUENT_INSTALL_KSQLDB": "true",
    "CONFLUENT_INSTALL_REST_PROXY": "true",
    "CONFLUENT_INSTALL_CONTROL_CENTER": "true",
    "CONFLUENT_AUTH_ENABLED": "true",
    "CONFLUENT_AUTH_MODE": "basic",
    "CONFLUENT_MDS_ENABLED": "true",
    "CONFLUENT_MDS_USER_STORE": "LDAP",
    "PROJECT_CONFLUENT_FLINK": "confluent-flink",
    "FLINK_CMF_CHART_VERSION": "2.5.0",
}


def git_show(path):
    return subprocess.run(["git", "show", f"{BASE_REF}:{path}"], cwd=REPO, capture_output=True, text=True,
                          check=True).stdout


@pytest.fixture
def sb():
    with make_sandbox(extra=EXTRAS) as box:
        os.symlink(REPO / ".venv", box.repo / ".venv")
        yield box


def fd3(sb, hook, *args, env=None):
    """Runs a hook with the Confluent config loaded; returns (fd 3 text, completed process)."""
    out = sb.root / "fd3.out"
    result = sb.run_zsh(f'zsh {hook} {" ".join(args)} 3>"{out}"\n',
                        env={"ENV_TARGET": "confluent", "ENV_SETUP_QUIET": "1", **(env or {})})
    assert result.returncode == 0, result.stdout + result.stderr
    return out.read_text(), result


def prefill(sb, hook=SEG0):
    text, _ = fd3(sb, hook, "prefill")
    return dict(line.split("\t", 1) for line in text.splitlines())


def test_scripts_mode_prefill_is_byte_identical_to_the_baseline(sb):
    sb.write_config("confluent", extra={**PLATFORM, "CONFLUENT_DEPLOY_MODE": "scripts"})
    base = sb.repo / SEG0.replace("confluent.sh", "confluent_baseline.sh")
    base.write_text(git_show(SEG0))
    new_text, _ = fd3(sb, SEG0, "prefill")
    base_text, _ = fd3(sb, base.relative_to(sb.repo), "prefill")
    assert new_text == base_text
    assert "flink-operator," in new_text and "cfk-operator" not in new_text and "operators" not in new_text


def test_operator_mode_prefill_adds_the_operator_components(sb):
    sb.write_config("confluent", extra=PLATFORM)            # no CONFLUENT_DEPLOY_MODE = operator mode
    values = prefill(sb)
    comps = values["MIRROR_CONFLUENT_COMPONENTS"].split(",")
    assert comps[:comps.index("cfk-operator")] == ["broker", "schema-registry", "connect", "ksqldb", "rest-proxy",
                                                   "control-center", "c3-gateway", "ldap"]
    assert "flink-operator-olm" in comps and "flink-operator" not in comps and "flink-cert-manager" not in comps
    assert {"flink-cmf", "flink-runtime", "flink-sql"} <= set(comps)
    assert values["MIRROR_CONFLUENT_CONTENT"] == "images,charts,operators"

    # Flink kept on the Helm operator: the chart component stays, CFK is still prefilled.
    sb.write_config("confluent", extra={**PLATFORM, "FLINK_OPERATOR_SOURCE": "helm"})
    comps = prefill(sb)["MIRROR_CONFLUENT_COMPONENTS"].split(",")
    assert "flink-operator" in comps and "flink-operator-olm" not in comps and "cfk-operator" in comps


def test_components_catalog_lists_the_new_components(sb):
    text, _ = fd3(sb, SEG0, "components", env={"PREG_NO_ENV": "1"})
    ids = [line.split("\t")[1] for line in text.splitlines()]
    assert {"cfk-operator", "flink-operator-olm"} <= set(ids)
    conf = (REPO / "scripts/private_registry_mirroring/0_initial_setup/installs/confluent.conf").read_text()
    assert 'INSTALL_CONTENT_KINDS="images charts connectors files operators"' in conf


def test_map_emits_the_operator_packages_and_the_init_image(sb):
    sb.write_config("confluent", extra=PLATFORM)
    env = {"MIRROR_CONFLUENT_COMPONENTS": "broker,cfk-operator,flink-operator-olm",
           "MIRROR_CONFLUENT_CONTENT": "images,operators"}
    text, result = fd3(sb, MAP, "map", env=env)
    items = [json.loads(line) for line in text.splitlines()]
    operators = [i for i in items if i["kind"] == "operator"]
    assert operators == [
        {"kind": "operator", "catalog": "certified-operators", "package": "confluent-for-kubernetes",
         "channel": "3.4", "component": "cfk-operator", "scope": "shared"},
        {"kind": "operator", "catalog": "certified-operators", "package": "cp-fko",
         "channel": "stable-v1.16", "component": "flink-operator-olm", "scope": "shared"},
    ]
    images = [(i["source"], i["component"]) for i in items if i["kind"] == "image"]
    assert images == [("docker.io/confluentinc/cp-server:8.2.0", "broker"),
                      ("docker.io/confluentinc/confluent-init-container:3.4.0", "cfk-operator")]
    assert "MIRROR_CONFLUENT_OPERATOR_DIGEST is empty" in result.stdout + result.stderr

    # Config values win; the CMF 2.4 line derives cp-fko stable-v1.15; a digest adds the operator image.
    sb.write_config("confluent", extra={**PLATFORM, "FLINK_CMF_CHART_VERSION": "2.4.2",
                                        "CONFLUENT_OPERATOR_CHANNEL": "3.5",
                                        "CONFLUENT_OPERATOR_INIT_IMAGE": "registry.example/ci:9"})
    text, _ = fd3(sb, MAP, "map", env={**env, "MIRROR_CONFLUENT_OPERATOR_DIGEST": DIGEST})
    items = [json.loads(line) for line in text.splitlines()]
    assert [(i["package"], i["channel"]) for i in items if i["kind"] == "operator"] == [
        ("confluent-for-kubernetes", "3.5"), ("cp-fko", "stable-v1.15")]
    assert [i["source"] for i in items if i["component"] == "cfk-operator" and i["kind"] == "image"] == [
        "registry.example/ci:9", f"docker.io/confluentinc/confluent-operator@{DIGEST}"]


def test_map_refuses_a_malformed_operator_digest_and_ignores_operators_in_scripts_selection(sb):
    sb.write_config("confluent", extra=PLATFORM)
    out = sb.root / "fd3.out"
    result = sb.run_zsh(f'zsh {MAP} map 3>"{out}"\n', env={
        "ENV_TARGET": "confluent", "ENV_SETUP_QUIET": "1", "MIRROR_CONFLUENT_COMPONENTS": "cfk-operator",
        "MIRROR_CONFLUENT_CONTENT": "images", "MIRROR_CONFLUENT_OPERATOR_DIGEST": "latest"})
    assert result.returncode != 0
    assert "is not a sha256 digest" in result.stdout + result.stderr

    # A scripts-mode selection (no operator components) emits no operator line, even with "operators".
    text, _ = fd3(sb, MAP, "map", env={"MIRROR_CONFLUENT_COMPONENTS": "broker,flink-operator",
                                       "MIRROR_CONFLUENT_CONTENT": "operators"})
    assert '"kind":"operator"' not in text


# ---------------------------------------------------------------------------------------------
# x_confluent_cr_dashboard.sh (contract §5.7): the launcher only builds the dashboard command line.
# ---------------------------------------------------------------------------------------------
DASH = "scripts/install_confluent_platform/x_confluent_cr_dashboard.sh"
DASH_EXTRAS = [DASH, "scripts/install_confluent_platform/confluent_cr_dashboard_profile.yaml"]


@pytest.fixture
def dash_sb():
    with make_sandbox(extra=DASH_EXTRAS) as box:
        uv = box.bin / "uv"            # fake uv: records its argv, one per line
        uv.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "${UV_ARGS_FILE:?}"\n')
        uv.chmod(0o755)
        yield box


def _dash(sb, *args):
    argv_file = sb.root / "uv.args"
    argv_file.unlink(missing_ok=True)
    result = sb.run_script(DASH, args=args, env={"ENV_TARGET": "confluent", "ENV_SETUP_QUIET": "1",
                                                 "UV_ARGS_FILE": str(argv_file)})
    return result, (argv_file.read_text().splitlines() if argv_file.exists() else None)


def test_dashboard_launcher_qualifies_the_cfk_kinds_and_adds_the_flink_namespace(dash_sb):
    dash_sb.write_config("confluent", extra=PLATFORM)        # operator mode, Flink CMF resources as CFK CRs
    result, argv = _dash(dash_sb, "--once")
    assert result.returncode == 0, result.stdout + result.stderr
    kinds = ["Kafka", "KRaftController", "SchemaRegistry", "Connect", "KsqlDB", "KafkaRestProxy", "ControlCenter",
             "FlinkEnvironment", "FlinkApplication"]
    profile = str(dash_sb.repo / DASH_EXTRAS[1])
    assert argv == ["run", "--quiet", "python", "-m", "tui.cr_dashboard", "cr",
                    *[f"{k}.platform.confluent.io" for k in kinds],
                    "-n", "confluent", "-n", "confluent-flink", "--no-exec", "--profile-file", profile, "--once"]
    assert {c[0] for c in dash_sb.calls("oc")} <= {"whoami", "login"}   # read-only: the login only

    # Flink on the CMF CLI: no Flink kinds, no Flink namespace.
    dash_sb.write_config("confluent", extra={**PLATFORM, "FLINK_CMF_RESOURCE_MODE": "cli"})
    _, argv = _dash(dash_sb)
    assert "FlinkEnvironment.platform.confluent.io" not in argv and "confluent-flink" not in argv


def test_dashboard_launcher_refuses_scripts_mode_without_cluster_calls(dash_sb):
    dash_sb.write_config("confluent", extra={**PLATFORM, "CONFLUENT_DEPLOY_MODE": "scripts"})
    result, argv = _dash(dash_sb)
    assert result.returncode == 1 and argv is None
    assert "[ERROR]" in result.stderr and "1.2_confluent_status.sh" in result.stderr
    assert dash_sb.calls("oc") == []
