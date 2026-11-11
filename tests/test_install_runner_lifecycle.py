"""In-cluster runner and the multi-cluster lifecycle (phase I5).

Plan: .claude/plans/multi-cluster-management/in-cluster-install-addon/in-cluster-install-addon-plan.md §7, gaps
X15 (a detached remote slot is invisible to remove, purge, rename, migrate and off) and X16 (no inventory across
clusters), decision D5 (15.1: refuse, and offer teardown first).

  - Launch records: ir_handoff writes ~/cpd-cli/clusters/<c>/.runner_slots/<slot> (flat: ~/cpd-cli/.runner_slots/),
    collect sets state=collected, teardown removes it (src/helpers/install_runner_slots.sh).
  - multi_cluster.sh remove, remove --purge, rename and off, and migrate_to_multi_cluster.sh (forward, rollback and
    --preflight-only) refuse while a record exists, and go through once it is torn down. `on` (the preflight with
    nothing to move) refuses on flat records only. teardown --forget clears a record when the cluster is gone.
  - ir-status carries cluster and ocp_url; x_install_runner.sh status shows CLUSTER and URL, and with
    --all-clusters ends with one table of every cluster, with no container start and no lease.

Everything runs in tests/mcm_harness.py sandboxes with the runner tests' fake oc, so nothing reaches a cluster,
podman or the real ~/cpd-cli.
"""

import json
import os
import re
import subprocess
import textwrap
import time

import pytest
import yaml
from mcm_harness import make_sandbox
from test_install_runner import FAKE_OC, REPO, SANDBOX_EXTRA, assert_clean_load
from test_install_runner_fanout import SETSID, SCRIPT, SUP_OC
from test_install_runner_workstation import SLOT, chain, clusters, leases, oc_log, path_records, run, starts, url
from test_mcm_migrate import _add_fixture, _migrate_unfinished, _run as migrate
from test_mcm_migrate import _sandbox as migrate_sandbox

MCM_CLI = "src/utilities/multi_cluster_management_utils/multi_cluster.sh"
RUNNER_TOOL = "scripts/install_runner/x_install_runner.sh"
WATCHER = "src/helpers/multi_cluster_idle_watcher.sh"
SLOTS = "src/helpers/install_runner_slots.sh"
# The fake oc answers `get configmap -A` per cluster: the pinned KUBECONFIG names it (.../clusters/<c>/.home/...).
PER_CLUSTER_STATUS = ('"get configmap -A"*) c="$(sed -E \'s#.*/clusters/([^/]+)/.*#\\1#\' <<<"${KUBECONFIG:-}")"; '
                      'cat "$d/all_status.$c.json" 2>/dev/null || cat "$d/all_status.json" 2>/dev/null || echo \'{"items":[]}\' ;;')


@pytest.fixture
def sb():
    """A runner sandbox (as in test_install_runner_workstation.py) that also holds multi_cluster.sh and the migration."""
    with make_sandbox(extra=[*SANDBOX_EXTRA, "src/utilities/multi_cluster_management_utils"]) as box:
        box.fake = box.root / "fake"
        box.fake.mkdir()
        (box.bin / "oc").write_text(FAKE_OC.replace(
            '"get configmap -A"*) cat "$d/all_status.json" 2>/dev/null || echo \'{"items":[]}\' ;;', PER_CLUSTER_STATUS))
        # Replaces the detached watcher, so no stray process outlives the test.
        (box.repo / WATCHER).write_text('#!/bin/zsh\nprint -r -- started >> "${HOME}/watcher_started"\n')
        subprocess.run(["git", "init", "-q"], cwd=box.repo, env=box.env(), check=True, capture_output=True)
        yield box


def record_file(box, cluster=None, slot=SLOT):
    base = box.home / "cpd-cli" / ("clusters/" + cluster if cluster else "")
    return base / ".runner_slots" / slot


def read_record(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


def write_record(box, cluster=None, slot=SLOT, state="launched", install="cpd", url_=None):
    path = record_file(box, cluster, slot)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"url={url_ or url(cluster or 'flat')}\nrun=20261111T000000Z\ninstall={install}\n"
                    f"launched=2026-11-11T00:00:00Z\nstate={state}\n")
    return path


