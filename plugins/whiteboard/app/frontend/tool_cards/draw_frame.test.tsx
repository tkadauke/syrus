import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import drawFrameToolCard, { examples } from "./draw_frame"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "draw_frame", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("draw_frame tool card", () => {
  it("shows the frame name, bounds, children, element id, and version", () => {
    const view = render(
      <>
        {drawFrameToolCard.renderExpanded(
          context({
            input: {
              type: "magicframe",
              x: 14,
              y: 24,
              width: 320,
              height: 180,
              name: "Overview",
              element_ids: ["shape-1", "text-2"],
              children: [{ id: "arrow-3" }]
            },
            parsedResult: { id: "frame-1", version: 4 }
          })
        )}
      </>
    )

    for (const value of ["Drew frame", "magicframe", "frame-1", "v4", "Overview", "14", "24", "320", "180", "shape-1, text-2", "arrow-3"])
      expect(screen.getByText(value)).toBeInTheDocument()
    expect(view.container.querySelector("dl.grid.min-w-0.gap-2.sm\\:grid-cols-2")).toBeInTheDocument()
    expect(screen.getByText("14").parentElement?.parentElement).toHaveClass("flex-wrap")
    expect(screen.getByText("shape-1, text-2")).toHaveClass("break-all")
  })

  it("accepts the provider-agnostic wrapped MCP result envelope", () => {
    render(
      <>
        {drawFrameToolCard.renderExpanded(
          context({
            input: { type: "frame", x: 0, y: 10, width: 500, height: 250, name: "Wrapped" },
            parsedResult: { result: { id: "wrapped-frame", version: 9 } }
          })
        )}
      </>
    )

    expect(screen.getByText("wrapped-frame")).toBeInTheDocument()
    expect(screen.getByText("v9")).toBeInTheDocument()
    const details = screen.getByText("Details").nextElementSibling
    expect(details).not.toBeNull()
    for (const value of ["0", "10", "500", "250"]) expect(within(details as HTMLElement).getByText(value)).toBeInTheDocument()
  })

  it("keeps structured failures and empty results explicit", () => {
    const failed = context({
      input: { type: "frame", x: 0, y: 0, width: 100, height: 100, name: "Unavailable" },
      resultError: true,
      resultBody: "Canvas element limit exceeded",
      parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" }
    })
    const { unmount } = render(<>{drawFrameToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Drew frame failed")).toBeInTheDocument()
    expect(screen.getByText("Canvas element limit exceeded")).toBeInTheDocument()
    unmount()

    render(<>{drawFrameToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
  })

  it("publishes reviewable success, wrapped, failure, and empty examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["named_frame", "wrapped_result", "element_limit", "pending"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
