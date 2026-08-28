import { afterEach, describe, expect, it, vi } from "vitest"
import type { SyrusShellBridge } from "./desktopShell"
import {
  dispatchNativeNotification,
  httpNotificationUrl,
  isNativeNotificationSupported,
  nativeNotificationClickUrl,
  nativeNotificationTitle,
  requestNativeNotificationPermission,
  setNativeNotificationCableSubscribed
} from "./nativeNotifications"

const desktopUa = "Mozilla/5.0 (Macintosh) Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.0 Safari/537.36"

class FakeNotification {
  static permission: NotificationPermission = "default"
  static requestPermissionMock = vi.fn<() => Promise<NotificationPermission>>()
  static instances: FakeNotification[] = []

  onclick: (() => void) | null = null
  closed = false
  title: string
  body?: string

  constructor(title: string, options?: NotificationOptions) {
    this.title = title
    this.body = options?.body
    FakeNotification.instances.push(this)
  }

  static requestPermission() {
    return FakeNotification.requestPermissionMock()
  }

  close() {
    this.closed = true
  }
}

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  FakeNotification.permission = "default"
  FakeNotification.requestPermissionMock = vi.fn()
  FakeNotification.instances = []
  delete window.syrusShell
  // Cable-subscription state is module-level (set by useAppEvents.ts as the
  // ActionCable subscription connects/disconnects) — reset between tests so
  // one test's subscribed state can't leak into the next.
  setNativeNotificationCableSubscribed(false)
})

describe("nativeNotificationTitle", () => {
  it("maps known kinds to friendly labels", () => {
    expect(nativeNotificationTitle("job_failed")).toBe("Job failed")
    expect(nativeNotificationTitle("PR_MERGED")).toBe("PR merged")
  })

  it("falls back to a titleized version of unknown kinds", () => {
    expect(nativeNotificationTitle("something_weird")).toBe("Something weird")
    expect(nativeNotificationTitle("pr_something_new")).toBe("PR something new")
  })

  it("falls back to a generic label for an empty kind", () => {
    expect(nativeNotificationTitle("   ")).toBe("Syrus notification")
  })
})

describe("nativeNotificationClickUrl", () => {
  it("prefers the PR url when present", () => {
    expect(nativeNotificationClickUrl({ jobId: 7, prUrl: "https://github.com/o/r/pull/1" }))
      .toBe("https://github.com/o/r/pull/1")
  })

  it("falls back to a job path scoped to the current route prefix", () => {
    vi.stubGlobal("location", { ...window.location, pathname: "/app-shell/dashboard" })
    expect(nativeNotificationClickUrl({ jobId: 42, prUrl: null })).toBe("/app-shell/jobs/42")
  })

  it("returns null when neither a PR url nor a job id is present", () => {
    expect(nativeNotificationClickUrl({ jobId: null, prUrl: null })).toBeNull()
  })
})

describe("httpNotificationUrl", () => {
  it("accepts http and https urls", () => {
    expect(httpNotificationUrl("https://github.com/o/r/pull/1")).toBe("https://github.com/o/r/pull/1")
    expect(httpNotificationUrl("http://example.com/x")).toBe("http://example.com/x")
  })

  it("rejects non-http(s) schemes and unparseable values", () => {
    expect(httpNotificationUrl("javascript:alert(1)")).toBeNull()
    expect(httpNotificationUrl("not a url")).toBeNull()
    expect(httpNotificationUrl("")).toBeNull()
    expect(httpNotificationUrl(null)).toBeNull()
    expect(httpNotificationUrl(42)).toBeNull()
  })
})

describe("isNativeNotificationSupported / requestNativeNotificationPermission", () => {
  it("reports unsupported and denies permission when window.Notification is absent", async () => {
    expect(isNativeNotificationSupported()).toBe(false)
    expect(await requestNativeNotificationPermission()).toBe("denied")
  })

  it("requests permission only when it is still the default", async () => {
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "default"
    FakeNotification.requestPermissionMock.mockResolvedValue("granted")

    expect(await requestNativeNotificationPermission()).toBe("granted")
    expect(FakeNotification.requestPermissionMock).toHaveBeenCalledOnce()
  })

  it("does not re-prompt once permission has already been decided", async () => {
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "denied"

    expect(await requestNativeNotificationPermission()).toBe("denied")
    expect(FakeNotification.requestPermissionMock).not.toHaveBeenCalled()
  })

  it("prompts inside the desktop shell too -- webAppWindow is a normal Chromium renderer and main's own dispatch is fallback-only now", async () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(desktopUa)
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "default"
    FakeNotification.requestPermissionMock.mockResolvedValue("granted")

    expect(await requestNativeNotificationPermission()).toBe("granted")
    expect(FakeNotification.requestPermissionMock).toHaveBeenCalledOnce()
  })
})

