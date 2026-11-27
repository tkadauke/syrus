import { beforeEach, describe, expect, it, vi } from "vitest"
import { readReloadBreadcrumb, reloadPage, resetReloadBreadcrumbForTests } from "./pageReload"

describe("page reload breadcrumbs", () => {
  beforeEach(() => {
    window.sessionStorage.clear()
    resetReloadBreadcrumbForTests()
  })

  it("records only the app reason, timestamp, and path before requesting a reload", () => {
    const reload = vi.fn()

    reloadPage("backend_revision_changed", reload)

    expect(readReloadBreadcrumb()).toEqual({
      reason: "backend_revision_changed",
      at: expect.any(String),
      path: window.location.pathname
    })
    expect(reload).toHaveBeenCalledOnce()
  })
})
