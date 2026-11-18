"""Flink add-on in operator mode (WP-F, contract §5.6, §7.1): full installer, 1.0/1.1/1.3, x.0 (both), x.3, x.4.

Every script runs in a temp copy of the repo (scripts/, src/helpers, env_bootstrap.sh; the venv is symlinked) with
the fake oc/helm/curl/confluent of tests/fakes/confluent first on PATH, a temp HOME/TMPDIR/MCM state and a
generated confluent_vars.sh in the copy's configs/. Nothing reaches a cluster or the real configs/.
"""

import json
import os
import re
import shutil
import subprocess
import types
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[1]
FAKE_TOOL = REPO / "tests/fakes/confluent/fake_tool.py"
F = "scripts/install_confluent_platform/install_confluent_platform_flink_addon"
FU = f"{F}/utility_scripts_confluent_flink"
WRITE_VERBS = {"apply", "create", "delete", "patch", "label", "annotate", "adm", "secrets", "exec", "rollout",
               "wait", "set", "scale", "replace"}
OVERRIDES = """
# --- test overrides -----------------------------------------------------------
export OC_LOGIN="true"
export FLINK_CMF_STORAGE_CLASS="blk"
export FLINK_STATE_STORAGE_CLASS="fil"
export FLINK_ENVIRONMENT_DELETE_WAIT="20"
export CFO_POLL_INTERVAL="10"
"""
CLI_OK = [{"tool": "confluent", "match": r"^version", "stdout": "Version: v4.74.0\n"},
          {"tool": "helm", "match": r"^version", "stdout": "v3.16.0"}]


def _base_env(home):
    return {"HOME": str(home), "PATH": f"{home / 'bin'}:/usr/bin:/bin", "TMPDIR": f"{home / 'tmp'}/",
            "_CP4D_PREP_DONE": "1", "ENV_SETUP_QUIET": "1", "LANG": "en_US.UTF-8", "TZ": "UTC",
            "MCM_STATE_FILE": str(home / "mcm" / "multi_cluster_management.sh"), "PYTHONDONTWRITEBYTECODE": "1"}


@pytest.fixture(scope="module")
def tree(tmp_path_factory):
    root = tmp_path_factory.mktemp("flink-repo")
    ignore = shutil.ignore_patterns("__pycache__", "confluent_platform_vars", "flink_vars")
    shutil.copytree(REPO / "scripts", root / "scripts", ignore=ignore, symlinks=True)
    shutil.copytree(REPO / "src/helpers", root / "src/helpers", ignore=ignore)
    for name in ("env_bootstrap.sh", "pyproject.toml"):
        shutil.copy2(REPO / name, root / name)
    (root / ".venv").symlink_to(REPO / ".venv")
    home = tmp_path_factory.mktemp("flink-gen-home")
    (home / "tmp").mkdir()
    env = _base_env(home)
    env["PATH"] = "/usr/bin:/bin"
    for cmd in (["zsh", "scripts/install_confluent_platform/0_confluent_prepare_template_config.sh", "--size", "small",
                 "--cluster-id", "AAAAAAAAAAAAAAAAAAAAAA"],
                ["zsh", f"{F}/0_flink_prepare_template_config.sh", "--size", "small"]):
        subprocess.run(cmd, cwd=root, env=env, check=True, capture_output=True, text=True, timeout=120)
    cfg = root / "configs/confluent_platform_config/confluent_vars.sh"
    return types.SimpleNamespace(root=root, base_vars=cfg.read_text() + OVERRIDES)


