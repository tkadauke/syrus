import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in admin views the Build Cache admin page and a Job's cache hit-rate card", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/admin/build_cache")

  const main = page.getByRole("main", { name: "Admin build cache" })
  await expect(main.getByRole("heading", { name: "Build Cache", level: 1 })).toBeVisible()
  await expect(main.getByText("Inspect and clear the shared sccache compiler-cache bucket.")).toBeVisible()
  const notConfiguredNotice = main.getByText(/SCCACHE_BUCKET is unset/)
  const statsCard = page.getByTestId("build-cache-stats")
  await expect(notConfiguredNotice.or(statsCard).first()).toBeVisible()

  if (await notConfiguredNotice.isVisible()) {
    await expect(statsCard).not.toBeVisible()
  } else {
    await expect(statsCard).toBeVisible()
    await expect(statsCard.getByRole("heading", { name: "Bucket footprint" })).toBeVisible()
    await expect(notConfiguredNotice).not.toBeVisible()
  }

  // The per-Job hit/miss card doesn't depend on the bucket being configured
  // -- it renders from a Workflow artifact recorded after a prepare/grader
  // command runs with sccache on PATH, seeded on the demo repository's
  // "Inspect preview dashboard states" job.
  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()

  const recentJobs = page.locator("section").filter({ has: page.getByRole("heading", { name: "Recent jobs" }) })
  await recentJobs.getByRole("link", { name: "Inspect preview dashboard states" }).click()

  await expect(page.getByRole("heading", { level: 1 })).toContainText("Inspect preview dashboard states")

  const sccacheCard = page.getByTestId("sccache-card")
  await expect(sccacheCard).toBeVisible()
  await expect(sccacheCard.getByText("Compiler Cache (sccache)")).toBeVisible()

  const sccacheSummary = page.getByTestId("sccache-summary")
  await expect(sccacheSummary.getByText("42", { exact: true })).toBeVisible()
  await expect(sccacheSummary.getByText("8", { exact: true })).toBeVisible()
  await expect(sccacheSummary.getByText("84.0%")).toBeVisible()
})
