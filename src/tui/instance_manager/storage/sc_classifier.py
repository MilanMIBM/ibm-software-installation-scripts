"""StorageClass -> file | block | object | unknown, with the evidence that decided (plan §5.1).

Strongest first: user override (--sc-kind) > declared (STG_CLASS_FILE / STG_CLASS_BLOCK) >
CDI StorageProfile access modes > census of bound PVCs on the class > provisioner family.
RWX only counts for Filesystem-mode PVCs: raw-block RWX (VM disks on rbd) is not file storage.
"""

from __future__ import annotations

from ..model import Evidence, Kind, StorageClassInfo

# Generic CSI knowledge (provisioner substrings), the last fallback. Not per-service mapping.
FAMILY: list[tuple[str, Kind]] = [
    ("/obc", Kind.OBJECT), ("bucket", Kind.OBJECT), ("objectstorage", Kind.OBJECT),
    ("cephfs", Kind.FILE), ("nfs", Kind.FILE), ("efs.csi", Kind.FILE), ("file.csi.azure", Kind.FILE),
    ("azure-file", Kind.FILE), ("azurefile", Kind.FILE), ("vpc.file", Kind.FILE), ("vpc-file", Kind.FILE),
    ("spectrumscale", Kind.FILE), ("gpfs", Kind.FILE), ("filestore", Kind.FILE), ("netapp", Kind.FILE),
    ("rbd", Kind.BLOCK), ("ebs.csi", Kind.BLOCK), ("aws-ebs", Kind.BLOCK), ("disk.csi.azure", Kind.BLOCK),
    ("azure-disk", Kind.BLOCK), ("vpc.block", Kind.BLOCK), ("pd.csi", Kind.BLOCK), ("gce-pd", Kind.BLOCK),
    ("cinder", Kind.BLOCK), ("vsphere", Kind.BLOCK), ("topolvm", Kind.BLOCK), ("lvms", Kind.BLOCK),
]
CENSUS_MIN_RWO = 3
_RWX = "ReadWriteMany"


def _family(provisioner: str, params: dict) -> tuple[Kind, str] | None:
    p = provisioner.lower()
    if "portworx" in p or "pxd" in p:
        shared = str(params.get("sharedv4", params.get("shared", ""))).lower() == "true"
        return (Kind.FILE, "portworx sharedv4") if shared else (Kind.BLOCK, "portworx (not sharedv4)")
    for token, kind in FAMILY:
        if token in p:
            return kind, f"provisioner family '{token}'"
    return None


def classify(storage_classes: list[dict], pvcs: list[dict], profiles: list[dict] | None = None,
             declared: dict[str, Kind] | None = None,
             overrides: dict[str, Kind] | None = None) -> dict[str, StorageClassInfo]:
    declared, overrides = declared or {}, overrides or {}
    census: dict[str, dict[str, int]] = {}
    fs_rwx: dict[str, int] = {}
    raw_block: set[str] = set()
    for pvc in pvcs:
        spec, status = pvc.get("spec") or {}, pvc.get("status") or {}
        sc = spec.get("storageClassName")
        if not sc or status.get("phase") != "Bound":
            continue
        modes = spec.get("accessModes") or []
        bucket = census.setdefault(sc, {})
        for m in modes:
            bucket[m] = bucket.get(m, 0) + 1
        if spec.get("volumeMode") == "Block":
            raw_block.add(sc)
        elif _RWX in modes:
            fs_rwx[sc] = fs_rwx.get(sc, 0) + 1
    prof_modes: dict[str, set[str]] = {}
    for p in profiles or []:
        name = (p.get("metadata") or {}).get("name")
        modes = {m for cps in (p.get("status") or {}).get("claimPropertySets") or []
                 if (cps.get("volumeMode") or "Filesystem") == "Filesystem" for m in cps.get("accessModes") or []}
        if name and modes:
            prof_modes[name] = modes

    out: dict[str, StorageClassInfo] = {}
    for sc in storage_classes:
        meta = sc.get("metadata") or {}
        name = meta.get("name", "")
        ann = meta.get("annotations") or {}
        info = StorageClassInfo(
            name=name, provisioner=sc.get("provisioner", ""), expandable=bool(sc.get("allowVolumeExpansion")),
            default=ann.get("storageclass.kubernetes.io/is-default-class") == "true",
            binding_mode=sc.get("volumeBindingMode", ""), access_modes=census.get(name, {}),
            raw_block=name in raw_block)
        fam = _family(info.provisioner, sc.get("parameters") or {})
        modes = census.get(name, {})
        rwo = modes.get("ReadWriteOnce", 0) + modes.get("ReadWriteOncePod", 0)
        if name in overrides:
            info.kind = overrides[name]
            info.evidence.append(Evidence("user", f"--sc-kind {name}={info.kind.value}", 1.0))
        elif fam and fam[0] == Kind.OBJECT:
            info.kind = Kind.OBJECT
            info.evidence.append(Evidence("live", f"{fam[1]}: object buckets, never a PVC class", 0.95))
        elif name in declared:
            info.kind = declared[name]
            info.evidence.append(Evidence("config", f"declared {info.kind.value} in cpd_vars", 0.95))
        elif name in prof_modes:
            info.kind = Kind.FILE if _RWX in prof_modes[name] else Kind.BLOCK
            info.evidence.append(Evidence("live", f"StorageProfile access modes {sorted(prof_modes[name])}", 0.9))
        elif fs_rwx.get(name):
            info.kind = Kind.FILE
            info.evidence.append(Evidence("live", f"{fs_rwx[name]} bound RWX filesystem PVCs", 0.85))
        elif rwo >= CENSUS_MIN_RWO and not modes.get(_RWX):
            info.kind = Kind.BLOCK
            info.evidence.append(Evidence("live", f"{rwo} bound PVCs, all RWO", 0.75))
        elif fam:
            info.kind = fam[0]
            info.evidence.append(Evidence("S8", fam[1], 0.5))
        # supporting evidence (doesn't change the decision)
        if info.kind != Kind.UNKNOWN and fs_rwx.get(name) and info.kind != Kind.FILE:
            info.evidence.append(Evidence("live", f"note: {fs_rwx[name]} RWX filesystem PVCs on it", 0.3))
        out[name] = info
    return out
