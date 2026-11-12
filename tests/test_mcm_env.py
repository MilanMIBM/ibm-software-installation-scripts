"""Per-cluster environment for multi-cluster management (plan sections 5.4, 5.5, 5.6, 5.12).

T5: every variable of the 5.5 table per cluster, precedence table 5.4, no leakage on a switch, a restore target's
    KUBECONFIG surviving the env load, the three places that resolve before the env load.
T6: the cpd-cli shim, which passes `manage` with the real HOME and gives everything else the cluster's HOME.
T13: mirror workspace per destination registry, cluster scope, entitled clusters skipped, stable key across
     `0.3 up`, machine-wide tools, --include-configs.

Everything runs in tests/mcm_harness.py sandboxes: temp HOME, temp repo copy, fake podman / oc / cpd-cli.
"""

import subprocess
import tarfile
from pathlib import Path

import pytest
from mcm_harness import REPO, make_sandbox

URL_A = "https://api.itz-a.example.com:6443"
URL_B = "https://api.itz-b.example.com:6443"
SHIM = "src/helpers/multi_cluster_bin"
DUMP = 'print -r -- "===DUMP==="\n/usr/bin/env\n'
BOOT = 'source "${0:A:h}/env_bootstrap.sh"\n'
OADP = "src/utilities/oadp_backup_restore_cp4d_utils"
MIRROR = "scripts/private_registry_mirroring"
FULL_MIRROR = f"{MIRROR}/0_x_full_quick_mirror_script/full_registry_mirror_process.sh"
BUILD_BUNDLE = f"{MIRROR}/2_download_and_mirror/2.5_build_transfer_bundle.sh"
LOCAL_REGISTRY = f"{MIRROR}/0_initial_setup/0.3_local_registry.sh"
CONFLUENT_LOGIN = "scripts/install_confluent_platform/confluent_cli_login.sh"


def write_state(sb, clusters=(), current="", targets="", apply_to_all="false", on="true", extra=""):
    (sb.repo / "configs" / "multi_cluster_management.sh").write_text(
        f'export MULTI_CLUSTER_MANAGEMENT="{on}"\n'
        f'export MCM_CLUSTERS="{" ".join(clusters)}"\n'
        f'export MCM_CURRENT_CLUSTER="{current}"\n'
        f'export APPLY_TO_ALL="{apply_to_all}"\n'
        f'export MCM_TARGET_CLUSTERS="{targets}"\n'
        f"{extra}"
    )


def two_clusters(sb, current="", targets="", apply_to_all="false"):
    for name, url in (("itz-a", URL_A), ("itz-b", URL_B)):
        sb.write_cluster_marker(name, url)
    write_state(sb, ("itz-a", "itz-b"), current=current, targets=targets, apply_to_all=apply_to_all)


def parse_dump(stdout):
    assert "===DUMP===" in stdout, stdout
    env = {}
    for line in stdout.split("===DUMP===\n", 1)[1].splitlines():
        key, sep, value = line.partition("=")
        if sep:
            env[key] = value
    return env


def load(sb, env=None, args=(), target="cpd"):
    """Exported environment after a strict script loads env_bootstrap.sh for `target`."""
    extra = {"ENV_TARGET": target, **(env or {})}
    result = sb.run_zsh(BOOT + DUMP, env=extra, args=args)
    assert result.returncode == 0, result.stdout + result.stderr
    return parse_dump(result.stdout)


def s_env(sb, args="", env=None):
    result = sb.run_zsh(f'source s_env.sh {args}\n' + DUMP, env=env, strict=False)
    assert result.returncode == 0, result.stdout + result.stderr
    return parse_dump(result.stdout), result


# ---- T5: variables ----------------------------------------------------------------------------------------------
def test_t5_every_variable_of_the_table_when_on():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        env = load(sb)
        c = sb.repo / "configs" / "clusters" / "itz-a"
        cli = sb.home / "cpd-cli" / "clusters" / "itz-a"
        expected = {
            "MCM_CLUSTER": "itz-a",
            "MCM_CLUSTER_ROOT": c,
            "CONFIGS_ROOT": c,
            "CONFIG_DIR": c / "cp4d_config",
            "CONCERT_CONFIG_DIR": c / "concert_config",
            "SERVICE_INSTANCE_FILE_DIR": c / "service_instances",
            "OLM_UTILS_CONTAINER": "olm-utils-play-v4-itz-a",
            "CPD_CLI_MANAGE_WORKSPACE": cli,
            "CPD_CLI_WORK_PATH": cli / "work",
            "CPD_CLI_BASE_WORK_PATH": cli / "work",
            "CPD_CLI_HOME": sb.home / "cpd-cli",
            "CPD_CLI_WORKSPACE": c / "cpd-cli-workspace",
            "KUBECONFIG": c / ".home" / ".kube" / "config",
            "CPDCONFIG": c / ".home" / ".cpd-cli" / "config",
            "CONCERT_WORKSPACE": c / "concert_workspace",
            "MC_WORKSPACE": c / "datastax_mc_workspace",
            "KC_WORKSPACE": c / "kubecost_workspace",
            "OADP_LOG_DIR": c / "cpd-cli-workspace" / "oadp",
            "MIRROR_CLUSTER_OUT": c / "registry_mirror_cluster",
            "SCC_CACHE_ROOT": sb.repo / "cpd-cli-workspace" / "scale_config_cache",
            "CPD_CLI": sb.repo / SHIM / "cpd-cli",
        }
        for name, value in expected.items():
            assert env.get(name) == str(value), name
        assert env["PATH"].split(":")[0] == str(sb.repo / SHIM)
        assert (c / "service_instances").is_dir()


def test_t5_private_folders_are_created_owner_only():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        load(sb)
        home = sb.repo / "configs" / "clusters" / "itz-a" / ".home"
        for folder in (home, home / ".kube", home / ".cpd-cli"):
            assert folder.stat().st_mode & 0o777 == 0o700, folder


def test_t5_mode_off_keeps_flat_values_and_adds_no_cluster_names():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        sb.write_config("cpd", ocp_url=URL_A)
        env = load(sb)
        assert env["CONFIGS_ROOT"] == str(sb.repo / "configs")
        assert env["CPD_CLI_MANAGE_WORKSPACE"] == str(sb.home / "cpd-cli")
        assert env["OLM_UTILS_CONTAINER"] == "olm-utils-play-v4"
        for name in ("KUBECONFIG", "CPDCONFIG", "CPD_CLI_WORKSPACE", "MCM_CLUSTER", "MCM_CLUSTER_ROOT", "CPD_CLI"):
            assert name not in env
        assert str(sb.repo / SHIM) not in env["PATH"]


def test_t5_state_file_is_generated_at_env_load():
    with make_sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        state = sb.repo / "configs" / "multi_cluster_management.sh"
        assert not state.exists()
        load(sb)
        assert state.exists()
        assert 'MULTI_CLUSTER_MANAGEMENT="false"' in state.read_text()


def test_t5_invalid_state_file_aborts_the_run():
    with make_sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        (sb.repo / "configs" / "multi_cluster_management.sh").write_text('export MULTI_CLUSTER_MANAGEMENT="maybe"\n')
        result = sb.run_zsh(BOOT + 'print -r -- SURVIVED\n', env={"ENV_TARGET": "cpd"})
        assert result.returncode != 0
        assert "MULTI_CLUSTER_MANAGEMENT" in result.stderr
        assert "SURVIVED" not in result.stdout


# ---- T5: precedence (table 5.4) -----------------------------------------------------------------------------------
RESOLVE = 'source src/helpers/multi_cluster_helpers.sh\nmcm_take_target_flags "$@"\nset -- "${_MCM_ARGV[@]}"\nmcm_resolve_targets\nprint -r -- "FROM=${_MCM_RESOLVED_FROM}"\n'


def resolve(sb, env=None, args=()):
    return sb.run_zsh(RESOLVE, env=env, args=args)


