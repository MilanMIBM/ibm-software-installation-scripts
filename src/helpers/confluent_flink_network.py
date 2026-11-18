"""Grant Flink ingress without introducing isolation on additional pods."""

import argparse
import hashlib
import json
import sys

FLINK_NAMESPACE_LABEL = "confluent.platform/flink-namespace"
# Pod "app" label values of the Kafka-side workloads Flink reaches. Scripts mode: StatefulSet broker and
# Deployment schema-registry. Operator mode (CFK) passes its own values with --apps (kafka, schema-registry; V12).
DEFAULT_APPS = ("broker", "schema-registry")
REGISTRY_APP = "schema-registry"


def matches(selector, labels):
    if any(labels.get(key) != value for key, value in selector.get("matchLabels", {}).items()):
        return False
    for expression in selector.get("matchExpressions", []):
        key = expression["key"]
        operator = expression["operator"]
        values = expression.get("values", [])
        if operator == "In":
            valid = key in labels and labels[key] in values
        elif operator == "NotIn":
            valid = key not in labels or labels[key] not in values
        elif operator == "Exists":
            valid = key in labels
        elif operator == "DoesNotExist":
            valid = key not in labels
        else:
            raise ValueError(f"Unsupported label selector operator: {operator}")
        if not valid:
            return False
    return True


def render(resources, kafka_namespace, flink_namespace, use_registry=True, apps=None):
    """apps: the pod "app" label values to protect (default DEFAULT_APPS); use_registry=False drops
    schema-registry from them."""
    apps = set(DEFAULT_APPS if apps is None else apps)
    if not use_registry:
        apps.discard(REGISTRY_APP)
    pods = [
        item["metadata"].get("labels", {})
        for item in resources["items"]
        if item["kind"] == "Pod" and item["metadata"].get("labels", {}).get("app") in apps
    ]
    policies = []
    for item in resources["items"]:
        if item["kind"] != "NetworkPolicy":
            continue
        metadata = item["metadata"]
        if FLINK_NAMESPACE_LABEL in metadata.get("labels", {}):
            continue
        spec = item["spec"]
        if "Ingress" not in spec.get("policyTypes", ["Ingress"]):
            continue
        selector = spec.get("podSelector", {})
        if not any(matches(selector, labels) for labels in pods):
            continue
        identity = f"{flink_namespace}:{metadata['uid']}"
        suffix = hashlib.sha256(identity.encode()).hexdigest()[:16]
        policies.append({
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": {
                "name": f"allow-flink-{suffix}",
                "namespace": kafka_namespace,
                "labels": {
                    "app.kubernetes.io/part-of": "confluent",
                    FLINK_NAMESPACE_LABEL: flink_namespace,
                },
                "ownerReferences": [{
                    "apiVersion": "networking.k8s.io/v1",
                    "kind": "NetworkPolicy",
                    "name": metadata["name"],
                    "uid": metadata["uid"],
                }],
            },
            "spec": {
                "podSelector": selector,
                "policyTypes": ["Ingress"],
                "ingress": [{"from": [{"namespaceSelector": {"matchLabels": {
                    "kubernetes.io/metadata.name": flink_namespace,
                }}}]}],
            },
        })
    return {"apiVersion": "v1", "kind": "List", "items": policies}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kafka-namespace", required=True)
    parser.add_argument("--flink-namespace", required=True)
    parser.add_argument("--no-schema-registry", action="store_true")
    parser.add_argument("--apps", default=None,
                        help=f"comma-separated pod 'app' label values (default: {','.join(DEFAULT_APPS)})")
    args = parser.parse_args()
    apps = None
    if args.apps is not None:
        apps = [a.strip() for a in args.apps.split(",") if a.strip()]
        if not apps:
            parser.error("--apps needs at least one app label value")
    result = render(json.load(sys.stdin), args.kafka_namespace, args.flink_namespace,
                    use_registry=not args.no_schema_registry, apps=apps)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
