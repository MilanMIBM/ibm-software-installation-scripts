#!/usr/bin/env python3
"""Advisory, read-only check of installed services sharing governance dependencies.

Uses owner references and explicit spec.scaleConfig values, so unrelated services
and installations without shared dependencies can use independent sizes. Warnings
never change cluster resources or make the installation fail.
"""

import argparse
import json
import subprocess
from urllib.parse import quote


class ClusterReader:
    def __init__(self):
        self.cache = {}
        self.incomplete = False

    def get(self, path):
        if path in self.cache:
            return self.cache[path]
        self.cache[path] = None
        try:
            result = subprocess.run(
                ["oc", "get", "--raw", path, "--request-timeout=10s"],
                capture_output=True, text=True, timeout=15,
            )
        except (OSError, subprocess.TimeoutExpired):
            self.unreadable(path)
            return None
        if result.returncode:
            if "(NotFound)" not in result.stderr:
                self.unreadable(path)
            return None
        try:
            value = json.loads(result.stdout)
            if not isinstance(value, dict):
                raise ValueError("expected an API object")
        except ValueError:
            self.unreadable(path)
            return None
        self.cache[path] = value
        return value

    def unreadable(self, path):
        self.incomplete = True
        print(f"[WARN] Shared governance scale check could not read {path}; comparison is incomplete.")

    def resource_path(self, api_version, kind, namespace):
        prefix = "/apis" if "/" in api_version else "/api"
        discovery_path = f"{prefix}/{api_version}"
        discovery = self.get(discovery_path)
        for resource in (discovery or {}).get("resources", []):
            if resource.get("kind") == kind and resource.get("namespaced") and "/" not in resource["name"]:
                return f"{discovery_path}/namespaces/{quote(namespace, safe='')}/{resource['name']}"
        return None


def scale(resource):
    value = resource.get("spec", {}).get("scaleConfig")
    return value.strip() if isinstance(value, str) and value.strip() else None


def label(resource):
    return f"{resource['kind']}/{resource['metadata']['name']}"


def shared_owners(reader, dependency, namespace):
    owners = {}
    for reference in dependency["metadata"].get("ownerReferences", []):
        path = reader.resource_path(reference["apiVersion"], reference["kind"], namespace)
        if not path:
            continue
        owner = reader.get(f"{path}/{quote(reference['name'], safe='')}")
        if not owner or owner["metadata"].get("deletionTimestamp"):
            continue
        # A recreated parent with the same name does not own the old dependency.
        if owner["metadata"].get("uid") != reference.get("uid"):
            continue
        if scale(owner):
            owners[reference["uid"]] = owner
    return sorted(owners.values(), key=label)


def compare(dependency, owners):
    """Return a conflict warning or a reconciliation note for shared owners."""
    if len(owners) < 2:
        return None
    sizes = {scale(owner) for owner in owners}
    description = ", ".join(f"{label(owner)}={scale(owner)}" for owner in owners)
    if len(sizes) > 1:
        return (
            "WARN",
            f"Conflicting owner scaleConfig values for {label(dependency)}: {description} "
            f"(dependency={scale(dependency) or 'unset'}). Their operators may repeatedly "
            "reconfigure the shared dependency. Review the related services' supported sizing "
            "together; no resources were changed.",
        )
    if scale(dependency) and scale(dependency) not in sizes:
        return (
            "INFO",
            f"{label(dependency)} currently uses {scale(dependency)}; its owners agree on "
            f"{scale(owners[0])}. Reconciliation may still be in progress; recheck after it completes.",
        )
    return None


def check(namespace, reader):
    group = reader.get("/apis/wkc.cpd.ibm.com")
    checked = conflicts = pending = 0
    if group:
        api_version = group["preferredVersion"]["groupVersion"]
        for kind in ("Metadataimports", "Enrichment"):
            path = reader.resource_path(api_version, kind, namespace)
            if not path:
                continue
            listing = reader.get(path)
            for dependency in (listing or {}).get("items", []):
                if dependency["metadata"].get("deletionTimestamp"):
                    continue
                owners = shared_owners(reader, dependency, namespace)
                if len(owners) < 2:
                    continue
                checked += 1
                message = compare(dependency, owners)
                if message:
                    level, detail = message
                    print(f"[{level}] {detail}")
                    conflicts += level == "WARN"
                    pending += level == "INFO"
    if reader.incomplete:
        print("[WARN] Shared governance scale check is incomplete; no resources were changed.")
    else:
        print(
            f"[INFO] Shared governance scale check in {namespace}: {checked} dependencies "
            f"with multiple explicitly sized owners, {conflicts} conflicting owner configurations, "
            f"{pending} dependencies awaiting alignment. No resources were changed."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", required=True, help="Software Hub operands namespace")
    args = parser.parse_args()
    check(args.namespace, ClusterReader())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
