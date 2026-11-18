"""WP-D platform scripts in operator mode, with the fake cluster tools (contract §5.4, §7.1 row D, §7.2).

Every run happens in a throwaway copy of the repo's code (tests/test_install_runner_local_mode.make_template),
with its own configs/, HOME, TMPDIR and MCM state, the fake oc/helm/... first on PATH, and
FAKE_OC_GET_DEFAULT=absent (an unanswered read is NotFound). The confluent config is what the operator-mode
generator (0_confluent_prepare_template_config.sh) writes, plus a fake login and a storage class.
Nothing reaches a cluster.
"""

import base64
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
from test_install_runner_local_mode import make_template

REPO = Path(__file__).resolve().parents[1]
FAKE_TOOL = REPO / "tests/fakes/confluent/fake_tool.py"
FIX = REPO / "tests/fixtures/confluent_operator"
P = "scripts/install_confluent_platform"
CID = "AbCdEfGhIjKlMnOpQrStUv"
WRITE_VERBS = {"apply", "create", "delete", "patch", "label", "annotate", "adm", "secrets", "exec", "rollout",
               "wait", "set", "scale", "replace"}
EXTRA = ('export OC_LOGIN="oc login --server=https://api.fake:6443 --token=fake"\n'
         'export STG_CLASS_BLOCK="ocs-block"\nexport STG_CLASS_FILE="ocs-file"\n'
         'export CONFLUENT_ROUTE_DOMAIN="apps.fake.example.com"\n')


def _b64(text):
    return base64.b64encode(text.encode()).decode()


@pytest.fixture(scope="module")
def template(tmp_path_factory):
    tpl = tmp_path_factory.mktemp("cfo-platform-tpl")
    make_template(REPO, tpl)
    (tpl / ".venv").symlink_to(REPO / ".venv")
    (tpl / "configs/cp4d_config").mkdir(parents=True)
    (tpl / "configs/cp4d_config/cpd_vars.sh").write_text('export STG_CLASS_BLOCK="ocs-block"\n')
    home = tmp_path_factory.mktemp("cfo-platform-home")
    r = subprocess.run(["zsh", f"{P}/0_confluent_prepare_template_config.sh", "--cluster-id", CID], cwd=tpl,
                       env={"PATH": "/usr/bin:/bin", "HOME": str(home), "_CP4D_PREP_DONE": "1",
                            "MCM_STATE_FILE": str(home / "mcm.sh"), "TMPDIR": str(home)},
                       capture_output=True, text=True, timeout=120, check=False)
    assert r.returncode == 0, r.stdout + r.stderr
    vars_text = (tpl / "configs/confluent_platform_config/confluent_vars.sh").read_text()
    assert 'export CONFLUENT_DEPLOY_MODE="operator"' in vars_text
    shutil.rmtree(tpl / "configs")
    return tpl, vars_text + EXTRA


