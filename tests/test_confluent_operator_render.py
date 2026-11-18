"""Operator-mode CFK renderer (src/helpers/confluent_cfk_render.py, contract section 4, WP-C).

Goldens: tests/golden/confluent_cfk/<case>/<set>/* rendered from tests/fixtures/confluent_cfk/<case>.json
({"input": <input JSON>, "renders": [{"set", "args"}]}). Regenerate after an intended template change:

    CFK_RENDER_WRITE_GOLDEN=1 .venv/bin/python tests/run_with_progress.py --status <dir>/status.json \
        -- tests/test_confluent_operator_render.py -k golden

No cluster, no shell scripts: pure rendering.
"""

import copy
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[1]
HELPERS = REPO / "src/helpers"
sys.path.insert(0, str(HELPERS))
import confluent_cfk_render as cfk

FIXTURES = REPO / "tests/fixtures/confluent_cfk"
GOLDEN = REPO / "tests/golden/confluent_cfk"
WRITE_GOLDEN = os.environ.get("CFK_RENDER_WRITE_GOLDEN") == "1"
CASES = sorted(p.stem for p in FIXTURES.glob("*.json"))
EXPECTED_CASES = {"plain", "sasl_plaintext", "sasl_ssl_repo", "sasl_ssl_cfk", "external", "scram", "c3_basic",
                  "c3_openshift", "no_c3", "xsmall", "connect_plugins_local", "connector_cr", "flink_env",
                  "flink_app", "mds_ldap"}
COMPONENT_KINDS = {"KRaftController", "Kafka", "SchemaRegistry", "Connect", "KsqlDB", "KafkaRestProxy",
                   "ControlCenter"}


def fixture(case):
    return json.loads((FIXTURES / f"{case}.json").read_text())


def base_doc(case="sasl_plaintext"):
    return copy.deepcopy(fixture(case)["input"])


def render_case(case, out_dir):
    data = fixture(case)
    return [cfk.render(data["input"], r["set"], out_dir, r.get("args")) for r in data["renders"]]


def tree(root):
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


def all_objects():
    """(case, set, parsed object) for every applied file of every case, rendered in memory."""
    out = []
    for case in CASES:
        data = fixture(case)
        for r in data["renders"]:
            manifest = cfk.render(data["input"], r["set"], None, r.get("args"))
            for f in manifest["files"]:
                if f["apply"]:
                    out.append((case, r["set"], yaml.safe_load(f["text"])))
    return out


def errors_of(doc, set_name="platform", args=None):
    with pytest.raises(cfk.RenderError) as exc:
        cfk.render(doc, set_name, None, args)
    return exc.value.errors


# ------------------------------------------------------------------------------
# Goldens
# ------------------------------------------------------------------------------
def test_golden_cases_are_the_contract_list():
    assert set(CASES) == EXPECTED_CASES


@pytest.mark.parametrize("case", CASES)
def test_golden(case, tmp_path):
    render_case(case, tmp_path)
    got = tree(tmp_path)
    if WRITE_GOLDEN:
        shutil.rmtree(GOLDEN / case, ignore_errors=True)
        for rel, data in got.items():
            (GOLDEN / case / rel).parent.mkdir(parents=True, exist_ok=True)
            (GOLDEN / case / rel).write_bytes(data)
    want = tree(GOLDEN / case)
    assert sorted(got) == sorted(want), f"file list differs for {case}"
    for rel in want:
        assert got[rel] == want[rel], f"{case}/{rel} differs from the golden"


# ------------------------------------------------------------------------------
# Properties over every rendered object
# ------------------------------------------------------------------------------
def test_every_component_cr_runs_under_restricted_v2_with_both_images():
    seen = set()
    for case, set_name, obj in all_objects():
        if obj["kind"] not in COMPONENT_KINDS:
            continue
        seen.add(obj["kind"])
        spec = obj["spec"]
        assert spec["podTemplate"]["podSecurityContext"] == {}, (case, obj["kind"])
        assert spec["image"]["application"] and spec["image"]["init"], (case, obj["kind"])
        assert spec["injectLabels"] == {"app.kubernetes.io/part-of": "confluent"}
    assert seen == COMPONENT_KINDS


