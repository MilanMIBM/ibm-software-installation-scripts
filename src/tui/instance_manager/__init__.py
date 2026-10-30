"""instance_manager - discover, create, rename, resize and delete service instances.

Provider-agnostic. Every instance type's options are discovered from the cluster (CRD
schemas, existing CRs, owned PVCs, platform registries), never from per-service tables.
Layers (plan §2):
  L1 providers.k8s_crd   generic CR-backed instances (the foundation)
  L2 providers.cpd       Software Hub / CP4D: zen add-on registry + cpd-cli, on top of L1
  L3 subservices         things inside an instance (watsonx.data engines first)

Run: PYTHONPATH=src python -m tui.instance_manager --help
"""

__version__ = "0.1.0"
