import { describe, expect, it } from "vitest"
import { lastPopulatedIndex } from "./MetricsChart"
import type { MetricsPanel } from "../api/metricsDashboard"

function panel(series: (number | null)[][]): MetricsPanel {
  return {
    key: "k",
    metric: "m",
    unit: "jobs",
    mode: "value",
    series: series.map((values, index) => ({ name: `s${index}`, values }))
  }
}

describe("lastPopulatedIndex", () => {
  // The recorder samples on its own cadence, not the grid's, so the newest
  // bucket is frequently still empty. Reading it literally showed an em dash
  // for every series in the legend even while the chart had data.
  it("skips trailing empty buckets to find the newest reading", () => {
    expect(lastPopulatedIndex(panel([ [ 1, 2, null, null ] ]), 4)).toBe(1)
  })

  it("uses the last bucket when it does have a reading", () => {
    expect(lastPopulatedIndex(panel([ [ 1, 2, 3 ] ]), 3)).toBe(2)
  })

  it("considers every series, not just the first", () => {
    expect(lastPopulatedIndex(panel([ [ 1, null, null ], [ null, null, 9 ] ]), 3)).toBe(2)
  })

  it("falls back to the last bucket when nothing has any reading", () => {
    expect(lastPopulatedIndex(panel([ [ null, null ] ]), 2)).toBe(1)
  })
})
