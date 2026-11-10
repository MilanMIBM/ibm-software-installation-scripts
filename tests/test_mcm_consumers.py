"""Multi-cluster consumers (plan P9): Secrets Manager prefix, wxO ADK env name, the TUIs' cpd-cli and paths."""

import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "helpers"))

import ibmcloud_secrets_manager_helpers as smh
from mcm_harness import make_sandbox

REPO = Path(__file__).resolve().parents[1]
URL_A = "https://api.itz-a.example.com:6443"
UPLOAD = "src/utilities/ibmcloud_secrets_manager_variable_management/ibmcloud-secrets-manager-upload-update-cpd-vars.py"
RETRIEVE = "src/utilities/ibmcloud_secrets_manager_variable_management/ibmcloud-secrets-manager-retrieve-cpd-vars.py"
WXO = (
    "scripts/install_cloud_pak_for_data/5_component_specific_scripts/"
    "wxo_adk_and_custom_model_import/add_wxo_onprem_environment.sh"
)
VENV_PY = REPO / ".venv" / "bin" / "python"
WXO_EXPORTS = {"WXO_URL": "https://cpd.example.com", "CPD_APIKEY": "key", "CPD_USERNAME": "cpadmin"}


def write_state(on=True, clusters="itz-a itz-b", current="itz-a"):
    # Written by hand: write_state() would look for cluster folders in the real configs/ when the file is missing.
    Path(os.environ["MCM_STATE_FILE"]).write_text(
        f'export MULTI_CLUSTER_MANAGEMENT="{"true" if on else "false"}"\n'
        f'export MCM_CLUSTERS="{clusters}"\n'
        f'export MCM_CURRENT_CLUSTER="{current}"\n'
    )


@pytest.fixture(autouse=True)
def _no_prefix_settings(monkeypatch):
    monkeypatch.delenv("CPD_SECRETS_PREFIX", raising=False)


@pytest.fixture
def hermetic_repo(monkeypatch, tmp_path):
    """The Secrets Manager helpers look for cluster folders in a temp repo, not this checkout's configs/."""
    import multi_cluster_state

    monkeypatch.setattr(multi_cluster_state, "repo_root", lambda: tmp_path)
    return tmp_path


def delineate(repo, name, url=URL_A, retired=False):
    marker = repo / "configs" / "clusters" / name / ".cluster"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(f'NAME="{name}"\nOCP_URL="{url}"\nDELINEATED="true"\n' + ('RETIRED="true"\n' if retired else ""))


