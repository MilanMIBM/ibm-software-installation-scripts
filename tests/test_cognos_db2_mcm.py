"""Db2 and Cognos provisioning launchers with multi-cluster management on and off.

The launchers 4.5_provision_db2.sh and 4.5_provision_cognos.sh run through the real env_bootstrap.sh in
tests/mcm_harness.py sandboxes (temp HOME, temp repo copy, fake oc / cpd-cli / uv). Checked:
  - with a delineated cluster, payloads land under configs/clusters/<name>/service_instances and instance details
    under configs/clusters/<name>/cp4d_config; nothing lands in the flat service_instances/ or configs/cp4d_config/
  - --target-clusters a,b gives each cluster its own payload, details and cpd-cli profile HOME
  - the multi-cluster flags never reach the Python argument parsers
  - mode off keeps the flat paths main used
"""

import json
import stat
import sys

import pytest
from mcm_harness import make_sandbox
from test_cognos_provisioning import volumes
from test_mcm_fanout import URLS, clusters

SETUPS = "scripts/install_cloud_pak_for_data/4.5_service_instance_setups"
DB2 = f"{SETUPS}/4.5_provision_db2.sh"
COGNOS = f"{SETUPS}/4.5_provision_cognos.sh"
EXTRA = [DB2, COGNOS, "src/tui"]

# Records every call, answers `service-instance list` from the payloads this cluster created, as cpd-cli would.
FAKE_CPD_CLI = r'''#!@@PYTHON@@ -I
import json, os, sys
from pathlib import Path
log = Path("@@LOG@@")
cluster = os.environ.get("MCM_CLUSTER", "") or "flat"
args = sys.argv[1:]
with log.open("a") as handle:
    handle.write(json.dumps({"tool": "cpd-cli", "argv": args, "cluster": cluster, "home": os.environ.get("HOME", ""),
                             "cpdconfig": os.environ.get("CPDCONFIG", "")}) + "\n")
if args[:2] == ["service-instance", "list"]:
    records = []
    for line in log.read_text().splitlines():
        call = json.loads(line)
        if call["cluster"] == cluster and call["argv"][:2] == ["service-instance", "create"]:
            source = next(a for a in call["argv"] if a.startswith("--from-source="))
            payload = json.loads(Path(source.split("=", 1)[1]).read_text())
            records.append({"id": "1234", "display_name": payload["display_name"], "service_type": "db2oltp",
                            "provision_status": "PROVISIONED"})
    print(json.dumps({"service_instances": records}))
'''

# Db2 custom resources answer `oc get db2uinstance(s)`; login / whoami go to the harness fake (per-KUBECONFIG sessions).
FAKE_OC = r'''#!@@PYTHON@@ -I
import json, os, sys
args = sys.argv[1:]
if args[:1] == ["get"] and len(args) > 1 and args[1] == "db2uinstances":
    print(json.dumps({"items": [{"metadata": {"name": "generated-db2-1234",
                                              "labels": {"icpdsupport/serviceInstanceId": "1234"}},
                                 "status": {"state": "Ready"}}]}))
    sys.exit(0)
if args[:1] == ["get"] and len(args) > 1 and args[1] == "db2uinstance":
    sys.exit(0)
os.execv("@@HARNESS_OC@@", ["@@HARNESS_OC@@", *args])
'''

# `uv run --quiet python SCRIPT ARGS` -> python SCRIPT ARGS, recording what the wrapper hands over.
FAKE_UV = r'''#!@@PYTHON@@ -I
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[:3] == ["run", "--quiet", "python"], args
with Path("@@LOG@@").open("a") as handle:
    handle.write(json.dumps({"tool": "uv", "argv": args[3:], "cluster": os.environ.get("MCM_CLUSTER", "") or "flat",
                             "cwd": os.getcwd(),
                             "env": {k: os.environ.get(k, "") for k in ("SERVICE_INSTANCE_FILE_DIR", "CONFIG_DIR",
                                                                         "PROJECT_CPD_INST_OPERANDS", "STG_CLASS_FILE")}})
                 + "\n")
os.execv("@@PYTHON@@", ["@@PYTHON@@", *args[3:]])
'''


def cpd_extra(name):
    return {
        "PROJECT_CPD_INST_OPERANDS": f"ns-{name}", "IMAGE_PULL_SECRET": "pull-secret",
        "STG_CLASS_BLOCK": f"block-{name}", "STG_CLASS_FILE": f"file-{name}", "CPD_USERNAME": "cpadmin",
        "IMAGE_ARCH": "amd64", "SERVICE_INSTANCE_VAULT_STORE": "false", "DB2_INSTANCE_NAME": f"db2-{name}",
        "DB2_PROFILE": "cognos",
    }