@pytest.fixture
def run(template, tmp_path):
    tpl, vars_text = template
    tree = tmp_path / "repo"
    shutil.copytree(tpl, tree, symlinks=True, copy_function=os.link)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name in ("oc", "kubectl", "helm", "curl", "confluent", "podman", "skopeo", "sleep"):
        (bin_dir / name).symlink_to(FAKE_TOOL)
    (tmp_path / "tmp").mkdir()
    log = tmp_path / "calls.log"

    def _run(cmd, *, mode="operator", responses=(), env=None, extra_vars=""):
        text = vars_text + extra_vars
        if mode is None:
            text = text.replace('export CONFLUENT_DEPLOY_MODE="operator"\n', "")
        elif mode != "operator":
            text = text.replace('export CONFLUENT_DEPLOY_MODE="operator"', f'export CONFLUENT_DEPLOY_MODE="{mode}"')
        cfg = tree / "configs/confluent_platform_config"
        cfg.mkdir(parents=True, exist_ok=True)
        (cfg / "confluent_vars.sh").write_text(text)
        (tree / "configs/cp4d_config").mkdir(parents=True, exist_ok=True)
        (tree / "configs/cp4d_config/cpd_vars.sh").write_text('export STG_CLASS_BLOCK="ocs-block"\n')
        resp = tmp_path / "responses.json"
        resp.write_text(json.dumps(list(responses)))
        for stale in (log, tmp_path / "responses.json.counts"):
            stale.unlink(missing_ok=True)
        full = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path), "TMPDIR": str(tmp_path / "tmp"),
                "_CP4D_PREP_DONE": "1", "FAKE_LOG": str(log), "FAKE_RESPONSES": str(resp),
                "FAKE_OC_GET_DEFAULT": "absent", "CFO_POLL_INTERVAL": "1",
                "MCM_STATE_FILE": os.environ.get("MCM_STATE_FILE", str(tmp_path / "mcm.sh"))}
        full.update(env or {})
        r = subprocess.run(["zsh", "-c", cmd], cwd=tree, env=full, capture_output=True, text=True, timeout=180,
                           check=False)
        r.calls = log.read_text().splitlines() if log.exists() else []
        r.writes = [c for c in r.calls if c.split()[0] in ("oc", "kubectl") and len(c.split()) > 1
                    and c.split()[1] in WRITE_VERBS]
        return r

    _run.tree = tree
    return _run


def _stub(tree, rel):
    """Replace an operator/ script in the throwaway tree by a stub that names itself (breaks the hard link)."""
    path = tree / rel
    path.unlink()
    path.write_text('#!/bin/zsh\nprint -r -- "OPERATOR-CHILD ${0:t} $*"\n')
    path.chmod(0o755)


# ---- shared fake answers ------------------------------------------------------------------------------------
def _olm_reuse():
    return [
        {"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com -A",
         "stdout": (FIX / "csvs_ours.json").read_text()},
        {"tool": "oc", "match": r"^get operatorgroups\.operators\.coreos\.com -A", "stdout": (FIX / "ogs_ours.json").read_text()},
        {"tool": "oc", "match": r"^get subscriptions\.operators\.coreos\.com -A", "stdout": (FIX / "subs_ours.json").read_text()},
    ]


def _prepared():
    return [
        {"tool": "oc", "match": r"^get namespace confluent", "stdout": "namespace/confluent\n"},
        {"tool": "oc", "match": r"^get serviceaccount confluent", "stdout": "serviceaccount/confluent\n"},
        {"tool": "oc", "match": r"^get secret confluent-auth-oauth -n confluent", "stdout": "secret/confluent-auth-oauth\n"},
    ]


# ---- dispatch -----------------------------------------------------------------------------------------------
def test_scripts_mode_never_execs_the_operator_twin_and_unset_does_before_login(run):
    for rel in (f"{P}/operator/1.1_confluent_install.sh", f"{P}/operator/1.2_confluent_status.sh"):
        _stub(run.tree, rel)
    for script in ("1.1_confluent_install.sh", "1.2_confluent_status.sh"):
        r = run(f"zsh {P}/{script}", mode="scripts")
        assert "OPERATOR-CHILD" not in r.stdout, r.stdout
        assert r.returncode == 1 and "does not exist" in r.stderr     # the scripts-mode code ran (and stopped)
        assert r.calls[0].startswith("oc login")
    for script in ("1.1_confluent_install.sh", "1.2_confluent_status.sh"):
        r = run(f"zsh {P}/{script} --dry-run --x", mode=None)
        assert r.returncode == 0, r.stdout + r.stderr
        assert f"OPERATOR-CHILD {script} --dry-run --x" in r.stdout
        assert r.calls == []                                           # exec'd before eval OC_LOGIN


