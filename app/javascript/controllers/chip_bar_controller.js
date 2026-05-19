import { Controller } from "@hotwired/stimulus"

// Composable-filter chip bar.
//
// Owns the JSON-encoded AST tree (Stimulus value), renders one
// element per top-level AND child, and exposes an add-filter
// popover backed by Filters::Schema. Clicks on a chip route to a
// per-bucket editor that mutates the tree and submits the form
// with ?q=<encoded>.
//
// Tree shape supported here:
//   - top-level AND of flat chips
//   - OR sub-groups containing 2+ flat chips
//
// NOT wrappers are still rendered as a read-only "complex filter"
// badge — added in a follow-up commit.
//
// Chip addressing: paths are arrays. `[i]` = top-level i'th child.
// `[i, j]` = j'th child of the i'th top-level OR group. We pass
// paths through DOM via JSON strings on `data-chip-path`.
export default class extends Controller {
  static targets = [
    "form", "qInput", "chips", "addButton", "addMenu", "addSearch", "addList", "editor"
  ]
  static values = {
    tree: Object,
    schema: Array,
    submitUrl: String
  }

  connect() {
    this.editingChipPath = null
    this.pendingAddTarget = null  // null = top-level AND; { path } = append to OR group at path
    this.typeaheadSearchSeq = 0
    this.renderChips()
    document.addEventListener("click", this.handleDocumentClick)
    // Turbo's morph-based refreshes can wipe the chips container —
    // the server-rendered partial has an empty `<div data-chip-bar-target="chips">`
    // (the controller fills it client-side), so morphing the live
    // DOM to match the new HTML deletes every rendered chip. We
    // re-render after every Turbo render pass to put them back.
    this.handleTurboRender = () => {
      if (!this.hasChipsTarget) return
      this.refreshTreeValueFromElement()
      this.renderChips()
    }
    document.addEventListener("turbo:render", this.handleTurboRender)
    document.addEventListener("turbo:frame-render", this.handleTurboRender)
    document.addEventListener("turbo:morph", this.handleTurboRender)

    // Open popovers are pure client state — the server-rendered HTML
    // always has them hidden — so idiomorph patches the `hidden`
    // class back on, closing the operator's open menu mid-interaction
    // during any broadcast_refresh. Cancel the per-element morph for
    // open popovers (we can't mark them data-turbo-permanent because
    // that would also block full-visit navigation from updating their
    // host chip-bar).
    this.handleBeforeMorphElement = (event) => {
      const el = event.target
      if (!(el instanceof Element)) return
      if (!this.element.contains(el)) return
      const isPopover = (this.hasAddMenuTarget && el === this.addMenuTarget) ||
                        (this.hasEditorTarget && el === this.editorTarget)
      if (isPopover && !el.classList.contains("hidden")) {
        event.preventDefault()
      }
    }
    document.addEventListener("turbo:before-morph-element", this.handleBeforeMorphElement)
  }

  disconnect() {
    document.removeEventListener("click", this.handleDocumentClick)
    document.removeEventListener("turbo:render", this.handleTurboRender)
    document.removeEventListener("turbo:frame-render", this.handleTurboRender)
    document.removeEventListener("turbo:morph", this.handleTurboRender)
    document.removeEventListener("turbo:before-morph-element", this.handleBeforeMorphElement)
  }

  // Stimulus fires this automatically when the controller's
  // data-chip-bar-tree-value attribute changes — e.g., after a Turbo
  // morph patches the attribute to reflect the new URL state. We
  // re-render so the chips stay synchronized with the tree.
  treeValueChanged() {
    if (this.hasChipsTarget) this.renderChips()
  }

  refreshTreeValueFromElement() {
    const raw = this.element?.dataset?.chipBarTreeValue
    if (!raw) return

    try {
      this.treeValue = JSON.parse(raw)
    } catch (_error) {
      // Keep the existing tree if a partial morph leaves invalid JSON.
    }
  }

  handleDocumentClick = (event) => {
    if (this.element.contains(event.target)) return
    this.closePopovers()
  }

  // ---- AST helpers ----

  topChildren() {
    const tree = this.treeValue || {}
    if (!tree || typeof tree !== "object") return []
    if (Array.isArray(tree.and)) return tree.and
    if (Array.isArray(tree.or) || tree.not !== undefined || "field" in tree) return [ tree ]
    return []
  }

  setTopChildren(children) {
    this.treeValue = { and: children }
    this.syncQInput()
    this.renderChips()
  }

  // Top-level slots can carry a NOT wrapper. `slotInner(slot)` returns
  // the inner node (the chip or OR group being negated). We address
  // chips through the NOT transparently — replaceNodeAtPath /
  // removeNodeAtPath preserve the wrapper unless removing the inner
  // chip empties it.
  slotInner(slot) {
    return slot && typeof slot === "object" && slot.not !== undefined ? slot.not : slot
  }

  slotIsNegated(slot) {
    return slot && typeof slot === "object" && slot.not !== undefined
  }

  // Returns the node at `path`. Path semantics defined at top of file.
  // Walks through any NOT wrapper at the top-level slot transparently.
  nodeAtPath(path) {
    if (!Array.isArray(path) || path.length === 0) return null
    const slot = this.topChildren()[path[0]]
    const inner = this.slotInner(slot)
    if (path.length === 1) return inner
    if (!inner || !Array.isArray(inner.or)) return null
    return inner.or[path[1]]
  }

  // Replace the node at `path`, preserving any top-level NOT wrapper
  // so toggling negation and editing the chip are independent.
  replaceNodeAtPath(path, node) {
    const children = this.topChildren().slice()
    const slot = children[path[0]]
    const wasNegated = this.slotIsNegated(slot)
    let inner
    if (path.length === 1) {
      inner = node
    } else {
      const innerSlot = this.slotInner(slot)
      if (!innerSlot || !Array.isArray(innerSlot.or)) return
      const newOr = innerSlot.or.slice()
      newOr[path[1]] = node
      inner = { or: newOr }
    }
    children[path[0]] = wasNegated ? { not: inner } : inner
    this.setTopChildren(children)
  }

  // Delete the node at `path`. Auto-flattens singleton OR groups
  // (preserving the NOT wrapper) and removes empty OR groups along
  // with their wrappers.
  removeNodeAtPath(path) {
    const children = this.topChildren().slice()
    if (path.length === 1) {
      children.splice(path[0], 1)
    } else {
      const slot = children[path[0]]
      const wasNegated = this.slotIsNegated(slot)
      const innerSlot = this.slotInner(slot)
      if (!innerSlot || !Array.isArray(innerSlot.or)) return
      const newOr = innerSlot.or.slice()
      newOr.splice(path[1], 1)
      if (newOr.length === 0) {
        children.splice(path[0], 1)
      } else if (newOr.length === 1) {
        children[path[0]] = wasNegated ? { not: newOr[0] } : newOr[0]
      } else {
        children[path[0]] = wasNegated ? { not: { or: newOr } } : { or: newOr }
      }
    }
    this.setTopChildren(children)
  }