def mcm(box, *args, input="", env=None):
    return subprocess.run(["zsh", str(box.repo / MCM_CLI), *args], cwd=box.repo, env=box.env(env), input=input,
                          capture_output=True, text=True, timeout=120, check=False)


def idle_scans(box):
    """Running containers answer the process scan as idle (a scan with no 'self' line counts as busy)."""
    box.add_exec_rule("mcm-proc-scan", stdout="self 999\n1 0 sleep infinity\n")


def mcm_state(box):
    return (box.repo / "configs/multi_cluster_management.sh").read_text()


def handoff_pinned(box, cluster="itz-a"):
    (box.fake / "state").write_text("completed\n")
    result = run(box, chain(box), "--target-cluster", cluster)
    assert result.returncode == 0, result.stdout + result.stderr
    return result


def status_item(slot, cluster=None, ocp_url=None, state="running"):
    data = {"slot": slot, "state": state, "step": "scripts/x.sh#cpd", "attempts": "1", "collected": "no",
            "heartbeat": str(int(time.time())), "warned": "-"}
    if cluster is not None:
        data["cluster"] = cluster
    if ocp_url is not None:
        data["ocp_url"] = ocp_url
    return {"metadata": {"name": "ir-status", "namespace": f"install-runner-{slot}"}, "data": data}


def write_status(box, items, cluster=None):
    name = f"all_status.{cluster}.json" if cluster else "all_status.json"
    (box.fake / name).write_text(json.dumps({"items": items}))


# --- launch records: written, updated, removed -----------------------------------------------------------------
def test_handoff_writes_a_launch_record_in_the_cluster_folder(sb):
    clusters(sb)
    handoff_pinned(sb)
    record = read_record(record_file(sb, "itz-a"))
    assert record["url"] == url("itz-a")
    assert record["install"] == "cpd"
    assert record["state"] == "launched"
    assert re.fullmatch(r"\d{8}T\d{6}Z", record["run"]), record
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", record["launched"]), record
    assert list(record) == ["url", "run", "install", "launched", "state"]
    assert oct(record_file(sb, "itz-a").parent.stat().st_mode & 0o777) == "0o700"
    assert not record_file(sb).exists(), "a pinned run writes no flat record"


def test_flat_handoff_writes_a_flat_record(sb):
    (sb.fake / "state").write_text("completed\n")
    sb.write_config("cpd", ocp_url="https://api.x:6443", extra={
        "PROJECT_CPD_INST_OPERANDS": "cpd-op", "STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil", "VERSION": "5.4.0",
        "INSTALL_RUNNER_CPD_CLI_URL": "https://x/cli.tgz", "INSTALL_RUN_MODE": "cluster"})
    result = run(sb, chain(sb))
    assert result.returncode == 0, result.stdout + result.stderr
    record = read_record(record_file(sb))
    assert record["url"] == "https://api.x:6443" and record["state"] == "launched"
    assert not (sb.home / "cpd-cli/clusters").exists()


def test_the_record_exists_before_the_slot_is_created(sb):
    """A launch that dies after the slot's resources went in still leaves its record: the slot is there to tear down."""
    clusters(sb)
    oc = sb.bin / "oc"
    oc.write_text(oc.read_text().replace('"apply -f -"*)', '"apply -f -"*) grep -q "kind: StatefulSet" && exit 1;', 1))
    result = run(sb, chain(sb))
    assert result.returncode != 0
    assert read_record(record_file(sb, "itz-a"))["state"] == "starting"
    assert read_record(record_file(sb, "itz-a"))["run"] == ""


def test_a_launch_refused_before_the_cluster_leaves_no_record(sb):
    clusters(sb)
    (sb.fake / "can_i").write_text("no\n")
    result = run(sb, chain(sb))
    assert result.returncode != 0
    assert "not cluster-admin" in result.stderr
    assert not record_file(sb, "itz-a").exists()


