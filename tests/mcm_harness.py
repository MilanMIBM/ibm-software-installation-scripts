"""Throwaway sandbox for multi-cluster shell tests (plan: .claude/plans/multi-cluster-management/).

Nothing here touches the real podman, a real cluster, ~/cpd-cli, ~/.kube, ~/.cpd-cli or the real
configs/. Everything lives under one temp folder and is removed when the context manager exits.

    from mcm_harness import make_sandbox

    def test_something():
        with make_sandbox(extra=["src/utilities/multi_cluster_management_utils"]) as sb:
            sb.write_config("cpd", ocp_url="https://api.itz-a.example.com:6443", cluster="itz-a")
            sb.add_container("olm-utils-play-v4-itz-a", running=False)
            result = sb.run_zsh('source src/helpers/multi_cluster_helpers.sh\\nmcm_is_on\\n')
            assert result.returncode == 1
            assert ["start", "olm-utils-play-v4-itz-a"] in sb.calls("podman")

make_sandbox(extra=()) -> Sandbox, usable with `with` (or call .close() yourself).
  Copies into sb.repo: env_bootstrap.sh, s_env.sh, scripts/source_env_setup.sh,
  scripts/operator_install_helpers.sh, every *.sh and *.py directly in src/helpers/, plus
  src/helpers/multi_cluster_bin/ when it exists. `extra` adds repo-relative files or folders.
  Asking for configs/, service_instances/ or a *_workspace folder raises ValueError.

Sandbox attributes:
  root, repo, home, bin, tmp     Path objects. sb.home/"cpd-cli" exists and holds a copy of the fake cpd-cli.

Running things (each returns a subprocess.CompletedProcess with text stdout/stderr; pass check=True to raise):
  sb.run_zsh(script, env=None, args=(), cwd=None, timeout=60, strict=True, check=False)
      Writes script to a new file in sb.repo and runs it. strict=True prepends 'set -euo pipefail',
      which is how the repo's scripts run. The file sits in the repo root, so ${0:A:h} is the repo.
  sb.run_script(rel_path, env=None, args=(), cwd=None, timeout=60, check=False)
      Runs a script already in the sandbox repo.
  sb.env(extra=None)
      The environment both use: PATH with the fakes first, then /usr/bin:/bin; temp HOME and TMPDIR;
      LOGNAME and USER fixed; _CP4D_PREP_DONE=1. Nothing else is inherited. A value of None removes a name.

Writing product configs:
  sb.write_config(product, ocp_url=DEFAULT_URL, cluster=None, extra=None, login=True, text=None) -> Path
      product: cpd, concert, confluent, datastax_mc, kubecost, registry_mirror, swhub_control_center.
      cluster=None writes the flat configs/<product dir>/; a name writes configs/clusters/<name>/<product dir>/.
      Only products that declare it get OLM_UTILS_IMAGE and CPDM_OC_LOGIN (cpd, swhub_control_center).
      extra adds export lines, login=False leaves out the login variables, text replaces the whole body.
  sb.write_cluster_marker(name, url="") -> Path
      Just the configs/clusters/<name>/.cluster marker, with no helper code involved.

Fake tools (all append to one log; state in sb.root/"fake_state.json", guarded by a file lock):
  sb.calls(tool=None)         argv lists, in order, for "podman", "oc" or "cpd-cli" (None: every tool)
  sb.call_records(tool=None)  dicts with tool, argv, cwd and env (HOME, KUBECONFIG, CPDCONFIG, CPD_CLI_HOME,
                              CPD_CLI_WORKSPACE, CPD_CLI_MANAGE_WORKSPACE, OLM_UTILS_CONTAINER, OLM_UTILS_IMAGE,
                              MCM_CLUSTER, MCM_CLUSTER_ROOT)
  sb.clear_calls()

Fake podman, modelled state (sb.fake_state() returns a copy, sb.update_fake_state(fn) edits under the lock):
  sb.add_container(name, running=True, image=DEFAULT_IMAGE, started_at=None)
  sb.container(name) -> dict or None   keys: running, image, id, started_at, finished_at
  sb.add_exec_rule(contains, stdout="", stderr="", rc=0, container="*")
      `podman exec NAME cmd...` uses the first rule whose text occurs in the joined command. Rules are tried in the
      order added. No rule: rc 0, no output. Exec on a stopped or missing container is rc 125, as with real podman.
  sb.add_event(container, status="exec", when=None, time_text=None)   when: epoch seconds, default now
  sb.add_external_container(name)      a container podman does not run (a buildah build): only ps --external lists it
  sb.set_machine("running"|"stopped")   anything but "running" makes container commands fail
  sb.set_podman_reachable(False)        same failure, while 'machine inspect' still answers
  Supported: machine inspect|stop|start|list|init, info, version, ps, inspect, start, stop, rm, exec, run, events,
  container exists|inspect|ls|ps|start|stop|rm|exec. --format understands json, {{.Field}}, {{.Nested.Field}},
  {{json .}}, {{json .Field}}, table and \\t \\n. ps honours -a and --filter name=REGEX / status=X. events honours
  --since, --until (epoch, ISO or 30m/2h), --filter event=X / container=X / type=X. Each exec, start, stop, run and
  rm is recorded as an event. Anything else: rc 0, no output.

Fake oc (sessions are per KUBECONFIG, so two clusters stay separate):
  login [URL] [--server=URL] [--token ..] [-u USER] records a session; whoami and whoami --show-server read it and
  fail with rc 1 when there is none; logout clears it. sb.oc_session(kubeconfig=None) -> dict or None.
  Everything else: rc 0, no output.

Fake cpd-cli: `version` prints a version. `manage VERB` starts or creates the container named by OLM_UTILS_CONTAINER,
as the real one does. Everything else: rc 0, no output.

No test should use the real state file: run_zsh runs in the temp repo, and tests/conftest.py points MCM_STATE_FILE
at a per-test temp path for code running inside pytest.
"""

