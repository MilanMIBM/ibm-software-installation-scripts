"""swhub_control_center_vars.sh rendering, and Control Center leaving the regular list."""

import importlib.util
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
    assert len(wanted) == 10 and wanted <= keys


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
    script = """
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