  // Toggle the NOT wrapper on a top-level slot. Wraps or unwraps the
  // entire chip / OR group in `{not: ...}` without disturbing its
  // contents.
  toggleNegationAtIndex(index) {
    const children = this.topChildren().slice()
    const slot = children[index]
    if (!slot || typeof slot !== "object") return
    children[index] = this.slotIsNegated(slot) ? slot.not : { not: slot }
    this.setTopChildren(children)
  }

  // Wrap the flat chip at `path` (length 1) into an OR group so the
  // operator can append alternatives. Preserves any NOT wrapper on
  // the top-level slot.
  wrapInOrGroup(path) {
    if (path.length !== 1) return path
    const children = this.topChildren().slice()
    const slot = children[path[0]]
    const wasNegated = this.slotIsNegated(slot)
    const inner = this.slotInner(slot)
    if (!inner || !("field" in inner)) return path
    const newInner = { or: [ inner ] }
    children[path[0]] = wasNegated ? { not: newInner } : newInner
    this.setTopChildren(children)
    return [ path[0], 0 ]
  }

  syncQInput() {
    this.qInputTarget.value = encodeTree(this.treeValue)
  }

  submitForm() {
    this.formTarget.requestSubmit()
  }

  // ---- Chip rendering ----

  renderChips() {
    const children = this.topChildren()
    const elements = []
    children.forEach((node, i) => {
      if (i > 0) elements.push(separator("and"))
      elements.push(this.topElement(node, i))
    })
    this.chipsTarget.replaceChildren(...elements)
    this.resolveVisibleTypeaheadLabels()
  }

  topElement(node, index) {
    const negated = this.slotIsNegated(node)
    const inner = this.slotInner(node)

    if (inner && typeof inner === "object" && "field" in inner) {
      return this.flatChipElement(inner, [ index ], { negated })
    }
    if (inner && typeof inner === "object" && Array.isArray(inner.or)) {
      return this.orGroupElement(inner, index, { negated })
    }
    return this.complexBadgeElement(node, [ index ])
  }

  flatChipElement(chip, path, { negated = false } = {}) {
    const meta = this.metaFor(chip.field)
    const wrapper = document.createElement("span")
    wrapper.className = negated
      ? "inline-flex items-center gap-1 rounded-md border border-rose-300 bg-rose-50 px-2 py-1 text-sm hover:bg-rose-100"
      : "inline-flex items-center gap-1 rounded-md border border-gray-300 bg-gray-50 px-2 py-1 text-sm hover:bg-gray-100"

    // The NOT toggle is only meaningful on top-level slots (length-1
    // paths). Inside an OR group, negation belongs on the operator
    // (`is_not`, `does_not_contain`, etc.) — we don't expose a
    // separate wrapper there.
    if (path.length === 1) {
      wrapper.append(notToggleButton(path, negated))
    }

    const editLink = document.createElement("button")
    editLink.type = "button"
    editLink.className = "inline-flex items-baseline gap-1 cursor-pointer"
    editLink.dataset.action = "click->chip-bar#editChip"
    editLink.dataset.chipPath = JSON.stringify(path)
    editLink.append(
      labelSpan(meta ? meta.label : chip.field, { negated }),
      opSpan(chip.op),
      valueSpan(chip, meta)
    )

    const removeButton = document.createElement("button")
    removeButton.type = "button"
    removeButton.className = negated
      ? "ml-1 text-rose-400 hover:text-rose-800 cursor-pointer"
      : "ml-1 text-gray-400 hover:text-gray-700 cursor-pointer"
    removeButton.textContent = "×"
    removeButton.setAttribute("aria-label", `Remove ${meta ? meta.label : chip.field} filter`)
    removeButton.dataset.action = "click->chip-bar#removeChip"
    removeButton.dataset.chipPath = JSON.stringify(path)

    wrapper.append(editLink, removeButton)
    return wrapper
  }

  orGroupElement(orNode, index, { negated = false } = {}) {
    const wrapper = document.createElement("span")
    wrapper.className = negated
      ? "inline-flex items-center gap-1 rounded-md border border-rose-300 bg-rose-50 px-1.5 py-0.5 text-sm"
      : "inline-flex items-center gap-1 rounded-md border border-indigo-300 bg-indigo-50 px-1.5 py-0.5 text-sm"

    wrapper.append(notToggleButton([ index ], negated))

    const opening = document.createElement("span")
    opening.className = negated
      ? "text-xs font-semibold text-rose-700"
      : "text-xs font-semibold text-indigo-700"
    opening.textContent = "("
    wrapper.append(opening)

    orNode.or.forEach((child, j) => {
      if (j > 0) wrapper.append(separator("or"))
      const childPath = [ index, j ]
      if (child && typeof child === "object" && "field" in child) {
        wrapper.append(this.flatChipElement(child, childPath))
      } else {
        wrapper.append(this.complexBadgeElement(child, childPath))
      }
    })

    const addAlt = document.createElement("button")
    addAlt.type = "button"
    addAlt.className = negated
      ? "ml-1 inline-flex items-center rounded border border-dashed border-rose-400 px-1.5 py-0.5 text-xs font-medium text-rose-700 hover:bg-rose-100 cursor-pointer"
      : "ml-1 inline-flex items-center rounded border border-dashed border-indigo-400 px-1.5 py-0.5 text-xs font-medium text-indigo-700 hover:bg-indigo-100 cursor-pointer"
    addAlt.textContent = "+ or"
    addAlt.dataset.action = "click->chip-bar#openAddMenuForOrGroup"
    addAlt.dataset.chipPath = JSON.stringify([ index ])
    wrapper.append(addAlt)

    const closing = document.createElement("span")
    closing.className = negated
      ? "text-xs font-semibold text-rose-700"
      : "text-xs font-semibold text-indigo-700"
    closing.textContent = ")"
    wrapper.append(closing)

    return wrapper
  }