@pytest.fixture
def run(tree, tmp_path):
    home = tmp_path
    (home / "bin").mkdir()
    (home / "tmp").mkdir()
    for name in ("oc", "kubectl", "helm", "curl", "confluent", "podman", "skopeo", "sleep"):
        (home / "bin" / name).symlink_to(FAKE_TOOL)
    log = home / "calls.log"
    cfg = tree.root / "configs/confluent_platform_config/confluent_vars.sh"
    details = tree.root / "configs/confluent_platform_config/confluent_flink_instance_details.sh"

    def _run(script, *args, extra_vars="", env=None, responses=None):
        cfg.write_text(tree.base_vars + extra_vars)
        if log.exists():
            log.unlink()
        full = _base_env(home)
        full["FAKE_LOG"] = str(log)
        if responses is not None:
            path = home / "responses.json"
            path.write_text(json.dumps(responses))
            counts = Path(str(path) + ".counts")
            if counts.exists():
                counts.unlink()
            full["FAKE_RESPONSES"] = str(path)
        full.update(env or {})
        r = subprocess.run(["zsh", script, *args], cwd=tree.root, env=full, capture_output=True, text=True, timeout=180,
                           check=False)
        r.calls = log.read_text().splitlines() if log.exists() else []
        r.writes = [c for c in r.calls if c.split()[0] in ("oc", "kubectl") and len(c.split()) > 1
                    and c.split()[1] in WRITE_VERBS and c.split()[1:3] != ["rollout", "status"]]
        return r

    yield _run
    if details.exists():   # sourced by every later run of the tree (source_env_setup.sh)
        details.unlink()


def _steps(stdout):
    return re.findall(r"^\[INFO\]   \[(?:run |skip|off )\] (\S+)", stdout, flags=re.MULTILINE)


# ---------------------------------------------------------------------------------------------------------------
# Full installer
# ---------------------------------------------------------------------------------------------------------------
def test_full_installer_lists_the_operator_step_first_in_operator_mode(run):
    r = run(f"{F}/full_installprocess-confluent_flink.sh", "--list-steps")
    assert r.returncode == 0, r.stdout + r.stderr
    assert _steps(r.stdout) == ["operator", "prep", "install", "status", "instance-details"]
    assert "Flink operator: cp-fko via OLM (olm" in r.stdout
    assert r.calls == []


def test_full_installer_scripts_mode_has_no_operator_step_and_rejects_the_flags(run):
    scripts = '\nexport CONFLUENT_DEPLOY_MODE="scripts"\n'
    r = run(f"{F}/full_installprocess-confluent_flink.sh", "--list-steps", extra_vars=scripts)
    assert r.returncode == 0, r.stdout + r.stderr
    assert _steps(r.stdout) == ["prep", "install", "status", "instance-details"]
    assert "Operator chart:" in r.stdout
    bad = run(f"{F}/full_installprocess-confluent_flink.sh", "--list-steps", "--autoselect-latest",
              extra_vars=scripts)
    assert bad.returncode != 0 and "--autoselect-latest" in bad.stderr


def test_full_installer_autoselect_needs_persist(run):
    r = run(f"{F}/full_installprocess-confluent_flink.sh", "--list-steps", "--autoselect-latest")
    assert r.returncode == 1
    assert "--autoselect-latest in the full installer needs --persist" in r.stderr
    ok = run(f"{F}/full_installprocess-confluent_flink.sh", "--list-steps", "--autoselect-latest", "--persist")
    assert ok.returncode == 0, ok.stdout + ok.stderr
    assert _steps(ok.stdout)[0] == "operator"


# ---------------------------------------------------------------------------------------------------------------
# 1.0 / 1.1 dry runs
# ---------------------------------------------------------------------------------------------------------------
def test_flink_1_0_dry_run_operator_mode_grants_no_anyuid_and_skips_cert_manager(run):
    r = run(f"{F}/1.0_flink_prep.sh", "--dry-run", responses=CLI_OK)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "anyuid" not in r.stdout + r.stderr
    assert "[INFO] olm: cert-manager not required" in r.stdout
    assert "[DRY-RUN] oc create serviceaccount confluent-manager-for-apache-flink" in r.stdout
    assert "serviceaccount flink-operator" not in r.stdout
    assert r.writes == []
    cani = [c for c in r.calls if c.startswith("oc auth can-i")]
    assert cani == ["oc auth can-i create subscriptions.operators.coreos.com -n confluent-flink",
                    "oc auth can-i create operatorgroups.operators.coreos.com -n confluent-flink"]
    assert not any("cert-manager" in c for c in r.calls)
    # H11: only the CMF chart comes from Helm
    assert "Charts verified" not in r.stdout


