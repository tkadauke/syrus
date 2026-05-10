import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.boundInvalid = this.invalid.bind(this)
    this.boundSubmit = this.submit.bind(this)
    this.boundInput = this.input.bind(this)

    this.element.addEventListener("invalid", this.boundInvalid, true)
    this.element.addEventListener("submit", this.boundSubmit, true)
    this.element.addEventListener("input", this.boundInput, true)
    this.element.addEventListener("change", this.boundInput, true)
  }

  disconnect() {
    this.element.removeEventListener("invalid", this.boundInvalid, true)
    this.element.removeEventListener("submit", this.boundSubmit, true)
    this.element.removeEventListener("input", this.boundInput, true)
    this.element.removeEventListener("change", this.boundInput, true)
  }

  submit(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement) || form.noValidate || event.submitter?.formNoValidate) return
    if (form.checkValidity()) return

    event.preventDefault()
    event.stopPropagation()

    this.showFormErrors(form)
    this.focusFirstInvalidField(form)
  }

  invalid(event) {
    const field = event.target
    if (!this.validatableField(field)) return

    this.showFieldError(field)
    const form = field.form
    if (form) queueMicrotask(() => this.showSummary(form))
  }

  input(event) {
    const field = event.target
    if (!this.validatableField(field)) return

    if (field.validity.valid) {
      this.clearFieldError(field)
      if (field.form) this.showSummary(field.form)
    } else if (field.getAttribute("aria-invalid") === "true") {
      this.showFieldError(field)
      if (field.form) this.showSummary(field.form)
    }
  }

  showFormErrors(form) {
    this.invalidFields(form).forEach((field) => this.showFieldError(field))
    this.showSummary(form)
  }

  showSummary(form) {
    const fields = this.invalidFields(form)
    const existing = form.querySelector(":scope > [data-form-validation-summary]")

    if (fields.length === 0) {
      existing?.remove()
      return
    }

    const summary = existing || document.createElement("div")
    summary.dataset.formValidationSummary = "true"
    summary.className = "rounded-md bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-800"
    summary.setAttribute("role", "alert")
    summary.textContent = fields.length === 1 ? "Fix the highlighted field before continuing." : "Fix the highlighted fields before continuing."

    if (!existing) form.prepend(summary)
  }

  showFieldError(field) {
    const message = this.validationMessage(field)
    const error = this.errorElement(field)

    field.setAttribute("aria-invalid", "true")
    this.setDescribedBy(field, this.describedBy(field, error.id))
    field.classList.add("border-red-500")

    error.textContent = message
    error.className = "mt-1 text-sm text-red-600"
    error.hidden = false
  }

  clearFieldError(field) {
    const error = this.existingErrorElement(field)
    if (!error) return

    error.remove()
    field.removeAttribute("aria-invalid")
    this.setDescribedBy(field, this.describedBy(field, null))
    field.classList.remove("border-red-500")
  }

  errorElement(field) {
    const existing = this.existingErrorElement(field)
    if (existing) return existing

    const error = document.createElement("p")
    error.id = this.errorId(field)
    error.dataset.formValidationErrorFor = this.fieldKey(field)
    field.insertAdjacentElement("afterend", error)
    return error
  }

  existingErrorElement(field) {
    return Array.from(field.parentElement?.querySelectorAll("[data-form-validation-error-for]") || [])
      .find((element) => element.dataset.formValidationErrorFor === this.fieldKey(field))
  }

  invalidFields(form) {
    return Array.from(form.elements).filter((field) => this.validatableField(field) && !field.validity.valid)
  }

  validatableField(field) {
    const isField = field instanceof HTMLInputElement ||
      field instanceof HTMLSelectElement ||
      field instanceof HTMLTextAreaElement
    return isField && field.willValidate
  }

  validationMessage(field) {
    if (field.validity.valueMissing) return `${this.fieldLabel(field)} is required.`
    return field.validationMessage || `${this.fieldLabel(field)} is invalid.`
  }

  fieldLabel(field) {
    if (field.labels?.length > 0) return field.labels[0].textContent.trim().replace(/\s+/g, " ")
    if (field.getAttribute("aria-label")) return field.getAttribute("aria-label")
    return field.name.replace(/\[[^\]]*\]/g, " ").replace(/_/g, " ").trim() || "This field"
  }

  focusFirstInvalidField(form) {
    const field = this.invalidFields(form)[0]
    if (!field) return

    field.focus()
    field.scrollIntoView({ block: "center", behavior: "smooth" })
  }

  fieldKey(field) {
    return field.id || field.name || "field"
  }

  errorId(field) {
    return `${this.fieldKey(field).replace(/[^a-zA-Z0-9_-]/g, "_")}_error`
  }

  describedBy(field, errorId) {
    const ids = (field.getAttribute("aria-describedby") || "")
      .split(/\s+/)
      .filter((id) => id.length > 0 && id !== this.errorId(field))

    if (errorId) ids.push(errorId)
    return ids.join(" ")
  }

  setDescribedBy(field, value) {
    if (value) {
      field.setAttribute("aria-describedby", value)
    } else {
      field.removeAttribute("aria-describedby")
    }
  }
}
