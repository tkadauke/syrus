import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import drawLineCard, { examples } from "./draw_line"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "draw_line", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("draw_line tool card", () => {
  it("renders line geometry, styling, arrowheads, point details, and element metadata", () => {
    const { container } = render(
      <>
        {drawLineCard.renderExpanded(
          context({
            input: {
              x: 10,
              y: 20,
              points: [
                [0, 5],
                [40, 25],
                [80, 10]
              ],
              stroke_width: 4,
              color: "#123456",
              start_arrowhead: "dot",
              end_arrowhead: "arrow"
            },
            parsedResult: { id: "line-42", version: 9 }
          })
        )}
      </>
    )

    expect(screen.getByText("line-42")).toBeInTheDocument()
    expect(screen.getByText("v9")).toBeInTheDocument()
    expect(screen.getAllByText("3 points").length).toBeGreaterThan(0)
    expect(screen.getByText("(0, 5) → (80, 10)")).toBeInTheDocument()
    for (const value of ["10", "20", "4", "#123456", "dot", "arrow"]) expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.getByLabelText("#123456")).toHaveStyle({ backgroundColor: "#123456" })
    const disclosure = screen.getByText("Points · 3 points").closest("details")
    expect(disclosure).not.toBeNull()
    expect(within(disclosure!).getByText("2. (40, 25)")).toBeInTheDocument()
    expect(container.querySelectorAll(".flex-wrap").length).toBeGreaterThan(1)
    expect(container.querySelector("dl")).toHaveClass("sm:grid-cols-2")
  })

  it("renders object-form points accepted by the draw_line contract", () => {
    render(
      <>
        {drawLineCard.renderExpanded(
          context({
            input: {
              x: 10,
              y: 20,
              points: [
                { x: 0, y: 5 },
                { x: 40, y: 25 },
                { x: 80, y: 10 }
              ]
            },
            parsedResult: { id: "object-points-line", version: 3 }
          })
        )}
      </>
    )

    expect(screen.getAllByText("3 points").length).toBeGreaterThan(0)
    expect(screen.getByText("(0, 5) → (80, 10)")).toBeInTheDocument()
    const disclosure = screen.getByText("Points · 3 points").closest("details")
    expect(disclosure).not.toBeNull()
    expect(within(disclosure!).getByText("2. (40, 25)")).toBeInTheDocument()
  })

  it("supports wrapped result envelopes", () => {
    const toolContext = context({ input: { x: 1, y: 2, points: [] }, parsedResult: { result: { id: "wrapped-line", version: 7 } } })
    expect(drawLineCard.collapsedSummary?.(toolContext)).toBe("Drew line · wrapped-line")
    render(<>{drawLineCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("wrapped-line")).toBeInTheDocument()
    expect(screen.getByText("v7")).toBeInTheDocument()
    expect(screen.getByText("0 points")).toBeInTheDocument()
  })

  it("uses the shared failure card and handles empty and malformed results", () => {
    const failed = context({
      input: { x: 1, y: 2, points: [] },
      resultBody: "Canvas element limit exceeded",
      resultError: true,
      parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" }
    })
    const { unmount } = render(<>{drawLineCard.renderExpanded(failed)}</>)
    expect(drawLineCard.collapsedSummary?.(failed)).toBe("Drew line failed: Canvas element limit exceeded")
    expect(screen.getByText("Drew line failed")).toBeInTheDocument()
    expect(screen.getByText("Canvas element limit exceeded")).toBeInTheDocument()

    unmount()
    const { unmount: unmountPending } = render(<>{drawLineCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()

    unmountPending()
    render(<>{drawLineCard.renderExpanded(context({ parsedResult: { version: 2 } }))}</>)
    expect(screen.getByText("Result did not include an element ID")).toBeInTheDocument()
  })

  it("redacts sensitive display values", () => {
    render(
      <>
        {drawLineCard.renderExpanded(
          context({
            input: { points: [], color: "token=super-secret-value", start_arrowhead: "secret=hidden-value" },
            parsedResult: { id: "secure", version: 1 }
          })
        )}
      </>
    )
    expect(screen.getByText("token=[redacted]")).toBeInTheDocument()
    expect(screen.getByText("secret=[redacted]")).toBeInTheDocument()
    expect(screen.queryByText(/super-secret-value|hidden-value/)).not.toBeInTheDocument()
  })

  it("provides provider-agnostic catalog examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["styled_line", "pending", "element_limit"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
