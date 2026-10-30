"""L3 sub-services (sub-plan §3): the protocol, the provider registry, generic tab states.

Candidates are found without provider knowledge: CRDs in the parent CR's API group (minus
the parent kind). With no provider registered for a parent, they make the Sub-services tab
grayed out with "N sub-resource kinds detected, no manager yet" - the backlog of future
sub-providers. Providers register in REGISTRY (subservices/__init__.py).
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field

from ...common.state import State
from ..model import Instance, InstanceType


@dataclass
class Match:
    enabled: bool
    reason: str = ""


class SubServiceProvider(ABC):
    id: str = "?"
    display_name: str = "Sub-services"

    @abstractmethod
    def matches(self, parent_type: InstanceType, parent: Instance) -> Match | None:
        """None = not for this parent; Match(enabled=False, reason) = for it, but not usable now."""


REGISTRY: list[SubServiceProvider] = []


@dataclass
class TabState:
    state: str                          # enabled | parent-not-ready | no-provider | none
    reason: str = ""
    provider: SubServiceProvider | None = None
    candidates: list[tuple[str, int]] = field(default_factory=list)   # (kind, CRs in the namespace)

    @property
    def enabled(self) -> bool:
        return self.state == "enabled"


def candidates(cluster, itype: InstanceType, namespace: str | None) -> list[tuple[str, int]]:
    """Other kinds in the parent's API group, with how many objects each has in the namespace."""
    if not itype.crd or not itype.group:
        return []
    entries = [e for e in cluster.kinds_in_group(itype.group) if e["kind"] != itype.kind]
    paths = {e["kind"]: (f"/apis/{e['group']}/{e['version']}/namespaces/{namespace}/{e['plural']}"
                         if e["namespaced"] and namespace else f"/apis/{e['group']}/{e['version']}/{e['plural']}")
             for e in entries}
    found = cluster.list_many(list(paths.values()))
    return sorted((kind, len(found.get(path, []))) for kind, path in paths.items())


def tab_state(cluster, itype: InstanceType, parent: Instance, namespace: str | None) -> TabState:
    for prov in REGISTRY:
        m = prov.matches(itype, parent)
        if m is None:
            continue
        if parent.state != State.HEALTHY:
            return TabState("parent-not-ready", f"parent is {parent.state.word}", prov)
        if not m.enabled:
            return TabState("parent-not-ready", m.reason, prov)
        return TabState("enabled", prov.display_name, prov)
    cands = candidates(cluster, itype, namespace)
    if cands:
        kinds = ", ".join(f"{k} x{n}" for k, n in cands)
        return TabState("no-provider", f"{len(cands)} sub-resource kind(s) detected ({kinds}), no manager yet",
                        candidates=cands)
    return TabState("none", "no sub-services")