@pytest.mark.usefixtures("hermetic_repo")
class TestSecretPrefix:
    def test_off_keeps_the_prefixes_it_always_had(self, monkeypatch):
        write_state(on=False, clusters="", current="")
        assert smh.resolve_prefix(None) == "cpd-config"
        assert smh.resolve_prefix("itz-42") == "itz-42"
        monkeypatch.setenv("CPD_SECRETS_PREFIX", "from-env")
        assert smh.resolve_prefix(None) == "from-env"

    def test_off_ignores_a_leftover_cluster_variable(self, monkeypatch):
        write_state(on=False, clusters="", current="")
        monkeypatch.setenv("MCM_CLUSTER", "itz-a")
        assert smh.resolve_prefix(None) == "cpd-config"

    def test_on_default_names_the_current_cluster(self):
        write_state()
        assert smh.resolve_prefix(None) == "cpd-config-itz-a"

    def test_on_pinned_cluster_beats_the_current_one(self, monkeypatch):
        write_state()
        monkeypatch.setenv("MCM_CLUSTER", "itz-b")
        assert smh.resolve_prefix(None) == "cpd-config-itz-b"

    def test_on_only_registered_cluster_is_used(self):
        write_state(clusters="itz-a", current="")
        assert smh.resolve_prefix(None) == "cpd-config-itz-a"

    def test_two_clusters_never_share_a_secret_name(self, monkeypatch):
        write_state()
        first = smh.secret_name_for(smh.resolve_prefix(None), "cpd_vars.sh")
        monkeypatch.setenv("MCM_CLUSTER", "itz-b")
        second = smh.secret_name_for(smh.resolve_prefix(None), "cpd_vars.sh")
        assert first == "cpd-config-itz-a-cpd-vars-sh"
        assert second == "cpd-config-itz-b-cpd-vars-sh"

    def test_on_standing_env_prefix_gets_the_cluster(self, monkeypatch):
        write_state()
        monkeypatch.setenv("CPD_SECRETS_PREFIX", "team")
        assert smh.resolve_prefix(None) == "team-itz-a"

    @pytest.mark.parametrize("value", ["itz-a", "team-itz-a"])
    def test_on_env_prefix_already_naming_the_cluster_is_not_doubled(self, monkeypatch, value):
        write_state()
        monkeypatch.setenv("CPD_SECRETS_PREFIX", value)
        assert smh.resolve_prefix(None) == value

    def test_on_flag_is_used_as_given(self):
        write_state()
        assert smh.resolve_prefix("my-bundle") == "my-bundle"

    def test_on_without_a_selected_cluster_stops(self):
        write_state(current="")
        with pytest.raises(ValueError, match="no cluster is selected"):
            smh.resolve_prefix(None)

    def test_invalid_state_file_stops(self):
        Path(os.environ["MCM_STATE_FILE"]).write_text('export MULTI_CLUSTER_MANAGEMENT="maybe"\n')
        with pytest.raises(ValueError, match="MULTI_CLUSTER_MANAGEMENT"):
            smh.resolve_prefix(None)


def secret(name, file_name=None):
    meta = {"name": name, "id": name}
    if file_name:
        meta["custom_metadata"] = {smh.META_FILE: file_name}
    return meta


class FakeResult:
    def __init__(self, secrets):
        self.secrets = secrets

    def get_result(self):
        return {"secrets": self.secrets, "total_count": len(self.secrets)}


class FakeClient:
    def __init__(self, secrets):
        self.secrets = secrets

    def list_secrets(self, offset=0, **_):
        return FakeResult(self.secrets[offset:])


BUNDLES = [
    secret("cpd-config-cpd-vars-sh", "cpd_vars.sh"),
    secret("cpd-config-prod-cpd-vars-sh", "cpd_vars.sh"),
    secret("cpd-config-prod-install-options-yml", "install-options.yml"),
    secret("cpd-config-prod-cpd-vars-sh-v2", "cpd_vars.sh"),
    secret("cpd-config-prod-2-cpd-vars-sh", "cpd_vars.sh"),
]


@pytest.mark.usefixtures("hermetic_repo")
class TestBundleListing:
    """Exact bundles with the mode on; the old --prefix gathering with it off."""

    @pytest.fixture(autouse=True)
    def _mode_on(self):
        write_state()

    def names(self, prefix, secrets=BUNDLES):
        return [m["name"] for m in smh.list_bundle_secrets(FakeClient(secrets), "group", prefix)]

    def test_off_a_partial_prefix_gathers_every_bundle_it_starts(self):
        write_state(on=False, clusters="", current="")
        assert self.names("cpd-config-pro") == [
            "cpd-config-prod-2-cpd-vars-sh",
            "cpd-config-prod-cpd-vars-sh",
            "cpd-config-prod-cpd-vars-sh-v2",
            "cpd-config-prod-install-options-yml",
        ]

    def test_off_the_default_bundle_includes_longer_names_as_before(self):
        write_state(on=False, clusters="", current="")
        assert len(self.names("cpd-config")) == len(BUNDLES)

    def test_flat_bundle_leaves_per_cluster_secrets_out(self):
        assert self.names("cpd-config") == ["cpd-config-cpd-vars-sh"]

    def test_cluster_bundle_keeps_iterations_and_leaves_out_a_longer_name(self):
        assert self.names("cpd-config-prod") == [
            "cpd-config-prod-cpd-vars-sh",
            "cpd-config-prod-cpd-vars-sh-v2",
            "cpd-config-prod-install-options-yml",
        ]

    def test_file_whose_own_name_ends_like_an_iteration(self):
        secrets = [secret("cpd-config-notes-v2", "notes-v2")]
        assert self.names("cpd-config", secrets) == ["cpd-config-notes-v2"]

    def test_secret_with_no_recorded_file_matches_by_name(self):
        secrets = [secret("cpd-config-by-hand"), secret("other-by-hand")]
        assert self.names("cpd-config", secrets) == ["cpd-config-by-hand"]

    def test_find_iterations_still_takes_a_base_name(self):
        found = smh.find_iterations(FakeClient(BUNDLES), "group", "cpd-config-prod-cpd-vars-sh")
        assert [i for i, _ in found] == [1, 2]


