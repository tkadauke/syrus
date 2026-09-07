import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user can view the Team Directory and open the seeded demo user's profile", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/profiles")
  await expect(page.getByRole("heading", { name: "Team directory", level: 1 })).toBeVisible()

  // The directory only lists profiles once there are 2+ users (see
  // db/seeds.rb's "ada@syrus.local" teammate); below that it collapses to a
  // single-user message instead of a list.
  const demoCard = page.locator("article").filter({ hasText: "Demo Operator" })
  await expect(demoCard).toBeVisible()
  await expect(demoCard.getByText("Admin", { exact: true })).toBeVisible()

  await demoCard.getByRole("link", { name: "Demo Operator" }).click()
  await expect(page).toHaveURL(/\/profiles\/\d+$/)
  await expect(page.getByRole("heading", { name: "Demo Operator", level: 1 })).toBeVisible()
  await expect(page.getByRole("link", { name: "Team directory" })).toBeVisible()

  // Reload to prove the profile route resolves server-side, not just via
  // client-side navigation state from the directory list.
  await page.reload()
  await expect(page.getByRole("heading", { name: "Demo Operator", level: 1 })).toBeVisible()
})
