"""dataRefresh in the Kubecost features config: file, kubecost_vars.sh variables and CR patch."""

import importlib.util
from pathlib import Path

import pytest
import yaml

_path = Path(__file__).resolve().parents[1] / "src/helpers/kubecost_features.py"
_spec = importlib.util.spec_from_file_location("kubecost_features", _path)
kf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(kf)

INTERVAL = {"name": kf.REFRESH_INTERVAL_ENV, "value": "15m"}
FIXED = {"name": kf.REFRESH_DYNAMIC_ENV, "value": "false"}
OTHER = {"name": "LOG_FORMAT", "value": "json"}


def ctx(env=None, interval="", dynamic=""):
    spec = {"aggregator": {"extraEnv": env}} if env is not None else {}
    return {
        "instance": "kc",
        "namespace": "kc",
        "crSpec": spec,
        "effective": spec,
        "refreshVars": {"interval": interval, "dynamic": dynamic},
    }


def plan_of(tmp_path, context, section):
    """The plan of a generated file with only dataRefresh changed (None = no such section)."""
    cfg = yaml.safe_load(kf.generate(context))
    if section is None:
        del cfg["dataRefresh"]
    else:
        cfg["dataRefresh"] = section
    path = tmp_path / "features.yaml"
    path.write_text(yaml.safe_dump(cfg))
    return kf.plan(context, str(path))


def refresh_row(result):
    return next(r for r in result["summary"] if r["feature"] == "dataRefresh")


def env_patch(result):
    return result["patch"].get("spec", {}).get("aggregator", {}).get("extraEnv", "absent")


@pytest.mark.parametrize(
    "text,minutes",
    [("15m", 15), ("2h", 120), ("1h30m", 90), ("0m", None), ("", None), ("15", None), ("1d", None), (15, None)],
)
def test_refresh_minutes(text, minutes):
    assert kf.refresh_minutes(text) == minutes


def test_generated_file_shows_the_chart_default_and_changes_nothing(tmp_path):
    context = ctx()
    assert yaml.safe_load(kf.generate(context))["dataRefresh"] == {"interval": "default", "dynamic": True}
    result = plan_of(tmp_path, context, {"interval": "default", "dynamic": True})
    assert env_patch(result) == "absent" and not refresh_row(result)["changed"]


def test_generated_file_reads_the_running_values():
    assert yaml.safe_load(kf.generate(ctx([INTERVAL, FIXED])))["dataRefresh"] == {"interval": "15m", "dynamic": False}


def test_file_from_before_this_section_leaves_the_instance_alone(tmp_path):
    result = plan_of(tmp_path, ctx([OTHER, INTERVAL, FIXED]), None)
    assert env_patch(result) == "absent" and not result["errors"]
    assert refresh_row(result)["state"] == "not in the file: left as is"


def test_fixed_interval_turns_the_self_adjustment_off(tmp_path):
    assert env_patch(plan_of(tmp_path, ctx(), {"interval": "15m"})) == [INTERVAL, FIXED]


def test_other_env_entries_are_kept(tmp_path):
    assert env_patch(plan_of(tmp_path, ctx([OTHER]), {"interval": "15m"})) == [OTHER, INTERVAL, FIXED]


def test_back_to_default_drops_the_list_it_made(tmp_path):
    assert env_patch(plan_of(tmp_path, ctx([INTERVAL, FIXED]), {"interval": "default"})) is None


def test_back_to_default_keeps_other_entries(tmp_path):
    assert env_patch(plan_of(tmp_path, ctx([OTHER, INTERVAL, FIXED]), {"interval": "default"})) == [OTHER]


def test_applying_twice_changes_nothing(tmp_path):
    result = plan_of(tmp_path, ctx([INTERVAL, FIXED]), {"interval": "15m", "dynamic": False})
    assert result["patch"] == {} and not refresh_row(result)["changed"]


def test_variable_wins_over_the_file_and_says_so(tmp_path):
    result = plan_of(tmp_path, ctx(interval="30m"), {"interval": "1h", "dynamic": True})
    assert env_patch(result) == [{"name": kf.REFRESH_INTERVAL_ENV, "value": "30m"}, FIXED]
    assert any("overrides interval: 1h" in w for w in result["warnings"])


