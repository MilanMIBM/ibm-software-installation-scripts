"""Regression tests for the review of one-way delineation per cluster (2026-11-10), one class per finding.

Each test fails without its fix. Sandboxes only (tests/mcm_harness.py); nothing touches the real configs/.
"""

import os
import stat
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "helpers"))

import ibmcloud_secrets_manager_helpers as smh
from mcm_harness import make_sandbox

from helpers import multi_cluster_notebook as nb
from helpers import multi_cluster_state as state

REPO = Path(__file__).resolve().parents[1]
UTILS = "src/utilities/multi_cluster_management_utils"
ADDON_LIST = "src/utilities/softwarehub_utils/get_instance_addon_list.sh"
KUBECOST_GEN = "src/utilities/kubecost_utils/generate_kubecost_config.sh"
DATASTAX_GEN = "scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh"
WXO = (
    "scripts/install_cloud_pak_for_data/5_component_specific_scripts/"
    "wxo_adk_and_custom_model_import/add_wxo_onprem_environment.sh"
)
URL_A = "https://api.itz-a.example.com:6443"
URL_B = "https://api.itz-b.example.com:6443"
ROKS_US = "https://c100-e.us-south.containers.cloud.ibm.com:31234"
ROKS_EU = "https://c100-e.eu-de.containers.cloud.ibm.com:30123"
BOOT = 'source "${0:A:h}/env_bootstrap.sh"\n'
SHOW_URL = 'print -r -- "LOADED:${OCP_URL}"\n'
# Forms of URL_A that name the same API server.
URL_A_FORMS = [
    "api.itz-a.example.com:6443",
    "https://api.itz-a.example.com",
    "https://api.itz-a.example.com:6443//",
    "https://api.itz-a.example.com.:6443",
    "  HTTPS://API.itz-a.example.com:6443/  ",
    "https://kubeadmin@api.itz-a.example.com:6443/path?x=1#frag",
]


def write_state(sb, on="false", clusters=(), current=""):
    (sb.repo / "configs" / "multi_cluster_management.sh").write_text(
        f'export MULTI_CLUSTER_MANAGEMENT="{on}"\nexport MCM_CLUSTERS="{" ".join(clusters)}"\n'
        f'export MCM_CURRENT_CLUSTER="{current}"\nexport APPLY_TO_ALL="false"\nexport MCM_TARGET_CLUSTERS=""\n'
    )


def env_load(sb, env=None, args=()):
    return sb.run_zsh(BOOT + SHOW_URL, env={"ENV_TARGET": "cpd", **(env or {})}, args=args)


# --- Finding: one URL key on both sides --------------------------------------------------------------------------
class TestUrlKey:
    CASES = (*URL_A_FORMS, URL_A, "https://[::1]:6444/", "[::1]", "https://", "", "host:", "https://api.x:443", "API.X.")

    def test_zsh_and_python_agree(self):
        with make_sandbox() as sb:
            script = 'source src/helpers/multi_cluster_helpers.sh\nfor u in "$@"; do print -r -- "<$(_mcm_url_key "$u")>"; done\n'
            result = sb.run_zsh(script, args=self.CASES, check=True)
            assert result.stdout.splitlines() == [f"<{state.url_key(case)}>" for case in self.CASES]

    @pytest.mark.parametrize("form", URL_A_FORMS)
    def test_every_form_has_the_key_of_the_full_url(self, form):
        assert state.url_key(form) == state.url_key(URL_A) == "api.itz-a.example.com:6443"

    def test_a_different_port_is_a_different_server(self):
        assert state.url_key("https://api.itz-a.example.com:6444") != state.url_key(URL_A)