def test_collect_marks_the_record_and_teardown_removes_it(sb):
    clusters(sb)
    handoff_pinned(sb)
    # The pod serves back the run and path records the launch wrote (collect refuses a run without them).
    for name in ("run.env", "path_map"):
        (sb.fake / f"pod_{name}").write_text((sb.fake / name).read_text())
    collected = run(sb, RUNNER_TOOL, "collect", "--target-cluster", "itz-a", "--install", "cpd")
    assert collected.returncode == 0, collected.stdout + collected.stderr
    assert read_record(record_file(sb, "itz-a"))["state"] == "collected"
    assert read_record(record_file(sb, "itz-a"))["url"] == url("itz-a"), "the rest of the record is kept"
    (sb.fake / "status.collected").write_text("yes")
    gone = run(sb, RUNNER_TOOL, "teardown", "--target-cluster", "itz-a", "--install", "cpd")
    assert gone.returncode == 0, gone.stdout + gone.stderr
    assert not record_file(sb, "itz-a").exists()
    assert not record_file(sb, "itz-a").parent.exists(), "an empty records folder goes too"


def test_collect_of_a_slot_launched_elsewhere_starts_no_record(sb):
    clusters(sb)
    path_records(sb, ("itz-a",))
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, RUNNER_TOOL, "collect", "--install", "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert not record_file(sb, "itz-a").exists()


def test_a_teardown_that_is_refused_keeps_the_record(sb):
    clusters(sb)
    handoff_pinned(sb)
    (sb.fake / "status.state").write_text("running")
    result = run(sb, RUNNER_TOOL, "teardown", "--install", "cpd", "--discard")
    assert result.returncode != 0
    assert record_file(sb, "itz-a").exists()


def test_records_reader_lists_every_record(sb):
    write_record(sb, "itz-a")
    write_record(sb, "itz-b", slot="cpd-two", state="collected")
    write_record(sb, None, slot="cpd-flat")
    record_file(sb, "itz-a").with_name(f"{SLOT}.new.123").write_text("url=half written\n")
    script = f'source "${{0:A:h}}/{SLOTS}"\nir_slot_records\nprint -- ---\nir_slot_records --cluster itz-b\n'
    result = sb.run_zsh(script)
    assert result.returncode == 0, result.stderr
    everything, _, one = result.stdout.partition("---\n")
    rows = [line.split("\t") for line in everything.splitlines()]
    assert [r[:3] for r in rows] == [["-", "cpd-flat", "launched"], ["itz-a", SLOT, "launched"],
                                    ["itz-b", "cpd-two", "collected"]]
    assert rows[1][3:] == [url("itz-a"), "20261111T000000Z", "cpd", "2026-11-11T00:00:00Z"]
    assert one.splitlines() == ["itz-b\tcpd-two\tcollected\t" + url("itz-b") + "\t20261111T000000Z\tcpd\t2026-11-11T00:00:00Z"]


def test_a_record_value_cannot_add_a_key(sb):
    script = (f'source "${{0:A:h}}/{SLOTS}"\n'
              "ir_slot_record_set itz-a s1 url=$'https://x\\nstate=collected' state=launched\n")
    assert sb.run_zsh(script).returncode == 0
    assert read_record(record_file(sb, "itz-a", "s1")) == {
        "url": "https://x state=collected", "run": "", "install": "", "launched": "", "state": "launched"}