def test_full_installer_lists_operators_first_only_in_operator_mode(run):
    r = run(f"zsh {P}/full_installprocess-confluent_platform.sh --list-steps", mode=None)
    assert r.returncode == 0, r.stdout + r.stderr
    steps = re.findall(r"^\[INFO\]   \[(?:run |skip|off )\] (\S+)", r.stdout, re.MULTILINE)
    assert steps[:3] == ["operators", "prep", "install"]
    assert r.calls == []
    r = run(f"zsh {P}/full_installprocess-confluent_platform.sh --list-steps", mode="scripts")
    steps = re.findall(r"^\[INFO\]   \[(?:run |skip|off )\] (\S+)", r.stdout, re.MULTILINE)
    assert r.returncode == 0 and steps[0] == "prep" and "operators" not in steps
    # operator-mode flags: taken out before h_steps_parse --strict in operator mode, rejected in scripts mode
    r = run(f"zsh {P}/full_installprocess-confluent_platform.sh --autoselect-latest --tls-source cfk --list-steps")
    assert r.returncode == 0, r.stdout + r.stderr
    r = run(f"zsh {P}/full_installprocess-confluent_platform.sh --autoselect-latest --list-steps", mode="scripts")
    assert r.returncode == 1 and "Unknown option: --autoselect-latest" in r.stderr
    r = run(f"zsh {P}/full_installprocess-confluent_platform.sh --help")
    assert "--autoselect-latest" in r.stdout and "--tls-source repo|cfk" in r.stdout


# ---- guard --------------------------------------------------------------------------------------------------
def test_unset_mode_with_a_scripts_mode_install_blocks_1_1_without_writes(run):
    r = run(f"zsh {P}/1.1_confluent_install.sh", mode=None,
            responses=[{"tool": "oc", "match": r"^get statefulset/broker ", "stdout": "statefulset.apps/broker\n"}])
    assert r.returncode == 2, r.stdout + r.stderr
    assert "[BLOCKED] Namespace confluent holds a scripts-mode Confluent install." in r.stderr
    assert "CONFLUENT_DEPLOY_MODE is unset, which means operator mode." in r.stderr
    assert r.writes == []
    assert all(c.split()[1] in ("login", "get") for c in r.calls)


# ---- operator 1.1 -------------------------------------------------------------------------------------------
def test_operator_1_1_dry_run_renders_and_only_server_dry_runs(run):
    r = run(f"zsh {P}/1.1_confluent_install.sh --dry-run", responses=_olm_reuse() + _prepared())
    assert r.returncode == 0, r.stdout + r.stderr
    steps = re.findall(r"^\[(\d)/8\]", r.stdout, re.MULTILINE)
    assert steps == [str(i) for i in range(1, 9)]
    assert all(" --dry-run=server " in w for w in r.writes), r.writes
    root = run.tree / f"{P}/confluent_platform_vars/rendered/cfk"
    assert (root / "platform/20-kafka-kafka.yaml").exists() and (root / "repo/manifest.json").exists()
    # default config: SASL + external on -> the secrets this run would create count as present for the render
    assert "secret/confluent-kafka-tls keys: ca.crt,fullchain.pem,privkey.pem,cacerts.pem" in r.stdout
    # MDS is on in the generated config but has no keypair yet: deferred, hand-off printed, not run
    assert "MDS / RBAC             deferred" in r.stdout
    assert "[DRY-RUN] hand off to x.4_confluent_add_mds.sh" in r.stdout
    assert "[DRY-RUN] x.4_confluent_add_external_access.sh --client-config-only" in r.stdout
    assert "services:" not in (root / "platform/20-kafka-kafka.yaml").read_text()
    # the trial-license warning is printed once (cfo_license_warning), not again by the renderer
    assert (r.stdout + r.stderr).count("30-day trial license") == 1


