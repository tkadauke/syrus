import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

// Exercises Job lifecycle beyond creation using the seeded demo/syrus-preview
// fixture data from db/seeds.rb (no worker process runs here, so these only
// drive the deterministic state-transition endpoints, never a real agent
// Run). Each test targets a distinct seeded Job so the three can run in any
// order without interfering with one another. Jobs are always resolved by
// their seeded title, never by numeric id -- db:prepare never truncates the
// dev database, so a developer who has used bin/dev before running the E2E
// seed for the first time would not have these Jobs land on predictable ids
// (same convention as plugins/test_insights/e2e/test_insights.spec.ts).
//
// Each test drives two full dashboard-list loads (open, then re-verify) on
// top of sign-in and the job-detail page, more page loads than the simpler
// existing specs -- give them extra headroom above the config default so a
// slow first-request cold start under parallel workers doesn't flake them.
test.slow()

async function dashboardRowFor(page: Page, title: string) {
  await page.goto("/dashboard/jobs?ownership_scope=team&view=list")
  // The default "Inbox" preset (a server-supplied "Preset" filter chip on
  // the `attention` field, see app/services/filters/chips/jobs/attention.rb)
  // hides closed/approved/running Jobs; removing it is what makes every
  // seeded Job -- regardless of the state a prior action just moved it to --
  // show up in the list.
  await page.getByRole("button", { name: "Remove Preset filter" }).click()

  return page.getByRole("row").filter({ has: page.getByRole("link", { name: title, exact: true }) })
}

async function openJob(page: Page, title: string) {
  const row = await dashboardRowFor(page, title)
  await row.getByRole("link", { name: title, exact: true }).click()
  await expect(page.getByRole("heading", { level: 1 })).toContainText(title)
}

test("approves an implemented job and reflects it in the dashboard", async ({ page }) => {
  await signInAsDemo(page)

  const title = "Inspect preview dashboard states"
  await openJob(page, title)

  await page.getByRole("button", { name: "Approve", exact: true }).click()

  await expect(page.getByText("Job approved.")).toBeVisible()
  await expect(page.getByRole("button", { name: "Approve", exact: true })).toHaveCount(0)

  const row = await dashboardRowFor(page, title)
  await expect(row).toContainText("approved")
})

test("retries a failed job from its failed step and reflects it in the dashboard", async ({ page }) => {
  await signInAsDemo(page)

  const title = "Repair seeded background workflow"
  await openJob(page, title)
  await expect(page.getByText("failed", { exact: true }).first()).toBeVisible()

  await page.getByRole("button", { name: "Retry failed step" }).click()

  await expect(page.getByText(/Retrying .* for WF-\d+/)).toBeVisible()
  await expect(page.getByRole("button", { name: "Retry failed step" })).toHaveCount(0)

  const row = await dashboardRowFor(page, title)
  await expect(row).toContainText("running")
})

test("cancels a queued job and reflects it in the dashboard", async ({ page }) => {
  await signInAsDemo(page)

  const title = "Coordinate scheduled task rollout"
  await openJob(page, title)
  await expect(page.getByText("queued", { exact: true }).first()).toBeVisible()

  await page.getByRole("button", { name: "⋯" }).click()
  await page.getByRole("menuitem", { name: "Cancel" }).click()

  const dialog = page.getByRole("dialog", { name: "Cancel any running work and close this Job?" })
  await expect(dialog).toBeVisible()
  await dialog.getByRole("button", { name: "Confirm" }).click()

  await expect(page.getByText("Cancellation requested.")).toBeVisible()
  await expect(page.getByRole("button", { name: "Reopen" })).toBeVisible()

  const row = await dashboardRowFor(page, title)
  await expect(row).toContainText("closed")
})
