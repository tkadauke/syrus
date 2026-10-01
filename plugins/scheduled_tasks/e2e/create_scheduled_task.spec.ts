import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user can create a scheduled task", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/scheduled_tasks/new")

  // Exact: the sidebar's new-chat repository selector also matches a loose
  // "Repository" label (plus its "Remove repository from new chat" button), so
  // a non-exact match resolves to three elements and fails strict mode.
  const repositoryPicker = page.getByLabel("Repository", { exact: true })
  await repositoryPicker.selectOption({ label: "demo/syrus-preview" })
  const continueButton = page.getByRole("button", { name: "Continue", exact: true })
  await expect(continueButton).toBeEnabled()
  await continueButton.click()

  const name = `E2E smoke ${Date.now()}`
  await page.getByLabel("Name").fill(name)
  await page.getByLabel("Cadence").fill("Every Monday at 9:00 AM")
  await page.getByRole("textbox", { name: /prompt/i }).fill("Post a status update.")
  await page.getByRole("button", { name: "Create task", exact: true }).click()

  await expect(page).not.toHaveURL(/\/scheduled_tasks\/new$/)
  await expect(page.getByText(name)).toBeVisible()
})
