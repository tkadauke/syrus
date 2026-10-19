import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import drawLineCard, { examples } from "./draw_line"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "draw_line", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("draw_line tool card", () => {
  it("renders every line input, result metadata, endpoints, and the expandable point list", () => {
    const { container } = render(
      <>
        {drawLineCard.renderExpanded(
          context({
            input: {
              type: "line",
              x: 12,
              y: 24,
              width: 160,
              height: 80,
              points: [
                [0, 0],
                [80, 40],
                [160, 80]
              ],
              color: "#e11d48",
              stroke_width: 3,
              start_arrowhead: "dot",
              end_arrowhead: "arrow"
            },
            parsedResult: { id: "line-42", version: 7 }
          })
        )}
      </>
    )

    for (const value of ["line-42", "v7", "line", "12", "24", "160", "80", "3 points", "(0, 0) → (160, 80)", "#e11d48", "3", "dot", "arrow"])
      expect(screen.getAllByText(value).length).toBeGreaterThan(0)
    expect(screen.getByLabelText("#e11d48")).toHaveStyle({ backgroundColor: "#e11d48" })
    const disclosure = screen.getByText("Points · 3 points").closest("details")
    expect(disclosure).not.toBeNull()
    expect(within(disclosure!).getByText("2. (80, 40)")).toBeInTheDocument()
    expect(container.querySelector(".flex.flex-wrap")).toBeInTheDocument()
    expect(disclosure?.querySelector(".sm\\:grid-cols-2")).toBeInTheDocument()
  })

  it("accepts the provider-agnostic wrapped result envelope", () => {
    const parsedResult = { result: { id: "wrapped-line", version: 9 } }
    expect(drawLineCard.collapsedSummary?.(context({ parsedResult }))).toBe("Drew line · wrapped-line")
    render(<>{drawLineCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("wrapped-line")).toBeInTheDocument()
    expect(screen.getByText("v9")).toBeInTheDocument()
  })

  it("uses the shared failure card and handles empty and malformed results", () => {
    const failed = context({
      input: { x: 1, y: 2, points: [] },
      resultError: true,
      resultBody: "Could not draw line",
      parsedResult: { message: "Could not draw line", retryable: false }
    })
    expect(drawLineCard.collapsedSummary?.(failed)).toBe("Drew line failed: Could not draw line")
    const first = render(<>{drawLineCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Check the canvas for a partial edit before retrying.")).toBeInTheDocument()
    first.unmount()

    const second = render(<>{drawLineCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
    second.unmount()

    render(<>{drawLineCard.renderExpanded(context({ parsedResult: { version: 2 } }))}</>)
    expect(screen.getByText("Result did not include an element ID")).toBeInTheDocument()
  })

  it("provides success, empty, and error catalog examples without provider-specific fixtures", () => {
    expect(examples.map(({ id }) => id)).toEqual(["styled_polyline", "pending", "failed"])
    expect(examples.every(({ sourceType }) => sourceType === "generic")).toBe(true)
  })
})