def test_flink_1_1_dry_run_operator_mode_cmf_args_and_no_helm_operator(run):
    r = run(f"{F}/1.1_flink_install.sh", "--dry-run")
    assert r.returncode == 0, r.stdout + r.stderr
    line = next(ln for ln in r.stdout.splitlines() if "[DRY-RUN] helm upgrade --install" in ln)
    assert "--set podSecurity.securityContext.fsGroup=null --set podSecurity.securityContext.runAsUser=null" in line
    assert "--set watchNamespaces={confluent-flink}" in line
    assert "runAsNonRoot" not in line
    assert line.count("helm upgrade --install") == 1 and " cmf " in line
    assert "cp-flink-kubernetes-operator" not in r.stdout
    assert "[DRY-RUN] oc apply ConfigMap confluent-ibm-scripts-deploy-mode -n confluent-flink" in r.stdout
    assert r.stdout.index("ConfigMap confluent-ibm-scripts-deploy-mode") < r.stdout.index("helm upgrade --install")
    assert "[DRY-RUN] render set flink" in r.stdout          # CMF resources as CFK CRs (default with olm)
    assert "anyuid" not in r.stdout
    assert r.writes == []
    assert not any(c.startswith(("helm upgrade", "helm install")) for c in r.calls)


def test_flink_1_1_dry_run_scripts_mode_keeps_the_helm_operator(run):
    r = run(f"{F}/1.1_flink_install.sh", "--dry-run", extra_vars='\nexport CONFLUENT_DEPLOY_MODE="scripts"\n')
    assert r.returncode == 0, r.stdout + r.stderr
    lines = [ln for ln in r.stdout.splitlines() if "[DRY-RUN] helm upgrade --install" in ln]
    assert len(lines) == 2 and "cp-flink-kubernetes-operator" in lines[0]
    assert "--set podSecurity.securityContext.runAsNonRoot=null" in lines[1]
    assert "fsGroup=null" not in lines[1]
    assert "confluent-ibm-scripts-deploy-mode" not in r.stdout and "render set flink" not in r.stdout
    bad = run(f"{F}/1.1_flink_install.sh", "--autoselect-latest", extra_vars='\nexport CONFLUENT_DEPLOY_MODE="scripts"\n')
    assert bad.returncode == 1 and "[ERROR] Unknown argument '--autoselect-latest'. Use --help." in bad.stderr


@pytest.mark.parametrize("helm_version,forced", [("v4.2.3", True), ("v3.16.0", False)])
def test_flink_1_1_cmf_upgrade_forces_conflicts_only_on_helm_4(run, helm_version, forced):
    """Both modes (user decision 2026-11-18): Helm 4's server-side apply refuses the probe fields 1.1 patches
    after every upgrade, so re-runs failed; Helm 3 must keep the old argument list."""
    for mode in ("scripts", "operator"):
        r = run(f"{F}/1.1_flink_install.sh", "--dry-run", extra_vars=f'\nexport CONFLUENT_DEPLOY_MODE="{mode}"\n',
                responses=[{"tool": "helm", "match": r"^version", "stdout": helm_version}] + CLI_OK[:1])
        assert r.returncode == 0, r.stdout + r.stderr
        cmf = [ln for ln in r.stdout.splitlines() if "[DRY-RUN] helm upgrade --install" in ln and " cmf " in ln]
        assert len(cmf) == 1, r.stdout
        assert ("--force-conflicts" in cmf[0]) is forced, (mode, cmf[0])
        assert all("--force-conflicts" not in ln for ln in r.stdout.splitlines()
                   if "cp-flink-kubernetes-operator" in ln)


