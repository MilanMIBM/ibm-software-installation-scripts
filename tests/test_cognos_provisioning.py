"""Validate provisioning locally; all cluster and create operations are mocked."""

import json
import os
import stat
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src/helpers"))
import cognos_provisioning as cognos
import db2_provisioning as db2
from cognos_content_store import Settings, parse_snapshot, plan
from test_cognos_content_store import catalog

from tui.common.state import State
from tui.instance_manager.model import Instance


def args(tmp_path):
    return cognos.parser().parse_args([
        "--name", "Cognos CLI", "--namespace", "new-namespace", "--version", "30.0.4",
        "--file-class", "file", "--block-class", "block", "--content-connection", "content store",
        "--audit-connection", "audit store", "--size", "small", "--output", str(tmp_path / "payload.json"),
        "--db2-instance", "db2-dedicated", "--db2-user", "cognos_svc",
    ])


def environment(**changes):
    return {
        "DB2_INSTANCE_NAME": "db2-new", "DB2_Version": "12.1.3.0-cn3-amd64",
        "PROJECT_CPD_INST_OPERANDS": "new-namespace", "IMAGE_PULL_SECRET": "pull-secret",
        "STG_CLASS_BLOCK": "block", "STG_CLASS_FILE": "file", "DB2_PASSWORD": "test-'$\\\"secret",
        "DB2_4K_DEVICE_SUPPORT": "ON", "DB2_CPU_LIMIT": "2", "DB2_MEMORY_LIMIT": "8Gi", **changes,
    }


def volumes(payload):
    params = payload["create_arguments"]["parameters"]
    return params["environment"]["databases"][0]["storage"] + params["storage"]


def test_generic_db2_defaults_and_storage_semantics():
    payload = db2.build_payload(environment())
    params = payload["create_arguments"]["parameters"]
    assert params["environment"]["databases"][0]["settings"] == {"dftPageSize": "16384"}
    assert params["environment"]["instance"]["password"]["value"] == environment()["DB2_PASSWORD"]
    assert params["environment"]["instance"]["registry"]["DB2_4K_DEVICE_SUPPORT"] == "ON"
    for volume in volumes(payload):
        name, spec = volume["name"], volume["spec"]
        assert spec["resources"]["requests"]["storage"] == "30Gi"
        assert spec["accessModes"] == (["ReadWriteOnce"] if name in {"data", "activelogs", "tempts"} else ["ReadWriteMany"])
        assert spec["storageClassName"] == ("block" if name in {"data", "activelogs"} else "file")
    assert "DB2_INLIST_TO_NLJN" not in params["environment"]["instance"]["registry"]


def test_independent_sizes_and_shared_fallback():
    env = environment(DB2_STORAGE_CLAIM="40", **{f"DB2_{v.upper()}_STORAGE_GI": str(i + 10) for i, v in enumerate(db2.VOLUMES)})
    assert [v["spec"]["resources"]["requests"]["storage"] for v in volumes(db2.build_payload(env))] == [f"{i + 10}Gi" for i in range(6)]
    del env["DB2_BACKUP_STORAGE_GI"]
    assert db2.configuration(env)[0]["backup"] == "40Gi"


@pytest.mark.parametrize("value", ["0", "-1", "1.5", "10Gi", "", "$(touch bad)", " 30"])
def test_invalid_size_rejected(value):
    with pytest.raises(ValueError):
        db2.configuration(environment(DB2_DATA_STORAGE_GI=value))


def test_cognos_db2_profile_only_changes_required_settings():
    generic = db2.build_payload(environment())
    profile = db2.build_payload(environment(DB2_PROFILE="cognos"))
    env = generic["create_arguments"]["parameters"]["environment"]
    env["databases"][0]["settings"]["dftPageSize"] = "32768"
    env["databases"][0]["settings"]["codeset"] = "UTF-8"
    env["instance"]["registry"]["DB2_INLIST_TO_NLJN"] = "YES"
    assert generic == profile
    with pytest.raises(ValueError):
        db2.configuration(environment(DB2_PROFILE="unknown"))
    with pytest.raises(ValueError):
        db2.configuration(environment(DB2_INSTANCE_NAME="../existing"))


