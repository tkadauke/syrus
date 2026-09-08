import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in admin can enable Agent Insights and view a generated insight report", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/admin/plugins")
  await expect(page.getByRole("heading", { name: "Plugins" })).toBeVisible()

  const pluginCard = page.locator("article").filter({ has: page.getByRole("heading", { name: "Agent Insights" }) })
  await expect(pluginCard).toBeVisible()

  const enableButton = pluginCard.getByRole("button", { name: "Enable", exact: true })
  const disableButton = pluginCard.getByRole("button", { name: "Disable", exact: true })

  // Enabling reloads the page (PluginCard's toggle mutation calls a full
  // page reload on success), so wait for the button label to flip instead
  // of racing a SPA navigation event.
  if (await enableButton.isVisible()) {
    await enableButton.click()
    await expect(disableButton).toBeVisible()
  } else {
    await expect(disableButton).toBeVisible()
  }

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()

  await page.getByRole("link", { name: /Insights/ }).click()
  await expect(page.getByRole("heading", { name: "Suggestions" })).toBeVisible()

  await expect(page.getByText("Repair workflows keep failing at the same implement step")).toBeVisible()
  await expect(page.getByText("repeated_failure")).toBeVisible()
})
