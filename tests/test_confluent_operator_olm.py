"""confluent_operator_olm.py from OLM / Helm fixtures (contract §3.4): detect, gates, InstallPlans, channels, autoselect."""

import json
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src/helpers"))
import confluent_operator_config as cfg
import confluent_operator_olm as olm

FIX = REPO / "tests/fixtures/confluent_operator"
CFK, FKO = olm.PKG_CFK, olm.PKG_FKO
EMPTY = {"items": []}


def load(name):
    return json.loads((FIX / name).read_text())


def detect(package, ns, csvs=EMPTY, ogs=EMPTY, subs=EMPTY, helm=None, values=None, owner="local.confluent"):
    return olm.detect(package, ns, csvs, ogs, subs, helm or [], values or {}, owner)


def test_detect_none_on_an_empty_cluster():
    r = detect(CFK, "confluent")
    assert r["result"] == "none" and r["others"] == []


def test_detect_reuse_of_the_eval_install_and_copied_csvs_filtered():
    csvs, ogs, subs = load("csvs_eval.json"), load("ogs_eval.json"), load("subs_eval.json")
    r = detect(CFK, "cfk-eval", csvs, ogs, subs)
    assert (r["result"], r["ns"], r["csv"], r["version"], r["channel"]) == \
        ("reuse", "cfk-eval", "confluent-for-kubernetes.v3.4.0", "3.4.0", "3.4")
    assert r["owned"] is False and r["sub"] == "confluent-for-kubernetes"
    # the Copied CFK CSV in "confluent" (watched by confluent-og) must not count as a watcher
    r = detect(CFK, "confluent", csvs, ogs, subs)
    assert r["result"] == "none"
    assert [o["ns"] for o in r["others"]] == ["cfk-eval"]


def test_detect_reuse_of_our_install_is_owned():
    r = detect(CFK, "confluent", load("csvs_ours.json"), load("ogs_ours.json"), load("subs_ours.json"))
    assert r["result"] == "reuse" and r["owned"] is True


def test_detect_resumes_our_unfinished_install_and_blocks_a_foreign_one():
    csvs = load("csvs_ours.json")
    csvs["items"][0]["status"]["phase"] = "Installing"
    r = detect(CFK, "confluent", csvs, load("ogs_ours.json"), load("subs_ours.json"))
    assert r["result"] == "none" and "resuming" in r["reason"]
    r = detect(CFK, "confluent", csvs, load("ogs_ours.json"), load("subs_ours.json"), owner="someone.else")
    assert r["result"] == "conflict" and "Installing" in r["reason"]


def test_detect_foreign_operatorgroup_scope():
    r = detect(CFK, "confluent", load("csvs_ours.json"), load("ogs_foreign.json"))
    assert r["result"] == "conflict" and r["reason"].startswith("foreign OperatorGroup scope")


def test_detect_two_watchers():
    r = detect(CFK, "confluent", load("csvs_two.json"), load("ogs_two.json"))
    assert r["result"] == "conflict" and r["reason"].startswith("two operators watch confluent")


def test_detect_helm_fko_overlap_blocks_cp_fko():
    r = detect(FKO, "confluent-flink", helm=load("helm_scripts_flink.json"), values=load("helm_values_fko.json"))
    assert r["result"] == "conflict" and "cp-flink-kubernetes-operator" in r["reason"]
    # watching another namespace only: no overlap
    r = detect(FKO, "other-ns", helm=load("helm_scripts_flink.json"), values=load("helm_values_fko.json"))
    assert r["result"] == "none"
    # empty watchNamespaces = every namespace
    r = detect(FKO, "other-ns", helm=load("helm_scripts_flink.json"),
               values={"confluent-flink/cp-flink-kubernetes-operator": {}})
    assert r["result"] == "conflict"


def test_detect_community_flink_operator_blocks_cp_fko():
    r = detect(FKO, "confluent-flink", load("csvs_community.json"), load("ogs_community.json"))
    assert r["result"] == "conflict" and "community flink-kubernetes-operator" in r["reason"]


def test_detect_helm_cfk_in_the_namespace_blocks_cfk():
    helm = [{"name": "cfk", "namespace": "confluent", "chart": "confluent-for-kubernetes-0.2038.1"}]
    assert detect(CFK, "confluent", helm=helm)["result"] == "conflict"
    assert detect(CFK, "elsewhere", helm=helm)["result"] == "none"


