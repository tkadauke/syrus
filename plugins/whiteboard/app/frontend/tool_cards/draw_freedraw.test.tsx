import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import drawFreedrawToolCard, { examples } from "./draw_freedraw"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "draw_freedraw", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("draw_freedraw tool card", () => {
  it("renders every stroke field, element metadata, and a scaled path preview", () => {
    render(
      <>
        {drawFreedrawToolCard.renderExpanded(
          context({
            input: {
              x: 12,
              y: 34,
              points: [[-10, 4], { x: 30, y: 24 }, [70, -6]],
              pressures: [0.2, 0.6, 0.9],
              simulate_pressure: false,
              stroke_width: 4,
              color: "#123456"
            },
            parsedResult: { id: "free-42", version: 7 }
          })
        )}
      </>
    )

    expect(screen.getByText("free-42")).toBeInTheDocument()
    expect(screen.getByText("v7")).toBeInTheDocument()
    expect(screen.getByText("3 points")).toBeInTheDocument()
    for (const value of ["12", "34", "0.2, 0.6, 0.9", "4", "#123456", "No"]) expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.getByLabelText("#123456")).toHaveStyle({ backgroundColor: "#123456" })
    const preview = screen.getByRole("img", { name: "Freehand path preview" })
    expect(preview).toHaveAttribute("viewBox", "0 0 160 64")
    expect(preview.querySelector("path")?.getAttribute("d")).toMatch(/^M[\d.]+ [\d.]+ L[\d.]+ [\d.]+ L[\d.]+ [\d.]+$/)
  })

  it("caps large previews to one path with at most 128 sampled points", () => {
    const points = Array.from({ length: 10_000 }, (_, index) => [index, index % 37])
    const { container } = render(
      <>{drawFreedrawToolCard.renderExpanded(context({ input: { x: 0, y: 0, points }, parsedResult: { id: "large", version: 1 } }))}</>
    )

    expect(screen.getByText("10000 points")).toBeInTheDocument()
    expect(container.querySelectorAll("svg path")).toHaveLength(1)
    expect(screen.getByRole("img", { name: "Freehand path preview" })).toHaveAttribute("data-preview-point-count", "128")
    expect(container.querySelector("svg path")?.getAttribute("d")?.match(/[ML]/g)).toHaveLength(128)
  })

  it("supports wrapped results and keeps detail groups responsive", () => {
    const { container } = render(
      <>
        {drawFreedrawToolCard.renderExpanded(
          context({
            input: {
              x: 1,
              y: 2,
              points: [
                [0, 0],
                [2, 3]
              ],
              pressures: [0.5, 0.8],
              simulate_pressure: true,
              color: "red",
              stroke_width: 2
            },
            parsedResult: { result: { id: "wrapped-free", version: 9 } }
          })
        )}
      </>
    )

    expect(drawFreedrawToolCard.collapsedSummary?.(context({ parsedResult: { result: { id: "wrapped-free", version: 9 } } }))).toBe(
      "Drew freehand path · wrapped-free"
    )
    expect(screen.getByText("wrapped-free")).toBeInTheDocument()
    expect(container.querySelectorAll(".flex-wrap").length).toBeGreaterThan(1)
    expect(container.querySelector("dl")).toHaveClass("sm:grid-cols-2")
  })

  it("renders failure and empty result states", () => {
    const { unmount } = render(
      <>
        {drawFreedrawToolCard.renderExpanded(
          context({
            input: { x: 1, y: 2, points: [[0, 0]] },
            resultBody: "Canvas element limit exceeded",
            resultError: true,
            parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" }
          })
        )}
      </>
    )
    expect(screen.getByText("Canvas element limit exceeded")).toBeInTheDocument()
    unmount()
    render(<>{drawFreedrawToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
  })

  it("redacts sensitive values before displaying them", () => {
    render(
      <>
        {drawFreedrawToolCard.renderExpanded(
          context({ input: { x: 0, y: 0, points: [[0, 0]], pressures: ["token=super-secret-value"] }, parsedResult: { id: "secure", version: 1 } })
        )}
      </>
    )
    expect(screen.getByText("token=[redacted]")).toBeInTheDocument()
    expect(screen.queryByText(/super-secret-value/)).not.toBeInTheDocument()
  })

  it("provides provider-agnostic catalog examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["pressure_stroke", "pending", "element_limit"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
