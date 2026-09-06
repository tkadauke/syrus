import { test, expect } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

test("signed-in user can create a direct Job", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/jobs/new")

  await page.getByLabel(/repository/i).selectOption({ label: "demo/syrus-preview" })

  const title = `E2E smoke ${Date.now()}`
  await page.getByLabel("Title").fill(title)
  await page.getByPlaceholder(/describe what you want the agent to do/i).fill("Say hello in the PR description.")
  await page.getByRole("button", { name: "Create job", exact: true }).click()

  await expect(page).not.toHaveURL(/\/jobs\/new$/)
  await expect(page.getByText(title)).toBeVisible()
})
