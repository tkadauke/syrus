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
  const controller = new Controller()
  controller.streamTarget = stream
  controller.newMessagesPillTarget = pill
  controller.textareaTarget = textarea
  controller.sendButtonTarget = sendButton
  controller.hasStreamTarget = true
  controller.hasNewMessagesPillTarget = true
  controller.hasTextareaTarget = true
  controller.hasSendButtonTarget = true
  controller.turnInFlightValue = inFlight
  return { controller, stream, pill, textarea, sendButton }
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
