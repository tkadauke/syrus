import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in admin views the Build Cache admin page and a Job's cache hit-rate card", async ({ page }) => {
  await signInAsDemo(page)

  // Preview environments never configure SCCACHE_BUCKET (no S3-compatible
  // bucket available), so the admin page's real default state is "not
  // configured" -- that is itself worth exercising rather than faking a
  // bucket just to reach a happier-looking screen.
  await page.goto("/admin/build_cache")

  const main = page.getByRole("main", { name: "Admin build cache" })
  await expect(main.getByRole("heading", { name: "Build Cache", level: 1 })).toBeVisible()
  await expect(main.getByText("Inspect and clear the shared sccache compiler-cache bucket.")).toBeVisible()
  await expect(main.getByText(/SCCACHE_BUCKET is unset/)).toBeVisible()
  await expect(page.getByTestId("build-cache-stats")).not.toBeVisible()

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
