"""swhub_control_center_vars.sh rendering, and Control Center leaving the regular list."""

import base64
import importlib.util
import json
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"src/helpers/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


render = load("swhub_control_center_config_render")
options = load("cp4d_id_options_templates")


def evaluate(text, tmp_path, names, cpd_vars=""):
    """Source the rendered file from a subfolder of a fake cp4d_config and read names."""
    (tmp_path / "cpd_vars.sh").write_text(cpd_vars)
    sub = tmp_path / "swhub_control_center"
    sub.mkdir()
    (sub / "swhub_control_center_vars.sh").write_text(text)
    reads = "; ".join(f'print -r -- "${{{n}}}"' for n in names)
    result = subprocess.run(
        ["zsh", "-c", f"source {sub}/swhub_control_center_vars.sh; {reads}"],
        capture_output=True, text=True, check=True,
    )
    return dict(zip(names, result.stdout.splitlines()))


def test_same_cluster_follows_cpd_vars(tmp_path):
    cpd = """
export OCP_URL=https://api.x:6443/ IMAGE_ARCH=amd64 STG_CLASS_BLOCK=blk STG_CLASS_FILE=fil
export SERVER_ARGUMENTS=--server=${OCP_URL} LOGIN_ARGUMENTS=--token=abc
"""
    got = evaluate(render.render_swhcc_vars({"oauth_secret": "s"}), tmp_path,
                   ["CONTROL_OCP_URL", "CONTROL_STG_CLASS_BLOCK", "CONTROL_OC_LOGIN",
                    "CONTROL_OLM_UTILS_IMAGE"], cpd)
    assert got["CONTROL_OCP_URL"] == "https://api.x:6443/"
    assert got["CONTROL_STG_CLASS_BLOCK"] == "blk"
    assert got["CONTROL_OC_LOGIN"] == "oc login --server=https://api.x:6443/ --token=abc"
    assert got["CONTROL_OLM_UTILS_IMAGE"] == "cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.amd64"


def test_same_cluster_leaves_out_the_shared_component_projects():
    assert "CONTROL_PROJECT_LICENSE_SERVICE" not in render.render_swhcc_vars()


def test_different_cluster_without_cpd_vars_stands_alone(tmp_path):
    text = render.render_swhcc_vars({
        "cluster_mode": "different", "has_cpd_vars": False,
        "ocp_url": "https://api.y:6443", "ocp_password": 'pa"ss$1', "patch_id": "8",
    })
    assert "cpd_vars.sh\"" not in text
    got = evaluate(text, tmp_path, ["CONTROL_OCP_PASSWORD", "PATCH_ID", "CONTROL_PROJECT_SCHEDULING_SERVICE"])
    assert got == {"CONTROL_OCP_PASSWORD": 'pa"ss$1', "PATCH_ID": "8",
                   "CONTROL_PROJECT_SCHEDULING_SERVICE": "ibm-cpd-scheduler"}


def test_token_login_wins_over_username():
    text = render.render_swhcc_vars({"cluster_mode": "different", "ocp_token": "tok"})
    assert 'CONTROL_LOGIN_ARGUMENTS="--token=${CONTROL_OCP_TOKEN}"' in text
    assert "CONTROL_OCP_USERNAME" not in text


def test_same_cluster_needs_cpd_vars():
    with pytest.raises(ValueError):
        render.render_swhcc_vars({"has_cpd_vars": False})


def test_written_file_is_private(tmp_path):
    path = tmp_path / "a" / "vars.sh"
    render.write_vars_file(path, "x")
    assert stat.S_IMODE(path.stat().st_mode) == 0o700


def test_control_center_left_the_regular_component_list():
    assert "ibm_swhcc" not in options.cp4d_component_id_options
    assert "ibm_swhcc" not in [r["component_id"] for r in options.cp4d_component_id_records]


def test_premium_image_follows_the_release_tag():
    assert "olm-utils-premium-v4:5.4.0.${CONTROL_IMAGE_ARCH}" in render.render_swhcc_vars()


def test_autodetect_is_on_by_default_and_never_rotates_keys_by_default():
    text = render.render_swhcc_vars()
    assert 'AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES="true"' in text
    assert 'CONTROL_AUTODETECT_ROTATE_API_KEYS="false"' in text


def test_notebook_can_set_every_autodetect_variable():
    keys = {r["key"] for r in options.default_swhub_control_center_setup}
    template = (render.TEMPLATE_DIR / render.TEMPLATE_NAME).read_text()
    wanted = {line.split("=")[0].split()[1] for line in template.splitlines()
              if line.startswith(("export CONTROL_AUTODETECT_", "export CONTROL_CLUSTER_DISPLAY_NAME", "export CONTROL_ADMIN_"))}
    assert len(wanted) == 13 and wanted <= keys


