"""Control Center in the runner pod (phase I6, D4): the premium sidecar, its queue, the shims, the slot.

Design: .claude/plans/multi-cluster-management/in-cluster-install-addon/d4-control-center-in-pod-design.md,
section 3 (build spec items 1-23, offline tests 1-12). Everything runs against fakes: a fake `oc` that logs
its calls, the real agent and client on a temp folder (a fake `setsid`, since macOS has none), and the shims
with fake neighbours. Nothing reaches a cluster, podman, `cpd-cli manage`, the real configs/ or ~/cpd-cli.
"""

import base64
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest
import yaml
from mcm_harness import make_sandbox
from test_install_runner import FAKE_OC as RUNNER_FAKE_OC
from test_install_runner import SANDBOX_EXTRA, SANDBOX_URL, STAND_IN_CHAIN

REPO = Path(__file__).resolve().parents[1]
HELPERS = REPO / "src/helpers/install_runner_helpers.sh"
AGENT = REPO / "src/install_runner/image/sidecar/swhcc-agent.sh"
CLIENT = REPO / "src/install_runner/image/bin/swhcc-exec"
SHIMS = REPO / "src/install_runner/image/shims"
CPD_HOOK = REPO / "src/install_runner/installs/cpd.sh"
FULL_CHAIN = "scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh"
SWHCC_CHAIN = "scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/full_installprocess-swhub_control_center.sh"
STEP4_CHAIN = "scripts/install_cloud_pak_for_data/4_install_components/4.0_full_step_4_installprocess-cpd.sh"
CC_DIR = "scripts/install_cloud_pak_for_data/optional_install_swhub_control_center"
PREMIUM = "cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.amd64"
PINNED = "cp.icr.io/cp/cpd/olm-utils-premium-v4@sha256:abc123"
KEY = "sekret-entitlement-key"

# A small fake oc for the slot and image tests: logs every call and keeps each `apply -f -` in its own file.
FAKE_OC = r"""#!/bin/bash
d="${FAKE_DIR}"
printf '%s\n' "oc $*" >> "$d/oc.log"
printf '%s\n' "${KUBECONFIG:-}" >> "$d/oc.kubeconfig"
args="$*"
case "$args" in
  "image info"*)
      prev=""; cfg=""
      for a in "$@"; do [ "$prev" = "--registry-config" ] && cfg="$a"; prev="$a"; done
      if [ -n "$cfg" ]; then
          { stat -f '%Lp' "$cfg" 2>/dev/null || stat -c '%a' "$cfg"; } > "$d/authfile_mode"
          cp "$cfg" "$d/authfile_copy"; echo "$cfg" > "$d/authfile_path"
      fi
      [ -e "$d/image_info_fails" ] && { echo "error: unauthorized: authentication required" >&2; exit 1; }
      [ -e "$d/image_info_warns" ] && echo 'W1111 12:00:00.000 warnings.go:70] a deprecation warning' >&2
      echo '{"name":"x","digest":"sha256:abc123","listDigest":"sha256:list"}' ;;
  "create namespace"*) printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "$3" ;;
  "create serviceaccount"*) printf 'apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: %s\n' "$3" ;;
  "label --local"*) cat ;;
  "apply -f -"*) n=$(ls "$d"/apply.* 2>/dev/null | wc -l | tr -d ' '); cat > "$d/apply.$((n + 1))" ;;
  "rollout status"*) [ -e "$d/rollout_fails" ] && exit 1 ;;
  "get secret"*) [ -e "$d/secret_$3" ] || exit 1 ;;
  "get pvc"*) exit 1 ;;
  "get statefulset"*) [ -e "$d/sts_exists" ] || exit 1 ;;
esac
exit 0
"""


def put(root, rel, text, mode=None):
    path = Path(root) / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if mode is not None:
        path.chmod(mode)
    return path


def tool(bin_dir, name, text):
    return put(bin_dir, name, text, mode=0o755)


def base_env(tmp_path, extra=None):
    """Only what a test sets, plus the system PATH: nothing from the developer's shell."""
    home = tmp_path / "home"
    (tmp_path / "tmp").mkdir(exist_ok=True)
    home.mkdir(exist_ok=True)
    env = {"PATH": f"{tmp_path}/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "TMPDIR": str(tmp_path / "tmp"),
           "_CP4D_REPO_ROOT": str(REPO), "FAKE_DIR": str(tmp_path), "LANG": "C"}
    env.update({k: str(v) for k, v in (extra or {}).items()})
    return env


def zsh(tmp_path, body, env=None, helpers=True, timeout=120):
    script = ("set -euo pipefail\n" + (f'source "{HELPERS}"\n' if helpers else "")) + textwrap.dedent(body)
    return subprocess.run(["zsh", "-c", script], capture_output=True, text=True, env=base_env(tmp_path, env),
                          timeout=timeout, check=False)


@pytest.fixture
def fake(tmp_path):
    tool(tmp_path / "bin", "oc", FAKE_OC)
    for name in ("podman", "cpd-cli"):
        tool(tmp_path / "bin", name, f'#!/bin/bash\necho "{name} $*" >> "$FAKE_DIR/tripwire"\nexit 0\n')
    return tmp_path


def oc_log(tmp_path):
    path = tmp_path / "oc.log"
    return path.read_text().splitlines() if path.exists() else []


def applies(tmp_path):
    return [p.read_text() for p in sorted(tmp_path.glob("apply.*"), key=lambda p: int(p.suffix[1:]))]


VARS_SAME = textwrap.dedent(f"""\
    export CONTROL_CLUSTER_MODE="same"
    export IMAGE_ARCH="amd64"
    export CONTROL_IMAGE_ARCH="amd64"
    export CONTROL_OLM_UTILS_IMAGE="cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.${{CONTROL_IMAGE_ARCH}}"
    export CONTROL_OLM_UTILS_CONTAINER="olm-utils-swhub-control-center"
    export PATCH_ID="8"
    export IBM_ENTITLEMENT_KEY="{KEY}"
    export CPD_IMAGE_SOURCE="entitled"
    export OCP_URL="https://api.x:6443"
    export OCP_USERNAME="kubeadmin"
    export OCP_PASSWORD="pw"
    export CONTROL_OC_LOGIN="oc login --server=https://api.x:6443 --token=t"
    export CONTROL_ROUTE_PUBLIC_IP="203.0.113.7"
    """)


def vars_file(tmp_path, text=VARS_SAME, **changes):
    for key, value in changes.items():
        if re.search(rf'^export {key}=', text, re.M):
            text = re.sub(rf'^export {key}=.*$', f'export {key}="{value}"', text, flags=re.M)
        else:
            text += f'export {key}="{value}"\n'
    return put(tmp_path, "cp4d_config/swhub_control_center/swhub_control_center_vars.sh", text)


# --- 1. slot render ------------------------------------------------------------------------------------------
SLOT_ENV = {"OCP_URL": "https://api.x:6443", "STG_CLASS_BLOCK": "blk", "PROJECT_CPD_INST_OPERANDS": "x"}


def slot_apply(tmp_path, chain, env=None):
    return zsh(tmp_path, f'ir_slot_apply cpd cpd-x img:1 "{chain}"', env={**SLOT_ENV, **(env or {})})


def slot_doc(tmp_path):
    text = next(t for t in applies(tmp_path) if t.startswith("# One independently runnable install"))
    docs = [d for d in yaml.safe_load_all(text) if d]
    return text, next(d for d in docs if d["kind"] == "StatefulSet")


def test_plain_slot_renders_byte_identical_to_before(fake):
    """No sidecar: the StatefulSet text is exactly what the template gave before I6 (golden from cf2cb31)."""
    for chain, env in ((FULL_CHAIN, {}), (STEP4_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true"}),
                       (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "DO_SWHUB_CONTROL_CENTER": "false"})):
        for f in fake.glob("apply.*"):
            f.unlink()
        result = slot_apply(fake, chain, env)
        assert result.returncode == 0, result.stderr
        text, _ = slot_doc(fake)
        assert text == (REPO / "tests/golden/install_runner_slot_plain.yaml").read_text(), chain
        assert not any(line.startswith(("oc image info", "oc rollout status", "oc secrets link")) for line in oc_log(fake))


@pytest.mark.parametrize("mode", ["same", "different"])
def test_sidecar_slot(fake, mode):
    vars_path = vars_file(fake, CONTROL_CLUSTER_MODE=mode)
    result = slot_apply(fake, SWHCC_CHAIN, {"ENV_TARGET_FILE": vars_path, "IBM_ENTITLEMENT_KEY": KEY})
    assert result.returncode == 0, result.stdout + result.stderr
    text, sts = slot_doc(fake)
    assert not re.search(r"@[A-Z_]+@", text)
    pod = sts["spec"]["template"]["spec"]
    annotations = sts["spec"]["template"]["metadata"]["annotations"]
    assert annotations["kubectl.kubernetes.io/default-container"] == "runner", "no 'Defaulted container' noise"
    assert annotations["openshift.io/required-scc"] == "restricted-v2"
    assert pod["automountServiceAccountToken"] is False
    assert "imagePullSecrets" not in pod, "a pod-level list would drop the SA's internal-registry secret"
    assert [c["name"] for c in pod["initContainers"]] == ["swhcc-prepare"]
    assert pod["initContainers"][0]["image"] == "img:1"
    runner, sidecar = pod["containers"]
    assert (runner["name"], sidecar["name"]) == ("runner", "swhcc")
    assert sidecar["image"] == PINNED, "the sidecar runs by digest"
    assert sidecar["command"] == ["/bin/bash", "/swhcc/bin/swhcc-agent.sh"]
    assert sidecar["resources"]["limits"]["memory"] == "4Gi"
    assert sidecar["securityContext"] == runner["securityContext"]
    work = [m for m in sidecar["volumeMounts"] if m["name"] == "work"]
    assert sorted(m["subPath"] for m in work) == ["swhcc", "swhcc/work"], "never /work/snapshots"
    sidecar_vols = {m["name"] for m in sidecar["volumeMounts"]}
    assert ("ir-sa" in sidecar_vols) == (mode == "same"), "a token in the sidecar only when its cluster is this one"
    assert {"swhcc-kube", "ir-sa", "work"} <= {m["name"] for m in runner["volumeMounts"]}
    env = {e["name"]: e.get("value") for e in runner["env"]}
    assert env["IR_SWHCC_IMAGE_SOURCE"] == PREMIUM and env["IR_SWHCC_IMAGE"] == PINNED
    assert env["IR_SWHCC_MODE"] == mode and env["IR_SWHCC_KUBE_DIR"] == "/var/run/install-runner/swhcc-kube"
    assert not re.search(r"(?i)password|token|apikey|entitlement", json.dumps(runner["env"] + sidecar["env"]))
    volumes = {v["name"]: v for v in pod["volumes"]}
    assert volumes["swhcc-kube"]["emptyDir"]["medium"] == "Memory"
    assert "projected" in volumes["ir-sa"]
    assert KEY not in text
    log = oc_log(fake)
    sts_apply = next(i for i, line in enumerate(log) if line == "oc apply -f -" and i > 0 and
                     any("image info" in l for l in log[:i]))
    assert any(l.startswith("oc rollout status sts/install-runner -n install-runner-cpd-x") for l in log[sts_apply:]), \
        "waits for the new pod before anything stages into it"


