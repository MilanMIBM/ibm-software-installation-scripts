#!/usr/bin/env python3
"""Rebuild cpd_vars.sh / install-options.yml from IBM Cloud Secrets Manager.

Reads the key/value (``kv``) secrets written by
ibmcloud-secrets-manager-upload-update-cpd-vars.py and writes the files back out,
comments and quoting included, ready for src/scripts/source_env_setup.sh to source.

Examples
--------
    # See what a bundle holds before writing anything
    ./ibmcloud-secrets-manager-retrieve-cpd-vars.py --instance-id 1a2b... --region eu-de --list

    # Restore into cp4d_config/ (existing files are backed up first)
    ./ibmcloud-secrets-manager-retrieve-cpd-vars.py --instance-id 1a2b... --region eu-de

    # A named bundle from its own group, into a scratch directory
    ./ibmcloud-secrets-manager-retrieve-cpd-vars.py \
        --prefix itz-42 --secret-group cp4d-configs --output-dir ~/clusters/itz-42

    # Just cpd_vars.sh, straight to stdout (contains secrets)
    ./ibmcloud-secrets-manager-retrieve-cpd-vars.py --only cpd_vars.sh --stdout

    # Roll back to the config as it was before the last upload
    ./ibmcloud-secrets-manager-retrieve-cpd-vars.py --secret-version previous

    # Roll back to an earlier iteration (bundles uploaded with --versioning iterations)
    ./ibmcloud-secrets-manager-retrieve-cpd-vars.py --iteration 2

By default this writes the current version of each file. --secret-version reaches
into Secrets Manager's version history (``current``, ``previous``, or a version id
from --list); --iteration picks between the sibling secrets that the ``iterations``
versioning mode creates.

Credentials come from --apikey or SECRETS_MANAGER_APIKEY / IBM_CLOUD_API_KEY /
IBMCLOUD_API_KEY, and a repo-root .env is loaded automatically when present.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "helpers"))

import ibmcloud_secrets_manager_helpers as smh

DEFAULT_CONFIG_DIR = "cp4d_config"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="\n".join(__doc__.split("\n\n")[1:]),
    )

    smh.add_connection_args(parser)

    output = parser.add_argument_group("output")
    output.add_argument(
        "--output-dir",
        help=f"Directory to write the files into (default: {DEFAULT_CONFIG_DIR}/ in the repo).",
    )
    output.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="FILE_OR_SECRET",
        help="Restore only this file name (e.g. cpd_vars.sh) or secret name; repeatable.",
    )
    output.add_argument(
        "--cpd-vars-out",
        help="Write the cpd_vars file to this exact path instead of <output-dir>/<original name>.",
    )
    output.add_argument(
        "--install-options-out",
        help="Write the install-options file to this exact path instead of "
        "<output-dir>/<original name>.",
    )
    output.add_argument(
        "--stdout",
        action="store_true",
        help="Print the files instead of writing them (output contains secrets).",
    )
    output.add_argument(
        "--list",
        action="store_true",
        dest="list_only",
        help="List the secrets in the bundle and what they hold, without writing files.",
    )
    output.add_argument(
        "--no-backup",
        action="store_true",
        help="Overwrite existing files without keeping a timestamped .bak copy.",
    )
    output.add_argument(
        "--all-in-group",
        action="store_true",
        help="Ignore the name prefix and take every kv secret in the group.",
    )
    output.add_argument(
        "--iteration",
        type=int,
        metavar="N",
        help="Restore iteration N of each file instead of the newest one "
        "(iterations exist only for bundles uploaded with --versioning iterations).",
    )
    output.add_argument(
        "--secret-version",
        metavar="ID|current|previous",
        help="Restore a specific Secrets Manager version instead of the current one. "
        "'previous' is the config as it was before the last upload; a raw version id "
        "(see --list) only works when a single file is selected.",
    )
    return parser.parse_args(argv)


def select_iterations(grouped: dict, requested: int | None) -> tuple[list[tuple[str, int, dict]], list[str]]:
    """Pick one secret per file: the requested iteration, else the newest.

    Returns:
        (selected, missing) where selected is [(base_name, iteration, metadata)]
        and missing lists the base names that have no such iteration.
    """
    selected: list[tuple[str, int, dict]] = []
    missing: list[str] = []
    for base, iterations in sorted(grouped.items()):
        if requested is None:
            chosen = max(iterations)
        elif requested in iterations:
            chosen = requested
        else:
            missing.append(base)
            continue
        selected.append((base, chosen, iterations[chosen]))
    return selected, missing


def wanted(args: argparse.Namespace, secret_name: str, file_name: str) -> bool:
    if not args.only:
        return True
    return any(item in (secret_name, file_name) for item in args.only)


def output_path(args: argparse.Namespace, output_dir: str, file_name: str) -> str:
    """Where a rebuilt file goes, honouring the per-file overrides."""
    if args.cpd_vars_out and file_name.startswith("cpd_vars"):
        return os.path.abspath(os.path.expanduser(args.cpd_vars_out))
    if args.install_options_out and file_name.startswith("install-options"):
        return os.path.abspath(os.path.expanduser(args.install_options_out))
    return os.path.join(output_dir, file_name)


def write_file(path: str, text: str, keep_backup: bool) -> str:
    """Write ``text`` to ``path``, backing up a differing existing file first."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)

    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as handle:
            if handle.read() == text:
                return "unchanged"
        if keep_backup:
            stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
            backup = f"{path}.bak-{stamp}"
            os.replace(path, backup)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            return f"updated (previous file kept at {os.path.basename(backup)})"

    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return "written"


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    repo_root = smh.repo_root_from(__file__)

    loaded = smh.load_env_file(args.env_file, repo_root)
    if loaded:
        print(f"Loaded environment from {loaded}")

    prefix = smh.resolve_prefix(args.prefix)
    output_dir = os.path.abspath(
        os.path.expanduser(args.output_dir or os.path.join(repo_root, DEFAULT_CONFIG_DIR))
    )

    client = smh.build_client(
        args.apikey,
        service_url=args.service_url,
        instance_id=args.instance_id,
        region=args.region,
    )
    group_id, group_name = smh.resolve_secret_group(client, args.secret_group)

    listed = smh.list_kv_secrets(client, group_id, None if args.all_in_group else prefix)
    if not listed:
        scope = "any kv secret" if args.all_in_group else f"kv secrets named '{prefix}-*'"
        raise SystemExit(f"ERROR: secret group '{group_name}' holds no {scope}.")

    grouped = smh.group_iterations(listed)
    if args.list_only:
        # Listing shows every iteration; restoring picks one per file.
        wanted_secrets = [
            (base, iteration, meta)
            for base, iterations in sorted(grouped.items())
            for iteration, meta in sorted(iterations.items())
        ]
        missing = []
    else:
        wanted_secrets, missing = select_iterations(grouped, args.iteration)

    version = args.secret_version
    if version and version not in smh.VERSION_ALIASES and len(wanted_secrets) > 1:
        raise SystemExit(
            f"ERROR: --secret-version {version} is a single secret's version id, but "
            f"{len(wanted_secrets)} files are selected. Narrow it with --only, or use "
            f"one of the aliases: {', '.join(smh.VERSION_ALIASES)}."
        )

    print(f"Secret group  : {group_name} ({group_id})")
    print(f"Bundle prefix : {'(all kv secrets)' if args.all_in_group else prefix}")
    print(f"Iteration     : {args.iteration if args.iteration else 'newest of each file'}")
    print(f"Version       : {version or 'current'}")

    for base in missing:
        print(
            f"WARNING: {base} has no iteration {args.iteration} "
            f"(available: {', '.join(str(i) for i in sorted(grouped[base]))}); skipped.",
            file=sys.stderr,
        )

    written = 0
    for base, iteration, meta in wanted_secrets:
        secret_id = meta["id"]
        # Metadata comes from the secret; the payload from whichever version was asked for.
        secret = client.get_secret_metadata(id=secret_id).get_result()
        custom_metadata = secret.get("custom_metadata") or {}
        if version:
            data = smh.get_secret_version_data(client, secret_id, version)
        else:
            data = client.get_secret(id=secret_id).get_result().get("data") or {}

        file_name, text = smh.payload_to_file(
            data, custom_metadata, secret_name=secret.get("name", "")
        )

        if not wanted(args, secret.get("name", ""), file_name):
            continue

        keys = smh.variable_names(data)
        updated = custom_metadata.get(smh.META_UPDATED) or meta.get("updated_at", "")
        newest = iteration == max(grouped[base])
        mode = smh.stored_versioning(custom_metadata) or smh.DEFAULT_VERSIONING
        at_version = custom_metadata.get(smh.META_ITERATION, "?")
        print(f"\n{secret.get('name')}  ->  {file_name}")
        if mode == smh.VERSIONING_ITERATIONS:
            print(
                f"  iteration   : {iteration}{' (newest)' if newest else ''}, "
                f"at version {at_version}, updated {updated}"
            )
        else:
            print(f"  versioning  : {mode}, at version {at_version}, updated {updated}")
        if version:
            print(f"  restoring   : version '{version}'")
        if keys:
            print(f"  payload     : {len(keys)} variable(s)")
        else:
            print(f"  payload     : whole file, {len(text)} chars")

        if args.list_only:
            for entry in smh.list_secret_versions(client, secret_id):
                print(f"      version {smh.describe_version(entry)}")
            for key in keys:
                print(f"      {key} = {smh.redact(data[key])}")
            continue

        if args.stdout:
            print(f"# ===== {file_name} =====")
            sys.stdout.write(text if text.endswith("\n") else text + "\n")
            written += 1
            continue

        target = output_path(args, output_dir, file_name)
        status = write_file(target, text, keep_backup=not args.no_backup)
        print(f"  {status}: {target}")
        written += 1

    if args.list_only:
        return 0

    if not written:
        reason = (
            f"no file has an iteration {args.iteration}"
            if args.iteration and missing
            else "nothing matched --only"
        )
        raise SystemExit(f"ERROR: {reason}; use --list to see what the bundle holds.")

    if not args.stdout:
        print(
            f"\nRestored {written} file(s) into {output_dir}.\n"
            "Source them with: source src/scripts/source_env_setup.sh"
        )
    return 0


if __name__ == "__main__":
    sys.exit(smh.run_cli(main, sys.argv[1:]))
