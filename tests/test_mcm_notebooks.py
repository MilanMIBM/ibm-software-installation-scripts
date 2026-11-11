"""T11: multi-cluster controls in the notebooks and the shell config generators.

Helper tests use a temp repo. Notebook tests run the real notebooks headless with app.run(defs=...)
inside that temp repo, so __file__ based paths land there. Generator tests run the real scripts there.
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest
from mcm_harness import make_sandbox

from helpers import multi_cluster_notebook as nb
from helpers import multi_cluster_state as state

REPO = Path(__file__).resolve().parents[1]
URL_A = "https://api.alpha.example.com:6443"
URL_B = "https://api.beta.example.com:6443"


@pytest.fixture
def sb():
    with make_sandbox() as sandbox:
        yield sandbox


def ctx(sandbox):
    return {"repo": sandbox.repo, "env": sandbox.env()}


def state_file(sandbox):
    return sandbox.repo / "configs" / "multi_cluster_management.sh"


def set_on(sandbox, clusters=(), current=""):
    for name, url in clusters:
        state.register_cluster(name, url, **ctx(sandbox))
    state.write_state({"MULTI_CLUSTER_MANAGEMENT": True, "MCM_CURRENT_CLUSTER": current}, **ctx(sandbox))


class TestDefaultFromFile:
    def test_missing_file_is_off_and_not_created(self, sb):
        assert nb.mode_default(**ctx(sb)) is False
        assert not state_file(sb).exists()

    def test_reads_on(self, sb):
        set_on(sb)
        assert nb.mode_default(**ctx(sb)) is True

    def test_broken_file_is_off_and_blocks_saves(self, sb):
        state_file(sb).parent.mkdir(parents=True, exist_ok=True)
        state_file(sb).write_text('export MULTI_CLUSTER_MANAGEMENT="maybe"\n')
        assert nb.mode_default(**ctx(sb)) is False
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert "MULTI_CLUSTER_MANAGEMENT" in target.error
        assert nb.save_blockers(target) == [target.error]


class TestResolveTarget:
    def test_off_is_flat(self, sb):
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert Path(target.directory) == sb.repo / "configs" / "cp4d_config"
        assert target.display == "./configs/cp4d_config/"
        assert target.cluster == ""
        assert "single-cluster" in nb.save_to_markdown(target)

    def test_off_ignores_a_configs_root_from_another_checkout(self, sb):
        env = sb.env({"CONFIGS_ROOT": str(sb.tmp / "elsewhere")})
        target = nb.resolve_target("cp4d_config", False, "", URL_A, repo=sb.repo, env=env)
        assert Path(target.directory) == sb.repo / "configs" / "cp4d_config"

    def test_unticked_while_on_goes_flat_even_with_a_current_cluster(self, sb):
        set_on(sb, [("alpha", URL_A)], "alpha")
        env = sb.env({"CONFIGS_ROOT": str(sb.repo / "configs/clusters/alpha")})
        target = nb.resolve_target("concert_config", False, "", URL_B, repo=sb.repo, env=env)
        assert Path(target.directory) == sb.repo / "configs" / "concert_config"
        assert "**off**" in nb.save_to_markdown(target)
        assert "alpha" in nb.save_to_markdown(target)

    def test_blank_name_uses_the_url(self, sb):
        target = nb.resolve_target("cp4d_config", True, "  ", URL_A, **ctx(sb))
        assert target.cluster == target.hint == "alpha"
        assert Path(target.directory) == sb.repo / "configs/clusters/alpha/cp4d_config"
        line = nb.save_to_markdown(target)
        assert "`./configs/clusters/alpha/cp4d_config/`" in line
        assert "Name from the URL: **alpha**" in line

    def test_typed_name_wins_and_the_hint_still_shows(self, sb):
        target = nb.resolve_target("cp4d_config", True, "my-prod", URL_A, **ctx(sb))
        assert target.cluster == "my-prod"
        assert Path(target.directory).parent.name == "my-prod"
        assert "**alpha**" in nb.save_to_markdown(target)

    def test_blank_name_never_falls_back_to_the_current_cluster(self, sb):
        set_on(sb, [("beta", URL_B)], "beta")
        target = nb.resolve_target("cp4d_config", True, "", "", **ctx(sb))
        assert target.directory == ""
        assert target.error
        assert nb.existing_vars_file(target, "cpd_vars.sh") is None

    def test_on_with_no_cluster_selected_a_ticked_box_never_saves_flat(self, sb):
        set_on(sb, [("alpha", URL_A), ("beta", URL_B)], "")
        target = nb.resolve_target("cp4d_config", True, "", "", **ctx(sb))
        assert target.directory == ""
        assert nb.save_blockers(target) == [target.error]

    @pytest.mark.parametrize("bad", ["Bad Name", "cp4d_config", "x_workspace", "clusters", "old_configs"])
    def test_invalid_names_are_reported(self, sb, bad):
        target = nb.resolve_target("cp4d_config", True, bad, URL_A, **ctx(sb))
        assert target.directory == "" and bad in target.error
        assert nb.save_blockers(target, confirmed=True) == [target.error]

    def test_a_url_with_no_usable_name_is_reported(self, sb):
        target = nb.resolve_target("cp4d_config", True, "", "https://", **ctx(sb))
        assert target.hint == "" and target.error


class TestOverwriteGuard:
    def seed(self, sandbox):
        sandbox.write_config("cpd", ocp_url=URL_A, cluster="alpha", login=False)

    def test_same_url_is_fine(self, sb):
        self.seed(sb)
        for url in (URL_A, URL_A + "/", URL_A.upper().replace("HTTPS", "https")):
            target = nb.resolve_target("cp4d_config", True, "alpha", url, **ctx(sb))
            assert not target.conflict, url

    def test_different_url_needs_the_tick(self, sb):
        self.seed(sb)
        target = nb.resolve_target("cp4d_config", True, "alpha", URL_B, **ctx(sb))
        assert target.conflict
        assert nb.save_blockers(target) and "overwrite" in nb.save_blockers(target)[0].lower()
        assert nb.save_blockers(target, confirmed=True) == []
        assert URL_A in nb.save_to_markdown(target)

    def test_any_product_of_the_cluster_counts(self, sb):
        sb.write_config("concert", ocp_url=URL_A, cluster="alpha", login=False)
        target = nb.resolve_target("cp4d_config", True, "alpha", URL_B, **ctx(sb))
        assert target.conflict

    def test_marker_url_counts(self, sb):
        sb.write_cluster_marker("alpha", URL_A)
        target = nb.resolve_target("cp4d_config", True, "alpha", URL_B, **ctx(sb))
        assert target.conflict

    def test_flat_layout_has_no_guard(self, sb):
        sb.write_config("cpd", ocp_url=URL_A, login=False)
        target = nb.resolve_target("cp4d_config", False, "", URL_B, **ctx(sb))
        assert not target.conflict
        assert nb.save_blockers(target) == []

    def test_editor_content_must_match_the_url_field(self, sb):
        target = nb.resolve_target("cp4d_config", True, "alpha", URL_A, **ctx(sb))
        assert nb.save_blockers(target, False, f'export OCP_URL="{URL_B}"\n')
        assert nb.save_blockers(target, False, f'export OCP_URL="{URL_A}"\n') == []
        assert nb.save_blockers(target, False, "") == []

    def test_editor_content_is_not_compared_in_flat_mode(self, sb):
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert nb.save_blockers(target, False, f'export OCP_URL="{URL_B}"\n') == []


class TestFinishSave:
    def test_on_updates_flag_registers_and_sets_current(self, sb):
        target = nb.resolve_target("cp4d_config", True, "", URL_A, **ctx(sb))
        notes = nb.finish_save(target, **ctx(sb))
        values = state.read_state(**ctx(sb))
        assert values["MULTI_CLUSTER_MANAGEMENT"] == "true"
        assert values["MCM_CURRENT_CLUSTER"] == "alpha"
        assert values["MCM_CLUSTERS"].split() == ["alpha"]
        assert f'OCP_URL="{URL_A}"' in (sb.repo / "configs/clusters/alpha/.cluster").read_text()
        assert "alpha" in notes[0]

    def test_new_cluster_joins_the_others_and_becomes_current(self, sb):
        set_on(sb, [("beta", URL_B)], "beta")
        nb.finish_save(nb.resolve_target("concert_config", True, "", URL_A, **ctx(sb)), **ctx(sb))
        values = state.read_state(**ctx(sb))
        assert values["MCM_CLUSTERS"].split() == ["beta", "alpha"]
        assert values["MCM_CURRENT_CLUSTER"] == "alpha"

    def test_ticked_overwrite_updates_the_marker(self, sb):
        sb.write_cluster_marker("alpha", URL_A)
        target = nb.resolve_target("cp4d_config", True, "alpha", URL_B, **ctx(sb))
        nb.finish_save(target, **ctx(sb))
        assert f'OCP_URL="{URL_B}"' in (sb.repo / "configs/clusters/alpha/.cluster").read_text()

    def test_off_save_writes_the_default_state_and_nothing_else(self, sb):
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert nb.finish_save(target, **ctx(sb)) == []
        assert state_file(sb).is_file()
        assert state.read_state(**ctx(sb))["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_unticking_turns_the_mode_off_and_keeps_the_folders(self, sb):
        set_on(sb, [("alpha", URL_A)], "alpha")
        target = nb.resolve_target("cp4d_config", False, "", URL_B, **ctx(sb))
        assert Path(target.directory) == sb.repo / "configs" / "cp4d_config"
        notes = nb.finish_save(target, **ctx(sb))
        values = state.read_state(**ctx(sb))
        assert values["MULTI_CLUSTER_MANAGEMENT"] == "false"
        assert values["MCM_CLUSTERS"] == "alpha"
        assert (sb.repo / "configs/clusters/alpha/.cluster").is_file()
        assert "off" in notes[0]


class TestOneWayPerCluster:
    """Delineation is one-way per cluster: a config of a delineated cluster always lands in its folder."""

    @pytest.mark.parametrize("on", [False, True])
    def test_unticked_save_for_a_delineated_url_is_forced_into_its_folder(self, sb, on):
        state.register_cluster("alpha", URL_A, **ctx(sb))
        state.write_state({"MULTI_CLUSTER_MANAGEMENT": on}, **ctx(sb))
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert target.forced and target.cluster == "alpha" and target.owner == "alpha"
        assert Path(target.directory) == sb.repo / "configs/clusters/alpha/cp4d_config"
        line = nb.save_to_markdown(target)
        assert "forced on" in line and "never goes back to the flat layout" in line
        assert f"stays **{'on' if on else 'off'}**" in line
        assert "turns multi-cluster mode" not in line
        assert nb.one_way_markdown(target) == ""

    def test_forced_save_keeps_the_flag_and_the_current_cluster(self, sb):
        state.register_cluster("alpha", URL_A, **ctx(sb))
        state.register_cluster("beta", URL_B, **ctx(sb))
        set_on(sb, current="beta")
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert nb.mode_change_blockers(target) == []
        notes = nb.finish_save(target, **ctx(sb))
        values = state.read_state(**ctx(sb))
        assert (values["MULTI_CLUSTER_MANAGEMENT"], values["MCM_CURRENT_CLUSTER"]) == ("true", "beta")
        assert "stays on" in notes[0]

    def test_forced_save_with_the_mode_off_leaves_it_off(self, sb):
        state.register_cluster("alpha", URL_A, **ctx(sb))
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert nb.save_blockers(target) == []
        notes = nb.finish_save(target, **ctx(sb))
        assert state.read_state(**ctx(sb))["MULTI_CLUSTER_MANAGEMENT"] == "false"
        assert "stays off" in notes[0] and "--target-cluster alpha" in notes[0]

    def test_a_marker_without_a_url_owns_its_derived_name(self, sb):
        sb.write_cluster_marker("alpha")
        target = nb.resolve_target("concert_config", False, "", URL_A, **ctx(sb))
        assert target.cluster == "alpha" and target.forced

    def test_owner_by_marker_url_beats_the_derived_name(self, sb):
        sb.write_cluster_marker("prod-east", URL_A)
        ticked = nb.resolve_target("cp4d_config", True, "", URL_A, **ctx(sb))
        unticked = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert ticked.cluster == unticked.cluster == "prod-east"
        assert nb.delineated_owner(URL_A + "/", repo=sb.repo) == "prod-east"

    def test_typed_name_for_a_url_another_cluster_owns_is_refused(self, sb):
        sb.write_cluster_marker("alpha", URL_A)
        target = nb.resolve_target("cp4d_config", True, "second", URL_A, **ctx(sb))
        assert target.directory == "" and "alpha" in target.error
        assert nb.save_blockers(target, confirmed=True) == [target.error]

    def test_forced_save_compares_the_editor_url(self, sb):
        sb.write_cluster_marker("alpha", URL_A)
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert nb.save_blockers(target, False, f'export OCP_URL="{URL_B}"\n')

    def test_a_retired_cluster_is_registered_again(self, sb):
        state.register_cluster("alpha", URL_A, **ctx(sb))
        state.mark_retired("alpha", repo=sb.repo)
        state.write_state({"MCM_CLUSTERS": ""}, **ctx(sb))
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert target.retired and "retired" in nb.save_to_markdown(target)
        notes = nb.finish_save(target, **ctx(sb))
        assert not state.is_retired("alpha", repo=sb.repo)
        assert state.read_state(**ctx(sb))["MCM_CLUSTERS"].split() == ["alpha"]
        assert any("registered again" in n for n in notes)

    def test_new_cluster_shows_the_one_way_warning(self, sb):
        target = nb.resolve_target("cp4d_config", True, "", URL_A, **ctx(sb))
        assert target.new_cluster
        warning = nb.one_way_markdown(target)
        assert "cannot be undone for cluster alpha" in warning and "preferred" in warning
        notes = nb.finish_save(target, **ctx(sb))
        assert any("cannot be undone for cluster alpha" in n for n in notes)

    def test_an_existing_cluster_shows_no_one_way_warning(self, sb):
        state.register_cluster("alpha", URL_A, **ctx(sb))
        target = nb.resolve_target("cp4d_config", True, "", URL_A, **ctx(sb))
        assert nb.one_way_markdown(target) == ""
        assert not any("cannot be undone" in n for n in nb.finish_save(target, **ctx(sb)))

    def test_flat_save_shows_no_one_way_warning(self, sb):
        target = nb.resolve_target("cp4d_config", False, "", URL_A, **ctx(sb))
        assert not target.forced and nb.one_way_markdown(target) == ""

    def test_state_failure_becomes_a_note(self, sb):
        target = nb.resolve_target("cp4d_config", True, "", URL_A, **ctx(sb))
        state_file(sb).parent.mkdir(parents=True, exist_ok=True)
        state_file(sb).write_text('export APPLY_TO_ALL="maybe"\n')
        notes = nb.finish_save(target, **ctx(sb))
        assert "not updated" in notes[0]

    def test_state_file_is_private(self, sb):
        nb.finish_save(nb.resolve_target("cp4d_config", True, "", URL_A, **ctx(sb)), **ctx(sb))
        assert stat.S_IMODE(state_file(sb).stat().st_mode) == 0o600


class TestStopIdleAfterOff:
    """A save that turns the mode off stops the idle containers, as multi_cluster.sh off does."""

    HELPERS = "src/helpers/multi_cluster_helpers.sh"

    def stub(self, sandbox, body):
        """Appended, so it replaces the real function in this sandbox's copy of the helpers."""
        with (sandbox.repo / self.HELPERS).open("a") as handle:
            handle.write(f"\nmcm_stop_idle_after_off() {{\n{body}\n}}\n")

    def turn_off(self, sandbox):
        set_on(sandbox, [("alpha", URL_A)], "alpha")
        return nb.finish_save(nb.resolve_target("cp4d_config", False, "", URL_B, **ctx(sandbox)), **ctx(sandbox))

    def marker(self, sandbox):
        return sandbox.root / "stop_called"

    def test_called_after_the_state_is_written_off(self, sb):
        self.stub(sb, f'mcm_load_state; print -r -- "$MULTI_CLUSTER_MANAGEMENT" > "{self.marker(sb)}"')
        self.turn_off(sb)
        assert self.marker(sb).read_text().strip() == "false"

    def test_busy_warning_reaches_the_save_result(self, sb):
        self.stub(sb, 'print -r -- "[INFO] checking" >&2\nprint -r -- "[WARN] olm-a is busy (exec), left running." >&2')
        notes = self.turn_off(sb)
        assert "off" in notes[0]
        assert "olm-a is busy (exec), left running." in notes[1]
        assert "[WARN]" not in notes[1] and "checking" not in notes[1]

    def test_quiet_when_nothing_is_busy(self, sb):
        self.stub(sb, 'print -r -- "[INFO] stopped olm-a" >&2')
        assert len(self.turn_off(sb)) == 1

    def test_not_called_when_the_mode_was_already_off(self, sb):
        self.stub(sb, f': > "{self.marker(sb)}"')
        nb.finish_save(nb.resolve_target("cp4d_config", False, "", URL_B, **ctx(sb)), **ctx(sb))
        assert not self.marker(sb).exists()

    def test_not_called_when_the_mode_goes_on(self, sb):
        self.stub(sb, f': > "{self.marker(sb)}"')
        nb.finish_save(nb.resolve_target("cp4d_config", True, "", URL_A, **ctx(sb)), **ctx(sb))
        assert not self.marker(sb).exists()

    def test_not_called_when_the_state_write_failed(self, sb):
        self.stub(sb, f': > "{self.marker(sb)}"')
        set_on(sb, [("alpha", URL_A)], "alpha")
        target = nb.resolve_target("cp4d_config", False, "", URL_B, **ctx(sb))
        state_file(sb).write_text('export APPLY_TO_ALL="maybe"\n')
        notes = nb.finish_save(target, **ctx(sb))
        assert "not updated" in notes[0]
        assert not self.marker(sb).exists()

    def test_helpers_without_the_function_are_fine(self, sb):
        set_on(sb, [("alpha", URL_A)], "alpha")
        (sb.repo / self.HELPERS).write_text("_mcm_warn() { :; }\n")
        target = nb.resolve_target("cp4d_config", False, "", URL_B, **ctx(sb))
        assert len(nb.finish_save(target, **ctx(sb))) == 1
        assert state.read_state(**ctx(sb))["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_missing_helpers_file_is_fine(self, sb):
        set_on(sb, [("alpha", URL_A)], "alpha")
        (sb.repo / self.HELPERS).unlink()
        target = nb.resolve_target("cp4d_config", False, "", URL_B, **ctx(sb))
        assert len(nb.finish_save(target, **ctx(sb))) == 1

    def test_a_failing_helper_is_a_note_not_an_exception(self, sb):
        self.stub(sb, "return 7")
        notes = self.turn_off(sb)
        assert "not checked" in notes[1] and "7" in notes[1]

    def test_a_timeout_is_a_note_not_an_exception(self, sb, monkeypatch):
        self.stub(sb, "sleep 30")
        monkeypatch.setattr(nb, "STOP_AFTER_OFF_TIMEOUT_SECONDS", 1)
        notes = self.turn_off(sb)
        assert "not checked" in notes[1]
        assert state.read_state(**ctx(sb))["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_uses_this_checkout_not_an_inherited_one(self, sb):
        self.stub(sb, f'print -r -- "$(mcm_repo_root)" > "{self.marker(sb)}"')
        set_on(sb, [("alpha", URL_A)], "alpha")
        env = sb.env({"_CP4D_REPO_ROOT": "/nonexistent/other-checkout"})
        target = nb.resolve_target("cp4d_config", False, "", URL_B, repo=sb.repo, env=env)
        nb.finish_save(target, repo=sb.repo, env=env)
        assert self.marker(sb).read_text().strip() == str(sb.repo)

    def test_finish_save_alone_uses_the_repo_and_env_of_the_target(self, sb, monkeypatch):
        # How the notebooks call it. The state writes are stubbed: with no repo they would reach the real one.
        self.stub(sb, f'print -r -- "$HOME" > "{self.marker(sb)}"')
        set_on(sb, [("alpha", URL_A)], "alpha")
        target = nb.resolve_target("cp4d_config", False, "", URL_B, **ctx(sb))
        monkeypatch.setattr(nb.mcm, "ensure_state_file", lambda *args: None)
        monkeypatch.setattr(nb.mcm, "write_state", lambda *args: None)
        nb.finish_save(target)
        assert self.marker(sb).read_text().strip() == str(sb.home)


class TestSmallHelpers:
    @pytest.mark.parametrize(
        ("text", "expected"),
        [
            (f'export OCP_URL="{URL_A}"\n', URL_A),
            (f"export OCP_URL='{URL_A}'\n", URL_A),
            (f"OCP_URL={URL_A}\n", URL_A),
            (f'export OCP_URL="{URL_A}"   # the hub\n', URL_A),
            (f'    export OCP_URL=""\nexport OCP_URL="{URL_A}"\n', URL_A),
            ('export OCP_URL="${OTHER}"\n', ""),
            ('export CONTROL_OCP_URL="x"\n', ""),
            ("", ""),
            (None, ""),
        ],
    )
    def test_url_in_text(self, text, expected):
        assert nb.url_in_text(text) == expected

    def test_flat_configs_lists_only_flat_vars_files(self, sb):
        sb.write_config("cpd", ocp_url=URL_A, login=False)
        sb.write_config("concert", ocp_url=URL_B, login=False)
        sb.write_config("cpd", ocp_url=URL_A, cluster="alpha", login=False)
        (sb.repo / "configs/old_configs").mkdir(parents=True)
        (sb.repo / "configs/old_configs/cpd_vars.sh").write_text('export OCP_URL="https://api.old.example.com"\n')
        found = nb.flat_configs(repo=sb.repo)
        assert sorted((f["product"], f["cluster"]) for f in found) == [("concert_config", "beta"), ("cp4d_config", "alpha")]
        text = nb.flat_configs_markdown(found)
        assert "`cp4d_config/cpd_vars.sh`" in text and "**beta**" in text

    def test_flat_configs_empty_on_a_clean_tree(self, sb):
        assert nb.flat_configs(repo=sb.repo) == []

    def test_existing_vars_file_follows_the_selected_cluster(self, sb):
        sb.write_config("concert", ocp_url=URL_A, cluster="alpha", login=False)
        found = nb.resolve_target("concert_config", True, "alpha", URL_A, **ctx(sb))
        missing = nb.resolve_target("concert_config", True, "beta", URL_B, **ctx(sb))
        assert nb.existing_vars_file(found, "concert_vars.sh") == str(sb.repo / "configs/clusters/alpha/concert_config/concert_vars.sh")
        assert nb.existing_vars_file(missing, "concert_vars.sh") is None

    def test_startup_file_is_flat_when_off_and_absent_when_on(self, sb):
        sb.write_config("concert", ocp_url=URL_A, login=False)
        assert nb.startup_vars_file("concert_config", "concert_vars.sh", **ctx(sb)).endswith("configs/concert_config/concert_vars.sh")
        set_on(sb)
        assert nb.startup_vars_file("concert_config", "concert_vars.sh", **ctx(sb)) is None

    def test_overwrite_label_names_the_cluster(self, sb):
        target = nb.resolve_target("cp4d_config", True, "alpha", URL_A, **ctx(sb))
        assert "alpha" in nb.overwrite_label(target)


class TestRunMigration:
    def test_reports_a_missing_script(self, sb):
        ok, output = nb.run_migration(repo=sb.repo, env=sb.env())
        assert not ok and "not in this checkout" in output

    def _stub(self, sandbox, body):
        script = sandbox.repo / nb.MIGRATE_SCRIPT
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text("#!/bin/zsh\n" + body)

    def test_runs_with_yes_and_returns_output(self, sb):
        self._stub(sb, 'print -r -- "args=$*"\n')
        ok, output = nb.run_migration(repo=sb.repo, env=sb.env())
        assert ok and output == "args=--yes"

    def test_reports_failure_with_output(self, sb):
        self._stub(sb, 'print -r -- "[ERROR] busy" >&2\nexit 3\n')
        ok, output = nb.run_migration(repo=sb.repo, env=sb.env())
        assert not ok and "busy" in output


class TestNotebookWiring:
    """Static: every notebook routes its save through the helper."""

    @pytest.mark.parametrize("name", ["softwarehub_cp4d_vars_generation.py", "confluent_platform_vars_generation.py", "ibm_concert_vars_generation.py"])
    def test_uses_the_helper_only(self, name):
        text = (REPO / name).read_text()
        assert "configs_root" not in text
        for symbol in ("mcm_nb.resolve_target(", "mcm_nb.save_blockers(", "mcm_nb.finish_save(", "mcm_nb.flat_configs()", "mcm_nb.mode_default()",
                       "mcm_nb.delineated_owner(cluster_url_input.value)", "mcm_nb.one_way_markdown(mcm_target)"):
            assert symbol in text, symbol
        assert "debounce=300" in text

    @pytest.mark.parametrize("name", ["softwarehub_cp4d_vars_generation.py", "confluent_platform_vars_generation.py", "ibm_concert_vars_generation.py"])
    def test_tick_cell_redraws_on_the_url_not_the_name(self, name):
        """The forced tick follows the URL; the name must not be an input of mcm_url_cluster, or typing would steal the focus."""
        text = (REPO / name).read_text()
        cell = text[text.index("mcm_url_cluster = ") - 300:text.index("mcm_url_cluster = ")]
        assert "def _(cluster_url_input, mcm_migrate_result):" in cell
        assert "disabled=True" in text and "always on for cluster" in text

    def test_concert_intro_names_both_layouts(self):
        text = (REPO / "ibm_concert_vars_generation.py").read_text()
        assert "Writes `configs/concert_config/concert_vars.sh`" not in text
        assert "`configs/concert_config/`" in text
        assert "`configs/clusters/<cluster>/concert_config/`" in text


NOTEBOOK_DRIVER = textwrap.dedent("""\
    import importlib.util, json, os, sys
    sys.path.insert(0, ".")
    spec = importlib.util.spec_from_file_location("nb_under_test", sys.argv[1])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    class W:
        def __init__(self, value):
            self.value = value
    requested = json.loads(sys.argv[2])
    if "file_getter" in requested:
        path = requested.pop("file_getter")
        requested["mcm_vars_file"] = lambda: path
        requested["mcm_set_vars_file"] = lambda value: None
    plain = ("mcm_vars_file", "mcm_set_vars_file", "config_errors", "config_warnings")
    defs = {k: (v if k in plain else W(v)) for k, v in requested.items()}
    if "config_errors" in defs:  # the same cell also imports re, so it has to be supplied with them
        import re
        defs["re"] = re
    outputs, values = module.app.run(defs=defs)
    wanted = {}
    for key in ("admin_password_input", "install_run_mode_select", "install_runner_settings"):
        if key in values:
            wanted[key] = getattr(values[key], "value", values[key])
    print("RESULT=" + json.dumps({"saved": any("Saved to" in str(getattr(o, "text", "")) for o in outputs),
                                  "not_saved": any("Not saved" in str(getattr(o, "text", "")) for o in outputs),
                                  "values": wanted}))
""")

NOTEBOOK_EXTRAS = [
    "softwarehub_cp4d_vars_generation.py",
    "confluent_platform_vars_generation.py",
    "ibm_concert_vars_generation.py",
    "src/helpers/config_file_jinja2_templates",
    "src/helpers/sortable-kv-dependencies",
]
NOTEBOOKS = {
    "cpd": ("softwarehub_cp4d_vars_generation.py", "cp4d_config", "cpd_vars.sh", "cpd_vars_template_editor", {}),
    "confluent": ("confluent_platform_vars_generation.py", "confluent_platform_config", "confluent_vars.sh", "confluent_vars_template_editor", {}),
    "concert": ("ibm_concert_vars_generation.py", "concert_config", "concert_vars.sh", "concert_vars_template_editor", {"config_errors": [], "config_warnings": []}),
}


def run_notebook(sandbox, notebook, values):
    driver = sandbox.repo / "nb_driver.py"
    driver.write_text(NOTEBOOK_DRIVER)
    # The Concert notebook asks GitHub for releases; a dead proxy makes it use its offline list.
    env = sandbox.env({"HTTPS_PROXY": "http://127.0.0.1:9", "https_proxy": "http://127.0.0.1:9"})
    done = subprocess.run(
        [sys.executable, "nb_driver.py", notebook, json.dumps(values)],
        cwd=sandbox.repo,
        env=env,
        capture_output=True,
        text=True,
        timeout=240, check=False,
    )
    assert done.returncode == 0, done.stdout[-2000:] + done.stderr[-2000:]
    line = next(item for item in done.stdout.splitlines() if item.startswith("RESULT="))
    return json.loads(line[len("RESULT="):])


@pytest.fixture(scope="module")
def nb_sb():
    with make_sandbox(extra=NOTEBOOK_EXTRAS) as sandbox:
        yield sandbox


class TestNotebooksHeadless:
    """Real notebooks, real cells, fake widget values. Runs inside the temp repo."""

    def _reset(self, sandbox):
        shutil.rmtree(sandbox.repo / "configs", ignore_errors=True)

    def _values(self, editor, **extra):
        return {
            "mcm_enable_checkbox": True,
            "mcm_name_input": "",
            "cluster_url_input": URL_A,
            "save_to_config_dir_button": True,
            "mcm_overwrite_checkbox": False,
            editor: f'export OCP_URL="{URL_A}"\n',
            **extra,
        }

    @pytest.mark.parametrize("key", list(NOTEBOOKS))
    def test_save_goes_to_the_cluster_and_updates_state(self, nb_sb, key):
        self._reset(nb_sb)
        notebook, product, vars_file, editor, extra = NOTEBOOKS[key]
        result = run_notebook(nb_sb, notebook, self._values(editor, **extra))
        assert result["saved"]
        assert (nb_sb.repo / "configs/clusters/alpha" / product / vars_file).is_file()
        assert not (nb_sb.repo / "configs" / product).exists()
        values = state.read_state(repo=nb_sb.repo, env=nb_sb.env())
        assert (values["MULTI_CLUSTER_MANAGEMENT"], values["MCM_CURRENT_CLUSTER"], values["MCM_CLUSTERS"]) == ("true", "alpha", "alpha")

    @pytest.mark.parametrize("key", list(NOTEBOOKS))
    def test_unticked_saves_flat(self, nb_sb, key):
        self._reset(nb_sb)
        notebook, product, vars_file, editor, extra = NOTEBOOKS[key]
        result = run_notebook(nb_sb, notebook, self._values(editor, mcm_enable_checkbox=False, **extra))
        assert result["saved"]
        assert (nb_sb.repo / "configs" / product / vars_file).is_file()
        assert not (nb_sb.repo / "configs/clusters").exists()
        assert state.read_state(repo=nb_sb.repo, env=nb_sb.env())["MULTI_CLUSTER_MANAGEMENT"] == "false"

    @pytest.mark.parametrize("key", list(NOTEBOOKS))
    def test_unticked_save_for_a_delineated_cluster_goes_into_its_folder(self, nb_sb, key):
        self._reset(nb_sb)
        nb_sb.write_cluster_marker("alpha", URL_A)
        notebook, product, vars_file, editor, extra = NOTEBOOKS[key]
        result = run_notebook(nb_sb, notebook, self._values(editor, mcm_enable_checkbox=False, **extra))
        assert result["saved"]
        assert (nb_sb.repo / "configs/clusters/alpha" / product / vars_file).is_file()
        assert not (nb_sb.repo / "configs" / product).exists()
        values = state.read_state(repo=nb_sb.repo, env=nb_sb.env())
        assert (values["MULTI_CLUSTER_MANAGEMENT"], values["MCM_CURRENT_CLUSTER"], values["MCM_CLUSTERS"]) == ("false", "", "alpha")

    def test_overwrite_guard_stops_the_write(self, nb_sb):
        self._reset(nb_sb)
        nb_sb.write_config("cpd", ocp_url=URL_B, cluster="alpha", login=False)
        notebook, product, vars_file, editor, extra = NOTEBOOKS["cpd"]
        before = (nb_sb.repo / "configs/clusters/alpha" / product / vars_file).read_text()
        result = run_notebook(nb_sb, notebook, self._values(editor, **extra))
        assert result["not_saved"] and not result["saved"]
        assert (nb_sb.repo / "configs/clusters/alpha" / product / vars_file).read_text() == before
        assert not state_file(nb_sb).exists()

    def test_concert_credentials_come_from_the_selected_cluster(self, nb_sb):
        self._reset(nb_sb)
        saved = nb_sb.write_config(
            "concert", ocp_url=URL_A, cluster="alpha", login=False, extra={"CONCERT_ADMIN_PASSWORD": "from-alpha"}
        )
        text = saved.read_text().replace("export CONCERT_ADMIN_PASSWORD=\"from-alpha\"", "export CONCERT_ADMIN_PASSWORD='from-alpha'")
        saved.write_text(text)
        notebook, _, _, editor, extra = NOTEBOOKS["concert"]
        values = self._values(editor, save_to_config_dir_button=False, file_getter=str(saved), **extra)
        result = run_notebook(nb_sb, notebook, values)
        assert result["values"]["admin_password_input"] == "from-alpha"


CPD_TEMPLATE = REPO / "src/helpers/config_file_jinja2_templates/cpd_variable_template.sh.j2"
RUNNER_KNOBS = {
    "INSTALL_RUNNER_STORAGE_CLASS": "",
    "INSTALL_RUNNER_IMAGE_SOURCE": "build-in-cluster",
    "INSTALL_RUNNER_IMAGE": "",
    "INSTALL_RUNNER_PVC_SIZE": "20Gi",
    "INSTALL_RUNNER_AUTO_RESUME": "true",
    "INSTALL_RUNNER_MAX_RESUMES": "3",
    "INSTALL_RUNNER_KEEP_ADMIN": "false",
    "INSTALL_RUNNER_NODE_SELECTOR": "",
    "INSTALL_RUNNER_TTY_SIZE": "120x50",
    "INSTALL_RUNNER_ROLLOUT_TIMEOUT": "900",
    "INSTALL_RUNNER_SWHCC_IMAGE": "",
    "INSTALL_RUNNER_SWHCC_PULL_SECRET": "",
    "INSTALL_RUNNER_SWHCC_MEMORY_LIMIT": "4Gi",
}


def render_cpd_vars(**values):
    """The cpd_vars.sh template with the fewest values it needs to render, plus `values`."""
    from helpers.jinja2_template_rendering_helpers import render_template_from_environment

    base = {"cp4d_install_project_naming": {}, "cp4d_private_registry_naming": {}, "components_to_install_str": ""}
    return render_template_from_environment(template_path=str(CPD_TEMPLATE), extra_vars={**base, **values}, print_missing=False)


def lines_of(text, prefix):
    return [line for line in text.splitlines() if line.startswith(prefix)]


class TestRunnerTemplate:
    """I7: INSTALL_RUN_MODE and the INSTALL_RUNNER_* knobs in cpd_vars.sh."""

    def test_default_is_local_with_every_knob_commented_at_its_default(self):
        text = render_cpd_vars()
        assert lines_of(text, "export INSTALL_RUN") == ['export INSTALL_RUN_MODE="local"']
        assert lines_of(text, "# export INSTALL_RUNNER_") == [f'# export {k}="{v}"' for k, v in RUNNER_KNOBS.items()]
        # The knob block keeps one blank line before the cluster section, as before it was added.
        assert '# export INSTALL_RUNNER_SWHCC_MEMORY_LIMIT="4Gi"\n\nexport OCP_URL=' in text

    @pytest.mark.parametrize("blank", ["", None])
    def test_a_blank_mode_is_local(self, blank):
        assert 'export INSTALL_RUN_MODE="local"' in render_cpd_vars(install_run_mode=blank)

    def test_set_values_are_exported_and_the_rest_stay_commented(self):
        text = render_cpd_vars(
            install_run_mode="cluster",
            install_runner_settings={"INSTALL_RUNNER_STORAGE_CLASS": " ocs-a ", "INSTALL_RUNNER_NODE_SELECTOR": "role=infra",
                                     "INSTALL_RUNNER_PVC_SIZE": "", "INSTALL_RUNNER_IMAGE": None},
        )
        assert lines_of(text, "export INSTALL_RUN") == [
            'export INSTALL_RUN_MODE="cluster"',
            'export INSTALL_RUNNER_STORAGE_CLASS="ocs-a"',
            'export INSTALL_RUNNER_NODE_SELECTOR="role=infra"',
        ]
        commented = lines_of(text, "# export INSTALL_RUNNER_")
        assert len(commented) == len(RUNNER_KNOBS) - 2
        assert '# export INSTALL_RUNNER_PVC_SIZE="20Gi"' in commented and '# export INSTALL_RUNNER_IMAGE=""' in commented

    def test_the_rendered_file_is_valid_zsh_and_sets_the_values(self, tmp_path):
        path = tmp_path / "cpd_vars.sh"
        path.write_text(render_cpd_vars(install_run_mode="cluster", install_runner_settings={"INSTALL_RUNNER_MAX_RESUMES": "5"}))
        assert subprocess.run(["zsh", "-n", str(path)], capture_output=True, check=False).returncode == 0
        done = subprocess.run(
            ["zsh", "-c", 'source "$1" >/dev/null 2>&1; print -r -- "$INSTALL_RUN_MODE ${INSTALL_RUNNER_MAX_RESUMES:-} ${INSTALL_RUNNER_PVC_SIZE:-unset}"', "x", str(path)],
            capture_output=True, text=True, env={"PATH": os.environ["PATH"], "HOME": str(tmp_path)}, check=False,
        )
        assert done.stdout.strip() == "cluster 5 unset"


SAVED_RUNNER_VARS = (
    'export OCP_URL="{url}"\n'
    '# local or cluster\n'
    'export INSTALL_RUN_MODE="local"\n'
    'export INSTALL_RUN_MODE="cluster"\n'
    "export INSTALL_RUNNER_STORAGE_CLASS='ocs-alpha'\n"
    '  export INSTALL_RUNNER_PVC_SIZE=40Gi   # bigger cache\n'
    '# export INSTALL_RUNNER_IMAGE_SOURCE="prebuilt"\n'
)


class TestRunnerNotebook:
    """I7: the run-mode widget and knobs start from the selected cluster's saved cpd_vars.sh, so a save keeps them."""

    def _values(self, **extra):
        return {
            "mcm_enable_checkbox": True,
            "mcm_name_input": "",
            "cluster_url_input": URL_A,
            "mcm_overwrite_checkbox": False,
            **extra,
        }

    def test_widgets_start_from_the_saved_file(self, nb_sb):
        shutil.rmtree(nb_sb.repo / "configs", ignore_errors=True)
        saved = nb_sb.write_config("cpd", cluster="alpha", text=SAVED_RUNNER_VARS.format(url=URL_A))
        result = run_notebook(nb_sb, "softwarehub_cp4d_vars_generation.py",
                              self._values(save_to_config_dir_button=False, file_getter=str(saved)))
        assert result["values"]["install_run_mode_select"] == "cluster"
        settings = result["values"]["install_runner_settings"]
        assert list(settings) == list(RUNNER_KNOBS)
        assert settings["INSTALL_RUNNER_STORAGE_CLASS"] == "ocs-alpha"
        assert settings["INSTALL_RUNNER_PVC_SIZE"] == "40Gi"
        assert settings["INSTALL_RUNNER_IMAGE_SOURCE"] == ""  # commented out: the default

    def test_no_saved_file_starts_local_and_blank(self, nb_sb):
        shutil.rmtree(nb_sb.repo / "configs", ignore_errors=True)
        result = run_notebook(nb_sb, "softwarehub_cp4d_vars_generation.py", self._values(save_to_config_dir_button=False))
        assert result["values"]["install_run_mode_select"] == "local"
        assert set(result["values"]["install_runner_settings"].values()) == {""}

    def test_a_save_keeps_the_cluster_values_and_only_that_clusters_own(self, nb_sb):
        """A save of alpha's file from a blank editor renders the template: alpha's values come back, beta's never.

        Headless app.run does not re-run cells on a state change, so the file the state cell would pick is
        handed in, as for Concert. Which file that is comes from mcm_nb.existing_vars_file (TestSmallHelpers).
        """
        shutil.rmtree(nb_sb.repo / "configs", ignore_errors=True)
        saved = nb_sb.write_config("cpd", cluster="alpha", text=SAVED_RUNNER_VARS.format(url=URL_A))
        nb_sb.write_config("cpd", cluster="beta", text=f'export OCP_URL="{URL_B}"\nexport INSTALL_RUNNER_STORAGE_CLASS="ocs-beta"\n')
        result = run_notebook(nb_sb, "softwarehub_cp4d_vars_generation.py",
                              self._values(save_to_config_dir_button=True, cpd_vars_template_editor="", file_getter=str(saved)))
        assert result["saved"]
        text = (nb_sb.repo / "configs/clusters/alpha/cp4d_config/cpd_vars.sh").read_text()
        assert lines_of(text, "export INSTALL_RUN") == [
            'export INSTALL_RUN_MODE="cluster"',
            'export INSTALL_RUNNER_STORAGE_CLASS="ocs-alpha"',
            'export INSTALL_RUNNER_PVC_SIZE="40Gi"',
        ]
        assert '# export INSTALL_RUNNER_IMAGE_SOURCE="build-in-cluster"' in text
        assert "ocs-beta" not in text

    def test_the_template_reads_the_widget_names(self):
        text = (REPO / "softwarehub_cp4d_vars_generation.py").read_text()
        assert "install_run_mode = install_run_mode_select.value" in text
        assert "install_runner_settings = records_to_dict(" in text
        assert 'mcm_nb.existing_vars_file(mcm_target, cpd_vars_filename)' in text
        for key in RUNNER_KNOBS:
            assert f'"{key}"' in text, key


GENERATOR_EXTRAS = [
    "pyproject.toml",
    "src/helpers/version_catalog.json",
    "src/helpers/config_file_jinja2_templates",
    "scripts/install_confluent_platform/0_confluent_prepare_template_config.sh",
    "scripts/install_confluent_platform/install_confluent_platform_flink_addon/0_flink_prepare_template_config.sh",
    "scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh",
    "scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/0_swhub_control_center_generate_config.sh",
    "src/utilities/kubecost_utils/generate_kubecost_config.sh",
    "scripts/private_registry_mirroring/0_initial_setup",
]
GENERATORS = {
    "datastax": ("scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh", ["--empty"], "datastax_mc_config/datastax_mc_vars.sh", None),
    "control-center": ("scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/0_swhub_control_center_generate_config.sh", ["--empty"], "cp4d_config/swhub_control_center/swhub_control_center_vars.sh", None),
    "kubecost": ("src/utilities/kubecost_utils/generate_kubecost_config.sh", ["--empty", "--source", "marketplace"], "kubecost_config/kubecost_vars.sh", None),
    "mirror": ("scripts/private_registry_mirroring/0_initial_setup/0.0_generate_mirror_config.sh", [], "registry_mirror_config/registry_mirror_vars.sh", None),
    "confluent": ("scripts/install_confluent_platform/0_confluent_prepare_template_config.sh", ["--size", "small"], "confluent_platform_config/confluent_vars.sh", "confluent"),
    "flink": ("scripts/install_confluent_platform/install_confluent_platform_flink_addon/0_flink_prepare_template_config.sh", ["--size", "small"], "confluent_platform_config/confluent_vars.sh", "confluent"),
}


@pytest.fixture
def gsb():
    with make_sandbox(extra=GENERATOR_EXTRAS) as sandbox:
        os.symlink(REPO / ".venv", sandbox.repo / ".venv")
        yield sandbox


def run_generator(sandbox, key, *flags, env=None):
    script, args, _, _ = GENERATORS[key]
    return sandbox.run_script(script, args=[*args, *flags], env=env)


def prep(sandbox, key, cluster=None):
    product = GENERATORS[key][3]
    if product:
        sandbox.write_config(product, cluster=cluster, login=False)


@pytest.mark.parametrize("key", list(GENERATORS))
class TestGenerators:
    def test_off_writes_flat(self, gsb, key):
        prep(gsb, key)
        result = run_generator(gsb, key)
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gsb.repo / "configs" / GENERATORS[key][2]).is_file()
        assert not (gsb.repo / "configs/clusters").exists()
        assert state.read_state(repo=gsb.repo, env=gsb.env())["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_target_cluster_writes_to_that_folder_and_registers(self, gsb, key):
        """Mode off: a delineated cluster named by flag works and keeps the mode off."""
        gsb.write_cluster_marker("alpha", URL_A)
        prep(gsb, key, cluster="alpha")
        result = run_generator(gsb, key, "--target-cluster", "alpha")
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gsb.repo / "configs/clusters/alpha" / GENERATORS[key][2]).is_file()
        assert not (gsb.repo / "configs" / GENERATORS[key][2]).exists()
        values = state.read_state(repo=gsb.repo, env=gsb.env())
        assert values["MULTI_CLUSTER_MANAGEMENT"] == "false"
        assert "alpha" in values["MCM_CLUSTERS"].split()
        assert "cannot be undone" not in result.stderr

    def test_off_names_only_a_delineated_cluster(self, gsb, key):
        result = run_generator(gsb, key, "--target-cluster", "alpha")
        assert result.returncode != 0
        assert "has no folder of its own" in result.stderr and "multi-cluster mode is off" in result.stderr
        assert not (gsb.repo / "configs/clusters").exists()

    def test_off_refuses_a_retired_cluster(self, gsb, key):
        state.register_cluster("alpha", URL_A, repo=gsb.repo, env=gsb.env())
        state.mark_retired("alpha", repo=gsb.repo)
        result = run_generator(gsb, key, "--target-cluster", "alpha")
        assert result.returncode != 0
        assert "retired" in result.stderr and "multi_cluster.sh add alpha" in result.stderr
        assert not (gsb.repo / "configs/clusters/alpha" / GENERATORS[key][2]).exists()

    def test_on_new_cluster_warns_that_it_is_one_way(self, gsb, key):
        set_on(gsb)
        prep(gsb, key, cluster="alpha")
        result = run_generator(gsb, key, "--target-cluster", "alpha")
        assert result.returncode == 0, result.stdout + result.stderr
        assert "[WARN] Cluster 'alpha' now has its own folder" in result.stderr
        assert "cannot be undone" in result.stderr and "preferred" in result.stderr
        assert state.is_delineated("alpha", repo=gsb.repo)

    def test_on_uses_the_current_cluster(self, gsb, key):
        set_on(gsb, [("alpha", URL_A), ("beta", URL_B)], "beta")
        prep(gsb, key, cluster="beta")
        result = run_generator(gsb, key)
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gsb.repo / "configs/clusters/beta" / GENERATORS[key][2]).is_file()

    def test_on_with_no_selection_fails_with_guidance(self, gsb, key):
        set_on(gsb, [("alpha", URL_A), ("beta", URL_B)], "")
        result = run_generator(gsb, key)
        assert result.returncode != 0
        assert "no cluster is selected" in result.stderr

    def test_bad_name_is_refused(self, gsb, key):
        result = run_generator(gsb, key, "--target-cluster", "Bad!")
        assert result.returncode != 0
        assert "Invalid cluster name" in result.stderr

    def test_help_needs_no_state(self, gsb, key):
        state_file(gsb).parent.mkdir(parents=True, exist_ok=True)
        state_file(gsb).write_text('export APPLY_TO_ALL="maybe"\n')
        result = run_generator(gsb, key, "--help")
        assert result.returncode == 0, result.stdout + result.stderr
        assert "--target-cluster" in result.stdout


