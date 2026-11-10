"""State file and cluster names for multi-cluster management (plan sections 5.2 and 5.3).

T3: src/helpers/multi_cluster_helpers.sh (zsh) and src/helpers/multi_cluster_state.py read and
write the state file identically.
T4: the name table from 5.3, invalid and reserved names, regeneration after deletion, the cluster
list rebuilt from the .cluster markers, unknown keys preserved.

Everything runs in tests/mcm_harness.py sandboxes: temp HOME, temp repo copy, fake tools.
"""

import stat
from pathlib import Path

import pytest
from mcm_harness import make_sandbox

from helpers import multi_cluster_state as py_state

SOURCE = 'source src/helpers/multi_cluster_helpers.sh\n'


class TestWritableConfigsRoot:
    """A writer must never land in the flat folder while the mode is on with no cluster."""

    @pytest.fixture
    def sb(self):
        with make_sandbox() as sandbox:
            (sandbox.repo / "configs").mkdir(exist_ok=True)
            yield sandbox

    def state(self, sb, on="true", clusters="itz-a itz-b", current=""):
        (sb.repo / "configs" / "multi_cluster_management.sh").write_text(
            f'export MULTI_CLUSTER_MANAGEMENT="{on}"\nexport MCM_CLUSTERS="{clusters}"\nexport MCM_CURRENT_CLUSTER="{current}"\n'
        )

    def env(self, sb, **extra):
        env = sb.env(extra)
        env.pop("CONFIGS_ROOT", None)
        env.pop("MCM_CLUSTER", None)
        return env | extra

    def test_on_with_no_cluster_raises_with_guidance(self, sb):
        self.state(sb)
        with pytest.raises(ValueError, match="no cluster is selected.*multi_cluster.sh use NAME"):
            py_state.writable_configs_root(sb.repo, self.env(sb))

    def test_on_with_a_cluster_is_that_cluster(self, sb):
        self.state(sb, current="itz-b")
        assert py_state.writable_configs_root(sb.repo, self.env(sb)) == sb.repo / "configs" / "clusters" / "itz-b"

    def test_off_is_the_flat_folder(self, sb):
        self.state(sb, on="false", clusters="", current="")
        assert py_state.writable_configs_root(sb.repo, self.env(sb)) == sb.repo / "configs"

    def test_configs_root_from_the_env_loader_is_trusted(self, sb):
        self.state(sb)
        env = self.env(sb, CONFIGS_ROOT="/somewhere/cluster")
        assert py_state.writable_configs_root(sb.repo, env) == Path("/somewhere/cluster")
KEY_NAMES = py_state.STATE_KEYS

# Prints the globals mcm_load_state sets as JSON built by the shell, one key per line.
DUMP_STATE = SOURCE + 'mcm_load_state\n' + "\n".join(
    f'print -r -- "{key}=${{{key}}}"' for key in KEY_NAMES
) + "\n"

HAND_EDITED = """# a note the user typed
export MULTI_CLUSTER_MANAGEMENT="true"      # edited

export MCM_CLUSTERS="alpha  beta"
  MCM_CURRENT_CLUSTER="alpha"
export APPLY_TO_ALL="false"
export MCM_TARGET_CLUSTERS=""
export MCM_STOP_INACTIVE_CONTAINERS="false"
export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0"
export MCM_STOP_IDLE_PODMAN_VM="true"
export FUTURE_KEY="keep me"   # unknown key
export ANOTHER_ONE="x=y"
export FUTURE_KEY="later wins"
weird line kept as is
export UNQUOTED=value"""


@pytest.fixture
def sb():
    with make_sandbox() as sandbox:
        yield sandbox


def state_path(sandbox):
    return sandbox.repo / "configs" / "multi_cluster_management.sh"


def zsh_state(sandbox, env=None):
    result = sandbox.run_zsh(DUMP_STATE, env=env, check=False)
    assert result.returncode == 0, result.stderr
    return dict(line.split("=", 1) for line in result.stdout.splitlines())


def py_args(sandbox):
    return {"repo": sandbox.repo, "env": sandbox.env()}


def known_only(values):
    return {key: values[key] for key in KEY_NAMES}


def zsh_ok(sandbox, script, env=None):
    result = sandbox.run_zsh(SOURCE + script, env=env)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    return result.stdout