def test_sidecar_follows_the_full_chain_toggle_and_the_install_cluster_arch(fake):
    """The full chain asks for the sidecar through INSTALL_SWHUB_CONTROL_CENTER, with the vars file next to the
    staged cpd config; in different mode the tag's arch becomes the install cluster's IMAGE_ARCH."""
    vars_file(fake, CONTROL_CLUSTER_MODE="different", CONTROL_IMAGE_ARCH="ppc64le", IMAGE_ARCH="amd64",
              CONTROL_OC_LOGIN="oc login --server=https://api.cc:6443 --token=t")
    result = slot_apply(fake, FULL_CHAIN, {"CONFIG_DIR": fake / "cp4d_config", "INSTALL_SWHUB_CONTROL_CENTER": "true",
                                           "IBM_ENTITLEMENT_KEY": KEY})
    assert result.returncode == 0, result.stderr
    _, sts = slot_doc(fake)
    env = {e["name"]: e.get("value") for e in sts["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["IR_SWHCC_IMAGE_SOURCE"] == PREMIUM
    assert any("--filter-by-os linux/amd64" in line for line in oc_log(fake))


def test_rollout_failure_stops_the_launch(fake):
    (fake / "rollout_fails").touch()
    result = slot_apply(fake, SWHCC_CHAIN, {"ENV_TARGET_FILE": vars_file(fake), "IBM_ENTITLEMENT_KEY": KEY})
    assert result.returncode != 0
    assert "did not come up with its sidecar" in result.stderr
    assert "oc delete pod install-runner-0 -n install-runner-cpd-x" in result.stderr


def test_a_slot_that_exists_waits_for_its_pod_even_without_a_sidecar(fake):
    """Back from a Control Center launch to a plain chain: the sidecar goes, the pod is replaced, and nothing
    may stage into the old one while it terminates. The render stays the plain golden."""
    (fake / "sts_exists").touch()
    result = slot_apply(fake, STEP4_CHAIN)
    assert result.returncode == 0, result.stderr
    text, _ = slot_doc(fake)
    assert text == (REPO / "tests/golden/install_runner_slot_plain.yaml").read_text()
    log = oc_log(fake)
    sts_apply = max(i for i, line in enumerate(log) if line == "oc apply -f -")
    assert any(l.startswith("oc rollout status sts/install-runner -n install-runner-cpd-x") for l in log[sts_apply:])
    (fake / "rollout_fails").touch()
    stuck = slot_apply(fake, STEP4_CHAIN)
    assert stuck.returncode != 0
    assert "did not come up." in stuck.stderr and "oc delete pod install-runner-0" in stuck.stderr


# --- 2. the sidecars hook ------------------------------------------------------------------------------------
def hook(tmp_path, verb, chain, env=None):
    return subprocess.run(["zsh", str(CPD_HOOK), verb, chain], capture_output=True, text=True,
                          env=base_env(tmp_path, env), timeout=60, check=False)


@pytest.mark.parametrize("chain,env,wanted", [
    (FULL_CHAIN, {}, False),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true"}, True),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "false"}, False),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "DO_SWHUB_CONTROL_CENTER": "false"}, False),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "false", "DO_SWHUB_CONTROL_CENTER": "true"}, True),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "yes"}, False),   # the full chain tests == true
    ("", {"INSTALL_SWHUB_CONTROL_CENTER": "true"}, True),            # x_install_runner.sh preflight
    (SWHCC_CHAIN, {}, True),
    (SWHCC_CHAIN, {"DO_SWHUB_CONTROL_CENTER": "false"}, True),
    (STEP4_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true"}, False),
    # The chain's own --skip / --only (IR_HOOK_ARGS, one per line): no sidecar for a step that won't run.
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "IR_HOOK_ARGS": "--skip\nswhub-control-center"}, False),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "IR_HOOK_ARGS": "--skip_steps=cpd,swhub-control-center"}, False),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "IR_HOOK_ARGS": "--only\ncpd"}, False),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "IR_HOOK_ARGS": "--cpd"}, False),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "IR_HOOK_ARGS": "--only\ncpd,swhub-control-center"}, True),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "IR_HOOK_ARGS": "--swhub-control-center"}, True),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "IR_HOOK_ARGS": "--from\ncpd\n--skip\nsoftwarehub"}, True),
    (FULL_CHAIN, {"INSTALL_SWHUB_CONTROL_CENTER": "true", "IR_HOOK_ARGS": "--from=x=y"}, True),  # the chain refuses it
    (SWHCC_CHAIN, {"IR_HOOK_ARGS": "--only\ncluster-admins"}, True),   # its own steps: always Control Center
])
def test_sidecars_hook(tmp_path, chain, env, wanted):
    vars_path = vars_file(tmp_path)
    result = hook(tmp_path, "sidecars", chain, {"CONFIG_DIR": vars_path.parents[1], **env})
    assert result.returncode == 0, result.stderr
    if wanted:
        assert result.stdout == f"swhcc\t{PREMIUM}\tsame\n"
    else:
        assert result.stdout == ""


def test_sidecars_hook_reads_the_staged_vars_file(tmp_path):
    """Under a pin the staged folder is the cluster's own: the sidecar's image and mode come from there."""
    here = vars_file(tmp_path)
    staged = put(tmp_path, "staged/swhub_control_center/swhub_control_center_vars.sh",
                 VARS_SAME.replace('CONTROL_CLUSTER_MODE="same"', 'CONTROL_CLUSTER_MODE="different"')
                          .replace('IMAGE_ARCH="amd64"\n', 'IMAGE_ARCH="s390x"\n', 1))
    result = hook(tmp_path, "sidecars", FULL_CHAIN, {"CONFIG_DIR": here.parents[1], "IR_STAGED_CONFIG_DIR": staged.parents[1],
                                                     "INSTALL_SWHUB_CONTROL_CENTER": "true"})
    assert result.returncode == 0, result.stderr
    assert result.stdout == "swhcc\tcp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.s390x\tdifferent\n"


def test_hooks_get_the_chain_arguments(tmp_path):
    body = ('ir_hook() { print -r -- "$2 chain=$IR_HOOK_CHAIN"; print -r -- "$IR_HOOK_ARGS"; }\n'
            '_ir_hook_staged cpd preflight x.sh\n'
            '_IR_CHAIN_ARGS=(--skip "a b" --only=c)\n'
            '_ir_hook_staged cpd sidecars x.sh\n')
    result = zsh(tmp_path, body)
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["preflight chain=x.sh", "", "sidecars chain=x.sh", "--skip", "a b", "--only=c"]


def test_sidecars_hook_without_a_vars_file_still_names_the_sidecar(tmp_path):
    result = hook(tmp_path, "sidecars", SWHCC_CHAIN, {"CONFIG_DIR": tmp_path / "nowhere"})
    assert result.returncode == 0 and result.stdout == "swhcc\t\tsame\n"


def test_unknown_hook_verb_exits_zero(tmp_path):
    assert hook(tmp_path, "some-new-verb", "").returncode == 0


# --- 3. shims ------------------------------------------------------------------------------------------------
def shim_env(tmp_path, extra=None):
    bin_dir = tmp_path / "bin"
    # Records what reached the sidecar client, one NUL-separated argv per call.
    tool(bin_dir, "swhcc-exec", '#!/bin/bash\nprintf "%s\\0" "$@" >> "$FAKE_DIR/client.argv"\nprintf "\\n" >> "$FAKE_DIR/client.argv"\nexit 0\n')
    tool(bin_dir, "oc", '#!/bin/bash\n[ "$*" = "whoami --show-server" ] && echo https://api.here:6443/\nexit 0\n')
    return base_env(tmp_path, extra)


def client_calls(tmp_path):
    path = tmp_path / "client.argv"
    if not path.exists():
        return []
    # Each call is its arguments, each ended by NUL, then a newline.
    return [chunk.split("\0") for chunk in path.read_text().split("\0\n") if chunk]


def run_shim(tmp_path, shim_path, args, env=None):
    return subprocess.run(["bash", str(shim_path), *args], capture_output=True, text=True,
                          env=shim_env(tmp_path, env), timeout=60, check=False)


UNROUTED_PODMAN = [
    ["exec", "-e", "A=1", "-w", "/tmp", "c", "sh", "-c", "echo $A; pwd"],
    ["exec", "-it", "c", "true"],
    ["exec", "--bogus", "c", "true"],
    ["inspect", "-f", "{{.ImageName}}", "c"],
    ["inspect", "-f", "{{.State.Status}}", "c"],
    ["inspect", "other"],
    ["image", "exists", "anything"],
    ["image", "rm", "x"],
    ["pull", "--arch=amd64", "anything"],
    ["ps"], ["rm", "c"], ["info"], ["version"], ["create", "img"], ["nope"],
]
UNROUTED_CPD_CLI = [
    ["manage", "restart-container"],
    ["manage", "login-to-ocp", "--token=x"],
    ["manage", "clean-workspace"],
    ["manage"],
    ["health", "operators"],
]


def old_shim(tmp_path, name):
    """The shim as it was before I6 (copied from cf2cb31, which a squash merge would not keep)."""
    text = (REPO / "tests/golden/install_runner_shims_pre_i6" / name).read_text()
    return put(tmp_path, f"old/{name}", text, mode=0o755)


@pytest.mark.parametrize("name,matrix", [("podman", UNROUTED_PODMAN), ("cpd-cli", UNROUTED_CPD_CLI)])
def test_shims_without_the_route_behave_as_before(tmp_path, name, matrix):
    old = old_shim(tmp_path, name)
    env = {"OLM_UTILS_IMAGE": "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8", "IR_EXEC_CONTAINER_NAME": "c",
           "IR_SWHCC_IMAGE_SOURCE": PREMIUM}
    for args in matrix:
        before = run_shim(tmp_path, old, args, env)
        after = run_shim(tmp_path, SHIMS / name, args, env)
        assert (after.returncode, after.stdout, after.stderr.replace(str(SHIMS / name), "SHIM")) == \
               (before.returncode, before.stdout, before.stderr.replace(str(old), "SHIM")), args
    assert client_calls(tmp_path) == [], "nothing goes to the sidecar without IR_EXEC_ROUTE"


ROUTE = {"IR_EXEC_ROUTE": "swhcc", "IR_EXEC_CONTAINER_NAME": "olm-utils-swhub-control-center",
         "IR_SWHCC_IMAGE_SOURCE": PREMIUM}


def test_cpd_cli_shim_routes_manage_commands_unchanged(tmp_path):
    args = ["manage", "case-download", "--components=a,b", "--x=it's \"quoted\"", "two words", "--patch_id=8"]
    result = run_shim(tmp_path, SHIMS / "cpd-cli", args, ROUTE)
    assert result.returncode == 0, result.stderr
    assert client_calls(tmp_path) == [args[1:]]
    for noop in ("login-to-ocp", "restart-container"):
        result = run_shim(tmp_path, SHIMS / "cpd-cli", ["manage", noop], ROUTE)
        assert result.returncode == 0 and "nothing to do" in result.stdout
    result = run_shim(tmp_path, SHIMS / "cpd-cli", ["manage", "save-image"], ROUTE)
    assert result.returncode == 3
    assert len(client_calls(tmp_path)) == 1


@pytest.mark.parametrize("args,rc", [
    (["--server=https://api.here:6443", "--token=t"], 0),
    (["--server", "https://api.here:6443/"], 0),
    (["--server=https://api.install:6443"], 0),
    (["--server=https://api.other:6443", "--token=t"], 3),
    (["--token=t"], 0),
])
def test_login_to_ocp_server_guard(tmp_path, args, rc):
    for env in ({}, ROUTE):
        result = run_shim(tmp_path, SHIMS / "cpd-cli", ["manage", "login-to-ocp", *args],
                          {"IR_OCP_URL": "https://api.install:6443", **env})
        assert result.returncode == rc, result.stderr
        if rc:
            assert "cluster switch was missed" in result.stderr


