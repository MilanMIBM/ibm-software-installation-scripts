"""Shared test setup: the TUIs ignore "f" for a moment after start-up (a stray terminal reply); tests press
it at once, so the grace is off here."""

import os
import pwd
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
GUARDED = (REPO / "configs/clusters", REPO / "configs/multi_cluster_management.sh", REAL_HOME / "cpd-cli/clusters")


def _snapshot(paths):
    seen = {}
    for root in paths:
        if not root.exists():
            continue
        for p in [root, *root.rglob("*")] if root.is_dir() else [root]:
            try:
                st = p.lstat()
            except OSError:
                continue
            seen[str(p)] = (st.st_mode, st.st_size, st.st_mtime_ns)
    return seen


@pytest.fixture(autouse=True)
def _real_repo_untouched():
    """Fails the test that creates, changes or deletes anything in the real multi-cluster locations."""
    before = _snapshot(GUARDED)
    yield
    after = _snapshot(GUARDED)
    if after != before:
        changed = sorted(set(before) ^ set(after) | {k for k in before.keys() & after.keys() if before[k] != after[k]})
        pytest.fail("test wrote to the real repo or ~/cpd-cli (left in place for inspection): " + ", ".join(changed[:10]))


@pytest.fixture(autouse=True)
def _no_startup_key_grace(monkeypatch):
    from tui.cr_dashboard.ui import app as cr_app
    from tui.instance_manager.ui import app as im_app
    monkeypatch.setattr(im_app, "STARTUP_KEY_GRACE", 0.0)
    monkeypatch.setattr(cr_app, "STARTUP_KEY_GRACE", 0.0)
