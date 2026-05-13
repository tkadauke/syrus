import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/chat_side_panel_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class ChatSidePanelController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default ChatSidePanelController`)}`)
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

class Element {
  constructor() {
    this.classList = new ClassList()
    this.attributes = {}
  }

  setAttribute(name, value) {
    this.attributes[name] = value
  }

  getAttribute(name) {
    return this.attributes[name] || null
  }
}

function installWindow() {
  const store = new Map()
  const dispatched = []

  globalThis.Event = class Event {
    constructor(type) {
      this.type = type
    }
  }
  globalThis.window = {
    localStorage: {
      getItem: (key) => store.get(key) || null,
      setItem: (key, value) => store.set(key, value)
    },
    requestAnimationFrame: (callback) => callback(),
    dispatchEvent: (event) => dispatched.push(event.type)
  }

  return { store, dispatched }
}

function buildController(Controller) {
  installWindow()

  const controller = new Controller()
  controller.repositoryIdValue = 12
  controller.documentationUrlValue = "/repositories/12/documents?frame=1"
  controller.hasDocumentationUrlValue = true
  controller.whiteboardTabTargets = [new Element(), new Element()]
  controller.documentationTabTargets = [new Element(), new Element()]
  controller.whiteboardPanelTarget = new Element()
  controller.documentationPanelTarget = new Element()
  controller.documentationFrameTarget = new Element()
  controller.hasDocumentationFrameTarget = true

  return controller
}

test("defaults to the pre-rendered whiteboard without loading documentation", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)

  controller.connect()

  assert.equal(controller.whiteboardPanelTarget.classList.contains("hidden"), false)
  assert.equal(controller.documentationPanelTarget.classList.contains("hidden"), true)
  assert.equal(controller.documentationFrameTarget.getAttribute("src"), null)
  assert.equal(controller.whiteboardTabTargets[0].attributes["aria-selected"], "true")
})

test("persists the selected documentation tab and lazy-loads its frame once", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)

  controller.connect()
  controller.showDocumentation()

  assert.equal(window.localStorage.getItem("syrus.repository.12.chat_side_panel_tab"), "documentation")
  assert.equal(controller.documentationPanelTarget.classList.contains("hidden"), false)
  assert.equal(controller.documentationFrameTarget.getAttribute("src"), "/repositories/12/documents?frame=1")

  controller.documentationFrameTarget.setAttribute("src", "/already-loaded")
  controller.showDocumentation()

  assert.equal(controller.documentationFrameTarget.getAttribute("src"), "/already-loaded")
})

test("restores the persisted documentation tab on reconnect", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)

  window.localStorage.setItem("syrus.repository.12.chat_side_panel_tab", "documentation")
  controller.connect()

  assert.equal(controller.documentationPanelTarget.classList.contains("hidden"), false)
  assert.equal(controller.documentationTabTargets[0].attributes["aria-selected"], "true")
  assert.equal(controller.documentationFrameTarget.getAttribute("src"), "/repositories/12/documents?frame=1")
})