# ----------------------------------------------------------------------------------------------- T3
class TestT3Parity:
    def test_default_file_is_byte_identical(self, sb):
        zsh_ok(sb, "mcm_ensure_state_file\n")
        zsh_bytes = state_path(sb).read_bytes()
        state_path(sb).unlink()
        py_state.ensure_state_file(**py_args(sb))
        assert state_path(sb).read_bytes() == zsh_bytes

    def test_default_file_matches_the_plan(self, sb):
        zsh_ok(sb, "mcm_ensure_state_file\n")
        lines = state_path(sb).read_text().splitlines()
        assert lines == [
            '# Generated. Safe to edit by hand; keep the KEY="value" form.',
            "# Manage with src/utilities/multi_cluster_management_utils/multi_cluster.sh or the notebooks.",
            'export MULTI_CLUSTER_MANAGEMENT="false"      # true | false',
            'export MCM_CLUSTERS=""                       # registered clusters, space separated',
            'export MCM_CURRENT_CLUSTER=""                # working cluster',
            'export APPLY_TO_ALL="false"                  # run each command on every registered cluster',
            'export MCM_TARGET_CLUSTERS=""                # or a specific list; beats APPLY_TO_ALL when set',
            'export MCM_STOP_INACTIVE_CONTAINERS="true"   # stop idle containers of clusters no longer targeted',
            'export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="120"  # stop a container after this long with no commands; 0 = never',
            'export MCM_STOP_IDLE_PODMAN_VM="true"        # also shut down the podman VM once nothing at all is running',
        ]

    def test_both_read_a_hand_edited_file_the_same(self, sb):
        state_path(sb).write_text(HAND_EDITED)
        from_py = py_state.read_state(**py_args(sb))
        assert zsh_state(sb) == known_only(from_py)
        assert from_py["MCM_CLUSTERS"] == "alpha  beta"
        assert from_py["FUTURE_KEY"] == "later wins"
        assert from_py["ANOTHER_ONE"] == "x=y"
        assert from_py["MCM_CONTAINER_IDLE_TIMEOUT_MINUTES"] == "0"

    def test_writes_are_byte_identical(self, sb):
        updates = {"MULTI_CLUSTER_MANAGEMENT": "true", "MCM_CLUSTERS": "a b", "MCM_CURRENT_CLUSTER": "a",
                   "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES": "30", "NEW_KEY": "v 1"}
        state_path(sb).write_text(HAND_EDITED)
        args = " ".join(f"'{key}={value}'" for key, value in updates.items())
        zsh_ok(sb, f"mcm_write_state {args}\n")
        zsh_bytes = state_path(sb).read_bytes()
        state_path(sb).write_text(HAND_EDITED)
        py_state.write_state(updates, **py_args(sb))
        assert state_path(sb).read_bytes() == zsh_bytes

    def test_python_reads_what_zsh_wrote(self, sb):
        zsh_ok(sb, "mcm_write_state APPLY_TO_ALL=true MCM_TARGET_CLUSTERS='x y'\n")
        state = py_state.read_state(**py_args(sb))
        assert (state["APPLY_TO_ALL"], state["MCM_TARGET_CLUSTERS"]) == ("true", "x y")

    def test_zsh_reads_what_python_wrote(self, sb):
        py_state.write_state({"APPLY_TO_ALL": True, "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES": 45}, **py_args(sb))
        state = zsh_state(sb)
        assert (state["APPLY_TO_ALL"], state["MCM_CONTAINER_IDLE_TIMEOUT_MINUTES"]) == ("true", "45")

    def test_register_makes_the_same_marker_and_list(self, sb):
        zsh_ok(sb, "mcm_register alpha https://api.alpha.example.com:6443\n")
        py_state.register_cluster("beta", "https://api.beta.example.com:6443", **py_args(sb))
        state = py_state.read_state(**py_args(sb))
        assert state["MCM_CLUSTERS"] == "alpha beta"
        strip = lambda text: [line for line in text.splitlines() if not line.startswith("CREATED=")]
        alpha = strip((sb.repo / "configs/clusters/alpha/.cluster").read_text())
        beta = strip((sb.repo / "configs/clusters/beta/.cluster").read_text())
        assert [line.replace("alpha", "beta") for line in alpha] == beta

    @pytest.mark.parametrize("bad", [
        ('APPLY_TO_ALL', 'export APPLY_TO_ALL="maybe"'),
        ('MCM_STOP_IDLE_PODMAN_VM', 'export MCM_STOP_IDLE_PODMAN_VM="TRUE"'),
        ('MCM_CONTAINER_IDLE_TIMEOUT_MINUTES', 'export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="soon"'),
        ('MCM_CLUSTERS', 'export MCM_CLUSTERS="ok Bad"'),
        ('MCM_TARGET_CLUSTERS', 'export MCM_TARGET_CLUSTERS="a,b"'),
        ('MCM_CURRENT_CLUSTER', 'export MCM_CURRENT_CLUSTER="clusters"'),
        ('APPLY_TO_ALL', 'export APPLY_TO_ALL=true'),
    ])
    def test_invalid_value_names_the_key_in_both(self, sb, bad):
        key, line = bad
        # With the mode on: a mode-off run only warns (test_bad_key_while_off_warns_in_both).
        state_path(sb).write_text('export MULTI_CLUSTER_MANAGEMENT="true"\n' + line + "\n")
        result = sb.run_zsh(SOURCE + "mcm_load_state\n")
        assert result.returncode != 0
        assert key in result.stderr
        assert "[ERROR]" in result.stderr
        with pytest.raises(ValueError, match=key):
            py_state.read_state(**py_args(sb))

    @pytest.mark.parametrize("line", ['export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="2h"', 'export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES=2h'])
    def test_bad_key_while_off_warns_in_both(self, sb, line):
        state_path(sb).write_text('export MULTI_CLUSTER_MANAGEMENT="false"\n' + line + "\n")
        result = sb.run_zsh(SOURCE + 'mcm_load_state\nprint -r -- "$MCM_CONTAINER_IDLE_TIMEOUT_MINUTES"\n')
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "120"
        assert "[WARN]" in result.stderr and "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES" in result.stderr
        assert "[ERROR]" not in result.stderr
        assert py_state.read_state(**py_args(sb))["MCM_CONTAINER_IDLE_TIMEOUT_MINUTES"] == "120"

    def test_a_bad_flag_still_stops_both(self, sb):
        state_path(sb).write_text('export MULTI_CLUSTER_MANAGEMENT="maybe"\nexport MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="2h"\n')
        assert sb.run_zsh(SOURCE + "mcm_load_state\n").returncode != 0
        with pytest.raises(ValueError, match="MULTI_CLUSTER_MANAGEMENT"):
            py_state.read_state(**py_args(sb))

    def test_write_can_repair_an_invalid_key(self, sb):
        state_path(sb).write_text('export APPLY_TO_ALL="maybe"\n')
        zsh_ok(sb, "mcm_write_state APPLY_TO_ALL=false\n")
        assert py_state.read_state(**py_args(sb))["APPLY_TO_ALL"] == "false"

    @pytest.mark.parametrize("pair", ["APPLY_TO_ALL=maybe", "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES=x", 'NOTE=a"b', "NOKEY", "1BAD=x"])
    def test_invalid_writes_change_nothing(self, sb, pair):
        zsh_ok(sb, "mcm_ensure_state_file\n")
        before = state_path(sb).read_bytes()
        result = sb.run_zsh(SOURCE + f"mcm_write_state '{pair}'\n")
        assert result.returncode != 0
        assert state_path(sb).read_bytes() == before
        if "=" in pair:
            key, _, value = pair.partition("=")
            with pytest.raises(ValueError):
                py_state.write_state({key: value}, **py_args(sb))
        assert state_path(sb).read_bytes() == before

    def test_mode_0600_and_no_leftovers(self, sb):
        zsh_ok(sb, "mcm_write_state APPLY_TO_ALL=true\n")
        assert stat.S_IMODE(state_path(sb).stat().st_mode) == 0o600
        py_state.write_state({"APPLY_TO_ALL": "false"}, **py_args(sb))
        assert stat.S_IMODE(state_path(sb).stat().st_mode) == 0o600
        assert [p.name for p in (sb.repo / "configs").iterdir()] == ["multi_cluster_management.sh"]

    def test_mcm_state_file_override_in_both(self, sb):
        other = sb.tmp / "nested" / "state.sh"
        env = {"MCM_STATE_FILE": str(other)}
        zsh_ok(sb, "mcm_write_state APPLY_TO_ALL=true\n", env=env)
        assert other.is_file()
        assert not state_path(sb).exists()
        assert py_state.read_state(sb.repo, {"MCM_STATE_FILE": str(other)})["APPLY_TO_ALL"] == "true"
        assert zsh_ok(sb, "mcm_state_file\n", env=env).strip() == str(other)

    def test_reader_does_not_run_the_file(self, sb):
        marker = sb.tmp / "ran"
        state_path(sb).write_text(f'touch {marker}\nexport FUTURE_KEY="$(touch {marker})"\n')
        zsh_state(sb)
        py_state.read_state(**py_args(sb))
        assert not marker.exists()

    def test_python_read_never_creates_the_file(self, sb):
        py_state.read_state(**py_args(sb))
        py_state.is_on(**py_args(sb))
        py_state.configs_root(**py_args(sb))
        assert not state_path(sb).exists()


