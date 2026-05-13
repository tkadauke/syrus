import { Controller } from "@hotwired/stimulus"

const DESKTOP_QUERY = "(min-width: 640px)"
const DEFAULT_CANVAS_RATIO = 0.6
const MIN_CANVAS_RATIO = 0.3
const MAX_CANVAS_RATIO = 0.75

export default class extends Controller {
  static targets = [
    "canvasPane",
    "chatPane",
    "desktopCanvasSlot",
    "desktopChatSlot",
    "mobileSlot",
    "grid",
    "divider",
    "chatTab",
    "canvasTab"
  ]
  static values = {
    activeTab: { type: String, default: "chat" },
    storageKey: String
  }

  connect() {
    this.mediaQuery = window.matchMedia(DESKTOP_QUERY)
    this.canvasRatio = this.storedRatio()
    this.canvasPane = this.canvasPaneTarget
    this.chatPane = this.chatPaneTarget
    this.detachedSlot = document.createDocumentFragment()
    this.mediaQuery.addEventListener("change", this.render)
    this.render()
  }

  disconnect() {
    this.mediaQuery?.removeEventListener("change", this.render)
    this.stopDrag()
  }

  render = () => {
    if (this.isDesktop()) {
      this.desktopCanvasSlotTarget.appendChild(this.canvasPane)
      this.desktopChatSlotTarget.appendChild(this.chatPane)
      this.applyRatio()
    } else if (this.activeTabValue === "canvas") {
      this.mobileSlotTarget.appendChild(this.canvasPane)
      this.desktopChatSlotTarget.appendChild(this.chatPane)
    } else {
      this.mobileSlotTarget.appendChild(this.chatPane)
      this.detachedSlot.appendChild(this.canvasPane)
    }

    this.updateTabs()
    this.queueCanvasResize()
  }

  showChat() {
    this.activeTabValue = "chat"
    this.render()
  }

  showCanvas() {
    this.activeTabValue = "canvas"
    this.render()
  }

  swipeStart(event) {
    if (this.isDesktop()) return

    this.touchStartX = event.touches?.[0]?.clientX
  }

  swipeEnd(event) {
    if (this.isDesktop() || this.touchStartX === undefined) return

    const endX = event.changedTouches?.[0]?.clientX
    if (endX === undefined) return

    const distance = endX - this.touchStartX
    this.touchStartX = undefined
    if (Math.abs(distance) < 48) return

    if (distance < 0) {
      this.showCanvas()
    } else {
      this.showChat()
    }
  }

  startDrag(event) {
    if (!this.isDesktop() || event.pointerType === "touch") return

    event.preventDefault()
    this.dragging = true
    this.dividerTarget.setPointerCapture(event.pointerId)
    this.dividerTarget.classList.add("bg-blue-100")
    window.addEventListener("pointermove", this.drag)
    window.addEventListener("pointerup", this.endDrag)
  }

  drag = (event) => {
    if (!this.dragging) return

    const rect = this.gridTarget.getBoundingClientRect()
    const ratio = (event.clientX - rect.left) / rect.width
    this.canvasRatio = this.clampRatio(ratio)
    this.applyRatio()
    this.persistRatio()
    this.queueCanvasResize()
  }

  endDrag = () => {
    this.stopDrag()
  }

  stopDrag() {
    if (!this.dragging) return

    this.dragging = false
    this.dividerTarget.classList.remove("bg-blue-100")
    window.removeEventListener("pointermove", this.drag)
    window.removeEventListener("pointerup", this.endDrag)
  }

  applyRatio() {
    if (!this.hasGridTarget) return

    const canvasPercent = this.formatPercent(this.canvasRatio)
    const chatPercent = this.formatPercent(1 - this.canvasRatio)
    this.gridTarget.style.gridTemplateColumns = `minmax(0, ${canvasPercent}) 0.75rem minmax(20rem, ${chatPercent})`
  }

  storedRatio() {
    if (!this.hasStorageKeyValue) return DEFAULT_CANVAS_RATIO

    const value = window.localStorage.getItem(this.storageKeyValue)
    const ratio = Number.parseFloat(value)
    return Number.isFinite(ratio) ? this.clampRatio(ratio) : DEFAULT_CANVAS_RATIO
  }

  persistRatio() {
    if (!this.hasStorageKeyValue) return

    window.localStorage.setItem(this.storageKeyValue, this.canvasRatio.toFixed(3))
  }

  clampRatio(value) {
    return Math.min(MAX_CANVAS_RATIO, Math.max(MIN_CANVAS_RATIO, value))
  }

  formatPercent(value) {
    return `${Number((value * 100).toFixed(3))}%`
  }

  isDesktop() {
    return this.mediaQuery.matches
  }

  updateTabs() {
    if (!this.hasChatTabTarget || !this.hasCanvasTabTarget) return

    this.updateTab(this.chatTabTarget, this.activeTabValue === "chat")
    this.updateTab(this.canvasTabTarget, this.activeTabValue === "canvas")
  }

  updateTab(tab, active) {
    tab.setAttribute("aria-selected", active ? "true" : "false")
    tab.classList.toggle("border-blue-600", active)
    tab.classList.toggle("text-blue-600", active)
    tab.classList.toggle("border-transparent", !active)
    tab.classList.toggle("text-gray-600", !active)
  }

  queueCanvasResize() {
    window.requestAnimationFrame(() => {
      window.dispatchEvent(new Event("resize"))
    })
  }
}