class TestGuardMatchesEveryUrlForm:
    """A cluster named apart from its URL ('prod') still owns its URL however a flat config spells it."""

    @pytest.mark.parametrize("form", URL_A_FORMS)
    def test_flat_load_is_refused(self, form):
        with make_sandbox() as sb:
            sb.write_cluster_marker("prod", URL_A)
            write_state(sb)
            sb.write_config("cpd", ocp_url=form)
            result = env_load(sb)
            assert result.returncode != 0, result.stdout
            assert "LOADED" not in result.stdout
            assert "belongs to the delineated cluster 'prod'" in result.stderr, result.stderr

    @pytest.mark.parametrize("form", URL_A_FORMS)
    def test_python_owner_lookup(self, form):
        with make_sandbox() as sb:
            sb.write_cluster_marker("prod", URL_A)
            assert state.cluster_for_url(form, sb.repo) == "prod"
            assert nb.delineated_owner(form, sb.repo) == "prod"

    def test_notebook_forces_the_save_into_the_cluster_folder(self):
        with make_sandbox() as sb:
            sb.write_cluster_marker("prod", URL_A)
            write_state(sb)
            target = nb.resolve_target("cp4d_config", False, "", "api.itz-a.example.com:6443", sb.repo, {})
            assert target.cluster == "prod" and target.forced
            assert target.directory == str(sb.repo / "configs/clusters/prod/cp4d_config")
            # The marker's URL spelled differently is not a conflict.
            assert not target.conflict

    def test_register_warns_about_the_same_url_spelled_differently(self):
        with make_sandbox() as sb:
            sb.write_cluster_marker("prod", URL_A)
            write_state(sb, clusters=("prod",))
            script = 'source src/helpers/multi_cluster_helpers.sh\nmcm_register other "api.itz-a.example.com"\n'
            result = sb.run_zsh(script, check=True)
            assert "Clusters 'prod' and 'other' point at the same URL" in result.stderr, result.stderr


# --- Finding: the derived-name fallback only for a marker with no URL --------------------------------------------
class TestDerivedNameFallback:
    def test_two_roks_clusters_with_the_same_derived_name_are_apart(self):
        with make_sandbox() as sb:
            sb.write_cluster_marker("c100-e", ROKS_US)
            write_state(sb)
            sb.write_config("cpd", ocp_url=ROKS_EU)
            result = env_load(sb)
            assert result.returncode == 0, result.stderr
            assert f"LOADED:{ROKS_EU}" in result.stdout
            script = f'source src/helpers/multi_cluster_helpers.sh\nprint -r -- "<$(mcm_cluster_for_url {ROKS_EU})>"\n'
            assert sb.run_zsh(script, check=True).stdout.strip() == "<>"
            assert state.cluster_for_url(ROKS_EU, sb.repo) == ""

    def test_the_notebook_saves_the_second_cluster_under_its_own_name(self):
        with make_sandbox() as sb:
            sb.write_cluster_marker("c100-e", ROKS_US)
            write_state(sb)
            target = nb.resolve_target("cp4d_config", True, "roks-eu", ROKS_EU, sb.repo, {})
            assert not target.error
            assert target.cluster == "roks-eu"
            unticked = nb.resolve_target("cp4d_config", False, "", ROKS_EU, sb.repo, {})
            assert unticked.cluster == "" and unticked.directory == str(sb.repo / "configs/cp4d_config")

    def test_a_marker_without_a_url_still_owns_its_derived_name(self):
        with make_sandbox() as sb:
            sb.write_cluster_marker("itz-a", "")
            write_state(sb)
            assert state.cluster_for_url(URL_A, sb.repo) == "itz-a"
            script = f'source src/helpers/multi_cluster_helpers.sh\nprint -r -- "<$(mcm_cluster_for_url {URL_A})>"\n'
            assert sb.run_zsh(script, check=True).stdout.strip() == "<itz-a>"


