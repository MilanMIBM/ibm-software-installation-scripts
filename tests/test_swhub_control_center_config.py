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
    assert len(wanted) == 9 and wanted <= keys


def test_cluster_admins_are_on_by_default():
    text = render.render_swhcc_vars()
    assert 'CONTROL_ADD_CLUSTER_ADMINS="true"' in text
    assert 'CONTROL_ADMIN_ROLES="zen_administrator_role"' in text
