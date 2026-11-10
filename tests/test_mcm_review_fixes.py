"""Regression tests for the review findings on multi-cluster management (one class or test per finding)."""

import os
import select
import stat
import subprocess
import sys
import tarfile
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mcm_harness import make_sandbox

from helpers import multi_cluster_notebook as nb
from helpers import multi_cluster_state as state

REPO = Path(__file__).resolve().parents[1]
UTILS = "src/utilities/multi_cluster_management_utils"
CLI = f"{UTILS}/multi_cluster.sh"
MIGRATE = f"{UTILS}/migrate_to_multi_cluster.sh"
WATCHER = "src/helpers/multi_cluster_idle_watcher.sh"
MIRROR = "scripts/private_registry_mirroring"
MIRROR_GEN = f"{MIRROR}/0_initial_setup/0.0_generate_mirror_config.sh"
KUBECOST_GEN = "src/utilities/kubecost_utils/generate_kubecost_config.sh"
DATASTAX_GEN = "scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh"
TOGGLE = "src/utilities/cpd-cli_utils/cpd-cli_toggle_olm_image.sh"
ADDON_LIST = "src/utilities/softwarehub_utils/get_instance_addon_list.sh"
BUNDLE = f"{MIRROR}/2_download_and_mirror/2.5_build_transfer_bundle.sh"
URL_A = "https://api.itz-a.example.com:6443"
URL_B = "https://api.itz-b.example.com:6443"
URL_C = "https://api.itz-c.example.com:6443"
PLAY = "olm-utils-play-v4"
SCAN_MARK = "mcm-proc-scan"
IDLE = "self 99\n1 0 /bin/sh /entry.sh\n"
BUSY = "self 99\n4242 1 skopeo copy --dest-creds admin:S3cretPw src dst\n"
BOOT = 'source "${0:A:h}/env_bootstrap.sh"\n'
# The real templates (concert, kubecost, datastax_mc, registry_mirror) start with this guard.
GUARD = '[[ "${ENV_TARGET:-}" == concert || "${ENV_TARGET:-}" == *concert_vars.sh ]] || return 0\n'


def sandbox(*extra):
    sb = make_sandbox(extra=[UTILS, *extra])
    # The real process table could hold anything: a fake ps keeps the preflight deterministic.
    ps = sb.bin / "ps"
    ps.write_text("#!/bin/zsh\nexit 0\n")
    ps.chmod(0o755)
    sb.add_exec_rule(SCAN_MARK, stdout=IDLE)
    return sb


def scan_first(sb, stdout, container="*"):
    rule = {"container": container, "contains": SCAN_MARK, "stdout": stdout, "stderr": "", "rc": 0}
    sb.update_fake_state(lambda fake: fake["exec_rules"].insert(0, rule))


def state_on(sb, clusters=(), current="", targets="", apply_to_all="false"):
    write_state(sb, on="true", clusters=clusters, current=current, targets=targets, apply_to_all=apply_to_all)


def write_state(sb, on="false", clusters=(), current="", targets="", apply_to_all="false"):
    (sb.repo / "configs" / "multi_cluster_management.sh").write_text(
        f'export MULTI_CLUSTER_MANAGEMENT="{on}"\nexport MCM_CLUSTERS="{" ".join(clusters)}"\n'
        f'export MCM_CURRENT_CLUSTER="{current}"\nexport APPLY_TO_ALL="{apply_to_all}"\n'
        f'export MCM_TARGET_CLUSTERS="{targets}"\n'
    )


def two_clusters(sb, current="itz-a", **kw):
    for name, url in (("itz-a", URL_A), ("itz-b", URL_B)):
        sb.write_cluster_marker(name, url)
        sb.write_config("cpd", ocp_url=url, cluster=name)
    state_on(sb, ("itz-a", "itz-b"), current=current, **kw)


def lease(sb, cluster, pid=None):
    path = sb.home / "cpd-cli" / "clusters" / cluster / ".leases" / str(pid or os.getpid())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("x\n")
    return path


def cli(sb, *args, input="", env=None):
    return subprocess.run(["zsh", str(sb.repo / CLI), *args], cwd=sb.repo, env=sb.env(env), input=input,
                          capture_output=True, text=True, timeout=120, check=False)


def migrate(sb, *args, env=None):
    return sb.run_script(MIGRATE, args=args, env=env, timeout=120)


def wait_for_prompt(proc, marker):
    """Reads the child's output until the prompt is on screen."""
    seen = b""
    deadline = time.time() + 60
    while marker not in seen:
        ready, _, _ = select.select([proc.stdout], [], [], max(0.0, deadline - time.time()))
        assert ready, f"no prompt; output so far: {seen!r}"
        chunk = os.read(proc.stdout.fileno(), 4096)
        assert chunk, f"exited before the prompt: {seen!r}"
        seen += chunk
    return seen


