import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import updateSceneToolCard, { examples } from "./update_scene"

const exportToSvg = vi.fn(async () => document.createElementNS("http://www.w3.org/2000/svg", "svg"))

vi.mock("@excalidraw/excalidraw", () => ({
  convertToExcalidrawElements: vi.fn((elements) => elements),
  exportToSvg
}))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "update_scene", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("update_scene tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(updateSceneToolCard.toolName).toBe("update_scene")
  })

  it("derives a useful collapsed summary when collapsed dispatch omits input", () => {
    expect(updateSceneToolCard.collapsedSummary?.(context({ parsedResult: { replaced: true, version: 5 } }))).toBe("Replaced scene · v5")
  })

  it("includes input counts and result version when input is available", () => {
    const input = { elements: [{ id: "a" }, { id: "b" }, { id: "c" }], files: { image: {} } }
    expect(updateSceneToolCard.collapsedSummary?.(context({ input, parsedResult: { replaced: true, version: 5 } }))).toBe(
      "Replaced scene: 3 elements, 1 file · v5"
    )
  })

  it("renders all scene fields, bounded appState keys, and a full preview modal", async () => {
    const input = {
      elements: [{ id: "box", type: "rectangle", x: 0, y: 0, width: 80, height: 60 }],
      files: { f1: { id: "f1" } },
      appState: Object.fromEntries(Array.from({ length: 10 }, (_, index) => [`setting${index}`, index]))
    }
    render(<>{updateSceneToolCard.renderExpanded(context({ input, parsedResult: { replaced: true, version: 2 } }))}</>)

    expect(screen.getByText("Replaced scene")).toBeInTheDocument()
    expect(screen.getByText("v2")).toBeInTheDocument()
    expect(screen.getByText("setting0")).toBeInTheDocument()
    expect(screen.getByText("+2")).toBeInTheDocument()
    expect(screen.queryByText("setting9")).not.toBeInTheDocument()

    const thumbnail = screen.getByRole("button", { name: "Open Replacement scene" })
    expect(thumbnail).toHaveClass("w-full", "sm:w-72", "max-w-full")
    await waitFor(() => expect(screen.getByRole("img", { name: "Replacement scene" })).toHaveAttribute("src", expect.stringContaining("data:image/svg+xml")))
    expect(exportToSvg).toHaveBeenCalledWith(expect.objectContaining({ appState: expect.objectContaining({ setting0: 0, exportBackground: true }) }))

    fireEvent.click(thumbnail)
    expect(screen.getByRole("dialog", { name: "Whiteboard scene" })).toBeInTheDocument()
    expect(screen.getByText("setting0, setting1, setting2, setting3, setting4, setting5, setting6, setting7, +2")).toBeInTheDocument()
  })

  it("renders an empty replacement without fabricating missing fields", async () => {
    render(
      <>{updateSceneToolCard.renderExpanded(context({ input: { elements: [], appState: {}, files: {} }, parsedResult: { replaced: true, version: 3 } }))}</>
    )

    expect(screen.getAllByText("0")).toHaveLength(2)
    expect(screen.getByText("None")).toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole("img", { name: "Replacement scene" })).toBeInTheDocument())
  })

  it("renders validation failures with their message and attempted count", () => {
    const errorContext = context({ input: { elements: [{ id: "bad" }] }, resultBody: "element type is required", resultError: true })
    expect(updateSceneToolCard.collapsedSummary?.(errorContext)).toBe("Replace scene failed: element type is required")

    render(<>{updateSceneToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Replace scene failed")).toBeInTheDocument()
    expect(screen.getByText("element type is required")).toBeInTheDocument()
    expect(screen.getByText("Replace scene with 1 element")).toBeInTheDocument()
  })

  it("unwraps provider-agnostic structured result envelopes", () => {
    const parsedResult = { content: [{ type: "text", text: "scene replaced" }], structured_content: { replaced: true, version: 8 } }
    expect(updateSceneToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Replaced scene · v8")
  })

  it("renders wrapped provider errors as validation failures", () => {
    const parsedResult = { content: [{ type: "text", text: "Error: unsupported element type: video" }], structured_content: null }
    const toolContext = context({ input: { elements: [{ type: "video" }] }, parsedResult, resultBody: JSON.stringify(parsedResult) })

    render(<>{updateSceneToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("unsupported element type: video")).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(updateSceneToolCard.renderExpanded(context({ parsedResult: { replaced: false } }))).toBeNull()
    expect(updateSceneToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("publishes provider-agnostic catalog examples for success, empty, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["replaced_scene", "empty_scene", "validation_error"])
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
