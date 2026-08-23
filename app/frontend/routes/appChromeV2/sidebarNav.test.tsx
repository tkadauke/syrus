import { describe, expect, it } from "vitest"
import type { SidebarPluginPage } from "../../api/sidebarPages"
import { CORE_NAV_ITEMS, applySidebarNavOrder, buildSidebarNavItems, sidebarNavItemActive } from "./sidebarNav"

const translate = (key: string, options?: { defaultValue?: string }) => options?.defaultValue ?? key

const baseContext = { simpleMode: false, featureFlags: { terminal: true }, teamUserCount: 2 }

describe("CORE_NAV_ITEMS", () => {
  it("covers the built-in nav entries except spending and setup", () => {
    expect(CORE_NAV_ITEMS.map((item) => item.id)).toEqual([
      "dashboard",
      "repositories",
      "schedules",
      "terminal",
      "team"
    ])
  })
})

describe("buildSidebarNavItems", () => {
  it("includes all core items in order when every visibility condition is met", () => {
    const items = buildSidebarNavItems(baseContext, [], translate)

    expect(items.map((item) => item.id)).toEqual(["dashboard", "repositories", "schedules", "terminal", "team"])
  })

  it("routes dashboard to the jobs board in simple mode", () => {
    const items = buildSidebarNavItems({ ...baseContext, simpleMode: true }, [], translate)

    expect(items.find((item) => item.id === "dashboard")?.to).toBe("/dashboard/jobs")
  })

  it("routes dashboard to the jobs board outside simple mode", () => {
    const items = buildSidebarNavItems(baseContext, [], translate)

    expect(items.find((item) => item.id === "dashboard")?.to).toBe("/dashboard/jobs")
  })

  it("hides schedules in simple mode", () => {
    const items = buildSidebarNavItems({ ...baseContext, simpleMode: true }, [], translate)

    expect(items.map((item) => item.id)).not.toContain("schedules")
  })

  it("hides terminal when the terminal feature flag is off", () => {
    const items = buildSidebarNavItems({ ...baseContext, featureFlags: {} }, [], translate)

    expect(items.map((item) => item.id)).not.toContain("terminal")
  })

  it("hides team when there is only one team member", () => {
    const items = buildSidebarNavItems({ ...baseContext, teamUserCount: 1 }, [], translate)

    expect(items.map((item) => item.id)).not.toContain("team")
  })

  it("appends enabled plugin-provided pages after the core items, preserving their given order", () => {
    const pluginPages: SidebarPluginPage[] = [
      { id: "spending.dashboard", label: "Spending", label_key: "spending:nav_spending", path: "/insights/spending", paths: ["/insights/spending"], order: 60, icon: "spending" },
      { id: "extra.page", label: "Extra", path: "/extra", paths: ["/extra"], order: 70 }
    ]

    const items = buildSidebarNavItems(baseContext, pluginPages, translate)

    expect(items.map((item) => item.id)).toEqual([
      "dashboard",
      "repositories",
      "schedules",
      "terminal",
      "team",
      "spending.dashboard",
      "extra.page"
    ])
  })

  it("translates a plugin page's label_key, falling back to its raw label", () => {
    const pluginPages: SidebarPluginPage[] = [
      { id: "extra.page", label: "Extra", label_key: "extra:nav_extra", path: "/extra", paths: ["/extra"], order: 70 }
    ]

    const items = buildSidebarNavItems(baseContext, pluginPages, (key, options) => (key === "extra:nav_extra" ? "Extra Translated" : (options?.defaultValue ?? key)))

    expect(items.find((item) => item.id === "extra.page")?.label).toBe("Extra Translated")
  })

  it("uses the raw label when a plugin page has no label_key", () => {
    const pluginPages: SidebarPluginPage[] = [
      { id: "extra.page", label: "Extra", path: "/extra", paths: ["/extra"], order: 70 }
    ]

    const items = buildSidebarNavItems(baseContext, pluginPages, translate)

    expect(items.find((item) => item.id === "extra.page")?.label).toBe("Extra")
  })
})

describe("applySidebarNavOrder", () => {
  const items = [
    { id: "dashboard" },
    { id: "repositories" },
    { id: "schedules" },
    { id: "terminal" },
    { id: "team" }
  ]

  it("returns items unchanged when no order is saved", () => {
    expect(applySidebarNavOrder(items, []).map((item) => item.id)).toEqual([
      "dashboard", "repositories", "schedules", "terminal", "team"
    ])
  })

  it("reorders items to match the saved order", () => {
    const order = ["team", "dashboard", "repositories", "schedules", "terminal"]

    expect(applySidebarNavOrder(items, order).map((item) => item.id)).toEqual(order)
  })

  it("appends items missing from the saved order at the end, preserving their relative order", () => {
    const order = ["terminal", "dashboard"]

    expect(applySidebarNavOrder(items, order).map((item) => item.id)).toEqual([
      "terminal", "dashboard", "repositories", "schedules", "team"
    ])
  })

  it("ignores saved order entries whose item is no longer present", () => {
    const order = ["spending.dashboard", "team", "dashboard"]

    expect(applySidebarNavOrder(items, order).map((item) => item.id)).toEqual([
      "team", "dashboard", "repositories", "schedules", "terminal"
    ])
  })

  it("appends a newly enabled plugin item at the end, not in the saved order", () => {
    const withPlugin = [...items, { id: "spending.dashboard" }]
    const order = ["team", "dashboard", "repositories", "schedules", "terminal"]

    expect(applySidebarNavOrder(withPlugin, order).map((item) => item.id)).toEqual([
      "team", "dashboard", "repositories", "schedules", "terminal", "spending.dashboard"
    ])
  })
})

describe("sidebarNavItemActive", () => {
  it("treats the dashboard root and any /dashboard path as active", () => {
    expect(sidebarNavItemActive({ id: "dashboard", to: "/dashboard/jobs" }, "/")).toBe(true)
    expect(sidebarNavItemActive({ id: "dashboard", to: "/dashboard/jobs" }, "/dashboard/epics")).toBe(true)
    expect(sidebarNavItemActive({ id: "dashboard", to: "/dashboard/jobs" }, "/repositories")).toBe(false)
  })

  it("treats any other item as active when the path starts with its target", () => {
    expect(sidebarNavItemActive({ id: "repositories", to: "/repositories" }, "/repositories/42")).toBe(true)
    expect(sidebarNavItemActive({ id: "repositories", to: "/repositories" }, "/schedules")).toBe(false)
  })
})
