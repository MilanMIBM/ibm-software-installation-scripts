"""Multi-cluster container power (plan: .claude/plans/multi-cluster-management/, sections 5.7 and 5.7.1).

T7 covers mcm_sync_containers: only the targeted-only rule decides what stops or starts, and only names the
feature owns are touched. T12 runs the idle watcher in its single-pass mode with set file times.

Everything runs in tests/mcm_harness.py sandboxes with fake podman, oc and cpd-cli.
"""

import os
import subprocess
import time

import pytest
from mcm_harness import DEFAULT_IMAGE, make_sandbox

URL_A = "https://api.itz-a.example.com:6443"
URL_B = "https://api.itz-b.example.com:6443"
PLAY = "olm-utils-play-v4"
SWHCC = "olm-utils-swhub-control-center"
OLD = "2026-01-01T00:00:00Z"
WATCHER = "src/helpers/multi_cluster_idle_watcher.sh"
# The process-table rule the harness matches against the scan's own text.
SCAN_MARK = "mcm-proc-scan"


def write_state(sb, **values):
    defaults = {
        "MULTI_CLUSTER_MANAGEMENT": "true", "MCM_CLUSTERS": "", "MCM_CURRENT_CLUSTER": "", "APPLY_TO_ALL": "false",
        "MCM_TARGET_CLUSTERS": "", "MCM_STOP_INACTIVE_CONTAINERS": "true", "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES": "120",
        "MCM_STOP_IDLE_PODMAN_VM": "true",
    }
    defaults.update(values)
    text = "".join(f'export {key}="{value}"\n' for key, value in defaults.items())
    (sb.repo / "configs" / "multi_cluster_management.sh").write_text(text)


def set_up(sb, names=("itz-a", "itz-b", "itz-c"), current="itz-a", products=("cpd", "concert"), **state):
    for name in names:
        sb.write_cluster_marker(name, f"https://api.{name}.example.com:6443")
        for product in products:
            sb.write_config(product, ocp_url=f"https://api.{name}.example.com:6443", cluster=name)
    write_state(sb, MCM_CLUSTERS=" ".join(names), MCM_CURRENT_CLUSTER=current, **state)
    # A scan with no output counts as busy, so idle containers need a real process table.
    sb.add_exec_rule(SCAN_MARK, stdout=idle_table())


def load(sb, target="cpd", args=(), env=None, body=""):
    """An env load as a script does it: strict, through env_bootstrap.sh."""
    script = 'source "${0:A:h}/env_bootstrap.sh"\n' + body
    return sb.run_zsh(script, env={"ENV_TARGET": target, **(env or {})}, args=args)


def podman_verbs(sb, verb):
    return [argv for argv in sb.calls("podman") if argv[:1] == [verb]]


def stops(sb):
    return [argv[-1] for argv in podman_verbs(sb, "stop")]


def starts(sb):
    return [argv[-1] for argv in podman_verbs(sb, "start")]


def lease_dir(sb, cluster):
    return sb.home / "cpd-cli" / "clusters" / cluster / ".leases"


def dead_pid():
    """A PID that has certainly exited."""
    child = subprocess.Popen(["/usr/bin/true"])
    child.wait()
    return child.pid


def proc_table(*rows, own=4242):
    """Scan output: 'self PID', then 'PID PPID cmdline'."""
    return "\n".join([f"self {own}", *rows]) + "\n"


def idle_table():
    return proc_table(
        "1 0 /usr/local/bin/entrypoint",
        "4242 0 /bin/sh -c # " + SCAN_MARK,
    )


def scan_rule(sb, stdout="", rc=0, container="*"):
    """Answers the process scan. Goes ahead of the idle table that set_up adds."""
    rule = {"container": container, "contains": SCAN_MARK, "stdout": stdout, "stderr": "", "rc": rc}
    sb.update_fake_state(lambda state: state["exec_rules"].insert(0, rule))


def wrap_podman(sb, before="", after=""):
    """Runs shell steps around each podman call. The fake keeps the basename podman, which selects its behaviour."""
    real = sb.bin / "real" / "podman"
    real.parent.mkdir()
    (sb.bin / "podman").rename(real)
    wrapper = sb.bin / "podman"
    wrapper.write_text(f'#!/bin/sh\n{before}\n"{real}" "$@"\nrc=$?\n{after}\nexit $rc\n')
    wrapper.chmod(0o755)


def write_lease(leases):
    return f'mkdir -p "{leases}"; echo x > "{leases}/{os.getpid()}"'


