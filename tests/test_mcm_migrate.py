"""T10: src/utilities/multi_cluster_management_utils/migrate_to_multi_cluster.sh (plan section 5.10)."""

import hashlib
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mcm_harness import make_sandbox

SCRIPT = "src/utilities/multi_cluster_management_utils/migrate_to_multi_cluster.sh"
URL_A = "https://api.itz-a.example.com:6443"
URL_B = "https://api.itz-b.example.com:6443"
URL_K = "https://api.itz-k.example.com:6443"
FLAT = "olm-utils-play-v4"
SCAN_MARK = "mcm-proc-scan"
SCAN_IDLE = "self 99\n1 0 /bin/sh /entry.sh\n99 1 sh -c # mcm-proc-scan\n"
CLI = "src/utilities/multi_cluster_management_utils/multi_cluster.sh"


def _sandbox():
    sb = make_sandbox(extra=["src/utilities/multi_cluster_management_utils"])
    # The real process table could hold anything: a fake ps keeps the scan deterministic.
    (sb.root / "ps.txt").write_text("")
    (sb.root / "ps_tree.txt").write_text("")
    (sb.root / "lsof.txt").write_text("")
    ps = sb.bin / "ps"
    ps.write_text(f'''#!/bin/zsh
case "$*" in
  *ppid*) cat "{sb.root}/ps_tree.txt" ;;
  *) cat "{sb.root}/ps.txt" ;;
esac
exit 0
''')
    ps.chmod(0o755)
    lsof = sb.bin / "lsof"
    lsof.write_text(f'#!/bin/zsh\ncat "{sb.root}/lsof.txt"\nexit 0\n')
    lsof.chmod(0o755)
    # A scan with no "self" line counts as busy, so idle containers need a real table.
    sb.add_exec_rule(SCAN_MARK, stdout=SCAN_IDLE)
    return sb


def _scan_rule(sb, stdout, container=FLAT):
    """Answers the process scan ahead of the idle table from _sandbox."""
    rule = {"container": container, "contains": SCAN_MARK, "stdout": stdout, "stderr": "", "rc": 0}
    sb.update_fake_state(lambda state: state["exec_rules"].insert(0, rule))


def _fake_oc_with_kubeconfig(sb):
    oc = sb.bin / "oc"
    oc.write_text(f"""#!/bin/zsh
case "$*" in
  *"contexts[*]"*) printf 'admin-a\\tcl-a\\nctx-b\\tcl-b\\nctx-other\\tcl-c\\n'; exit 0 ;;
  *"clusters[*]"*) printf 'cl-a\\t{URL_A}\\ncl-b\\t{URL_B}\\ncl-c\\thttps://api.other.example.com:6443\\n'; exit 0 ;;
  "config current-context"*) print -r -- admin-a; exit 0 ;;
  "config view"*) print -r -- "kubeconfig-for: $*"; exit 0 ;;
esac
exit 0
""")
    oc.chmod(0o755)
    kube = sb.home / ".kube" / "config"
    kube.parent.mkdir(parents=True, exist_ok=True)
    kube.write_text("original kubeconfig\n")
    return kube


def _add_fixture(sb):
    """A two-cluster flat setup: CP4D and Kubecost on A, Concert on B."""
    sb.write_config("cpd", ocp_url=URL_A)
    sb.write_config("kubecost", ocp_url=URL_A)
    sb.write_config("concert", ocp_url=URL_B)

    openshift = sb.repo / "configs" / "openshift_config"
    openshift.mkdir(parents=True)
    (openshift / "htpasswd_credentials.txt").write_text(f"# username:password for the 'htpasswd' login on {URL_A}\nuser:secret\n")
    (openshift / "guest_admin_credentials.txt").write_text("guestuser_1:secret\n")
    (openshift / "service_id_credentials.txt").write_text(
        f"# username:password for service IDs on the 'p' login on {URL_K}\n"
        "# Software Hub API keys below are for https://cpd-cpd.apps.itz-k.example.com\n\nsvc:secret\n"
    )
    (openshift / "multi.txt").write_text(f"# login on {URL_A}\n# login on {URL_B}\nu:p\n")

    for rel, text in {
        "service_instances/instance.json": "{}",
        "cpd-cli-workspace/logs/run.log": "log",
        "cpd-cli-workspace/scale_config_cache/entry": "cache",
        "kubecost_workspace/kc.txt": "kc",
        "concert_workspace/run.txt": "concert",
        "registry_mirror_workspace/mirrored.txt": "mirrored",
        "registry_mirror_workspace/tools/oc-mirror": "tool",
        "src/utilities/oadp_backup_restore_cp4d_utils/backup_bucket_configs/s3_bucket.sh": "bucket",
        "src/utilities/oadp_backup_restore_cp4d_utils/restore_target_configs/t_vars.sh": "target",
        "scripts/install_confluent_platform/confluent_platform_vars/rendered/kafka-secret.json": "{}",
        "scripts/install_confluent_platform/install_confluent_platform_flink_addon/flink_vars/rendered/flink.yaml": "a: 1",
    }.items():
        path = sb.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    for rel, text in {
        "cpd-cli/work/offline/case.tgz": "case",
        "cpd-cli-swhub-control-center/work/status.csv": "status",
        "cpd-cli/m_backups/keep.txt": "keep",
        ".cpd-cli/config": "profiles: {}\n",
    }.items():
        path = sb.home / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def _run(sb, *args, stdin=None, check=False, env_extra=None):
    env = sb.env(env_extra)
    result = subprocess.run(
        ["zsh", str(sb.repo / SCRIPT), *args], cwd=sb.repo, env=env, capture_output=True, text=True, timeout=120,
        input=stdin if stdin is not None else "", check=False,
    )
    if check:
        assert result.returncode == 0, result.stdout + result.stderr
    return result


def _state(sb):
    values = {}
    state_file = sb.repo / "configs" / "multi_cluster_management.sh"
    for line in state_file.read_text().splitlines():
        if line.startswith("export "):
            key, _, rest = line[len("export "):].partition("=")
            values[key] = rest.split('"')[1]
    return values


def _snapshot(root):
    """Every path under root with its mode, mtime and content hash, leaving out the fake tools' own files."""
    found = {}
    for path in sorted(root.rglob("*")):
        rel = str(path.relative_to(root))
        if rel in ("fake_state.json", "fake_state.lock", "fake_calls.log") or rel.startswith("fake_state."):
            continue
        info = path.lstat()
        digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else ""
        found[rel] = (info.st_mode, info.st_mtime_ns, digest)
    return found


def _mutating_podman(sb):
    return [c for c in sb.calls("podman") if c and c[0] in ("rm", "stop", "start", "run", "machine")]


def _migrate_unfinished(sb, *args):
    """A migration that stops at its first register step, after every move. Its journal is not complete."""
    flag = _break_mv_on(sb, "/.cluster")
    result = _run(sb, "--yes", *args)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "failed: register cluster" in result.stderr
    flag.unlink()
    assert "status\tcomplete" not in _journal(sb).read_text()
    return result


def _strip_complete(sb):
    """Turns the latest complete journal into one killed after its last step, before it said complete."""
    journal = _journal(sb)
    lines = journal.read_text().splitlines(keepends=True)
    assert lines[-1] == "status\tcomplete\n"
    journal.write_text("".join(lines[:-1]))


def test_help_describes_flags():
    with _sandbox() as sb:
        result = _run(sb, "--help", check=True)
        for flag in ("--dry-run", "--yes", "--name", "--map", "--mirror-state-to", "--rollback"):
            assert flag in result.stdout
        assert "--reverse" not in result.stdout
        assert "One way" in result.stdout and "permanent" in result.stdout


def test_dry_run_changes_nothing():
    with _sandbox() as sb:
        _add_fixture(sb)
        _fake_oc_with_kubeconfig(sb)
        sb.add_container(FLAT)
        before = _snapshot(sb.root)
        result = _run(sb, "--dry-run", "--yes", check=True)
        assert _snapshot(sb.root) == before
        assert "Dry run" in result.stdout
        assert not (sb.repo / "configs" / "multi_cluster_management.sh").exists()
        assert _mutating_podman(sb) == []
        assert "itz-a" in result.stdout and "itz-b" in result.stdout
        assert "service_id_credentials.txt" in result.stdout and "no longer visible" in result.stdout
        # Passwords stay out of the output.
        assert "secret" not in result.stdout and "secret" not in result.stderr