# ---------------------------------------------------------------------------------------------------------------
# x.0 (scripts twin dispatch + O24, operator twin)
# ---------------------------------------------------------------------------------------------------------------
X0_RESPONSES = [
    {"tool": "oc", "match": r"^get flinkapplications\.platform\.confluent\.io -n confluent-flink -o jsonpath=",
     "stdout": "app1|local.confluent|cp-env\n"},
    {"tool": "oc", "match": r"^get flinkenvironments\.platform\.confluent\.io cp-env -n confluent-flink -o jsonpath=",
     "stdout": "cp-env|local.confluent"},
    {"tool": "oc", "match": r"^get cmfrestclasses\.platform\.confluent\.io default -n confluent-flink -o jsonpath=",
     "stdout": "default|local.confluent"},
    {"tool": "oc", "match": r"^get flinkdeployments\.flink\.apache\.org -n confluent-flink -o name",
     "stdout": "flinkdeployment.flink.apache.org/fd1\n"},
    {"tool": "oc", "match": r"^get subscriptions\.operators\.coreos\.com -n confluent-flink -l ",
     "stdout": "cp-fko|cp-fko|cp-fko.v1.16.1-cp1\n"},
]


def test_operator_x0_dry_run_order(run):
    r = run(f"{FU}/x.0_flink_uninstall.sh", "--dry-run", "--remove-operator", responses=X0_RESPONSES)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "(operator mode)" in r.stdout
    headers = re.findall(r"^\[(\d)/9\]", r.stdout, flags=re.MULTILINE)
    assert headers == [str(i) for i in range(1, 10)]
    order = ["oc delete flinkapplications.platform.confluent.io app1",
             "curl -X DELETE <cmf>/cmf/api/v1/environments/cp-env",
             "oc delete flinkenvironments.platform.confluent.io cp-env",
             "platform.confluent.io/block-reconcile=true",
             "oc delete cmfrestclasses.platform.confluent.io default",
             "oc delete flinkdeployments.flink.apache.org fd1",
             "helm uninstall cmf -n confluent-flink",
             "oc delete configmap confluent-ibm-scripts-deploy-mode",
             "oc delete subscriptions.operators.coreos.com cp-fko",
             "oc delete namespace confluent-flink"]
    pos = [r.stdout.index(x) for x in order]
    assert pos == sorted(pos), list(zip(order, pos))
    assert "helm uninstall cp-flink-kubernetes-operator" not in r.stdout
    assert "oc delete crd" not in r.stdout and "cert-manager" not in r.stdout
    assert r.writes == []


def test_operator_x0_workaround_path_after_cmf_deleted_the_environment(run):
    env_get = r"^get flinkenvironments\.platform\.confluent\.io cp-env -n confluent-flink -o name$"
    responses = [
        {"tool": "oc", "match": r"^get flinkenvironments\.platform\.confluent\.io cp-env -n confluent-flink -o jsonpath=",
         "stdout": "cp-env|local.confluent"},
        {"tool": "oc", "match": env_get, "stdout": "flinkenvironment.platform.confluent.io/cp-env\n", "max": 3},
        {"tool": "oc", "match": env_get, "rc": 1, "stderr": "Error from server (NotFound): not found\n"},
        {"tool": "oc", "match": r"^get cmfrestclasses\.platform\.confluent\.io default -n confluent-flink -o name$",
         "rc": 1, "stderr": "Error from server (NotFound): not found\n"},
        {"tool": "curl", "match": r"-X DELETE \S+/cmf/api/v1/environments/cp-env$", "stdout": "204"},
        {"tool": "curl", "match": r"-o /dev/null -w %\{http_code\} \S+/cmf/api/v1/environments/cp-env$",
         "stdout": "404"},
    ]
    r = run(f"{FU}/x.0_flink_uninstall.sh", "--keep-project", env={"CMF_URL": "http://cmf.test"},
            responses=responses)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "[WORKAROUND] FlinkEnvironment/cp-env still present after 20s although CMF deleted the environment" in r.stdout
    env_writes = [w for w in r.writes if "flinkenvironments.platform.confluent.io" in w]
    assert [w.split()[1] for w in env_writes] == ["delete", "annotate", "delete", "patch"]
    assert "platform.confluent.io/block-reconcile=true" in env_writes[1]
    assert '{"metadata":{"finalizers":[]}}' in env_writes[3]
    assert "[INFO] Keeping namespace confluent-flink: --keep-project given" in r.stdout
    assert not any(w.startswith("oc delete namespace") for w in r.writes)