def test_operator_1_1_applies_in_stages_and_waits(run):
    sasl = f"confluent-admin={_b64('adminpw')}\napp-client={_b64('clientpw')}\n"
    responses = [
        {"tool": "oc", "match": r"^get secret (confluent-kafka-tls|confluent-sasl-cfk-server|confluent-sasl-cfk-client)"
                                r" -n confluent -o name", "stdout": "secret/x\n"},
        {"tool": "oc", "match": r"^get secret confluent-sasl -n confluent -o go-template", "stdout": sasl},
        {"tool": "oc", "match": r"-o jsonpath=\{\.status\.phase\}\|", "stdout": "RUNNING|1|1|1"},
        {"tool": "oc", "match": r"^get deployment control-center-auth .*readyReplicas", "stdout": "1/1"},
    ] + _olm_reuse() + _prepared()
    r = run(f"zsh {P}/1.1_confluent_install.sh", responses=responses, env={"CONFLUENT_MDS_ENABLED": "false"},
            extra_vars='export CONFLUENT_MDS_ENABLED="false"\n')
    assert r.returncode == 0, r.stdout + r.stderr
    applied = [w.split()[-1].rsplit("/", 1)[-1] for w in r.writes if w.startswith("oc apply -f ") and w.endswith(".yaml")]
    assert applied[:7] == ["10-kraftcontroller-kraftcontroller.yaml", "20-kafka-kafka.yaml",
                           "40-schemaregistry-schema-registry.yaml", "50-connect-connect.yaml",
                           "60-ksqldb-ksqldb-server.yaml", "70-kafkarestproxy-rest-proxy.yaml",
                           "80-controlcenter-control-center.yaml"]
    assert "21-deployment-control-center-auth.yaml" in applied[7:]
    secrets = [i for i, c in enumerate(r.calls) if c.startswith("oc create secret generic")]
    first_apply = next(i for i, c in enumerate(r.calls) if c.startswith("oc apply -f ") and c.endswith(".yaml"))
    assert secrets and max(secrets) < first_apply                     # every secret before the first CR
    assert "[2/2] Kafka/kafka: phase=RUNNING ready=1/1" in r.stdout
    assert "adminpw" not in r.stdout + r.stderr and not any("adminpw" in c for c in r.calls)
    assert "[INFO] License: none configured - the 30-day trial applies." in r.stdout
    # external on (generated default): the local client files come from x.4 --client-config-only
    assert "x.4_confluent_add_external_access.sh --client-config-only" in r.stdout


def test_operator_1_1_applies_the_mds_stages_around_the_components(run):
    sasl = f"confluent-admin={_b64('adminpw')}\napp-client={_b64('clientpw')}\n"
    responses = [
        {"tool": "oc", "match": r"^get secret (confluent-kafka-tls|confluent-sasl-cfk-server|confluent-sasl-cfk-client"
                                r"|confluent-mds-cfk-token) -n confluent", "stdout": "secret/x\n"},
        {"tool": "oc", "match": r"^get secret confluent-sasl -n confluent -o go-template", "stdout": sasl},
        {"tool": "oc", "match": r"-o jsonpath=\{\.status\.phase\}\|", "stdout": "RUNNING|1|1|1"},
        {"tool": "oc", "match": r"^get deployment control-center-auth .*readyReplicas", "stdout": "1/1"},
    ] + _olm_reuse() + _prepared()
    r = run(f"zsh {P}/1.1_confluent_install.sh", responses=responses)
    assert r.returncode == 0, r.stdout + r.stderr
    applied = [w.split()[-1].rsplit("/", 1)[-1] for w in r.writes if w.startswith("oc apply -f ") and w.endswith(".yaml")]
    order = [a for a in applied if a.startswith(("20-kafka-", "30-kafkarestclass-", "40-", "80-", "90-"))]
    assert order == ["20-kafka-kafka.yaml", "30-kafkarestclass-default.yaml", "40-schemaregistry-schema-registry.yaml",
                     "80-controlcenter-control-center.yaml", "90-confluentrolebinding-mds-super-systemadmin.yaml"], applied
    assert "hand off" not in r.stdout and "handing off" not in r.stdout


