"""generic profile: any CRD, by KIND[/NAME] in -n namespaces (or -A)."""

from __future__ import annotations

from . import CRDInfo, Profile, TargetSpec, find_crd


class GenericProfile(Profile):
    name = "cr"

    def __init__(self, refs: list[str], namespaces: list[str] | None, operator_ns: list[str] | None = None,
                 overrides: dict | None = None):
        super().__init__()
        self.refs = refs
        self.ns = namespaces          # None = all namespaces
        self.op_ns = operator_ns or []
        self.overrides = overrides or {}
        self._discovered_ns: list[str] = []

    def namespaces(self) -> list[str]:
        return self.ns if self.ns is not None else self._discovered_ns

    def set_discovered_namespaces(self, ns: list[str]):
        self._discovered_ns = sorted(set(ns))

    def operator_namespaces(self) -> list[str]:
        return self.op_ns or self.namespaces()

    def resolve(self, crds: dict[tuple[str, str], CRDInfo]) -> list[TargetSpec]:
        specs = []
        for ref in self.refs:
            kind_tok, _, name = ref.partition("/")
            hits = find_crd(crds, kind_tok)
            if not hits:
                self.notes.append(f"no CRD matches '{kind_tok}'")
                continue
            if len(hits) > 1:
                self.notes.append(f"'{kind_tok}' matches {len(hits)} CRDs; using {hits[0].plural}.{hits[0].group}")
            info = hits[0]
            ver = info.version()
            specs.append(TargetSpec(
                group=info.group, version=ver, kind=info.kind, plural=info.plural, namespaced=info.namespaced,
                name=name or None, namespaces=self.ns if info.namespaced else None, component=None,
                is_component=True, override=self.overrides.get(info.kind),
                printer_columns=info.printer_columns.get(ver, [])))
        return specs

    def title(self) -> str:
        return "cr " + " ".join(self.refs)
