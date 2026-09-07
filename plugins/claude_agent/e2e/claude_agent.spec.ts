import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user can view Claude's credential status and select it as the agent provider", async ({ page }) => {
  await signInAsDemo(page)

  // Credential-configured state: the demo user's default agent_provider is
  // codex (see db/seeds.rb), so the Claude card should read as not connected.
  await page.goto("/credentials")
  await expect(page.getByRole("heading", { name: "Credentials" })).toBeVisible()

  const claudeCard = page.getByTestId("credential-card-claude")
  await expect(claudeCard).toBeVisible()
  await expect(claudeCard.getByRole("heading", { name: "Claude" })).toBeVisible()
  await expect(claudeCard.getByText("Not set")).toBeVisible()
  await expect(claudeCard.getByRole("button", { name: "Connect Claude" })).toBeVisible()

  // Provider selection: the Agent Settings page lets the operator pick Claude
  // as their default agent provider.
  await page.goto("/settings/agent")
  await expect(page.getByRole("heading", { name: "Agent Settings" })).toBeVisible()

  const providerSelect = page.getByLabel("Agent provider")
  await expect(providerSelect.locator("option", { hasText: "Claude" })).toHaveCount(1)
  const originalProvider = await providerSelect.inputValue()

  await providerSelect.selectOption({ label: "Claude" })
  await page.getByRole("button", { name: "Save", exact: true }).click()

  await expect(page.getByText("Agent settings updated.")).toBeVisible()
  await expect(providerSelect).toHaveValue("claude")

  // Restore the demo user's original provider so other specs relying on the
  // seeded default aren't affected by this run.
  await providerSelect.selectOption(originalProvider)
  await page.getByRole("button", { name: "Save", exact: true }).click()
  await expect(page.getByText("Agent settings updated.")).toBeVisible()
})
