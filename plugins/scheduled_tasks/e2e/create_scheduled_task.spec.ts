import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user can create a scheduled task", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/scheduled_tasks/new")

  await page.getByLabel("Repository").selectOption({ label: "demo/syrus-preview" })
  await page.getByRole("button", { name: "Continue", exact: true }).click()

  const name = `E2E smoke ${Date.now()}`
  await page.getByLabel("Name").fill(name)
  await page.getByLabel("Cadence").fill("Every Monday at 9:00 AM")
  await page.getByRole("textbox", { name: /prompt/i }).fill("Post a status update.")
  await page.getByRole("button", { name: "Create task", exact: true }).click()

  await expect(page).not.toHaveURL(/\/scheduled_tasks\/new$/)
  await expect(page.getByText(name)).toBeVisible()
})