def test_every_object_carries_the_ownership_labels():
    for case, set_name, obj in all_objects():
        labels = obj["metadata"]["labels"]
        assert labels["app.kubernetes.io/part-of"] == "confluent", (case, obj["kind"])
        assert labels["confluent.ibm-scripts/installed-by"] == "local.confluent"
        assert labels["confluent.ibm-scripts/deploy-mode"] == "operator"


def test_kafka_config_overrides_are_exactly_the_scripts_mode_properties():
    manifest = cfk.render(base_doc(), "platform", None)
    kafka = yaml.safe_load(next(f["text"] for f in manifest["files"] if f["kind"] == "Kafka"))
    assert kafka["spec"]["configOverrides"]["server"] == [
        "default.replication.factor=3", "min.insync.replicas=2", "num.partitions=3",
        "offsets.topic.replication.factor=3", "transaction.state.log.replication.factor=3",
        "transaction.state.log.min.isr=2", "transaction.max.timeout.ms=3600000",
        "group.initial.rebalance.delay.ms=0", "confluent.license.topic.replication.factor=3",
        "confluent.balancer.topic.replication.factor=3", "confluent.metadata.topic.replication.factor=3",
        "confluent.consumer.lag.emitter.enabled=true",
        "confluent.schema.registry.url=http://schema-registry.confluent.svc.cluster.local:8081",
        "auto.create.topics.enable=true",
    ]
    # E1: the external listener is configured (authenticated) even without external access.
    assert kafka["spec"]["listeners"]["external"]["authentication"]["type"] == "plain"
    assert "externalAccess" not in kafka["spec"]["listeners"]["external"]


def test_auto_create_topics_can_be_turned_off():
    doc = base_doc()
    doc["vars"]["CONFLUENT_AUTO_CREATE_TOPICS"] = "false"
    manifest = cfk.render(doc, "platform", None)
    kafka = yaml.safe_load(next(f["text"] for f in manifest["files"] if f["kind"] == "Kafka"))
    assert not [x for x in kafka["spec"]["configOverrides"]["server"] if x.startswith("auto.create")]


def test_flink_application_cpu_is_a_string():
    data = fixture("flink_app")
    manifest = cfk.render(data["input"], "flink-app", None, data["renders"][0]["args"])
    app = yaml.safe_load(manifest["files"][0]["text"])
    for role in ("jobManager", "taskManager"):
        assert isinstance(app["spec"][role]["resource"]["cpu"], str)
    assert isinstance(app["spec"]["flinkConfiguration"]["taskmanager.numberOfTaskSlots"], str)


@pytest.mark.parametrize("version,ok", [("v2_2", True), ("v2_3", False), ("v3_0", False), ("2.0", False)])
def test_flink_version_cap(version, ok):
    data = fixture("flink_app")
    doc = data["input"]
    doc["vars"]["FLINK_APPLICATION_VERSION"] = version
    if ok:
        cfk.render(doc, "flink-app", None, {"name": "x"})
    else:
        assert any("FLINK_APPLICATION_VERSION" in e for e in errors_of(doc, "flink-app", {"name": "x"}))


@pytest.mark.parametrize("defaults", [
    {"metadata": {"labels": {"a": "b"}}, "spec": {}},
    {"spec": {"podTemplate": {"metadata": {"labels": {"a": "b"}}}}},
])
def test_flink_environment_defaults_without_metadata(defaults):
    doc = fixture("flink_env")["input"]
    doc["live"]["flink_defaults"] = defaults
    assert "CMF rejects metadata.labels in flinkApplicationDefaults" in errors_of(doc, "flink")


