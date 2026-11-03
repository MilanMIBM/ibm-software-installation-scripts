"""CLI: python -m tui.instance_manager --help"""

from __future__ import annotations

import argparse
import os
import sys

from .model import Kind


def _sc_kinds(pairs: list[str]) -> dict[str, Kind]:
    out = {}
    for p in pairs:
        name, _, kind = p.partition("=")
        try:
            out[name] = Kind(kind.strip().lower())
        except ValueError:
            raise SystemExit(f"--sc-kind {p}: kind must be one of file|block|object|unknown")
    return out


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="instance-manager",
                                 description="Discover, create, resize, rename and delete service instances.")
    ap.add_argument("--provider", choices=["cpd", "k8s-crd"], default="cpd",
                    help="cpd = Software Hub / CP4D service instances (default); k8s-crd = any CRD (--kinds)")
    ap.add_argument("--kinds", action="append", default=[],
                    help="k8s-crd: CRDs to manage (plural.group | Kind | kind.group), comma list, repeatable")
    scope = ap.add_mutually_exclusive_group()
    scope.add_argument("-n", "--namespace", help="cpd: the instance namespace (default $PROJECT_CPD_INST_OPERANDS)")
    scope.add_argument("-A", "--all-namespaces", action="store_true", help="k8s-crd only")
    cpd = ap.add_argument_group("cpd")
    cpd.add_argument("--profile", help="cpd-cli profile (default $CPD_PROFILE_NAME or ${CPD_USERNAME}-profile)")
    cpd.add_argument("--auto-repair-profile", action=argparse.BooleanOptionalAction, default=None,
                     help="repair a stale/broken profile automatically, for this run only "
                          "(default: the value saved for this cluster, else off)")
    cpd.add_argument("--save-auto-repair", choices=["on", "off"],
                     help="save the auto-repair setting for this cluster + config (persists until changed)")
    cpd.add_argument("--sub", metavar="INSTANCE",
                     help="work on the sub-services of INSTANCE ([TYPE/]NAME), e.g. watsonx.data engines; "
                          "with --once / --explain KIND / --create KIND / --edit KIND/NAME / --delete KIND/NAME")
    cpd.add_argument("--seed", action="append", default=[], metavar="TYPE=payload.json",
                     help="a payload sample for a type nothing else describes (D6)")
    out = ap.add_argument_group("headless (read-only, no TTY needed)")
    out.add_argument("--once", action="store_true", help="print types, instances and states, then exit")
    out.add_argument("--explain", metavar="TYPE", help="print the discovered field model of TYPE with provenance")
    out.add_argument("--storage-report", action="store_true",
                     help="print StorageClass kinds and every storage field's need, with evidence")
    out.add_argument("--all-fields", action="store_true", help="--explain: include schema-only fields")
    ops = ap.add_argument_group("changes (print the plan; run it only with --yes)")
    ops.add_argument("--create", metavar="TYPE", help="create an instance of TYPE (with --name, --set)")
    ops.add_argument("--edit", metavar="INSTANCE", help="change scale/capacity of INSTANCE ([TYPE/]NAME, with --set)")
    ops.add_argument("--delete", metavar="INSTANCE", help="delete INSTANCE ([TYPE/]NAME)")
    ops.add_argument("--name", help="--create: the instance name")
    ops.add_argument("--description", default="", help="--create: description")
    ops.add_argument("--version", help="--create: add-on version (default: the newest the registry lists)")
    ops.add_argument("--set", action="append", default=[], metavar="FIELD=VALUE",
                     help="a field by key (parameters.numberofnodes), last key part or label; repeatable")
    ops.add_argument("--vault", action=argparse.BooleanOptionalAction, default=None,
                     help="--create: also save the credentials in the Software Hub vault, shared with "
                          "$SERVICE_INSTANCE_VAULT_MEMBERS (default: $SERVICE_INSTANCE_VAULT_STORE, else on)")
    ops.add_argument("--generate-secrets", action="store_true", help="--create: fill empty password fields")
    ops.add_argument("--force", action="store_true", help="--delete: cpd-cli --force (only after a failed delete)")
    ops.add_argument("--yes", action="store_true", help="run the plan (without it: print only)")
    ops.add_argument("--confirm", metavar="NAME", help="--delete: the instance name again (typed confirmation)")
    ops.add_argument("--ack-warnings", action="store_true", help="run even though the plan has warnings")
    ops.add_argument("--read-only", action="store_true", help="refuse every change")
    st = ap.add_argument_group("storage")
    st.add_argument("--file-sc", default=os.environ.get("STG_CLASS_FILE"),
                    help="declared file StorageClass (default $STG_CLASS_FILE)")
    st.add_argument("--block-sc", default=os.environ.get("STG_CLASS_BLOCK"),
                    help="declared block StorageClass (default $STG_CLASS_BLOCK)")
    st.add_argument("--sc-kind", action="append", default=[], metavar="NAME=KIND",
                    help="override a StorageClass kind (file|block|object|unknown)")
    ap.add_argument("--no-color", action="store_true")
    ap.add_argument("--no-animation", action="store_true", help="steady dots (no pulse)")
    ap.add_argument("--classic-ui", action="store_true",
                    help="the earlier pop-up windows for forms, plans, explain, legend, profile and sub-services "
                         "(default: everything inline)")
    cache = ap.add_argument_group("discovery cache (${CONFIG_DIR}/instance_manager_cache, rebuilt automatically "
                                  "when missing or when the cpd_vars summary changes)")
    cache.add_argument("--build-cache", action="store_true", help="build the stale parts of the cache, then exit "
                       "(or continue with --once / --explain / --storage-report)")
    cache.add_argument("--rebuild-cache", action="store_true", help="rebuild every part of the cache")
    cache.add_argument("--check-cache", action="store_true", help="print what is stale and why; writes nothing")
    cache.add_argument("--clear-cache", action="store_true", help="remove this cluster + namespace's cache")
    cache.add_argument("--no-cache", action="store_true", help="bypass the cache for this run")
    cache.add_argument("--include-subservices", action="store_true",
                       help="also warm the watsonx.data sub-service facts while building (automatic when a "
                            "watsonx.data instance exists)")
    ap.add_argument("--timings", action="store_true",
                    help="print how long each discovery step took, on stderr at exit (also INSTANCE_MANAGER_TIMINGS=1)")
    ap.add_argument("--kubeconfig")
    ap.add_argument("--context")
    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    from . import timings
    if args.timings:
        timings.enable()
    from ..common.kube import Kube, KubeError
    from . import report
    from .providers.k8s_crd.cluster import Cluster
    from .providers.k8s_crd.provider import CrdProvider

    try:
        kube = Kube(context=args.context, kubeconfig=args.kubeconfig)
    except Exception as e:
        print(f"cannot load kubeconfig ({e}); run oc login first", file=sys.stderr)
        return 2
    declared = {}
    if args.file_sc:
        declared[args.file_sc] = Kind.FILE
    if args.block_sc:
        declared[args.block_sc] = Kind.BLOCK
    cache_cmd = args.build_cache or args.rebuild_cache or args.check_cache or args.clear_cache
    if args.no_cache and cache_cmd:
        print("--no-cache can't be combined with --build-cache / --rebuild-cache / --check-cache / --clear-cache",
              file=sys.stderr)
        return 2
    interactive = not (args.once or args.explain or args.storage_report or args.create or args.edit
                       or args.delete or getattr(args, "sub", None) or cache_cmd) and sys.stdout.isatty() \
        and sys.stdin.isatty()
    cluster = Cluster(kube)
    plain = args.no_color or bool(os.environ.get("NO_COLOR")) or not sys.stdout.isatty()
    tags: list[str] = []
    profile_ctx = None
    preflight = None
    kinds: list[str] = []
    if args.provider == "cpd":
        from .discovery.samples import set_seed
        from .providers.cpd import profile as prof
        from .providers.cpd.cpdcli import CpdCli
        from .providers.cpd.provider import CpdProvider

        namespace = args.namespace or os.environ.get("PROJECT_CPD_INST_OPERANDS")
        if not namespace:
            print("cpd provider: set -n or PROJECT_CPD_INST_OPERANDS", file=sys.stderr)
            return 2
        for seed in args.seed:
            t, _, path = seed.partition("=")
            set_seed(t, path)
        if args.save_auto_repair:
            prof.save_auto_repair(kube.host, args.save_auto_repair == "on")
        auto, source = prof.auto_repair_setting(kube.host, args.auto_repair_profile)
        cli = CpdCli(args.profile or prof.default_profile())
        provider = CpdProvider(cluster, namespace, cli, declared_sc=declared, sc_overrides=_sc_kinds(args.sc_kind))
        from .subservices import register_defaults
        register_defaults(cluster)
        from .ui.app import ProfileCtx
        profile_ctx = ProfileCtx(status=None, auto=auto, source=source, api_url=kube.host, cli=cli, kube=kube,
                                 namespace=namespace)

        def preflight(log=lambda m: print(m, file=sys.stderr)) -> None:
            """Profile check (+ auto-repair); runs before discovery: in the TUI on the loader thread.
            Its zen list is handed to the provider, so discovery doesn't list again."""
            with timings.span("preflight"):
                st = prof.preflight(kube, namespace, cli, auto, log=log)
            profile_ctx.status = st
            if not st.ok:
                provider.disable_zen(f"{st.tag}: {st.detail}; run x_repair_cpd_cli_profile.sh "
                                     "or --auto-repair-profile")
            else:
                provider.seed_zen(st.records)
    else:
        namespace = None if args.all_namespaces else args.namespace
        kinds = [k for chunk in args.kinds for k in chunk.split(",") if k.strip()]
        provider = CrdProvider(cluster, kinds, namespace, declared, _sc_kinds(args.sc_kind))
    cache = None
    if not args.no_cache:
        from .cache.manager import DiscoveryCache
        cache = DiscoveryCache(provider, kube, namespace,
                               kinds_key=None if args.provider == "cpd" else ",".join(sorted(kinds)),
                               storage_flags={"file_sc": args.file_sc, "block_sc": args.block_sc,
                                              "sc_kind": sorted(args.sc_kind)},
                               operators_ns=os.environ.get("PROJECT_CPD_INST_OPERATORS"))
        if args.clear_cache:
            print(f"removed {cache.store.dir}" if cache.store.clear() else f"no cache at {cache.store.dir}")
            return 0
        if args.check_cache:
            return _check_cache(cache)
        cache.attach()
    base = [f"instance-manager · {kube.host.split('//')[-1].split(':')[0]} · {kube.whoami()}",
            f"provider {provider.id}", f"ns {namespace}" if namespace else "all namespaces"]
    if interactive:
        from .hub import DataHub
        from .ui.app import InstanceManagerApp
        hub = DataHub(provider, before_load=(lambda: preflight(log=lambda m: hub.event("info", m)))
                      if preflight else None, cache=cache, include_subservices=args.include_subservices or None)
        try:
            InstanceManagerApp(hub, " · ".join(base), profile_ctx, plain=args.no_color,
                               animate=not args.no_animation, read_only=args.read_only, api_url=kube.host,
                               classic_ui=args.classic_ui).run()
        finally:
            if cache is not None:
                cache.finish()
        return 0
    if preflight or cache:
        _prepare_headless(cache, preflight, args)
    if profile_ctx is not None:
        tags = [f"{profile_ctx.status.tag} ({profile_ctx.cli.profile})",
                f"auto-repair {'on' if profile_ctx.auto else 'off'} ({profile_ctx.source})"]
    header = " · ".join(base + tags)
    try:
        if args.build_cache or args.rebuild_cache:
            if not (args.once or args.explain or args.storage_report):
                return 0
        if getattr(args, "sub", None):
            from .ops.subcli import run_sub
            return run_sub(provider, args, plain)
        if args.create or args.edit or args.delete:
            from .ops.cli import run_change
            return run_change(provider, args, kube.host, plain)
        if args.explain:
            return report.print_explain(provider, args.explain, plain, args.all_fields)
        if args.storage_report:
            report.print_storage_report(provider, plain)
            return 0
        report.print_once(provider, header, plain)
        return 0
    except KubeError as e:
        print(f"cluster error: {e}", file=sys.stderr)
        return 1
    finally:
        if cache is not None:
            cache.finish()


