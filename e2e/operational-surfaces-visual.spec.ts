import { expect, test, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"
import { removePresetFilter, sortDashboardByNewest } from "./support/dashboard"

test.slow()

const SURFACES = [
  {
    name: "job-detail",
    open: async (page: Page) => {
      await openSeededJob(page, "Inspect preview dashboard states")
      await expect(page.getByRole("heading", { level: 1 })).toContainText("Inspect preview dashboard states")
      await expect(page.getByRole("heading", { name: "Details" })).toBeVisible()
      await expect(page.getByRole("heading", { name: "Agent summary" })).toBeVisible()
    }
  },
  {
    name: "workflow-diagnostics",
    open: async (page: Page) => {
      await openSeededJob(page, "Inspect preview dashboard states")
      await page.getByRole("button", { name: "Workflows" }).click()
      await expect(page.getByRole("heading", { name: /^WF-/ })).toBeVisible()
      await page.getByRole("button", { name: /Implement/ }).click()
      await expect(page.getByRole("button", { name: "Transcript" })).toBeVisible()
      await expect(page.getByRole("button", { name: "Diff" })).toBeVisible()
    }
  },
  {
    name: "chat-tool-card",
    open: async (page: Page) => {
      await page.getByRole("link", { name: "Preview walkthrough" }).click()
      await expect(page.getByTestId("chat-message-stream")).toContainText("I checked the representative Jobs through the chat tools.")
      // Exact: the tool card shows both a "List jobs" title and a
      // "List jobs(preview)" command line, so a substring match is ambiguous.
      await page.getByText("List jobs", { exact: true }).click()
      await expect(page.getByText("Inspect preview dashboard states").last()).toBeVisible()
      await expect(page.getByText("Repair seeded background workflow").last()).toBeVisible()
    }
  }
]

for (const theme of ["light", "dark"] as const) {
  for (const surface of SURFACES) {
    test(`visually renders ${surface.name} in ${theme} theme`, async ({ page }) => {
      await signInAsDemo(page)
      await surface.open(page)
      await applyTheme(page, theme)

      await expectNoHorizontalOverflow(page)
      const mainBackground = await page.locator("main").evaluate((element) => getComputedStyle(element).backgroundColor)
      expect(mainBackground).not.toBe(theme === "dark" ? "rgb(255, 255, 255)" : "rgb(17, 24, 39)")

      const screenshot = await page.screenshot({ fullPage: false })
      expect(pngDimensions(screenshot)).toMatchObject({ width: 1280, height: 720 })
      expect(screenshot.byteLength).toBeGreaterThan(20_000)
    })
  }
}

async function openSeededJob(page: Page, title: string) {
  sortDashboardByNewest()
  await page.goto("/dashboard/jobs?ownership_scope=team&view=list")
  await removePresetFilter(page)
  await page.getByRole("row").filter({ has: page.getByRole("link", { name: title, exact: true }) }).getByRole("link", { name: title, exact: true }).click()
}

async function applyTheme(page: Page, theme: "light" | "dark") {
  await page.evaluate((value) => {
    document.documentElement.classList.toggle("dark", value === "dark")
  }, theme)

  await expect(page.locator("html")).toHaveClass(theme === "dark" ? /dark/ : /^(?!.*\bdark\b)/)
}

async function expectNoHorizontalOverflow(page: Page) {
  const overflow = await page.locator("html").evaluate((html) => html.scrollWidth - html.clientWidth)
  expect(overflow).toBeLessThanOrEqual(1)
}

function pngDimensions(buffer: Buffer) {
  return {
    width: buffer.readUInt32BE(16),
    height: buffer.readUInt32BE(20)
  }
}