  complexBadgeElement(node, path) {
    const wrapper = document.createElement("span")
    wrapper.className = "inline-flex items-center gap-1 rounded-md border border-amber-300 bg-amber-50 px-2 py-1 text-sm text-amber-800"
    wrapper.title = JSON.stringify(node)
    wrapper.textContent = node && node.not ? "NOT group" : "complex filter"

    const removeButton = document.createElement("button")
    removeButton.type = "button"
    removeButton.className = "ml-1 text-amber-600 hover:text-amber-900 cursor-pointer"
    removeButton.textContent = "×"
    removeButton.dataset.action = "click->chip-bar#removeChip"
    removeButton.dataset.chipPath = JSON.stringify(path)
    wrapper.append(removeButton)
    return wrapper
  }

  metaFor(field) {
    return (this.schemaValue || []).find(meta => meta.field === field)
  }

  // ---- Chip mutations ----

  removeChip(event) {
    const path = JSON.parse(event.currentTarget.dataset.chipPath)
    this.removeNodeAtPath(path)
    this.submitForm()
  }

  toggleNegation(event) {
    const path = JSON.parse(event.currentTarget.dataset.chipPath)
    if (!Array.isArray(path) || path.length !== 1) return
    this.toggleNegationAtIndex(path[0])
    this.submitForm()
  }

  clearAll() {
    this.setTopChildren([])
    this.submitForm()
  }

  // ---- Add-filter popover ----

  // Default add: append a new chip at the top level (AND).
  openAddMenu(event) {
    this.pendingAddTarget = null
    this.closePopovers()
    this.positionPopover(this.addMenuTarget, event.currentTarget)
    this.populateAddMenu("")
    this.addMenuTarget.classList.remove("hidden")
    this.addSearchTarget.value = ""
    this.addSearchTarget.focus()
  }

  // Open the add menu in "append to OR group" mode. The button passes
  // the OR group's top-level path; the next addChip will append into
  // that group instead of the AND root.
  openAddMenuForOrGroup(event) {
    const path = JSON.parse(event.currentTarget.dataset.chipPath)
    this.pendingAddTarget = { kind: "or_group", path }
    this.closePopovers()
    this.positionPopover(this.addMenuTarget, event.currentTarget)
    this.populateAddMenu("")
    this.addMenuTarget.classList.remove("hidden")
    this.addSearchTarget.value = ""
    this.addSearchTarget.focus()
  }

  filterAddMenu() {
    this.populateAddMenu(this.addSearchTarget.value)
  }

  addMenuKeydown(event) {
    if (event.key !== "Enter") return
    event.preventDefault()
    const first = this.addListTarget.querySelector("button")
    if (first) first.click()
  }

