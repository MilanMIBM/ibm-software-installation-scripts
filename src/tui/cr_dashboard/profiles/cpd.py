"""cpd profile: IBM Software Hub / Cloud Pak for Data components -> their CRs.

Component metadata (cr_kind / cr_name / cr_api / component_dependencies) comes from
config-vars/global.yml in the olm-utils container, read with `podman exec cat`
through cpd_release_meta.global_components(cache=False) - never `cpd-cli manage`,
and never written to disk. Expected CR versions come from the patch file / release yml.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from . import CRDInfo, Placeholder, Profile, TargetSpec

# src/helpers (cpd_release_meta.py), wherever this package sits under src/
_HELPERS = next((p / "helpers" for p in Path(__file__).resolve().parents
                 if (p / "helpers" / "cpd_release_meta.py").is_file()), None)
if _HELPERS is not None and str(_HELPERS) not in sys.path:
    sys.path.insert(0, str(_HELPERS))

# Components whose global.yml entry has no CR metadata (F13). global.yml wins when it has one.
SUPPLEMENT = {
    "ibm-licensing": {"cr_api": "operator.ibm.com", "cr_api_version": "v1alpha1", "cr_kind": "IBMLicensing",
                      "cr_name": "instance"},
}


def split_list(text: str | None) -> list[str]:
    out = []
    for part in (text or "").replace(" ", ",").split(","):
        part = part.strip()
        if part and part not in out:
            out.append(part)
    return out


class CpdProfile(Profile):
    name = "cpd"
    label_key = "icpdsupport/addOnId"

    def __init__(self, components: list[str], fallback: list[str], instance_ns: str, operator_ns: str,
                 cluster_ns: list[str], *, deps: bool = True, extra: list[TargetSpec] | None = None,
                 overrides: dict | None = None):
        super().__init__()
        self.components = components or fallback
        if not components:
            self.notes.append("component list empty: using the fallback list (cpfs,cpd_platform,ccs,CPD_COMPONENTS)")
        self.fallback = fallback
        self.instance_ns = instance_ns
        self.operator_ns = operator_ns
        self.cluster_ns = [n for n in cluster_ns if n]
        self.deps_enabled = deps
        self.extra = extra or []
        self.overrides = overrides or {}
        self.meta: dict[str, dict] = {}
        self.meta_source: str | None = None
        self.expected: dict[str, str] = {}
        self._load()

    # ------------------------------------------------------------------
    def _load(self):
        try:
            import cpd_release_meta as crm
        except Exception as e:  # pragma: no cover - repo layout problem
            self.notes.append(f"cpd_release_meta not importable: {e}")
            return
        try:
            self.meta, self.meta_source = crm.global_components(cache=False)
        except Exception as e:
            self.notes.append(f"global.yml not readable ({e}); component CRs guessed from CRDs")
            self.meta = {}
        if not os.environ.get("VERSION"):
            self.notes.append("VERSION not set: expected CR versions unknown")
            return
        try:
            pm, psrc = crm.patch_meta()
            if os.environ.get("PATCH_ID", "").strip() and not psrc:
                self.notes.append("PATCH_ID set but the patch file is missing: expected versions unknown")
                return
            rm, _ = crm.release_meta(cache=False)
        except Exception as e:
            self.notes.append(f"release metadata not readable: {e}")
            return
        for comp in set(rm) | set(pm):
            v = (pm.get(comp) or {}).get("cr_version") or (rm.get(comp) or {}).get("cr_version")
            if v:
                self.expected[comp] = v

    def namespaces(self) -> list[str]:
        out = []
        for n in [self.instance_ns, self.operator_ns, *self.cluster_ns]:
            if n and n not in out:
                out.append(n)
        return out

    def operator_namespaces(self) -> list[str]:
        out = [self.operator_ns] if self.operator_ns else []
        return out + [n for n in self.cluster_ns if n not in out]

    def _expand(self) -> list[str]:
        comps = []
        for c in self.components:
            entry = self.meta.get(c) or {}
            if str(entry.get("deprecated", "")).lower() == "true":
                continue
            if self.deps_enabled:
                for d in entry.get("component_dependencies") or []:
                    if d not in comps:
                        comps.append(d)
            if c not in comps:
                comps.append(c)
        return comps

    def resolve(self, crds: dict[tuple[str, str], CRDInfo]) -> list[TargetSpec]:
        specs: list[TargetSpec] = []
        seen: dict[tuple[str, str, str], TargetSpec] = {}
        self.placeholders = []
        comps = self._expand() if self.meta else list(self.components)
        for comp in comps:
            entry = dict(self.meta.get(comp) or {})
            if not entry.get("cr_kind") and comp in SUPPLEMENT:
                entry.update(SUPPLEMENT[comp])
            kind, group = entry.get("cr_kind"), entry.get("cr_api")
            if not kind or not group:
                why = "no CR in global.yml" if comp in self.meta else (
                    "not in global.yml" if self.meta else "global.yml unavailable")
                self.placeholders.append(Placeholder(comp, f"not resolvable: {why}"))
                continue
            name = entry.get("cr_name") or None
            k = (group, kind, name or "*")
            if k in seen:
                continue
            info = crds.get((group, kind))
            if info is None:
                spec = TargetSpec(group=group, version=entry.get("cr_api_version") or "v1", kind=kind,
                                  plural=kind.lower() + "s", namespaced=True, name=name,
                                  namespaces=self.namespaces(), component=comp, note="CRD not installed",
                                  missing_crd=True)
            else:
                ver = info.version(entry.get("cr_api_version"))
                spec = TargetSpec(group=group, version=ver, kind=kind, plural=info.plural,
                                  namespaced=info.namespaced, name=name,
                                  namespaces=self.namespaces() if info.namespaced else None,
                                  component=comp, expected_version=self.expected.get(comp),
                                  override=self.overrides.get(kind),
                                  printer_columns=info.printer_columns.get(ver, []))
            seen[k] = spec
            specs.append(spec)
        # operator-only dependencies: cpd-cli installs just the operator; the parent operator creates the CR
        requested = set(self.components)
        op_only = set()
        for c in self.components:
            op_only |= set((self.meta.get(c) or {}).get("operator_only_dependencies") or [])
        for s in specs:
            if s.component in op_only and s.component not in requested and not s.note:
                s.note = "operator only: created by its parent operator when needed"
        # static dependencies between the resolved components
        resolved = {s.component for s in specs}
        self.depends = {c: [d for d in (self.meta.get(c) or {}).get("component_dependencies") or [] if d in resolved]
                        for c in resolved}
        for s in self.extra:
            if (s.group, s.kind, s.name or "*") not in seen:
                specs.append(s)
        if not self.meta:
            specs += self._guess(crds, {(s.group, s.kind) for s in specs})
        return specs

    def _guess(self, crds, have) -> list[TargetSpec]:
        """No global.yml: every *.cpd.ibm.com kind in the instance namespace counts as a component."""
        out = []
        for (group, kind), info in crds.items():
            if not group.endswith("cpd.ibm.com") or (group, kind) in have or not info.namespaced:
                continue
            ver = info.version()
            out.append(TargetSpec(group=group, version=ver, kind=kind, plural=info.plural, namespaced=True,
                                  name=None, namespaces=[self.instance_ns], component=None,
                                  printer_columns=info.printer_columns.get(ver, []), note="guessed (no global.yml)"))
        return out

    def title(self) -> str:
        return f"cpd {os.environ.get('VERSION', '')}{('+' + os.environ['PATCH_ID']) if os.environ.get('PATCH_ID') else ''}"
