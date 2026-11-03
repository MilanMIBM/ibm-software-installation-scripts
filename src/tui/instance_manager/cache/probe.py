"""Fingerprint probe (cache plan §2.3): cheap cluster reads, in parallel, at every start.

  cluster identity  clusterversions/version spec.clusterID, else the kube-system namespace uid (V-C6)
  add-on registry   metadata-only list of the icpdata_addon=true configmaps -> {name: resourceVersion}
  CRDs              metadata-only GET of each cached CRD -> resourceVersion (None = gone)
  StorageClasses    hash of (name, provisioner, parameters, default annotation, expansion, binding)
  patch level (F1)  Ibmcpd spec.version + the image digests of every Deployment in the operators
                    namespace (CP4D 5.4 operators are non-OLM: no Subscriptions / CSVs to read)
Every check fails soft: an unreadable item is None and simply doesn't validate anything.
"""

from __future__ import annotations

import hashlib
import json
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

from ...common.kube import METADATA_ONLY, Kube, KubeError
from ..timings import span

ONE_METADATA = "application/json;as=PartialObjectMetadata;g=meta.k8s.io;v=v1,application/json"
CRD_PATH = "/apis/apiextensions.k8s.io/v1/customresourcedefinitions"


def _h(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, default=str).encode()).hexdigest()[:16]


@dataclass
class ProbeResult:
    cluster_id: str | None = None
    addon_rvs: dict[str, str] | None = None
    crd_rvs: dict[str, str | None] = field(default_factory=dict)
    sc_hash: str | None = None
    cluster_patch: dict | None = None
    took: float = 0.0
    errors: list[str] = field(default_factory=list)


def cluster_id(kube: Kube) -> str | None:
    try:
        return (kube.get("/apis/config.openshift.io/v1/clusterversions/version", timeout=(5, 15)).get("spec")
                or {}).get("clusterID")
    except KubeError:
        pass
    try:
        return "ns-uid:" + kube.get("/api/v1/namespaces/kube-system", timeout=(5, 15))["metadata"]["uid"]
    except (KubeError, KeyError):
        return None


def addon_rvs(kube: Kube, namespace: str) -> dict[str, str]:
    data = kube.get(f"/api/v1/namespaces/{namespace}/configmaps", accept=METADATA_ONLY,
                    labelSelector="icpdata_addon=true")
    return {i["metadata"]["name"]: i["metadata"].get("resourceVersion", "") for i in data.get("items") or []}


def crd_rv(kube: Kube, name: str) -> str | None:
    try:
        return kube.get(f"{CRD_PATH}/{name}", accept=ONE_METADATA, timeout=(5, 15))["metadata"]["resourceVersion"]
    except (KubeError, KeyError):
        return None


def sc_fingerprint(storage_classes: list[dict]) -> str:
    rows = []
    for sc in storage_classes:
        meta = sc.get("metadata") or {}
        ann = meta.get("annotations") or {}
        rows.append([meta.get("name"), sc.get("provisioner"), sc.get("parameters") or {},
                     ann.get("storageclass.kubernetes.io/is-default-class"), bool(sc.get("allowVolumeExpansion")),
                     sc.get("volumeBindingMode")])
    return _h(sorted(rows, key=lambda r: str(r[0])))


def cluster_patch(kube: Kube, operands_ns: str | None, operators_ns: str | None) -> dict | None:
    """Ibmcpd spec.version + {deployment: image digest} of the operators namespace."""
    out: dict = {"ibmcpd_version": None, "operators": {}}
    if operands_ns:
        try:
            items = kube.get(f"/apis/cpd.ibm.com/v1/namespaces/{operands_ns}/ibmcpds").get("items") or []
            out["ibmcpd_version"] = next(((i.get("spec") or {}).get("version") for i in items), None)
        except KubeError:
            pass
    if operators_ns:
        try:
            for d in kube.get(f"/apis/apps/v1/namespaces/{operators_ns}/deployments").get("items") or []:
                cs = ((d.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers") or []
                imgs = sorted(c.get("image", "") for c in cs)
                out["operators"][d["metadata"]["name"]] = ",".join(i.rsplit("@sha256:", 1)[-1][:16]
                                                                   if "@sha256:" in i else i for i in imgs)
        except KubeError:
            pass
    if out["ibmcpd_version"] is None and not out["operators"]:
        return None
    out["hash"] = _h([out["ibmcpd_version"], out["operators"]])
    return out


def run(kube: Kube, namespace: str | None, crd_names: list[str], operators_ns: str | None = None,
        addons: bool = True) -> ProbeResult:
    res = ProbeResult()
    t0 = time.monotonic()

    def guard(name, fn):
        try:
            return fn()
        except Exception as e:      # noqa: BLE001 - a probe item never fails the start
            res.errors.append(f"{name}: {str(e)[:120]}")
            return None

    with span("cache probe"), ThreadPoolExecutor(max_workers=8) as pool:
        f_id = pool.submit(guard, "cluster id", lambda: cluster_id(kube))
        f_add = pool.submit(guard, "add-on configmaps", lambda: addon_rvs(kube, namespace)) \
            if addons and namespace else None
        f_sc = pool.submit(guard, "storage classes", lambda: sc_fingerprint(
            kube.get("/apis/storage.k8s.io/v1/storageclasses").get("items") or []))
        f_patch = pool.submit(guard, "patch level", lambda: cluster_patch(kube, namespace, operators_ns))
        f_crds = {n: pool.submit(crd_rv, kube, n) for n in crd_names}
        res.cluster_id = f_id.result()
        res.addon_rvs = f_add.result() if f_add else None
        res.sc_hash = f_sc.result()
        res.cluster_patch = f_patch.result()
        res.crd_rvs = {n: f.result() for n, f in f_crds.items()}
    res.took = time.monotonic() - t0
    return res