describe("dispatchNativeNotification", () => {
  it("fails silently when Notification is unsupported", () => {
    expect(dispatchNativeNotification({ kind: "job_failed", body: "oops", jobId: 1, prUrl: null })).toBe(false)
  })

  it("fails silently when permission has not been granted", () => {
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "denied"

    expect(dispatchNativeNotification({ kind: "job_failed", body: "oops", jobId: 1, prUrl: null })).toBe(false)
    expect(FakeNotification.instances).toHaveLength(0)
  })

  it("shows a notification with a mapped title and navigates on click when permission is granted", () => {
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "granted"
    const assign = vi.fn()
    vi.stubGlobal("location", { ...window.location, pathname: "/dashboard", set href(value: string) { assign(value) } })
    const focus = vi.spyOn(window, "focus").mockImplementation(() => {})

    const result = dispatchNativeNotification({ kind: "pr_merged", body: "PR #4 merged", jobId: 4, prUrl: null })

    expect(result).toBe(true)
    expect(FakeNotification.instances).toHaveLength(1)
    expect(FakeNotification.instances[0].title).toBe("PR merged")
    expect(FakeNotification.instances[0].body).toBe("PR #4 merged")

    FakeNotification.instances[0].onclick?.()
    expect(focus).toHaveBeenCalledOnce()
    expect(assign).toHaveBeenCalledWith("/jobs/4")
    expect(FakeNotification.instances[0].closed).toBe(true)
  })

  it("dispatches inside the desktop shell too -- Electron main's own dispatch is fallback-only now, so this path no longer needs to stand down", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(desktopUa)
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "granted"

    const result = dispatchNativeNotification({ kind: "pr_merged", body: "PR #4 merged", jobId: 4, prUrl: null })

    expect(result).toBe(true)
    expect(FakeNotification.instances).toHaveLength(1)
  })
})

describe("setNativeNotificationCableSubscribed / desktop-shell liveness reporting", () => {
  it("is a no-op in a plain browser tab (no shell bridge to report to)", () => {
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "granted"

    expect(() => setNativeNotificationCableSubscribed(true)).not.toThrow()
  })

  it("reports live only once both subscribed AND permission is granted", () => {
    const reportLive = vi.fn()
    window.syrusShell = { notifications: { reportLive } } as unknown as SyrusShellBridge
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "granted"

    setNativeNotificationCableSubscribed(true)

    expect(reportLive).toHaveBeenCalledWith(true)
  })

  it("reports not-live when subscribed but permission has not been granted", () => {
    const reportLive = vi.fn()
    window.syrusShell = { notifications: { reportLive } } as unknown as SyrusShellBridge
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "default"

    setNativeNotificationCableSubscribed(true)

    expect(reportLive).toHaveBeenCalledWith(false)
  })

  it("reports not-live when permission is granted but the cable is not subscribed", () => {
    const reportLive = vi.fn()
    window.syrusShell = { notifications: { reportLive } } as unknown as SyrusShellBridge
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "granted"

    setNativeNotificationCableSubscribed(false)

    expect(reportLive).toHaveBeenCalledWith(false)
  })

  it("re-syncs liveness after a permission decision resolves", async () => {
    const reportLive = vi.fn()
    window.syrusShell = { notifications: { reportLive } } as unknown as SyrusShellBridge
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "default"
    // Mirrors real browser behavior: once requestPermission() resolves, the
    // Notification.permission getter reflects the new value too.
    FakeNotification.requestPermissionMock.mockImplementation(async () => {
      FakeNotification.permission = "granted"
      return "granted"
    })
    setNativeNotificationCableSubscribed(true)
    reportLive.mockClear()

    await requestNativeNotificationPermission()

    expect(reportLive).toHaveBeenCalledWith(true)
  })
})
