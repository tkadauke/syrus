import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"
import { jobsListRow } from "./support/dashboard"

test.slow()

async function openImplementedDemoJob(page: Page) {
  const title = "Inspect preview dashboard states"

  const row = await jobsListRow(page, title)
  await row.getByRole("link", { name: title, exact: true }).click()
  await expect(page.getByRole("heading", { level: 1 })).toContainText(title)
}

test("covers review diff, coverage, diff comments, and workflow warning action", async ({ page }) => {
  const commentBody = `E2E review note: verify the seeded diff quality gate ${Date.now()}`

  await signInAsDemo(page)
  await openImplementedDemoJob(page)

  await page.getByRole("button", { name: "Review", exact: true }).click()
  await expect(page.getByRole("heading", { name: "Implementation review" })).toBeVisible()
  await expect(page.getByText(/changed files/)).toBeVisible()
  await expect(page.getByText("app/services/dashboard_payload.rb").first()).toBeVisible()
  await expect(page.getByText("app/frontend/routes/Dashboard.tsx").first()).toBeVisible()
  await expect(page.getByText("needs_attention_count").first()).toBeVisible()

  await page.locator("[data-testid='diff-file-scroll']").first().evaluate((scrollRegion) => {
    const codeCell = scrollRegion.querySelector("td.whitespace-pre")
    if (!codeCell) throw new Error("diff code cell not found")
    codeCell.textContent = "very_wide_diff_line_" + "x".repeat(360)
  })
  await page.getByRole("button", { name: /^Comment on / }).first().click({ force: true })

  const viewportWidth = page.viewportSize()?.width ?? 1280
  const layout = await page.evaluate(() => {
    const scroller = document.querySelector("[data-testid='diff-file-scroll']")?.getBoundingClientRect()
    const composer = document.querySelector("[data-testid='diff-review-composer'] textarea")?.getBoundingClientRect()
    const grid = document.querySelector("[data-testid='agent-diff-viewer']")?.closest(".grid")
    const sidebar = grid ? Array.from(grid.children).at(-1)?.getBoundingClientRect() : null

    return {
      bodyScrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
      composerRight: composer?.right ?? 0,
      composerWidth: composer?.width ?? 0,
      scrollerWidth: scroller?.width ?? 0,
      sidebarRight: sidebar?.right ?? 0,
      sidebarWidth: sidebar?.width ?? 0
    }
  })

  expect(layout.bodyScrollWidth).toBeLessThanOrEqual(layout.clientWidth + 1)
  expect(layout.sidebarRight).toBeLessThanOrEqual(viewportWidth + 1)
  expect(layout.sidebarWidth).toBeLessThanOrEqual(384)
  expect(layout.composerRight).toBeLessThanOrEqual(viewportWidth + 1)
  expect(layout.composerWidth).toBeLessThanOrEqual(layout.scrollerWidth + 1)
  await page.getByRole("button", { name: "Cancel" }).click()

  await page.getByLabel("Whole-review comment").fill(commentBody)
  await page.getByRole("button", { name: "Comment", exact: true }).click()
  // The "Whole-review comment" label belongs to the composer, which closes on
  // save; the posted comment itself is what survives.
  await expect(page.getByText(commentBody)).toBeVisible()

  await page.getByRole("button", { name: "Summary", exact: true }).click()
  const coverage = page.getByTestId("coverage-card")
  await expect(coverage).toContainText("Coverage")
  await expect(coverage).toContainText("Lines")
  await expect(coverage).toContainText("87.1%")
  await expect(coverage).toContainText("PR delta:")
  await expect(coverage).toContainText("12/15 changed lines covered")
  await coverage.getByRole("button", { name: "Show 2 files" }).click()
  await expect(coverage).toContainText("app/services/dashboard_payload.rb")
  await expect(coverage).toContainText("app/frontend/routes/Dashboard.tsx")

  await page.getByRole("button", { name: /^Workflows \(\d+\)$/ }).click()
  await page.getByRole("button", { name: /Implement/i }).click()
  await expect(page.getByText("Branch coverage 70.2% is below the 75% threshold")).toBeVisible()
  await expect(page.getByRole("button", { name: "File a fix Job" })).toBeVisible()
})
