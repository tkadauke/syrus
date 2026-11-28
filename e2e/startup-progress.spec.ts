import { test, expect } from "@playwright/test"
import { signInAsDemo, waitForSpaBoot } from "./support/auth"

// On a slow connection the startup screen shows how much of the app has
// downloaded instead of an open-ended spinner. Throttling goes through the
// Chromium DevTools protocol, so these run on Chromium only.

test.describe("without the service worker", () => {
  // Every first visit takes this path: the worker is not controlling the page
  // yet, so the bar comes from resource timing of finished startup assets.
  test.use({ serviceWorkers: "block" })

  test("shows a download progress bar while the app loads over a slow connection", async ({ page, context, browserName }) => {
    test.skip(browserName !== "chromium", "network throttling uses the Chromium DevTools protocol")
    test.setTimeout(180_000)

    await signInAsDemo(page)

    const cdp = await context.newCDPSession(page)
    await cdp.send("Network.enable")
    // The sign-in already put every startup asset in the HTTP cache.
    await cdp.send("Network.setCacheDisabled", { cacheDisabled: true })
    await cdp.send("Network.emulateNetworkConditions", {
      offline: false,
      latency: 150,
      downloadThroughput: 48 * 1024,
      uploadThroughput: 48 * 1024
    })

    await page.reload({ waitUntil: "commit" })

    const bar = page.getByRole("progressbar", { name: "Download progress" })
    await expect(bar).toBeVisible({ timeout: 60_000 })
    await expect(page.locator("[data-syrus-startup-progress-detail]")).toHaveText(/\d+(\.\d)? (KB|MB) of (about )?\d+(\.\d)? (KB|MB)/)
    await expect(page.locator("#syrus-startup-status")).toHaveAttribute("data-startup-state", /watchdog|stalled/)

    await cdp.send("Network.emulateNetworkConditions", { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 })
    await waitForSpaBoot(page)
    await expect(bar).toBeHidden()
  })
})

test.describe("with the service worker", () => {
  test("counts the startup bytes it streams through and still boots the app", async ({ page, context, browserName }) => {
    test.skip(browserName !== "chromium", "service worker interception is only exercised on Chromium here")
    test.setTimeout(120_000)

    // Records the worker's progress messages from before any page script runs.
    await page.addInitScript(() => {
      const messages: unknown[] = []
      ;(window as unknown as { __startupProgressMessages: unknown[] }).__startupProgressMessages = messages
      navigator.serviceWorker?.addEventListener("message", (event) => messages.push(event.data))
      navigator.serviceWorker?.startMessages()
    })

    await signInAsDemo(page)
    await page.waitForFunction(() => navigator.serviceWorker?.controller !== null && navigator.serviceWorker?.controller !== undefined, undefined, { timeout: 30_000 })

    // Otherwise the renderer serves the startup files from its in-memory
    // cache on reload, without asking the worker at all.
    const cdp = await context.newCDPSession(page)
    await cdp.send("Network.enable")
    await cdp.send("Network.setCacheDisabled", { cacheDisabled: true })
    await page.reload()
    await waitForSpaBoot(page)

    const assets = await page.evaluate(() => {
      const meta = document.querySelector('meta[name="syrus-startup-assets"]')
      return JSON.parse(meta?.getAttribute("content") ?? "{}").assets as Record<string, { size: number; wire: number }>
    })
    const entry = Object.keys(assets).find((path) => path.includes("spa-entry-"))
    expect(entry).toBeTruthy()
    // The entry streamed through the worker's counter, byte for byte (the
    // worker counts decoded bytes, so this is the uncompressed size).
    await expect.poll(() => page.evaluate((path) => {
      const messages = (window as unknown as { __startupProgressMessages: Array<{ type: string; path: string; loaded: number; done: boolean }> }).__startupProgressMessages
      return messages.find((message) => message.type === "syrus:startup-asset-progress" && message.path === path && message.done)?.loaded ?? null
    }, entry)).toBe(assets[entry as string].size)
    await expect(page.locator("#syrus-startup-status")).toBeHidden()
  })
})
