"""cpd-cli profile preflight + auto-repair (D10).

check() compares the profile URL with the live `cpd` route and makes one authenticated
call; it changes nothing. repair() runs x_repair_cpd_cli_profile.sh (one implementation for
the script and the TUI), which itself is a no-op when the profile is healthy.
Auto-repair: persisted per cluster + config in settings.json until toggled off; a flag or
INSTANCE_MANAGER_AUTO_REPAIR_PROFILE overrides it for one run without rewriting the file.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

import yaml

from ....common.kube import Kube, KubeError
from ...settings import Settings
from .cpdcli import CpdCli, CpdCliError

ENV_AUTO = "INSTANCE_MANAGER_AUTO_REPAIR_PROFILE"
SETTING = "auto_repair_profile"


@dataclass
class ProfileStatus:
    state: str              # ok | missing | stale | auth-failed | no-route | no-cli
    profile: str
    url: str = ""
    live_url: str = ""
    detail: str = ""

    @property
    def ok(self) -> bool:
        return self.state == "ok"

    @property
    def tag(self) -> str:
        return "profile repaired" if self.ok and self.detail == "repaired" else f"profile {self.state}"


def default_profile() -> str:
    return os.environ.get("CPD_PROFILE_NAME") or f"{os.environ.get('CPD_USERNAME') or 'cpadmin'}-profile"


def _profile_url(profile: str) -> str:
    path = Path(os.environ.get("CPDCONFIG") or Path.home() / ".cpd-cli" / "config")
    try:
        doc = yaml.safe_load(path.read_text()) or {}
    except (OSError, yaml.YAMLError):
        return ""
    for p in doc.get("profiles") or []:
        if p.get("name") == profile:
            return ((p.get("profile") or {}).get("url") or "").rstrip("/")
    return ""


def live_url(kube: Kube, namespace: str) -> str:
    try:
        route = kube.get(f"/apis/route.openshift.io/v1/namespaces/{namespace}/routes/cpd")
    except KubeError:
        return ""
    host = (route.get("spec") or {}).get("host")
    return f"https://{host}" if host else ""


def check(kube: Kube, namespace: str, cli: CpdCli) -> ProfileStatus:
    st = ProfileStatus(state="ok", profile=cli.profile, url=_profile_url(cli.profile),
                       live_url=live_url(kube, namespace))
    if not cli.available:
        st.state, st.detail = "no-cli", "cpd-cli not found"
    elif not st.live_url:
        st.state, st.detail = "no-route", f"no route 'cpd' in {namespace}"
    elif not st.url:
        st.state, st.detail = "missing", f"no profile {cli.profile} in the cpd-cli config"
    elif st.url != st.live_url:
        st.state, st.detail = "stale", f"points at {st.url}"
    else:
        try:
            cli.run("service-instance", "list", "--exclude-user-count", "-o", "json", timeout=90)
        except (CpdCliError, subprocess.TimeoutExpired) as e:
            st.state, st.detail = "auth-failed", str(e)[:200]
    return st


def repair_script() -> Path:
    here = Path(__file__).resolve()
    for parent in here.parents:
        cand = parent / "scripts" / "install_cloud_pak_for_data" / "4.5_service_instance_setups" / \
            "x_repair_cpd_cli_profile.sh"
        if cand.is_file():
            return cand
    raise FileNotFoundError("x_repair_cpd_cli_profile.sh not found")


def repair(profile: str) -> tuple[bool, list[str]]:
    """Run the repair script; (success, output lines without the [ENV] banner)."""
    proc = subprocess.run(["zsh", str(repair_script()), "--profile", profile], capture_output=True, text=True,
                          timeout=300, stdin=subprocess.DEVNULL)
    lines = [ln for ln in ((proc.stdout or "") + (proc.stderr or "")).splitlines()
             if ln.strip() and not ln.startswith("[ENV]")]
    return proc.returncode == 0, lines


def auto_repair_setting(api_url: str, flag: bool | None, settings: Settings | None = None) -> tuple[bool, str]:
    """(value in effect, where it came from): flag > env > saved > default off."""
    if flag is not None:
        return flag, "flag"
    env = os.environ.get(ENV_AUTO)
    if env:
        return env.strip().lower() in ("1", "true", "yes", "y", "on"), "env"
    saved = (settings or Settings()).cluster(api_url).get(SETTING)
    if saved is not None:
        return bool(saved), "saved"
    return False, "default"


def save_auto_repair(api_url: str, value: bool, settings: Settings | None = None) -> None:
    (settings or Settings()).set(api_url, SETTING, bool(value))


def preflight(kube: Kube, namespace: str, cli: CpdCli, auto: bool, log=print) -> ProfileStatus:
    """check(); when it fails and auto-repair is on, repair and check again. Healthy -> no-op."""
    st = check(kube, namespace, cli)
    if st.ok or not auto or st.state in ("no-cli", "no-route"):
        return st
    log(f"[INFO] {st.tag} ({st.detail}); auto-repair is on, repairing")
    ok, lines = repair(cli.profile)
    for ln in lines:
        log(f"  {ln}")
    st2 = check(kube, namespace, cli)
    if st2.ok:
        st2.state, st2.detail = "ok", "repaired"
    return st2