@pytest.mark.parametrize("args,env,state,expected,source", [
    (["--target-cluster", "itz-b"], {"MCM_CLUSTER": "itz-a"}, {"current": "itz-a"}, "itz-b", "flag"),
    (["--target-clusters", "itz-a,itz-b"], {}, {"current": "itz-a"}, "itz-a itz-b", "flag"),
    (["--all-clusters"], {}, {"targets": "itz-a"}, "itz-a itz-b", "flag"),
    ([], {"MCM_CLUSTER": "itz-b"}, {"targets": "itz-a", "apply_to_all": "true", "current": "itz-a"}, "itz-b", "pin"),
    ([], {}, {"targets": "itz-b", "apply_to_all": "true", "current": "itz-a"}, "itz-b", "targets"),
    ([], {}, {"apply_to_all": "true", "current": "itz-a"}, "itz-a itz-b", "all"),
    ([], {}, {"current": "itz-b"}, "itz-b", "current"),
])
def test_t5_precedence_table(args, env, state, expected, source):
    with make_sandbox() as sb:
        two_clusters(sb, **state)
        result = resolve(sb, env=env, args=args)
        assert result.returncode == 0, result.stderr
        assert result.stdout.splitlines() == [expected, f"FROM={source}"]


def test_t5_precedence_only_registered_cluster():
    with make_sandbox() as sb:
        sb.write_cluster_marker("itz-a", URL_A)
        write_state(sb, ("itz-a",))
        result = resolve(sb)
        assert result.stdout.splitlines() == ["itz-a", "FROM=only"]


def test_t5_precedence_ocp_url_is_last_and_must_be_registered():
    with make_sandbox() as sb:
        two_clusters(sb)
        assert resolve(sb, env={"OCP_URL": URL_B}).stdout.splitlines() == ["itz-b", "FROM=url"]
        missing = resolve(sb, env={"OCP_URL": "https://api.itz-c.example.com:6443"})
        assert missing.returncode != 0
        assert "itz-a itz-b" in missing.stderr and "--target-cluster" in missing.stderr


def test_t5_precedence_current_beats_ocp_url():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        assert resolve(sb, env={"OCP_URL": URL_B}).stdout.splitlines() == ["itz-a", "FROM=current"]


def test_t5_missing_cluster_folder_is_an_error_with_guidance():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        result = resolve(sb, args=["--target-cluster", "itz-c"])
        assert result.returncode != 0
        assert "itz-c" in result.stderr and "multi_cluster.sh add" in result.stderr
        assert not (sb.repo / "configs" / "clusters" / "itz-c").exists()


def test_t5_flag_with_mode_off_is_an_error():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        sb.write_config("cpd", ocp_url=URL_A)
        result = sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd"}, args=["--target-cluster", "itz-a"])
        assert result.returncode != 0
        assert "multi-cluster mode" in result.stderr
        assert sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd"}).returncode == 0


def test_t5_several_flags_are_consumed_and_arguments_survive():
    with make_sandbox() as sb:
        two_clusters(sb)
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        result = sb.run_zsh(BOOT + 'printf "<%s>" "$@"\n', env={"ENV_TARGET": "cpd"},
                            args=["one two", "--target-cluster", "itz-b", "", "--flag=a b"])
        assert result.returncode == 0, result.stderr
        assert result.stdout == "<one two><><--flag=a b>"


def test_t5_more_than_one_target_reaches_the_fanout_seam_with_the_arguments():
    with make_sandbox() as sb:
        two_clusters(sb)
        script = (
            'source "${0:A:h}/src/helpers/multi_cluster_helpers.sh"\n'
            'mcm_fanout() { printf "<%s>" "$@"; print -r -- "|${_MCM_RESOLVED[*]}"; exit 0; }\n' + BOOT +
            'print -r -- NOT-REACHED\n'
        )
        result = sb.run_zsh(script, env={"ENV_TARGET": "cpd"}, args=["keep me", "--all-clusters", "--x=1"])
        assert result.returncode == 0, result.stderr
        assert result.stdout == "<keep me><--x=1>|itz-a itz-b\n"


def test_t5_a_pinned_run_never_fans_out():
    with make_sandbox() as sb:
        two_clusters(sb, apply_to_all="true")
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        env = load(sb, env={"MCM_CLUSTER": "itz-b"})
        assert env["MCM_CLUSTER"] == "itz-b"


# ---- T5: banner and pin -------------------------------------------------------------------------------------------
def test_t5_summary_row_only_when_on():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        sb.write_config("cpd", ocp_url=URL_A)
        off = sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd"})
        assert "[ENV]   mcm" not in off.stderr
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        on = sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd"})
        assert "[ENV]   mcm      itz-a (current cluster)" in on.stderr


def test_t5_banner_notes_a_pin_overriding_apply_to_all():
    with make_sandbox() as sb:
        two_clusters(sb, apply_to_all="true")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        result = sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd", "MCM_CLUSTER": "itz-a"})
        assert result.returncode == 0, result.stderr
        assert "overrides APPLY_TO_ALL" in result.stderr


def test_t5_banner_notes_a_pin_overriding_the_current_cluster():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-b")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        result = sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd"}, args=["--target-cluster", "itz-a"])
        assert "overrides current cluster itz-b" in result.stderr


def test_t5_no_banner_note_for_a_fanout_child():
    with make_sandbox() as sb:
        two_clusters(sb, apply_to_all="true")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        result = sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd", "MCM_CLUSTER": "itz-a", "_MCM_FANOUT_CHILD": "1"})
        assert "overrides" not in result.stderr


def test_t5_s_env_flag_pins_and_exports_the_cluster():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        env, result = s_env(sb, "cpd --target-cluster itz-b")
        assert env["MCM_CLUSTER"] == "itz-b"
        assert env["CONFIGS_ROOT"].endswith("configs/clusters/itz-b")
        assert "[ENV]   mcm      itz-b" in result.stderr
        assert sb.oc_session(env["KUBECONFIG"])["server"] == URL_B


def test_t5_s_env_never_fans_out_and_uses_the_current_cluster():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a", apply_to_all="true")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        env, _ = s_env(sb, "cpd")
        assert env["MCM_CLUSTER"] == "itz-a"


def test_t5_s_env_with_several_targets_and_no_current_is_an_error():
    with make_sandbox() as sb:
        two_clusters(sb, apply_to_all="true")
        result = sb.run_zsh('source s_env.sh cpd\nprint -r -- SURVIVED\n', strict=False)
        assert result.returncode != 0 and "SURVIVED" not in result.stdout
        assert "--target-cluster" in result.stderr


def test_t5_s_env_rejects_multi_cluster_flags():
    with make_sandbox() as sb:
        two_clusters(sb)
        result = sb.run_zsh('source s_env.sh --all-clusters\nprint -r -- "rc=$?"\n', strict=False)
        assert "rc=1" in result.stdout
        assert "one cluster" in result.stderr


def test_t5_s_env_help_prints_the_whole_header():
    with make_sandbox() as sb:
        result = sb.run_zsh('source s_env.sh --help\n', strict=False)
        assert result.returncode == 0
        assert result.stdout.startswith("Load the env into the current shell")
        assert "--target-cluster NAME" in result.stdout
        assert "Always reloads, even if the env was already loaded in this shell." in result.stdout
        assert "_s_env_target" not in result.stdout


def test_t5_s_env_reresolves_from_the_state_file_on_a_second_load():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        script = (
            'source s_env.sh cpd >/dev/null 2>&1\n'
            'print -r -- "$MCM_CLUSTER"\n'
            'sed -i.bak \'s/MCM_CURRENT_CLUSTER="itz-a"/MCM_CURRENT_CLUSTER="itz-b"/\' configs/multi_cluster_management.sh\n'
            'source s_env.sh cpd >/dev/null 2>&1\n'
            'print -r -- "$MCM_CLUSTER"\n'
        )
        result = sb.run_zsh(script, strict=False)
        assert result.stdout.splitlines() == ["itz-a", "itz-b"], result.stderr


def test_t5_s_env_checks_the_podman_machine_when_on():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        marker = sb.tmp / "prep-ran"
        (sb.repo / "scripts" / "0.0_make_executable.sh").write_text(f'touch "{marker}"\n')
        sb.set_machine("stopped")
        result = sb.run_zsh('source s_env.sh cpd\nprint -r -- LOADED\n', strict=False)
        assert "LOADED" in result.stdout, result.stdout + result.stderr
        if subprocess.run(["uname", "-s"], capture_output=True, text=True, check=False).stdout.strip() == "Darwin":
            assert marker.exists()
            assert not [argv for argv in sb.calls("podman") if argv[:2] == ["machine", "start"]]


