import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user can view the Mockups sidebar list and open a published mockup", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/mockups")
  await expect(page.getByRole("heading", { name: "Mockups", level: 1 })).toBeVisible()

  // Seeded in db/seeds.rb via PreviewPanel::Service + Mockups::Mockup.record_publish! --
  // mockups only come to exist through chat's show_preview MCP tool, so there is no
  // in-app "create mockup" action for this test to drive itself.
  const listEntry = page.getByRole("button", { name: /Dashboard onboarding sketch/ })
  await expect(listEntry).toBeVisible()
  await expect(listEntry.getByText("1 files")).toBeVisible()

  await listEntry.click()
  await expect(page).toHaveURL(/\/mockups\/(MOCKUP-\d+)$/)

  const previewPanel = page.getByLabel("Mockup preview")
  await expect(previewPanel).toBeVisible()
  await expect(previewPanel.getByText("Dashboard onboarding sketch")).toBeVisible()
  await expect(previewPanel.getByText("index.html")).toBeVisible()
  await expect(previewPanel.getByRole("link", { name: "Download" })).toBeVisible()

  // Reload to prove the selection (and the underlying mockup) persists server-side,
  // not just in client-side navigation state.
  await page.reload()
  await expect(page.getByLabel("Mockup preview").getByText("Dashboard onboarding sketch")).toBeVisible()
})