def test_rollback_dry_run_changes_nothing():
    with _sandbox() as sb:
        _add_fixture(sb)
        _migrate_unfinished(sb)
        before = _snapshot(sb.root)
        result = _run(sb, "--dry-run", "--rollback", check=True)
        assert "Dry run" in result.stdout and "undo:" in result.stdout
        assert _snapshot(sb.root) == before


# --- One way per cluster ------------------------------------------------------------------------------------------
def test_reverse_is_removed_with_a_one_way_error():
    with _sandbox() as sb:
        _add_fixture(sb)
        _run(sb, "--yes", check=True)
        before = _snapshot(sb.root)
        for args in (("--reverse", "itz-a", "--yes"), ("--reverse=itz-a", "--yes"), ("--dry-run", "--reverse", "itz-a")):
            result = _run(sb, *args)
            assert result.returncode == 2, args
            assert "--reverse was removed" in result.stderr and "one-way" in result.stderr, args
            assert "multi_cluster.sh remove" in result.stderr
        assert _snapshot(sb.root) == before
        assert (sb.repo / "configs/clusters/itz-a/cp4d_config/cpd_vars.sh").is_file()
        assert not (sb.repo / "configs/cp4d_config").exists()


def test_rollback_refuses_a_completed_migration():
    with _sandbox() as sb:
        _add_fixture(sb)
        sb.add_container("olm-utils-play-v4-itz-a")
        _run(sb, "--yes", check=True)
        before = _snapshot(sb.root)
        podman_before = _mutating_podman(sb)
        for args in (("--rollback", "--yes"), ("--rollback", "--dry-run")):
            result = _run(sb, *args)
            assert result.returncode == 1, args
            assert "is complete" in result.stderr and "final" in result.stderr and "one-way" in result.stderr
            assert "configs/old_configs/pre_multi_cluster_" in result.stderr
            assert "itz-a" in result.stderr and "itz-b" in result.stderr
            assert "undo:" not in result.stdout
        assert _snapshot(sb.root) == before
        assert _mutating_podman(sb) == podman_before
        assert sb.container("olm-utils-play-v4-itz-a") is not None
        state = _state(sb)
        assert state["MULTI_CLUSTER_MANAGEMENT"] == "true"
        assert set(state["MCM_CLUSTERS"].split()) == {"itz-a", "itz-b"}
        assert (sb.repo / "configs/clusters/itz-a/.cluster").is_file()


def test_rollback_after_a_rolled_back_run_still_refuses_the_completed_one():
    """Only the newest journal that was not rolled back counts, and a complete one is final."""
    with _sandbox() as sb:
        _add_fixture(sb)
        _run(sb, "--yes", check=True)
        sb.write_config("confluent", ocp_url=URL_A)
        # itz-a is registered already, so this run has no register step: it stops at its move.
        flag = _break_mv_on(sb, "confluent_platform_config")
        assert _run(sb, "--yes").returncode == 1
        flag.unlink()
        _run(sb, "--rollback", "--yes", check=True)
        assert (sb.repo / "configs/confluent_platform_config").is_dir()
        assert (sb.repo / "configs/clusters/itz-a/cp4d_config/cpd_vars.sh").is_file()
        result = _run(sb, "--rollback", "--yes")
        assert result.returncode == 1 and "is complete" in result.stderr


def test_plan_and_prompt_say_the_move_is_permanent():
    with _sandbox() as sb:
        _add_fixture(sb)
        dry = _run(sb, "--dry-run", check=True)
        for name in ("itz-a", "itz-b", "itz-k"):
            line = next(l for l in dry.stdout.splitlines() if l.startswith(f"  {name} "))
            assert "permanent" in line and "flat layout" in line, line
        warning = next(l for l in dry.stdout.splitlines() if "permanent for each cluster listed" in l)
        assert warning.startswith("[WARN] One way")
        for name in ("itz-a", "itz-b", "itz-k"):
            assert name in warning

        declined = _run(sb, stdin="n\n")
        assert declined.returncode == 0 and "Aborted" in declined.stdout
        prompt = next(l for l in declined.stdout.splitlines() if "Move these items now?" in l)
        assert "This is permanent for" in prompt and "never go back to the flat layout" in prompt
        for name in ("itz-a", "itz-b", "itz-k"):
            assert name in prompt
        assert (sb.repo / "configs/cp4d_config").is_dir()
        assert not (sb.repo / "configs/clusters").exists()

        done = _run(sb, "--yes", check=True)
        assert "This migration is final" in done.stdout
        assert "To undo" not in done.stdout
        assert "configs/old_configs/pre_multi_cluster_" in done.stdout


def test_journal_of_the_removed_reverse_is_refused():
    with _sandbox() as sb:
        _add_fixture(sb)
        journal_dir = sb.repo / "configs/old_configs/pre_reverse_itz-a_20260101_000000"
        journal_dir.mkdir(parents=True)
        (journal_dir / "migration_journal.tsv").write_text("meta\tkind\treverse\nstatus\tapplying\n")
        _run(sb, "--dry-run")
        before = _snapshot(sb.root)
        for args in (("--rollback", "--yes"), ("--yes",), ("--dry-run",)):
            result = _run(sb, *args)
            assert result.returncode == 1, args
            assert "--reverse, which was removed" in result.stderr, args
        # Only the state file a real run reads first may appear; nothing moves.
        after = {k: v for k, v in _snapshot(sb.root).items() if k not in ("repo/configs", "repo/configs/multi_cluster_management.sh")}
        assert after == {k: v for k, v in before.items() if k != "repo/configs"}
        assert (sb.repo / "configs/cp4d_config/cpd_vars.sh").is_file()
        assert not (sb.repo / "configs/clusters").exists()


def test_rollback_restores_a_marker_that_was_there_before():
    """A cluster delineated (here retired) before the migration stays delineated after the undo."""
    with _sandbox() as sb:
        _add_fixture(sb)
        marker = sb.repo / "configs/clusters/itz-b/.cluster"
        marker.parent.mkdir(parents=True)
        marker.write_text(
            f'NAME="itz-b"\nOCP_URL="{URL_B}"\nCREATED="2026-01-01T00:00:00Z"\nDELINEATED="true"\nRETIRED="true"\nNOTE="kept"\n'
        )
        original = marker.read_text()
        _run(sb, "--yes", check=True)
        assert 'RETIRED="true"' not in marker.read_text()  # registering unretires it
        _strip_complete(sb)
        _run(sb, "--rollback", "--yes", check=True)
        assert marker.read_text() == original
        assert (sb.repo / "configs/concert_config/concert_vars.sh").is_file()
        assert not (sb.repo / "configs/clusters/itz-a").exists()
        assert _state(sb)["MCM_CLUSTERS"] == ""


def test_dry_run_reports_a_refusal():
    with _sandbox() as sb:
        _add_fixture(sb)
        (sb.root / "ps.txt").write_text("  100 /Users/x/cpd-cli/cpd-cli manage login-to-ocp\n")
        before = _snapshot(sb.root)
        result = _run(sb, "--dry-run")
        assert result.returncode == 1
        assert "would refuse" in result.stderr
        assert "itz-a" in result.stdout  # the plan is still shown
        assert _snapshot(sb.root) == before


