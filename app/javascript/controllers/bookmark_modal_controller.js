import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "label"]

  open() {
    if (!this.hasDialogTarget) return

    this.dialogTarget.showModal()
    if (this.hasLabelTarget) this.labelTarget.focus()
  }

  close() {
    if (!this.hasDialogTarget) return

    this.dialogTarget.close()
  }
}
