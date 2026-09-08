import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user can view failing, flaky, and slow tests on a repository's Tests tab", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()

  await page.getByRole("navigation", { name: "Repository tabs" }).getByRole("link", { name: "Tests", exact: true }).click()

  // level: 1 disambiguates from the pinned chat's own "demo/syrus-preview"
  // heading (level 2) rendered in the sidebar's "Recent chats" nav.
  await expect(page.getByRole("heading", { name: "demo/syrus-preview", level: 1 })).toBeVisible()
  await expect(page.getByText("Interesting tests")).toBeVisible()

  const failingRow = page.locator("tr").filter({ has: page.getByRole("link", { name: "raises when the discount exceeds the order total" }) })
  await expect(failingRow).toBeVisible()
  await expect(failingRow.getByText("failing", { exact: true })).toBeVisible()

  const flakyRow = page.locator("tr").filter({ has: page.getByRole("link", { name: "retries once before giving up on a flaky webhook delivery" }) })
  await expect(flakyRow).toBeVisible()
  await expect(flakyRow.getByText("flaky", { exact: true })).toBeVisible()

  const slowRow = page.locator("tr").filter({ has: page.getByRole("link", { name: "renders the full dashboard summary payload" }) })
  await expect(slowRow).toBeVisible()
  await expect(slowRow.getByText("slow", { exact: true })).toBeVisible()

  // Drill into the slow test's detail view to confirm its run history and
  // duration chart render from the same seeded fixture data.
  await slowRow.getByRole("link", { name: "renders the full dashboard summary payload" }).click()

  await expect(page.getByRole("heading", { name: "renders the full dashboard summary payload", level: 2 })).toBeVisible()
  await expect(page.getByText("Duration over time")).toBeVisible()
})
