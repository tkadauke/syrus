import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["actions", "checkbox", "selectAll", "count"]

  connect() {
    this.sync()
  }

  toggleAll(event) {
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = event.target.checked
    })
    this.sync()
  }

  sync() {
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
}