def test_operator_x0_stops_on_cmf_422_without_touching_the_cr(run):
    responses = [
        {"tool": "oc", "match": r"^get flinkenvironments\.platform\.confluent\.io cp-env -n confluent-flink -o jsonpath=",
         "stdout": "cp-env|local.confluent"},
        {"tool": "curl", "match": r"-X DELETE \S+/cmf/api/v1/environments/cp-env$", "stdout": "422"},
    ]
    r = run(f"{FU}/x.0_flink_uninstall.sh", env={"CMF_URL": "http://cmf.test"}, responses=responses)
    assert r.returncode == 1
    assert "CMF refused to delete environment cp-env (HTTP 422)" in r.stderr
    assert "uninstall stopped; nothing after step 4 ran" in r.stderr
    assert not [w for w in r.writes if "flinkenvironments" in w]
    assert "[5/9]" not in r.stdout
    assert not any(c.startswith("helm uninstall") for c in r.calls)


def test_scripts_x0_stays_in_scripts_mode_and_o24_names_olm_crds(run):
    scripts = '\nexport CONFLUENT_DEPLOY_MODE="scripts"\n'
    responses = [{"tool": "oc", "match": r"^get crd flinkdeployments\.flink\.apache\.org -o jsonpath=",
                  "stdout": "true"}]
    r = run(f"{FU}/x.0_flink_uninstall.sh", "--dry-run", "--keep-project", extra_vars=scripts, responses=responses)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "(operator mode)" not in r.stdout
    assert "[INFO] The flink.apache.org CRDs are OLM-managed (shared with cp-fko installs) - do not delete them." in r.stdout
    assert "oc delete crd flinkdeployments" not in r.stdout
    plain = run(f"{FU}/x.0_flink_uninstall.sh", "--dry-run", "--keep-project", extra_vars=scripts)
    assert "oc delete crd flinkdeployments.flink.apache.org flinksessionjobs.flink.apache.org" in plain.stdout
    assert "OLM-managed" not in plain.stdout


def test_operator_x0_keep_data_tolerates_a_cr_gone_right_after_the_delete(run):
    responses = [
        {"tool": "oc", "match": r"^get flinkenvironments\.platform\.confluent\.io cp-env -n confluent-flink -o jsonpath=",
         "stdout": "cp-env|local.confluent"},
        {"tool": "oc", "match": r"^get flinkenvironments\.platform\.confluent\.io cp-env -n confluent-flink -o name$",
         "rc": 1, "stderr": "Error from server (NotFound): not found\n"},
    ]
    r = run(f"{FU}/x.0_flink_uninstall.sh", "--keep-data", "--keep-project", responses=responses)
    assert r.returncode == 0, r.stdout + r.stderr
    env_writes = [w.split()[1] for w in r.writes if "flinkenvironments.platform.confluent.io" in w]
    assert env_writes == ["annotate", "delete"]          # no finalizer patch on a CR that is already gone
    assert not any(c.startswith("curl") and "-X DELETE" in c for c in r.calls)   # --keep-data keeps the CMF env


def test_operator_x0_remove_operator_takes_our_cfk_out_of_the_flink_ns_in_cli_mode(run):
    responses = [
        {"tool": "oc", "match": r"^get subscriptions\.operators\.coreos\.com -n confluent-flink -l ",
         "stdout": "confluent-for-kubernetes|confluent-for-kubernetes|confluent-for-kubernetes.v3.4.0\n"
                   "cp-fko|cp-fko|cp-fko.v1.16.1-cp1\n"},
    ]
    r = run(f"{FU}/x.0_flink_uninstall.sh", "--dry-run", "--remove-operator", responses=responses,
            extra_vars='\nexport FLINK_CMF_RESOURCE_MODE="cli"\n')
    assert r.returncode == 0, r.stdout + r.stderr
    assert "oc delete subscriptions.operators.coreos.com cp-fko -n confluent-flink" in r.stdout
    assert "oc delete subscriptions.operators.coreos.com confluent-for-kubernetes -n confluent-flink" in r.stdout
    assert r.writes == []


