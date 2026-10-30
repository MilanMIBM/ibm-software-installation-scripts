"""ActionPlan: one mutation, described before anything runs (plan §2, §9).

Every change goes plan -> preview -> confirm -> dry-run -> execute -> watch. A plan with
errors can't run; warnings need an explicit acknowledgement; delete needs the name typed.
Previews never contain secret values.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

Log = Callable[[str], None]


@dataclass
class Step:
    title: str
    run: Callable[[Log], None]
    preview: str = ""                 # masked command / patch
    dry_run: str = ""                 # what was validated before running, or why it couldn't be


@dataclass
class ActionPlan:
    op: str                           # create | edit | delete | rename
    target: str
    type_key: str
    steps: list[Step] = field(default_factory=list)
    summary: list[str] = field(default_factory=list)
    diff: list[tuple[str, str, str]] = field(default_factory=list)     # (field, old, new)
    warnings: list[str] = field(default_factory=list)                   # need an acknowledgement
    errors: list[str] = field(default_factory=list)                     # block the plan
    confirm_name: str | None = None                                     # must be typed to run

    @property
    def runnable(self) -> bool:
        return not self.errors and bool(self.steps)

    def text(self) -> str:
        """Plain preview (headless --dry-run output and the log)."""
        out = [f"{self.op} {self.target}"]
        out += [f"  {s}" for s in self.summary]
        if self.diff:
            out.append("changes:")
            out += [f"  {k}: {o} -> {n}" for k, o, n in self.diff]
        out.append("steps:")
        for i, s in enumerate(self.steps, 1):
            out.append(f"  {i}. {s.title}")
            if s.preview:
                out += [f"       {ln}" for ln in s.preview.splitlines()]
            if s.dry_run:
                out.append(f"       dry-run: {s.dry_run}")
        out += [f"WARNING {w}" for w in self.warnings]
        out += [f"ERROR {e}" for e in self.errors]
        return "\n".join(out)
