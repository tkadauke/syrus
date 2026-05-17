import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/checkbox_persistence_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class CheckboxPersistenceController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default CheckboxPersistenceController`)}`)
}

class InputElement {
  constructor({ id = "", name = "", value = "on", type = "checkbox", form = null, checked = false, indeterminate = false, persistence = undefined } = {}) {
    this.id = id
    this.name = name
    this.value = value
    this.type = type
    this.checked = checked
    this.indeterminate = indeterminate
    this.dataset = {}
    this.attributes = new Map()

    if (form) this.attributes.set("form", form)
    if (checked) this.attributes.set("checked", "checked")
    if (persistence !== undefined) this.dataset.checkboxPersistence = persistence
  }

  getAttribute(name) {
    return this.attributes.get(name) || null
  }

  setAttribute(name, value) {
    this.attributes.set(name, value)
  }

  removeAttribute(name) {
    this.attributes.delete(name)
  }
}

globalThis.HTMLInputElement = InputElement

function eventFor(current, replacement) {
  return {
    target: current,
    detail: { newElement: replacement }
  }
}

test("copies checked checkbox state to Turbo morph replacements with the same id", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const current = new InputElement({ id: "bulk_job_1", checked: true, indeterminate: true })
  const replacement = new InputElement({ id: "bulk_job_1", checked: false })

  controller.preserveCheckboxState(eventFor(current, replacement))

  assert.equal(replacement.checked, true)
  assert.equal(replacement.indeterminate, true)
  assert.equal(replacement.getAttribute("checked"), "checked")
})

test("copies unchecked checkbox state to matching Turbo morph replacements", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const current = new InputElement({ name: "issue_numbers[]", value: "12", form: "repository_bulk_issues", checked: false })
  const replacement = new InputElement({ name: "issue_numbers[]", value: "12", form: "repository_bulk_issues", checked: true })

  controller.preserveCheckboxState(eventFor(current, replacement))

  assert.equal(replacement.checked, false)
  assert.equal(replacement.getAttribute("checked"), null)
})

test("does not copy checkbox state to a different checkbox", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const current = new InputElement({ name: "issue_numbers[]", value: "12", form: "repository_bulk_issues", checked: true })
  const replacement = new InputElement({ name: "issue_numbers[]", value: "13", form: "repository_bulk_issues", checked: false })

  controller.preserveCheckboxState(eventFor(current, replacement))

  assert.equal(replacement.checked, false)
  assert.equal(replacement.getAttribute("checked"), null)
})

test("allows checkbox persistence to be disabled per element", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const current = new InputElement({ id: "server_owned", checked: true, persistence: "false" })
  const replacement = new InputElement({ id: "server_owned", checked: false })

  controller.preserveCheckboxState(eventFor(current, replacement))

  assert.equal(replacement.checked, false)
  assert.equal(replacement.getAttribute("checked"), null)
})
