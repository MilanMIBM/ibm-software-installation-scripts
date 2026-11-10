"""Render or submit IBM Software Hub 5.4 Cognos instance payloads."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

from cognos_content_store import Db2, PreparationError, Settings, prepare
from db2_provisioning import write_payload

ADDON = "cognos-analytics-app"
SIZES = ("small_mincpureq", "fixedminimum", "xsmall", "small", "medium", "large")


def build_payload(args):
    for label, value in (("name", args.name), ("description", args.description)):
        if not re.fullmatch(r"[A-Za-z0-9 ._-]+" if label == "name" else r"[A-Za-z0-9 ._-]*", value):
            raise ValueError(f"Invalid Cognos {label}; use letters, digits, spaces, periods, underscores or dashes")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        raise ValueError("Supply the installed Cognos service version, for example 30.0.4")
    if not args.namespace or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", args.namespace):
        raise ValueError("Supply a valid target namespace")
    for value in (args.file_class, args.block_class, args.content_connection, args.audit_connection):
        if not value or not value.strip():
            raise ValueError("File/block classes and content/audit platform connection names are required")
    if args.size not in SIZES:
        raise ValueError("Invalid Cognos plan size")
    for name in (args.file_class, args.block_class):
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?", name):
            raise ValueError("Storage classes must be Kubernetes resource names")
    return {
        "addon_type": ADDON,
        "display_name": args.name,
        "namespace": args.namespace,
        "addon_version": args.version,
        "create_arguments": {
            "deployment_id": "",
            "parameters": {
                "fileStorageClass": args.file_class,
                "blockStorageClass": args.block_class,
                "fips": "FIPS 140-2" if args.fips else "",
                "planSize": args.size,
                "audit": args.audit_connection,
                "auditProperty": os.environ.get("COGNOS_AUDIT_CONNECTION_PROPS", ""),
                "cs": args.content_connection,
                "csProperty": os.environ.get("COGNOS_CONTENT_CONNECTION_PROPS", ""),
            },
            "resources": {},
            "description": args.description,
            "owner_username": "",
        },
        "transient_fields": {},
    }


def preflight(provider, args, *, wait_only=False):
    """Read the installed registry and both platform/CR inventories before any create."""
    types = [t for t in provider.discover_types() if t.key == f"cpd:{ADDON}"]
    if len(types) != 1:
        raise ValueError("Cannot discover exactly one installed Cognos type")
    itype = types[0]
    if not itype.crd:
        from tui.instance_manager.providers.k8s_crd.provider import type_from_crd

        # Cognos registers its CLI version without declaring custom_resource_kind.
        crd = provider.cluster.get_crd("caserviceinstances.ca.cpd.ibm.com")
        if not crd or crd.get("spec", {}).get("names", {}).get("kind") != "CAServiceInstance":
            raise ValueError("Cannot discover the installed Cognos CAServiceInstance CRD")
        resolved = type_from_crd(crd, key=itype.key, provider="cpd")
        resolved.versions = itype.versions
        itype = resolved
    if args.version not in itype.versions:
        raise ValueError("Requested Cognos version is not advertised by the installed service")
    # These strict reads must not use the provider's permission-tolerant inventory fallback.
    crs = provider.cluster.list(itype.list_path(args.namespace), cache=False)
    records = [r for r in provider.cli.list_instances() if r.get("service_type") == ADDON]
    if any(not r.get("namespace") for r in records):
        raise ValueError("Cognos platform records lack namespace information; cannot verify isolation")
    if not wait_only and (crs or any(r["namespace"] == args.namespace for r in records)):
        raise ValueError("A Cognos instance already exists in this namespace; use --wait-only to observe it")
    if any(r.get("display_name") == args.name and r["namespace"] != args.namespace for r in records):
        raise ValueError("Cognos display name already exists in another namespace")
    for name in (args.file_class, args.block_class):
        provider.cluster.kube.get("/apis/storage.k8s.io/v1/storageclasses/" + name)
    return itype


def wait_ready(provider, itype, name, timeout):
    from tui.common.state import State
    from tui.cr_dashboard.model import Phase
    from tui.cr_dashboard.status_normalize import normalize
    from tui.instance_manager.ops.planner import watch

    def done(instances):
        hits = [i for i in instances if i.display_name == name]
        if len(hits) > 1:
            raise ValueError("Ambiguous Cognos display name; inspect the instance manager")
        if not hits:
            return False, "waiting for Cognos instance registration"
        inst = hits[0]
        zen = inst.meta.get("zen", {}).get("provision_status")
        ro = inst.meta.get("rollout")
        phase = normalize(inst.obj, inst.obj.get("kind", ""), None, None).phase if inst.obj else None
        if zen in {"FAILED", "PROVISION_FAILED"} or phase == Phase.FAILED:
            raise ValueError("Cognos provisioning failed; inspect redacted operator/platform logs")
        ready = (zen == "PROVISIONED" and phase == Phase.COMPLETED and ro is not None
                 and ro.state == State.HEALTHY and ro.total > 0 and ro.ready == ro.total)
        return ready, "Cognos is ready" if ready else "waiting for Cognos CR, application replicas and platform status"

    if not watch(provider, itype, done, timeout, print):
        raise ValueError("Readiness timed out; creation may still complete. Use --wait-only; do not resubmit create")


def provision(provider, args, payload):
    itype = preflight(provider, args, wait_only=args.wait_only)
    provider.namespace = args.namespace
    provider.refresh_instances()
    if not args.wait_only:
        if not args.db2_instance or not args.db2_user:
            raise ValueError("--apply requires --db2-instance and --db2-user for read-only 32K content-store validation")
        db = Db2(args.db2_namespace or args.namespace, args.db2_instance, args.db2_pod, args.db2_os_user)
        settings = Settings(args.database, args.db2_user, args.db2_schema or args.db2_user, require_32k=True)
        if prepare(db, settings, False) != 0:
            raise ValueError("Content store is not ready; complete preparation/reactivation separately and rerun --check --require-32k")
        write_payload(args.output, payload)
        # Do not echo CLI output: provider errors and JDBC properties can contain credentials.
        provider.cli.run("service-instance", "create", f"--from-source={args.output.resolve()}", timeout=600)
        print("Cognos create submitted; the payload is saved with mode 0600")
    wait_ready(provider, itype, args.name, args.timeout)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    mode = result.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="validate the prepared Db2 store, create Cognos once and wait")
    mode.add_argument("--wait-only", action="store_true", help="observe a previous submission without creating or preparing anything")
    result.add_argument("--name", required=True)
    result.add_argument("--version", required=True, help="installed service version; not the Software Hub version")
    result.add_argument("--description", default="")
    result.add_argument("--namespace", default=os.environ.get("PROJECT_CPD_INST_OPERANDS"))
    result.add_argument("--platform-namespace", default=os.environ.get("PROJECT_CPD_INST_OPERANDS"), help="operands namespace holding the add-on registry (for tethered targets)")
    result.add_argument("--file-class", default=os.environ.get("STG_CLASS_FILE"))
    result.add_argument("--block-class", default=os.environ.get("STG_CLASS_BLOCK"))
    result.add_argument("--content-connection", required=True, help="tested platform connection display name")
    result.add_argument("--audit-connection", required=True, help="tested audit platform connection; may equal content connection")
    result.add_argument("--size", choices=SIZES, required=True)
    result.add_argument("--fips", action="store_true", help="cluster has FIPS enabled")
    result.add_argument("--profile", default=os.environ.get("CPD_PROFILE_NAME") or f"{os.environ.get('CPD_USERNAME', 'cpadmin')}-profile")
    result.add_argument("--output", type=Path, help="new payload path (required for render/apply); never overwritten")
    result.add_argument("--timeout", type=int, default=2700, help="readiness timeout in seconds (default: 2700)")
    result.add_argument("--db2-namespace")
    result.add_argument("--db2-instance")
    result.add_argument("--db2-pod")
    result.add_argument("--database", default="BLUDB")
    result.add_argument("--db2-user", help="existing platform connection's database authorization ID")
    result.add_argument("--db2-schema")
    result.add_argument("--db2-os-user", default="db2inst1")
    return result


def main(argv=None):
    arguments = parser()
    args = arguments.parse_args(argv)
    if not args.wait_only and not args.output:
        arguments.error("--output is required for render/apply")
    if args.timeout <= 0:
        arguments.error("--timeout must be positive")
    try:
        payload = build_payload(args)
        if not (args.apply or args.wait_only):
            write_payload(args.output, payload)
            print("Payload rendered with mode 0600; no cluster calls made")
            return 0
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        from tui.common.kube import Kube
        from tui.instance_manager.providers.cpd.cpdcli import CpdCli
        from tui.instance_manager.providers.cpd.provider import CpdProvider
        from tui.instance_manager.providers.k8s_crd.cluster import Cluster
        provider = CpdProvider(Cluster(Kube()), args.platform_namespace or args.namespace, CpdCli(args.profile))
        provision(provider, args, payload)
        return 0
    except (ValueError, PreparationError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - vendor responses can contain JDBC credentials
        print("[ERROR] Provisioning operation failed; inspect local CLI diagnostics with credentials redacted. No automatic retry was made; check instance state before resubmitting.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