def interactive(sb, script, *args):
    return subprocess.Popen(["zsh", str(sb.repo / script), *args], cwd=sb.repo, env=sb.env(), stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def answer(proc, seen, text):
    proc.stdin.write(text)
    proc.stdin.close()
    rest = proc.stdout.read()
    return proc.wait(timeout=60), (seen + rest).decode(errors="replace")


# --- Finding 1: guarded product configs -------------------------------------------------------------------------
class TestGuardedConfigs:
    def concert(self, sb, url=URL_B):
        return sb.write_config("concert", text=f'{GUARD}export OCP_URL="{url}"\nexport OC_LOGIN="oc login {url}"\n')

    def test_a_guarded_concert_config_routes_by_its_own_url(self):
        with sandbox() as sb:
            sb.write_config("cpd", ocp_url=URL_A)
            self.concert(sb)
            result = migrate(sb, "--yes")
            assert result.returncode == 0, result.stdout + result.stderr
            assert (sb.repo / "configs/clusters/itz-b/concert_config/concert_vars.sh").is_file()
            assert not (sb.repo / "configs/clusters/itz-a/concert_config").exists()
            assert "itz-b" in state.read_state(repo=sb.repo, env=sb.env())["MCM_CLUSTERS"].split()

    def test_only_a_guarded_config_still_finds_its_cluster(self):
        with sandbox() as sb:
            self.concert(sb)
            result = migrate(sb, "--dry-run")
            assert result.returncode == 0, result.stdout + result.stderr
            assert "itz-b" in result.stdout

    def test_two_urls_under_one_name_are_seen_through_the_guard(self):
        with sandbox() as sb:
            sb.write_config("cpd", ocp_url=URL_A)
            self.concert(sb, url="https://api.itz-a.other.example.com:6443")
            result = migrate(sb, "--dry-run")
            assert result.returncode != 0
            assert "api.itz-a.other.example.com" in result.stdout + result.stderr


# --- Finding 2: a mode change under a running chain --------------------------------------------------------------
class TestModeChangeUnderARun:
    def target(self, sb, enabled, url=URL_B):
        return nb.resolve_target("cp4d_config", enabled, "", url, repo=sb.repo, env=sb.env())

    def test_turning_on_is_refused_over_a_busy_flat_container(self):
        with sandbox() as sb:
            sb.add_container(PLAY, running=True)
            scan_first(sb, BUSY, container=PLAY)
            blockers = nb.save_blockers(self.target(sb, True))
            assert blockers and "busy" in " ".join(blockers)
            assert "next step" in " ".join(blockers)

    def test_turning_on_is_refused_over_a_running_manage(self):
        with sandbox() as sb:
            (sb.bin / "ps").write_text('#!/bin/zsh\nprint -r -- "4321 /Users/x/cpd-cli/cpd-cli manage apply-olm"\nexit 0\n')
            assert any("cpd-cli manage" in b for b in nb.save_blockers(self.target(sb, True)))

    def test_turning_off_is_refused_over_a_live_lease(self):
        with sandbox() as sb:
            two_clusters(sb)
            lease(sb, "itz-a")
            blockers = nb.save_blockers(self.target(sb, False, url=URL_C))
            assert any("itz-a" in b and "live" in b for b in blockers)

    def test_a_dead_lease_does_not_block(self):
        with sandbox() as sb:
            two_clusters(sb)
            child = subprocess.Popen(["/usr/bin/true"])
            child.wait()
            lease(sb, "itz-a", pid=child.pid)
            assert nb.save_blockers(self.target(sb, False, url=URL_C)) == []

    def test_unticked_save_of_a_delineated_cluster_is_not_a_mode_change(self):
        """It goes into the cluster's folder and keeps the mode on, so a live run does not block it."""
        with sandbox() as sb:
            two_clusters(sb)
            lease(sb, "itz-a")
            target = self.target(sb, False)
            assert target.forced and target.cluster == "itz-b" and target.mode_after
            assert nb.save_blockers(target) == []

    def test_a_quiet_machine_saves(self):
        with sandbox() as sb:
            assert nb.save_blockers(self.target(sb, True)) == []

    def test_staying_on_is_not_a_mode_change(self):
        """A pin outlives a change of current cluster, so a live run does not block this."""
        with sandbox() as sb:
            two_clusters(sb)
            lease(sb, "itz-a")
            assert nb.save_blockers(self.target(sb, True)) == []

    def test_on_no_migrate_refuses_over_a_busy_flat_container(self):
        with sandbox() as sb:
            sb.write_config("cpd", ocp_url=URL_A)
            sb.add_container(PLAY, running=True)
            scan_first(sb, BUSY, container=PLAY)
            result = cli(sb, "on", "--no-migrate")
            assert result.returncode == 1
            assert "stays off" in result.stderr
            assert state.read_state(repo=sb.repo, env=sb.env())["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_preflight_only_answers_without_touching_the_state(self):
        with sandbox() as sb:
            result = migrate(sb, "--preflight-only")
            assert result.returncode == 0, result.stdout + result.stderr
            assert not (sb.repo / "configs/multi_cluster_management.sh").exists()


# --- Finding 3: --copy-from and a live install ------------------------------------------------------------------
def test_copy_from_leaves_the_source_clusters_live_install_behind():
    with sandbox() as sb:
        sb.write_cluster_marker("itz-a", URL_A)
        vars_file = sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        (vars_file.parent / "cpd_instance_details.sh").write_text('export CPD_URL="https://cpd.apps.itz-a"\nexport CPD_APIKEY="A"\n')
        managed = vars_file.parent / "managed-service-instances" / "db2"
        managed.mkdir(parents=True)
        (managed / "x-instance_details.sh").write_text('export DB2="db2.apps.itz-a"\n')
        state_on(sb, ("itz-a",), current="itz-a")
        result = cli(sb, "add", "itz-b", "--url", URL_B, "--copy-from", "itz-a")
        assert result.returncode == 0, result.stderr
        copy = sb.repo / "configs/clusters/itz-b/cp4d_config"
        assert (copy / "cpd_vars.sh").is_file()
        assert not (copy / "cpd_instance_details.sh").exists()
        assert not (copy / "managed-service-instances").exists()
        assert "cpd_instance_details.sh" in result.stdout
        assert (vars_file.parent / "cpd_instance_details.sh").is_file()


# --- Findings 4, 5, 7, 16, 18, 29, 10: config generators ---------------------------------------------------------
GENERATOR_EXTRAS = [
    "pyproject.toml",
    "src/helpers/version_catalog.json",
    "src/helpers/config_file_jinja2_templates",
    "scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh",
    "src/utilities/kubecost_utils/generate_kubecost_config.sh",
    f"{MIRROR}/0_initial_setup",
]


@pytest.fixture
def gen():
    with sandbox(*GENERATOR_EXTRAS) as sb:
        os.symlink(REPO / ".venv", sb.repo / ".venv")
        yield sb


def generate_datastax(sb, *flags, env=None):
    return sb.run_script(DATASTAX_GEN, args=["--empty", "--force", *flags], env=env, timeout=60)


def mc_file(sb, cluster):
    return sb.repo / "configs/clusters" / cluster / "datastax_mc_config/datastax_mc_vars.sh"


FLAT_MC = "configs/datastax_mc_config/datastax_mc_vars.sh"


class TestGeneratorSelection:
    def test_single_entry_target_list_wins_over_current(self, gen):
        two_clusters(gen, targets="itz-b")
        result = generate_datastax(gen)
        assert result.returncode == 0, result.stdout + result.stderr
        assert mc_file(gen, "itz-b").is_file() and not mc_file(gen, "itz-a").exists()

    @pytest.mark.parametrize("kw", [{"targets": "itz-a itz-b"}, {"apply_to_all": "true"}])
    def test_several_targets_are_refused(self, gen, kw):
        two_clusters(gen, **kw)
        result = generate_datastax(gen)
        assert result.returncode != 0
        assert "writes one cluster's config" in result.stderr
        assert not mc_file(gen, "itz-a").exists() and not mc_file(gen, "itz-b").exists()

    def test_a_flag_beats_the_list(self, gen):
        two_clusters(gen, apply_to_all="true")
        assert generate_datastax(gen, "--target-cluster", "itz-b").returncode == 0
        assert mc_file(gen, "itz-b").is_file()

    def test_a_cluster_named_by_the_variable_is_registered(self, gen):
        state_on(gen)
        result = generate_datastax(gen, env={"MCM_CLUSTER": "newc"})
        assert result.returncode == 0, result.stdout + result.stderr
        assert mc_file(gen, "newc").is_file()
        assert (gen.repo / "configs/clusters/newc/.cluster").is_file()
        assert state.read_state(repo=gen.repo, env=gen.env())["MCM_CLUSTERS"].split() == ["newc"]

    def test_off_ignores_a_shell_still_pinned_to_a_cluster_without_a_folder(self, gen):
        write_state(gen, on="false", clusters=("itz-a",))
        env = {"MCM_CLUSTER": "itz-a", "CONFIGS_ROOT": str(gen.repo / "configs/clusters/itz-a")}
        assert generate_datastax(gen, env=env).returncode == 0
        assert (gen.repo / FLAT_MC).is_file()
        assert not mc_file(gen, "itz-a").exists()

    def test_off_a_pin_to_a_delineated_cluster_holds(self, gen):
        """A delineated cluster never goes back to the flat layout, whatever the flag says."""
        gen.write_cluster_marker("itz-a", URL_A)
        write_state(gen, on="false", clusters=("itz-a",))
        env = {"MCM_CLUSTER": "itz-a", "CONFIGS_ROOT": str(gen.repo / "configs")}
        result = generate_datastax(gen, env=env)
        assert result.returncode == 0, result.stdout + result.stderr
        assert mc_file(gen, "itz-a").is_file()
        assert not (gen.repo / FLAT_MC).exists()
        assert state.read_state(repo=gen.repo, env=gen.env())["MULTI_CLUSTER_MANAGEMENT"] == "false"

    def test_off_children_see_a_delineated_target(self, gen):
        gen.write_cluster_marker("itz-b", URL_B)
        driver = gen.repo / "pin_probe.sh"
        driver.write_text(
            'source src/helpers/multi_cluster_generator_args.sh\nmcm_generator_setup --target-cluster itz-b || exit 1\n'
            'zsh -c \'print -r -- "CHILD=${MCM_CLUSTER:-none} ROOT=${CONFIGS_ROOT}"\'\n'
        )
        result = gen.run_script("pin_probe.sh")
        assert f"CHILD=itz-b ROOT={gen.repo}/configs/clusters/itz-b" in result.stdout, result.stdout + result.stderr

    def test_off_ignores_another_checkouts_exports(self, gen):
        other = gen.tmp / "other"
        (other / "configs").mkdir(parents=True)
        env = {"CONFIGS_ROOT": str(other / "configs"), "_CP4D_REPO_ROOT": str(other)}
        assert generate_datastax(gen, env=env).returncode == 0
        assert (gen.repo / FLAT_MC).is_file()
        assert not (other / FLAT_MC).exists()

    def test_children_see_the_generators_cluster(self, gen):
        two_clusters(gen)
        driver = gen.repo / "pin_probe.sh"
        driver.write_text(
            'source src/helpers/multi_cluster_generator_args.sh\nmcm_generator_setup --target-cluster itz-b || exit 1\n'
            'zsh -c \'print -r -- "CHILD=${MCM_CLUSTER:-none} ROOT=${CONFIGS_ROOT}"\'\n'
        )
        result = gen.run_script("pin_probe.sh")
        assert f"CHILD=itz-b ROOT={gen.repo}/configs/clusters/itz-b" in result.stdout

    def registries(self, sb):
        for name, reg in (("itz-a", "reg-a.example.com/x"), ("itz-b", "reg-b.example.com/x")):
            sb.write_config("cpd", ocp_url=f"https://api.{name}.example.com:6443", cluster=name, extra={
                "PRIVATE_REGISTRY_LOCATION": reg, "PRIVATE_REGISTRY_PUSH_USER": f"user-{name}",
            })

    def test_prefill_for_a_named_cluster_reads_that_cluster(self, gen):
        two_clusters(gen)
        self.registries(gen)
        result = gen.run_script(MIRROR_GEN, args=["--target-cluster", "itz-b", "--prefill-from-installs", "cpd"], timeout=120)
        assert "reg-b.example.com/x" in result.stdout, result.stdout + result.stderr
        assert "reg-a.example.com" not in result.stdout

    def test_prefill_for_a_cluster_without_a_folder_refuses_while_off(self, gen):
        write_state(gen, on="false")
        result = gen.run_script(MIRROR_GEN, args=["--target-cluster", "itz-b", "--prefill-from-installs", "cpd"], timeout=120)
        assert result.returncode != 0
        assert "multi-cluster mode is off" in result.stderr and "no folder of its own" in result.stderr

    def test_prefill_for_a_delineated_cluster_reads_that_cluster_while_off(self, gen):
        two_clusters(gen)
        write_state(gen, on="false", clusters=("itz-a", "itz-b"), current="itz-a")
        self.registries(gen)
        result = gen.run_script(MIRROR_GEN, args=["--target-cluster", "itz-b", "--prefill-from-installs", "cpd"], timeout=120)
        assert "reg-b.example.com/x" in result.stdout, result.stdout + result.stderr
        assert "reg-a.example.com" not in result.stdout


# --- Finding 6: reading OCP_URL from a copied config ------------------------------------------------------------
CONCERT_SHAPE = f'''export OCP_URL="{URL_B}"
export OC_LOGIN="oc login {URL_B} --token=t"
if [[ -n "${{CONCERT_TARGET_OC_LOGIN:-}}" ]]; then
    export OC_LOGIN="${{CONCERT_TARGET_OC_LOGIN}}"
    export OCP_URL=""
fi
'''


class TestCopiedUrl:
    def seed(self, sb, text):
        sb.write_cluster_marker("itz-b", URL_B)
        sb.write_config("concert", cluster="itz-b", text=text)
        state_on(sb, ("itz-b",), current="itz-b")

    def test_a_trailing_empty_url_does_not_hide_the_real_one(self):
        with sandbox() as sb:
            self.seed(sb, CONCERT_SHAPE)
            assert cli(sb, "add", "itz-c", "--url", URL_C, "--copy-from", "itz-b").returncode == 0
            text = (sb.repo / "configs/clusters/itz-c/concert_config/concert_vars.sh").read_text()
            assert URL_B not in text and URL_C in text

    def test_no_url_argument_warns_about_the_source_url(self):
        with sandbox() as sb:
            self.seed(sb, CONCERT_SHAPE)
            result = cli(sb, "add", "itz-c", "--copy-from", "itz-b")
            assert URL_B in result.stderr

    def test_an_unreadable_url_is_named(self):
        with sandbox() as sb:
            self.seed(sb, 'export OCP_URL="${SOME_URL}"\n')
            result = cli(sb, "add", "itz-c", "--url", URL_C, "--copy-from", "itz-b")
            assert "Could not read an OCP_URL" in result.stderr


# --- Finding 8: rollback after a rename --------------------------------------------------------------------------
def test_rollback_refuses_when_the_moved_folders_are_gone():
    with sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        assert migrate(sb, "--yes").returncode == 0
        assert cli(sb, "rename", "itz-a", "prod").returncode == 0
        result = migrate(sb, "--rollback", "--yes")
        assert result.returncode != 0
        # A completed migration is final (one-way per cluster), before any folder check.
        assert "final" in result.stderr
        assert (sb.repo / "configs/clusters/prod/cp4d_config").is_dir()
        assert state.read_state(repo=sb.repo, env=sb.env())["MULTI_CLUSTER_MANAGEMENT"] == "true"


# --- Finding 9: file modes ------------------------------------------------------------------------------------------
def test_no_shell_script_in_the_repo_lacks_the_executable_bit():
    """A mode-off env load treats any non-executable .sh as a reason to run the prep step (T1 sets _CP4D_PREP_DONE)."""
    listed = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "*.sh"], cwd=REPO, capture_output=True,
                            text=True, check=True)
    paths = [REPO / p for p in listed.stdout.splitlines()]
    assert paths
    assert [str(p) for p in paths if p.exists() and not os.stat(p).st_mode & stat.S_IXUSR] == []


