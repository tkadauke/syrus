import { describe, expect, it } from "vitest"
import { composeFloatingClassName } from "./utils"

describe("composeFloatingClassName", () => {
  it("anchors the mobile margin to safe-area-aware fixed insets, not a viewport-relative center", () => {
    const className = composeFloatingClassName(false)

    expect(className).toContain("left-[max(0.5rem,env(safe-area-inset-left))]")
    expect(className).toContain("right-[max(0.5rem,env(safe-area-inset-right))]")
  })

  it("pins flush to the ancestor's own padding box at sm and up instead of mx-auto plus a max-width step", () => {
    const className = composeFloatingClassName(false)

    // Regression guard: `mx-auto` plus a `max-w-*` step looks like it centers
    // the pill, but for an absolutely-positioned box with left/right both
    // set, auto margins resolve to 0 before max-width clamps the box — the
    // leftover space collapses onto one side instead of centering, which is
    // exactly the reported right-edge overlap. `sm:inset-x-0` pins both
    // edges flush to ChatColumn's `position: relative` <section> padding
    // box; the visible margin comes from that section's own `sm:px-8`
    // padding (a single source of truth), not from a hardcoded inset here.
    expect(className).toContain("sm:inset-x-0")
    expect(className).not.toContain("mx-auto")
    expect(className).not.toMatch(/max-w-/)
  })

  it("keeps left and right margins symmetric across breakpoints", () => {
    const className = composeFloatingClassName(false)
    const tokens = className.split(/\s+/)

    const leftTokens = tokens.filter((token) => /(?:^|:)left-/.test(token))
    const rightTokens = tokens.filter((token) => /(?:^|:)right-/.test(token))
    const insetXTokens = tokens.filter((token) => /(?:^|:)inset-x-/.test(token))

    // Every explicit left-* override at a given breakpoint has a matching
    // right-* (or a symmetric inset-x-* shorthand) at that same breakpoint.
    expect(leftTokens.length).toBe(rightTokens.length)
    expect(insetXTokens.length).toBeGreaterThan(0)
  })

  it("applies the drag-over ring only when dragging over", () => {
    expect(composeFloatingClassName(false)).not.toContain("ring-2 ring-brand")
    expect(composeFloatingClassName(true)).toContain("ring-2 ring-brand")
  })
})