def test_t5_s_env_checks_the_podman_machine_before_the_env_load():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", ocp_url=URL_A, cluster="itz-a")
        # 0.0_make_executable.sh brings the VM back, as the real one does.
        (sb.repo / "scripts" / "0.0_make_executable.sh").write_text("podman machine start\n")
        sb.set_machine("stopped")
        result = sb.run_zsh('source s_env.sh cpd\nprint -r -- LOADED\n', strict=False)
        assert "LOADED" in result.stdout, result.stdout + result.stderr
        if subprocess.run(["uname", "-s"], capture_output=True, text=True, check=False).stdout.strip() == "Darwin":
            assert "not reachable" not in result.stderr


def test_t5_s_env_skips_the_podman_machine_check_when_off():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        sb.write_config("cpd", ocp_url=URL_A)
        marker = sb.tmp / "prep-ran"
        (sb.repo / "scripts" / "0.0_make_executable.sh").write_text(f'touch "{marker}"\n')
        sb.set_machine("stopped")
        result = sb.run_zsh('source s_env.sh cpd\nprint -r -- LOADED\n', strict=False)
        assert "LOADED" in result.stdout, result.stdout + result.stderr
        assert not marker.exists()


# ---- T5: no leakage -----------------------------------------------------------------------------------------------
def test_t5_switching_forgets_what_the_previous_config_exported():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A, extra={"ONLY_ON_A": "yes", "SHARED_NAME": "from-a"})
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B, extra={"ONLY_ON_B": "yes", "SHARED_NAME": "from-b"})
        script = (
            'source s_env.sh cpd >/dev/null 2>&1\n'
            'print -r -- "A:${ONLY_ON_A:-unset}:${SHARED_NAME}"\n'
            'source s_env.sh cpd --target-cluster itz-b >/dev/null 2>&1\n'
            'print -r -- "B:${ONLY_ON_A:-unset}:${ONLY_ON_B:-unset}:${SHARED_NAME}:${OC_LOGIN_FORCE:-unset}"\n'
        )
        result = sb.run_zsh(script, strict=False)
        lines = result.stdout.splitlines()
        assert lines[0] == "A:yes:from-a", result.stderr
        assert lines[1].startswith("B:unset:yes:from-b:oc login " + URL_B)


def test_t5_a_child_of_a_shell_loaded_for_a_gets_b_clean():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A, extra={"ONLY_ON_A": "yes"})
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        (sb.repo / "child.sh").write_text(BOOT + 'print -r -- "${ONLY_ON_A:-unset}:${OCP_URL}"\n')
        script = (
            'source s_env.sh cpd >/dev/null 2>&1\n'
            'export _CP4D_PREP_DONE=1\n'
            'ENV_TARGET=cpd MCM_CLUSTER=itz-b zsh "${0:A:h}/child.sh" 2>/dev/null\n'
        )
        result = sb.run_zsh(script, strict=False)
        assert result.stdout.strip() == f"unset:{URL_B}", result.stdout + result.stderr


def test_t5_same_cluster_reload_keeps_the_record():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A, extra={"ONLY_ON_A": "yes"})
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        script = (
            'source s_env.sh cpd >/dev/null 2>&1\nsource s_env.sh cpd >/dev/null 2>&1\n'
            'source s_env.sh cpd --target-cluster itz-b >/dev/null 2>&1\n'
            'print -r -- "${ONLY_ON_A:-unset}"\n'
        )
        assert sb.run_zsh(script, strict=False).stdout.strip() == "unset"


def test_t5_a_stale_pin_is_dropped_when_the_mode_is_off():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        sb.write_config("cpd", ocp_url=URL_A)
        root = sb.repo / "configs" / "clusters" / "itz-a"
        stale = {
            "MCM_CLUSTER": "itz-a", "MCM_CLUSTER_ROOT": root, "KUBECONFIG": root / ".home/.kube/config",
            "OLM_UTILS_CONTAINER": "olm-utils-play-v4-itz-a", "CPD_CLI_WORKSPACE": root / "cpd-cli-workspace",
            "PATH": f"{sb.repo / SHIM}:{sb.bin}:/usr/bin:/bin", "OADP_LOG_DIR": root / "cpd-cli-workspace/oadp",
        }
        env = load(sb, env=stale)
        assert env["CONFIGS_ROOT"] == str(sb.repo / "configs")
        assert env["OLM_UTILS_CONTAINER"] == "olm-utils-play-v4"
        for name in ("MCM_CLUSTER", "MCM_CLUSTER_ROOT", "KUBECONFIG", "CPD_CLI_WORKSPACE", "OADP_LOG_DIR"):
            assert name not in env, name
        assert str(sb.repo / SHIM) not in env["PATH"]


def test_t5_a_user_kubeconfig_is_kept_when_the_mode_is_off():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        sb.write_config("cpd", ocp_url=URL_A)
        mine = sb.tmp / "my-kubeconfig"
        assert load(sb, env={"KUBECONFIG": mine})["KUBECONFIG"] == str(mine)


def test_t5_a_switch_forgets_the_config_file_of_the_previous_cluster():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("datastax_mc", cluster="itz-a", ocp_url=URL_A)
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        script = (
            'source s_env.sh datastax_mc --target-cluster itz-a >/dev/null 2>&1\n'
            'print -r -- "${ENV_TARGET_FILE:-unset}"\n'
            'source s_env.sh --target-cluster itz-b >/dev/null 2>&1\n'
            'print -r -- "$MCM_CLUSTER:${ENV_TARGET_FILE:-unset}"\n'
        )
        lines = sb.run_zsh(script, strict=False).stdout.splitlines()
        assert lines[0].endswith("clusters/itz-a/datastax_mc_config/datastax_mc_vars.sh"), lines
        assert lines[1] == "itz-b:unset"


def test_t5_a_switch_forgets_key_value_overrides():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        script = (
            'source s_env.sh cpd --target-cluster itz-a X_ONLY=1 >/dev/null 2>&1\n'
            'print -r -- "${X_ONLY:-unset}"\n'
            'source s_env.sh cpd --target-cluster itz-b >/dev/null 2>&1\n'
            'print -r -- "$MCM_CLUSTER:${X_ONLY:-unset}"\n'
        )
        assert sb.run_zsh(script, strict=False).stdout.splitlines() == ["1", "itz-b:unset"]


# Flat load first, then 'multi_cluster.sh on' in the same terminal: FLIP stands in for that utility.
FLAT_URL = "https://api.flat.example.com:6443"
FLIP = 'cp "$MCM_ON_STATE" configs/multi_cluster_management.sh\n'


def flat_then_on(sb):
    """Flat cpd config, state file off, MCM_ON_STATE holding the 'on' state; itz-a has only a Concert config."""
    write_state(sb, ("itz-a",), current="itz-a")
    on_state = sb.tmp / "on_state.sh"
    on_state.write_text((sb.repo / "configs" / "multi_cluster_management.sh").read_text())
    write_state(sb, ("itz-a",), current="itz-a", on="false")
    sb.write_cluster_marker("itz-a", URL_A)
    sb.write_config("cpd", ocp_url=FLAT_URL, extra={"ONLY_FLAT": "1"})
    sb.write_config("concert", cluster="itz-a", ocp_url=URL_A)
    return {"MCM_ON_STATE": on_state}


def test_t5_a_flat_load_is_forgotten_when_the_mode_comes_on_in_the_same_shell():
    with make_sandbox() as sb:
        env = flat_then_on(sb)
        script = (
            'source s_env.sh cpd >/dev/null 2>&1\n'
            'print -r -- "flat:${ONLY_FLAT:-unset}"\n'
            'typeset +x _MCM_FLAT_CONFIG_VARS\n'
            'if /usr/bin/env | grep -q _MCM_FLAT_CONFIG_VARS; then print -r -- exported; else print -r -- private; fi\n'
            + FLIP +
            'source s_env.sh >/dev/null 2>&1\n'
            'print -r -- "$MCM_CLUSTER:${ONLY_FLAT:-unset}:${CPDM_OC_LOGIN:-unset}:${CPDM_OC_LOGIN_FORCE:-unset}"\n'
        )
        result = sb.run_zsh(script, env=env, strict=False)
        assert result.stdout.splitlines() == ["flat:1", "private", "itz-a:unset:unset:unset"], result.stdout + result.stderr
        logins = [r for r in sb.call_records("cpd-cli") if r["argv"][:2] == ["manage", "login-to-ocp"]]
        assert all(r["env"].get("OLM_UTILS_CONTAINER") != "olm-utils-play-v4-itz-a" for r in logins), logins
        kubeconfig = sb.repo / "configs" / "clusters" / "itz-a" / ".home" / ".kube" / "config"
        assert sb.oc_session(kubeconfig)["server"] == URL_A