from __future__ import annotations

import fcntl
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

DEFAULT_URL = "https://api.itz-test.example.com:6443"
DEFAULT_IMAGE = "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8"

SCAFFOLD_FILES = (
    "env_bootstrap.sh",
    "s_env.sh",
    "scripts/source_env_setup.sh",
    "scripts/operator_install_helpers.sh",
)
FORBIDDEN_TOP = ("configs", "service_instances", "cpd-cli-workspace")

PRODUCTS = {
    "cpd": ("cp4d_config/cpd_vars.sh", True),
    "concert": ("concert_config/concert_vars.sh", False),
    "confluent": ("confluent_platform_config/confluent_vars.sh", False),
    "datastax_mc": ("datastax_mc_config/datastax_mc_vars.sh", False),
    "kubecost": ("kubecost_config/kubecost_vars.sh", False),
    "registry_mirror": ("registry_mirror_config/registry_mirror_vars.sh", False),
    "swhub_control_center": ("cp4d_config/swhub_control_center/swhub_control_center_vars.sh", True),
}

LOGGED_ENV = (
    "HOME", "KUBECONFIG", "CPDCONFIG", "CPD_CLI_HOME", "CPD_CLI_WORKSPACE", "CPD_CLI_MANAGE_WORKSPACE",
    "OLM_UTILS_CONTAINER", "OLM_UTILS_IMAGE", "MCM_CLUSTER", "MCM_CLUSTER_ROOT",
)

