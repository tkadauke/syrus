import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["actions", "checkbox", "count", "submit"]

  connect() {
    this.sync()
  }

  sync() {
    const selectedCount = this.checkboxTargets.filter((checkbox) => checkbox.checked).length

    if (this.hasActionsTarget) {
      this.actionsTarget.classList.toggle("hidden", selectedCount === 0)
    }
    if (this.hasCountTarget) {
      this.countTarget.textContent = selectedCount
    }
    if (this.hasSubmitTarget) {
      this.submitTarget.value = `File selected (${selectedCount})`
      this.submitTarget.disabled = selectedCount === 0
    }
  }
}