# ---- 1.3 instance details -----------------------------------------------------------------------------------
DETAIL_KEYS = ["CONFLUENT_NAMESPACE", "CONFLUENT_DEPLOYED_VERSION", "CONFLUENT_RUNNING_CLUSTER_ID", "CONFLUENT_AUTH_MODE_DEPLOYED", "CONFLUENT_AUTH_USER", "CONFLUENT_AUTH_PASS", "CONFLUENT_BOOTSTRAP_INTERNAL", "CONFLUENT_SCHEMA_REGISTRY_INTERNAL_URL", "CONFLUENT_CONNECT_INTERNAL_URL", "CONFLUENT_KSQLDB_INTERNAL_URL", "CONFLUENT_REST_PROXY_INTERNAL_URL", "CONFLUENT_CONTROL_CENTER_INTERNAL_URL", "CONFLUENT_SCHEMA_REGISTRY_URL", "CONFLUENT_CONNECT_URL", "CONFLUENT_KSQLDB_URL", "CONFLUENT_REST_PROXY_URL", "CONFLUENT_CONTROL_CENTER_URL", "CONFLUENT_MDS_URL", "CONFLUENT_MDS_USER", "CONFLUENT_MDS_PASS", "CONFLUENT_PLATFORM_MDS_URL", "CONFLUENT_PLATFORM_USERNAME", "CONFLUENT_PLATFORM_PASSWORD", "CONFLUENT_BOOTSTRAP_EXTERNAL", "CONFLUENT_KAFKA_INTERNAL_PROTOCOL", "CONFLUENT_KAFKA_INTERNAL_MECHANISM", "CONFLUENT_KAFKA_INTERNAL_MECHANISMS", "CONFLUENT_KAFKA_EXTERNAL_MECHANISMS", "CONFLUENT_SASL_CLIENT_CREDS"]


