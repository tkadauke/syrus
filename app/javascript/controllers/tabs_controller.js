import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    this.activeIndex = this.tabIndexFromURL()
    this.apply()
    document.addEventListener("turbo:morph", this.reapply)
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.reapply)
  }

  switch(event) {
    this.activeIndex = this.tabTargets.indexOf(event.currentTarget)
    this.updateURL()
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

  tabIndexFromURL() {
    const params = new URLSearchParams(window.location.search)
    const tabId = params.get("tab")
    if (!tabId) return 0
    const idx = this.tabTargets.findIndex(t => t.dataset.tabId === tabId)
    return idx >= 0 ? idx : 0
  }

  updateURL() {
    const tab = this.tabTargets[this.activeIndex]
    if (!tab?.dataset.tabId) return
    const url = new URL(window.location)
    url.searchParams.set("tab", tab.dataset.tabId)
    history.pushState({}, "", url)
  }
}