# --- Findings 10, 12: Python configs_root ------------------------------------------------------------------------
class TestPythonConfigsRoot:
    def test_off_ignores_a_root_outside_this_checkout(self):
        with sandbox() as sb:
            env = sb.env({"CONFIGS_ROOT": str(sb.tmp / "other/configs")})
            assert state.configs_root(sb.repo, env) == sb.repo / "configs"

    def test_off_ignores_a_stale_cluster_root(self):
        with sandbox() as sb:
            env = sb.env({"CONFIGS_ROOT": str(sb.repo / "configs/clusters/itz-a")})
            assert state.configs_root(sb.repo, env) == sb.repo / "configs"

    def test_off_keeps_this_checkouts_flat_root(self):
        with sandbox() as sb:
            env = sb.env({"CONFIGS_ROOT": str(sb.repo / "configs")})
            assert state.configs_root(sb.repo, env) == sb.repo / "configs"

    def test_mcm_cluster_beats_a_shells_root_for_another_cluster(self):
        with sandbox() as sb:
            two_clusters(sb)
            env = sb.env({"MCM_CLUSTER": "itz-b", "CONFIGS_ROOT": str(sb.repo / "configs/clusters/itz-a")})
            assert state.configs_root(sb.repo, env) == sb.repo / "configs/clusters/itz-b"
            assert state.writable_configs_root(sb.repo, env) == sb.repo / "configs/clusters/itz-b"

    def test_a_root_for_the_named_cluster_stands(self):
        with sandbox() as sb:
            two_clusters(sb)
            root = str(sb.repo / "configs/clusters/itz-b")
            env = sb.env({"MCM_CLUSTER": "itz-b", "CONFIGS_ROOT": root})
            assert state.configs_root(sb.repo, env) == Path(root)