@pytest.mark.parametrize("script", [f"{F}/1.2_flink_status.sh", f"{F}/1.3_flink_get_instance_details.sh"])
def test_flink_status_and_details_run_the_guard_in_operator_mode(run, tree, script):
    helm = [{"name": "cp-flink-kubernetes-operator", "namespace": "confluent-flink",
             "chart": "flink-kubernetes-operator-1.150.3", "status": "deployed"}]
    responses = [{"tool": "helm", "match": r"^list -n confluent-flink -o json", "stdout": json.dumps(helm)}]
    r = run(script, responses=responses)
    assert r.returncode == 2, r.stdout + r.stderr
    assert "[BLOCKED]" in r.stderr
    assert not (tree.root / "configs/confluent_platform_config/confluent_flink_instance_details.sh").exists()
    assert r.writes == []


# ---------------------------------------------------------------------------------------------------------------
# 1.3, x.3, x.4
# ---------------------------------------------------------------------------------------------------------------
def _olm_objects():
    csv = {"apiVersion": "operators.coreos.com/v1alpha1", "kind": "ClusterServiceVersion",
           "metadata": {"name": "cp-fko.v1.16.1-cp1", "namespace": "confluent-flink"},
           "spec": {"version": "1.16.1-cp1"}, "status": {"phase": "Succeeded"}}
    og = {"kind": "OperatorGroup", "metadata": {"name": "confluent-flink-confluent-og", "namespace": "confluent-flink"},
          "spec": {"targetNamespaces": ["confluent-flink"]}, "status": {"namespaces": ["confluent-flink"]}}
    sub = {"kind": "Subscription",
           "metadata": {"name": "cp-fko", "namespace": "confluent-flink",
                        "labels": {"confluent.ibm-scripts/installed-by": "local.confluent"}},
           "spec": {"name": "cp-fko", "channel": "stable-v1.16"},
           "status": {"installedCSV": "cp-fko.v1.16.1-cp1", "currentCSV": "cp-fko.v1.16.1-cp1"}}
    return [
        {"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com -A -o json",
         "stdout": json.dumps({"items": [csv]})},
        {"tool": "oc", "match": r"^get operatorgroups\.operators\.coreos\.com -A -o json",
         "stdout": json.dumps({"items": [og]})},
        {"tool": "oc", "match": r"^get subscriptions\.operators\.coreos\.com -A -o json",
         "stdout": json.dumps({"items": [sub]})},
        {"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com cp-fko\.v1\.16\.1-cp1 -n "
                                r"confluent-flink -o jsonpath=\{\.spec\.version\}", "stdout": "1.16.1-cp1"},
        {"tool": "oc", "match": r"^get cmfrestclasses\.platform\.confluent\.io default -n confluent-flink -o jsonpath=",
         "stdout": "default"},
    ]


def test_flink_1_3_operator_mode_appends_the_deployed_keys(run, tree):
    r = run(f"{F}/1.3_flink_get_instance_details.sh", responses=_olm_objects())
    assert r.returncode == 0, r.stdout + r.stderr
    text = (tree.root / "configs/confluent_platform_config/confluent_flink_instance_details.sh").read_text()
    for line in ('export FLINK_OPERATOR_DEPLOYED_VERSION="1.16.1-cp1"',
                 'export FLINK_OPERATOR_DEPLOYED_SOURCE="olm"',
                 'export FLINK_OPERATOR_DEPLOYED_NAMESPACE="confluent-flink"',
                 'export FLINK_OPERATOR_DEPLOYED_CSV="cp-fko.v1.16.1-cp1"',
                 'export FLINK_OPERATOR_DEPLOYED_CHANNEL="stable-v1.16"',
                 'export FLINK_CMF_RESTCLASS_DEPLOYED="confluent-flink/default"'):
        assert line in text, text
    # never a config var name (source_env_setup.sh sources this after confluent_vars.sh)
    assert not re.search(r"^export FLINK_OPERATOR_SOURCE=|^export FLINK_CMF_RESOURCE_MODE=", text, flags=re.MULTILINE)
    assert r.writes == []


