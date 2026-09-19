import { render, screen } from "@testing-library/react"
import { scaleTime } from "d3-scale"
import { describe, expect, it } from "vitest"
import { TimeAxis } from "./TimeAxis"
import { timezoneOffsetLabel } from "../../lib/relativeTime"

describe("TimeAxis", () => {
  const scale = scaleTime()
    .domain([new Date("2026-01-01T00:00:00Z"), new Date("2026-01-01T06:00:00Z")])
    .range([0, 1000])

  it("renders tick labels in the viewer's local time", () => {
    render(<TimeAxis scale={scale} width={1000} />)

    const ticks = scale.ticks(6)
    expect(ticks.length).toBeGreaterThan(0)
    for (const tick of ticks) {
      const label = tick.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
      expect(screen.getByText(label)).toBeInTheDocument()
    }
  })

  it("shows the viewer's UTC offset next to the axis, since a dense multi-tick axis has no single timestamp to sanity-check by hover", () => {
    render(<TimeAxis scale={scale} width={1000} />)

    const offset = timezoneOffsetLabel()
    expect(offset).not.toBe("")
    expect(screen.getByText(offset)).toBeInTheDocument()
  })
})