def _prepare_headless(cache, preflight, args) -> None:
    """Profile preflight and the cache's fingerprint check side by side, then the automatic build
    (C-D2: no cache yet, or the cpd_vars summary changed) with the progress bar on stderr."""
    from concurrent.futures import ThreadPoolExecutor

    from .cache.manager import log_lines
    from .cache.progress import TerminalBar
    with ThreadPoolExecutor(max_workers=6) as pool:
        fut = pool.submit(cache.check) if cache else None
        if cache and (args.explain or args.storage_report or args.create or args.edit or args.delete):
            # the owner graph's cluster-wide lists (live evidence, never cached) load during the preflight
            cluster = cache.provider.cluster
            for fn in (cluster.pvcs, cluster.statefulsets, cluster.index, cluster.storage_classes):
                pool.submit(fn)
            if cache.namespace:
                pool.submit(cluster.secret_names, cache.namespace)
        if preflight:
            preflight()
        st = fut.result() if fut else None
    if cache is None:
        return
    log_lines(st.lines)
    if args.rebuild_cache:
        cache.drop_all()
        log_lines(["--rebuild-cache: rebuilding every part"])
    if st.need_build or args.build_cache or args.rebuild_cache:
        pr = cache.build(TerminalBar(), include_subservices=args.include_subservices or None)
        failed = [p for p in pr.parts if p.state == "failed"]
        log_lines([f"built {pr.done_count}/{pr.total} part(s) in {pr.elapsed:.1f}s"
                   + (f", {len(failed)} failed ({', '.join(p.label for p in failed)})" if failed else "")
                   + f": {cache.store.dir}"])


def _check_cache(cache) -> int:
    """--check-cache: the fingerprint diff (what is stale and why); writes nothing."""
    cache.dry = True
    st = cache.check()
    for ln in cache.describe():
        print(ln)
    for ln in st.lines:
        print(f"! {ln}")
    if st.dropped:
        print("would rebuild: " + ", ".join(st.dropped))
    print("up to date" if not (st.need_build or st.dropped) else
          "stale: the next run rebuilds " + ("everything" if st.cold else "the parts above"))
    if cache.probe and cache.probe.errors:
        print("probe errors: " + "; ".join(cache.probe.errors))
    return 0

if __name__ == "__main__":
    sys.exit(main())