def test_32k_validation_rejects_incompatible_or_missing_initial_objects():
    snap = parse_snapshot(catalog())
    settings = Settings("BLUDB", "COGNOS_SVC", "COGNOS_SVC", require_32k=True)
    for name in ("SYSCATSPACE", "TEMPSPACE1"):
        snap.spaces[name] = (32768, "T", "IBMDEFAULTBP")
    assert plan(snap, settings).ready
    for name in ("SYSCATSPACE", "USERSPACE1", "TEMPSPACE1"):
        original = snap.spaces[name]
        snap.spaces[name] = (16384, *original[1:])
        assert plan(snap, settings).errors
        snap.spaces[name] = original
    snap.pools["IBMDEFAULTBP"] = (16384, 49800)
    assert plan(snap, settings).errors
    del snap.pools["IBMDEFAULTBP"]
    result = plan(snap, settings)
    assert result.errors
    assert not any("CREATE BUFFERPOOL IBMDEFAULTBP" in s for s in result.statements)


def test_cognos_payload_matches_ibm_fields_and_safe_json(tmp_path, monkeypatch):
    options = args(tmp_path)
    options.fips = True
    monkeypatch.setenv("COGNOS_CONTENT_CONNECTION_PROPS", "key=test-'$\\\"value")
    payload = cognos.build_payload(options)
    assert payload["addon_type"] == "cognos-analytics-app"
    assert payload["addon_version"] == "30.0.4"
    assert payload["namespace"] == "new-namespace"
    params = payload["create_arguments"]["parameters"]
    assert params == {
        "fileStorageClass": "file", "blockStorageClass": "block", "fips": "FIPS 140-2",
        "planSize": "small", "audit": "audit store", "auditProperty": "",
        "cs": "content store", "csProperty": "key=test-'$\\\"value",
    }
    db2.write_payload(options.output, payload)
    assert json.loads(options.output.read_text()) == payload
    assert stat.S_IMODE(options.output.stat().st_mode) == 0o600
    with pytest.raises(FileExistsError):
        db2.write_payload(options.output, {})
    target = tmp_path / "symlink"
    target.symlink_to(options.output)
    with pytest.raises(FileExistsError):
        db2.write_payload(target, {})


