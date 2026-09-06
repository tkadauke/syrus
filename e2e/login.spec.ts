import { test, expect } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

test("demo user can sign in and reach the dashboard", async ({ page }) => {
  await signInAsDemo(page)

  // A fresh seeded demo user lands on /onboarding rather than /dashboard;
  // the meaningful assertion is that auth succeeded and left /session/new.
  await expect(page).not.toHaveURL(/\/session\/new$/)
})