def test_cluster_admins_are_on_by_default():
    text = render.render_swhcc_vars()
    assert 'CONTROL_ADD_CLUSTER_ADMINS="true"' in text
    assert 'CONTROL_ADMIN_ROLES="zen_administrator_role,zen_resource_group_admin_role"' in text


def test_oauth_url_request_sends_a_bare_host():
    # Control Center adds https:// to swh_host itself; a URL here gave it https://https://.
    script = """
export _CP4D_REPO_ROOT="$1" CONTROL_CENTER_URL=https://cpd-cc.apps.example.com/
source "$1/src/helpers/swhub_control_center_api_helpers.sh"
cpdapi() { print -r -- "$2"; API_CODE=200; API_BODY='{"oauth_authz_url":"https://x"}'; }
swhcc_cluster_oauth_url c1
"""
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT)], capture_output=True, text=True, check=True)
    assert "swh_host=cpd-cc.apps.example.com" in result.stdout
    assert "https" not in result.stdout.split("swh_host=")[1]


def test_cluster_is_verified_with_no_browser(tmp_path):
    fake = tmp_path / "curl"
    fake.write_text("""#!/bin/sh
cat > "$CAPTURE"
printf 'HTTP/1.1 302 Found\\r\\nLocation: https://cc/zen/oauth/redirect?code=abc&state=c3Q%%3D\\r\\n\\r\\n'
""")
    fake.chmod(0o755)
    script = """
export _CP4D_REPO_ROOT="$1" CONTROL_CENTER_URL=https://cpd-cc.apps.example.com
export OCP_USERNAME=kubeadmin OCP_PASSWORD='pa"ss\\1'
source "$1/src/helpers/swhub_control_center_api_helpers.sh"
export CONTROL_OAUTH_CLIENT_ID=cc
oc() { print -r -- "oc $*" >> "$OC_LOG"; }
PATH="$2:$PATH"
cpdapi() { [[ "$1" == GET ]] && API_BODY='{"oauth_authz_url":"https://oauth/authorize"}' || { print -r -- "$1 $2"; cat "${3#@}"; }; API_CODE=200; }
swhcc_cluster_auto_verify c1
"""
    capture = tmp_path / "curl-config"
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT), str(tmp_path)], capture_output=True, text=True,
                            check=True, env={**__import__("os").environ, "CAPTURE": str(capture), "OC_LOG": str(tmp_path / "oc.log")})
    patches = (tmp_path / "oc.log").read_text().splitlines()
    assert [("true" in p) for p in patches] == [True, False], "challenges must be switched back off"
    assert "PUT /zen-data/v1/management/platform/clusters/c1/capacities" in result.stdout
    assert '"code": "abc"' in result.stdout and '"state": "c3Q="' in result.stdout
    assert '"swh_host": "cpd-cc.apps.example.com"' in result.stdout
    assert capture.read_text().strip() == r'user = "kubeadmin:pa\"ss\\1"'


def test_oauth_client_stays_browser_friendly_at_rest():
    text = (ROOT / "scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/1.4_swhub_control_center_oauth_client.sh").read_text()
    # True here would make OpenShift reject the web client's Refresh data button.
    assert "grantMethod: prompt" in text and "respondWithChallenges: false" in text


@pytest.mark.parametrize("call", ["swhcc_grant_roles u1 new_role", "swhcc_revoke_roles u1 old_role"])
def test_role_updates_send_the_username_usermgmt_requires(call):
    script = f"""
export _CP4D_REPO_ROOT="$1"
source "$1/src/helpers/swhub_control_center_api_helpers.sh"
cpdapi() {{
    API_CODE=200
    if [[ "$1" == GET ]]; then API_BODY='{{"user_roles":["old_role"]}}'; else print -r -- "$1 $3"; fi
}}
{call}
"""
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT)], capture_output=True, text=True, check=True)
    body = result.stdout.split("PUT ", 1)[1]
    assert __import__("json").loads(body)["username"] == "u1"