# ----------------------------------------------------------------------------------------------- T4
NAME_TABLE = [
    ("https://api.itz-r0247p.infra01-lb.fra02.techzone.ibm.com:6443/", "itz-r0247p"),
    ("https://api.itz-5balgo.infra01-lb.fra02.techzone.ibm.com:6443", "itz-5balgo"),
    ("API.My_Prod.example.com:6443", "my_prod"),
    ("https://c100-e.us-south.containers.cloud.ibm.com:31234", "c100-e"),
    ("https://10.0.0.5:6443", "10-0-0-5"),
    ("10.0.0.5", "10-0-0-5"),
    ("https://user:pw@api.host-a.example.com:6443/path?x=1", "host-a"),
    ("HTTPS://API.UP.example.com", "up"),
    ("  https://api.spaced.example.com:6443  ", "spaced"),
    ("https://api", "api"),
    ("https://300.1.1.1:6443", "300"),
    ("https://1.2.3:6443", "1"),
]
BAD_URLS = ["", "https://", "https://:6443", "https://api.clusters.example.com", "https://api.foo_config.example.com",
            "https://-x.example.com", "https://api.bad name.example.com", "https://[fd00::1]:6443"]
GOOD_NAMES = ["a", "0", "itz-r0247p", "my_prod", "a.b-c_d", "10-0-0-5", "clusters2", "old_configs2", "a_configs"]
BAD_NAMES = ["", "A", "aB", "-a", ".a", "_a", "a b", "a/b", "..", "a\nb", "é",
             "clusters", "old_configs", "cp4d_config", "x_workspace", "concert_workspace"]


