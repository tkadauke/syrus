import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { activeIndex: Number }

  connect() {
    this.selectedIndex = this.activeIndexValue || 0
    this.apply()
    document.addEventListener("turbo:morph", this.reapply)
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.reapply)
  }

  select(event) {
    this.selectedIndex = Number(event.currentTarget.dataset.iterationTabsIndexValue)
    this.apply()
  }

  apply() {
    this.tabTargets.forEach((tab, index) => {
      const active = index === this.selectedIndex
      tab.classList.toggle("ring-2", active)
      tab.classList.toggle("ring-blue-500", active)
      tab.classList.toggle("ring-offset-1", active)
      tab.setAttribute("aria-selected", active ? "true" : "false")
    })

    this.panelTargets.forEach((panel, index) => {
      panel.classList.toggle("hidden", index !== this.selectedIndex)
    })
  }

  reapply = () => {
    if (this.element.isConnected) this.apply()
  }
}
