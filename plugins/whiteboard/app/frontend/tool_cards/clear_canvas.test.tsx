import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { fetchWhiteboardSnapshot } from "@app/api/chats"
import clearCanvasToolCard, { examples } from "./clear_canvas"

vi.mock("@app/api/chats", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@app/api/chats")>()),
  fetchWhiteboardSnapshot: vi.fn()
}))

vi.mock("@excalidraw/excalidraw", () => ({
  exportToSvg: vi.fn(async () => document.createElementNS("http://www.w3.org/2000/svg", "svg"))
}))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "clear_canvas",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("clear_canvas tool card", () => {
  beforeEach(() => {
    vi.mocked(fetchWhiteboardSnapshot).mockResolvedValue({
      id: 3,
      name: null,
      snapshot_kind: "auto_clear",
      element_count: 5,
      created_at: "2026-10-23T12:00:00Z",
      scene_json: { elements: [{ id: "box", type: "rectangle" }], appState: {}, files: {} }
    })
  })

  it("registers under the exact MCP tool name", () => {
    expect(clearCanvasToolCard.toolName).toBe("clear_canvas")
  })

  it("renders every result field, a linked snapshot, and a responsive full-size preview", async () => {
    const parsedResult = { cleared: true, snapshot_id: 3, element_count: 5, chat_session_id: 12, version: 4 }
    expect(clearCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Cleared canvas (saved as #3)")

    render(<>{clearCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Cleared canvas")).toBeInTheDocument()
    expect(screen.getByText("SNAPSHOT-3")).toBeInTheDocument()
    expect(screen.getByText("v4")).toBeInTheDocument()
    expect(screen.getByText("5 elements")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "SNAPSHOT-3" })).toHaveAttribute("href", "/chats/12?workspace=plugin%3Awhiteboard.canvas")

    const thumbnail = screen.getByRole("button", { name: "Open Auto-saved canvas snapshot" })
    expect(thumbnail).toHaveClass("w-full", "sm:w-72")
    await waitFor(() =>
      expect(screen.getByRole("img", { name: "Auto-saved canvas snapshot" })).toHaveAttribute("src", expect.stringContaining("data:image/svg+xml"))
    )
    fireEvent.click(thumbnail)
    expect(screen.getByRole("dialog", { name: "Whiteboard snapshot" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open whiteboard" })).toHaveAttribute("href", "/chats/12?workspace=plugin%3Awhiteboard.canvas")
    expect(screen.getByRole("link", { name: "View in media" })).toHaveAttribute("href", "/chats/12?workspace=media")
    expect(fetchWhiteboardSnapshot).toHaveBeenCalledWith("12", "3")
  })

  it("uses the owning chat when the result omits a chat id", async () => {
    render(<>{clearCanvasToolCard.renderExpanded(context({ parsedResult: { cleared: true, snapshot_id: 3, version: 4 }, chatSessionId: 21 }))}</>)
    expect(screen.getByRole("link", { name: "SNAPSHOT-3" })).toHaveAttribute("href", "/chats/21?workspace=plugin%3Awhiteboard.canvas")
    await waitFor(() => expect(fetchWhiteboardSnapshot).toHaveBeenCalledWith("21", "3"))
  })

  it("summarizes and renders an already-empty canvas with its version", () => {
    const parsedResult = { cleared: true, snapshot_id: null, version: 1 }
    expect(clearCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Cleared canvas")

    render(<>{clearCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("v1")).toBeInTheDocument()
    expect(screen.getByText("Canvas was already empty.")).toBeInTheDocument()
  })

  it("accepts a wrapped result envelope", () => {
    const parsedResult = { result: { cleared: true, snapshot_id: null, version: 2 } }
    expect(clearCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Cleared canvas")
    render(<>{clearCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("v2")).toBeInTheDocument()
  })

  it("shows a localized structured card for tool errors", () => {
    const errorContext = context({ resultError: true, resultBody: "database unavailable" })
    expect(clearCanvasToolCard.collapsedSummary?.(errorContext)).toContain("failed")
    render(<>{clearCanvasToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Clear canvas failed")).toBeInTheDocument()
    expect(screen.getByText("database unavailable")).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(clearCanvasToolCard.renderExpanded(context({ parsedResult: { cleared: false } }))).toBeNull()
    expect(clearCanvasToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("publishes provider-agnostic catalog examples for success, empty, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["cleared_canvas", "already_empty", "error"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
