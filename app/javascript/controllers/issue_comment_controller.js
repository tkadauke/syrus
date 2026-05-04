import { Controller } from "@hotwired/stimulus"

// Manages the single shared comment dialog on the issues browser.
// Each "Comment" button passes the issue number and title via Stimulus
// value params; this controller wires them into the hidden field and
// dialog heading before opening the native <dialog>.
export default class extends Controller {
  static targets = ["dialog", "issueNumber", "issueLabel", "body"]

  open(event) {
    event.preventDefault()
    this.issueNumberTarget.value = event.params.issue
    this.issueLabelTarget.textContent = `#${event.params.issue} — ${event.params.title}`
    this.bodyTarget.value = ""
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }
}