def test_flink_environment_golden_has_no_metadata_in_defaults():
    data = fixture("flink_env")
    manifest = cfk.render(data["input"], "flink", None)
    env = yaml.safe_load(next(f["text"] for f in manifest["files"] if f["kind"] == "FlinkEnvironment"))
    assert "metadata" not in json.dumps(env["spec"]["flinkApplicationDefaults"])
    assert env["spec"]["kubernetesNamespace"] == "confluent-flink"


# ------------------------------------------------------------------------------
# Secrets never reach the renderer
# ------------------------------------------------------------------------------
def test_allowed_inputs_hold_no_secret_names():
    assert not [v for v in cfk.ALLOWED_INPUT_VARS if cfk.SECRET_VAR_RE.search(v) or v == "OCP_PASSWORD"]


@pytest.mark.parametrize("name", ["CONFLUENT_LICENSE_KEY", "CONFLUENT_AUTH_PASSWORD", "OCP_PASSWORD", "OCP_TOKEN",
                                  "CONFLUENT_REGISTRY_PASSWORD", "FLINK_S3_SECRET_KEY", "CONFLUENT_SASL_CLIENT_CREDS",
                                  "CONFLUENT_LDAP_ADMIN_PASS"])
def test_secret_pattern_var_is_refused(name):
    doc = base_doc()
    doc["vars"][name] = "s3cr3t"
    errors = errors_of(doc)
    assert f"secret values must never reach the renderer: {name}" in errors
    assert not any("s3cr3t" in e for e in errors)


def test_unknown_var_is_refused():
    doc = base_doc()
    doc["vars"]["CONFLUENT_SOMETHING_NEW"] = "x"
    assert "unknown input var CONFLUENT_SOMETHING_NEW" in errors_of(doc)


# ------------------------------------------------------------------------------
# Validation (exit 1, nothing written)
# ------------------------------------------------------------------------------
def _with(vars_=None, live=None, case="sasl_plaintext"):
    doc = base_doc(case)
    doc["vars"].update(vars_ or {})
    doc["live"].update(live or {})
    return doc


@pytest.mark.parametrize("doc,needle", [
    (_with({"CONFLUENT_SASL_ENABLED": "false", "CONFLUENT_EXTERNAL_KAFKA_ENABLED": "true"},
           {"external_tls_secret_present": True}), "needs CONFLUENT_SASL_ENABLED=true"),
    (_with({"CONFLUENT_EXTERNAL_KAFKA_ENABLED": "true"}, {"route_domain": "", "external_tls_secret_present": True}),
     "needs live.route_domain"),
    (_with({"CONFLUENT_EXTERNAL_KAFKA_ENABLED": "true"}), "live.external_tls_secret_present"),
    (_with({"CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS": "PLAIN,SCRAM-SHA-512"}), cfk.SCRAM_PLAIN_ERROR),
    (_with({"CONFLUENT_SASL_MECHANISM": "SCRAM-SHA-512"}), "CONFLUENT_SASL_MECHANISM=SCRAM-SHA-512"),
    (_with({"CONFLUENT_CLUSTER_ID": "too-short"}), "CONFLUENT_CLUSTER_ID"),
    (_with({"CONFLUENT_REPLICATION_FACTOR": "5"}), "is larger than CONFLUENT_BROKER_REPLICAS"),
    (_with({"CONFLUENT_BROKER_REPLICAS": "0", "CONFLUENT_REPLICATION_FACTOR": "1"}), "CONFLUENT_BROKER_REPLICAS=0"),
    (_with({"CONFLUENT_KRAFT_REPLICAS": "2"}), "must be an odd integer"),
    (_with({"CONFLUENT_VERSION": "latest"}), "concrete X.Y.Z"),
    (_with({"CONFLUENT_BROKER_STORAGE_SIZE": ""}), "Kafka dataVolumeCapacity is empty"),
    (_with({"CONFLUENT_STORAGE_CLASS": "", "STG_CLASS_BLOCK": ""}), "storage class is empty"),
    (_with({"CONFLUENT_SASL_PROTOCOL": "SASL_SSL"}), "live.internal_tls_secret_present"),
    (_with({"CONFLUENT_SASL_PROTOCOL": "SASL_SSL", "CONFLUENT_OPERATOR_TLS_SOURCE": "cfk"}), "ca-pair-sslcerts"),
    (_with({"CONFLUENT_OPERATOR_IMAGE_SOURCE": "csv", "CONFLUENT_CONNECT_IMAGE": "",
            "CONFLUENT_OPERATOR_INIT_IMAGE": ""}), "image.application is empty"),
    (_with(live={"connect_state": {"plugins": {"url": [{"name": "x", "archivePath": "https://e/x.zip"}]}}}),
     "has no checksum"),
])
def test_validation_errors(doc, needle):
    errors = errors_of(doc)
    assert any(needle in e for e in errors), errors


