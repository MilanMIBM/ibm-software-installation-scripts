"""The real-home guard in tests/conftest.py: what it lets through and what it still fails on.

Runs on a stand-in ~/cpd-cli/clusters under tmp_path, never on the real one.
"""

import os
import time

import pytest
from conftest import guard_changes, live_tooling_path, snapshot


@pytest.fixture
def home(tmp_path):
    """A stand-in clusters home with one delineated cluster, as the live tooling leaves it."""
    root = tmp_path / "clusters"
    (root / "itz-a/work").mkdir(parents=True)
    (root / "itz-a/work/internal-registry.log").write_text("old\n")
    (root / "itz-a/.cluster").write_text('NAME="itz-a"\n')
    (root / "itz-a/.home/.kube").mkdir(parents=True)
    (root / "itz-a/.home/.kube/config").write_text("kube\n")
    (root / ".idle-watcher.log").write_text("start\n")
    return root


def touch_later(path, text):
    """Rewrites a file and moves its mtime, as a later write by another process would."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    later = time.time() + 5
    os.utime(path, (later, later))


def changes(home, change):
    before = snapshot([home])
    change()
    return guard_changes(before, snapshot([home]), clusters_home=home)


@pytest.mark.parametrize("rel", [
    "itz-a/work/internal-registry.log",
    "itz-a/work/new-job/output.log",
    "itz-a/swhub-control-center/work/cp4d_config/cpd_vars.sh",
    ".idle-watcher.log",
    ".idle-watcher.pid",
    ".vm-stopping",
    "itz-a/.last_activity",
    "itz-a/.scans/olm-utils-play-v4-itz-a",
    ".flat/.scans/olm-utils-play-v4",
    "itz-a/.leases/4242",
    "itz-a/.stopping",
    "itz-a/.custom_containers",
])
def test_live_tooling_writes_are_let_through(home, rel):
    assert changes(home, lambda: touch_later(home / rel, "new\n")) == []


def test_live_tooling_files_going_away_are_let_through(home):
    (home / "itz-a/.leases").mkdir()
    (home / "itz-a/.leases/4242").write_text("")
    (home / ".vm-stopping").write_text("")

    def remove():
        (home / "itz-a/.leases/4242").unlink()
        (home / "itz-a/.leases").rmdir()
        (home / ".vm-stopping").unlink()
    assert changes(home, remove) == []


@pytest.mark.parametrize("rel", [
    "itz-a/.cluster",
    "itz-a/.home/.kube/config",
    "itz-b/.cluster",
    "itz-a/cp4d_config/cpd_vars.sh",
    "itz-a/notes.txt",
    "work.txt",
    ".last_activity",
])
def test_anything_else_still_fails(home, rel):
    assert str(home / rel) in changes(home, lambda: touch_later(home / rel, "test leak\n"))


def test_new_cluster_folder_is_reported(home):
    found = changes(home, lambda: touch_later(home / "itz-b/.cluster", "NAME=itz-b\n"))
    assert str(home / "itz-b") in found
    assert str(home / "itz-b/.cluster") in found


def test_empty_new_folder_is_reported(home):
    assert changes(home, lambda: (home / "itz-c").mkdir()) == [str(home / "itz-c")]


def test_deleted_marker_is_reported(home):
    assert changes(home, lambda: (home / "itz-a/.cluster").unlink()) == [str(home / "itz-a/.cluster")]


def test_mode_change_is_reported(home):
    assert changes(home, lambda: (home / "itz-a/.cluster").chmod(0o600)) == [str(home / "itz-a/.cluster")]


def test_exemptions_apply_only_under_the_clusters_home(tmp_path, home):
    """A repo's configs/clusters has no live tooling: a work/ folder there is a leak."""
    repo_clusters = tmp_path / "repo/configs/clusters"
    (repo_clusters / "itz-a").mkdir(parents=True)
    before = snapshot([repo_clusters, home])
    touch_later(repo_clusters / "itz-a/work/x.log", "leak\n")
    touch_later(repo_clusters / "itz-a/.last_activity", "leak\n")
    found = guard_changes(before, snapshot([repo_clusters, home]), clusters_home=home)
    assert str(repo_clusters / "itz-a/work/x.log") in found
    assert str(repo_clusters / "itz-a/.last_activity") in found


def test_folder_mtime_alone_is_not_a_change(home):
    """A watcher file appearing moves its folder's mtime; that must not fail the test."""
    def add():
        touch_later(home / "itz-a/.last_activity", "")
        later = time.time() + 10
        os.utime(home / "itz-a", (later, later))
    assert changes(home, add) == []


@pytest.mark.parametrize("rel,owned", [
    ((".idle-watcher.log",), True),
    (("itz-a",), False),
    (("itz-a", "work"), True),
    (("itz-a", "swhub-control-center"), False),
    (("itz-a", "swhub-control-center", "work", "x"), True),
    (("itz-a", "swhub-control-center", "cp4d_config"), False),
    (("itz-a", ".last_activity", "x"), False),
    (("itz-a", "x", ".last_activity"), False),
    ((), False),
])
def test_live_tooling_path(rel, owned):
    assert live_tooling_path(rel) is owned


@pytest.mark.parametrize("rel", [
    "itz-b/work/cpd-cli-workspace/olm-utils-workspace.log",
    "itz-b/.leases/123",
    "itz-b/.last_activity",
    "itz-b/swhub-control-center/work/x",
    "itz-b/.scans/olm-utils-play-v4-itz-b",
])
def test_new_cluster_folder_with_only_tooling_data_is_reported(home, rel):
    """The usual leak from a test running multi-cluster code with the real HOME: a work dir or a
    lease under a test cluster's own folder. The exemptions hold only for an existing cluster."""
    assert str(home / "itz-b") in changes(home, lambda: touch_later(home / rel, "test leak\n"))


def test_removed_cluster_folder_with_only_tooling_data_is_reported(home):
    (home / "itz-d/work").mkdir(parents=True)
    (home / "itz-d/work/job.log").write_text("x\n")

    def remove():
        (home / "itz-d/work/job.log").unlink()
        (home / "itz-d/work").rmdir()
        (home / "itz-d").rmdir()
    found = changes(home, remove)
    assert str(home / "itz-d") in found
    assert str(home / "itz-d/work/job.log") in found


def test_flat_folder_holds_only_scans(home):
    assert str(home / ".flat/work/x.log") in changes(home, lambda: touch_later(home / ".flat/work/x.log", "leak\n"))
