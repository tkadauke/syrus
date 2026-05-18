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
  controller.checkboxTargets = [ { checked: true, value: "1" }, { checked: false, value: "2" } ]
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
  globalThis.location = { pathname: "/dashboard/jobs", search: "" }
  globalThis.sessionStorage = new MemoryStorage()
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

test("restores checkbox selection from sessionStorage after Turbo morphs", async () => {
  const { default: Controller } = await loadController()
  const listeners = new Map()
  globalThis.document = {
    addEventListener(name, listener) {
      listeners.set(name, listener)
    },
    removeEventListener() {}
  }
  globalThis.location = { pathname: "/dashboard/jobs", search: "?subject=job" }
  globalThis.sessionStorage = new MemoryStorage()
  globalThis.sessionStorage.setItem("bulk-jobs:/dashboard/jobs?subject=job", JSON.stringify([ "2" ]))

  const controller = buildController(Controller)
  controller.checkboxTargets = [ { checked: false, value: "1" }, { checked: false, value: "2" } ]

  controller.connect()
  assert.deepEqual(controller.checkboxTargets.map((checkbox) => checkbox.checked), [ false, true ])

  controller.checkboxTargets.forEach((checkbox) => {
    checkbox.checked = false
  })
  listeners.get("turbo:morph")()

  assert.deepEqual(controller.checkboxTargets.map((checkbox) => checkbox.checked), [ false, true ])
  assert.equal(controller.countTargets[0].textContent, "1")
  assert.equal(controller.actionsTarget.classList.contains("hidden"), false)
})

class MemoryStorage {
  constructor() {
    this.values = new Map()
  }

  getItem(key) {
    return this.values.get(key) || null
  }

  setItem(key, value) {
    this.values.set(key, value)
  }
}
