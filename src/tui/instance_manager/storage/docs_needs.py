"""What the IBM docs say each service's storage needs are (D6: checked at implementation time).

Used by field_need.assess when the CRD / zen form (S1, S5) says nothing about a storage-class
field: a service the docs list with one storage kind decides every storage field of that
service; a service that uses file and block storage decides only fields whose name says which
(blockStorageClass, file_storage_class, ...) and otherwise leaves the field on "either", so the
picker shows every file and block class. Live evidence (PVCs, peers) still adds to the docs.

Kept as Python (not a samples/ JSON file) so it is part of the discovery cache's code hash:
an edit here re-derives every cached model with no cluster call.
"""

from __future__ import annotations

from dataclasses import dataclass

from ..model import Need

SOURCE_URL = "https://www.ibm.com/docs/en/software-hub/5.4.x?topic=requirements-storage"
RETRIEVED = "2026-11-03"


@dataclass(frozen=True)
class DocNeed:
    uses: frozenset[str]            # {"file"} | {"block"} | {"file", "block"}
    quote: str                      # the docs sentence, verbatim

    @property
    def need(self) -> Need | None:
        """The need every storage field of the service has, when the docs name one kind only."""
        if self.uses == {"file"}:
            return Need.FILE
        if self.uses == {"block"}:
            return Need.BLOCK
        return None


def _d(uses: str, quote: str) -> DocNeed:
    return DocNeed(frozenset(uses.split("+")), quote)


# keyed by the zen add-on type (cpd:<addon_type>); KINDS maps CR kinds (k8s-crd provider) onto them
SERVICES: dict[str, DocNeed] = {
    "edb": _d("block", "EDB Postgres uses block storage."),
    "informix": _d("file", "Informix uses file storage."),
    "spark": _d("file", "Analytics Engine powered by Apache Spark uses file storage."),
    "datastage": _d("file", "DataStage uses file storage."),
    "mdm": _d("file+block", "IBM Master Data Management uses file storage and block storage."),
    "watsonx-data": _d("file+block", "watsonx.data uses file storage and block storage."),
    "db2oltp": _d("file+block", "Db2 uses file storage and block storage on most storage environments."),
    "db2wh": _d("file+block", "Db2 uses file storage and block storage on most storage environments."),
    "pa": _d("file+block", "Planning Analytics uses file storage or a combination of file storage and block "
                           "storage."),
    "openpages": _d("file+block", "OpenPages uses file storage and block storage."),
}
KINDS: dict[str, str] = {
    "CPDEdbInstance": "edb", "PXRuntime": "datastage", "MasterDataManagement": "mdm", "Wxd": "watsonx-data",
    "AnalyticsEngine": "spark", "Db2oltpService": "db2oltp", "Db2whService": "db2wh",
    "OpenPagesInstance": "openpages", "PAService": "pa",
}


def lookup(type_key: str, kind: str | None = None) -> DocNeed | None:
    """type_key: cpd:<addon_type> | crd:<plural.group>_<Kind> | wxd:<engine kind> (sub-services: no
    per-engine docs entry, their API spec descriptions say rwo / rwx)."""
    tail = type_key.split(":", 1)[-1]
    hit = SERVICES.get(tail)
    if hit is None:
        k = kind or tail.rsplit("_", 1)[-1]
        hit = SERVICES.get(KINDS.get(k, ""))
    return hit
