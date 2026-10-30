#!/usr/bin/env python3
"""Save a service instance's credentials in the Software Hub (zen) internal vault.

Every value of one instance-details file
(configs/<product>/managed-service-instances/<type>/<instance>-instance_details.sh) becomes one
`generic` secret named `<type>-<instance>` (letters, digits and '-'), owned by the Software Hub
admin who signs in (CPD_URL + CPD_USERNAME + CPD_APIKEY, else CPD_PASSWORD) and shared with
SERVICE_INSTANCE_VAULT_MEMBERS (default "cpadmin"; comma-separated usernames, "group:<id|name>"
for groups). Re-running is safe: the secret is created, updated, or left as it is
(SoftwareHubVault.store_secret).

On by default. Off with SERVICE_INSTANCE_VAULT_STORE=false (cpd_vars.sh / env), the
STORE_CREDENTIALS_IN_VAULT line at the top of each service-instance script, or the TUI's
checkbox / --no-vault. VAULT_URN picks another vault (default the internal one).

The owner is never listed as a member: the secrets API answers HTTP 500 to that and leaves an
orphan that blocks the name (.claude/docs/softwarehub-secrets-api.md), so a member that is the
signed-in user is dropped (it owns the secret anyway).

Shell (h_write_instance_details calls this):  python3 instance_details_vault.py store <details-file>
                                              python3 instance_details_vault.py delete <type> <instance>
Values are never printed.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from softwarehub_internal_vault_helpers import (  # noqa: E402
    DEFAULT_VAULT_URN, SoftwareHubVault, VaultError, members, secret_name_for)

_HEADER = re.compile(r"^# (\S+) instance (\S+) in (\S+), cluster (\S+), written by (.+) on (\S+)$")
_EXPORT = re.compile(r"^export ([A-Za-z_][A-Za-z0-9_]*)=")
TRUE = ("1", "true", "yes", "y", "on")


def enabled(flag: bool | None = None) -> bool:
    if flag is not None:
        return flag
    return os.environ.get("SERVICE_INSTANCE_VAULT_STORE", "true").strip().lower() in TRUE


def member_names(raw: str | None = None) -> list[str]:
    raw = os.environ.get("SERVICE_INSTANCE_VAULT_MEMBERS", "cpadmin") if raw is None else raw
    return [m.strip() for m in raw.split(",") if m.strip()]


def secret_name(type_: str, instance: str) -> str:
    return secret_name_for(f"{type_}-{instance}")


def read_details(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    """-> (header: type/instance/namespace/cluster/writer, values) - values by sourcing in a clean zsh."""
    lines = path.read_text().splitlines()
    m = _HEADER.match(lines[0]) if lines else None
    header = dict(zip(("type", "instance", "namespace", "cluster", "writer", "written"), m.groups())) if m else {}
    if any(ln.startswith("# deleted") for ln in lines):
        header["deleted"] = "true"
    names = [mm.group(1) for ln in lines if (mm := _EXPORT.match(ln))]
    if not names:
        return header, {}
    script = f"source {subprocess.list2cmdline([str(path)])}\n" + \
        "for _n in " + " ".join(names) + "; do print -rn -- \"${(P)_n}\"; print -n '\\0'; done"
    out = subprocess.run(["zsh", "-f", "-c", script], capture_output=True, text=True, check=True).stdout
    return header, dict(zip(names, out.split("\0")))


def sign_in() -> SoftwareHubVault:
    url, user = os.environ.get("CPD_URL", ""), os.environ.get("CPD_USERNAME", "")
    key, pwd = os.environ.get("CPD_APIKEY"), os.environ.get("CPD_PASSWORD")
    if not (url and user and (key or pwd)):
        raise VaultError("CPD_URL / CPD_USERNAME / CPD_APIKEY (or CPD_PASSWORD) are not set "
                         "(configs/cp4d_config/cpd_instance_details.sh)")
    return SoftwareHubVault.sign_in(url, user, **({"api_key": key} if key else {"password": pwd}))


def _members(vault: SoftwareHubVault, names: list[str], log) -> dict:
    me = (vault.current_user().get("user_name") or vault.current_user().get("username") or "").lower()
    users, groups = [], []
    for n in names:
        if n.lower().startswith("group:"):
            g = n.split(":", 1)[1]
            grp = vault.find_group(g) if not g.isdigit() else {"group_id": g}
            if grp:
                groups.append({"group_id": str(grp.get("group_id")), **({"group_name": grp["name"]}
                                                                         if grp.get("name") else {})})
            else:
                log(f"[WARN] vault: no group '{g}'; not shared with it")
            continue
        if n.lower() == me:
            continue                         # the owner: listing it breaks the create (HTTP 500 + orphan)
        try:
            info = vault._request("GET", "/usermgmt/v1/user/" + urllib.parse.quote(n, safe="")) or {}
        except VaultError:
            info = {}
        uid = info.get("uid")
        if uid is None:
            log(f"[WARN] vault: no user '{n}'; not shared with it")
            continue
        users.append({"uid": str(uid), "username": n})
    return members(users=users, groups=groups)


def store(path: Path, member_list: list[str] | None = None, log=print, vault: SoftwareHubVault | None = None):
    header, values = read_details(path)
    if header.get("deleted"):
        log(f"[INFO] vault: {path.name} belongs to a deleted instance; not stored")
        return None
    type_, inst = header.get("type") or path.parent.name, header.get("instance") or path.name.removesuffix(
        "-instance_details.sh")
    vault = vault or sign_in()
    names = member_names() if member_list is None else member_list
    mem = _members(vault, names, log)
    secret = {"generic": {"instance": inst, "type": type_, "namespace": header.get("namespace", ""), **values}}
    desc = (f"{type_} instance {inst} in {header.get('namespace', '?')}: every value of "
            f"managed-service-instances/{type_}/{path.name}")
    res = vault.store_secret(secret_name(type_, inst), secret, type="generic",
                             vault_urn=os.environ.get("VAULT_URN", DEFAULT_VAULT_URN), description=desc,
                             members=mem or None)
    shared = ", ".join([u["username"] for u in mem.get("users", [])] +
                       [f"group {g['group_id']}" for g in mem.get("groups", [])]) or "nobody else"
    log(f"[INFO] vault: secret {res.urn} {res.action} ({len(values)} value(s); owner "
        f"{os.environ.get('CPD_USERNAME', '?')}, shared with {shared})")
    if res.action != "created" and mem:
        log("[INFO] vault: members are only set when a secret is created; an existing secret keeps its list")
    return res


def delete(type_: str, instance: str, log=print, vault: SoftwareHubVault | None = None) -> bool:
    vault = vault or sign_in()
    found = vault.find_secret(secret_name(type_, instance), owner_uid=vault.current_uid(),
                              vault_urn=os.environ.get("VAULT_URN", DEFAULT_VAULT_URN))
    if not found:
        log(f"[INFO] vault: no secret {secret_name(type_, instance)} to delete")
        return False
    vault.delete_secret(found["secret_urn"])
    log(f"[INFO] vault: deleted secret {found['secret_urn']}")
    return True


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "store":
        store(Path(argv[1]))
        return 0
    if len(argv) >= 3 and argv[0] == "delete":
        delete(argv[1], argv[2])
        return 0
    print(__doc__.split("Values are never printed.")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:      # never fatal for the caller: the details file is already saved
        print(f"[WARN] vault: {str(e).splitlines()[0][:300]}", file=sys.stderr)
        sys.exit(1)