def test_account_admins_follow_control_center_access():
    script = """
export _CP4D_REPO_ROOT="$1"
source "$1/src/helpers/swhub_control_center_api_helpers.sh"
cpdapi() {
    API_CODE=200
    case "$1 $2" in
        "GET /usermgmt/v2/usermgmt/users"*) API_BODY='[{"uid":"1","username":"member","user_roles":["r"]},{"uid":"2","username":"new","user_roles":["r"]},{"uid":"3","username":"norole","user_roles":[]}]' ;;
        "GET /usermgmt/v4/groups"*) API_BODY='{"results":[{"group_id":10000,"name":"All Users","roles":[]},{"group_id":7,"name":"admins","roles":["r"]}]}' ;;
        "GET /usermgmt/v1/user/"*) API_BODY='{"user_roles":["r","zen_resource_group_admin_role"]}' ;;
        GET*) API_BODY='{"user_members":{"users":[{"uid":"1"}]}}' ;;
        *) print -r -- "$1 $2 $(print -r -- "$3" | jq -c .)" ;;
    esac
}
swhcc_sync_account_admins acct
"""
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT)], capture_output=True, text=True, check=True)
    writes = [line for line in result.stdout.splitlines() if line.startswith(("POST", "PATCH"))]
    assert len(writes) == 3
    assert 'members {"users":[{"uid":"2","username":"new"}]}' in writes[0]
    assert "/v2/groups/7" in writes[1] and "zen_resource_group_admin_role" in writes[1]
    assert '{"groups":[{"group_id":"7","group_name":"admins"}]}' in writes[2]
    assert "All Users" not in result.stdout and "norole" not in result.stdout


def test_reserved_capacity_is_the_pod_requests_rounded_up():
    pods = """{"items":[
      {"status":{"phase":"Running"},"spec":{"containers":[{"resources":{"requests":{"cpu":"1500m","memory":"1Gi"}}},{"resources":{"requests":{"cpu":"1","memory":"512Mi"}}}]}},
      {"status":{"phase":"Pending"},"spec":{"containers":[{"resources":{"requests":{"cpu":"100m"}}}]}},
      {"status":{"phase":"Succeeded"},"spec":{"containers":[{"resources":{"requests":{"cpu":"50","memory":"50Gi"}}}]}},
      {"status":{"phase":"Running"},"spec":{"containers":[{"resources":{}}]}}]}"""
    script = f"""
export _CP4D_REPO_ROOT="$1"
source "$1/src/helpers/swhub_control_center_api_helpers.sh"
oc() {{ print -r -- '{pods}'; }}
swhcc_reserved_capacity one
print -r -- "$SWHCC_CPU $SWHCC_MEMORY_GI"
swhcc_reserved_capacity one two
print -r -- "$SWHCC_CPU $SWHCC_MEMORY_GI"
"""
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT)], capture_output=True, text=True, check=True)
    assert result.stdout.split("\n")[:2] == ["3 2", "6 3"]


def test_cluster_capacity_is_the_room_left_plus_what_the_account_holds():
    # set -e as in the real scripts: (( x += 0 )) counts as a failure and ends them.
    script = """
set -euo pipefail
export _CP4D_REPO_ROOT="$1"
source "$1/src/helpers/swhub_control_center_api_helpers.sh"
cpdapi() {
    API_CODE=200
    case "$2" in
        */cluster/resources) API_BODY='{"requestObj":{"Resources":[{"ClusterID":"c1","Resources":{"CPU":{"AvailableCapacity":83},"Memory":{"AvailableCapacity":447.5},"GPU":{"AvailableCapacity":0}}}]}}' ;;
        *) API_BODY='{"requestObj":{"Resources":[{"ClusterID":"c1","Resources":{"CPU":{"Allocated":77},"Memory":{"Allocated":213},"GPU":{"Allocated":-1}}}]}}' ;;
    esac
}
swhcc_cluster_capacity c1 acct
print -r -- "$SWHCC_CPU $SWHCC_MEMORY_GI $SWHCC_GPU"
swhcc_cluster_capacity c1
print -r -- "$SWHCC_CPU $SWHCC_MEMORY_GI $SWHCC_GPU"
"""
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT)], capture_output=True, text=True, check=True)
    assert result.stdout.split("\n")[:2] == ["160 661 0", "83 448 0"]


def test_instance_quota_tracks_without_enforcing():
    script = """
export _CP4D_REPO_ROOT="$1"
source "$1/src/helpers/swhub_control_center_api_helpers.sh"
cpdapi() { print -r -- "$3"; }
swhcc_set_instance_quota i1 77 213
"""
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT)], capture_output=True, text=True, check=True)
    body = __import__("json").loads(result.stdout)
    assert body["Enforce"] is False and body["InstanceID"] == "i1"
    assert body["Policies"]["Quota"]["CPU"]["Maximum"] == 77
    assert body["Policies"]["Quota"]["Memory"]["Maximum"] == 213
    # Measured against requests: a limit quota alerts as soon as limits overcommit.
    assert body["Policies"]["Quota"]["PolicyType"] == "request"