  populateAddMenu(query) {
    const q = query.trim().toLowerCase()
    const items = (this.schemaValue || []).filter(meta => {
      if (!q) return true
      return meta.field.toLowerCase().includes(q) || meta.label.toLowerCase().includes(q)
    })

    this.addListTarget.replaceChildren(...items.map(meta => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "flex w-full items-center justify-between gap-2 px-3 py-2 text-left text-sm hover:bg-gray-50 cursor-pointer"
      button.dataset.action = "click->chip-bar#addChip"
      button.dataset.field = meta.field
      const label = document.createElement("span")
      label.textContent = meta.label
      const bucket = document.createElement("span")
      bucket.className = "text-xs text-gray-400"
      bucket.textContent = meta.bucket
      button.append(label, bucket)
      return button
    }))
  }

  addChip(event) {
    const field = event.currentTarget.dataset.field
    const meta = this.metaFor(field)
    if (!meta) return

    const defaults = defaultsFor(meta)
    const newChip = { field, op: defaults.op, value: defaults.value }

    let newPath
    if (this.pendingAddTarget && this.pendingAddTarget.kind === "or_group") {
      const groupIndex = this.pendingAddTarget.path[0]
      const children = this.topChildren().slice()
      const group = children[groupIndex]
      if (!group || !Array.isArray(group.or)) return
      const newOr = group.or.concat([ newChip ])
      children[groupIndex] = { or: newOr }
      this.setTopChildren(children)
      newPath = [ groupIndex, newOr.length - 1 ]
    } else {
      const children = this.topChildren().slice()
      children.push(newChip)
      this.setTopChildren(children)
      newPath = [ children.length - 1 ]
    }

    this.pendingAddTarget = null
    this.closePopovers()
    this.openEditorForPath(newPath)
  }

  // ---- Per-chip editor popover ----

  editChip(event) {
    const path = JSON.parse(event.currentTarget.dataset.chipPath)
    this.openEditorForPath(path)
  }

  openEditorForPath(path) {
    const chip = this.nodeAtPath(path)
    if (!chip || !("field" in chip)) return
    const meta = this.metaFor(chip.field)
    if (!meta) return

    this.editingChipPath = path
    this.editorTarget.replaceChildren(this.editorContent(chip, meta, path))

    const anchor = this.chipsTarget.querySelector(`[data-chip-path='${JSON.stringify(path)}']`) || this.addButtonTarget
    this.positionPopover(this.editorTarget, anchor)
    this.editorTarget.classList.remove("hidden")
  }

  editorContent(chip, meta, path) {
    const root = document.createElement("div")
    root.className = "p-3 space-y-3 min-w-[14rem]"

    const header = document.createElement("div")
    header.className = "text-xs font-semibold uppercase tracking-wide text-gray-500"
    header.textContent = meta.label
    root.append(header)

    if (meta.operators.length > 1) {
      const opSelect = document.createElement("select")
      opSelect.className = "block w-full rounded-md border border-gray-300 px-2 py-1.5 text-sm"
      opSelect.dataset.action = "change->chip-bar#updateChipOp"
      meta.operators.forEach(op => {
        const option = document.createElement("option")
        option.value = op
        option.textContent = humanizeOp(op)
        if (op === chip.op) option.selected = true
        opSelect.append(option)
      })
      root.append(opSelect)
    }

    const valueEditor = this.valueEditorFor(chip, meta)
    if (valueEditor) root.append(valueEditor)

    // Preset-only: surface an "Expand into primitives" button when
    // the current value has a known expansion. Clicking replaces the
    // preset chip with the underlying primitive chips so the operator
    // can tweak the building blocks (date window, OR branches, etc.).
    const expansion = expansionForPresetChip(chip, meta)
    if (expansion && path.length === 1) {
      const expand = document.createElement("button")
      expand.type = "button"
      expand.className = "block w-full rounded-md border border-purple-300 bg-purple-50 px-2 py-1.5 text-xs font-medium text-purple-700 hover:bg-purple-100 cursor-pointer"
      expand.textContent = "Expand into primitives"
      expand.title = "Replace this preset with its underlying primitive chips so you can edit them"
      expand.dataset.action = "click->chip-bar#expandPresetFromEditor"
      root.append(expand)
    }

    const footer = document.createElement("div")
    footer.className = "flex items-center justify-between gap-2 pt-1"

    // Add OR alternative: visible on flat chips (length-1 path) AND
    // on chips already inside an OR group (length-2 path). For flat
    // chips, applying wraps in an OR group first; for grouped chips,
    // it appends an alternative directly to the existing group.
    const addOr = document.createElement("button")
    addOr.type = "button"
    addOr.className = "rounded-md border border-indigo-300 px-2 py-1 text-xs font-medium text-indigo-700 hover:bg-indigo-50 cursor-pointer"
    addOr.textContent = "+ OR alternative"
    addOr.dataset.action = "click->chip-bar#addOrAlternativeFromEditor"
    footer.append(addOr)

    const done = document.createElement("button")
    done.type = "button"
    done.className = "rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 cursor-pointer"
    done.textContent = "Done"
    done.dataset.action = "click->chip-bar#applyEditor"
    footer.append(done)

    root.append(footer)

    return root
  }

  valueEditorFor(chip, meta) {
    if (isPredicateOp(chip.op)) return null
    if (meta.typeahead) return typeaheadEditor(chip, meta, this)

    switch (meta.bucket) {
      case "enum":
      case "fk":
      case "preset":
        return enumEditor(chip, meta)
      case "boolean":
        return null
      case "string":
        return stringEditor(chip)
      case "number":
        return numberEditor(chip)
      case "date":
        return dateEditor(chip)
      case "collection":
        return collectionEditor(chip, meta)
      default:
        return stringEditor(chip)
    }
  }

  applyEditor() {
    if (this.editingChipPath === null) return
    const current = this.nodeAtPath(this.editingChipPath)
    if (!current) return

    const opSelect = this.editorTarget.querySelector("select[data-action*='updateChipOp']")
    const updated = { ...current }
    if (opSelect) updated.op = opSelect.value
    updated.value = readEditorValue(this.editorTarget, updated.op)

    this.replaceNodeAtPath(this.editingChipPath, updated)
    this.closePopovers()
    this.submitForm()
  }

  // Replace a top-level preset chip with its primitive expansion.
  // If the expansion is `{and: [...]}`, splice its children into the
  // top-level AND so they appear as individual chips. If it's a
  // single chip or `{or: [...]}`, use it as one slot.
  expandPresetFromEditor() {
    if (this.editingChipPath === null) return
    if (this.editingChipPath.length !== 1) return
    const current = this.nodeAtPath(this.editingChipPath)
    const meta = current && this.metaFor(current.field)
    const expansion = expansionForPresetChip(current, meta)
    if (!expansion) return

    const replacement = expansion.and && Array.isArray(expansion.and)
      ? expansion.and
      : [ expansion ]

    const children = this.topChildren().slice()
    children.splice(this.editingChipPath[0], 1, ...replacement)
    this.setTopChildren(children)
    this.closePopovers()
    this.submitForm()
  }

  // Apply current edits, then either wrap the chip in a fresh OR
  // group (if it's a flat top-level chip) or address the existing
  // OR group, and open the add menu for the alternative.
  addOrAlternativeFromEditor() {
    if (this.editingChipPath === null) return
    const current = this.nodeAtPath(this.editingChipPath)
    if (!current) return

    const opSelect = this.editorTarget.querySelector("select[data-action*='updateChipOp']")
    const updated = { ...current }
    if (opSelect) updated.op = opSelect.value
    updated.value = readEditorValue(this.editorTarget, updated.op)
    this.replaceNodeAtPath(this.editingChipPath, updated)

    let groupTopPath
    if (this.editingChipPath.length === 1) {
      const newPath = this.wrapInOrGroup(this.editingChipPath)
      groupTopPath = [ newPath[0] ]
    } else {
      groupTopPath = [ this.editingChipPath[0] ]
    }

    this.editorTarget.classList.add("hidden")
    this.editingChipPath = null
    this.pendingAddTarget = { kind: "or_group", path: groupTopPath }

    const anchor = this.chipsTarget.querySelector(`[data-chip-path='${JSON.stringify(groupTopPath)}']`)
      || this.chipsTarget.children[groupTopPath[0]]
      || this.addButtonTarget
    this.positionPopover(this.addMenuTarget, anchor)
    this.populateAddMenu("")
    this.addMenuTarget.classList.remove("hidden")
    this.addSearchTarget.value = ""
    this.addSearchTarget.focus()
  }

  updateChipOp(event) {
    if (this.editingChipPath === null) return
    const newOp = event.currentTarget.value
    const current = this.nodeAtPath(this.editingChipPath)
    if (!current) return
    this.replaceNodeAtPath(this.editingChipPath, { ...current, op: newOp, value: null })
    this.openEditorForPath(this.editingChipPath)
  }

  updateChipValue(event) {
    if (this.editingChipPath === null) return
    const newValue = event.currentTarget.value
    const current = this.nodeAtPath(this.editingChipPath)
    if (!current) return
    this.replaceNodeAtPath(this.editingChipPath, { ...current, value: newValue })
    this.openEditorForPath(this.editingChipPath)
  }

  typeaheadSearchInput(event) {
    const wrapper = event.currentTarget.closest("[data-role='typeahead']")
    if (!wrapper) return
    clearTimeout(wrapper._typeaheadTimer)
    wrapper._typeaheadTimer = setTimeout(() => this.fetchTypeaheadSearch(wrapper), 200)
  }

  typeaheadKeydown(event) {
    const wrapper = event.currentTarget.closest("[data-role='typeahead']")
    if (!wrapper) return

    const options = Array.from(wrapper.querySelectorAll("button[data-role='typeahead-option']"))
    if (options.length === 0) return

    const current = Number(wrapper.dataset.activeIndex || 0)
    if (event.key === "ArrowDown") {
      event.preventDefault()
      setTypeaheadActiveOption(wrapper, Math.min(current + 1, options.length - 1))
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      setTypeaheadActiveOption(wrapper, Math.max(current - 1, 0))
    } else if (event.key === "Enter") {
      event.preventDefault()
      options[current] ? options[current].click() : options[0].click()
    }
  }

  selectTypeaheadOption(event) {
    const option = event.currentTarget
    const wrapper = option.closest("[data-role='typeahead']")
    if (!wrapper) return

    event.stopPropagation()
    const selected = JSON.parse(wrapper.dataset.selected || "[]")
    const value = option.dataset.value
    if (wrapper.dataset.multi === "true") {
      if (!selected.some(v => String(v) === String(value))) selected.push(value)
      wrapper.dataset.selected = JSON.stringify(selected)
    } else {
      wrapper.dataset.selected = JSON.stringify([ value ])
    }

    const meta = this.metaFor(wrapper.dataset.field)
    addMetaOption(meta, { value, label: option.textContent })
    renderTypeaheadState(wrapper, meta)
    const input = wrapper.querySelector("[data-role='typeahead-search']")
    if (input) {
      input.value = ""
      input.focus()
    }
  }

  removeTypeaheadSelection(event) {
    const button = event.currentTarget
    const wrapper = button.closest("[data-role='typeahead']")
    if (!wrapper) return

    event.stopPropagation()
    const selected = JSON.parse(wrapper.dataset.selected || "[]")
    wrapper.dataset.selected = JSON.stringify(selected.filter(value => String(value) !== String(button.dataset.value)))
    renderTypeaheadState(wrapper, this.metaFor(wrapper.dataset.field))
  }

  fetchTypeaheadSearch(wrapper) {
    const input = wrapper.querySelector("[data-role='typeahead-search']")
    const list = wrapper.querySelector("[data-role='typeahead-options']")
    if (!input || !list) return

    const field = wrapper.dataset.field
    const query = input.value || ""
    const requestId = String(++this.typeaheadSearchSeq)
    wrapper.dataset.requestId = requestId

    this.fetchTypeaheadOptions(field, { q: query })
      .then(options => {
        if (wrapper.dataset.requestId !== requestId) return
        renderTypeaheadOptions(wrapper, options)
      })
      .catch(() => {
        if (wrapper.dataset.requestId !== requestId) return
        renderTypeaheadError(wrapper)
      })
  }

  fetchTypeaheadOptions(field, { q = null, ids = [] } = {}) {
    const params = new URLSearchParams()
    params.set("field", field)
    if (q !== null) params.set("q", q)
    ids.forEach(id => params.append("ids[]", id))

    return fetch(`/filters/fk_options?${params.toString()}`, {
      headers: { Accept: "application/json" }
    }).then(response => {
      if (!response.ok) throw new Error(`typeahead request failed: ${response.status}`)
      return response.json()
    })
  }

  resolveVisibleTypeaheadLabels() {
    if (typeof fetch !== "function") return

    const idsByField = new Map()
    collectTypeaheadChipValues(this.topChildren(), field => this.metaFor(field)).forEach((ids, field) => {
      const meta = this.metaFor(field)
      const missing = Array.from(ids).filter(value => !optionExists(meta, value))
      if (missing.length > 0) idsByField.set(field, missing)
    })

    idsByField.forEach((ids, field) => {
      this.fetchTypeaheadOptions(field, { ids })
        .then(options => {
          const meta = this.metaFor(field)
          options.forEach(option => addMetaOption(meta, option))
          this.renderChips()
        })
        .catch(() => {})
    })
  }

  closePopovers() {
    this.addMenuTarget.classList.add("hidden")
    this.editorTarget.classList.add("hidden")
    this.editingChipPath = null
    this.pendingAddTarget = null
  }

  positionPopover(popover, anchor) {
    const containerRect = this.element.getBoundingClientRect()
    const anchorRect = anchor.getBoundingClientRect()
    popover.style.position = "absolute"
    popover.style.top = `${anchorRect.bottom - containerRect.top + 4}px`
    popover.style.left = `${anchorRect.left - containerRect.left}px`
  }
}