def run_python(sb, rel, args, extra_env=None):
    env = sb.env({"PYTHONDONTWRITEBYTECODE": "1", **(extra_env or {})})
    for name in ("SECRETS_MANAGER_APIKEY", "IBM_CLOUD_API_KEY", "IBMCLOUD_API_KEY"):
        env.pop(name, None)
    return subprocess.run(
        [str(VENV_PY), str(sb.repo / rel), *args],
        env=env, cwd=sb.repo, capture_output=True, text=True, timeout=60, check=False,
    )


class TestRefuseFlatWrites:
    """Mode on, no cluster selected: nothing is written to the flat folder."""

    def sandbox(self):
        sb = make_sandbox(extra=["src/utilities/ibmcloud_secrets_manager_variable_management"])
        (sb.repo / "configs").mkdir(exist_ok=True)
        for name in ("itz-a", "itz-b"):
            sb.write_cluster_marker(name, f"https://api.{name}.example.com:6443")
        (sb.repo / "configs" / "multi_cluster_management.sh").write_text(
            'export MULTI_CLUSTER_MANAGEMENT="true"\nexport MCM_CLUSTERS="itz-a itz-b"\nexport MCM_CURRENT_CLUSTER=""\n'
        )
        return sb

    def test_retrieve_to_the_default_folder_is_refused(self):
        with self.sandbox() as sb:
            result = run_python(sb, RETRIEVE, ["--prefix", "x"])
            assert result.returncode != 0
            assert "no cluster is selected" in result.stderr
            assert not (sb.repo / "configs" / "cp4d_config").exists()

    def test_retrieve_with_an_output_folder_goes_on_past_that_check(self):
        with self.sandbox() as sb:
            result = run_python(sb, RETRIEVE, ["--prefix", "x", "--output-dir", str(sb.root / "out")])
            assert result.returncode != 0
            assert "no cluster is selected" not in result.stderr

    def test_retrieve_listing_writes_nothing_so_is_not_refused(self):
        with self.sandbox() as sb:
            result = run_python(sb, RETRIEVE, ["--prefix", "x", "--list"])
            assert result.returncode != 0
            assert "no cluster is selected" not in result.stderr

    def test_tui_config_dir_refuses(self, monkeypatch):
        from tui.instance_manager import settings

        monkeypatch.delenv("CONFIG_DIR", raising=False)
        write_state(current="")
        with pytest.raises(ValueError, match="no cluster is selected"):
            settings.config_dir()

    def test_tui_entry_point_stops_with_guidance(self, monkeypatch, capsys):
        from tui.instance_manager import __main__ as tui

        monkeypatch.delenv("CONFIG_DIR", raising=False)
        write_state(current="")
        assert tui.main(["--once"]) == 2
        assert "no cluster is selected" in capsys.readouterr().err

    def test_tui_details_migration_stops_with_guidance(self, monkeypatch, capsys):
        from tui.instance_manager.ops import migrate_details

        monkeypatch.delenv("CONFIG_DIR", raising=False)
        write_state(current="")
        assert migrate_details.main(["--apply"]) == 1
        assert "no cluster is selected" in capsys.readouterr().err

    def test_a_config_dir_from_the_env_loader_still_works(self, monkeypatch):
        from tui.instance_manager import settings

        with tempfile.TemporaryDirectory() as tmp:
            monkeypatch.setenv("CONFIG_DIR", tmp)
            write_state(current="")
            assert settings.config_dir() == Path(tmp).resolve()