def test_other_workloads_leave_out_software_hub_and_masters():
    script = """
export _CP4D_REPO_ROOT="$1" PROJECT_CPD_INST_OPERANDS=cpd CONTROL_PROJECT_OPERATORS=cc CONTROL_PROJECT_OPERANDS=cco
source "$1/src/helpers/swhub_control_center_api_helpers.sh"
pod() { print -r -- "{\\"metadata\\":{\\"namespace\\":\\"$1\\"},\\"status\\":{\\"phase\\":\\"Running\\"},\\"spec\\":{\\"nodeName\\":\\"$2\\",\\"containers\\":[{\\"resources\\":{\\"requests\\":{\\"cpu\\":\\"$3\\",\\"memory\\":\\"1Gi\\"}}}]}}"; }
oc() {
    case "$*" in
        "get zenservice"*) print -r -- '{"items":[{"metadata":{"namespace":"cpd"}}]}' ;;
        "get commonservice"*) print -r -- '{"items":[{"metadata":{"namespace":"ops"}}]}' ;;
        "get nodes"*) print -r -- '{"items":[{"metadata":{"name":"m1"}}]}' ;;
        "get pods"*) print -r -- "{\\"items\\":[$(pod storage w1 1500m),$(pod monitoring w2 1),$(pod storage m1 50),$(pod cpd w1 50),$(pod ops w1 50),$(pod cco w1 2)]}" ;;
    esac
}
swhcc_other_reserved_capacity
print -r -- "$SWHCC_OTHER_CPU $SWHCC_OTHER_MEMORY_GI"
"""
    # Control Center (cco) has a ZenService of its own but counts as an other workload.
    script = script.replace('{"metadata":{"namespace":"cpd"}}', '{"metadata":{"namespace":"cpd"}},{"metadata":{"namespace":"cco"}}')
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT)], capture_output=True, text=True, check=True)
    assert result.stdout.strip().splitlines()[-1] == "5 4"  # requests 4.5 and 3 Gi, / 0.95


def load_indicator():
    spec = importlib.util.spec_from_file_location("indicator", ROOT / "src/helpers/swhub_control_center_indicator_server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeKube:
    def __init__(self, data):
        self.data = data

    def items(self, path):
        return self.data.get(path, [])


def test_indicator_counts_control_center_but_not_instances_or_masters():
    ind = load_indicator()
    def pod(ns, node, cpu, mem="1Gi", phase="Running"):
        return {"metadata": {"namespace": ns, "name": f"{ns}-{node}-{cpu}"}, "status": {"phase": phase},
                "spec": {"nodeName": node, "containers": [{"resources": {"requests": {"cpu": cpu, "memory": mem},
                                                                          "limits": {"cpu": "2", "memory": "2Gi"}}}]}}
    kube = FakeKube({
        "/apis/zen.cpd.ibm.com/v1/zenservices": [{"metadata": {"namespace": "cpd"}}, {"metadata": {"namespace": "cc"}}],
        "/apis/operator.ibm.com/v3/commonservices": [{"metadata": {"namespace": "ops"}}],
        "/api/v1/nodes": [{"metadata": {"name": "w1", "labels": {"node-role.kubernetes.io/worker": ""}}},
                          {"metadata": {"name": "m1", "labels": {}}}],
        "/api/v1/pods": [pod("storage", "w1", "1500m"), pod("cc", "w1", "1"), pod("cpd", "w1", "9"),
                         pod("ops", "w1", "9"), pod("storage", "m1", "9"), pod("storage", "w1", "9", phase="Succeeded")],
        "/apis/metrics.k8s.io/v1beta1/pods": [{"metadata": {"namespace": "storage", "name": "storage-w1-1500m"},
                                               "containers": [{"usage": {"cpu": "250000000n", "memory": "512Mi"}}]}],
        "/api/v1/persistentvolumeclaims": [{"metadata": {"namespace": "storage"}, "status": {"phase": "Bound", "capacity": {"storage": "10G"}}},
                                           {"metadata": {"namespace": "cpd"}, "status": {"phase": "Bound", "capacity": {"storage": "99G"}}}],
    })
    totals = ind.collect(kube, extra_projects=["unused"], include_projects=["cc"])
    assert totals["cpu_requests"] == 2.5 and totals["cpu_limits"] == 4
    assert totals["memory_requests"] == 2 * 2**30 and totals["cpu_usage"] == 0.25
    assert totals["volume_bytes"] == 10e9 and totals["projects"] == 2


def test_indicator_speaks_control_centers_format():
    ind = load_indicator()
    totals = {"cpu_requests": 15.1, "cpu_limits": 30, "memory_requests": 54 * 2**30, "memory_limits": 80 * 2**30,
              "cpu_usage": 3, "memory_usage": 20 * 2**30, "volume_bytes": 0, "projects": 27}
    policy = ind.merge_policy(ind.default_policy(), {"Policies": {"Quota": {"CPU": {"Maximum": 17}, "Memory": {"Maximum": 58}}}})
    body = ind.overview(totals, policy, 1793893800)["requestObj"]
    assert body["Resources"]["InUse"]["Memory"]["Requests"] == 54
    # The web client shows these unrounded, so float noise must not reach it.
    noisy = dict(totals, cpu_requests=19.911000000000012, memory_requests=65.14453125 * 2**30, volume_bytes=561566973952)
    used = ind.overview(noisy, policy, 0)["requestObj"]["Resources"]["InUse"]
    assert (used["CPU"]["Requests"], used["Memory"]["Requests"], used["Volume"]["Capacity"]) == (19.911, 65.145, 561.567)
    assert body["Resources"]["ResourcePlan"]["Policies"]["Quota"]["CPU"]["Maximum"] == 17
    assert round(body["Resources"]["Quota"]["PercentCPU"], 1) == 88.8
    assert body["AlertsAndEvents"]["CriticalStatus"]["Total"] == 0
    key = base64.b64encode(b"ind:secret").decode()
    assert ind.authorized(f"ZenApiKey {key}", "ind", "secret")
    assert not ind.authorized(f"ZenApiKey {key}x", "ind", "secret") and not ind.authorized("Bearer x", "ind", "secret")


def plan(cap_cpu, cap_mem, rows, headroom="0.9"):
    script = """
export _CP4D_REPO_ROOT="$1"
source "$1/src/helpers/swhub_control_center_api_helpers.sh"
print -rl -- "${@:5}" | swhcc_plan_quotas "$2" "$3" "$4"
"""
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT), str(cap_cpu), str(cap_mem), headroom, *rows],
                            capture_output=True, text=True, check=True)
    return result.stdout.split(), result.stderr