# --- Finding 11: ENV_TARGET as a file of another cluster --------------------------------------------------------------
SHOW = 'print -r -- "PIN=${MCM_CLUSTER:-} URL=${OCP_URL:-}"\n'


class TestEnvTargetFile:
    def test_another_clusters_file_is_refused(self):
        with sandbox() as sb:
            two_clusters(sb, current="itz-b")
            path = str(sb.repo / "configs/clusters/itz-a/cp4d_config/cpd_vars.sh")
            result = sb.run_zsh(BOOT + SHOW, env={"ENV_TARGET": path})
            assert result.returncode != 0
            assert "not in the folder of cluster 'itz-b'" in result.stderr
            assert "PIN=itz-b" not in result.stdout

    def test_the_flat_file_is_refused_with_the_mode_on(self):
        with sandbox() as sb:
            two_clusters(sb, current="itz-a")
            flat = sb.write_config("cpd", ocp_url="https://api.flat.example.com:6443")
            result = sb.run_zsh(BOOT + SHOW, env={"ENV_TARGET": str(flat)})
            assert result.returncode != 0

    def test_a_file_of_this_cluster_passes(self):
        with sandbox() as sb:
            two_clusters(sb, current="itz-b")
            restore = sb.repo / "configs/clusters/itz-b/oadp/restore_targets/t_vars.sh"
            restore.parent.mkdir(parents=True)
            restore.write_text('export OCP_URL="https://api.restore.example.com:6443"\n')
            result = sb.run_zsh(BOOT + SHOW, env={"ENV_TARGET": str(restore)})
            assert result.returncode == 0, result.stderr
            assert "URL=https://api.restore.example.com:6443" in result.stdout

    def test_the_documented_mirror_file_may_live_elsewhere(self):
        with sandbox() as sb:
            two_clusters(sb, current="itz-a")
            elsewhere = sb.tmp / "my_mirror_vars.sh"
            elsewhere.write_text('export MIRROR_CONFIG_VERSION="2"\n')
            result = sb.run_zsh(BOOT + SHOW, env={"ENV_TARGET": str(elsewhere), "MIRROR_CONFIG_FILE": str(elsewhere)})
            assert result.returncode == 0, result.stderr

    def test_fan_out_refuses_a_file(self):
        with sandbox() as sb:
            two_clusters(sb, apply_to_all="true")
            path = str(sb.repo / "configs/clusters/itz-a/cp4d_config/cpd_vars.sh")
            result = sb.run_zsh(BOOT + SHOW, env={"ENV_TARGET": path})
            assert result.returncode != 0
            assert "belongs to one cluster" in result.stderr
            assert "[MCM] Running" not in result.stdout

    def test_mode_off_still_takes_any_path(self):
        with sandbox() as sb:
            sb.write_config("cpd", ocp_url=URL_A)
            other = sb.tmp / "x_vars.sh"
            other.write_text('export OCP_URL="https://api.other.example.com:6443"\n')
            result = sb.run_zsh(BOOT + SHOW, env={"ENV_TARGET": str(other)})
            assert result.returncode == 0, result.stderr
            assert "api.other.example.com" in result.stdout


