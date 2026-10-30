"""Detail pane: the selected instance's configuration by role, its storage fields with the
StorageKindTag, and the Sub-services tab (grayed out with the reason when not usable)."""

from __future__ import annotations

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import Label, Static, TabbedContent, TabPane

from ...common.ui_util import reconcile, set_attr, set_text
from ..discovery.observed import flatten
from ..model import Field, FormModel, Instance, InstanceType, Path, Role, StorageClassInfo
from ..subservices import TabState
from .storage_kind_tag import StorageKindTag

GROUPS = [
    ("Capacity", (Role.REPLICAS, Role.CPU, Role.MEMORY, Role.SIZE_PRESET, Role.STORAGE_SIZE, Role.UNIT)),
    ("Storage", (Role.STORAGE_CLASS,)),
    ("Version / lifecycle", (Role.VERSION, Role.LIFECYCLE)),
    ("Security", (Role.SECRET, Role.SECRET_REF)),
]


def _val(f: Field, v) -> str:
    if v is None:
        return "-"
    if f.role == Role.SECRET:
        return "****"
    s = str(v)
    return s if len(s) <= 48 else s[:45] + "..."


def _sources(f: Field) -> str:
    return ",".join(sorted(f.sources))


def config_text(inst: Instance, itype: InstanceType | None, fm: FormModel | Exception | None) -> Text:
    t = Text()
    t.append(f"{inst.display_name or inst.name}", style="bold")
    t.append(f"  {inst.state.word}", style=f"bold {'' if inst.state.value == 'inactive' else ''}")
    t.append(f"\n{inst.reason}\n", style="dim")
    zen = inst.meta.get("zen") or {}
    rows = [("type", itype.display if itype else inst.type_key), ("namespace", inst.namespace or "-")]
    if itype and itype.kind:
        rows.append(("resource", f"{itype.kind}/{inst.name}"))
    if zen:
        rows += [("zen id", str(zen.get("id"))), ("zen status", str(zen.get("provision_status"))),
                 ("version", str(zen.get("service_version")))]
    if inst.badges:
        rows.append(("view", " ".join(inst.badges)))
    for k, v in rows:
        t.append(f"  {k:<11}", style="dim")
        t.append(f"{v}\n")
    if fm is None:
        t.append("\ndiscovering fields...", style="dim italic")
        return t
    if isinstance(fm, Exception):
        t.append(f"\nfield discovery failed: {fm}", style="red")
        return t
    flat = flatten(inst.spec)
    for title, roles in GROUPS:
        fields = [f for f in fm.fields.values() if f.role in roles and (f.path in flat or not inst.spec)]
        if not fields:
            continue
        t.append(f"\n{title}\n", style="bold underline")
        for f in fm.representatives(fields):
            t.append(f"  {(f.label or f.key)[:30]:<31}")
            t.append(_val(f, flat.get(f.path)), style="bold")
            bounds = []
            if f.minimum is not None or f.maximum is not None:
                bounds.append(f"{f.minimum if f.minimum is not None else ''}..{f.maximum if f.maximum is not None else ''}")
            if f.enum and not f.enum_soft:
                bounds.append("|".join(map(str, f.enum[:5])))
            if bounds:
                t.append(f"  [{', '.join(bounds)}]", style="dim")
            if f.aliases:
                t.append(f"  +{len(f.aliases)} alias", style="dim")
            t.append(f"  {{{_sources(f)}}}\n", style="dim")
    notes = [n for n in fm.notices]
    if notes:
        t.append("\nNotes\n", style="bold underline")
        for n in notes:
            t.append(f"  ! {n}\n", style="yellow")
    return t


