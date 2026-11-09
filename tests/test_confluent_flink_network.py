"""Check that Flink ingress grants cannot isolate previously open workloads."""

import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src/helpers"))
from confluent_flink_network import FLINK_NAMESPACE_LABEL, matches, render


def policy(name, selector, types=None):
    spec = {"podSelector": selector}
    if types is not None:
        spec["policyTypes"] = types
    return {
        "kind": "NetworkPolicy",
        "metadata": {"name": name, "uid": f"uid-{name}"},
        "spec": spec,
    }


class FlinkIngressTests(unittest.TestCase):
    def setUp(self):
        self.pods = [
            {"kind": "Pod", "metadata": {"labels": {"app": app}}}
            for app in ("broker", "schema-registry", "prometheus", "connect")
        ]

    def plan(self, *policies, **kwargs):
        return render({"items": self.pods + list(policies)}, "confluent", "confluent-flink", **kwargs)["items"]

    def test_open_cluster_gets_no_policy(self):
        self.assertEqual(self.plan(), [])

    def test_monitoring_policy_does_not_trigger_kafka_isolation(self):
        monitoring = policy("monitoring-internal", {"matchExpressions": [
            {"key": "app", "operator": "In", "values": ["prometheus", "alertmanager"]},
        ]}, ["Ingress"])
        self.assertEqual(self.plan(monitoring), [])

    def test_registry_only_restriction_does_not_select_brokers(self):
        source = policy("registry", {"matchLabels": {"app": "schema-registry"}})
        result = self.plan(source)
        self.assertEqual(len(result), 1)
        selector = result[0]["spec"]["podSelector"]
        self.assertTrue(matches(selector, {"app": "schema-registry"}))
        self.assertFalse(matches(selector, {"app": "broker"}))
        self.assertEqual(selector, source["spec"]["podSelector"])

    def test_namespace_isolation_preserves_existing_rules(self):
        source = policy("restricted", {}, ["Ingress"])
        source["spec"]["ingress"] = [{"from": [{"podSelector": {}}]}]
        original = copy.deepcopy(source)
        result = self.plan(source)
        self.assertEqual(source, original)
        self.assertEqual(result[0]["spec"]["podSelector"], {})
        self.assertEqual(result[0]["spec"]["ingress"], [{"from": [{
            "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "confluent-flink"}},
        }]}])

    def test_egress_only_policy_does_not_trigger_ingress_isolation(self):
        self.assertEqual(self.plan(policy("egress", {}, ["Egress"])), [])

    def test_grants_follow_source_lifetime_and_uninstall_label(self):
        source = policy("restricted", {})
        grant = self.plan(source)[0]
        self.assertEqual(grant["metadata"]["labels"][FLINK_NAMESPACE_LABEL], "confluent-flink")
        self.assertEqual(grant["metadata"]["ownerReferences"][0], {
            "apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
            "name": "restricted", "uid": "uid-restricted",
        })

    def test_repeated_runs_do_not_create_grants_for_generated_policies(self):
        source = policy("restricted", {})
        first = self.plan(source)
        self.assertEqual(self.plan(source, *first), first)
        self.assertEqual(self.plan(*first), [])

    def test_without_registry_only_broker_restrictions_matter(self):
        self.assertEqual(self.plan(policy("registry", {"matchLabels": {"app": "schema-registry"}}),
                                   use_registry=False), [])

    def test_selectors_support_missing_labels_and_all_operators(self):
        for operator, values, labels, expected in [
            ("In", ["broker"], {}, False),
            ("NotIn", ["prometheus"], {}, True),
            ("Exists", [], {}, False),
            ("DoesNotExist", [], {}, True),
            ("NotIn", ["prometheus"], {"app": "prometheus"}, False),
            ("Exists", [], {"app": "broker"}, True),
            ("DoesNotExist", [], {"app": "broker"}, False),
        ]:
            with self.subTest(operator=operator, labels=labels):
                self.assertEqual(matches({"matchExpressions": [{
                    "key": "app", "operator": operator, "values": values,
                }]}, labels), expected)


if __name__ == "__main__":
    unittest.main()
