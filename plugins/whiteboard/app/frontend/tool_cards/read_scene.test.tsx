import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { exportToSvg } from "@excalidraw/excalidraw"
import readSceneToolCard, { examples } from "./read_scene"

vi.mock("@excalidraw/excalidraw", () => ({
  exportToSvg: vi.fn(async ({ elements }: { elements: unknown[] }) => {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.dataset.elementCount = String(elements.length)
    return svg
  })
}))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_scene",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("read_scene tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readSceneToolCard.toolName).toBe("read_scene")
  })

  it("summarizes the collapsed row with element and file counts", () => {
    const parsedResult = { elements: [{ id: "a" }, { id: "b" }], appState: {}, files: { f1: {} }, version: 3 }
    expect(readSceneToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 elements, 1 file")
  })

  it("renders type counts, image files, text contents, and a responsive full-size preview", async () => {
    const longText = "A".repeat(170)
    const parsedResult = {
      elements: [
        { id: "a", type: "rectangle" },
        { id: "b", type: "rectangle" },
        { id: "c", type: "arrow" },
        { id: "d", type: "text", text: longText },
        { id: "e", type: "text", text: "Second note" },
        { id: "f", type: "text", text: "Third note" },
        { id: "g", type: "text", text: "Fourth note" }
      ],
      appState: { viewBackgroundColor: "#fff" },
      files: { image1: { id: "image1" }, image2: { id: "image2" } },
      version: 1
    }
    render(<>{readSceneToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getAllByText("Scene")).toHaveLength(2)
    expect(screen.getByText("v1")).toBeInTheDocument()
    expect(screen.getByText("rectangle 2")).toBeInTheDocument()
    expect(screen.getByText("text 4")).toBeInTheDocument()
    expect(screen.getByText("arrow 1")).toBeInTheDocument()
    expect(screen.getByText("Text contents")).toBeInTheDocument()
    expect(screen.getByText(`${"A".repeat(157)}…`)).toBeInTheDocument()
    expect(screen.queryByText("Fourth note")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByText(longText)).toBeInTheDocument()
    expect(screen.getByText("Fourth note")).toBeInTheDocument()

    const thumbnail = screen.getByRole("button", { name: "Open Whiteboard scene" })
    expect(thumbnail).toHaveClass("w-full", "sm:w-72")
    await waitFor(() => expect(screen.getByRole("img", { name: "Whiteboard scene" })).toHaveAttribute("src", expect.stringContaining("data:image/svg+xml")))
    fireEvent.click(thumbnail)
    const dialog = screen.getByRole("dialog", { name: "Whiteboard scene" })
    expect(within(dialog).getByText("Image files")).toBeInTheDocument()
    expect(within(dialog).getByText("2")).toBeInTheDocument()
  })

  it("renders a clear empty-scene state without attempting a preview", () => {
    render(<>{readSceneToolCard.renderExpanded(context({ parsedResult: { elements: [], appState: {}, files: {}, version: 0 } }))}</>)

    expect(screen.getByText("This whiteboard scene is empty.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open Whiteboard scene" })).not.toBeInTheDocument()
  })

  it("accepts wrapped structured-content envelopes", () => {
    const parsedResult = { result: { structured_content: { elements: [{ id: "a", type: "ellipse" }], appState: {}, files: {}, version: 6 } } }
    expect(readSceneToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 element")
    render(<>{readSceneToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("ellipse 1")).toBeInTheDocument()
    expect(screen.getByText("v6")).toBeInTheDocument()
  })

  it("shows a structured error card", () => {
    const errorContext = context({ resultError: true, resultBody: "canvas unavailable" })
    expect(readSceneToolCard.collapsedSummary?.(errorContext)).toContain("failed")
    render(<>{readSceneToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Read whiteboard scene failed")).toBeInTheDocument()
    expect(screen.getByText("canvas unavailable")).toBeInTheDocument()
  })

  it("bounds large-scene thumbnails and keeps files referenced by retained images", async () => {
    const elements = [{ id: "image", type: "image", fileId: "124" }, ...Array.from({ length: 249 }, (_, id) => ({ id: String(id), type: "rectangle" }))]
    const files = Object.fromEntries(Array.from({ length: 125 }, (_, id) => [String(id), { id: String(id) }]))
    render(<>{readSceneToolCard.renderExpanded(context({ parsedResult: { elements, appState: {}, files, version: 1 } }))}</>)
    await waitFor(() => expect(exportToSvg).toHaveBeenCalled())
    const renderInput = vi.mocked(exportToSvg).mock.calls.at(-1)?.[0]
    expect(renderInput.elements).toHaveLength(200)
    expect(renderInput.files).toEqual({ "124": { id: "124" } })
  })

  it("falls back to null for a malformed payload (missing elements array)", () => {
    expect(readSceneToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readSceneToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("publishes provider-agnostic catalog examples for populated, empty, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["populated_scene", "empty_scene", "error"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })

  it("uses complete Excalidraw elements and file data in the populated catalog example", () => {
    const populated = examples.find((example) => example.id === "populated_scene")?.parsedResult as {
      elements: Record<string, unknown>[]
      files: Record<string, Record<string, unknown>>
    }
    const requiredBaseFields = ["id", "type", "x", "y", "width", "height", "strokeColor", "backgroundColor", "opacity", "seed", "version", "versionNonce"]
    populated.elements.forEach((element) => requiredBaseFields.forEach((field) => expect(element).toHaveProperty(field)))
    expect(populated.elements.find((element) => element.type === "arrow")).toMatchObject({
      points: [
        [0, 0],
        [100, 0]
      ],
      endArrowhead: "arrow"
    })
    expect(populated.elements.find((element) => element.type === "image")).toMatchObject({ fileId: "image1", status: "saved" })
    expect(populated.files.image1).toMatchObject({ id: "image1", mimeType: "image/svg+xml" })
    expect(populated.files.image1.dataURL).toMatch(/^data:image\/svg\+xml,/)
  })
})
