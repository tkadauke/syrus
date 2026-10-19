import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { toolCardContextForExample, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { setSlugReferenceRegistryForTests } from "@app/lib/slugReferenceRegistry"
import clearCanvasToolCard from "./clear_canvas"
import deleteElementToolCard from "./delete_element"
import drawArrowToolCard from "./draw_arrow"
import drawEmbedToolCard from "./draw_embed"
import drawFrameToolCard from "./draw_frame"
import { examples as drawFrameExamples } from "./draw_frame"
import drawFreedrawToolCard from "./draw_freedraw"
import drawImageToolCard from "./draw_image"
import drawLineToolCard, { examples as drawLineExamples } from "./draw_line"
import drawShapeToolCard from "./draw_shape"
import drawTextToolCard from "./draw_text"
import moveElementToolCard, { examples as moveElementExamples } from "./move_element"

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
    expectedDetails: ["iframe", "https://example.com/card", "15 / 25", "400 × 225"]
  },
  {
    card: drawImageToolCard,
    action: "Drew image",
    input: { data_url: "data:image/png;base64,AA==", mime_type: "image/png", file_id: "input-file", x: 16, y: 26, width: 120, height: 90 },
    expectedDetails: ["image/png", "input-file", "16", "26", "120", "90"]
  },
  {
    card: moveElementToolCard,
    action: "Moved element",
    input: { id: "move-me", x: 17, y: 27 },
    expectedDetails: ["el_abc123", "(17, 27)"]
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
    const expectedSummary = card.toolName === "move_element" ? `${action} · el_abc123 · v4` : `${action} · el_abc123`
    expect(card.collapsedSummary?.(context({ toolName: card.toolName, parsedResult }))).toBe(expectedSummary)

    render(<>{card.renderExpanded(context({ toolName: card.toolName, parsedResult }))}</>)
    expect(screen.getByText(action)).toBeInTheDocument()
    expect(screen.getByText("el_abc123")).toBeInTheDocument()
    expect(screen.getByText("v4")).toBeInTheDocument()
  })

  it.each(CARDS)("$card.toolName includes its representative tool input details", ({ card, action, input, expectedDetails }) => {
    const parsedResult = { id: "el_abc123", version: 1 }
    const type = typeof input.type === "string" ? ` (${input.type})` : ""
    const endpoints = card === drawArrowToolCard ? ` ${input.from_id} → ${input.to_id}` : ""
    const expectedSummary = card.toolName === "move_element" ? `${action} · el_abc123 · To (17, 27) · v1` : `${action}${type}${endpoints} · el_abc123`

    expect(card.collapsedSummary?.(context({ toolName: card.toolName, input, parsedResult }))).toBe(expectedSummary)

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

  it("shows the supported frame name, bounds, id, and version with wrapping-safe layout", () => {
    const input = {
      type: "magicframe",
      name: "Release overview",
      x: 14,
      y: 24,
      width: 320,
      height: 180
    }

    render(<>{drawFrameToolCard.renderExpanded(context({ toolName: "draw_frame", input, parsedResult: { id: "frame-1", version: 6 } }))}</>)

    for (const value of ["Release overview", "14", "24", "320", "180", "frame-1", "v6"]) expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.getByText("Release overview")).toHaveClass("break-all")
    expect(screen.getByText("Release overview").parentElement?.parentElement).toHaveClass("flex-wrap")
    expect(screen.getByText("frame-1")).toHaveClass("break-all")
  })

  it("accepts a frame name and wrapped provider-agnostic result envelope", () => {
    const parsedResult = { result: { id: "wrapped-frame", version: 3 } }
    const input = { name: "System map", x: 0, y: 0, width: 800, height: 600 }

    expect(drawFrameToolCard.collapsedSummary?.(context({ toolName: "draw_frame", input, parsedResult }))).toBe("Drew frame · wrapped-frame")
    render(<>{drawFrameToolCard.renderExpanded(context({ toolName: "draw_frame", input, parsedResult }))}</>)

    expect(screen.getByText("System map")).toBeInTheDocument()
    expect(screen.getByText("wrapped-frame")).toBeInTheDocument()
    expect(screen.getByText("v3")).toBeInTheDocument()
  })

  it("renders catalog examples for full, wrapped, failed, and empty frame results", () => {
    expect(drawFrameExamples.map(({ id }) => id)).toEqual(["named_frame", "wrapped_result", "invalid_bounds", "pending"])
    expect(drawFrameExamples.every(({ sourceType }) => sourceType === "generic")).toBe(true)

    const failure = toolCardContextForExample(
      "draw_frame",
      drawFrameExamples.find(({ id }) => id === "invalid_bounds")!
    )
    expect(drawFrameToolCard.collapsedSummary?.(failure)).toBe("Drew frame failed: width must be greater than zero")
    const { unmount } = render(<>{drawFrameToolCard.renderExpanded(failure)}</>)
    expect(screen.getByText("Drew frame failed")).toBeInTheDocument()
    expect(screen.getByText("width must be greater than zero")).toBeInTheDocument()
    expect(screen.getByText("Check the canvas for a partial edit before retrying.")).toBeInTheDocument()
    unmount()

    const pending = toolCardContextForExample(
      "draw_frame",
      drawFrameExamples.find(({ id }) => id === "pending")!
    )
    expect(drawFrameToolCard.collapsedSummary?.(pending)).toBe("Drew frame pending")
    render(<>{drawFrameToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
  })

  it("shows type-aware line and freehand details", () => {
    const { unmount } = render(
      <>
        {drawLineToolCard.renderExpanded(
          context({
            input: {
              x: 1,
              y: 2,
              type: "arrow",
              width: 10,
              height: 20,
              points: [[0, 0], { x: 5, y: 5 }, [10, 0]],
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
    expect(screen.getByText("(0, 0) → (10, 0)")).toBeInTheDocument()
    for (const value of ["red", "3", "dot", "10", "20"]) expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.getAllByText("arrow")).toHaveLength(2)
    expect(screen.getByLabelText("red")).toHaveAttribute("style", "background-color: red;")
    const points = screen.getByText("3 points").closest("details")
    expect(points).toHaveClass("min-w-0", "max-w-full")
    expect(points?.querySelector("ol")).toHaveClass("sm:grid-cols-2")
    expect(points?.querySelectorAll("li")).toHaveLength(3)
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

  it("shows every arrow field with copyable bindings and wrapping-safe layout", () => {
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: vi.fn().mockResolvedValue(undefined) } })
    const input = {
      from_id: "source-element-with-a-long-id",
      to_id: "target-element-with-a-long-id",
      label: "Moves through review",
      start_arrowhead: "dot",
      end_arrowhead: "arrow",
      color: "#b6492e",
      stroke_width: 3
    }
    const parsedResult = { result: { id: "arrow-1", label_id: "arrow-label-1", version: 8 } }

    expect(drawArrowToolCard.collapsedSummary?.(context({ toolName: "draw_arrow", input, parsedResult }))).toBe(
      "Drew arrow source-element-with-a-long-id → target-element-with-a-long-id · arrow-1"
    )
    render(<>{drawArrowToolCard.renderExpanded(context({ toolName: "draw_arrow", input, parsedResult }))}</>)

    for (const value of ["Moves through review", "#b6492e", "v8"]) expect(screen.getByText(value, { exact: true })).toBeInTheDocument()
    expect(screen.getByText("Start arrowhead: dot")).toBeInTheDocument()
    expect(screen.getByText("End arrowhead: arrow")).toBeInTheDocument()
    expect(screen.getByText("Stroke width: 3")).toBeInTheDocument()
    expect(screen.getByLabelText("#b6492e")).toHaveStyle({ backgroundColor: "#b6492e" })
    for (const id of ["source-element-with-a-long-id", "target-element-with-a-long-id", "arrow-1", "arrow-label-1"]) {
      const copy = screen.getByRole("button", { name: `Copy ${id} to clipboard` })
      expect(copy).toHaveClass("max-w-full")
      fireEvent.click(copy)
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith(id)
    }
    expect(screen.getByText("→").parentElement).toHaveClass("flex-wrap", "sm:flex-nowrap")
  })

  it("renders empty and malformed arrow results without inventing fields", () => {
    expect(drawArrowToolCard.collapsedSummary?.(context({ toolName: "draw_arrow", input: {} }))).toBe("Drew arrow pending")
    const { unmount } = render(<>{drawArrowToolCard.renderExpanded(context({ toolName: "draw_arrow", input: {} }))}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
    unmount()

    render(<>{drawArrowToolCard.renderExpanded(context({ toolName: "draw_arrow", input: {}, parsedResult: {} }))}</>)
    expect(screen.getByText("Result did not include an element ID")).toBeInTheDocument()
    expect(screen.queryByText("From → To")).not.toBeInTheDocument()
  })

  it("renders embed links as safe external anchors", () => {
    const { unmount } = render(
      <>
        {drawEmbedToolCard.renderExpanded(
          context({ input: { link: "https://example.com/embed", x: 1, y: 2, width: 3, height: 4 }, parsedResult: { id: "embed-1", version: 1 } })
        )}
      </>
    )
    const link = screen.getByRole("link", { name: "https://example.com/embed" })
    expect(link).toHaveAttribute("target", "_blank")
    expect(link).toHaveAttribute("rel", "noreferrer noopener")
    expect(screen.getByText("example.com")).toBeInTheDocument()
    expect(link).toHaveClass("min-w-0")
    expect(link.querySelector(".break-all")).toHaveTextContent("https://example.com/embed")
    unmount()

    render(
      <>
        {drawEmbedToolCard.renderExpanded(
          context({
            input: { type: "embeddable", link: "javascript:alert(1)", x: 5, y: 6, width: 320, height: 180 },
            parsedResult: { id: "embed-unsafe", version: 2 }
          })
        )}
      </>
    )
    expect(screen.queryByRole("link", { name: /javascript:/ })).not.toBeInTheDocument()
    expect(screen.getByText("javascript:alert(1)")).toHaveClass("break-all")
    expect(screen.getByText("javascript:alert(1)").parentElement).toHaveAttribute("aria-invalid", "true")
    unmount()

    render(
      <>
        {drawEmbedToolCard.renderExpanded(
          context({
            input: { type: "iframe", link: "https://example.com/embed", x: 10, y: 20, width: 640, height: 360 },
            parsedResult: { result: { id: "wrapped-embed", version: 9 } }
          })
        )}
      </>
    )
    for (const value of ["iframe", "10 / 20", "640 × 360", "wrapped-embed", "v9"]) expect(screen.getByText(value)).toBeInTheDocument()
    unmount()
  })

  it("shows literal wrapped draw_text content, typography, position, links, and a wrapped result envelope", () => {
    setSlugReferenceRegistryForTests([
      {
        prefix: "JOB",
        type: "job",
        displayLabel: "Job",
        copyable: true,
        linkable: true,
        previewAvailable: false,
        linkifiesGeneratedText: true,
        hrefTemplate: "/jobs/:id",
        mobileInteractionHints: {},
        pluginPreviewComponent: null
      }
    ])
    const content = `**Literal markdown** JOB-42 https://example.com/Foo_(bar).\n${Array.from({ length: 6 }, (_, index) => `canvas line ${index + 1}`).join("\n")}`
    render(
      <MemoryRouter>
        {drawTextToolCard.renderExpanded(context({ input: { content, x: 12, y: 34, font_size: 24 }, parsedResult: { result: { id: "text-1", version: 5 } } }))}
      </MemoryRouter>
    )

    expect(screen.getByText("text-1")).toBeInTheDocument()
    expect(screen.getByText("v5")).toBeInTheDocument()
    expect(screen.getByTestId("text-preview-content")).toHaveTextContent("**Literal markdown**", { normalizeWhitespace: false })
    expect(screen.queryByText("Literal markdown", { selector: "strong" })).not.toBeInTheDocument()
    for (const value of ["12", "34", "24"]) expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "https://example.com/Foo_(bar)" })).toHaveAttribute("href", "https://example.com/Foo_(bar)")
    expect(screen.getByRole("link", { name: "https://example.com/Foo_(bar)" })).toHaveAttribute("target", "_blank")

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog", { name: "Content" })).getByText(/canvas line 6/)).toBeInTheDocument()
    setSlugReferenceRegistryForTests(null)
  })

  it("shows an explicit empty text value and missing-result state", () => {
    const { unmount } = render(
      <>{drawTextToolCard.renderExpanded(context({ input: { content: "", x: 0, y: 0 }, parsedResult: { id: "text-empty", version: 1 } }))}</>
    )
    expect(screen.getByText("—")).toBeInTheDocument()
    expect(screen.getAllByText("0")).toHaveLength(2)
    unmount()

    render(<>{drawTextToolCard.renderExpanded(context({ input: { content: "note", x: 1, y: 2 }, parsedResult: { result: {} } }))}</>)
    expect(screen.getByText("Result did not include an element ID")).toBeInTheDocument()
  })

  it("renders draw_text limit errors through the shared failure card", () => {
    const toolContext = context({
      toolName: "draw_text",
      input: { content: "Blocked", x: 1, y: 2 },
      resultError: true,
      resultBody: "Canvas element limit exceeded",
      parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" }
    })

    expect(drawTextToolCard.collapsedSummary?.(toolContext)).toBe("Drew text failed: Canvas element limit exceeded")
    render(<>{drawTextToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Drew text failed")).toBeInTheDocument()
    expect(screen.getByText("Whiteboard::Canvas::ElementLimitExceeded")).toBeInTheDocument()
  })

  it("renders draw_embed pending, malformed, and failure states", () => {
    expect(drawEmbedToolCard.collapsedSummary?.(context({ toolName: "draw_embed" }))).toBe("Drew embed pending")
    const { unmount } = render(<>{drawEmbedToolCard.renderExpanded(context({ toolName: "draw_embed" }))}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
    unmount()

    const malformed = render(<>{drawEmbedToolCard.renderExpanded(context({ toolName: "draw_embed", parsedResult: {} }))}</>)
    expect(screen.getByText("Result did not include an element ID")).toBeInTheDocument()
    malformed.unmount()

    const failed = context({
      toolName: "draw_embed",
      input: { type: "iframe", link: "https://example.com/embed", x: 1, y: 2, width: 0, height: 4 },
      resultError: true,
      resultBody: "width must be positive",
      parsedResult: { message: "width must be positive", retryable: false }
    })
    expect(drawEmbedToolCard.collapsedSummary?.(failed)).toBe("Drew embed failed: width must be positive")
    render(<>{drawEmbedToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Drew embed failed")).toBeInTheDocument()
    expect(screen.getByText("width must be positive")).toBeInTheDocument()
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

  it("handles wrapped line results and exports provider-agnostic catalog examples", () => {
    const input = {
      points: [
        [0, 1],
        [20, 30]
      ],
      stroke_width: 4,
      color: "#123456",
      start_arrowhead: "none",
      end_arrowhead: "triangle"
    }
    render(<>{drawLineToolCard.renderExpanded(context({ toolName: "draw_line", input, parsedResult: { result: { id: "wrapped-line", version: 8 } } }))}</>)

    for (const value of ["wrapped-line", "v8", "2 points", "(0, 1) → (20, 30)", "4", "none", "triangle", "#123456"])
      expect(screen.getByText(value)).toBeInTheDocument()
    expect(drawLineExamples.map((example) => example.id)).toEqual(["styled_polyline", "pending", "element_limit"])
    expect(drawLineExamples.every((example) => example.sourceType === "generic")).toBe(true)
  })

  it("renders line failure and empty-result states through the shared cards", () => {
    const failed = context({
      toolName: "draw_line",
      input: {
        x: 1,
        y: 2,
        points: [
          [0, 0],
          [10, 10]
        ]
      },
      resultError: true,
      resultBody: "Canvas element limit exceeded",
      parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" }
    })
    expect(drawLineToolCard.collapsedSummary?.(failed)).toBe("Drew line failed: Canvas element limit exceeded")
    const { unmount } = render(<>{drawLineToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Drew line failed")).toBeInTheDocument()
    expect(screen.getByText("Whiteboard::Canvas::ElementLimitExceeded")).toBeInTheDocument()
    unmount()

    const pending = context({ toolName: "draw_line", input: { x: 1, y: 2 } })
    expect(drawLineToolCard.collapsedSummary?.(pending)).toBe("Drew line pending")
    render(<>{drawLineToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
  })
})

describe("move_element tool card", () => {
  it("provides provider-agnostic examples for coordinates, target elements, and failures", () => {
    expect(moveElementExamples.map((example) => example.id)).toEqual(["move_by_coordinates", "move_to_element", "unknown_element"])
    expect(moveElementExamples.every((example) => example.sourceType === "generic")).toBe(true)
  })

  it("shows coordinate destination, previous position, computed delta, and version", () => {
    const toolContext = context({
      toolName: "move_element",
      input: { id: "shape-1", x: 240, y: 120 },
      parsedResult: { id: "shape-1", x: 240, y: 120, previous_x: 100, previous_y: 80, version: 3 }
    })

    expect(moveElementToolCard.collapsedSummary?.(toolContext)).toBe("Moved element · shape-1 · To (240, 120) · v3")
    render(<>{moveElementToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("shape-1")).toHaveClass("min-w-0", "break-all")
    expect(screen.getByText("(240, 120)")).toBeInTheDocument()
    expect(screen.getByText("(100, 80)")).toBeInTheDocument()
    expect(screen.getByText("(140, 40)")).toBeInTheDocument()
    expect(screen.getByText("v3")).toBeInTheDocument()
    expect(screen.getByText("X / Y").closest("dl")).toHaveClass("sm:grid-cols-2")
  })

  it("derives from/to ids from a wrapped result without call input", () => {
    const toolContext = context({
      toolName: "move_element",
      parsedResult: { result: { from_id: "shape-1", to_id: "frame-2", delta_x: -20, delta_y: 15, version: 4 } }
    })

    expect(moveElementToolCard.collapsedSummary?.(toolContext)).toBe("Moved element · shape-1 · To frame-2 · v4")
    render(<>{moveElementToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("shape-1")).toBeInTheDocument()
    expect(screen.getByText("frame-2")).toHaveClass("break-all")
    expect(screen.getByText("(-20, 15)")).toBeInTheDocument()
    expect(screen.getByText("v4")).toBeInTheDocument()
  })

  it("uses call input when the result only returns id and version", () => {
    const toolContext = context({ toolName: "move_element", input: { id: "shape-2", x: 17, y: 27 }, parsedResult: { id: "shape-2", version: 5 } })

    expect(moveElementToolCard.collapsedSummary?.(toolContext)).toBe("Moved element · shape-2 · To (17, 27) · v5")
    expect(moveElementToolCard.collapsedSummary?.(context({ toolName: "move_element", parsedResult: { id: "shape-2", version: 5 } }))).toBe(
      "Moved element · shape-2 · v5"
    )
    render(<>{moveElementToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("(17, 27)")).toBeInTheDocument()
  })

  it("renders unknown-element failures through the shared failure card", () => {
    const toolContext = context({
      toolName: "move_element",
      input: { id: "missing", x: 10, y: 20 },
      parsedResult: { message: "Unknown element: missing", retryable: false },
      resultBody: '{"message":"Unknown element: missing","retryable":false}',
      resultError: true
    })

    expect(moveElementToolCard.collapsedSummary?.(toolContext)).toBe("Moved element failed: Unknown element: missing")
    render(<>{moveElementToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Moved element failed")).toBeInTheDocument()
    expect(screen.getByText("Unknown element: missing")).toBeInTheDocument()
    expect(screen.getByText("Check before retrying")).toBeInTheDocument()
  })

  it("renders pending and empty-result states", () => {
    expect(moveElementToolCard.collapsedSummary?.(context({ toolName: "move_element" }))).toBe("Moved element pending")
    const empty = context({ toolName: "move_element", parsedResult: {} })
    expect(moveElementToolCard.collapsedSummary?.(empty)).toBe("Moved element returned no element")
    render(<>{moveElementToolCard.renderExpanded(empty)}</>)
    expect(screen.getByText("Result did not include an element ID")).toBeInTheDocument()
  })
})
