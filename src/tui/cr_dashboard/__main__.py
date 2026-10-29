"""cr-dashboard CLI.

  python -m tui.cr_dashboard cpd [--components a,b] [--instance-ns NS] [--operator-ns NS]
                             [--cluster-component-ns NS ...] [--no-deps] [KIND[/NAME] ...]
  python -m tui.cr_dashboard cr  KIND[/NAME] [...] [-n NS ... | -A] [--operator-ns NS ...]

Read-only: never writes to the cluster or to disk. Quit with q / Ctrl-C.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta

from .classifier import Thresholds
from .k8s_source import Hub, Introspector, Kube, KubeError
from .profiles import index_crds
from .profiles.cpd import CpdProfile, split_list
from .profiles.generic import GenericProfile
from .store import Engine, build_resources


def duration(text: str) -> timedelta:
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*", str(text))
    if not m:
        raise argparse.ArgumentTypeError(f"bad duration '{text}' (use e.g. 30s, 15m, 1h)")
    n, unit = float(m.group(1)), m.group(2) or "s"
    return timedelta(seconds=n * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit])


def _common(p: argparse.ArgumentParser):
    g = p.add_argument_group("common")
    g.add_argument("--interval", type=duration, default=timedelta(seconds=10),
                   help="operator introspection interval (default 10s)")
    g.add_argument("--stall-after", type=duration, default=timedelta(minutes=15),
                   help="in progress with no change for this long -> stuck (default 15m)")
    g.add_argument("--debounce", type=duration, default=timedelta(seconds=30),
                   help="a pod problem must last this long before the dot changes (default 30s)")
    g.add_argument("--scale-grace", type=duration, default=timedelta(minutes=10),
                   help="pods may be not-ready this long after a scale change (default 10m)")
    g.add_argument("--retry-warn", type=float, default=0.8, help="wait-loop retries used -> stuck (default 0.8)")
    g.add_argument("--max-depth", type=int, default=3,
                   help="show non-component sub-CRs down to this chain layer (default 3)")
    g.add_argument("--all-depths", action="store_true", help="show every CR, at any depth")
    g.add_argument("--tree-mode", choices=("live", "owns", "deps"), default="live")
    g.add_argument("--no-exec", action="store_true", help="don't read operator pods (no current step)")
    g.add_argument("--no-follow-owned", action="store_true", help="don't look for owned sub-CRs")
    g.add_argument("--profile-file", help="YAML with per-kind overrides: {kinds: {Kind: {status: .status.x}}}")
    g.add_argument("--no-animation", action="store_true", help="glowing dots without the pulse")
    g.add_argument("--no-color", action="store_true", help="text tags instead of coloured dots")
    g.add_argument("--once", action="store_true", help="print the current state and exit")
    g.add_argument("--exit-when-settled", nargs="?", const="5m", default=None, type=str, metavar="DURATION",
                   help="exit once everything is green/gray and unchanged this long (default 5m)")
    g.add_argument("--kubeconfig")
    g.add_argument("--context")


def parse(argv=None):
    ap = argparse.ArgumentParser(prog="cr-dashboard", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="profile", required=True)
    env = os.environ
    p = sub.add_parser("cpd", help="IBM Software Hub / CP4D components")
    p.add_argument("refs", nargs="*", metavar="KIND[/NAME]", help="extra CRs to show")
    p.add_argument("--components", default=env.get("COMPLETE_COMPONENT_LIST", ""))
    p.add_argument("--fallback-components",
                   default="cpfs,cpd_platform,ccs," + env.get("CPD_COMPONENTS", ""))
    p.add_argument("--instance-ns", default=env.get("PROJECT_CPD_INST_OPERANDS", ""))
    p.add_argument("--operator-ns", default=env.get("PROJECT_CPD_INST_OPERATORS", ""))
    p.add_argument("--cluster-component-ns", action="append",
                   default=None, help="repeatable (default: scheduling + licensing namespaces)")
    p.add_argument("--no-deps", action="store_true", help="don't add component_dependencies")
    _common(p)
    p = sub.add_parser("cr", help="any CRD")
    p.add_argument("refs", nargs="+", metavar="KIND[/NAME]")
    p.add_argument("-n", "--namespace", action="append", default=None)
    p.add_argument("-A", "--all-namespaces", action="store_true")
    p.add_argument("--operator-ns", action="append", default=None)
    _common(p)
    a = ap.parse_args(argv)
    if a.profile == "cpd" and a.cluster_component_ns is None:
        a.cluster_component_ns = [env.get("PROJECT_SCHEDULING_SERVICE", ""), env.get("PROJECT_LICENSE_SERVICE", "")]
    return a


def _overrides(path: str | None) -> dict:
    if not path:
        return {}
    import yaml
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    return doc.get("kinds") or {}


def build(a):
    kube = Kube(context=a.context, kubeconfig=a.kubeconfig)
    crds = index_crds(kube.get("/apis/apiextensions.k8s.io/v1/customresourcedefinitions", timeout=(5, 120)))
    overrides = _overrides(a.profile_file)
    if a.profile == "cpd":
        if not a.instance_ns:
            sys.exit("cr-dashboard: --instance-ns (or PROJECT_CPD_INST_OPERANDS) is required")
        profile = CpdProfile(split_list(a.components), split_list(a.fallback_components), a.instance_ns,
                             a.operator_ns, a.cluster_component_ns or [], deps=not a.no_deps, overrides=overrides)
        if a.refs:
            extra = GenericProfile(a.refs, profile.namespaces(), overrides=overrides)
            profile.extra = extra.resolve(crds)
            profile.notes += extra.notes
    else:
        ns = None if a.all_namespaces else (a.namespace or [_default_namespace(a)])
        profile = GenericProfile(a.refs, ns, a.operator_ns, overrides)
    specs = profile.resolve(crds)
    if a.profile == "cr" and a.all_namespaces:
        found = set()
        for s in specs:
            if s.namespaced:
                try:
                    lst = kube.get(f"/apis/{s.group}/{s.version}/{s.plural}")
                    found |= {o["metadata"]["namespace"] for o in lst.get("items") or []}
                except KubeError:
                    pass
        profile.set_discovered_namespaces(list(found))
    resources, scan_specs = build_resources(specs, profile, crds, scan=not a.no_follow_owned)
    hub = Hub(kube)
    th = Thresholds(a.stall_after, a.debounce, a.scale_grace, a.retry_warn)
    engine = Engine(profile, hub, crds, specs, scan_specs, th=th, max_depth=None if a.all_depths else a.max_depth,
                    tree_mode=a.tree_mode)
    intro = Introspector(kube, hub, profile.operator_namespaces(), enabled=not a.no_exec,
                         interval=a.interval.total_seconds())
    return kube, profile, hub, engine, intro, resources


def _default_namespace(a) -> str:
    from kubernetes import config
    try:
        _, active = config.list_kube_config_contexts(config_file=a.kubeconfig)
        return ((active or {}).get("context") or {}).get("namespace") or "default"
    except Exception:
        return "default"


def load_once(hub: Hub, resources) -> None:
    def one(r):
        paths = [r.path]
        try:
            items, _ = hub._list(r, paths)
        except KubeError as e:
            if e.status == 403 and r.fallback_paths:
                try:
                    items, _ = hub._list(r, r.fallback_paths)
                except Exception as e2:
                    hub._error(r.name, str(e2))
                    return
            elif e.status == 404:
                items = {}
            else:
                hub._error(r.name, str(e))
                return
        except Exception as e:
            hub._error(r.name, f"{type(e).__name__}: {e}"[:200])
            return
        hub._sync(r.name, items)

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(one, resources))


def header_line(kube: Kube, profile, user: str) -> str:
    host = re.sub(r"^https?://", "", kube.host or "").split(":")[0]
    ns = " / ".join(profile.namespaces()[:2])
    return f"cr-dashboard · {host} · {user} · {ns} · {profile.title()}"


def main(argv=None) -> int:
    a = parse(argv)
    if "NO_COLOR" in os.environ:
        a.no_color = True
    try:
        kube, profile, hub, engine, intro, resources = build(a)
    except KubeError as e:
        print(f"cr-dashboard: cluster access failed: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"cr-dashboard: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    user = kube.whoami()
    from . import plain
    if a.once or not sys.stdout.isatty():
        load_once(hub, resources)
        view = engine.compute(intro)
        if intro.enabled:
            targets, green = engine.intro_targets(view)
            intro.set_targets([t for t in targets if t.key not in green], set())
            intro._tick()
            view = engine.compute(intro)
        plain.render(view, header_line(kube, profile, user), color=None if not a.no_color else False)
        return 0
    from .ui.app import DashboardApp
    app = DashboardApp(kube=kube, profile=profile, hub=hub, engine=engine, intro=intro, resources=resources,
                       user=user, header=header_line(kube, profile, user), animate=not a.no_animation,
                       plain=a.no_color,
                       exit_when_settled=duration(a.exit_when_settled) if a.exit_when_settled else None)
    app.run()
    hub.stop.set()
    if app.settled_view is not None:
        plain.render(app.settled_view, header_line(kube, profile, user), color=None if not a.no_color else False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
