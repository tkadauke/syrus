import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["overlay", "panel", "frame", "expandLabel"]

  connect() {
    this.boundKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeydown)
  }

  open() {
    this.overlayTarget.classList.remove("hidden")
    this.panelTarget.classList.remove("translate-x-full")
  }

  close() {
    this.panelTarget.classList.add("translate-x-full")
    this.overlayTarget.classList.add("hidden")
  }

  toggleExpanded() {
    this.panelTarget.classList.toggle("max-w-3xl")
    this.panelTarget.classList.toggle("max-w-none")
    this.panelTarget.classList.toggle("w-full")
    this.expandLabelTarget.textContent = this.panelTarget.classList.contains("max-w-none") ? "Restore width" : "Expand full-width"
  }

  handleKeydown(event) {
    if (event.key === "Escape") this.close()
  }
}
