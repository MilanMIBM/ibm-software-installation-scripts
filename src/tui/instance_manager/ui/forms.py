"""Generated forms (create, edit), the StoragePicker and the plan screen (plan §5.3, §6).

Forms are built from a FormModel: steps (S1 custom_steps, else role groups), labels, bounds,
enums, show_if dependencies, secrets with a Generate button. Storage-class fields get a
StoragePicker: classes the field accepts first; "show all" adds the rest dimmed with the
reason (object classes never); a StorageKindTag beside it follows every selection.
Nothing changes the cluster here: Preview builds an ActionPlan; the plan screen runs it.
"""

from __future__ import annotations

from typing import ClassVar

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Checkbox, Input, Label, Select, Static, Switch

from ..model import Field, FormModel, Instance, InstanceType, Kind, Path, Role, StorageClassInfo, path_str
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
    """Select + 'show all' + StorageKindTag. Value = the StorageClass name."""

    DEFAULT_CSS = """
    StoragePicker { height: auto; }
    StoragePicker Select { width: 1fr; }
    StoragePicker .all { width: auto; padding: 1 1 0 1; color: $text-muted; }
    StoragePicker StorageKindTag { width: 36; }
    """

    def __init__(self, f: Field, sc: dict[str, StorageClassInfo], value: str | None, **kw):
        super().__init__(**kw)
        self.f, self.sc, self.show_all = f, sc, False
        self._value = value

    def compose(self) -> ComposeResult:
        yield Select(self._options(), value=self._value if self._value in self._names() else Select.BLANK,
                     allow_blank=True, prompt="StorageClass")
        yield Label("all", classes="all")
        yield Switch(value=False, id="all")
        yield StorageKindTag(self.sc.get(self._value), self.f.storage)

    def _ok(self, info: StorageClassInfo) -> bool:
        return self.f.storage.accepts(info.kind) if self.f.storage else info.kind != Kind.OBJECT

    def _names(self) -> list[str]:
        return [n for n, i in self.sc.items() if i.kind != Kind.OBJECT and (self.show_all or self._ok(i))]

    def _options(self):
        infos = sorted((i for i in self.sc.values() if i.kind != Kind.OBJECT),
                       key=lambda i: (not self._ok(i), not any(e.source == "config" for e in i.evidence),
                                      not i.default, i.name))
        out = []
        for i in infos:
            if self._ok(i):
                label = Text(f"{i.name}  ", style="bold")
                label.append(i.kind.label + ("  default" if i.default else ""), style="dim")
            elif self.show_all:
                label = Text(f"{i.name}  {i.kind.label}  - not {self.f.storage.need.value}", style="dim strike")
            else:
                continue
            out.append((label, i.name))
        return out

    @property
    def value(self) -> str | None:
        v = self.query_one(Select).value
        return None if v is Select.BLANK else str(v)

    def on_switch_changed(self, event: Switch.Changed) -> None:
        event.stop()
        self.show_all = event.value
        cur = self.value
        sel = self.query_one(Select)
        sel.set_options(self._options())
        if cur in self._names():
            sel.value = cur

    def on_select_changed(self, event: Select.Changed) -> None:
        v = None if event.value is Select.BLANK else str(event.value)
        self.query_one(StorageKindTag).show(self.sc.get(v) if v else None, self.f.storage)


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
                                                            else Select.BLANK)
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
        w = self.query(".fwidget").first()
        if isinstance(w, StoragePicker):
            return w.value
        if isinstance(w, Switch):
            return w.value
        if isinstance(w, Select):
            return None if w.value is Select.BLANK else w.value
        inp = self.query(Input).first()
        return inp.value if inp.value != "" else None

    def set_value(self, value) -> None:
        w = self.query(".fwidget").first()
        if isinstance(w, Select):
            w.value = value if value in (self.f.enum or []) else Select.BLANK
        elif isinstance(w, Switch):
            w.value = bool(value)
        elif not isinstance(w, StoragePicker):
            self.query(Input).first().value = "" if value is None else str(value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "gen":
            event.stop()
            self.query(Input).first().value = pl.random_password()


class _FormBase(ModalScreen):
    BINDINGS: ClassVar[list[BindingType]] = [Binding("escape", "dismiss", "cancel")]

    def rows(self) -> list[FieldRow]:
        return list(self.query(FieldRow))

    def values(self) -> dict[Path, object]:
        return {r.f.path: r.value for r in self.rows()}

    def refresh_visibility(self) -> None:
        vals = self.values()
        for r in self.rows():
            vis = pl.shown(r.f, vals)
            if r.display != vis:
                r.display = vis

    def on_input_changed(self, event) -> None:
        self.refresh_visibility()

    def on_select_changed(self, event) -> None:
        row = next((a for a in event.control.ancestors if isinstance(a, FieldRow)), None)
        if row is not None and row.f.role == Role.SIZE_PRESET and row.f.presets:
            meta = next((p.get("metadata") or {} for p in row.f.presets if p.get("value") == event.value), {})
            for r in self.rows():
                key = ".".join(r.f.path[1:])
                if r is not row and (key in meta or r.f.path[-1] in meta):
                    r.set_value(meta.get(key, meta.get(r.f.path[-1])))   # the template fills sizes; still editable
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
                    yield Checkbox(f"Also save the credentials in the Software Hub vault (shared with {who})",
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


class PlanScreen(ModalScreen):
    """The ActionPlan before it runs: summary, changes, steps with dry-run results, warnings, errors."""

    DEFAULT_CSS = FORM_CSS.format(name="PlanScreen")
    BINDINGS: ClassVar[list[BindingType]] = [Binding("escape", "dismiss", "cancel")]

    def __init__(self, plan: ActionPlan, on_run):
        super().__init__()
        self.plan, self.on_run = plan, on_run

    def compose(self) -> ComposeResult:
        p = self.plan
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
        with Vertical():
            yield Label(f"plan · {p.op} {p.target}  (esc to cancel)", classes="title")
            with VerticalScroll():
                yield Static(t)
            if p.warnings:
                yield Checkbox("I have read the warnings above", id="ack")
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
            ok = ok and self.query_one("#ack", Checkbox).value
        if p.confirm_name:
            ok = ok and self.query_one("#confirm", Input).value.strip() == p.confirm_name
        self.query_one("#run", Button).disabled = not ok

    def on_checkbox_changed(self, event) -> None:
        self._update()

    def on_input_changed(self, event) -> None:
        self._update()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.dismiss()
        elif event.button.id == "run" and not event.button.disabled:
            self.dismiss()
            self.on_run(self.plan)