def test_1_3_operator_mode_writes_the_same_keys_from_the_crs_and_masks_passwords(run):
    svc = "confluent.svc.cluster.local"
    comp = {"schemaregistries": ("schema-registry", 8081), "connects": ("connect", 8083), "ksqldbs": ("ksqldb-server", 8088),
            "kafkarestproxies": ("rest-proxy", 8082), "controlcenters": ("control-center", 9021)}
    responses = [
        {"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent -o "
                                r"jsonpath=\{\.status\.listeners\.internal\.internalEndpoint\}", "stdout": f"kafka.{svc}:9071"},
        {"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent -o jsonpath=\{\.status\.clusterID\}",
         "stdout": CID},
        {"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent -o jsonpath=\{\.spec\.image\.application\}",
         "stdout": "docker.io/confluentinc/cp-server:8.2.0"},
        {"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent -o jsonpath=\{\.spec\.listeners\.internal",
         "stdout": "plain||route"},
        {"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent -o jsonpath=\{range \.spec\.configOverrides",
         "stdout": "auto.create.topics.enable=true\n"},
        {"tool": "oc", "match": r"^get kafkas\.platform\.confluent\.io kafka -n confluent$", "stdout": "kafka\n"},
        {"tool": "oc", "match": r"^get route kafka-bootstrap -n confluent -o jsonpath=\{\.spec\.host\}",
         "stdout": "kafka-confluent.apps.fake.example.com"},
        {"tool": "oc", "match": r"^get route kafka-bootstrap -n confluent -o jsonpath=\{\.spec\.tls\.termination\}",
         "stdout": "passthrough"},
        {"tool": "oc", "match": r"^get route schema-registry -n confluent -o jsonpath=\{\.spec\.host\}",
         "stdout": "schema-registry-confluent.apps.fake.example.com"},
        {"tool": "oc", "match": r"^get route schema-registry -n confluent -o jsonpath=\{\.spec\.tls\.termination\}", "stdout": "edge"},
        {"tool": "oc", "match": r"^get routes -n confluent -l app\.kubernetes\.io/part-of=confluent -o jsonpath",
         "stdout": "kafka-bootstrap\nschema-registry\n"},
        {"tool": "oc", "match": r"^get secret confluent-auth -n confluent -o jsonpath=\{\.data\.username\}", "stdout": _b64("ui-user")},
        {"tool": "oc", "match": r"^get secret confluent-auth -n confluent -o jsonpath=\{\.data\.password\}", "stdout": _b64("ui-secret-pw")},
        {"tool": "oc", "match": r"^get secret confluent-sasl -n confluent$", "stdout": "secret/confluent-sasl\n"},
        {"tool": "oc", "match": r"^get secret confluent-sasl -n confluent -o jsonpath=\{\.data\}$",
         "stdout": json.dumps({"confluent-admin": _b64("admin-pw-1"), "app-client": _b64("client-pw-2")})},
        {"tool": "oc", "match": r"^get secret confluent-sasl -n confluent -o jsonpath=\{\.data\.confluent-admin\}",
         "stdout": _b64("admin-pw-1")},
        {"tool": "oc", "match": r"^get secret confluent-sasl -n confluent -o jsonpath=\{\.data\.app-client\}",
         "stdout": _b64("client-pw-2")},
    ] + [{"tool": "oc", "match": rf"^get {res}\.platform\.confluent\.io {name} -n confluent -o jsonpath=\{{\.metadata\.name\}}",
          "stdout": f"{name}|http://{name}.{svc}:{port}"} for res, (name, port) in comp.items()] \
      + _olm_reuse() + _prepared()[:1]
    details_path = run.tree / "configs/confluent_platform_config/confluent_instance_details.sh"
    details_path.parent.mkdir(parents=True, exist_ok=True)
    details_path.write_text("# left by an older run\n")
    details_path.chmod(0o644)                       # older runs (both modes) left it world-readable
    r = run(f"zsh {P}/1.3_confluent_get_instance_details.sh", responses=responses)
    assert r.returncode == 0, r.stdout + r.stderr
    assert details_path.stat().st_mode & 0o777 == 0o600   # holds passwords: owner-only (user decision 2026-11-18)
    details = details_path.read_text()
    values = dict(re.findall(r'^export (\w+)="([^"]*)"', details, re.MULTILINE))
    missing = [k for k in DETAIL_KEYS if f"export {k}=" not in details]
    assert missing == []
    assert [k for k, v in values.items() if "broker" in v] == []       # no scripts-mode name in any value
    assert values["CONFLUENT_BOOTSTRAP_INTERNAL"] == f"kafka.{svc}:9071"
    assert values["CONFLUENT_SCHEMA_REGISTRY_INTERNAL_URL"] == f"http://schema-registry.{svc}:8081"
    assert values["CONFLUENT_BOOTSTRAP_EXTERNAL"] == "kafka-confluent.apps.fake.example.com:443"
    assert values["CONFLUENT_RUNNING_CLUSTER_ID"] == CID and values["CONFLUENT_DEPLOYED_VERSION"] == "8.2.0"
    assert (values["CONFLUENT_KAFKA_INTERNAL_PROTOCOL"], values["CONFLUENT_KAFKA_INTERNAL_MECHANISMS"],
            values["CONFLUENT_KAFKA_EXTERNAL_MECHANISMS"]) == ("SASL_PLAINTEXT", "PLAIN", "PLAIN")
    assert values["CONFLUENT_DEPLOY_MODE_DEPLOYED"] == "operator"
    assert values["CONFLUENT_OPERATOR_DEPLOYED_CSV"] == "confluent-for-kubernetes.v3.4.0"
    assert values["CONFLUENT_OPERATOR_DEPLOYED_NAMESPACE"] == "confluent"
    assert "#   kafka-bootstrap    protected - Kafka SASL_SSL (PLAIN)" in details
    # the file keeps the passwords; the terminal never shows them
    assert "client-pw-2" in details and "ui-secret-pw" in details
    for secret in ("admin-pw-1", "client-pw-2", "ui-secret-pw"):
        assert secret not in r.stdout + r.stderr
    assert 'export CONFLUENT_SASL_CLIENT_CREDS="********"' in r.stdout
    assert 'export CONFLUENT_AUTH_PASS="********"' in r.stdout
    # watsonx.data: one bootstrap row (D18)
    props = (run.tree / "configs/confluent_platform_config/confluent_sasl_clients.properties").read_text()
    rows = re.findall(r"^#\s+(\S+)\s+443$", props, re.MULTILINE)
    assert rows == ["kafka-confluent.apps.fake.example.com"]
    assert r.writes == []