class TestT4Names:
    @pytest.mark.parametrize("url,name", NAME_TABLE)
    def test_name_table(self, sb, url, name):
        assert py_state.name_from_url(url) == name
        assert zsh_ok(sb, f"mcm_name_from_url '{url}'\n").strip() == name

    @pytest.mark.parametrize("url", BAD_URLS)
    def test_unusable_urls_fail_in_both(self, sb, url):
        with pytest.raises(ValueError):
            py_state.name_from_url(url)
        result = sb.run_zsh(SOURCE + f"mcm_name_from_url '{url}'\n")
        assert result.returncode != 0
        assert result.stdout == ""
        assert "[ERROR]" in result.stderr

    @pytest.mark.parametrize("name", GOOD_NAMES)
    def test_good_names(self, sb, name):
        assert py_state.validate_name(name) == name
        zsh_ok(sb, f"mcm_validate_name '{name}'\n")

    @pytest.mark.parametrize("name", BAD_NAMES)
    def test_bad_names_are_refused_with_a_message(self, sb, name):
        with pytest.raises(ValueError):
            py_state.validate_name(name)
        result = sb.run_zsh(SOURCE + 'mcm_validate_name "$1"\n', args=[name])
        assert result.returncode != 0
        assert "[ERROR] Invalid cluster name" in result.stderr
        with pytest.raises(ValueError):
            py_state.cluster_root(name, sb.repo)
        assert sb.run_zsh(SOURCE + 'mcm_cluster_root "$1"\n', args=[name]).returncode != 0


def marker(sandbox, name, url="https://api.x.example.com:6443"):
    sandbox.write_cluster_marker(name, url)


