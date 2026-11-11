"""Shared test setup: the TUIs ignore "f" for a moment after start-up (a stray terminal reply); tests press
it at once, so the grace is off here."""

import os
import pwd
import stat
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

# Exported by `source s_env.sh`. The scripts honour these when preset, so a test launched from such a terminal
# would leave its temp repo and read or overwrite the real configs/ and service_instances/.
ENV_LOADER_EXPORTS = (
    "CONFIGS_ROOT", "CONFIG_DIR", "CONFLUENT_CONFIG_DIR", "CONCERT_CONFIG_DIR", "DATASTAX_MC_CONFIG_DIR",
    "REGISTRY_MIRROR_CONFIG_DIR", "SERVICE_INSTANCE_FILE_DIR", "CPD_CLI_MANAGE_WORKSPACE", "CPD_CLI_WORK_PATH",
    "CPD_CLI_HOME", "CPD_CLI_BASE_WORK_PATH", "OLM_UTILS_CONTAINER", "CONCERT_WORKSPACE", "MC_WORKSPACE",
    "KC_WORKSPACE", "OADP_LOG_DIR", "MIRROR_WORKSPACE", "MIRROR_BASE", "MIRROR_CLUSTER_OUT", "MCM_CLUSTER",
    "MCM_CLUSTER_ROOT",
)


@pytest.fixture(autouse=True)
def _clean_env_loader_exports(monkeypatch):
    for name in ENV_LOADER_EXPORTS:
        monkeypatch.delenv(name, raising=False)


@pytest.fixture(autouse=True)
def _isolated_mcm_state_file(monkeypatch):
    """Keeps every test away from the real configs/multi_cluster_management.sh."""
    with tempfile.TemporaryDirectory(prefix="mcm-state-") as tmp:
        monkeypatch.setenv("MCM_STATE_FILE", str(Path(tmp).resolve() / "multi_cluster_management.sh"))
        yield


REPO = Path(__file__).resolve().parents[1]
REAL_HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)
# Real locations multi-cluster code writes to. Markers are permanent (delineation is one-way per
# cluster), so a test leaking one here would change how the real repo loads its configs.
REAL_CLUSTERS_HOME = REAL_HOME / "cpd-cli/clusters"
# Flat launch records of in-cluster runs (gap X15) sit next to clusters/, outside its live-tooling
# exemptions: a leaked one would make the real `multi_cluster.sh on` and the migration refuse.
REAL_FLAT_RUNNER_SLOTS = REAL_HOME / "cpd-cli/.runner_slots"
GUARDED = (REPO / "configs/clusters", REPO / "configs/multi_cluster_management.sh", REAL_CLUSTERS_HOME,
           REAL_FLAT_RUNNER_SLOTS)

# What the user's own live tooling keeps changing under ~/cpd-cli/clusters while the suite runs: a job
# in a live olm-utils container writes its work dir, and the idle watcher keeps its log, pid, leases,
# scans and markers there. A real in-cluster launch, collect or teardown writes or removes its launch
# record in <cluster>/.runner_slots/ (gap X15). None of it decides how a config loads, so a change there
# is not a test leaking out. Everything else in the tree (a .cluster marker, a config, a new folder) is
# still guarded. Tests write launch records only in sandbox HOMEs.
LIVE_TOOLING_TOP = {".idle-watcher.log", ".idle-watcher.pid", ".vm-stopping"}       # ~/cpd-cli/clusters/<file>
LIVE_TOOLING_PER_CLUSTER = {".last_activity", ".stopping", ".custom_containers"}    # <cluster>/<file>
LIVE_TOOLING_TREES = {("work",), (".scans",), (".leases",), (".runner_slots",),
                      ("swhub-control-center", "work")}  # <cluster>/<tree>/**


def live_tooling_path(rel):
    """True for a path under ~/cpd-cli/clusters (given as a tuple of parts) that live tooling owns."""
    if not rel:
        return False
    if len(rel) == 1:
        return rel[0] in LIVE_TOOLING_TOP
    if len(rel) == 2 and rel[1] in LIVE_TOOLING_PER_CLUSTER:
        return True
    return any(rel[1:1 + len(tree)] == tree for tree in LIVE_TOOLING_TREES)


def snapshot(paths):
    """path -> (is a dir, mode, size, mtime). A directory keeps only its mode: its mtime moves
    whenever a child comes or goes, and every child is recorded on its own."""
    seen = {}
    for root in paths:
        if not root.exists():
            continue
        for p in [root, *root.rglob("*")] if root.is_dir() else [root]:
            try:
                st = p.lstat()
            except OSError:
                continue
            if stat.S_ISDIR(st.st_mode):
                seen[str(p)] = (True, st.st_mode, 0, 0)
            else:
                seen[str(p)] = (False, st.st_mode, st.st_size, st.st_mtime_ns)
    return seen


def guard_changes(before, after, clusters_home=REAL_CLUSTERS_HOME):
    """Sorted paths created, changed or deleted between two snapshots, without what live tooling owns.

    The per-cluster exemptions hold only inside a cluster folder that was there before and after: a
    new or removed ~/cpd-cli/clusters/<cluster> is always reported, whatever it holds, since a test
    running multi-cluster code with the real HOME leaves exactly that (<test cluster>/work, .leases).
    Inside an existing cluster, a folder that came or went is left out when everything it held, before
    or after, is live-tooling data (the watcher creating <cluster>/swhub-control-center/ on the way to
    its work dir). The same goes for the top-level .flat/, the watcher's scan folder in flat mode. An
    empty new folder still counts."""
    def rel(path):
        try:
            return Path(path).relative_to(clusters_home).parts
        except ValueError:
            return None

    def cluster_kept(name):
        folder = str(Path(clusters_home) / name)
        return folder in before and folder in after

    def owned(path):
        parts = rel(path)
        if parts and len(parts) >= 2:
            if parts[0] == ".flat":
                return parts[1] == ".scans"   # the flat-mode scan folder holds nothing else
            if not cluster_kept(parts[0]):
                return False
        return live_tooling_path(parts)

    everything = set(before) | set(after)
    changed = (set(before) ^ set(after)) | {p for p in before.keys() & after.keys() if before[p] != after[p]}
    kept = []
    for path in sorted(changed):
        if owned(path):
            continue
        parts = rel(path)
        is_dir = (before.get(path) or after.get(path))[0]
        came_or_went = (path in before) != (path in after)
        if is_dir and came_or_went and parts and (len(parts) >= 2 or parts == (".flat",)):
            inside = [p for p in everything if p.startswith(path + os.sep)]
            if inside and all(owned(p) for p in inside):
                continue
        kept.append(path)
    return kept


@pytest.fixture(autouse=True)
def _real_repo_untouched():
    """Fails the test that creates, changes or deletes anything in the real multi-cluster locations."""
    before = snapshot(GUARDED)
    yield
    changed = guard_changes(before, snapshot(GUARDED))
    if changed:
        pytest.fail("test wrote to the real repo or ~/cpd-cli (left in place for inspection): " + ", ".join(changed[:10]))


@pytest.fixture(autouse=True)
def _no_startup_key_grace(monkeypatch):
    from tui.cr_dashboard.ui import app as cr_app
    from tui.instance_manager.ui import app as im_app
    monkeypatch.setattr(im_app, "STARTUP_KEY_GRACE", 0.0)
    monkeypatch.setattr(cr_app, "STARTUP_KEY_GRACE", 0.0)
