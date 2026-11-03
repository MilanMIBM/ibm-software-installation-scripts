"""Generated forms (create, edit), the StoragePicker and the plan screen (plan §5.3, §6).

Forms are built from a FormModel: steps (S1 custom_steps, else role groups), labels, bounds,
enums, show_if dependencies, secrets with a Generate button. Every storage-class field gets a
StoragePicker: a dropdown of only the classes the field accepts (object classes never), with an
override switch that turns it into a free-text field; a StorageKindTag beside it follows
every change.
Nothing changes the cluster here: Preview builds an ActionPlan; the plan screen runs it.
"""

from __future__ import annotations

from typing import ClassVar

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.suggester import SuggestFromList
from textual.widgets import Button, Input, Label, Select, Static, Switch

from ...common.toggle import ToggleSetting
from ..model import (
    Field,
    FormModel,
    Instance,
    InstanceType,
    Kind,
    Path,
    Role,
    StorageClassInfo,
    path_str,
)
from ..ops import payload as pl
from ..ops.plan import ActionPlan
from .storage_kind_tag import StorageKindTag

FORM_CSS = """
{name} {{ align: center middle; }}
{name} > Vertical {{ width: 92%; max-width: 140; height: 92%; border: round $accent; background: $surface;
    padding: 0 1; }}
{name} .title {{ text-style: bold; height: 1; margin: 1 0; }}
{name} .step {{ text-style: bold underline; margin-top: 1; height: 1; }}
{name} .frow {{ height: auto; min-height: 3; }}
{name} .flabel {{ width: 34; padding-top: 1; }}
{name} .fwidget {{ width: 1fr; }}
{name} .fhint {{ width: 24; padding-top: 1; color: $text-muted; }}
{name} #errors {{ height: auto; max-height: 8; color: $error; }}
{name} #buttons {{ height: 3; dock: bottom; }}
{name} Button {{ margin-right: 2; }}
"""


def _hint(f: Field) -> str:
    parts = []
    if f.minimum is not None or f.maximum is not None:
        parts.append(f"{f.minimum if f.minimum is not None else ''}..{f.maximum if f.maximum is not None else ''}")
    if f.required:
        parts.append("required")
    return "  ".join(parts)


