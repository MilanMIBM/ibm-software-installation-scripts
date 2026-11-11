"""Running across several clusters for multi-cluster management (plan section 5.8).

T8: arguments preserved, exit codes, skip code, no double fan-out, confirm and single-only policies, plus: progress
    and result table on the main output, the parent's EXIT trap not firing, a pinned shell's values not reaching the
    children, sourced loads never fanning out.

Everything runs in tests/mcm_harness.py sandboxes: temp HOME, temp repo copy, fake podman / oc / cpd-cli.
"""

import os
import pty
import signal
import subprocess
import time

import pytest
from mcm_harness import REPO, make_sandbox

URLS = {
    "itz-a": "https://api.itz-a.example.com:6443",
    "itz-b": "https://api.itz-b.example.com:6443",
    "itz-c": "https://api.itz-c.example.com:6443",
}
CPD_DIR = "scripts/install_cloud_pak_for_data"
ALLOW = f"{CPD_DIR}/4_install_components/x_probe.sh"
RAN = "RAN "

# A script as the repo writes them: strict, EXIT trap ahead of the env load, walk up to env_bootstrap.sh.
PROBE = r'''#!/bin/zsh
set -euo pipefail
trap 'print -r -- "TRAP-FIRED $0"' EXIT
SCRIPT_DIR="${0:A:h}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="${_b:h}"; done; source "${_b}/env_bootstrap.sh"; unset _b
printf 'RAN %s ' "${MCM_CLUSTER:-flat}"
printf '<%s>' "$@"
print
print -r -- "VARS ${MCM_CLUSTER:-flat} child=${_MCM_FANOUT_CHILD:-} prep=${_CP4D_PREP_DONE:-} url=${OCP_URL:-} only=${A_ONLY:-} flat_only=${FLAT_ONLY:-} kube=${KUBECONFIG:-} root=${CONFIGS_ROOT:-}"
if [[ -n "${READ_STDIN:-}" ]]; then
    IFS= read -r _line || _line="<EOF>"
    print -r -- "GOT ${MCM_CLUSTER:-flat} [${_line}]"
fi
if [[ -n "${NESTED_SCRIPT:-}" ]]; then
    NESTED_SCRIPT="" zsh "${_CP4D_REPO_ROOT}/${NESTED_SCRIPT}" --all-clusters
fi
print -r -- "AFTER-NESTED ${MCM_CLUSTER:-flat}"
if [[ -n "${WAIT_FILE:-}" ]]; then
    : > "${WAIT_FILE}"
    sleep 60
fi
if [[ -n "${FAIL_ON:-}" && "${FAIL_ON}" == "${MCM_CLUSTER:-}" ]]; then
    exit "${FAIL_RC:-3}"
fi
'''


def write_state(sb, clusters, current="", targets="", apply_to_all="false"):
    (sb.repo / "configs" / "multi_cluster_management.sh").write_text(
        'export MULTI_CLUSTER_MANAGEMENT="true"\n'
        f'export MCM_CLUSTERS="{" ".join(clusters)}"\n'
        f'export MCM_CURRENT_CLUSTER="{current}"\n'
        f'export APPLY_TO_ALL="{apply_to_all}"\n'
        f'export MCM_TARGET_CLUSTERS="{targets}"\n'
        'export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0"\n'
    )


def clusters(sb, names=("itz-a", "itz-b"), configs=None, **state):
    configs = names if configs is None else configs
    for name in names:
        sb.write_cluster_marker(name, URLS[name])
    for name in configs:
        sb.write_config("cpd", ocp_url=URLS[name], cluster=name)
    write_state(sb, names, **state)


def script(sb, rel=ALLOW):
    path = sb.repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(PROBE)
    path.chmod(0o755)
    return rel


def ran(result):
    return [line.split()[1] for line in result.stdout.splitlines() if line.startswith(RAN)]


def run_with_terminal(sb, rel, typed, args=()):
    """The script with a real terminal on stdin; `typed` is what the user enters."""
    master, slave = pty.openpty()
    try:
        os.write(master, typed.encode() + b"\n")
        return subprocess.run(
            ["zsh", str(sb.repo / rel), *args], cwd=sb.repo, env=sb.env(), stdin=slave,
            capture_output=True, text=True, timeout=60, check=False,
        )
    finally:
        os.close(master)
        os.close(slave)


def run_with_stdin(sb, rel, data, args=(), env=None):
    """The script with `data` (bytes) piped to its stdin."""
    return subprocess.run(
        ["zsh", str(sb.repo / rel), *args], cwd=sb.repo, env=sb.env(env), input=data, capture_output=True, timeout=120, check=False,
    )


def got(stdout):
    return [line for line in stdout.splitlines() if line.startswith("GOT ")]


