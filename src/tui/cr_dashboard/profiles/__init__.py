"""Profiles turn user input into target specs (which CRs to show) plus static metadata."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class CRDInfo:
    group: str
    kind: str
    plural: str
    singular: str
    short_names: list[str]
    namespaced: bool
    served: list[str]
    storage: str
    printer_columns: dict[str, list[dict]]

    def version(self, preferred: str | None = None) -> str:
        if preferred and preferred in self.served:
            return preferred
        return self.storage or (self.served[0] if self.served else preferred or "v1")


def index_crds(crd_list: dict) -> dict[tuple[str, str], CRDInfo]:
    out = {}
    for c in crd_list.get("items") or []:
        spec = c.get("spec") or {}
        names = spec.get("names") or {}
        versions = spec.get("versions") or []
        info = CRDInfo(
            group=spec.get("group", ""), kind=names.get("kind", ""), plural=names.get("plural", ""),
            singular=names.get("singular", ""), short_names=names.get("shortNames") or [],
            namespaced=spec.get("scope") == "Namespaced",
            served=[v["name"] for v in versions if v.get("served")],
            storage=next((v["name"] for v in versions if v.get("storage")), ""),
            printer_columns={v["name"]: v.get("additionalPrinterColumns") or [] for v in versions})
        out[(info.group, info.kind)] = info
    return out


def find_crd(crds: dict[tuple[str, str], CRDInfo], token: str) -> list[CRDInfo]:
    """Kind, plural, singular, short name, or <plural>.<group>, case-insensitive."""
    t = token.strip().lower()
    hits = []
    for info in crds.values():
        full = f"{info.plural}.{info.group}".lower()
        if t in (info.kind.lower(), info.plural.lower(), info.singular.lower(), full,
                 f"{info.kind.lower()}.{info.group.lower()}") or t in [s.lower() for s in info.short_names]:
            hits.append(info)
    return hits


@dataclass
class TargetSpec:
    group: str
    version: str
    kind: str
    plural: str
    namespaced: bool
    name: str | None                  # None = every instance
    namespaces: list[str] | None      # None = any namespace
    component: str | None = None
    is_component: bool = True
    note: str | None = None
    expected_version: str | None = None
    override: dict | None = None
    allow_any_name: bool = False      # exact name missing -> take any instance of the kind
    printer_columns: list[dict] = field(default_factory=list)
    missing_crd: bool = False

    @property
    def collection(self) -> str:
        return f"cr:{self.group}/{self.version}/{self.plural}"


@dataclass
class Placeholder:
    """A component with no CR to watch (no metadata / not resolvable): a gray list-only row."""
    component: str
    note: str


class Profile:
    name = "base"
    label_key: str | None = None

    def __init__(self):
        self.notes: list[str] = []
        self.depends: dict[str, list[str]] = {}       # component -> [components]
        self.placeholders: list[Placeholder] = []

    def namespaces(self) -> list[str]:
        raise NotImplementedError

    def operator_namespaces(self) -> list[str]:
        return []

    def resolve(self, crds: dict[tuple[str, str], CRDInfo]) -> list[TargetSpec]:
        raise NotImplementedError

    def scan_groups(self, specs: list[TargetSpec]) -> set[str]:
        return {s.group for s in specs if not s.missing_crd}

    def title(self) -> str:
        return self.name
