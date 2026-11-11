"""Render swhub_control_center_vars.sh for the optional Control Center sub-install.

Used by the softwarehub_cp4d_vars_generation.py notebook (render_swhcc_vars) and by
0_swhub_control_center_generate_config.sh, so both write the same file:

    python3 swhub_control_center_config_render.py --out FILE [--set KEY=VALUE ...]
"""

import argparse
import os
import sys
import tempfile
from pathlib import Path

try:
    import jinja2
except ImportError:
    print("[ERROR] jinja2 is needed to render the config - run `uv sync` in the repo "
          "(or pip install jinja2)", file=sys.stderr)
    sys.exit(2)

TEMPLATE_DIR = Path(__file__).resolve().parent / "config_file_jinja2_templates"
TEMPLATE_NAME = "swhub_control_center_variable_template.sh.j2"

# Recommended values. The projects and the OAuth client ID follow IBM's docs.
SWHCC_DEFAULTS = {
    "cluster_mode": "same",
    "has_cpd_vars": True,
    "version": "5.4.0",
    "patch_id": "",
    "ocp_url": "",
    "image_arch": "amd64",
    "ocp_username": "kubeadmin",
    "ocp_password": "",
    "ocp_token": "",
    "stg_block": "ocs-storagecluster-ceph-rbd",
    "stg_file": "ocs-storagecluster-cephfs",
    "license_project": "ibm-licensing",
    "scheduler_project": "ibm-cpd-scheduler",
    "operators_project": "cpd-swhub-center",
    "operands_project": "cpd-swhub-center-operands",
    "premium_tag": "5.4.0",
    "container": "olm-utils-swhub-control-center",
    "workspace_dir": "cpd-cli-swhub-control-center",
    "oauth_client_id": "ibm-software-hub-cc",
    "oauth_secret": "",
    "autodetect": "true",
    "cluster_display_name": "",
    "account_name": "software-hub-instances",
    "account_allocation": "cluster",
    "account_cpu": "",
    "other_account_name": "other-reserved-workloads",
    "instance_quota": "limits",
    "quota_headroom": "0.9",
    "indicator": "true",
    "indicator_project": "swhcc-other-workloads",
    "indicator_image": "image-registry.openshift-image-registry.svc:5000/openshift/python:3.11-ubi9",
    "route_public_ip": "",
    "account_memory_gi": "",
    "rotate_api_keys": "false",
    "verify_wait_seconds": "600",
    "add_cluster_admins": "true",
    "admin_users": "",
    "admin_roles": "zen_administrator_role,zen_resource_group_admin_role",
    "admin_exclude_users": "",
}


def _sh(value):
    """Escape a value for use inside double quotes in a shell script."""
    text = str(value)
    for char in ("\\", '"', "$", "`"):
        text = text.replace(char, "\\" + char)
    return text


def render_swhcc_vars(settings=None):
    """Return the vars file text; settings override SWHCC_DEFAULTS."""
    context = {**SWHCC_DEFAULTS, **(settings or {})}
    if context["cluster_mode"] not in ("same", "different"):
        raise ValueError("cluster_mode must be 'same' or 'different'")
    if context["cluster_mode"] == "same" and not context["has_cpd_vars"]:
        raise ValueError("cluster_mode 'same' takes its cluster from cpd_vars.sh, which is missing")
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(TEMPLATE_DIR)),
        undefined=jinja2.StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )
    env.filters["sh"] = _sh
    return env.get_template(TEMPLATE_NAME).render(context)


def write_vars_file(path, text):
    """Write atomically with mode 0700: the file holds credentials."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as out:
            out.write(text)
        os.chmod(tmp, 0o700)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", help="file to write; omit to print")
    parser.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    args = parser.parse_args()

    settings = {}
    for item in args.set:
        key, sep, value = item.partition("=")
        if not sep or key not in SWHCC_DEFAULTS:
            parser.error(f"unknown setting: {item.split('=')[0]}")
        settings[key] = value.lower() == "true" if key == "has_cpd_vars" else value

    try:
        text = render_swhcc_vars(settings)
    except ValueError as err:
        print(f"[ERROR] {err}", file=sys.stderr)
        return 1
    if args.out:
        write_vars_file(args.out, text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