def test_version_gate():
    csvs = load("csvs_version_mismatch.json")
    r = olm.version_gate(FKO, "1.16.1-cp1", csvs)
    assert r["ok"] is False and {f["version"] for f in r["found"]} == {"1.15.0-cp4", "1.16.1-cp1"}
    assert olm.version_gate(CFK, "3.4.0", load("csvs_eval.json"))["ok"] is True
    # spec.version without the "-cp1" the CSV name carries still matches by name
    short = {"items": [{"metadata": {"name": "cp-fko.v1.16.1-cp1", "namespace": "a"}, "spec": {"version": "1.16.1"}}]}
    assert olm.version_gate(FKO, "1.16.1-cp1", short)["ok"] is True


def test_installplan_check():
    ours = olm.installplan_check(load("installplan_ours.json"), ["confluent-for-kubernetes.v3.4.0", "cp-fko.v1.16.1-cp1"])
    assert ours["approve"] is True and ours["extra"] == []
    extra = olm.installplan_check(load("installplan_extra.json"), ["confluent-for-kubernetes.v3.4.0"])
    assert extra["approve"] is False and extra["extra"] == ["other-operator.v2.0.0"]
    assert olm.installplan_check({"spec": {}}, ["x"])["approve"] is False


def test_channel_info():
    pm = load("pm_cfk.json")
    ok = olm.channel_info(pm, CFK, "certified-operators", "3.4", "confluent-for-kubernetes.v3.4.0")
    assert ok["found"] and ok["channel_found"] and ok["starting_csv_ok"] and ok["head"] == "confluent-for-kubernetes.v3.4.0"
    assert olm.channel_info(pm, CFK, "certified-operators", "9.9", "")["channel_found"] is False
    assert olm.channel_info(pm, CFK, "certified-operators", "3.3", "confluent-for-kubernetes.v3.4.0")["starting_csv_ok"] is False
    assert olm.channel_info(pm, CFK, "my-mirror", "3.4", "")["found"] is False
    head = olm.channel_info(pm, CFK, "certified-operators", "", "")
    assert head["channel"] == "3.4" and head["starting_csv_ok"] is True


def test_og_check():
    assert olm.og_check(EMPTY, "confluent")["result"] == "none"
    assert olm.og_check(load("ogs_ours.json"), "confluent")["result"] == "own"
    assert olm.og_check(load("ogs_foreign.json"), "confluent")["result"] == "foreign"
    assert olm.og_check(load("ogs_two.json"), "openshift-operators")["targets"] == "all"


def test_autoselect_picks_the_newest_compatible_set():
    catalog = cfg.operator_catalog()
    index = yaml.safe_load((FIX / "helm_index.yaml").read_text())
    r = olm.autoselect(load("pm_cfk.json"), load("pm_fko.json"), index, catalog)
    # CFK 3.5 is offered but has no compat entry; CMF 2.6 has no pairing; 2.5.2-rc1 is a pre-release
    assert r["chosen"]["CONFLUENT_OPERATOR_CHANNEL"] == "3.4"
    assert r["chosen"]["FLINK_CMF_CHART_VERSION"] == "2.5.1"
    assert r["chosen"]["FLINK_OLM_CHANNEL"] == "stable-v1.16"
    assert r["chosen"]["FLINK_OLM_STARTING_CSV"] == "cp-fko.v1.16.1-cp2"
    assert r["pinned"]["FLINK_CMF_CHART_VERSION"] == "2.5.0"
    assert any("3.5" in n for n in r["notes"])
    no_index = olm.autoselect(load("pm_cfk.json"), load("pm_fko.json"), None, catalog)
    assert no_index["chosen"]["FLINK_CMF_CHART_VERSION"] == "2.5.0"


def test_sub_env_merge_keeps_other_entries():
    sub = load("subs_ours.json")["items"][0]
    state, patch = olm.sub_env_merge(sub, {"ENABLE_CMF_DAY2_OPS": "true"})
    assert state == "patch"
    assert patch == {"spec": {"config": {"env": [{"name": "OTHER", "value": "1"},
                                                  {"name": "ENABLE_CMF_DAY2_OPS", "value": "true"}]}}}
    assert olm.sub_env_merge(sub, {"OTHER": "1"})[0] == "present"
    assert olm.sub_env_merge({}, {"X": "1"})[0] == "absent"