def test_t5_a_flat_load_with_no_login_on_the_cluster_cannot_log_it_in_to_the_flat_cluster():
    with make_sandbox() as sb:
        env = flat_then_on(sb)
        sb.write_config("concert", cluster="itz-a", ocp_url=URL_A, login=False)
        result = sb.run_zsh('source s_env.sh cpd >/dev/null 2>&1\n' + FLIP + 'source s_env.sh >/dev/null 2>&1\n',
                            env=env, strict=False)
        assert result.returncode == 0, result.stdout + result.stderr
        kubeconfig = sb.repo / "configs" / "clusters" / "itz-a" / ".home" / ".kube" / "config"
        assert sb.oc_session(kubeconfig) is None


def test_t5_several_flat_loads_are_all_forgotten():
    with make_sandbox() as sb:
        env = flat_then_on(sb)
        sb.write_config("confluent", ocp_url=FLAT_URL, extra={"ONLY_CONFLUENT": "1"})
        script = (
            'source s_env.sh cpd >/dev/null 2>&1\nsource s_env.sh confluent >/dev/null 2>&1\n' + FLIP +
            'source s_env.sh concert >/dev/null 2>&1\n'
            'print -r -- "${ONLY_FLAT:-unset}:${ONLY_CONFLUENT:-unset}"\n'
        )
        assert sb.run_zsh(script, env=env, strict=False).stdout.strip() == "unset:unset"


def test_t5_a_child_of_a_flat_shell_does_not_inherit_its_logins():
    with make_sandbox() as sb:
        env = flat_then_on(sb)
        (sb.repo / "child.sh").write_text(
            "set -euo pipefail\n" + BOOT + 'print -r -- "$MCM_CLUSTER:${CPDM_OC_LOGIN:-unset}:${OC_LOGIN_FORCE:-unset}"\n')
        script = ('source s_env.sh cpd >/dev/null 2>&1\n' + FLIP +
                  'ENV_TARGET=concert zsh "${0:A:h}/child.sh" 2>/dev/null\n')
        result = sb.run_zsh(script, env=env, strict=False)
        assert result.stdout.strip() == f"itz-a:unset:oc login {URL_A} --token=fake-token", result.stdout + result.stderr


def test_t5_first_pin_with_a_clean_environment_keeps_preset_login_names():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A, login=False)
        env = load(sb, env={"OC_LOGIN": "echo mine"})
        assert env["OC_LOGIN"].endswith("echo mine; fi")


# An interactive shell survives a failed load, so the failure must not change what it is loaded for.
def interactive(sb, body):
    script = sb.tmp / "interactive.zsh"
    script.write_text(body)
    return sb.run_zsh(f'zsh -f -i -c "source {script}"\n', strict=False)


SHELL_STATE = 'print -r -- "$MCM_CLUSTER|${_MCM_SHELL_PIN:-}|${MCM_CLUSTER_ROOT:t}|${KUBECONFIG}|${CPD_CLI_WORKSPACE}|${OC_LOGIN:+login}|${ONLY_ON_A:-unset}"\n'


def expected_shell_state(sb):
    root = sb.repo / "configs" / "clusters" / "itz-a"
    return f"itz-a|itz-a|itz-a|{root}/.home/.kube/config|{root}/cpd-cli-workspace|login|yes"


SET_CURRENT_B = 'sed -i.bak \'s/MCM_CURRENT_CLUSTER="itz-a"/MCM_CURRENT_CLUSTER="itz-b"/\' configs/multi_cluster_management.sh\n'


def test_t5_failed_switch_to_a_cluster_without_the_config_leaves_the_shell_alone():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A, extra={"ONLY_ON_A": "yes"})
        result = interactive(sb, (
            'source s_env.sh cpd >/dev/null 2>&1\n' + SET_CURRENT_B +
            'source s_env.sh cpd; print -r -- "rc=$?"\n' + SHELL_STATE
        ))
        lines = result.stdout.splitlines()
        assert lines[-2:] == ["rc=1", expected_shell_state(sb)], result.stdout + result.stderr
        assert "[ERROR]" in result.stderr and "itz-b" in result.stderr


def test_t5_failed_flag_switch_keeps_the_pin_and_the_next_load_reresolves():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A, extra={"ONLY_ON_A": "yes"})
        result = interactive(sb, (
            'source s_env.sh cpd >/dev/null 2>&1\n'
            'source s_env.sh cpd --target-cluster itz-b 2>/dev/null; print -r -- "rc=$?"\n' + SHELL_STATE +
            'source s_env.sh cpd >/dev/null 2>&1; print -r -- "rc=$?"\n' + SHELL_STATE
        ))
        state = expected_shell_state(sb)
        assert result.stdout.splitlines()[-4:] == ["rc=1", state, "rc=0", state], result.stdout + result.stderr


def test_t5_a_failed_load_does_not_mark_the_target_as_loaded():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        result = interactive(sb, (
            'source s_env.sh cpd >/dev/null 2>&1\n'
            'source s_env.sh concert >/dev/null 2>&1; print -r -- "rc=$?:${_CP4D_ENV_LOADED:-unset}"\n'
        ))
        assert result.stdout.splitlines()[-1] == "rc=1:unset", result.stdout + result.stderr


def test_t5_interactive_load_of_a_path_target_on_the_cluster_still_works():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        path = sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        result = interactive(sb, (
            f'source s_env.sh {path} --target-cluster itz-b >/dev/null 2>&1; print -r -- "rc=$?:$MCM_CLUSTER"\n'
            'source s_env.sh --target-cluster itz-a >/dev/null 2>&1; print -r -- "rc=$?:$MCM_CLUSTER"\n'
        ))
        assert result.stdout.splitlines()[-2:] == ["rc=0:itz-b", "rc=0:itz-a"], result.stdout + result.stderr


def test_t5_a_non_interactive_sourced_load_still_reports_skipped():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        result = sb.run_zsh('source scripts/source_env_setup.sh\n', env={"ENV_TARGET": "concert"})
        assert result.returncode == 75
        assert "skipped" in result.stderr


def test_t5_state_file_does_not_trigger_the_make_executable_prep():
    with make_sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        marker = sb.tmp / "prep-ran"
        (sb.repo / "scripts" / "0.0_make_executable.sh").write_text(f'touch "{marker}"\n')
        for path in sb.repo.rglob("*.sh"):
            path.chmod(path.stat().st_mode | 0o700)
        for _ in range(2):
            result = sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd", "_CP4D_PREP_DONE": None})
            assert result.returncode == 0, result.stdout + result.stderr
        state = sb.repo / "configs" / "multi_cluster_management.sh"
        assert state.stat().st_mode & 0o777 == 0o600
        assert not marker.exists(), result.stdout


def test_t5_a_real_non_executable_script_still_triggers_the_prep():
    with make_sandbox() as sb:
        sb.write_config("cpd", ocp_url=URL_A)
        marker = sb.tmp / "prep-ran"
        (sb.repo / "scripts" / "0.0_make_executable.sh").write_text(f'touch "{marker}"\n')
        for path in sb.repo.rglob("*.sh"):
            path.chmod(path.stat().st_mode | 0o700)
        (sb.repo / "scripts" / "not_executable.sh").write_text("true\n")
        (sb.repo / "scripts" / "not_executable.sh").chmod(0o644)
        assert sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd", "_CP4D_PREP_DONE": None}).returncode == 0
        assert marker.exists()


# ---- T5: the private kubeconfigs of the parallel operator lanes -----------------------------------------------------
LANES_DIR = "scripts/install_cloud_pak_for_data/2_prepare_cluster/2.2_install_prerequisite_operators"
LANE_CHILD = (
    '#!/bin/zsh\nset -euo pipefail\nSCRIPT_DIR="${0:A:h}"\n'
    '_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b\n'
    'print -r -- "KC=${KUBECONFIG:-unset}"\n'
)