class TestT4StateFile:
    def test_regenerated_after_deletion_with_cluster_list_rebuilt(self, sb):
        for name in ("b", "a-b", "a", "a.b", "a_b"):
            marker(sb, name, f"https://api.{name}.example.com:6443")
        (sb.repo / "configs/clusters/no-marker").mkdir()
        zsh_ok(sb, "mcm_load_state\n")
        first = state_path(sb).read_text()
        assert 'MCM_CLUSTERS="a a-b a.b a_b b"' in first
        assert 'MULTI_CLUSTER_MANAGEMENT="false"' in first

        state_path(sb).unlink()
        assert py_state.read_state(**py_args(sb))["MCM_CLUSTERS"] == "a a-b a.b a_b b"
        py_state.ensure_state_file(**py_args(sb))
        assert state_path(sb).read_text() == first

        state_path(sb).unlink()
        assert zsh_ok(sb, 'mcm_is_on || print -r -- off\n').strip() == "off"
        assert state_path(sb).read_text() == first

    def test_unknown_keys_survive_writes_from_both(self, sb):
        state_path(sb).write_text(HAND_EDITED)
        zsh_ok(sb, "mcm_write_state MCM_CURRENT_CLUSTER=beta\n")
        once = state_path(sb).read_text()
        assert 'export FUTURE_KEY="later wins"\n' in once
        assert 'export ANOTHER_ONE="x=y"\n' in once
        assert "weird line kept as is\n" in once
        assert "export UNQUOTED=value\n" in once
        py_state.write_state({"MCM_CURRENT_CLUSTER": "alpha"}, **py_args(sb))
        twice = state_path(sb).read_text()
        assert 'export MCM_CURRENT_CLUSTER="alpha"' in twice
        for line in ('export FUTURE_KEY="later wins"\n', 'export ANOTHER_ONE="x=y"\n', "weird line kept as is\n", "export UNQUOTED=value\n"):
            assert twice.count(line) == 1

    def test_unknown_keys_do_not_become_shell_variables(self, sb):
        state_path(sb).write_text('export FUTURE_KEY="x"\nexport PATH="/nonexistent"\n')
        out = zsh_ok(sb, 'mcm_load_state\nprint -r -- "[${FUTURE_KEY:-unset}]"\nmkdir -p "$TMPDIR/still-works" && print ok\n')
        assert "[unset]" in out
        assert "ok" in out

    def test_register_set_current_and_lookups(self, sb):
        out = zsh_ok(sb, """
mcm_register alpha https://api.alpha.example.com:6443
mcm_register beta
mcm_register alpha
mcm_set_current beta
mcm_load_state
print -r -- "$MCM_CLUSTERS|$MCM_CURRENT_CLUSTER"
mcm_is_registered alpha && print -r -- yes
mcm_is_registered nope || print -r -- no
mcm_cluster_root alpha
mcm_cpd_cli_root alpha
mcm_clusters_root
""")
        lines = out.splitlines()
        assert lines[0] == "alpha beta|beta"
        assert lines[1:3] == ["yes", "no"]
        assert lines[3] == str(sb.repo / "configs/clusters/alpha")
        assert lines[4] == str(sb.home / "cpd-cli/clusters/alpha")
        assert lines[5] == str(sb.repo / "configs/clusters")
        marker_text = (sb.repo / "configs/clusters/alpha/.cluster").read_text()
        assert 'NAME="alpha"' in marker_text
        assert 'OCP_URL="https://api.alpha.example.com:6443"' in marker_text
        assert 'CREATED="' in marker_text

    def test_set_current_refuses_an_unregistered_name(self, sb):
        result = sb.run_zsh(SOURCE + "mcm_set_current ghost\n")
        assert result.returncode != 0
        assert "[ERROR]" in result.stderr
        assert "ghost" in result.stderr

    def test_second_name_for_one_url_warns(self, sb):
        result = sb.run_zsh(SOURCE + "mcm_register a https://api.same.example.com:6443\nmcm_register b https://api.same.example.com:6443/\n")
        assert result.returncode == 0, result.stderr
        assert "[WARN]" in result.stderr
        assert "same URL" in result.stderr

    def test_register_keeps_created_and_updates_url(self, sb):
        zsh_ok(sb, "mcm_register a https://one.example.com\n")
        path = sb.repo / "configs/clusters/a/.cluster"
        path.write_text(path.read_text().replace('CREATED="', 'CREATED="X'))
        zsh_ok(sb, "mcm_register a https://two.example.com\n")
        text = path.read_text()
        assert 'OCP_URL="https://two.example.com"' in text
        assert 'CREATED="X' in text
        py_state.register_cluster("a", "https://three.example.com", **py_args(sb))
        text = path.read_text()
        assert 'OCP_URL="https://three.example.com"' in text
        assert 'CREATED="X' in text

    def test_resolve_configs_root_off(self, sb):
        assert zsh_ok(sb, "mcm_resolve_configs_root\n").strip() == str(sb.repo / "configs")
        assert zsh_ok(sb, "mcm_resolve_configs_root named\n").strip() == str(sb.repo / "configs/clusters/named")

    def test_resolve_configs_root_on(self, sb):
        zsh_ok(sb, "mcm_write_state MULTI_CLUSTER_MANAGEMENT=true\n")
        result = sb.run_zsh(SOURCE + "mcm_resolve_configs_root\n")
        assert result.returncode != 0
        assert "--target-cluster" in result.stderr

        zsh_ok(sb, "mcm_register solo\n")
        assert zsh_ok(sb, "mcm_resolve_configs_root\n").strip() == str(sb.repo / "configs/clusters/solo")

        zsh_ok(sb, "mcm_register other\n")
        assert sb.run_zsh(SOURCE + "mcm_resolve_configs_root\n").returncode != 0

        zsh_ok(sb, "mcm_set_current other\n")
        assert zsh_ok(sb, "mcm_resolve_configs_root\n").strip() == str(sb.repo / "configs/clusters/other")
        assert zsh_ok(sb, "mcm_resolve_configs_root\n", env={"MCM_CLUSTER": "solo"}).strip() == str(sb.repo / "configs/clusters/solo")
        assert zsh_ok(sb, "mcm_resolve_configs_root named\n").strip() == str(sb.repo / "configs/clusters/named")

        bad = sb.run_zsh(SOURCE + "mcm_resolve_configs_root\n", env={"MCM_CLUSTER": "Bad Name"})
        assert bad.returncode != 0

    def test_python_configs_root_order(self, sb):
        args = py_args(sb)
        assert py_state.configs_root(**args) == sb.repo / "configs"
        assert not py_state.is_on(**args)

        py_state.write_state({"MULTI_CLUSTER_MANAGEMENT": True}, **args)
        assert py_state.is_on(**args)
        assert py_state.configs_root(**args) == sb.repo / "configs"  # on, nothing selected

        py_state.register_cluster("solo", **args)
        py_state.register_cluster("other", **args)
        assert py_state.configs_root(**args) == sb.repo / "configs"  # two registered, no current
        py_state.write_state({"MCM_CURRENT_CLUSTER": "other"}, **args)
        assert py_state.configs_root(**args) == sb.repo / "configs/clusters/other"
        assert py_state.configs_root(sb.repo, {**sb.env(), "MCM_CLUSTER": "solo"}) == sb.repo / "configs/clusters/solo"
        assert py_state.configs_root(sb.repo, {**sb.env(), "CONFIGS_ROOT": "/x/y"}).as_posix() == "/x/y"
        assert py_state.config_dir("cp4d_config", **args) == sb.repo / "configs/clusters/other/cp4d_config"
        assert py_state.config_dir("cp4d_config", cluster="solo", **args) == sb.repo / "configs/clusters/solo/cp4d_config"

    def test_python_config_dir_with_a_cluster_ignores_the_mode(self, sb):
        args = py_args(sb)
        assert py_state.config_dir("concert_config", **args) == sb.repo / "configs/concert_config"
        assert py_state.config_dir("concert_config", cluster="new", **args) == sb.repo / "configs/clusters/new/concert_config"

    def test_python_register_returns_the_folder(self, sb):
        args = py_args(sb)
        assert py_state.register_cluster("a", "https://api.a.example.com", **args) == sb.repo / "configs/clusters/a"
        assert py_state.register_cluster("a", **args) == sb.repo / "configs/clusters/a"
        assert py_state.read_state(**args)["MCM_CLUSTERS"] == "a"