class TestUploadDryRun:
    def sandbox(self):
        sb = make_sandbox(extra=["src/utilities/ibmcloud_secrets_manager_variable_management"])
        (sb.repo / "configs").mkdir(exist_ok=True)
        return sb

    def enable(self, sb):
        sb.run_zsh(
            "source src/helpers/multi_cluster_helpers.sh\n"
            f"mcm_register itz-a {URL_A}\nmcm_register itz-b https://api.itz-b.example.com:6443\n"
            "mcm_set_current itz-a\nmcm_write_state MULTI_CLUSTER_MANAGEMENT=true\n",
            check=True,
        )

    def test_on_reads_the_cluster_config_and_names_the_cluster(self):
        with self.sandbox() as sb:
            self.enable(sb)
            sb.write_config("cpd", cluster="itz-a")
            result = run_python(sb, UPLOAD, ["--dry-run", "--no-install-options"])
            assert result.returncode == 0, result.stdout + result.stderr
            assert "Bundle prefix : cpd-config-itz-a" in result.stdout
            assert "secret name : cpd-config-itz-a-cpd-vars-sh" in result.stdout
            assert "configs/clusters/itz-a/cp4d_config/cpd_vars.sh" in result.stdout

    def test_on_mcm_cluster_selects_the_other_cluster(self):
        with self.sandbox() as sb:
            self.enable(sb)
            sb.write_config("cpd", cluster="itz-b")
            result = run_python(sb, UPLOAD, ["--dry-run", "--no-install-options"], {"MCM_CLUSTER": "itz-b"})
            assert result.returncode == 0, result.stdout + result.stderr
            assert "secret name : cpd-config-itz-b-cpd-vars-sh" in result.stdout

    def test_off_is_the_flat_bundle(self):
        with self.sandbox() as sb:
            sb.write_config("cpd")
            result = run_python(sb, UPLOAD, ["--dry-run", "--no-install-options"])
            assert result.returncode == 0, result.stdout + result.stderr
            assert "Bundle prefix : cpd-config\n" in result.stdout
            assert "secret name : cpd-config-cpd-vars-sh" in result.stdout

    def test_help_explains_the_cluster_suffix(self):
        with self.sandbox() as sb:
            for rel in (UPLOAD, RETRIEVE):
                result = run_python(sb, rel, ["--help"])
                assert result.returncode == 0, result.stdout + result.stderr
                assert "cpd-config-<cluster>" in result.stdout


