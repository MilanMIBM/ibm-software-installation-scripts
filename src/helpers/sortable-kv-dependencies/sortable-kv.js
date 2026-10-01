function render({ model, el }) {
  el.classList.add("sortable-kv-widget");

  let draggedItem = null;
  let draggedIndex = null;
  let dropTarget = null;
  let dropPosition = null;

  // Prevents change:value from triggering a full re-render while the user
  // is actively typing - we update the model but own the DOM ourselves.
  let suppressValueRerender = false;

  function setModelValue(items) {
    suppressValueRerender = true;
    model.set("value", items);
    model.save_changes();
    suppressValueRerender = false;
  }

  function buildRow(item, index) {
    let movable = model.get("movable");
    let editable = model.get("editable");

    let row = document.createElement("div");
    row.className = "kv-row";
    row.draggable = movable;
    row.dataset.index = index;

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
    keyField.className = "kv-key" + (editable ? "" : " readonly");
    keyField.value = item.key ?? "";
    keyField.placeholder = model.get("key_placeholder");
    keyField.readOnly = !editable;
    keyField.addEventListener("mousedown", e => e.stopPropagation());
    keyField.addEventListener("keydown", e => e.stopPropagation());
    keyField.addEventListener("input", () => {
      let items = model.get("value").map(o => ({ ...o }));
      items[index] = { ...items[index], key: keyField.value };
      setModelValue(items);
    });

    let separator = document.createElement("span");
    separator.className = "kv-separator";
    separator.textContent = ":";

    let valueField = document.createElement("input");
    valueField.type = "text";
    valueField.className = "kv-value" + (editable ? "" : " readonly");
    valueField.value = item.value ?? "";
    valueField.placeholder = model.get("value_placeholder");
    valueField.readOnly = !editable;
    valueField.addEventListener("mousedown", e => e.stopPropagation());
    valueField.addEventListener("keydown", e => e.stopPropagation());
    valueField.addEventListener("input", () => {
      let items = model.get("value").map(o => ({ ...o }));
      items[index] = { ...items[index], value: valueField.value };
      setModelValue(items);
    });

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

    return row;
  }

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
      container.appendChild(buildRow(item, index));
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
  model.on("change:value", () => { if (!suppressValueRerender) renderList(); });
  model.on("change:label", renderList);
  model.on("change:addable", renderList);
  model.on("change:removable", renderList);
  model.on("change:editable", renderList);
  model.on("change:movable", renderList);
}

export default { render };
