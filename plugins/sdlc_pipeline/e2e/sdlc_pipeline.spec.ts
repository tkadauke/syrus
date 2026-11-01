import { expect, test } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"
import { expectNativePluginSurface } from "../../../e2e/support/pluginNativeUi"

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

  const pipeline = page.getByRole("region", { name: "Repository SDLC pipeline" })
  await expect(pipeline.getByRole("region", { name: "Pipeline stages" })).toBeVisible()
  await expect(pipeline.getByRole("button", { name: "Next pipeline stages" })).toBeVisible()
  expect(await pipeline.getByRole("link", { name: "Job" }).count()).toBeLessThanOrEqual(5 * (await pipeline.locator("[data-stage]").count()))
  await expect(pipeline.locator('[draggable="true"]')).toHaveCount(0)
  const stage = pipeline.locator("[data-stage]").first()
  await stage.getByRole("button").first().click()
  await expect(page.getByRole("dialog")).toBeVisible()
  await expect(page.getByText(/read-only overview|cannot be changed from the pipeline/)).toBeVisible()
})
