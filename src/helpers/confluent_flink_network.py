"""Grant Flink ingress without introducing isolation on additional pods."""

import argparse
import hashlib
import json
import sys


FLINK_NAMESPACE_LABEL = "confluent.platform/flink-namespace"


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


def render(resources, kafka_namespace, flink_namespace, use_registry=True):
    apps = {"broker", "schema-registry"} if use_registry else {"broker"}
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
    args = parser.parse_args()
    result = render(json.load(sys.stdin), args.kafka_namespace, args.flink_namespace,
                    use_registry=not args.no_schema_registry)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