def test_render_is_offline_and_does_not_print_properties(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("COGNOS_CONTENT_CONNECTION_PROPS", "password=do-not-print")
    options = args(tmp_path)
    with patch.object(cognos, "provision", side_effect=AssertionError("must be offline")):
        assert cognos.main([
            "--name", options.name, "--namespace", options.namespace, "--version", options.version,
            "--file-class", "file", "--block-class", "block", "--content-connection", "content",
            "--audit-connection", "content", "--size", "xsmall", "--output", str(options.output),
        ]) == 0
    assert "do-not-print" not in capsys.readouterr().out


def test_cli_failure_does_not_echo_vendor_credentials(tmp_path, capsys):
    with patch("tui.common.kube.Kube"), patch.object(cognos, "provision", side_effect=RuntimeError("password=do-not-print")):
        result = cognos.main([
            "--apply", "--name", "new-cognos", "--namespace", "new-namespace", "--version", "30.0.4",
            "--file-class", "file", "--block-class", "block", "--content-connection", "content",
            "--audit-connection", "content", "--size", "small", "--output", str(tmp_path / "submitted.json"),
        ])
    assert result == 1
    output = capsys.readouterr()
    assert "do-not-print" not in output.out + output.err
    assert "No automatic retry" in output.err


def provider():
    mock = Mock()
    itype = SimpleNamespace(key="cpd:cognos-analytics-app", crd={"name": "cognos"}, versions=["30.0.4"], list_path=lambda ns: f"/cognos/{ns}")
    mock.discover_types.return_value = [itype]
    mock.cluster.list.return_value = []
    mock.cli.list_instances.return_value = []
    return mock, itype


@pytest.mark.parametrize("inventory", ["cr", "platform", "unknown-namespace", "name-collision", "version"])
def test_preflight_refuses_existing_or_unverifiable_targets(tmp_path, inventory):
    mock, itype = provider()
    options = args(tmp_path)
    if inventory == "cr":
        mock.cluster.list.return_value = [{"metadata": {"name": "existing"}}]
    elif inventory == "version":
        itype.versions = ["30.0.0"]
    else:
        record = {"service_type": cognos.ADDON, "namespace": options.namespace, "display_name": "existing"}
        if inventory == "unknown-namespace":
            del record["namespace"]
        if inventory == "name-collision":
            record.update(namespace="other", display_name=options.name)
        mock.cli.list_instances.return_value = [record]
    with pytest.raises(ValueError):
        cognos.preflight(mock, options)
    mock.cli.run.assert_not_called()


def test_permission_failure_is_not_interpreted_as_empty_inventory(tmp_path):
    mock, _ = provider()
    mock.cluster.list.side_effect = RuntimeError("forbidden")
    with pytest.raises(RuntimeError):
        cognos.preflight(mock, args(tmp_path))
    mock.cli.run.assert_not_called()


def test_cognos_registry_without_cr_kind_uses_installed_instance_crd(tmp_path):
    mock, itype = provider()
    itype.crd = None
    mock.cluster.get_crd.return_value = {"spec": {
        "group": "ca.cpd.ibm.com", "scope": "Namespaced",
        "names": {"kind": "CAServiceInstance", "plural": "caserviceinstances"},
        "versions": [{"name": "v1", "served": True, "storage": True}],
    }}
    resolved = cognos.preflight(mock, args(tmp_path))
    assert resolved.kind == "CAServiceInstance"
    assert resolved.versions == ["30.0.4"]
    mock.cluster.list.assert_called_once_with("/apis/ca.cpd.ibm.com/v1/namespaces/new-namespace/caserviceinstances", cache=False)
    mock.cluster.get_crd.return_value = None
    with pytest.raises(ValueError, match="CRD"):
        cognos.preflight(mock, args(tmp_path))


def test_apply_requires_ready_32k_store_and_never_applies_sql(tmp_path):
    mock, _ = provider()
    options = args(tmp_path)
    with patch.object(cognos, "prepare", return_value=2) as check, pytest.raises(ValueError, match="not ready"):
        cognos.provision(mock, options, cognos.build_payload(options))
    assert check.call_args.args[1].require_32k
    assert check.call_args.args[2] is False
    mock.cli.run.assert_not_called()
    assert not options.output.exists()


def test_create_is_submitted_once_and_failure_retains_private_payload(tmp_path):
    mock, _ = provider()
    options = args(tmp_path)
    mock.cli.run.side_effect = subprocess.TimeoutExpired("cpd-cli", 600)
    with patch.object(cognos, "prepare", return_value=0), patch.object(cognos, "wait_ready") as wait, pytest.raises(subprocess.TimeoutExpired):
        cognos.provision(mock, options, cognos.build_payload(options))
    assert mock.cli.run.call_count == 1
    assert options.output.exists()
    assert stat.S_IMODE(options.output.stat().st_mode) == 0o600
    wait.assert_not_called()
    assert mock.cli.run.call_args.args == ("service-instance", "create", f"--from-source={options.output.resolve()}")


def test_wait_only_never_creates_or_prepares_store(tmp_path):
    mock, _ = provider()
    options = args(tmp_path)
    options.wait_only = True
    with patch.object(cognos, "prepare") as prepare, patch.object(cognos, "wait_ready") as wait:
        cognos.provision(mock, options, cognos.build_payload(options))
    prepare.assert_not_called()
    mock.cli.run.assert_not_called()
    wait.assert_called_once()
    assert not options.output.exists()


@pytest.mark.parametrize("link", [
    {"zenServiceInstanceId": "1234"},
    {"podTemplate": {"db2u": {"labels": {"icpdsupport/serviceInstanceId": "1234"}}}},
])
def test_db2_wait_matches_platform_id_and_requires_both_states(link):
    cli = Mock()
    cli.list_instances.side_effect = [
        [{"id": 1234, "display_name": "new-db", "service_type": "db2oltp", "provision_status": "PROVISION_IN_PROGRESS"}],
        [{"id": 1234, "display_name": "new-db", "service_type": "db2oltp", "provision_status": "PROVISIONED"}],
    ]
    objects = {"items": [
        {"metadata": {"name": "unrelated", "labels": {"icpdsupport/serviceInstanceId": "5678"}}, "status": {"state": "Ready"}},
        {"metadata": {"name": "actual-generated-name"}, "spec": link, "status": {"state": "Ready"}},
    ]}
    with patch.object(db2.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=json.dumps(objects))) as run, patch.object(db2.time, "sleep") as sleep:
        db2.wait_ready(cli, "new-db", "new-namespace")
    assert cli.list_instances.call_count == 2
    sleep.assert_called_once_with(10)
    assert run.call_args.args[0] == ["oc", "get", "db2uinstances", "-n", "new-namespace", "-o", "json"]


