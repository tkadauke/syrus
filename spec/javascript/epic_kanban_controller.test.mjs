import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/epic_kanban_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class EpicKanbanController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default EpicKanbanController`)}`)
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

function event({ cardState = "ready", laneState = "in_progress" } = {}) {
  return {
    currentTarget: {
      dataset: {
        epicId: "123",
        epicState: cardState,
        epicStateUrl: "/epics/123/state"
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

test("dragStart only permits ready cards", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const ready = event({ cardState: "ready" })

  controller.dragStart(ready)

  assert.equal(ready.defaultPrevented, false)
  assert.deepEqual(JSON.parse(ready.dataTransfer.getData("text/plain")), {
    id: "123",
    state: "ready",
    url: "/epics/123/state"
  })

  const backlog = event({ cardState: "backlog" })
  controller.dragStart(backlog)
  assert.equal(backlog.defaultPrevented, true)
})

test("dragOver rejects every lane except ready to in_progress", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const drag = event({ cardState: "ready" })
  controller.dragStart(drag)

  const allowed = { currentTarget: { dataset: { epicState: "in_progress" } }, dataTransfer: drag.dataTransfer, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
  controller.dragOver(allowed)
  assert.equal(allowed.defaultPrevented, true)

  const rejected = { currentTarget: { dataset: { epicState: "done" } }, dataTransfer: drag.dataTransfer, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
  controller.dragOver(rejected)
  assert.equal(rejected.defaultPrevented, false)
})

test("drop patches the Epic state endpoint for an allowed move", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
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

  const drop = { currentTarget: { dataset: { epicState: "in_progress" } }, dataTransfer: drag.dataTransfer, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
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
