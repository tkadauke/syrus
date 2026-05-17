import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    document.addEventListener("turbo:before-morph-element", this.preserveCheckboxState)
  }

  disconnect() {
    document.removeEventListener("turbo:before-morph-element", this.preserveCheckboxState)
  }

  preserveCheckboxState = (event) => {
    const current = event.target
    const replacement = event.detail?.newElement

    if (!this.shouldPreserve(current, replacement)) return

    replacement.checked = current.checked
    replacement.indeterminate = current.indeterminate

    if (current.checked) {
      replacement.setAttribute("checked", "checked")
    } else {
      replacement.removeAttribute("checked")
    }
  }

  shouldPreserve(current, replacement) {
    if (!this.isCheckbox(current) || !this.isCheckbox(replacement)) return false
    if (this.optedOut(current) || this.optedOut(replacement)) return false

    if (current.id && replacement.id) {
      return current.id === replacement.id
    }

    return current.name === replacement.name &&
      current.value === replacement.value &&
      current.getAttribute("form") === replacement.getAttribute("form")
  }

  isCheckbox(element) {
    return element instanceof HTMLInputElement && element.type === "checkbox"
  }

  optedOut(element) {
    return element.dataset.checkboxPersistence === "false"
  }
}
