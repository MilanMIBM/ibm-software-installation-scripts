from typing import Sequence
import marimo as mo
import anywidget
import traitlets


_ESM = """
function render({ model, el }) {
  el.classList.add("sortable-kv-widget");

  let draggedItem = null;
  let draggedIndex = null;
  let dropTarget = null;
  let dropPosition = null;

  function renderList() {
    el.replaceChildren();

    let label = model.get("label");
    if (label) {
      let heading = document.createElement("div");
      heading.className = "kv-label";
      heading.textContent = label;
      el.appendChild(heading);
    }

    let container = document.createElement("div");
    container.className = "kv-container";

    model.get("value").forEach((item, index) => {
      let row = document.createElement("div");
      row.className = "kv-row";
      row.draggable = true;
      row.dataset.index = index;

      let movable = model.get("movable");
      row.draggable = movable;

      let dragHandle = document.createElement("button");
      dragHandle.className = "drag-handle" + (movable ? "" : " hidden");
      dragHandle.innerHTML = `
        <svg width="10" height="10" viewBox="0 0 16 16">
          <circle cx="4" cy="4" r="1"/>
          <circle cx="12" cy="4" r="1"/>
          <circle cx="4" cy="8" r="1"/>
          <circle cx="12" cy="8" r="1"/>
          <circle cx="4" cy="12" r="1"/>
          <circle cx="12" cy="12" r="1"/>
        </svg>
      `;
      dragHandle.setAttribute("aria-label", `Reorder row ${index + 1}`);

      let keyField = document.createElement("input");
      keyField.type = "text";
      keyField.className = "kv-key" + (model.get("editable") ? "" : " readonly");
      keyField.value = item.key ?? "";
      keyField.placeholder = model.get("key_placeholder");
      keyField.readOnly = !model.get("editable");
      keyField.addEventListener("mousedown", e => e.stopPropagation());
      keyField.addEventListener("change", () => {
        let items = model.get("value").map(o => ({ ...o }));
        items[index] = { ...items[index], key: keyField.value };
        model.set("value", items);
        model.save_changes();
      });
      keyField.addEventListener("keydown", e => e.stopPropagation());

      let separator = document.createElement("span");
      separator.className = "kv-separator";
      separator.textContent = ":";

      let valueField = document.createElement("input");
      valueField.type = "text";
      valueField.className = "kv-value" + (model.get("editable") ? "" : " readonly");
      valueField.value = item.value ?? "";
      valueField.placeholder = model.get("value_placeholder");
      valueField.readOnly = !model.get("editable");
      valueField.addEventListener("mousedown", e => e.stopPropagation());
      valueField.addEventListener("change", () => {
        let items = model.get("value").map(o => ({ ...o }));
        items[index] = { ...items[index], value: valueField.value };
        model.set("value", items);
        model.save_changes();
      });
      valueField.addEventListener("keydown", e => e.stopPropagation());

      row.appendChild(dragHandle);
      row.appendChild(keyField);
      row.appendChild(separator);
      row.appendChild(valueField);

      if (model.get("removable")) {
        let removeButton = document.createElement("button");
        removeButton.className = "remove-button";
        removeButton.innerHTML = `
          <svg width="10" height="10" viewBox="0 0 14 14" fill="none">
            <path d="M4 4l6 6m0-6l-6 6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
          </svg>
        `;
        removeButton.setAttribute("aria-label", `Remove row ${index + 1}`);
        removeButton.addEventListener("click", e => {
          e.stopPropagation();
          removeItem(index);
        });
        row.appendChild(removeButton);
      }

      if (movable) {
        row.addEventListener("dragstart", e => {
          draggedItem = row;
          draggedIndex = index;
          row.classList.add("dragging");
          e.dataTransfer.effectAllowed = "move";
          e.dataTransfer.setData("text/html", row.outerHTML);
        });

        row.addEventListener("dragend", () => {
          row.classList.remove("dragging");
          draggedItem = null;
          draggedIndex = null;
          clearDropIndicators();
        });

        row.addEventListener("dragover", e => {
          if (draggedItem && draggedItem !== row) {
            e.preventDefault();
            e.dataTransfer.dropEffect = "move";
            let rect = row.getBoundingClientRect();
            let newDropPosition = e.clientY < rect.top + rect.height / 2 ? "top" : "bottom";
            if (dropTarget !== row || dropPosition !== newDropPosition) {
              clearDropIndicators();
              dropTarget = row;
              dropPosition = newDropPosition;
              showDropIndicator(row, newDropPosition);
            }
          }
        });

        row.addEventListener("dragleave", e => {
          if (!row.contains(e.relatedTarget)) {
            clearDropIndicators();
          }
        });

        row.addEventListener("drop", e => {
          e.preventDefault();
          if (draggedItem && draggedItem !== row) {
            let targetIndex = parseInt(row.dataset.index);
            let newIndex = dropPosition === "bottom" ? targetIndex + 1 : targetIndex;
            if (draggedIndex < newIndex) newIndex--;
            reorderItems(draggedIndex, newIndex);
          }
          clearDropIndicators();
        });
      }

      container.appendChild(row);
    });

    el.appendChild(container);

    if (model.get("addable")) {
      let addButton = document.createElement("button");
      addButton.className = "add-button";
      addButton.textContent = "+ Add row";
      addButton.addEventListener("click", () => addItem());
      el.appendChild(addButton);
    }
  }

  function addItem() {
    model.set("value", [...model.get("value"), { key: "", value: "" }]);
    model.save_changes();
  }

  function removeItem(index) {
    model.set("value", model.get("value").toSpliced(index, 1));
    model.save_changes();
  }

  function showDropIndicator(element, position) {
    let indicator = document.createElement("div");
    indicator.className = "drop-indicator";
    indicator.style.cssText = "position:absolute;left:0;right:0;height:2px;background:#0066cc;z-index:1000;" +
      (position === "top" ? "top:-1px" : "bottom:-1px");
    element.style.position = "relative";
    element.appendChild(indicator);
  }

  function clearDropIndicators() {
    el.querySelectorAll(".drop-indicator").forEach(i => i.remove());
    dropTarget = null;
    dropPosition = null;
  }

  function reorderItems(fromIndex, toIndex) {
    let items = [...model.get("value")];
    let [moved] = items.splice(fromIndex, 1);
    items.splice(toIndex, 0, moved);
    model.set("value", items);
    model.save_changes();
  }

  renderList();
  model.on("change:value", renderList);
  model.on("change:label", renderList);
  model.on("change:addable", renderList);
  model.on("change:removable", renderList);
  model.on("change:editable", renderList);
  model.on("change:movable", renderList);
}

export default { render };
"""

