import { describe, expect, it } from "vitest"
import { MIN_LABEL_SPACING_PX, MIN_TICK_SPACING_PX, layoutRail, railLabels } from "./historyRailScale"

const DAY = 86_400_000
const to = Date.parse("2026-10-31T12:00:00Z")

describe("layoutRail", () => {
  it("makes a seven-day window taller than a typical viewport", () => {
    expect(layoutRail([], to - 7 * DAY, to).height).toBeGreaterThan(1500)
  })

  it("positions events proportionally, newest first", () => {
    const ticks = [new Date(to - 6 * 3_600_000).toISOString(), new Date(to - 3_600_000).toISOString()]
    const layout = layoutRail(ticks, to - 7 * DAY, to)
    expect(layout.tickY[1]).toBeLessThan(layout.tickY[0])
    expect(layout.tickY[0] - layout.tickY[1]).toBeCloseTo(5 * 12, 5)
  })

  it("keeps dense events at least the minimum spacing apart", () => {
    const ticks = Array.from({ length: 20 }, (_, i) => new Date(to - 60_000 * (20 - i)).toISOString())
    const ys = layoutRail(ticks, to - 7 * DAY, to).tickY
    for (let i = 1; i < ys.length; i++) expect(ys[i - 1] - ys[i]).toBeGreaterThanOrEqual(MIN_TICK_SPACING_PX - 1e-6)
  })
})

describe("railLabels", () => {
  it("labels a one-day window with sub-daily landmarks", () => {
    const layout = layoutRail([], to - DAY, to)
    const labels = railLabels(layout, to - DAY, to)
    expect(labels.length).toBeGreaterThanOrEqual(12)
    labels.slice(1).forEach((label, i) => expect(label.y - labels[i].y).toBeGreaterThanOrEqual(MIN_LABEL_SPACING_PX - 1e-6))
  })

  it("labels a seven-day window with several landmarks including day boundaries", () => {
    const layout = layoutRail([], to - 7 * DAY, to)
    const labels = railLabels(layout, to - 7 * DAY, to)
    expect(labels.length).toBeGreaterThan(6)
    expect(labels.filter((label) => label.major).length).toBeGreaterThanOrEqual(7)
  })
})
