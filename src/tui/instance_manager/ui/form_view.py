"""Inline forms (cache plan §4.3): one FormView for create, scale/edit and sub-service create/edit.

A FormSpec is computed once per model version: rows in step order, the starting values and the
show_if dependents map (field -> the rows whose visibility it decides), so a change toggles only
those rows. The view checks each field as you type (150 ms debounce, local only: no cluster call)
and posts Changed / FieldFocused / Submit. The app turns Submit into a plan (create or edit, for
the main provider or a sub-service owner); nothing here changes the cluster.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.events import Click
from textual.message import Message
from textual.widgets import Button, Checkbox, Input, Label, Select, Static

from ...common.ui_util import set_text
from ..discovery.observed import flatten
from ..model import Field, FormModel, Instance, InstanceType, Path, Role, StorageClassInfo
from ..ops import payload as pl
from .forms import FieldRow, FormLogic

STEP_FOR_ROLE = {Role.STORAGE_CLASS: "storage", Role.SECRET: "security"}


def step_of(f: Field) -> str:
    return f.step or STEP_FOR_ROLE.get(f.role, "settings")


def step_title(step: str) -> str:
    return step.replace("_", " ").capitalize()


@dataclass
class FormSpec:
    mode: str                                   # create | edit
    itype: InstanceType
    fm: FormModel
    rows: list[tuple[str, Field]]               # (step, field) in display order
    initial: dict[Path, object]
    dependents: dict[Path, list[Path]]
    steps: list[str]
    inst: Instance | None = None
    current: dict = field(default_factory=dict)  # edit: the instance's flattened spec
    offers_vault: bool = True

    @property
    def title(self) -> str:
        if self.mode == "edit" and self.inst is not None:
            return f"scale · {self.inst.display_name or self.inst.name}"
        return f"new {self.itype.display} instance"


def _dependents(fields: list[Field]) -> dict[Path, list[Path]]:
    deps: dict[Path, list[Path]] = {}
    for f in fields:
        for ctrl in f.show_if or {}:
            deps.setdefault(ctrl, []).append(f.path)
    return deps


def create_spec(itype: InstanceType, fm: FormModel, sc: dict[str, StorageClassInfo],
                offers_vault: bool = True) -> FormSpec:
    fields = sorted(pl.payload_fields(fm), key=lambda f: (f.order, f.path))
    rows = [(step_of(f), f) for f in fields]
    return FormSpec("create", itype, fm, rows, pl.initial_values(fm, sc), _dependents(fields),
                    list(dict.fromkeys(s for s, _ in rows)), offers_vault=offers_vault)


def editable_fields(fm: FormModel, flat: dict) -> list[Field]:
    cands = [f for f in fm.fields.values() if f.role.capacity and f.path in flat
             and f.mutability.value != "immutable" and not any(p.startswith("[") for p in f.path)]
    return fm.representatives(cands)


def edit_spec(itype: InstanceType, inst: Instance, fm: FormModel) -> FormSpec:
    flat = flatten(inst.spec)
    fields = editable_fields(fm, flat)
    rows = [("scale", f) for f in fields]
    return FormSpec("edit", itype, fm, rows, {f.path: flat.get(f.path) for f in fields}, _dependents(fields),
                    ["scale"] if fields else [], inst=inst, current=flat, offers_vault=False)


class FormView(FormLogic, Vertical):
    DEFAULT_CSS = """
    FormView { height: 1fr; }
    FormView #stepbar { height: 1; padding: 0 1; background: $panel; }
    FormView #stepbar .stepbtn { width: auto; margin-right: 3; color: $text-muted; }
    FormView #stepbar .stepbtn:hover { color: $accent; text-style: underline; }
    FormView #fscroll { height: 1fr; padding: 0 1; }
    FormView .step { text-style: bold underline; margin-top: 1; height: 1; }
    FormView .frow { height: auto; min-height: 3; }
    FormView .flabel { width: 28; padding-top: 1; text-wrap: nowrap; text-overflow: ellipsis; }
    FormView .fwidget { width: 1fr; }
    FormView .fhint { width: 16; padding-top: 1; color: $text-muted; }
    FormView .ferr { height: auto; padding-left: 28; color: $error; display: none; }
    FormView .ferr.-on { display: block; }
    FormView .ferr.-warn { color: $warning; }
    FormView .frow.-changed .flabel { color: $accent; text-style: bold; }
    FormView #fbuttons { height: 3; padding: 0 1; }
    FormView #fbuttons Button { margin-right: 2; }
    """

    class Changed(Message):
        def __init__(self, view: FormView):
            super().__init__()
            self.view = view

    class FieldFocused(Message):
        def __init__(self, view: FormView, field: Field | None):
            super().__init__()
            self.view = view
            self.field = field

    class Submit(Message):
        def __init__(self, view: FormView):
            super().__init__()
            self.view = view

    DEBOUNCE = 0.15

    def __init__(self, spec: FormSpec, sc: dict[str, StorageClassInfo], owner=None,
                 existing: Callable[[], list[str]] | None = None, name_regex: str | None = None,
                 vault_default: bool | None = None, vault_label: str = "", **kw):
        super().__init__(**kw)
        self.spec, self.sc, self.owner = spec, sc, owner
        self.existing = existing or (lambda: [])
        self.name_regex = name_regex
        self.vault_default, self.vault_label = vault_default, vault_label
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self._err: dict[Path | str, Label] = {}
        self._timer = None
        self._step_anchor: dict[str, Label] = {}

    # -- layout -----------------------------------------------------------------------------
    def _row(self, label: str, widget, hint: str = "") -> Horizontal:
        return Horizontal(Label(label, classes="flabel"), widget, Label(hint, classes="fhint"), classes="frow")

    def compose(self) -> ComposeResult:
        spec = self.spec
        if len(spec.steps) > 1:
            with Horizontal(id="stepbar"):
                for i, s in enumerate(spec.steps):
                    yield Label(step_title(s), id=f"stepbtn-{i}", classes="stepbtn")
        with VerticalScroll(id="fscroll"):
            if spec.mode == "create":
                yield self._row("Name", Input(id="name", placeholder="instance name", classes="fwidget"), "required")
                self._err["name"] = Label("", classes="ferr")
                yield self._err["name"]
                yield self._row("Description", Input(id="description", classes="fwidget"))
                if spec.itype.versions:
                    yield self._row("Add-on version", Select([(v, v) for v in spec.itype.versions],
                                                             value=spec.itype.versions[-1], allow_blank=False,
                                                             id="version", classes="fwidget"))
            step = None
            for s, f in spec.rows:
                if s != step:
                    step = s
                    anchor = Label(step_title(s), classes="step")
                    self._step_anchor.setdefault(s, anchor)
                    yield anchor
                yield FieldRow(f, spec.initial.get(f.path), self.sc)
                self._err[f.path] = Label("", classes="ferr")
                yield self._err[f.path]
            if not spec.rows:
                yield Static("no payload fields were discovered for this type (see the Fields tab; D6 samples)"
                             if spec.mode == "create" else
                             "no editable scale/capacity fields were discovered for this instance", classes="fhint")
            if spec.mode == "create" and spec.offers_vault:
                yield Label("Credentials", classes="step")
                yield Checkbox(self.vault_label or "Also save the credentials in the Software Hub vault",
                               value=bool(self.vault_default), id="vault")
            if spec.mode == "edit":
                yield Static("aliases (copies of the same value elsewhere in the CR) change together; "
                             "the plan lists every one", classes="fhint")
        with Horizontal(id="fbuttons"):
            yield Button("Preview plan", id="preview", variant="primary",
                         disabled=spec.mode == "edit" and not spec.rows)
            yield Button("Reset", id="reset")

    def on_mount(self) -> None:
        self.refresh_visibility()

    # -- values --------------------------------------------------------------------------------
    def _input(self, wid: str) -> str:
        found = self.query(f"#{wid}")
        return found.first().value.strip() if found else ""

    @property
    def name(self) -> str:
        return self._input("name")

    @property
    def description(self) -> str:
        return self._input("description")

    @property
    def version(self) -> str | None:
        found = self.query("#version")
        return found.first().value if found else None

    @property
    def vault(self) -> bool | None:
        found = self.query("#vault")
        return found.first().value if found else None

    @property
    def dirty(self) -> bool:
        """The user typed something: a name, a description, or a value other than the starting one
        (a background re-check of the model then keeps this draft's widgets)."""
        if self.name or self.description:
            return True
        for r in self.rows():
            a, b = r.value, self.spec.initial.get(r.f.path)
            if a in (None, "") and b in (None, ""):
                continue
            if str(a) != str(b):
                return True
        return False

    def changes(self) -> dict[Path, object]:
        """edit: the fields whose value differs from the instance's current one."""
        cur = self.spec.current
        return {r.f.path: r.value for r in self.rows()
                if r.value is not None and str(r.value) != str(cur.get(r.f.path))}

    def reset(self) -> None:
        for r in self.rows():
            r.set_value(self.spec.initial.get(r.f.path))
        for wid in ("name", "description"):
            found = self.query(f"#{wid}")
            if found:
                found.first().value = ""
        self.refresh_visibility()
        self._schedule()

    # -- reactions -------------------------------------------------------------------------------
    def _row_of(self, widget) -> FieldRow | None:
        return next((a for a in widget.ancestors_with_self if isinstance(a, FieldRow)), None)

    def _after_change(self, control, value=None, preset: bool = False) -> None:
        row = self._row_of(control)
        if row is not None:
            if preset:
                self.apply_preset(row, value)
            deps = self.spec.dependents.get(row.f.path)
            if deps:
                self.refresh_visibility(deps)
        self._schedule()

    def on_input_changed(self, event: Input.Changed) -> None:
        event.stop()
        self._after_change(event.control)

    def on_select_changed(self, event: Select.Changed) -> None:
        event.stop()
        self._after_change(event.control, event.value, preset=True)

    def on_switch_changed(self, event) -> None:
        event.stop()
        self._after_change(event.control)

    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        event.stop()
        self._schedule()

    def on_descendant_focus(self, event) -> None:
        row = self._row_of(event.widget)
        self.post_message(self.FieldFocused(self, row.f if row else None))

    def on_click(self, event: Click) -> None:
        wid = getattr(event.widget, "id", "") or ""
        if wid.startswith("stepbtn-"):
            event.stop()
            step = self.spec.steps[int(wid.split("-", 1)[1])]
            anchor = self._step_anchor.get(step)
            if anchor is not None:
                self.query_one("#fscroll", VerticalScroll).scroll_to_widget(anchor, top=True, animate=False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "preview":
            event.stop()
            self.check_now()
            self.post_message(self.Submit(self))
        elif event.button.id == "reset":
            event.stop()
            self.reset()

    def _schedule(self) -> None:
        if self._timer is not None:
            self._timer.stop()
        self._timer = self.set_timer(self.DEBOUNCE, self.check_now)

    # -- checks (local only) ---------------------------------------------------------------------
    def check_now(self) -> None:
        self._timer = None
        spec = self.spec
        errors, warnings = [], []
        if spec.mode == "create":
            name_errs = pl.check_name(spec.itype, self.name, self.existing(), self.name_regex) if self.name else []
            self._show(self._err.get("name"), name_errs, [])
            errors += name_errs
        changed = self.changes() if spec.mode == "edit" else {}
        for r in self.rows():
            label = self._err.get(r.f.path)
            if not r.display or (spec.mode == "edit" and r.f.path not in changed):
                self._show(label, [], [])
                if spec.mode == "edit":
                    r.set_class(False, "-changed")
                continue
            e, w = pl.check_field(r.f, r.value, self.sc)
            if spec.mode == "edit":
                e = [x for x in e if not x.endswith(" is required")]
                r.set_class(True, "-changed")
            self._show(label, e, w)
            errors += e
            warnings += w
        self.errors, self.warnings = errors, warnings
        self.post_message(self.Changed(self))

    @staticmethod
    def _show(label: Label | None, errors: list[str], warnings: list[str]) -> None:
        if label is None:
            return
        text = "\n".join([*(f"x {e}" for e in errors), *(f"! {w}" for w in warnings)])
        set_text(label, text)
        label.set_class(bool(text), "-on")
        label.set_class(bool(warnings) and not errors, "-warn")