def test_installplan_others_names_the_other_package_csvs():
    plan = load("installplan_extra.json")
    assert olm.installplan_others(plan, CFK) == ["other-operator.v2.0.0"]
    shared = {"spec": {"clusterServiceVersionNames": ["confluent-for-kubernetes.v3.4.1", "cp-fko.v1.16.2-cp1"]}}
    assert olm.installplan_others(shared, FKO) == ["confluent-for-kubernetes.v3.4.1"]
    assert olm.installplan_others({}, CFK) == []


def test_retain_plan_maps_stateful_crs_to_their_data_pvs():
    def pvc(name, pv=""):
        return {"metadata": {"name": name}, "spec": {"volumeName": pv} if pv else {}}
    pvcs = {"items": [pvc("data0-kafka-0", "pv-k0"), pvc("data0-kafka-1", "pv-k1"), pvc("data0-kafka-x"),
                      pvc("data-ksqldb-server-0", "pv-q0"), pvc("data0-control-center-0", "pv-c0"),
                      pvc("prometheus-data-control-center-0", "pv-p0"), pvc("data0-kraftcontroller-0"),
                      pvc("connect-plugins", "pv-cp"), pvc("data0-kafka-other-0", "pv-o")]}
    out = olm.retain_plan(pvcs, ["Kafka/kafka", "KsqlDB/ksqldb-server", "ControlCenter/control-center",
                                 "KRaftController/kraftcontroller", "Connect/connect", "Kafka/gone"])
    assert out == [("Kafka/kafka", "data0-kafka-0", "pv-k0"), ("Kafka/kafka", "data0-kafka-1", "pv-k1"),
                   ("KsqlDB/ksqldb-server", "data-ksqldb-server-0", "pv-q0"),
                   ("ControlCenter/control-center", "data0-control-center-0", "pv-c0"),
                   ("ControlCenter/control-center", "prometheus-data-control-center-0", "pv-p0"),
                   ("KRaftController/kraftcontroller", "data0-kraftcontroller-0", ""),
                   ("Kafka/gone", "", "")]


def test_live_json_keeps_only_object_values(tmp_path):
    (tmp_path / "list.json").write_text("[1, 2]")
    (tmp_path / "state.json").write_text('{"schema_version": 1}')
    (tmp_path / "env.json").write_text('{"spec": {"secrets": ["x"]}}')
    out = tmp_path / "live.json"
    r = subprocess.run([sys.executable, "-I", str(REPO / "src/helpers/confluent_operator_olm.py"), "live-json",
                        "--out", str(out), "--route-domain", "apps.example.com", "--related-images",
                        str(tmp_path / "list.json"), "--connect-state", str(tmp_path / "state.json"),
                        "--flink-env", str(tmp_path / "env.json")],
                       check=False, capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    assert json.loads(out.read_text()) == {"route_domain": "apps.example.com", "connect_state": {"schema_version": 1}}
    assert "related_images left out" in r.stderr


@pytest.mark.parametrize("args,needle", [
    (["detect", "--package", CFK, "--namespace", "cfk-eval", "--csvs", "csvs_eval.json",
      "--ogs", "ogs_eval.json", "--subs", "subs_eval.json", "--owner", "x", "--format", "shell"], "CFO_RESULT=reuse"),
    (["guard-flink", "--helm", "helm_scripts_flink.json"], "fko cp-flink-kubernetes-operator"),
    (["installplan-check", "--plan", "installplan_extra.json", "--expect", "confluent-for-kubernetes.v3.4.0"],
     '"approve": false'),
    (["installplan-others", "--plan", "installplan_extra.json", "--package", CFK], "other-operator.v2.0.0"),
    (["autoselect", "--cfk-pm", "pm_cfk.json", "--fko-pm", "pm_fko.json", "--helm-index", "helm_index.yaml",
      "--format", "lines"], "FLINK_CMF_CHART_VERSION\t2.5.0\t2.5.1"),
])
def test_cli(args, needle):
    r = subprocess.run([sys.executable, "-I", str(REPO / "src/helpers/confluent_operator_olm.py"), *args],
                       check=False, cwd=FIX, capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    assert needle in r.stdout


def test_front_proxy_mode_of_a_rendered_repo_manifest():
    name = "control-center-auth"
    dep = {"kind": "Deployment", "name": name}
    conf = {"kind": "File", "name": f"{name}-nginx.conf"}
    assert olm.front_proxy_mode({"files": [conf, dep]}, name) == "basic"
    assert olm.front_proxy_mode({"files": [dep]}, name) == "openshift"
    assert olm.front_proxy_mode({"files": [conf]}, name) == "none"
    assert olm.front_proxy_mode({}, name) == "none"
