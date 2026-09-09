import { test, expect } from "@playwright/test"
import { signInAsDemo, signOut } from "./support/auth"

test("demo user can sign in, reach the dashboard, and sign out", async ({ page }) => {
  await signInAsDemo(page)

  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible()

  await signOut(page, "demo@syrus.local")
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible()
})