# ---- running per cluster ---------------------------------------------------------------------------------------
def test_t8_one_run_per_cluster_with_arguments_intact():
    with make_sandbox() as sb:
        clusters(sb)
        rel = script(sb)
        result = sb.run_script(rel, args=["one two", "", "--all-clusters", "--flag=a b"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]
        assert result.stdout.count("<one two><><--flag=a b>") == 2
        assert "--all-clusters" not in result.stdout


def test_t8_child_environment():
    with make_sandbox() as sb:
        clusters(sb)
        rel = script(sb)
        result = sb.run_script(rel, args=["--target-clusters", "itz-b,itz-a"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-b", "itz-a"]
        lines = {line.split()[1]: line for line in result.stdout.splitlines() if line.startswith("VARS ")}
        for name, line in lines.items():
            assert "child=1" in line and "prep=1" in line
            assert f"url={URLS[name]}" in line
            assert f"root={sb.repo}/configs/clusters/{name}" in line
            assert f"kube={sb.repo}/configs/clusters/{name}/.home/.kube/config" in line


def test_t8_runs_from_the_state_file():
    for state in ({"apply_to_all": "true"}, {"targets": "itz-a itz-b", "current": "itz-a"}):
        with make_sandbox() as sb:
            clusters(sb, **state)
            result = sb.run_script(script(sb))
            assert result.returncode == 0, result.stdout + result.stderr
            assert ran(result) == ["itz-a", "itz-b"]


def test_t8_env_target_flag_reaches_the_children():
    with make_sandbox() as sb:
        clusters(sb, configs=())
        for name in ("itz-a", "itz-b"):
            sb.write_config("concert", ocp_url=URLS[name], cluster=name)
        result = sb.run_script(script(sb), args=["--all-clusters", "--env-target", "concert"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]
        assert "--env-target" not in result.stdout


def test_t8_a_failure_does_not_stop_the_others_and_the_run_fails():
    with make_sandbox() as sb:
        clusters(sb, ("itz-a", "itz-b", "itz-c"))
        result = sb.run_script(script(sb), env={"FAIL_ON": "itz-b", "FAIL_RC": "7"}, args=["--all-clusters"])
        assert result.returncode == 7, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b", "itz-c"]
        assert "FAILED (rc 7)" in result.stdout


def test_t8_first_failure_decides_the_exit_code():
    with make_sandbox() as sb:
        clusters(sb)
        rel = script(sb)
        path = sb.repo / rel
        path.write_text(PROBE + '[[ "${MCM_CLUSTER}" == itz-a ]] && exit 4\nexit 9\n')
        result = sb.run_script(rel, args=["--all-clusters"])
        assert result.returncode == 4, result.stdout + result.stderr
        assert "FAILED (rc 4)" in result.stdout and "FAILED (rc 9)" in result.stdout


def test_t8_a_cluster_without_the_config_is_skipped_not_failed():
    with make_sandbox() as sb:
        clusters(sb, ("itz-a", "itz-b"), configs=("itz-a",))
        result = sb.run_script(script(sb), args=["--all-clusters"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a"]
        table = result.stdout[result.stdout.index("Result per cluster"):]
        assert "itz-b" in table and "skipped" in table
        assert "FAILED" not in table


def test_t8_all_clusters_skipped_uses_the_skip_code():
    with make_sandbox() as sb:
        clusters(sb, ("itz-a", "itz-b"), configs=())
        result = sb.run_script(script(sb), args=["--all-clusters"])
        assert result.returncode == 75, result.stdout + result.stderr
        assert "nothing ran" in result.stderr


def test_t8_interrupt_stops_the_rest():
    with make_sandbox() as sb:
        clusters(sb, ("itz-a", "itz-b", "itz-c"))
        result = sb.run_script(script(sb), env={"FAIL_ON": "itz-b", "FAIL_RC": "130"}, args=["--all-clusters"])
        assert result.returncode == 130, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]
        table = result.stdout[result.stdout.index("Result per cluster"):]
        assert "interrupted" in table and "not run" in table


def test_t8_progress_and_table_on_the_main_output():
    with make_sandbox() as sb:
        clusters(sb)
        result = sb.run_script(script(sb), args=["--all-clusters"])
        for text in ("[MCM] 1/2 itz-a", "[MCM] 2/2 itz-b", "[MCM] 1/2 itz-a: ok", "[MCM] 2/2 itz-b: ok", "CLUSTER", "RESULT", "DURATION"):
            assert text in result.stdout, result.stdout
        assert "[MCM]" not in result.stderr


def test_t8_the_parent_exit_trap_does_not_fire():
    with make_sandbox() as sb:
        clusters(sb)
        rel = script(sb)
        result = sb.run_script(rel, args=["--all-clusters"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert result.stdout.count("TRAP-FIRED") == 2
        assert "env_bootstrap" not in result.stdout


# ---- no double fan-out -----------------------------------------------------------------------------------------
def test_t8_a_child_does_not_fan_out_again():
    with make_sandbox() as sb:
        clusters(sb, apply_to_all="true")
        rel = script(sb)
        result = sb.run_script(rel)
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]


def test_t8_a_chained_script_with_a_target_flag_stays_on_its_cluster():
    with make_sandbox() as sb:
        clusters(sb)
        rel = script(sb)
        result = sb.run_script(rel, env={"NESTED_SCRIPT": rel}, args=["--all-clusters"], timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-a", "itz-b", "itz-b"]
        assert "staying on itz-a" in result.stderr


# ---- policies --------------------------------------------------------------------------------------------------
@pytest.mark.parametrize("rel", [
    "scripts/install_ibm_concert/x_clean_or_debug_concert/x_runner_shell.sh",
    f"{CPD_DIR}/check_cr_status/x_cr_state_dashboard.sh",
    f"{CPD_DIR}/4.5_service_instance_setups/x_service_instance_manager.sh",
    "scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh",
    "src/utilities/multi_cluster_management_utils/multi_cluster.sh",
])
def test_t8_single_only_refuses_several_targets_and_allows_one(rel):
    with make_sandbox() as sb:
        clusters(sb)
        script(sb, rel)
        refused = sb.run_script(rel, args=["--all-clusters"])
        assert refused.returncode == 1, refused.stdout + refused.stderr
        assert "[ERROR]" in refused.stderr and "one cluster at a time" in refused.stderr
        assert ran(refused) == []
        assert "TRAP-FIRED" not in refused.stdout


def test_t8_single_only_still_runs_on_one_target():
    with make_sandbox() as sb:
        clusters(sb)
        rel = f"{CPD_DIR}/check_cr_status/x_cr_state_dashboard.sh"
        script(sb, rel)
        result = sb.run_script(rel, args=["--target-cluster", "itz-a"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a"]
        assert "[MCM]" not in result.stdout


UNINSTALL = f"{CPD_DIR}/x_clean_or_debug_cp4d/x_uninstall_softwarehub_and_cpd.sh"


def test_t8_confirm_refuses_without_a_terminal():
    with make_sandbox() as sb:
        clusters(sb)
        script(sb, UNINSTALL)
        result = sb.run_script(UNINSTALL, args=["--all-clusters"])
        assert result.returncode == 1, result.stdout + result.stderr
        assert ran(result) == []
        assert "--yes-all-clusters" in result.stderr


def test_t8_confirm_flag_runs_without_a_terminal_and_is_consumed():
    with make_sandbox() as sb:
        clusters(sb)
        script(sb, UNINSTALL)
        result = sb.run_script(UNINSTALL, args=["--all-clusters", "--yes-all-clusters", "keep"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]
        assert "--yes-all-clusters" not in result.stdout
        assert result.stdout.count("<keep>") == 2


def test_t8_confirm_typed_answer_runs():
    with make_sandbox() as sb:
        clusters(sb)
        script(sb, UNINSTALL)
        result = run_with_terminal(sb, UNINSTALL, "confirm-2", args=["--all-clusters"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]
        assert "itz-a" in result.stdout.split("confirm-2")[0]


def test_t8_confirm_wrong_answer_cancels():
    with make_sandbox() as sb:
        clusters(sb)
        script(sb, UNINSTALL)
        result = run_with_terminal(sb, UNINSTALL, "yes", args=["--all-clusters"])
        assert result.returncode == 1, result.stdout + result.stderr
        assert ran(result) == []
        assert "Cancelled" in result.stderr


def test_t8_confirm_not_asked_for_one_target():
    with make_sandbox() as sb:
        clusters(sb)
        script(sb, UNINSTALL)
        result = sb.run_script(UNINSTALL, args=["--target-cluster", "itz-b"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-b"]


def test_t8_non_destructive_match_is_not_confirmed():
    with make_sandbox() as sb:
        rel = "scripts/install_ibm_concert/4_post_install/4.4_refresh_concert_ca_bundle.sh"
        clusters(sb, configs=())
        for name in ("itz-a", "itz-b"):
            sb.write_config("concert", ocp_url=URLS[name], cluster=name)
        script(sb, rel)
        result = sb.run_script(rel, args=["--all-clusters"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]


def test_t8_the_oadp_entry_point_applies_the_policy():
    with make_sandbox() as sb:
        clusters(sb)
        rel = "src/utilities/oadp_backup_restore_cp4d_utils/5_uninstall_from_target_cluster.sh"
        path = sb.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '#!/bin/zsh\nset -euo pipefail\n'
            'source "${0:A:h:h:h:h}/src/helpers/oadp_br_helpers.sh"\n'
            'print -r -- "RAN ${MCM_CLUSTER:-flat}"\n'
        )
        path.chmod(0o755)
        refused = sb.run_script(rel, args=["--all-clusters"])
        assert refused.returncode == 1, refused.stdout + refused.stderr
        assert "--yes-all-clusters" in refused.stderr
        result = sb.run_script(rel, args=["--all-clusters", "--yes-all-clusters"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]


def policy_of(sb, paths):
    body = "source src/helpers/multi_cluster_helpers.sh\n"
    for rel in paths:
        body += f'print -r -- "{rel} $(mcm_script_policy "$PWD/{rel}")"\n'
    result = sb.run_zsh(body, check=True)
    return dict(line.split() for line in result.stdout.splitlines())


def test_t8_policy_of_every_script_in_the_repo():
    listed = subprocess.run(["git", "ls-files", "*.sh"], cwd=REPO, capture_output=True, text=True, check=True)
    paths = [p for p in listed.stdout.splitlines() if " " not in p]
    with make_sandbox() as sb:
        policies = policy_of(sb, paths)
    matches = [p for p in paths if any(w in p.rsplit("/", 1)[-1].lower() for w in
                                       ("uninstall", "reinstall", "delete", "remove", "prune", "force", "clean", "refresh",
                                        "restore"))]
    confirm = sorted(p for p, v in policies.items() if v == "confirm")
    # Matches the name rule, but the exceptions come first: a CA refresh, and a generator (one cluster's config).
    exceptions = ("4.4_refresh_concert_ca_bundle.sh", "1.2_generate_restore_target_config.sh")
    # Matches no word, but force-removes the cluster's container.
    toggle = ["src/utilities/cpd-cli_utils/cpd-cli_toggle_olm_image.sh"]
    assert confirm == sorted([p for p in matches if not p.endswith(exceptions)] + toggle)
    restores = {name for name in (p.rsplit("/", 1)[-1] for p in confirm) if "restore" in name}
    assert restores == {"4_restore_cp4d_instance.sh", "4.1_restore_cp4d_instance_fresh_cluster.sh",
                        "2.6_restore_transfer_bundle.sh"}
    assert policies["src/utilities/oadp_backup_restore_cp4d_utils/1.2_generate_restore_target_config.sh"] == "single-only"
    assert policies["scripts/install_ibm_concert/4_post_install/4.4_refresh_concert_ca_bundle.sh"] == "allow"
    reinstalls = {p.rsplit("/", 1)[-1] for p in confirm if "reinstall" in p.lower()}
    assert {"x_specific_component_REinstall.sh", "x.1_confluent_reinstall.sh"} <= reinstalls
    for read_only_name_in_clean_folder in (p for p in paths if "x_clean_or_debug" in p and p not in matches):
        assert policies[read_only_name_in_clean_folder] != "confirm"
    single = {p.rsplit("/", 1)[-1] for p, v in policies.items() if v == "single-only"}
    assert {"x_runner_shell.sh", "x_cr_state_dashboard.sh", "x_service_instance_manager.sh",
            "0.0_generate_mirror_config.sh", "generate_kubecost_config.sh"} <= single
    assert "4.6_generate_api_key.sh" not in single and "generate_service_id_cpd_apikeys.sh" not in single


# ---- no variable leakage ---------------------------------------------------------------------------------------
def test_t8_a_pinned_shell_does_not_leak_into_the_other_clusters():
    with make_sandbox() as sb:
        clusters(sb, current="itz-a", configs=("itz-b",))
        sb.write_config("cpd", ocp_url=URLS["itz-a"], cluster="itz-a", extra={"A_ONLY": "from-a"})
        rel = script(sb)
        result = sb.run_zsh(
            'source s_env.sh cpd --target-cluster itz-a\n'
            '[[ "${A_ONLY}" == from-a ]] || { print -r -- "pin failed"; exit 40; }\n'
            f'zsh "$PWD/{rel}" --all-clusters\n',
            strict=False,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        lines = {line.split()[1]: line for line in result.stdout.splitlines() if line.startswith("VARS ")}
        assert "only=from-a" in lines["itz-a"]
        assert "only= " in lines["itz-b"]
        assert f"url={URLS['itz-b']}" in lines["itz-b"]
        assert f"kube={sb.repo}/configs/clusters/itz-b/.home/.kube/config" in lines["itz-b"]


RUNNER_PROBE = r'''#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="${_b:h}"; done; source "${_b}/env_bootstrap.sh"; unset _b
print -r -- "RUNNER ${MCM_CLUSTER:-flat} mode=${INSTALL_RUN_MODE:-} override=${INSTALL_RUN_MODE_OVERRIDE:-} sc=${INSTALL_RUNNER_STORAGE_CLASS:-} image=${INSTALL_RUNNER_IMAGE:-} new=${INSTALL_RUNNER_NEW_RUN:-}"
'''


def test_i7_shell_runner_settings_do_not_cross_clusters_but_the_override_does():
    """A storage class or image exported once names one cluster; --run-mode (the override) and the
    one-run switches such as INSTALL_RUNNER_NEW_RUN are meant for all."""
    with make_sandbox() as sb:
        clusters(sb, configs=("itz-b",))
        sb.write_config("cpd", ocp_url=URLS["itz-a"], cluster="itz-a", extra={"INSTALL_RUNNER_STORAGE_CLASS": "class-a"})
        path = sb.repo / ALLOW
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(RUNNER_PROBE)
        path.chmod(0o755)
        shell = {
            "INSTALL_RUN_MODE": "cluster",
            "INSTALL_RUN_MODE_OVERRIDE": "local",
            "INSTALL_RUNNER_STORAGE_CLASS": "shell-class",
            "INSTALL_RUNNER_IMAGE": "registry.itz-a.example.com/runner:1",
            "INSTALL_RUNNER_NEW_RUN": "true",
        }
        result = sb.run_script(ALLOW, env=shell, args=["--all-clusters"])
        assert result.returncode == 0, result.stdout + result.stderr
        lines = {line.split()[1]: line for line in result.stdout.splitlines() if line.startswith("RUNNER ")}
        assert lines["itz-a"] == "RUNNER itz-a mode= override=local sc=class-a image= new=true"
        assert lines["itz-b"] == "RUNNER itz-b mode= override=local sc= image= new=true"


def test_t8_a_preset_target_kubeconfig_is_left_alone():
    with make_sandbox() as sb:
        clusters(sb)
        result = sb.run_script(script(sb), env={"KUBECONFIG": "/tmp/mcm-target", "MCM_KUBECONFIG_OVERRIDE": "1"}, args=["--all-clusters"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert result.stdout.count("kube=/tmp/mcm-target") == 2


# ---- sourced loads ---------------------------------------------------------------------------------------------
def test_t8_a_load_with_no_script_never_fans_out():
    with make_sandbox() as sb:
        clusters(sb, current="itz-b", apply_to_all="true")
        result = subprocess.run(
            ["zsh", "-c", 'source ./env_bootstrap.sh; print -r -- "ON ${MCM_CLUSTER}"'],
            cwd=sb.repo, env=sb.env({"ENV_TARGET": "cpd"}), capture_output=True, text=True, timeout=60, check=False,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert "ON itz-b" in result.stdout
        assert "[MCM]" not in result.stdout


def test_t8_s_env_never_fans_out():
    with make_sandbox() as sb:
        clusters(sb, current="itz-a", apply_to_all="true")
        result = sb.run_zsh('source s_env.sh cpd\nprint -r -- "ON ${MCM_CLUSTER}"\n', strict=False)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "ON itz-a" in result.stdout and "[MCM]" not in result.stdout


# ---- mode off --------------------------------------------------------------------------------------------------
def test_t8_mode_off_runs_once_and_drops_the_confirmation_flag():
    with make_sandbox() as sb:
        sb.write_config("cpd", ocp_url=URLS["itz-a"])
        rel = script(sb)
        result = sb.run_script(rel, args=["--yes-all-clusters", "keep"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["flat"]
        assert "<keep>" in result.stdout and "--yes-all-clusters" not in result.stdout
        assert "[MCM]" not in result.stdout


# ---- review findings on P5 -------------------------------------------------------------------------------------
@pytest.mark.parametrize("name", ["x_specific_component_REinstall.sh", "x.1_confluent_reinstall.sh"])
def test_t8_a_reinstall_needs_a_confirmation(name):
    with make_sandbox() as sb:
        clusters(sb)
        rel = script(sb, f"{CPD_DIR}/x_clean_or_debug_cp4d/{name}")
        result = sb.run_script(rel, args=["--all-clusters"])
        assert result.returncode == 1, result.stdout + result.stderr
        assert ran(result) == []
        assert "--yes-all-clusters" in result.stderr


@pytest.mark.parametrize("rel", [
    "src/utilities/oadp_backup_restore_cp4d_utils/4_restore_cp4d_instance.sh",
    "src/utilities/oadp_backup_restore_cp4d_utils/4.1_restore_cp4d_instance_fresh_cluster.sh",
    "scripts/private_registry_mirroring/2_download_and_mirror/2.6_restore_transfer_bundle.sh",
])
def test_t8_a_restore_needs_a_confirmation(rel):
    with make_sandbox() as sb:
        clusters(sb)
        result = sb.run_zsh(
            "source src/helpers/multi_cluster_helpers.sh\n"
            f'print -r -- "$(mcm_script_policy "$PWD/{rel}")"\n', check=True,
        )
        assert result.stdout.strip() == "confirm"


def test_t8_every_cluster_gets_the_same_piped_input():
    with make_sandbox() as sb:
        clusters(sb)
        rel = script(sb)
        result = run_with_stdin(sb, rel, b"SECRET-KEY\nsecond\n", args=["--all-clusters"], env={"READ_STDIN": "1"})
        out = result.stdout.decode()
        assert result.returncode == 0, out + result.stderr.decode()
        assert got(out) == ["GOT itz-a [SECRET-KEY]", "GOT itz-b [SECRET-KEY]"]
        assert list(sb.tmp.glob("mcm-stdin.*")) == []


def test_t8_empty_piped_input_reads_as_end_of_file_everywhere():
    with make_sandbox() as sb:
        clusters(sb)
        result = run_with_stdin(sb, script(sb), b"", args=["--all-clusters"], env={"READ_STDIN": "1"})
        out = result.stdout.decode()
        assert result.returncode == 0, out + result.stderr.decode()
        assert got(out) == ["GOT itz-a [<EOF>]", "GOT itz-b [<EOF>]"]


def test_t8_endless_piped_input_is_refused():
    with make_sandbox() as sb:
        clusters(sb)
        result = run_with_stdin(sb, script(sb), b"y\n" * (9 * 1024 * 1024), args=["--all-clusters"])
        assert result.returncode == 1, result.stdout.decode() + result.stderr.decode()
        assert "RAN " not in result.stdout.decode()
        assert "MiB" in result.stderr.decode()
        assert list(sb.tmp.glob("mcm-stdin.*")) == []


def test_t8_an_open_pipe_nobody_writes_to_does_not_hang_the_run():
    with make_sandbox() as sb:
        clusters(sb)
        rel = script(sb)
        read_end, write_end = os.pipe()
        try:
            result = subprocess.run(
                ["zsh", str(sb.repo / rel), "--all-clusters"], cwd=sb.repo, env=sb.env({"READ_STDIN": "1"}),
                stdin=read_end, capture_output=True, text=True, timeout=60, check=False,
            )
        finally:
            os.close(read_end)
            os.close(write_end)
        assert result.returncode == 0, result.stdout + result.stderr
        assert got(result.stdout) == ["GOT itz-a [<EOF>]", "GOT itz-b [<EOF>]"]
        assert "Standard input is open" in result.stderr


def nested_concert_step(sb):
    """A CP4D-folder script with a nested Concert-folder step; only itz-a has a Concert config."""
    clusters(sb)
    sb.write_config("concert", ocp_url=URLS["itz-a"], cluster="itz-a")
    return script(sb), script(sb, "scripts/install_ibm_concert/4_post_install/x_nested_probe.sh")


def test_t8_a_nested_step_without_its_config_fails_the_cluster():
    with make_sandbox() as sb:
        rel, nested = nested_concert_step(sb)
        result = sb.run_script(rel, env={"NESTED_SCRIPT": nested}, args=["--all-clusters"], timeout=120)
        assert result.returncode == 1, result.stdout + result.stderr
        table = result.stdout[result.stdout.index("Result per cluster"):]
        assert "skipped" not in table
        assert "FAILED (rc 1)" in table
        assert result.stdout.count("AFTER-NESTED itz-b") == 0
        assert "needs a 'concert' config" in result.stderr
        for line in result.stdout.splitlines():
            if line.startswith("TRAP-FIRED"):
                assert line.endswith(("x_probe.sh", "x_nested_probe.sh")), line


def test_t8_a_later_load_in_the_same_script_fails_the_cluster():
    with make_sandbox() as sb:
        clusters(sb, configs=("itz-a", "itz-b"))
        sb.write_config("concert", ocp_url=URLS["itz-a"], cluster="itz-a")
        rel = script(sb)
        path = sb.repo / rel
        path.write_text(PROBE + 'ENV_TARGET=concert source "${_CP4D_REPO_ROOT}/env_bootstrap.sh"\n')
        result = sb.run_script(rel, args=["--all-clusters"], timeout=120)
        assert result.returncode == 1, result.stdout + result.stderr
        table = result.stdout[result.stdout.index("Result per cluster"):]
        assert "skipped" not in table
        assert "FAILED (rc 1)" in table


def test_t8_a_skipped_cluster_does_not_run_the_exit_trap():
    with make_sandbox() as sb:
        clusters(sb, ("itz-a", "itz-b"), configs=("itz-a",))
        result = sb.run_script(script(sb), args=["--all-clusters"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert result.stdout.count("TRAP-FIRED") == 1
        assert "source_env_setup" not in result.stdout


def flat_shell_then_mode_on(sb, rel_args):
    """Loads the flat config in a shell while the mode is off, turns it on, starts the script from that shell."""
    state = sb.repo / "configs" / "multi_cluster_management.sh"
    on_state = sb.tmp / "on_state.sh"
    on_state.write_text(state.read_text())
    state.write_text(state.read_text().replace('MULTI_CLUSTER_MANAGEMENT="true"', 'MULTI_CLUSTER_MANAGEMENT="false"'))
    sb.write_config("cpd", ocp_url="https://api.flat.example.com:6443", extra={"FLAT_ONLY": "from-flat"})
    return sb.run_zsh(
        'source s_env.sh cpd\n'
        '[[ "${FLAT_ONLY}" == from-flat ]] || { print -r -- "flat load failed"; exit 40; }\n'
        f'cp "{on_state}" configs/multi_cluster_management.sh\n'
        + rel_args + "\n",
        strict=False,
    )


def test_t8_a_flat_shell_does_not_leak_into_the_clusters():
    with make_sandbox() as sb:
        clusters(sb)
        rel = script(sb)
        result = flat_shell_then_mode_on(sb, f'zsh "$PWD/{rel}" --all-clusters')
        assert result.returncode == 0, result.stdout + result.stderr
        lines = [line for line in result.stdout.splitlines() if line.startswith("VARS ")]
        assert len(lines) == 2, result.stdout + result.stderr
        assert all("flat_only= " in line for line in lines), lines
        assert f"url={URLS['itz-a']}" in lines[0] and f"url={URLS['itz-b']}" in lines[1]


def test_t8_a_real_ctrl_c_prints_the_table_and_stops_the_rest():
    with make_sandbox() as sb:
        clusters(sb, ("itz-a", "itz-b", "itz-c"))
        rel = script(sb)
        marker = sb.tmp / "started"
        proc = subprocess.Popen(
            ["zsh", str(sb.repo / rel), "--all-clusters"], cwd=sb.repo, env=sb.env({"WAIT_FILE": str(marker)}),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 40
            while not marker.exists():
                assert time.monotonic() < deadline, "the first cluster never started"
                time.sleep(0.05)
            time.sleep(0.2)
            os.killpg(proc.pid, signal.SIGINT)
            stdout, stderr = proc.communicate(timeout=30)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
        assert proc.returncode == 130, stdout + stderr
        assert [line.split()[1] for line in stdout.splitlines() if line.startswith(RAN)] == ["itz-a"]
        table = stdout[stdout.index("Result per cluster"):]
        assert "interrupted" in table
        assert table.count("not run") == 2


def test_t8_yes_flag_does_not_skip_the_prompt_at_a_terminal():
    with make_sandbox() as sb:
        clusters(sb)
        script(sb, UNINSTALL)
        cancelled = run_with_terminal(sb, UNINSTALL, "no", args=["--all-clusters", "--yes-all-clusters"])
        assert cancelled.returncode == 1, cancelled.stdout + cancelled.stderr
        assert ran(cancelled) == []
        assert "Cancelled" in cancelled.stderr
        typed = run_with_terminal(sb, UNINSTALL, "confirm-2", args=["--all-clusters", "--yes-all-clusters"])
        assert typed.returncode == 0, typed.stdout + typed.stderr
        assert ran(typed) == ["itz-a", "itz-b"]


def with_removed_cluster(sb, **state):
    clusters(sb, **state)
    sb.write_cluster_marker("itz-removed", "https://api.itz-removed.example.com:6443")
    sb.write_config("cpd", ocp_url="https://api.itz-removed.example.com:6443", cluster="itz-removed")


@pytest.mark.parametrize("args", [["--target-clusters", "itz-a,itz-removed"], ["--target-clusters", "itz-removed"]])
def test_t8_an_unregistered_cluster_in_a_flag_list_is_refused(args):
    with make_sandbox() as sb:
        with_removed_cluster(sb)
        result = sb.run_script(script(sb), args=args)
        assert result.returncode == 1, result.stdout + result.stderr
        assert ran(result) == []
        assert "not registered" in result.stderr and "itz-a itz-b" in result.stderr


def test_t8_an_unregistered_cluster_in_the_state_file_list_is_refused():
    with make_sandbox() as sb:
        with_removed_cluster(sb, targets="itz-a itz-removed")
        result = sb.run_script(script(sb))
        assert result.returncode == 1, result.stdout + result.stderr
        assert ran(result) == []
        assert "not registered" in result.stderr


def test_t8_one_explicit_pin_to_an_unregistered_cluster_still_warns_and_runs():
    with make_sandbox() as sb:
        with_removed_cluster(sb)
        result = sb.run_script(script(sb), args=["--target-cluster", "itz-removed"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-removed"]
        assert "[WARN]" in result.stderr and "not registered" in result.stderr


USAGE_PROBE = PROBE.replace("printf 'RAN %s '", """case "${1:-}" in -h|--help) print -r -- "USAGE ${MCM_CLUSTER:-flat}"; exit 0 ;; esac
printf 'RAN %s '""")


def usage_lines(result):
    return [line for line in result.stdout.splitlines() if line.startswith("USAGE ")]


@pytest.mark.parametrize("flag", ["--help", "-h"])
def test_t8_help_prints_the_usage_once(flag):
    with make_sandbox() as sb:
        clusters(sb, apply_to_all="true", current="itz-b")
        rel = script(sb)
        (sb.repo / rel).write_text(USAGE_PROBE)
        result = sb.run_script(rel, args=[flag])
        assert result.returncode == 0, result.stdout + result.stderr
        assert usage_lines(result) == ["USAGE itz-b"]
        assert "[MCM]" not in result.stdout


def test_t8_help_on_a_destructive_script_needs_no_confirmation():
    with make_sandbox() as sb:
        clusters(sb, apply_to_all="true")
        script(sb, UNINSTALL)
        (sb.repo / UNINSTALL).write_text(USAGE_PROBE)
        result = sb.run_script(UNINSTALL, args=["--help"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert usage_lines(result) == ["USAGE itz-a"]
        assert "--yes-all-clusters" not in result.stderr


def test_t8_help_on_a_script_with_no_usage_option_keeps_its_policy():
    """The real x_uninstall_softwarehub_and_cpd.sh has no --help: it ignores the word and uninstalls."""
    with make_sandbox() as sb:
        clusters(sb, apply_to_all="true")
        script(sb, UNINSTALL)
        result = sb.run_script(UNINSTALL, args=["--help"])
        assert result.returncode == 1, result.stdout + result.stderr
        assert ran(result) == []
        assert "--yes-all-clusters" in result.stderr


@pytest.mark.parametrize("args, message", [
    (["--target-clusters", "itz-a,itz-ghost"], "itz-ghost"),
    (["--target-cluster", "a,b"], "takes one name"),
])
def test_t8_a_refused_target_does_not_run_the_exit_trap(args, message):
    with make_sandbox() as sb:
        clusters(sb)
        result = sb.run_script(script(sb), args=args)
        assert result.returncode == 1, result.stdout + result.stderr
        assert message in result.stderr
        assert "TRAP-FIRED" not in result.stdout


def test_t8_a_script_argument_cannot_turn_off_the_fanout():
    with make_sandbox() as sb:
        clusters(sb, apply_to_all="true", current="itz-a")
        result = sb.run_script(script(sb), args=["--no-fanout", "x"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]
        assert result.stdout.count("<--no-fanout><x>") == 2


# ---- one-way delineation: explicit names fan out with the flag off -----------------------------------------------
def clusters_off(sb, names=("itz-a", "itz-b"), **state):
    clusters(sb, names, **state)
    path = sb.repo / "configs" / "multi_cluster_management.sh"
    path.write_text(path.read_text().replace('MULTI_CLUSTER_MANAGEMENT="true"', 'MULTI_CLUSTER_MANAGEMENT="false"'))


def test_t8_mode_off_fans_out_over_named_delineated_clusters():
    with make_sandbox() as sb:
        clusters_off(sb)
        rel = script(sb)
        result = sb.run_script(rel, args=["--target-clusters", "itz-b,itz-a", "keep"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-b", "itz-a"]
        lines = {line.split()[1]: line for line in result.stdout.splitlines() if line.startswith("VARS ")}
        for name, line in lines.items():
            assert f"url={URLS[name]}" in line
            assert f"root={sb.repo}/configs/clusters/{name}" in line
            assert f"kube={sb.repo}/configs/clusters/{name}/.home/.kube/config" in line
        assert result.stdout.count("<keep>") == 2


def test_t8_mode_off_all_clusters_leaves_out_retired_ones():
    with make_sandbox() as sb:
        clusters_off(sb, ("itz-a", "itz-b", "itz-c"))
        marker = sb.repo / "configs" / "clusters" / "itz-c" / ".cluster"
        marker.write_text(marker.read_text() + 'RETIRED="true"\n')
        rel = script(sb)
        result = sb.run_script(rel, args=["--all-clusters"])
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["itz-a", "itz-b"]


def test_t8_mode_off_ignores_apply_to_all_and_runs_flat_once():
    with make_sandbox() as sb:
        clusters_off(sb, current="itz-a", apply_to_all="true")
        sb.write_config("cpd", ocp_url="https://api.flat.example.com:6443")
        rel = script(sb)
        result = sb.run_script(rel)
        assert result.returncode == 0, result.stdout + result.stderr
        assert ran(result) == ["flat"]
        assert "[MCM]" not in result.stdout
