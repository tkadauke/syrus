import { expect, type Page } from "@playwright/test"

export async function expectNativePluginSurface(page: Page, headingName: string | RegExp) {
  await expect(page.getByRole("heading", { name: headingName }).first()).toBeVisible()
  await expect(page.getByRole("heading", { name: /Page unavailable|Tab unavailable/ })).toHaveCount(0)
  await expect(page.getByText(/plugin_pages\.|sidebar_pages\.|plugin_repo_tabs\./)).toHaveCount(0)

  await page.evaluate(() => document.documentElement.classList.add("dark"))
  await expect(page.getByRole("heading", { name: headingName }).first()).toBeVisible()
  await page.evaluate(() => document.documentElement.classList.remove("dark"))
}
