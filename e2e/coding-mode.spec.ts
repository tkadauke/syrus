import { test, expect, type Locator, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

test.slow()

async function openCodingModeFixture(page: Page) {
  await signInAsDemo(page)
  await page.getByRole("link", { name: "Coding Mode handoff UI" }).click()
  await expect(page.getByRole("heading", { level: 1 })).toContainText("Coding Mode handoff UI")
}

function pendingActionCard(page: Page, name: string | RegExp): Locator {
  return page.locator("article").filter({ hasText: name })
}

test("enables Coding Mode and shows the writable checkout workspace state", async ({ page }) => {
  await openCodingModeFixture(page)

  await expect(page.getByRole("button", { name: "Change mode" })).toContainText("Planning")
  await expect(page.getByRole("button", { name: "Files" })).toHaveCount(0)

  await page.getByRole("button", { name: "Change mode" }).click()
  await page.getByRole("option", { name: "Coding" }).click()

  await expect(page.getByRole("button", { name: "Change mode" })).toContainText("Coding")
  await expect(page.getByText("Unfinished coding session · uncommitted changes.")).toBeVisible()

  await page.getByRole("button", { name: "Open workspace panel" }).click()
  await expect(page.getByRole("button", { name: "Files" })).toBeVisible()
})

test("renders Coding Mode handoff confirmations and moves one into the pending confirmation UI", async ({ page }) => {
  await openCodingModeFixture(page)

  const existingJobHandoff = pendingActionCard(page, /Hand off JOB-\d+/)
  const submittedChangesHandoff = pendingActionCard(page, "E2E Coding Mode submitted changes")

  await expect(existingJobHandoff).toContainText("Needs confirmation")
  await expect(existingJobHandoff).toContainText("E2E Coding Mode existing Job handoff")
  await expect(submittedChangesHandoff).toContainText("Needs confirmation")
  await expect(submittedChangesHandoff).toContainText("demo/syrus-preview")
  await expect(submittedChangesHandoff).toContainText("Seeded chat-authored work waiting for operator handoff confirmation.")

  await existingJobHandoff.getByRole("button", { name: "Confirm", exact: true }).click()

  await expect(existingJobHandoff).toContainText("Working...")
  await expect(existingJobHandoff).toContainText("Waiting for background worker...")
})
