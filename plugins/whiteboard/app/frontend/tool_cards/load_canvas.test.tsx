import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import i18n from "i18next"
import type { ToolCardContext } from "@app/pluginToolCards"
import { fetchWhiteboardSnapshot } from "@app/api/chats"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import loadCanvasToolCard, { examples } from "./load_canvas"

vi.mock("@app/api/chats", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@app/api/chats")>()),
  fetchWhiteboardSnapshot: vi.fn()
}))

vi.mock("@excalidraw/excalidraw", () => ({
  exportToSvg: vi.fn(async () => document.createElementNS("http://www.w3.org/2000/svg", "svg"))
}))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "load_canvas",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("load_canvas tool card", () => {
  beforeEach(() => {
    vi.mocked(fetchWhiteboardSnapshot).mockImplementation(async (_chatId, snapshotId) => ({
      id: Number(snapshotId),
      name: snapshotId === "4" ? "Before replacement" : "Loaded plan",
      snapshot_kind: snapshotId === "4" ? "auto_before_load" : "manual",
      element_count: snapshotId === "4" ? 2 : 6,
      created_at: "2026-10-23T12:00:00Z",
      scene_json: { elements: [{ id: `box-${snapshotId}`, type: "rectangle" }], appState: {}, files: {} }
    }))
  })

  afterEach(async () => {
    await i18n.changeLanguage("en")
  })

  it("registers under the exact MCP tool name", () => {
    expect(loadCanvasToolCard.toolName).toBe("load_canvas")
  })

  it("renders every merge result field, links, version, and a full-size preview", async () => {
    const parsedResult = { loaded: true, elements_added: 6, auto_saved_snapshot_id: null, snapshot_id: 8, mode: "merge", chat_session_id: 12, version: 3 }
    expect(loadCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Loaded #8 (Merge)")

    render(<>{loadCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getAllByText("Loaded snapshot").length).toBeGreaterThan(0)
    expect(screen.getByText("SNAPSHOT-8")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "SNAPSHOT-8" })).toHaveAttribute("href", "/chats/12?workspace=plugin%3Awhiteboard.canvas")
    expect(screen.getAllByText("Merge").length).toBeGreaterThan(0)
    expect(screen.getByText("v3")).toBeInTheDocument()
    expect(screen.getByText("6")).toBeInTheDocument()
    expect(screen.getByText("Rendering snapshot...")).toBeInTheDocument()

    const thumbnail = screen.getByRole("button", { name: "Open Snapshot #8" })
    expect(thumbnail).toHaveClass("w-full", "sm:w-72")
    await waitFor(() => expect(screen.getByRole("img", { name: "Snapshot #8" })).toHaveAttribute("src", expect.stringContaining("data:image/svg+xml")))
    fireEvent.click(thumbnail)
    expect(screen.getByRole("dialog", { name: "Whiteboard snapshot" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open whiteboard" })).toHaveAttribute("href", "/chats/12?workspace=plugin%3Awhiteboard.canvas")
    expect(screen.getByRole("link", { name: "View in media" })).toHaveAttribute("href", "/chats/12?workspace=media")
    expect(fetchWhiteboardSnapshot).toHaveBeenCalledWith("12", "8")
  })

  it("renders the replace input and linked pre-load backup preview", { timeout: 10_000 }, async () => {
    const parsedResult = { loaded: true, elements_added: 6, auto_saved_snapshot_id: 4, snapshot_id: 8, chat_session_id: 12, version: 3 }
    render(<>{loadCanvasToolCard.renderExpanded(context({ parsedResult, input: { snapshot_id: 8, mode: "replace" } }))}</>)

    expect(screen.getAllByText("Replace").length).toBeGreaterThan(0)
    expect(screen.getByText("#4")).toBeInTheDocument()
    expect(screen.getByText("Pre-load backup #4")).toBeInTheDocument()
    const backupThumbnail = screen.getByRole("button", { name: "Open Pre-load backup #4" })
    expect(backupThumbnail).toHaveClass("w-full", "sm:w-72")
    fireEvent.click(backupThumbnail)
    expect(screen.getByRole("dialog", { name: "Whiteboard snapshot" })).toBeInTheDocument()
    expect(fetchWhiteboardSnapshot).toHaveBeenCalledWith("12", "4")
  })

  it("uses input snapshot and default mode when older results omit them", () => {
    const parsedResult = { loaded: true, elements_added: 1, auto_saved_snapshot_id: null, version: 2 }
    const cardContext = context({ parsedResult, input: { snapshot_id: 17 } })

    expect(loadCanvasToolCard.collapsedSummary?.(cardContext)).toBe("Loaded #17 (Merge)")
    render(<>{loadCanvasToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("SNAPSHOT-17")).toBeInTheDocument()
    expect(screen.getAllByText("Merge").length).toBeGreaterThan(0)
  })

  it("renders not-found and invalid-mode errors with attempted inputs", () => {
    for (const [message, mode] of [
      ["Couldn't find Whiteboard::Snapshot with 'id'=404", "merge"],
      ["mode must be merge or replace", "invalid"]
    ]) {
      const errorContext = context({ resultError: true, resultBody: message, input: { snapshot_id: 404, mode } })
      expect(loadCanvasToolCard.collapsedSummary?.(errorContext)).toContain("failed")
      const { unmount } = render(<>{loadCanvasToolCard.renderExpanded(errorContext)}</>)
      expect(screen.getByText("Load canvas snapshot failed")).toBeInTheDocument()
      expect(screen.getByText(message)).toBeInTheDocument()
      expect(screen.getByText(new RegExp("#404"))).toBeInTheDocument()
      unmount()
    }
  })

  it("renders a normalized provider envelope", () => {
    const payload = { loaded: true, elements_added: 2, snapshot_id: 8, mode: "merge", chat_session_id: 12, version: 5 }
    const parsedResult = normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null })

    render(<>{loadCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("SNAPSHOT-8")).toBeInTheDocument()
    expect(screen.getByText("v5")).toBeInTheDocument()
  })

  it("localizes snapshot preview metadata", async () => {
    await i18n.changeLanguage("de")
    const parsedResult = { loaded: true, elements_added: 6, auto_saved_snapshot_id: 4, snapshot_id: 8, mode: "replace", chat_session_id: 12, version: 3 }

    render(<>{loadCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Open Snapshot #8" }))
    expect(await screen.findByText("Snapshot-ID")).toBeInTheDocument()
    expect(screen.getByText("Modus")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "ID kopieren" })).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "ID kopieren" })).toHaveLength(2)
  })

  it("falls back to null for a malformed payload (loaded not true)", () => {
    expect(loadCanvasToolCard.renderExpanded(context({ parsedResult: { loaded: false } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(loadCanvasToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("publishes provider-agnostic catalog examples for merge, replace, and not-found states", () => {
    expect(examples.map((example) => example.id)).toEqual(["merge", "replace_with_backup", "not_found"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
