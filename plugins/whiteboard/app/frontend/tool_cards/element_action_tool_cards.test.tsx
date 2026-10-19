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
const CARDS: { card: ToolCardRenderer; action: string; input: Record<string, unknown>; expectedDetails: string[] }[] = [
  {
    card: drawShapeToolCard,
    action: "Drew shape",
    input: { type: "rectangle", x: 10, y: 20, width: 80, height: 40, color: "blue" },
    expectedDetails: ["rectangle", "10", "20", "80", "40", "blue"]
  },
  {
    card: drawTextToolCard,
    action: "Drew text",
    input: { content: "Text body", x: 11, y: 21, font_size: 18 },
    expectedDetails: ["Text body", "11", "21", "18"]
  },
  {
    card: drawLineToolCard,
    action: "Drew line",
    input: {
      type: "line",
      x: 12,
      y: 22,
      points: [
        [0, 0],
        [5, 5]
      ],
      stroke_width: 2
    },
    expectedDetails: ["line", "12", "22", "2 points", "2"]
  },
  {
    card: drawArrowToolCard,
    action: "Drew arrow",
    input: { from_id: "source-id", to_id: "target-id", label: "Flow" },
    expectedDetails: ["source-id", "target-id", "Flow"]
  },
  {
    card: drawFreedrawToolCard,
    action: "Drew freehand path",
    input: {
      x: 13,
      y: 23,
      points: [
        [0, 0],
        [1, 1]
      ],
      pressures: [0.25, 0.75],
      simulate_pressure: false
    },
    expectedDetails: ["13", "23", "2 points", "0.25, 0.75", "No"]
  },
  {
    card: drawFrameToolCard,
    action: "Drew frame",
    input: { type: "magicframe", x: 14, y: 24, width: 320, height: 180, name: "Overview" },
    expectedDetails: ["magicframe", "14", "24", "320", "180", "Overview"]
  },
  {
    card: drawEmbedToolCard,
    action: "Drew embed",
    input: { type: "iframe", link: "https://example.com/card", x: 15, y: 25, width: 400, height: 225 },
    expectedDetails: ["iframe", "https://example.com/card", "15", "25", "400", "225"]
  },
  {
    card: drawImageToolCard,
    action: "Drew image",
    input: { data_url: "data:image/png;base64,AA==", mime_type: "image/png", file_id: "input-file", x: 16, y: 26, width: 120, height: 90 },
    expectedDetails: ["image/png", "input-file", "16", "26", "120", "90"]
  },
  { card: deleteElementToolCard, action: "Deleted element", input: { id: "delete-me" }, expectedDetails: ["delete-me"] }
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

  it.each(CARDS)("$card.toolName includes its representative tool input details", ({ card, action, input, expectedDetails }) => {
    const parsedResult = { id: "el_abc123", version: 1 }
    const type = typeof input.type === "string" ? ` (${input.type})` : ""

    expect(card.collapsedSummary?.(context({ toolName: card.toolName, input, parsedResult }))).toBe(`${action}${type} · el_abc123`)

    render(<>{card.renderExpanded(context({ toolName: card.toolName, input, parsedResult }))}</>)
    for (const detail of expectedDetails) expect(screen.getAllByText(detail).length).toBeGreaterThan(0)
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
    expect(screen.getByText("2 points")).toBeInTheDocument()
    expect(screen.getByText("0.3, 0.7")).toBeInTheDocument()
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

describe("move_element tool card", () => {
  it("summarizes and renders a coordinate move with its computed delta", () => {
    const toolContext = context({
      toolName: "move_element",
      input: { id: "shape-1", x: 240, y: 120 },
      parsedResult: { id: "shape-1", x: 240, y: 120, previous_x: 100, previous_y: 80, version: 3 }
    })

    expect(moveElementToolCard.collapsedSummary?.(toolContext)).toBe("Moved element · shape-1 · to (240, 120) · v3")
    render(<>{moveElementToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("shape-1")).toHaveClass("min-w-0", "break-all")
    expect(screen.getByText("(240, 120)")).toBeInTheDocument()
    expect(screen.getByText("(100, 80)")).toBeInTheDocument()
    expect(screen.getByText("(140, 40)")).toBeInTheDocument()
    expect(screen.getByText("v3")).toBeInTheDocument()
    expect(screen.getByText("Position").closest("dl")).toHaveClass("sm:grid-cols-2")
  })

  it("derives from/to ids from a wrapped result without call input", () => {
    const toolContext = context({
      toolName: "move_element",
      parsedResult: { result: { from_id: "shape-1", to_id: "frame-2", delta_x: -20, delta_y: 15, version: 4 } }
    })

    expect(moveElementToolCard.collapsedSummary?.(toolContext)).toBe("Moved element · shape-1 · to frame-2 · v4")
    render(<>{moveElementToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("shape-1")).toBeInTheDocument()
    expect(screen.getByText("frame-2")).toBeInTheDocument()
    expect(screen.getByText("(-20, 15)")).toBeInTheDocument()
    expect(screen.getByText("v4")).toBeInTheDocument()
  })

  it("falls back to expanded input fields when the result only returns id/version", () => {
    const toolContext = context({ toolName: "move_element", input: { id: "shape-2", x: 17, y: 27 }, parsedResult: { id: "shape-2", version: 5 } })

    expect(moveElementToolCard.collapsedSummary?.(context({ toolName: "move_element", parsedResult: { id: "shape-2", version: 5 } }))).toBe(
      "Moved element · shape-2 · v5"
    )
    render(<>{moveElementToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("(17, 27)")).toBeInTheDocument()
  })

  it("renders unknown-element failures and empty results", () => {
    const failure = context({
      toolName: "move_element",
      input: { id: "missing", x: 10, y: 20 },
      resultError: true,
      resultBody: "Unknown element: missing",
      parsedResult: { message: "Unknown element: missing", retryable: false }
    })
    expect(moveElementToolCard.collapsedSummary?.(failure)).toBe("Moved element failed: Unknown element: missing")
    const { unmount } = render(<>{moveElementToolCard.renderExpanded(failure)}</>)
    expect(screen.getByText("Moved element missing")).toBeInTheDocument()
    expect(screen.getByText("Unknown element: missing")).toBeInTheDocument()
    unmount()

    const empty = context({ toolName: "move_element", parsedResult: {} })
    expect(moveElementToolCard.collapsedSummary?.(empty)).toBe("Moved element returned no element")
    render(<>{moveElementToolCard.renderExpanded(empty)}</>)
    expect(screen.getByText("Result did not include an element ID")).toBeInTheDocument()
  })
})