def test_two_cluster_split():
    with _sandbox() as sb:
        _add_fixture(sb)
        sb.add_container(FLAT)
        result = _run(sb, "--yes", check=True)

        a = sb.repo / "configs/clusters/itz-a"
        b = sb.repo / "configs/clusters/itz-b"
        assert (a / "cp4d_config/cpd_vars.sh").is_file()
        assert (a / "kubecost_config/kubecost_vars.sh").is_file()
        assert (b / "concert_config/concert_vars.sh").is_file()
        assert not (sb.repo / "configs/cp4d_config").exists()
        assert not (sb.repo / "configs/concert_config").exists()
        assert (a / "service_instances/instance.json").is_file()
        assert not (sb.repo / "service_instances").exists()
        assert (a / "cpd-cli-workspace/logs/run.log").is_file()
        assert (sb.repo / "cpd-cli-workspace/scale_config_cache/entry").is_file()
        assert (a / "kubecost_workspace/kc.txt").is_file()
        assert (b / "concert_workspace/run.txt").is_file()
        assert (a / "oadp/backup_bucket_configs/s3_bucket.sh").is_file()
        assert (a / "oadp/restore_target_configs/t_vars.sh").is_file()

        # Rendered Confluent and Flink folders move even without a Confluent config (they go with the CP4D cluster).
        assert (a / "confluent_platform_vars/rendered/kafka-secret.json").is_file()
        assert (a / "flink_vars/rendered/flink.yaml").is_file()

        # ~/cpd-cli/work moved, and the empty folder the flat layout needs stays.
        assert (sb.home / "cpd-cli/clusters/itz-a/work/offline/case.tgz").is_file()
        assert (sb.home / "cpd-cli/work").is_dir() and not list((sb.home / "cpd-cli/work").iterdir())
        assert (sb.home / "cpd-cli/clusters/itz-a/swhub-control-center/work/status.csv").is_file()
        assert (sb.home / "cpd-cli/m_backups/keep.txt").is_file()

        # registry_mirror_workspace is left alone without --mirror-state-to.
        assert (sb.repo / "registry_mirror_workspace/mirrored.txt").is_file()
        assert (sb.repo / "registry_mirror_workspace/tools/oc-mirror").is_file()

        state = _state(sb)
        assert state["MULTI_CLUSTER_MANAGEMENT"] == "true"
        assert set(state["MCM_CLUSTERS"].split()) == {"itz-a", "itz-b"}
        assert state["MCM_CURRENT_CLUSTER"] == "itz-a"
        assert (a / ".cluster").is_file() and (b / ".cluster").is_file()
        assert f'OCP_URL="{URL_A}"' in (a / ".cluster").read_text()
        assert 'DELINEATED="true"' in (a / ".cluster").read_text()

        # Progress on the main output as done/total.
        assert "[MCM] 1/" in result.stdout
        assert "secret" not in result.stdout

        # The flat container is gone, its image kept.
        assert sb.container(FLAT) is None
        assert ["rm", "-f", FLAT] in sb.calls("podman")


def test_backup_is_private_and_holds_configs():
    with _sandbox() as sb:
        _add_fixture(sb)
        _run(sb, "--yes", check=True)
        backups = list((sb.repo / "configs/old_configs").glob("pre_multi_cluster_*"))
        assert len(backups) == 1
        backup = backups[0]
        assert oct(backup.stat().st_mode)[-3:] == "700"
        assert (backup / "configs/cp4d_config/cpd_vars.sh").is_file()
        assert (backup / "configs/openshift_config/htpasswd_credentials.txt").is_file()
        assert (backup / "src/utilities/oadp_backup_restore_cp4d_utils/backup_bucket_configs/s3_bucket.sh").is_file()
        # work/ can be hundreds of GB: moved, never copied.
        assert not (backup / "cpd-cli").exists()
        assert (backup / "migration_journal.tsv").is_file()


def test_openshift_config_routing():
    with _sandbox() as sb:
        _add_fixture(sb)
        result = _run(sb, "--yes", check=True)
        a = sb.repo / "configs/clusters/itz-a/openshift_config"
        k = sb.repo / "configs/clusters/itz-k/openshift_config"

        assert (a / "htpasswd_credentials.txt").is_file()      # URL in its comment
        assert (a / "guest_admin_credentials.txt").is_file()   # no URL: with cp4d_config
        assert (a / "multi.txt").is_file()                     # several URLs: with cp4d_config
        assert "several cluster URLs" in result.stdout
        assert (k / "service_id_credentials.txt").is_file()    # comment URL only

        # itz-k holds no *_vars.sh: folder kept, not registered, no marker.
        state = _state(sb)
        assert "itz-k" not in state["MCM_CLUSTERS"].split()
        assert not (sb.repo / "configs/clusters/itz-k/.cluster").exists()
        assert not (sb.repo / "configs/openshift_config").exists()


def test_map_overrides_routing():
    with _sandbox() as sb:
        _add_fixture(sb)
        _run(sb, "--yes", "--map", "multi.txt=itz-b", "--map", "concert=itz-c", check=True)
        assert (sb.repo / "configs/clusters/itz-b/openshift_config/multi.txt").is_file()
        assert (sb.repo / "configs/clusters/itz-c/concert_config/concert_vars.sh").is_file()
        # concert_workspace follows its product when the product is mapped.
        assert (sb.repo / "configs/clusters/itz-c/concert_workspace/run.txt").is_file()
        assert "itz-c" in _state(sb)["MCM_CLUSTERS"].split()


def test_map_unknown_key_is_refused():
    with _sandbox() as sb:
        _add_fixture(sb)
        result = _run(sb, "--yes", "--map", "nonsense=itz-a")
        assert result.returncode != 0
        assert "--map nonsense" in result.stderr
        assert (sb.repo / "configs/cp4d_config/cpd_vars.sh").is_file()


def test_name_renames_primary_cluster():
    with _sandbox() as sb:
        _add_fixture(sb)
        _run(sb, "--yes", "--name", "prod", check=True)
        assert (sb.repo / "configs/clusters/prod/cp4d_config/cpd_vars.sh").is_file()
        assert (sb.repo / "configs/clusters/prod/kubecost_config/kubecost_vars.sh").is_file()
        assert (sb.repo / "configs/clusters/itz-b/concert_config/concert_vars.sh").is_file()
        assert _state(sb)["MCM_CURRENT_CLUSTER"] == "prod"


def test_invalid_name_is_refused():
    with _sandbox() as sb:
        _add_fixture(sb)
        result = _run(sb, "--yes", "--name", "Bad Name")
        assert result.returncode != 0
        assert (sb.repo / "configs/cp4d_config").is_dir()
        assert not (sb.repo / "configs/clusters").exists()


def test_config_without_url_needs_a_home():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("confluent", text='export SOMETHING_ELSE="x"\n')
        _run(sb, "--yes", check=True)
        assert (sb.repo / "configs/clusters/itz-a/confluent_platform_config/confluent_vars.sh").is_file()


def test_preflight_refuses_live_lease():
    with _sandbox() as sb:
        _add_fixture(sb)
        lease_dir = sb.home / "cpd-cli/clusters/itz-a/.leases"
        lease_dir.mkdir(parents=True)
        sleeper = subprocess.Popen(["/bin/sleep", "30"])
        try:
            (lease_dir / str(sleeper.pid)).write_text("")
            result = _run(sb, "--yes")
            assert result.returncode == 1
            assert "A run is live on cluster itz-a" in result.stderr
            assert (sb.repo / "configs/cp4d_config").is_dir()
            assert not (sb.repo / "configs/clusters").exists()
        finally:
            sleeper.kill()
            sleeper.wait()


def test_stale_lease_does_not_block():
    with _sandbox() as sb:
        _add_fixture(sb)
        lease_dir = sb.home / "cpd-cli/clusters/itz-a/.leases"
        lease_dir.mkdir(parents=True)
        done = subprocess.Popen(["/usr/bin/true"])
        done.wait()
        (lease_dir / str(done.pid)).write_text("")
        _run(sb, "--yes", check=True)
        assert (sb.repo / "configs/clusters/itz-a/cp4d_config").is_dir()


def test_preflight_refuses_running_cpd_cli_manage():
    with _sandbox() as sb:
        _add_fixture(sb)
        (sb.root / "ps.txt").write_text("  100 /Users/x/cpd-cli/cpd-cli manage login-to-ocp --server=x\n")
        result = _run(sb, "--yes")
        assert result.returncode == 1
        assert "cpd-cli manage is running" in result.stderr
        assert (sb.repo / "configs/cp4d_config").is_dir()


def test_preflight_sees_the_shim():
    with _sandbox() as sb:
        _add_fixture(sb)
        (sb.root / "ps.txt").write_text("  100 /bin/zsh -f /repo/src/helpers/multi_cluster_bin/cpd-cli manage apply-olm\n")
        result = _run(sb, "--yes")
        assert result.returncode == 1
        assert "cpd-cli manage is running" in result.stderr


def test_preflight_ignores_lookalike_processes():
    with _sandbox() as sb:
        _add_fixture(sb)
        editor = sb.bin / "vim"
        editor.write_text("#!/bin/zsh\n")
        editor.chmod(0o755)
        (sb.root / "ps.txt").write_text(
            f"  100 {editor} notes/cpd-cli manage plan.md\n"
            "  101 grep cpd-cli manage\n"
            "  102 /Users/x/cpd-cli/cpd-cli version\n"
        )
        _run(sb, "--yes", check=True)
        assert (sb.repo / "configs/clusters/itz-a/cp4d_config").is_dir()


def test_preflight_refuses_busy_container():
    with _sandbox() as sb:
        _add_fixture(sb)
        sb.add_container(FLAT)
        _scan_rule(sb, "self 99\n1 0 /bin/sh /entry.sh\n200 1 ansible-playbook apply-cr.yml\n")
        result = _run(sb, "--yes")
        assert result.returncode == 1
        assert "busy" in result.stderr
        assert sb.container(FLAT) is not None
        assert (sb.repo / "configs/cp4d_config").is_dir()