def run_operator_lanes(sb):
    for child in (sb.repo / LANES_DIR).glob("2.2.*.sh"):
        child.write_text(LANE_CHILD)
        child.chmod(0o755)
    result = sb.run_script(f"{LANES_DIR}/2.2_install_prerequisite_operators.sh", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return [line for line in result.stdout.splitlines() if "KC=" in line]


def test_t5_operator_lanes_keep_their_private_kubeconfigs():
    with make_sandbox(extra=[LANES_DIR]) as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        lines = run_operator_lanes(sb)
        assert len(lines) == 5, lines
        for line in lines:
            lane = line[1:line.index("]")]
            assert line.endswith(f"/kubeconfigs/{lane}.kubeconfig"), line


# ---- T5: a restore target's kubeconfig ----------------------------------------------------------------------------
def write_oadp_target(sb, cluster="itz-a"):
    target_dir = sb.repo / "configs" / "clusters" / cluster / "oadp" / "restore_target_configs"
    target_dir.mkdir(parents=True)
    (target_dir / "tgt1_vars.sh").write_text(
        'export OCP_URL="https://api.target.example.com:6443"\n'
        'export OCP_TOKEN="fake"\n'
        'export OC_LOGIN="oc login https://api.target.example.com:6443 --token=fake"\n'
        'export CPDM_OC_LOGIN="cpd-cli manage login-to-ocp --server=https://api.target.example.com:6443 --token=fake"\n'
        'export OADP_PROJECT="oadp-operator"\n'
        'export PROJECT_CPD_INST_OPERATORS="cpd-ops"\n'
        'export PROJECT_CPD_INST_OPERANDS="cpd"\n'
    )
    return target_dir


@pytest.mark.parametrize("script,args", [
    ("4.1_restore_cp4d_instance_fresh_cluster.sh", ["--target", "tgt1", "--list"]),
    ("5_uninstall_from_target_cluster.sh", ["--target", "tgt1", "--dry-run", "--yes"]),
])
def test_t5_restore_target_kubeconfig_survives_the_env_load(script, args):
    with make_sandbox(extra=[OADP]) as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        target_dir = write_oadp_target(sb)
        # The uninstall looks for other restores to the same target with pgrep over this machine's
        # process table: an empty fake keeps the test off whatever the host runs right now.
        (sb.bin / "pgrep").write_text("#!/bin/zsh\nexit 1\n")
        (sb.bin / "pgrep").chmod(0o755)
        sb.run_script(f"{OADP}/{script}", env={"MCM_CLUSTER": None}, args=args, timeout=120)
        target_kubeconfig = target_dir / "tgt1.kubeconfig"
        current_kubeconfig = sb.repo / "configs" / "clusters" / "itz-a" / ".home" / ".kube" / "config"
        session = sb.oc_session(target_kubeconfig)
        assert session and session["server"] == "https://api.target.example.com:6443", sb.call_records("oc")
        assert sb.oc_session(current_kubeconfig) is None
        assert sb.oc_session() is None


def test_t5_oadp_helper_resolves_the_cluster_when_it_loads():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        script = ('source "${0:A:h}/src/helpers/oadp_br_helpers.sh"\n'
                  'print -r -- "$BUCKET_CONFIG_DIR|$TARGET_CONFIG_DIR|$OADP_LOG_DIR|$KUBECONFIG"\n'
                  'printf "<%s>" "$@"\n')
        result = sb.run_zsh(script, args=["--target-cluster", "itz-b", "--target", "tgt1"])
        assert result.returncode == 0, result.stderr
        c = sb.repo / "configs" / "clusters" / "itz-b"
        assert result.stdout.splitlines() == [
            f"{c}/oadp/backup_bucket_configs|{c}/oadp/restore_target_configs|{c}/cpd-cli-workspace/oadp|{c}/.home/.kube/config",
            "<--target><tgt1>",
        ]


def test_t5_oadp_helper_stays_flat_when_off():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        script = ('source "${0:A:h}/src/helpers/oadp_br_helpers.sh"\n'
                  'print -r -- "$OADP_LOG_DIR"\n'
                  'print -r -- "${KUBECONFIG:-none}"\n')
        result = sb.run_zsh(script)
        assert result.stdout.splitlines() == [str(sb.repo / "cpd-cli-workspace" / "oadp"), "none"], result.stderr


def test_t5_oadp_helper_with_several_targets_reaches_the_seam_with_the_arguments():
    with make_sandbox() as sb:
        two_clusters(sb, apply_to_all="true")
        script = ('source "${0:A:h}/src/helpers/multi_cluster_helpers.sh"\n'
                  'mcm_fanout() { printf "<%s>" "$@"; exit 0; }\n'
                  'source "${0:A:h}/src/helpers/oadp_br_helpers.sh"\n'
                  'print -r -- NOT-REACHED\n')
        result = sb.run_zsh(script, args=["--target", "tgt1"])
        assert result.stdout == "<--target><tgt1>", result.stderr


# ---- T5: resolving before the env load ----------------------------------------------------------------------------
def write_mirror_config(sb, cluster, root="reg.example.com:5000/ns", extra=None):
    values = {"MIRROR_CONFIG_VERSION": "2", "MIRROR_REGISTRY_ROOT": root, **(extra or {})}
    body = "".join(f'export {key}="{value}"\n' for key, value in values.items())
    return sb.write_config("registry_mirror", cluster=cluster, text=body)


def mirror_track(extra=()):
    return [f"{MIRROR}/0_x_full_quick_mirror_script", f"{MIRROR}/2_download_and_mirror", *extra]


def test_t5_mirror_guard_uses_the_resolved_cluster():
    with make_sandbox(extra=mirror_track()) as sb:
        two_clusters(sb, current="itz-a")
        write_mirror_config(sb, "itz-b")
        result = sb.run_script(FULL_MIRROR, args=["--list-steps", "--target-cluster", "itz-b"])
        assert "No mirror config" not in result.stderr
        assert "skipped" not in result.stderr
        assert "Unknown" not in result.stderr


def test_t5_mirror_guard_nested_in_a_fanout_reports_a_failure_not_a_skip():
    with make_sandbox(extra=mirror_track()) as sb:
        two_clusters(sb, current="itz-a")
        write_mirror_config(sb, "itz-a")
        result = sb.run_script(FULL_MIRROR, env={"MCM_CLUSTER": "itz-b", "_MCM_FANOUT_SCRIPT": "/some/other/script.sh"})
        assert result.returncode == 1, result.stdout + result.stderr
        assert "[ERROR]" in result.stderr and "skipped" not in result.stderr


def test_t5_mirror_guard_when_off_is_unchanged():
    with make_sandbox(extra=mirror_track()) as sb:
        write_state(sb, on="false")
        result = sb.run_script(FULL_MIRROR, args=[])
        assert result.returncode == 1
        assert "No mirror config yet" in result.stderr and "0.0_generate_mirror_config.sh" in result.stderr


def write_confluent_details(sb, cluster, marker):
    folder = sb.repo / "configs" / "clusters" / cluster / "confluent_platform_config"
    folder.mkdir(parents=True)
    (folder / "confluent_instance_details.sh").write_text(f'export CONFLUENT_NAMESPACE="{marker}"\n')


def fake_confluent(sb):
    tool = sb.bin / "confluent"
    tool.write_text("#!/bin/sh\necho 'Version: v1'\n")
    tool.chmod(0o755)


def test_t5_confluent_login_reads_the_resolved_clusters_details():
    with make_sandbox(extra=["scripts/install_confluent_platform/confluent_cli_login.sh", "pyproject.toml"]) as sb:
        two_clusters(sb, current="itz-a")
        write_confluent_details(sb, "itz-a", "from-itz-a")
        write_confluent_details(sb, "itz-b", "from-itz-b")
        fake_confluent(sb)
        current = sb.run_script(CONFLUENT_LOGIN, args=["--status"])
        assert "from-itz-a" in current.stdout, current.stderr
        flag = sb.run_script(CONFLUENT_LOGIN, args=["--status", "--target-cluster", "itz-b"])
        assert "from-itz-b" in flag.stdout, flag.stderr


def test_t5_confluent_login_sourced_leaves_no_pin():
    with make_sandbox(extra=["scripts/install_confluent_platform/confluent_cli_login.sh", "pyproject.toml"]) as sb:
        two_clusters(sb, current="itz-a")
        write_confluent_details(sb, "itz-a", "from-itz-a")
        fake_confluent(sb)
        script = (f'source {CONFLUENT_LOGIN} --status >/dev/null 2>&1\n'
                  'print -r -- "${MCM_CLUSTER:-none}:${_MCM_ARG_TARGETS[*]:-empty}"\n')
        assert sb.run_zsh(script, strict=False).stdout.strip() == "none:empty"


def test_t5_confluent_login_when_off_uses_the_flat_details():
    with make_sandbox(extra=["scripts/install_confluent_platform/confluent_cli_login.sh", "pyproject.toml"]) as sb:
        write_state(sb, on="false")
        folder = sb.repo / "configs" / "confluent_platform_config"
        folder.mkdir(parents=True)
        (folder / "confluent_instance_details.sh").write_text('export CONFLUENT_NAMESPACE="flat-one"\n')
        fake_confluent(sb)
        result = sb.run_script(CONFLUENT_LOGIN, args=["--status"])
        assert "flat-one" in result.stdout, result.stderr


# ---- T6: the cpd-cli shim -----------------------------------------------------------------------------------------
def last_cpd_cli_call(sb):
    return sb.call_records("cpd-cli")[-1]


@pytest.mark.parametrize("verb", ["manage", "manage-k8s"])
def test_t6_manage_keeps_the_real_home(verb):
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        result = sb.run_zsh(BOOT + f'cpd-cli {verb} login-to-ocp --server=x\n', env={"ENV_TARGET": "cpd"})
        assert result.returncode == 0, result.stderr
        record = last_cpd_cli_call(sb)
        assert record["argv"] == [verb, "login-to-ocp", "--server=x"]
        assert record["env"]["HOME"] == str(sb.home)
        assert record["env"]["MCM_CLUSTER"] == "itz-a"
        assert record["env"]["CPD_CLI_MANAGE_WORKSPACE"] == str(sb.home / "cpd-cli" / "clusters" / "itz-a")
        assert record["env"]["OLM_UTILS_CONTAINER"] == "olm-utils-play-v4-itz-a"


@pytest.mark.parametrize("args", [["service-instance", "list"], ["config", "profiles", "list"], ["oadp", "status"]])
def test_t6_everything_else_gets_the_clusters_home(args):
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        result = sb.run_zsh(BOOT + 'cpd-cli "$@"\n', env={"ENV_TARGET": "cpd"}, args=args)
        assert result.returncode == 0, result.stderr
        record = last_cpd_cli_call(sb)
        assert record["argv"] == args
        assert record["env"]["HOME"] == str(sb.repo / "configs" / "clusters" / "itz-a" / ".home")


def test_t6_health_runs_in_the_cluster_folder():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        sb.run_zsh(BOOT + 'cpd-cli health runs\n', env={"ENV_TARGET": "cpd"}, check=True)
        record = last_cpd_cli_call(sb)
        root = sb.repo / "configs" / "clusters" / "itz-a"
        assert record["cwd"] == str(root)
        assert record["env"]["HOME"] == str(root / ".home")


def test_t6_shim_is_not_on_path_when_off_and_the_real_tool_runs_directly():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        sb.write_config("cpd", ocp_url=URL_A)
        result = sb.run_zsh(BOOT + 'cpd-cli health runs\n', env={"ENV_TARGET": "cpd"})
        assert result.returncode == 0, result.stderr
        record = last_cpd_cli_call(sb)
        assert record["env"]["HOME"] == str(sb.home)
        assert record["cwd"] == str(sb.repo)


def test_t6_shim_with_no_pin_acts_as_the_plain_binary():
    with make_sandbox() as sb:
        result = sb.run_zsh(f'{SHIM}/cpd-cli version\n', env={"CPD_CLI_HOME": sb.home / "cpd-cli"})
        assert result.returncode == 0, result.stderr
        assert last_cpd_cli_call(sb)["env"]["HOME"] == str(sb.home)


def test_t6_shim_fails_clearly_when_cpd_cli_is_missing():
    with make_sandbox() as sb:
        result = sb.run_zsh(f'{SHIM}/cpd-cli version\n', env={"CPD_CLI_HOME": sb.tmp / "nope"})
        assert result.returncode == 127
        assert "[ERROR]" in result.stderr


def test_t6_shim_is_executable_in_the_repo():
    assert (REPO / SHIM / "cpd-cli").stat().st_mode & 0o100


def test_t6_control_center_side_container_and_workspace_are_per_cluster():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        sb.write_config("swhub_control_center", cluster="itz-a", ocp_url=URL_A, extra={
            "CONTROL_CLUSTER_MODE": "same", "CONTROL_OCP_URL": URL_A,
            "CONTROL_OLM_UTILS_IMAGE": "cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.amd64",
            "CONTROL_OLM_UTILS_CONTAINER": "olm-utils-swhub-control-center",
            "CONTROL_CPD_CLI_WORKSPACE": f"{sb.home}/cpd-cli-swhub-control-center",
            "CONTROL_PROJECT_OPERATORS": "ops", "CONTROL_PROJECT_OPERANDS": "ands", "CONTROL_STG_CLASS_BLOCK": "b",
            "VERSION": "5.4.0", "PATCH_ID": "1",
        })
        script = (BOOT + 'source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_helpers.sh"\n'
                  'swhcc_activate\nprint -r -- "$OLM_UTILS_CONTAINER|$CPD_CLI_MANAGE_WORKSPACE|$CPD_CLI_WORK_PATH"\n')
        result = sb.run_zsh(script, env={"ENV_TARGET": "swhub_control_center"})
        assert result.returncode == 0, result.stdout + result.stderr
        workspace = sb.home / "cpd-cli" / "clusters" / "itz-a" / "swhub-control-center"
        assert result.stdout.strip().splitlines()[-1] == f"olm-utils-swhub-control-center-itz-a|{workspace}|{workspace}/work"


# ---- T13: mirror workspace ----------------------------------------------------------------------------------------
HELPERS = 'source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"\n'
SHOW = (HELPERS + 'print -r -- "BASE=$MIRROR_BASE"\nprint -r -- "WS=$MIRROR_WORKSPACE"\n'
        'print -r -- "TOOLS=$(preg_tools_dir)"\nprint -r -- "LOCAL=$(preg_local_registry_dir)"\n'
        'print -r -- "STATE=$(preg_local_state_file)"\nprint -r -- "NAME=${LOCAL_REGISTRY_CONTAINER:-default}"\n'
        + DUMP)


def mirror_values(sb, cluster, env=None):
    result = sb.run_zsh(BOOT + SHOW, env={"ENV_TARGET": "registry_mirror", "MCM_CLUSTER": cluster, **(env or {})})
    assert result.returncode == 0, result.stdout + result.stderr
    head = dict(line.split("=", 1) for line in result.stdout.split("===DUMP===")[0].splitlines())
    return head, parse_dump(result.stdout)


def test_t13_same_registry_root_shares_the_workspace():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a", "reg.example.com:5000/ns")
        write_mirror_config(sb, "itz-b", "reg.example.com:5000/ns/")
        a, _ = mirror_values(sb, "itz-a")
        b, _ = mirror_values(sb, "itz-b")
        assert a["WS"] == b["WS"]
        assert a["WS"] == str(sb.repo / "registry_mirror_workspace" / "registries" / "reg.example.com_5000+ns")
        assert ":" not in a["WS"].rsplit("/", 1)[1]


def test_t13_different_root_separates():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a", "reg.example.com:5000/ns")
        write_mirror_config(sb, "itz-b", "other.example.com:5000/ns")
        assert mirror_values(sb, "itz-a")[0]["WS"] != mirror_values(sb, "itz-b")[0]["WS"]


def test_t13_cluster_scope_keeps_its_own_folder():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a", "reg.example.com:5000/ns", extra={"MIRROR_WORKSPACE_SCOPE": "cluster"})
        write_mirror_config(sb, "itz-b", "reg.example.com:5000/ns")
        a, env_a = mirror_values(sb, "itz-a")
        assert a["WS"] == str(sb.repo / "configs" / "clusters" / "itz-a" / "registry_mirror_workspace")
        assert a["TOOLS"] == str(sb.repo / "registry_mirror_workspace" / "tools")
        assert env_a["MIRROR_CLUSTER_OUT"] == str(sb.repo / "configs" / "clusters" / "itz-a" / "registry_mirror_cluster")
        assert mirror_values(sb, "itz-b")[0]["WS"] != a["WS"]


def test_t13_invalid_scope_is_an_error():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a", extra={"MIRROR_WORKSPACE_SCOPE": "bogus"})
        result = sb.run_zsh(BOOT + HELPERS, env={"ENV_TARGET": "registry_mirror", "MCM_CLUSTER": "itz-a"})
        assert result.returncode != 0
        assert "MIRROR_WORKSPACE_SCOPE" in result.stderr


def test_t13_tools_and_base_stay_machine_wide_and_base_is_exported_first():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a")
        a, env = mirror_values(sb, "itz-a")
        base = sb.repo / "registry_mirror_workspace"
        assert a["BASE"] == str(base)
        assert a["TOOLS"] == str(base / "tools")
        assert a["LOCAL"] == str(base / "local-registry")
        assert a["STATE"] == str(base / "local-registry" / "state.env")
        assert a["NAME"] == "default"
        assert env["MIRROR_BASE"] == str(base) and env["MIRROR_WORKSPACE"] == a["WS"]


def test_t13_a_child_process_keeps_the_machine_wide_base():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a")
        parent, env = mirror_values(sb, "itz-a")
        child, _ = mirror_values(sb, "itz-a", env={"MIRROR_BASE": env["MIRROR_BASE"], "MIRROR_WORKSPACE": env["MIRROR_WORKSPACE"]})
        assert child["BASE"] == parent["BASE"]
        assert child["WS"] == parent["WS"]
        assert child["TOOLS"] == parent["TOOLS"]


def test_t13_key_is_stable_across_local_registry_up():
    with make_sandbox() as sb:
        two_clusters(sb)
        extra = {"LOCAL_REGISTRY_HOST": "Bastion.Example.com", "LOCAL_REGISTRY_PORT": "5000", "LOCAL_REGISTRY_NAMESPACE": "mirror"}
        write_mirror_config(sb, "itz-a", root="", extra=extra)
        before = mirror_values(sb, "itz-a")[0]["WS"]
        assert before.endswith("/registries/bastion.example.com_5000+mirror")
        # 0.3 up writes "${HOST}:${PORT}${NS:+/${NS}}" into MIRROR_REGISTRY_ROOT.
        write_mirror_config(sb, "itz-a", root="Bastion.Example.com:5000/mirror", extra=extra)
        assert mirror_values(sb, "itz-a")[0]["WS"] == before


def test_t13_empty_root_uses_the_engines_default_port():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a", root="", extra={"LOCAL_REGISTRY_HOST": "bastion", "LOCAL_REGISTRY_ENGINE": "mirror-registry"})
        assert mirror_values(sb, "itz-a")[0]["WS"].endswith("/registries/bastion_8443")


def test_t13_key_matches_what_the_local_registry_step_writes():
    # Guards the assumption in _preg_mcm_resolve_workspace: if 0.3 changes how it builds the root, the key must follow.
    text = (REPO / LOCAL_REGISTRY).read_text()
    assert 'ROOT="${HOST}:${PORT}${NS:+/${NS}}"' in text
    assert 'PORT="${LOCAL_REGISTRY_PORT:-5000}"' in text
    assert 'NAME="${LOCAL_REGISTRY_CONTAINER:-mirror-local-registry}"' in text


def test_t13_non_default_port_gets_its_own_folder_and_container():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a", extra={"LOCAL_REGISTRY_PORT": "5001"})
        a, _ = mirror_values(sb, "itz-a")
        base = sb.repo / "registry_mirror_workspace"
        assert a["LOCAL"] == str(base / "local-registry-5001")
        assert a["STATE"] == str(base / "local-registry-5001" / "state.env")
        assert a["NAME"] == "mirror-local-registry-5001"


def test_t13_explicit_local_registry_names_win():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a", extra={"LOCAL_REGISTRY_PORT": "5001", "LOCAL_REGISTRY_CONTAINER": "mine", "LOCAL_REGISTRY_DIR": "/data/x"})
        a, _ = mirror_values(sb, "itz-a")
        assert a["LOCAL"] == str(sb.repo / "registry_mirror_workspace" / "local-registry")
        assert a["NAME"] == "mine"


def test_t13_default_port_keeps_the_default_names():
    with make_sandbox() as sb:
        two_clusters(sb)
        write_mirror_config(sb, "itz-a", extra={"LOCAL_REGISTRY_PORT": "5000"})
        a, _ = mirror_values(sb, "itz-a")
        assert a["LOCAL"].endswith("/local-registry")
        assert a["NAME"] == "default"


def test_t13_mode_off_keeps_the_flat_workspace():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        sb.write_config("cpd")  # the flat layout needs configs/cp4d_config, as it did before the mode existed
        sb.write_config("registry_mirror", text='export MIRROR_CONFIG_VERSION="2"\nexport MIRROR_REGISTRY_ROOT="reg:5000"\nexport LOCAL_REGISTRY_PORT="5001"\n')
        result = sb.run_zsh(BOOT + SHOW, env={"ENV_TARGET": "registry_mirror"})
        assert result.returncode == 0, result.stdout + result.stderr
        head = dict(line.split("=", 1) for line in result.stdout.split("===DUMP===")[0].splitlines())
        flat = sb.repo / "registry_mirror_workspace"
        assert head["WS"] == str(flat) and head["TOOLS"] == str(flat / "tools")
        assert head["LOCAL"] == str(flat / "local-registry") and head["NAME"] == "default"


def test_t13_entitled_cluster_is_skipped_with_the_dedicated_code():
    with make_sandbox(extra=mirror_track([f"{MIRROR}/0_initial_setup"])) as sb:
        two_clusters(sb, current="itz-a")
        write_mirror_config(sb, "itz-b")
        result = sb.run_script(LOCAL_REGISTRY, args=["status"])
        assert result.returncode == 75, result.stderr
        assert "skipped" in result.stderr
        guard = sb.run_script(FULL_MIRROR)
        assert guard.returncode == 75
        assert "skipped" in guard.stderr


def test_t13_a_path_target_that_is_missing_stays_an_error():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        result = sb.run_zsh(BOOT, env={"ENV_TARGET": "/no/such/file_vars.sh"})
        assert result.returncode == 1
        assert "[ERROR]" in result.stderr


def test_t13_cluster_without_a_config_is_skipped_for_other_products_too():
    with make_sandbox() as sb:
        two_clusters(sb, current="itz-a")
        result = sb.run_zsh(BOOT, env={"ENV_TARGET": "concert"})
        assert result.returncode == 75
        assert "skipped" in result.stderr


def test_t13_include_configs_carries_only_this_clusters_config_folders():
    with make_sandbox(extra=[f"{MIRROR}/2_download_and_mirror"]) as sb:
        two_clusters(sb, current="itz-a")
        write_mirror_config(sb, "itz-a", extra={"MIRROR_TRANSPORT": "stopover", "MIRROR_BUNDLE_DIR": sb.tmp / "bundle"})
        sb.write_config("cpd", cluster="itz-a", ocp_url=URL_A)
        sb.write_config("cpd", cluster="itz-b", ocp_url=URL_B)
        first = mirror_values(sb, "itz-a")[0]["WS"]
        inventory = Path(first) / "inventory"
        inventory.mkdir(parents=True)
        (inventory / "inventory.json").write_text("{}\n")
        (inventory / "report.txt").write_text("r\n")
        for args in (["init", "-q"], ["add", "-A"]):
            subprocess.run(["git", *args], cwd=sb.repo, check=True, capture_output=True,
                           env={"PATH": "/usr/bin:/bin", "HOME": str(sb.home)})
        result = sb.run_script(BUILD_BUNDLE, args=["--include-configs", "--skip-tools"], timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        with tarfile.open(sb.tmp / "bundle" / "config" / "configs-with-secrets.tar.gz") as archive:
            names = archive.getnames()
        assert "configs/cp4d_config/cpd_vars.sh" in names
        assert "configs/registry_mirror_config/registry_mirror_vars.sh" in names
        assert not [n for n in names if "itz-b" in n or "clusters" in n or ".home" in n]


# ---- one-way delineation: the flag is only the default ------------------------------------------------------------
def off_two_clusters(sb, current="", targets="", apply_to_all="false"):
    """itz-a and itz-b delineated and registered, each with a cpd config; the flag off."""
    for name, url in (("itz-a", URL_A), ("itz-b", URL_B)):
        sb.write_cluster_marker(name, url)
        sb.write_config("cpd", cluster=name, ocp_url=url, extra={"ONLY_ON": name})
    write_state(sb, ("itz-a", "itz-b"), current=current, targets=targets, apply_to_all=apply_to_all, on="false")


def retire(sb, name):
    marker = sb.repo / "configs" / "clusters" / name / ".cluster"
    marker.write_text(marker.read_text() + 'RETIRED="true"\n')


@pytest.mark.parametrize("how", ["flag", "pin"])
def test_off_naming_a_delineated_cluster_pins_it_fully(how):
    with make_sandbox() as sb:
        off_two_clusters(sb)
        args, extra = (["--target-cluster", "itz-b"], {}) if how == "flag" else ((), {"MCM_CLUSTER": "itz-b"})
        env = load(sb, env=extra, args=args)
        c = sb.repo / "configs" / "clusters" / "itz-b"
        cli = sb.home / "cpd-cli" / "clusters" / "itz-b"
        assert env["MCM_CLUSTER"] == "itz-b"
        assert env["CONFIGS_ROOT"] == str(c)
        assert env["ONLY_ON"] == "itz-b" and env["OCP_URL"] == URL_B
        assert env["KUBECONFIG"] == str(c / ".home" / ".kube" / "config")
        assert env["OLM_UTILS_CONTAINER"] == "olm-utils-play-v4-itz-b"
        assert env["CPD_CLI_MANAGE_WORKSPACE"] == str(cli)
        assert env["SERVICE_INSTANCE_FILE_DIR"] == str(c / "service_instances")
        assert env["PATH"].split(":")[0] == str(sb.repo / SHIM)
        assert env["CPD_CLI"] == str(sb.repo / SHIM / "cpd-cli")


def test_off_pinned_summary_row_says_the_default_stays_flat():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        result = sb.run_zsh(BOOT, env={"ENV_TARGET": "cpd"}, args=["--target-cluster", "itz-a"])
        assert result.returncode == 0, result.stderr
        assert "[ENV]   mcm      itz-a (--target-cluster) - multi-cluster mode is off" in result.stderr


def test_off_state_file_selection_is_ignored_and_the_run_is_flat():
    with make_sandbox() as sb:
        off_two_clusters(sb, current="itz-a", targets="itz-b", apply_to_all="true")
        sb.write_config("cpd", ocp_url="https://api.flat.example.com:6443")
        env = load(sb)
        assert env["CONFIGS_ROOT"] == str(sb.repo / "configs")
        assert env["OLM_UTILS_CONTAINER"] == "olm-utils-play-v4"
        for name in ("MCM_CLUSTER", "KUBECONFIG", "CPD_CLI"):
            assert name not in env, name


def test_off_naming_a_cluster_that_is_not_delineated_is_an_error():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        (sb.repo / "configs" / "clusters" / "itz-c").mkdir()  # a folder, but no marker
        result = sb.run_zsh(BOOT + 'print -r -- SURVIVED\n', env={"ENV_TARGET": "cpd"}, args=["--target-cluster", "itz-c"])
        assert result.returncode != 0
        assert "'itz-c' is not delineated" in result.stderr and "itz-a itz-b" in result.stderr
        assert "SURVIVED" not in result.stdout


def test_off_a_retired_cluster_cannot_be_named():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        retire(sb, "itz-b")
        for args, extra in ((["--target-cluster", "itz-b"], {}), ((), {"MCM_CLUSTER": "itz-b"})):
            result = sb.run_zsh(BOOT + 'print -r -- SURVIVED\n', env={"ENV_TARGET": "cpd", **extra}, args=args)
            assert result.returncode != 0
            assert "retired" in result.stderr and "multi_cluster.sh add itz-b" in result.stderr
            assert "SURVIVED" not in result.stdout


def test_off_all_clusters_is_the_registered_clusters_that_are_not_retired():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        sb.write_cluster_marker("itz-c", "https://api.itz-c.example.com:6443")
        retire(sb, "itz-c")
        write_state(sb, ("itz-a", "itz-b", "itz-c"), on="false")
        result = resolve(sb, args=["--all-clusters"])
        assert result.returncode == 0, result.stderr
        assert result.stdout.splitlines() == ["itz-a itz-b", "FROM=flag"]


def test_off_all_clusters_with_no_delineated_cluster_keeps_the_old_error():
    with make_sandbox() as sb:
        write_state(sb, on="false")
        result = resolve(sb, args=["--all-clusters"])
        assert result.returncode != 0
        assert "need multi-cluster mode, which is off" in result.stderr


def test_off_s_env_target_cluster_loads_a_delineated_cluster():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        env, _ = s_env(sb, "cpd --target-cluster itz-a")
        assert env["MCM_CLUSTER"] == "itz-a" and env["OCP_URL"] == URL_A
        assert env["KUBECONFIG"] == str(sb.repo / "configs" / "clusters" / "itz-a" / ".home" / ".kube" / "config")


def test_off_s_env_target_cluster_runs_the_podman_machine_check():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        marker = sb.tmp / "prep-ran"
        (sb.repo / "scripts" / "0.0_make_executable.sh").write_text(f'touch "{marker}"\n')
        sb.set_machine("stopped")
        result = sb.run_zsh('source s_env.sh cpd --target-cluster itz-a\nprint -r -- LOADED\n', strict=False)
        assert "LOADED" in result.stdout, result.stdout + result.stderr
        if subprocess.run(["uname", "-s"], capture_output=True, text=True, check=False).stdout.strip() == "Darwin":
            assert marker.exists()


# ---- one-way delineation: a flat config never reaches a delineated cluster ----------------------------------------
GUARD_OK = 'print -r -- "LOADED ${OCP_URL:-}"\n'


def test_flat_config_for_a_delineated_cluster_is_refused():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        sb.write_config("cpd", ocp_url=URL_A)
        result = sb.run_zsh(BOOT + GUARD_OK, env={"ENV_TARGET": "cpd"})
        assert result.returncode != 0
        assert "LOADED" not in result.stdout
        assert "delineated cluster 'itz-a' (configs/clusters/itz-a/)" in result.stderr
        assert "configs/cp4d_config/cpd_vars.sh" in result.stderr
        assert "--target-cluster itz-a" in result.stderr


def test_flat_config_guard_matches_by_derived_name_and_retired_clusters():
    with make_sandbox() as sb:
        sb.write_cluster_marker("itz-a", "")         # no URL in the marker: the derived name decides
        sb.write_cluster_marker("itz-b", URL_B)
        retire(sb, "itz-b")
        write_state(sb, ("itz-a",), on="false")
        for url, name in ((URL_A, "itz-a"), (URL_B, "itz-b")):
            sb.write_config("cpd", ocp_url=url)
            result = sb.run_zsh(BOOT + GUARD_OK, env={"ENV_TARGET": "cpd"})
            assert result.returncode != 0, url
            assert f"delineated cluster '{name}'" in result.stderr
        assert "is retired" in result.stderr


def test_flat_config_guard_checks_every_file_of_an_all_load_and_an_override():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        sb.write_config("cpd", ocp_url="https://api.flat.example.com:6443")
        # Load order: cpd, concert, confluent. The last one's URL wins, so only the per-file check sees concert's.
        sb.write_config("concert", ocp_url=URL_B)
        sb.write_config("confluent", ocp_url="https://api.flat2.example.com:6443")
        result = sb.run_zsh('source "${0:A:h}/env_bootstrap.sh"\n' + GUARD_OK, env={"ENV_TARGET": "all"})
        assert result.returncode != 0
        assert "configs/concert_config/concert_vars.sh" in result.stderr and "'itz-b'" in result.stderr
        (sb.repo / "configs" / "concert_config" / "concert_vars.sh").unlink()
        override = sb.run_zsh(f'source s_env.sh cpd OCP_URL={URL_A}\n' + GUARD_OK, strict=False)
        assert override.returncode != 0 and "LOADED" not in override.stdout
        assert "delineated cluster 'itz-a'" in override.stderr


def test_flat_config_for_another_cluster_still_loads_with_delineated_clusters_around():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        sb.write_config("cpd", ocp_url="https://api.flat.example.com:6443")
        result = sb.run_zsh(BOOT + GUARD_OK, env={"ENV_TARGET": "cpd"})
        assert result.returncode == 0, result.stderr
        assert "LOADED https://api.flat.example.com:6443" in result.stdout
        assert "[ERROR]" not in result.stderr


def test_flat_config_guard_in_an_interactive_shell_keeps_the_shell_and_drops_the_load():
    with make_sandbox() as sb:
        off_two_clusters(sb)
        sb.write_config("cpd", ocp_url=URL_A, extra={"FLAT_ONLY": "1"})
        script = sb.repo / "interactive_probe"
        script.write_text('source s_env.sh cpd\nprint -r -- "rc=$? url=${OCP_URL:-unset} flat=${FLAT_ONLY:-unset} loaded=${_CP4D_ENV_LOADED:-unset}"\n')
        result = subprocess.run(["zsh", "-i", "-f", str(script)], cwd=sb.repo, env=sb.env(), capture_output=True,
                                text=True, timeout=60, check=False)
        assert "rc=1 url=unset flat=unset loaded=unset" in result.stdout, result.stdout + result.stderr