class StoragePicker(Horizontal):
    """A dropdown of the StorageClasses the field accepts, prefiltered by its need (file, block, or both
    when either is valid; object classes never): form-offered and declared classes first. The
    override switch swaps the dropdown for a free-text input (it suggests every class on the
    cluster), for a class the filter leaves out or one that doesn't exist yet. The StorageKindTag
    beside it follows every change. Value = the StorageClass name."""

    DEFAULT_CSS = """
    StoragePicker { height: auto; }
    StoragePicker #sc-select { width: 2fr; min-width: 24; }
    StoragePicker #sc-input { width: 2fr; min-width: 24; display: none; }
    StoragePicker.-override #sc-select { display: none; }
    StoragePicker.-override #sc-input { display: block; }
    StoragePicker #override { width: auto; }
    StoragePicker StorageKindTag { width: 1fr; min-width: 18; max-width: 40; padding-top: 1; height: 3;
        text-wrap: nowrap; text-overflow: ellipsis; }
    """

    def __init__(self, f: Field, sc: dict[str, StorageClassInfo], value: str | None, **kw):
        super().__init__(**kw)
        self.f, self.sc = f, sc
        self._value = value
        # a starting value the filter doesn't offer (an edit's current class, a preset) opens in override
        self.override = bool(value) and value not in self._names()
        self.set_class(self.override, "-override")

    def compose(self) -> ComposeResult:
        opts = self._options()
        names = self._names()
        yield Select(opts, value=self._value if self._value in names else Select.NULL, allow_blank=True,
                     prompt=self._prompt(), id="sc-select")
        every = sorted(n for n, i in self.sc.items() if i.kind != Kind.OBJECT)
        yield Input(value=self._value or "", placeholder="any StorageClass name", id="sc-input",
                    suggester=SuggestFromList(every, case_sensitive=True) if every else None)
        yield ToggleSetting("override", value=self.override, id="override", compact=True,
                            tooltip="type any StorageClass name instead of picking a compatible one")
        yield StorageKindTag(self.sc.get(self._value) if self._value else None, self.f.storage,
                             unknown=self._value if self._value and self._value not in self.sc else None)

    def _ok(self, info: StorageClassInfo) -> bool:
        return self.f.storage.accepts(info.kind) if self.f.storage else info.kind != Kind.OBJECT

    def _names(self) -> list[str]:
        return [v for _, v in self._options()]

    def _prompt(self) -> str:
        if self._names():
            return "StorageClass"
        need = self.f.storage.need.value if self.f.storage else "compatible"
        return f"no {need} class on this cluster: tick override"

    def _options(self):
        offered = {str(v) for v in self.f.enum or []}
        infos = sorted((i for i in self.sc.values() if self._ok(i)),
                       key=lambda i: (i.name not in offered, not any(e.source == "config" for e in i.evidence),
                                      not i.default, -i.pvc_count, i.name))
        out = []
        for i in infos:
            label = Text(f"{i.name}  ", style="bold")
            notes = [i.kind.label] + (["default"] if i.default else []) + (
                ["declared"] if any(e.source == "config" for e in i.evidence) else [])
            label.append("  ".join(notes), style="dim")
            out.append((label, i.name))
        return out

    @property
    def value(self) -> str | None:
        if self.override:
            found = self.query("#sc-input")
            v = found.first().value.strip() if found else (self._value or "")
            return v or None
        found = self.query("#sc-select")
        if not found:                       # not composed yet: the starting value
            return self._value
        v = found.first().value
        return None if v is Select.NULL else str(v)

    def _tag(self) -> None:
        v = self.value
        found = self.query(StorageKindTag)
        if found:
            found.first().show(self.sc.get(v) if v else None, self.f.storage,
                               unknown=v if v and v not in self.sc else None)

    def _set_override(self, on: bool) -> None:
        if on == self.override:
            return
        cur = self.value
        self.override = on
        self.set_class(on, "-override")
        if on:
            self.query_one("#sc-input", Input).value = cur or ""
        else:
            sel = self.query_one("#sc-select", Select)
            sel.value = cur if cur in self._names() else (self._names()[0] if self._names() else Select.NULL)
        self._tag()

    def on_toggle_setting_changed(self, event: ToggleSetting.Changed) -> None:
        if event.toggle.id == "override":
            self._set_override(event.value)          # bubbles on: the form re-checks the value

    def on_select_changed(self, event: Select.Changed) -> None:
        self._tag()

    def on_input_changed(self, event: Input.Changed) -> None:
        self._tag()

    def set_value(self, value: str | None) -> None:
        if value is not None and value not in self._names():
            self.query_one("#override", ToggleSetting).value = True          # the setter posts nothing
            self.override = True
            self.set_class(True, "-override")
            self.query_one("#sc-input", Input).value = value
        else:
            if self.override:
                self.query_one("#override", ToggleSetting).value = False
                self.override = False
                self.set_class(False, "-override")
            self.query_one("#sc-select", Select).value = value if value is not None else Select.NULL
        self._tag()


