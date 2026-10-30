"""Data model shared by the providers, the discovery core and the UI (Textual-free)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum

from ..common.state import State

Path = tuple[str, ...]          # spec path; list items are "[name=x]", "[0]" (observed) or "[]" (schema)

UNSET_STRINGS = {"<no value>", "<nil>", "None", "null"}
QUANTITY_RE = re.compile(r"^[0-9]+(\.[0-9]+)?(m|k|Ki|Mi|Gi|Ti|Pi|Ei|M|G|T|P|E)?$")
UNIT_RE = re.compile(r"^(Ki|Mi|Gi|Ti|Pi|Ei|K|M|G|T|P|E|k)$")


def path_str(path: Path) -> str:
    out = ""
    for p in path:
        out += p if p.startswith("[") else (("." if out else "") + p)
    return out


def schema_path(path: Path) -> Path:
    """Observed list markers -> the schema's generic one."""
    return tuple("[]" if p.startswith("[") else p for p in path)


def is_unset(value) -> bool:
    return value is None or (isinstance(value, str) and (value.strip() == "" or value.strip() in UNSET_STRINGS))


class Role(str, Enum):
    REPLICAS = "replicas"
    CPU = "cpu"
    MEMORY = "memory"
    RESOURCES = "resources"           # a whole ResourceRequirements object
    STORAGE_SIZE = "storage_size"
    UNIT = "unit"                     # sibling unit of a bare-number size (ssize + sunit)
    SIZE_PRESET = "size_preset"
    STORAGE_CLASS = "storage_class"
    SECRET = "secret"                 # a secret value (password); masked
    SECRET_REF = "secret_ref"         # the name of a Secret
    VERSION = "version"
    LIFECYCLE = "lifecycle"           # shutdown
    QUANTITY = "quantity"
    OTHER = "other"

    @property
    def capacity(self) -> bool:
        return self in (Role.REPLICAS, Role.CPU, Role.MEMORY, Role.STORAGE_SIZE, Role.SIZE_PRESET)


class Mutability(str, Enum):
    MUTABLE = "mutable"
    IMMUTABLE = "immutable"
    UNKNOWN = "unknown"


class Need(str, Enum):
    FILE = "file"
    BLOCK = "block-preferred"
    EITHER = "either"
    UNKNOWN = "unknown"


class Kind(str, Enum):
    FILE = "file"
    BLOCK = "block"
    OBJECT = "object"
    UNKNOWN = "unknown"

    @property
    def label(self) -> str:
        return f"{self.value} storage"


@dataclass
class Evidence:
    source: str          # S1..S8, docs, script, seed, live
    detail: str
    confidence: float = 0.5

    def __str__(self) -> str:
        return f"[{self.source}] {self.detail}"


@dataclass
class StorageClassInfo:
    name: str
    provisioner: str = ""
    kind: Kind = Kind.UNKNOWN
    evidence: list[Evidence] = field(default_factory=list)
    expandable: bool = False
    default: bool = False
    binding_mode: str = ""
    access_modes: dict[str, int] = field(default_factory=dict)   # census of bound PVCs
    raw_block: bool = False

    @property
    def pvc_count(self) -> int:
        return sum(self.access_modes.values())


@dataclass
class StorageNeed:
    need: Need = Need.UNKNOWN
    evidence: list[Evidence] = field(default_factory=list)
    mismatches: list[str] = field(default_factory=list)     # "instance X: cephfs is file storage"

    def accepts(self, kind: Kind) -> bool:
        if kind == Kind.OBJECT:
            return False
        if self.need == Need.FILE:
            return kind == Kind.FILE
        if self.need == Need.BLOCK:
            return kind == Kind.BLOCK
        return True


@dataclass
class Field:
    path: Path
    type: str = "string"                 # string|integer|number|boolean|object|array|quantity|resources
    label: str = ""
    description: str = ""
    enum: list | None = None
    minimum: float | None = None
    maximum: float | None = None
    pattern: str | None = None
    required: bool = False
    default: object = None
    observed: list = field(default_factory=list)    # values seen across instances (unset ones dropped)
    role: Role = Role.OTHER
    role_evidence: Evidence | None = None
    mutability: Mutability = Mutability.UNKNOWN
    aliases: list[Path] = field(default_factory=list)
    alias_confirmed: bool = False                     # held on >= 2 instances
    sources: set[str] = field(default_factory=set)
    notices: list[str] = field(default_factory=list)
    storage: StorageNeed | None = None
    preserve_unknown: bool = False
    # form presentation (S1 / samples)
    placeholder: str = ""                              # example value (S1); never used as evidence
    step: str = ""                                     # wizard step key
    order: int = 10_000
    show_if: dict[Path, list] | None = None            # shown only while these fields hold one of the values
    enum_labels: dict | None = None                    # value -> label
    enum_soft: bool = False                            # a hint, not a closed list (storage-class enums)
    presets: list[dict] | None = None                  # size presets: value, label, cpu/memory, metadata
    payload: bool = False                              # part of the create payload (create_arguments.parameters)

    @property
    def key(self) -> str:
        return path_str(self.path)

    @property
    def prominent(self) -> bool:
        """Shown by default: observed, required, a recognised role, or a top-level scalar."""
        return bool(self.observed) or self.required or self.role != Role.OTHER or (
            len(self.path) == 1 and self.type not in ("object", "array"))


@dataclass
class FormModel:
    type_key: str
    fields: dict[Path, Field] = field(default_factory=dict)
    notices: list[str] = field(default_factory=list)
    instance_count: int = 0

    def get(self, path: Path) -> Field | None:
        return self.fields.get(path)

    def by_role(self, *roles: Role) -> list[Field]:
        return [f for f in self.fields.values() if f.role in roles]

    def representatives(self, fields: list[Field]) -> list[Field]:
        """One field per alias group: the one the form describes best (S1 label/bounds, then payload,
        then the shortest path), so the UI shows "Cores per node [1..16]", not a bare CR copy."""
        def rank(f: Field):
            return (0 if "S1" in f.sources else 1, 0 if f.payload else 1, len(f.path), f.path)
        out, seen = [], set()
        for f in sorted(fields, key=rank):
            if f.path in seen:
                continue
            seen |= {f.path, *f.aliases}
            out.append(f)
        return sorted(out, key=lambda f: (f.order, f.path))


@dataclass
class InstanceType:
    key: str                     # "crd:<group>/<Kind>" or "cpd:<addon_type>"
    display: str
    group: str
    version: str
    kind: str
    plural: str
    namespaced: bool = True
    crd: dict | None = None
    status_path: str | None = None          # override, e.g. ".status.edbStatus"
    max_instances: int | None = None
    provider: str = "k8s-crd"
    notices: list[str] = field(default_factory=list)
    creatable: bool = True
    versions: list[str] = field(default_factory=list)
    meta: dict = field(default_factory=dict)            # provider-specific (cpd: the add-on entry)

    def list_path(self, namespace: str | None) -> str:
        base = f"/apis/{self.group}/{self.version}" if self.group else f"/api/{self.version}"
        if self.namespaced and namespace:
            return f"{base}/namespaces/{namespace}/{self.plural}"
        return f"{base}/{self.plural}"


@dataclass
class Instance:
    type_key: str
    name: str
    namespace: str | None
    uid: str
    obj: dict
    state: State = State.INACTIVE
    reason: str = ""
    badges: list[str] = field(default_factory=list)
    display_name: str | None = None
    meta: dict = field(default_factory=dict)            # provider-specific (cpd: the zen record)

    @property
    def spec(self) -> dict:
        return self.obj.get("spec") or {}
