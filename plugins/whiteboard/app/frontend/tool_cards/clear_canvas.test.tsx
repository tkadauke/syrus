import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { fetchWhiteboardSnapshot } from "@app/api/chats"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import clearCanvasToolCard, { examples } from "./clear_canvas"

vi.mock("@app/api/chats", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@app/api/chats")>()),
  fetchWhiteboardSnapshot: vi.fn()
}))

vi.mock("@excalidraw/excalidraw", () => ({
  exportToSvg: vi.fn(async () => document.createElementNS("http://www.w3.org/2000/svg", "svg"))
}))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "clear_canvas", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("clear_canvas tool card", () => {
  beforeEach(() => {
    vi.mocked(fetchWhiteboardSnapshot).mockResolvedValue({
      id: 3,
      name: null,
      snapshot_kind: "auto_clear",
      element_count: 4,
      created_at: "2026-10-23T12:00:00Z",
      scene_json: { elements: [{ id: "box", type: "rectangle" }], appState: {}, files: {} }
    })
  })

  it("registers under the exact MCP tool name", () => {
    expect(clearCanvasToolCard.toolName).toBe("clear_canvas")
  })

  it("renders every result field, a linked snapshot, and a responsive full-size preview", async () => {
    const parsedResult = { cleared: true, snapshot_id: 3, element_count: 4, chat_session_id: 12, version: 4 }
    expect(clearCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Cleared canvas (saved as #3)")

    const { container } = render(<>{clearCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Cleared canvas")).toBeInTheDocument()
    expect(screen.getByText("SNAPSHOT-3")).toBeInTheDocument()
    expect(screen.getByText("v4")).toBeInTheDocument()
    expect(screen.getByText("4 elements")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "SNAPSHOT-3" })).toHaveAttribute("href", "/chats/12?workspace=plugin%3Awhiteboard.canvas")
    expect(container.querySelector(".flex.flex-wrap")).toBeInTheDocument()

    const thumbnail = screen.getByRole("button", { name: "Open Snapshot #3" })
    expect(thumbnail).toHaveClass("w-full", "sm:w-72")
    await waitFor(() => expect(screen.getByRole("img", { name: "Snapshot #3" })).toHaveAttribute("src", expect.stringContaining("data:image/svg+xml")))
    fireEvent.click(thumbnail)
    expect(screen.getByRole("dialog", { name: "Whiteboard snapshot" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open whiteboard" })).toHaveAttribute("href", "/chats/12?workspace=plugin%3Awhiteboard.canvas")
    expect(screen.getByRole("link", { name: "View in media" })).toHaveAttribute("href", "/chats/12?workspace=media")
    expect(screen.getByText("Elements cleared")).toBeInTheDocument()
    expect(fetchWhiteboardSnapshot).toHaveBeenCalledWith("12", "3")
  })

  it("renders an already-empty canvas with all returned fields", () => {
    const parsedResult = { cleared: true, snapshot_id: null, element_count: 0, chat_session_id: 12, version: 1 }
    expect(clearCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Cleared canvas")

    render(<>{clearCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Canvas was already empty.")).toBeInTheDocument()
    expect(screen.getByText("Elements cleared")).toBeInTheDocument()
    expect(screen.getByText("0")).toBeInTheDocument()
    expect(screen.getByText("v1")).toBeInTheDocument()
  })

  it("renders the provider-independent MCP content envelope", () => {
    const envelope = {
      content: [{ type: "text", text: JSON.stringify({ cleared: true, snapshot_id: null, element_count: 0, chat_session_id: 12, version: 1 }) }]
    }
    render(<>{clearCanvasToolCard.renderExpanded(context({ parsedResult: normalizedToolCardParsedResult(envelope) }))}</>)
    expect(screen.getByText("Canvas was already empty.")).toBeInTheDocument()
  })

  it("shows a structured card for tool errors", () => {
    const errorContext = context({ resultError: true, resultBody: "snapshot could not be created" })
    expect(clearCanvasToolCard.collapsedSummary?.(errorContext)).toContain("failed")

    render(<>{clearCanvasToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Clear canvas failed")).toBeInTheDocument()
    expect(screen.getByText("snapshot could not be created")).toBeInTheDocument()
    expect(screen.getByText("Check the canvas for a partial clear before retrying.")).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(clearCanvasToolCard.renderExpanded(context({ parsedResult: { cleared: false } }))).toBeNull()
    expect(clearCanvasToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("publishes provider-agnostic catalog examples for success, empty, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["cleared_with_snapshot", "already_empty", "error"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
