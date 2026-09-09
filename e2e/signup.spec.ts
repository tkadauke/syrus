import { test, expect } from "@playwright/test"
import { INVITATION_TOKEN, INVITED_USER, signIn, signOut } from "./support/auth"

test("invitation token signup creates a usable account", async ({ page }) => {
  await page.goto(`/users/new?token=${INVITATION_TOKEN}`)

  await expect(page.getByRole("heading", { name: "Create account" })).toBeVisible()
  await expect(page.getByLabel("Email address")).toHaveValue(INVITED_USER.email)

  await page.getByLabel("Password", { exact: true }).fill(INVITED_USER.password)
  await page.getByLabel("Confirm password").fill(INVITED_USER.password)
  await page.getByRole("button", { name: "Create account" }).click()

  await page.getByRole("button", { name: "Not now" }).click()

  await expect(page).toHaveURL(/\/onboarding$/)
  await expect(page.getByRole("heading", { name: "Set up Syrus" })).toBeVisible()

  await signOut(page, INVITED_USER.email)
  await signIn(page, INVITED_USER)
  await expect(page).toHaveURL(/\/onboarding$/)
})
