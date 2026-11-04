import { expect, test } from "@playwright/test"
import { mkdirSync } from "node:fs"
import path from "node:path"
import { signInAsDemo } from "../../../e2e/support/auth"
import { expectNativePluginSurface } from "../../../e2e/support/pluginNativeUi"

const SCREENSHOT_DIR = path.join(process.cwd(), "tmp", "visual-review")

test("SDLC Pipeline repository tab is aggregate-first and drills into a bounded stage", async ({ page }) => {
  await signInAsDemo(page)
  await page.goto("/admin/plugins")
  const card = page
    .getByRole("region", { name: "Registered plugins" })
    .locator("article")
    .filter({ has: page.getByRole("heading", { name: "SDLC Pipeline", exact: true }) })
  const enable = card.getByRole("button", { name: "Enable" })
  if (await enable.isVisible()) {
    await enable.click()
    await page.waitForLoadState("load")
    await expect(card.getByRole("button", { name: "Disable" })).toBeVisible({ timeout: 60_000 })
  }

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()
  await page.getByRole("link", { name: "Pipeline" }).click()
  await expectNativePluginSurface(page, "SDLC Pipeline")

  const pipeline = page.getByRole("main", { name: "Repository SDLC pipeline" })
  await expect(pipeline.getByRole("region", { name: "Pipeline stages" })).toBeVisible()
  await expect(pipeline.getByRole("button", { name: "Next pipeline stages" })).toBeVisible()
  await expect(pipeline.getByRole("slider", { name: "Historical time", exact: true })).toBeVisible()
  await pipeline.getByText("Options").click()
  await expect(pipeline.getByTestId("pipeline-time-rail").getByLabel("History window")).toBeVisible()
  await pipeline.getByText("Options").click()
  await expect(pipeline.getByRole("button", { name: "Play", exact: true })).toBeVisible()
  await expect(pipeline.getByTestId("pipeline-time-rail")).toBeVisible()
  const initialStageCount = await pipeline.locator("[data-stage]").count()
  const firstEvent = pipeline.getByTestId("history-event-track").getByRole("button").first()
  await expect(firstEvent).toBeVisible()
  await firstEvent.click()
  await expect(page).toHaveURL(/(?:\?|&)at=/)
  await expect(pipeline.locator("[data-stage]")).toHaveCount(initialStageCount)
  await expect(pipeline.getByText(/Past/)).toBeVisible()
  const desktopStageBox = await pipeline.locator("[data-stage]").first().boundingBox()
  expect(desktopStageBox).not.toBeNull()
  expect(desktopStageBox!.y).toBeGreaterThanOrEqual(0)
  expect(desktopStageBox!.y + Math.min(desktopStageBox!.height, 80)).toBeLessThanOrEqual(page.viewportSize()!.height)
  mkdirSync(SCREENSHOT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, "pipeline-history-desktop.png"), fullPage: false })
  expect(await pipeline.getByRole("link", { name: "Job" }).count()).toBeLessThanOrEqual(5 * (await pipeline.locator("[data-stage]").count()))
  await expect(pipeline.locator('[draggable="true"]')).toHaveCount(0)
  // Drill-down is only available for the live pipeline, not a reconstructed past.
  await pipeline.getByTestId("pipeline-time-rail").getByRole("button", { name: "Return to now" }).click()
  await expect(page).not.toHaveURL(/(?:\?|&)at=/)
  const stage = pipeline.locator("[data-stage]").first()
  await stage.getByRole("button").first().click()
  await expect(page.getByRole("dialog")).toBeVisible()
  await expect(page.getByText(/read-only overview|cannot be changed from the pipeline/)).toBeVisible()
})

test("SDLC Pipeline keeps a stage beside the time rail at 390px", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await signInAsDemo(page)
  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()
  await page.getByRole("link", { name: "Pipeline" }).click()

  const pipeline = page.getByRole("main", { name: "Repository SDLC pipeline" })
  const rail = pipeline.getByTestId("pipeline-time-rail")
  const stage = pipeline.locator("[data-stage]").first()
  await expect(rail).toBeVisible()
  await expect(stage).toBeVisible()
  // Exactly one history navigator and one window selector at narrow widths.
  await expect(pipeline.getByTestId("pipeline-time-rail")).toHaveCount(1)
  await expect(pipeline.getByTestId("compact-pipeline-time-rail")).toHaveCount(0)
  await expect(pipeline.getByLabel(/History window/)).toHaveCount(1)
  const [railBox, stageBox] = await Promise.all([rail.boundingBox(), stage.boundingBox()])
  expect(railBox).not.toBeNull()
  expect(stageBox).not.toBeNull()
  expect(stageBox!.y).toBeGreaterThanOrEqual(0)
  expect(stageBox!.y + Math.min(stageBox!.height, 80)).toBeLessThanOrEqual(844)
  expect(stageBox!.x).toBeGreaterThanOrEqual(railBox!.x + railBox!.width - 1)
  mkdirSync(SCREENSHOT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, "pipeline-history-mobile.png"), fullPage: false })
})

for (const size of [
  { width: 390, height: 844 },
  { width: 402, height: 812 }
]) {
  test(`SDLC Pipeline shows distinct history states at ${size.width}px`, async ({ page }) => {
    await page.setViewportSize(size)
    await signInAsDemo(page)
    let mode: "pending" | "error" | "empty" = "pending"
    await page.route("**/sdlc_pipeline*history=1*", async (route) => {
      if (mode === "pending") return new Promise(() => {})
      if (mode === "error") return route.fulfill({ status: 500, body: "{}" })
      const response = await route.fetch({ url: route.request().url().replace("history=1", "history=0") })
      const body = await response.json()
      const now = new Date().toISOString()
      return route.fulfill({
        response,
        json: {
          ...body,
          history: {
            from: now,
            to: now,
            checkpoint: { at: now, placements: [] },
            deltas: [],
            ticks: [],
            traces: [],
            accuracy: { status: "reconstructed", message: "", truncated: false }
          }
        }
      })
    })
    await page.goto("/repositories")
    await page.getByRole("link", { name: "demo/syrus-preview" }).click()
    await page.getByRole("link", { name: "Pipeline" }).click()
    const pipeline = page.getByRole("main", { name: "Repository SDLC pipeline" })
    await expect(pipeline.locator("[data-stage]").first()).toBeVisible()
    await expect(pipeline.getByTestId("history-status")).toHaveAttribute("data-history-status", "loading")
    mode = "error"
    await page.reload()
    await expect(pipeline.getByTestId("history-status")).toHaveAttribute("data-history-status", "error")
    await expect(pipeline.locator("[data-stage]").first()).toBeVisible()
    mode = "empty"
    await pipeline.getByRole("button", { name: "Retry history" }).click()
    await expect(pipeline.getByTestId("history-status")).toHaveAttribute("data-history-status", "empty")
    await expect(pipeline.getByTestId("pipeline-time-rail")).toHaveCount(1)
  })
}