class TestHelperContract:
    def test_exports_nothing_when_off(self, sb):
        script = """
_before=("${(@f)$(typeset -x)}")
source src/helpers/multi_cluster_helpers.sh
mcm_ensure_state_file
mcm_load_state
mcm_is_on || true
mcm_resolve_configs_root >/dev/null
_after=("${(@f)$(typeset -x)}")
print -r -- "${(j:\\n:)_before}" > "$TMPDIR/before"
print -r -- "${(j:\\n:)_after}" > "$TMPDIR/after"
"""
        result = sb.run_zsh(script)
        assert result.returncode == 0, result.stderr
        assert (sb.tmp / "before").read_text() == (sb.tmp / "after").read_text()

    def test_preexported_state_names_are_not_passed_on(self, sb):
        out = zsh_ok(sb, "mcm_load_state\nenv | grep -c '^APPLY_TO_ALL=' || true\nprint -r -- \"[$APPLY_TO_ALL]\"\n",
                     env={"APPLY_TO_ALL": "true"})
        assert out.splitlines() == ["0", "[false]"]

    def test_second_source_is_a_no_op_and_silent(self, sb):
        result = sb.run_zsh(SOURCE + SOURCE + 'print -r -- "${_MCM_HELPERS_LOADED}"\n')
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "1"
        assert result.stderr == ""

    def test_repo_root_ignores_another_checkouts_export(self, sb):
        out = zsh_ok(sb, "mcm_repo_root\nmcm_clusters_root\n", env={"_CP4D_REPO_ROOT": "/some/other"})
        assert out.splitlines() == [str(sb.repo), f"{sb.repo}/configs/clusters"]

    def test_repo_root_keeps_the_spelling_of_its_own_checkout(self, sb):
        link = sb.tmp / "link-to-repo"
        link.symlink_to(sb.repo)
        assert zsh_ok(sb, "mcm_repo_root\n", env={"_CP4D_REPO_ROOT": str(link)}).strip() == str(link)

    def test_sourcing_another_checkouts_copy_replaces_the_functions(self, sb):
        other = sb.tmp / "other/src/helpers"
        other.mkdir(parents=True)
        (other / "multi_cluster_helpers.sh").write_bytes((sb.repo / "src/helpers/multi_cluster_helpers.sh").read_bytes())
        out = zsh_ok(sb, f'source "{other}/multi_cluster_helpers.sh"\nmcm_repo_root\n')
        assert out.strip() == str(sb.tmp / "other")

    def test_flat_configs_root(self, sb):
        cases = [
            (str(sb.tmp / "other/configs"), f"{sb.repo}/configs"),
            (f"{sb.repo}/configs/clusters/itz-a", f"{sb.repo}/configs"),
            (f"{sb.repo}/other", f"{sb.repo}/configs"),
            (f"{sb.repo}/configs/alternate", f"{sb.repo}/configs/alternate"),
            (None, f"{sb.repo}/configs"),
        ]
        for given, expected in cases:
            assert zsh_ok(sb, "mcm_flat_configs_root\n", env={"CONFIGS_ROOT": given}).strip() == expected

    def test_python_off_ignores_a_configs_root_outside_configs(self, sb):
        env = {**sb.env(), "CONFIGS_ROOT": str(sb.repo / "other")}
        assert py_state.configs_root(sb.repo, env) == sb.repo / "configs"

    def test_repo_root_falls_back_to_the_helper_location(self, sb):
        assert zsh_ok(sb, "mcm_repo_root\n").strip() == str(sb.repo)

    def test_is_on_reports_an_invalid_file(self, sb):
        state_path(sb).write_text('export MULTI_CLUSTER_MANAGEMENT="nope"\n')
        result = sb.run_zsh(SOURCE + 'mcm_is_on; print -r -- "unreachable"\n')
        assert result.returncode == 2
        assert "unreachable" not in result.stdout

    def test_survives_interactive_shell_options(self, sb):
        result = sb.run_zsh("""
setopt sh_word_split ksh_arrays glob_subst
source src/helpers/multi_cluster_helpers.sh
mcm_register alpha https://api.alpha.example.com:6443
mcm_register beta
mcm_set_current alpha
mcm_is_registered beta
mcm_name_from_url https://api.alpha.example.com:6443
mcm_name_from_url 10.0.0.5
mcm_load_state
print -r -- "$MCM_CLUSTERS|$MCM_CURRENT_CLUSTER"
""", strict=False)
        assert result.returncode == 0, result.stderr
        assert result.stdout.splitlines() == ["alpha", "10-0-0-5", "alpha beta|alpha"]

    def test_harness_fake_tools_record_and_model_state(self, sb):
        sb.add_container("c1", running=False)
        result = sb.run_zsh("""
podman start c1
podman inspect -f '{{.State.Running}}' c1
podman exec c1 echo hi
podman events --filter event=exec --format '{{.Name}}'
podman ps --format '{{.Names}}'
podman stop -t 3 c1
podman exec c1 true || print -r -- "exec rc=$?"
podman machine stop
podman info || print -r -- "info rc=$?"
print -r -- "$(podman machine inspect --format '{{.State}}')"
oc whoami || print -r -- "whoami rc=$?"
oc login https://api.x:6443 --token=t
oc whoami --show-server
""")
        assert result.returncode == 0, result.stderr
        assert result.stdout.splitlines() == [
            "c1", "true", "c1", "c1", "c1", "exec rc=125", 'Machine "podman-machine-default" stopped successfully',
            "info rc=125", "stopped", "whoami rc=1", 'Logged into "https://api.x:6443" as "fake-user"', "https://api.x:6443",
        ]
        assert ["start", "c1"] in sb.calls("podman")
        assert sb.container("c1")["running"] is False
        assert sb.oc_session() == {"server": "https://api.x:6443", "user": "fake-user"}

    def test_harness_refuses_real_user_data(self):
        for rel in ("configs/cp4d_config", "service_instances", "concert_workspace"):
            with pytest.raises(ValueError):
                make_sandbox(extra=[rel])

    def test_harness_writes_flat_and_per_cluster_configs(self, sb):
        flat = sb.write_config("concert", ocp_url="https://api.c.example.com:6443")
        scoped = sb.write_config("cpd", cluster="a", extra={"FOO": "1"})
        assert flat == sb.repo / "configs/concert_config/concert_vars.sh"
        assert "OLM_UTILS_IMAGE" not in flat.read_text()
        assert scoped == sb.repo / "configs/clusters/a/cp4d_config/cpd_vars.sh"
        assert 'export FOO="1"' in scoped.read_text()

    def test_conftest_keeps_tests_off_the_real_state_file(self):
        real = py_state.repo_root() / "configs" / "multi_cluster_management.sh"
        assert py_state.state_file() != real



