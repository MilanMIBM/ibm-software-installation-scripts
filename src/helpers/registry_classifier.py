"""Classify a container registry as a cloud ("private") or local ("local") registry.

Used by the private registry mirroring track (scripts/private_registry_mirroring/)
and by the CP4D config notebook, so both reach the same verdict for a host.

    python3 registry_classifier.py classify <registry-root> [--local-state FILE]
        -> prints "<local|private|unknown><TAB><reason>"
    python3 registry_classifier.py push-root <registry-root> <local|cloud>
        -> prints the root to push to (U5: ICR private endpoints are not
           reachable from outside IBM Cloud, so "local" pushes go to the
           public endpoint of the same namespace)

Only the standard library is used: this also runs on an air-gapped workstation
where the repo's virtualenv may not exist.
"""

import ipaddress
import os
import socket
import sys

# Registries that are hosted services. Matching is on the host (port removed):
# an exact match or a "*.<suffix>" match.
CLOUD_SUFFIXES = (
    "icr.io",                # IBM Cloud Container Registry (all regions, private.*)
    "quay.io",
    "azurecr.io",            # Azure Container Registry
    "amazonaws.com",         # ECR: <acct>.dkr.ecr.<region>.amazonaws.com
    "gcr.io",
    "pkg.dev",               # Google Artifact Registry
    "ghcr.io",
    "docker.io",
    "registry-1.docker.io",
    "registry.gitlab.com",
    "jfrog.io",
    "ocir.io",               # Oracle
)

LOCAL_SUFFIXES = (".local", ".lan", ".internal", ".home.arpa", ".localdomain")

PRIVATE_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
    "169.254.0.0/16", "127.0.0.0/8", "fc00::/7", "fe80::/10", "::1/128",
)]


def split_host(root):
    """'host:port/ns/path' -> ('host', 'host:port')."""
    hostport = root.split("/", 1)[0].strip().lower()
    host = hostport
    if hostport.startswith("["):                     # [ipv6]:port
        host = hostport[1:hostport.index("]")]
    elif hostport.count(":") == 1:
        host = hostport.split(":", 1)[0]
    return host, hostport


def _is_private_ip(text):
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return None
    return any(ip in net for net in PRIVATE_NETS)


def _local_state_hostport(path):
    """host:port from the local registry state file written by 0.3 (KEY=VALUE lines)."""
    if not path or not os.path.isfile(path):
        return ""
    vals = {}
    with open(path) as f:
        for line in f:
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.strip().split("=", 1)
                vals[k.replace("export ", "").strip()] = v.strip().strip('"').strip("'")
    host, port = vals.get("LOCAL_REGISTRY_HOST", ""), vals.get("LOCAL_REGISTRY_PORT", "")
    return f"{host}:{port}".lower() if host and port else ""


def classify(root, local_state=""):
    if not root:
        return "unknown", "no registry root given"
    host, hostport = split_host(root)

    state = _local_state_hostport(local_state)
    if state and state == hostport:
        return "local", "matches the local registry started by 0.3_local_registry.sh"

    for suffix in CLOUD_SUFFIXES:
        if host == suffix or host.endswith("." + suffix):
            return "private", f"cloud registry domain ({suffix})"

    if host == "localhost":
        return "local", "localhost"
    verdict = _is_private_ip(host)
    if verdict is True:
        return "local", "private/loopback IP address"
    if verdict is False:
        return "private", "public IP address"
    if "." not in host:
        return "local", "single-label host name"
    if host.endswith(LOCAL_SUFFIXES):
        return "local", "local DNS suffix"
    own = {socket.gethostname().lower(), socket.getfqdn().lower()}
    if host in own:
        return "local", "this machine's host name"

    try:
        addrs = {ai[4][0] for ai in socket.getaddrinfo(host, None)}
    except OSError:
        return "unknown", f"cannot resolve {host}; set MIRROR_IMAGE_SOURCE explicitly"
    private = [_is_private_ip(a.split("%", 1)[0]) for a in addrs]
    if private and all(private):
        return "local", "resolves only to private addresses"
    if private and not any(private):
        return "private", "resolves to public addresses"
    return "unknown", "resolves to a mix of private and public addresses; set MIRROR_IMAGE_SOURCE explicitly"


def push_root(root, push_from):
    """ICR private endpoints (private.icr.io, private.<region>.icr.io) are reachable
    only from inside IBM Cloud; pushing "from local" goes to the public endpoint
    of the same namespace. Any other registry pushes where it pulls."""
    host, hostport = split_host(root)
    rest = root[len(root.split("/", 1)[0]):]
    if push_from == "local" and host.startswith("private.") and host.endswith("icr.io"):
        return hostport[len("private."):] + rest
    return root


def main(argv):
    if len(argv) >= 3 and argv[1] == "classify":
        state = ""
        if "--local-state" in argv:
            state = argv[argv.index("--local-state") + 1]
        kind, reason = classify(argv[2], state)
        print(f"{kind}\t{reason}")
        return 0
    if len(argv) == 4 and argv[1] == "push-root":
        if argv[3] not in ("local", "cloud"):
            print("push-root: second argument must be local or cloud", file=sys.stderr)
            return 2
        print(push_root(argv[2], argv[3]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