def install_fakes(sb):
    log = sb.root / "provision_calls.log"
    harness_oc = sb.root / "harness_bin" / "oc"
    harness_oc.parent.mkdir()
    (sb.bin / "oc").rename(harness_oc)
    for path, body in ((sb.bin / "cpd-cli", FAKE_CPD_CLI), (sb.home / "cpd-cli" / "cpd-cli", FAKE_CPD_CLI),
                       (sb.bin / "oc", FAKE_OC), (sb.bin / "uv", FAKE_UV)):
        path.write_text(body.replace("@@PYTHON@@", sys.executable).replace("@@LOG@@", str(log))
                        .replace("@@HARNESS_OC@@", str(harness_oc)))
        path.chmod(0o755)
    # The launchers call python3 by name; use the test interpreter, not whatever /usr/bin holds.
    (sb.bin / "python3").symlink_to(sys.executable)
    return log


def records(log, tool=None):
    if not log.exists():
        return []
    rows = [json.loads(line) for line in log.read_text().splitlines() if line]
    return [r for r in rows if tool is None or r["tool"] == tool]


def env(**changes):
    return {"DB2_PASSWORD": "test-'$\\\"secret", "DB2_DATA_STORAGE_GI": "50", **changes}


def flat_outputs(sb):
    """Everything in the shared folders a delineated run must leave alone."""
    flat_payloads = sb.repo / "service_instances"
    flat_details = sb.repo / "configs" / "cp4d_config" / "managed-service-instances"
    return sorted(p for root in (flat_payloads, flat_details) if root.exists() for p in root.rglob("*") if p.is_file())


def details_file(base, name):
    found = list((base / "cp4d_config" / "managed-service-instances").rglob(f"*{name}*-instance_details.sh"))
    assert len(found) == 1, found
    return found[0]


def check_db2_outputs(base, name, payload_dir=None):
    """base: the folder holding cp4d_config; payload_dir: the service-instance folder (default base/service_instances)."""
    payload = json.loads(((payload_dir or base / "service_instances") / f"db2-{name}.json").read_text())
    assert payload["display_name"] == f"db2-{name}"
    assert payload["create_arguments"]["parameters"]["environment"]["databases"][0]["settings"]["dftPageSize"] == "32768"
    sizes = {v["spec"]["resources"]["requests"]["storage"] for v in volumes(payload) if v["name"] == "data"}
    assert sizes == {"50Gi"}
    details = details_file(base, f"db2-{name}")
    assert stat.S_IMODE(details.stat().st_mode) == 0o600
    assert "_PASSWORD=" in details.read_text()
    return payload


COGNOS_ARGS = [
    "--name", "cognos-new", "--version", "30.0.4", "--size", "small",
    "--content-connection", "cognos-new-store", "--audit-connection", "cognos-new-store",
]


