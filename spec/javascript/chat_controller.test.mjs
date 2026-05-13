import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/chat_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class ChatController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default ChatController`)}`)
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
    if (force === undefined) {
      if (this.values.has(value)) {
        this.values.delete(value)
        return false
      }

      this.values.add(value)
      return true
    }

    if (force) {
      this.values.add(value)
    } else {
      this.values.delete(value)
    }

    return force
  }

  contains(value) {
    return this.values.has(value)
  }
}

class FakeMutationObserver {
  constructor(callback) {
    this.callback = callback
  }

  observe(target, options) {
    this.target = target
    this.options = options
  }

  disconnect() {
    this.disconnected = true
  }
}

globalThis.MutationObserver = FakeMutationObserver

function buildController(Controller, { scrollTop = 700, scrollHeight = 1000, clientHeight = 300, inFlight = false } = {}) {
  const stream = { scrollTop, scrollHeight, clientHeight }
  const pill = { classList: new ClassList(["hidden"]) }
  const textarea = { disabled: false }
  const sendButton = { disabled: false }
  const stopButton = { disabled: false, value: "Stop", textContent: "Stop" }
  const whiteboard = { dataset: { whiteboardScene: JSON.stringify({ elements: [] }) } }
  const whiteboardPlaceholder = { classList: new ClassList(["hidden"]) }
  const controller = new Controller()
  controller.streamTarget = stream
  controller.newMessagesPillTarget = pill
  controller.textareaTarget = textarea
  controller.sendButtonTarget = sendButton
  controller.stopButtonTarget = stopButton
  controller.whiteboardTarget = whiteboard
  controller.whiteboardPlaceholderTarget = whiteboardPlaceholder
  controller.hasStreamTarget = true
  controller.hasNewMessagesPillTarget = true
  controller.hasTextareaTarget = true
  controller.hasSendButtonTarget = true
  controller.hasStopButtonTarget = true
  controller.hasWhiteboardTarget = true
  controller.hasWhiteboardPlaceholderTarget = true
  controller.turnInFlightValue = inFlight
  return { controller, stream, pill, textarea, sendButton, stopButton, whiteboard, whiteboardPlaceholder }
}

test("auto-scrolls when messages arrive while the user is at the bottom", async () => {
  const { default: Controller } = await loadController()
  const { controller, stream, pill } = buildController(Controller)

  controller.connect()
  stream.scrollHeight = 1200
  controller.messagesChanged()

  assert.equal(stream.scrollTop, 1200)
  assert.equal(pill.classList.contains("hidden"), true)
})

test("shows the new messages pill instead of scrolling when user has scrolled up", async () => {
  const { default: Controller } = await loadController()
  const { controller, stream, pill } = buildController(Controller, { scrollTop: 200 })

  controller.wasNearBottom = false
  stream.scrollHeight = 1300
  controller.messagesChanged()

  assert.equal(stream.scrollTop, 200)
  assert.equal(pill.classList.contains("hidden"), false)
})

test("clicking the new messages pill scrolls to bottom and hides it", async () => {
  const { default: Controller } = await loadController()
  const { controller, stream, pill } = buildController(Controller, { scrollTop: 200 })
  pill.classList.remove("hidden")

  controller.scrollToBottom()

  assert.equal(stream.scrollTop, 1000)
  assert.equal(pill.classList.contains("hidden"), true)
})

test("disables compose controls while a turn is in flight", async () => {
  const { default: Controller } = await loadController()
  const { controller, textarea, sendButton } = buildController(Controller, { inFlight: true })

  controller.updateCompose()

  assert.equal(textarea.disabled, true)
  assert.equal(sendButton.disabled, true)
})

test("stop disables the stop button and flips its label immediately", async () => {
  const { default: Controller } = await loadController()
  const { controller, stopButton } = buildController(Controller)

  controller.stop()

  assert.equal(stopButton.disabled, true)
  assert.equal(stopButton.value, "Stopping…")
  assert.equal(stopButton.textContent, "Stopping…")
})

test("shows the whiteboard empty state for an empty scene", async () => {
  const { default: Controller } = await loadController()
  const { controller, whiteboardPlaceholder } = buildController(Controller)

  controller.syncWhiteboardPlaceholder()

  assert.equal(whiteboardPlaceholder.classList.contains("hidden"), false)
})

test("hides and restores the whiteboard empty state as elements change", async () => {
  const { default: Controller } = await loadController()
  const { controller, whiteboardPlaceholder } = buildController(Controller)

  controller.whiteboardChanged({ detail: { elements: [{ id: "shape-1" }] } })
  assert.equal(whiteboardPlaceholder.classList.contains("hidden"), true)

  controller.whiteboardChanged({ detail: { elements: [] } })
  assert.equal(whiteboardPlaceholder.classList.contains("hidden"), false)
})

test("connects without a message stream on unavailable chat views", async () => {
  const { default: Controller } = await loadController()
  const { controller } = buildController(Controller)
  controller.hasStreamTarget = false
  delete controller.streamTarget

  controller.connect()

  assert.equal(controller.observer, undefined)
})