class StorageFieldRow(Horizontal):
    DEFAULT_CSS = """
    StorageFieldRow { height: 2; margin-bottom: 1; }
    StorageFieldRow .s-key { width: 20; text-wrap: nowrap; text-overflow: ellipsis; }
    StorageFieldRow .s-val { width: 1fr; min-width: 24; text-wrap: nowrap; text-overflow: ellipsis; }
    StorageFieldRow StorageKindTag { width: 38; text-wrap: nowrap; text-overflow: ellipsis; }
    """

    def __init__(self, key: Path):
        super().__init__()
        self.key = key

    def compose(self) -> ComposeResult:
        yield Label("", classes="s-key")
        yield Label("", classes="s-val")
        yield StorageKindTag()

    _pending: tuple | None = None

    def on_mount(self) -> None:
        self.call_after_refresh(self._flush)

    def _flush(self) -> None:
        if self._pending is None:
            return
        if self.query(".s-key"):
            args, self._pending = self._pending, None
            self.fill(*args)
        elif self.is_attached:
            self.call_after_refresh(self._flush)

    def fill(self, f: Field, value, info: StorageClassInfo | None) -> None:
        if not (self.is_mounted and self.query(".s-key")):
            self._pending = (f, value, info)              # newest wins; painted once the labels exist
            if self.is_attached:
                self.call_after_refresh(self._flush)
            return
        set_text(self.query_one(".s-key", Label), f.label or f.key)
        alias = f"\n+ {len(f.aliases)} alias(es)" if f.aliases else ""
        set_text(self.query_one(".s-val", Label), f"{value or '-'}{alias}")
        self.query_one(StorageKindTag).show(info, f.storage)


class Detail(Vertical):
    DEFAULT_CSS = """
    Detail { border: round $panel-lighten-2; border-title-color: $text-muted; }
    Detail #storage-empty { color: $text-muted; }
    Detail #sub-text { padding: 1; }
    """

    def compose(self) -> ComposeResult:
        with TabbedContent(id="tabs", initial="tab-config"):
            with TabPane("Config", id="tab-config"):
                with VerticalScroll():
                    yield Static("select an instance", id="config-text")
            with TabPane("Storage", id="tab-storage"):
                with VerticalScroll(id="storage-rows"):
                    yield Static("", id="storage-empty")
            with TabPane("Sub-services", id="tab-sub"):
                yield Static("", id="sub-text")

    def on_mount(self) -> None:
        self.border_title = "detail"
        self._storage_rows: list[StorageFieldRow] = []

    def show(self, inst: Instance | None, itype: InstanceType | None, fm, tab: TabState | None,
             sc: dict[str, StorageClassInfo]) -> None:
        set_attr(self, "border_title", f"detail · {inst.display_name or inst.name}" if inst else "detail")
        if inst is None:
            set_text(self.query_one("#config-text", Static), "select an instance")
            self._fill_storage([], {}, sc)
            self._tab(None)
            return
        set_text(self.query_one("#config-text", Static), config_text(inst, itype, fm))
        flat = flatten(inst.spec)
        fields = []
        if isinstance(fm, FormModel):
            fields = fm.representatives([f for f in fm.by_role(Role.STORAGE_CLASS)
                                         if f.path in flat or not inst.spec])
        self._fill_storage(fields, flat, sc)
        self._tab(tab)

    def _fill_storage(self, fields: list[Field], flat: dict, sc: dict[str, StorageClassInfo]) -> None:
        box = self.query_one("#storage-rows", VerticalScroll)
        empty = self.query_one("#storage-empty", Static)
        set_text(empty, "" if fields else "no storage-class fields on this instance")
        by = {f.path: f for f in fields}
        self._storage_rows, fresh = reconcile(box, self._storage_rows, list(by), lambda w: w.key,
                                              StorageFieldRow, first_anchor=empty)
        for row in self._storage_rows:
            f = by[row.key]
            value = flat.get(f.path)
            if row in fresh:
                self.call_after_refresh(row.fill, f, value, sc.get(value))
            else:
                row.fill(f, value, sc.get(value))

    def _tab(self, tab: TabState | None) -> None:
        tabs = self.query_one("#tabs", TabbedContent)
        text = Text()
        if tab is None:
            text.append("checking for sub-services...", style="dim")
        elif tab.enabled:
            text.append(f"{tab.reason}\n", style="bold")
            text.append("press s (or click here) to open", style="dim")
        else:
            text.append(f"{tab.state}: ", style="bold")
            text.append(tab.reason, style="dim")
        set_text(self.query_one("#sub-text", Static), text)
        enabled = bool(tab and tab.enabled)
        set_attr(tabs.get_tab("tab-sub"), "tooltip", None if enabled else (tab.reason if tab else "checking"))
        if getattr(self, "_sub_enabled", None) == enabled:
            return
        self._sub_enabled = enabled
        if enabled:
            tabs.enable_tab("tab-sub")
        else:
            if tabs.active == "tab-sub":
                tabs.active = "tab-config"
            tabs.disable_tab("tab-sub")
