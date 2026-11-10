"""4.5_provision_cognos.sh puts payloads in the service-instance folder, per cluster when the mode is on.

Runs only in tests/mcm_harness.py sandboxes with a fake `uv` that records its argv; no real cluster,
podman, cpd-cli or repo configs/ are touched.
"""

import json
import re
from pathlib import Path

from mcm_harness import make_sandbox

REPO = Path(__file__).resolve().parents[1]
WRAPPER = "scripts/install_cloud_pak_for_data/4.5_service_instance_setups/4.5_provision_cognos.sh"
DOC = REPO / "docs" / "cognos-analytics.md"
URL_A = "https://api.itz-a.example.com:6443"
URL_B = "https://api.itz-b.example.com:6443"
RENDER = ["--name", "cognos-new", "--version", "30.0.4", "--size", "small",
          "--content-connection", "store", "--audit-connection", "store"]
FAKE_UV = """#!/usr/bin/python3
import json, os, sys
with open(os.environ["UV_LOG"], "a") as stream:
    stream.write(json.dumps({"argv": sys.argv[1:], "dir": os.environ.get("SERVICE_INSTANCE_FILE_DIR", "")}) + "\\n")
"""


def sandbox():
    sb = make_sandbox(extra=[WRAPPER])
    uv = sb.bin / "uv"
    uv.write_text(FAKE_UV)
    uv.chmod(0o755)
    return sb


def run(sb, args):
    log = sb.root / "uv.log"
    result = sb.run_script(WRAPPER, env={"UV_LOG": str(log)}, args=args)
    assert result.returncode == 0, result.stdout + result.stderr
    return [json.loads(line) for line in log.read_text().splitlines()]


def output_of(argv):
    for index, item in enumerate(argv):
        if item == "--output":
            return argv[index + 1]
        if item.startswith("--output="):
            return item.split("=", 1)[1]
    raise AssertionError(argv)


def two_clusters(sb):
    for name, url in (("itz-a", URL_A), ("itz-b", URL_B)):
        sb.write_cluster_marker(name, url)
        sb.write_config("cpd", cluster=name, ocp_url=url)
    (sb.repo / "configs" / "multi_cluster_management.sh").write_text(
        'export MULTI_CLUSTER_MANAGEMENT="true"\nexport MCM_CLUSTERS="itz-a itz-b"\n'
        'export MCM_CURRENT_CLUSTER="itz-a"\nexport APPLY_TO_ALL="false"\nexport MCM_TARGET_CLUSTERS=""\n'
    )


def test_mode_off_resolves_bare_and_service_instances_paths_to_the_flat_folder():
    with sandbox() as sb:
        sb.write_config("cpd")
        flat = (sb.repo / "service_instances").resolve()
        cases = {
            "c1.json": flat / "c1.json",
            "service_instances/c2.json": flat / "c2.json",
            "/elsewhere/c3.json": Path("/elsewhere/c3.json"),
            "review/c4.json": Path("review/c4.json"),
        }
        for given, expected in cases.items():
            for args in (RENDER + ["--output", given], RENDER + [f"--output={given}"]):
                (sb.root / "uv.log").unlink(missing_ok=True)
                [call] = run(sb, args)
                got = Path(output_of(call["argv"]))
                assert (got.resolve() if got.is_absolute() else got) == expected, (given, got)
                assert call["argv"][4:4 + len(RENDER)] == RENDER
        assert sb.calls("oc") == []  # render never logs in


def test_mode_on_writes_one_payload_per_cluster_on_a_multi_target_run():
    with sandbox() as sb:
        two_clusters(sb)
        calls = run(sb, RENDER + ["--output", "c1.json", "--target-clusters", "itz-a,itz-b", "--yes-all-clusters"])
        outputs = sorted(Path(output_of(call["argv"])).resolve() for call in calls)
        clusters = (sb.repo / "configs" / "clusters").resolve()
        assert outputs == [clusters / name / "service_instances" / "c1.json" for name in ("itz-a", "itz-b")]
        for call in calls:
            assert not any(item.startswith("--target-cluster") for item in call["argv"])


def test_mode_on_single_cluster_maps_service_instances_prefix_to_the_cluster_folder():
    with sandbox() as sb:
        two_clusters(sb)
        [call] = run(sb, RENDER + ["--output", "service_instances/c2.json", "--target-cluster", "itz-b"])
        expected = (sb.repo / "configs" / "clusters" / "itz-b" / "service_instances" / "c2.json").resolve()
        assert Path(output_of(call["argv"])).resolve() == expected


def test_docs_use_the_wrapper_and_the_service_instance_folder():
    text = DOC.read_text()
    assert not re.search(r"--output\s+service_instances/", text)
    assert "python3 src/helpers/cognos_provisioning.py" not in text
    assert "configs/clusters/<cluster>/service_instances/" in text
