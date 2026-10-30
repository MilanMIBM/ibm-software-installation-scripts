"""The six dot states shared by every TUI (cr_dashboard, instance_manager)."""

from __future__ import annotations

from enum import Enum


class State(str, Enum):
    """The six dot states. Order of the members = severity order (worst first)."""

    FAILING = "failing"
    STUCK = "stuck"
    SCALING = "scaling"
    PROGRESS = "progress"
    HEALTHY = "healthy"
    INACTIVE = "inactive"

    @property
    def severity(self) -> int:
        return list(State).index(self)

    @property
    def word(self) -> str:
        return {"progress": "in progress"}.get(self.value, self.value)

    @property
    def tag(self) -> str:
        """Fixed-width tag for --no-color / --once output."""
        return {"failing": "[ERR]", "stuck": "[STK]", "scaling": "[SCL]", "progress": "[RUN]",
                "healthy": "[OK ]", "inactive": "[OFF]"}[self.value]