def test_idle_container_is_removed():
    with _sandbox() as sb:
        _add_fixture(sb)
        sb.add_container(FLAT)
        _scan_rule(sb, SCAN_IDLE + "60 1 /usr/bin/registry serve /etc/registry.yml\n")
        _run(sb, "--yes", check=True)
        assert sb.container(FLAT) is None


def test_preflight_uses_the_shared_idle_list():
    """One list: a process the shared scan counts as a job refuses the migration too."""
    with _sandbox() as sb:
        _add_fixture(sb)
        sb.add_container(FLAT)
        _scan_rule(sb, SCAN_IDLE + "50 1 sleep infinity\n")
        result = _run(sb, "--yes")
        assert result.returncode == 1
        assert "busy" in result.stderr and "sleep infinity" in result.stderr
        assert (sb.repo / "configs/cp4d_config").is_dir()


def test_scan_that_returns_no_data_counts_as_busy():
    with _sandbox() as sb:
        _add_fixture(sb)
        sb.add_container(FLAT)
        _scan_rule(sb, "")
        result = _run(sb, "--yes")
        assert result.returncode == 1 and "no data" in result.stderr
        assert sb.container(FLAT) is not None


def test_dry_run_with_a_container_writes_no_scan_log():
    with _sandbox() as sb:
        _add_fixture(sb)
        sb.add_container(FLAT)
        _run(sb, "--dry-run", check=True)
        assert not list((sb.home / "cpd-cli").glob("clusters/**/.scans"))


def test_container_turning_busy_late_is_kept():
    """Preflight idle, busy at removal time: the migration finishes and the container stays."""
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.add_container(FLAT)
        # The first scan is preflight; a marker file makes the later one report a job.
        script = sb.bin / "podman"
        original = script.read_text()
        real_dir = sb.root / "real_podman"
        real_dir.mkdir()
        # The fake picks its behaviour from its own file name, so the copy must still be called podman.
        wrapper = real_dir / "podman"
        wrapper.write_text(original)
        wrapper.chmod(0o755)
        counter = sb.root / "scans"
        script.write_text(f"""#!/bin/zsh
if [[ "${{1:-}}" == exec ]]; then
    if [[ -e "{counter}" ]]; then
        print -r -- "self 8"
        print -r -- "1 0 /bin/sh"
        print -r -- "9 1 ansible-playbook apply-cr.yml"
        exit 0
    fi
    : > "{counter}"
fi
exec "{wrapper}" "$@"
""")
        script.chmod(0o755)
        result = _run(sb, "--yes", check=True)
        assert sb.container(FLAT) is not None
        assert "became busy" in result.stdout
        assert _state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"


def test_podman_unreachable_warns_and_finishes():
    with _sandbox() as sb:
        _add_fixture(sb)
        sb.add_container(FLAT)
        sb.set_podman_reachable(False)
        result = _run(sb, "--yes", check=True)
        assert "podman rm -f olm-utils-play-v4" in result.stdout
        assert (sb.repo / "configs/clusters/itz-a/cp4d_config").is_dir()
        assert _state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"
        assert not any(c[:1] == ["machine"] and c[1:2] == ["start"] for c in sb.calls("podman"))


def test_confirmation_declined_changes_nothing():
    with _sandbox() as sb:
        _add_fixture(sb)
        result = _run(sb, stdin="n\n")
        assert result.returncode == 0
        assert "Aborted" in result.stdout
        assert (sb.repo / "configs/cp4d_config").is_dir()
        assert not list((sb.repo / "configs").glob("old_configs/pre_multi_cluster_*"))


def test_no_answer_without_yes_refuses():
    with _sandbox() as sb:
        _add_fixture(sb)
        result = _run(sb)
        assert result.returncode == 1
        assert "--yes" in result.stderr
        assert (sb.repo / "configs/cp4d_config").is_dir()


def test_confirmation_accepted_runs():
    with _sandbox() as sb:
        _add_fixture(sb)
        _run(sb, stdin="y\n", check=True)
        assert (sb.repo / "configs/clusters/itz-a/cp4d_config").is_dir()


def test_conflict_refuses_before_moving_anything():
    with _sandbox() as sb:
        _add_fixture(sb)
        existing = sb.repo / "configs/clusters/itz-a/cp4d_config"
        existing.mkdir(parents=True)
        (existing / "cpd_vars.sh").write_text('export OCP_URL="x"\n')
        result = _run(sb, "--yes")
        assert result.returncode == 1
        assert "will not overwrite" in result.stderr
        assert (sb.repo / "configs/cp4d_config").is_dir()
        assert (sb.repo / "configs/kubecost_config").is_dir()
        assert not list((sb.repo / "configs").glob("old_configs/pre_multi_cluster_*"))


def _break_mv_on(sb, marker):
    """Makes mv fail when an argument contains marker, while the file sb.root/mv_fail exists."""
    flag = sb.root / "mv_fail"
    flag.write_text("")
    fake = sb.bin / "mv"
    fake.write_text(f"""#!/bin/zsh
if [[ -e "{flag}" && "$*" == *{marker}* ]]; then
    echo "mv: simulated failure" >&2
    exit 1
fi
exec /bin/mv "$@"
""")
    fake.chmod(0o755)
    return flag


def test_resume_after_midway_failure():
    with _sandbox() as sb:
        _add_fixture(sb)
        flag = _break_mv_on(sb, "kubecost_config")
        failed = _run(sb, "--yes")
        assert failed.returncode == 1
        assert "failed" in failed.stderr
        assert "--rollback" in failed.stderr
        # Finished entries are in place, the failed one and those after it are not.
        assert (sb.repo / "configs/clusters/itz-b/concert_config").is_dir()
        assert (sb.repo / "configs/kubecost_config").is_dir()
        assert (sb.repo / "configs/service_instances").exists() is False

        flag.unlink()
        journal = next((sb.repo / "configs/old_configs").glob("pre_multi_cluster_*/migration_journal.tsv"))
        backups_before = {p.name for p in (sb.repo / "configs/old_configs").iterdir()}
        resumed = _run(sb, "--yes", check=True)
        assert "Continuing" in resumed.stdout
        assert "already done" in resumed.stdout
        assert (sb.repo / "configs/clusters/itz-a/kubecost_config/kubecost_vars.sh").is_file()
        assert (sb.repo / "configs/clusters/itz-b/concert_config/concert_vars.sh").is_file()
        assert (sb.home / "cpd-cli/clusters/itz-a/work/offline/case.tgz").is_file()
        assert _state(sb)["MULTI_CLUSTER_MANAGEMENT"] == "true"
        assert {p.name for p in (sb.repo / "configs/old_configs").iterdir()} == backups_before
        assert "status\tcomplete" in journal.read_text()


def test_rollback_restores_flat_layout():
    with _sandbox() as sb:
        _add_fixture(sb)
        sb.add_container("olm-utils-play-v4-itz-a")
        _migrate_unfinished(sb)
        result = _run(sb, "--rollback", "--yes", check=True)
        assert "[MCM] 1/" in result.stdout

        assert (sb.repo / "configs/cp4d_config/cpd_vars.sh").is_file()
        assert (sb.repo / "configs/concert_config/concert_vars.sh").is_file()
        assert (sb.repo / "configs/openshift_config/service_id_credentials.txt").is_file()
        assert (sb.repo / "service_instances/instance.json").is_file()
        assert (sb.repo / "cpd-cli-workspace/logs/run.log").is_file()
        assert (sb.home / "cpd-cli/work/offline/case.tgz").is_file()
        assert (sb.home / "cpd-cli-swhub-control-center/work/status.csv").is_file()
        assert (sb.repo / "src/utilities/oadp_backup_restore_cp4d_utils/backup_bucket_configs/s3_bucket.sh").is_file()
        assert (sb.repo / "scripts/install_confluent_platform/confluent_platform_vars/rendered/kafka-secret.json").is_file()

        # Cluster folders are gone, and with them the markers and registrations.
        assert not (sb.repo / "configs/clusters").exists()
        assert not (sb.home / "cpd-cli/clusters").exists()
        state = _state(sb)
        assert state["MULTI_CLUSTER_MANAGEMENT"] == "false"
        assert state["MCM_CLUSTERS"] == ""
        assert state["MCM_CURRENT_CLUSTER"] == ""
        # A per-cluster container's bind mount is gone too.
        assert sb.container("olm-utils-play-v4-itz-a") is None


