"""Merge per-source Fields into one FormModel (plan §3).

Sources are passed highest rank first. Observed (real) paths win over the schema's
generic "[]" paths. Attributes: the highest-ranked non-empty value wins; constraints only
tighten (max of minimums, min of maximums, enum intersection); conflicts become notices.
"""

from __future__ import annotations

from dataclasses import replace

from ..model import Field, Mutability, Path, Role, schema_path


def _tighten(target: Field, other: Field) -> None:
    if other.minimum is not None:
        target.minimum = other.minimum if target.minimum is None else max(target.minimum, other.minimum)
    if other.maximum is not None:
        target.maximum = other.maximum if target.maximum is None else min(target.maximum, other.maximum)
    if other.enum:
        if target.enum_soft or other.enum_soft:
            target.enum = target.enum or list(other.enum)       # a hint (storage classes): never narrows
        elif target.enum:
            both = [v for v in target.enum if v in other.enum]
            if both:
                target.enum = both
            else:
                target.notices.append(f"enum conflict between sources ({target.enum} vs {other.enum}); "
                                      "kept the higher-ranked one")
        else:
            target.enum = list(other.enum)


def _absorb(target: Field, other: Field) -> None:
    """`other` ranks lower than everything already in `target`."""
    if target.type in ("string", "") and other.type not in ("string", ""):
        target.type = other.type if not target.observed or other.type != "object" else target.type
    for attr in ("label", "description", "pattern"):
        if not getattr(target, attr) and getattr(other, attr):
            setattr(target, attr, getattr(other, attr))
    if target.default is None and other.default is not None:
        target.default = other.default
    target.required = target.required or other.required
    target.preserve_unknown = target.preserve_unknown or other.preserve_unknown
    if target.role == Role.OTHER and other.role != Role.OTHER:
        target.role, target.role_evidence = other.role, other.role_evidence
    if other.mutability == Mutability.IMMUTABLE:
        target.mutability = Mutability.IMMUTABLE
    if not target.observed and other.observed:
        target.observed = list(other.observed)
    for attr in ("step", "show_if", "enum_labels", "presets", "placeholder"):
        if not getattr(target, attr) and getattr(other, attr):
            setattr(target, attr, getattr(other, attr))
    if target.order == 10_000:
        target.order = other.order
    target.enum_soft = target.enum_soft or other.enum_soft
    target.payload = target.payload or other.payload
    target.sources |= other.sources
    _tighten(target, other)


def merge(sources: list[dict[Path, Field]]) -> dict[Path, Field]:
    """sources: highest rank first."""
    real: set[Path] = {p for src in sources for p in src if not any(x == "[]" for x in p)}
    by_generic: dict[Path, list[Path]] = {}
    for p in real:
        by_generic.setdefault(schema_path(p), []).append(p)
    out: dict[Path, Field] = {}
    for src in sources:
        for p, f in src.items():
            targets = by_generic.get(p, [p]) if "[]" in p else [p]
            for t in targets:
                if t not in out:
                    out[t] = replace(f, path=t, observed=list(f.observed), sources=set(f.sources),
                                     notices=list(f.notices), aliases=list(f.aliases),
                                     enum=list(f.enum) if f.enum else f.enum)
                else:
                    _absorb(out[t], f)
    # bounds vs observed values
    for f in out.values():
        nums = [v for v in f.observed if isinstance(v, (int, float)) and not isinstance(v, bool)]
        if f.minimum is not None and any(v < f.minimum for v in nums):
            f.notices.append(f"observed {min(nums)} is below the minimum {f.minimum}")
        if f.maximum is not None and any(v > f.maximum for v in nums):
            f.notices.append(f"observed {max(nums)} is above the maximum {f.maximum}")
        if f.enum and any(v not in f.enum for v in f.observed if not isinstance(v, (dict, list))):
            f.notices.append("observed values outside the enum: "
                             + ", ".join(str(v) for v in f.observed if v not in f.enum)[:120])
    return dict(sorted(out.items(), key=lambda kv: kv[0]))