_CSS = """
.sortable-kv-widget {
  font-family: system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
  max-width: 100%;
}
.sortable-kv-widget .kv-label {
  font-size: 13px;
  font-weight: 600;
  color: #172b4d;
  margin-bottom: 6px;
}
.sortable-kv-widget .kv-container {
  background: white;
  border: 1px solid #e1e5e9;
  border-radius: 6px;
  overflow: hidden;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
}
.sortable-kv-widget .kv-row {
  position: relative;
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 10px;
  background: white;
  border-bottom: 1px solid #e1e5e9;
  transition: background-color 0.15s ease, opacity 0.15s ease;
  cursor: grab;
}
.sortable-kv-widget .kv-row:last-child {
  border-bottom: none;
}
.sortable-kv-widget .kv-row:hover {
  background-color: #f8f9fa;
}
.sortable-kv-widget .kv-row:hover .remove-button {
  opacity: 1;
}
.sortable-kv-widget .kv-row.dragging {
  opacity: 0.5;
  cursor: grabbing;
}
.sortable-kv-widget .drag-handle.hidden {
  visibility: hidden;
  pointer-events: none;
}
.sortable-kv-widget .drag-handle {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 18px;
  height: 18px;
  border: none;
  background: transparent;
  cursor: grab;
  color: #6b778c;
  flex-shrink: 0;
}
.sortable-kv-widget .drag-handle:active {
  cursor: grabbing;
}
.sortable-kv-widget .drag-handle svg {
  fill: currentColor;
}
.sortable-kv-widget .kv-key,
.sortable-kv-widget .kv-value {
  flex: 1;
  font-size: 14px;
  font-family: inherit;
  color: #172b4d;
  border: 1px solid transparent;
  border-radius: 3px;
  padding: 2px 6px;
  background: transparent;
  outline: none;
  min-width: 0;
  cursor: text;
}
.sortable-kv-widget .kv-key:focus,
.sortable-kv-widget .kv-value:focus {
  border-color: #0052cc;
  background: white;
}
.sortable-kv-widget .kv-key.readonly,
.sortable-kv-widget .kv-value.readonly {
  cursor: default;
  color: #172b4d;
}
.sortable-kv-widget .kv-separator {
  color: #6b778c;
  font-size: 14px;
  flex-shrink: 0;
  user-select: none;
}
.sortable-kv-widget .remove-button {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 18px;
  height: 18px;
  border: none;
  background: transparent;
  cursor: pointer;
  border-radius: 3px;
  color: #6b778c;
  flex-shrink: 0;
  opacity: 0;
  transition: opacity 0.15s ease, background-color 0.15s ease;
}
.sortable-kv-widget .remove-button:hover {
  background-color: #e4e6ea;
  color: #42526e;
}
.sortable-kv-widget .add-button {
  margin-top: 8px;
  padding: 5px 10px;
  font-size: 13px;
  font-family: inherit;
  color: #0052cc;
  background: transparent;
  border: 1px dashed #c1c7d0;
  border-radius: 4px;
  cursor: pointer;
  width: 100%;
  text-align: left;
  transition: background-color 0.15s ease, border-color 0.15s ease;
}
.sortable-kv-widget .add-button:hover {
  background-color: #f4f5f7;
  border-color: #0052cc;
}
.sortable-kv-widget .drop-indicator {
  background-color: #0052cc !important;
  border-radius: 1px;
}
"""