def test_rollback_of_interrupted_migration():
    with _sandbox() as sb:
        _add_fixture(sb)
        flag = _break_mv_on(sb, "kubecost_config")
        assert _run(sb, "--yes").returncode == 1
        flag.unlink()
        _run(sb, "--rollback", "--yes", check=True)
        assert (sb.repo / "configs/concert_config/concert_vars.sh").is_file()
        assert (sb.repo / "configs/kubecost_config/kubecost_vars.sh").is_file()
        assert not (sb.repo / "configs/clusters").exists()


def test_rollback_refuses_new_content_at_original_place():
    with _sandbox() as sb:
        _add_fixture(sb)
        _migrate_unfinished(sb)
        journal_before = _journal(sb).read_text()
        (sb.home / "cpd-cli/work/new.txt").write_text("written after migration")
        result = _run(sb, "--rollback", "--yes")
        assert result.returncode == 1
        assert "new content" in result.stderr
        # Nothing was undone.
        assert (sb.repo / "configs/clusters/itz-a/cp4d_config").is_dir()
        assert _journal(sb).read_text() == journal_before


def test_rollback_without_journal_fails():
    with _sandbox() as sb:
        result = _run(sb, "--rollback", "--yes")
        assert result.returncode == 1
        assert "No migration journal" in result.stderr


def test_rollback_keeps_changed_profiles_copy():
    with _sandbox() as sb:
        _add_fixture(sb)
        _migrate_unfinished(sb)
        copy = sb.repo / "configs/clusters/itz-a/.home/.cpd-cli/config"
        copy.write_text("profiles: {changed: true}\n")
        result = _run(sb, "--rollback", "--yes", check=True)
        assert "Keeping" in result.stdout
        assert copy.read_text() == "profiles: {changed: true}\n"


def test_cpd_cli_profiles_copied_not_moved():
    with _sandbox() as sb:
        _add_fixture(sb)
        _run(sb, "--yes", check=True)
        original = sb.home / ".cpd-cli/config"
        copy = sb.repo / "configs/clusters/itz-a/.home/.cpd-cli/config"
        assert original.read_text() == copy.read_text()
        assert oct(copy.stat().st_mode)[-3:] == "600"


def test_kube_config_seeded_per_cluster_without_touching_original():
    with _sandbox() as sb:
        _add_fixture(sb)
        kube = _fake_oc_with_kubeconfig(sb)
        before = (kube.read_bytes(), kube.stat().st_mtime_ns)
        _run(sb, "--yes", check=True)
        assert (kube.read_bytes(), kube.stat().st_mtime_ns) == before

        seeded_a = sb.repo / "configs/clusters/itz-a/.home/.kube/config"
        seeded_b = sb.repo / "configs/clusters/itz-b/.home/.kube/config"
        assert "--context=admin-a" in seeded_a.read_text()
        assert "--context=ctx-b" in seeded_b.read_text()
        assert oct(seeded_a.stat().st_mode)[-3:] == "600"
        assert oct(seeded_a.parent.stat().st_mode)[-3:] == "700"
        # No context for this one: nothing to seed.
        assert not (sb.repo / "configs/clusters/itz-k/.home").exists()


def test_seed_failure_is_only_a_warning():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        _fake_oc_with_kubeconfig(sb)
        oc = sb.bin / "oc"
        oc.write_text(oc.read_text().replace('"config view"*) print -r -- "kubeconfig-for: $*"; exit 0 ;;', '"config view"*) exit 1 ;;'))
        result = _run(sb, "--yes", check=True)
        assert "Could not extract context" in result.stdout
        assert not (sb.repo / "configs/clusters/itz-a/.home/.kube/config").exists()


def test_truststore_rewritten_by_migrate_and_rollback():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("confluent", ocp_url=URL_A)
        flat = sb.repo / "configs/confluent_platform_config"
        clients = flat / "confluent_sasl_clients.properties"
        clients.write_text(
            "security.protocol=SASL_SSL\n"
            f"ssl.truststore.location={flat}/confluent_kafka_internal_ca.crt\n"
            f"listener.name.x.ssl.truststore.location={flat}/other.crt\n"
            "ssl.truststore.location=/somewhere/else/ca.crt\n"
        )
        clients.chmod(0o640)

        _migrate_unfinished(sb)
        cluster_dir = sb.repo / "configs/clusters/itz-a/confluent_platform_config"
        text = (cluster_dir / "confluent_sasl_clients.properties").read_text()
        assert f"ssl.truststore.location={cluster_dir}/confluent_kafka_internal_ca.crt" in text
        assert f"listener.name.x.ssl.truststore.location={cluster_dir}/other.crt" in text
        assert "ssl.truststore.location=/somewhere/else/ca.crt" in text
        assert oct((cluster_dir / "confluent_sasl_clients.properties").stat().st_mode)[-3:] == "640"

        _run(sb, "--rollback", "--yes", check=True)
        text = clients.read_text()
        assert f"ssl.truststore.location={flat}/confluent_kafka_internal_ca.crt" in text
        assert f"listener.name.x.ssl.truststore.location={flat}/other.crt" in text
        assert "ssl.truststore.location=/somewhere/else/ca.crt" in text

        # A second migration, completed this time.
        _run(sb, "--yes", check=True)
        text = (cluster_dir / "confluent_sasl_clients.properties").read_text()
        assert f"ssl.truststore.location={cluster_dir}/confluent_kafka_internal_ca.crt" in text


def test_mirror_state_to_assigns_destination():
    with _sandbox() as sb:
        _add_fixture(sb)
        ws = sb.repo / "registry_mirror_workspace"
        (ws / "local-registry").mkdir()
        (ws / "local-registry/state.env").write_text("x")
        (ws / "cluster/mirror-sets").mkdir(parents=True)
        (ws / "cluster/mirror-sets/idms.yaml").write_text("a: 1")
        (ws / "cpd").mkdir()
        (ws / "cpd/targets.tsv").write_text("t")
        _migrate_unfinished(sb, "--mirror-state-to", "registry.example.com:5000/cp")

        key = ws / "registries" / "registry.example.com_5000+cp"
        assert (key / "mirrored.txt").is_file()
        assert (key / "cpd/targets.tsv").is_file()
        assert (ws / "tools/oc-mirror").is_file()
        assert (ws / "local-registry/state.env").is_file()
        assert (sb.repo / "configs/clusters/itz-a/registry_mirror_cluster/mirror-sets/idms.yaml").is_file()

        _run(sb, "--rollback", "--yes", check=True)
        assert (ws / "mirrored.txt").is_file()
        assert (ws / "cpd/targets.tsv").is_file()
        assert (ws / "cluster/mirror-sets/idms.yaml").is_file()
        assert not (ws / "registries").exists()


def test_nothing_to_migrate():
    with _sandbox() as sb:
        result = _run(sb, "--yes", check=True)
        assert "Nothing to migrate" in result.stdout
        assert not (sb.repo / "configs/clusters").exists()


def test_invalid_state_file_stops_the_run():
    with _sandbox() as sb:
        _add_fixture(sb)
        (sb.repo / "configs/multi_cluster_management.sh").write_text('export MULTI_CLUSTER_MANAGEMENT="sometimes"\n')
        result = _run(sb, "--yes")
        assert result.returncode != 0
        assert "MULTI_CLUSTER_MANAGEMENT" in result.stderr
        assert (sb.repo / "configs/cp4d_config").is_dir()


def test_config_with_unset_variables_and_exit_is_survivable():
    """Sourcing happens in a subshell: a config using unset names or calling exit must not kill the run."""
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("kubecost", text=f'export OCP_URL="{URL_A}"\nprint -r -- "${{NOT_SET_ANYWHERE}}"\nfalse\n')
        sb.write_config("concert", text=f'export OCP_URL="{URL_B}"\nexit 3\n')
        _run(sb, "--dry-run", check=True)


def test_ocp_url_in_environment_does_not_leak_into_detection():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("confluent", text='export SOMETHING="x"\n')
        result = subprocess.run(
            ["zsh", str(sb.repo / SCRIPT), "--dry-run"], cwd=sb.repo,
            env={**sb.env(), "OCP_URL": URL_B}, capture_output=True, text=True, timeout=60, check=False,
        )
        assert result.returncode == 0, result.stderr
        assert "itz-b" not in result.stdout


# ---- Regressions from the P7 review ------------------------------------------------------