def test_generate_writes_the_variable_so_the_file_agrees(tmp_path):
    context = ctx(interval="30m")
    assert yaml.safe_load(kf.generate(context))["dataRefresh"] == {"interval": "30m", "dynamic": False}


def test_dynamic_variable_can_keep_the_self_adjustment(tmp_path):
    result = plan_of(tmp_path, ctx(interval="15m", dynamic="true"), None)
    assert env_patch(result) == [INTERVAL]
    assert any("may change it on its own" in w for w in result["warnings"])


def test_below_ingest_rate_warns(tmp_path):
    result = plan_of(tmp_path, ctx(), {"interval": "5m"})
    assert any("no new data" in w for w in result["warnings"]) and not result["errors"]


@pytest.mark.parametrize(
    "section,message",
    [
        ({"interval": "1d"}, "duration"),
        ({"interval": 15}, "duration"),
        ({"interval": "15m", "dynamic": "no"}, "true or false"),
    ],
)
def test_bad_file_values_stop_the_apply(tmp_path, section, message):
    result = plan_of(tmp_path, ctx(), section)
    assert any(message in e for e in result["errors"])


def test_bad_variable_stops_the_apply_but_not_generate(tmp_path):
    context = ctx(interval="soon")
    assert yaml.safe_load(kf.generate(context))["dataRefresh"]["interval"] == "default"
    assert kf.refresh_plan(context)["errors"]


def test_install_plan_without_variables_is_empty():
    result = kf.refresh_plan(ctx())
    assert result["patch"] == {} and not result["errors"]


def test_install_plan_with_variables():
    assert kf.refresh_plan(ctx(interval="15m"))["patch"] == {"spec": {"aggregator": {"extraEnv": [INTERVAL, FIXED]}}}


def older_file(tmp_path, context, *dropped, edit=True):
    """A generated file with sections cut out and a user's edit and comment in it."""
    lines = kf.generate(context).split("\n")
    starts = kf.section_starts(lines)
    order = list(starts)
    for key in sorted(dropped, key=order.index, reverse=True):
        nxt = order.index(key) + 1
        end = starts[order[nxt]] if nxt < len(order) else len(lines)
        del lines[starts[key] : end]
    text = "\n".join(lines)
    if edit:
        text = text.replace("  daily: 91", "  daily: 30  # my edit")
    path = tmp_path / "features.yaml"
    path.write_text(text)
    return path


def test_missing_section_is_added_in_its_place_and_edits_stay(tmp_path):
    context = ctx()
    path = older_file(tmp_path, context, "dataRefresh")
    result = kf.add_missing(context, str(path))
    assert result["added"] == ["dataRefresh"] and not result["errors"]
    assert "  daily: 30  # my edit" in result["text"]
    keys = list(kf.section_starts(result["text"].split("\n")))
    assert keys.index("dataRefresh") == keys.index("dataRetention") + 1
    assert "# --- Data refresh" in result["text"]
    assert yaml.safe_load(result["text"])["dataRefresh"] == {"interval": "default", "dynamic": True}


def test_added_section_follows_the_variable(tmp_path):
    context = ctx(interval="15m")
    result = kf.add_missing(context, str(older_file(tmp_path, context, "dataRefresh")))
    assert yaml.safe_load(result["text"])["dataRefresh"] == {"interval": "15m", "dynamic": False}


def test_complete_file_is_left_alone(tmp_path):
    context = ctx()
    path = older_file(tmp_path, context)
    result = kf.add_missing(context, str(path))
    assert result["added"] == [] and result["text"] == path.read_text()


def test_several_sections_and_the_last_one(tmp_path):
    context = ctx()
    result = kf.add_missing(context, str(older_file(tmp_path, context, "dataRefresh", "teams", "actions")))
    assert result["added"] == ["dataRefresh", "teams", "actions"]
    assert list(kf.section_starts(result["text"].split("\n"))) == list(kf.section_starts(kf.generate(context).split("\n")))


def test_adding_then_planning_changes_nothing(tmp_path):
    context = ctx()
    path = older_file(tmp_path, context, "dataRefresh", edit=False)
    path.write_text(kf.add_missing(context, str(path))["text"])
    assert env_patch(kf.plan(context, str(path))) == "absent"


def test_foreign_file_is_refused(tmp_path):
    path = tmp_path / "other.yaml"
    path.write_text("a: 1\n")
    assert kf.add_missing(ctx(), str(path))["errors"]
