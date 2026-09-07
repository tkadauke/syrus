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
// element-mutator family (EPIC-292 / JOB-4223) -- draw_shape, draw_text,
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

    expect(card.collapsedSummary?.(context({ toolName: card.toolName, input, parsedResult }))).toBe(
      `${action} (rectangle) · el_abc123`
    )

    render(<>{card.renderExpanded(context({ toolName: card.toolName, input, parsedResult }))}</>)
    expect(screen.getByText("rectangle")).toBeInTheDocument()
  })

  it.each(CARDS)("$card.toolName falls back to null for a malformed payload (missing id)", ({ card }) => {
    expect(card.collapsedSummary?.(context({ toolName: card.toolName, parsedResult: { oops: true } }))).toBeNull()
    expect(card.renderExpanded(context({ toolName: card.toolName, parsedResult: { oops: true } }))).toBeNull()
  })

  it.each(CARDS)("$card.toolName falls back to null for a non-object payload", ({ card }) => {
    expect(card.renderExpanded(context({ toolName: card.toolName, parsedResult: "not json" }))).toBeNull()
  })
})
