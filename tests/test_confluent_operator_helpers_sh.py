"""confluent_helpers.sh / confluent_operator_helpers.sh with the fake cluster tools (contract §3.1, §3.2, §7.2).

Each test sources the helpers from a temp copy of the repo's helper files (never the working tree in place), with
the fake oc/helm/... first on PATH, a temp HOME and MCM_CLUSTER_ROOT, so rendered files land in the temp dir.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
FAKE_TOOL = REPO / "tests/fakes/confluent/fake_tool.py"
FIX = REPO / "tests/fixtures/confluent_operator"
WRITE_VERBS = {"apply", "create", "delete", "patch", "label", "annotate", "adm", "secrets", "exec", "rollout",
               "wait", "set", "scale", "replace"}
X8 = "scripts/install_confluent_platform/utility_scripts_confluent_platform/x.8_confluent_wipe_scripts_mode.sh"


@pytest.fixture(scope="module")
def tree(tmp_path_factory):
    root = tmp_path_factory.mktemp("cfo-repo")
    shutil.copytree(REPO / "src/helpers", root / "src/helpers", ignore=shutil.ignore_patterns("__pycache__"))
    (root / "scripts/install_confluent_platform").mkdir(parents=True)
    shutil.copy2(REPO / "scripts/operator_install_helpers.sh", root / "scripts/operator_install_helpers.sh")
    shutil.copy2(REPO / "scripts/install_confluent_platform/confluent_kafka_security.sh",
                 root / "scripts/install_confluent_platform/confluent_kafka_security.sh")
    (root / ".venv").symlink_to(REPO / ".venv")
    return root


@pytest.fixture
def run(tree, tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name in ("oc", "kubectl", "helm", "curl", "confluent", "podman", "skopeo", "sleep"):
        (bin_dir / name).symlink_to(FAKE_TOOL)
    log = tmp_path / "calls.log"

    def _run(script, env=None, responses=None):
        full = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path), "FAKE_LOG": str(log),
                "MCM_CLUSTER_ROOT": str(tmp_path / "cluster"), "TMPDIR": str(tmp_path),
                "_CP4D_REPO_ROOT": str(tree), "ENV_TARGET_FILE": str(tmp_path / "confluent_vars.sh"),
                "MCM_STATE_FILE": os.environ.get("MCM_STATE_FILE", str(tmp_path / "mcm.sh"))}
        if responses is not None:
            path = tmp_path / "responses.json"
            path.write_text(json.dumps(responses))
            full["FAKE_RESPONSES"] = str(path)
        full.update(env or {})
        r = subprocess.run(["zsh", "-c", script], check=False, env=full, capture_output=True, text=True, timeout=120)
        r.calls = log.read_text().splitlines() if log.exists() else []
        r.writes = [c for c in r.calls if c.split()[0] in ("oc", "kubectl") and len(c.split()) > 1
                    and c.split()[1] in WRITE_VERBS]
        return r

    _run.tree = tree
    _run.tmp = tmp_path
    return _run


def _src(name):
    return f'source "${{_CP4D_REPO_ROOT}}/src/helpers/{name}"'


def test_guard_blocks_a_scripts_mode_install_with_zero_writes(run):
    r = run(f"{_src('confluent_helpers.sh')}; cf_operator_guard platform; echo rc=$?",
            env={"PROJECT_CONFLUENT_SERVER": "confluent"},
            responses=[{"tool": "oc", "match": r"^get statefulset/broker ", "stdout": "statefulset.apps/broker\n"}])
    assert r.stdout.strip() == "rc=2"
    vars_file = run.tmp / "confluent_vars.sh"
    assert r.stderr == (
        "[BLOCKED] Namespace confluent holds a scripts-mode Confluent install.\n"
        "          CONFLUENT_DEPLOY_MODE is unset, which means operator mode.\n"
        "          Choose one:\n"
        f"            1. Keep it: set CONFLUENT_DEPLOY_MODE=\"scripts\" in {vars_file}\n"
        f"            2. Replace it: run {run.tree}/{X8}\n"
        "               (add --keep-data to keep the PVCs), then re-run this script.\n")
    assert r.calls and r.writes == []
    assert all(c.split()[1] == "get" for c in r.calls)


def test_guard_in_scripts_mode_makes_no_call_and_prints_nothing(run):
    r = run(f"{_src('confluent_helpers.sh')}; cf_operator_guard platform; cf_operator_guard flink; "
            "cf_operator_guard all; echo rc=$?",
            env={"CONFLUENT_DEPLOY_MODE": "scripts", "PROJECT_CONFLUENT_SERVER": "confluent",
                 "PROJECT_CONFLUENT_FLINK": "confluent-flink", "FLINK_CMF_CHART_VERSION": "2.4.2"})
    assert (r.stdout, r.stderr, r.calls) == ("rc=0\n", "", [])


def test_install_ns_manual_path_call_order(run):
    pm = (FIX / "pm_cfk.json").read_text()
    plan = (FIX / "installplan_ours.json").read_text()
    responses = [
        {"tool": "oc", "match": r"^get packagemanifests\.packages\.operators\.coreos\.com ", "stdout": pm},
        {"tool": "oc", "match": r"^get catalogsources\.operators\.coreos\.com certified-operators ", "stdout": "READY"},
        {"tool": "oc", "match": r"^get subscriptions\.operators\.coreos\.com -n confluent -l ", "max": 1,
         "stdout": "confluent-for-kubernetes confluent-for-kubernetes \n"},
        {"tool": "oc", "match": r"^get subscriptions\.operators\.coreos\.com -n confluent -l ",
         "stdout": "confluent-for-kubernetes confluent-for-kubernetes install-abcde\n"},
        {"tool": "oc", "match": r"^get installplans\.operators\.coreos\.com install-abcde ", "stdout": plan},
        {"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com -n confluent --no-headers",
         "stdout": "confluent-for-kubernetes.v3.4.0   Confluent for Kubernetes   3.4.0   Succeeded\n"},
        {"tool": "oc", "match": r"^get deployment confluent-operator ", "stdout": "1/1"},
    ]
    r = run(f"set -euo pipefail; {_src('confluent_operator_helpers.sh')}; "
            "CFO_OWNER_ID=local.confluent; cfo_install_ns confluent confluent-for-kubernetes; echo DONE",
            env={"FAKE_OC_GET_DEFAULT": "absent", "PROJECT_CONFLUENT_SERVER": "confluent"}, responses=responses)
    assert r.returncode == 0 and r.stdout.rstrip().endswith("DONE"), r.stdout + r.stderr
    steps = [line[:5] for line in r.stdout.splitlines() if line.startswith("[") and line[1].isdigit()]
    assert steps == ["[1/6]", "[2/6]", "[3/6]", "[4/6]", "[5/6]", "[6/6]"]
    olm_dir = run.tmp / "cluster/confluent_platform_vars/rendered/cfk/olm"
    writes = [" ".join(w.split()[:4]) for w in r.writes]
    assert writes == ["oc apply -f -",                                               # namespace
                      f"oc apply -f {olm_dir}/operatorgroup-confluent.yaml",
                      f"oc apply -f {olm_dir}/subscription-confluent-confluent-for-kubernetes.yaml",
                      "oc patch installplans.operators.coreos.com install-abcde"]
    sub = (olm_dir / "subscription-confluent-confluent-for-kubernetes.yaml").read_text()
    assert "installPlanApproval: Manual" in sub and "startingCSV: confluent-for-kubernetes.v3.4.0" in sub
    assert 'confluent.ibm-scripts/installed-by: "local.confluent"' in sub
    og = (olm_dir / "operatorgroup-confluent.yaml").read_text()
    assert "targetNamespaces:\n  - confluent" in og
    assert "InstallPlan install-abcde approved" in r.stdout


def test_ensure_operators_conflict_blocks_without_writes(run):
    responses = [
        {"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com -A",
         "stdout": (FIX / "csvs_two.json").read_text()},
        {"tool": "oc", "match": r"^get operatorgroups\.operators\.coreos\.com -A",
         "stdout": (FIX / "ogs_two.json").read_text()},
    ]
    r = run(f"{_src('confluent_operator_helpers.sh')}; CFO_OWNER_ID=local.confluent; "
            "cfo_ensure_operators confluent confluent-for-kubernetes; echo rc=$?",
            env={"FAKE_OC_GET_DEFAULT": "absent", "PROJECT_CONFLUENT_SERVER": "confluent"}, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=2"
    assert "[BLOCKED] two operators watch confluent" in r.stderr
    assert r.writes == []


def test_ensure_operators_fails_closed_when_the_cluster_cannot_be_read(run):
    # A Forbidden CSV read must not look like "nothing installed" (that would install a second operator).
    responses = [{"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com -A", "rc": 1,
                  "stderr": 'Error from server (Forbidden): clusterserviceversions is forbidden\n'}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; CFO_OWNER_ID=local.confluent; "
            "cfo_ensure_operators confluent confluent-for-kubernetes; echo rc=$?",
            env={"FAKE_OC_GET_DEFAULT": "absent", "PROJECT_CONFLUENT_SERVER": "confluent"}, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=1"
    assert "Forbidden" in r.stderr and "nothing decided" in r.stderr
    assert r.writes == []


def test_persist_var_rewrites_appends_and_refuses_unsafe_values(run):
    vars_file = run.tmp / "confluent_vars.sh"
    vars_file.write_text('export A="1"\nexport B="x"\n')
    vars_file.chmod(0o600)
    unsafe = ['a"b', "a\\b", "a`b", "a$(id)", "a|b", "a\nb"]
    script = (f"{_src('confluent_helpers.sh')}; f=\"$ENV_TARGET_FILE\"; "
              'cf_persist_var "$f" A "x&y/\\${REG}"; cf_persist_var "$f" C new; '
              'cf_persist_var "$f.missing" D 1; echo missing=$?; '
              f'for n in {" ".join(f"UNSAFE_{i}" for i in range(len(unsafe)))}; do '
              'cf_persist_var "$f" B "${(P)n}"; echo rc=$?; done')
    # the unsafe values travel through the environment, so no shell quoting touches them
    r = run(script, env={f"UNSAFE_{i}": v for i, v in enumerate(unsafe)})
    assert r.stdout.splitlines()[:3] == ['[INFO] A=x&y/${REG} saved to confluent_vars.sh.',
                                         "[INFO] C=new saved to confluent_vars.sh.", "missing=0"]
    assert r.stdout.splitlines()[3:] == ["rc=1"] * len(unsafe)
    assert r.stderr.count("[ERROR] B:") == len(unsafe)
    assert vars_file.read_text() == 'export A="x&y/${REG}"\nexport B="x"\n\nexport C="new"\n'
    assert oct(vars_file.stat().st_mode & 0o777) == "0o600"


# ---- wave 1.5: KEEP_DATA retain, fail-closed deletes, FlinkEnvironment removal, license once, V23 ----------
OWNED = {"confluent.ibm-scripts/installed-by": "local.confluent"}
CRS = json.dumps({"items": [{"kind": "Kafka", "metadata": {"name": "kafka", "labels": OWNED}},
                            {"kind": "SchemaRegistry", "metadata": {"name": "schema-registry", "labels": OWNED}},
                            {"kind": "Kafka", "metadata": {"name": "foreign", "labels": {}}}]})
PVCS = json.dumps({"items": [{"metadata": {"name": "data0-kafka-0"}, "spec": {"volumeName": "pv-k0"}},
                             {"metadata": {"name": "data0-kafka-1"}, "spec": {"volumeName": "pv-k1"}},
                             {"metadata": {"name": "data0-foreign-0"}, "spec": {"volumeName": "pv-f0"}}]})
DELETE_ENV = {"FAKE_OC_GET_DEFAULT": "absent", "PROJECT_CONFLUENT_SERVER": "confluent", "CFO_OWNER_ID": "local.confluent"}


@pytest.mark.parametrize("flag", ["", "--delete-data"])
def test_delete_group_retains_the_data_pvs_unless_delete_data(run, flag):
    responses = [{"tool": "oc", "match": r"^get confluent -n confluent -o json", "stdout": CRS},
                 {"tool": "oc", "match": r"^get pvc -n confluent -o json", "stdout": PVCS}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_delete_group confluent 30 {flag} Kafka SchemaRegistry; "
            "echo rc=$?", env=DELETE_ENV, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=0", r.stdout + r.stderr
    writes = [" ".join(w.split()[:4]) for w in r.writes]
    deletes = ["oc delete kafkas.platform.confluent.io kafka",
               "oc delete schemaregistries.platform.confluent.io schema-registry"]
    if flag:
        assert writes == deletes and "Data kept" not in r.stdout
        return
    assert writes == ["oc patch pv pv-k0", "oc patch pv pv-k1", *deletes]
    patch = json.loads(r.writes[0].split("-p ", 1)[1].strip("'"))
    assert patch == {"metadata": {"labels": {"confluent.ibm-scripts/retained-from": "confluent.kafka"},
                                  "annotations": {"confluent.ibm-scripts/retained-from": "confluent/kafka"}},
                     "spec": {"persistentVolumeReclaimPolicy": "Retain"}}
    assert "[INFO] Data kept: 2 PV(s)" in r.stdout and "pv-k1  (was confluent/data0-kafka-1, Kafka/kafka)" in r.stdout


@pytest.mark.parametrize("failing", ["get confluent", "get pvc"])
def test_delete_group_fails_closed_on_read_errors(run, failing):
    responses = [{"tool": "oc", "match": "^" + failing + " ", "rc": 1,
                  "stderr": "Error from server (Forbidden): forbidden\n"},
                 {"tool": "oc", "match": r"^get confluent -n confluent -o json", "stdout": CRS}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_delete_group confluent 30 Kafka; echo rc=$?",
            env=DELETE_ENV, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=1" and "Forbidden" in r.stderr
    assert r.writes == []


def test_remove_operator_keeps_cfk_when_kraft_crs_cannot_be_read(run):
    responses = [{"tool": "oc", "match": r"^get subscriptions\.operators\.coreos\.com -n confluent -l ",
                  "stdout": "confluent-for-kubernetes|confluent-for-kubernetes|confluent-for-kubernetes.v3.4.0\n"},
                 {"tool": "oc", "match": r"^get kraftcontrollers\.platform\.confluent\.io ", "rc": 1,
                  "stderr": "Error from server (Forbidden): forbidden\n"}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_remove_operator confluent confluent-for-kubernetes; "
            "echo rc=$?", env=DELETE_ENV, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=1" and "CFK kept" in r.stderr
    assert r.writes == []


FLINK_ENV = {"FAKE_OC_GET_DEFAULT": "absent", "CMF_URL": "http://cmf.test", "FLINK_ENVIRONMENT_DELETE_WAIT": "20",
             "CFO_OWNER_ID": "local.confluent"}


def test_flinkenv_delete_stops_on_cmf_422_without_touching_the_cr(run):
    responses = [{"tool": "curl", "match": r"-X DELETE ", "stdout": "422"}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_flinkenv_delete confluent-flink env1; echo rc=$?",
            env=FLINK_ENV, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=1"
    assert "HTTP 422" in r.stderr and "SHOW TABLES / SHOW VIEWS" in r.stderr
    assert any("environments/env1/catalog" in c for c in r.calls)
    assert r.writes == []


POOL_422 = '{"errors":[{"message":"Environment \'env1\' cannot be deleted because it still has 1 compute pool."}]}'


def test_flinkenv_delete_waits_while_cmf_still_removes_the_compute_pool(run):
    # CMF deletes pools asynchronously: the DELETE right after the pool delete answered 422 in a live uninstall.
    responses = [{"tool": "curl", "match": r"-X DELETE ", "stdout": "422", "body": POOL_422, "max": 2},
                 {"tool": "curl", "match": r"-X DELETE ", "stdout": "204"}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; CFO_POLL_INTERVAL=10 cfo_flinkenv_delete confluent-flink env1; echo rc=$?",
            env=FLINK_ENV, responses=responses)
    assert "still has compute pools/applications being removed" in r.stdout, r.stdout + r.stderr
    assert "delete answered HTTP 204" in r.stdout
    assert sum("-X DELETE" in c for c in r.calls if c.startswith("curl")) == 3
    assert "SHOW TABLES" not in r.stderr


def test_flinkenv_delete_names_the_pool_when_it_never_goes(run):
    responses = [{"tool": "curl", "match": r"-X DELETE ", "stdout": "422", "body": POOL_422}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; CFO_POLL_INTERVAL=10 cfo_flinkenv_delete confluent-flink env1; echo rc=$?",
            env=FLINK_ENV, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=1"
    assert "Compute pools or applications were still present after 20s" in r.stderr
    assert "SHOW TABLES" not in r.stderr and r.writes == []


def test_flinkenv_delete_documented_finalizer_removal_after_cmf_404(run):
    responses = [{"tool": "curl", "match": r"-X DELETE ", "stdout": "204"},
                 {"tool": "curl", "match": r"environments/env1$", "stdout": "404"},
                 {"tool": "oc", "match": r"^get flinkenvironments\.platform\.confluent\.io env1 ", "max": 4,
                  "stdout": "flinkenvironment/env1\n"}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_flinkenv_delete confluent-flink env1; echo rc=$?",
            env=FLINK_ENV, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=0", r.stdout + r.stderr
    assert [" ".join(w.split()[:2]) for w in r.writes] == ["oc delete", "oc annotate", "oc delete", "oc patch"]
    assert "platform.confluent.io/block-reconcile=true" in r.writes[1]
    assert """'{"metadata":{"finalizers":[]}}'""" in r.writes[3]
    assert "[WORKAROUND]" in r.stdout


def test_license_warning_prints_once(run):
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_check_config platform >/dev/null; "
            "cfo_ensure_license_secret confluent; echo present=$CFO_LICENSE_PRESENT",
            env={"FAKE_OC_GET_DEFAULT": "absent", "CONFLUENT_DEPLOY_MODE": "operator",
                 "PROJECT_CONFLUENT_SERVER": "confluent"})
    assert r.stdout.splitlines()[-1] == "present=false"
    assert r.stderr.count("30-day trial license") == 1, r.stderr


def test_installplan_other_csvs_warns_about_the_other_package(run):
    responses = [{"tool": "oc", "match": r"^get installplans\.operators\.coreos\.com install-x ",
                  "stdout": (FIX / "installplan_extra.json").read_text()}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_installplan_other_csvs confluent install-x "
            "confluent-for-kubernetes; echo rc=$? n=${#CFO_PLAN_OTHERS} ${CFO_PLAN_OTHERS[1]}",
            env={"FAKE_OC_GET_DEFAULT": "absent"}, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=0 n=1 other-operator.v2.0.0"
    assert "also carries other-operator.v2.0.0" in r.stderr and r.writes == []


def test_live_json_fills_route_domain_from_the_cluster(run):
    responses = [{"tool": "oc", "match": r"^get ingresses\.config/cluster ", "stdout": "apps.fake.example"}]
    out = run.tmp / "live.json"
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_live_json platform {out}; echo rc=$?",
            env={"FAKE_OC_GET_DEFAULT": "absent", "PROJECT_CONFLUENT_SERVER": "confluent",
                 "CONFLUENT_CONNECT_STATE_FILE": str(run.tmp / "none.json")}, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=0", r.stderr
    live = json.loads(out.read_text())
    assert live["route_domain"] == "apps.fake.example"
    assert all(isinstance(v, (dict, bool)) or k == "route_domain" for k, v in live.items())


# ---------------------------------------------------------------------------------------------
# Lead fixes 2026-11-18 (WP-A helper requests)
# ---------------------------------------------------------------------------------------------
def test_license_warning_skipped_when_the_license_secret_exists(run):
    responses = [{"tool": "oc", "match": r"^get secret confluent-license -n confluent -o name",
                  "stdout": "secret/confluent-license\n"}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_check_config platform >/dev/null; echo rc=$?",
            env={"FAKE_OC_GET_DEFAULT": "absent", "CONFLUENT_DEPLOY_MODE": "operator",
                 "PROJECT_CONFLUENT_SERVER": "confluent", "CONFLUENT_VERSION": "8.1.0"}, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=0", r.stderr
    assert "30-day trial license" not in r.stderr, r.stderr


def test_entry_defers_the_license_secret_check_until_after_the_login(run):
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_entry platform --no-guard; echo rc=$?",
            env={"FAKE_OC_GET_DEFAULT": "absent", "CONFLUENT_DEPLOY_MODE": "operator",
                 "PROJECT_CONFLUENT_SERVER": "confluent", "CONFLUENT_VERSION": "8.1.0",
                 "OC_LOGIN": "oc login --token=x https://api.test:6443"})
    assert r.stdout.splitlines()[-1] == "rc=0", r.stdout + r.stderr
    login = next(i for i, c in enumerate(r.calls) if c.startswith("oc login"))
    secret = next(i for i, c in enumerate(r.calls) if c.startswith("oc get secret confluent-license"))
    assert login < secret
    assert r.stderr.count("30-day trial license") == 1


def test_namespace_deletable_fails_closed_on_a_read_error(run):
    responses = [{"tool": "oc", "match": r"^get subscriptions\.operators\.coreos\.com,operatorgroups", "rc": 1,
                  "stderr": "Error from server (Forbidden): forbidden\n"}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_namespace_deletable confluent; echo rc=$?",
            env=DELETE_ENV, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=1"
    assert "Forbidden" in r.stderr and "not deletable" in r.stderr


def test_namespace_deletable_when_everything_is_ours_or_absent(run):
    ours = "Subscription/confluent-for-kubernetes|local.confluent\nOperatorGroup/confluent|local.confluent\n"
    for stdout, want in ((ours, "rc=0"), (ours + "Subscription/other|someone\n", "rc=1")):
        r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_namespace_deletable confluent; echo rc=$?",
                env=DELETE_ENV, responses=[{"tool": "oc", "match": r"^get subscriptions", "stdout": stdout}])
        assert r.stdout.splitlines()[-1] == want, r.stdout + r.stderr


def _roll(responses):
    return [{"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent -o jsonpath=\{\.metadata",
             "max": 1, "stdout": s} for s in responses]


def test_wait_roll_ignores_a_stale_false_until_the_generation_is_observed(run):
    # poll 1: False of the old spec (observed 3 < 4); poll 2: rolling; poll 3: done
    responses = _roll(["4|3|False", "4|3|True", "4|4|False"]) + [
        {"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent -o json",
         "stdout": json.dumps({"status": {"phase": "RUNNING", "readyReplicas": 3, "replicas": 3}})}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_wait_roll confluent Kafka/kafka 300 >/dev/null; "
            "echo rc=$?", env={"CFO_POLL_INTERVAL": "10"}, responses=responses)
    rolls = [c for c in r.calls if "confluent.io/rolling" in c]
    assert len(rolls) == 3, r.calls


def test_wait_roll_trusts_false_once_observed_and_falls_back_after_60s(run):
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_wait_roll confluent Kafka/kafka 300 | head -3",
            env={"CFO_POLL_INTERVAL": "10"}, responses=_roll(["4|4|False"]))
    assert r.stdout.splitlines()[0] == "  [1/1] Kafka/kafka: rolling=False observedGeneration=4/4 [0s/300s]"
    assert len([c for c in r.calls if "confluent.io/rolling" in c]) == 1
    # observedGeneration never catches up and no roll shows: polls 0..60 s, then continues
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_wait_roll confluent Kafka/kafka 300 | head -8",
            env={"CFO_POLL_INTERVAL": "10"}, responses=_roll(["4|3|False"] * 10))
    assert r.stdout.splitlines()[7] == "  [1/1] Kafka/kafka: no roll seen in 60s (rolling=False) - continuing"
    # (the call log is shared by both runs of this test: 1 poll above + 7 here)
    assert len([c for c in r.calls if "confluent.io/rolling" in c]) == 1 + 7


def test_print_masked_drops_continuation_lines_of_a_masked_value(run):
    vars_file = run.tmp / "masked.sh"
    vars_file.write_text('export A=1\nexport X_PASSWORD="one\ntwo"\nexport B=2\nexport Y_PASS=\'a\nb\'\n'
                         'export Z_PASS=abc\\\ndef\nexport W_PASS="esc\\"aped\nmore"\nexport C=3\n')
    r = run(f"{_src('confluent_operator_helpers.sh')}; cfo_print_masked {vars_file}")
    assert r.stdout == ('export A=1\nexport X_PASSWORD="********"\nexport B=2\nexport Y_PASS="********"\n'
                        'export Z_PASS="********"\nexport W_PASS="********"\nexport C=3\n')


def test_delete_crds_fails_closed_when_discovery_fails(run):
    # A failed CRD listing used to count as "No ... CRDs" (rc 0): seen in a live uninstall test, where
    # `oc get crd` hit an API-server stream error. Discovery errors now retry and then keep the CRDs.
    responses = [{"tool": "oc", "match": r"^api-resources --api-group=platform\.confluent\.io", "rc": 1,
                  "stderr": "error: stream error: stream ID 1; INTERNAL_ERROR; received from peer\n"}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; CFO_POLL_INTERVAL=0 cfo_delete_crds cfk; echo rc=$?",
            env=DELETE_ENV, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=1", r.stdout + r.stderr
    assert "CRDs kept" in r.stderr and "No platform.confluent.io CRDs" not in r.stdout
    assert sum(c.startswith("oc api-resources --api-group=platform.confluent.io") for c in r.calls) == 3
    assert r.writes == []


def test_delete_crds_lists_the_group_through_discovery(run):
    responses = [{"tool": "oc", "match": r"^api-resources --api-group=flink\.apache\.org",
                  "stdout": "flinkdeployments.flink.apache.org\nflinksessionjobs.flink.apache.org\n"},
                 {"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com -A", "stdout": '{"items": []}'}]
    r = run(f"{_src('confluent_operator_helpers.sh')}; DRY_RUN=true cfo_delete_crds flink; echo rc=$?",
            env=DELETE_ENV, responses=responses)
    assert r.stdout.splitlines()[-1] == "rc=0", r.stdout + r.stderr
    assert "[DRY-RUN] oc delete crd flinkdeployments.flink.apache.org" in r.stdout
    assert "[DRY-RUN] oc delete crd flinksessionjobs.flink.apache.org" in r.stdout
