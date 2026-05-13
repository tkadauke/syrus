import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "filename"]

  choose() {
    this.inputTarget.click()
  }

  dragOver(event) {
    event.preventDefault()
    this.element.classList.add("border-blue-400", "bg-blue-50")
  }

  dragLeave() {
    this.element.classList.remove("border-blue-400", "bg-blue-50")
  }

  drop(event) {
    event.preventDefault()
    this.dragLeave()

    if (event.dataTransfer.files.length > 0) {
      this.inputTarget.files = event.dataTransfer.files
      this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }
  }

  updateName() {
    const file = this.inputTarget.files[0]
    this.filenameTarget.textContent = file ? file.name : "No file selected"
  }
}