def test_db2_wait_failure_and_timeout_never_create():
    cli = Mock()
    cli.list_instances.return_value = [{"display_name": "new-db", "service_type": "db2oltp", "provision_status": "PROVISION_FAILED"}]
    with pytest.raises(ValueError, match="failed"):
        db2.wait_ready(cli, "new-db", "new-namespace")
    cli.list_instances.return_value = []
    with patch.object(db2.time, "monotonic", side_effect=[0, 0, 2]), patch.object(db2.time, "sleep"), pytest.raises(ValueError, match="timed out"):
        db2.wait_ready(cli, "new-db", "new-namespace", timeout=1)
    cli.run.assert_not_called()


def test_existing_db2_display_name_is_rejected():
    cli = Mock()
    cli.list_instances.return_value = [{"display_name": "existing", "service_type": "db2oltp"}]
    with pytest.raises(ValueError, match="already exists"):
        db2.ensure_new(cli, "existing")
    cli.run.assert_not_called()


def test_readiness_requires_cr_workloads_and_platform(tmp_path):
    options = args(tmp_path)
    mock, itype = provider()
    inst = Instance(type_key=itype.key, name="ca-test", namespace=options.namespace, uid="test", obj={"kind": "CA", "status": {"state": "Completed"}}, display_name=options.name)
    inst.meta = {"zen": {"provision_status": "PROVISIONED"}}
    from tui.cr_dashboard.model import Phase
    from tui.instance_manager.ops import planner

    def watch(_provider, _itype, done, _timeout, _log):
        assert done([])[0] is False
        assert done([inst])[0] is False
        inst.meta["rollout"] = SimpleNamespace(state=State.HEALTHY, ready=0, total=0)
        assert done([inst])[0] is False
        inst.meta["rollout"] = SimpleNamespace(state=State.HEALTHY, ready=10, total=10)
        assert done([inst])[0] is True
        inst.meta["zen"]["provision_status"] = "PROVISION_IN_PROGRESS"
        assert done([inst])[0] is False
        inst.meta["zen"]["provision_status"] = "PROVISION_FAILED"
        with pytest.raises(ValueError, match="failed"):
            done([inst])
        return False

    with patch.object(planner, "watch", side_effect=watch), patch("tui.cr_dashboard.status_normalize.normalize", return_value=SimpleNamespace(phase=Phase.COMPLETED)), pytest.raises(ValueError, match="timed out"):
        cognos.wait_ready(mock, itype, options.name, 1)


