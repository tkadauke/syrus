import { describe, expect, it } from "vitest"
import { sparklinePoints } from "./MetricsDashboard"

function ys(points: string) {
  return points.split(" ").map((pair) => Number(pair.split(",")[1]))
}

describe("sparklinePoints", () => {
  // The first version shared one zero-anchored scale across every series in a
  // panel, which made the whole dashboard a set of horizontal lines: `cleanup`
  // at 4 shares an axis with `polling` at 24,124, and polling's own 21,614 ->
  // 24,124 climb is ~10% of its value, about three pixels of a 28-pixel chart.
  // Each series is scaled to its own range so the line shows shape; the number
  // printed beside it carries magnitude.
  it("uses the full height for a series' own range, whatever its magnitude" , () => {
    const small = ys(sparklinePoints([ 2, 4, 14 ]))
    const large = ys(sparklinePoints([ 21614, 22800, 24124 ]))

    // Both start at the floor and end at the ceiling of the 28px box.
    expect(small[0]).toBe(28)
    expect(small.at(-1)).toBe(0)
    expect(large[0]).toBe(28)
    expect(large.at(-1)).toBe(0)
  })

  // A 10% move on a large number was the case that looked flat before.
  it("makes a small relative change visible", () => {
    const points = ys(sparklinePoints([ 21614, 24124 ]))

    expect(Math.abs(points[0] - points[1])).toBeGreaterThan(20)
  })

  // Centred, not pinned to an edge: "steady" should read as steady rather than
  // as sitting at a limit.
  it("draws a flat series down the middle", () => {
    expect(ys(sparklinePoints([ 5, 5, 5 ]))).toEqual([ 14, 14, 14 ])
  })

  it("spreads points evenly across the width", () => {
    const xs = sparklinePoints([ 1, 2, 3 ], 200).split(" ").map((pair) => Number(pair.split(",")[0]))

    expect(xs).toEqual([ 0, 100, 200 ])
  })

  it("returns nothing for an empty series rather than NaN coordinates", () => {
    expect(sparklinePoints([])).toBe("")
  })
})
