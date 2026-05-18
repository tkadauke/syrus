import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["actions", "checkbox", "selectAll", "count"]
  static values = { storageKey: String }

  connect() {
    this.restoreSelection()
    this.sync()
    document.addEventListener("turbo:render", this.restoreAndSync)
    document.addEventListener("turbo:frame-render", this.restoreAndSync)
    document.addEventListener("turbo:morph", this.restoreAndSync)
  }

  disconnect() {
    document.removeEventListener("turbo:render", this.restoreAndSync)
    document.removeEventListener("turbo:frame-render", this.restoreAndSync)
    document.removeEventListener("turbo:morph", this.restoreAndSync)
  }

  toggleAll(event) {
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = event.target.checked
    })
    this.sync()
  }

  sync = () => {
    this.persistSelection()
    const selectedCount = this.checkboxTargets.filter((checkbox) => checkbox.checked).length
    this.actionsTarget.classList.toggle("hidden", selectedCount === 0)
    this.countTargets.forEach((target) => {
      target.textContent = selectedCount.toString()
    })

    if (this.hasSelectAllTarget) {
      this.selectAllTarget.checked = selectedCount > 0 && selectedCount === this.checkboxTargets.length
      this.selectAllTarget.indeterminate = selectedCount > 0 && selectedCount < this.checkboxTargets.length
    }
  }

  restoreAndSync = () => {
    this.restoreSelection()
    this.sync()
  }

  persistSelection() {
    const storage = this.sessionStorage()
    if (!storage) return

    const selected = this.checkboxTargets
      .filter((checkbox) => checkbox.checked)
      .map((checkbox) => checkbox.value || checkbox.id)
      .filter(Boolean)

    storage.setItem(this.selectionStorageKey(), JSON.stringify(selected))
  }

  restoreSelection() {
    const storage = this.sessionStorage()
    if (!storage) return

    const raw = storage.getItem(this.selectionStorageKey())
    if (raw === null) return

    let selected
    try {
      selected = JSON.parse(raw)
    } catch (_error) {
      selected = []
    }

    const selectedSet = new Set(selected.map((value) => value.toString()))
    this.checkboxTargets.forEach((checkbox) => {
      const key = checkbox.value || checkbox.id
      checkbox.checked = key ? selectedSet.has(key.toString()) : checkbox.checked
    })
  }

  selectionStorageKey() {
    if (this.hasStorageKeyValue && this.storageKeyValue) return this.storageKeyValue

    const location = globalThis.location
    return `bulk-jobs:${location?.pathname || ""}${location?.search || ""}`
  }

  sessionStorage() {
    try {
      return globalThis.sessionStorage || null
    } catch (_error) {
      return null
    }
  }
}
