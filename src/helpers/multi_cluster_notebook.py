"""Logic behind the "Manage multiple clusters" controls in the *_vars_generation.py notebooks.

Plan section 5.11. Plain data in, plain data out, no marimo imports: the notebooks hold the
widgets and cells, this module decides where a save goes and whether it may happen, so the
three notebooks stay identical and tests need no running notebook.

    target = resolve_target("cp4d_config", enabled, typed_name, cluster_url)
    save_to_markdown(target)            the live "Save to" line
    one_way_markdown(target)            the warning shown when the save creates a cluster folder
    save_blockers(target, ticked, text) reasons the save must not run; [] means go
    finish_save(target)                 flag, registration and current cluster, after writing

Delineation is one-way per cluster: a cluster with a configs/clusters/<name>/.cluster marker
keeps its own folder for good. A save for such a cluster (named, or owning the URL through
cluster_for_url) always goes into that folder, whatever the tick or the state file says. The
tick only sets the repo-wide default (MULTI_CLUSTER_MANAGEMENT) and places new clusters.

Every function takes optional repo and env, the same as multi_cluster_state.
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from . import multi_cluster_state as mcm

MIGRATE_SCRIPT = Path("src/utilities/multi_cluster_management_utils/migrate_to_multi_cluster.sh")
MIGRATE_TIMEOUT_SECONDS = 1800
PREFLIGHT_TIMEOUT_SECONDS = 120
HELPERS_SCRIPT = Path("src/helpers/multi_cluster_helpers.sh")
STOP_AFTER_OFF_TIMEOUT_SECONDS = 300

# $1 is the helpers file. A checkout without the function has nothing to run.
_STOP_AFTER_OFF = """
source "$1" || exit
(( ${+functions[mcm_stop_idle_after_off]} )) || exit 0
mcm_stop_idle_after_off
"""

_OCP_URL_LINE = re.compile(r"""^[ \t]*(?:export[ \t]+)?OCP_URL=(["']?)(.*?)\1[ \t]*(?:#.*)?$""", re.MULTILINE)


@dataclass(frozen=True)
class SaveTarget:
    """Where one save goes, worked out from the notebook's fields."""

    product_dir: str
    enabled: bool  # the "Manage multiple clusters" tick
    typed_name: str  # the name field, stripped; "" = use the name from the URL
    url: str  # the cluster URL field, stripped
    hint: str = ""  # name derived from the URL, "" when there is none
    cluster: str = ""  # resolved cluster, "" for the flat layout or while unresolved
    directory: str = ""  # product folder to write into, "" while unresolved
    display: str = ""  # the same folder, relative to the repo where possible
    error: str = ""  # why this cannot be saved yet
    conflicts: tuple = ()  # (where, url) for configs of this cluster at a different URL
    state_on: bool = False  # the state file currently has the mode on
    registered: tuple = ()  # clusters registered in the state file
    owner: str = ""  # delineated cluster owning the URL (cluster_for_url), "" when none
    delineated: bool = False  # cluster already has its marker: the save goes there whatever the tick says
    retired: bool = False  # cluster is delineated but retired: the save registers it again
    repo: object = field(default=None, repr=False, compare=False)  # what resolve_target was given
    env: object = field(default=None, repr=False, compare=False)

    @property
    def conflict(self) -> bool:
        return bool(self.conflicts)

    @property
    def forced(self) -> bool:
        """Unticked, but the cluster is delineated, so the save still goes into its folder."""
        return not self.enabled and bool(self.cluster)

    @property
    def new_cluster(self) -> bool:
        """The save creates this cluster's folder and marker: one-way for that cluster."""
        return bool(self.cluster) and not self.delineated

    @property
    def mode_after(self) -> bool:
        """MULTI_CLUSTER_MANAGEMENT after the save. A forced save leaves the default as it is."""
        return self.enabled or (self.forced and self.state_on)


def _base(repo):
    return Path(repo) if repo else mcm.repo_root()


def _display(path, repo):
    path = Path(path)
    try:
        return f"./{path.relative_to(_base(repo))}/"
    except ValueError:
        return f"{path}/"


def _url_key(url):
    return mcm.url_key(url)


def url_in_text(text) -> str:
    """First literal OCP_URL in a config's text; "" when it is missing, empty or a ${reference}."""
    for match in _OCP_URL_LINE.finditer(str(text or "")):
        value = match.group(2).strip()
        if value and "$" not in value:
            return value
    return ""


def _url_in_file(path) -> str:
    try:
        return url_in_text(Path(path).read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return ""


def derive_name(url) -> str:
    """Cluster name from the URL for the hint; "" when none can be derived."""
    try:
        return mcm.name_from_url(url)
    except ValueError:
        return ""


def mode_default(repo=None, env=None) -> bool:
    """Starting value of the tick box. A broken state file reads as off; resolve_target reports it."""
    try:
        return mcm.is_on(repo, env)
    except ValueError:
        return False


def cluster_urls(cluster, repo=None) -> list:
    """(where, url) for the marker and every product config of the cluster that names a URL."""
    root = mcm.cluster_root(cluster, repo)
    found = []
    marker_url = _url_in_file(root / ".cluster")
    if marker_url:
        found.append((".cluster", marker_url))
    for path in sorted(root.glob("*_config/*_vars.sh")):
        url = _url_in_file(path)
        if url:
            found.append((str(path.relative_to(root)), url))
    return found


def delineated_owner(url, repo=None) -> str:
    """Delineated cluster owning url (marker URL, else the derived name with a marker); "" when none.

    Depends on the URL only, so the cell showing the tick can use it without redrawing
    while the name is typed.
    """
    try:
        return mcm.cluster_for_url(str(url or "").strip(), repo)
    except (ValueError, OSError):
        return ""


def resolve_target(product_dir, enabled, name="", url="", repo=None, env=None) -> SaveTarget:
    """Works out the folder from the tick, the typed name and the URL.

    A delineated cluster wins over the tick: a URL it owns saves into its folder even when
    unticked, so it never gets a second, flat config. Never raises for bad input: the
    reason lands in .error, for the "Save to" line to show.
    """
    typed = str(name or "").strip()
    url = str(url or "").strip()
    fields = {
        "product_dir": product_dir,
        "enabled": bool(enabled),
        "typed_name": typed,
        "url": url,
        "hint": derive_name(url),
        "repo": repo,
        "env": env,
    }
    try:
        state = mcm.read_state(repo, env)
    except ValueError as exc:
        return SaveTarget(**fields, error=f"Fix the state file first: {exc}")
    fields["state_on"] = state["MULTI_CLUSTER_MANAGEMENT"] == "true"
    fields["registered"] = tuple(state["MCM_CLUSTERS"].split())
    owner = delineated_owner(url, repo) if url else ""
    fields["owner"] = owner

    if not enabled and not owner:
        # Unticked means the flat folder: with the mode on, not the current cluster; with it off,
        # not a cluster an inherited MCM_CLUSTER pins (configs_root follows that pin), which
        # would land another cluster's values in that folder past the conflict check.
        try:
            pinned = None if fields["state_on"] else mcm.pinned_cluster(repo, env)
        except ValueError as exc:
            return SaveTarget(**fields, error=str(exc))
        flat = fields["state_on"] or pinned
        root = mcm.clusters_root(repo).parent if flat else mcm.configs_root(repo, env)
        directory = root / product_dir
        return SaveTarget(**fields, directory=str(directory), display=_display(directory, repo))

    if not enabled:
        cluster = owner  # the typed name is hidden while unticked
    elif typed:
        try:
            cluster = mcm.validate_name(typed)
        except ValueError as exc:
            return SaveTarget(**fields, error=str(exc))
        if owner and owner != cluster:
            return SaveTarget(
                **fields,
                error=(
                    f"This URL belongs to cluster {owner}, which has its own folder "
                    f"(./configs/clusters/{owner}/) for good. Leave the name blank or type {owner}, "
                    "so the cluster does not get a second config."
                ),
            )
    elif owner:
        cluster = owner
    elif url:
        try:
            cluster = mcm.name_from_url(url)
        except ValueError as exc:
            return SaveTarget(**fields, error=str(exc))
    else:
        return SaveTarget(**fields, error="Enter the cluster URL or type a cluster name.")

    try:
        directory = mcm.config_dir(product_dir, cluster, repo, env)
    except ValueError as exc:
        return SaveTarget(**fields, error=str(exc))
    conflicts = tuple(item for item in cluster_urls(cluster, repo) if url and _url_key(item[1]) != _url_key(url))
    return SaveTarget(
        **fields,
        cluster=cluster,
        directory=str(directory),
        display=_display(directory, repo),
        conflicts=conflicts,
        delineated=mcm.is_delineated(cluster, repo),
        retired=mcm.is_retired(cluster, repo),
    )


def existing_vars_file(target, filename):
    """Path of an already saved config in the target folder, or None."""
    if not target.directory:
        return None
    path = os.path.join(target.directory, filename)
    return path if os.path.isfile(path) else None


def startup_vars_file(product_dir, filename, repo=None, env=None):
    """The same, for the moment the notebook opens and the fields are still blank."""
    return existing_vars_file(resolve_target(product_dir, mode_default(repo, env), "", "", repo, env), filename)


def save_to_markdown(target) -> str:
    """The live "Save to" line with the name hint and anything else that affects the save."""
    lines = []
    default = "on" if target.state_on else "off"
    if target.error:
        lines.append(f"**Save to:** not decided yet. {target.error}")
    elif target.cluster:
        lines.append(f"**Save to:** `{target.display}` (cluster **{target.cluster}**)")
    else:
        lines.append(f"**Save to:** `{target.display}` (single-cluster layout)")
    if target.enabled and target.hint and not target.owner:
        if target.typed_name and target.typed_name != target.hint:
            lines.append(f"The URL alone would give **{target.hint}**; the name you typed is used instead.")
        elif not target.typed_name:
            lines.append(f"Name from the URL: **{target.hint}**. Type a name to use a different one.")
    if target.forced:
        lines.append(
            f"**Manage multiple clusters is forced on for this config:** cluster **{target.cluster}** owns this "
            f"URL and has its own folder, so its config is always saved there, whatever the tick says. A cluster "
            f"with its own folder never goes back to the flat layout. The tick only sets the default for new "
            f"clusters and for runs that name no cluster, which stays **{default}**; run this cluster with "
            f"`--target-cluster {target.cluster}`."
        )
    elif target.enabled and target.delineated:
        lines.append(f"Cluster **{target.cluster}** already has its own folder, which it keeps for good.")
    if target.retired:
        lines.append(f"Cluster **{target.cluster}** is retired: saving registers it again.")
    elif target.enabled and target.new_cluster:
        lines.append("New cluster: saving registers it and makes it the current one.")
    if not target.enabled and not target.cluster and target.state_on:
        clusters = ", ".join(target.registered) or "none"
        lines.append(
            "Saving turns multi-cluster mode **off**, the default for new clusters and for runs that name no "
            f"cluster. Clusters with their own folder keep it and stay reachable with --target-cluster: {clusters}."
        )
    for where, url in target.conflicts:
        lines.append(f"Cluster **{target.cluster}** already points at `{url}` (`{where}`), not this URL.")
    return "\n\n".join(lines)


def one_way_markdown(target) -> str:
    """Warning for a save that creates a cluster folder; "" when the save creates none."""
    if target.error or not target.new_cluster:
        return ""
    return (
        f"**This cannot be undone for cluster {target.cluster}.** Managing each cluster in its own folder is "
        f"the preferred layout, but once saved, **{target.cluster}** is managed from "
        f"`./configs/clusters/{target.cluster}/` for good, even if multi-cluster mode is turned off later. "
        "Untick to keep this config in the flat layout instead."
    )


def overwrite_label(target) -> str:
    return f"**Overwrite cluster {target.cluster or '(none)'}: its existing config points at a different URL**"


def live_leases(env=None) -> list:
    """(cluster, pid) for every run holding a live lease, on any cluster folder."""
    environ = os.environ if env is None else env
    home = Path(environ.get("HOME") or Path.home())
    found = []
    for lease in sorted(home.glob("cpd-cli/clusters/*/.leases/*")):
        if not lease.name.isdigit():
            continue
        try:
            os.kill(int(lease.name), 0)
        except ProcessLookupError:
            continue
        except (OSError, OverflowError):
            pass
        found.append((lease.parent.parent.name, lease.name))
    return found


def _flat_run_blockers(target) -> list:
    """What migrate_to_multi_cluster.sh --preflight-only reports: a running cpd-cli manage, a busy container."""
    base = _base(target.repo)
    script = base / MIGRATE_SCRIPT
    if not script.is_file():
        return []
    try:
        done = subprocess.run(
            ["zsh", str(script), "--preflight-only"],
            cwd=base,
            env=None if target.env is None else dict(target.env),
            capture_output=True,
            text=True,
            timeout=PREFLIGHT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return [f"Could not check for a run in progress ({exc}), so the mode was not changed."]
    if done.returncode == 0:
        return []
    found = [line.split("Preflight: ", 1)[1] for line in done.stderr.splitlines() if "Preflight: " in line]
    return found or [f"Could not check for a run in progress: {done.stderr.strip() or done.returncode}"]


def mode_change_blockers(target) -> list:
    """Reasons a save must not flip the mode now.

    A pin outlives a change of current cluster, but not a change of mode: each nested step
    resolves its cluster again, so a run in progress would continue on another config.
    """
    if target.mode_after == target.state_on:
        return []
    found = [f"A run is live on cluster {name} (pid {pid})." for name, pid in live_leases(target.env)]
    if target.mode_after and not found:
        found = _flat_run_blockers(target)
    if not found:
        return []
    verb = "on" if target.mode_after else "off"
    return [
        *found,
        f"Saving would turn multi-cluster mode {verb} under that run, and its next step would load "
        "another config. Wait for it to finish, then save again.",
    ]


def save_blockers(target, confirmed=False, content="") -> list:
    """Reasons the save must not run; empty means go. content is the text about to be written."""
    if target.error:
        return [target.error]
    blockers = mode_change_blockers(target)
    if target.conflict and not confirmed:
        blockers.append(
            f"Cluster {target.cluster} already has a config for a different URL. "
            "Tick the overwrite box to replace it, or type another cluster name."
        )
    content_url = url_in_text(content)
    if target.cluster and target.url and content_url and _url_key(content_url) != _url_key(target.url):
        blockers.append(
            f"The file being saved has OCP_URL {content_url}, but the cluster URL field says {target.url}. "
            "Generate the file again or make the two match."
        )
    return blockers


def _stop_failure_note(reason) -> str:
    return (
        f"**Cluster containers were not checked** ({reason}). "
        "Any still running stay up until you stop them: `podman ps`, then `podman stop -t 3 <name>`."
    )


def _stop_idle_after_off(repo=None, env=None) -> list:
    """Stops the idle cluster containers the mode has just stopped managing. Returns notes to show.

    Best effort, after the state is written: nothing here fails the save, and a checkout
    without the helper has nothing to do. A busy container stays up, so the note says so.
    """
    base = _base(repo)
    helpers = base / HELPERS_SCRIPT
    if not helpers.is_file():
        return []
    run_env = dict(os.environ if env is None else env)
    run_env["_CP4D_REPO_ROOT"] = str(base)  # an inherited value can name another checkout
    try:
        done = subprocess.run(
            ["zsh", "-c", _STOP_AFTER_OFF, "zsh", str(helpers)],
            cwd=base,
            env=run_env,
            capture_output=True,
            text=True,
            timeout=STOP_AFTER_OFF_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return [_stop_failure_note(exc)]
    warnings = [
        re.sub(r"^\[[A-Z]+\]\s*", "", line)
        for line in (done.stdout + "\n" + done.stderr).splitlines()
        if line.startswith(("[WARN]", "[ERROR]")) or "left running" in line
    ]
    if warnings:
        return ["**Cluster containers:**\n\n" + "\n".join(f"- {line}" for line in warnings)]
    return [] if done.returncode == 0 else [_stop_failure_note(f"exit code {done.returncode}")]


def finish_save(target, repo=None, env=None) -> list:
    """After the files are written: flag, registration, current cluster. Returns notes to show.

    A forced save (unticked, delineated cluster) registers the cluster and leaves the flag
    and the current cluster alone. A failure here cannot undo the write, so it comes back
    as a note instead of an exception.
    """
    notes = []
    try:
        if target.cluster:
            new = not mcm.is_delineated(target.cluster, repo)
            retired = mcm.is_retired(target.cluster, repo)
            mcm.register_cluster(target.cluster, target.url or None, repo, env)
            if target.enabled:
                mcm.write_state({"MULTI_CLUSTER_MANAGEMENT": True, "MCM_CURRENT_CLUSTER": target.cluster}, repo, env)
                notes.append(f"Multi-cluster mode is on; **{target.cluster}** is registered and current.")
            else:
                mode = "on" if target.state_on else "off"
                notes.append(
                    f"Saved into the folder of **{target.cluster}**, which has its own folder for good. "
                    f"Multi-cluster mode stays {mode}; run this cluster with `--target-cluster {target.cluster}`."
                )
            if retired:
                notes.append(f"**{target.cluster}** was retired and is registered again.")
            if new:
                notes.append(
                    f"**This cannot be undone for cluster {target.cluster}:** it is now managed from "
                    f"`./configs/clusters/{target.cluster}/` for good, even if multi-cluster mode is turned off later."
                )
        else:
            mcm.ensure_state_file(repo, env)
            if target.state_on:
                mcm.write_state({"MULTI_CLUSTER_MANAGEMENT": False}, repo, env)
                notes.append(
                    "Multi-cluster mode is now off for new clusters and for runs that name no cluster. "
                    "Clusters with their own folder keep it; run them with --target-cluster NAME."
                )
                notes.extend(_stop_idle_after_off(repo or target.repo, target.env if env is None else env))
    except (ValueError, OSError) as exc:
        notes.append(f"**The files were saved, but the cluster state was not updated:** {exc}")
    return notes


def flat_configs(repo=None) -> list:
    """Product configs still in the flat layout: {product, file, url, cluster} per *_vars.sh."""
    root = mcm.clusters_root(repo).parent
    found = []
    for path in sorted(root.glob("*_config/*_vars.sh")):
        url = _url_in_file(path)
        found.append(
            {
                "product": path.parent.name,
                "file": str(path.relative_to(root)),
                "url": url,
                "cluster": derive_name(url),
            }
        )
    return found


def flat_configs_markdown(configs) -> str:
    rows = "\n".join(
        f"- `{item['file']}` goes to **{item['cluster'] or 'the cluster holding cp4d_config'}**" for item in configs
    )
    return (
        "**Configs from before multi-cluster mode were found.** They are not used while the mode is on. "
        f"Migrating moves them into per-cluster folders:\n\n{rows}"
    )


def run_migration(repo=None, env=None) -> tuple:
    """Runs the migration utility without its prompt. Returns (succeeded, combined output)."""
    base = _base(repo)
    script = base / MIGRATE_SCRIPT
    if not script.is_file():
        return False, f"[ERROR] {MIGRATE_SCRIPT} is not in this checkout."
    try:
        done = subprocess.run(
            ["zsh", str(script), "--yes"],
            cwd=base,
            env=None if env is None else dict(env),
            capture_output=True,
            text=True,
            timeout=MIGRATE_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"[ERROR] Could not run the migration: {exc}"
    return done.returncode == 0, (done.stdout + done.stderr).strip()