@pytest.mark.parametrize("mutate,needle", [
    (lambda d: d.update(schema_version=2), "schema_version must be 1"),
    (lambda d: d.pop("namespace"), "required key 'namespace' is missing"),
    (lambda d: d.pop("owner_id"), "required key 'owner_id' is missing"),
    (lambda d: d["vars"].update(CONFLUENT_VERSION=8), "vars.CONFLUENT_VERSION must be a string"),
])
def test_document_errors(mutate, needle):
    doc = base_doc()
    mutate(doc)
    errors = errors_of(doc)
    assert any(needle in e for e in errors), errors


def test_failed_render_writes_nothing(tmp_path):
    cfk.render(base_doc(), "platform", tmp_path)
    before = tree(tmp_path)
    doc = base_doc()
    doc["vars"]["CONFLUENT_CLUSTER_ID"] = "bad"
    with pytest.raises(cfk.RenderError):
        cfk.render(doc, "platform", tmp_path)
    assert tree(tmp_path) == before


def test_deterministic_double_render_and_stale_cleanup(tmp_path):
    first, second = tmp_path / "a", tmp_path / "b"
    cfk.render(base_doc(), "platform", first)
    cfk.render(base_doc(), "platform", second)
    assert tree(first) == tree(second)
    (first / "platform/99-stale-left-over.yaml").write_text("kind: Stale\n")
    (first / "platform/keep.txt").write_text("not ours\n")
    doc = base_doc()
    doc["vars"]["CONFLUENT_INSTALL_CONTROL_CENTER"] = "false"
    manifest = cfk.render(doc, "platform", first)
    files = set(tree(first / "platform"))
    assert "99-stale-left-over.yaml" not in files and "80-controlcenter-control-center.yaml" not in files
    assert "keep.txt" in files
    assert {"kind": "ControlCenter", "name": "control-center"} in manifest["disabled"]
    assert json.loads((first / "platform/manifest.json").read_text()) == manifest


def test_csv_image_source_uses_related_images_unless_a_var_is_set():
    doc = _with({"CONFLUENT_OPERATOR_IMAGE_SOURCE": "csv", "CONFLUENT_VERSION": "8.4.0"},
                {"related_images": {name: f"registry.connect.redhat.com/confluentinc/{name}@sha256:{'a' * 64}" for name in
                                    ("cp-server", "cp-schema-registry", "cp-server-connect", "cp-ksqldb-server",
                                     "cp-kafka-rest", "cp-enterprise-control-center-next-gen",
                                     "cp-enterprise-prometheus", "cp-enterprise-alertmanager",
                                     "confluent-init-container")}})
    del doc["vars"]["CONFLUENT_OPERATOR_INIT_IMAGE"]
    manifest = cfk.render(doc, "platform", None)
    objs = {f["kind"]: yaml.safe_load(f["text"]) for f in manifest["files"]}
    assert objs["Kafka"]["spec"]["image"]["application"].startswith("registry.connect.redhat.com/confluentinc/cp-server@")
    assert objs["Kafka"]["spec"]["image"]["init"].startswith("registry.connect.redhat.com/confluentinc/confluent-init")
    # CONFLUENT_CONNECT_IMAGE is set in the fixture, so it wins over the CSV digest.
    assert objs["Connect"]["spec"]["image"]["application"] == doc["vars"]["CONFLUENT_CONNECT_IMAGE"]


