import { describe, expect, it } from "vitest"
import {
  NOTICE_AUTO_DISMISS_DELAY_MS,
  NOTICE_POPOVER_CLASS,
  NOTICE_SIDEBAR_STACK_CLASS,
  NOTICE_TOAST_VIEWPORT_CLASS,
  noticePopoverSurfaceClass
} from "./noticeStyles"

describe("noticeStyles", () => {
  it("keeps notice timing and placement contracts centralized", () => {
    expect(NOTICE_AUTO_DISMISS_DELAY_MS).toBe(3_000)
    expect(NOTICE_TOAST_VIEWPORT_CLASS).toContain("top-[68px]")
    expect(NOTICE_TOAST_VIEWPORT_CLASS).toContain("lg:top-4")
    expect(NOTICE_POPOVER_CLASS).toContain("top-full")
    expect(NOTICE_POPOVER_CLASS).toContain("w-80")
    expect(NOTICE_SIDEBAR_STACK_CLASS).toContain("pb-2")
  })

  it("uses the shared notice animation on anchored popovers", () => {
    expect(noticePopoverSurfaceClass()).toContain(NOTICE_POPOVER_CLASS)
    expect(noticePopoverSurfaceClass()).toContain("motion-safe:animate-notice-in")
  })
})