# ---- confluent_kafka_security.sh ----------------------------------------------------------------------------
def test_kafka_ensure_internal_tls_cfk_san_list_and_secret_keys(run, tmp_path):
    out = tmp_path / "fullchain.pem"
    script = (f'source "$PWD/env_bootstrap.sh" >/dev/null 2>&1; source src/helpers/confluent_operator_helpers.sh; '
              f'source {P}/confluent_kafka_security.sh; kafka_internal_tls_sans_cfk confluent; '
              # keep the key names and the certificate the helper hands to cfo_secret_apply (to read its SANs)
              'cfo_secret_apply() { local kv seen=false; for kv in "$@"; do '
              'if $seen; then print -r -- "KEY ${kv%%=*}"; '
              f'[[ "$kv" == fullchain.pem=* ]] && cp "${{kv#*=}}" {out}; fi; '
              '[[ "$kv" == -- ]] && seen=true; done; return 0; }; '
              'kafka_ensure_internal_tls confluent; echo rc=$?')
    r = run(script, responses=_prepared())
    lines = r.stdout.splitlines()
    sans = ("localhost,kafka,kafka.confluent,kafka.confluent.svc,kafka.confluent.svc.cluster.local,"
            "*.kafka.confluent.svc,*.kafka.confluent.svc.cluster.local,*.confluent.svc,*.confluent.svc.cluster.local,"
            "kraftcontroller.confluent.svc.cluster.local,*.kraftcontroller.confluent.svc.cluster.local")
    assert sans in lines, r.stdout + r.stderr
    assert "rc=0" in lines
    keys = [ln.split()[1] for ln in lines if ln.startswith("KEY ")]
    assert keys == ["ca.crt", "fullchain.pem", "privkey.pem", "cacerts.pem"]       # no CA key, no keystore
    text = subprocess.run(["openssl", "x509", "-in", str(out), "-noout", "-text"], capture_output=True, text=True,
                          check=True).stdout
    found = sorted(re.findall(r"DNS:([^,\s]+)", text))
    assert found == sorted(sans.split(","))
    # TLS source cfk: nothing to make, no cluster call
    r = run(f'source "$PWD/env_bootstrap.sh" >/dev/null 2>&1; source {P}/confluent_kafka_security.sh; '
            'kafka_ensure_internal_tls confluent; echo rc=$?', env={"CONFLUENT_OPERATOR_TLS_SOURCE_CLI": "cfk"})
    assert "[INFO] CONFLUENT_OPERATOR_TLS_SOURCE=cfk - CFK generates the in-cluster certificates." in r.stdout
    assert r.stdout.splitlines()[-1] == "rc=0" and r.calls == []


# ---- operator 1.2 -------------------------------------------------------------------------------------------
def test_operator_1_2_reports_ready_crs_and_exits_0(run):
    pods = "kafka-0 Running true 0 node1\nkraftcontroller-0 Running true 0 node1\n"
    responses = [
        {"tool": "oc", "match": r"^get subscriptions\.operators\.coreos\.com -n confluent", "stdout": (FIX / "subs_ours.json").read_text()},
        {"tool": "oc", "match": r"^get clusterserviceversions\.operators\.coreos\.com -n confluent",
         "stdout": (FIX / "csvs_ours.json").read_text()},
        {"tool": "oc", "match": r"^get deployments\.apps -n confluent", "stdout": json.dumps({"items": [
            {"metadata": {"name": "confluent-operator", "namespace": "confluent"}, "spec": {"replicas": 1},
             "status": {"readyReplicas": 1}}]})},
        {"tool": "oc", "match": r"\.platform\.confluent\.io \S+ -n confluent$", "stdout": "x\n"},
        {"tool": "oc", "match": r"-o jsonpath=\{\.status\.phase\}\|", "stdout": "RUNNING|1|1|1|2|2"},
        {"tool": "oc", "match": r"^get deployment control-center-auth ", "stdout": "1/1"},
        {"tool": "oc", "match": r"^get pods -n confluent -l confluent-platform=true", "stdout": pods},
        {"tool": "oc", "match": r"^get pvc -n confluent -l app\.kubernetes\.io/part-of=confluent",
         "stdout": "data0-kafka-0 Bound 100Gi\n"},
    ] + _olm_reuse() + _prepared()
    r = run(f"zsh {P}/1.2_confluent_status.sh", responses=responses)
    assert r.returncode == 0, r.stdout + r.stderr
    assert re.search(r"Kafka/kafka\s+READY phase=RUNNING ready=1/1 generation=2 observedGeneration=2", r.stdout)
    assert "confluent-for-kubernetes" in r.stdout and "csv=Succeeded" in r.stdout
    assert "[INFO] All enabled Confluent components are ready." in r.stdout
    assert r.writes == []


