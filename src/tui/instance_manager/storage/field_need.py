"""Storage-class field -> what it needs: file | block-preferred | either | unknown (plan §5.2).

  1 explicit    sibling accessModes, schema description, a form/sample enum of classes
                (what the CRD / zen form says; a form default is no evidence: zen's EDB form
                defaults to a file class while EDB needs block)
  1b docs       when 1 found nothing: the IBM docs' storage kind of the service (docs_needs.py);
                a service that uses file and block storage only decides fields whose name says
                which, else the field ends on "either" (every file and block class is valid)
  2 value-flow  the field's value on each existing instance, traced to that instance's PVCs:
                any RWX filesystem PVC -> file; all RWO -> block-preferred
  3 peers       PVCs owned by the same sink kind elsewhere in the cluster (>= 80% one kind)
  4 name tokens a hint only ("blockStorageClass" held a file class on the live cluster)
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Callable

from ..discovery.observed import Flat
from ..discovery.roles import leaf_name
from ..model import (
    Evidence,
    Field,
    Kind,
    Need,
    Path,
    Role,
    StorageClassInfo,
    StorageNeed,
)
from .docs_needs import DocNeed, lookup

PEER_SHARE = 0.8
PEER_MIN = 3
_FILE_WORDS = ("readwritemany", "rwx", "shared")
_BLOCK_WORDS = ("readwriteonce", "rwo")


def _kind_need(kind: Kind) -> Need | None:
    return {Kind.FILE: Need.FILE, Kind.BLOCK: Need.BLOCK}.get(kind)


def assess(f: Field, fields: dict[Path, Field], flats: list[tuple[str, Flat]],
           pvcs_of: Callable[[str], list[dict]], sc_info: dict[str, StorageClassInfo],
           peer_pvcs: Callable[[set[str], set[str]], list[dict]] | None = None,
           docs: DocNeed | None = None) -> StorageNeed:
    """flats: (instance name, flattened spec); pvcs_of(name) -> that instance's PVCs;
    peer_pvcs(sink_keys, exclude_uids) -> PVCs of the same sink kinds elsewhere;
    docs: the service's documented storage kinds (docs_needs.lookup)."""
    sn = StorageNeed()

    def decide(need: Need, ev: Evidence) -> None:
        if sn.need == Need.UNKNOWN:
            sn.need = need
        sn.evidence.append(ev)

    # 1. explicit
    sib = fields.get(f.path[:-1] + ("accessModes",))
    if sib is not None:
        modes = {m for v in sib.observed for m in (v if isinstance(v, list) else [v])}
        if "ReadWriteMany" in modes:
            decide(Need.FILE, Evidence("S5", "sibling accessModes ReadWriteMany", 0.95))
        elif modes & {"ReadWriteOnce", "ReadWriteOncePod"}:
            decide(Need.BLOCK, Evidence("S5", "sibling accessModes ReadWriteOnce", 0.95))
    desc = f.description.lower()
    if any(w in desc for w in _FILE_WORDS):
        decide(Need.FILE, Evidence("S5", "description mentions RWX/shared", 0.8))
    elif any(w in desc for w in _BLOCK_WORDS):
        decide(Need.BLOCK, Evidence("S5", "description mentions RWO", 0.8))
    if f.enum:
        kinds = {sc_info[v].kind for v in f.enum if v in sc_info} - {Kind.UNKNOWN}
        if kinds == {Kind.FILE, Kind.BLOCK}:
            decide(Need.EITHER, Evidence(next(iter(f.sources), "S1"), "offered classes include file and block", 0.7))
        elif len(kinds) == 1:
            k = kinds.pop()
            if _kind_need(k):
                decide(_kind_need(k), Evidence(next(iter(f.sources), "S1"),
                                               f"offered classes are {k.label} ({', '.join(map(str, f.enum))})",
                                               0.7))

    # 1b. docs, when the CRD / form said nothing
    leaf = (leaf_name(f.path) + " " + (f.label or "")).lower()     # the form label counts ("File storage class")
    token = Need.FILE if any(w in leaf for w in ("file", "rwx", "shared")) else (
        Need.BLOCK if any(w in leaf for w in ("block", "rwo")) else None)
    if docs is not None and sn.need == Need.UNKNOWN:
        where = f"IBM docs: \"{docs.quote}\""
        if docs.need is not None:
            decide(docs.need, Evidence("docs", where, 0.85))
        elif token is not None:
            decide(token, Evidence("docs", f"{where}; the field name says {token.value}", 0.75))

    # 2. value-flow
    flow: list[Need] = []
    traced_uids: set[str] = set()
    sink_keys: set[str] = set()
    for name, flat in flats:
        value = flat.get(f.path)
        if not isinstance(value, str):
            continue
        hit = [p for p in pvcs_of(name) if (p.get("spec") or {}).get("storageClassName") == value]
        if not hit:
            continue
        modes = Counter(m for p in hit for m in (p.get("spec") or {}).get("accessModes") or [])
        fs_rwx = any("ReadWriteMany" in ((p.get("spec") or {}).get("accessModes") or [])
                     and (p.get("spec") or {}).get("volumeMode") != "Block" for p in hit)
        need = Need.FILE if fs_rwx else Need.BLOCK
        flow.append(need)
        traced_uids |= {(p.get("metadata") or {}).get("uid", "") for p in hit}
        sink_keys |= {p.get("_sink", "") for p in hit if p.get("_sink")}
        sn.evidence.append(Evidence("live", f"{name}: {len(hit)} PVC(s) on {value}, "
                                    + ", ".join(f"{m} x{n}" for m, n in modes.items()), 0.85))
    if flow:
        if len(set(flow)) == 1:
            if sn.need == Need.UNKNOWN:
                sn.need = flow[0]
        else:
            sn.evidence.append(Evidence("live", "instances disagree (some RWX, some RWO only)", 0.4))
            if sn.need == Need.UNKNOWN and Need.FILE in flow:
                sn.need = Need.FILE

    # 3. peers through the sink kind
    if peer_pvcs and sink_keys:
        peers = [p for p in peer_pvcs(sink_keys, traced_uids)
                 if (p.get("spec") or {}).get("storageClassName") in sc_info]
        kinds = Counter(sc_info[p["spec"]["storageClassName"]].kind for p in peers)
        total = sum(kinds.values())
        if total >= PEER_MIN:
            kind, n = kinds.most_common(1)[0]
            label = ", ".join(sorted(k.split("/")[-1] for k in sink_keys))
            if n / total >= PEER_SHARE and _kind_need(kind):
                ev = Evidence("live", f"peers: {n}/{total} other {label} PVCs use {kind.label}", 0.7)
                if sn.need == Need.UNKNOWN:
                    decide(_kind_need(kind), ev)
                else:
                    sn.evidence.append(ev)

    # 4. name tokens (hint only)
    if token:
        ev = Evidence("S8", f"name/label hint '{leaf.strip()}' -> {token.value}", 0.3)
        if sn.need == Need.UNKNOWN:
            decide(token, ev)
        elif sn.need != token:
            sn.evidence.append(Evidence("S8", f"name says {token.value}, outranked by the evidence above", 0.3))

    # a documented file-and-block service, nothing more specific found: both kinds are valid
    if docs is not None and docs.need is None and sn.need == Need.UNKNOWN:
        decide(Need.EITHER, Evidence("docs", f"IBM docs: \"{docs.quote}\" (this field isn't documented "
                                             "separately)", 0.6))

    # mismatches: current values the need doesn't accept
    for name, flat in flats:
        value = flat.get(f.path)
        info = sc_info.get(value) if isinstance(value, str) else None
        if info and not sn.accepts(info.kind):
            sn.mismatches.append(f"{name}: {value} is {info.kind.label}, field needs {sn.need.value}")
    return sn


def assess_static(fields: dict[Path, Field], sc_info: dict[str, StorageClassInfo], type_key: str = "") -> None:
    """Storage needs for a form without traceable instances (sub-service forms such as the watsonx.data
    engines): what the schema says (descriptions like "rwo storage class"), the docs, the field name.
    Fields that already carry a need keep it."""
    docs = lookup(type_key) if type_key else None
    for f in fields.values():
        if f.role == Role.STORAGE_CLASS and f.storage is None:
            f.storage = assess(f, fields, [], lambda n: [], sc_info, docs=docs)