# One script body, copied as bin/podman, bin/oc, bin/cpd-cli and ~/cpd-cli/cpd-cli. basename($0) picks the tool.
# @@SANDBOX@@ and @@LOGGED_ENV@@ are replaced when written.
FAKE_TOOL = r'''#!@@PYTHON@@ -I
"""Fake podman / oc / cpd-cli for tests. See tests/mcm_harness.py."""
import datetime, fcntl, json, os, re, sys, time
from pathlib import Path

SANDBOX = Path("@@SANDBOX@@")
STATE = SANDBOX / "fake_state.json"
LOCK = SANDBOX / "fake_state.lock"
LOG = SANDBOX / "fake_calls.log"
LOGGED_ENV = @@LOGGED_ENV@@
TOOL = os.path.basename(sys.argv[0])
ARGS = sys.argv[1:]


def iso(when):
    return datetime.datetime.fromtimestamp(when, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load():
    return json.loads(STATE.read_text())


def save(state):
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
    os.replace(tmp, STATE)


def log_call():
    record = {
        "tool": TOOL, "argv": ARGS, "cwd": os.getcwd(),
        "env": {k: os.environ[k] for k in LOGGED_ENV if k in os.environ},
    }
    with LOG.open("a") as handle:
        handle.write(json.dumps(record) + "\n")


def fail(text, rc=125):
    print(text, file=sys.stderr)
    sys.exit(rc)


def out(text):
    if text != "":
        print(text)


def add_event(state, name, status, when=None):
    when = time.time() if when is None else when
    # Real podman's {{.Time}} is int64 epoch seconds (cmd/podman/system/events.go, v6.1.0).
    state["events"].append({"Name": name, "Status": status, "Type": "container", "Time": int(when), "timeUnix": when})


def template_value(data, path):
    value = data
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            return "<no value>"
        value = value[part]
    return value


def as_text(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)


def render(fmt, data):
    fmt = fmt.replace("\\t", "\t").replace("\\n", "\n")
    if fmt.startswith("table "):
        fmt = fmt[len("table "):]
    fmt = re.sub(r"\{\{\s*json\s+\.\s*\}\}", lambda _: json.dumps(data), fmt)
    fmt = re.sub(r"\{\{\s*json\s+\.([\w.]+)\s*\}\}", lambda m: json.dumps(template_value(data, m.group(1))), fmt)
    return re.sub(r"\{\{\s*\.([\w.]+)\s*\}\}", lambda m: as_text(template_value(data, m.group(1))), fmt)


def take_option(args, *names):
    """Removes --name VALUE / --name=VALUE / -n VALUE from args and returns every VALUE."""
    found, rest, i = [], [], 0
    while i < len(args):
        arg = args[i]
        if arg in names and i + 1 < len(args):
            found.append(args[i + 1])
            i += 2
            continue
        matched = next((n for n in names if n.startswith("--") and arg.startswith(n + "=")), None)
        if matched:
            found.append(arg[len(matched) + 1:])
        else:
            rest.append(arg)
        i += 1
    args[:] = rest
    return found


def ensure_reachable(state):
    if not state["reachable"] or state["machine"] != "running":
        fail("Cannot connect to Podman. Please verify your connection to the Linux system")


def inspect_view(name, c):
    return {
        "Name": name, "Id": c["id"], "Image": c["image"], "ImageName": c["image"],
        "State": {
            "Status": "running" if c["running"] else "exited", "Running": c["running"],
            "StartedAt": c["started_at"], "FinishedAt": c["finished_at"],
        },
        "Config": {"Image": c["image"]},
    }


def ps_view(name, c):
    return {
        "Names": name, "Name": name, "ID": c["id"], "Id": c["id"], "Image": c["image"],
        "State": "running" if c["running"] else "exited",
        "Status": f"Up since {c['started_at']}" if c["running"] else "Exited (0)", "StartedAt": c["started_at"],
    }


def machine(state, args):
    verb = args[0] if args else ""
    rest = args[1:]
    fmt = take_option(rest, "--format", "-f")
    if verb == "inspect":
        data = {"Name": "podman-machine-default", "State": state["machine"]}
        out(render(fmt[0], data) if fmt else json.dumps([data]))
    elif verb == "stop":
        state["machine"] = "stopped"
        out("Machine \"podman-machine-default\" stopped successfully")
    elif verb == "start":
        state["machine"] = "running"
        out("Machine \"podman-machine-default\" started successfully")
    elif verb == "list":
        data = {"Name": "podman-machine-default", "LastUp": state["machine"]}
        out(render(fmt[0], data) if fmt else "podman-machine-default")


def ps(state, args):
    filters = take_option(args, "--filter", "-f")
    fmt = take_option(args, "--format")
    show_all = "-a" in args or "--all" in args
    views = []
    for name, c in sorted(state["containers"].items()):
        if not show_all and not c["running"]:
            continue
        view = ps_view(name, c)
        keep = True
        for item in filters:
            key, _, value = item.partition("=")
            if key == "name" and not re.search(value, name):
                keep = False
            if key == "status" and value != view["State"]:
                keep = False
        if keep:
            views.append(view)
    # --external: containers in storage that podman does not run (a buildah build). Real podman
    # lists them with State "storage" (pkg/ps/ps.go ListStorageContainer).
    if "--external" in args:
        for name in state.get("external", []):
            views.append({"Names": name, "Name": name, "ID": "", "Id": "", "Image": "", "State": "storage",
                          "Status": "", "StartedAt": ""})
    if fmt and fmt[0] == "json":
        out(json.dumps(views))
    elif fmt:
        for view in views:
            out(render(fmt[0], view))
    else:
        for view in views:
            out(f"{view['ID']} {view['Image']} {view['Status']} {view['Names']}")


def inspect(state, args):
    fmt = take_option(args, "--format", "-f")
    take_option(args, "--type", "-t")
    names = [a for a in args if not a.startswith("-")]
    views = []
    for name in names:
        if name not in state["containers"]:
            fail(f"Error: no such object: \"{name}\"")
        views.append(inspect_view(name, state["containers"][name]))
    if fmt and fmt[0] != "json":
        for view in views:
            out(render(fmt[0], view))
    else:
        out(json.dumps(views))


def start(state, args):
    names = [a for a in args if not a.startswith("-")]
    for name in names:
        c = state["containers"].get(name)
        if c is None:
            fail(f"Error: no container with name or ID \"{name}\" found: no such container")
        if not c["running"]:
            c["running"] = True
            c["started_at"] = iso(time.time())
            add_event(state, name, "start")
        out(name)


def stop(state, args):
    take_option(args, "--time", "-t")
    names = [a for a in args if not a.startswith("-")]
    for name in names:
        c = state["containers"].get(name)
        if c is None:
            fail(f"Error: no container with name or ID \"{name}\" found: no such container")
        if c["running"]:
            c["running"] = False
            c["finished_at"] = iso(time.time())
            add_event(state, name, "died")
        out(name)


def rm(state, args):
    ignore = any(flag in args for flag in ("--ignore", "-i", "--force", "-f"))
    names = [a for a in args if not a.startswith("-")]
    for name in names:
        if name not in state["containers"]:
            if ignore:
                continue
            fail(f"Error: no container with ID or name \"{name}\" found: no such container", 1)
        del state["containers"][name]
        add_event(state, name, "remove")
        out(name)


def new_container(image):
    now = iso(time.time())
    return {"running": True, "image": image, "id": os.urandom(6).hex(), "started_at": now, "finished_at": ""}


def run(state, args):
    names = take_option(args, "--name")
    for option in ("-v", "--volume", "-e", "--env", "-p", "--publish", "-w", "--workdir", "-u", "--user",
                   "--network", "--entrypoint", "--hostname", "--restart"):
        take_option(args, option)
    positional = [a for a in args if not a.startswith("-")]
    image = positional[0] if positional else ""
    if names:
        state["containers"][names[0]] = new_container(image)
        add_event(state, names[0], "create")
        add_event(state, names[0], "start")
        out(state["containers"][names[0]]["id"])


def exec_in(state, args):
    i = 0
    value_flags = {"-e", "--env", "-u", "--user", "-w", "--workdir"}
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in value_flags else 1
    if i >= len(args):
        fail("Error: must provide a non-empty command to start an exec session")
    name, command = args[i], args[i + 1:]
    c = state["containers"].get(name)
    if c is None:
        fail(f"Error: no container with name or ID \"{name}\" found: no such container")
    if not c["running"]:
        fail("Error: can only create exec sessions on running containers: container state improper")
    add_event(state, name, "exec")
    joined = " ".join(command)
    for rule in state["exec_rules"]:
        if rule["container"] in ("*", name) and rule["contains"] in joined:
            if rule["stdout"]:
                sys.stdout.write(rule["stdout"])
            if rule["stderr"]:
                sys.stderr.write(rule["stderr"])
            return rule["rc"]
    return 0


def parse_time(text):
    match = re.fullmatch(r"(\d+)([smh])", text)
    if match:
        return time.time() - int(match.group(1)) * {"s": 1, "m": 60, "h": 3600}[match.group(2)]
    if re.fullmatch(r"\d+(\.\d+)?", text):
        return float(text)
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def events(state, args):
    since = take_option(args, "--since")
    until = take_option(args, "--until")
    filters = take_option(args, "--filter", "-f")
    fmt = take_option(args, "--format")
    low = parse_time(since[0]) if since else None
    high = parse_time(until[0]) if until else None
    for event in state["events"]:
        if low is not None and event["timeUnix"] < low:
            continue
        if high is not None and event["timeUnix"] > high:
            continue
        wanted = True
        for item in filters:
            key, _, value = item.partition("=")
            if key == "event" and event["Status"] != value:
                wanted = False
            if key == "container" and event["Name"] != value:
                wanted = False
            if key == "type" and event["Type"] != value:
                wanted = False
        if not wanted:
            continue
        if fmt and fmt[0] == "json":
            out(json.dumps(event))
        elif fmt:
            out(render(fmt[0], event))
        else:
            out(f"{iso(event['timeUnix'])} container {event['Status']} ({event['Name']})")


def podman(state):
    args = list(ARGS)
    if not args:
        return 0
    verb = args.pop(0)
    if verb == "machine":
        machine(state, args)
        return 0
    if verb == "info":
        ensure_reachable(state)
        out("host: fake")
        return 0
    if verb == "version":
        out("Client: fake")
        return 0
    ensure_reachable(state)
    if verb == "container":
        if not args:
            return 0
        verb = args.pop(0)
        if verb == "exists":
            return 0 if args and args[0] in state["containers"] else 1
    handlers = {"ps": ps, "ls": ps, "inspect": inspect, "start": start, "stop": stop, "rm": rm, "run": run, "events": events}
    if verb == "exec":
        return exec_in(state, args)
    if verb in handlers:
        handlers[verb](state, args)
    return 0


def oc(state):
    key = os.environ.get("KUBECONFIG", "<default>")
    args = list(ARGS)
    verb = args[0] if args else ""
    if verb == "whoami":
        session = state["oc_sessions"].get(key)
        if session is None:
            fail("error: You must be logged in to the server (Unauthorized)", 1)
        out(session["server"] if "--show-server" in args else session["user"])
    elif verb == "login":
        rest = args[1:]
        servers = take_option(rest, "--server", "-s")
        users = take_option(rest, "--username", "-u")
        take_option(rest, "--token", "--password", "-p")
        positional = [a for a in rest if not a.startswith("-")]
        server = servers[0] if servers else (positional[0] if positional else "")
        state["oc_sessions"][key] = {"server": server, "user": users[0] if users else "fake-user"}
        out(f"Logged into \"{server}\" as \"{state['oc_sessions'][key]['user']}\"")
    elif verb == "logout":
        state["oc_sessions"].pop(key, None)
    return 0


def cpd_cli(state):
    args = list(ARGS)
    verb = args[0] if args else ""
    if verb == "version":
        out("cpd-cli fake 14.4.0")
    elif verb in ("manage", "manage-k8s"):
        name = os.environ.get("OLM_UTILS_CONTAINER", "")
        if name:
            ensure_reachable(state)
            c = state["containers"].get(name)
            if c is None:
                state["containers"][name] = new_container(os.environ.get("OLM_UTILS_IMAGE", "fake-default-image"))
                add_event(state, name, "create")
                add_event(state, name, "start")
            elif not c["running"]:
                c["running"] = True
                c["started_at"] = iso(time.time())
                add_event(state, name, "start")
    return 0


def main():
    log_call()
    with LOCK.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load()
        rc = {"podman": podman, "oc": oc, "cpd-cli": cpd_cli}.get(TOOL, lambda _: 0)(state)
        save(state)
    sys.exit(rc)


main()
'''