# ------------------------------------------------------------------------- one-way delineation
URL_ALPHA = "https://api.alpha.example.com:6443"
URL_BETA = "https://api.beta.example.com:6443"


def marker_path(sandbox, name):
    return sandbox.repo / "configs" / "clusters" / name / ".cluster"


def retire_by_hand(sandbox, name, url=""):
    path = sandbox.write_cluster_marker(name, url)
    path.write_text(path.read_text() + 'RETIRED="true"\n')
    return path


class TestDelineation:
    """A cluster with a .cluster marker stays delineated for good; zsh and Python agree on every lookup."""

    def zsh_lines(self, sb, script):
        return zsh_ok(sb, script).splitlines()

    def test_register_writes_delineated_in_both(self, sb):
        zsh_ok(sb, f"mcm_register alpha {URL_ALPHA}\n")
        py_state.register_cluster("beta", URL_BETA, **py_args(sb))
        for name in ("alpha", "beta"):
            assert 'DELINEATED="true"' in marker_path(sb, name).read_text().splitlines()
        strip = lambda text: [line for line in text.splitlines() if not line.startswith("CREATED=")]
        alpha = strip(marker_path(sb, "alpha").read_text())
        assert [line.replace("alpha", "beta") for line in alpha] == strip(marker_path(sb, "beta").read_text())
        assert marker_path(sb, "alpha").stat().st_mode & 0o777 == marker_path(sb, "beta").stat().st_mode & 0o777 == 0o644

    def test_a_marker_without_the_field_counts_as_delineated(self, sb):
        sb.write_cluster_marker("alpha", URL_ALPHA)  # the pre-field shape: NAME, OCP_URL, CREATED only
        assert "DELINEATED" not in marker_path(sb, "alpha").read_text()
        assert self.zsh_lines(sb, "mcm_is_delineated alpha && print yes\nmcm_delineated_clusters\n") == ["yes", "alpha"]
        assert py_state.is_delineated("alpha", sb.repo)
        assert py_state.delineated_clusters(repo=sb.repo) == ["alpha"]

    def test_lookups_agree(self, sb):
        sb.write_cluster_marker("b", URL_BETA)
        sb.write_cluster_marker("a", URL_ALPHA)
        retire_by_hand(sb, "a-c")
        (sb.repo / "configs/clusters/no-marker").mkdir()
        (sb.repo / "configs/clusters/Bad").mkdir()
        (sb.repo / "configs/clusters/Bad/.cluster").write_text('NAME="Bad"\n')
        script = "".join(
            f'mcm_is_delineated {n} && print -r -- "d {n}"; mcm_is_retired {n} && print -r -- "r {n}"\n'
            for n in ("a", "b", "a-c", "no-marker", "Bad", "ghost", "clusters")
        ) + 'print -r -- "all=$(mcm_delineated_clusters)"\nprint -r -- "active=$(mcm_delineated_clusters --exclude-retired)"\n'
        zsh = self.zsh_lines(sb, script)
        py = []
        for n in ("a", "b", "a-c", "no-marker", "Bad", "ghost", "clusters"):
            if py_state.is_delineated(n, sb.repo):
                py.append(f"d {n}")
            if py_state.is_retired(n, sb.repo):
                py.append(f"r {n}")
        py.append("all=" + " ".join(py_state.delineated_clusters(repo=sb.repo)))
        py.append("active=" + " ".join(py_state.delineated_clusters(include_retired=False, repo=sb.repo)))
        assert zsh == py == ["d a", "d b", "d a-c", "r a-c", "all=a a-c b", "active=a b"]

    @pytest.mark.parametrize("url,owner", [
        (URL_ALPHA, "alpha"),
        ("HTTPS://API.ALPHA.example.com:6443/", "alpha"),     # case and a trailing slash do not matter
        ("https://api.beta.other.net:6443", "beta"),          # no marker URL, but the derived name has a marker
        ("https://api.gone.example.com:6443", "gone"),        # retired still owns its URL
        ("https://api.nobody.example.com:6443", ""),
        ("", ""),
        ("https://", ""),                                     # no name can be derived
    ])
    def test_cluster_for_url_agrees(self, sb, url, owner):
        sb.write_cluster_marker("alpha", URL_ALPHA)
        sb.write_cluster_marker("beta", "")
        retire_by_hand(sb, "gone", "https://api.gone.example.com:6443")
        result = sb.run_zsh(SOURCE + 'print -r -- "[$(mcm_cluster_for_url "$1")]"\n', args=[url])
        assert result.returncode == 0 and result.stderr == "", result.stderr
        assert result.stdout.strip() == f"[{owner}]"
        assert py_state.cluster_for_url(url, sb.repo) == owner

    def test_marker_url_beats_the_derived_name(self, sb):
        sb.write_cluster_marker("alpha", "")
        sb.write_cluster_marker("prod", URL_ALPHA)
        assert zsh_ok(sb, f"mcm_cluster_for_url {URL_ALPHA}\n").strip() == "prod"
        assert py_state.cluster_for_url(URL_ALPHA, sb.repo) == "prod"

    def test_retire_and_unretire_write_the_same_marker_and_keep_other_lines(self, sb):
        for name in ("alpha", "beta"):
            path = sb.write_cluster_marker(name, f"https://api.{name}.example.com:6443")
            path.write_text(path.read_text() + 'OWNER="me"\n')
        zsh_ok(sb, "mcm_mark_retired alpha\n")
        py_state.mark_retired("beta", sb.repo)
        alpha, beta = marker_path(sb, "alpha").read_text(), marker_path(sb, "beta").read_text()
        assert alpha.replace("alpha", "beta") == beta
        assert alpha.splitlines()[-3:] == ['DELINEATED="true"', 'RETIRED="true"', 'OWNER="me"']
        assert 'CREATED="2026-11-09T00:00:00Z"' in alpha
        zsh_ok(sb, "mcm_unretire alpha\n")
        py_state.unretire("beta", sb.repo)
        alpha, beta = marker_path(sb, "alpha").read_text(), marker_path(sb, "beta").read_text()
        assert alpha.replace("alpha", "beta") == beta
        assert "RETIRED" not in alpha and 'DELINEATED="true"' in alpha and 'OWNER="me"' in alpha

    def test_retire_refuses_a_cluster_that_is_not_delineated(self, sb):
        (sb.repo / "configs/clusters/ghost").mkdir(parents=True)
        result = sb.run_zsh(SOURCE + "mcm_mark_retired ghost\n")
        assert result.returncode != 0 and "not delineated" in result.stderr
        with pytest.raises(ValueError, match="not delineated"):
            py_state.mark_retired("ghost", sb.repo)
        assert not marker_path(sb, "ghost").exists()

    def test_rebuild_skips_retired_clusters_in_both(self, sb):
        sb.write_cluster_marker("alpha", URL_ALPHA)
        retire_by_hand(sb, "beta", URL_BETA)
        assert py_state.read_state(**py_args(sb))["MCM_CLUSTERS"] == "alpha"
        zsh_ok(sb, "mcm_load_state\n")
        assert 'MCM_CLUSTERS="alpha"' in state_path(sb).read_text()
        assert marker_path(sb, "beta").exists()

    def test_register_unretires_in_both(self, sb):
        retire_by_hand(sb, "alpha", URL_ALPHA)
        retire_by_hand(sb, "beta", URL_BETA)
        zsh_ok(sb, "mcm_register alpha\n")
        py_state.register_cluster("beta", **py_args(sb))
        assert py_state.read_state(**py_args(sb))["MCM_CLUSTERS"] == "alpha beta"
        for name, url in (("alpha", URL_ALPHA), ("beta", URL_BETA)):
            text = marker_path(sb, name).read_text()
            assert "RETIRED" not in text and 'DELINEATED="true"' in text and f'OCP_URL="{url}"' in text


