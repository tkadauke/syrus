import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

test.slow()

async function openImplementedDemoJob(page: Page) {
  const title = "Inspect preview dashboard states"

  await page.goto("/dashboard/jobs?ownership_scope=team&view=list")
  await page.getByRole("button", { name: "Remove Preset filter" }).click()
  await page.getByRole("row").filter({ has: page.getByRole("link", { name: title, exact: true }) }).getByRole("link", { name: title, exact: true }).click()
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

  await page.getByLabel("Whole-review comment").fill(commentBody)
  await page.getByRole("button", { name: "Comment", exact: true }).click()
  await expect(page.getByText(commentBody)).toBeVisible()
  await expect(page.getByText("Whole-review comment")).toBeVisible()

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