// ---- Pure helpers (kept at module scope for testability) ----

function defaultsFor(meta) {
  if (meta.operators.includes("is_true")) return { op: "is_true", value: null }
  if (meta.bucket === "collection") return { op: "contains_any", value: [] }
  if (meta.bucket === "date") return { op: "within_last", value: { n: 7, unit: "days" } }
  if (meta.bucket === "number") return { op: "equals", value: null }
  const op = meta.operators[0] || "is"
  // For single-value enum / preset / fk chips with a static values
  // list, pre-fill the first option so the chip face shows something
  // meaningful immediately and operator-only features (like the
  // preset Expand button) work without an extra Done round-trip.
  const firstValue = firstStaticValue(meta)
  if (firstValue !== null && (meta.bucket === "enum" || meta.bucket === "preset" || meta.bucket === "fk")) {
    return { op, value: firstValue }
  }
  return { op, value: null }
}

function firstStaticValue(meta) {
  const first = (meta.values || [])[0]
  if (first === undefined || first === null) return null
  return typeof first === "object" ? first.value : first
}

function isPredicateOp(op) {
  return [ "is_true", "is_false", "is_set", "is_unset", "is_empty", "is_not_empty" ].includes(op)
}

// Look up a preset chip's expansion from its meta. Returns an AST
// sub-tree ({"field":...}, {"and":[...]}, {"or":[...]}) or null if
// the preset value has no defined expansion.
function expansionForPresetChip(chip, meta) {
  if (!chip || !meta || meta.bucket !== "preset") return null
  if (!meta.expansions || typeof meta.expansions !== "object") return null
  const key = String(chip.value || "")
  return meta.expansions[key] || null
}

// Explicit map of operator → human-readable phrase. Keeping this
// as a static table (vs. a generic underscore→space substitution)
// lets us pick wording that reads as natural English: "is any of"
// beats "is one of", "doesn't contain" beats "does not contain".
const OP_LABELS = {
  is:                   "is",
  is_not:               "is not",
  is_one_of:            "is any of",
  is_none_of:           "is none of",
  is_set:               "is set",
  is_unset:             "is not set",
  is_true:              "is true",
  is_false:             "is false",
  is_empty:             "is empty",
  is_not_empty:         "is not empty",
  contains:             "contains",
  does_not_contain:     "doesn't contain",
  starts_with:          "starts with",
  does_not_start_with:  "doesn't start with",
  ends_with:            "ends with",
  does_not_end_with:    "doesn't end with",
  equals:               "equals",
  not_equals:           "doesn't equal",
  contains_any:         "contains any of",
  contains_all:         "contains all of",
  contains_none:        "contains none of",
  before:               "before",
  after:                "after",
  between:              "between",
  within_last:          "within last",
  more_than_ago:        "more than"
}

function humanizeOp(op) {
  return OP_LABELS[op] || op.replace(/_/g, " ")
}

