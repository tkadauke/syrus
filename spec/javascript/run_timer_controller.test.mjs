import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/run_timer_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class RunTimerController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default RunTimerController`)}`)
}

test("updates elapsed time without calculating remaining time", async () => {
  const { default: Controller } = await loadController()
  const controller = new Controller()
  const realNow = Date.now

  try {
    Date.now = () => new Date("2026-05-23T12:01:05Z").getTime()
    controller.startedAtValue = "2026-05-23T12:00:00Z"
    controller.hasElapsedTarget = true
    controller.elapsedTarget = { textContent: "" }

    controller.tick()

    assert.equal(controller.elapsedTarget.textContent, "1m 5s")
    assert.equal("estimatedSecondsValue" in controller, false)
  } finally {
    Date.now = realNow
  }
})
