"""Sub-service warmup during a cache build (decision C-D3: automatic when a parent instance exists).

For every instance a registered sub-service provider can open (watsonx.data -> engines),
the provider's warm() loads what opening it needs: the API spec, the operator pod, its
presets and documented fields, the engine CRD. They are read through the cache (cache plan
C3), so the next open is a few image checks instead of ~40 s of execs.
"""

from __future__ import annotations

from ..subservices import REGISTRY


def _targets(itype, instances):
    for inst in instances:
        for sp in REGISTRY:
            m = sp.matches(itype, inst)
            if m is not None and m.enabled and hasattr(sp, "warm"):
                yield sp, inst


def applies(itype, instances) -> bool:
    return any(True for _ in _targets(itype, instances))


def attach(sources) -> None:
    for sp in REGISTRY:
        if hasattr(sp, "sources"):
            sp.sources = sources


def warm(cache, types, instances) -> int:
    attach(cache.sources)
    n = 0
    for t in types:
        for sp, inst in _targets(t, instances.get(t.key, [])):
            sp.warm(inst)
            n += 1
    return n