# --- D5: remove, purge, rename, off and migrate refuse while a slot exists ---------------------------------------
def test_remove_is_refused_while_a_slot_exists_and_goes_through_after_teardown(sb):
    """The full flow: launch, remove refused with the teardown command, run that command, remove works."""
    clusters(sb, names=("itz-a", "itz-b"))
    handoff_pinned(sb)
    refused = mcm(sb, "remove", "itz-a")
    assert refused.returncode == 1, refused.stdout + refused.stderr
    assert f"{SLOT} (cluster itz-a, {url('itz-a')}" in refused.stderr
    assert "credentials" in refused.stderr and "Nothing was changed." in refused.stderr
    hint = re.search(r"(scripts/install_runner/x_install_runner\.sh teardown [^\n]+)", refused.stderr).group(1)
    assert hint == f"scripts/install_runner/x_install_runner.sh teardown --target-cluster itz-a --install cpd --slot {SLOT}"
    assert 'MCM_CLUSTERS="itz-a itz-b"' in mcm_state(sb)
    assert "RETIRED" not in (sb.repo / "configs/clusters/itz-a/.cluster").read_text()

    (sb.fake / "status.collected").write_text("yes")
    words = hint.split()
    torn = run(sb, words[0], *words[1:])
    assert torn.returncode == 0, torn.stdout + torn.stderr
    assert f"delete namespace install-runner-{SLOT}" in oc_log(sb)
    removed = mcm(sb, "remove", "itz-a")
    assert removed.returncode == 0, removed.stdout + removed.stderr
    assert 'MCM_CLUSTERS="itz-b"' in mcm_state(sb)


def test_a_cluster_that_is_gone_can_be_forgotten_and_then_removed(sb):
    """An expired reservation: the login fails, so teardown cannot reach the slot. The refusal names
    teardown --forget and the record's path; --forget clears it without the cluster, and remove goes."""
    clusters(sb, names=("itz-a", "itz-b"))
    write_record(sb, "itz-a")
    config = sb.repo / "configs/clusters/itz-a/cp4d_config/cpd_vars.sh"
    config.write_text(config.read_text().replace('OC_LOGIN="oc login', 'OC_LOGIN="false; oc login'))
    refused = mcm(sb, "remove", "itz-a")
    assert refused.returncode == 1, refused.stdout + refused.stderr
    assert "add --forget to the teardown" in refused.stderr
    assert str(record_file(sb, "itz-a")) in refused.stderr
    hint = re.search(r"(scripts/install_runner/x_install_runner\.sh teardown [^\n]+)", refused.stderr).group(1)
    words = hint.split()
    assert run(sb, words[0], *words[1:], "--discard").returncode != 0, "the login still fails"
    assert record_file(sb, "itz-a").exists()

    forgot = run(sb, words[0], *words[1:], "--forget")
    assert forgot.returncode == 0, forgot.stdout + forgot.stderr
    assert "remain there" in forgot.stdout + forgot.stderr
    assert not record_file(sb, "itz-a").exists()
    assert "login" not in oc_log(sb) and "delete" not in oc_log(sb), "nothing reached the cluster"
    again = run(sb, words[0], *words[1:], "--forget")
    assert again.returncode == 0 and "nothing to forget" in again.stdout + again.stderr
    removed = mcm(sb, "remove", "itz-a")
    assert removed.returncode == 0, removed.stdout + removed.stderr
    assert 'MCM_CLUSTERS="itz-b"' in mcm_state(sb)


def test_forget_clears_a_flat_record(sb):
    (sb.fake / "state").write_text("completed\n")
    sb.write_config("cpd", ocp_url="https://api.x:6443", extra={
        "PROJECT_CPD_INST_OPERANDS": "cpd-op", "STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil", "VERSION": "5.4.0",
        "INSTALL_RUNNER_CPD_CLI_URL": "https://x/cli.tgz", "INSTALL_RUN_MODE": "cluster"})
    write_record(sb, None)
    forgot = run(sb, RUNNER_TOOL, "teardown", "--install", "cpd", "--slot", SLOT, "--forget")
    assert forgot.returncode == 0, forgot.stdout + forgot.stderr
    assert not record_file(sb, None).exists()


def test_purge_is_refused_and_says_what_stays_on_the_cluster(sb):
    clusters(sb, names=("itz-a", "itz-b"))
    write_record(sb, "itz-a")
    refused = mcm(sb, "remove", "itz-a", "--purge", input="itz-a\n")
    assert refused.returncode == 1, refused.stdout + refused.stderr
    assert "Will be deleted permanently:" in refused.stdout
    assert f"Not deleted: install slot {SLOT} in the cluster ({url('itz-a')})" in refused.stderr
    assert "remains on the cluster" in refused.stderr
    assert "Type the cluster name" not in refused.stdout, "refused before the prompt"
    assert (sb.repo / "configs/clusters/itz-a/cp4d_config/cpd_vars.sh").is_file()
    assert record_file(sb, "itz-a").is_file()

    record_file(sb, "itz-a").unlink()
    purged = mcm(sb, "remove", "itz-a", "--purge", input="itz-a\n")
    assert purged.returncode == 0, purged.stdout + purged.stderr
    assert "Not deleted" not in purged.stderr
    assert not (sb.repo / "configs/clusters/itz-a").exists()


