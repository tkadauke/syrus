import { Controller } from "@hotwired/stimulus"

const DEFAULT_TAB = "whiteboard"
const DOCUMENTATION_TAB = "documentation"

export default class extends Controller {
  static targets = [
    "whiteboardTab",
    "documentationTab",
    "whiteboardPanel",
    "documentationPanel",
    "documentationFrame"
  ]
  static values = {
    documentationUrl: String,
    repositoryId: Number
  }

  connect() {
    this.activeTab = this.storedTab()
    this.render()
  }

  showWhiteboard() {
    this.selectTab(DEFAULT_TAB)
  }

  showDocumentation() {
    this.selectTab(DOCUMENTATION_TAB)
  }

  selectTab(tab) {
    this.activeTab = tab
    this.persistTab()
    this.render()
  }

  render() {
    const documentationActive = this.activeTab === DOCUMENTATION_TAB

    this.whiteboardPanelTarget.classList.toggle("hidden", documentationActive)
    this.documentationPanelTarget.classList.toggle("hidden", !documentationActive)
    this.updateTab(this.whiteboardTabTargets, !documentationActive)
    this.updateTab(this.documentationTabTargets, documentationActive)

    if (documentationActive) {
      this.loadDocumentation()
    } else {
      this.queueResize()
    }
  }

  updateTab(tabs, active) {
    tabs.forEach((tab) => {
      tab.setAttribute("aria-selected", active ? "true" : "false")
      tab.classList.toggle("border-blue-600", active)
      tab.classList.toggle("text-blue-600", active)
      tab.classList.toggle("border-transparent", !active)
      tab.classList.toggle("text-gray-600", !active)
    })
  }

  loadDocumentation() {
    if (!this.hasDocumentationFrameTarget || !this.hasDocumentationUrlValue) return
    if (this.documentationFrameTarget.getAttribute("src")) return

    this.documentationFrameTarget.setAttribute("src", this.documentationUrlValue)
  }

  storedTab() {
    const value = window.localStorage.getItem(this.storageKey())
    return value === DOCUMENTATION_TAB ? DOCUMENTATION_TAB : DEFAULT_TAB
  }

  persistTab() {
    window.localStorage.setItem(this.storageKey(), this.activeTab)
  }

  storageKey() {
    return `syrus.repository.${this.repositoryIdValue}.chat_side_panel_tab`
  }

  queueResize() {
    window.requestAnimationFrame(() => {
      window.dispatchEvent(new Event("resize"))
    })
  }
}
