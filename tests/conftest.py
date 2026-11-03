"""Shared test setup: the TUIs ignore "f" for a moment after start-up (a stray terminal reply); tests press
it at once, so the grace is off here."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))


@pytest.fixture(autouse=True)
def _no_startup_key_grace(monkeypatch):
    from tui.cr_dashboard.ui import app as cr_app
    from tui.instance_manager.ui import app as im_app
    monkeypatch.setattr(im_app, "STARTUP_KEY_GRACE", 0.0)
    monkeypatch.setattr(cr_app, "STARTUP_KEY_GRACE", 0.0)
