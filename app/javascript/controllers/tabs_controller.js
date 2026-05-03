import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    this.activeIndex = 0
    this.apply()
    document.addEventListener("turbo:morph", this.reapply)
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.reapply)
  }

  switch(event) {
    this.activeIndex = this.tabTargets.indexOf(event.currentTarget)
    this.apply()
  }

  apply() {
    this.tabTargets.forEach((tab, i) => {
      const active = i === this.activeIndex
      tab.classList.toggle("text-blue-600", active)
      tab.classList.toggle("border-b-2", active)
      tab.classList.toggle("border-blue-600", active)
      tab.classList.toggle("text-gray-500", !active)
    })
    this.panelTargets.forEach((panel, i) => {
      panel.classList.toggle("hidden", i !== this.activeIndex)
    })
  }

  // Arrow function so `this` is bound when used as an event listener.
  reapply = () => {
    if (this.element.isConnected) this.apply()
  }
}