# --- Finding: a pinned run always leaves a marker ----------------------------------------------------------------
class TestPinWritesTheMarker:
    def test_a_registered_folder_without_a_marker_gets_one(self):
        with make_sandbox() as sb:
            write_state(sb, on="true", clusters=("foo",), current="foo")
            sb.write_config("cpd", ocp_url=URL_A, cluster="foo")
            marker = sb.repo / "configs/clusters/foo/.cluster"
            assert not marker.exists()
            result = env_load(sb)
            assert result.returncode == 0, result.stderr
            assert marker.is_file()
            text = marker.read_text()
            assert 'DELINEATED="true"' in text and f'OCP_URL="{URL_A}"' in text and 'NAME="foo"' in text
            assert "had no .cluster marker" in result.stderr

    def test_the_cluster_then_stays_delineated_with_the_mode_off(self):
        with make_sandbox() as sb:
            write_state(sb, on="true", clusters=("foo",), current="foo")
            sb.write_config("cpd", ocp_url=URL_A, cluster="foo")
            assert env_load(sb).returncode == 0
            write_state(sb, on="false", clusters=("foo",))
            pinned = env_load(sb, args=["--target-cluster", "foo"])
            assert pinned.returncode == 0, pinned.stderr
            assert f"LOADED:{URL_A}" in pinned.stdout
            sb.write_config("cpd", ocp_url=URL_A)
            flat = env_load(sb)
            assert flat.returncode != 0 and "belongs to the delineated cluster 'foo'" in flat.stderr

    def test_an_existing_marker_is_left_alone(self):
        with make_sandbox() as sb:
            marker = sb.write_cluster_marker("itz-a", URL_A)
            before = marker.read_text()
            write_state(sb, on="true", clusters=("itz-a",), current="itz-a")
            sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
            result = env_load(sb)
            assert result.returncode == 0, result.stderr
            assert marker.read_text() == before
            assert "had no .cluster marker" not in result.stderr


# --- Findings: notebook resolve_target with an inherited MCM_CLUSTER ----------------------------------------------
class TestNotebookInheritedPin:
    def setup(self, sb):
        sb.write_cluster_marker("itz-a", URL_A)
        sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        write_state(sb, clusters=("itz-a",))

    def test_unticked_save_with_another_url_goes_flat(self):
        with make_sandbox() as sb:
            self.setup(sb)
            target = nb.resolve_target(
                "cp4d_config", False, "", "https://api.itz-x.example.com:6443", sb.repo, {"MCM_CLUSTER": "itz-a"}
            )
            assert not target.error
            assert target.cluster == ""
            assert target.directory == str(sb.repo / "configs/cp4d_config")
            assert "single-cluster layout" in nb.save_to_markdown(target)
            assert nb.existing_vars_file(target, "cpd_vars.sh") is None

    def test_unticked_save_of_the_pinned_clusters_url_still_goes_into_its_folder(self):
        with make_sandbox() as sb:
            self.setup(sb)
            target = nb.resolve_target("cp4d_config", False, "", URL_A, sb.repo, {"MCM_CLUSTER": "itz-a"})
            assert target.cluster == "itz-a" and target.forced

    def test_a_retired_pin_is_reported_not_raised(self):
        with make_sandbox() as sb:
            self.setup(sb)
            state.mark_retired("itz-a", sb.repo)
            env = {"MCM_CLUSTER": "itz-a"}
            target = nb.resolve_target("cp4d_config", False, "", "", sb.repo, env)
            assert "retired" in target.error
            assert "not decided yet" in nb.save_to_markdown(target)
            assert nb.startup_vars_file("cp4d_config", "cpd_vars.sh", sb.repo, env) is None


# --- Findings: Secrets Manager prefix and bundle listing with the mode off -----------------------------------------
@pytest.fixture
def hermetic_repo(monkeypatch, tmp_path):
    import multi_cluster_state

    monkeypatch.setattr(multi_cluster_state, "repo_root", lambda: tmp_path)
    monkeypatch.delenv("CPD_SECRETS_PREFIX", raising=False)
    Path(os.environ["MCM_STATE_FILE"]).write_text('export MULTI_CLUSTER_MANAGEMENT="false"\nexport MCM_CLUSTERS="itz-a"\n')
    marker = tmp_path / "configs/clusters/itz-a/.cluster"
    marker.parent.mkdir(parents=True)
    marker.write_text(f'NAME="itz-a"\nOCP_URL="{URL_A}"\nDELINEATED="true"\n')
    return tmp_path


class _Result:
    def __init__(self, secrets):
        self.secrets = secrets

    def get_result(self):
        return {"secrets": self.secrets, "total_count": len(self.secrets)}


class _Client:
    def __init__(self, secrets):
        self.secrets = secrets

    def list_secrets(self, offset=0, **_):
        return _Result(self.secrets[offset:])


def _secret(name, file_name):
    return {"name": name, "id": name, "custom_metadata": {smh.META_FILE: file_name}}


