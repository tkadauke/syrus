import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"
import { jobsListRow } from "./support/dashboard"

test.slow()

async function dashboardRowFor(page: Page, title: string) {
  return jobsListRow(page, title)
}

async function openJob(page: Page, title: string) {
  const row = await dashboardRowFor(page, title)
  await row.getByRole("link", { name: title, exact: true }).click()
  await expect(page.getByRole("heading", { level: 1 })).toContainText(title)
}

async function openLandingQueue(page: Page) {
  await page.goto("/dashboard/jobs?ownership_scope=team&view=list")
  await page.getByRole("link", { name: /^Landing queue \d+$/ }).click()
  // The queue-position column, whose sortable header is labelled
  // "Sort by <label> <direction>" (dashboard.sort_by). There is no separate
  // "Queue status" column any more: JobsTable filters landing_queue_wait_reason
  // out and shows blocker messaging on the rows instead, which the tests below
  // assert.
  await expect(page.getByRole("columnheader", { name: /^Sort by Queue/ })).toBeVisible()
}

test("renders approved and landing queue states with blocker messaging", async ({ page }) => {
  await signInAsDemo(page)

  await openJob(page, "Approve trigger label rollout")
  await expect(page.getByText(/In landing queue/)).toBeVisible()
  await expect(page.getByText(/Auto-merge not enabled/)).toBeVisible()
  await expect(page.getByRole("link", { name: "Enable auto-merge in repository settings" })).toBeVisible()

  await openLandingQueue(page)

  const approvedRow = page.getByRole("row").filter({ has: page.getByRole("link", { name: "Approve trigger label rollout", exact: true }) })
  await expect(approvedRow).toContainText("Auto-merge not enabled")

  const landingRow = page.getByRole("row").filter({ has: page.getByRole("link", { name: "Land approval queue fixture", exact: true }) })
  await expect(landingRow).toContainText("landing")
  await expect(landingRow).toContainText(/#\d+/)
})

test("pauses and resumes landing from the landing queue view", async ({ page }) => {
  await signInAsDemo(page)
  await openLandingQueue(page)

  // Pausing asks for confirmation first (resuming does not).
  await page.getByRole("button", { name: "Pause landing" }).click()
  await page.getByRole("dialog").getByRole("button", { name: "Pause landing" }).click()
  await expect(page.getByText("Landing paused.")).toBeVisible()
  await expect(page.getByRole("button", { name: "Resume landing" })).toBeVisible()

  await page.getByRole("button", { name: "Resume landing" }).click()
  await expect(page.getByText("Landing resumed.")).toBeVisible()
  await expect(page.getByRole("button", { name: "Pause landing" })).toBeVisible()
})
