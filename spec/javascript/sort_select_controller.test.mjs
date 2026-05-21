import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/sort_select_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class SortSelectController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default SortSelectController`)}`)
}

test("navigates to the current URL with selected sort params", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  controller.element = { value: "state:asc" }
  globalThis.location = { href: "http://example.test/dashboard/epics?subject=epic&view=list&page=2" }

  controller.change()

  assert.equal(
    globalThis.location.href,
    "http://example.test/dashboard/epics?subject=epic&view=list&page=2&sort_column=state&sort_direction=asc"
  )
})