def test_podman_shim_routes_the_side_container_and_tells_the_truth(tmp_path):
    env = {**ROUTE, "PASSED_ON": "from-env"}
    result = run_shim(tmp_path, SHIMS / "podman",
                      ["exec", "-w", "/x y", "-e", "K=v w", "-e", "PASSED_ON", "olm-utils-swhub-control-center",
                       "oc", "whoami", "--show-server"], env)
    assert result.returncode == 0, result.stderr
    assert client_calls(tmp_path) == [["--cwd", "/x y", "--env", "K=v w", "--env", "PASSED_ON=from-env", "--",
                                       "oc", "whoami", "--show-server"]]
    # Another container still runs here.
    result = run_shim(tmp_path, SHIMS / "podman", ["exec", "olm-utils-play-v4", "echo", "local"], env)
    assert result.stdout == "local\n" and len(client_calls(tmp_path)) == 1
    inspect = run_shim(tmp_path, SHIMS / "podman", ["inspect", "-f", "{{.ImageName}}", "olm-utils-swhub-control-center"],
                       {**env, "OLM_UTILS_IMAGE": "something-else"})
    assert inspect.stdout.strip() == PREMIUM
    assert run_shim(tmp_path, SHIMS / "podman", ["image", "exists", PREMIUM], env).returncode == 0
    other = run_shim(tmp_path, SHIMS / "podman", ["image", "exists", "icr.io/cpopen/cpd/olm-utils-v4:5.4.0"], env)
    assert other.returncode == 1 and "sidecar runs" in other.stderr
    assert run_shim(tmp_path, SHIMS / "podman", ["pull", "--arch=amd64", PREMIUM], env).returncode == 0
    assert run_shim(tmp_path, SHIMS / "podman", ["pull", "--arch=amd64", "x:1"], env).returncode == 1


# --- 4. agent and client -------------------------------------------------------------------------------------
FAKE_SETSID = f"#!{sys.executable}\nimport os, sys\nos.setsid()\nos.execvp(sys.argv[1], sys.argv[1:])\n"


