"""StorageKindTag (D5): the kind of the selected StorageClass, right of every storage field.

Line 1 is the selected class's kind (file / block / object / unknown storage), coloured by
the $kind-* variables and updated on every selection change. Line 2 (dim) is what the field
needs and its strongest evidence. A kind the need doesn't accept adds the -mismatch class.
"""

from __future__ import annotations

from rich.text import Text
from textual.widgets import Static

from ...common.ui_util import set_text
from ..model import Kind, Need, StorageClassInfo, StorageNeed

KIND_COLORS = {Kind.FILE: "#22d3ee", Kind.BLOCK: "#c084fc", Kind.OBJECT: "#facc15", Kind.UNKNOWN: "#9ca3af"}
NEED_WORDS = {Need.FILE: "needs: file", Need.BLOCK: "needs: block", Need.EITHER: "accepts: file or block",
              Need.UNKNOWN: "need: unknown"}


def need_line(need: StorageNeed | None) -> str:
    if need is None:
        return ""
    best = max(need.evidence, key=lambda e: e.confidence, default=None)
    return NEED_WORDS[need.need] + (f" ({best.detail})" if best else "")


class StorageKindTag(Static):
    DEFAULT_CSS = """
    StorageKindTag { width: auto; min-width: 16; height: 2; padding: 0 1; }
    StorageKindTag.-file { color: $kind-file; }
    StorageKindTag.-block { color: $kind-block; }
    StorageKindTag.-object { color: $kind-object; }
    StorageKindTag.-unknown { color: $kind-unknown; }
    StorageKindTag.-mismatch { background: $error 15%; }
    """

    def __init__(self, info: StorageClassInfo | None = None, need: StorageNeed | None = None, **kw):
        super().__init__("", **kw)
        self.kind: Kind | None = None
        self.mismatch = False
        self._args = (info, need)

    def on_mount(self) -> None:
        self._paint()

    def show(self, info: StorageClassInfo | None, need: StorageNeed | None) -> None:
        """Remember the latest selection; paint now if mounted, else on mount (never an older one)."""
        self._args = (info, need)
        self.kind = info.kind if info else None
        if self.is_mounted:
            self._paint()

    def _paint(self) -> None:
        info, need = self._args
        self.kind = info.kind if info else None
        self.mismatch = bool(info and need and not need.accepts(info.kind))
        for k in Kind:
            self.set_class(self.kind == k, f"-{k.value}")
        self.set_class(self.mismatch, "-mismatch")
        head = info.kind.label if info else "no class selected"
        if self.mismatch:
            head += "  - does not match"
        text = Text(head, style="bold")
        sub = need_line(need)
        if sub:
            text.append("\n" + sub, style="dim")
        set_text(self, text)
