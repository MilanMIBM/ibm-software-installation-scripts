"""The provider protocol (plan §2/§7). discovery/, storage/ and ui/ only see these types."""

from __future__ import annotations

from abc import ABC, abstractmethod

from ..model import FormModel, Instance, InstanceType, StorageClassInfo


class Provider(ABC):
    id: str = "?"

    @abstractmethod
    def discover_types(self) -> list[InstanceType]:
        """Creatable instance types, in display order."""

    @abstractmethod
    def list_instances(self, itype: InstanceType) -> list[Instance]:
        """Existing instances of a type, with their dot state."""

    @abstractmethod
    def form_model(self, itype: InstanceType) -> FormModel:
        """The merged, provenance-tagged field model of a type."""

    @abstractmethod
    def storage_classes(self) -> dict[str, StorageClassInfo]:
        """StorageClass name -> kind + evidence."""

    def refresh(self) -> None:
        """Drop cached discovery (the `R` key)."""

    def refresh_instances(self) -> None:
        """Drop cached instance lists only (the periodic poll)."""