def test_flink_1_3_scripts_mode_writes_no_operator_keys(run, tree):
    r = run(f"{F}/1.3_flink_get_instance_details.sh", extra_vars='\nexport CONFLUENT_DEPLOY_MODE="scripts"\n')
    assert r.returncode == 0, r.stdout + r.stderr
    text = (tree.root / "configs/confluent_platform_config/confluent_flink_instance_details.sh").read_text()
    assert "DEPLOYED_SOURCE" not in text and "Operator mode" not in text
    assert not any("operators.coreos.com" in c for c in r.calls)


def test_x3_cfk_application_dry_run_renders_cpu_as_string(run, tree):
    r = run(f"{FU}/x.3_flink_sample_job.sh", "--dry-run", "--name", "smoke")
    assert r.returncode == 0, r.stdout + r.stderr
    files = list((tree.root / F / "flink_vars/rendered/cfk/flink-app").glob("*-flinkapplication-smoke.yaml"))
    assert len(files) == 1
    doc = yaml.safe_load(files[0].read_text())
    assert doc["kind"] == "FlinkApplication" and doc["metadata"]["namespace"] == "confluent-flink"
    assert doc["spec"]["jobManager"]["resource"]["cpu"] == "0.5"
    assert isinstance(doc["spec"]["taskManager"]["resource"]["cpu"], str)
    assert doc["spec"]["job"]["jarURI"].endswith("StateMachineExample.jar")
    assert not any(c.startswith("confluent ") for c in r.calls)       # no CLI in the CR path
    assert r.writes == []


def test_x4_operator_mode_discovers_cfk_kafka_and_uses_its_pod_labels(run):
    resources = {"items": [
        {"kind": "Pod", "metadata": {"labels": {"app": "kafka"}}},
        {"kind": "NetworkPolicy", "metadata": {"name": "cfk-kafka-listeners", "uid": "u1"},
         "spec": {"podSelector": {"matchLabels": {"app": "kafka"}}, "policyTypes": ["Ingress"]}}]}
    responses = [
        {"tool": "oc", "match": r"^get statefulset broker -n confluent -o name --ignore-not-found", "stdout": ""},
        {"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent -o name",
         "stdout": "kafka.platform.confluent.io/kafka\n"},
        {"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent -o "
                                r"jsonpath=\{\.status\.listeners\.internal\.internalEndpoint\}",
         "stdout": "kafka.confluent.svc.cluster.local:9071"},
        {"tool": "oc", "match": r"^get networkpolicy,pods -n confluent -o json", "stdout": json.dumps(resources)},
    ]
    r = run(f"{FU}/x.4_flink_connect_kafka.sh", "--dry-run", "--no-sasl", "--no-schema-registry", "--allow-network",
            responses=responses)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Discovered Kafka cluster in 'confluent' (CFK)." in r.stdout
    assert "kafka.confluent.svc.cluster.local:9071" in r.stdout
    assert "[DRY-RUN] Flink ingress grants (1 existing policy selectors)" in r.stdout
    assert not any("statefulset broker -o jsonpath" in c for c in r.calls)
    assert r.writes == []


@pytest.mark.parametrize("script", [
    f"{F}/full_installprocess-confluent_flink.sh", f"{F}/1.0_flink_prep.sh", f"{F}/1.1_flink_install.sh",
    f"{F}/1.2_flink_status.sh", f"{F}/1.3_flink_get_instance_details.sh", f"{FU}/x.0_flink_uninstall.sh",
    f"{FU}/operator/x.0_flink_uninstall.sh", f"{FU}/x.3_flink_sample_job.sh", f"{FU}/x.4_flink_connect_kafka.sh"])
def test_scripts_parse(script):
    r = subprocess.run(["zsh", "-n", str(REPO / script)], capture_output=True, text=True, check=False)
    assert r.returncode == 0, r.stderr
    if "/operator/" in script:
        assert os.access(REPO / script, os.X_OK)