function encodeTree(tree) {
  const json = JSON.stringify(tree || { and: [] })
  return btoa(unescape(encodeURIComponent(json)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

function separator(kind) {
  const span = document.createElement("span")
  span.className = kind === "or"
    ? "text-xs font-semibold uppercase tracking-wide text-indigo-600"
    : "text-xs font-semibold uppercase tracking-wide text-gray-400"
  span.textContent = kind
  return span
}

function labelSpan(text, { negated = false } = {}) {
  const span = document.createElement("span")
  span.className = "font-medium text-gray-700"
  if (negated) {
    const prefix = document.createElement("span")
    prefix.className = "mr-1 rounded bg-rose-200 px-1 py-0.5 text-[0.65rem] font-bold uppercase tracking-wider text-rose-800"
    prefix.textContent = "NOT"
    span.append(prefix, document.createTextNode(text))
  } else {
    span.textContent = text
  }
  return span
}

function notToggleButton(path, negated) {
  const btn = document.createElement("button")
  btn.type = "button"
  btn.className = negated
    ? "inline-flex h-5 w-5 items-center justify-center rounded bg-rose-200 text-rose-900 hover:bg-rose-300 cursor-pointer"
    : "inline-flex h-5 w-5 items-center justify-center rounded border border-gray-300 text-gray-400 hover:border-rose-300 hover:bg-rose-50 hover:text-rose-700 cursor-pointer"
  btn.textContent = "¬"
  btn.setAttribute("aria-label", negated ? "Remove NOT wrapper" : "Negate this filter group")
  btn.title = negated ? "Remove NOT (negation)" : "Wrap in NOT (negation)"
  btn.dataset.action = "click->chip-bar#toggleNegation"
  btn.dataset.chipPath = JSON.stringify(path)
  return btn
}

function opSpan(op) {
  const span = document.createElement("span")
  span.className = "text-xs text-gray-500"
  span.textContent = humanizeOp(op)
  return span
}

function valueSpan(chip, meta) {
  const span = document.createElement("span")
  span.className = "font-mono text-gray-900"
  span.textContent = formatChipValue(chip, meta)
  return span
}

function formatChipValue(chip, meta) {
  if (isPredicateOp(chip.op)) return ""
  if (chip.value === null || chip.value === undefined) return "(unset)"
  if (Array.isArray(chip.value)) return chip.value.map(v => labelForOption(v, meta)).join(", ")
  if (typeof chip.value === "object") return formatObjectValue(chip)
  return labelForOption(chip.value, meta)
}

function formatObjectValue(chip) {
  // within_last / more_than_ago carry { n, unit }
  if (chip.value && "n" in chip.value && "unit" in chip.value) {
    const n = chip.value.n
    const unit = chip.value.unit
    const singular = unit && unit.endsWith("s") && Number(n) === 1 ? unit.slice(0, -1) : unit
    const phrase = `${n} ${singular}`
    // more_than_ago reads naturally with an "ago" tail — "more
    // than 7 days ago" beats "more than 7 days".
    return chip.op === "more_than_ago" ? `${phrase} ago` : phrase
  }
  return JSON.stringify(chip.value)
}

function labelForOption(value, meta) {
  if (!meta || !Array.isArray(meta.values)) return String(value)
  const match = meta.values.find(v => String(typeof v === "object" ? v.value : v) === String(value))
  if (!match) return String(value)
  return typeof match === "object" ? match.label : match
}

function addMetaOption(meta, option) {
  if (!meta) return
  if (!Array.isArray(meta.values)) meta.values = []
  if (optionExists(meta, option.value)) return
  meta.values.push({ value: option.value, label: option.label })
}

function optionExists(meta, value) {
  if (!meta || !Array.isArray(meta.values)) return false
  return meta.values.some(v => String(typeof v === "object" ? v.value : v) === String(value))
}

function collectTypeaheadChipValues(nodes, metaFor) {
  const idsByField = new Map()

  const visit = node => {
    if (!node || typeof node !== "object") return
    if (node.not) return visit(node.not)
    if (Array.isArray(node.or)) return node.or.forEach(visit)
    if (!("field" in node)) return

    const meta = metaFor(node.field)
    if (!meta || !meta.typeahead || isPredicateOp(node.op)) return

    const values = Array.isArray(node.value) ? node.value : [ node.value ]
    values.filter(value => value !== null && value !== undefined && value !== "").forEach(value => {
      if (!idsByField.has(node.field)) idsByField.set(node.field, new Set())
      idsByField.get(node.field).add(String(value))
    })
  }

  nodes.forEach(visit)
  return idsByField
}

// ---- Per-bucket value editors ----

function enumEditor(chip, meta) {
  const multi = [ "is_one_of", "is_none_of", "contains_any", "contains_all", "contains_none" ].includes(chip.op)
  if (multi) return multiPillEditor(chip, meta)

  const wrapper = document.createElement("div")
  const select = document.createElement("select")
  select.className = "block w-full rounded-md border border-gray-300 px-2 py-1.5 text-sm"
  select.dataset.chipBarTarget = "editorInput"
  // Preset chips depend on the *current* value to decide whether the
  // Expand button shows in the editor footer. Trigger a re-render
  // when the operator picks a different preset.
  if (meta.bucket === "preset") {
    select.dataset.action = "change->chip-bar#updateChipValue"
  }

  meta.values.forEach(v => {
    const option = document.createElement("option")
    const val = typeof v === "object" ? v.value : v
    const label = typeof v === "object" ? v.label : v
    option.value = val
    option.textContent = label
    if (String(chip.value) === String(val)) option.selected = true
    select.append(option)
  })

  wrapper.append(select)
  return wrapper
}

// Multi-pill autocomplete: pills above a search input above a
// scrollable, filtered options list. Selected values live in the
// wrapper's dataset.selected JSON; readEditorValue picks them up
// from there.
function multiPillEditor(chip, meta) {
  const wrapper = document.createElement("div")
  wrapper.className = "rounded-md border border-gray-300 bg-white"
  wrapper.dataset.chipBarTarget = "editorInput"
  wrapper.dataset.role = "multi-pill"

  const initial = Array.isArray(chip.value) ? chip.value.map(String) : []
  wrapper.dataset.selected = JSON.stringify(initial)

  const pillsRow = document.createElement("div")
  pillsRow.className = "flex flex-wrap gap-1 p-2"
  pillsRow.dataset.role = "pills-row"

  const search = document.createElement("input")
  search.type = "text"
  search.placeholder = (meta.values && meta.values.length) ? "Search…" : "No options available"
  search.className = "block w-full border-0 border-t border-gray-200 px-2 py-1.5 text-sm focus:outline-none focus:ring-0"
  search.dataset.role = "search"
  search.autocomplete = "off"

  const list = document.createElement("div")
  list.className = "max-h-40 overflow-y-auto border-t border-gray-200 text-sm"
  list.dataset.role = "options-list"

  wrapper.append(pillsRow, search, list)

  const refresh = () => renderMultiPillState(wrapper, meta)
  refresh()

  search.addEventListener("input", refresh)
  search.addEventListener("keydown", event => {
    if (event.key !== "Enter") return
    event.preventDefault()
    const first = list.querySelector("button[data-role='option']")
    if (first) first.click()
  })

  // stopPropagation is intentional: refresh() replaces the clicked
  // pill / option button via replaceChildren, which detaches it from
  // the DOM. The chip-bar's document-click handler treats clicks
  // whose target is no longer inside `this.element` as "outside" and
  // calls closePopovers — so without this guard, picking an item
  // would dismiss the editor and lose the selection.
  pillsRow.addEventListener("click", event => {
    const target = event.target.closest("button[data-role='pill-remove']")
    if (!target) return
    event.stopPropagation()
    const value = target.dataset.value
    const selected = JSON.parse(wrapper.dataset.selected || "[]")
    wrapper.dataset.selected = JSON.stringify(selected.filter(v => String(v) !== String(value)))
    refresh()
  })

  list.addEventListener("click", event => {
    const target = event.target.closest("button[data-role='option']")
    if (!target) return
    event.stopPropagation()
    const value = target.dataset.value
    const selected = JSON.parse(wrapper.dataset.selected || "[]")
    if (!selected.some(v => String(v) === String(value))) {
      selected.push(value)
      wrapper.dataset.selected = JSON.stringify(selected)
    }
    search.value = ""
    refresh()
    search.focus()
  })

  return wrapper
}

function renderMultiPillState(wrapper, meta) {
  const selected = JSON.parse(wrapper.dataset.selected || "[]").map(String)
  const pillsRow = wrapper.querySelector("[data-role='pills-row']")
  const search = wrapper.querySelector("[data-role='search']")
  const list = wrapper.querySelector("[data-role='options-list']")

  // Pills
  pillsRow.replaceChildren(...selected.map(value => {
    const pill = document.createElement("span")
    pill.className = "inline-flex items-center gap-1 rounded bg-indigo-100 px-2 py-0.5 text-xs text-indigo-800"
    const text = document.createElement("span")
    text.textContent = labelForOption(value, meta)
    const remove = document.createElement("button")
    remove.type = "button"
    remove.dataset.role = "pill-remove"
    remove.dataset.value = value
    remove.className = "text-indigo-500 hover:text-indigo-900 cursor-pointer"
    remove.textContent = "×"
    pill.append(text, remove)
    return pill
  }))

  if (selected.length === 0) {
    const placeholder = document.createElement("span")
    placeholder.className = "text-xs text-gray-400"
    placeholder.textContent = "Nothing selected yet"
    pillsRow.append(placeholder)
  }

  // Filtered options
  const query = (search.value || "").trim().toLowerCase()
  const selectedSet = new Set(selected)
  const options = (Array.isArray(meta.values) ? meta.values : []).map(v => {
    return typeof v === "object" ? { value: String(v.value), label: v.label }
                                  : { value: String(v),       label: String(v) }
  })
  const matches = options
    .filter(opt => !selectedSet.has(opt.value))
    .filter(opt => !query || opt.label.toLowerCase().includes(query) || opt.value.toLowerCase().includes(query))
    .slice(0, 50)

  list.replaceChildren(...matches.map(opt => {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.dataset.role = "option"
    btn.dataset.value = opt.value
    btn.className = "flex w-full items-center justify-between gap-2 px-3 py-1.5 text-left hover:bg-gray-50 cursor-pointer"
    btn.textContent = opt.label
    return btn
  }))

  if (matches.length === 0) {
    const empty = document.createElement("div")
    empty.className = "px-3 py-1.5 text-xs text-gray-400"
    empty.textContent = options.length === 0 ? "No options available" : "No matches"
    list.append(empty)
  }
}

function stringEditor(chip) {
  const input = document.createElement("input")
  input.type = "text"
  input.value = chip.value ?? ""
  input.placeholder = "value"
  input.className = "block w-full rounded-md border border-gray-300 px-2 py-1.5 text-sm"
  input.dataset.chipBarTarget = "editorInput"
  return input
}

function numberEditor(chip) {
  if (chip.op === "between") {
    const wrapper = document.createElement("div")
    wrapper.className = "flex items-center gap-2"
    const range = Array.isArray(chip.value) ? chip.value : []
    wrapper.append(numberInput(range[0], "min"), numberInput(range[1], "max"))
    return wrapper
  }
  return numberInput(chip.value, "value")
}

function numberInput(value, placeholder) {
  const input = document.createElement("input")
  input.type = "number"
  input.value = value ?? ""
  input.placeholder = placeholder
  input.className = "block w-full rounded-md border border-gray-300 px-2 py-1.5 text-sm"
  input.dataset.chipBarTarget = "editorInput"
  return input
}

function dateEditor(chip) {
  if (chip.op === "within_last" || chip.op === "more_than_ago") {
    const wrapper = document.createElement("div")
    wrapper.className = "flex items-center gap-2"
    const spec = chip.value && typeof chip.value === "object" ? chip.value : {}
    const nInput = document.createElement("input")
    nInput.type = "number"
    nInput.min = "0"
    nInput.value = spec.n ?? 7
    nInput.className = "block w-20 rounded-md border border-gray-300 px-2 py-1.5 text-sm"
    nInput.dataset.chipBarTarget = "editorInput"
    nInput.dataset.role = "n"

    const unitSelect = document.createElement("select")
    unitSelect.className = "block w-full rounded-md border border-gray-300 px-2 py-1.5 text-sm"
    unitSelect.dataset.chipBarTarget = "editorInput"
    unitSelect.dataset.role = "unit";
    [ "minutes", "hours", "days", "weeks", "months" ].forEach(unit => {
      const option = document.createElement("option")
      option.value = unit
      option.textContent = unit
      if ((spec.unit || "days") === unit) option.selected = true
      unitSelect.append(option)
    })
    wrapper.append(nInput, unitSelect)
    return wrapper
  }

  if (chip.op === "between") {
    const wrapper = document.createElement("div")
    wrapper.className = "flex flex-col gap-2"
    const range = Array.isArray(chip.value) ? chip.value : []
    wrapper.append(
      labeledDateInput("from", range[0]),
      labeledDateInput("to", range[1])
    )
    return wrapper
  }

  return dateInput(chip.value)
}

function labeledDateInput(label, value) {
  const row = document.createElement("label")
  row.className = "flex items-center gap-2 text-xs text-gray-500"
  const text = document.createElement("span")
  text.className = "w-10 shrink-0"
  text.textContent = label
  row.append(text, dateInput(value))
  return row
}

function dateInput(value) {
  const input = document.createElement("input")
  input.type = "date"
  input.value = value ? String(value).slice(0, 10) : ""
  input.className = "block w-full min-w-0 rounded-md border border-gray-300 px-2 py-1.5 text-sm"
  input.dataset.chipBarTarget = "editorInput"
  return input
}

function collectionEditor(chip, meta) {
  if (meta.typeahead) return null
  // Always use the multi-pill picker — the schema embeds the user's
  // tag list via dynamic_values, so this works for tags and any
  // future collection chip with a known value set.
  return multiPillEditor(chip, meta)
}

function typeaheadEditor(chip, meta, controller) {
  const multi = [ "is_one_of", "is_none_of", "contains_any", "contains_all", "contains_none" ].includes(chip.op)
  const wrapper = document.createElement("div")
  wrapper.className = "rounded-md border border-gray-300 bg-white"
  wrapper.dataset.chipBarTarget = "editorInput"
  wrapper.dataset.role = "typeahead"
  wrapper.dataset.field = meta.field
  wrapper.dataset.multi = multi ? "true" : "false"
  wrapper.dataset.selected = JSON.stringify(normalizedSelectedValues(chip.value, multi))
  wrapper.dataset.activeIndex = "0"

  const selectedRow = document.createElement("div")
  selectedRow.className = "flex flex-wrap gap-1 p-2"
  selectedRow.dataset.role = "typeahead-selected"

  const input = document.createElement("input")
  input.type = "search"
  input.placeholder = "Search..."
  input.autocomplete = "off"
  input.className = "block w-full border-0 border-t border-gray-200 px-2 py-1.5 text-sm focus:outline-none focus:ring-0"
  input.dataset.role = "typeahead-search"
  input.dataset.action = "input->chip-bar#typeaheadSearchInput keydown->chip-bar#typeaheadKeydown"

  const list = document.createElement("div")
  list.className = "max-h-40 overflow-y-auto border-t border-gray-200 text-sm"
  list.dataset.role = "typeahead-options"

  wrapper.append(selectedRow, input, list)
  renderTypeaheadState(wrapper, meta)
  controller.fetchTypeaheadSearch(wrapper)

  return wrapper
}

function normalizedSelectedValues(value, multi) {
  if (multi) return Array.isArray(value) ? value.map(String) : []
  if (value === null || value === undefined || value === "") return []
  return [ String(value) ]
}

function renderTypeaheadState(wrapper, meta) {
  const selected = JSON.parse(wrapper.dataset.selected || "[]").map(String)
  const selectedRow = wrapper.querySelector("[data-role='typeahead-selected']")

  selectedRow.replaceChildren(...selected.map(value => {
    const pill = document.createElement("span")
    pill.className = "inline-flex items-center gap-1 rounded bg-indigo-100 px-2 py-0.5 text-xs text-indigo-800"
    const text = document.createElement("span")
    text.textContent = labelForOption(value, meta)
    const remove = document.createElement("button")
    remove.type = "button"
    remove.dataset.role = "typeahead-remove"
    remove.dataset.value = value
    remove.dataset.action = "click->chip-bar#removeTypeaheadSelection"
    remove.className = "text-indigo-500 hover:text-indigo-900 cursor-pointer"
    remove.textContent = "×"
    pill.append(text, remove)
    return pill
  }))

  if (selected.length === 0) {
    const placeholder = document.createElement("span")
    placeholder.className = "text-xs text-gray-400"
    placeholder.textContent = "Nothing selected yet"
    selectedRow.append(placeholder)
  }
}

function renderTypeaheadOptions(wrapper, options) {
  const selected = new Set(JSON.parse(wrapper.dataset.selected || "[]").map(String))
  const list = wrapper.querySelector("[data-role='typeahead-options']")
  const visible = options.filter(option => !selected.has(String(option.value)))

  list.replaceChildren(...visible.map((option, index) => {
    const button = document.createElement("button")
    button.type = "button"
    button.dataset.role = "typeahead-option"
    button.dataset.value = option.value
    button.dataset.action = "click->chip-bar#selectTypeaheadOption"
    button.className = typeaheadOptionClass(index === 0)
    button.textContent = option.label
    return button
  }))

  wrapper.dataset.activeIndex = "0"
  if (visible.length === 0) {
    const empty = document.createElement("div")
    empty.className = "px-3 py-1.5 text-xs text-gray-400"
    empty.textContent = "No matches"
    list.append(empty)
  }
}

function renderTypeaheadError(wrapper) {
  const list = wrapper.querySelector("[data-role='typeahead-options']")
  const error = document.createElement("div")
  error.className = "px-3 py-1.5 text-xs text-rose-500"
  error.textContent = "Options unavailable"
  list.replaceChildren(error)
}

function setTypeaheadActiveOption(wrapper, index) {
  const options = Array.from(wrapper.querySelectorAll("button[data-role='typeahead-option']"))
  wrapper.dataset.activeIndex = String(index)
  options.forEach((option, i) => {
    option.className = typeaheadOptionClass(i === index)
  })
}

function typeaheadOptionClass(active) {
  return active
    ? "flex w-full items-center justify-between gap-2 bg-blue-50 px-3 py-1.5 text-left cursor-pointer"
    : "flex w-full items-center justify-between gap-2 px-3 py-1.5 text-left hover:bg-gray-50 cursor-pointer"
}

function readEditorValue(editor, op) {
  if (isPredicateOp(op)) return null

  const inputs = editor.querySelectorAll('[data-chip-bar-target="editorInput"]')
  if (inputs.length === 0) return null

  const nInput = editor.querySelector('[data-role="n"]')
  const unitSelect = editor.querySelector('[data-role="unit"]')
  if (nInput && unitSelect) {
    return { n: Number(nInput.value || 0), unit: unitSelect.value }
  }

  const multiPill = editor.querySelector('[data-role="multi-pill"]')
  if (multiPill) {
    return JSON.parse(multiPill.dataset.selected || "[]")
  }

  const typeahead = editor.querySelector('[data-role="typeahead"]')
  if (typeahead) {
    const selected = JSON.parse(typeahead.dataset.selected || "[]")
    return typeahead.dataset.multi === "true" ? selected : (selected[0] || null)
  }

  if (inputs.length === 1) {
    const input = inputs[0]
    if (input.tagName === "SELECT" && input.multiple) {
      return Array.from(input.selectedOptions).map(o => o.value)
    }
    if (input.type === "number") {
      const num = Number(input.value)
      return Number.isFinite(num) && input.value !== "" ? num : null
    }
    return input.value === "" ? null : input.value
  }

  return Array.from(inputs).map(input => {
    if (input.type === "number") {
      const num = Number(input.value)
      return Number.isFinite(num) && input.value !== "" ? num : null
    }
    return input.value
  })
}
