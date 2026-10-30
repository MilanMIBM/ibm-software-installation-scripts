"""L3 sub-services: things provisioned inside an instance (watsonx.data engines first).

Providers need the cluster, so they are installed at start-up with register_defaults().
"""

from .base import REGISTRY, SubServiceProvider, TabState, tab_state  # noqa: F401


def register_defaults(cluster) -> None:
    from .wxd.provider import WxdEngines
    if not any(isinstance(p, WxdEngines) for p in REGISTRY):
        REGISTRY.append(WxdEngines(cluster))