def test_full_installer_needs_helm_in_operator_mode_with_flink(run, tmp_path):
    no_helm = tmp_path / "bin-no-helm"
    no_helm.mkdir()
    for name in ("oc", "kubectl", "curl", "sleep"):
        (no_helm / name).symlink_to(FAKE_TOOL)
    flink = 'export PROJECT_CONFLUENT_FLINK="confluent-flink"\nexport FLINK_CMF_CHART_VERSION="2.5.0"\n'
    env = {"PATH": f"{no_helm}:/usr/bin:/bin"}
    r = run(f"zsh {P}/full_installprocess-confluent_platform.sh --list-steps", env=env, extra_vars=flink)
    assert r.returncode == 0, r.stdout + r.stderr                     # planning stays offline and helm-free
    r = run(f"zsh {P}/full_installprocess-confluent_platform.sh", env=env, extra_vars=flink)
    assert r.returncode == 1 and "[ERROR] helm is not on PATH." in r.stderr
    assert r.calls == []                                               # stopped before the first step
    r = run(f"zsh {P}/full_installprocess-confluent_platform.sh --only prep", env=env, extra_vars=flink)
    assert "helm is not on PATH" not in r.stderr                       # neither operators nor flink runs


# ---- 1.0 prep in operator mode (lead fix 2026-11-18) ----------------------------------------------------------
def test_1_0_operator_mode_keeps_the_namespace_labels_and_skips_scc_and_monitoring_policy(run):
    responses = [{"tool": "oc", "match": r"^get storageclass ", "stdout": "storageclass/ocs-block\n"}]
    # MDS with the bundled OpenLDAP: anyuid for SA confluent only (the bitnami LDAP image needs a fixed uid;
    # it crash-loops under restricted-v2). CFK pods still get no grant.
    r = run(f"zsh {P}/1.0_confluent_prep.sh", responses=responses,
            env={"CONFLUENT_MDS_ENABLED": "true", "CONFLUENT_MDS_USER_STORE": "LDAP"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert any(c.startswith("oc adm policy add-scc-to-user anyuid -z confluent") for c in r.calls), r.calls
    assert "for the bundled identity store only" in r.stdout
    # MDS off: no SCC grant at all
    r = run(f"zsh {P}/1.0_confluent_prep.sh", responses=responses, env={"CONFLUENT_MDS_ENABLED": "false"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert not any("add-scc-to-user" in c for c in r.calls), r.calls
    assert not any("monitoring-internal" in c for c in r.calls), r.calls
    assert not any(c.startswith("oc create namespace") for c in r.calls), r.calls
    assert "[INFO] Operator mode: no SCC grant" in r.stdout
    assert "no 'monitoring-internal' NetworkPolicy here" in r.stdout
    # an existing namespace is left as it is (its labels stay); no label-less re-apply
    responses.append({"tool": "oc", "match": r"^get namespace confluent", "stdout": "namespace/confluent\n"})
    r = run(f"zsh {P}/1.0_confluent_prep.sh", responses=responses)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "[INFO] Namespace confluent already exists, leaving it as-is." in r.stdout
    assert not any(c.startswith("oc create namespace") for c in r.calls), r.calls
