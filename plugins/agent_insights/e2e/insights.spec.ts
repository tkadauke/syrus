import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in admin can enable Agent Insights and view a generated insight report", async ({ page }) => {
  await signInAsDemo(page)

  // Toggle from the plugin's own page rather than its card in the list. The
  // card's heading is a link to this page, and enabling re-renders the list
  // underneath the cursor, so the click lands on the link often enough to
  // matter -- and then the assertion waits for a card that is no longer on
  // screen.
  await page.goto("/admin/plugins/agent_insights")
  // The page renders its own h1 and the plugin's docs render another.
  await expect(page.getByRole("heading", { name: "Agent Insights", level: 1 }).first()).toBeVisible()

  const enableButton = page.getByRole("button", { name: "Enable", exact: true })
  const disableButton = page.getByRole("button", { name: "Disable", exact: true })

  if (await enableButton.isVisible()) {
    await enableButton.click()
    // Enabling reloads the whole page, and a cold dev-mode render of this
    // app can take the better part of a minute.
    await page.waitForLoadState("load")
  }
  await expect(disableButton).toBeVisible({ timeout: 60_000 })

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()

  await page.getByRole("link", { name: /Insights/ }).click()
  await expect(page.getByRole("heading", { name: "Suggestions" })).toBeVisible()

  await expect(page.getByText("Repair workflows keep failing at the same implement step")).toBeVisible()
  await expect(page.getByText("repeated_failure")).toBeVisible()
})