def test_rename_is_refused_while_a_slot_exists(sb):
    clusters(sb, names=("itz-a", "itz-b"))
    write_record(sb, "itz-a", state="collected")
    refused = mcm(sb, "rename", "itz-a", "itz-c")
    assert refused.returncode == 1, refused.stdout + refused.stderr
    assert f"teardown --target-cluster itz-a --install cpd --slot {SLOT}" in refused.stderr
    assert (sb.repo / "configs/clusters/itz-a").is_dir() and not (sb.repo / "configs/clusters/itz-c").exists()
    record_file(sb, "itz-a").unlink()
    renamed = mcm(sb, "rename", "itz-a", "itz-c")
    assert renamed.returncode == 0, renamed.stdout + renamed.stderr
    assert (sb.repo / "configs/clusters/itz-c").is_dir()


def test_a_slot_on_another_cluster_does_not_block_remove(sb):
    clusters(sb, names=("itz-a", "itz-b"))
    write_record(sb, "itz-b")
    write_record(sb, None, slot="cpd-flat")
    result = mcm(sb, "remove", "itz-a")
    assert result.returncode == 0, result.stdout + result.stderr


def test_off_is_refused_while_any_cluster_has_a_slot(sb):
    clusters(sb, names=("itz-a", "itz-b"))
    idle_scans(sb)
    write_record(sb, "itz-b")
    refused = mcm(sb, "off")
    assert refused.returncode == 1, refused.stdout + refused.stderr
    assert f"{SLOT} (cluster itz-b" in refused.stderr
    assert 'MULTI_CLUSTER_MANAGEMENT="true"' in mcm_state(sb)
    record_file(sb, "itz-b").unlink()
    turned_off = mcm(sb, "off")
    assert turned_off.returncode == 0, turned_off.stdout + turned_off.stderr
    assert 'MULTI_CLUSTER_MANAGEMENT="false"' in mcm_state(sb)


def test_off_while_already_off_is_not_refused(sb):
    clusters(sb)
    idle_scans(sb)
    (sb.repo / "configs/multi_cluster_management.sh").write_text(
        mcm_state(sb).replace('MULTI_CLUSTER_MANAGEMENT="true"', 'MULTI_CLUSTER_MANAGEMENT="false"'))
    write_record(sb, "itz-a")
    result = mcm(sb, "off")
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_flat_slot_does_not_block_off(sb):
    clusters(sb)
    idle_scans(sb)
    write_record(sb, None, slot="cpd-flat")
    assert mcm(sb, "off").returncode == 0


def test_status_counts_remote_runs(sb):
    clusters(sb)
    none = mcm(sb, "status")
    assert none.returncode == 0, none.stderr
    assert "Remote runs:               0\n" in none.stdout
    write_record(sb, "itz-a")
    write_record(sb, None, slot="cpd-flat")
    some = mcm(sb, "status")
    assert some.returncode == 0, some.stderr
    assert (f"Remote runs:               2 (flat/cpd-flat, itz-a/{SLOT}; "
            "see x_install_runner.sh status --all-clusters)") in some.stdout
    assert oc_log(sb) == "", "status reads only the records"


def test_help_names_the_slot_refusal(sb):
    text = mcm(sb, "--help").stdout
    assert "install slot launched from here" in text
    assert "x_install_runner.sh teardown --target-cluster NAME --slot SLOT" in text


# --- D5: the migration --------------------------------------------------------------------------------------------
def flat_record(sb, slot="cpd-flat"):
    path = sb.home / "cpd-cli/.runner_slots" / slot
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("url=https://api.itz-a.example.com:6443\nrun=r1\ninstall=cpd\nlaunched=-\nstate=launched\n")
    return path


