import { describe, expect, it } from "vitest"
import {
  formatDuration,
  formatWithUnit,
  linePath,
  panelScale,
  tickIndexes,
  yScale
} from "./chartGeometry"

describe("yScale", () => {
  it("anchors counts at zero so small numbers are not exaggerated", () => {
    expect(yScale([ 2, 5, 9 ]).min).toBe(0)
  })

  // The flat-line bug: polling climbing 21,614 -> 24,124 is a 12% move, which a
  // zero-anchored axis renders as a horizontal line.
  it("zooms a large, tightly clustered series instead of flattening it", () => {
    const scale = yScale([ 21_614, 22_800, 24_124 ])

    expect(scale.min).toBeGreaterThan(20_000)
    expect(scale.max - scale.min).toBeLessThan(5_000)
  })

  it("ignores empty buckets when choosing the range", () => {
    expect(yScale([ null, 4, null ]).max).toBe(yScale([ 4 ]).max)
  })

  it("gives a constant series a range it can be drawn in", () => {
    expect(yScale([ 7, 7 ]).max).toBeGreaterThan(7)
    expect(yScale([ 0, 0 ])).toEqual({ min: 0, max: 1 })
  })

  it("has a range even with nothing to draw", () => {
    expect(yScale([]).max).toBeGreaterThan(yScale([]).min)
  })
})

describe("panelScale", () => {
  it("spans every series so lines in one chart are comparable", () => {
    const scale = panelScale([ { values: [ 1, 2 ] }, { values: [ 50 ] } ])

    expect(scale.max).toBeGreaterThanOrEqual(50)
  })

  // The actual point of hiding a series: a spiky series flattens everything
  // else under the old scale, so hiding it must rescale to what's left, not
  // just stop drawing its line inside the same range.
  it("excludes hidden series from the range so the remaining lines rescale", () => {
    const series = [ { name: "spiky", values: [ 1, 500 ] }, { name: "steady", values: [ 4, 6 ] } ]

    const withSpiky = panelScale(series)
    const spikyHidden = panelScale(series, new Set([ "spiky" ]))

    expect(spikyHidden.max).toBeLessThan(withSpiky.max)
    expect(spikyHidden.max).toBeLessThan(50)
  })

  it("ignores an empty or missing hidden set", () => {
    const series = [ { name: "a", values: [ 1, 2 ] }, { name: "b", values: [ 50 ] } ]

    expect(panelScale(series, new Set())).toEqual(panelScale(series))
  })

  it("falls back to the default range when every series is hidden", () => {
    const series = [ { name: "a", values: [ 1, 2 ] } ]

    expect(panelScale(series, new Set([ "a" ]))).toEqual({ min: 0, max: 1 })
  })
})

describe("linePath", () => {
  // A line drawn through a gap claims we observed something we did not.
  it("breaks into separate subpaths around an empty bucket", () => {
    const path = linePath([ 1, null, 1 ], { min: 0, max: 2 }, 100, 10)

    expect(path.match(/M/g)).toHaveLength(2)
  })

  it("still draws a series with a single reading", () => {
    expect(linePath([ 1 ], { min: 0, max: 2 }, 100, 10)).toMatch(/M/)
  })

  it("offsets every point by the axis gutter", () => {
    const plain = linePath([ 1, 2 ], { min: 0, max: 2 }, 100, 10)
    const shifted = linePath([ 1, 2 ], { min: 0, max: 2 }, 100, 10, 40)

    expect(shifted).not.toEqual(plain)
    expect(shifted.startsWith("M40.0,")).toBe(true)
  })

  it("draws nothing for a series with no readings at all", () => {
    expect(linePath([ null, null ], { min: 0, max: 1 }, 100, 10)).toBe("")
  })
})

describe("tickIndexes", () => {
  it("always labels the first and last bucket", () => {
    const ticks = tickIndexes(73)

    expect(ticks[0]).toBe(0)
    expect(ticks.at(-1)).toBe(72)
  })

  it("never asks for more ticks than there are buckets", () => {
    expect(tickIndexes(2)).toEqual([ 0, 1 ])
    expect(tickIndexes(1)).toEqual([ 0 ])
  })
})

describe("formatWithUnit", () => {
  // 24,124 on a "seconds" axis means nothing until it reads as 6.7h.
  it("renders seconds as a duration", () => {
    expect(formatWithUnit(45, "seconds")).toBe("45s")
    expect(formatWithUnit(600, "seconds")).toBe("10m")
    expect(formatWithUnit(24_124, "seconds")).toBe("6.7h")
  })

  it("leaves other units as counts", () => {
    expect(formatWithUnit(3_319, "jobs")).toBe("3319")
    expect(formatWithUnit(24_124, "jobs")).toBe("24.1k")
  })

  it("marks an empty bucket rather than printing zero", () => {
    expect(formatWithUnit(null, "jobs")).toBe("—")
  })
})

describe("formatDuration", () => {
  it("names the bucket in the largest whole unit", () => {
    expect(formatDuration(60)).toBe("1m")
    expect(formatDuration(300)).toBe("5m")
    expect(formatDuration(3600)).toBe("1h")
  })
})
