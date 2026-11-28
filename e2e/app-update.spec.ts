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

test("saves drafts and defers a breaking API update reload until navigation", async ({ page }) => {
  await signInAsDemo(page)
  await page.goto("/dashboard/jobs")
  await page.evaluate(() => {
    ;(window as typeof window & { __draftSaveRequests?: number }).__draftSaveRequests = 0
    window.addEventListener("syrus:save-drafts", () => {
      const instrumentedWindow = window as typeof window & { __draftSaveRequests?: number }
      instrumentedWindow.__draftSaveRequests = (instrumentedWindow.__draftSaveRequests ?? 0) + 1
    })
  })
  await page.route("**/api/v1/app/dashboard**", async (route) => {
    const response = await route.fetch()
    const payload = await response.json()
    await route.fulfill({ response, json: { ...payload, v: 2 } })
  })

  await page.getByRole("link", { name: "Epics", exact: true }).click()

  await expect(page.getByText(/Syrus must reload because the API changed/)).toBeVisible()
  await expect(page.getByRole("button", { name: "Reload now" })).toBeVisible()
  await expect(page.getByRole("button", { name: "Dismiss notification" })).toHaveCount(0)
  expect(await page.evaluate(() => (window as typeof window & { __draftSaveRequests?: number }).__draftSaveRequests)).toBe(1)

  let documentNavigation = false
  page.on("request", (request) => {
    if (request.isNavigationRequest() && request.url().endsWith("/notifications")) documentNavigation = true
  })
  await page.getByRole("link", { name: "Notifications" }).first().click()

  await expect(page).toHaveURL(/\/notifications$/)
  expect(documentNavigation).toBe(true)
})
