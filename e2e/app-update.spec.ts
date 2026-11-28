import { expect, test } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

test("announces a revision change and full-loads the next navigation", async ({ page }) => {
  await signInAsDemo(page)
  await page.goto("/dashboard/jobs")

  await page.evaluate(() => {
    const bootstrap = document.getElementById("syrus-bootstrap-data")
    if (bootstrap) bootstrap.textContent = JSON.stringify({ app: { revision: "old-revision" } })
  })
  await page.route("**/api/v1/app/dashboard**", async (route) => {
    const response = await route.fetch()
    await route.fulfill({ response, headers: { ...response.headers(), "X-Syrus-Revision": "new-revision" } })
  })

  await page.getByRole("link", { name: "Epics", exact: true }).click()
  await expect(page).toHaveURL(/\/dashboard\/epics$/)
  await expect(page.getByText("A new version of Syrus is available.")).toBeVisible()
  await expect(page.getByRole("button", { name: "Reload" })).toBeVisible()

  let documentNavigation = false
  page.on("request", (request) => {
    if (request.isNavigationRequest() && request.url().endsWith("/notifications")) documentNavigation = true
  })
  await page.getByRole("link", { name: "Notifications" }).first().click()

  await expect(page).toHaveURL(/\/notifications$/)
  expect(documentNavigation).toBe(true)
})
