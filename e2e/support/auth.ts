import type { Page } from "@playwright/test"

export async function signInAsDemo(page: Page) {
  await page.goto("/session/new")
  await page.getByLabel(/email/i).fill("demo@syrus.local")
  await page.getByLabel(/password/i).fill("password")
  await page.getByRole("button", { name: "Sign in", exact: true }).click()
  await page.waitForURL((url) => !url.pathname.endsWith("/session/new"))
}