class TestWxoEnvName:
    def sandbox(self):
        sb = make_sandbox(extra=[WXO])
        fake = sb.bin / "orchestrate"
        fake.write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$ORCHESTRATE_LOG"\n')
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        return sb

    def enable(self, sb):
        sb.run_zsh(
            "source src/helpers/multi_cluster_helpers.sh\n"
            f"mcm_register itz-a {URL_A}\nmcm_set_current itz-a\nmcm_write_state MULTI_CLUSTER_MANAGEMENT=true\n",
            check=True,
        )

    def run(self, sb, args=(), env=None, cluster=None, config=None):
        # Flat as well as per cluster, so the script loads whichever folder the env layer picks.
        extra = {**WXO_EXPORTS, **(config or {})}
        for where in (None, cluster) if cluster else (None,):
            sb.write_config("cpd", ocp_url=URL_A, cluster=where, extra=extra)
        log = sb.root / "orchestrate.log"
        result = sb.run_script(WXO, env={"ORCHESTRATE_LOG": str(log), **(env or {})}, args=args)
        assert result.returncode == 0, result.stdout + result.stderr
        return log.read_text().splitlines()

    @staticmethod
    def added(lines):
        return [line.split(" -n ")[1].split()[0] for line in lines if line.startswith("env add")]

    def test_off_keeps_cpd_onprem(self):
        with self.sandbox() as sb:
            assert self.added(self.run(sb, args=["--no-activate"])) == ["cpd-onprem"]

    def test_on_appends_the_cluster(self):
        with self.sandbox() as sb:
            self.enable(sb)
            lines = self.run(sb, args=["--no-activate"], env={"MCM_CLUSTER": "itz-a"}, cluster="itz-a")
            assert self.added(lines) == ["cpd-onprem-itz-a"]

    def test_on_explicit_name_is_used_as_given(self):
        with self.sandbox() as sb:
            self.enable(sb)
            lines = self.run(sb, args=["--no-activate", "--name", "mine"], env={"MCM_CLUSTER": "itz-a"}, cluster="itz-a")
            assert self.added(lines) == ["mine"]

    def test_on_persisted_name_is_kept(self):
        with self.sandbox() as sb:
            self.enable(sb)
            lines = self.run(
                sb, args=["--no-activate"], env={"MCM_CLUSTER": "itz-a"}, cluster="itz-a",
                config={"WXO_ENV_NAME": "already-there"},
            )
            assert self.added(lines) == ["already-there"]


class TestInstanceManagerCpdCli:
    def binaries(self, tmp):
        real, shim_dir = Path(tmp) / "real" / "cpd-cli", Path(tmp) / "shim"
        real.parent.mkdir()
        shim_dir.mkdir()
        for path in (real, shim_dir / "cpd-cli"):
            path.write_text("#!/bin/sh\n")
            path.chmod(0o755)
        return str(real), str(shim_dir / "cpd-cli")

    def test_cpd_cli_variable_wins_with_the_mode_off(self, monkeypatch):
        from tui.instance_manager.providers.cpd.cpdcli import find_binary

        with tempfile.TemporaryDirectory() as tmp:
            real, shim = self.binaries(tmp)
            monkeypatch.setenv("CPD_CLI", real)
            monkeypatch.setenv("PATH", str(Path(shim).parent))
            assert find_binary() == real

    def test_shim_on_path_wins_while_a_cluster_is_pinned(self, monkeypatch):
        from tui.instance_manager.providers.cpd.cpdcli import find_binary

        with tempfile.TemporaryDirectory() as tmp:
            real, shim = self.binaries(tmp)
            monkeypatch.setenv("CPD_CLI", real)
            monkeypatch.setenv("PATH", str(Path(shim).parent))
            monkeypatch.setenv("MCM_CLUSTER_ROOT", str(Path(tmp) / "cluster"))
            assert find_binary() == shim


class TestTuiPaths:
    def test_settings_follow_config_dir_from_the_env_loader(self, monkeypatch):
        from tui.instance_manager import settings

        with tempfile.TemporaryDirectory() as tmp:
            monkeypatch.setenv("CONFIG_DIR", tmp)
            assert settings.config_dir() == Path(tmp).resolve()

    def test_settings_use_the_cluster_folder_without_the_env_loader(self, monkeypatch):
        from tui.instance_manager import settings

        monkeypatch.delenv("CONFIG_DIR", raising=False)
        write_state()
        assert settings.config_dir() == REPO / "configs" / "clusters" / "itz-a" / "cp4d_config"

    def test_profile_lookup_reads_the_cluster_profile_store(self, monkeypatch):
        from tui.instance_manager.providers.cpd.profile import _profile_url

        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "config"
            store.write_text("profiles:\n- name: cpadmin-profile\n  profile:\n    url: https://cpd.itz-a/\n")
            monkeypatch.setenv("CPDCONFIG", str(store))
            assert _profile_url("cpadmin-profile") == "https://cpd.itz-a"
