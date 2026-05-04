import { Controller } from "@hotwired/stimulus"

// Opens/closes the native <dialog> for the "Retry with context" form.
export default class extends Controller {
  static targets = ["dialog"]

  open(event) {
    event.preventDefault()
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }
}
