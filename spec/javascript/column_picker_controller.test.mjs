import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/column_picker_controller.js", import.meta.url)
let importCounter = 0

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class ColumnPickerController extends Controller")

  importCounter += 1
  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default ColumnPickerController\n// import ${importCounter}`)}`)
}

class ClassList {
  constructor(values = []) {
    this.values = new Set(values)
  }

  add(value) {
    this.values.add(value)
  }

  remove(value) {
    this.values.delete(value)
  }

  toggle(value) {
    if (this.values.has(value)) {
      this.values.delete(value)
    } else {
      this.values.add(value)
    }
  }

  contains(value) {
    return this.values.has(value)
  }
}

function installDocument() {
  const listeners = new Map()
  globalThis.document = {
    addEventListener(name, listener) {
      listeners.set(name, listener)
    },
    removeEventListener(name, listener) {
      if (listeners.get(name) === listener) listeners.delete(name)
    },
    querySelector(selector) {
      if (selector === "meta[name='csrf-token']") return { content: "csrf-token" }
      return null
    }
  }
  return listeners
}

function buildController(Controller) {
  const panelTarget = { classList: new ClassList([ "hidden" ]) }
  const element = {
    contains(target) {
      return target === this || target === panelTarget
    }
  }
  const controller = new Controller()
  controller.element = element
  controller.panelTarget = panelTarget
  return controller
}

test("toggles the picker panel and closes on outside click", async () => {
  const { default: Controller } = await loadController()
  const listeners = installDocument()
  const controller = buildController(Controller)
  controller.connect()

  controller.toggle({ preventDefault() {}, stopPropagation() {} })
  assert.equal(controller.panelTarget.classList.contains("hidden"), false)

  listeners.get("click")({ target: {} })
  assert.equal(controller.panelTarget.classList.contains("hidden"), true)

  controller.disconnect()
  assert.equal(listeners.size, 0)
})

test("patches preferences and refreshes the current page after save", async () => {
  installDocument()
  const { default: Controller } = await loadController()
  globalThis.FormData = class FormData {
    constructor(form) {
      this.form = form
    }
  }
  let fetchCall
  globalThis.fetch = async (url, options) => {
    fetchCall = { url, options }
    return { ok: true }
  }
  globalThis.window = {
    location: { href: "/?subject=job&view=list" },
    Turbo: {
      visit(url, options) {
        this.lastVisit = { url, options }
      }
    }
  }
  const controller = buildController(Controller)
  const form = { action: "/dashboard/preferences" }

  await controller.save({ preventDefault() {}, target: form })

  assert.equal(fetchCall.url, "/dashboard/preferences")
  assert.equal(fetchCall.options.method, "PATCH")
  assert.equal(fetchCall.options.headers["X-CSRF-Token"], "csrf-token")
  assert.equal(globalThis.window.Turbo.lastVisit.url, "/?subject=job&view=list")
  assert.deepEqual(globalThis.window.Turbo.lastVisit.options, { action: "replace" })
})