# --- Finding 13: re-check after a confirmation prompt ------------------------------------------------------------------
class TestRecheckAfterPrompt:
    def test_purge_stops_when_a_run_started_during_the_prompt(self):
        with sandbox() as sb:
            two_clusters(sb)
            proc = interactive(sb, CLI, "remove", "itz-a", "--purge")
            seen = wait_for_prompt(proc, b"permanently: ")
            lease(sb, "itz-a")
            rc, output = answer(proc, seen, b"itz-a\n")
            assert rc == 1, output
            assert "A run is live on cluster" in output
            assert (sb.repo / "configs/clusters/itz-a/.cluster").is_file()
            assert state.read_state(repo=sb.repo, env=sb.env())["MCM_CLUSTERS"].split() == ["itz-a", "itz-b"]

    def test_purge_goes_ahead_when_nothing_started(self):
        with sandbox() as sb:
            two_clusters(sb)
            proc = interactive(sb, CLI, "remove", "itz-a", "--purge")
            seen = wait_for_prompt(proc, b"permanently: ")
            rc, output = answer(proc, seen, b"itz-a\n")
            assert rc == 0, output
            assert not (sb.repo / "configs/clusters/itz-a").exists()

    def test_migrate_stops_when_a_run_started_during_the_prompt(self):
        with sandbox() as sb:
            sb.write_config("cpd", ocp_url=URL_A)
            proc = interactive(sb, MIGRATE)
            seen = wait_for_prompt(proc, b"[y/N] ")
            # Not this process: the preflight leaves out its own parent.
            other = subprocess.Popen(["/bin/sleep", "60"])
            try:
                lease(sb, "itz-z", pid=other.pid)
                rc, output = answer(proc, seen, b"y\n")
            finally:
                other.kill()
                other.wait()
            assert rc == 1, output
            assert "A run is live on cluster itz-z" in output
            assert (sb.repo / "configs/cp4d_config/cpd_vars.sh").is_file()


