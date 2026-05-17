import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/bug_report_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace('import html2canvas from "html2canvas"', "const html2canvas = () => {}")
    .replace("export default class extends Controller", "class BugReportController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default BugReportController`)}`)
}

class FakeDataTransfer {
  constructor() {
    this.files = []
    this.items = {
      add: (file) => this.files.push(file)
    }
  }
}

class FakeFormData {
  constructor(form) {
    this.form = form
  }
}

function buildController(Controller, { capture = { name: "bug-report-viewport.png" }, existingFiles = [], noneChecked = false } = {}) {
  let closed = false
  const controller = new Controller()
  controller.captures = { viewport: capture }
  controller.formTarget = { action: "/bug_reports", method: "post" }
  controller.dialogTarget = {
    close() {
      closed = true
    }
  }
  controller.viewportRadioTarget = { checked: !noneChecked }
  controller.fullPageRadioTarget = { checked: false }
  controller.noneRadioTarget = { checked: noneChecked }
  // Stimulus auto-generates hasXTarget when target X is declared.
  // The bare new Controller() doesn't get that wiring, so mock it
  // explicitly — the controller branches on it to decide whether
  // the "no screenshot" radio is in scope.
  controller.hasNoneRadioTarget = true
  controller.screenshotInputTarget = { files: existingFiles, value: "existing" }

  return { controller, wasClosed: () => closed }
}

globalThis.DataTransfer = FakeDataTransfer
globalThis.FormData = FakeFormData

function resetBrowserStubs() {
  globalThis.window = { alert() {} }
  globalThis.document = {
    querySelector(selector) {
      if (selector === "meta[name='csrf-token']") return { content: "csrf-token" }
      if (selector === "main") return { prepend() {} }
      return null
    },
    getElementById() {
      return null
    },
    createElement() {
      return { dataset: {} }
    }
  }
  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({ message: "Bug report queued." })
  })
}

test("submits a valid bug report without navigating away", async () => {
  resetBrowserStubs()
  const { default: Controller } = await loadController()
  const { controller, wasClosed } = buildController(Controller)
  let prevented = false
  let request = null
  globalThis.fetch = async (url, options) => {
    request = { url, options }
    return {
      ok: true,
      json: async () => ({ message: "Bug report queued." })
    }
  }

  await controller.submit({
    preventDefault() {
      prevented = true
    }
  })

  assert.equal(prevented, true)
  assert.equal(wasClosed(), true)
  assert.equal(controller.screenshotInputTarget.files.length, 1)
  assert.equal(request.url, "/bug_reports")
  assert.equal(request.options.method, "POST")
  assert.equal(request.options.headers.Accept, "application/json")
  assert.equal(request.options.headers["X-CSRF-Token"], "csrf-token")
})

test("clears the screenshot and closes when no screenshot is selected", async () => {
  resetBrowserStubs()
  const { default: Controller } = await loadController()
  const { controller, wasClosed } = buildController(Controller, { noneChecked: true })
  let prevented = false

  await controller.submit({
    preventDefault() {
      prevented = true
    }
  })

  assert.equal(prevented, true)
  assert.equal(wasClosed(), true)
  assert.equal(controller.screenshotInputTarget.value, "")
})

test("allows submit when no screenshot is explicitly selected", async () => {
  resetBrowserStubs()
  const { default: Controller } = await loadController()
  const { controller, wasClosed } = buildController(Controller, { capture: null })
  controller.noneRadioTarget.checked = true
  let prevented = false

  await controller.submit({
    preventDefault() {
      prevented = true
    }
  })

  assert.equal(prevented, true)
  assert.equal(wasClosed(), true)
  assert.equal(controller.screenshotInputTarget.value, "")
})