@pytest.mark.parametrize("mds,routes,external,router_ports", [
    ("false", "true", "false", None), ("true", "true", "false", [8090]), ("true", "false", "false", None),
    ("true", "true", "true", [9092, 8090]),
])
def test_kafka_network_policy_admits_the_router_only_for_exposed_ports(mds, routes, external, router_ports):
    doc = _with({"CONFLUENT_MDS_ENABLED": mds, "CONFLUENT_CREATE_ROUTES": routes,
                 "CONFLUENT_EXTERNAL_KAFKA_ENABLED": external}, {"external_tls_secret_present": True})
    manifest = cfk.render(doc, "repo", None)
    np = yaml.safe_load(next(f["text"] for f in manifest["files"] if f["name"] == "cfk-kafka-listeners"))
    rules = [r for r in np["spec"]["ingress"] if any("namespaceSelector" in s for s in r.get("from", []))]
    assert [[p["port"] for p in r["ports"]] for r in rules] == ([router_ports] if router_ports else [])


def test_nginx_front_proxy_resolves_the_headless_c3_service_per_request():
    data = fixture("c3_basic")
    manifest = cfk.render(data["input"], "repo", None, data["renders"][0].get("args"))
    conf = next(f["text"] for f in manifest["files"] if f["kind"] == "File")
    assert "resolver dns-default.openshift-dns.svc.cluster.local valid=10s;" in conf
    assert "proxy_pass $c3_upstream;" in conf and "127.0.0.1" not in conf


@pytest.mark.parametrize("key", ["related_images", "connect_state", "flink_defaults", "flink_env_secrets"])
def test_live_objects_of_the_wrong_shape_are_errors(key):
    doc = base_doc()
    doc["live"][key] = ["not", "an", "object"]
    assert f"live.{key} must be an object" in errors_of(doc)


def test_connector_secret_refs_become_file_provider_references():
    data = fixture("connector_cr")
    manifest = cfk.render(data["input"], "connector", None, data["renders"][1]["args"])
    connector = yaml.safe_load(manifest["files"][0]["text"])
    assert (connector["spec"]["configs"]["iceberg.catalog.s3.secret-access-key"] ==
            "${file:/mnt/secrets/iceberg-watsonx-credentials/credentials.properties:iceberg.catalog.s3.secret-access-key}")


# ------------------------------------------------------------------------------
# CLI and import paths
# ------------------------------------------------------------------------------
def _cli(*args, stdin=None, env=None):
    return subprocess.run([sys.executable, "-I", str(HELPERS / "confluent_cfk_render.py"), *args], check=False,
                          input=stdin, capture_output=True, text=True, env=env, cwd=str(REPO))


def test_cli_input_from_env_then_render(tmp_path):
    doc = base_doc()
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(tmp_path), **doc["vars"],
           "CONFLUENT_LICENSE_KEY": "license-value-never-copied", "OCP_PASSWORD": "never-copied",
           "MCM_CLUSTER": "itz-x1"}
    live = tmp_path / "live.json"
    live.write_text(json.dumps(doc["live"]))
    made = _cli("input-from-env", "--live", str(live), env=env)
    assert made.returncode == 0, made.stderr
    assert "never-copied" not in made.stdout and "license-value" not in made.stdout
    built = json.loads(made.stdout)
    assert built["owner_id"] == "itz-x1.confluent" and built["namespace"] == "confluent"
    out = _cli("render", "--set", "platform", "--out-dir", str(tmp_path / "cfk"), stdin=made.stdout, env=env)
    assert out.returncode == 0, out.stderr
    assert json.loads(out.stdout) == json.loads((tmp_path / "cfk/platform/manifest.json").read_text())
    assert "[INFO] Connect CPU raised to the operator-mode minimum (1 request / 2 limit)" in out.stderr


