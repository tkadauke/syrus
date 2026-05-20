import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/kanban_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class KanbanController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default KanbanController`)}`)
}

class DataTransfer {
  constructor() {
    this.values = new Map()
  }

  setData(type, value) {
    this.values.set(type, value)
  }

  getData(type) {
    return this.values.get(type) || ""
  }
}

class Element {
  constructor(tagName = "div") {
    this.tagName = tagName.toUpperCase()
    this.children = []
    this.attributes = {}
    this.parentElement = null
  }

  append(...children) {
    children.forEach((child) => {
      if (child instanceof Element) child.parentElement = this
      this.children.push(child)
    })
  }

  setAttribute(name, value) {
    this.attributes[name] = value
  }

  closest(selector) {
    let node = this
    while (node) {
      if (matchesSelector(node, selector)) return node
      node = node.parentElement
    }
    return null
  }

  contains(other) {
    if (other === this) return true
    return this.children.some((child) => child instanceof Element && child.contains(other))
  }
}

function matchesSelector(element, selector) {
  return selector === "details[open]" &&
    element.tagName === "DETAILS" &&
    Object.hasOwn(element.attributes, "open")
}

function event({ cardState = "ready", laneState = "in_progress" } = {}) {
  return {
    currentTarget: {
      dataset: {
        epicId: "123",
        epicState: cardState,
        epicStateUrl: "/epics/123/state",
        kanbanId: "123",
        kanbanState: cardState,
        kanbanStateUrl: "/epics/123/state"
      }
    },
    dataTransfer: new DataTransfer(),
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
    lane(state = laneState) {
      this.currentTarget = { dataset: { epicState: state } }
      return this
    }
  }
}

test("open card menus prevent Turbo element morphs", async () => {
  const { default: Controller } = await loadController()
  const listeners = new Map()
  globalThis.Element = Element
  globalThis.document = {
    addEventListener: (name, listener) => listeners.set(name, listener),
    removeEventListener() {}
  }

  const controller = new Controller()
  controller.element = new Element()
  const menu = new Element("details")
  const menuItem = new Element("button")
  menu.setAttribute("open", "")
  menu.append(menuItem)
  controller.element.append(menu)

  controller.connect()

  let prevented = false
  listeners.get("turbo:before-morph-element")({
    target: menuItem,
    preventDefault() { prevented = true }
  })

  assert.equal(prevented, true)
})

test("dragStart permits ready and in_progress Epic cards", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  controller.subjectValue = "epic"
  const ready = event({ cardState: "ready" })

  controller.dragStart(ready)

  assert.equal(ready.defaultPrevented, false)
  assert.deepEqual(JSON.parse(ready.dataTransfer.getData("text/plain")), {
    id: "123",
    state: "ready",
    url: "/epics/123/state"
  })

  const inProgress = event({ cardState: "in_progress" })
  controller.dragStart(inProgress)

  assert.equal(inProgress.defaultPrevented, false)
  assert.deepEqual(JSON.parse(inProgress.dataTransfer.getData("text/plain")), {
    id: "123",
    state: "in_progress",
    url: "/epics/123/state"
  })

  const backlog = event({ cardState: "backlog" })
  controller.dragStart(backlog)
  assert.equal(backlog.defaultPrevented, true)
})

test("dragOver rejects every lane except ready to in_progress and in_progress to ready", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  controller.subjectValue = "epic"
  const drag = event({ cardState: "ready" })
  controller.dragStart(drag)

  const allowed = { currentTarget: { dataset: { kanbanState: "in_progress" } }, dataTransfer: drag.dataTransfer, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
  controller.dragOver(allowed)
  assert.equal(allowed.defaultPrevented, true)

  const rejected = { currentTarget: { dataset: { kanbanState: "done" } }, dataTransfer: drag.dataTransfer, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
  controller.dragOver(rejected)
  assert.equal(rejected.defaultPrevented, false)

  const reverseDrag = event({ cardState: "in_progress" })
  controller.dragStart(reverseDrag)

  const reverseAllowed = { currentTarget: { dataset: { kanbanState: "ready" } }, dataTransfer: reverseDrag.dataTransfer, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
  controller.dragOver(reverseAllowed)
  assert.equal(reverseAllowed.defaultPrevented, true)

  for (const laneState of [ "backlog", "in_progress", "done" ]) {
    const reverseRejected = { currentTarget: { dataset: { kanbanState: laneState } }, dataTransfer: reverseDrag.dataTransfer, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
    controller.dragOver(reverseRejected)
    assert.equal(reverseRejected.defaultPrevented, false)
  }
})

test("drop patches the Epic state endpoint for an allowed move", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  controller.subjectValue = "epic"
  const drag = event({ cardState: "ready" })
  controller.dragStart(drag)

  global.document = {
    querySelector() {
      return { content: "csrf-token" }
    }
  }
  global.window = {
    location: { href: "http://example.test/dashboard/epics" },
    Turbo: { visit(url, options) { this.visited = { url, options } } }
  }

  let request
  global.fetch = async (url, options) => {
    request = { url, options }
    return { ok: true }
  }

  const drop = { currentTarget: { dataset: { kanbanState: "in_progress" } }, dataTransfer: drag.dataTransfer, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
  await controller.drop(drop)

  assert.equal(drop.defaultPrevented, true)
  assert.equal(request.url, "/epics/123/state")
  assert.equal(request.options.method, "PATCH")
  assert.equal(request.options.headers["X-CSRF-Token"], "csrf-token")
  assert.deepEqual(JSON.parse(request.options.body), { target_state: "in_progress" })
  assert.deepEqual(window.Turbo.visited, {
    url: "http://example.test/dashboard/epics",
    options: { action: "replace" }
  })
})

test("drop patches ready when an in_progress Epic is dropped on the ready lane", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  controller.subjectValue = "epic"
  const drag = event({ cardState: "in_progress" })
  controller.dragStart(drag)

  global.document = {
    querySelector() {
      return { content: "csrf-token" }
    }
  }
  global.window = {
    location: { href: "http://example.test/dashboard/epics" },
    Turbo: { visit(url, options) { this.visited = { url, options } } }
  }

  let request
  global.fetch = async (url, options) => {
    request = { url, options }
    return { ok: true }
  }

  const drop = { currentTarget: { dataset: { kanbanState: "ready" } }, dataTransfer: drag.dataTransfer, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
  await controller.drop(drop)

  assert.equal(drop.defaultPrevented, true)
  assert.equal(request.url, "/epics/123/state")
  assert.deepEqual(JSON.parse(request.options.body), { target_state: "ready" })
})
