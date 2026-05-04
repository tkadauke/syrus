import { Controller } from "@hotwired/stimulus"

// Fills the title and prompt fields when the user picks a template card.
export default class extends Controller {
  static targets = ["title", "prompt"]
  static values  = { templates: Array }

  apply(event) {
    const id       = event.currentTarget.dataset.templateId
    const template = this.templatesValue.find(t => t.id === id)
    if (!template) return

    this.promptTarget.value = template.prompt
    if (this.titleTarget.value.trim() === "") {
      this.titleTarget.value = template.name
    }
    this.promptTarget.focus()
  }
}