def test_migration_preflight_is_refused_while_a_slot_exists():
    with migrate_sandbox() as sb:
        assert migrate(sb, "--preflight-only").returncode == 0
        path = flat_record(sb)
        refused = migrate(sb, "--preflight-only")
        assert refused.returncode == 1, refused.stdout + refused.stderr
        assert "[ERROR] Preflight: Install slot cpd-flat (flat config, https://api.itz-a.example.com:6443, launched)" in refused.stderr
        assert "tear it down: scripts/install_runner/x_install_runner.sh teardown --install cpd --slot cpd-flat" in refused.stderr
        path.unlink()
        assert migrate(sb, "--preflight-only").returncode == 0


def test_migration_moves_nothing_while_a_slot_exists():
    with migrate_sandbox() as sb:
        _add_fixture(sb)
        flat_record(sb)
        refused = migrate(sb, "--yes")
        assert refused.returncode == 1, refused.stdout + refused.stderr
        assert "Install slot cpd-flat" in refused.stderr
        assert (sb.repo / "configs/cp4d_config/cpd_vars.sh").is_file()
        assert not (sb.repo / "configs/clusters").exists()


def test_migration_is_refused_by_a_slot_of_a_delineated_cluster():
    with migrate_sandbox() as sb:
        path = sb.home / "cpd-cli/clusters/itz-a/.runner_slots/cpd-x"
        path.parent.mkdir(parents=True)
        path.write_text("url=u\nrun=r\ninstall=cpd\nlaunched=-\nstate=collected\n")
        refused = migrate(sb, "--preflight-only")
        assert refused.returncode == 1
        assert "teardown --target-cluster itz-a --install cpd --slot cpd-x" in refused.stderr


def test_rollback_is_refused_while_a_slot_exists():
    with migrate_sandbox() as sb:
        _add_fixture(sb)
        _migrate_unfinished(sb)
        path = flat_record(sb)
        refused = migrate(sb, "--rollback", "--yes")
        assert refused.returncode == 1, refused.stdout + refused.stderr
        assert "Install slot cpd-flat" in refused.stderr
        assert (sb.repo / "configs/clusters").exists(), "nothing was undone"
        path.unlink()
        rolled_back = migrate(sb, "--rollback", "--yes")
        assert rolled_back.returncode == 0, rolled_back.stdout + rolled_back.stderr
        assert (sb.repo / "configs/cp4d_config/cpd_vars.sh").is_file()


def test_turning_the_mode_on_is_refused_while_a_flat_slot_exists():
    """`on` runs the migration's preflight: a flat slot's collect and teardown need the flat layout."""
    with migrate_sandbox() as sb:
        flat_record(sb)
        result = subprocess.run(["zsh", str(sb.repo / MCM_CLI), "on", "--no-migrate"], cwd=sb.repo, env=sb.env(),
                                capture_output=True, text=True, timeout=120, check=False, input="")
        assert result.returncode == 1, result.stdout + result.stderr
        assert "Install slot cpd-flat" in result.stderr
        assert "Multi-cluster mode stays off" in result.stderr


def test_turning_the_mode_on_is_not_refused_by_a_slot_of_a_delineated_cluster(sb):
    """Nothing moves when `on` has nothing to migrate, and --target-cluster reaches that slot in either mode."""
    clusters(sb, names=("itz-a",))
    idle_scans(sb)
    (sb.repo / "configs/multi_cluster_management.sh").write_text(
        mcm_state(sb).replace('MULTI_CLUSTER_MANAGEMENT="true"', 'MULTI_CLUSTER_MANAGEMENT="false"'))
    write_record(sb, "itz-a")
    turned_on = mcm(sb, "on")
    assert turned_on.returncode == 0, turned_on.stdout + turned_on.stderr
    assert 'MULTI_CLUSTER_MANAGEMENT="true"' in mcm_state(sb)
    assert record_file(sb, "itz-a").exists()

    (sb.repo / "configs/multi_cluster_management.sh").write_text(
        mcm_state(sb).replace('MULTI_CLUSTER_MANAGEMENT="true"', 'MULTI_CLUSTER_MANAGEMENT="false"'))
    write_record(sb, None, slot="cpd-flat")
    refused = mcm(sb, "on")
    assert refused.returncode == 1, refused.stdout + refused.stderr
    assert "Install slot cpd-flat" in refused.stderr and f"Install slot {SLOT}" not in refused.stderr
    assert "Multi-cluster mode stays off (see the preflight errors above)" in refused.stderr
    assert 'MULTI_CLUSTER_MANAGEMENT="false"' in mcm_state(sb)


