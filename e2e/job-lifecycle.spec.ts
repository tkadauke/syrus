import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

// Exercises Job lifecycle beyond creation using the seeded demo/syrus-preview
// fixture data from db/seeds.rb (no worker process runs here, so these only
// drive the deterministic state-transition endpoints, never a real agent
// Run). Each test targets a distinct seeded Job so the three can run in any
// order without interfering with one another.

async function dashboardRowFor(page: Page, title: string) {
  await page.goto("/dashboard/jobs?ownership_scope=team&view=list")
  // The default "Inbox" preset hides closed/approved/running Jobs; removing
  // it is what makes every seeded Job -- regardless of the state a prior
  // action just moved it to -- show up in the list.
  await page.getByRole("button", { name: "Remove Preset filter" }).click()

  return page.getByRole("row").filter({ has: page.getByRole("link", { name: title, exact: true }) })
}

test("approves an implemented job and reflects it in the dashboard", async ({ page }) => {
  await signInAsDemo(page)

  const title = "Inspect preview dashboard states"
  await page.goto("/jobs/1")
  await expect(page.getByRole("heading", { level: 1 })).toContainText(title)

  await page.getByRole("button", { name: "Approve", exact: true }).click()

  await expect(page.getByText("Job approved.")).toBeVisible()
  await expect(page.getByRole("button", { name: "Approve", exact: true })).toHaveCount(0)

  const row = await dashboardRowFor(page, title)
  await expect(row).toContainText("approved")
})

test("retries a failed job from its failed step and reflects it in the dashboard", async ({ page }) => {
  await signInAsDemo(page)

  const title = "Repair seeded background workflow"
  await page.goto("/jobs/2")
  await expect(page.getByRole("heading", { level: 1 })).toContainText(title)
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
  await page.goto("/jobs/4")
  await expect(page.getByRole("heading", { level: 1 })).toContainText(title)
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