# --- Finding 14: transfer bundle from a flat setup with old cluster folders --------------------------------------------
def test_flat_bundle_leaves_cluster_folders_out():
    with sandbox(f"{MIRROR}/2_download_and_mirror") as sb:
        write_state(sb, on="false")
        bundle_dir = sb.tmp / "bundle"
        sb.write_config("cpd", ocp_url=URL_A)
        sb.write_config("registry_mirror", text=(
            'export MIRROR_CONFIG_VERSION="2"\nexport MIRROR_REGISTRY_ROOT="reg:5000"\n'
            f'export MIRROR_TRANSPORT="stopover"\nexport MIRROR_BUNDLE_DIR="{bundle_dir}"\n'
        ))
        kube = sb.repo / "configs/clusters/itz-b/.home/.kube/config"
        kube.parent.mkdir(parents=True)
        kube.write_text("token\n")
        backup = sb.repo / "configs/old_configs/pre_multi_cluster_1/cp4d_config/cpd_vars.sh"
        backup.parent.mkdir(parents=True)
        backup.write_text("old\n")
        keep = sb.repo / "configs/old_configs/other/note.txt"
        keep.parent.mkdir(parents=True)
        keep.write_text("mine\n")
        inventory = sb.repo / "registry_mirror_workspace/inventory"
        inventory.mkdir(parents=True)
        (inventory / "inventory.json").write_text("{}\n")
        (inventory / "report.txt").write_text("r\n")
        for args in (["init", "-q"], ["add", "-A"]):
            subprocess.run(["git", *args], cwd=sb.repo, check=True, capture_output=True,
                           env={"PATH": "/usr/bin:/bin", "HOME": str(sb.home)})
        result = sb.run_script(BUNDLE, args=["--include-configs", "--skip-tools"], timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        with tarfile.open(bundle_dir / "config" / "configs-with-secrets.tar.gz") as archive:
            names = archive.getnames()
        assert "configs/cp4d_config/cpd_vars.sh" in names
        assert "configs/old_configs/other/note.txt" in names
        assert not [n for n in names if "clusters" in n or "pre_multi_cluster" in n or ".home" in n]


# --- Finding 15: podman events time ---------------------------------------------------------------------------------
class TestEventTime:
    def epoch(self, sb, text):
        script = f'source src/helpers/multi_cluster_helpers.sh\n_mcm_epoch_from_timestamp "{text}"\n'
        return sb.run_zsh(script, check=True).stdout.strip()

    def test_epoch_digits_are_returned_as_they_are(self):
        with sandbox() as sb:
            assert self.epoch(sb, "1794236737") == "1794236737"

    def test_date_text_still_parses(self):
        with sandbox() as sb:
            assert self.epoch(sb, "2026-11-09T10:00:00Z") == "1794218400"
            assert self.epoch(sb, "2026-11-09 11:00:00.5 +0100 CET") == "1794218400"

    @pytest.mark.parametrize("text", [None, "go"])
    def test_status_counts_an_exec_with_either_format(self, text):
        with sandbox() as sb:
            two_clusters(sb)
            name = f"{PLAY}-itz-a"
            sb.add_container(name, running=True, started_at="2026-01-01T00:00:00Z")
            moment = time.time() - 300
            shown = None if text is None else time.strftime("%Y-%m-%d %H:%M:%S.000 +0000 UTC", time.gmtime(moment))
            sb.add_event(name, "exec", when=moment, time_text=shown)
            result = cli(sb, "containers", "status")
            row = next(line for line in result.stdout.splitlines() if name in line)
            assert " 5m " in row or " 4m " in row, row


# --- Finding 19: mode-off null glob --------------------------------------------------------------------------------
def test_flat_layout_with_no_cp4d_config_still_fails_as_it_did():
    with sandbox() as sb:
        write_state(sb, on="false")
        result = sb.run_zsh(BOOT, env=None)
        assert result.returncode != 0
        assert "no matches found" in result.stderr


def test_cluster_with_no_cp4d_config_is_fine():
    with sandbox() as sb:
        sb.write_cluster_marker("itz-a", URL_A)
        sb.write_config("concert", ocp_url=URL_A, cluster="itz-a")
        state_on(sb, ("itz-a",), current="itz-a")
        result = sb.run_zsh(BOOT + SHOW, env={"ENV_TARGET": "concert"})
        assert result.returncode == 0, result.stderr
        assert "PIN=itz-a" in result.stdout


# --- Finding 20: invalid setting with the mode off ------------------------------------------------------------------
def test_a_mistyped_setting_does_not_stop_a_flat_run():
    with sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        (sb.repo / "configs/multi_cluster_management.sh").write_text(
            'export MULTI_CLUSTER_MANAGEMENT="false"\nexport MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="2h"\n')
        result = sb.run_zsh(BOOT + SHOW)
        assert result.returncode == 0, result.stderr
        assert f"URL={URL_A}" in result.stdout
        assert "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES" in result.stderr


def test_turning_on_with_a_mistyped_setting_stops():
    with sandbox() as sb:
        (sb.repo / "configs/multi_cluster_management.sh").write_text(
            'export MULTI_CLUSTER_MANAGEMENT="false"\nexport MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="2h"\n')
        result = cli(sb, "on", "--no-migrate")
        assert result.returncode != 0
        assert "MCM_CONTAINER_IDLE_TIMEOUT_MINUTES" in result.stderr
        assert 'MULTI_CLUSTER_MANAGEMENT="false"' in (sb.repo / "configs/multi_cluster_management.sh").read_text()


# --- Finding 21: unwritable configs/ -----------------------------------------------------------------------------------
def test_a_read_only_configs_folder_stays_silent_on_env_load():
    with sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        configs = sb.repo / "configs"
        configs.chmod(0o555)
        try:
            result = sb.run_zsh(BOOT + SHOW)
        finally:
            configs.chmod(0o755)
        assert result.returncode == 0, result.stderr
        assert "[ERROR]" not in result.stderr and "mktemp" not in result.stderr and "Could not create" not in result.stderr


def test_explicit_write_still_reports_a_read_only_configs_folder():
    with sandbox() as sb:
        configs = sb.repo / "configs"
        configs.chmod(0o555)
        try:
            result = sb.run_zsh('source src/helpers/multi_cluster_helpers.sh\nmcm_write_state APPLY_TO_ALL=true\n')
        finally:
            configs.chmod(0o755)
        assert result.returncode != 0
        assert "[ERROR]" in result.stderr


# --- Finding 22: import as src.tui.* -------------------------------------------------------------------------------
def test_settings_works_when_imported_through_src():
    with sandbox("src/tui") as sb:
        code = "import src.tui.instance_manager.settings as s; print(s.config_dir())"
        env = sb.env({"PYTHONPATH": None, "CONFIG_DIR": None})
        result = subprocess.run([sys.executable, "-c", code], cwd=sb.repo, env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == str(sb.repo / "configs/cp4d_config")


# --- Finding 23: read-only addon list --------------------------------------------------------------------------------
class TestAddonList:
    def seed(self, sb):
        (sb.repo / "src/helpers/cpd_api_helpers.sh").write_text('cpdapi_login() { CPDAPI_TOKEN=t; }\n')
        curl = sb.bin / "curl"
        curl.write_text('#!/bin/zsh\nprint -r -- \'{"requestObj":[{"Type":"wx","State":"on"}]}\'\n')
        curl.chmod(0o755)

    def test_mode_off_sources_the_two_files_only(self):
        with sandbox(ADDON_LIST) as sb:
            self.seed(sb)
            vars_file = sb.write_config("cpd", ocp_url=URL_A)
            (vars_file.parent / "cpd_instance_details.sh").write_text('export CPD_URL="https://x" CPD_USERNAME=a CPD_PASSWORD=b\n')
            write_state(sb, on="false")
            result = sb.run_script(ADDON_LIST, cwd=sb.repo)
            assert result.returncode == 0, result.stderr
            assert result.stdout.strip() == "wx on"
            assert "[ENV]" not in result.stderr
            assert not (sb.repo / "service_instances").exists()
            assert not (sb.home / "cpd-cli/work").exists()

    def test_mode_on_loads_the_clusters_config(self):
        with sandbox(ADDON_LIST) as sb:
            self.seed(sb)
            two_clusters(sb, current="itz-b")
            root = sb.repo / "configs/clusters/itz-b/cp4d_config"
            (root / "cpd_instance_details.sh").write_text('export CPD_URL="https://b" CPD_USERNAME=a CPD_PASSWORD=b\n')
            result = sb.run_script(ADDON_LIST, cwd=sb.repo)
            assert result.returncode == 0, result.stderr
            assert result.stdout.strip() == "wx on"


# --- Finding 24: kubeconfig context choice ----------------------------------------------------------------------------
def _fake_oc(sb, contexts, clusters, current):
    oc = sb.bin / "oc"
    oc.write_text(f"""#!/bin/zsh
case "$*" in
  *"contexts[*]"*) printf '{contexts}'; exit 0 ;;
  *"clusters[*]"*) printf '{clusters}'; exit 0 ;;
  "config current-context"*) print -r -- {current}; exit 0 ;;
  "config view"*) print -r -- "kubeconfig-for: $*"; exit 0 ;;
esac
exit 0
""")
    oc.chmod(0o755)
    kube = sb.home / ".kube" / "config"
    kube.parent.mkdir(parents=True, exist_ok=True)
    kube.write_text("original\n")


def test_an_exact_url_beats_the_current_context_with_the_same_derived_name():
    with sandbox() as sb:
        url = "https://c100-e.us-south.containers.example.com:31234"
        sb.write_config("cpd", ocp_url=url)
        _fake_oc(sb, "us-right\\tcl-us\\neu-other\\tcl-eu\\n",
                 f"cl-us\\t{url}\\ncl-eu\\thttps://c100-e.eu-de.containers.example.com:30000\\n", "eu-other")
        assert migrate(sb, "--yes").returncode == 0
        seeded = (sb.repo / "configs/clusters/c100-e/.home/.kube/config").read_text()
        assert "--context=us-right" in seeded and "eu-other" not in seeded


def test_a_same_named_server_is_not_used_when_the_url_is_known():
    with sandbox() as sb:
        url = "https://c100-e.us-south.containers.example.com:31234"
        sb.write_config("cpd", ocp_url=url)
        _fake_oc(sb, "eu-other\\tcl-eu\\n", "cl-eu\\thttps://c100-e.eu-de.containers.example.com:30000\\n", "eu-other")
        assert migrate(sb, "--yes").returncode == 0
        assert not (sb.repo / "configs/clusters/c100-e/.home/.kube/config").exists()


# --- Finding 25: watcher log ---------------------------------------------------------------------------------------------
def test_the_watcher_log_holds_no_arguments_and_is_private():
    with sandbox() as sb:
        two_clusters(sb, current="itz-a")
        scan_first(sb, BUSY)
        name = f"{PLAY}-itz-a"
        sb.add_container(name, running=True, started_at="2026-01-01T00:00:00Z")
        activity = sb.home / "cpd-cli/clusters/itz-a/.last_activity"
        activity.parent.mkdir(parents=True, exist_ok=True)
        activity.touch()
        os.utime(activity, (time.time() - 3 * 3600, time.time() - 3 * 3600))
        result = sb.run_script(WATCHER, args=["--once"])
        assert result.returncode == 0, result.stderr
        log = sb.home / "cpd-cli/clusters/.idle-watcher.log"
        text = log.read_text()
        assert "process 4242: skopeo" in text
        assert "S3cretPw" not in text and "--dest-creds" not in text
        assert stat.S_IMODE(log.stat().st_mode) == 0o600


# --- Finding 26: path rewrite ---------------------------------------------------------------------------------------------
def test_rename_leaves_sibling_cluster_paths_alone():
    with sandbox() as sb:
        for name in ("prod", "prod-dr"):
            sb.write_cluster_marker(name, f"https://api.{name}.example.com:6443")
        state_on(sb, ("prod", "prod-dr"), current="prod")
        root = sb.repo / "configs/clusters"
        props = root / "prod/confluent_platform_config/client.properties"
        props.parent.mkdir(parents=True)
        props.write_text(
            f"a={root}/prod/confluent_platform_config/ts.jks\n"
            f"b={root}/prod-dr/confluent_platform_config/ts.jks\n"
            f"c={root}/prod\n"
        )
        assert cli(sb, "rename", "prod", "east").returncode == 0
        text = (root / "east/confluent_platform_config/client.properties").read_text()
        assert f"a={root}/east/confluent_platform_config/ts.jks" in text
        assert f"b={root}/prod-dr/confluent_platform_config/ts.jks" in text
        assert f"c={root}/east\n" in text


# --- Finding 27: toggling the image of a busy container ----------------------------------------------------------------
class TestToggle:
    def run(self, sb, scan):
        sb.write_cluster_marker("itz-a", URL_A)
        sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a", extra={"VERSION": "5.4.0"})
        state_on(sb, ("itz-a",), current="itz-a")
        sb.add_container(f"{PLAY}-itz-a", running=True)
        if scan:
            scan_first(sb, scan, container=f"{PLAY}-itz-a")
        return sb.run_script(TOGGLE, args=["premium"], timeout=60)

    def test_a_busy_container_stays(self):
        with sandbox(TOGGLE) as sb:
            result = self.run(sb, BUSY)
            assert result.returncode != 0
            assert "left in place" in result.stdout
            assert sb.container(f"{PLAY}-itz-a") is not None
            assert not [c for c in sb.calls("podman") if c[:1] == ["rm"]]

    def test_an_idle_container_is_replaced(self):
        with sandbox(TOGGLE) as sb:
            result = self.run(sb, None)
            assert result.returncode == 0, result.stdout + result.stderr
            assert [c for c in sb.calls("podman") if c[:2] == ["rm", "-f"]]


# --- Finding 28: Finder's .DS_Store ------------------------------------------------------------------------------------
class TestDsStore:
    def migrated(self, sb):
        sb.write_config("cpd", ocp_url=URL_A)
        (sb.home / "cpd-cli/work").mkdir(parents=True, exist_ok=True)
        (sb.home / "cpd-cli/work/f").write_text("x\n")
        assert migrate(sb, "--yes").returncode == 0
        (sb.home / "cpd-cli/work/.DS_Store").write_text("finder\n")

    def test_reverse_is_gone_and_leaves_the_cluster_delineated(self):
        with sandbox() as sb:
            self.migrated(sb)
            result = migrate(sb, "--reverse", "itz-a", "--yes")
            assert result.returncode != 0
            assert "removed" in result.stderr and "one-way" in result.stderr
            assert (sb.repo / "configs/clusters/itz-a/cp4d_config").is_dir()
            assert not (sb.repo / "configs/cp4d_config").exists()

    def test_second_run_finds_nothing_to_migrate(self):
        with sandbox() as sb:
            self.migrated(sb)
            result = migrate(sb, "--dry-run")
            assert result.returncode == 0, result.stdout + result.stderr
            assert "Nothing to migrate" in result.stdout


# --- Findings 30, 31: docs --------------------------------------------------------------------------------------------
def test_readme_and_notebooks_name_the_current_button_and_folders():
    readme = (REPO / "README.md").read_text()
    assert "Save directly to" not in readme
    assert readme.count("Save to the folder shown above") >= 3
    assert "Generators only warn; they never prompt." in readme
    confluent = (REPO / "confluent_platform_vars_generation.py").read_text()
    concert = (REPO / "ibm_concert_vars_generation.py").read_text()
    assert "only read `configs/confluent_platform_config/" not in confluent
    assert "read `configs/concert_config/concert_vars.sh`" not in concert


# --- Mode off: another checkout's exports -------------------------------------------------------------------------
CONFLUENT_LOGIN = "scripts/install_confluent_platform/confluent_cli_login.sh"
MIRROR_FULL = f"{MIRROR}/0_x_full_quick_mirror_script/full_registry_mirror_process.sh"
MIRROR_VARS = "configs/registry_mirror_config/registry_mirror_vars.sh"
DETAILS = "configs/confluent_platform_config/confluent_instance_details.sh"


def other_checkout(sb):
    """A second checkout's folder, and the exports a shell loaded from it leaves behind."""
    other = sb.tmp / "checkout-a"
    (other / "configs").mkdir(parents=True)
    return other, {"CONFIGS_ROOT": str(other / "configs"), "_CP4D_REPO_ROOT": str(other)}


def write_at(root, rel, text):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


class TestAnotherCheckoutsExports:
    def login_status(self, sb, env):
        confluent = sb.bin / "confluent"
        confluent.write_text("#!/bin/zsh\nexit 0\n")
        confluent.chmod(0o755)
        write_at(sb.repo, "pyproject.toml", "")
        write_at(sb.repo, DETAILS, 'print -r -- DETAILS_FROM_B\n')
        return sb.run_script(CONFLUENT_LOGIN, args=["--status"], env=env)

    def test_confluent_login_reads_its_own_details(self):
        with sandbox(CONFLUENT_LOGIN) as sb:
            other, env = other_checkout(sb)
            write_at(other, DETAILS, 'print -r -- DETAILS_FROM_A\n')
            write_state(sb, on="false")
            result = self.login_status(sb, env)
            assert "DETAILS_FROM_B" in result.stdout, result.stdout + result.stderr
            assert "DETAILS_FROM_A" not in result.stdout

    def test_confluent_login_sourced_in_a_shell_that_loaded_the_other_checkout(self):
        with sandbox(CONFLUENT_LOGIN) as sb:
            other, env = other_checkout(sb)
            write_at(other, DETAILS, 'print -r -- DETAILS_FROM_A\n')
            helpers = other / "src/helpers/multi_cluster_helpers.sh"
            helpers.parent.mkdir(parents=True)
            helpers.write_bytes((sb.repo / "src/helpers/multi_cluster_helpers.sh").read_bytes())
            write_state(sb, on="false")
            self.login_status(sb, env)
            result = sb.run_zsh(f'source "{helpers}"\nsource "{sb.repo / CONFLUENT_LOGIN}" --status\n', env=env, strict=False)
            assert "DETAILS_FROM_B" in result.stdout, result.stdout + result.stderr
            assert "DETAILS_FROM_A" not in result.stdout

    def test_mirror_guard_ignores_the_other_checkouts_config(self):
        with sandbox(MIRROR_FULL) as sb:
            other, env = other_checkout(sb)
            write_at(other, MIRROR_VARS, "")
            write_state(sb, on="false")
            result = sb.run_script(MIRROR_FULL, args=["--list-steps"], env=env)
            assert result.returncode == 1
            assert f"No mirror config yet: {sb.repo}/{MIRROR_VARS}" in result.stderr, result.stderr

    def test_mirror_guard_finds_its_own_config(self):
        with sandbox(MIRROR_FULL) as sb:
            _, env = other_checkout(sb)
            write_at(sb.repo, MIRROR_VARS, "")
            write_state(sb, on="false")
            result = sb.run_script(MIRROR_FULL, args=["--list-steps"], env=env, timeout=120)
            assert "No mirror config yet" not in result.stdout + result.stderr

    def addon_list(self, sb, env):
        TestAddonList().seed(sb)
        vars_file = sb.write_config("cpd", ocp_url=URL_A)
        (vars_file.parent / "cpd_instance_details.sh").write_text('export CPD_URL="https://x" CPD_USERNAME=a CPD_PASSWORD=b\n')
        return sb.run_script(ADDON_LIST, cwd=sb.repo, env=env)

    def test_addon_list_does_not_follow_the_other_checkouts_mode(self):
        with sandbox(ADDON_LIST) as sb:
            other, env = other_checkout(sb)
            write_at(other, "configs/multi_cluster_management.sh", 'export MULTI_CLUSTER_MANAGEMENT="true"\nexport MCM_CLUSTERS=""\n')
            write_state(sb, on="false")
            result = self.addon_list(sb, env)
            assert result.returncode == 0, result.stderr
            assert result.stdout.strip() == "wx on"
            assert "[ENV]" not in result.stderr
            assert not (sb.repo / "service_instances").exists()

    def test_addon_list_writes_nothing_into_the_other_checkout(self):
        with sandbox(ADDON_LIST) as sb:
            other, env = other_checkout(sb)
            write_state(sb, on="false")
            assert self.addon_list(sb, env).returncode == 0
            assert not (other / "configs/multi_cluster_management.sh").exists()


# --- Mode off from the notebook or migrate --reverse: containers ----------------------------------------------------
STOP_AFTER_OFF = 'source src/helpers/multi_cluster_helpers.sh\nmcm_stop_idle_after_off\nprint -r -- RC=$?\n'


class TestStopIdleAfterOff:
    def setup(self, sb, timeout="0"):
        for name, url in (("itz-a", URL_A), ("itz-b", URL_B)):
            sb.write_cluster_marker(name, url)
        write_state(sb, on="false", clusters=("itz-a", "itz-b"))
        with (sb.repo / "configs/multi_cluster_management.sh").open("a") as state_file:
            state_file.write(f'export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="{timeout}"\n')
        for container in (f"{PLAY}-itz-a", f"{PLAY}-itz-b", PLAY):
            sb.add_container(container, running=True)

    def running(self, sb, container):
        return sb.container(container)["running"]

    def test_idle_cluster_containers_stop_with_no_watcher(self):
        with sandbox() as sb:
            self.setup(sb)
            result = sb.run_zsh(STOP_AFTER_OFF)
            assert "RC=0" in result.stdout, result.stdout + result.stderr
            assert not self.running(sb, f"{PLAY}-itz-a")
            assert not self.running(sb, f"{PLAY}-itz-b")
            assert not (sb.home / "cpd-cli/clusters/.idle-watcher.pid").exists()

    def test_the_flat_container_stays(self):
        with sandbox() as sb:
            self.setup(sb)
            sb.run_zsh(STOP_AFTER_OFF)
            assert self.running(sb, PLAY)

    def test_a_busy_container_stays_with_a_warning_that_hides_its_arguments(self):
        with sandbox() as sb:
            self.setup(sb)
            scan_first(sb, BUSY, container=f"{PLAY}-itz-a")
            result = sb.run_zsh(STOP_AFTER_OFF)
            assert "RC=0" in result.stdout, result.stdout + result.stderr
            assert self.running(sb, f"{PLAY}-itz-a")
            assert not self.running(sb, f"{PLAY}-itz-b")
            assert f"[WARN] Containers 1/2: {PLAY}-itz-a is busy (process 4242: skopeo)" in result.stderr
            assert "S3cretPw" not in result.stderr

    def test_a_live_run_keeps_its_container(self):
        with sandbox() as sb:
            self.setup(sb)
            lease(sb, "itz-a")
            result = sb.run_zsh(STOP_AFTER_OFF)
            assert self.running(sb, f"{PLAY}-itz-a")
            assert "holds a lease" in result.stderr

    def test_does_nothing_while_the_mode_is_on(self):
        with sandbox() as sb:
            self.setup(sb)
            state_on(sb, ("itz-a", "itz-b"), current="itz-a")
            assert "RC=0" in sb.run_zsh(STOP_AFTER_OFF).stdout
            assert self.running(sb, f"{PLAY}-itz-b")

    def test_unreachable_podman_warns_and_succeeds(self):
        with sandbox() as sb:
            self.setup(sb)
            sb.set_podman_reachable(False)
            result = sb.run_zsh(STOP_AFTER_OFF)
            assert "RC=0" in result.stdout, result.stdout + result.stderr
            assert "podman is not reachable" in result.stderr

    def test_an_invalid_state_file_warns_and_succeeds(self):
        with sandbox() as sb:
            self.setup(sb)
            (sb.repo / "configs/multi_cluster_management.sh").write_text('export MULTI_CLUSTER_MANAGEMENT="nope"\n')
            result = sb.run_zsh(STOP_AFTER_OFF)
            assert "RC=0" in result.stdout, result.stdout + result.stderr
            assert "left as they are" in result.stderr
            assert self.running(sb, f"{PLAY}-itz-a")
