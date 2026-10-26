import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { convertToExcalidrawElements } from "@excalidraw/excalidraw"
import readSceneToolCard, { examples } from "./read_scene"

vi.mock("@excalidraw/excalidraw", () => ({
  convertToExcalidrawElements: vi.fn((elements) => elements),
  exportToSvg: vi.fn(async () => document.createElementNS("http://www.w3.org/2000/svg", "svg"))
}))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "read_scene", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("read_scene tool card", () => {
  it("registers under the exact MCP tool name", () => expect(readSceneToolCard.toolName).toBe("read_scene"))

  it("renders all result fields, per-type counts, text, and a full-size scene preview", async () => {
    const parsedResult = {
      elements: [
        { id: "a", type: "rectangle", x: 0, y: 0, width: 100, height: 80 },
        { id: "b", type: "text", text: "First note" },
        { id: "c", type: "text", text: "Second note" },
        { id: "d", type: "text", text: "Third note" },
        { id: "e", type: "text", text: "Fourth note" },
        { id: "f", type: "image", fileId: "image-1" }
      ],
      appState: { viewBackgroundColor: "#fff" },
      files: { "image-1": { id: "image-1", dataURL: "data:image/png;base64,AA==" } },
      version: 3
    }
    expect(readSceneToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("6 elements, 1 file")
    render(<>{readSceneToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("v3")).toBeInTheDocument()
    expect(screen.getByText("text · 4")).toBeInTheDocument()
    expect(screen.getByText("rectangle · 1")).toBeInTheDocument()
    expect(screen.getByText("image · 1")).toBeInTheDocument()
    expect(screen.queryByText("Fourth note")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByText("Fourth note")).toBeInTheDocument()

    const thumbnail = screen.getByRole("button", { name: "Open Scene preview" })
    expect(thumbnail).toHaveClass("w-full", "sm:w-72")
    await waitFor(() => expect(screen.getByRole("img", { name: "Scene preview" })).toHaveAttribute("src", expect.stringContaining("data:image/svg+xml")))
    fireEvent.click(thumbnail)
    expect(screen.getByRole("dialog", { name: "Whiteboard snapshot" })).toBeInTheDocument()
  })

  it("bounds thumbnail rendering for large scenes", async () => {
    const elements = Array.from({ length: 700 }, (_, index) => ({ id: String(index), type: "rectangle" }))
    render(<>{readSceneToolCard.renderExpanded(context({ parsedResult: { elements, appState: {}, files: {}, version: 1 } }))}</>)
    await waitFor(() => expect(convertToExcalidrawElements).toHaveBeenCalled())
    expect(vi.mocked(convertToExcalidrawElements).mock.calls.at(-1)?.[0]).toHaveLength(500)
  })

  it("renders a wrapped empty result without a thumbnail", () => {
    const parsedResult = { result: { elements: [], appState: {}, files: {}, version: 0 } }
    expect(readSceneToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("0 elements")
    render(<>{readSceneToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("The scene is empty.")).toBeInTheDocument()
    expect(screen.getByText("v0")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open Scene preview" })).not.toBeInTheDocument()
  })

  it("redacts secrets in text elements", () => {
    const parsedResult = { elements: [{ id: "text", type: "text", text: "token=abcdefghijklmnop-secret" }], appState: {}, files: {} }
    render(<>{readSceneToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("token=[redacted]")).toBeInTheDocument()
    expect(screen.queryByText(/abcdefghijklmnop-secret/)).not.toBeInTheDocument()
  })

  it("shows a structured card for tool errors", () => {
    const errorContext = context({ resultError: true, resultBody: "board unavailable" })
    expect(readSceneToolCard.collapsedSummary?.(errorContext)).toContain("failed")
    render(<>{readSceneToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Read scene failed")).toBeInTheDocument()
    expect(screen.getByText("board unavailable")).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(readSceneToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readSceneToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("publishes provider-agnostic catalog examples for success, empty, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["scene", "empty", "error"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
