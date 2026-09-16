import { createElement } from "react"
import { fireEvent, render, screen, within } from "@testing-library/react"
import { beforeEach, describe, expect, it } from "vitest"
import { MetricsChart, hiddenSeriesStorageKey, lastPopulatedIndex, loadHiddenSeries, persistSeriesHidden } from "./MetricsChart"
import type { MetricsPanel } from "../api/metricsDashboard"

function panel(series: (number | null)[][]): MetricsPanel {
  return {
    key: "k",
    metric: "m",
    unit: "jobs",
    mode: "value",
    category: "queue_throughput",
    series: series.map((values, index) => ({ name: `s${index}`, values }))
  }
}

function renderChart(testPanel: MetricsPanel, overrides: Partial<Parameters<typeof MetricsChart>[0]> = {}) {
  return render(
    createElement(MetricsChart, {
      panel: testPanel,
      buckets: testPanel.series[0]?.values.map((_, index) => `2026-01-01T00:0${index}:00Z`) ?? [],
      bucketSeconds: 60,
      hoverIndex: null,
      onHover: () => {},
      title: "Test panel",
      ...overrides
    })
  )
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

describe("hidden series storage", () => {
  it("keys storage by panel and series name", () => {
    expect(hiddenSeriesStorageKey("queue_failed", "worker")).toBe("metrics_dashboard.hidden_series.queue_failed.worker")
  })

  it("reads back what was persisted, scoped per series", () => {
    persistSeriesHidden("p", "a", true)
    persistSeriesHidden("p", "b", false)

    expect(loadHiddenSeries("p", [ "a", "b" ])).toEqual(new Set([ "a" ]))
  })

  it("un-persists a series once it is shown again", () => {
    persistSeriesHidden("p", "a", true)
    persistSeriesHidden("p", "a", false)

    expect(loadHiddenSeries("p", [ "a" ])).toEqual(new Set())
  })
})

describe("MetricsChart series toggling", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("toggling a legend row hides that series' line and dims its row", () => {
    const { container } = renderChart(panel([ [ 1, 2, 3 ], [ 4, 5, 6 ] ]))

    expect(container.querySelectorAll("path")).toHaveLength(2)

    fireEvent.click(screen.getByRole("button", { name: "Hide s0 series" }))

    expect(container.querySelectorAll("path")).toHaveLength(1)
    expect(screen.getByRole("button", { name: "Show s0 series" })).toHaveAttribute("aria-pressed", "true")
    expect(screen.getByTitle("s0")).toHaveClass("line-through")
    // The other series is untouched.
    expect(screen.getByRole("button", { name: "Hide s1 series" })).toHaveAttribute("aria-pressed", "false")
  })

  it("excludes a hidden series from the hover legend readout", () => {
    renderChart(panel([ [ 1, 2, 3 ] ]), { hoverIndex: 1 })

    expect(screen.getByText("2")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Hide s0 series" }))

    expect(screen.queryByText("2")).not.toBeInTheDocument()
    expect(screen.getByText("—")).toBeInTheDocument()
  })

  it("excludes a hidden series from the crosshair dot", () => {
    const { container } = renderChart(panel([ [ 1, 2, 3 ] ]), { hoverIndex: 1 })

    expect(container.querySelectorAll("circle")).toHaveLength(1)

    fireEvent.click(screen.getByRole("button", { name: "Hide s0 series" }))

    expect(container.querySelectorAll("circle")).toHaveLength(0)
  })

  it("persists the hidden state so a fresh mount of the same panel honors it", () => {
    const { unmount } = renderChart(panel([ [ 1, 2, 3 ] ]))
    fireEvent.click(screen.getByRole("button", { name: "Hide s0 series" }))
    unmount()

    renderChart(panel([ [ 1, 2, 3 ] ]))

    expect(screen.getByRole("button", { name: "Show s0 series" })).toHaveAttribute("aria-pressed", "true")
  })

  it("does not affect a different panel's hidden state", () => {
    const first = renderChart({ ...panel([ [ 1, 2, 3 ] ]), key: "panel-a" })
    fireEvent.click(within(first.container).getByRole("button", { name: "Hide s0 series" }))

    const second = renderChart({ ...panel([ [ 1, 2, 3 ] ]), key: "panel-b" })

    expect(within(second.container).getByRole("button", { name: "Hide s0 series" })).toHaveAttribute(
      "aria-pressed",
      "false"
    )
  })
})
