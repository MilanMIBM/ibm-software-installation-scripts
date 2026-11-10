"""T9: src/utilities/multi_cluster_management_utils/multi_cluster.sh, each subcommand against a sandbox repo (plan 5.9)."""

import os
import re
import subprocess
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "helpers"))

import multi_cluster_state as mcm
from mcm_harness import make_sandbox

SCRIPT = "src/utilities/multi_cluster_management_utils/multi_cluster.sh"
URL_A = "https://api.itz-a.example.com:6443"
URL_B = "https://api.itz-b.example.com:6443"
PLAY = "olm-utils-play-v4"
SWHCC = "olm-utils-swhub-control-center"
SCAN_MARK = "mcm-proc-scan"
IDLE_TABLE = "self 999\n1 0 sleep infinity\n"
BUSY_TABLE = "self 999\n4242 1 oc apply -f x.yaml\n"
LONG_AGO = "2026-01-01T00:00:00Z"
WATCHER = "src/helpers/multi_cluster_idle_watcher.sh"
MIGRATE = "src/utilities/multi_cluster_management_utils/migrate_to_multi_cluster.sh"

# Stands in for migrate_to_multi_cluster.sh. STUB_MODE decides what it does to the state.
MIGRATE_STUB = """#!/bin/zsh
set -euo pipefail
print -r -- "$*" >> "${HOME}/migrate_calls"
source "${0:A:h:h:h}/helpers/multi_cluster_helpers.sh"
case "${STUB_MODE:-enable}" in
  enable)  mcm_write_state MULTI_CLUSTER_MANAGEMENT=true ;;
  nothing) ;;
  fail)    exit 3 ;;
  off)     mcm_write_state MULTI_CLUSTER_MANAGEMENT=false ;;
esac
"""


@pytest.fixture
def sb():
    with make_sandbox(extra=["src/utilities/multi_cluster_management_utils"]) as box:
        # Replaces the detached watcher: leaves a file and exits, so no stray process outlives the test.
        (box.repo / WATCHER).write_text('#!/bin/zsh\nprint -r -- started >> "${HOME}/watcher_started"\n')
        (box.repo / MIGRATE).write_text(MIGRATE_STUB)
        yield box


def run(sb, *args, input="", env=None, timeout=60):
    """Runs the utility in the sandbox with a given stdin (empty means EOF, as in a pipeline)."""
    return subprocess.run(
        ["zsh", str(sb.repo / SCRIPT), *args], cwd=sb.repo, env=sb.env(env), input=input,
        capture_output=True, text=True, timeout=timeout, check=False,
    )


def state(sb):
    return mcm.read_state(repo=sb.repo, env={})


def setup_on(sb, names=("itz-a", "itz-b"), current=None):
    assert run(sb, "on", "--no-migrate").returncode == 0
    for name in names:
        assert run(sb, "add", name, "--url", f"https://api.{name}.example.com:6443").returncode == 0
    if current:
        assert run(sb, "use", current).returncode == 0
    sb.clear_calls()


def idle(sb, container="*"):
    sb.add_exec_rule(SCAN_MARK, stdout=IDLE_TABLE, container=container)


def busy(sb, container):
    rule = {"container": container, "contains": SCAN_MARK, "stdout": BUSY_TABLE, "stderr": "", "rc": 0}
    sb.update_fake_state(lambda fake: fake["exec_rules"].insert(0, rule))


def podman_verbs(sb, verb):
    return [argv for argv in sb.calls("podman") if argv[:1] == [verb]]


def stops(sb):
    return [argv[-1] for argv in podman_verbs(sb, "stop")]


def starts(sb):
    return [argv[-1] for argv in podman_verbs(sb, "start")]


def removed(sb):
    return [argv[-1] for argv in podman_verbs(sb, "rm")]


def lease_file(sb, cluster):
    """A lease held by the test process: alive for the whole test."""
    path = sb.home / "cpd-cli" / "clusters" / cluster / ".leases" / str(os.getpid())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("run\n")
    return path


def migrate_calls(sb):
    calls = sb.home / "migrate_calls"
    lines = calls.read_text().splitlines() if calls.exists() else []
    return [line for line in lines if line != "--preflight-only"]  # asked before every turn-on


def status_row(result, container):
    for line in result.stdout.splitlines():
        words = line.split()
        if container in words:
            return line, words
    raise AssertionError(f"no row for {container}:\n{result.stdout}\n{result.stderr}")


# ---- help and usage -----------------------------------------------------------------------------
class TestUsage:
    def test_help_needs_no_state_file(self, sb):
        result = run(sb, "--help")
        assert result.returncode == 0 and "containers status" in result.stdout
        assert not (sb.repo / "configs" / "multi_cluster_management.sh").exists()

    def test_help_states_the_one_way_rule_and_has_no_restore(self, sb):
        text = run(sb, "--help").stdout
        assert "one-way per cluster" in text and "cannot be undone" in text
        assert "--restore" not in text and "Retires a cluster" in text

    def test_subcommand_help(self, sb):
        assert run(sb, "containers", "--help").returncode == 0
        assert "rename OLD NEW" in run(sb, "rename", "--help").stdout

    def test_no_arguments_prints_usage(self, sb):
        result = run(sb)
        assert result.returncode == 2 and "multi_cluster.sh on" in result.stdout

    def test_unknown_command(self, sb):
        result = run(sb, "frobnicate")
        assert result.returncode == 2 and "Unknown command" in result.stderr

    def test_utility_call_generates_the_state_file_with_mode_off(self, sb):
        assert run(sb, "list").returncode == 0
        assert (sb.repo / "configs" / "multi_cluster_management.sh").is_file()
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_invalid_state_file_aborts_every_command(self, sb):
        (sb.repo / "configs" / "multi_cluster_management.sh").write_text('export MULTI_CLUSTER_MANAGEMENT="maybe"\n')
        result = run(sb, "on")
        assert result.returncode == 1 and "MULTI_CLUSTER_MANAGEMENT" in result.stderr


