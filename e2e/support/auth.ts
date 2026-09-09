import { expect, type Page } from "@playwright/test"

export const DEMO_USER = {
  email: "demo@syrus.local",
  password: "password"
}

export const ONBOARDING_USER = {
  email: "onboarding@syrus.local",
  password: "password"
}

export const INVITED_USER = {
  email: "invited-e2e@syrus.local",
  password: "password"
}

export const INVITATION_TOKEN = "e2e-invitation-token-0001"

export async function signIn(page: Page, user: { email: string; password: string }) {
  await page.goto("/session/new")
  await page.getByLabel(/email/i).fill(user.email)
  await page.getByLabel(/password/i).fill(user.password)
  await page.getByRole("button", { name: "Sign in", exact: true }).click()
  await page.waitForURL((url) => !url.pathname.endsWith("/session/new"))
}

export async function signInAsDemo(page: Page) {
  await signIn(page, DEMO_USER)
}

export async function signOut(page: Page, email: string) {
  await page.getByRole("button", { name: email }).click()
  await page.getByRole("button", { name: "Sign out" }).click()
  await expect(page).toHaveURL(/\/session\/new$/)
}
