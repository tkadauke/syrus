import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/details_persistence_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class DetailsPersistenceController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default DetailsPersistenceController`)}`)
}

class DetailsElement {
  constructor({ key = "", open = false, persistence = undefined } = {}) {
    this.open = open
    this.dataset = {}
    this.attributes = new Map()

    if (key) this.dataset.detailsPersistenceKey = key
    if (open) this.attributes.set("open", "")
    if (persistence !== undefined) this.dataset.detailsPersistence = persistence
  }

  setAttribute(name, value) {
    this.attributes.set(name, value)
  }

  removeAttribute(name) {
    this.attributes.delete(name)
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null
  }
}

globalThis.HTMLDetailsElement = DetailsElement

function eventFor(current, replacement) {
  return {
    target: current,
    detail: { newElement: replacement }
  }
}

test("copies open details state to Turbo morph replacements with the same persistence key", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const current = new DetailsElement({ key: "smart-folders-more-job", open: true })
  const replacement = new DetailsElement({ key: "smart-folders-more-job", open: false })

  controller.preserveDetailsState(eventFor(current, replacement))

  assert.equal(replacement.open, true)
  assert.equal(replacement.getAttribute("open"), "")
})

test("copies closed details state to matching Turbo morph replacements", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const current = new DetailsElement({ key: "smart-folders-more-job", open: false })
  const replacement = new DetailsElement({ key: "smart-folders-more-job", open: true })

  controller.preserveDetailsState(eventFor(current, replacement))

  assert.equal(replacement.open, false)
  assert.equal(replacement.getAttribute("open"), null)
})

test("does not copy details state to a different disclosure", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const current = new DetailsElement({ key: "smart-folders-more-job", open: true })
  const replacement = new DetailsElement({ key: "smart-folders-more-workflow", open: false })

  controller.preserveDetailsState(eventFor(current, replacement))

  assert.equal(replacement.open, false)
  assert.equal(replacement.getAttribute("open"), null)
})

test("allows details persistence to be disabled per element", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const current = new DetailsElement({ key: "server-owned", open: true, persistence: "false" })
  const replacement = new DetailsElement({ key: "server-owned", open: false })

  controller.preserveDetailsState(eventFor(current, replacement))

  assert.equal(replacement.open, false)
  assert.equal(replacement.getAttribute("open"), null)
})
