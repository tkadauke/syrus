import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    document.addEventListener("turbo:before-morph-element", this.preserveDetailsState)
  }

  disconnect() {
    document.removeEventListener("turbo:before-morph-element", this.preserveDetailsState)
  }

  preserveDetailsState = (event) => {
    const current = event.target
    const replacement = event.detail?.newElement

    if (!this.shouldPreserve(current, replacement)) return

    replacement.open = current.open

    if (current.open) {
      replacement.setAttribute("open", "")
    } else {
      replacement.removeAttribute("open")
    }
  }

  shouldPreserve(current, replacement) {
    if (!this.isDetails(current) || !this.isDetails(replacement)) return false
    if (this.optedOut(current) || this.optedOut(replacement)) return false

    const currentKey = current.dataset.detailsPersistenceKey
    const replacementKey = replacement.dataset.detailsPersistenceKey
    return Boolean(currentKey) && currentKey === replacementKey
  }

  isDetails(element) {
    return element instanceof HTMLDetailsElement
  }

  optedOut(element) {
    return element.dataset.detailsPersistence === "false"
  }
}