class FieldRow(Horizontal):
    def __init__(self, f: Field, value, sc: dict[str, StorageClassInfo]):
        super().__init__(classes="frow")
        self.f, self.value0, self.sc = f, value, sc

    def compose(self) -> ComposeResult:
        f = self.f
        yield Label(f.label or path_str(f.path), classes="flabel")
        if f.role == Role.STORAGE_CLASS:
            yield StoragePicker(f, self.sc, self.value0, classes="fwidget")
        elif f.type == "boolean":
            yield Switch(value=bool(pl.coerce(f, self.value0)) if self.value0 is not None else False,
                         classes="fwidget")
        elif f.enum and (not f.enum_soft or f.role in (Role.SIZE_PRESET, Role.UNIT)):
            labels = f.enum_labels or {}
            opts = []
            for v in f.enum:
                text = str(labels.get(v, v))
                preset = next((p for p in f.presets or [] if p.get("value") == v), None)
                if preset and (preset.get("cpu") or preset.get("memory")):
                    text += f"  ({preset.get('cpu')} vCPU, {preset.get('memory')})"
                opts.append((text, v))
            cur = self.value0 if self.value0 in f.enum else (str(self.value0) if str(self.value0) in map(str, f.enum)
                                                            else Select.NULL)
            yield Select(opts, value=cur, allow_blank=not f.required, classes="fwidget")
        elif f.role == Role.SECRET:
            with Horizontal(classes="fwidget"):
                yield Input(value=str(self.value0 or ""), password=True, placeholder="password")
                yield Button("Generate", id="gen", variant="default")
        else:
            yield Input(value="" if self.value0 is None else str(self.value0),
                        type="integer" if f.type == "integer" else "text",
                        placeholder=f.placeholder or "", classes="fwidget")
        yield Label(_hint(f), classes="fhint")

    @property
    def value(self):
        found = self.query(".fwidget")
        if not found:                       # not composed yet: the starting value
            return self.value0
        w = found.first()
        if isinstance(w, StoragePicker):
            return w.value
        if isinstance(w, Switch):
            return w.value
        if isinstance(w, Select):
            return None if w.value is Select.NULL else w.value
        inp = self.query(Input).first()
        return inp.value if inp.value != "" else None

    @property
    def override(self) -> bool:
        """A storage field typed by hand (the picker's override box)."""
        found = self.query(StoragePicker)
        return bool(found) and found.first().override

    def set_value(self, value) -> None:
        w = self.query(".fwidget").first()
        if isinstance(w, Select):
            w.value = value if value in (self.f.enum or []) else Select.NULL
        elif isinstance(w, Switch):
            w.value = bool(value)
        elif isinstance(w, StoragePicker):
            w.set_value(None if value is None else str(value))
        else:
            self.query(Input).first().value = "" if value is None else str(value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "gen":
            event.stop()
            self.query(Input).first().value = pl.random_password()


class FormLogic:
    """Rows, values, show_if visibility and size-preset filling, shared by the modal screens
    (--classic-ui) and the inline FormView."""

    def rows(self) -> list[FieldRow]:
        return list(self.query(FieldRow))

    def values(self) -> dict[Path, object]:
        return {r.f.path: r.value for r in self.rows()}

    def refresh_visibility(self, only: list[Path] | None = None) -> None:
        """only = the rows that depend on the field that changed (None: every row)."""
        vals = self.values()
        for r in self.rows():
            if only is not None and r.f.path not in only:
                continue
            vis = pl.shown(r.f, vals) and not self.hidden_extra(r)
            if r.display != vis:
                r.display = vis

    def hidden_extra(self, row: FieldRow) -> bool:
        """Hidden for a reason of the form's own (FormView: advanced settings closed)."""
        return False

    def apply_preset(self, row: FieldRow, value) -> None:
        """A size preset was chosen: the template fills the sizes it names; they stay editable."""
        if row.f.role != Role.SIZE_PRESET or not row.f.presets:
            return
        meta = next((p.get("metadata") or {} for p in row.f.presets if p.get("value") == value), {})
        for r in self.rows():
            key = ".".join(r.f.path[1:])
            if r is not row and (key in meta or r.f.path[-1] in meta):
                r.set_value(meta.get(key, meta.get(r.f.path[-1])))


class _FormBase(FormLogic, ModalScreen):
    BINDINGS: ClassVar[list[BindingType]] = [Binding("escape", "dismiss", "cancel")]

    def on_input_changed(self, event) -> None:
        self.refresh_visibility()

    def on_select_changed(self, event) -> None:
        row = next((a for a in event.control.ancestors if isinstance(a, FieldRow)), None)
        if row is not None:
            self.apply_preset(row, event.value)
        self.refresh_visibility()

    def on_switch_changed(self, event) -> None:
        self.refresh_visibility()


class CreateScreen(_FormBase):
    DEFAULT_CSS = FORM_CSS.format(name="CreateScreen")

    def __init__(self, itype: InstanceType, fm: FormModel, sc: dict[str, StorageClassInfo], owner=None):
        super().__init__()
        self.itype, self.fm, self.sc = itype, fm, sc
        self.owner = owner          # who plans the change: the app, or a SubServiceScreen

    def compose(self) -> ComposeResult:
        vals = pl.initial_values(self.fm, self.sc)
        fields = pl.payload_fields(self.fm)
        with Vertical():
            yield Label(f"new {self.itype.display} instance  (esc to cancel)", classes="title")
            with VerticalScroll():
                with Horizontal(classes="frow"):
                    yield Label("Name", classes="flabel")
                    yield Input(id="name", placeholder="instance name", classes="fwidget")
                    yield Label("required", classes="fhint")
                with Horizontal(classes="frow"):
                    yield Label("Description", classes="flabel")
                    yield Input(id="description", classes="fwidget")
                    yield Label("", classes="fhint")
                if self.itype.versions:
                    with Horizontal(classes="frow"):
                        yield Label("Add-on version", classes="flabel")
                        yield Select([(v, v) for v in self.itype.versions], value=self.itype.versions[-1],
                                     allow_blank=False, id="version", classes="fwidget")
                        yield Label("", classes="fhint")
                step = None
                for f in sorted(fields, key=lambda f: (f.order, f.path)):
                    s = f.step or {Role.STORAGE_CLASS: "storage", Role.SECRET: "security"}.get(f.role, "settings")
                    if s != step:
                        step = s
                        yield Label(s.replace("_", " ").capitalize(), classes="step")
                    yield FieldRow(f, vals.get(f.path), self.sc)
                if not fields:
                    yield Static("no payload fields were discovered for this type (see x explain; D6 samples)",
                                 classes="fhint")
                if getattr(self.owner or self.app, "offers_vault", True):
                    from ..ops import credentials
                    vmod = credentials.vault()
                    who = ", ".join(vmod.member_names()) or "nobody else"
                    yield Label("Credentials", classes="step")
                    yield ToggleSetting(f"Also save the credentials in the Software Hub vault (shared with {who})",
                                        value=vmod.enabled(None), id="vault")
            yield Static("", id="errors")
            with Horizontal(id="buttons"):
                yield Button("Preview plan", id="preview", variant="primary")
                yield Button("Cancel", id="cancel")

    def on_mount(self) -> None:
        self.refresh_visibility()
        self.query_one("#name", Input).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.dismiss()
        elif event.button.id == "preview":
            ver = self.query("#version")
            version = ver.first().value if ver else None
            vault_box = self.query("#vault")
            (self.owner or self.app).plan_create(self.itype, self.fm, self.values(),
                                                 self.query_one("#name", Input).value.strip(),
                                                 self.query_one("#description", Input).value.strip(), version,
                                                 vault=vault_box.first().value if vault_box else None)


class EditScreen(_FormBase):
    DEFAULT_CSS = FORM_CSS.format(name="EditScreen")

    def __init__(self, itype: InstanceType, inst: Instance, fm: FormModel, sc: dict[str, StorageClassInfo],
                 owner=None):
        super().__init__()
        self.itype, self.inst, self.fm, self.sc = itype, inst, fm, sc
        self.owner = owner
        from ..discovery.observed import flatten
        self.flat = flatten(inst.spec)

    def editable(self) -> list[Field]:
        cands = [f for f in self.fm.fields.values() if f.role.capacity and f.path in self.flat
                 and f.mutability.value != "immutable" and not any(p.startswith("[") for p in f.path)]
        return self.fm.representatives(cands)

    def compose(self) -> ComposeResult:
        fields = self.editable()
        with Vertical():
            yield Label(f"scale / capacity · {self.inst.display_name or self.inst.name}  (esc to cancel)",
                        classes="title")
            with VerticalScroll():
                for f in fields:
                    yield FieldRow(f, self.flat.get(f.path), self.sc)
                if not fields:
                    yield Static("no editable scale/capacity fields were discovered for this instance",
                                 classes="fhint")
            yield Static("aliases (copies of the same value elsewhere in the CR) change together; "
                         "the plan lists every one", classes="fhint")
            with Horizontal(id="buttons"):
                yield Button("Preview plan", id="preview", variant="primary", disabled=not fields)
                yield Button("Cancel", id="cancel")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.dismiss()
        elif event.button.id == "preview":
            changes = {r.f.path: r.value for r in self.rows()
                       if r.value is not None and str(r.value) != str(self.flat.get(r.f.path))}
            (self.owner or self.app).plan_edit(self.itype, self.inst, self.fm, changes)


def plan_text(p: ActionPlan) -> Text:
    """An ActionPlan for the screen: summary, changes, steps with dry-run results, warnings, errors."""
    t = Text()
    for s in p.summary:
        t.append(f"{s}\n")
    if p.diff:
        t.append("\nchanges\n", style="bold underline")
        for k, o, n in p.diff:
            t.append(f"  {k}: ", style="dim")
            t.append(f"{o} -> {n}\n", style="bold")
    t.append("\nsteps\n", style="bold underline")
    for i, s in enumerate(p.steps, 1):
        t.append(f"  {i}. {s.title}\n", style="bold")
        if s.preview:
            t.append("\n".join(f"       {ln}" for ln in s.preview.splitlines()) + "\n", style="dim")
        if s.dry_run:
            t.append(f"       dry-run: {s.dry_run}\n", style="cyan")
    for w in p.warnings:
        t.append(f"\n! {w}", style="yellow")
    for e in p.errors:
        t.append(f"\nx {e}", style="red")
    return t


class PlanScreen(ModalScreen):
    """The ActionPlan before it runs: summary, changes, steps with dry-run results, warnings, errors."""

    DEFAULT_CSS = FORM_CSS.format(name="PlanScreen")
    BINDINGS: ClassVar[list[BindingType]] = [Binding("escape", "dismiss", "cancel")]

    def __init__(self, plan: ActionPlan, on_run):
        super().__init__()
        self.plan, self.on_run = plan, on_run

    def compose(self) -> ComposeResult:
        p = self.plan
        t = plan_text(p)
        with Vertical():
            yield Label(f"plan · {p.op} {p.target}  (esc to cancel)", classes="title")
            with VerticalScroll():
                yield Static(t)
            if p.warnings:
                yield ToggleSetting("I have read the warnings above", id="ack", on_word="YES", off_word="NO")
            if p.confirm_name:
                yield Input(placeholder=f"type {p.confirm_name} to confirm", id="confirm")
            with Horizontal(id="buttons"):
                yield Button("Run", id="run", variant="error" if p.op == "delete" else "primary", disabled=True)
                yield Button("Cancel", id="cancel")

    def on_mount(self) -> None:
        self._update()

    def _update(self) -> None:
        p = self.plan
        ok = p.runnable
        if p.warnings:
            ok = ok and self.query_one("#ack", ToggleSetting).value
        if p.confirm_name:
            ok = ok and self.query_one("#confirm", Input).value.strip() == p.confirm_name
        self.query_one("#run", Button).disabled = not ok

    def on_toggle_setting_changed(self, event) -> None:
        self._update()

    def on_input_changed(self, event) -> None:
        self._update()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.dismiss()
        elif event.button.id == "run" and not event.button.disabled:
            self.dismiss()
            self.on_run(self.plan)
