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

function buildController(Controller, { capture = { name: "bug-report-viewport.png" }, existingFiles = [], noneChecked = false } = {}) {
  let closed = false
  const controller = new Controller()
  controller.captures = { viewport: capture }
  controller.dialogTarget = {
    close() {
      closed = true
    }
  }
  controller.viewportRadioTarget = { checked: !noneChecked }
  controller.fullPageRadioTarget = { checked: false }
  controller.noneRadioTarget = { checked: noneChecked }
  controller.screenshotInputTarget = { files: existingFiles, value: "existing" }

  return { controller, wasClosed: () => closed }
}

globalThis.DataTransfer = FakeDataTransfer

test("closes the dialog after a valid bug report submit starts", async () => {
  const { default: Controller } = await loadController()
  const { controller, wasClosed } = buildController(Controller)
  let prevented = false

  controller.submit({
    preventDefault() {
      prevented = true
    }
  })

  assert.equal(prevented, false)
  assert.equal(wasClosed(), true)
  assert.equal(controller.screenshotInputTarget.files.length, 1)
})

test("clears the screenshot and closes when no screenshot is selected", async () => {
  const { default: Controller } = await loadController()
  const { controller, wasClosed } = buildController(Controller, { noneChecked: true })
  let prevented = false

  controller.submit({
    preventDefault() {
      prevented = true
    }
  })

  assert.equal(prevented, false)
  assert.equal(wasClosed(), true)
  assert.equal(controller.screenshotInputTarget.value, "")
})

test("allows submit when no screenshot is explicitly selected", async () => {
  const { default: Controller } = await loadController()
  const { controller, wasClosed } = buildController(Controller, { capture: null })
  controller.noneRadioTarget.checked = true
  let prevented = false

  controller.submit({
    preventDefault() {
      prevented = true
    }
  })

  assert.equal(prevented, false)
  assert.equal(wasClosed(), true)
  assert.equal(controller.screenshotInputTarget.value, "")
})
