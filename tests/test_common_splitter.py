"""Resizable panes (common/splitter.py) in both TUIs: locked at start, L unlocks, drag / keys / reset."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import pytest  # noqa: E402
from test_instance_manager_ui import FormProvider, filled, settle  # noqa: E402

from tui.common.splitter import Divider  # noqa: E402
from tui.instance_manager.hub import DataHub  # noqa: E402


def _divider(app, target):
    return next(d for d in app.query(Divider) if d.target_sel == target)


async def _drag(pilot, div, dx=0, dy=0):
    await pilot.mouse_down(div)
    await pilot.hover(div, offset=(dx, dy))
    await pilot.mouse_up(div)            # the bar moved with the pointer: release on it


@pytest.mark.asyncio
async def test_instance_manager_panes_resize_only_when_unlocked():
    from tui.instance_manager.ui.app import InstanceManagerApp

    app = InstanceManagerApp(DataHub(FormProvider(), poll=3600), "t", animate=False)
    async with app.run_test(size=(200, 50)) as pilot:
        assert await settle(pilot, lambda: filled(app, "InstanceRow"))
        left, div = app.query_one("#left"), _divider(app, "#left")
        w0 = left.outer_size.width
        assert app.layout_locked and not div.display                 # locked by default: no bars at all
        await pilot.press("L")
        assert await settle(pilot, lambda: div.display and div.region.width == 1)
        assert not app.layout_locked
        await _drag(pilot, div, dx=12)
        assert await settle(pilot, lambda: left.outer_size.width == w0 + 12)
        div.focus()                                                  # keyboard twin
        await pilot.press("left", "left")
        assert await settle(pilot, lambda: left.outer_size.width == w0 + 10)
        await pilot.press("enter")                                   # reset to the stylesheet's width
        assert await settle(pilot, lambda: left.outer_size.width == w0)
        state, sdiv = app.query_one("#state"), _divider(app, "#state")
        h0 = state.outer_size.height
        await _drag(pilot, sdiv, dy=-5)                              # the state panel grows upwards
        assert await settle(pilot, lambda: state.outer_size.height == h0 + 5)
        await pilot.double_click(sdiv)
        assert await settle(pilot, lambda: state.outer_size.height == h0)
        await pilot.press("L")
        assert await settle(pilot, lambda: not div.display and app.layout_locked)
        await _drag(pilot, app.query_one("#right"), dx=-20)          # locked: nothing to drag
        assert left.outer_size.width == w0


@pytest.mark.asyncio
async def test_cr_dashboard_panes_resize_when_unlocked():
    from test_cr_dashboard import Introspector, fake_engine

    from tui.cr_dashboard.ui.app import DashboardApp

    hub, profile, engine = fake_engine()
    app = DashboardApp(kube=None, profile=profile, hub=hub, engine=engine,
                       intro=Introspector(None, hub, [], enabled=False), resources=[], user="t", header="t")
    async with app.run_test(size=(160, 45)) as pilot:
        await pilot.pause(0.2)
        chains, div = app.query_one("#chains"), _divider(app, "#chains")
        w0 = chains.outer_size.width
        assert not div.display
        await pilot.press("L")
        assert await settle(pilot, lambda: div.display)
        await _drag(pilot, div, dx=-8)
        assert await settle(pilot, lambda: chains.outer_size.width == w0 - 8)
        events, ediv = app.query_one("#events"), _divider(app, "#events")
        e0 = events.outer_size.height
        await _drag(pilot, ediv, dy=-3)
        assert await settle(pilot, lambda: events.outer_size.height == e0 + 3)
