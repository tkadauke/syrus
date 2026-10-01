import { test, expect } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

test("signed-in user can create a direct Job", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/jobs/new")

  // Exact, not /repository/i: the sidebar's new-chat repository selector is
  // also on this page ("Repository for new chat", plus its "Remove repository
  // from new chat" button), so a loose match resolves to three elements and
  // fails strict mode. The form's own label is exactly "Repository".
  await page.getByLabel("Repository", { exact: true }).selectOption({ label: "demo/syrus-preview" })

  const title = `E2E smoke ${Date.now()}`
  await page.getByLabel("Title").fill(title)
  await page.getByPlaceholder(/describe what you want the agent to do/i).fill("Say hello in the PR description.")
  await page.getByRole("button", { name: "Create job", exact: true }).click()

  await page.waitForURL((url) => !url.pathname.endsWith("/jobs/new"), { timeout: 20_000 })
  await expect(page.getByText(title)).toBeVisible()
})