class TestConfigsRootModeOff:
    """Mode off: a pin to a delineated cluster still means that cluster's folder (zsh and Python)."""

    def state_off(self, sb):
        state_path(sb).write_text('export MULTI_CLUSTER_MANAGEMENT="false"\nexport MCM_CLUSTERS="alpha"\n')

    def env(self, sb, **extra):
        env = sb.env()
        env.pop("CONFIGS_ROOT", None)
        env.pop("MCM_CLUSTER", None)
        return env | extra

    @pytest.mark.parametrize("pin,expected", [("alpha", "configs/clusters/alpha"), ("ghost", "configs"), ("", "configs")])
    def test_resolve_configs_root_follows_a_delineated_pin(self, sb, pin, expected):
        sb.write_cluster_marker("alpha", URL_ALPHA)
        self.state_off(sb)
        env = self.env(sb, **({"MCM_CLUSTER": pin} if pin else {}))
        assert zsh_ok(sb, "mcm_resolve_configs_root\n", env=env).strip() == str(sb.repo / expected)
        assert py_state.configs_root(sb.repo, env) == sb.repo / expected
        assert py_state.pinned_cluster(sb.repo, env) == (pin if pin == "alpha" else None)

    def test_a_retired_pin_is_refused_in_both(self, sb):
        retire_by_hand(sb, "alpha", URL_ALPHA)
        self.state_off(sb)
        env = self.env(sb, MCM_CLUSTER="alpha")
        result = sb.run_zsh(SOURCE + "mcm_resolve_configs_root\n", env=env)
        assert result.returncode != 0 and "retired" in result.stderr
        with pytest.raises(ValueError, match="retired"):
            py_state.configs_root(sb.repo, env)

    def test_configs_root_from_a_pinned_loader_is_kept_with_the_mode_off(self, sb):
        sb.write_cluster_marker("alpha", URL_ALPHA)
        self.state_off(sb)
        root = sb.repo / "configs/clusters/alpha"
        assert py_state.configs_root(sb.repo, self.env(sb, MCM_CLUSTER="alpha", CONFIGS_ROOT=str(root))) == root
        flat_env = self.env(sb, MCM_CLUSTER="alpha", CONFIGS_ROOT=str(sb.repo / "configs"))
        assert py_state.configs_root(sb.repo, flat_env) == root
