import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/epic_graph_drawer_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class EpicGraphDrawerController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default EpicGraphDrawerController`)}`)
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

class Element {
  constructor(classes = []) {
    this.classList = new ClassList(classes)
    this.textContent = ""
  }
}

function installDocument() {
  const listeners = new Map()
  globalThis.document = {
    addEventListener: (type, listener) => listeners.set(type, listener),
    removeEventListener: (type) => listeners.delete(type)
  }
  return listeners
}

function buildController(Controller) {
  installDocument()

  const controller = new Controller()
  controller.overlayTarget = new Element([ "hidden" ])
  controller.panelTarget = new Element([ "translate-x-full", "max-w-3xl" ])
  controller.expandLabelTarget = new Element()
  controller.expandLabelTarget.textContent = "Expand full-width"
  return controller
}

test("opens and closes the drawer", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)

  controller.open()

  assert.equal(controller.overlayTarget.classList.contains("hidden"), false)
  assert.equal(controller.panelTarget.classList.contains("translate-x-full"), false)

  controller.close()

  assert.equal(controller.overlayTarget.classList.contains("hidden"), true)
  assert.equal(controller.panelTarget.classList.contains("translate-x-full"), true)
})

test("closes on Escape after connect", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)
  controller.open()

  const listeners = installDocument()
  controller.connect()
  listeners.get("keydown")({ key: "Escape" })

  assert.equal(controller.overlayTarget.classList.contains("hidden"), true)
  assert.equal(controller.panelTarget.classList.contains("translate-x-full"), true)
})

test("toggles full-width mode", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)

  controller.toggleExpanded()

  assert.equal(controller.panelTarget.classList.contains("max-w-3xl"), false)
  assert.equal(controller.panelTarget.classList.contains("max-w-none"), true)
  assert.equal(controller.panelTarget.classList.contains("w-full"), true)
  assert.equal(controller.expandLabelTarget.textContent, "Restore width")

  controller.toggleExpanded()

  assert.equal(controller.panelTarget.classList.contains("max-w-3xl"), true)
  assert.equal(controller.panelTarget.classList.contains("max-w-none"), false)
  assert.equal(controller.panelTarget.classList.contains("w-full"), false)
  assert.equal(controller.expandLabelTarget.textContent, "Expand full-width")
})
