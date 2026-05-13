import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/chat_layout_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class ChatLayoutController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default ChatLayoutController`)}`)
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
  constructor({ rect } = {}) {
    this.children = []
    this.parentNode = null
    this.classList = new ClassList()
    this.style = {}
    this.attributes = {}
    this.rect = rect
  }

  appendChild(child) {
    if (child.parentNode) {
      child.parentNode.children = child.parentNode.children.filter((existing) => existing !== child)
    }

    child.parentNode = this
    this.children.push(child)
    return child
  }

  setAttribute(name, value) {
    this.attributes[name] = value
  }

  getBoundingClientRect() {
    return this.rect || { left: 0, width: 1000 }
  }

  setPointerCapture(pointerId) {
    this.capturedPointerId = pointerId
  }
}

class DocumentFragment extends Element {}

function installWindow({ desktop }) {
  const store = new Map()
  const listeners = {}
  const mediaQuery = {
    matches: desktop,
    addEventListener(eventName, callback) {
      this.listener = { eventName, callback }
    },
    removeEventListener(eventName, callback) {
      if (this.listener?.eventName === eventName && this.listener?.callback === callback) this.listener = null
    }
  }

  globalThis.document = {
    createDocumentFragment: () => new DocumentFragment()
  }
  globalThis.Event = class Event {
    constructor(type) {
      this.type = type
    }
  }
  globalThis.window = {
    matchMedia: () => mediaQuery,
    localStorage: {
      getItem: (key) => store.get(key) || null,
      setItem: (key, value) => store.set(key, value)
    },
    requestAnimationFrame: (callback) => callback(),
    dispatchEvent: (event) => {
      listeners[event.type] = (listeners[event.type] || 0) + 1
    },
    addEventListener: (eventName, callback) => {
      listeners[eventName] = callback
    },
    removeEventListener: (eventName, callback) => {
      if (listeners[eventName] === callback) delete listeners[eventName]
    }
  }

  return { mediaQuery, store, listeners }
}

function buildController(Controller, { desktop = true } = {}) {
  installWindow({ desktop })

  const controller = new Controller()
  controller.activeTabValue = "chat"
  controller.storageKeyValue = "syrus.repository.1.chat_split"
  controller.hasStorageKeyValue = true
  controller.canvasPaneTarget = new Element()
  controller.chatPaneTarget = new Element()
  controller.desktopCanvasSlotTarget = new Element()
  controller.desktopChatSlotTarget = new Element()
  controller.mobileSlotTarget = new Element()
  controller.gridTarget = new Element()
  controller.dividerTarget = new Element()
  controller.chatTabTarget = new Element()
  controller.canvasTabTarget = new Element()
  controller.hasGridTarget = true
  controller.hasChatTabTarget = true
  controller.hasCanvasTabTarget = true

  return controller
}

test("desktop mounts both panes and applies the default split", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)

  controller.connect()

  assert.equal(controller.canvasPaneTarget.parentNode, controller.desktopCanvasSlotTarget)
  assert.equal(controller.chatPaneTarget.parentNode, controller.desktopChatSlotTarget)
  assert.equal(
    controller.gridTarget.style.gridTemplateColumns,
    "minmax(0, 60%) 0.75rem minmax(20rem, 40%)"
  )
})

test("desktop drag resizes the grid and persists the ratio", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller)

  controller.connect()
  controller.startDrag({ pointerType: "mouse", pointerId: 1, preventDefault() {} })
  controller.drag({ clientX: 700 })

  assert.equal(
    controller.gridTarget.style.gridTemplateColumns,
    "minmax(0, 70%) 0.75rem minmax(20rem, 30%)"
  )
  assert.equal(window.localStorage.getItem("syrus.repository.1.chat_split"), "0.700")
})

test("mobile mounts only the active pane and switches tabs", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller, { desktop: false })

  controller.connect()
  assert.equal(controller.chatPaneTarget.parentNode, controller.mobileSlotTarget)
  assert.equal(controller.canvasPaneTarget.parentNode, controller.detachedSlot)
  assert.equal(controller.chatTabTarget.attributes["aria-selected"], "true")

  controller.showCanvas()

  assert.equal(controller.canvasPaneTarget.parentNode, controller.mobileSlotTarget)
  assert.equal(controller.chatPaneTarget.parentNode, controller.desktopChatSlotTarget)
  assert.equal(controller.canvasTabTarget.attributes["aria-selected"], "true")
})

test("mobile swipe switches between chat and canvas tabs", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller, { desktop: false })

  controller.connect()
  controller.swipeStart({ touches: [{ clientX: 180 }] })
  controller.swipeEnd({ changedTouches: [{ clientX: 80 }] })

  assert.equal(controller.activeTabValue, "canvas")

  controller.swipeStart({ touches: [{ clientX: 80 }] })
  controller.swipeEnd({ changedTouches: [{ clientX: 180 }] })

  assert.equal(controller.activeTabValue, "chat")
})