@pytest.mark.usefixtures("hermetic_repo")
class TestSecretsFollowThePin:
    BUNDLES = (_secret("cpd-config-cpd-vars-sh", "cpd_vars.sh"), _secret("cpd-config-itz-a-cpd-vars-sh", "cpd_vars.sh"))

    def names(self, prefix):
        return [m["name"] for m in smh.list_bundle_secrets(_Client(list(self.BUNDLES)), "group", prefix)]

    def test_a_pinned_delineated_cluster_names_its_bundle(self, monkeypatch):
        monkeypatch.setenv("MCM_CLUSTER", "itz-a")
        assert smh.resolve_prefix(None) == "cpd-config-itz-a"
        assert self.names(smh.resolve_prefix(None)) == ["cpd-config-itz-a-cpd-vars-sh"]

    def test_unpinned_flat_run_keeps_the_flat_prefix(self):
        assert smh.resolve_prefix(None) == "cpd-config"

    def test_flat_restore_leaves_a_delineated_clusters_bundle_out(self):
        assert self.names("cpd-config") == ["cpd-config-cpd-vars-sh"]

    def test_a_stale_pin_of_an_unknown_cluster_is_ignored(self, monkeypatch):
        monkeypatch.setenv("MCM_CLUSTER", "nope")
        assert smh.resolve_prefix(None) == "cpd-config"

    def test_a_retired_pin_stops(self, monkeypatch, hermetic_repo):
        marker = hermetic_repo / "configs/clusters/itz-a/.cluster"
        marker.write_text(marker.read_text() + 'RETIRED="true"\n')
        monkeypatch.setenv("MCM_CLUSTER", "itz-a")
        with pytest.raises(ValueError, match="retired"):
            smh.resolve_prefix(None)


# --- Findings: get_instance_addon_list.sh with delineated clusters ------------------------------------------------
class TestAddonListWithDelineatedClusters:
    def sandbox(self):
        sb = make_sandbox(extra=[UTILS, ADDON_LIST])
        (sb.repo / "src/helpers/cpd_api_helpers.sh").write_text(
            'cpdapi_login() { CPDAPI_TOKEN=t; print -r -- "SIGNIN:$1" >&2; }\n'
        )
        curl = sb.bin / "curl"
        curl.write_text('#!/bin/zsh\nprint -r -- \'{"requestObj":[{"Type":"wx","State":"on"}]}\'\n')
        curl.chmod(0o755)
        flat = sb.write_config("cpd", ocp_url=URL_B)
        (flat.parent / "cpd_instance_details.sh").write_text('export CPD_URL="https://cpd.flat" CPD_USERNAME=a CPD_PASSWORD=b\n')
        sb.write_cluster_marker("itz-a", URL_A)
        own = sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        (own.parent / "cpd_instance_details.sh").write_text('export CPD_URL="https://cpd.itz-a" CPD_USERNAME=a CPD_PASSWORD=b\n')
        write_state(sb, clusters=("itz-a",))
        return sb

    @pytest.mark.parametrize("how", ["env", "flag", "flag="])
    def test_a_pin_reaches_the_clusters_software_hub(self, how):
        with self.sandbox() as sb:
            env = {"MCM_CLUSTER": "itz-a"} if how == "env" else {}
            args = {"env": [], "flag": ["--target-cluster", "itz-a"], "flag=": ["--target-cluster=itz-a"]}[how]
            result = sb.run_script(ADDON_LIST, cwd=sb.repo, env=env, args=args)
            assert result.returncode == 0, result.stderr
            assert "SIGNIN:https://cpd.itz-a" in result.stderr, result.stderr
            assert result.stdout.strip().endswith("wx on")

    def test_a_flat_copy_of_a_delineated_cluster_is_refused(self):
        with self.sandbox() as sb:
            sb.write_config("cpd", ocp_url=URL_A)
            result = sb.run_script(ADDON_LIST, cwd=sb.repo)
            assert result.returncode != 0
            assert "SIGNIN" not in result.stderr
            assert "belongs to the delineated cluster 'itz-a'" in result.stderr, result.stderr

    def test_an_unpinned_flat_run_still_signs_in_to_the_flat_cluster(self):
        with self.sandbox() as sb:
            result = sb.run_script(ADDON_LIST, cwd=sb.repo)
            assert result.returncode == 0, result.stderr
            assert "SIGNIN:https://cpd.flat" in result.stderr

    def test_a_target_flag_with_nothing_delineated_is_an_error(self):
        with self.sandbox() as sb:
            (sb.repo / "configs/clusters/itz-a/.cluster").unlink()
            result = sb.run_script(ADDON_LIST, cwd=sb.repo, args=["--target-cluster", "itz-a"])
            assert result.returncode != 0
            assert "SIGNIN" not in result.stderr


