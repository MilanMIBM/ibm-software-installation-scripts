"""WP-E utilities in operator mode with the fake cluster tools (contract §5.5, §7.1, §7.2).

Each test runs a real script from a temp copy of the repo (never the working tree in place). The copy's
env_bootstrap.sh is a stub that only exports _CP4D_REPO_ROOT and sources the test's vars file, so no real config,
MCM state or cluster is ever read. The fake oc/helm/curl/... come first on PATH; FAKE_OC_GET_DEFAULT=absent makes
every unmatched read a NotFound.
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
U = "scripts/install_confluent_platform/utility_scripts_confluent_platform"
WRITE_VERBS = {"apply", "create", "delete", "patch", "label", "annotate", "adm", "secrets", "exec", "rollout",
               "wait", "set", "scale", "replace"}
OWNER = "local.confluent"
NS = "confluent"

VARS = f"""
export CONFLUENT_DEPLOY_MODE="operator"
export PROJECT_CONFLUENT_SERVER="{NS}"
export OC_LOGIN="oc login --server=https://api.fake:6443 --token=fake"
export CONFLUENT_VERSION="8.0.0"
export CONFLUENT_C3_VERSION="2.4.0"
export CONFLUENT_CLUSTER_ID="AbCdEfGhIjKlMnOpQrStUv"
export CONFLUENT_LICENSE_KEY="fake-license"
export CONFLUENT_SASL_ENABLED="false"
export CONFLUENT_MDS_ENABLED="false"
export CONFLUENT_STORAGE_CLASS="fake-block"
export CONFLUENT_ROUTE_DOMAIN="apps.fake.example"
export CONFLUENT_KRAFT_REPLICAS="3"
export CONFLUENT_BROKER_REPLICAS="3"
export CONFLUENT_INSTALL_CONNECT="true"
export CONFLUENT_INSTALL_CONTROL_CENTER="true"
export CONFLUENT_REGISTRY="confluentinc"
export CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL="Manual"
export CONFLUENT_REPLICATION_FACTOR="3"
export CONFLUENT_MIN_INSYNC_REPLICAS="2"
export CONFLUENT_PARTITIONS="3"
export CONFLUENT_BROKER_STORAGE_SIZE="10Gi"
export CONFLUENT_CONNECT_IMAGE="confluentinc/cp-server-connect"
"""

STUB_BOOTSTRAP = """# test stub of env_bootstrap.sh: the repo root and the test's vars file, nothing else
export _CP4D_REPO_ROOT="${${(%):-%x}:A:h}"
[[ -n "${TEST_VARS_FILE:-}" ]] && source "${TEST_VARS_FILE}"
"""


@pytest.fixture(scope="module")
def tree(tmp_path_factory):
    root = tmp_path_factory.mktemp("wpe-repo")
    shutil.copytree(REPO / "src/helpers", root / "src/helpers", ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copytree(REPO / "scripts/install_confluent_platform", root / "scripts/install_confluent_platform",
                    ignore=shutil.ignore_patterns("__pycache__", "confluent_platform_vars", "flink_vars"), symlinks=True)
    shutil.copy2(REPO / "scripts/operator_install_helpers.sh", root / "scripts/operator_install_helpers.sh")
    (root / "env_bootstrap.sh").write_text(STUB_BOOTSTRAP)
    (root / "pyproject.toml").touch()   # some scripts find the repo root by walking up to it
    (root / ".venv").symlink_to(REPO / ".venv")
    return root


def _cr(kind, name, owner=OWNER):
    labels = {"app.kubernetes.io/part-of": "confluent"}
    if owner:
        labels["confluent.ibm-scripts/installed-by"] = owner
    return {"apiVersion": "platform.confluent.io/v1beta1", "kind": kind,
            "metadata": {"name": name, "namespace": NS, "labels": labels}}


def _pvc(name, pv):
    return {"kind": "PersistentVolumeClaim", "metadata": {"name": name, "namespace": NS}, "spec": {"volumeName": pv}}


PLATFORM_CRS = {"items": [
    _cr("Kafka", "kafka"), _cr("KRaftController", "kraftcontroller"), _cr("KsqlDB", "ksqldb-server"),
    _cr("ControlCenter", "control-center"), _cr("Connect", "connect"), _cr("SchemaRegistry", "schema-registry"),
    _cr("KafkaTopic", "orders"), _cr("KafkaTopic", "theirs", owner="someone.else")]}
PLATFORM_PVCS = {"items": [
    _pvc("data0-kafka-0", "pv-kafka-0"), _pvc("data-kraftcontroller-0", "pv-kraft-0"),
    _pvc("data-ksqldb-server-0", "pv-ksql-0"), _pvc("data0-control-center-0", "pv-c3-0"),
    _pvc("prometheus-data-control-center-0", "pv-prom-0"), _pvc("connect-plugins", "pv-plugins")]}


def _platform_responses(extra=()):
    return [*extra,
            {"tool": "oc", "match": rf"^get namespace {NS}( -o name)?$", "stdout": f"namespace/{NS}\n"},
            {"tool": "oc", "match": rf"^get confluent -n {NS} -o json", "stdout": json.dumps(PLATFORM_CRS)},
            {"tool": "oc", "match": rf"^get pvc -n {NS} -o json", "stdout": json.dumps(PLATFORM_PVCS)}]


@pytest.fixture
def run(tree, tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name in ("oc", "kubectl", "helm", "curl", "confluent", "podman", "skopeo", "sleep"):
        (bin_dir / name).symlink_to(FAKE_TOOL)
    log = tmp_path / "calls.log"
    vars_file = tmp_path / "confluent_vars.sh"
    vars_file.write_text(VARS)

    def _run(cmd, env=None, responses=None, timeout=180):
        full = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path), "FAKE_LOG": str(log),
                "FAKE_OC_GET_DEFAULT": "absent", "TMPDIR": str(tmp_path), "TEST_VARS_FILE": str(vars_file),
                "MCM_CLUSTER_ROOT": str(tmp_path / "cluster"), "ENV_TARGET_FILE": str(vars_file),
                "CONFLUENT_CONFIG_DIR": str(tmp_path / "cfg"), "CONFIGS_ROOT": str(tmp_path / "configs"),
                "CFO_POLL_INTERVAL": "10", "ENV_SETUP_QUIET": "1",
                "MCM_STATE_FILE": os.environ.get("MCM_STATE_FILE", str(tmp_path / "mcm.sh"))}
        if responses is not None:
            path = tmp_path / "responses.json"
            path.write_text(json.dumps(responses))
            full["FAKE_RESPONSES"] = str(path)
        full.update(env or {})
        # The vars file is sourced after the environment, so a mode override goes into it.
        text = VARS
        if "CONFLUENT_DEPLOY_MODE" in (env or {}):
            text = text.replace('CONFLUENT_DEPLOY_MODE="operator"', f'CONFLUENT_DEPLOY_MODE="{env["CONFLUENT_DEPLOY_MODE"]}"')
        vars_file.write_text(text)
        if log.exists():
            log.unlink()
        r = subprocess.run(["zsh", "-c", cmd], check=False, env=full, capture_output=True, text=True,
                           timeout=timeout, cwd=tree)
        r.calls = log.read_text().splitlines() if log.exists() else []
        r.writes = [c for c in r.calls if c.split()[0] in ("oc", "kubectl") and len(c.split()) > 1
                    and c.split()[1] in WRITE_VERBS]
        r.out = r.stdout + r.stderr
        return r

    _run.tree = tree
    _run.tmp = tmp_path
    _run.vars = vars_file
    return _run


def _lines_with(text, *needles):
    return [i for i, line in enumerate(text.splitlines()) if all(n in line for n in needles)]


# ---------------------------------------------------------------------------------------------------------------
# x.0 (operator twin, via the dispatch line)
# ---------------------------------------------------------------------------------------------------------------
def test_x0_dry_run_retains_pvs_before_the_stateful_deletes_in_docs_order(run):
    r = run(f"zsh {U}/x.0_confluent_uninstall.sh --dry-run", responses=_platform_responses())
    assert r.returncode == 0, r.out
    assert r.writes == [], r.writes
    out = r.stdout
    dels = [line.split()[3] + "/" + line.split()[4] for line in out.splitlines()
            if line.startswith("  [DRY-RUN] oc delete ") and ".platform.confluent.io" in line]
    # docs order between the groups (contract 3.2 cfo_delete_order); within a group the listing order
    groups = [{"kafkatopics.platform.confluent.io/orders"},
              {"connects.platform.confluent.io/connect", "schemaregistries.platform.confluent.io/schema-registry"},
              {"ksqldbs.platform.confluent.io/ksqldb-server", "controlcenters.platform.confluent.io/control-center"},
              {"kafkas.platform.confluent.io/kafka", "kraftcontrollers.platform.confluent.io/kraftcontroller"}]
    assert [set(dels[0:1]), set(dels[1:3]), set(dels[3:5]), set(dels[5:7])] == groups and len(dels) == 7, dels
    assert "theirs" not in " ".join(dels)
    assert "Not ours" in out and "KafkaTopic/theirs" in out
    patches = _lines_with(out, "[DRY-RUN] oc patch pv ")
    assert {out.splitlines()[i].split()[4] for i in patches} == {"pv-kafka-0", "pv-kraft-0", "pv-ksql-0", "pv-c3-0",
                                                                "pv-prom-0"}
    first_stateful_delete = min(_lines_with(out, "[DRY-RUN] oc delete ksqldbs.platform.confluent.io")[0],
                                _lines_with(out, "[DRY-RUN] oc delete controlcenters.platform.confluent.io")[0])
    kafka_delete = min(_lines_with(out, "[DRY-RUN] oc delete kafkas.platform.confluent.io")[0],
                       _lines_with(out, "[DRY-RUN] oc delete kraftcontrollers.platform.confluent.io")[0])
    ksql_c3 = [i for i in patches if any(p in out.splitlines()[i] for p in ("pv-ksql-0", "pv-c3-0", "pv-prom-0"))]
    kafka_kraft = [i for i in patches if any(p in out.splitlines()[i] for p in ("pv-kafka-0", "pv-kraft-0"))]
    assert max(ksql_c3) < first_stateful_delete and max(kafka_kraft) < kafka_delete
    assert '"persistentVolumeReclaimPolicy":"Retain"' in out.splitlines()[patches[0]]
    assert f"confluent.ibm-scripts/retained-from\":\"{NS}.kafka" in out
    assert "Data that would be kept" in out
    assert "pv-plugins" not in out
    assert f"[INFO] Keeping namespace {NS}:" in out
    assert "--dry-run complete" in out


def test_x0_delete_data_has_no_retain_patch(run):
    r = run(f"zsh {U}/x.0_confluent_uninstall.sh --dry-run --delete-data", responses=_platform_responses())
    assert r.returncode == 0, r.out
    assert "oc patch pv" not in r.stdout
    assert f"[DRY-RUN] oc delete pvc -n {NS} -l app.kubernetes.io/part-of=confluent" in r.stdout
    assert "kafkas.platform.confluent.io kafka" in r.stdout


def test_x0_ignores_the_delete_crds_env(run):
    r = run(f"zsh {U}/x.0_confluent_uninstall.sh --dry-run --keep-project",
            env={"CONFLUENT_DELETE_CRDS": "true", "DELETE_CRDS": "true"}, responses=_platform_responses())
    assert r.returncode == 0, r.out
    assert "--delete-crds" not in r.stdout.replace("add --remove-operator", "")
    assert not any(c.startswith(("oc get crd", "oc api-resources")) for c in r.calls)
    assert "oc delete crd" not in r.stdout


def test_x0_keeps_the_namespace_with_a_foreign_subscription(run):
    subs = ("Subscription/confluent-for-kubernetes|local.confluent\n"
            "Subscription/someone-elses|\nOperatorGroup/confluent-confluent-og|local.confluent\n")
    extra = [{"tool": "oc", "match": rf"^get subscriptions\.operators\.coreos\.com,operatorgroups\.operators\.coreos\.com -n {NS}",
              "stdout": subs}]
    r = run(f"zsh {U}/x.0_confluent_uninstall.sh --dry-run --remove-operator", responses=_platform_responses(extra))
    assert r.returncode == 0, r.out
    assert f"[INFO] Keeping namespace {NS}: it holds Subscriptions or OperatorGroups that are not ours." in r.stdout
    assert "oc delete namespace" not in r.stdout


def test_x0_guard_blocks_before_the_flink_uninstall(run):
    # A scripts-mode broker in the namespace: the guard (exit 2) must come before the Flink add-on is touched.
    extra = [{"tool": "oc", "match": rf"^get statefulset/broker .* -n {NS} -o name", "stdout": "statefulset.apps/broker\n"}]
    r = run(f"zsh {U}/x.0_confluent_uninstall.sh --dry-run", responses=_platform_responses(extra),
            env={"PROJECT_CONFLUENT_FLINK": "flink", "FLINK_CMF_CHART_VERSION": "2.5.0"})
    assert r.returncode == 2, r.out
    assert "[BLOCKED] Namespace confluent holds a scripts-mode Confluent install." in r.stderr
    assert "Flink settings detected" not in r.stdout and not any(c.startswith("helm ") for c in r.calls)
    assert r.writes == []


# ---------------------------------------------------------------------------------------------------------------
# x.1 (shared, operator branch)
# ---------------------------------------------------------------------------------------------------------------
def test_x1_keep_data_keeps_the_stateful_crs_and_reruns_install(run, tree):
    # Stand-ins for 1.0 and 1.1 so only the teardown runs for real.
    p = run.tmp / "stubs"
    p.mkdir()
    plat = tree / "scripts/install_confluent_platform"
    saved = {n: (plat / n).read_text() for n in ("1.0_confluent_prep.sh", "1.1_confluent_install.sh", "1.2_confluent_status.sh")}
    try:
        for n in saved:
            (plat / n).write_text(f'#!/bin/zsh\necho "STUB {n}"\n')
        routes = [{"tool": "oc", "match": rf"^get route -n {NS} -l confluent\.ibm-scripts/installed-by={OWNER} -o name",
                   "stdout": "route.route.openshift.io/kafka-bootstrap\nroute.route.openshift.io/kafka-0\n"
                             "route.route.openshift.io/schema-registry\n"}]
        r = run(f"zsh {U}/x.1_confluent_reinstall.sh", responses=_platform_responses(routes))
    finally:
        for n, text in saved.items():
            (plat / n).write_text(text)
    assert r.returncode == 0, r.out
    assert ("[INFO] Kafka, KRaft, ksqlDB and Control Center CRs kept with their data; 1.1 re-applies them "
            "(CFK reconciles in place).") in r.stdout
    deleted = [c.split()[2] + "/" + c.split()[3] for c in r.writes if c.startswith("oc delete ") and "platform.confluent.io" in c]
    assert deleted == ["kafkatopics.platform.confluent.io/orders", "connects.platform.confluent.io/connect",
                       "schemaregistries.platform.confluent.io/schema-registry"]
    assert not any(k in " ".join(r.writes) for k in ("kafkas.", "kraftcontrollers.", "ksqldbs.", "controlcenters.", "patch pv"))
    assert not any(c.startswith(("oc delete namespace", "oc delete pvc")) for c in r.writes)
    # the running brokers keep their secrets and identity store, and the Kafka CR keeps its routes
    assert not any(c.startswith("oc delete secret") and "gateway" not in c for c in r.writes), r.writes
    assert not any("openldap" in c or "keycloak" in c for c in r.writes), r.writes
    route_dels = [c for c in r.writes if c.startswith("oc delete route")]
    assert route_dels == [f"oc delete route.route.openshift.io/schema-registry -n {NS} --ignore-not-found"], r.writes
    assert not any(c.startswith("oc delete deployment,service,route") for c in r.writes), r.writes
    assert r.stdout.index("STUB 1.0_confluent_prep.sh") < r.stdout.index("STUB 1.1_confluent_install.sh")


def test_x1_delete_data_is_rejected_in_scripts_mode(run):
    r = run(f"zsh {U}/x.1_confluent_reinstall.sh --delete-data", env={"CONFLUENT_DEPLOY_MODE": "scripts"})
    assert r.returncode == 1
    assert r.stderr.strip() == "[ERROR] Unknown argument '--delete-data'. Try --help."
    assert r.calls == []


# ---------------------------------------------------------------------------------------------------------------
# x.7
# ---------------------------------------------------------------------------------------------------------------
def _sub(name, pkg, owner=OWNER, approval="Manual", plan="install-up", csv="confluent-for-kubernetes.v3.4.0"):
    labels = {"confluent.ibm-scripts/installed-by": owner} if owner else {}
    return {"metadata": {"name": name, "namespace": NS, "labels": labels},
            "spec": {"name": pkg, "channel": "3.4", "installPlanApproval": approval},
            "status": {"installedCSV": csv, "currentCSV": csv, "state": "UpgradePending",
                       "installPlanRef": {"name": plan}}}


def _x7_responses(subs, plan=None):
    resp = [{"tool": "oc", "match": rf"^get subscriptions\.operators\.coreos\.com -n {NS} -o json",
             "stdout": json.dumps({"items": subs})},
            {"tool": "oc", "match": rf"^get confluent -n {NS} -o json", "stdout": json.dumps(PLATFORM_CRS)},
            {"tool": "oc", "match": rf"^get subscriptions\.operators\.coreos\.com confluent-for-kubernetes -n {NS} -o jsonpath=\{{\.status\.installPlanRef\.name\}}",
             "stdout": "install-up"},
            {"tool": "oc", "match": r"^get installplans\.operators\.coreos\.com install-up .*jsonpath=\{\.spec\.approved\}",
             "stdout": "false"}]
    if plan is not None:
        resp.append({"tool": "oc", "match": r"^get installplans\.operators\.coreos\.com install-up -n confluent -o json",
                     "stdout": json.dumps(plan)})
    return resp


def test_x7_warns_before_approving_a_plan_that_carries_the_other_operator(run):
    plan = {"metadata": {"name": "install-up", "namespace": NS},
            "spec": {"approved": False, "clusterServiceVersionNames": ["confluent-for-kubernetes.v3.4.1", "cp-fko.v1.16.2-cp1"]},
            "status": {"phase": "RequiresApproval"}}
    r = run(f"zsh {U}/x.7_confluent_operator_upgrade.sh --approve --dry-run",
            responses=_x7_responses([_sub("confluent-for-kubernetes", "confluent-for-kubernetes")], plan))
    assert r.returncode == 0, r.out
    assert ("[WARN] InstallPlan install-up in confluent also carries cp-fko.v1.16.2-cp1 - approving it upgrades that "
            "operator too (OLM puts every Subscription of a namespace into one InstallPlan, V23).") in r.stderr
    assert "[DRY-RUN] stop: InstallPlan install-up also upgrades cp-fko.v1.16.2-cp1" in r.stdout
    assert "oc patch installplans" not in r.stdout
    assert r.writes == []
    # block-reconcile was printed for our CRs, and printed off again on the stop
    on = _lines_with(r.stdout, "[DRY-RUN] oc annotate kafkas.platform.confluent.io kafka", "block-reconcile=true")
    off = _lines_with(r.stdout, "[DRY-RUN] oc annotate kafkas.platform.confluent.io kafka", "block-reconcile-")
    assert on and off and on[0] < off[0]
    assert "theirs" not in r.stdout


def test_x7_approve_dry_run_patches_the_init_image_of_component_crs_only(run):
    plan = {"metadata": {"name": "install-up", "namespace": NS},
            "spec": {"approved": False, "clusterServiceVersionNames": ["confluent-for-kubernetes.v3.4.1"]},
            "status": {"phase": "RequiresApproval"}}
    r = run(f"zsh {U}/x.7_confluent_operator_upgrade.sh --approve --dry-run",
            responses=_x7_responses([_sub("confluent-for-kubernetes", "confluent-for-kubernetes")], plan))
    assert r.returncode == 0, r.out
    inits = [line for line in r.stdout.splitlines() if "[DRY-RUN] oc patch" in line and "image" in line]
    kinds = {line.split()[3] for line in inits}
    assert "kafkas.platform.confluent.io" in kinds and "connects.platform.confluent.io" in kinds, inits
    assert not any("kafkatopics" in k for k in kinds), inits
    assert all("confluentinc/confluent-init-container:3.4.1" in line for line in inits), inits
    assert "[DRY-RUN] persist CONFLUENT_OPERATOR_INIT_IMAGE=${CONFLUENT_REGISTRY}/confluent-init-container:3.4.1" in r.stdout
    assert r.writes == []


def test_x7_set_approval_dry_run_prints_the_patch_and_refuses_foreign(run):
    subs = [_sub("confluent-for-kubernetes", "confluent-for-kubernetes"),
            _sub("other-cfk", "confluent-for-kubernetes", owner=None)]
    r = run(f"zsh {U}/x.7_confluent_operator_upgrade.sh --set-approval automatic --persist --dry-run",
            responses=_x7_responses(subs))
    assert r.returncode == 2, r.out
    assert ("  [DRY-RUN] oc patch subscriptions.operators.coreos.com confluent-for-kubernetes -n confluent --type=merge "
            "-p {\"spec\":{\"installPlanApproval\":\"Automatic\"}}") in r.stdout
    assert "[BLOCKED] Subscription other-cfk in confluent is not ours" in r.stderr
    assert "[DRY-RUN] persist CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL=Automatic" in r.stdout
    assert "Manual" in run.vars.read_text() and "Automatic" not in run.vars.read_text()
    assert r.writes == []


def test_x7_refuses_scripts_mode(run):
    r = run(f"zsh {U}/x.7_confluent_operator_upgrade.sh", env={"CONFLUENT_DEPLOY_MODE": "scripts"})
    assert (r.returncode, r.stderr.strip()) == (1, "[ERROR] x.7 manages OLM operators - operator mode only.")


# ---------------------------------------------------------------------------------------------------------------
# x.8
# ---------------------------------------------------------------------------------------------------------------
def test_x8_dry_run_order(run):
    resp = [{"tool": "oc", "match": rf"^get namespace {NS} -o name$", "stdout": f"namespace/{NS}\n"},
            {"tool": "oc", "match": rf"^get pvc -n {NS} -o jsonpath", "stdout": "confluent-broker-data-broker-0\nother\n"}]
    r = run(f"zsh {U}/x.8_confluent_wipe_scripts_mode.sh --dry-run", env={"CONFLUENT_DEPLOY_MODE": "scripts"},
            responses=resp)
    assert r.returncode == 0, r.out
    steps = [line for line in r.stdout.splitlines() if line.startswith("[") and "/" in line.split("]")[0]]
    assert [s.split("]")[0] + "]" for s in steps] == [f"[{i}/11]" for i in range(1, 12)]
    order = [line.split()[3] for line in r.stdout.splitlines() if line.startswith("  [DRY-RUN] oc delete ")]
    assert order == ["deployment", "statefulset", "service", "service", "route", "networkpolicy", "configmap",
                     "configmap", "pod", "secret", "pvc"]
    assert "confluent-registry" not in " ".join(line for line in r.stdout.splitlines() if "oc delete secret" in line)
    assert "broker-0-external broker-1-external broker-2-external" in r.stdout
    assert "[DRY-RUN] oc delete pvc confluent-broker-data-broker-0" in r.stdout
    assert "next: re-run" in r.stdout and "CONFLUENT_DEPLOY_MODE=operator" in r.stdout
    assert r.writes == []


def test_x8_unconfirmed_data_delete_deletes_nothing(run):
    resp = [{"tool": "oc", "match": rf"^get namespace {NS} -o name$", "stdout": f"namespace/{NS}\n"},
            {"tool": "oc", "match": rf"^get pvc -n {NS} -o jsonpath", "stdout": "confluent-broker-data-broker-0\n"}]
    r = run(f"zsh {U}/x.8_confluent_wipe_scripts_mode.sh --yes --confirm-delete-data wrong-ns",
            env={"CONFLUENT_DEPLOY_MODE": "scripts"}, responses=resp)
    assert r.returncode == 1, r.out
    assert "does not match namespace" in r.stderr and "nothing deleted" in r.stdout
    assert r.writes == [], r.writes


def test_x8_refuses_a_namespace_with_cfk_crs(run):
    resp = [{"tool": "oc", "match": rf"^get namespace {NS} -o name$", "stdout": f"namespace/{NS}\n"},
            {"tool": "oc", "match": rf"^get kafkas\.platform\.confluent\.io -n {NS} -o name",
             "stdout": "kafka.platform.confluent.io/kafka\n"}]
    r = run(f"zsh {U}/x.8_confluent_wipe_scripts_mode.sh --dry-run", responses=resp)
    assert r.returncode == 2, r.out
    assert "[BLOCKED] Namespace confluent holds CFK CRs" in r.stderr
    assert "[DRY-RUN]" not in r.stdout and r.writes == []


# ---------------------------------------------------------------------------------------------------------------
# Shared x.2 / x.4 scripts: operator branches reach their dry-run exit without writes or shell errors
# ---------------------------------------------------------------------------------------------------------------
@pytest.mark.parametrize("cmd", ["x.2_confluent_add_auth.sh --dry-run", "x.2_confluent_add_auth_openshift.sh --dry-run",
                                 "x.2_confluent_add_sasl.sh --dry-run", "x.4_confluent_remove_mds.sh --dry-run --purge",
                                 "x.4_confluent_user_store.sh --dry-run"])
def test_shared_scripts_operator_branch_dry_run(run, cmd):
    r = run(f"zsh {U}/{cmd}", responses=_platform_responses())
    assert r.returncode == 0, r.out
    assert "[INFO] --dry-run" in r.stdout, r.out
    assert not any(bad in r.stderr for bad in ("command not found", "parameter not set", "bad substitution")), r.stderr
    assert r.writes == [] and not any(c.startswith("oc get sts broker") for c in r.calls)


# ---------------------------------------------------------------------------------------------------------------
# x.3 (operator twin)
# ---------------------------------------------------------------------------------------------------------------
CONNECT_CR = [{"tool": "oc", "match": rf"^get connects\.platform\.confluent\.io connect -n {NS} -o name",
               "stdout": "connect.platform.confluent.io/connect\n"}]


def test_x3_hub_source_updates_the_state_file(run):
    state = run.tmp / "cfg/confluent_connect_state.json"
    r = run(f"zsh {U}/x.3_confluent_add_connector.sh confluentinc/kafka-connect-datagen:0.6.7 --no-restart",
            responses=CONNECT_CR)
    assert r.returncode == 0, r.out
    data = json.loads(state.read_text())
    assert data["plugins"]["confluentHub"] == [{"owner": "confluentinc", "name": "kafka-connect-datagen", "version": "0.6.7"}]
    assert data["local_plugins"] == {"enabled": False, "pvc": "connect-plugins", "dirs": []}
    assert state.stat().st_mode & 0o777 == 0o600
    assert r.writes == []
    # a second add of the same plugin needs --force
    r2 = run(f"zsh {U}/x.3_confluent_add_connector.sh confluentinc/kafka-connect-datagen:0.6.8 --no-restart",
             responses=CONNECT_CR)
    assert r2.returncode == 1 and "already installed" in r2.stderr
    assert json.loads(state.read_text())["plugins"]["confluentHub"][0]["version"] == "0.6.7"


def test_x3_dry_run_renders_the_connect_cr_from_the_new_state(run, tmp_path):
    plugin = tmp_path / "my-plugin"
    (plugin / "lib").mkdir(parents=True)
    (plugin / "lib/x.jar").write_text("jar")
    r = run(f"zsh {U}/x.3_confluent_add_connector.sh confluentinc/kafka-connect-datagen:0.6.7 {plugin} --dry-run",
            responses=CONNECT_CR)
    assert r.returncode == 0, r.out
    out = r.stdout
    assert "[DRY-RUN] Connect CR from the new state" in out, r.out
    assert "confluentHub:" in out and "name: kafka-connect-datagen" in out and "version: 0.6.7" in out
    assert "claimName: connect-plugins" in out and "mountPath: /mnt/local-plugins" in out
    assert "plugin.path=/usr/share/java,/usr/share/confluent-hub-components,/mnt/plugins,/mnt/local-plugins" in out
    assert "[DRY-RUN] oc apply -f" in out and "connect-plugins-loader" in out
    assert not (run.tmp / "cfg/confluent_connect_state.json").exists()
    # only server dry-runs reach oc (contract 1.6)
    assert r.writes and all("--dry-run=server" in w for w in r.writes), r.writes


# ---------------------------------------------------------------------------------------------------------------
# x.2_confluent_add_sasl.sh --rotate in operator mode: client users only (lead fix 2026-11-18)
# ---------------------------------------------------------------------------------------------------------------
def test_x2_sasl_rotate_in_operator_mode_rotates_clients_only(run):
    r = run(f"zsh {U}/x.2_confluent_add_sasl.sh --rotate --dry-run", responses=_platform_responses())
    assert r.returncode == 0, r.out
    assert "[INFO] Operator mode: --rotate regenerates the client passwords only (app-client)." in r.stdout, r.out
    assert "is NOT rotated" in r.stdout and r.writes == []


def test_x2_sasl_rotate_in_operator_mode_without_clients_refuses(run):
    r = run(f"zsh {U}/x.2_confluent_add_sasl.sh --rotate --clients , --dry-run", responses=_platform_responses())
    assert r.returncode == 1, r.out
    assert "no client users are configured" in r.stderr and r.writes == []


def test_x0_delete_crds_still_runs_when_the_namespace_is_already_gone(run):
    # Live clean-up test 2026-11-18: after a full uninstall the namespace is gone, and `x.0 --delete-crds`
    # stopped at "nothing to uninstall" without reaching the CRD step.
    responses = [{"tool": "oc", "match": rf"^get namespace {NS}", "rc": 1,
                  "stderr": f'Error from server (NotFound): namespaces "{NS}" not found\n'},
                 {"tool": "oc", "match": r"^api-resources --api-group=platform\.confluent\.io",
                  "stdout": "kafkas.platform.confluent.io\nkraftcontrollers.platform.confluent.io\n"},
                 {"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com -A", "stdout": '{"items": []}'}]
    r = run(f"zsh {U}/x.0_confluent_uninstall.sh --dry-run --delete-crds", responses=responses,
            env={"DO_FLINK_UNINSTALL": "false"})
    assert r.returncode == 0, r.out
    assert "does not exist - nothing to uninstall" in r.stdout
    assert "[DRY-RUN] oc delete crd kafkas.platform.confluent.io" in r.stdout
    assert "[DRY-RUN] oc delete crd kraftcontrollers.platform.confluent.io" in r.stdout
    assert "flink.apache.org" not in r.stdout          # Flink add-on not configured: its CRDs are not offered


def test_x0_delete_crds_offers_both_groups_independently_with_flink_configured(run):
    # User request 2026-11-18: one yes/no per CRD group, and the second group is still checked whatever
    # the first answer or result was (here the platform group is refused while a CSV uses it).
    responses = [{"tool": "oc", "match": rf"^get namespace {NS}", "rc": 1,
                  "stderr": f'Error from server (NotFound): namespaces "{NS}" not found\n'},
                 {"tool": "oc", "match": r"^api-resources --api-group=platform\.confluent\.io",
                  "stdout": "kafkas.platform.confluent.io\n"},
                 {"tool": "oc", "match": r"^api-resources --api-group=flink\.apache\.org",
                  "stdout": "flinkdeployments.flink.apache.org\n"},
                 {"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com -A",
                  "stdout": json.dumps({"items": [{"metadata": {"name": "confluent-for-kubernetes.v3.4.0",
                                                                "namespace": "other"}, "status": {}}]})}]
    r = run(f"zsh {U}/x.0_confluent_uninstall.sh --dry-run --delete-crds", responses=responses,
            env={"DO_FLINK_UNINSTALL": "false", "PROJECT_CONFLUENT_FLINK": "confluent-flink",
                 "FLINK_CMF_CHART_VERSION": "2.5.0"})
    assert "The platform.confluent.io CRDs are still in use" in r.stdout + r.stderr, r.out
    assert "[DRY-RUN] oc delete crd kafkas.platform.confluent.io" not in r.stdout
    assert "checking the flink.apache.org CRDs" in r.stdout
    assert "[DRY-RUN] oc delete crd flinkdeployments.flink.apache.org" in r.stdout
    assert r.returncode == 2                             # the refused group is still reported