@pytest.mark.parametrize("wait_status", [0, 1])
def test_db2_launcher_preserves_credentials_and_propagates_readiness_failure(tmp_path, wait_status):
    import shutil

    root = Path(__file__).resolve().parents[1]
    launcher = tmp_path / "scripts/provision/db2.sh"
    launcher.parent.mkdir(parents=True)
    shutil.copy(root / "scripts/install_cloud_pak_for_data/4.5_service_instance_setups/4.5_provision_db2.sh", launcher)
    helpers = tmp_path / "src/helpers"
    helpers.mkdir(parents=True)
    for name in ("common_helpers.sh", "db2_provisioning.py"):
        shutil.copy(root / "src/helpers" / name, helpers / name)
    cli_module = Path("tui/instance_manager/providers/cpd/cpdcli.py")
    (tmp_path / "src" / cli_module).parent.mkdir(parents=True)
    shutil.copy(root / "src" / cli_module, tmp_path / "src" / cli_module)
    (tmp_path / "env_bootstrap.sh").write_text('export _CP4D_REPO_ROOT="${TEST_REPO_ROOT}"\nexport OC_LOGIN=":"\n')
    binary_dir = tmp_path / "bin"
    binary_dir.mkdir()
    for name, script in {
        "oc": """#!/usr/bin/env python3
import json, sys
if sys.argv[2] == "db2uinstances":
    print(json.dumps({"items": [{"metadata": {"name": "generated-db2-1234", "labels": {"icpdsupport/serviceInstanceId": "1234"}}, "status": {"state": "Ready"}}]}))
""",
        "cpd-cli": """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
calls = Path(os.environ["CLI_CALLS"])
with calls.open("a") as stream:
    stream.write(" ".join(sys.argv[1:]) + "\\n")
if sys.argv[2] == "list":
    records = []
    if "service-instance create" in calls.read_text():
        records = [{"id": "1234", "display_name": "db2-new", "service_type": "db2oltp", "provision_status": "PROVISION_FAILED" if os.environ["WAIT_STATUS"] == "1" else "PROVISIONED"}]
    print(json.dumps({"service_instances": records}))
""",
        "sleep": '#!/bin/zsh\nexit 0\n',
    }.items():
        path = binary_dir / name
        path.write_text(script)
        path.chmod(0o755)
    output = tmp_path / "service_instances"
    output.mkdir()
    cli_calls = tmp_path / "calls"
    run_env = {
        **os.environ, **environment(DB2_PROFILE="cognos", DB2_DATA_STORAGE_GI="50", DB2_BACKUP_STORAGE_GI="120"),
        "PATH": str(binary_dir) + os.pathsep + os.environ["PATH"],
        "TEST_REPO_ROOT": str(tmp_path), "IMAGE_ARCH": "amd64", "CPD_USERNAME": "test", "SERVICE_INSTANCE_VAULT_STORE": "false",
        "SERVICE_INSTANCE_FILE_DIR": str(output), "CONFIG_DIR": str(tmp_path / "configs"),
        "CLI_CALLS": str(cli_calls), "WAIT_STATUS": str(wait_status), "CPD_CLI": str(binary_dir / "cpd-cli"),
    }
    for key in ("_COMMON_HELPERS_LOADED", "DB2_STORAGE_CLAIM", "DB2_VERSION"):
        run_env.pop(key, None)
    response = subprocess.run(["zsh", str(launcher)], env=run_env, text=True, capture_output=True, check=False)
    assert response.returncode == wait_status, response.stdout + response.stderr
    payload = json.loads((output / "db2-new.json").read_text())
    sizes = {v["name"]: v["spec"]["resources"]["requests"]["storage"] for v in volumes(payload)}
    assert sizes == {**dict.fromkeys(db2.VOLUMES, "30Gi"), "data": "50Gi", "backup": "120Gi"}
    assert payload["create_arguments"]["parameters"]["environment"]["databases"][0]["settings"]["dftPageSize"] == "32768"
    credentials = next((tmp_path / "configs").rglob("*-instance_details.sh"))
    assert stat.S_IMODE(credentials.stat().st_mode) == 0o600
    assert "_PASSWORD=" in credentials.read_text()
    assert run_env["DB2_PASSWORD"] not in response.stdout + response.stderr + cli_calls.read_text()
    assert ("service-instance status" in cli_calls.read_text()) is (wait_status == 0)
    previous = credentials.read_text()
    retry = subprocess.run(["zsh", str(launcher)], env=run_env, text=True, capture_output=True, check=False)
    assert retry.returncode != 0
    assert credentials.read_text() == previous