class Queue:
    """The sidecar's folder, an agent on it, and a way to call the client."""

    def __init__(self, tmp_path):
        self.tmp = tmp_path
        self.root = tmp_path / "swhcc"
        (self.root / "q/.tmp").mkdir(parents=True)
        tool(tmp_path / "bin", "setsid", FAKE_SETSID)
        self.agent = None

    def env(self, extra=None):
        return base_env(self.tmp, {"SWHCC_ROOT": self.root, "IR_SWHCC_ROOT": self.root, "SWHCC_POLL": "0.2",
                                   "SWHCC_KILL_AFTER": "5", "IR_SWHCC_KUBECONFIG": "/kube/control.kubeconfig",
                                   "SWHCC_CWD": self.tmp,
                                   "IR_RUN_ID": "r1", **(extra or {})})

    def start_agent(self, extra=None):
        self.agent_log = open(self.tmp / "agent.log", "a")
        self.agent = subprocess.Popen(["bash", str(AGENT)], env=self.env(extra), stdout=self.agent_log,
                                      stderr=subprocess.STDOUT)
        wait_for(lambda: (self.root / "agent.heartbeat").exists())

    def stop_agent(self, sig=signal.SIGTERM):
        if self.agent and self.agent.poll() is None:
            self.agent.send_signal(sig)
            self.agent.wait(timeout=30)
        self.agent = None

    def client(self, *args, extra=None, timeout=60):
        return subprocess.run(["bash", str(CLIENT), *args], capture_output=True, text=True,
                              env=self.env(extra), timeout=timeout, check=False)

    def client_bg(self, *args, extra=None):
        return subprocess.Popen(["bash", str(CLIENT), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=self.env(extra))

    def requests(self):
        return sorted(p.name for p in (self.root / "q").iterdir() if not p.name.startswith("."))


def wait_for(check, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        if check():
            return True
        time.sleep(0.1)
    raise AssertionError("timed out")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie still answers kill 0; ps says whether it really runs.
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


@pytest.fixture
def queue(tmp_path):
    q = Queue(tmp_path)
    yield q
    q.stop_agent(signal.SIGKILL)
    # A command whose agent was killed lives on (as it would in a dead container's place): end it here.
    for pidfile in (q.root / "q").glob("*/pid"):
        try:
            pid = int(pidfile.read_text())
        except ValueError:
            continue
        for target in (-pid, pid):
            try:
                os.kill(target, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass


def test_output_streams_and_the_exit_code_passes_through(queue):
    queue.start_agent()
    proc = queue.client_bg("sh", "-c", "echo first; sleep 3; echo second >&2; exit 5")
    start = time.time()
    assert proc.stdout.readline() == "first\n"
    assert time.time() - start < 2.5, "output comes while the command still runs"
    out, _ = proc.communicate(timeout=30)
    assert proc.returncode == 5
    assert "second" in out, "stderr comes through the same stream, as podman exec -t gives it"
    assert queue.requests() == []


def test_arguments_and_cwd_reach_the_command_unchanged(queue, tmp_path):
    queue.start_agent()
    work = tmp_path / "a dir"
    work.mkdir()
    args = ["two words", "--x=it's \"q\"", "a=b", "", "$HOME"]
    result = queue.client("--cwd", str(work), "--", sys.executable, "-c",
                          "import json, os, sys; print(json.dumps([os.getcwd()] + sys.argv[1:]))", *args)
    assert result.returncode == 0, result.stderr
    got = json.loads(result.stdout.strip().splitlines()[-1])
    assert Path(got[0]).resolve() == work.resolve() and got[1:] == args


def test_one_request_at_a_time(queue, tmp_path):
    queue.start_agent()
    log = tmp_path / "order.log"
    procs = [queue.client_bg("sh", "-c", f'echo "start $1" >> {log}; sleep 1; echo "end $1" >> {log}', "_", name)
             for name in ("a", "b", "c")]
    for proc in procs:
        proc.communicate(timeout=60)
        assert proc.returncode == 0
    lines = log.read_text().splitlines()
    assert len(lines) == 6
    for i in range(0, 6, 2):
        assert lines[i].split()[1] == lines[i + 1].split()[1] and lines[i].startswith("start"), lines


def test_term_on_the_client_cancels_the_process_group(queue, tmp_path):
    queue.start_agent()
    pidfile = tmp_path / "child.pid"
    proc = queue.client_bg("sh", "-c", f"sleep 300 & echo $! > {pidfile}; wait")
    wait_for(pidfile.exists)
    wait_for(lambda: pidfile.read_text().strip() != "")
    child = int(pidfile.read_text())
    assert alive(child)
    proc.send_signal(signal.SIGTERM)
    proc.communicate(timeout=60)
    assert proc.returncode == 143
    wait_for(lambda: not alive(child))
    assert queue.requests() == []


TERM_SWALLOWER = 'trap "exit 0" TERM; echo $$ > {pid}; while :; do sleep 0.1; done'


def test_a_cancelled_command_is_143_whatever_it_returns(queue, tmp_path):
    """L-03 on the sidecar side: a command that traps TERM and exits 0 must not read as done."""
    queue.start_agent()
    pidfile = tmp_path / "pid"
    proc = queue.client_bg("sh", "-c", TERM_SWALLOWER.format(pid=pidfile))
    wait_for(lambda: pidfile.exists() and pidfile.read_text().strip())
    proc.send_signal(signal.SIGTERM)
    proc.communicate(timeout=60)
    assert proc.returncode == 143
    wait_for(lambda: "(exit 143)" in (tmp_path / "agent.log").read_text())
    assert "(exit 0)" not in (tmp_path / "agent.log").read_text()


def test_a_command_stopped_with_the_sidecar_is_143_whatever_it_returns(queue, tmp_path):
    queue.start_agent()
    pidfile = tmp_path / "pid"
    proc = queue.client_bg("sh", "-c", TERM_SWALLOWER.format(pid=pidfile))
    wait_for(lambda: pidfile.exists() and pidfile.read_text().strip())
    queue.stop_agent(signal.SIGTERM)
    proc.communicate(timeout=60)
    assert proc.returncode == 143, "the client passes the agent's 143 on"
    assert "(exit 143)" in (tmp_path / "agent.log").read_text()


def test_no_agent_gives_137_and_withdraws_the_request(queue):
    (queue.root / "agent.heartbeat").write_text(f"{int(time.time()) - 600}\n")
    result = queue.client("true", extra={"SWHCC_UNCLAIMED_LIMIT": "1", "SWHCC_STALE_UNCLAIMED": "1"})
    assert result.returncode == 137
    assert "sidecar not running" in result.stderr
    assert queue.requests() == []


def test_a_lost_agent_gives_137(queue, tmp_path):
    queue.start_agent()
    pidfile = tmp_path / "pid"
    proc = queue.client_bg("sh", "-c", f"echo $$ > {pidfile}; sleep 300", extra={"SWHCC_STALE_CLAIMED": "2"})
    wait_for(lambda: pidfile.exists() and pidfile.read_text().strip())
    queue.stop_agent(signal.SIGKILL)
    out, err = proc.communicate(timeout=60)
    assert proc.returncode == 137 and "lost the command" in err
    os.kill(int(pidfile.read_text()), signal.SIGKILL)


def test_an_agent_restart_marks_what_it_had_taken(queue):
    req = queue.root / "q/r0-1-1"
    (req / "claimed").mkdir(parents=True)
    (req / "argv").write_bytes(b"sleep\x00300\x00")
    queue.start_agent()
    wait_for(lambda: (req / "rc").exists())
    assert (req / "rc").read_text().strip() == "137"
    assert (req / "reason").read_text().strip() == "agent restarted"


def test_cancel_orphans_stops_what_a_dead_client_left(queue, tmp_path):
    queue.start_agent()
    pidfile = tmp_path / "pid"
    proc = queue.client_bg("sh", "-c", f"echo $$ > {pidfile}; sleep 300")
    wait_for(lambda: pidfile.exists() and pidfile.read_text().strip())
    proc.kill()   # the runner container died; the sidecar keeps running the command
    proc.communicate()
    orphan = int(pidfile.read_text())
    assert alive(orphan)
    result = queue.client("--cancel-orphans")
    assert result.returncode == 0, result.stderr
    assert "Cancelling 1" in result.stdout
    wait_for(lambda: not alive(orphan))
    assert queue.requests() == []


def test_cancel_all_drops_unclaimed_and_finished_requests(queue):
    unclaimed = queue.root / "q/r0-1-1"
    unclaimed.mkdir()
    (unclaimed / "argv").write_bytes(b"true\x00")
    finished = queue.root / "q/r0-2-2"
    (finished / "claimed").mkdir(parents=True)
    (finished / "rc").write_text("0\n")
    (queue.root / "q/.tmp/half").mkdir()
    result = queue.client("--cancel-all")
    assert result.returncode == 0, result.stderr
    assert queue.requests() == [] and list((queue.root / "q/.tmp").iterdir()) == []


def test_only_allowlisted_env_reaches_the_command_and_no_secret_is_queued(queue, tmp_path):
    queue.start_agent()
    seen = tmp_path / "seen"
    secrets = {"IBM_ENTITLEMENT_KEY": KEY, "CONTROL_OCP_PASSWORD": "pw-123", "KUBECONFIG": "/chain.kubeconfig",
               "OLM_UTILS_IMAGE": PREMIUM, "HTTPS_PROXY": "http://proxy:3128"}
    # A caller's own KUBECONFIG (a routed `podman exec -e KUBECONFIG=...`) never reaches the sidecar.
    proc = queue.client_bg("--env", "KUBECONFIG=/attacker.kc", "--env", "K8S_AUTH_KUBECONFIG=/attacker.kc",
                           "--env", "MINE=1", "sh", "-c", f"env > {seen}; sleep 1", extra=secrets)
    wait_for(seen.exists)
    for req in (queue.root / "q").iterdir():
        for f in req.rglob("*"):
            if f.is_file():
                text = f.read_bytes()
                assert KEY.encode() not in text and b"pw-123" not in text, f
                if f.name == "env":
                    assert stat.S_IMODE(f.stat().st_mode) == 0o600
    proc.communicate(timeout=30)
    env = dict(line.split("=", 1) for line in seen.read_text().splitlines() if "=" in line)
    assert env["KUBECONFIG"] == "/kube/control.kubeconfig", "always the control kubeconfig"
    assert env["K8S_AUTH_KUBECONFIG"] == "/kube/control.kubeconfig"
    assert env["EXTERNAL_WORK_ROOT"] == "/tmp/work" and env["CMD_PREFIX"] == "cpd-cli manage"
    assert env["OLM_UTILS_IMAGE"] == PREMIUM and env["HTTPS_PROXY"] == "http://proxy:3128"
    assert "IBM_ENTITLEMENT_KEY" not in env and "CONTROL_OCP_PASSWORD" not in env
    assert env["MINE"] == "1", "other --env keys still go across"


def test_agent_drops_keys_off_its_allowlist(queue, tmp_path):
    """A request written by hand: the agent's own filter holds even when a request carries more."""
    for name, extra in (("r0-1-1", b""), ("r0-2-2", b"FOO\n"), ("r0-3-3", b"KUBECONFIG\n")):
        req = queue.root / "q" / name
        req.mkdir()
        (req / "argv").write_bytes(b"sh\x00-c\x00echo ${FOO:-unset} ${KUBECONFIG:-none}\x00")
        (req / "env").write_bytes(b"FOO=bar\x00KUBECONFIG=/k\x00KUBECONFIG=/evil\x00")
        (req / "env.extra").write_bytes(extra)
    queue.start_agent()
    wait_for(lambda: (queue.root / "q/r0-3-3/rc").exists())
    assert (queue.root / "q/r0-1-1/out").read_text().strip() == "unset /k"
    assert (queue.root / "q/r0-2-2/out").read_text().strip() == "bar /k"
    assert (queue.root / "q/r0-3-3/out").read_text().strip() == "unset /k", "the first KUBECONFIG, the client's"


def test_client_needs_the_control_kubeconfig(queue):
    result = queue.client("true", extra={"IR_SWHCC_KUBECONFIG": ""})
    assert result.returncode == 2 and "IR_SWHCC_KUBECONFIG" in result.stderr


def test_client_keeps_a_copy_of_the_output_in_the_run(queue, tmp_path):
    queue.start_agent()
    run = tmp_path / "run"
    result = queue.client("echo", "kept", extra={"IR_RUN_DIR": run})
    assert result.returncode == 0
    logs = list((run / "swhcc-exec").glob("r1-*.log"))
    assert len(logs) == 1 and logs[0].read_text() == "kept\n"


def test_agent_stops_its_command_on_term(queue, tmp_path):
    queue.start_agent()
    pidfile = tmp_path / "pid"
    proc = queue.client_bg("sh", "-c", f"echo $$ > {pidfile}; sleep 300")
    wait_for(lambda: pidfile.exists() and pidfile.read_text().strip())
    queue.stop_agent(signal.SIGTERM)
    out, err = proc.communicate(timeout=30)
    assert proc.returncode == 143
    assert not alive(int(pidfile.read_text()))


def test_shim_to_agent_end_to_end(queue, tmp_path):
    """cpd-cli manage <cmd> in a routed step runs <cmd> in the sidecar from /opt/ansible's stand-in."""
    bin_dir = tmp_path / "bin"
    real_client = tool(bin_dir, "swhcc-exec", CLIENT.read_text())
    assert real_client.exists()
    tool(bin_dir, "get-cr-status", '#!/bin/bash\nprintf "%s|" "$@"; echo; echo "KUBECONFIG=$KUBECONFIG"\nexit 4\n')
    queue.start_agent()
    result = subprocess.run(["bash", str(SHIMS / "cpd-cli"), "manage", "get-cr-status", "--cpd_instance_ns=a b", "x=y"],
                            capture_output=True, text=True, env=queue.env({**ROUTE, "OLM_UTILS_IMAGE": PREMIUM}),
                            timeout=60, check=False)
    assert result.returncode == 4
    assert "--cpd_instance_ns=a b|x=y|" in result.stdout
    assert "KUBECONFIG=/kube/control.kubeconfig" in result.stdout


# --- 6. swhcc_activate in the pod ----------------------------------------------------------------------------
CONTROL = {"CONTROL_CLUSTER_MODE": "same", "CONTROL_OCP_URL": "https://api.x:6443", "CONTROL_OLM_UTILS_IMAGE": PREMIUM,
           "CONTROL_IMAGE_ARCH": "amd64", "IMAGE_ARCH": "amd64", "CONTROL_OLM_UTILS_CONTAINER": "olm-utils-swhub-control-center",
           "CONTROL_CPD_CLI_WORKSPACE": "/nope/cpd-cli-swhub-control-center", "CONTROL_PROJECT_OPERATORS": "cc-op",
           "CONTROL_PROJECT_OPERANDS": "cc", "CONTROL_STG_CLASS_BLOCK": "blk", "VERSION": "5.4.0", "PATCH_ID": "8"}


def pod_env(tmp_path, extra=None):
    """A Control Center step's env in a runner pod, with the real podman shim and a client that runs here."""
    bin_dir = tmp_path / "bin"
    tool(bin_dir, "podman", (SHIMS / "podman").read_text())
    # Runs the request here: drops the client options and logs the call.
    tool(bin_dir, "swhcc-exec", textwrap.dedent("""\
        #!/bin/bash
        echo "$*" >> "$FAKE_DIR/client.log"
        while [[ "$1" == --* ]]; do [[ "$1" == -- ]] && { shift; break; }; shift 2; done
        exec "$@"
        """))
    return {**CONTROL, "IR_IN_RUNNER": "1", "IR_SWHCC_IMAGE_SOURCE": PREMIUM, "IR_SWHCC_IMAGE": PINNED,
            "IR_SWHCC_MODE": "same", "IR_SWHCC_ROOT": tmp_path / "swhcc", "IR_SWHCC_KUBE_DIR": tmp_path / "kube",
            "IR_RUN_DIR": tmp_path / "run", **(extra or {})}


def setup_control_center(tmp_path, stub):
    text = "#!/bin/bash\necho 'This command is part of IBM Software Hub Premium'; exit 1\n" if stub \
        else "#!/bin/bash\nexec python3 /opt/ansible/bin/apply_control_center.py \"$@\"\n"
    tool(tmp_path / "bin", "setup-control-center", text)


def activate(tmp_path, env, body='swhcc_activate\nfor n in OLM_UTILS_IMAGE OLM_UTILS_CONTAINER CPD_CLI_MANAGE_WORKSPACE CPD_CLI_WORK_PATH IR_EXEC_ROUTE IR_EXEC_CONTAINER_NAME IR_SWHCC_KUBECONFIG; do print -r -- "$n=${(P)n}"; done\n'):
    (tmp_path / "run").mkdir(exist_ok=True)
    script = f'source "{REPO}/src/helpers/swhub_control_center_helpers.sh"\n{body}'
    return zsh(tmp_path, script, env=env, helpers=False)


def test_activate_in_the_pod_points_everything_at_the_sidecar(tmp_path):
    setup_control_center(tmp_path, stub=False)
    result = activate(tmp_path, pod_env(tmp_path))
    assert result.returncode == 0, result.stdout + result.stderr
    got = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line and not line.startswith("["))
    assert got == {"OLM_UTILS_IMAGE": PREMIUM, "OLM_UTILS_CONTAINER": "olm-utils-swhub-control-center",
                   "CPD_CLI_MANAGE_WORKSPACE": str(tmp_path / "swhcc"), "CPD_CLI_WORK_PATH": str(tmp_path / "swhcc/work"),
                   "IR_EXEC_ROUTE": "swhcc", "IR_EXEC_CONTAINER_NAME": "olm-utils-swhub-control-center",
                   "IR_SWHCC_KUBECONFIG": str(tmp_path / "kube/control.kubeconfig")}
    assert (tmp_path / "swhcc/work").is_dir()
    assert "pinned at sha256:abc123" in result.stdout
    # The probe ran once, through the sidecar route; the next step's activate reuses its result.
    assert len((tmp_path / "client.log").read_text().splitlines()) == 1
    assert activate(tmp_path, pod_env(tmp_path)).returncode == 0
    assert len((tmp_path / "client.log").read_text().splitlines()) == 1


def test_activate_refuses_a_stub_image_before_any_cluster_call(tmp_path):
    setup_control_center(tmp_path, stub=True)
    tool(tmp_path / "bin", "oc", '#!/bin/bash\necho "oc $*" >> "$FAKE_DIR/oc.log"\n')
    result = activate(tmp_path, pod_env(tmp_path))
    assert result.returncode != 0
    assert "stub" in result.stderr
    assert not (tmp_path / "oc.log").exists()
    assert not (tmp_path / "run/swhcc-probe.ok").exists()


@pytest.mark.parametrize("change,why", [
    ({"IR_SWHCC_IMAGE_SOURCE": ""}, "no Control Center sidecar"),
    ({"IR_SWHCC_IMAGE_SOURCE": "cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.ppc64le"}, "this config asks for"),
    ({"IR_SWHCC_MODE": "different"}, "set up for CONTROL_CLUSTER_MODE=different"),
])
def test_activate_refuses_a_slot_that_does_not_match(tmp_path, change, why):
    setup_control_center(tmp_path, stub=False)
    result = activate(tmp_path, pod_env(tmp_path, change))
    assert result.returncode != 0
    assert why in result.stderr, result.stderr
    assert not (tmp_path / "client.log").exists(), "nothing reached the sidecar"


def test_activate_and_ensure_image_stay_as_they_were_on_a_workstation(tmp_path):
    tool(tmp_path / "bin", "podman", '#!/bin/bash\necho "podman $*" >> "$FAKE_DIR/podman.log"\nexit 0\n')
    body = ('swhcc_activate\nswhcc_ensure_image\nprint -r -- "$CPD_CLI_WORK_PATH|$OLM_UTILS_CONTAINER|${IR_EXEC_ROUTE:-none}"\n')
    result = activate(tmp_path, {**CONTROL, "CONTROL_CPD_CLI_WORKSPACE": tmp_path / "ws"}, body)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().splitlines()[-1] == f"{tmp_path}/ws/work|olm-utils-swhub-control-center|none"
    assert (tmp_path / "podman.log").read_text() == f"podman image exists {PREMIUM}\n"


# --- 7. ir_swhcc_image_prepare -------------------------------------------------------------------------------
def prepare(tmp_path, env=None, source=PREMIUM):
    body = f'ir_swhcc_image_prepare install-runner-cpd-x cpd-x "{source}"\nprint -r -- "REPLY=$REPLY"\n'
    return zsh(tmp_path, body, env={"IBM_ENTITLEMENT_KEY": KEY, **(env or {})})


def jq_logger(tmp_path):
    """jq that logs its argv, then runs the real one: the key must reach it through env only."""
    real = shutil.which("jq", path="/usr/bin:/bin:/usr/sbin:/sbin")
    assert real, "jq is needed on the test PATH"
    tool(tmp_path / "bin", "jq", f'#!/bin/bash\nprintf "%s\\n" "$*" >> "$FAKE_DIR/jq.argv"\nexec {real} "$@"\n')


def test_image_prepare_pins_the_digest_and_keeps_the_key_out_of_argv(fake):
    jq_logger(fake)
    result = prepare(fake)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().splitlines()[-1] == f"REPLY={PINNED}"
    log = "\n".join(oc_log(fake))
    auth = base64.b64encode(f"cp:{KEY}".encode()).decode()
    assert KEY not in log and auth not in log and KEY not in result.stdout + result.stderr
    jq_argv = (fake / "jq.argv").read_text()
    assert jq_argv.count("\n") >= 2, "the auth file and the Secret both come from jq"
    assert KEY not in jq_argv and auth not in jq_argv
    assert (fake / "authfile_mode").read_text().strip() == "600"
    assert not Path((fake / "authfile_path").read_text().strip()).exists(), "the auth file is gone"
    assert json.loads((fake / "authfile_copy").read_text()) == {"auths": {"cp.icr.io": {"auth": auth}}}
    assert "--filter-by-os linux/amd64 -o json " + PREMIUM in log
    secret = next(json.loads(t) for t in applies(fake) if '"kind": "Secret"' in t or '"Secret"' in t)
    assert secret["metadata"]["name"] == "ir-cp-icr-pull" and secret["type"] == "kubernetes.io/dockerconfigjson"
    config = json.loads(base64.b64decode(secret["data"][".dockerconfigjson"]))
    assert config == {"auths": {"cp.icr.io": {"auth": auth}}}
    lines = oc_log(fake)
    link = lines.index("oc secrets link install-runner ir-cp-icr-pull --for=pull -n install-runner-cpd-x")
    assert any(l.startswith("oc create namespace install-runner-cpd-x") for l in lines[:link])
    assert any(l.startswith("oc create serviceaccount install-runner -n install-runner-cpd-x") for l in lines[:link])


@pytest.mark.parametrize("source,env,arch", [
    ("cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.s390x", {}, "s390x"),
    ("cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.ppc64le", {"IMAGE_ARCH": "amd64"}, "ppc64le"),
    ("cp.icr.io/cp/cpd/olm-utils-premium-v4:latest", {"IMAGE_ARCH": "ppc64le"}, "ppc64le"),   # no arch in the tag
    ("cp.icr.io/cp/cpd/olm-utils-premium-v4:latest", {}, "amd64"),
])
def test_image_prepare_pins_the_nodes_arch(fake, source, env, arch):
    result = prepare(fake, env, source=source)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().splitlines()[-1] == f"REPLY={PINNED}"
    assert any(f"--filter-by-os linux/{arch} -o json {source}" in line for line in oc_log(fake)), oc_log(fake)


def test_image_prepare_reads_the_digest_past_a_warning_from_oc(fake):
    (fake / "image_info_warns").touch()
    result = prepare(fake)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().splitlines()[-1] == f"REPLY={PINNED}"
    assert not list((fake / "tmp").glob("ir-swhcc-*")), "no temp file left"


def test_image_prepare_stops_on_a_failed_lookup(fake):
    (fake / "image_info_fails").touch()
    result = prepare(fake)
    assert result.returncode != 0
    assert "authentication required" in result.stderr
    assert not any("secrets link" in l for l in oc_log(fake))
    assert not Path((fake / "authfile_path").read_text().strip()).exists()
    assert not list((fake / "tmp").glob("ir-swhcc-*")), "no temp file left"


def test_image_prepare_needs_the_key(fake):
    result = prepare(fake, {"IBM_ENTITLEMENT_KEY": ""})
    assert result.returncode != 0 and "IBM_ENTITLEMENT_KEY" in result.stderr
    assert oc_log(fake) == []


def test_image_prepare_overrides(fake):
    mirrored = "registry.example.com/cp/cpd/olm-utils-premium-v4:5.4.0.amd64"
    result = prepare(fake, {"INSTALL_RUNNER_SWHCC_IMAGE": mirrored}, source=mirrored)
    assert result.returncode == 0 and result.stdout.strip().endswith(f"REPLY={mirrored}")
    assert oc_log(fake) == []
    missing = prepare(fake, {"INSTALL_RUNNER_SWHCC_IMAGE": mirrored, "INSTALL_RUNNER_SWHCC_PULL_SECRET": "mine"}, mirrored)
    assert missing.returncode != 0 and "is not in install-runner-cpd-x" in missing.stderr
    (fake / "secret_mine").touch()
    linked = prepare(fake, {"INSTALL_RUNNER_SWHCC_IMAGE": mirrored, "INSTALL_RUNNER_SWHCC_PULL_SECRET": "mine"}, mirrored)
    assert linked.returncode == 0
    assert "oc secrets link install-runner mine --for=pull -n install-runner-cpd-x" in oc_log(fake)
    assert not any("image info" in l for l in oc_log(fake))


# --- 8. pod image and preflight ------------------------------------------------------------------------------
@pytest.mark.parametrize("env,expected", [
    ({"CONTROL_OLM_UTILS_IMAGE": "cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.ppc64le", "CONTROL_IMAGE_ARCH": "ppc64le",
      "IMAGE_ARCH": "amd64"}, PREMIUM),
    ({"CONTROL_OLM_UTILS_IMAGE": PREMIUM, "CONTROL_IMAGE_ARCH": "amd64"}, PREMIUM),
    ({"CONTROL_OLM_UTILS_IMAGE": PREMIUM, "CONTROL_IMAGE_ARCH": "amd64", "IMAGE_ARCH": "s390x"},
     "cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.s390x"),
    ({"CONTROL_OLM_UTILS_IMAGE": PREMIUM, "INSTALL_RUNNER_SWHCC_IMAGE": "reg/x:1"}, "reg/x:1"),
])
def test_pod_image_takes_the_install_cluster_arch(tmp_path, env, expected):
    result = zsh(tmp_path, f'source "{REPO}/src/helpers/swhub_control_center_image.sh"\nswhcc_pod_image\n', env, helpers=False)
    assert result.stdout.strip() == expected, result.stderr


def preflight(tmp_path, chain=SWHCC_CHAIN, env=None, **changes):
    vars_path = vars_file(tmp_path, **changes)
    tool(tmp_path / "bin", "oc", '#!/bin/bash\nexit 0\n')
    return hook(tmp_path, "preflight", chain, {"ENV_TARGET_FILE": vars_path, "STG_CLASS_BLOCK": "blk",
                                               "STG_CLASS_FILE": "fil", "OCP_URL": "https://api.x:6443", **(env or {})})


def test_preflight_passes_a_good_config(tmp_path):
    result = preflight(tmp_path)
    assert result.returncode == 0, result.stderr
    assert "[ERROR]" not in result.stderr
    assert "premium tag 5.4.0.amd64 moves" in result.stderr


@pytest.mark.parametrize("changes,error", [
    ({"IBM_ENTITLEMENT_KEY": ""}, "IBM_ENTITLEMENT_KEY is empty"),
    ({"PATCH_ID": ""}, "PATCH_ID is empty"),
    ({"CONTROL_OLM_UTILS_IMAGE": "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.amd64"}, "is not olm-utils-premium-v4"),
    ({"CONTROL_CLUSTER_MODE": "different", "CONTROL_OC_LOGIN": "oc login --server=https://api.cc:6443 --token="},
     "has no token or username and password"),
    ({"CONTROL_CLUSTER_MODE": "different", "CONTROL_OC_LOGIN": "oc login --server=https://api.cc:6443 --username=u"},
     "has no token or username and password"),
])
def test_preflight_errors(tmp_path, changes, error):
    result = preflight(tmp_path, **changes)
    assert result.returncode != 0
    assert error in result.stderr, result.stderr


def test_preflight_takes_a_mirrored_image_pinned_by_digest(tmp_path):
    mirrored = "registry.example.com/cp/cpd/olm-utils-premium-v4@sha256:abc123"
    result = preflight(tmp_path, env={"INSTALL_RUNNER_SWHCC_IMAGE": mirrored})
    assert result.returncode == 0, result.stderr
    standard = preflight(tmp_path, env={"INSTALL_RUNNER_SWHCC_IMAGE": "registry.example.com/cp/cpd/olm-utils-v4@sha256:abc"})
    assert standard.returncode != 0 and "is not olm-utils-premium-v4" in standard.stderr


@pytest.mark.parametrize("changes,env,warning", [
    ({"CONTROL_CLUSTER_MODE": "different"}, {}, "No CONTROL_OCP_CA_FILE"),
    ({"OCP_USERNAME": "", "OCP_PASSWORD": ""}, {}, "Token-only login"),
    ({"CONTROL_AUTODETECT_ROTATE_API_KEYS": "true"}, {}, "revokes instance API keys again"),
    ({"CONTROL_ROUTE_PUBLIC_IP": ""}, {}, "CONTROL_ROUTE_PUBLIC_IP"),
    ({}, {"OCP_URL": ""}, "kubernetes.default.svc"),
])
def test_preflight_warnings(tmp_path, changes, env, warning):
    result = preflight(tmp_path, env=env, **changes)
    assert result.returncode == 0, result.stderr
    assert warning in result.stderr, result.stderr


def test_preflight_quiet_where_nothing_applies(tmp_path):
    result = preflight(tmp_path, CONTROL_CLUSTER_MODE="different", CONTROL_OCP_CA_FILE="/ca.crt",
                       CONTROL_OC_LOGIN="oc login --server=https://api.cc:6443 --username=u --password=p")
    assert result.returncode == 0, result.stderr
    for text in ("CONTROL_OCP_CA_FILE", "Token-only", "revokes", "private address", "kubernetes.default.svc"):
        assert text not in result.stderr, text


@pytest.mark.parametrize("ip,line,read", [
    ("", '# export CONTROL_ROUTE_PUBLIC_IP=""', ""),
    ("203.0.113.8", 'export CONTROL_ROUTE_PUBLIC_IP="203.0.113.8"', "203.0.113.8"),
])
def test_route_public_ip_is_a_commented_knob_in_the_generated_vars_file(tmp_path, ip, line, read):
    """The Control Center vars file both generators write (the notebook and 0_swhub_control_center_generate_config.sh)
    shows CONTROL_ROUTE_PUBLIC_IP commented at its default, and the runner launch reads it from there."""
    from helpers import swhub_control_center_config_render as render
    from helpers import cp4d_id_options_templates as options

    assert {"key": "CONTROL_ROUTE_PUBLIC_IP", "value": ""} in options.default_swhub_control_center_setup
    text = render.render_swhcc_vars({"route_public_ip": ip} if ip else None)
    assert [l for l in text.splitlines() if "export CONTROL_ROUTE_PUBLIC_IP" in l] == [line]
    put(tmp_path, "cp4d_config/cpd_vars.sh", "export OCP_URL=https://api.x:6443\n")
    path = put(tmp_path, "cp4d_config/swhub_control_center/swhub_control_center_vars.sh", text)
    result = zsh(tmp_path, f'source "{REPO}/src/helpers/swhub_control_center_image.sh"\n'
                           f'swhcc_runner_values "{path}"\nprint -r -- "ip=${{SWHCC_RV[CONTROL_ROUTE_PUBLIC_IP]}}"\n', helpers=False)
    assert result.stdout.strip() == f"ip={read}", result.stderr


def test_preflight_needs_the_vars_file_only_when_control_center_runs(tmp_path):
    tool(tmp_path / "bin", "oc", '#!/bin/bash\nexit 0\n')
    env = {"CONFIG_DIR": tmp_path / "empty", "STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil"}
    result = hook(tmp_path, "preflight", FULL_CHAIN, {**env, "INSTALL_SWHUB_CONTROL_CENTER": "true"})
    assert result.returncode != 0
    assert "0_swhub_control_center_generate_config.sh --from-cpd" in result.stderr
    assert hook(tmp_path, "preflight", FULL_CHAIN, env).returncode == 0
    assert hook(tmp_path, "preflight", STEP4_CHAIN, {**env, "INSTALL_SWHUB_CONTROL_CENTER": "true"}).returncode == 0


# --- 9. helpers ----------------------------------------------------------------------------------------------
def test_cluster_facts_use_ocp_url_in_the_pod(tmp_path):
    tool(tmp_path / "bin", "oc", textwrap.dedent("""\
        #!/bin/bash
        case "$*" in
          "whoami --show-server") echo https://kubernetes.default.svc ;;
          "get route oauth-openshift"*) echo oauth-openshift.apps.x.example.com ;;
        esac
        """))
    body = f'source "{REPO}/src/helpers/swhub_control_center_api_helpers.sh"\nswhcc_cluster_facts\nprint -r -- "$SWHCC_API_ENDPOINT|$SWHCC_CLUSTER_NAME"\n'
    pod = zsh(tmp_path, body, {"IR_IN_RUNNER": "1", "OCP_URL": "https://api.itz-a.example.com:6443/"}, helpers=False)
    assert pod.stdout.strip().splitlines()[-1] == "https://api.itz-a.example.com:6443|itz-a", pod.stderr
    local = zsh(tmp_path, body, {"OCP_URL": "https://api.itz-a.example.com:6443/"}, helpers=False)
    assert local.stdout.strip().splitlines()[-1] == "https://kubernetes.default.svc|kubernetes", local.stderr


def only_tools(tmp_path, name, tools):
    """A bin folder holding just these fakes and the basics the helpers call."""
    bin_dir = tmp_path / name
    for basic in ("awk", "grep", "tail", "cat", "cut", "head"):
        target = next(Path(p) / basic for p in ("/usr/bin", "/bin") if (Path(p) / basic).exists())
        (bin_dir).mkdir(parents=True, exist_ok=True)
        (bin_dir / basic).symlink_to(target)
    for tool_name, text in tools.items():
        tool(bin_dir, tool_name, text)
    return bin_dir


@pytest.mark.parametrize("hasher", ["sha256sum", "shasum"])
def test_h_sha256_works_with_either_tool(tmp_path, hasher):
    impl = (f"#!{sys.executable}\nimport hashlib, sys\nargs = [a for a in sys.argv[1:] if a not in ('-a', '256')]\n"
            "data = open(args[0], 'rb').read() if args else sys.stdin.buffer.read()\n"
            "print(hashlib.sha256(data).hexdigest() + '  ' + (args[0] if args else '-'))\n")
    bin_dir = only_tools(tmp_path, f"bin-{hasher}", {hasher: impl})
    target = put(tmp_path, "server.py", "print('hi')\n")
    script = f'source "{REPO}/src/helpers/common_helpers.sh"\nh_sha256 "{target}"\n'
    result = subprocess.run(["/bin/zsh", "-f", "-c", script], capture_output=True, text=True,
                            env={"PATH": str(bin_dir), "_CP4D_REPO_ROOT": str(REPO)}, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [hashlib.sha256(target.read_bytes()).hexdigest()]


@pytest.mark.parametrize("present,expected", [
    (("getent", "python3", "dig"), "10.0.0.1"),
    (("python3", "dig"), "10.0.0.2"),
    (("dig",), "10.0.0.3"),
    ((), ""),
])
def test_resolve_ipv4_order(tmp_path, present, expected):
    fakes = {"getent": "#!/bin/sh\necho '10.0.0.1  STREAM host'\n", "python3": "#!/bin/sh\necho 10.0.0.2\n",
             "dig": "#!/bin/sh\necho alias.example.com.\necho 10.0.0.3\n"}
    bin_dir = only_tools(tmp_path, "bin-resolve", {k: v for k, v in fakes.items() if k in present})
    script = (f'export _CP4D_REPO_ROOT="{REPO}"\nsource "{REPO}/src/helpers/swhub_control_center_api_helpers.sh" 2>/dev/null\n'
              'print -r -- "[$(swhcc_resolve_ipv4 host.example.com)]"\n')
    result = subprocess.run(["/bin/zsh", "-f", "-c", script], capture_output=True, text=True,
                            env={"PATH": str(bin_dir), "HOME": str(tmp_path)}, check=False)
    assert result.stdout.strip().splitlines()[-1] == f"[{expected}]", result.stderr


def indicator_branch():
    """The private-route block of the indicator toggle, to run with stand-ins for what it calls."""
    text = (REPO / CC_DIR / "x_debug_toggle_other_workloads_indicator.sh").read_text()
    return re.search(r"^    if swhcc_route_is_private .*?^    else\n", text, re.S | re.M).group(0) + "        register\n    fi\n"


@pytest.mark.parametrize("env,mapped", [
    ({"IR_IN_RUNNER": "1"}, None),
    ({"IR_IN_RUNNER": "1", "CONTROL_ROUTE_PUBLIC_IP": "203.0.113.9"}, "203.0.113.9"),
    ({}, "198.51.100.4"),
])
def test_indicator_private_route_in_the_pod(tmp_path, env, mapped):
    tool(tmp_path / "bin", "dig", '#!/bin/sh\necho "dig $*" >> "$FAKE_DIR/calls"\necho 198.51.100.4\n')
    script = textwrap.dedent(f"""\
        h_warn() {{ print -r -- "[WARN] $*" >&2; }}
        h_die() {{ print -r -- "[ERROR] $*" >&2; exit 1; }}
        swhcc_route_is_private() {{ return 0; }}
        swhcc_with_route_mapping() {{ print -r -- "mapped $1" >> "$FAKE_DIR/calls"; }}
        register() {{ print -r -- register >> "$FAKE_DIR/calls"; }}
        HOST=cpd-x.apps.example.com PROJECT=p NAME=n ENV_TARGET_FILE=/x/swhub_control_center_vars.sh
        """) + "if true; then\n" + indicator_branch() + "fi\n"
    result = zsh(tmp_path, script, env, helpers=False)
    calls = (tmp_path / "calls").read_text().splitlines() if (tmp_path / "calls").exists() else []
    if mapped is None:
        assert result.returncode == 1
        assert "not registered" in result.stderr and "x_debug_toggle_other_workloads_indicator.sh on" in result.stderr
        assert calls == [], "no lookup and no mapping in the pod"
    else:
        assert result.returncode == 0, result.stderr
        assert f"mapped {mapped}" in calls
        assert any(c.startswith("dig") for c in calls) == (mapped == "198.51.100.4")


def cc_sandbox():
    return make_sandbox(extra=[CC_DIR])


SWHCC_SANDBOX_VARS = textwrap.dedent("""\
    _d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    source "${_d}/../cpd_vars.sh"
    export CONTROL_CLUSTER_MODE="same"
    export CONTROL_OCP_URL="${OCP_URL}"
    export CONTROL_IMAGE_ARCH="amd64"
    export CONTROL_OC_LOGIN="oc login --server=${OCP_URL} --token=t"
    export CONTROL_CPDM_OC_LOGIN="cpd-cli manage login-to-ocp --server=${OCP_URL} --token=t"
    export CONTROL_OLM_UTILS_IMAGE="cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.amd64"
    export CONTROL_OLM_UTILS_CONTAINER="olm-utils-swhub-control-center"
    export CONTROL_CPD_CLI_WORKSPACE="${HOME}/cpd-cli-swhub-control-center"
    export CONTROL_PROJECT_OPERATORS="cc-operators"
    export CONTROL_PROJECT_OPERANDS="cc"
    export CONTROL_STG_CLASS_BLOCK="blk"
    """)


def test_private_route_script_refuses_in_the_pod():
    with cc_sandbox() as box:
        box.write_config("cpd", ocp_url=SANDBOX_URL, extra={"VERSION": "5.4.0"})
        put(box.repo, "configs/cp4d_config/swhub_control_center/swhub_control_center_vars.sh", SWHCC_SANDBOX_VARS)
        result = box.run_script(f"{CC_DIR}/x_debug_register_private_route_instances.sh", env={"IR_IN_RUNNER": "1"})
    assert result.returncode == 1
    assert "workstation only" in result.stderr
    assert box.calls("oc") == [] and box.calls("podman") == []


# --- 10. ENV_TARGET map, the entry point, K5 -----------------------------------------------------------------
def test_control_center_chain_is_a_cpd_entry_point_with_its_own_target(tmp_path):
    result = zsh(tmp_path, f'ir_install_for_chain {SWHCC_CHAIN}; print -r -- "$REPLY"\n'
                           f'_ir_chain_env_target cpd {SWHCC_CHAIN}; print -r -- "$REPLY"\n'
                           f'_ir_chain_env_target cpd {FULL_CHAIN}; print -r -- "[$REPLY]"\n')
    assert result.stdout.splitlines() == ["cpd", "swhub_control_center", "[]"], result.stderr
    text = (REPO / SWHCC_CHAIN).read_text()
    assert text.count('ir_dispatch "$@"') == 1
    assert text.index("env_bootstrap.sh") < text.index('ir_dispatch "$@"') < text.index("h_steps_parse")


# The runner tests' fake oc, plus what the sidecar launch asks of it.
HANDOFF_OC = RUNNER_FAKE_OC.replace('case "$args" in\n', 'case "$args" in\n' + textwrap.dedent("""\
      "image info"*) echo '{"digest":"sha256:abc123"}' ;;
      "create namespace"*|"create serviceaccount"*) printf 'apiVersion: v1\\nkind: Namespace\\nmetadata:\\n  name: %s\\n' "$3" ;;
      "label --local"*) cat ;;
      "secrets link"*|"rollout status"*) ;;
    """), 1)


def test_handoff_of_the_control_center_chain():
    """The standalone Control Center chain goes to the cpd slot with its sidecar, loads swhub_control_center in
    the pod, and waits for the new pod before staging into it."""
    with make_sandbox(extra=SANDBOX_EXTRA + [CC_DIR]) as box:
        box.fake = box.root / "fake"
        box.fake.mkdir()
        (box.bin / "oc").write_text(HANDOFF_OC)
        subprocess.run(["git", "init", "-q"], cwd=box.repo, env=box.env(), check=True, capture_output=True)
        box.write_config("cpd", ocp_url=SANDBOX_URL, extra={
            "INSTALL_RUN_MODE": "cluster", "PROJECT_CPD_INST_OPERANDS": "cpd-op", "STG_CLASS_BLOCK": "blk",
            "STG_CLASS_FILE": "fil", "VERSION": "5.4.0", "PATCH_ID": "8", "IMAGE_ARCH": "amd64",
            "IBM_ENTITLEMENT_KEY": KEY, "OCP_USERNAME": "kubeadmin", "OCP_PASSWORD": "pw",
            "INSTALL_RUNNER_CPD_CLI_URL": "https://x/cli.tgz"})
        put(box.repo, "configs/cp4d_config/swhub_control_center/swhub_control_center_vars.sh", SWHCC_SANDBOX_VARS)
        chain = box.repo / SWHCC_CHAIN
        chain.write_text(STAND_IN_CHAIN)
        chain.chmod(0o755)
        (box.fake / "state").write_text("completed\n")
        result = box.run_script(SWHCC_CHAIN, env={"FAKE_DIR": box.fake}, timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "CHAIN-RAN-LOCALLY" not in result.stdout
        assert box.calls("podman") == [] and box.calls("cpd-cli") == []
        run_env = (box.fake / "run.env").read_text()
        assert "export ENV_TARGET='swhub_control_center'" in run_env
        assert f"IR_CHAIN='{SWHCC_CHAIN}'" in run_env
        docs = [d for d in yaml.safe_load_all((box.fake / "applied.yaml").read_text()) if d]
        sts = next(d for d in docs if d.get("kind") == "StatefulSet")
        assert [c["name"] for c in sts["spec"]["template"]["spec"]["containers"]] == ["runner", "swhcc"]
        log = (box.fake / "oc.log").read_text().splitlines()
        rollout = next(i for i, l in enumerate(log) if l.startswith("oc rollout status sts/install-runner"))
        first_stage = next(i for i, l in enumerate(log) if "tar -xf" in l)
        assert rollout < first_stage
        assert KEY not in "\n".join(log)
        staged = box.fake / "pod/configs/cp4d_config/swhub_control_center/swhub_control_center_vars.sh"
        assert staged.exists(), "the vars file goes with configs/cp4d_config"


# --- C5: Control Center on a cluster of its own, from a vars file written with --empty ---------------------------
STORAGE_CLASSES = json.dumps({"items": [
    {"metadata": {"name": "ocs-rbd", "annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}},
    {"metadata": {"name": "ocs-fs"}}]})
EMPTY_HANDOFF_OC = HANDOFF_OC.replace('case "$args" in\n', 'case "$args" in\n'
                                      '  "get storageclass -o json"*) cat "$d/storageclasses.json" ;;\n', 1)


def empty_vars_text():
    """What 0_swhub_control_center_generate_config.sh --empty writes, with the login and key filled in: no
    cpd_vars.sh behind it, so no OLM_UTILS_IMAGE, STG_CLASS_*, INSTALL_OPTIONS_FILE or OCP_URL."""
    from helpers import swhub_control_center_config_render as render

    text = render.render_swhcc_vars({"has_cpd_vars": False, "cluster_mode": "different", "patch_id": "8",
                                     "ocp_url": "https://api.cc.example.com:6443", "ocp_token": "cc-token",
                                     "stg_block": "cc-blk", "stg_file": "cc-fil", "oauth_secret": "s"})
    assert "cpd_vars.sh\"" not in text and "OLM_UTILS_IMAGE=\"icr.io" not in text
    return text.replace('export IBM_ENTITLEMENT_KEY=""', f'export IBM_ENTITLEMENT_KEY="{KEY}"')


def empty_box(box, storage_classes=STORAGE_CLASSES):
    box.fake = box.root / "fake"
    box.fake.mkdir()
    (box.bin / "oc").write_text(EMPTY_HANDOFF_OC)
    (box.fake / "storageclasses.json").write_text(storage_classes)
    subprocess.run(["git", "init", "-q"], cwd=box.repo, env=box.env(), check=True, capture_output=True)
    put(box.repo, "configs/cp4d_config/swhub_control_center/swhub_control_center_vars.sh", empty_vars_text())
    for rel in (SWHCC_CHAIN, FULL_CHAIN):
        chain = box.repo / rel
        chain.parent.mkdir(parents=True, exist_ok=True)
        chain.write_text(STAND_IN_CHAIN)
        chain.chmod(0o755)
    (box.fake / "state").write_text("completed\n")
    (box.fake / "image_missing").touch()
    # The Software Hub cluster, where the pod runs, comes from the shell: the vars file names only Control Center's.
    return {"FAKE_DIR": box.fake, "OCP_URL": SANDBOX_URL, "OC_LOGIN": "true", "INSTALL_RUN_MODE": "cluster",
            "INSTALL_RUNNER_CPD_CLI_URL": "https://x/cli.tgz"}


def test_control_center_from_an_empty_vars_file_launches_without_cp4d_values():
    """C5: the standalone Control Center chain in different mode needs no CP4D storage classes, options file or
    olm-utils image: the runner's base image comes from the vars file's release, its volume from the cluster's
    default storage class."""
    with make_sandbox(extra=SANDBOX_EXTRA + [CC_DIR]) as box:
        env = empty_box(box)
        result = box.run_script(SWHCC_CHAIN, env=env, timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "STG_CLASS_BLOCK and STG_CLASS_FILE must be set" not in result.stderr
        assert "OLM_UTILS_IMAGE is not set" not in result.stderr
        assert "the cluster's default storage class ocs-rbd" in result.stdout
        docs = [d for d in yaml.safe_load_all((box.fake / "applied.yaml").read_text()) if d]
        build = next(d for d in docs if d["kind"] == "BuildConfig")
        args = {a["name"]: a["value"] for a in build["spec"]["strategy"]["dockerStrategy"]["buildArgs"]}
        assert args["BASE_IMAGE"] == "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8"
        pvc = next(d for d in docs if d["kind"] == "PersistentVolumeClaim")
        assert pvc["spec"]["storageClassName"] == "ocs-rbd"
        sts = next(d for d in docs if d.get("kind") == "StatefulSet")
        assert [c["name"] for c in sts["spec"]["template"]["spec"]["containers"]] == ["runner", "swhcc"]
        assert box.calls("podman") == [] and box.calls("cpd-cli") == []


def test_install_runner_storage_class_still_wins_for_control_center():
    with make_sandbox(extra=SANDBOX_EXTRA + [CC_DIR]) as box:
        env = empty_box(box)
        result = box.run_script(SWHCC_CHAIN, env={**env, "INSTALL_RUNNER_STORAGE_CLASS": "picked"}, timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "default storage class" not in result.stdout
        docs = [d for d in yaml.safe_load_all((box.fake / "applied.yaml").read_text()) if d]
        assert next(d for d in docs if d["kind"] == "PersistentVolumeClaim")["spec"]["storageClassName"] == "picked"


def test_no_default_storage_class_still_stops_control_center_with_the_runner_hint():
    with make_sandbox(extra=SANDBOX_EXTRA + [CC_DIR]) as box:
        env = empty_box(box, storage_classes=json.dumps({"items": [{"metadata": {"name": "ocs-fs"}}]}))
        result = box.run_script(SWHCC_CHAIN, env=env, timeout=120)
        assert result.returncode != 0
        assert "No storage class for the runner's volume: set INSTALL_RUNNER_STORAGE_CLASS." in result.stderr
        assert not (box.fake / "applied.yaml").exists(), "nothing was changed"


def test_the_cp4d_chains_stay_strict_with_the_same_config():
    """The full chain on the same config (no cpd_vars.sh values) is still refused for each missing value."""
    with make_sandbox(extra=SANDBOX_EXTRA + [CC_DIR]) as box:
        env = empty_box(box)
        result = box.run_script(FULL_CHAIN, env={**env, "ENV_TARGET": "swhub_control_center"}, timeout=120)
        assert result.returncode != 0
        assert "STG_CLASS_BLOCK and STG_CLASS_FILE must be set." in result.stderr
        assert "No storage class for the runner's volume" in result.stderr
        assert "default storage class" not in result.stdout
        assert not (box.fake / "applied.yaml").exists()


@pytest.mark.parametrize("chain,expected", [
    (SWHCC_CHAIN, ["base_image=icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8", "storage_class=default"]),
    (FULL_CHAIN, []), (STEP4_CHAIN, []), ("", [])])
def test_runner_inputs_only_for_the_control_center_chain(tmp_path, chain, expected):
    result = hook(tmp_path, "runner-inputs", chain, {"VERSION": "5.4.0", "PATCH_ID": "8"})
    assert result.returncode == 0, result.stderr
    assert result.stdout.split() == expected
    full = hook(tmp_path, "runner-inputs", SWHCC_CHAIN, {"VERSION": "5.4.0", "OLM_UTILS_IMAGE": "x:1", "STG_CLASS_BLOCK": "b"})
    assert full.stdout == "", "a vars file that has them (from cpd_vars.sh) keeps its own"


# --- 11. the notice ------------------------------------------------------------------------------------------
NOTICE_STUBS = """
swhcc_cluster_verified() { [[ -e "$FAKE_DIR/verified" ]]; }
swhcc_cluster_auto_verify() { return 1; }
swhcc_cluster_oauth_url() { REPLY="https://oauth.apps.x/oauth/authorize?client_id=cc&state=s1"; }
"""


@pytest.mark.parametrize("wait_ok", [True, False])
def test_notice_is_written_at_the_wait_and_removed_on_success(tmp_path, wait_ok):
    run = tmp_path / "run"
    run.mkdir()
    approve = 'touch "$FAKE_DIR/verified"; return 0' if wait_ok else "return 1"
    body = (f'source "{REPO}/src/helpers/swhub_control_center_api_helpers.sh"\n{NOTICE_STUBS}'
            f'h_wait_for() {{ [[ -s "$IR_RUN_DIR/notice" ]] && cp "$IR_RUN_DIR/notice" "$FAKE_DIR/seen"; {approve}; }}\n'
            'SWHCC_CLUSTER_ID=c1\nif swhcc_wait_cluster_verified 600; then print ok; else print waited-out; fi\n')
    result = zsh(tmp_path, body, {"IR_IN_RUNNER": "1", "IR_RUN_DIR": run, "CONTROL_CENTER_URL": "https://cpd-cc.apps.x"},
                 helpers=False)
    assert result.returncode == 0, result.stderr
    seen = (tmp_path / "seen").read_text()
    assert seen.startswith("Control Center cluster not verified: sign in to https://cpd-cc.apps.x, then open https://oauth.apps.x/")
    assert result.stdout.strip().splitlines()[-1] == ("ok" if wait_ok else "waited-out")
    assert (run / "notice").exists() == (not wait_ok)


def test_no_notice_on_a_workstation_or_when_already_verified(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    (run / "notice").write_text("old\n")
    body = (f'source "{REPO}/src/helpers/swhub_control_center_api_helpers.sh"\n{NOTICE_STUBS}'
            'SWHCC_CLUSTER_ID=c1\nswhcc_wait_cluster_verified 0 || true\n')
    zsh(tmp_path, body, {"IR_RUN_DIR": run, "CONTROL_CENTER_URL": "https://cc"}, helpers=False)
    assert (run / "notice").read_text() == "old\n", "a workstation run never writes or removes it"
    (tmp_path / "verified").touch()
    result = zsh(tmp_path, body, {"IR_IN_RUNNER": "1", "IR_RUN_DIR": run, "CONTROL_CENTER_URL": "https://cc"}, helpers=False)
    assert result.returncode == 0
    assert not (run / "notice").exists(), "a verified cluster clears a stale notice"


def test_status_shows_the_notice(tmp_path):
    items = {"items": [{"metadata": {"name": "ir-status", "namespace": "install-runner-cpd-x"},
                        "data": {"slot": "cpd-x", "state": "running", "step": "-", "attempts": "1", "collected": "no",
                                 "heartbeat": str(int(time.time())), "warned": "-",
                                 "notice": "Control Center cluster not verified: sign in to https://cc, then open https://o"}}]}
    tool(tmp_path / "bin", "oc", f"#!/bin/bash\ncat <<'EOF'\n{json.dumps(items)}\nEOF\n")
    result = zsh(tmp_path, "ir_status")
    assert result.returncode == 0, result.stderr
    assert "cpd-x: Control Center cluster not verified: sign in to https://cc, then open https://o" in result.stderr


# --- 12. step 1.0 checks the pull secret first ---------------------------------------------------------------
PREP_OC = r"""#!/bin/bash
echo "oc $*" >> "$FAKE_DIR/oc.log"
case "$*" in
  "whoami --show-server") echo "$OCP_URL" ;;
  "whoami") echo tester ;;
  "get secret pull-secret -n openshift-config"*) printf '%s' "$(cat "$FAKE_DIR/pull_secret_auths")" | base64 ;;
  "get project cc"*) exit 1 ;;
  "get secret"*) echo '{"metadata":{"name":"pull-secret"}}' ;;
esac
exit 0
"""
PREP_PODMAN = r"""#!/bin/bash
echo "podman $*" >> "$FAKE_DIR/podman.log"
case "$*" in
  inspect*) echo "cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.amd64" ;;
  *"oc whoami --show-server"*) echo "$OCP_URL" ;;
esac
exit 0
"""


@pytest.mark.parametrize("auths,passes,mode", [('{"auths":{"quay.io":{}}}', False, "same"),
                                               ('{"auths":{"quay.io":{}}}', False, "different"),
                                               ('{"auths":{"quay.io":{},"cp.icr.io":{"auth":"x"}}}', True, "same")])
def test_prep_checks_cp_icr_io_before_creating_projects(auths, passes, mode):
    with cc_sandbox() as box:
        fake = box.root / "fake"
        fake.mkdir()
        (fake / "pull_secret_auths").write_text(auths)
        (box.bin / "oc").write_text(PREP_OC)
        (box.bin / "podman").write_text(PREP_PODMAN)
        box.write_config("cpd", ocp_url=SANDBOX_URL, extra={
            "VERSION": "5.4.0", "PATCH_ID": "8", "PROJECT_LICENSE_SERVICE": "lic", "PROJECT_SCHEDULING_SERVICE": "sch",
            "PROJECT_CPD_INST_OPERATORS": "cpd-ops", "PROJECT_CPD_INST_OPERANDS": "cpd"})
        put(box.repo, "configs/cp4d_config/swhub_control_center/swhub_control_center_vars.sh",
            SWHCC_SANDBOX_VARS.replace('CONTROL_CLUSTER_MODE="same"', f'CONTROL_CLUSTER_MODE="{mode}"'))
        result = box.run_script(f"{CC_DIR}/1.0_swhub_control_center_prep.sh", env={"FAKE_DIR": fake}, timeout=120)
        log = (fake / "oc.log").read_text()
    if passes:
        assert "oc new-project cc-operators" in log, result.stdout + result.stderr
    else:
        assert result.returncode != 0
        assert "has no cp.icr.io login" in result.stderr, result.stdout + result.stderr
        assert "new-project" not in log and "apply" not in log, "nothing on the cluster changed"
        # 1.1 changes the Software Hub cluster's secret, so it is the fix only in same mode.
        assert ("Add the entitlement key first: 1_global_pull_secret" in result.stderr) == (mode == "same")
        assert ("while logged in to" in result.stderr) == (mode == "different")


# --- 13. the Control Center session in the pod, and switching clusters in different mode ---------------------
# oc for these: `login` writes the server into $KUBECONFIG, as oc does; whoami reads it back. Every call notes
# the KUBECONFIG it ran with, so a call on the wrong cluster shows.
SWITCH_OC = r"""#!/bin/bash
echo "oc $* KUBECONFIG=${KUBECONFIG:-}" >> "$FAKE_DIR/switch_oc.log"
case "$1" in
  login)
      server=""; for a in "$@"; do case "$a" in --server=*) server="${a#--server=}" ;; esac; done
      printf 'server: %s\n' "$server" > "$KUBECONFIG" ;;
  whoami)
      [ -s "$KUBECONFIG" ] || exit 1
      [ "${2:-}" = --show-server ] && sed -n 's/^server: //p' "$KUBECONFIG" ;;
  get) echo "pod/zen-core-api-abc" ;;
  exec) echo "10.1.2.3 STREAM cpd.apps.example.com" ;;
esac
exit 0
"""
CC_URL = "https://api.cc.example.com:6443"


def switch_env(tmp_path, mode, extra=None):
    """A pod step that never ran swhcc_activate (cluster-admins, the indicator): no IR_SWHCC_KUBECONFIG."""
    tool(tmp_path / "bin", "oc", SWITCH_OC)
    chain = put(tmp_path, "chain.kubeconfig", "server: https://api.swh.example.com:6443\n", mode=0o600)
    (tmp_path / "kube").mkdir(exist_ok=True)
    return {**CONTROL, "CONTROL_CLUSTER_MODE": mode, "CONTROL_OCP_URL": CC_URL,
            "CONTROL_OC_LOGIN": f"oc login --server={CC_URL} --token=t", "IR_IN_RUNNER": "1",
            "IR_SWHCC_KUBE_DIR": tmp_path / "kube", "IR_CHAIN_KUBECONFIG": chain, "KUBECONFIG": chain,
            "OC_LOGIN": 'export KUBECONFIG="${IR_CHAIN_KUBECONFIG}" K8S_AUTH_KUBECONFIG="${IR_CHAIN_KUBECONFIG}"; oc whoami >/dev/null',
            **(extra or {})}


def switch_run(tmp_path, env, body):
    script = f'source "{REPO}/src/helpers/swhub_control_center_api_helpers.sh"\n{textwrap.dedent(body)}'
    return zsh(tmp_path, script, env=env, helpers=False)


def switch_calls(tmp_path):
    path = tmp_path / "switch_oc.log"
    return path.read_text().splitlines() if path.exists() else []


@pytest.mark.parametrize("mode", ["same", "different"])
def test_oc_login_in_the_pod_without_activate(tmp_path, mode):
    """toggle_cluster_admins.sh calls swhcc_oc_login straight away: the control file comes from the slot's env."""
    result = switch_run(tmp_path, switch_env(tmp_path, mode),
                        'swhcc_oc_login\nprint -r -- "K=$KUBECONFIG|$K8S_AUTH_KUBECONFIG|$IR_SWHCC_KUBECONFIG"\n')
    assert result.returncode == 0, result.stdout + result.stderr
    control = tmp_path / "kube/control.kubeconfig"
    assert result.stdout.strip().splitlines()[-1] == f"K={control}|{control}|{control}"
    assert stat.S_IMODE(control.stat().st_mode) == 0o600
    logins = [c for c in switch_calls(tmp_path) if c.startswith("oc login")]
    assert len(logins) == (1 if mode == "different" else 0)


def test_oc_login_in_a_pod_without_the_sidecar_says_so(tmp_path):
    env = switch_env(tmp_path, "same")
    del env["IR_SWHCC_KUBE_DIR"]
    result = switch_run(tmp_path, env, "swhcc_oc_login\n")
    assert result.returncode != 0
    assert "has no Control Center sidecar" in result.stderr


@pytest.mark.parametrize("mode", ["same", "different"])
def test_zen_core_api_calls_run_on_the_control_center_cluster(tmp_path, mode):
    """In different mode zen-core-api is on the other cluster: its lookups and patches go there, the command
    in between and whatever follows run on the Software Hub cluster again. One login does for all of it."""
    env = switch_env(tmp_path, mode)
    result = switch_run(tmp_path, env, """\
        stub() { print -r -- "STUB=$KUBECONFIG" >> "$FAKE_DIR/stub.log"; }
        swhcc_route_is_private cpd.apps.example.com && print -r -- PRIVATE
        print -r -- "AFTER_LOOKUP=$KUBECONFIG"
        swhcc_with_route_mapping 203.0.113.7 cpd.apps.example.com -- stub
        print -r -- "FINAL=$KUBECONFIG"
        """)
    assert result.returncode == 0, result.stdout + result.stderr
    chain, control = env["KUBECONFIG"], tmp_path / "kube/control.kubeconfig"
    out = result.stdout.splitlines()
    assert "PRIVATE" in out
    assert f"AFTER_LOOKUP={chain}" in out and f"FINAL={chain}" in out
    assert (tmp_path / "stub.log").read_text().strip() == f"STUB={chain}", "the command runs on the Software Hub cluster"
    calls = switch_calls(tmp_path)
    zen = [c for c in calls if " get pods " in f" {c} " or c.startswith(("oc exec", "oc patch deployment zen-core-api",
                                                                          "oc rollout status deployment/zen-core-api"))]
    assert len(zen) == 6, calls   # get pods, exec, patch, rollout, then remove: patch, rollout
    expected = control if mode == "different" else chain
    assert all(c.endswith(f"KUBECONFIG={expected}") for c in zen), calls
    logins = [c for c in calls if c.startswith("oc login")]
    if mode == "different":
        assert len(logins) == 1, "logged in once, then 'already logged in'"
        assert "oc already logged in to" in result.stdout
    else:
        assert logins == [] and not (tmp_path / "kube/control.kubeconfig").exists(), "same mode never switches"


@pytest.mark.parametrize("ca", [True, False])
def test_different_mode_login_checks_the_certificate_when_it_can(tmp_path, ca):
    ca_file = put(tmp_path, "cc-ca.crt", "pem\n")
    env = switch_env(tmp_path, "different", {"CONTROL_OCP_CA_FILE": ca_file if ca else tmp_path / "missing.crt"})
    result = switch_run(tmp_path, env, "swhcc_oc_login\n")
    assert result.returncode == 0, result.stderr
    (login,) = [c for c in switch_calls(tmp_path) if c.startswith("oc login")]
    if ca:
        assert f"--certificate-authority={ca_file}" in login and "insecure" not in login
    else:
        assert "--insecure-skip-tls-verify=true" in login and "No readable CONTROL_OCP_CA_FILE" in result.stderr


@pytest.mark.parametrize("sidecar_server,ok", [(CC_URL + "/", True), ("https://api.swh.example.com:6443", False), ("", False)])
def test_login_proves_the_sidecar_sees_the_same_session(tmp_path, sidecar_server, ok):
    env = switch_env(tmp_path, "different", {"OLM_UTILS_CONTAINER": "olm-utils-swhub-control-center",
                                              "SIDECAR_SERVER": sidecar_server})
    tool(tmp_path / "bin", "podman", '#!/bin/bash\necho "podman $*" >> "$FAKE_DIR/podman.log"\n'
                                     '[ -n "$SIDECAR_SERVER" ] || exit 1\necho "$SIDECAR_SERVER"\n')
    result = switch_run(tmp_path, env, "swhcc_login\n")
    assert (tmp_path / "podman.log").read_text().strip() == \
        "podman exec olm-utils-swhub-control-center oc whoami --show-server"
    if ok:
        assert result.returncode == 0, result.stderr
        assert f"uses the session for {CC_URL}" in result.stdout
    else:
        assert result.returncode != 0
        assert "The Control Center sidecar sees" in result.stderr


def test_activate_takes_a_mirrored_sidecar_image_pinned_by_digest(tmp_path):
    mirrored = "registry.example.com/cp/cpd/olm-utils-premium-v4@sha256:abc123"
    setup_control_center(tmp_path, stub=False)
    result = activate(tmp_path, pod_env(tmp_path, {"IR_SWHCC_IMAGE_SOURCE": mirrored, "INSTALL_RUNNER_SWHCC_IMAGE": mirrored}))
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"OLM_UTILS_IMAGE={mirrored}" in result.stdout
