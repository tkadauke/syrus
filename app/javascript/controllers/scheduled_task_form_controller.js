import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["kindSelect", "cronSection", "oneShotSection"]

  connect() {
    this.updateVisibility()
  }

  kindChanged() {
    this.updateVisibility()
  }

  updateVisibility() {
    const isCron = this.kindSelectTarget.value === "cron"
    this.cronSectionTarget.classList.toggle("hidden", !isCron)
    this.oneShotSectionTarget.classList.toggle("hidden", isCron)
  }
}
