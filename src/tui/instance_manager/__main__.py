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
    ap.add_argument("--kubeconfig")
    ap.add_argument("--context")
    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
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
    interactive = not (args.once or args.explain or args.storage_report or args.create or args.edit
                       or args.delete or getattr(args, "sub", None)) and sys.stdout.isatty() \
        and sys.stdin.isatty()
    cluster = Cluster(kube)
    plain = args.no_color or bool(os.environ.get("NO_COLOR")) or not sys.stdout.isatty()
    tags: list[str] = []
    profile_ctx = None
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
            """Profile check (+ auto-repair); runs before discovery: in the TUI on the loader thread."""
            st = prof.preflight(kube, namespace, cli, auto, log=log)
            profile_ctx.status = st
            if not st.ok:
                provider.disable_zen(f"{st.tag}: {st.detail}; run x_repair_cpd_cli_profile.sh "
                                     "or --auto-repair-profile")

        if not interactive:
            preflight()
            tags = [f"{profile_ctx.status.tag} ({cli.profile})", f"auto-repair {'on' if auto else 'off'} ({source})"]
    else:
        namespace = None if args.all_namespaces else args.namespace
        kinds = [k for chunk in args.kinds for k in chunk.split(",") if k.strip()]
        provider = CrdProvider(cluster, kinds, namespace, declared, _sc_kinds(args.sc_kind))
    base = [f"instance-manager · {kube.host.split('//')[-1].split(':')[0]} · {kube.whoami()}",
            f"provider {provider.id}", f"ns {namespace}" if namespace else "all namespaces"]
    header = " · ".join(base + tags)
    if interactive:
        from .hub import DataHub
        from .ui.app import InstanceManagerApp
        hub = DataHub(provider, before_load=(lambda: preflight(log=lambda m: hub.event("info", m)))
                      if args.provider == "cpd" else None)
        InstanceManagerApp(hub, " · ".join(base), profile_ctx, plain=args.no_color,
                           animate=not args.no_animation, read_only=args.read_only, api_url=kube.host).run()
        return 0
    try:
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


if __name__ == "__main__":
    sys.exit(main())
