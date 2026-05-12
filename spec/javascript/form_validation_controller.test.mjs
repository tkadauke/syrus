import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/form_validation_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class FormValidationController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default FormValidationController`)}`)
}

class ClassList {
  constructor() {
    this.values = new Set()
  }

  add(value) {
    this.values.add(value)
  }

  remove(value) {
    this.values.delete(value)
  }

  contains(value) {
    return this.values.has(value)
  }
}

class FakeElement {
  constructor(tagName = "div") {
    this.tagName = tagName
    this.attributes = new Map()
    this.children = []
    this.classList = new ClassList()
    this.dataset = {}
    this.hidden = false
    this.parentElement = null
    this.textContent = ""
  }

  set id(value) {
    this.attributes.set("id", value)
  }

  get id() {
    return this.attributes.get("id") || ""
  }

  set className(value) {
    this.attributes.set("class", value)
  }

  get className() {
    return this.attributes.get("class") || ""
  }

  setAttribute(name, value) {
    this.attributes.set(name, value)
  }

  getAttribute(name) {
    return this.attributes.get(name) || null
  }

  removeAttribute(name) {
    this.attributes.delete(name)
  }

  appendChild(child) {
    child.parentElement = this
    this.children.push(child)
  }

  prepend(child) {
    child.parentElement = this
    this.children.unshift(child)
  }

  insertAdjacentElement(position, element) {
    assert.equal(position, "afterend")

    const siblings = this.parentElement.children
    const index = siblings.indexOf(this)
    element.parentElement = this.parentElement
    siblings.splice(index + 1, 0, element)
  }

  remove() {
    if (!this.parentElement) return

    const siblings = this.parentElement.children
    siblings.splice(siblings.indexOf(this), 1)
    this.parentElement = null
  }

  querySelector(selector) {
    if (selector === ":scope > [data-form-validation-summary]") {
      return this.children.find((child) => child.dataset.formValidationSummary === "true") || null
    }

    return null
  }

  querySelectorAll(selector) {
    if (selector !== "[data-form-validation-error-for]") return []

    return this.children.filter((child) => child.dataset.formValidationErrorFor)
  }
}

class HTMLFormElement extends FakeElement {
  constructor(elements) {
    super("form")
    this.elements = elements
    this.noValidate = false

    for (const element of elements) {
      element.form = this
      this.appendChild(element)
    }
  }

  checkValidity() {
    return this.elements.every((element) => element.validity.valid)
  }
}

class FieldElement extends FakeElement {
  constructor({ id, name, label, valid = false }) {
    super("select")
    this.id = id
    this.name = name
    this.labels = label ? [{ textContent: label }] : []
    this.validity = { valid, valueMissing: !valid }
    this.validationMessage = ""
    this.willValidate = true
  }

  focus() {
    this.focused = true
  }

  scrollIntoView(options) {
    this.scrolledTo = options
  }
}

class TextAreaElement extends FieldElement {
  constructor(options) {
    super(options)
    this.tagName = "textarea"
  }
}

class SubmitButtonElement extends FakeElement {
  constructor({ form, type = "submit", formNoValidate = false }) {
    super("button")
    this.form = form
    this.type = type
    this.formNoValidate = formNoValidate
  }
}

class SubmitButtonChildElement extends FakeElement {
  constructor(button) {
    super("span")
    this.button = button
  }

  closest(selector) {
    assert.equal(selector, "button, input")
    return this.button
  }
}

globalThis.document = {
  createElement: (tagName) => new FakeElement(tagName)
}
globalThis.HTMLButtonElement = SubmitButtonElement
globalThis.HTMLFormElement = HTMLFormElement
globalThis.HTMLInputElement = FieldElement
globalThis.HTMLSelectElement = FieldElement
globalThis.HTMLTextAreaElement = TextAreaElement

function buildController(Controller) {
  const controller = new Controller()
  controller.submittedForms = new WeakSet()
  return controller
}

test("does not render field errors before the form has been submitted", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)
  const repository = new FieldElement({ id: "repository_id", name: "repository_id", label: "Repository" })
  new HTMLFormElement([repository])

  controller.invalid({ target: repository })
  controller.input({ target: repository })

  assert.equal(repository.getAttribute("aria-invalid"), null)
  assert.equal(repository.classList.contains("border-red-500"), false)
  assert.equal(repository.parentElement.querySelectorAll("[data-form-validation-error-for]").length, 0)
})

test("renders invalid fields and the summary after a submit attempt", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)
  const repository = new FieldElement({ id: "repository_id", name: "repository_id", label: "Repository" })
  const form = new HTMLFormElement([repository])
  const submitter = new SubmitButtonElement({ form })

  controller.submitAttempt({ target: submitter })
  controller.invalid({ target: repository })
  await Promise.resolve()

  assert.equal(repository.getAttribute("aria-invalid"), "true")
  assert.equal(repository.classList.contains("border-red-500"), true)

  const error = form.querySelectorAll("[data-form-validation-error-for]")[0]
  assert.equal(error.textContent, "Repository is required.")
  assert.equal(form.querySelector(":scope > [data-form-validation-summary]").textContent, "Fix the highlighted field before continuing.")
})

test("treats clicks inside a submit button as submit attempts", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)
  const repository = new FieldElement({ id: "repository_id", name: "repository_id", label: "Repository" })
  const form = new HTMLFormElement([repository])
  const submitter = new SubmitButtonElement({ form })

  controller.submitAttempt({ target: new SubmitButtonChildElement(submitter) })
  controller.invalid({ target: repository })
  await Promise.resolve()

  assert.equal(repository.getAttribute("aria-invalid"), "true")
  assert.equal(form.querySelectorAll("[data-form-validation-error-for]")[0].textContent, "Repository is required.")
})

test("renders invalid fields after an implicit Enter-key submit attempt", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)
  const repository = new FieldElement({ id: "repository_id", name: "repository_id", label: "Repository" })
  const form = new HTMLFormElement([repository])

  controller.keydown({ target: repository, key: "Enter" })
  controller.invalid({ target: repository })
  await Promise.resolve()

  assert.equal(repository.getAttribute("aria-invalid"), "true")
  assert.equal(form.querySelectorAll("[data-form-validation-error-for]")[0].textContent, "Repository is required.")
})

test("clears errors after a submitted field becomes valid", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)
  const repository = new FieldElement({ id: "repository_id", name: "repository_id", label: "Repository" })
  const form = new HTMLFormElement([repository])

  controller.submit({
    target: form,
    submitter: null,
    preventDefault: () => {},
    stopPropagation: () => {}
  })

  repository.validity = { valid: true, valueMissing: false }
  controller.input({ target: repository })

  assert.equal(repository.getAttribute("aria-invalid"), null)
  assert.equal(repository.classList.contains("border-red-500"), false)
  assert.equal(form.querySelectorAll("[data-form-validation-error-for]").length, 0)
  assert.equal(form.querySelector(":scope > [data-form-validation-summary]"), null)
})
