import { expect, test } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

// Real-layout contract for the mobile sidebar drawer: with very tall content the
// middle region scrolls on its own while the close control, New Chat action and
// the account footer stay inside the viewport, and the account popup opens
// upward and stays usable. jsdom performs no layout, so this cannot be proven
// by component tests.
const MOBILE = { width: 390, height: 640 }

function maintenanceTask(id: number) {
  return {
    id,
    definition_key: "repair_stale_indexes",
    task_key: `repair-stale-indexes-${id}`,
    state: "pending",
    recurrence: "one_off",
    category: "data",
    title: `Maintenance item ${id}`,
    summary: "Repair stale search indexes.",
    trigger_kind: "manual",
    trigger_key: "repair_stale_indexes",
    required_role: "admin",
    current_step_key: null,
    current_step_title: null,
    total_units: 10,
    completed_units: 0,
    failed_units: 0,
    progress_percent: 0,
    eta_seconds: null,
    started_at: null,
    finished_at: null,
    paused_at: null,
    cancelled_at: null,
    dismissed_at: null,
    last_error: null,
    pending_reason: null,
    documentation: null,
    steps: [],
    paths: { admin: `/admin/maintenance_tasks/${id}`, api: `/api/v1/app/admin/maintenance_tasks/${id}` }
  }
}

test.describe("Mobile sidebar drawer layout", () => {
  test("tall content scrolls in the middle region while header and account footer stay reachable", async ({ page }) => {
    await page.route("**/api/v1/app/maintenance_tasks/sidebar", (route) =>
      route.fulfill({ json: { tasks: Array.from({ length: 60 }, (_, index) => maintenanceTask(index + 1)) } })
    )
    await page.setViewportSize(MOBILE)
    await signInAsDemo(page)
    await page.goto("/dashboard/jobs")
    await page.getByRole("button", { name: "Open sidebar" }).first().click()

    const scrollRegion = page.locator('[data-mobile-drawer-scroll-region="true"]')
    const footer = page.locator(".fixed.inset-0.z-40").locator('[data-sidebar-account-footer="true"]')
    const close = page.locator(".fixed.inset-0.z-40").getByRole("button", { name: "Close sidebar" })
    await expect(scrollRegion.getByRole("link", { name: "Maintenance item 60" })).toBeAttached()

    // The content really overflows, and only the middle region owns that overflow.
    const metrics = await scrollRegion.evaluate((el) => ({ scroll: el.scrollHeight, client: el.clientHeight }))
    expect(metrics.scroll).toBeGreaterThan(metrics.client)
    expect(await page.evaluate(() => document.documentElement.scrollHeight <= window.innerHeight + 1)).toBe(true)

    const withinViewport = async (locator: typeof footer) => {
      const box = await locator.boundingBox()
      expect(box).not.toBeNull()
      expect(box!.y).toBeGreaterThanOrEqual(0)
      expect(box!.y + box!.height).toBeLessThanOrEqual(MOBILE.height + 1)
    }
    await withinViewport(footer)
    await withinViewport(close)
    await expect(footer.getByRole("navigation", { name: "Account" })).toBeVisible()

    // Footer sits at the very bottom of the viewport and is not covered by scrolling content.
    const footerBox = (await footer.boundingBox())!
    expect(footerBox.y + footerBox.height).toBeGreaterThanOrEqual(MOBILE.height - 1)
    const regionBox = (await scrollRegion.boundingBox())!
    expect(regionBox.y + regionBox.height).toBeLessThanOrEqual(footerBox.y + 1)

    // Scrolling the middle region reaches the last item; fixed controls do not move.
    const footerTopBefore = footerBox.y
    await scrollRegion.evaluate((el) => {
      el.scrollTop = el.scrollHeight
    })
    const last = scrollRegion.getByRole("link", { name: "Maintenance item 60" })
    await expect(last).toBeInViewport()
    expect((await footer.boundingBox())!.y).toBeCloseTo(footerTopBefore, 0)
    await withinViewport(close)

    // The account popup opens upward from the footer, unclipped and clickable.
    const trigger = footer.getByRole("button", { expanded: false }).first()
    const triggerBox = (await trigger.boundingBox())!
    await trigger.click()
    const signOut = footer.getByRole("button", { name: "Sign out" })
    const settings = footer.getByRole("link", { name: "Settings" })
    await expect(signOut).toBeVisible()
    await expect(settings).toBeInViewport({ ratio: 1 })
    await expect(signOut).toBeInViewport({ ratio: 1 })
    const menuBox = (await settings.boundingBox())!
    // Opens upward: every popup row sits above the trigger, not clipped by the footer.
    expect(menuBox.y + menuBox.height).toBeLessThanOrEqual(triggerBox.y + 1)
    const signOutBox = (await signOut.boundingBox())!
    expect(signOutBox.y + signOutBox.height).toBeLessThanOrEqual(triggerBox.y + 1)
    // Hit-testing proves nothing (e.g. the scrolling region) overlays the popup.
    expect(await signOut.evaluate((el) => el.contains(document.elementFromPoint(el.getBoundingClientRect().x + 5, el.getBoundingClientRect().y + 5)))).toBe(
      true
    )
  })
})