# --- Finding: generators check the file given to --from-cpd -------------------------------------------------------
GENERATOR_EXTRAS = [
    "pyproject.toml",
    "src/helpers/version_catalog.json",
    "src/helpers/config_file_jinja2_templates",
    DATASTAX_GEN,
    KUBECOST_GEN,
]


@pytest.fixture
def gen():
    with make_sandbox(extra=GENERATOR_EXTRAS) as sb:
        os.symlink(REPO / ".venv", sb.repo / ".venv")
        sb.write_cluster_marker("itz-a", URL_A)
        sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        write_state(sb, clusters=("itz-a",))
        yield sb


class TestGeneratorFromCpdFile:
    @pytest.mark.parametrize(
        "script, out",
        [(DATASTAX_GEN, "datastax_mc_config/datastax_mc_vars.sh"), (KUBECOST_GEN, "kubecost_config/kubecost_vars.sh")],
    )
    def test_a_delineated_clusters_file_sends_the_write_into_its_folder(self, gen, script, out):
        result = gen.run_script(
            script, args=["--from-cpd", "configs/clusters/itz-a/cp4d_config/cpd_vars.sh", "--force"], timeout=90
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gen.repo / "configs/clusters/itz-a" / out).is_file()
        assert not (gen.repo / "configs" / out).exists()
        assert "belongs to cluster 'itz-a'" in result.stderr

    def test_a_flat_file_of_another_cluster_still_writes_flat(self, gen):
        gen.write_config("cpd", ocp_url=URL_B)
        result = gen.run_script(DATASTAX_GEN, args=["--from-cpd", "configs/cp4d_config/cpd_vars.sh", "--force"], timeout=90)
        assert result.returncode == 0, result.stdout + result.stderr
        assert (gen.repo / "configs/datastax_mc_config/datastax_mc_vars.sh").is_file()
        assert not (gen.repo / "configs/clusters/itz-a/datastax_mc_config").exists()


# --- Finding: per-cluster ADK environment name on a pinned run with the mode off ---------------------------------
WXO_EXPORTS = {"WXO_URL": "https://cpd.example.com", "CPD_APIKEY": "key", "CPD_USERNAME": "cpadmin"}


class TestWxoEnvNameWithTheModeOff:
    def sandbox(self):
        sb = make_sandbox(extra=[WXO])
        fake = sb.bin / "orchestrate"
        fake.write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$ORCHESTRATE_LOG"\n')
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        for name, url in (("itz-a", URL_A), ("itz-b", URL_B)):
            sb.write_cluster_marker(name, url)
            sb.write_config("cpd", ocp_url=url, cluster=name, extra=WXO_EXPORTS)
        sb.write_config("cpd", ocp_url="https://api.flat.example.com:6443", extra=WXO_EXPORTS)
        write_state(sb, clusters=("itz-a", "itz-b"))
        return sb

    def added(self, sb, args):
        log = sb.root / "orchestrate.log"
        log.unlink(missing_ok=True)
        result = sb.run_script(WXO, env={"ORCHESTRATE_LOG": str(log)}, args=["--no-activate", *args])
        assert result.returncode == 0, result.stdout + result.stderr
        return [line.split(" -n ")[1].split()[0] for line in log.read_text().splitlines() if line.startswith("env add")]

    def test_each_pinned_cluster_gets_its_own_entry(self):
        with self.sandbox() as sb:
            assert self.added(sb, ["--target-cluster", "itz-a"]) == ["cpd-onprem-itz-a"]
            assert self.added(sb, ["--target-cluster", "itz-b"]) == ["cpd-onprem-itz-b"]

    def test_a_flat_run_keeps_cpd_onprem(self):
        with self.sandbox() as sb:
            assert self.added(sb, []) == ["cpd-onprem"]