# --- X16: ir-status carries the cluster, status shows it ------------------------------------------------------
def test_slot_carries_this_checkouts_cluster_name(sb):
    clusters(sb)
    handoff_pinned(sb)
    docs = [d for d in yaml.safe_load_all((sb.fake / "applied.yaml").read_text()) if d]
    sts = next(d for d in docs if d["kind"] == "StatefulSet")
    env = {e["name"]: e.get("value") for e in sts["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["IR_SOURCE_CLUSTER"] == "itz-a"
    assert env["IR_OCP_URL"] == url("itz-a")


def test_flat_slot_has_no_cluster_name(sb):
    (sb.fake / "state").write_text("completed\n")
    sb.write_config("cpd", ocp_url="https://api.x:6443", extra={
        "PROJECT_CPD_INST_OPERANDS": "cpd-op", "STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil", "VERSION": "5.4.0",
        "INSTALL_RUNNER_CPD_CLI_URL": "https://x/cli.tgz", "INSTALL_RUN_MODE": "cluster"})
    assert run(sb, chain(sb)).returncode == 0
    docs = [d for d in yaml.safe_load_all((sb.fake / "applied.yaml").read_text()) if d]
    sts = next(d for d in docs if d["kind"] == "StatefulSet")
    env = {e["name"]: e.get("value") for e in sts["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["IR_SOURCE_CLUSTER"] == ""


@pytest.mark.parametrize("cluster,expected", [("itz-a", "itz-a"), ("", "-")])
def test_supervisor_publishes_cluster_and_url(tmp_path, cluster, expected):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, text in (("setsid", SETSID), ("script", SCRIPT), ("oc", SUP_OC)):
        (bin_dir / name).write_text(text)
        (bin_dir / name).chmod(0o755)
    work = tmp_path / "work"
    env = {**{k: v for k, v in os.environ.items() if not k.startswith("IR_")},
           "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path), "IR_WORK": str(work),
           "IR_BIN": str(REPO / "src/install_runner/image/bin"), "IR_POLL": "0.2", "IR_HEARTBEAT": "1",
           "IR_SLOT": "t", "IR_NAMESPACE": "ns", "IR_OCP_URL": "https://api.itz-a.example.com:6443",
           "IR_SOURCE_CLUSTER": cluster}
    sup = subprocess.Popen(["zsh", str(REPO / "src/install_runner/image/bin/supervisor.sh")], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log = tmp_path / "oc.log"
    try:
        end = time.monotonic() + 30
        while time.monotonic() < end and "create configmap" not in (log.read_text() if log.exists() else ""):
            time.sleep(0.2)
    finally:
        sup.terminate()
        sup.communicate(timeout=30)
    text = log.read_text()
    assert f"--from-literal=cluster={expected} " in text
    assert "--from-literal=ocp_url=https://api.itz-a.example.com:6443 " in text


def status_table(stdout, header="CLUSTER"):
    """The rows of the first table under a header line that starts with header."""
    lines = stdout.splitlines()
    start = next(i for i, line in enumerate(lines) if line.split()[:1] == [header])
    rows = []
    for line in lines[start + 1:]:
        if not line.strip() or line.startswith("["):
            break
        rows.append(line.split())
    return lines[start].split(), rows


def test_status_shows_cluster_and_url(sb):
    clusters(sb)
    write_status(sb, [status_item("cpd-a", cluster="old-name", ocp_url="https://api.launched.example.com:6443"),
                      status_item("cpd-b")], cluster="itz-a")
    result = run(sb, RUNNER_TOOL, "status", "--install", "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    header, rows = status_table(result.stdout)
    assert header == ["CLUSTER", "URL", "SLOT", "STATE", "STEP", "ATTEMPT", "COLLECTED", "SEEN", "ago"][:len(header)]
    # This checkout's name, which --target-cluster takes; the URL the slot was launched for, else this login's.
    assert rows[0][:4] == ["itz-a", "https://api.launched.example.com:6443", "cpd-a", "running"]
    assert rows[1][:4] == ["itz-a", url("itz-a"), "cpd-b", "running"]
    assert "Install runner slots on every cluster" not in result.stdout, "one cluster: no second table"


def test_flat_status_shows_the_published_cluster_name(sb):
    sb.write_config("cpd", ocp_url="https://api.x:6443", extra={"PROJECT_CPD_INST_OPERANDS": "cpd-op"})
    write_status(sb, [status_item("cpd-a", cluster="itz-q"), status_item("cpd-b", cluster="-")])
    result = run(sb, RUNNER_TOOL, "status", "--install", "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    _, rows = status_table(result.stdout)
    assert [r[:3] for r in rows] == [["itz-q", "https://api.x:6443", "cpd-a"], ["-", "https://api.x:6443", "cpd-b"]]


def test_status_all_clusters_merges_every_cluster_and_starts_nothing(sb):
    clusters(sb, names=("itz-a", "itz-b"))
    sb.set_machine("stopped")
    write_status(sb, [status_item("cpd-one", cluster="itz-a", ocp_url=url("itz-a"))], cluster="itz-a")
    write_status(sb, [status_item("cpd-two", cluster="itz-b", ocp_url=url("itz-b"), state="completed")], cluster="itz-b")
    # No _CP4D_PREP_DONE: as from a terminal, where the auto-prep would start the VM.
    result = run(sb, RUNNER_TOOL, "status", "--all-clusters", env={"_CP4D_PREP_DONE": None})
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    assert "[MCM] 1/2 itz-a: ok" in result.stdout and "[MCM] 2/2 itz-b: ok" in result.stdout
    tail = result.stdout.split("[INFO] Install runner slots on every cluster:\n", 1)[1]
    header, rows = status_table(tail)
    assert header[:3] == ["CLUSTER", "URL", "SLOT"]
    assert [r[:4] for r in rows] == [["itz-a", url("itz-a"), "cpd-one", "running"],
                                    ["itz-b", url("itz-b"), "cpd-two", "completed"]]
    assert starts(sb) == [], sb.calls("podman")
    assert sb.fake_state()["machine"] == "stopped"
    assert leases(sb, "itz-a") == [] and leases(sb, "itz-b") == []
    assert list(sb.tmp.glob("ir-status.*")) == [], "the rows file is removed"


def test_status_all_clusters_with_no_slots_prints_no_second_table(sb):
    clusters(sb, names=("itz-a", "itz-b"))
    result = run(sb, RUNNER_TOOL, "status", "--all-clusters")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Install runner slots on every cluster" not in result.stdout


def test_status_all_clusters_keeps_a_failure_code(sb):
    clusters(sb, names=("itz-a", "itz-b"))
    write_status(sb, [status_item("cpd-one")], cluster="itz-a")
    (sb.repo / "configs/clusters/itz-b/cp4d_config/cpd_vars.sh").write_text(
        (sb.repo / "configs/clusters/itz-b/cp4d_config/cpd_vars.sh").read_text().replace(
            'OC_LOGIN="oc login', 'OC_LOGIN="false; oc login'))
    # itz-b's login fails: its child fails and the run's code says so; the table still has itz-a's row.
    result = run(sb, RUNNER_TOOL, "status", "--all-clusters")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "[MCM] 1/2 itz-a: ok" in result.stdout and "[MCM] 2/2 itz-b: FAILED" in result.stdout
    tail = result.stdout.split("[INFO] Install runner slots on every cluster:\n", 1)[1]
    assert [r[:3] for r in status_table(tail)[1]] == [["itz-a", url("itz-a"), "cpd-one"]]