def _kill_on(sb, tool, pattern, nth=1, before=""):
    """kill -9 the whole run the nth time TOOL's arguments match the zsh pattern. Needs _run_killed."""
    armed = sb.root / f"kill_{tool}.armed"
    counter = sb.root / f"kill_{tool}.count"
    armed.write_text("")
    real = shutil.which(tool, path="/usr/bin:/bin")
    fake = sb.bin / tool
    fake.write_text(f"""#!/bin/zsh
if [[ -e "{armed}" && "$*" == {pattern} ]]; then
    print -n x >> "{counter}"
    if (( $(wc -c < "{counter}") >= {nth} )); then
        rm -f "{armed}"
        {before}
        kill -9 0
    fi
fi
exec "{real}" "$@"
""")
    fake.chmod(0o755)


def _run_killed(sb, *args):
    """Runs in its own process group, so 'kill -9 0' from a fake tool stops only the run."""
    result = subprocess.run(
        ["zsh", str(sb.repo / SCRIPT), *args], cwd=sb.repo, env=sb.env(), capture_output=True, text=True,
        timeout=120, input="", start_new_session=True, check=False,
    )
    assert result.returncode == -9, result.stdout + result.stderr
    return result


def _journal(sb, glob="pre_*"):
    return max((sb.repo / "configs/old_configs").glob(f"{glob}/migration_journal.tsv"))


def _mode(path):
    return oct(path.stat().st_mode)[-3:]


def test_openshift_config_folder_mode_kept_by_migrate_and_rollback():
    with _sandbox() as sb:
        _add_fixture(sb)
        flat = sb.repo / "configs/openshift_config"
        flat.chmod(0o700)
        (flat / "htpasswd_credentials.txt").chmod(0o644)
        _migrate_unfinished(sb)
        assert _mode(sb.repo / "configs/clusters/itz-a/openshift_config") == "700"
        assert _mode(sb.repo / "configs/clusters/itz-k/openshift_config") == "700"
        assert not list(flat.iterdir())
        _run(sb, "--rollback", "--yes", check=True)
        assert _mode(flat) == "700"
        assert (flat / "htpasswd_credentials.txt").is_file()


def test_collision_when_name_targets_another_clusters_name():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("concert", ocp_url=URL_B)
        result = _run(sb, "--yes", "--name", "itz-b")
        assert result.returncode == 1
        assert URL_A in result.stderr and URL_B in result.stderr and "--map" in result.stderr
        assert (sb.repo / "configs/cp4d_config").is_dir()
        assert not (sb.repo / "configs/clusters").exists()


def test_collision_when_two_urls_derive_one_name():
    east, west = "https://api.prod.east.example.com:6443", "https://api.prod.west.example.com:6443"
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=east)
        sb.write_config("concert", ocp_url=west)
        result = _run(sb, "--dry-run")
        assert result.returncode == 1
        assert east in result.stderr and west in result.stderr and "--map" in result.stderr


def test_collision_url_forms_of_one_cluster_are_not_a_collision():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("kubecost", ocp_url="HTTPS://API.itz-a.example.com:6443/")
        _run(sb, "--dry-run", check=True)


def test_collision_with_an_existing_marker():
    other = "https://api.itz-a.another.example.com:6443"
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_cluster_marker("itz-a", url=other)
        result = _run(sb, "--yes")
        assert result.returncode == 1
        assert URL_A in result.stderr and other in result.stderr and "--map" in result.stderr
        assert (sb.repo / "configs/cp4d_config").is_dir()


def test_collision_can_be_overridden_only_by_map():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("concert", ocp_url=URL_B)
        _run(sb, "--yes", "--map", "concert=itz-a", check=True)
        cluster = sb.repo / "configs/clusters/itz-a"
        assert (cluster / "concert_config/concert_vars.sh").is_file()
        assert (cluster / "cp4d_config/cpd_vars.sh").is_file()
        # The marker keeps the URL of the item that belongs there, whatever the order.
        assert f'OCP_URL="{URL_A}"' in (cluster / ".cluster").read_text()


def test_map_onto_marked_cluster_keeps_the_marker_url():
    other = "https://api.itz-z.example.com:6443"
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_cluster_marker("itz-z", url=other)
        _run(sb, "--yes", "--map", "cp4d=itz-z", check=True)
        assert f'OCP_URL="{other}"' in (sb.repo / "configs/clusters/itz-z/.cluster").read_text()


def test_second_run_has_nothing_to_do():
    with _sandbox() as sb:
        _add_fixture(sb)
        _run(sb, "--yes", check=True)
        second = _run(sb, "--yes", check=True)
        assert "Nothing to migrate" in second.stdout
        dry = _run(sb, "--dry-run", check=True)
        assert "Nothing to migrate" in dry.stdout


def test_second_run_one_cluster():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        (sb.home / ".cpd-cli").mkdir()
        (sb.home / ".cpd-cli/config").write_text("profiles: {}\n")
        _run(sb, "--yes", check=True)
        assert "Nothing to migrate" in _run(sb, "--yes", check=True).stdout


def test_profiles_still_need_a_cluster_when_other_moves_are_planned():
    with _sandbox() as sb:
        sb.write_config("kubecost", ocp_url=URL_A)
        sb.write_config("concert", ocp_url=URL_B)
        (sb.home / ".cpd-cli").mkdir()
        (sb.home / ".cpd-cli/config").write_text("profiles: {}\n")
        result = _run(sb, "--dry-run")
        assert result.returncode == 1
        assert "No cluster for cpd-cli-profiles" in result.stderr


def test_every_map_value_is_validated():
    bad = (
        ("oadp=../../outside", "--yes"),
        ("service_instances=Not A Name", "--dry-run"),
        ("cpd-cli-work=old_configs", "--dry-run"),
        ("cpd-cli-profiles=x_config", "--dry-run"),
        ("kubecost_workspace=my_workspace", "--dry-run"),
    )
    with _sandbox() as sb:
        _add_fixture(sb)
        before = _snapshot(sb.repo)
        for spec, mode in bad:
            with_subtest = _run(sb, mode, "--map", spec)
            assert with_subtest.returncode != 0, spec
            assert "Invalid cluster name" in with_subtest.stderr, spec
        assert _snapshot(sb.repo) == before
        assert not (sb.repo / "outside").exists()


def test_comment_urls_that_are_not_cluster_endpoints_are_ignored():
    docs = "https://docs.redhat.com/en/documentation"
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        openshift = sb.repo / "configs/openshift_config"
        openshift.mkdir()
        (openshift / "docs.txt").write_text(f"# procedure: {docs}\nu:p\n")
        (openshift / "route.txt").write_text("# Software Hub on https://cpd.custom-domain.example.com\nu:p\n")
        (openshift / "web_port.txt").write_text("# console at https://portal.example.com:443\nu:p\n")
        (openshift / "api_path.txt").write_text("# see https://api.github.com/repos/x/y\nu:p\n")
        (openshift / "both.txt").write_text(f"# login on {URL_K}\n# procedure: {docs}\nu:p\n")
        (openshift / "roks.txt").write_text("# login on https://c100-e.us-south.containers.cloud.ibm.com:31234\nu:p\n")
        result = _run(sb, "--yes", check=True)

        root = sb.repo / "configs/clusters"
        assert not (root / "docs").exists() and not (root / "portal").exists() and not (root / "cpd").exists()
        for name in ("docs.txt", "route.txt", "web_port.txt", "api_path.txt"):
            assert (root / "itz-a/openshift_config" / name).is_file(), name
        assert (root / "itz-k/openshift_config/both.txt").is_file()
        assert (root / "c100-e/openshift_config/roks.txt").is_file()
        assert "several cluster URLs" not in result.stdout


def test_cp_step_is_atomic_across_a_kill():
    with _sandbox() as sb:
        _add_fixture(sb)
        _kill_on(sb, "cp", "*.home/.cpd-cli/config.mcm-partial", before='print -rn -- pro > "${@[-1]}"')
        _run_killed(sb, "--yes")
        copy = sb.repo / "configs/clusters/itz-a/.home/.cpd-cli/config"
        assert not copy.exists()  # never a truncated file under the real name
        _run(sb, "--yes", check=True)
        assert copy.read_text() == (sb.home / ".cpd-cli/config").read_text()
        assert not copy.with_name("config.mcm-partial").exists()
        assert "status\tcomplete" in _journal(sb).read_text()


