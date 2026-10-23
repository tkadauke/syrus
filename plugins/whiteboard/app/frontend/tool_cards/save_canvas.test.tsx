import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { fetchWhiteboardSnapshot } from "@app/api/chats"
import saveCanvasToolCard, { examples } from "./save_canvas"

vi.mock("@app/api/chats", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@app/api/chats")>()),
  fetchWhiteboardSnapshot: vi.fn()
}))

vi.mock("@excalidraw/excalidraw", () => ({
  exportToSvg: vi.fn(async () => document.createElementNS("http://www.w3.org/2000/svg", "svg"))
}))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "save_canvas",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("save_canvas tool card", () => {
  beforeEach(() => {
    vi.mocked(fetchWhiteboardSnapshot).mockResolvedValue({
      id: 9,
      name: "Diagram v1",
      snapshot_kind: "manual",
      element_count: 4,
      created_at: "2026-10-23T12:00:00Z",
      scene_json: { elements: [{ id: "box", type: "rectangle" }], appState: {}, files: {} }
    })
  })

  it("registers under the exact MCP tool name", () => {
    expect(saveCanvasToolCard.toolName).toBe("save_canvas")
  })

  it("renders every saved result field, links, and a lazy full-size preview", async () => {
    const parsedResult = { saved: true, snapshot_id: 9, name: "Diagram v1", element_count: 4, chat_session_id: 12, version: 2 }
    expect(saveCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe('Saved snapshot "Diagram v1"')

    render(<>{saveCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Saved snapshot")).toBeInTheDocument()
    expect(screen.getByText("SNAPSHOT-9")).toBeInTheDocument()
    expect(screen.getByText("v2")).toBeInTheDocument()
    expect(screen.getByText("Diagram v1")).toBeInTheDocument()
    expect(screen.getByText("4 elements")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "SNAPSHOT-9" })).toHaveAttribute("href", "/chats/12?workspace=plugin%3Awhiteboard.canvas")
    expect(screen.getByText("Rendering snapshot...")).toBeInTheDocument()

    const thumbnail = screen.getByRole("button", { name: "Open Diagram v1" })
    expect(thumbnail).toHaveClass("w-full", "sm:w-72")
    await waitFor(() => expect(screen.getByRole("img", { name: "Diagram v1" })).toHaveAttribute("src", expect.stringContaining("data:image/svg+xml")))
    fireEvent.click(thumbnail)
    expect(screen.getByRole("dialog", { name: "Whiteboard snapshot" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open whiteboard" })).toHaveAttribute("href", "/chats/12?workspace=plugin%3Awhiteboard.canvas")
    expect(screen.getByRole("link", { name: "View in media" })).toHaveAttribute("href", "/chats/12?workspace=media")
    expect(screen.getByText("Snapshot ID")).toBeInTheDocument()
    expect(screen.getByText("Version")).toBeInTheDocument()
    expect(fetchWhiteboardSnapshot).toHaveBeenCalledWith("12", "9")
  })

  it("renders the attempted name and version for an empty-canvas non-save", () => {
    const parsedResult = { saved: false, reason: "canvas is empty", version: 1 }
    expect(saveCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Canvas not saved (empty)")

    render(<>{saveCanvasToolCard.renderExpanded(context({ parsedResult, input: { name: "Empty plan" } }))}</>)
    expect(screen.getByText("Not saved")).toBeInTheDocument()
    expect(screen.getByText("v1")).toBeInTheDocument()
    expect(screen.getByText("canvas is empty")).toBeInTheDocument()
    expect(screen.getByText("Empty plan")).toBeInTheDocument()
  })

  it("keeps snapshot metadata available when the preview cannot be rendered", async () => {
    vi.mocked(fetchWhiteboardSnapshot).mockRejectedValueOnce(new Error("offline"))
    const parsedResult = { saved: true, snapshot_id: 9, name: "Diagram v1", element_count: 4, chat_session_id: 12, version: 2 }

    render(<>{saveCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)

    await waitFor(() => expect(screen.getByText("Snapshot preview unavailable")).toBeInTheDocument())
    expect(screen.getByText("SNAPSHOT-9")).toBeInTheDocument()
  })

  it("shows a localized structured card for tool errors", () => {
    const errorContext = context({ resultError: true, resultBody: "database unavailable", input: { name: "Plan" } })
    expect(saveCanvasToolCard.collapsedSummary?.(errorContext)).toContain("failed")

    render(<>{saveCanvasToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Save canvas snapshot failed")).toBeInTheDocument()
    expect(screen.getByText('Save canvas snapshot "Plan"')).toBeInTheDocument()
    expect(screen.getByText("database unavailable")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing saved flag)", () => {
    expect(saveCanvasToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(saveCanvasToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("publishes provider-agnostic catalog examples for success, empty, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["saved_snapshot", "empty_canvas", "error"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