class SortableKV(anywidget.AnyWidget):
    """Interactive sortable key/value list widget.

    Each row is a dict with ``key`` and ``value`` string fields. Rows drag
    as a single unit via the grip handle on the left.

    Args:
        value: Initial list of ``{"key": str, "value": str}`` dicts.
        addable: Allow inserting new rows (default: False).
        removable: Allow deleting rows (default: False).
        editable: Allow inline editing of key/value fields (default: True).
        movable: Allow reordering rows by drag-and-drop (default: True).
        label: Optional heading shown above the list.
        key_placeholder: Placeholder text for the key field.
        value_placeholder: Placeholder text for the value field.
        **kwargs: Forwarded to ``anywidget.AnyWidget``.
    """

    _esm = traitlets.Unicode(_ESM).tag(sync=True)
    _css = traitlets.Unicode(_CSS).tag(sync=True)

    value = traitlets.List(traitlets.Dict()).tag(sync=True)
    addable = traitlets.Bool(default_value=False).tag(sync=True)
    removable = traitlets.Bool(default_value=False).tag(sync=True)
    editable = traitlets.Bool(default_value=True).tag(sync=True)
    movable = traitlets.Bool(default_value=True).tag(sync=True)
    label = traitlets.Unicode("").tag(sync=True)
    key_placeholder = traitlets.Unicode("key").tag(sync=True)
    value_placeholder = traitlets.Unicode("value").tag(sync=True)

    def __init__(
        self,
        value: Sequence[dict],
        *,
        addable: bool = False,
        removable: bool = False,
        editable: bool = True,
        movable: bool = True,
        label: str = "",
        key_placeholder: str = "key",
        value_placeholder: str = "value",
        **kwargs,
    ) -> None:
        rows = [
            {"key": str(r), "value": ""}
            if isinstance(r, str)
            else {"key": str(r.get("key", "")), "value": str(r.get("value", ""))}
            for r in value
        ]
        super().__init__(
            value=rows,
            addable=addable,
            removable=removable,
            editable=editable,
            movable=movable,
            label=label,
            key_placeholder=key_placeholder,
            value_placeholder=value_placeholder,
            **kwargs,
        )


def sortable_kv(
    value: Sequence[dict],
    *,
    addable: bool = False,
    removable: bool = False,
    editable: bool = True,
    movable: bool = True,
    label: str = "",
    key_placeholder: str = "key",
    value_placeholder: str = "value",
    **kwargs,
) -> mo.ui.anywidget:
    return mo.ui.anywidget(
        SortableKV(
            value,
            addable=addable,
            removable=removable,
            editable=editable,
            movable=movable,
            label=label,
            key_placeholder=key_placeholder,
            value_placeholder=value_placeholder,
            **kwargs,
        )
    )