class Sandbox:
    def __init__(self, tmp_dir):
        self._tmp_dir = tmp_dir
        self.root = Path(tmp_dir.name).resolve()
        self.repo = self.root / "repo"
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.tmp = self.root / "tmp"
        self._state = self.root / "fake_state.json"
        self._lock = self.root / "fake_state.lock"
        self._log = self.root / "fake_calls.log"
        self._counter = 0

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self.close()

    def close(self):
        if self._tmp_dir is None:
            return
        # A detached idle watcher started by a mode-on load can still be writing its pid file or
        # log here for a moment; it exits once the folder is gone.
        for attempt in range(25):
            try:
                self._tmp_dir.cleanup()
                break
            except OSError:
                if attempt == 24:
                    raise
                time.sleep(0.2)
        self._tmp_dir = None

    # ---- running ----------------------------------------------------------------------------
    def env(self, extra=None):
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(self.tmp),
            "LOGNAME": "mcm-tester",
            "USER": "mcm-tester",
            "_CP4D_PREP_DONE": "1",
        }
        for key, value in (extra or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
        return env

    def run_zsh(self, script, env=None, args=(), cwd=None, timeout=60, strict=True, check=False):
        self._counter += 1
        driver = self.repo / f"mcm_run_{self._counter}.sh"
        driver.write_text(("set -euo pipefail\n" if strict else "") + script)
        driver.chmod(0o755)
        return self._exec(driver, env, args, cwd, timeout, check)

    def run_script(self, rel_path, env=None, args=(), cwd=None, timeout=60, check=False):
        return self._exec(self.repo / rel_path, env, args, cwd, timeout, check)

    def _exec(self, path, env, args, cwd, timeout, check):
        return subprocess.run(
            ["zsh", str(path), *map(str, args)],
            cwd=cwd or self.repo, env=self.env(env), capture_output=True, text=True, timeout=timeout, check=check,
        )

    # ---- fake configs -----------------------------------------------------------------------
    def write_config(self, product, ocp_url=DEFAULT_URL, cluster=None, extra=None, login=True, text=None):
        relative, uses_olm_utils = PRODUCTS[product]
        base = self.repo / "configs" / "clusters" / cluster if cluster else self.repo / "configs"
        path = base / relative
        if text is None:
            lines = [f'export OCP_URL="{ocp_url}"']
            if login:
                lines.append(f'export OC_LOGIN="oc login {ocp_url} --token=fake-token"')
            if uses_olm_utils:
                lines.append(f'export OLM_UTILS_IMAGE="{DEFAULT_IMAGE}"')
                if login:
                    lines.append(f'export CPDM_OC_LOGIN="cpd-cli manage login-to-ocp --server={ocp_url} --token=fake-token"')
            lines.extend(f'export {key}="{value}"' for key, value in (extra or {}).items())
            text = "\n".join(lines) + "\n"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def write_cluster_marker(self, name, url=""):
        marker = self.repo / "configs" / "clusters" / name / ".cluster"
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(f'NAME="{name}"\nOCP_URL="{url}"\nCREATED="2026-11-09T00:00:00Z"\n')
        return marker

    # ---- fake tools -------------------------------------------------------------------------
    def call_records(self, tool=None):
        if not self._log.exists():
            return []
        records = [json.loads(line) for line in self._log.read_text().splitlines() if line]
        return [r for r in records if tool is None or r["tool"] == tool]

    def calls(self, tool=None):
        return [r["argv"] for r in self.call_records(tool)]

    def clear_calls(self):
        self._log.unlink(missing_ok=True)

    def fake_state(self):
        return self._with_state(lambda state: json.loads(json.dumps(state)))

    def update_fake_state(self, change):
        def apply(state):
            change(state)
            self._write_state(state)
        self._with_state(apply)

    def _with_state(self, action):
        with self._lock.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return action(json.loads(self._state.read_text()))

    def _write_state(self, state):
        temp = self._state.with_suffix(".harness")
        temp.write_text(json.dumps(state, indent=1, sort_keys=True))
        temp.replace(self._state)

    def add_container(self, name, running=True, image=DEFAULT_IMAGE, started_at=None):
        stamp = started_at or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        def change(state):
            state["containers"][name] = {
                "running": running, "image": image, "id": f"{abs(hash(name)):012x}"[:12], "started_at": stamp, "finished_at": "",
            }
        self.update_fake_state(change)

    def container(self, name):
        return self.fake_state()["containers"].get(name)

    def add_external_container(self, name):
        self.update_fake_state(lambda state: state.setdefault("external", []).append(name))

    def add_exec_rule(self, contains, stdout="", stderr="", rc=0, container="*"):
        rule = {"container": container, "contains": contains, "stdout": stdout, "stderr": stderr, "rc": rc}
        self.update_fake_state(lambda state: state["exec_rules"].append(rule))

    def add_event(self, container, status="exec", when=None, time_text=None):
        """time_text: what {{.Time}} prints instead of epoch seconds (older podman clients print date text)."""
        moment = time.time() if when is None else when
        shown = int(moment) if time_text is None else time_text
        event = {"Name": container, "Status": status, "Type": "container", "Time": shown, "timeUnix": moment}
        self.update_fake_state(lambda state: state["events"].append(event))

    def set_machine(self, status):
        self.update_fake_state(lambda state: state.__setitem__("machine", status))

    def set_podman_reachable(self, reachable):
        self.update_fake_state(lambda state: state.__setitem__("reachable", reachable))

    def oc_session(self, kubeconfig=None):
        return self.fake_state()["oc_sessions"].get(str(kubeconfig) if kubeconfig else "<default>")


def _copy_into(repo, rel):
    rel_path = Path(rel)
    if rel_path.is_absolute() or ".." in rel_path.parts:
        raise ValueError(f"sandbox extras must be repo-relative: {rel}")
    top = rel_path.parts[0]
    if top in FORBIDDEN_TOP or top.endswith("_workspace"):
        raise ValueError(f"sandbox must not copy real user data: {rel}")
    source, target = REPO / rel_path, repo / rel_path
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__"), dirs_exist_ok=True)
    else:
        shutil.copy2(source, target)


def make_sandbox(extra=()):
    """A new temp HOME, repo copy and fake tools. See the module docstring."""
    tmp_dir = tempfile.TemporaryDirectory(prefix="mcm-sandbox-")
    sandbox = Sandbox(tmp_dir)
    for folder in (sandbox.repo / "configs", sandbox.home / "cpd-cli", sandbox.bin, sandbox.tmp):
        folder.mkdir(parents=True)
    for rel in SCAFFOLD_FILES:
        _copy_into(sandbox.repo, rel)
    helpers = sandbox.repo / "src" / "helpers"
    helpers.mkdir(parents=True)
    for pattern in ("*.sh", "*.py"):
        for source in (REPO / "src" / "helpers").glob(pattern):
            shutil.copy2(source, helpers / source.name)
    if (REPO / "src" / "helpers" / "multi_cluster_bin").is_dir():
        _copy_into(sandbox.repo, "src/helpers/multi_cluster_bin")
    for rel in extra:
        _copy_into(sandbox.repo, rel)

    (sandbox.root / "fake_state.json").write_text(json.dumps({
        "machine": "running", "reachable": True, "containers": {}, "events": [], "exec_rules": [], "oc_sessions": {},
    }))
    body = (FAKE_TOOL.replace("@@PYTHON@@", sys.executable)
            .replace("@@SANDBOX@@", str(sandbox.root))
            .replace("@@LOGGED_ENV@@", repr(list(LOGGED_ENV))))
    for tool_path in (sandbox.bin / "podman", sandbox.bin / "oc", sandbox.bin / "cpd-cli", sandbox.home / "cpd-cli" / "cpd-cli"):
        tool_path.write_text(body)
        tool_path.chmod(0o755)
    return sandbox