def test_rollback_keeps_a_changed_seeded_kubeconfig():
    with _sandbox() as sb:
        _add_fixture(sb)
        _fake_oc_with_kubeconfig(sb)
        _migrate_unfinished(sb)
        seeded = sb.repo / "configs/clusters/itz-a/.home/.kube/config"
        seeded.write_text("a newer session\n")
        result = _run(sb, "--rollback", "--yes", check=True)
        assert "Keeping" in result.stdout
        assert seeded.read_text() == "a newer session\n"


def test_rollback_removes_an_unchanged_seeded_kubeconfig():
    with _sandbox() as sb:
        _add_fixture(sb)
        _fake_oc_with_kubeconfig(sb)
        _migrate_unfinished(sb)
        seeded = sb.repo / "configs/clusters/itz-a/.home/.kube/config"
        assert seeded.is_file()
        _run(sb, "--rollback", "--yes", check=True)
        assert not seeded.exists()


def test_keep_folder_recreated_when_killed_between_mv_and_mkdir():
    with _sandbox() as sb:
        _add_fixture(sb)
        _kill_on(sb, "mkdir", "\"-p \"*/cpd-cli/work")
        _run_killed(sb, "--yes")
        work = sb.home / "cpd-cli/work"
        assert not work.exists()  # the kill landed where intended
        _run(sb, "--yes", check=True)
        assert work.is_dir() and not list(work.iterdir())
        assert (sb.home / "cpd-cli/clusters/itz-a/work/offline/case.tgz").is_file()
        assert "status\tcomplete" in _journal(sb).read_text()


def test_preflight_sees_cpd_cli_in_a_path_with_a_space():
    with _sandbox() as sb:
        _add_fixture(sb)
        (sb.root / "ps.txt").write_text("  100 /Users/a b/cpd-cli/cpd-cli manage login-to-ocp\n")
        result = _run(sb, "--dry-run")
        assert result.returncode == 1
        assert "cpd-cli manage is running" in result.stderr


def test_preflight_sees_manage_k8s_and_shim_in_a_path_with_a_space():
    with _sandbox() as sb:
        _add_fixture(sb)
        (sb.root / "ps.txt").write_text(
            "  100 /Users/a b/cpd-cli/cpd-cli manage-k8s apply-cr\n"
            "  101 /bin/zsh -f /Users/a b/repo/src/helpers/multi_cluster_bin/cpd-cli manage apply-olm\n"
        )
        result = _run(sb, "--dry-run")
        assert result.returncode == 1
        assert result.stderr.count("cpd-cli manage is running") == 2


def test_preflight_ignores_a_script_that_only_names_cpd_cli():
    with _sandbox() as sb:
        _add_fixture(sb)
        script = sb.bin / "wrapper.sh"
        script.write_text("#!/bin/zsh\n")
        script.chmod(0o755)
        (sb.root / "ps.txt").write_text(
            f"  100 /bin/zsh {script} cpd-cli manage notes\n"
            f"  101 {script} docs/cpd-cli manage notes\n"
        )
        _run(sb, "--dry-run", check=True)


def test_dry_run_reports_a_forward_conflict():
    with _sandbox() as sb:
        _add_fixture(sb)
        existing = sb.repo / "configs/clusters/itz-a/cp4d_config"
        existing.mkdir(parents=True)
        (existing / "cpd_vars.sh").write_text('export OCP_URL="x"\n')
        before = _snapshot(sb.repo)
        result = _run(sb, "--dry-run", "--yes")
        assert result.returncode == 1
        assert "will not overwrite" in result.stderr and "would refuse" in result.stderr
        assert _snapshot(sb.repo) == before


def test_dry_run_reports_a_rollback_conflict():
    with _sandbox() as sb:
        _add_fixture(sb)
        _migrate_unfinished(sb)
        (sb.home / "cpd-cli/work/new.txt").write_text("written after migration")
        result = _run(sb, "--dry-run", "--rollback", "--yes")
        assert result.returncode == 1
        assert "new content" in result.stderr and "would refuse" in result.stderr


# --- A Finder .DS_Store is never an item --------------------------------------------------------------------------
def test_ds_store_in_the_kept_flat_workspace_is_not_an_item():
    with _sandbox() as sb:
        _add_fixture(sb)
        _run(sb, "--yes", check=True)
        (sb.repo / "cpd-cli-workspace/.DS_Store").write_text("finder")
        result = _run(sb, "--dry-run")
        assert result.returncode == 0, result.stdout + result.stderr
        assert "No cluster for" not in result.stderr


def test_ds_store_does_not_travel_and_does_not_block_rollback():
    with _sandbox() as sb:
        _add_fixture(sb)
        (sb.repo / "cpd-cli-workspace/.DS_Store").write_text("finder")
        _migrate_unfinished(sb)
        cluster = sb.repo / "configs/clusters/itz-a"
        assert not (cluster / "cpd-cli-workspace/.DS_Store").exists()
        # Finder opened all of these since.
        (cluster / "cpd-cli-workspace/.DS_Store").write_text("finder")
        (cluster / "openshift_config/.DS_Store").write_text("finder")
        (sb.repo / "cpd-cli-workspace/.DS_Store").write_text("finder")
        result = _run(sb, "--rollback", "--yes")
        assert result.returncode == 0, result.stdout + result.stderr
        assert (sb.repo / "cpd-cli-workspace/logs/run.log").is_file()
        assert (sb.repo / "configs/openshift_config/htpasswd_credentials.txt").is_file()
        assert not (sb.repo / "configs/openshift_config/.DS_Store").exists()


def test_ds_store_in_flat_openshift_config_is_not_routed():
    with _sandbox() as sb:
        _add_fixture(sb)
        flat = sb.repo / "configs/openshift_config"
        (flat / ".DS_Store").write_text("finder")
        _run(sb, "--yes", check=True)
        assert not (sb.repo / "configs/clusters/itz-a/openshift_config/.DS_Store").exists()
        assert not flat.exists()  # the folder still goes, past its .DS_Store
        flat.mkdir()
        (flat / ".DS_Store").write_text("finder")
        result = _run(sb, "--dry-run")
        assert result.returncode == 0, result.stdout + result.stderr
        assert "No cluster for" not in result.stderr


def test_ds_store_is_not_assigned_to_a_registry():
    with _sandbox() as sb:
        _add_fixture(sb)
        (sb.repo / "registry_mirror_workspace/.DS_Store").write_text("finder")
        _run(sb, "--yes", "--mirror-state-to", "registry.example.com:5000/cp", check=True)
        assert (sb.repo / "registry_mirror_workspace/.DS_Store").is_file()
        assert list((sb.repo / "registry_mirror_workspace/registries").glob("*/.DS_Store")) == []


# --- OCP_URL is read with per-command switches cleared -------------------------------------------------------------
CONCERT_WITH_SWITCH = f'''export OCP_URL="{URL_B}"
if [[ -n "${{CONCERT_TARGET_OC_LOGIN:-}}" ]]; then
    export OC_LOGIN="${{CONCERT_TARGET_OC_LOGIN}}"
    export OCP_URL=""
fi
'''


def test_an_exported_target_login_cannot_blank_ocp_url():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("concert", text=CONCERT_WITH_SWITCH)
        result = _run(sb, "--yes", env_extra={"CONCERT_TARGET_OC_LOGIN": "oc login https://api.hub.example.com:6443"})
        assert result.returncode == 0, result.stdout + result.stderr
        assert "concert_config has no OCP_URL" not in result.stdout
        assert (sb.repo / "configs/clusters/itz-b/concert_config/concert_vars.sh").is_file()


# --- A live script of this checkout holds no lease, so the preflight looks for it ----------------------------------
def _repo_script(sb, rel):
    path = sb.repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/zsh\n")
    path.chmod(0o755)
    return path


def test_preflight_refuses_a_live_script_of_this_checkout():
    with _sandbox() as sb:
        path = _repo_script(sb, "scripts/inst/1.1_step.sh")
        (sb.root / "ps_tree.txt").write_text(f"  200     1 /bin/zsh {path} --flag\n")
        result = _run(sb, "--preflight-only")
        assert result.returncode == 1
        assert "pid 200: scripts/inst/1.1_step.sh" in result.stderr


def test_preflight_refuses_a_live_script_under_src_utilities():
    with _sandbox() as sb:
        path = _repo_script(sb, "src/utilities/some_utils/do_it.sh")
        (sb.root / "ps_tree.txt").write_text(f"  200     1 zsh {path}\n")
        result = _run(sb, "--preflight-only")
        assert result.returncode == 1
        assert "src/utilities/some_utils/do_it.sh" in result.stderr