def test_control_center_cluster_flag_still_means_same_or_different(gsb):
    gsb.write_cluster_marker("alpha", URL_A)
    result = run_generator(gsb, "control-center", "--cluster", "different", "--target-cluster", "alpha")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (gsb.repo / "configs/clusters/alpha/cp4d_config/swhub_control_center/swhub_control_center_vars.sh").is_file()


def test_generator_ignores_an_inherited_configs_root_while_off(gsb):
    other = gsb.tmp / "other-checkout"
    env = {"CONFIGS_ROOT": str(other / "configs"), "_CP4D_REPO_ROOT": str(other)}
    result = gsb.run_script(GENERATORS["datastax"][0], args=["--empty"], env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (gsb.repo / "configs/datastax_mc_config/datastax_mc_vars.sh").is_file()
    assert not other.exists()


def test_register_records_the_url_from_the_written_file(gsb):
    gsb.write_cluster_marker("alpha")
    gsb.write_config("cpd", ocp_url=URL_A, cluster="alpha", login=False)
    (gsb.repo / "configs/clusters/alpha/cp4d_config/cpd_vars.sh").write_text(
        f'export OCP_URL="{URL_A}"\nexport OCP_USERNAME="kubeadmin"\nexport OCP_PASSWORD="x"\nexport STG_CLASS_BLOCK="sc"\nexport IBM_ENTITLEMENT_KEY="k"\n'
    )
    script = GENERATORS["datastax"][0]
    result = gsb.run_script(script, args=["--from-cpd", "--target-cluster", "alpha"])
    assert result.returncode == 0, result.stdout + result.stderr
    assert f'OCP_URL="{URL_A}"' in (gsb.repo / "configs/clusters/alpha/.cluster").read_text()


class TestGeneratorUrlOwner:
    """Mode off, no name: a flat file of a delineated cluster sends the write into that cluster's folder."""

    def test_a_flat_cp4d_config_of_a_delineated_cluster_redirects(self, gsb):
        gsb.write_cluster_marker("alpha", URL_A)
        gsb.write_config("cpd", ocp_url=URL_A, login=False)
        gsb.write_config("confluent", cluster="alpha", login=False)
        result = run_generator(gsb, "confluent")
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gsb.repo / "configs/clusters/alpha" / GENERATORS["confluent"][2]).is_file()
        assert not (gsb.repo / "configs" / GENERATORS["confluent"][2]).exists()
        assert "belongs to cluster 'alpha'" in result.stderr
        assert state.read_state(repo=gsb.repo, env=gsb.env())["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_the_flat_output_file_counts_too(self, gsb):
        gsb.write_cluster_marker("alpha", URL_A)
        flat = gsb.repo / "configs" / GENERATORS["datastax"][2]
        flat.parent.mkdir(parents=True)
        flat.write_text(f'export OCP_URL="{URL_A}"\n')
        result = run_generator(gsb, "datastax", "--force")
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gsb.repo / "configs/clusters/alpha" / GENERATORS["datastax"][2]).is_file()
        assert flat.read_text() == f'export OCP_URL="{URL_A}"\n'

    def test_a_flat_config_of_another_cluster_stays_flat(self, gsb):
        gsb.write_cluster_marker("alpha", URL_A)
        gsb.write_config("cpd", ocp_url=URL_B, login=False)
        gsb.write_config("confluent", ocp_url=URL_B, login=False)
        result = run_generator(gsb, "confluent")
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gsb.repo / "configs" / GENERATORS["confluent"][2]).is_file()
        assert "belongs to cluster" not in result.stderr

    def test_a_retired_owner_is_refused_with_guidance(self, gsb):
        state.register_cluster("alpha", URL_A, repo=gsb.repo, env=gsb.env())
        state.mark_retired("alpha", repo=gsb.repo)
        gsb.write_config("cpd", ocp_url=URL_A, login=False)
        gsb.write_config("confluent", ocp_url=URL_A, login=False)
        result = run_generator(gsb, "confluent")
        assert result.returncode != 0
        assert "retired" in result.stderr and "multi_cluster.sh add alpha" in result.stderr

    def test_two_owners_are_refused(self, gsb):
        gsb.write_cluster_marker("alpha", URL_A)
        gsb.write_cluster_marker("beta", URL_B)
        gsb.write_config("cpd", ocp_url=URL_A, login=False)
        gsb.write_config("confluent", ocp_url=URL_B, login=False)
        result = run_generator(gsb, "confluent")
        assert result.returncode != 0
        assert "several clusters" in result.stderr

    def test_a_delineated_pin_holds_with_the_mode_off(self, gsb):
        gsb.write_cluster_marker("alpha", URL_A)
        result = run_generator(gsb, "datastax", env={"MCM_CLUSTER": "alpha"})
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gsb.repo / "configs/clusters/alpha" / GENERATORS["datastax"][2]).is_file()

    def test_a_stale_pin_is_ignored_with_the_mode_off(self, gsb):
        result = run_generator(gsb, "datastax", env={"MCM_CLUSTER": "ghost"})
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gsb.repo / "configs" / GENERATORS["datastax"][2]).is_file()
        assert not (gsb.repo / "configs/clusters").exists()
