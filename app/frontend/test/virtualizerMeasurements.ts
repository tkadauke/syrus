import { afterAll, beforeAll, vi } from "vitest"

// jsdom performs no real layout, so every element's offsetHeight/offsetWidth
// is always 0. Call this once at the top of any test file that renders
// ReviewableDiff/AgentDiff (or anything else built on
// @tanstack/react-virtual) so its file-level virtualizer can compute a sane
// range instead of either rendering nothing (a zero-height viewport "fits"
// no items) or everything (zero-height items never fill a zero-height
// viewport, so overscan never bounds the range).
//
// Note this does NOT stub Element.prototype.scrollTo, which jsdom also
// lacks entirely: @tanstack/react-virtual already calls it through optional
// chaining and no-ops safely without it, and a permanent prototype-level
// stub would silently break unrelated code that feature-detects
// `typeof element.scrollTo === "function"` to choose a smooth-scroll path
// (see messageStream.ts's chat auto-scroll) -- a real regression this
// caused once. A test that needs to assert a scroll happened should define
// `scrollTo` as a `vi.fn()` directly on the specific element instance
// instead (see ReviewableDiff.test.tsx's Files-menu navigation test).
//
// Scoped per test file rather than applied in the shared test/setup.ts: a
// fixed non-zero offsetHeight would also change behavior for unrelated
// scrollHeight/clientHeight-driven logic elsewhere, which doesn't expect
// offsetHeight to be nonzero either.
export function stubVirtualizerMeasurements() {
  let originalOffsetHeight: PropertyDescriptor | undefined
  let originalOffsetWidth: PropertyDescriptor | undefined

  beforeAll(() => {
    originalOffsetHeight = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "offsetHeight")
    originalOffsetWidth = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "offsetWidth")

    Object.defineProperty(HTMLElement.prototype, "offsetHeight", { configurable: true, value: 800 })
    Object.defineProperty(HTMLElement.prototype, "offsetWidth", { configurable: true, value: 1200 })
  })

  afterAll(() => {
    if (originalOffsetHeight) Object.defineProperty(HTMLElement.prototype, "offsetHeight", originalOffsetHeight)
    if (originalOffsetWidth) Object.defineProperty(HTMLElement.prototype, "offsetWidth", originalOffsetWidth)
  })
}

// Per-test variant for a file that mixes diff-rendering tests with unrelated
// ones (e.g. the big App.test.tsx, which also has real scrollHeight/
// clientHeight-driven chat auto-scroll tests that a file-wide stub would
// throw off). Call inside the specific test that renders a diff; `vi.spyOn`
// is auto-restored by test/setup.ts's global `afterEach(() => vi.restoreAllMocks())`,
// so there's no matching teardown to call here.
export function stubVirtualizerMeasurementsForTest() {
  vi.spyOn(HTMLElement.prototype, "offsetHeight", "get").mockReturnValue(800)
  vi.spyOn(HTMLElement.prototype, "offsetWidth", "get").mockReturnValue(1200)
}