def test_preflight_names_each_script_once():
    with _sandbox() as sb:
        path = _repo_script(sb, "scripts/inst/1.1_step.sh")
        # A forked subshell shows the same command line.
        (sb.root / "ps_tree.txt").write_text(f"  200 1 /bin/zsh {path}\n  201 200 /bin/zsh {path}\n")
        result = _run(sb, "--preflight-only")
        assert result.returncode == 1
        assert result.stderr.count("scripts/inst/1.1_step.sh") == 1


def test_preflight_sees_a_script_path_with_a_space_and_options():
    with _sandbox() as sb:
        path = _repo_script(sb, "scripts/my dir/1.1_step.sh")
        (sb.root / "ps_tree.txt").write_text(f"  200 1 /bin/zsh -o errexit -f {path} arg\n")
        result = _run(sb, "--preflight-only")
        assert result.returncode == 1
        assert "scripts/my dir/1.1_step.sh" in result.stderr


def test_preflight_resolves_a_relative_script_from_the_process_folder():
    with _sandbox() as sb:
        _repo_script(sb, "scripts/inst/1.1_step.sh")
        (sb.root / "ps_tree.txt").write_text("  200 1 /bin/zsh ./1.1_step.sh\n")
        (sb.root / "lsof.txt").write_text(f"p200\nfcwd\nn{sb.repo}/scripts/inst\n")
        result = _run(sb, "--preflight-only")
        assert result.returncode == 1
        assert "pid 200: scripts/inst/1.1_step.sh" in result.stderr


def test_preflight_ignores_a_relative_script_of_another_checkout():
    with _sandbox() as sb:
        _repo_script(sb, "scripts/inst/1.1_step.sh")
        other = sb.root / "other/scripts/inst"
        other.mkdir(parents=True)
        (other / "1.1_step.sh").write_text("#!/bin/zsh\n")
        (sb.root / "ps_tree.txt").write_text("  200 1 /bin/zsh ./1.1_step.sh\n")
        (sb.root / "lsof.txt").write_text(f"p200\nfcwd\nn{other}\n")
        _run(sb, "--preflight-only", check=True)


def test_preflight_with_an_unreadable_folder_goes_by_the_script_name():
    with _sandbox() as sb:
        _repo_script(sb, "scripts/inst/1.1_step.sh")
        (sb.root / "ps_tree.txt").write_text("  200 1 /bin/zsh ./1.1_step.sh\n")
        result = _run(sb, "--preflight-only")
        assert result.returncode == 1
        assert "scripts/inst/1.1_step.sh" in result.stderr
        (sb.root / "ps_tree.txt").write_text("  200 1 /bin/zsh ./not_one_of_ours.sh\n")
        _run(sb, "--preflight-only", check=True)


def test_preflight_ignores_what_is_not_a_live_script_of_this_checkout():
    with _sandbox() as sb:
        ours = _repo_script(sb, "scripts/inst/1.1_step.sh")
        helper = _repo_script(sb, "src/helpers/some_helper.sh")
        mcm = sb.repo / "src/utilities/multi_cluster_management_utils/multi_cluster.sh"
        other = sb.root / "other/scripts/inst/1.1_step.sh"
        other.parent.mkdir(parents=True)
        other.write_text("#!/bin/zsh\n")
        (sb.root / "ps_tree.txt").write_text(
            f"  200 1 /bin/zsh {mcm} on --no-migrate\n"
            f"  201 1 /bin/zsh {helper}\n"
            f"  202 1 /bin/zsh {other}\n"
            f"  203 1 /bin/zsh -c source {ours}\n"
            f"  204 1 -zsh\n"
            f"  205 1 /bin/zsh\n"
            f"  206 1 /bin/bash {ours}\n"
            f"  207 1 vim {ours}\n"
            f"  208 1 /usr/bin/python3 {ours}\n"
            f"  209 1 /bin/zsh /no/such/script.sh {ours}\n"
        )
        _run(sb, "--preflight-only", check=True)


def test_turning_the_mode_on_is_refused_over_a_live_script():
    with _sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        path = _repo_script(sb, "scripts/inst/1.1_step.sh")
        (sb.root / "ps_tree.txt").write_text(f"  200 1 /bin/zsh {path}\n")
        result = subprocess.run(
            ["zsh", str(sb.repo / CLI), "on", "--no-migrate"], cwd=sb.repo, env=sb.env(), input="",
            capture_output=True, text=True, timeout=120, check=False,
        )
        assert result.returncode == 1
        assert "stays off" in result.stderr and "scripts/inst/1.1_step.sh" in result.stderr
        state_file = sb.repo / "configs/multi_cluster_management.sh"
        assert not state_file.exists() or 'MULTI_CLUSTER_MANAGEMENT="false"' in state_file.read_text()


def test_migrate_and_dry_run_refuse_over_a_live_script():
    with _sandbox() as sb:
        _add_fixture(sb)
        path = _repo_script(sb, "scripts/inst/1.1_step.sh")
        (sb.root / "ps_tree.txt").write_text(f"  200 1 /bin/zsh {path}\n")
        result = _run(sb, "--dry-run")
        assert result.returncode == 1 and "would refuse" in result.stderr
        result = _run(sb, "--yes")
        assert result.returncode == 1 and "1.1_step.sh" in result.stderr
        assert (sb.repo / "configs/cp4d_config/cpd_vars.sh").is_file()
        assert not (sb.repo / "configs/clusters").exists()


def _use_the_real_process_table(sb):
    """Real ps for the new scan only: the manage scan stays deterministic. Nothing outside the sandbox matches."""
    (sb.bin / "lsof").unlink()
    ps = sb.bin / "ps"
    ps.write_text(f'''#!/bin/zsh
case "$*" in
  *ppid*) exec /bin/ps "$@" ;;
esac
exit 0
''')


def _start_chain(sb, rel, argv1=None, cwd=None):
    path = sb.repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    started = sb.root / "chain_started"
    path.write_text(f'#!/bin/zsh\ntouch "{started}"\nsleep 120\nprint finished\n')
    path.chmod(0o755)
    chain = subprocess.Popen(
        ["zsh", argv1 or str(path)], cwd=cwd or sb.repo, env=sb.env(), start_new_session=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    deadline = time.time() + 30
    while not started.exists():
        assert time.time() < deadline, "the chain did not start"
        time.sleep(0.05)
    return chain


def _stop_chain(chain):
    os.killpg(chain.pid, signal.SIGKILL)
    chain.wait()


def test_preflight_sees_a_real_flat_chain_between_steps():
    with _sandbox() as sb:
        _use_the_real_process_table(sb)
        chain = _start_chain(sb, "scripts/install_cloud_pak_for_data/2_prepare_cluster/2.1_a_step_with_a_long_enough_name.sh")
        try:
            result = _run(sb, "--preflight-only")
        finally:
            _stop_chain(chain)
        assert result.returncode == 1
        assert f"pid {chain.pid}: scripts/install_cloud_pak_for_data/2_prepare_cluster/2.1_a_step_with_a_long_enough_name.sh" in result.stderr
        _run(sb, "--preflight-only", check=True)  # and it clears once the chain is gone


def test_preflight_sees_a_real_chain_started_with_a_relative_path():
    with _sandbox() as sb:
        _use_the_real_process_table(sb)
        chain = _start_chain(sb, "scripts/inst/1.1_step.sh", argv1="./1.1_step.sh", cwd=sb.repo / "scripts/inst")
        try:
            result = _run(sb, "--preflight-only")
        finally:
            _stop_chain(chain)
        assert result.returncode == 1
        assert "scripts/inst/1.1_step.sh" in result.stderr


def test_preflight_ignores_the_script_that_called_it():
    with _sandbox() as sb:
        _use_the_real_process_table(sb)
        wrapper = sb.repo / "scripts/inst/wrapper.sh"
        wrapper.parent.mkdir(parents=True)
        wrapper.write_text(f'#!/bin/zsh\nzsh "{sb.repo / SCRIPT}" --preflight-only\n')
        wrapper.chmod(0o755)
        result = subprocess.run(["zsh", str(wrapper)], cwd=sb.repo, env=sb.env(), capture_output=True, text=True, timeout=120, check=False)
        assert result.returncode == 0, result.stdout + result.stderr


def test_script_is_executable_and_syntax_clean():
    with _sandbox() as sb:
        path = sb.repo / SCRIPT
        assert os.access(path, os.X_OK)
        subprocess.run(["zsh", "-n", str(path)], check=True)