# ---- status and list -----------------------------------------------------------------------------
class TestStatusAndList:
    def test_status_mode_off_without_podman(self, sb):
        result = run(sb, "status")
        assert result.returncode == 0
        assert re.search(r"management:\s+off", result.stdout)
        assert sb.calls("podman") == []

    def test_status_shows_the_selection(self, sb):
        setup_on(sb, current="itz-a")
        assert run(sb, "targets", "itz-b").returncode == 0
        result = run(sb, "status")
        assert re.search(r"management:\s+on", result.stdout)
        assert re.search(r"Current cluster:\s+itz-a", result.stdout)
        assert re.search(r"Targeted now:\s+itz-b$", result.stdout, re.MULTILINE)
        assert "Flat configs" not in result.stderr

    def test_status_warns_about_flat_configs_while_on(self, sb):
        sb.write_config("cpd")
        setup_on(sb)
        assert "Flat configs" in run(sb, "status").stderr

    def test_list_marks_current_and_targeted(self, sb):
        setup_on(sb, current="itz-a")
        result = run(sb, "list")
        line_a = next(l for l in result.stdout.splitlines() if l.startswith("itz-a"))
        line_b = next(l for l in result.stdout.splitlines() if l.startswith("itz-b"))
        assert "*" in line_a and "yes" in line_a and URL_A in line_a
        assert "*" not in line_b and " no " in line_b

    def test_list_shows_folders_that_are_not_registered(self, sb):
        setup_on(sb, names=("itz-a",))
        (sb.repo / "configs" / "clusters" / "itz-old").mkdir()
        assert "not registered" in run(sb, "list").stdout

    def test_list_empty(self, sb):
        result = run(sb, "list")
        assert "No clusters" in result.stdout and "mode off" in result.stdout and "flat configs/ layout" in result.stdout

    def test_status_shows_the_default_delineated_and_retired(self, sb):
        setup_on(sb, names=("itz-a", "itz-b", "itz-c"))
        assert run(sb, "remove", "itz-c").returncode == 0
        assert run(sb, "off").returncode == 0
        result = run(sb, "status")
        assert result.returncode == 0, result.stderr
        assert re.search(r"Default layout:\s+the flat configs/ layout", result.stdout)
        assert re.search(r"Delineated clusters:\s+itz-a itz-b itz-c \(one-way", result.stdout)
        assert re.search(r"Retired clusters:\s+itz-c$", result.stdout, re.MULTILINE)
        assert re.search(r"Registered clusters:\s+itz-a itz-b$", result.stdout, re.MULTILINE)
        assert "select nothing" in result.stdout

    def test_status_with_the_mode_on_names_per_cluster_folders_as_default(self, sb):
        setup_on(sb, names=("itz-a",))
        result = run(sb, "status")
        assert re.search(r"Default layout:\s+per-cluster folders", result.stdout)
        assert re.search(r"Retired clusters:\s+none$", result.stdout, re.MULTILINE)

    def test_status_mode_off_targets_only_the_pinned_cluster(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        result = run(sb, "status", env={"MCM_CLUSTER": "itz-a"})
        assert re.search(r"Targeted now:\s+itz-a$", result.stdout, re.MULTILINE)

    def test_status_mode_off_warns_about_conflicting_flat_configs(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        sb.write_config("cpd", ocp_url=URL_A + "/")
        sb.write_config("kubecost", ocp_url=URL_B)
        result = run(sb, "status")
        assert result.returncode == 0
        assert "cp4d_config/cpd_vars.sh" in result.stderr and "'itz-a'" in result.stderr
        assert URL_B not in result.stderr

    def test_list_shows_retired_unregistered_and_the_default(self, sb):
        setup_on(sb, names=("itz-a", "itz-b"))
        assert run(sb, "remove", "itz-b").returncode == 0
        sb.write_cluster_marker("itz-hand", URL_A)
        result = run(sb, "list")
        assert result.returncode == 0, result.stderr
        rows = {l.split()[0]: l for l in result.stdout.splitlines() if l.startswith("itz-")}
        assert " active " in rows["itz-a"]
        assert " retired " in rows["itz-b"] and URL_B in rows["itz-b"]
        assert " unregistered " in rows["itz-hand"] and "add itz-hand" in rows["itz-hand"]
        assert "mode on" in result.stdout and "per-cluster folders" in result.stdout
        assert "Delineated clusters (one-way" in result.stdout and "itz-a itz-b itz-hand" in result.stdout
        assert "Retired clusters stay delineated: itz-b" in result.stdout


# ---- on and off ----------------------------------------------------------------------------------
class TestOn:
    def test_no_flat_configs_turns_on_without_migrate(self, sb):
        result = run(sb, "on")
        assert result.returncode == 0 and state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"
        assert migrate_calls(sb) == []

    def test_flat_configs_with_no_answer_available_refuses(self, sb):
        sb.write_config("cpd")
        result = run(sb, "on")
        assert result.returncode == 1 and "--no-migrate" in result.stderr
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "false"
        assert migrate_calls(sb) == []

    def test_prompt_yes_runs_migrate_with_its_own_confirmation(self, sb):
        sb.write_config("cpd")
        result = run(sb, "on", input="y\n")
        assert result.returncode == 0 and "Migrate them now?" in result.stdout
        assert "one-way for each cluster it moves" in result.stdout
        assert migrate_calls(sb) == [""]
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"

    def test_prompt_no_turns_on_and_leaves_flat_configs(self, sb):
        path = sb.write_config("cpd")
        result = run(sb, "on", input="n\n")
        assert result.returncode == 0 and state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"
        assert migrate_calls(sb) == [] and path.is_file()
        assert "Flat configs" in result.stderr

    def test_migrate_flag_skips_the_prompt(self, sb):
        sb.write_config("cpd")
        result = run(sb, "on", "--migrate")
        assert result.returncode == 0 and "Migrate them now?" not in result.stdout
        assert migrate_calls(sb) == ["--yes"]

    def test_migrate_flag_with_nothing_to_move_still_turns_on(self, sb):
        sb.write_config("cpd")
        result = run(sb, "on", "--migrate", env={"STUB_MODE": "nothing"})
        assert result.returncode == 0 and state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"

    def test_declined_at_the_plan_keeps_the_mode_off(self, sb):
        sb.write_config("cpd")
        result = run(sb, "on", input="y\n", env={"STUB_MODE": "nothing"})
        assert result.returncode == 0 and "stays off" in result.stdout
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_failed_migration_passes_its_exit_code_and_stays_off(self, sb):
        sb.write_config("cpd")
        result = run(sb, "on", "--migrate", env={"STUB_MODE": "fail"})
        assert result.returncode == 3 and "failed" in result.stderr
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_no_migrate_flag_never_calls_migrate(self, sb):
        path = sb.write_config("cpd")
        result = run(sb, "on", "--no-migrate")
        assert result.returncode == 0 and state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"
        assert migrate_calls(sb) == [] and path.is_file()

    def test_flags_cannot_be_combined(self, sb):
        result = run(sb, "on", "--migrate", "--no-migrate")
        assert result.returncode == 2 and state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_already_on_does_not_prompt(self, sb):
        sb.write_config("cpd")
        setup_on(sb)
        result = run(sb, "on")
        assert result.returncode == 0 and "already on" in result.stdout and migrate_calls(sb) == []

    def test_only_openshift_config_is_not_a_flat_product(self, sb):
        (sb.repo / "configs" / "openshift_config").mkdir()
        (sb.repo / "configs" / "openshift_config" / "x.txt").write_text("user:pw\n")
        assert run(sb, "on").returncode == 0
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"


class TestOff:
    def test_off_leaves_folders_and_says_they_stay_delineated(self, sb):
        setup_on(sb, current="itz-a")
        marker = sb.repo / "configs" / "clusters" / "itz-a" / ".cluster"
        result = run(sb, "off")
        assert result.returncode == 0 and state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "false"
        assert marker.is_file() and 'DELINEATED="true"' in marker.read_text()
        assert not mcm.is_retired("itz-a", repo=sb.repo)
        assert "stay delineated" in result.stderr and "itz-a itz-b" in result.stderr
        assert "--target-cluster NAME" in result.stderr and "MCM_CLUSTER=NAME" in result.stderr
        assert "--restore" not in result.stdout + result.stderr
        assert state(sb)["MCM_CLUSTERS"] == "itz-a itz-b"

    def test_off_names_no_retired_cluster_as_targetable(self, sb):
        setup_on(sb)
        assert run(sb, "remove", "itz-b").returncode == 0
        result = run(sb, "off")
        line = next(l for l in result.stderr.splitlines() if "stay delineated" in l)
        assert line.rstrip(".").endswith(": itz-a")

    def test_off_when_already_off_says_so(self, sb):
        result = run(sb, "off")
        assert result.returncode == 0 and "already off" in result.stdout
        assert "stay delineated" not in result.stderr

    def test_off_warns_about_a_flat_config_of_a_delineated_cluster(self, sb):
        setup_on(sb, names=("itz-a",))
        sb.write_config("cpd", ocp_url=URL_A)
        result = run(sb, "off")
        assert result.returncode == 0
        assert "cp4d_config/cpd_vars.sh" in result.stderr and "belongs to the delineated cluster 'itz-a'" in result.stderr

    def test_off_stops_idle_cluster_containers_only(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        sb.add_container(f"{PLAY}-itz-a")
        sb.add_container(f"{PLAY}-itz-b")
        busy(sb, f"{PLAY}-itz-b")
        sb.add_container(PLAY)
        sb.add_container("mirror-local-registry")
        result = run(sb, "off")
        assert result.returncode == 0
        assert stops(sb) == [f"{PLAY}-itz-a"]
        assert sb.container(f"{PLAY}-itz-a")["running"] is False
        assert sb.container(PLAY)["running"] and sb.container("mirror-local-registry")["running"]
        assert "busy" in result.stderr

    def test_off_with_unreachable_podman_still_succeeds(self, sb):
        setup_on(sb)
        sb.set_podman_reachable(False)
        result = run(sb, "off")
        assert result.returncode == 0 and state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_off_refuses_while_a_run_is_live(self, sb):
        setup_on(sb)
        lease_file(sb, "itz-b")
        result = run(sb, "off")
        assert result.returncode == 1 and "itz-b" in result.stderr
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"

    @pytest.mark.parametrize("args", [("--restore", "itz-a"), ("--restore=itz-a",), ("--restore", "Bad Name"), ("--restore",)])
    def test_restore_is_removed_because_delineation_is_one_way(self, sb, args):
        setup_on(sb)
        before = (sb.repo / "configs" / "multi_cluster_management.sh").read_text()
        result = run(sb, "off", *args, env={"STUB_MODE": "off"})
        assert result.returncode == 2
        assert "removed" in result.stderr and "one-way" in result.stderr
        assert migrate_calls(sb) == []
        assert (sb.repo / "configs" / "multi_cluster_management.sh").read_text() == before
        assert (sb.repo / "configs" / "clusters" / "itz-a" / ".cluster").is_file()


# ---- add, use, targets, apply-to-all -------------------------------------------------------------
class TestAdd:
    def test_add_with_name_and_url(self, sb):
        result = run(sb, "add", "my-cluster", "--url", URL_A)
        assert result.returncode == 0
        marker = sb.repo / "configs" / "clusters" / "my-cluster" / ".cluster"
        assert f'OCP_URL="{URL_A}"' in marker.read_text()
        assert state(sb)["MCM_CLUSTERS"] == "my-cluster"
        assert state(sb)["MCM_CURRENT_CLUSTER"] == ""

    def test_add_of_a_new_cluster_warns_that_it_cannot_be_undone(self, sb):
        result = run(sb, "add", "itz-a", "--url", URL_A)
        assert result.returncode == 0
        assert "cannot be undone for this cluster" in result.stderr and "itz-a" in result.stderr
        assert "--target-cluster itz-a" in result.stdout
        assert mcm.is_delineated("itz-a", repo=sb.repo)

    def test_add_of_a_folder_without_a_marker_warns_too(self, sb):
        (sb.repo / "configs" / "clusters" / "itz-a").mkdir(parents=True)
        assert "cannot be undone" in run(sb, "add", "itz-a").stderr

    def test_adding_a_delineated_cluster_again_does_not_warn(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        result = run(sb, "add", "itz-a")
        assert result.returncode == 0 and "cannot be undone" not in result.stderr
        assert URL_A in result.stdout

    def test_add_reactivates_a_retired_cluster(self, sb):
        setup_on(sb, names=("itz-a", "itz-b"))
        vars_file = sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        assert run(sb, "remove", "itz-a").returncode == 0
        assert mcm.is_retired("itz-a", repo=sb.repo) and state(sb)["MCM_CLUSTERS"] == "itz-b"
        result = run(sb, "add", "itz-a")
        assert result.returncode == 0, result.stderr
        assert "Re-activated retired cluster itz-a" in result.stdout and URL_A in result.stdout
        assert "cannot be undone" not in result.stderr
        assert not mcm.is_retired("itz-a", repo=sb.repo) and mcm.is_delineated("itz-a", repo=sb.repo)
        marker = (sb.repo / "configs" / "clusters" / "itz-a" / ".cluster").read_text()
        assert "RETIRED" not in marker and f'OCP_URL="{URL_A}"' in marker
        assert state(sb)["MCM_CLUSTERS"] == "itz-b itz-a" and vars_file.is_file()

    def test_add_warns_about_a_flat_config_with_its_url(self, sb):
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("kubecost", ocp_url=URL_B)
        result = run(sb, "add", "itz-a", "--url", URL_A)
        assert result.returncode == 0
        assert "cp4d_config/cpd_vars.sh" in result.stderr and "Flat runs refuse it" in result.stderr
        assert "kubecost" not in result.stderr

    def test_add_derives_the_name_from_the_url(self, sb):
        assert run(sb, "add", "--url", URL_A).returncode == 0
        assert state(sb)["MCM_CLUSTERS"] == "itz-a"

    def test_add_derives_the_name_from_ocp_url_in_the_environment(self, sb):
        assert run(sb, "add", env={"OCP_URL": URL_B}).returncode == 0
        assert state(sb)["MCM_CLUSTERS"] == "itz-b"

    def test_add_needs_a_name_or_url(self, sb):
        assert run(sb, "add").returncode == 2

    @pytest.mark.parametrize("bad", ["Bad", "x_config", "clusters", "../evil"])
    def test_invalid_or_reserved_names_are_refused(self, sb, bad):
        result = run(sb, "add", bad)
        assert result.returncode != 0 and "[ERROR]" in result.stderr
        assert state(sb)["MCM_CLUSTERS"] == ""

    def test_add_use_makes_it_current_and_syncs(self, sb):
        setup_on(sb, names=("itz-a",), current="itz-a")
        idle(sb)
        sb.add_container(f"{PLAY}-itz-a")
        assert run(sb, "add", "itz-b", "--use").returncode == 0
        assert state(sb)["MCM_CURRENT_CLUSTER"] == "itz-b"
        assert stops(sb) == [f"{PLAY}-itz-a"]

    def test_add_warns_when_two_names_share_a_url(self, sb):
        assert run(sb, "add", "one", "--url", URL_A).returncode == 0
        assert "same URL" in run(sb, "add", "two", "--url", URL_A).stderr

    def test_copy_from_copies_configs_and_fixes_url_and_paths(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        vars_file = sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        root_a = sb.repo / "configs" / "clusters" / "itz-a"
        (root_a / "openshift_config").mkdir()
        (root_a / "openshift_config" / "htpasswd_credentials.txt").write_text("u:p\n")
        props = root_a / "confluent_platform_config" / "client.properties"
        props.parent.mkdir()
        props.write_text(f"ssl.truststore.location={root_a}/confluent_platform_config/truststore.jks\n")
        vars_file.chmod(0o600)

        result = run(sb, "add", "itz-b", "--url", URL_B, "--copy-from", "itz-a")
        assert result.returncode == 0
        root_b = sb.repo / "configs" / "clusters" / "itz-b"
        copied = root_b / "cp4d_config" / "cpd_vars.sh"
        assert URL_B in copied.read_text() and URL_A not in copied.read_text()
        assert copied.stat().st_mode & 0o777 == 0o600
        assert not (root_b / "openshift_config").exists()
        assert str(root_b) in (root_b / "confluent_platform_config" / "client.properties").read_text()
        assert URL_A in vars_file.read_text()
        assert "tokens" in result.stderr

    def test_copy_from_without_url_warns_it_still_points_at_the_source(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        result = run(sb, "add", "itz-b", "--copy-from", "itz-a")
        assert result.returncode == 0 and URL_A in result.stderr
        assert URL_A in (sb.repo / "configs" / "clusters" / "itz-b" / "cp4d_config" / "cpd_vars.sh").read_text()

    def test_copy_from_refuses_to_overwrite(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        sb.write_config("cpd", ocp_url=URL_B, cluster="itz-b")
        result = run(sb, "add", "itz-b", "--copy-from", "itz-a")
        assert result.returncode == 1 and "already exists" in result.stderr
        assert URL_B in (sb.repo / "configs" / "clusters" / "itz-b" / "cp4d_config" / "cpd_vars.sh").read_text()

    def test_copy_from_a_missing_cluster_is_refused(self, sb):
        result = run(sb, "add", "itz-b", "--copy-from", "nope")
        assert result.returncode == 1 and state(sb)["MCM_CLUSTERS"] == ""

    @pytest.mark.parametrize("quote", ['"', "'", ""], ids=["double", "single", "bare"])
    @pytest.mark.parametrize(
        "tail", ["  # c", " \t# c", "\t # c", " ", "   ", "\t", " # c", "\r"],
        ids=["two-spaces-comment", "space-tab-comment", "tab-space-comment", "one-space", "spaces", "tab", "one-space-comment", "cr"],
    )
    def test_copy_from_reads_the_url_whatever_follows_it(self, sb, quote, tail):
        """Text after the value stays out of it, so the replace leaves the quoting intact."""
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        login = f'export OC_LOGIN="oc login {URL_A} --token=t"\n'
        sb.write_config("cpd", cluster="itz-a", text=f"export OCP_URL={quote}{URL_A}{quote}{tail}\n{login}")

        assert run(sb, "add", "itz-b", "--url", URL_B, "--copy-from", "itz-a").returncode == 0
        copied = sb.repo / "configs" / "clusters" / "itz-b" / "cp4d_config" / "cpd_vars.sh"
        assert copied.read_bytes().decode().split("\n")[:2] == [
            f"export OCP_URL={quote}{URL_B}{quote}{tail}", f'export OC_LOGIN="oc login {URL_B} --token=t"',
        ]
        check = subprocess.run(["zsh", "-n", str(copied)], capture_output=True, text=True, check=False)
        assert check.returncode == 0, check.stderr

    @pytest.mark.parametrize(
        "line", [f'OCP_URL="{URL_A}"# c', f"export  OCP_URL='{URL_A}'  ; true", f'\t export\tOCP_URL="{URL_A}"\t\t#c  '],
        ids=["comment-after-the-quote", "command-after-the-quote", "tabs-around"],
    )
    def test_copy_from_without_url_names_the_clean_value(self, sb, line):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        sb.write_config("cpd", cluster="itz-a", text=f"{line}\n")
        result = run(sb, "add", "itz-b", "--copy-from", "itz-a")
        assert result.returncode == 0 and f"still point at {URL_A}." in result.stderr

    @pytest.mark.parametrize(
        "line", ['export OCP_URL=""  # c', "OCP_URL=", "OCP_URL=  # c", "OCP_URL=# c", 'OCP_URL="${X}"  # c', f'OCP_URL="{URL_A}'],
        ids=["empty-quotes", "bare-empty", "bare-empty-comment", "comment-at-once", "reference", "unterminated"],
    )
    def test_copy_from_says_when_a_line_holds_no_usable_url(self, sb, line):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        text = f"{line}\nexport KEEP=#1\n"
        sb.write_config("cpd", cluster="itz-a", text=text)
        result = run(sb, "add", "itz-b", "--url", URL_B, "--copy-from", "itz-a")
        assert result.returncode == 0 and "Could not read an OCP_URL" in result.stderr
        assert (sb.repo / "configs" / "clusters" / "itz-b" / "cp4d_config" / "cpd_vars.sh").read_text() == text

    def test_copy_from_takes_the_first_literal_url_past_an_empty_one(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        sb.write_config("cpd", cluster="itz-a", text=f'export OCP_URL=""  # c\nexport OCP_URL="{URL_A}"  # d\n')
        assert run(sb, "add", "itz-b", "--url", URL_B, "--copy-from", "itz-a").returncode == 0
        copied = sb.repo / "configs" / "clusters" / "itz-b" / "cp4d_config" / "cpd_vars.sh"
        assert copied.read_text() == f'export OCP_URL=""  # c\nexport OCP_URL="{URL_B}"  # d\n'


class TestSelection:
    def test_use_sets_current_and_stops_what_left(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        sb.add_container(f"{PLAY}-itz-a")
        sb.add_container(f"{PLAY}-itz-b", running=False)
        assert run(sb, "use", "itz-b").returncode == 0
        assert state(sb)["MCM_CURRENT_CLUSTER"] == "itz-b"
        assert stops(sb) == [f"{PLAY}-itz-a"]
        assert starts(sb) == []

    def test_use_unknown_cluster_is_refused(self, sb):
        setup_on(sb, current="itz-a")
        result = run(sb, "use", "nope")
        assert result.returncode == 1 and state(sb)["MCM_CURRENT_CLUSTER"] == "itz-a"

    def test_use_in_a_pinned_shell_says_so(self, sb):
        setup_on(sb, current="itz-a")
        result = run(sb, "use", "itz-b", env={"MCM_CLUSTER": "itz-a"})
        assert result.returncode == 0 and "pinned to itz-a" in result.stdout

    def test_targets_converts_commas(self, sb):
        setup_on(sb, names=("itz-a", "itz-b", "itz-c"), current="itz-a")
        assert run(sb, "targets", "itz-a,itz-c").returncode == 0
        assert state(sb)["MCM_TARGET_CLUSTERS"] == "itz-a itz-c"

    def test_targets_accepts_repeats_and_spaces(self, sb):
        setup_on(sb, current="itz-a")
        assert run(sb, "targets", "itz-b,itz-b", "itz-a").returncode == 0
        assert state(sb)["MCM_TARGET_CLUSTERS"] == "itz-b itz-a"

    def test_targets_stops_what_left_the_set(self, sb):
        setup_on(sb, names=("itz-a", "itz-b", "itz-c"), current="itz-a")
        idle(sb)
        sb.add_container(f"{PLAY}-itz-c")
        sb.add_container(f"{PLAY}-itz-a")
        assert run(sb, "targets", "itz-a,itz-b").returncode == 0
        assert stops(sb) == [f"{PLAY}-itz-c"]

    def test_targets_clear(self, sb):
        setup_on(sb, current="itz-a")
        assert run(sb, "targets", "itz-b").returncode == 0
        assert run(sb, "targets", "--clear").returncode == 0
        assert state(sb)["MCM_TARGET_CLUSTERS"] == ""

    def test_targets_refuses_an_unregistered_cluster(self, sb):
        setup_on(sb, current="itz-a")
        result = run(sb, "targets", "itz-a,nope")
        assert result.returncode == 1 and state(sb)["MCM_TARGET_CLUSTERS"] == ""

    def test_targets_needs_a_list(self, sb):
        setup_on(sb)
        assert run(sb, "targets").returncode == 2
        assert run(sb, "targets", ",").returncode == 2

    def test_apply_to_all(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        sb.add_container(f"{PLAY}-itz-b")
        assert run(sb, "apply-to-all", "true").returncode == 0
        assert state(sb)["APPLY_TO_ALL"] == "true" and stops(sb) == []
        assert run(sb, "apply-to-all", "false").returncode == 0
        assert state(sb)["APPLY_TO_ALL"] == "false"
        assert stops(sb) == [f"{PLAY}-itz-b"]

    @pytest.mark.parametrize("value", ["yes", "TRUE", ""])
    def test_apply_to_all_takes_only_true_or_false(self, sb, value):
        setup_on(sb)
        assert run(sb, "apply-to-all", value).returncode == 2
        assert state(sb)["APPLY_TO_ALL"] == "false"

    def test_apply_to_all_says_when_a_target_list_wins(self, sb):
        setup_on(sb, current="itz-a")
        assert run(sb, "targets", "itz-a").returncode == 0
        assert "wins" in run(sb, "apply-to-all", "true").stdout


# ---- rename and remove ---------------------------------------------------------------------------
class TestRename:
    def test_rename_moves_everything_and_keeps_the_order(self, sb):
        setup_on(sb, names=("itz-a", "itz-b", "itz-c"), current="itz-b")
        assert run(sb, "targets", "itz-a,itz-b").returncode == 0
        root_b = sb.repo / "configs" / "clusters" / "itz-b"
        sb.write_config("cpd", ocp_url=URL_B, cluster="itz-b")
        props = root_b / "confluent_platform_config" / "client.properties"
        props.parent.mkdir()
        props.write_text(f"ssl.truststore.location={root_b}/confluent_platform_config/truststore.jks\n")
        cli_b = sb.home / "cpd-cli" / "clusters" / "itz-b"
        (cli_b / "work").mkdir(parents=True)
        (cli_b / "work" / "marker").write_text("x")
        (cli_b / ".custom_containers").write_text("custom-itz-b\n")
        sb.add_container(f"{PLAY}-itz-b", running=False)
        sb.add_container("custom-itz-b", running=False)
        sb.add_container(f"{SWHCC}-itz-b", running=False)

        result = run(sb, "rename", "itz-b", "prod-1")
        assert result.returncode == 0, result.stderr
        s = state(sb)
        assert s["MCM_CLUSTERS"] == "itz-a prod-1 itz-c"
        assert s["MCM_CURRENT_CLUSTER"] == "prod-1"
        assert s["MCM_TARGET_CLUSTERS"] == "itz-a prod-1"
        new_root = sb.repo / "configs" / "clusters" / "prod-1"
        assert not root_b.exists() and (new_root / "cp4d_config" / "cpd_vars.sh").is_file()
        assert 'NAME="prod-1"' in (new_root / ".cluster").read_text()
        assert str(new_root) in (new_root / "confluent_platform_config" / "client.properties").read_text()
        new_cli = sb.home / "cpd-cli" / "clusters" / "prod-1"
        assert (new_cli / "work" / "marker").is_file() and not cli_b.exists()
        assert not (new_cli / ".custom_containers").exists()
        assert sorted(removed(sb)) == sorted([f"{PLAY}-itz-b", "custom-itz-b", f"{SWHCC}-itz-b"])
        assert sb.container(f"{PLAY}-itz-b") is None

    def _rename_prod(self, sb, body):
        """Renames prod to east with BODY (bytes, or a function of the old root) in a properties file."""
        setup_on(sb, names=("prod",))
        old = sb.repo / "configs" / "clusters" / "prod"
        props = old / "confluent_platform_config" / "client.properties"
        props.parent.mkdir()
        props.write_bytes(body(str(old).encode()))
        result = run(sb, "rename", "prod", "east")
        assert result.returncode == 0, result.stderr
        new = sb.repo / "configs" / "clusters" / "east"
        return str(old).encode(), str(new).encode(), new / "confluent_platform_config" / "client.properties"

    @pytest.mark.parametrize(
        "after", list(",;)]}=|&<>\\@+~%!?*$#^`(") + ["/z", '"', "'", " ", "\t", "\n", ":"],
        ids=lambda text: "x%s" % text.encode().hex(),
    )
    def test_rename_rewrites_a_complete_path_before_any_delimiter(self, sb, after):
        tail = after.encode()
        old, new, props = self._rename_prod(sb, lambda root: b"e=" + root + tail + b"\n")
        assert props.read_bytes() == b"e=" + new + tail + b"\n"
        assert old not in props.read_bytes()

    def test_rename_rewrites_a_path_at_the_end_of_the_file(self, sb):
        old, new, props = self._rename_prod(sb, lambda root: b"e=" + root)
        assert props.read_bytes() == b"e=" + new

    @pytest.mark.parametrize("sibling", ["-dr", "-dr/z", "_old", ".bak", "2", "X", "-"])
    def test_rename_leaves_a_longer_folder_name_alone(self, sb, sibling):
        tail = sibling.encode()
        old, new, props = self._rename_prod(sb, lambda root: b"e=" + root + tail + b",\n")
        assert props.read_bytes() == b"e=" + old + tail + b",\n"

    def test_rename_decides_each_occurrence_on_its_own(self, sb):
        """The finding's line: a comma ends the first path, the sibling beside it is kept."""
        old, new, props = self._rename_prod(
            sb, lambda root: b"e=" + root + b"," + root + b"-dr/z," + root + b"," + root + b"/a:" + root,
        )
        assert props.read_bytes() == b"e=" + new + b"," + old + b"-dr/z," + new + b"," + new + b"/a:" + new

    def test_rename_keeps_other_bytes_exact(self, sb):
        """Non-ASCII text and bytes that are not valid UTF-8 survive the rewrite."""
        before, after = "caf\u00e9 ".encode(), b" \xff\xfe tail\n\n"
        old, new, props = self._rename_prod(sb, lambda root: before + root + b"," + after)
        assert props.read_bytes() == before + new + b"," + after

    def test_rename_refuses_a_taken_name(self, sb):
        setup_on(sb)
        result = run(sb, "rename", "itz-a", "itz-b")
        assert result.returncode == 1 and (sb.repo / "configs" / "clusters" / "itz-a").is_dir()

    def test_rename_refuses_a_folder_that_exists(self, sb):
        setup_on(sb)
        (sb.home / "cpd-cli" / "clusters" / "taken").mkdir(parents=True)
        assert run(sb, "rename", "itz-a", "taken").returncode == 1

    def test_rename_refuses_unregistered_and_same_name(self, sb):
        setup_on(sb)
        assert run(sb, "rename", "nope", "x").returncode == 1
        assert run(sb, "rename", "itz-a", "itz-a").returncode == 1

    def test_rename_refuses_while_running(self, sb):
        setup_on(sb)
        lease_file(sb, "itz-a")
        result = run(sb, "rename", "itz-a", "x")
        assert result.returncode == 1 and "itz-a" in result.stderr
        assert state(sb)["MCM_CLUSTERS"] == "itz-a itz-b" and removed(sb) == []

    def test_rename_refuses_a_busy_container(self, sb):
        setup_on(sb)
        sb.add_container(f"{PLAY}-itz-a")
        busy(sb, f"{PLAY}-itz-a")
        assert run(sb, "rename", "itz-a", "x").returncode == 1
        assert sb.container(f"{PLAY}-itz-a") is not None
        assert (sb.repo / "configs" / "clusters" / "itz-a").is_dir()

    def test_rename_needs_podman_reachable(self, sb):
        setup_on(sb)
        sb.set_podman_reachable(False)
        result = run(sb, "rename", "itz-a", "x")
        assert result.returncode == 1 and "podman" in result.stderr
        assert (sb.repo / "configs" / "clusters" / "itz-a").is_dir()


class TestRemove:
    def test_remove_keeps_files(self, sb):
        setup_on(sb, current="itz-a")
        assert run(sb, "targets", "itz-a,itz-b").returncode == 0
        sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        cli = sb.home / "cpd-cli" / "clusters" / "itz-a" / "work"
        cli.mkdir(parents=True)
        (cli / "marker").write_text("x")
        sb.add_container(f"{PLAY}-itz-a", running=False)
        result = run(sb, "remove", "itz-a")
        assert result.returncode == 0, result.stderr
        s = state(sb)
        assert s["MCM_CLUSTERS"] == "itz-b" and s["MCM_TARGET_CLUSTERS"] == "itz-b" and s["MCM_CURRENT_CLUSTER"] == ""
        root = sb.repo / "configs" / "clusters" / "itz-a"
        assert (root / "cp4d_config" / "cpd_vars.sh").is_file()
        marker = (root / ".cluster").read_text()
        assert 'RETIRED="true"' in marker and 'DELINEATED="true"' in marker and f'OCP_URL="{URL_A}"' in marker
        assert mcm.is_retired("itz-a", repo=sb.repo) and mcm.is_delineated("itz-a", repo=sb.repo)
        assert (cli / "marker").is_file() and sb.container(f"{PLAY}-itz-a") is None
        assert "Retired cluster itz-a" in result.stdout and "stays delineated" in result.stdout
        assert "add itz-a --url" in result.stdout and "--purge" in result.stdout

    def test_remove_of_a_retired_cluster_says_so(self, sb):
        setup_on(sb)
        assert run(sb, "remove", "itz-a").returncode == 0
        result = run(sb, "remove", "itz-a")
        assert result.returncode == 0 and "already retired" in result.stdout
        assert mcm.is_retired("itz-a", repo=sb.repo)

    def test_remove_retires_a_delineated_cluster_missing_from_the_state_file(self, sb):
        setup_on(sb, names=("itz-a",))
        sb.write_cluster_marker("itz-hand", URL_B)
        result = run(sb, "remove", "itz-hand")
        assert result.returncode == 0, result.stderr
        assert mcm.is_retired("itz-hand", repo=sb.repo) and state(sb)["MCM_CLUSTERS"] == "itz-a"

    def test_remove_of_a_hand_registered_name_without_a_folder(self, sb):
        setup_on(sb, names=("itz-a",))
        path = sb.repo / "configs" / "multi_cluster_management.sh"
        path.write_text(path.read_text().replace('MCM_CLUSTERS="itz-a"', 'MCM_CLUSTERS="itz-a ghost"'))
        result = run(sb, "remove", "ghost")
        assert result.returncode == 0, result.stderr
        assert state(sb)["MCM_CLUSTERS"] == "itz-a" and not mcm.is_delineated("ghost", repo=sb.repo)

    def test_remove_does_not_come_back_when_the_state_file_is_rebuilt(self, sb):
        setup_on(sb)
        assert run(sb, "remove", "itz-a").returncode == 0
        (sb.repo / "configs" / "multi_cluster_management.sh").unlink()
        assert run(sb, "status").returncode == 0
        assert state(sb)["MCM_CLUSTERS"] == "itz-b"
        assert mcm.delineated_clusters(repo=sb.repo) == ["itz-a", "itz-b"]

    def test_remove_unknown_is_refused(self, sb):
        setup_on(sb)
        result = run(sb, "remove", "nope")
        assert result.returncode == 1 and "not registered" in result.stderr

    def test_remove_refuses_live_or_busy(self, sb):
        setup_on(sb)
        sb.add_container(f"{PLAY}-itz-a")
        busy(sb, f"{PLAY}-itz-a")
        assert run(sb, "remove", "itz-a").returncode == 1
        assert state(sb)["MCM_CLUSTERS"] == "itz-a itz-b"
        lease_file(sb, "itz-b")
        assert run(sb, "remove", "itz-b").returncode == 1

    def _purge_setup(self, sb):
        setup_on(sb, current="itz-a")
        sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        cli = sb.home / "cpd-cli" / "clusters" / "itz-a"
        (cli / "work").mkdir(parents=True)
        (cli / "work" / "case.tgz").write_text("x" * 100)
        kube = sb.repo / "configs" / "clusters" / "itz-a" / ".home" / ".kube" / "config"
        kube.parent.mkdir(parents=True)
        kube.write_text("kube\n")
        return sb.repo / "configs" / "clusters" / "itz-a", cli

    def test_purge_lists_what_it_deletes_and_needs_the_exact_name(self, sb):
        root, cli = self._purge_setup(sb)
        result = run(sb, "remove", "itz-a", "--purge", input="wrong\n")
        assert result.returncode == 1 and "did not match" in result.stderr
        assert "cp4d_config" in result.stdout and "work" in result.stdout and ".home" in result.stdout
        assert "oc session" in result.stderr and "credentials" in result.stderr
        assert root.is_dir() and cli.is_dir() and state(sb)["MCM_CLUSTERS"] == "itz-a itz-b"
        assert (root / ".cluster").is_file()

    def test_purge_with_no_stdin_changes_nothing(self, sb):
        root, cli = self._purge_setup(sb)
        result = run(sb, "remove", "itz-a", "--purge")
        assert result.returncode == 1 and root.is_dir() and cli.is_dir()
        assert state(sb)["MCM_CLUSTERS"] == "itz-a itz-b"

    def test_purge_with_the_exact_name_deletes_both_folders(self, sb):
        root, cli = self._purge_setup(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        other = sb.repo / "configs" / "clusters" / "itz-b"
        result = run(sb, "remove", "itz-a", "--purge", input="itz-a\n")
        assert result.returncode == 0, result.stderr
        assert not root.exists() and not cli.exists() and other.is_dir()
        assert sb.container(f"{PLAY}-itz-a") is None
        assert state(sb)["MCM_CLUSTERS"] == "itz-b" and state(sb)["MCM_CURRENT_CLUSTER"] == ""
        assert not mcm.is_delineated("itz-a", repo=sb.repo) and mcm.delineated_clusters(repo=sb.repo) == ["itz-b"]
        assert "no longer delineated" in result.stdout

    def test_purge_of_a_retired_cluster_leaves_nothing(self, sb):
        root, cli = self._purge_setup(sb)
        assert run(sb, "remove", "itz-a").returncode == 0
        result = run(sb, "remove", "itz-a", "--purge", input="itz-a\n")
        assert result.returncode == 0, result.stderr
        assert not root.exists() and not cli.exists()
        assert mcm.delineated_clusters(repo=sb.repo) == ["itz-b"]

    def test_purge_refuses_a_symlinked_folder(self, sb):
        setup_on(sb)
        target = sb.root / "elsewhere"
        target.mkdir()
        (target / "precious").write_text("x")
        cli = sb.home / "cpd-cli" / "clusters" / "itz-a"
        cli.parent.mkdir(parents=True, exist_ok=True)
        cli.symlink_to(target)
        result = run(sb, "remove", "itz-a", "--purge", input="itz-a\n")
        assert result.returncode == 1 and "symbolic link" in result.stderr
        assert (target / "precious").is_file() and state(sb)["MCM_CLUSTERS"] == "itz-a itz-b"

    def test_purge_works_on_a_folder_that_is_not_registered(self, sb):
        setup_on(sb)
        orphan = sb.repo / "configs" / "clusters" / "itz-old"
        orphan.mkdir()
        (orphan / "file").write_text("x")
        result = run(sb, "remove", "itz-old", "--purge", input="itz-old\n")
        assert result.returncode == 0 and not orphan.exists()
        assert state(sb)["MCM_CLUSTERS"] == "itz-a itz-b"


# ---- containers ----------------------------------------------------------------------------------
class TestContainersStatus:
    def _table(self, sb):
        result = run(sb, "containers", "status")
        assert result.returncode == 0, result.stderr
        return result

    def test_shows_state_targeted_idle_and_time_left(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3000))
        sb.add_container(f"{PLAY}-itz-a", started_at=started)
        sb.add_event(f"{PLAY}-itz-a", "exec", when=time.time() - 600)
        sb.add_container(f"{PLAY}-itz-b", running=False)
        result = self._table(sb)
        line, words = status_row(result, f"{PLAY}-itz-a")
        assert "running" in words and "yes" in words
        # The exec was 600 s ago: one second of scan time already reads 1h 49m left.
        assert re.search(r"\b(9|10)m\b", line) and re.search(r"1h (49|50|51)m", line)
        _, words_b = status_row(result, f"{PLAY}-itz-b")
        assert "exited" in words_b and "no" in words_b and "-" in words_b

    def test_times_come_from_last_activity_marker(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        sb.add_container(f"{PLAY}-itz-a", started_at=LONG_AGO)
        activity = sb.home / "cpd-cli" / "clusters" / "itz-a" / ".last_activity"
        activity.parent.mkdir(parents=True, exist_ok=True)
        activity.write_text("")
        moment = time.time() - 1800
        os.utime(activity, (moment, moment))
        line, _ = status_row(self._table(sb), f"{PLAY}-itz-a")
        assert re.search(r"\b(29|30)m\b", line) and re.search(r"1h (29|30|31)m", line)

    def test_status_scans_do_not_reset_the_idle_clock(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 2400))
        sb.add_container(f"{PLAY}-itz-a", started_at=started)
        for _ in range(3):
            line, _unused = status_row(self._table(sb), f"{PLAY}-itz-a")
            assert re.search(r"\b(39|40|41)m\b", line), line

    def test_past_the_timeout_reads_due(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        sb.add_container(f"{PLAY}-itz-a", started_at=LONG_AGO)
        assert " due " in status_row(self._table(sb), f"{PLAY}-itz-a")[0]

    def test_timeout_zero_reads_never(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        path = sb.repo / "configs" / "multi_cluster_management.sh"
        path.write_text(path.read_text().replace('TIMEOUT_MINUTES="120"', 'TIMEOUT_MINUTES="0"'))
        sb.add_container(f"{PLAY}-itz-a", started_at=LONG_AGO)
        result = self._table(sb)
        assert " never " in status_row(result, f"{PLAY}-itz-a")[0]
        assert "disabled" in result.stdout

    def test_busy_container_shows_why(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        sb.add_container(f"{PLAY}-itz-a", started_at=LONG_AGO)
        busy(sb, f"{PLAY}-itz-a")
        line, words = status_row(self._table(sb), f"{PLAY}-itz-a")
        assert "busy" in words and "oc apply" in line

    def test_missing_main_container_is_listed_as_not_created(self, sb):
        setup_on(sb, names=("itz-a",), current="itz-a")
        line, _ = status_row(self._table(sb), f"{PLAY}-itz-a")
        assert "not created" in line

    def test_flat_container_is_shown_while_on(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        sb.add_container(PLAY, started_at=LONG_AGO)
        _, words = status_row(self._table(sb), PLAY)
        assert words[0] == "(flat)" and "no" in words

    def test_unreachable_podman_still_lists(self, sb):
        setup_on(sb, names=("itz-a",), current="itz-a")
        sb.set_podman_reachable(False)
        result = self._table(sb)
        assert "not reachable" in result.stderr and "unknown" in status_row(result, f"{PLAY}-itz-a")[0]

    def test_mode_off_still_times_a_delineated_clusters_container(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        idle(sb)
        sb.add_container(f"{PLAY}-itz-a", started_at=LONG_AGO)
        sb.add_container(PLAY, started_at=LONG_AGO)
        result = self._table(sb)
        line, _ = status_row(result, f"{PLAY}-itz-a")
        assert " due " in line and "mode off" not in line
        flat_line, _ = status_row(result, PLAY)
        assert "mode off: flat default" in flat_line and " due " not in flat_line

    def test_mode_off_shows_states_without_scanning(self, sb):
        sb.add_container(PLAY, started_at=LONG_AGO)
        result = self._table(sb)
        assert "running" in status_row(result, PLAY)[1]
        assert "off" in result.stdout
        assert podman_verbs(sb, "exec") == []


class TestContainersStartStop:
    def test_start_refuses_a_cluster_that_is_not_targeted(self, sb):
        setup_on(sb, current="itz-a")
        sb.add_container(f"{PLAY}-itz-b", running=False)
        result = run(sb, "containers", "start", "itz-b")
        assert result.returncode == 1 and "not targeted" in result.stderr
        assert starts(sb) == [] and sb.container(f"{PLAY}-itz-b")["running"] is False

    def test_start_a_targeted_cluster_and_launches_the_watcher(self, sb):
        setup_on(sb, current="itz-a")
        sb.add_container(f"{PLAY}-itz-a", running=False)
        result = run(sb, "containers", "start", "itz-a")
        assert result.returncode == 0, result.stderr
        assert starts(sb) == [f"{PLAY}-itz-a"] and sb.container(f"{PLAY}-itz-a")["running"]
        deadline = time.time() + 5
        while time.time() < deadline and not (sb.home / "watcher_started").exists():
            time.sleep(0.05)
        assert (sb.home / "watcher_started").exists()

    def test_start_counts_a_pinned_shell_as_targeted(self, sb):
        setup_on(sb, current="itz-a")
        sb.add_container(f"{PLAY}-itz-b", running=False)
        assert run(sb, "containers", "start", "itz-b", env={"MCM_CLUSTER": "itz-b"}).returncode == 0
        assert starts(sb) == [f"{PLAY}-itz-b"]

    def test_start_a_target_list_member(self, sb):
        setup_on(sb, current="itz-a")
        assert run(sb, "targets", "itz-b").returncode == 0
        sb.add_container(f"{PLAY}-itz-b", running=False)
        assert run(sb, "containers", "start", "itz-b").returncode == 0

    def test_start_does_not_create_a_missing_container(self, sb):
        setup_on(sb, current="itz-a")
        result = run(sb, "containers", "start", "itz-a")
        assert result.returncode == 0 and "cpd-cli manage" in result.stdout
        assert podman_verbs(sb, "run") == [] and podman_verbs(sb, "start") == []

    def test_start_also_starts_the_clusters_other_containers(self, sb):
        setup_on(sb, current="itz-a")
        sb.add_container(f"{PLAY}-itz-a", running=False)
        sb.add_container(f"{SWHCC}-itz-a", running=False)
        assert run(sb, "containers", "start", "itz-a").returncode == 0
        assert sorted(starts(sb)) == sorted([f"{PLAY}-itz-a", f"{SWHCC}-itz-a"])

    def test_start_with_the_mode_off_needs_the_cluster_named(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        sb.add_container(f"{PLAY}-itz-a", running=False)
        result = run(sb, "containers", "start", "itz-a")
        assert result.returncode == 1 and "MCM_CLUSTER=itz-a" in result.stderr and starts(sb) == []
        result = run(sb, "containers", "start", "itz-a", env={"MCM_CLUSTER": "itz-a"})
        assert result.returncode == 0, result.stderr
        assert starts(sb) == [f"{PLAY}-itz-a"]

    def test_start_refuses_a_retired_cluster(self, sb):
        assert run(sb, "add", "itz-a", "--url", URL_A).returncode == 0
        assert run(sb, "remove", "itz-a").returncode == 0
        assert run(sb, "containers", "start", "itz-a", env={"MCM_CLUSTER": "itz-a"}).returncode == 1

    def test_start_refuses_when_mode_is_off_or_unregistered(self, sb):
        assert run(sb, "containers", "start", "itz-a").returncode == 1
        setup_on(sb, current="itz-a")
        assert run(sb, "containers", "start", "nope").returncode == 1

    def test_start_recovers_a_stopped_vm(self, sb):
        setup_on(sb, current="itz-a")
        sb.add_container(f"{PLAY}-itz-a", running=False)
        sb.set_machine("stopped")
        assert run(sb, "containers", "start", "itz-a").returncode == 0
        assert ["machine", "start"] in sb.calls("podman")
        assert sb.container(f"{PLAY}-itz-a")["running"]

    def test_start_fails_cleanly_when_podman_is_down(self, sb):
        setup_on(sb, current="itz-a")
        sb.set_podman_reachable(False)
        result = run(sb, "containers", "start", "itz-a")
        assert result.returncode == 1 and "not reachable" in result.stderr

    def test_stop_stops_idle_containers_of_the_cluster(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        sb.add_container(f"{PLAY}-itz-a")
        sb.add_container(f"{SWHCC}-itz-a")
        sb.add_container(f"{PLAY}-itz-b")
        result = run(sb, "containers", "stop", "itz-a")
        assert result.returncode == 0, result.stderr
        assert sorted(stops(sb)) == sorted([f"{PLAY}-itz-a", f"{SWHCC}-itz-a"])
        assert ["stop", "-t", "3", f"{PLAY}-itz-a"] in sb.calls("podman")
        assert sb.container(f"{PLAY}-itz-b")["running"]
        assert "1/2" in result.stdout and "2/2" in result.stdout

    def test_stop_leaves_a_busy_container_and_reports_it(self, sb):
        setup_on(sb, current="itz-a")
        sb.add_container(f"{PLAY}-itz-a")
        busy(sb, f"{PLAY}-itz-a")
        result = run(sb, "containers", "stop", "itz-a")
        assert result.returncode == 1 and "busy" in result.stderr
        assert stops(sb) == []

    def test_stop_of_nothing_running(self, sb):
        setup_on(sb, current="itz-a")
        result = run(sb, "containers", "stop", "itz-a")
        assert result.returncode == 0 and "no running container" in result.stdout

    def test_stop_refuses_unregistered_and_unreachable(self, sb):
        setup_on(sb, current="itz-a")
        assert run(sb, "containers", "stop", "nope").returncode == 1
        sb.set_podman_reachable(False)
        assert run(sb, "containers", "stop", "itz-a").returncode == 1

    def test_stop_all_covers_managed_names_only(self, sb):
        setup_on(sb, current="itz-a")
        idle(sb)
        sb.add_container(PLAY)
        sb.add_container(f"{PLAY}-itz-a")
        sb.add_container(f"{SWHCC}-itz-b")
        sb.add_container("mirror-local-registry")
        sb.add_container(f"{PLAY}-unregistered")
        result = run(sb, "containers", "stop-all")
        assert result.returncode == 0, result.stderr
        assert sorted(stops(sb)) == sorted([PLAY, f"{PLAY}-itz-a", f"{SWHCC}-itz-b"])
        assert sb.container("mirror-local-registry")["running"] and sb.container(f"{PLAY}-unregistered")["running"]

    def test_stop_all_with_nothing_running(self, sb):
        setup_on(sb)
        assert "No managed container" in run(sb, "containers", "stop-all").stdout

    def test_containers_needs_a_known_subcommand(self, sb):
        assert run(sb, "containers").returncode == 2
        assert run(sb, "containers", "explode").returncode == 2
        assert run(sb, "containers", "start").returncode == 2


# ---- with the real migration script ---------------------------------------------------------------
class TestRealMigration:
    @pytest.fixture
    def real(self, sb):
        import shutil
        repo_copy = Path(__file__).resolve().parents[1] / MIGRATE
        shutil.copy2(repo_copy, sb.repo / MIGRATE)
        ps = sb.bin / "ps"
        ps.write_text("#!/bin/zsh\nexit 0\n")
        ps.chmod(0o755)
        return sb

    def test_on_migrate_then_off_keeps_the_cluster_delineated(self, real):
        sb = real
        sb.write_config("cpd", ocp_url=URL_A)
        result = run(sb, "on", "--migrate")
        assert result.returncode == 0, result.stdout + result.stderr
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"
        moved = sb.repo / "configs" / "clusters" / "itz-a" / "cp4d_config" / "cpd_vars.sh"
        assert moved.is_file() and not (sb.repo / "configs" / "cp4d_config").exists()
        assert mcm.is_delineated("itz-a", repo=sb.repo)

        result = run(sb, "off", "--restore", "itz-a", input="y\n")
        assert result.returncode == 2 and "one-way" in result.stderr
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"

        result = run(sb, "off")
        assert result.returncode == 0, result.stdout + result.stderr
        assert state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "false"
        assert moved.is_file() and not (sb.repo / "configs" / "cp4d_config").exists()
        assert mcm.is_delineated("itz-a", repo=sb.repo) and not mcm.is_retired("itz-a", repo=sb.repo)
        assert "itz-a" in result.stderr and "stay delineated" in result.stderr


# ---- README against the scripts --------------------------------------------------------------------------------
class TestReadmeMatchesTheScripts:
    """The README section was written before these scripts existed; keep its flags honest."""

    SECTION = (Path(__file__).resolve().parents[1] / "README.md").read_text().split("## Managing several clusters")[1].split("\n## ")[0]
    MIGRATE = "src/utilities/multi_cluster_management_utils/migrate_to_multi_cluster.sh"

    def test_the_too_broad_claim_is_gone(self):
        assert "Any script takes" not in self.SECTION

    def test_multi_cluster_flags_and_subcommands_exist(self, sb):
        text = run(sb, "--help").stdout
        for word in ("--migrate", "--no-migrate", "--url", "--copy-from", "--use", "--clear",
                     "--purge", "apply-to-all", "containers", "stop-all", "rename", "remove"):
            assert word in text, word
            assert word in self.SECTION, word
        assert "--restore" not in text  # removed: delineation is one-way per cluster

    def test_migrate_flags_exist(self):
        # Read, not run: the sandbox here holds a stub of the migration script.
        usage = (Path(__file__).resolve().parents[1] / self.MIGRATE).read_text().split("EOF")[1]
        for flag in ("--dry-run", "--yes", "--name", "--map", "--mirror-state-to", "--rollback"):
            assert flag in usage, flag
            assert flag in self.SECTION, flag

    def test_secrets_utilities_are_named_as_not_taking_the_flags(self):
        assert "Secrets Manager utilities" in self.SECTION and "MCM_CLUSTER=NAME" in self.SECTION