def test_quota_grows_to_limits_within_the_account():
    # cpd-operands today: limits over the account for CPU, inside it for memory.
    out, warn = plan(144, 605, ["i1 76.573 212.33 290.162 553.25"])
    assert out == ["i1", "144", "554"] and not warn


def test_quota_floor_keeps_requests_under_the_alert_line():
    out, _ = plan(1000, 1000, ["i1 10 10 10.5 10.5"])  # limits barely above requests
    assert out == ["i1", "12", "12"]  # ceil(10 / 0.9), not 11


def test_quotas_share_the_account_by_limits():
    out, warn = plan(100, 100, ["a 10 10 300 300", "b 10 10 100 100"])
    assert out == ["a", "75", "75", "b", "25", "25"] and not warn


def test_quota_warns_when_floors_do_not_fit():
    out, warn = plan(10, 10, ["a 9 9 20 20", "b 9 9 20 20"])
    assert out == ["a", "10", "10", "b", "10", "10"] and "need 20" in warn


def test_ceil_with_headroom():
    script = 'export _CP4D_REPO_ROOT="$1"; source "$1/src/helpers/swhub_control_center_api_helpers.sh"; swhcc_ceil 15.111 0.95; swhcc_ceil 3; swhcc_ceil 3.000000000001; swhcc_ceil 3.0000001'
    result = subprocess.run(["zsh", "-c", script, "_", str(ROOT)], capture_output=True, text=True, check=True)
    assert result.stdout.split() == ["16", "3", "3", "4"]


def test_indicator_answers_the_registration_check():
    import http.client, threading
    from http.server import ThreadingHTTPServer
    ind = load_indicator()
    state = ind.State(FakeKube({}), [], [], ind.default_policy(), "swhcc-other-workloads")
    server = ThreadingHTTPServer(("127.0.0.1", 0), ind.make_handler(state, "ind", "secret"))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        key = base64.b64encode(b"ind:secret").decode()
        def get(path, auth=True):
            conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1])
            conn.request("GET", path, headers={"Authorization": f"ZenApiKey {key}"} if auth else {})
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        assert get("/zen-data/v2/controlplane") == (200, {"message": "Success", "requestObj": "swhcc-other-workloads"})
        assert get("/zen-data/v2/controlplane", auth=False)[0] == 401
        assert get("/zen-watchdog/v1/monitor", auth=False)[0] == 200
        assert get("/zen-watchdog/v3/instance/overview")[0] == 200
        assert get("/anything/else")[0] == 404
    finally:
        server.shutdown()
