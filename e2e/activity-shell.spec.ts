import { expect, test } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

const MOBILE = { width: 390, height: 780 }
const LANDSCAPE = { width: 780, height: 390 }
const DESKTOP = { width: 1280, height: 800 }

test.describe("Activity shell", () => {
  test("mobile entry points open Activity directly on their own tab", async ({ page }) => {
    await page.setViewportSize(MOBILE)
    await signInAsDemo(page)
    await page.goto("/dashboard/jobs")

    const bell = page.getByRole("button", { name: /^Notifications/ }).first()
    await bell.click()
    const shell = page.getByRole("dialog", { name: "Activity" })
    await expect(shell).toBeVisible()
    await expect(shell.getByRole("tab", { name: /Notifications/ })).toHaveAttribute("aria-selected", "true")
    // The shell fills the dynamic viewport and nothing scrolls sideways.
    const box = await shell.boundingBox()
    expect(box?.width).toBeCloseTo(MOBILE.width, 0)
    expect(box?.height).toBeCloseTo(MOBILE.height, 0)
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)

    await shell.getByRole("tab", { name: /Approvals/ }).click()
    await expect(shell.getByRole("tabpanel", { name: /Approvals/ })).toBeVisible()
    await page.keyboard.press("Escape")
    await expect(shell).toBeHidden()
    await expect(bell).toBeFocused()

    const shield = page.getByRole("button", { name: /^Approvals/ }).first()
    await shield.click()
    await expect(shell.getByRole("tab", { name: /Approvals/ })).toHaveAttribute("aria-selected", "true")
    await expect(page.getByRole("dialog")).toHaveCount(1)
  })

  test("browser back closes Activity without leaving the page", async ({ page }) => {
    await page.setViewportSize(MOBILE)
    await signInAsDemo(page)
    await page.goto("/dashboard/jobs")
    const url = page.url()

    await page
      .getByRole("button", { name: /^Notifications/ })
      .first()
      .click()
    await expect(page.getByRole("dialog", { name: "Activity" })).toBeVisible()
    await page.goBack()
    await expect(page.getByRole("dialog", { name: "Activity" })).toBeHidden()
    expect(page.url()).toBe(url)
  })

  test("leaving through an in-shell link leaves no dead history entry", async ({ page }) => {
    await page.setViewportSize(MOBILE)
    await signInAsDemo(page)
    await page.goto("/dashboard/jobs")

    await page
      .getByRole("button", { name: /^Approvals/ })
      .first()
      .click()
    await page.getByRole("dialog", { name: "Activity" }).getByRole("link", { name: "View all requests" }).click()
    await expect(page).toHaveURL(/\/permissions\/inbox$/)
    await expect(page.getByRole("dialog", { name: "Activity" })).toBeHidden()
    await page.goBack()
    await expect(page).toHaveURL(/\/dashboard\/jobs/)
    await expect(page.getByRole("dialog", { name: "Activity" })).toBeHidden()
  })

  test("rotating to a desktop width hands off to the popover and drawer", async ({ page }) => {
    await page.setViewportSize(MOBILE)
    await signInAsDemo(page)
    await page.goto("/dashboard/jobs")
    await page
      .getByRole("button", { name: /^Notifications/ })
      .first()
      .click()
    await expect(page.getByRole("dialog", { name: "Activity" })).toBeVisible()

    await page.setViewportSize(LANDSCAPE)
    await expect(page.getByRole("dialog", { name: "Activity" })).toBeVisible()
    await page.setViewportSize(DESKTOP)
    await expect(page.getByRole("dialog", { name: "Activity" })).toBeHidden()
  })

  test("desktop keeps the notification popover and approval drawer distinct", async ({ page }) => {
    await page.setViewportSize(DESKTOP)
    await signInAsDemo(page)
    await page.goto("/dashboard/jobs")

    await page
      .getByRole("button", { name: /^Notifications/ })
      .first()
      .click()
    await expect(page.getByRole("button", { name: "Mark all read" })).toBeVisible()
    await expect(page.getByTestId("activity-shell")).toHaveCount(0)

    await page
      .getByRole("button", { name: /^Approvals/ })
      .first()
      .click()
    await expect(page.getByRole("complementary", { name: "Needs your attention" })).toBeVisible()
    await expect(page.getByTestId("activity-shell")).toHaveCount(0)
  })
})