# ---- Db2 ----------------------------------------------------------------------------------------------------------
def test_db2_target_cluster_writes_payload_and_details_under_the_cluster():
    with make_sandbox(extra=EXTRA) as sb:
        clusters(sb)
        for name in ("itz-a", "itz-b"):
            sb.write_config("cpd", ocp_url=URLS[name], cluster=name, extra=cpd_extra(name))
        log = install_fakes(sb)
        result = sb.run_script(DB2, env=env(), args=["--target-cluster", "itz-a"], timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        base = sb.repo / "configs" / "clusters" / "itz-a"
        check_db2_outputs(base, "itz-a")
        assert flat_outputs(sb) == []
        other = sb.repo / "configs" / "clusters" / "itz-b"
        assert not any(p.is_file() for p in other.rglob("*") if "service_instances" in p.parts or "managed-service-instances" in p.parts)
        calls = records(log, "cpd-cli")
        assert calls and {c["cluster"] for c in calls} == {"itz-a"}
        # Profiles come from the cluster's own HOME (the PATH shim), not the shared ~/.cpd-cli.
        assert all(c["home"].startswith(str(base)) for c in calls), calls
        create = next(c for c in calls if c["argv"][:2] == ["service-instance", "create"])
        assert create["argv"][2] == f"--from-source={base / 'service_instances' / 'db2-itz-a.json'}"
        assert env()["DB2_PASSWORD"] not in result.stdout + result.stderr + log.read_text()
        assert "--target-cluster" not in log.read_text()


def test_db2_target_clusters_gives_each_cluster_its_own_payload_and_profile():
    with make_sandbox(extra=EXTRA) as sb:
        clusters(sb)
        for name in ("itz-a", "itz-b"):
            sb.write_config("cpd", ocp_url=URLS[name], cluster=name, extra=cpd_extra(name))
        log = install_fakes(sb)
        result = sb.run_script(DB2, env=env(), args=["--target-clusters", "itz-a,itz-b"], timeout=180)
        assert result.returncode == 0, result.stdout + result.stderr
        homes = {}
        for name in ("itz-a", "itz-b"):
            base = sb.repo / "configs" / "clusters" / name
            check_db2_outputs(base, name)
            # Only this cluster's payload in this cluster's folder.
            assert sorted(p.name for p in (base / "service_instances").iterdir()) == [f"db2-{name}.json"]
            calls = [c for c in records(log, "cpd-cli") if c["cluster"] == name]
            assert any(c["argv"][:2] == ["service-instance", "create"] for c in calls)
            homes[name] = {c["home"] for c in calls}
            assert all(h.startswith(str(base)) for h in homes[name])
        assert homes["itz-a"].isdisjoint(homes["itz-b"])
        assert flat_outputs(sb) == []


def test_db2_mode_off_keeps_the_flat_paths():
    with make_sandbox(extra=EXTRA) as sb:
        sb.write_config("cpd", extra=cpd_extra("flat"))
        log = install_fakes(sb)
        result = sb.run_script(DB2, env=env(), timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        # Main's layout: payloads in the repo-level service_instances/, details in configs/cp4d_config/.
        check_db2_outputs(sb.repo / "configs", "flat", payload_dir=sb.repo / "service_instances")
        payload = sb.repo / "service_instances" / "db2-flat.json"
        assert not (sb.repo / "configs" / "clusters").exists()
        create = next(c for c in records(log, "cpd-cli") if c["argv"][:2] == ["service-instance", "create"])
        assert create["argv"][2] == f"--from-source={payload}"
        assert create["home"] == str(sb.home)


# ---- Cognos -------------------------------------------------------------------------------------------------------
def cognos_payload(path, name):
    payload = json.loads(path.read_text())
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    params = payload["create_arguments"]["parameters"]
    # Namespace and storage classes come from the cluster's own config.
    assert payload["namespace"] == f"ns-{name}"
    assert (params["fileStorageClass"], params["blockStorageClass"]) == (f"file-{name}", f"block-{name}")
    return payload


@pytest.mark.parametrize("output", [
    "cognos-new-review.json",  # the documented render command (docs/cognos-analytics.md)
    "service_instances/cognos-new-review.json",  # the form main's docs used
])
def test_cognos_render_target_cluster_lands_under_the_cluster(output):
    with make_sandbox(extra=EXTRA) as sb:
        clusters(sb)
        for name in ("itz-a", "itz-b"):
            sb.write_config("cpd", ocp_url=URLS[name], cluster=name, extra=cpd_extra(name))
        log = install_fakes(sb)
        result = sb.run_script(COGNOS, args=[*COGNOS_ARGS, "--output", output, "--target-cluster", "itz-a"], timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        base = sb.repo / "configs" / "clusters" / "itz-a"
        cognos_payload(base / "service_instances" / "cognos-new-review.json", "itz-a")
        assert flat_outputs(sb) == []
        (run,) = records(log, "uv")
        assert run["cluster"] == "itz-a"
        assert run["env"]["SERVICE_INSTANCE_FILE_DIR"] == str(base / "service_instances")
        assert run["env"]["CONFIG_DIR"] == str(base / "cp4d_config")
        # The multi-cluster flags are consumed by the env load; argparse never sees them.
        assert not any(a.startswith(("--target-cluster", "--all-clusters", "--yes-all-clusters")) for a in run["argv"])
        assert records(log, "cpd-cli") == []  # render mode makes no cluster calls


def test_cognos_render_target_clusters_gives_a_payload_per_cluster():
    with make_sandbox(extra=EXTRA) as sb:
        clusters(sb)
        for name in ("itz-a", "itz-b"):
            sb.write_config("cpd", ocp_url=URLS[name], cluster=name, extra=cpd_extra(name))
        log = install_fakes(sb)
        result = sb.run_script(COGNOS, args=[
            *COGNOS_ARGS, "--output", "cognos-new-review.json", "--target-clusters", "itz-a,itz-b",
        ], timeout=180)
        assert result.returncode == 0, result.stdout + result.stderr
        for name in ("itz-a", "itz-b"):
            cognos_payload(sb.repo / "configs" / "clusters" / name / "service_instances" / "cognos-new-review.json", name)
        assert flat_outputs(sb) == []
        runs = records(log, "uv")
        assert sorted(r["cluster"] for r in runs) == ["itz-a", "itz-b"]
        assert not any(a.startswith("--target-cluster") for r in runs for a in r["argv"])


@pytest.mark.parametrize("output", ["cognos-new-review.json", "service_instances/cognos-new-review.json"])
def test_cognos_render_mode_off_keeps_the_flat_path(output):
    with make_sandbox(extra=EXTRA) as sb:
        sb.write_config("cpd", extra=cpd_extra("flat"))
        log = install_fakes(sb)
        result = sb.run_script(COGNOS, args=[*COGNOS_ARGS, "--output", output], timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        cognos_payload(sb.repo / "service_instances" / "cognos-new-review.json", "flat")
        assert not (sb.repo / "configs" / "clusters").exists()
        (run,) = records(log, "uv")
        assert run["env"]["SERVICE_INSTANCE_FILE_DIR"].rstrip("/").endswith("service_instances")
        assert run["env"]["CONFIG_DIR"] == str(sb.repo / "configs" / "cp4d_config")
