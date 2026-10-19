import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import clearCanvasToolCard from "./clear_canvas"
import deleteElementToolCard from "./delete_element"
import drawArrowToolCard from "./draw_arrow"
import drawEmbedToolCard from "./draw_embed"
import drawFrameToolCard from "./draw_frame"
import drawFreedrawToolCard from "./draw_freedraw"
import drawImageToolCard from "./draw_image"
import drawLineToolCard from "./draw_line"
import drawShapeToolCard from "./draw_shape"
import drawTextToolCard from "./draw_text"
import moveElementToolCard from "./move_element"

// Aggregation/parity test for the whiteboard plugin's `{ id, version }`
// element-mutator family (the pending-action tool-card work) -- draw_shape, draw_text,
// draw_line, draw_arrow, draw_freedraw, draw_frame, draw_embed, draw_image,
// move_element, and delete_element all share the same result shape and
// ElementActionCard renderer (see ../whiteboardToolCard.tsx), so one shared
// test proves the whole family stays wired up and consistent instead of
// duplicating the same assertions across ten near-identical files.
const CARDS: { card: ToolCardRenderer; action: string }[] = [
  { card: drawShapeToolCard, action: "Drew shape" },
  { card: drawTextToolCard, action: "Drew text" },
  { card: drawLineToolCard, action: "Drew line" },
  { card: drawArrowToolCard, action: "Drew arrow" },
  { card: drawFreedrawToolCard, action: "Drew freehand path" },
  { card: drawFrameToolCard, action: "Drew frame" },
  { card: drawEmbedToolCard, action: "Drew embed" },
  { card: drawImageToolCard, action: "Drew image" },
  { card: moveElementToolCard, action: "Moved element" },
  { card: deleteElementToolCard, action: "Deleted element" }
]

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "draw_shape",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("whiteboard element-action tool cards", () => {
  it("has no duplicate tool names", () => {
    const names = CARDS.map(({ card }) => card.toolName)
    expect(new Set(names).size).toBe(names.length)
  })

  it.each(CARDS)("$card.toolName registers under its exact MCP tool name and renders the id/version result", ({ card, action }) => {
    expect(card.toolName).toBeTruthy()

    const parsedResult = { id: "el_abc123", version: 4 }
    expect(card.collapsedSummary?.(context({ toolName: card.toolName, parsedResult }))).toBe(`${action} · el_abc123`)

    render(<>{card.renderExpanded(context({ toolName: card.toolName, parsedResult }))}</>)
    expect(screen.getByText(action)).toBeInTheDocument()
    expect(screen.getByText("el_abc123")).toBeInTheDocument()
    expect(screen.getByText("v4")).toBeInTheDocument()
  })

  it.each(CARDS)("$card.toolName includes the tool call's own input as concise detail rows", ({ card, action }) => {
    const parsedResult = { id: "el_abc123", version: 1 }
    const input = { type: "rectangle", x: 10, y: 20 }

    expect(card.collapsedSummary?.(context({ toolName: card.toolName, input, parsedResult }))).toBe(`${action} (rectangle) · el_abc123`)

    render(<>{card.renderExpanded(context({ toolName: card.toolName, input, parsedResult }))}</>)
    expect(screen.getByText("rectangle")).toBeInTheDocument()
  })

  it("shows shape geometry and color with a swatch", () => {
    render(
      <>
        {drawShapeToolCard.renderExpanded(
          context({ input: { type: "diamond", x: 10, y: 20, width: 300, height: 120, color: "#ffcc00" }, parsedResult: { id: "shape-1", version: 2 } })
        )}
      </>
    )

    for (const value of ["diamond", "10", "20", "300", "120", "#ffcc00"]) expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.getByLabelText("#ffcc00")).toHaveStyle({ backgroundColor: "#ffcc00" })
  })

  it("shows type-aware line and freehand details", () => {
    const { unmount } = render(
      <>
        {drawLineToolCard.renderExpanded(
          context({
            input: {
              x: 1,
              y: 2,
              points: [
                [0, 0],
                [5, 5],
                [10, 0]
              ],
              color: "red",
              stroke_width: 3,
              start_arrowhead: "dot",
              end_arrowhead: "arrow"
            },
            parsedResult: { id: "line-1", version: 1 }
          })
        )}
      </>
    )
    expect(screen.getByText("3 points")).toBeInTheDocument()
    for (const value of ["red", "3", "dot", "arrow"]) expect(screen.getByText(value)).toBeInTheDocument()
    unmount()

    render(
      <>
        {drawFreedrawToolCard.renderExpanded(
          context({
            input: {
              x: 4,
              y: 5,
              points: [
                [0, 0],
                [1, 1]
              ],
              pressures: [0.3, 0.7],
              simulate_pressure: false
            },
            parsedResult: { id: "free-1", version: 1 }
          })
        )}
      </>
    )
    expect(screen.getAllByText("2 points")).toHaveLength(2)
    expect(screen.getByText("No")).toBeInTheDocument()
  })

  it("shows arrow label ids and image file metadata from wrapped results", () => {
    const { unmount } = render(
      <>
        {drawArrowToolCard.renderExpanded(
          context({ input: { from_id: "start", to_id: "finish" }, parsedResult: { result: { id: "arrow-1", label_id: "label-1", version: 7 } } })
        )}
      </>
    )
    expect(screen.getByText("label-1")).toBeInTheDocument()
    unmount()

    render(
      <>
        {drawImageToolCard.renderExpanded(
          context({
            input: { data_url: "data:image/png;base64,AA==", mime_type: "image/png", file_id: "requested-file", x: 1, y: 2, width: 30, height: 40 },
            parsedResult: { result: { id: "image-1", file_id: "actual-file", version: 3 } }
          })
        )}
      </>
    )
    expect(screen.getAllByText("actual-file")).toHaveLength(2)
    expect(screen.getAllByText("image/png")).toHaveLength(2)
    expect(screen.getByRole("button", { name: "Open actual-file" })).toBeInTheDocument()
  })

  it("renders embed links as safe external anchors and text content as markdown", () => {
    const { unmount } = render(
      <>
        {drawEmbedToolCard.renderExpanded(
          context({ input: { link: "https://example.com/embed", x: 1, y: 2, width: 3, height: 4 }, parsedResult: { id: "embed-1", version: 1 } })
        )}
      </>
    )
    const link = screen.getByRole("link", { name: "https://example.com/embed" })
    expect(link).toHaveAttribute("target", "_blank")
    expect(link).toHaveAttribute("rel", "noreferrer")
    unmount()

    render(
      <>
        {drawTextToolCard.renderExpanded(
          context({ input: { content: "**Important** note", x: 1, y: 2, font_size: 24 }, parsedResult: { id: "text-1", version: 1 } })
        )}
      </>
    )
    expect(screen.getByText("Important").tagName).toBe("STRONG")
    expect(screen.getByText("24")).toBeInTheDocument()
  })

  it("renders a specific failure card for a failed draw_arrow call", () => {
    const toolContext = context({
      toolName: "draw_arrow",
      input: { from_id: "start", to_id: "finish", label: "handoff" },
      resultError: true,
      resultBody: "could not find endpoint",
      parsedResult: { message: "could not find endpoint", retryable: false }
    })

    expect(drawArrowToolCard.collapsedSummary?.(toolContext)).toBe("Drew arrow failed: could not find endpoint")

    render(<>{drawArrowToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Drew arrow failed")).toBeInTheDocument()
    expect(screen.getByText("Drew arrow from start to finish")).toBeInTheDocument()
    expect(screen.getByText("Check before retrying")).toBeInTheDocument()
    expect(screen.getByText("Check the canvas for a partial edit before retrying.")).toBeInTheDocument()
  })

  it("renders ElementLimitExceeded as a structured failure", () => {
    render(
      <>
        {drawShapeToolCard.renderExpanded(
          context({
            resultError: true,
            resultBody: "Canvas element limit exceeded",
            parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" }
          })
        )}
      </>
    )
    expect(screen.getByText("Canvas element limit exceeded")).toBeInTheDocument()
    expect(screen.getByText("Whiteboard::Canvas::ElementLimitExceeded")).toBeInTheDocument()
  })

  it.each(CARDS)("$card.toolName renders a missing-result state for a malformed payload", ({ card, action }) => {
    expect(card.collapsedSummary?.(context({ toolName: card.toolName, parsedResult: { oops: true } }))).toBe(`${action} returned no element`)
    render(<>{card.renderExpanded(context({ toolName: card.toolName, parsedResult: { oops: true } }))}</>)
    expect(screen.getByText("Result did not include an element ID")).toBeInTheDocument()
  })

  it("renders a pending state when no result has arrived", () => {
    expect(drawShapeToolCard.collapsedSummary?.(context())).toBe("Drew shape pending")
    render(<>{drawShapeToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
  })
})
