import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/bulk_jobs_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class BulkJobsController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default BulkJobsController`)}`)
}

class ClassList {
  constructor(values = []) {
    this.values = new Set(values)
  }

  toggle(value, force) {
    if (force) {
      this.values.add(value)
    } else {
      this.values.delete(value)
    }
  }

  contains(value) {
    return this.values.has(value)
  }
}

function buildController(Controller) {
  const controller = new Controller()
  controller.actionsTarget = { classList: new ClassList([ "hidden" ]) }
  controller.countTargets = [ { textContent: "0" } ]
  controller.checkboxTargets = [ { checked: true }, { checked: false } ]
  controller.selectAllTarget = { checked: false, indeterminate: false }
  controller.hasSelectAllTarget = true
  return controller
}

test("syncs bulk action state after Turbo morph events", async () => {
  const { default: Controller } = await loadController()
  const listeners = new Map()
  globalThis.document = {
    addEventListener(name, listener) {
      listeners.set(name, listener)
    },
    removeEventListener() {}
  }
  const controller = buildController(Controller)

  controller.connect()

  assert.equal(controller.actionsTarget.classList.contains("hidden"), false)
  assert.equal(controller.countTargets[0].textContent, "1")
  assert.equal(controller.selectAllTarget.indeterminate, true)

  controller.actionsTarget.classList.values.add("hidden")
  controller.countTargets[0].textContent = "0"
  controller.selectAllTarget.indeterminate = false
  listeners.get("turbo:morph")()

  assert.equal(controller.actionsTarget.classList.contains("hidden"), false)
  assert.equal(controller.countTargets[0].textContent, "1")
  assert.equal(controller.selectAllTarget.indeterminate, true)
})