def wait_for(condition, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return condition()


def stop_watcher(sb):
    """Ends a watcher a test left running."""
    pid_file = sb.home / "cpd-cli/clusters/.idle-watcher.pid"
    if pid_file.exists():
        try:
            os.kill(int(pid_file.read_text().strip()), 15)
        except (ValueError, ProcessLookupError):
            pass


def live_process():
    return subprocess.Popen(["/bin/sleep", "60"])


def start_watcher(sb, poll=1):
    return subprocess.Popen(["zsh", str(sb.repo / WATCHER)], cwd=sb.repo, env=sb.env({"MCM_IDLE_POLL_SECONDS": str(poll)}))


def end(process):
    if process.poll() is None:
        process.kill()
    process.wait()


@pytest.fixture
def sb():
    with make_sandbox() as sandbox:
        yield sandbox


class TestT7Sync:
    def test_starts_the_run_cluster_when_config_declares_the_image(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        result = load(sb, "cpd")
        assert result.returncode == 0, result.stderr
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        assert starts(sb) == [f"{PLAY}-itz-a"]

    def test_config_without_the_image_leaves_it_off(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert sb.container(f"{PLAY}-itz-a")["running"] is False
        assert starts(sb) == []

    def test_inherited_image_value_does_not_count_as_declared(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        result = load(sb, "concert", env={"OLM_UTILS_IMAGE": DEFAULT_IMAGE})
        assert result.returncode == 0, result.stderr
        assert starts(sb) == []

    def test_missing_container_is_not_created_by_sync(self, sb):
        set_up(sb)
        result = load(sb, "cpd")
        assert result.returncode == 0, result.stderr
        assert sb.container(f"{PLAY}-itz-a") is None
        assert starts(sb) == [] and podman_verbs(sb, "run") == []

    def test_other_targeted_cluster_is_left_alone(self, sb):
        set_up(sb, MCM_TARGET_CLUSTERS="itz-a itz-b")
        sb.add_container(f"{PLAY}-itz-a", running=True)
        sb.add_container(f"{PLAY}-itz-b", running=False)
        result = load(sb, "cpd", args=["--target-cluster", "itz-a"])
        assert result.returncode == 0, result.stderr
        assert sb.container(f"{PLAY}-itz-b")["running"] is False
        assert starts(sb) == [] and stops(sb) == []

    def test_one_off_target_keeps_the_current_cluster_running(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=True)
        sb.add_container(f"{PLAY}-itz-b", running=False)
        sb.add_container(f"{PLAY}-itz-c", running=True)
        result = load(sb, "cpd", args=["--target-cluster", "itz-b"])
        assert result.returncode == 0, result.stderr
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        assert sb.container(f"{PLAY}-itz-b")["running"] is True
        assert sb.container(f"{PLAY}-itz-c")["running"] is False
        assert stops(sb) == [f"{PLAY}-itz-c"]

    def test_target_list_replaces_the_current_cluster_in_the_selection(self, sb):
        set_up(sb, current="itz-c", MCM_TARGET_CLUSTERS="itz-a")
        sb.add_container(f"{PLAY}-itz-c", running=True)
        result = load(sb, "cpd", args=["--target-cluster", "itz-a"])
        assert result.returncode == 0, result.stderr
        assert stops(sb) == [f"{PLAY}-itz-c"]

    def test_apply_to_all_targets_every_registered_cluster(self, sb):
        set_up(sb, APPLY_TO_ALL="true")
        sb.add_container(f"{PLAY}-itz-b", running=True)
        result = load(sb, "cpd", args=["--target-cluster", "itz-a"])
        assert result.returncode == 0, result.stderr
        assert stops(sb) == []

    def test_fan_out_siblings_stay_targeted(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=True)
        sb.add_container(f"{PLAY}-itz-c", running=True)
        result = load(sb, "cpd", args=["--target-cluster", "itz-b"], env={"MCM_RUN_TARGETS": "itz-b itz-c"})
        assert result.returncode == 0, result.stderr
        assert stops(sb) == []

    def test_non_targeted_stop_uses_short_timeout_and_reports_progress(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        sb.add_container(f"{SWHCC}-itz-c", running=True)
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert sorted(podman_verbs(sb, "stop")) == sorted(
            [["stop", "-t", "3", f"{PLAY}-itz-b"], ["stop", "-t", "3", f"{SWHCC}-itz-c"]]
        )
        assert "1/2" in result.stderr and "2/2" in result.stderr

    def test_toggle_off_keeps_non_targeted_but_flat_still_stops(self, sb):
        set_up(sb, MCM_STOP_INACTIVE_CONTAINERS="false")
        sb.add_container(f"{PLAY}-itz-b", running=True)
        sb.add_container(PLAY, running=True)
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert stops(sb) == [PLAY]

    def test_flat_container_stops_while_mode_is_on(self, sb):
        set_up(sb)
        sb.add_container(PLAY, running=True)
        sb.add_container(SWHCC, running=True)
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert sorted(stops(sb)) == sorted([PLAY, SWHCC])

    def test_busy_container_is_left_running_with_a_notice(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        scan_rule(sb, proc_table("77 1 /usr/bin/python3 /opt/ansible/bin/mirror-images --release=5.4"), container=f"{PLAY}-itz-b")
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert stops(sb) == []
        assert "busy" in result.stderr and "mirror-images" in result.stderr

    def test_live_lease_keeps_a_non_targeted_container_running(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        lease_dir(sb, "itz-b").mkdir(parents=True)
        (lease_dir(sb, "itz-b") / str(os.getpid())).write_text("x\n")
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert stops(sb) == []
        assert "lease" in result.stderr

    def test_stale_lease_is_removed_and_the_container_stops(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        lease_dir(sb, "itz-b").mkdir(parents=True)
        stale = lease_dir(sb, "itz-b") / str(dead_pid())
        stale.write_text("x\n")
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert stops(sb) == [f"{PLAY}-itz-b"]
        assert not stale.exists()

    def test_foreign_containers_are_never_touched(self, sb):
        set_up(sb)
        for name in ("mirror-local-registry", "concert-runner-1", f"{PLAY}-unregistered", f"{PLAY}x", "some-debug-box"):
            sb.add_container(name, running=True)
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert stops(sb) == [] and starts(sb) == []
        assert not [argv for argv in sb.calls("podman") if argv[:1] == ["exec"]]

    def test_mode_off_runs_no_podman_at_all(self, sb):
        sb.write_config("cpd", ocp_url=URL_A)
        sb.add_container(PLAY, running=False)
        write_state(sb, MULTI_CLUSTER_MANAGEMENT="false")
        result = load(sb, "cpd")
        assert result.returncode == 0, result.stderr
        assert sb.calls("podman") == []

    def test_unreachable_podman_never_fails_the_run(self, sb):
        set_up(sb)
        sb.set_podman_reachable(False)
        result = load(sb, "cpd", body='print ran-to-the-end\n')
        assert result.returncode == 0, result.stderr
        assert "ran-to-the-end" in result.stdout
        assert "[WARN]" in result.stderr and "podman" in result.stderr

    def test_stop_only_starts_nothing_and_takes_no_lease(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        script = 'source src/helpers/multi_cluster_helpers.sh\nmcm_sync_containers stop-only\n'
        result = sb.run_zsh(script)
        assert result.returncode == 0, result.stderr
        assert starts(sb) == [] and stops(sb) == [f"{PLAY}-itz-b"]
        assert not lease_dir(sb, "itz-a").exists()

    def test_control_center_config_starts_its_own_container(self, sb):
        set_up(sb, products=("swhub_control_center",))
        sb.add_container(f"{SWHCC}-itz-a", running=False)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        result = load(sb, "swhub_control_center")
        assert result.returncode == 0, result.stderr
        assert starts(sb) == [f"{SWHCC}-itz-a"]

    def test_real_control_center_config_counts_as_declaring(self, sb):
        set_up(sb, products=())
        sb.write_config(
            "swhub_control_center", cluster="itz-a",
            text='export OCP_URL="https://api.itz-a.example.com:6443"\n'
                 'export CONTROL_OLM_UTILS_IMAGE="cp.icr.io/x:1"\nexport CONTROL_OLM_UTILS_CONTAINER="custom-cc"\n',
        )
        sb.add_container("custom-cc-itz-a", running=False)
        result = load(sb, "swhub_control_center")
        assert result.returncode == 0, result.stderr
        assert starts(sb) == ["custom-cc-itz-a"]

    def write_custom_control_center(self, sb):
        sb.write_config(
            "swhub_control_center", cluster="itz-a",
            text='export OCP_URL="https://api.itz-a.example.com:6443"\n'
                 'export CONTROL_OLM_UTILS_IMAGE="cp.icr.io/x:1"\nexport CONTROL_OLM_UTILS_CONTAINER="custom-cc"\n',
        )

    def test_custom_control_center_name_joins_the_managed_set(self, sb):
        set_up(sb, products=())
        self.write_custom_control_center(sb)
        sb.add_container("custom-cc-itz-a", running=False)
        result = load(sb, "swhub_control_center", env={"MCM_IDLE_POLL_SECONDS": "30"})
        assert result.returncode == 0, result.stderr
        stop_watcher(sb)
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            'mcm_managed_containers\nprint SEP\n_mcm_container_cluster custom-cc-itz-a\n'
        )
        names, owner = sb.run_zsh(script, check=True).stdout.split("SEP\n")
        assert "custom-cc-itz-a" in names.split()
        assert owner.strip() == "itz-a"

    def test_custom_control_center_container_launches_the_watcher_and_auto_stops(self, sb):
        set_up(sb, products=())
        self.write_custom_control_center(sb)
        sb.add_container("custom-cc-itz-a", running=True, started_at=OLD)
        old_activity(sb)
        result = load(sb, "swhub_control_center", env={"MCM_IDLE_POLL_SECONDS": "30"})
        assert result.returncode == 0, result.stderr
        pid_file = sb.home / "cpd-cli/clusters/.idle-watcher.pid"
        assert wait_for(pid_file.exists)
        stop_watcher(sb)
        wait_for(lambda: not pid_file.exists())
        watcher_once(sb)
        assert sb.container("custom-cc-itz-a")["running"] is False

    def test_custom_control_center_container_stops_when_not_targeted(self, sb):
        set_up(sb, products=("concert",))
        self.write_custom_control_center(sb)
        sb.add_container("custom-cc-itz-a", running=True)
        first = load(sb, "swhub_control_center", env={"MCM_IDLE_POLL_SECONDS": "30"})
        assert first.returncode == 0, first.stderr
        stop_watcher(sb)
        write_state(sb, MCM_CLUSTERS="itz-a itz-b itz-c", MCM_CURRENT_CLUSTER="itz-b")
        second = load(sb, "concert")
        assert second.returncode == 0, second.stderr
        assert stops(sb) == ["custom-cc-itz-a"]

    def test_default_control_center_name_records_nothing(self, sb):
        set_up(sb, products=("swhub_control_center",))
        sb.add_container(f"{SWHCC}-itz-a", running=False)
        result = load(sb, "swhub_control_center", env={"MCM_IDLE_POLL_SECONDS": "30"})
        assert result.returncode == 0, result.stderr
        stop_watcher(sb)
        assert not (sb.home / "cpd-cli/clusters/itz-a/.custom_containers").exists()

    def test_recorded_name_without_the_cluster_suffix_is_ignored(self, sb):
        set_up(sb)
        record = sb.home / "cpd-cli/clusters/itz-b/.custom_containers"
        record.parent.mkdir(parents=True)
        record.write_text("some-foreign-box\nbad name-itz-b\n")
        sb.add_container("some-foreign-box", running=True)
        script = 'source src/helpers/multi_cluster_helpers.sh\nmcm_container_names itz-b\n'
        assert sb.run_zsh(script, check=True).stdout.split() == [f"{PLAY}-itz-b", f"{SWHCC}-itz-b"]

    def test_unregistered_folder_is_not_started_or_counted(self, sb):
        set_up(sb)
        sb.write_config("cpd", ocp_url="https://api.itz-x.example.com:6443", cluster="itz-x")
        sb.add_container(f"{PLAY}-itz-x", running=False)
        result = load(sb, "cpd", args=["--target-cluster", "itz-x"])
        assert result.returncode == 0, result.stderr
        assert starts(sb) == []
        assert sb.container(f"{PLAY}-itz-x")["running"] is False
        assert "itz-x is not registered" in result.stderr
        time.sleep(0.3)
        assert not (sb.home / "cpd-cli/clusters/.idle-watcher.pid").exists()

    def test_nested_child_of_a_config_without_the_image_still_starts(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        (sb.repo / "child.sh").write_text('set -euo pipefail\nsource "${0:A:h}/env_bootstrap.sh"\n')
        result = load(sb, "concert", body='ENV_TARGET=cpd zsh "${0:A:h}/child.sh"\n')
        assert result.returncode == 0, result.stderr
        assert starts(sb) == [f"{PLAY}-itz-a"]

    def test_nested_children_do_not_repeat_the_work(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        (sb.repo / "child.sh").write_text('set -euo pipefail\nsource "${0:A:h}/env_bootstrap.sh"\n')
        result = load(sb, "cpd", body='ENV_TARGET=cpd zsh "${0:A:h}/child.sh"\nENV_TARGET=cpd zsh "${0:A:h}/child.sh"\n')
        assert result.returncode == 0, result.stderr
        assert starts(sb) == [f"{PLAY}-itz-a"] and stops(sb) == [f"{PLAY}-itz-b"]
        assert len(podman_verbs(sb, "ps")) == 1

    def test_nested_child_on_another_cluster_does_its_own_sync(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        sb.add_container(f"{PLAY}-itz-b", running=False)
        (sb.repo / "child.sh").write_text('set -euo pipefail\nsource "${0:A:h}/env_bootstrap.sh"\n')
        result = load(sb, "cpd", body='ENV_TARGET=cpd MCM_CLUSTER=itz-b zsh "${0:A:h}/child.sh"\n')
        assert result.returncode == 0, result.stderr
        assert sorted(starts(sb)) == sorted([f"{PLAY}-itz-a", f"{PLAY}-itz-b"])

    def test_stopping_marker_of_a_dead_owner_is_cleared(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        marker = sb.home / "cpd-cli/clusters/itz-a/.stopping"
        marker.parent.mkdir(parents=True)
        marker.write_text(f"{dead_pid()}\n")
        result = load(sb, "cpd")
        assert result.returncode == 0, result.stderr
        assert not marker.exists()
        assert starts(sb) == [f"{PLAY}-itz-a"]

    def test_stopping_marker_of_a_live_owner_is_waited_for_with_a_limit(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        marker = sb.home / "cpd-cli/clusters/itz-a/.stopping"
        marker.parent.mkdir(parents=True)
        marker.write_text(f"{os.getpid()}\n")
        started = time.time()
        result = load(sb, "cpd", env={"MCM_STOP_WAIT_SECONDS": "1"})
        assert result.returncode == 0, result.stderr
        assert time.time() - started >= 1
        assert "still being stopped" in result.stderr
        assert starts(sb) == [f"{PLAY}-itz-a"]


class TestT7Lease:
    def test_top_level_run_holds_a_lease_for_its_lifetime(self, sb):
        set_up(sb)
        result = load(sb, "cpd", body='print -r -- "PID=$$"\nls "$HOME/cpd-cli/clusters/itz-a/.leases"\n')
        assert result.returncode == 0, result.stderr
        pid = next(line.split("=")[1] for line in result.stdout.splitlines() if line.startswith("PID="))
        assert pid in result.stdout.split("PID=", 1)[1].splitlines()[1:]

    def test_config_without_image_also_takes_a_lease(self, sb):
        set_up(sb)
        result = load(sb, "concert", body='ls "$HOME/cpd-cli/clusters/itz-a/.leases"\n')
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip()

    def test_nested_child_shares_the_parent_lease(self, sb):
        set_up(sb)
        (sb.repo / "child.sh").write_text(
            'set -euo pipefail\nsource "${0:A:h}/env_bootstrap.sh"\nprint -r -- "CHILD=$$"\n'
        )
        result = load(sb, "cpd", body='ENV_TARGET=cpd zsh "${0:A:h}/child.sh"\nprint LEASES\nls "$HOME/cpd-cli/clusters/itz-a/.leases"\n')
        assert result.returncode == 0, result.stderr
        child = next(line.split("=")[1] for line in result.stdout.splitlines() if line.startswith("CHILD="))
        leases = result.stdout.split("LEASES\n", 1)[1].split()
        assert child not in leases and len(leases) == 1

    def test_sourced_shell_takes_no_lease_and_exports_no_guards(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        script = (
            'source "${0:A:h}/s_env.sh" cpd\n'
            'zsh -c \'print -r -- "held=${_MCM_LEASE_HELD:-} done=${_MCM_SYNC_STOP_DONE:-} started=${_MCM_SYNC_STARTED:-}"\'\n'
        )
        result = sb.run_zsh(script, strict=False)
        assert result.returncode == 0, result.stderr
        assert not lease_dir(sb, "itz-a").exists()
        assert "held= done= started=\n" in result.stdout
        # A sourced load still starts the container; only the lease is withheld.
        assert starts(sb) == [f"{PLAY}-itz-a"]

    def test_script_launched_from_a_sourced_shell_takes_its_own_lease(self, sb):
        set_up(sb)
        (sb.repo / "child.sh").write_text('source "${0:A:h}/env_bootstrap.sh"\nls "$HOME/cpd-cli/clusters/itz-a/.leases"\n')
        script = 'source "${0:A:h}/s_env.sh" cpd\nENV_TARGET=cpd zsh "${0:A:h}/child.sh"\n'
        result = sb.run_zsh(script, strict=False)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip().splitlines()[-1].strip().isdigit()

    @pytest.mark.parametrize("launcher", ["x_cr_state_dashboard.sh", "x_service_instance_manager.sh"])
    def test_tui_launcher_takes_no_lease(self, sb, launcher):
        set_up(sb)
        (sb.repo / launcher).write_text('set -euo pipefail\nsource "${0:A:h}/env_bootstrap.sh"\n')
        result = sb.run_script(launcher, env={"ENV_TARGET": "cpd"})
        assert result.returncode == 0, result.stderr
        assert not lease_dir(sb, "itz-a").exists()


class TestT7ProcessScan:
    def busy(self, sb, table):
        sb.add_container(f"{PLAY}-itz-b", running=True)
        scan_rule(sb, table, container=f"{PLAY}-itz-b")
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            f'if mcm_container_busy {PLAY}-itz-b; then print -r -- "BUSY ${{_MCM_BUSY_WHY}}"; else print IDLE; fi\n'
        )
        return sb.run_zsh(script, check=True).stdout

    def test_pid_1_and_the_scan_itself_are_idle(self, sb):
        set_up(sb)
        assert self.busy(sb, idle_table()).strip() == "IDLE"

    def test_children_of_the_scan_are_idle(self, sb):
        set_up(sb)
        table = proc_table("1 0 init", "4242 0 /bin/sh -c x", "4300 4242 cat /proc/4300/stat", "4301 4242 tr x y")
        assert self.busy(sb, table).strip() == "IDLE"

    def test_scan_is_recognised_under_qemu(self, sb):
        set_up(sb)
        table = proc_table(
            "1 0 /usr/bin/qemu-x86_64-static /usr/local/bin/entrypoint",
            "4242 0 /usr/bin/qemu-x86_64-static /bin/sh -c # mcm-proc-scan",
            "4300 4242 /usr/bin/qemu-x86_64-static /usr/bin/cat /proc/4300/stat",
        )
        assert self.busy(sb, table).strip() == "IDLE"

    def test_another_scan_running_at_the_same_moment_is_idle(self, sb):
        set_up(sb)
        table = proc_table("1 0 init", "5555 0 /bin/sh -c # mcm-proc-scan echo self 5555")
        assert self.busy(sb, table).strip() == "IDLE"

    @pytest.mark.parametrize("row", [
        "80 1 /usr/bin/registry serve /etc/docker/registry/config.yml",
        "81 1 registry serve /etc/docker/registry/config.yml",
        "82 1 /usr/bin/qemu-x86_64-static /usr/bin/registry serve /etc/config.yml",
        "83 1 /usr/bin/qemu-x86_64-static /usr/bin/registry registry serve /etc/config.yml",
        "84 1 /usr/bin/qemu-x86_64-static -0 registry /usr/bin/registry serve /etc/config.yml",
        "85 1 /opt/ansible/bin/start-registry",
        "86 1 /bin/bash /opt/ansible/bin/start-registry --port 12443",
        "87 1 /usr/bin/qemu-x86_64-static /bin/bash /opt/ansible/bin/start-registry",
    ])
    def test_registry_processes_are_idle(self, sb, row):
        set_up(sb)
        assert self.busy(sb, proc_table("1 0 init", row)).strip() == "IDLE"

    def test_zombie_without_a_command_line_is_idle(self, sb):
        set_up(sb)
        assert self.busy(sb, proc_table("1 0 init", "90 1 ")).strip() == "IDLE"

    @pytest.mark.parametrize("row", [
        "90 1 /usr/bin/python3 /opt/ansible/bin/mirror-images",
        "91 1 /usr/bin/qemu-x86_64-static /usr/bin/oc image mirror -f /tmp/work/x",
        "92 1 /usr/bin/something-new --flag",
        "93 1 /bin/sh -c registry serve; mirror",
        "94 1 /usr/bin/registry garbage-collect",
    ])
    def test_anything_unrecognised_is_busy(self, sb, row):
        set_up(sb)
        output = self.busy(sb, proc_table("1 0 init", row))
        assert output.startswith("BUSY process " + row.split()[0]), output

    def test_failed_scan_of_a_running_container_counts_as_busy(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        scan_rule(sb, rc=1, container=f"{PLAY}-itz-b")
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            f'if mcm_container_busy {PLAY}-itz-b; then print BUSY; else print IDLE; fi\n'
        )
        assert sb.run_zsh(script, check=True).stdout.strip() == "BUSY"

    def missing_says(self, sb, name):
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            f'if mcm_container_busy {name}; then print -r -- "BUSY ${{_MCM_BUSY_WHY}}"; else print IDLE; fi\n'
        )
        return sb.run_zsh(script, check=True).stdout.strip()

    def test_a_container_that_does_not_exist_is_not_busy(self, sb):
        set_up(sb)
        assert self.missing_says(sb, f"{PLAY}-itz-b") == "IDLE"

    def test_a_cluster_with_no_containers_is_not_busy(self, sb):
        set_up(sb)
        assert self.missing_says(sb, "itz-b") == "IDLE"

    def test_a_cluster_with_only_one_container_created_is_judged_on_that_one(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        assert self.missing_says(sb, "itz-b") == "IDLE"
        scan_rule(sb, proc_table("1 0 init", "93 1 ansible-playbook x"), container=f"{PLAY}-itz-b")
        assert self.missing_says(sb, "itz-b").startswith("BUSY")

    def test_unreachable_podman_still_counts_as_busy(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        sb.set_podman_reachable(False)
        assert self.missing_says(sb, f"{PLAY}-itz-b").startswith("BUSY process scan failed")

    def test_scan_with_no_output_counts_as_busy(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        scan_rule(sb, "", container=f"{PLAY}-itz-b")
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            f'if mcm_container_busy {PLAY}-itz-b; then print -r -- "BUSY ${{_MCM_BUSY_WHY}}"; else print IDLE; fi\n'
        )
        assert sb.run_zsh(script, check=True).stdout.strip() == "BUSY process scan returned no data"

    def test_output_without_the_self_line_counts_as_busy(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        scan_rule(sb, "1 0 init\n", container=f"{PLAY}-itz-b")
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            f'mcm_container_busy {PLAY}-itz-b && print BUSY || print IDLE\n'
        )
        assert sb.run_zsh(script, check=True).stdout.strip() == "BUSY"

    def test_sync_leaves_a_container_with_an_empty_scan_running(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        scan_rule(sb, "", container=f"{PLAY}-itz-b")
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert stops(sb) == []
        assert "returned no data" in result.stderr

    def test_stopped_container_counts_as_idle(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-b", running=False)
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            f'if mcm_container_busy {PLAY}-itz-b; then print BUSY; else print IDLE; fi\n'
        )
        assert sb.run_zsh(script, check=True).stdout.strip() == "IDLE"

    def test_scan_script_output_parses_on_a_fake_proc(self, sb):
        """Runs the container-side script with sh against a /proc look-alike; the classifier reads the result."""
        proc = sb.root / "fakeproc"
        entries = {
            "1": ("1 (entrypoint) S 0 1 1 0", b"/usr/local/bin/entrypoint\0"),
            "23": ("23 (registry) S 1 23 23 0", b"/usr/bin/registry\0serve\0/etc/config.yml\0"),
            "24": ("24 (weird name) (x)) S 1 24 24 0", b"/usr/bin/python3\0/opt/ansible/bin/mirror-images\0--a\nb\0"),
            "25": ("25 (defunct) Z 1 25 25 0", b""),
            "26": ("26 (cat) S 999999 26 26 0", b"cat\0/proc/26/stat\0"),
        }
        for pid, (stat, cmdline) in entries.items():
            (proc / pid).mkdir(parents=True)
            (proc / pid / "stat").write_text(stat + "\n")
            (proc / pid / "cmdline").write_bytes(cmdline)
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            f'out="$(sh -c "${{_MCM_SCAN_SCRIPT//\\/proc/{proc}}}")"\n'
            'print -r -- "$out"\n'
            'print SEP\n'
            '_mcm_scan_busy_lines "$out"\n'
        )
        table, busy = sb.run_zsh(script, check=True).stdout.split("SEP\n")
        assert "23 1 /usr/bin/registry serve /etc/config.yml" in table
        assert "24 1 /usr/bin/python3 /opt/ansible/bin/mirror-images --a b" in table
        assert table.startswith("self ")
        # 26 is an unknown process with a live-looking parent, so it counts.
        assert sorted(line.split(":")[0] for line in busy.strip().splitlines()) == ["24", "26"]

    def test_a_cluster_name_covers_its_containers_and_lease(self, sb):
        set_up(sb)
        sb.add_container(f"{SWHCC}-itz-b", running=True)
        scan_rule(sb, proc_table("1 0 init", "9 1 busy-thing"), container=f"{SWHCC}-itz-b")
        script = 'source src/helpers/multi_cluster_helpers.sh\nmcm_container_busy itz-b && print BUSY || print IDLE\n'
        assert sb.run_zsh(script, check=True).stdout.strip() == "BUSY"


class TestT7Names:
    def test_container_names(self, sb):
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            'mcm_container_names itz-a\nprint SEP\nmcm_container_names\n'
        )
        out = sb.run_zsh(script, check=True).stdout.split("SEP\n")
        assert out[0].split() == [f"{PLAY}-itz-a", f"{SWHCC}-itz-a"]
        assert out[1].split() == [PLAY, SWHCC]

    def test_targeted_clusters_combines_run_and_state_file(self, sb):
        set_up(sb)
        script = (
            'source src/helpers/multi_cluster_helpers.sh\n'
            'MCM_CLUSTER=itz-b mcm_targeted_clusters\n'
        )
        assert set(sb.run_zsh(script, check=True).stdout.split()) == {"itz-a", "itz-b"}


class TestT7Watcher:
    def test_sync_launches_a_single_detached_watcher(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=True)
        pid_file = sb.home / "cpd-cli/clusters/.idle-watcher.pid"
        env = {"MCM_IDLE_POLL_SECONDS": "30"}
        first = load(sb, "cpd", env=env)
        assert first.returncode == 0, first.stderr
        deadline = time.time() + 10
        while time.time() < deadline and not pid_file.exists():
            time.sleep(0.1)
        assert pid_file.exists()
        pid = int(pid_file.read_text().strip())
        try:
            os.kill(pid, 0)
            second = load(sb, "cpd", env=env)
            assert second.returncode == 0, second.stderr
            time.sleep(1)
            assert int(pid_file.read_text().strip()) == pid
        finally:
            os.kill(pid, 15)

    def test_no_watcher_when_nothing_is_up(self, sb):
        set_up(sb)
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        time.sleep(0.3)
        assert not (sb.home / "cpd-cli/clusters/.idle-watcher.pid").exists()

    def test_no_watcher_when_the_timeout_is_zero(self, sb):
        set_up(sb, MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0")
        sb.add_container(f"{PLAY}-itz-a", running=True)
        result = load(sb, "cpd")
        assert result.returncode == 0, result.stderr
        time.sleep(0.3)
        assert not (sb.home / "cpd-cli/clusters/.idle-watcher.pid").exists()


def old_activity(sb, cluster="itz-a", minutes=240):
    path = sb.home / "cpd-cli" / "clusters" / cluster / ".last_activity"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()
    stamp = time.time() - minutes * 60
    os.utime(path, (stamp, stamp))
    return path


def watcher_once(sb, env=None):
    return sb.run_script(WATCHER, args=["--once"], env=env)


def old_container(sb, name=f"{PLAY}-itz-a"):
    sb.add_container(name, running=True, started_at=OLD)


class TestT12Watcher:
    def test_timeout_reached_stops_the_container_and_the_vm(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        result = watcher_once(sb)
        assert result.returncode == 0, result.stderr
        assert sb.container(f"{PLAY}-itz-a")["running"] is False
        assert ["machine", "stop"] in sb.calls("podman")
        assert (sb.home / "cpd-cli/clusters/.idle-watcher.log").exists()

    def test_recent_last_activity_is_enough_and_costs_no_podman_call(self, sb):
        set_up(sb)
        old_container(sb)
        path = old_activity(sb)
        stamp = time.time() - 60
        os.utime(path, (stamp, stamp))
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        assert podman_verbs(sb, "events") == [] and podman_verbs(sb, "exec") == []

    def test_newer_exec_event_counts_as_activity(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        sb.add_event(f"{PLAY}-itz-a", "exec", when=time.time() - 300)
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True

    def test_exec_event_before_the_window_does_not_count(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        sb.add_event(f"{PLAY}-itz-a", "exec", when=time.time() - 3 * 3600)
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False

    def test_events_are_bounded_so_the_call_cannot_stream_forever(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        watcher_once(sb)
        call = podman_verbs(sb, "events")[0]
        assert "--until" in call and "--since" in call

    def test_recent_start_counts_as_activity(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=True)
        old_activity(sb)
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True

    def test_real_podman_start_time_format_is_understood(self, sb):
        set_up(sb)
        now = time.time() - 300
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now)) + ".123456789 +0000 UTC"
        sb.add_container(f"{PLAY}-itz-a", running=True, started_at=stamp)
        old_activity(sb)
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True

    def test_unreadable_start_time_leaves_it_running(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=True, started_at="not-a-time")
        old_activity(sb)
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True

    def test_busy_process_keeps_it_running_and_the_vm_up(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        scan_rule(sb, proc_table("1 0 init", "9 1 /usr/bin/oc image mirror"))
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        assert sb.fake_state()["machine"] == "running"

    def test_own_scan_does_not_reset_the_clock(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        scan_rule(sb, proc_table("1 0 init", "9 1 /usr/bin/oc image mirror"))
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        sb.update_fake_state(lambda state: state["exec_rules"].pop(0))
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False

    def test_live_lease_counts_as_activity_and_costs_no_podman_call(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        lease_dir(sb, "itz-a").mkdir(parents=True)
        (lease_dir(sb, "itz-a") / str(os.getpid())).write_text("x\n")
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        assert podman_verbs(sb, "events") == [] and podman_verbs(sb, "exec") == []

    def test_lease_is_checked_again_under_the_marker(self, sb):
        """Between the scan and the stop a run appears: it must win."""
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        wrap_podman(sb, before=f'case "$1" in exec) {write_lease(lease_dir(sb, "itz-a"))} ;; esac')
        result = watcher_once(sb)
        assert podman_verbs(sb, "exec"), "the scan never reached the fake"
        assert "a run started on cluster itz-a" in result.stdout
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        assert stops(sb) == []
        assert not (sb.home / "cpd-cli/clusters/itz-a/.stopping").exists()

    def test_zero_timeout_disables_it(self, sb):
        set_up(sb, MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0")
        old_container(sb)
        old_activity(sb)
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        assert podman_verbs(sb, "stop") == []

    def test_env_load_alone_does_not_reset_the_clock(self, sb):
        set_up(sb, products=("concert",))
        old_container(sb)
        path = old_activity(sb)
        before = path.stat().st_mtime
        result = load(sb, "concert", body="print done\n")
        assert result.returncode == 0, result.stderr
        assert path.stat().st_mtime == before
        # The driver has exited, so its lease is stale by the time the watcher looks.
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False

    def test_login_probes_of_a_cpd_load_do_not_reset_the_clock(self, sb):
        set_up(sb, products=("cpd",))
        old_container(sb)
        path = old_activity(sb)
        before = path.stat().st_mtime
        sb.add_exec_rule("oc whoami --show-server", stdout=URL_A + "\n", container=f"{PLAY}-itz-a")
        sb.add_exec_rule("oc whoami", stdout="admin\n", container=f"{PLAY}-itz-a")
        result = sb.run_zsh('source s_env.sh cpd\nprint -r -- "${CPDM_OC_LOGIN}"\n', strict=False)
        assert result.returncode == 0, result.stderr
        assert "mcm_login_probe.sh" in result.stdout
        probes = [argv for argv in podman_verbs(sb, "exec") if "whoami" in argv]
        assert len(probes) == 2
        assert sb.calls("cpd-cli") == [] and path.stat().st_mtime == before
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False

    def test_a_real_exec_after_the_login_probes_still_counts(self, sb):
        set_up(sb, products=("cpd",))
        old_container(sb)
        old_activity(sb)
        sb.add_exec_rule("oc whoami --show-server", stdout=URL_A + "\n", container=f"{PLAY}-itz-a")
        sb.add_exec_rule("oc whoami", stdout="admin\n", container=f"{PLAY}-itz-a")
        result = sb.run_zsh('source s_env.sh cpd\n', strict=False)
        assert result.returncode == 0, result.stderr
        sb.add_event(f"{PLAY}-itz-a", "exec")
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True

    def test_mode_off_login_string_has_no_probe_tool(self, sb):
        write_state(sb, MULTI_CLUSTER_MANAGEMENT="false")
        sb.write_config("cpd", ocp_url=URL_A)
        result = load(sb, "cpd", body='print -r -- "${CPDM_OC_LOGIN}"\n')
        assert result.returncode == 0, result.stderr
        assert "mcm_login_probe" not in result.stdout and "podman exec olm-utils-play-v4 oc whoami" in result.stdout

    def test_shim_manage_refreshes_the_clock(self, sb):
        set_up(sb, MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0")
        old_container(sb)
        path = old_activity(sb)
        before = path.stat().st_mtime
        env = {
            "MCM_CLUSTER_ROOT": str(sb.repo / "configs/clusters/itz-a"),
            "MCM_CPD_CLI_WORKSPACE": str(sb.home / "cpd-cli/clusters/itz-a"),
            "CPD_CLI_HOME": str(sb.home / "cpd-cli"),
        }
        result = sb.run_script("src/helpers/multi_cluster_bin/cpd-cli", env=env, args=["manage", "login-to-ocp"])
        assert result.returncode == 0, result.stderr
        assert path.stat().st_mtime > before

    def test_shim_manage_starts_a_watcher_for_the_container_it_creates(self, sb):
        set_up(sb)
        env = {
            "MCM_CLUSTER_ROOT": str(sb.repo / "configs/clusters/itz-a"),
            "MCM_CPD_CLI_WORKSPACE": str(sb.home / "cpd-cli/clusters/itz-a"),
            "CPD_CLI_HOME": str(sb.home / "cpd-cli"),
            "OLM_UTILS_CONTAINER": f"{PLAY}-itz-a",
            "MCM_IDLE_POLL_SECONDS": "30",
        }
        (sb.home / "cpd-cli/clusters/itz-a").mkdir(parents=True)
        result = sb.run_script("src/helpers/multi_cluster_bin/cpd-cli", env=env, args=["manage", "login-to-ocp"])
        assert result.returncode == 0, result.stderr
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        pid_file = sb.home / "cpd-cli/clusters/.idle-watcher.pid"
        try:
            assert wait_for(pid_file.exists)
            os.kill(int(pid_file.read_text().strip()), 0)
        finally:
            stop_watcher(sb)

    def test_watcher_waits_for_a_container_a_recent_manage_is_creating(self, sb):
        set_up(sb)
        old_activity(sb, minutes=1)
        watcher = start_watcher(sb)
        try:
            log = sb.home / "cpd-cli/clusters/.idle-watcher.log"
            assert wait_for(lambda: log.exists() and "running yet, waiting: a recent cpd-cli manage" in log.read_text())
            assert watcher.poll() is None
            sb.add_container(f"{PLAY}-itz-a", running=True, started_at=OLD)
            time.sleep(1.5)
            assert watcher.poll() is None
        finally:
            end(watcher)

    def test_watcher_waits_while_a_run_holds_a_lease(self, sb):
        set_up(sb)
        run = live_process()
        watcher = start_watcher(sb)
        try:
            lease_dir(sb, "itz-a").mkdir(parents=True)
            (lease_dir(sb, "itz-a") / str(run.pid)).write_text("x\n")
            time.sleep(2.5)
            assert watcher.poll() is None
            end(run)
            assert watcher.wait(timeout=15) == 0
            assert "no managed container is running, exiting" in (sb.home / "cpd-cli/clusters/.idle-watcher.log").read_text()
        finally:
            end(run)
            end(watcher)

    def test_loop_exits_after_three_wakes_with_an_invalid_state_file(self, sb):
        set_up(sb)
        (sb.repo / "configs/multi_cluster_management.sh").write_text('export MULTI_CLUSTER_MANAGEMENT="maybe"\n')
        result = sb.run_script(WATCHER, env={"MCM_IDLE_POLL_SECONDS": "1"}, timeout=20)
        assert result.returncode == 0, result.stderr
        log = (sb.home / "cpd-cli/clusters/.idle-watcher.log").read_text()
        assert "state file invalid for 3 wakes" in log
        assert log.count("state file is invalid (") == 2

    def test_a_valid_wake_resets_the_invalid_count(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb, minutes=1)
        state = sb.repo / "configs/multi_cluster_management.sh"
        good = state.read_text()
        state.write_text('export MULTI_CLUSTER_MANAGEMENT="maybe"\n')
        watcher = start_watcher(sb)
        try:
            log = sb.home / "cpd-cli/clusters/.idle-watcher.log"
            assert wait_for(lambda: log.exists() and "is invalid (1/3)" in log.read_text())
            state.write_text(good)
            time.sleep(1.5)
            state.write_text('export MULTI_CLUSTER_MANAGEMENT="maybe"\n')
            assert wait_for(lambda: log.read_text().count("is invalid (1/3)") == 2)
            assert watcher.poll() is None
        finally:
            end(watcher)

    def test_loop_exits_when_the_timeout_is_set_to_zero(self, sb):
        set_up(sb, MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0")
        old_container(sb)
        old_activity(sb, minutes=1)
        result = sb.run_script(WATCHER, env={"MCM_IDLE_POLL_SECONDS": "1"}, timeout=20)
        assert result.returncode == 0, result.stderr
        assert "idle timeout is 0" in (sb.home / "cpd-cli/clusters/.idle-watcher.log").read_text()
        assert not (sb.home / "cpd-cli/clusters/.idle-watcher.pid").exists()

    def test_shim_other_verbs_do_not_touch_the_clock(self, sb):
        set_up(sb)
        path = old_activity(sb)
        before = path.stat().st_mtime
        env = {
            "MCM_CLUSTER_ROOT": str(sb.repo / "configs/clusters/itz-a"),
            "MCM_CPD_CLI_WORKSPACE": str(sb.home / "cpd-cli/clusters/itz-a"),
            "CPD_CLI_HOME": str(sb.home / "cpd-cli"),
        }
        (sb.repo / "configs/clusters/itz-a/.home").mkdir(parents=True)
        result = sb.run_script("src/helpers/multi_cluster_bin/cpd-cli", env=env, args=["version"])
        assert result.returncode == 0, result.stderr
        assert path.stat().st_mtime == before

    def test_vm_stays_up_while_anything_else_runs(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        sb.add_container("mirror-local-registry", running=True)
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False
        assert sb.container("mirror-local-registry")["running"] is True
        assert ["machine", "stop"] not in sb.calls("podman")

    def test_vm_stays_up_while_a_podman_build_runs(self, sb):
        """A buildah build container is listed only by `podman ps --external` (gap X8b)."""
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        sb.add_external_container("install-runner-build-working-container")
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False
        assert ["machine", "stop"] not in sb.calls("podman")

    def test_vm_stop_can_be_turned_off(self, sb):
        set_up(sb, MCM_STOP_IDLE_PODMAN_VM="false")
        old_container(sb)
        old_activity(sb)
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False
        assert ["machine", "stop"] not in sb.calls("podman")

    def test_vm_stays_up_while_another_managed_container_is_busy(self, sb):
        set_up(sb)
        old_container(sb, f"{PLAY}-itz-a")
        old_container(sb, f"{PLAY}-itz-b")
        old_activity(sb, "itz-a")
        old_activity(sb, "itz-b")
        scan_rule(sb, proc_table("1 0 init", "9 1 busy-thing"), container=f"{PLAY}-itz-b")
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False
        assert sb.container(f"{PLAY}-itz-b")["running"] is True
        assert ["machine", "stop"] not in sb.calls("podman")

    def test_vm_stays_up_for_a_lease_on_another_cluster_with_no_container(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        lease_dir(sb, "itz-b").mkdir(parents=True)
        (lease_dir(sb, "itz-b") / str(os.getpid())).write_text("x\n")
        result = watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False
        assert ["machine", "stop"] not in sb.calls("podman")
        assert sb.fake_state()["machine"] == "running"
        assert "VM stays up for now" in result.stdout

    def test_vm_stays_up_for_a_lease_in_an_unregistered_folder(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        lease_dir(sb, "itz-x").mkdir(parents=True)
        (lease_dir(sb, "itz-x") / str(os.getpid())).write_text("x\n")
        watcher_once(sb)
        assert ["machine", "stop"] not in sb.calls("podman")

    def test_vm_stays_up_for_a_recent_manage_on_another_cluster(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        old_activity(sb, "itz-b", minutes=1)
        watcher_once(sb)
        assert ["machine", "stop"] not in sb.calls("podman")

    def test_vm_stays_up_for_a_lease_written_after_the_container_stop(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        wrap_podman(sb, after=f'case "$1" in stop) {write_lease(lease_dir(sb, "itz-a"))} ;; esac')
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is False
        assert ["machine", "stop"] not in sb.calls("podman")
        assert not (sb.home / "cpd-cli/clusters/.vm-stopping").exists()

    def test_vm_stays_up_for_a_container_started_under_the_marker(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        real = sb.bin / "real" / "podman"
        wrap_podman(sb, before=f'if [ "$1 $2" = "machine inspect" ]; then "{real}" run --name latecomer x >/dev/null; fi')
        result = watcher_once(sb)
        assert ["machine", "stop"] not in sb.calls("podman")
        assert not (sb.home / "cpd-cli/clusters/.vm-stopping").exists()
        assert "VM stays up" in result.stdout

    def test_vm_stop_holds_the_marker(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        marker = sb.home / "cpd-cli/clusters/.vm-stopping"
        seen = sb.tmp / "marker-seen"
        wrap_podman(sb, before=f'if [ "$1 $2" = "machine stop" ] && [ -f "{marker}" ]; then touch "{seen}"; fi')
        watcher_once(sb)
        assert ["machine", "stop"] in sb.calls("podman")
        assert seen.exists() and not marker.exists()

    def test_vm_stops_once_the_lease_that_held_it_up_has_ended(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb)
        run = live_process()
        lease_dir(sb, "itz-b").mkdir(parents=True)
        (lease_dir(sb, "itz-b") / str(run.pid)).write_text("x\n")
        watcher = start_watcher(sb)
        try:
            assert wait_for(lambda: sb.container(f"{PLAY}-itz-a")["running"] is False)
            time.sleep(1.5)
            assert watcher.poll() is None
            assert sb.fake_state()["machine"] == "running"
            end(run)
            assert watcher.wait(timeout=15) == 0
            assert sb.fake_state()["machine"] == "stopped"
        finally:
            end(run)
            end(watcher)

    def test_vm_not_stopped_when_the_watcher_stopped_nothing(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        watcher_once(sb)
        assert ["machine", "stop"] not in sb.calls("podman")

    def test_foreign_containers_are_left_alone(self, sb):
        set_up(sb)
        old_container(sb, "some-debug-box")
        old_container(sb, f"{PLAY}-unregistered")
        old_container(sb)
        old_activity(sb)
        watcher_once(sb)
        assert sorted(stops(sb)) == [f"{PLAY}-itz-a"]

    def test_control_center_and_flat_containers_are_watched(self, sb):
        set_up(sb)
        old_container(sb, f"{SWHCC}-itz-b")
        old_container(sb, PLAY)
        old_activity(sb, "itz-b")
        watcher_once(sb)
        assert sorted(stops(sb)) == sorted([f"{SWHCC}-itz-b", PLAY])

    def test_targeted_containers_stop_on_idle_too(self, sb):
        """The auto-stop applies to a targeted container, unlike sync."""
        set_up(sb, current="itz-a")
        old_container(sb, f"{PLAY}-itz-a")
        old_activity(sb)
        watcher_once(sb)
        assert stops(sb) == [f"{PLAY}-itz-a"]

    def test_mode_off_keeps_watching_cluster_containers_with_the_idle_rules(self, sb):
        """Delineation is one-way: a pinned run uses its cluster's container with the mode off, so the watcher stays.

        It stops an idle cluster container once the timeout has passed, leaves a fresh one, and does not exit while
        cluster containers run. Before, the mode going off stopped every idle one at once and exited.
        """
        set_up(sb, MULTI_CLUSTER_MANAGEMENT="false")
        old_container(sb)
        old_activity(sb)  # also creates the folder holding the log
        sb.add_container(f"{PLAY}-itz-b", running=True)  # started now: within the timeout
        result = watcher_once(sb)
        assert "mode is off, exiting" not in result.stdout
        assert stops(sb) == [f"{PLAY}-itz-a"]
        assert sb.container(f"{PLAY}-itz-b")["running"] is True

    def test_mode_off_leaves_the_flat_containers_and_the_vm_alone(self, sb):
        """Flat runs, the default while off, take no leases: their container and the VM are not the watcher's."""
        set_up(sb, MULTI_CLUSTER_MANAGEMENT="false")
        old_container(sb)
        old_activity(sb)
        sb.add_container(PLAY, running=True, started_at=OLD)
        sb.add_container(SWHCC, running=True, started_at=OLD)
        result = watcher_once(sb)
        assert stops(sb) == [f"{PLAY}-itz-a"]
        assert sb.container(PLAY)["running"] is True
        assert ["machine", "stop"] not in sb.calls("podman")
        assert result.returncode == 0, result.stderr

    def test_mode_off_vm_stays_up_after_the_last_cluster_container(self, sb):
        set_up(sb, MULTI_CLUSTER_MANAGEMENT="false")
        old_container(sb)
        old_activity(sb)
        result = watcher_once(sb)
        assert stops(sb) == [f"{PLAY}-itz-a"]
        assert ["machine", "stop"] not in sb.calls("podman")
        assert "multi-cluster mode is off" in result.stdout

    def test_mode_off_leaves_a_busy_cluster_container_running(self, sb):
        set_up(sb, MULTI_CLUSTER_MANAGEMENT="false")
        old_container(sb)
        old_activity(sb)
        scan_rule(sb, stdout="self 9\n1 0 /bin/sh /entry.sh\n42 1 ansible-playbook x\n")
        watcher_once(sb)
        assert sb.container(f"{PLAY}-itz-a")["running"] is True
        assert podman_verbs(sb, "stop") == []

    def test_mode_off_with_nothing_running_stops_nothing(self, sb):
        set_up(sb, MULTI_CLUSTER_MANAGEMENT="false")
        watcher_once(sb)
        assert podman_verbs(sb, "stop") == []

    def test_mode_off_loop_runs_until_no_cluster_container_is_left(self, sb):
        set_up(sb, MULTI_CLUSTER_MANAGEMENT="false")
        old_container(sb)
        old_activity(sb)
        result = sb.run_script(WATCHER, env={"MCM_IDLE_POLL_SECONDS": "1"}, timeout=30)
        assert result.returncode == 0, result.stderr
        log = (sb.home / "cpd-cli/clusters/.idle-watcher.log").read_text()
        assert "mode is off, exiting" not in log
        assert "idle for the whole timeout, stopping" in log
        assert "VM stays up: multi-cluster mode is off" in log and "watcher finished" in log
        assert stops(sb) == [f"{PLAY}-itz-a"]

    def test_missing_state_file_is_not_created(self, sb):
        set_up(sb)
        state = sb.repo / "configs" / "multi_cluster_management.sh"
        state.unlink()
        old_container(sb)
        result = watcher_once(sb)
        assert result.returncode == 0, result.stderr
        assert not state.exists()

    def test_loop_exits_when_no_managed_container_runs(self, sb):
        set_up(sb)
        result = sb.run_script(WATCHER, env={"MCM_IDLE_POLL_SECONDS": "1"}, timeout=20)
        assert result.returncode == 0, result.stderr
        assert not (sb.home / "cpd-cli/clusters/.idle-watcher.pid").exists()
        log = (sb.home / "cpd-cli/clusters/.idle-watcher.log").read_text()
        assert "no managed container" in log

    def test_loop_exits_after_three_unreachable_wakes(self, sb):
        set_up(sb)
        old_container(sb)
        sb.set_podman_reachable(False)
        result = sb.run_script(WATCHER, env={"MCM_IDLE_POLL_SECONDS": "1"}, timeout=20)
        assert result.returncode == 0, result.stderr
        log = (sb.home / "cpd-cli/clusters/.idle-watcher.log").read_text()
        assert "unreachable for 3" in log
        assert log.count("podman unreachable (") == 2

    def test_loop_keeps_watching_when_the_mode_is_turned_off(self, sb):
        """A delineated cluster stays per cluster with the flag off, so its container is still watched.

        Before, the watcher exited as soon as the flag went off. Now it exits once no cluster container runs.
        """
        set_up(sb)
        old_container(sb)
        old_activity(sb, minutes=1)
        process = subprocess.Popen(["zsh", str(sb.repo / WATCHER)], cwd=sb.repo, env=sb.env({"MCM_IDLE_POLL_SECONDS": "1"}))
        try:
            time.sleep(1.5)
            assert process.poll() is None
            write_state(sb, MULTI_CLUSTER_MANAGEMENT="false", MCM_CLUSTERS="itz-a itz-b itz-c", MCM_CURRENT_CLUSTER="itz-a")
            time.sleep(2.5)
            assert process.poll() is None
            assert sb.container(f"{PLAY}-itz-a")["running"] is True
            # Nothing left: the container is down and the last cpd-cli manage is past the timeout.
            sb.run_zsh(f"podman stop -t 3 {PLAY}-itz-a\n", check=True)
            old_activity(sb)
            assert process.wait(timeout=15) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_second_watcher_leaves_at_once(self, sb):
        set_up(sb)
        old_container(sb)
        old_activity(sb, minutes=1)
        env = {"MCM_IDLE_POLL_SECONDS": "30"}
        first = subprocess.Popen(["zsh", str(sb.repo / WATCHER)], cwd=sb.repo, env=sb.env(env))
        try:
            pid_file = sb.home / "cpd-cli/clusters/.idle-watcher.pid"
            deadline = time.time() + 10
            while time.time() < deadline and not pid_file.exists():
                time.sleep(0.05)
            assert pid_file.read_text().strip() == str(first.pid)
            second = sb.run_script(WATCHER, env=env, timeout=10)
            assert second.returncode == 0, second.stderr
            assert pid_file.read_text().strip() == str(first.pid)
        finally:
            first.kill()
            first.wait()

    def test_stale_pid_file_is_replaced(self, sb):
        set_up(sb)
        pid_file = sb.home / "cpd-cli/clusters/.idle-watcher.pid"
        pid_file.parent.mkdir(parents=True)
        pid_file.write_text(f"{dead_pid()}\n")
        result = sb.run_script(WATCHER, env={"MCM_IDLE_POLL_SECONDS": "1"}, timeout=20)
        assert result.returncode == 0, result.stderr
        assert not pid_file.exists()

    def test_help_exits_cleanly(self, sb):
        result = sb.run_script(WATCHER, args=["--help"])
        assert result.returncode == 0
        assert "--once" in result.stdout

    def test_unknown_option_is_an_error(self, sb):
        result = sb.run_script(WATCHER, args=["--nope"])
        assert result.returncode != 0
        assert "[ERROR]" in result.stderr


class TestT12VmRecovery:
    def vm_marker(self, sb, owner):
        marker = sb.home / "cpd-cli/clusters/.vm-stopping"
        marker.parent.mkdir(parents=True)
        marker.write_text(f"{owner}\n")
        return marker

    def test_run_writes_its_lease_before_waiting_for_a_vm_stop(self, sb):
        set_up(sb)
        marker = self.vm_marker(sb, os.getpid())
        driver = sb.repo / "driver.sh"
        driver.write_text('set -euo pipefail\nsource "${0:A:h}/env_bootstrap.sh"\n')
        run = subprocess.Popen(
            ["zsh", str(driver)], cwd=sb.repo, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=sb.env({"ENV_TARGET": "concert", "MCM_VM_STOP_WAIT_SECONDS": "20"}),
        )
        try:
            leases = lease_dir(sb, "itz-a")
            assert wait_for(lambda: leases.exists() and any(leases.iterdir()))
            assert run.poll() is None
            marker.unlink()
            assert run.wait(timeout=15) == 0
        finally:
            end(run)

    def test_load_waits_for_a_vm_stop_then_starts_the_vm_again(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        self.vm_marker(sb, os.getpid())
        sb.set_machine("stopped")
        started = time.time()
        result = load(sb, "cpd", env={"MCM_VM_STOP_WAIT_SECONDS": "1"})
        assert result.returncode == 0, result.stderr
        assert time.time() - started >= 1
        assert "still being stopped" in result.stderr
        assert ["machine", "start"] in sb.calls("podman")
        assert starts(sb) == [f"{PLAY}-itz-a"]

    def test_marker_of_a_dead_watcher_is_cleared(self, sb):
        set_up(sb)
        marker = self.vm_marker(sb, dead_pid())
        result = load(sb, "concert")
        assert result.returncode == 0, result.stderr
        assert not marker.exists()
        assert ["machine", "start"] not in sb.calls("podman")

    def test_vm_stopped_just_before_the_lease_is_started_again(self, sb):
        set_up(sb)
        sb.add_container(f"{PLAY}-itz-a", running=False)
        sb.set_machine("stopped")
        result = load(sb, "cpd")
        assert result.returncode == 0, result.stderr
        assert ["machine", "start"] in sb.calls("podman")
        assert starts(sb) == [f"{PLAY}-itz-a"]

    def test_unreachable_podman_with_a_running_vm_is_not_restarted(self, sb):
        set_up(sb)
        sb.set_podman_reachable(False)
        result = load(sb, "cpd")
        assert result.returncode == 0, result.stderr
        assert ["machine", "start"] not in sb.calls("podman")


class TestTimestamps:
    @pytest.mark.parametrize("text,epoch", [
        ("1970-01-01T00:00:00Z", 0),
        ("2026-11-09T12:00:00Z", 1794225600),
        ("2026-11-09 12:00:00.123456789 +0000 UTC", 1794225600),
        ("2026-11-09 13:00:00 +0100 CET", 1794225600),
        ("2026-11-09T07:00:00-05:00", 1794225600),
        ("2024-02-29T00:00:00Z", 1709164800),
        ("2024-01-01T00:00:00Z", 1704067200),
    ])
    def test_formats(self, sb, text, epoch):
        script = f"source src/helpers/multi_cluster_helpers.sh\n_mcm_epoch_from_timestamp '{text}'\n"
        assert sb.run_zsh(script, check=True).stdout.strip() == str(epoch)

    @pytest.mark.parametrize("text", ["", "<no value>", "yesterday"])
    def test_garbage_is_refused(self, sb, text):
        script = f"source src/helpers/multi_cluster_helpers.sh\n_mcm_epoch_from_timestamp '{text}' || print REFUSED\n"
        assert sb.run_zsh(script, check=True).stdout.strip() == "REFUSED"


# ---- one-way delineation: a pinned run is managed whatever the flag says ------------------------------------------
class TestModeOffPinned:
    def test_pinned_run_starts_its_container(self, sb):
        set_up(sb, MULTI_CLUSTER_MANAGEMENT="false")
        sb.add_container(f"{PLAY}-itz-a", running=False)
        result = load(sb, "cpd", args=["--target-cluster", "itz-a"])
        assert result.returncode == 0, result.stderr
        assert starts(sb) == [f"{PLAY}-itz-a"]

    def test_only_the_run_own_targets_count_and_flat_containers_stay(self, sb):
        """With the flag off the state file selects nothing: itz-b (current) and itz-c (target list) are not targeted."""
        set_up(sb, current="itz-b", MULTI_CLUSTER_MANAGEMENT="false", MCM_TARGET_CLUSTERS="itz-c")
        sb.add_container(f"{PLAY}-itz-a", running=True)
        sb.add_container(f"{PLAY}-itz-b", running=True)
        sb.add_container(f"{PLAY}-itz-c", running=True)
        sb.add_container(PLAY, running=True)
        sb.add_container(SWHCC, running=True)
        result = load(sb, "cpd", args=["--target-cluster", "itz-a"])
        assert result.returncode == 0, result.stderr
        assert sorted(stops(sb)) == [f"{PLAY}-itz-b", f"{PLAY}-itz-c"]
        assert sb.container(PLAY)["running"] is True and sb.container(SWHCC)["running"] is True

    def test_pinned_run_takes_a_lease_and_launches_the_watcher(self, sb):
        set_up(sb, MULTI_CLUSTER_MANAGEMENT="false")
        sb.add_container(f"{PLAY}-itz-a", running=True)
        pid_file = sb.home / "cpd-cli/clusters/.idle-watcher.pid"
        result = load(sb, "cpd", env={"MCM_CLUSTER": "itz-a", "MCM_IDLE_POLL_SECONDS": "30"})
        assert result.returncode == 0, result.stderr
        assert list((sb.home / "cpd-cli/clusters/itz-a/.leases").iterdir())
        deadline = time.time() + 10
        while time.time() < deadline and not pid_file.exists():
            time.sleep(0.1)
        assert pid_file.exists()
        os.kill(int(pid_file.read_text().strip()), 15)

    def test_flat_run_touches_no_podman_even_with_delineated_clusters(self, sb):
        set_up(sb, current="itz-a", MULTI_CLUSTER_MANAGEMENT="false")
        sb.write_config("cpd", ocp_url="https://api.flat.example.com:6443")
        sb.add_container(f"{PLAY}-itz-a", running=True)
        result = load(sb, "cpd")
        assert result.returncode == 0, result.stderr
        assert sb.calls("podman") == []

    def test_no_watcher_for_an_unpinned_call_with_the_mode_off(self, sb):
        set_up(sb, MULTI_CLUSTER_MANAGEMENT="false")
        sb.add_container(f"{PLAY}-itz-a", running=True)
        result = sb.run_zsh('source src/helpers/multi_cluster_helpers.sh\nmcm_ensure_idle_watcher\n')
        assert result.returncode == 0, result.stderr
        time.sleep(0.3)
        assert not (sb.home / "cpd-cli/clusters/.idle-watcher.pid").exists()
