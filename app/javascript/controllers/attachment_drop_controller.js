import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "dropzone"]

  browse() {
    this.inputTarget.click()
  }

  upload() {
    if (this.inputTarget.files.length > 0) this.inputTarget.form.requestSubmit()
  }

  dragover(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.add("border-blue-400", "bg-blue-50")
  }

  dragleave() {
    this.dropzoneTarget.classList.remove("border-blue-400", "bg-blue-50")
  }

  drop(event) {
    event.preventDefault()
    this.dragleave()
    if (event.dataTransfer.files.length === 0) return

    this.inputTarget.files = event.dataTransfer.files
    this.inputTarget.form.requestSubmit()
  }
}