def test_cli_validate_and_list_inputs(tmp_path):
    listed = _cli("list-inputs")
    assert listed.returncode == 0 and set(listed.stdout.split()) == set(cfk.ALLOWED_INPUT_VARS)
    good = _cli("validate", stdin=json.dumps(base_doc()))
    assert good.returncode == 0, good.stderr
    bad_doc = base_doc()
    bad_doc["vars"]["CONFLUENT_AUTH_PASSWORD"] = "x"
    bad = _cli("render", "--set", "platform", "--out-dir", str(tmp_path / "cfk"), stdin=json.dumps(bad_doc))
    assert bad.returncode == 1
    assert "[ERROR] secret values must never reach the renderer: CONFLUENT_AUTH_PASSWORD" in bad.stderr
    assert not (tmp_path / "cfk").exists()


def test_importable_as_package_module():
    sys.path.insert(0, str(REPO))
    try:
        import importlib
        mod = importlib.import_module("src.helpers.confluent_cfk_render")
    finally:
        sys.path.remove(str(REPO))
    assert mod.render(base_doc(), "platform", None)["set"] == "platform"


# ------------------------------------------------------------------------------
# Lead fixes 2026-11-18: front-proxy checksum, license warning printed once
# ------------------------------------------------------------------------------
def _proxy_checksum(case, args):
    data = fixture(case)
    manifest = cfk.render(data["input"], "repo", None, args)
    dep = next(f for f in manifest["files"] if f["kind"] == "Deployment" and f["name"] == cfk.FRONT_PROXY)
    obj = yaml.safe_load(dep["text"])
    return obj["spec"]["template"]["metadata"]["annotations"][cfk.FRONT_PROXY_CHECKSUM_ANNOTATION]


@pytest.mark.parametrize("case,mode", [("c3_basic", "basic"), ("c3_openshift", "openshift")])
def test_front_proxy_checksum_follows_the_secret_digest(case, mode):
    a = _proxy_checksum(case, {"front_proxy_mode": mode, "front_proxy_secret_digest": "aaa"})
    b = _proxy_checksum(case, {"front_proxy_mode": mode, "front_proxy_secret_digest": "bbb"})
    assert a != b and len(a) == 64
    assert a == _proxy_checksum(case, {"front_proxy_mode": mode, "front_proxy_secret_digest": "aaa"})


def test_front_proxy_checksum_covers_the_rendered_nginx_conf():
    doc = base_doc("c3_basic")
    args = {"front_proxy_mode": "basic", "front_proxy_secret_digest": "aaa"}
    before = _proxy_checksum("c3_basic", args)
    doc["vars"]["CONFLUENT_C3_GATEWAY_PORT"] = "9443"
    manifest = cfk.render(doc, "repo", None, args)
    dep = next(f for f in manifest["files"] if f["kind"] == "Deployment" and f["name"] == cfk.FRONT_PROXY)
    after = yaml.safe_load(dep["text"])["spec"]["template"]["metadata"]["annotations"]
    assert after[cfk.FRONT_PROXY_CHECKSUM_ANNOTATION] != before


@pytest.mark.parametrize("warned,count", [("1", 0), ("", 1)])
def test_license_warning_left_off_stderr_once_the_shell_printed_it(capsys, monkeypatch, warned, count):
    monkeypatch.setenv("_CFO_LICENSE_WARNED", warned)
    license_warning = "No CONFLUENT_LICENSE_KEY - Confluent Platform runs on the 30-day trial license."
    manifest = {"info": [], "warnings": [license_warning, "other warning"]}
    cfk._print_notes(manifest)
    err = capsys.readouterr().err
    assert err.count("30-day trial license") == count
    assert "[WARN] other warning" in err
