#!/usr/bin/env python3
"""Upload (or update) cpd_vars.sh and install-options.yml into IBM Cloud Secrets Manager.

Each file becomes one key/value (``kv``) secret in the chosen secret group, so the
variables stay individually readable in the Secrets Manager UI and the files can be
rebuilt later with ibmcloud-secrets-manager-retrieve-cpd-vars.py.

Versioning
----------
Re-running compares the file against what is already stored:

* identical -> nothing is written
* changed   -> a new version of the same secret (Secrets Manager's own versioning);
  the payload it replaces stays reachable as ``previous``

``--versioning iterations`` switches to the alternative scheme, where each change
becomes a sibling secret (``<name>-v2``, ``<name>-v3``, ...) so nothing ages out,
and ``--overwrite`` versions the current iteration in place instead.

Retrieval takes the current version by default, or ``--secret-version
previous|<id>``, or ``--iteration N`` for a bundle built with iterations.

Examples
--------
    # Defaults: cp4d_config/cpd_vars.sh + its install-options file, group 'default'
    ./ibmcloud-secrets-manager-upload-update-cpd-vars.py \
        --instance-id 1a2b3c4d-... --region eu-de

    # A different config set, into a dedicated group, under its own name prefix
    ./ibmcloud-secrets-manager-upload-update-cpd-vars.py \
        --cpd-vars ~/clusters/itz-42/cpd_vars.sh \
        --install-options ~/clusters/itz-42/install-options-wx.yml \
        --secret-group cp4d-configs --create-group --prefix itz-42

    # Also stash the credentials the install scripts write out
    ./ibmcloud-secrets-manager-upload-update-cpd-vars.py \
        --extra-file cp4d_config/cpd_instance_details.sh --dry-run

Credentials come from --apikey or SECRETS_MANAGER_APIKEY / IBM_CLOUD_API_KEY /
IBMCLOUD_API_KEY, and a repo-root .env is loaded automatically when present.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "helpers"
    ),
)

import ibmcloud_secrets_manager_helpers as smh

DEFAULT_CONFIG_DIR = "cp4d_config"
DEFAULT_CPD_VARS = "cpd_vars.sh"
DEFAULT_INSTALL_OPTIONS = "install-options.yml"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="\n".join(__doc__.split("\n\n")[1:]),
    )

    files = parser.add_argument_group("files")
    files.add_argument(
        "--cpd-vars",
        help=f"Path to the cpd_vars.sh to upload (default: {DEFAULT_CONFIG_DIR}/{DEFAULT_CPD_VARS}).",
    )
    files.add_argument(
        "--install-options",
        help="Path to install-options.yml. Defaults to INSTALL_OPTIONS_FILE from cpd_vars.sh, "
        f"otherwise {DEFAULT_CONFIG_DIR}/{DEFAULT_INSTALL_OPTIONS}.",
    )
    files.add_argument(
        "--no-install-options",
        action="store_true",
        help="Upload only cpd_vars.sh (and any --extra-file).",
    )
    files.add_argument(
        "--extra-file",
        action="append",
        default=[],
        metavar="PATH",
        help="Additional file to store in the same bundle; repeatable. "
        "*.sh/*.env are parsed into key/value pairs, anything else is stored verbatim.",
    )

    smh.add_connection_args(parser)

    behaviour = parser.add_argument_group("behaviour")
    behaviour.add_argument(
        "--create-group",
        action="store_true",
        help="Create the secret group when it does not exist yet.",
    )
    behaviour.add_argument(
        "--description",
        help="Description to set on every secret in this bundle.",
    )
    behaviour.add_argument(
        "--label",
        action="append",
        default=[],
        help="Extra label to set on every secret; repeatable.",
    )
    behaviour.add_argument(
        "--versioning",
        choices=smh.VERSIONING_MODES,
        default=None,
        help=f"How to keep a changed file (default: {smh.DEFAULT_VERSIONING}, "
        "env: CPD_SECRETS_VERSIONING). 'native' uses Secrets Manager's own versions of "
        "one secret (the current and previous payloads stay retrievable); 'iterations' "
        "keeps a sibling secret per change (<name>-v2, -v3, ... - nothing ages out).",
    )
    behaviour.add_argument(
        "--overwrite",
        action="store_true",
        help="Iterations mode only: when the file differs, version the current iteration "
        "in place instead of creating the next one.",
    )
    behaviour.add_argument(
        "--values-only",
        action="store_true",
        help="Do not store the file layout. Values still round-trip, but comments, section banners and quoting style are lost on retrieval.",
    )
    behaviour.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be uploaded (values redacted) and which iteration it would "
        "land in, without writing anything. Read-only lookups still run when credentials "
        "are available.",
    )
    return parser.parse_args(argv)


def resolve_targets(args: argparse.Namespace, repo_root: str) -> list[str]:
    """Work out which files to upload, in bundle order."""
    cpd_vars = args.cpd_vars or os.path.join(
        repo_root, DEFAULT_CONFIG_DIR, DEFAULT_CPD_VARS
    )
    cpd_vars = os.path.abspath(os.path.expanduser(cpd_vars))
    if not os.path.isfile(cpd_vars):
        raise SystemExit(f"ERROR: cpd_vars file not found: {cpd_vars}")

    targets = [cpd_vars]

    if not args.no_install_options:
        install_options = args.install_options
        if install_options:
            install_options = os.path.abspath(os.path.expanduser(install_options))
            if not os.path.isfile(install_options):
                raise SystemExit(
                    f"ERROR: install-options file not found: {install_options}"
                )
        else:
            install_options = default_install_options(cpd_vars, repo_root)
            if install_options is None:
                print(
                    "NOTE: no install-options file found next to cpd_vars.sh; skipping it. "
                    "Pass --install-options to point at one.",
                    file=sys.stderr,
                )
        if install_options:
            targets.append(install_options)

    for extra in args.extra_file:
        path = os.path.abspath(os.path.expanduser(extra))
        if not os.path.isfile(path):
            raise SystemExit(f"ERROR: extra file not found: {path}")
        targets.append(path)

    # Preserve order while dropping duplicates.
    seen: set[str] = set()
    return [t for t in targets if not (t in seen or seen.add(t))]


def default_install_options(cpd_vars_path: str, repo_root: str) -> str | None:
    """Find the install-options file that belongs to a cpd_vars.sh.

    Honours INSTALL_OPTIONS_FILE from the file itself (that is the name cpd-cli
    is told to use), then falls back to the conventional locations.
    """
    config_dir = os.path.dirname(cpd_vars_path)
    candidates = []

    with open(cpd_vars_path, "r", encoding="utf-8") as handle:
        _, values, _ = smh.parse_shell_vars(handle.read())
    declared = values.get("INSTALL_OPTIONS_FILE")
    if declared and "$" not in declared:
        candidates.append(os.path.join(config_dir, declared))

    candidates.append(os.path.join(config_dir, DEFAULT_INSTALL_OPTIONS))
    candidates.append(
        os.path.join(repo_root, DEFAULT_CONFIG_DIR, DEFAULT_INSTALL_OPTIONS)
    )

    for candidate in candidates:
        if os.path.isfile(candidate):
            return os.path.abspath(candidate)
    return None


def check_yaml(path: str, text: str) -> None:
    """Warn when a YAML file does not parse - it is stored either way."""
    if not path.endswith((".yml", ".yaml")):
        return
    try:
        import yaml
    except ImportError:
        return
    try:
        list(yaml.safe_load_all(text))
    except yaml.YAMLError as exc:
        print(
            f"WARNING: {os.path.basename(path)} is not valid YAML ({exc}).",
            file=sys.stderr,
        )


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    repo_root = smh.repo_root_from(__file__)

    loaded = smh.load_env_file(args.env_file, repo_root)
    if loaded:
        print(f"Loaded environment from {loaded}")

    targets = resolve_targets(args, repo_root)
    prefix = smh.resolve_prefix(args.prefix)
    labels = sorted({"cpd-config", prefix, *args.label})
    labels = [label for label in labels if 2 <= len(label) <= 30]

    payloads = []
    for path in targets:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
        check_yaml(path, text)
        data, custom_metadata, warnings = smh.build_payload(
            path, text, store_layout=not args.values_only
        )
        for warning in warnings:
            print(f"WARNING: {os.path.basename(path)}: {warning}", file=sys.stderr)
        size = smh.payload_size(data)
        if size > smh.PAYLOAD_WARN_BYTES:
            print(
                f"WARNING: {os.path.basename(path)} payload is {size} bytes and may exceed "
                "the Secrets Manager payload limit for a single secret.",
                file=sys.stderr,
            )
        payloads.append(
            (path, smh.secret_name_for(prefix, path), data, custom_metadata, size)
        )

    # A dry run still connects when it can: comparing against what is already
    # stored is the only way to say whether this upload would iterate.
    client, group_id, group_name = connect(args)

    print(f"\nBundle prefix : {prefix}")
    print(f"Secret group  : {group_name} ({group_id})" if group_id else f"Secret group  : {group_name}")
    print(f"Labels        : {', '.join(labels)}")
    versioning = (
        args.versioning or os.environ.get("CPD_SECRETS_VERSIONING") or smh.DEFAULT_VERSIONING
    )
    if versioning not in smh.VERSIONING_MODES:
        raise SystemExit(
            f"ERROR: unknown versioning mode '{versioning}'; "
            f"expected one of {', '.join(smh.VERSIONING_MODES)}."
        )
    print(f"Versioning    : {versioning}")
    if args.overwrite and versioning == smh.VERSIONING_NATIVE:
        print(
            "NOTE: --overwrite has no effect in native mode - every change is already "
            "a new version of the same secret.",
            file=sys.stderr,
        )

    plans = []
    for path, name, data, custom_metadata, size in payloads:
        keys = smh.variable_names(data)
        plan = None
        if client is not None and group_id is not None:
            plan = smh.plan_kv_upload(
                client,
                base_name=name,
                group_id=group_id,
                data=data,
                versioning=versioning,
                overwrite=args.overwrite,
            )
        plans.append(plan)

        print(
            f"\n{os.path.relpath(path, repo_root) if path.startswith(repo_root) else path}"
        )
        print(f"  secret name : {plan['target_name'] if plan else name}")
        print(f"  format      : {custom_metadata[smh.META_FORMAT]}")
        if custom_metadata[smh.META_FORMAT] == smh.FORMAT_SHELL:
            print(f"  payload     : {len(keys)} variable(s), {size} bytes")
        else:
            print(f"  payload     : whole file under '{smh.CONTENT_KEY}', {size} bytes")
        if plan:
            print(f"  stored      : {describe_stored(plan)}")
            print(f"  action      : {describe_action(plan)}")
        if args.dry_run:
            for key in keys:
                print(f"      {key} = {smh.redact(data[key])}")

    if args.dry_run:
        print("\nDry run - nothing was sent to Secrets Manager.")
        return 0

    print()
    iterated = False
    for (path, name, data, custom_metadata, _), plan in zip(payloads, plans, strict=True):
        description = args.description or (
            f"IBM Software Hub config file {custom_metadata[smh.META_FILE]} "
            f"(bundle '{prefix}', uploaded by {smh.TOOL_NAME})"
        )
        result = smh.put_kv_secret(
            client,
            name=name,
            group_id=group_id,
            data=data,
            description=description,
            labels=labels,
            custom_metadata=custom_metadata,
            versioning=versioning,
            overwrite=args.overwrite,
            plan=plan,
        )
        iterated = iterated or result["action"] == "iterate"
        secret_id = (result["secret"] or {}).get("id", "-")
        where = f"version {result['version_number']}"
        if result["versioning"] == smh.VERSIONING_ITERATIONS:
            where = f"iteration {result['iteration']}, {where}"
        if result.get("version"):
            where += f" [{result['version']['id']}]"
        print(
            f"  {ACTION_LABELS[result['action']]}: {result['target_name']} "
            f"({where}, id {secret_id})"
        )

    print(
        "\nDone. Retrieve the current config with:\n"
        f"  src/utils/ibmcloud-secrets-manager-retrieve-cpd-vars.sh --prefix {prefix} "
        f"--secret-group {group_name}"
    )
    if iterated:
        print("  ... or an earlier iteration by adding --iteration <N> (see --list).")
    else:
        print("  ... or the config before this upload by adding --secret-version previous.")
    return 0


ACTION_LABELS = {
    "create": "created   ",
    "iterate": "iterated  ",
    "version": "versioned ",
    "unchanged": "unchanged ",
}


def describe_stored(plan: dict) -> str:
    """One line about what the instance already holds for this file."""
    if plan["latest"] == 0:
        return "nothing yet"
    where = f"version {plan['stored_version_number']}"
    if plan["versioning"] == smh.VERSIONING_ITERATIONS:
        where = f"iteration {plan['latest']}, {where}"
    line = f"{where} - {smh.describe_diff(plan['diff'])}"
    stored = plan.get("stored_versioning")
    if stored and stored != plan["versioning"]:
        line += f" [uploaded with {stored} versioning; this run uses {plan['versioning']}]"
    return line


def describe_action(plan: dict) -> str:
    """One line about what this upload is going to do."""
    if plan["action"] == "create":
        return f"create '{plan['target_name']}' at version 1 ({plan['versioning']} versioning)"
    if plan["action"] == "unchanged":
        return f"nothing to do - stored payload is identical (stays at version {plan['version_number']})"
    if plan["action"] == "version":
        return (
            f"take '{plan['target_name']}' to version {plan['version_number']}; "
            f"version {plan['stored_version_number']} becomes the 'previous' alias"
        )
    return (
        f"create '{plan['target_name']}' (iteration {plan['iteration']}); "
        f"iteration {plan['latest']} is left untouched"
    )


def connect(args: argparse.Namespace):
    """Build the client and resolve the group, tolerating a credential-less dry run.

    Returns:
        (client, group_id, group_name). During a dry run the client and group id
        may be None, in which case the run only previews the payloads.
    """
    fallback_name = args.secret_group or os.environ.get("SECRETS_MANAGER_GROUP") or "default"
    try:
        client = smh.build_client(
            args.apikey,
            service_url=args.service_url,
            instance_id=args.instance_id,
            region=args.region,
        )
    except ValueError as exc:
        if not args.dry_run:
            raise
        print(f"\nNOTE: {exc}\n      Dry run continues without comparing against the instance.")
        return None, None, fallback_name

    try:
        # Never create the group during a dry run.
        group_id, group_name = smh.resolve_secret_group(
            client, args.secret_group, create=args.create_group and not args.dry_run
        )
    except ValueError as exc:
        if not (args.dry_run and args.create_group):
            raise
        print(f"\nNOTE: {exc}\n      --create-group is set, so it would be created.")
        return None, None, fallback_name

    return client, group_id, group_name


if __name__ == "__main__":
    sys.exit(smh.run_cli(main, sys.argv[1:]))
