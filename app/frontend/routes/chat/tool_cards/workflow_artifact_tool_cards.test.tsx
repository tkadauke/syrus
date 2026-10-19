import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listArtifactsToolCard from "./list_artifacts"
import readArtifactToolCard from "./read_artifact"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("workflow artifact tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(listArtifactsToolCard.toolName).toBe("list_artifacts")
    expect(readArtifactToolCard.toolName).toBe("read_artifact")
  })

  it("renders an empty artifact list", () => {
    const parsedResult = { workflow_id: 28622, artifacts: [] }
    const toolContext = context("list_artifacts", { parsedResult })

    expect(listArtifactsToolCard.collapsedSummary?.(toolContext)).toBe("No artifacts")
    render(<>{listArtifactsToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("No artifacts recorded on this Workflow.")).toBeInTheDocument()
  })

  it("renders artifact metadata for multiple typed artifacts", () => {
    const parsedResult = {
      workflow_id: 28622,
      artifacts: [
        {
          type: "visual_review_screenshot_1",
          title: "Homepage after fix",
          content_type: "image/png",
          byte_size: 204800,
          run_id: 144524,
          step_id: 223959,
          iteration: 1,
          image_url: "/api/v1/app/workflows/28622/visual_artifact?type=visual_review_screenshot_1"
        },
        {
          type: "rails_schema_erd",
          title: "Schema ERD",
          content_type: "application/json",
          byte_size: null,
          run_id: null,
          step_id: null,
          iteration: null,
          image_url: null
        }
      ]
    }
    const toolContext = context("list_artifacts", { parsedResult })

    expect(listArtifactsToolCard.collapsedSummary?.(toolContext)).toBe("2 artifacts")
    render(<>{listArtifactsToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("visual_review_screenshot_1")).toHaveClass("whitespace-nowrap")
    expect(screen.getByText("Homepage after fix")).toBeInTheDocument()
    expect(screen.getByText("image/png")).toBeInTheDocument()
    expect(screen.getByText("200.0 KB")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy RUN-144524 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("STEP-223959")).toBeInTheDocument()
    expect(screen.getByText("rails_schema_erd")).toBeInTheDocument()
    expect(screen.getByText("Schema ERD")).toBeInTheDocument()
  })

  it("falls back to the generic renderer for a malformed list_artifacts payload", () => {
    expect(listArtifactsToolCard.collapsedSummary?.(context("list_artifacts", { parsedResult: { oops: true } }))).toBeNull()
    expect(listArtifactsToolCard.renderExpanded(context("list_artifacts", { parsedResult: "not json" }))).toBeNull()
  })

  it("renders a read_artifact image result inline", () => {
    const parsedResult = [{ type: "image", data: "abc123", mimeType: "image/png" }]
    const toolContext = context("read_artifact", {
      input: { workflow_id: 28622, job_id: 7705, type: "visual_review_screenshot_1" },
      parsedResult
    })

    expect(readArtifactToolCard.collapsedSummary?.(toolContext)).toBe("Artifact: visual_review_screenshot_1")

    render(<>{readArtifactToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByRole("img", { name: "visual_review_screenshot_1" })).toHaveAttribute("src", "data:image/png;base64,abc123")
    expect(screen.getAllByText("visual_review_screenshot_1").length).toBeGreaterThan(0)
    const workflowLinks = screen.getAllByText("WF-28622")
    expect(workflowLinks.some((link) => link.closest("a")?.getAttribute("href") === "/jobs/7705?tab=workflows#workflow-28622")).toBe(true)

    fireEvent.click(screen.getByRole("button", { name: "Open visual_review_screenshot_1" }))
    expect(screen.getByRole("dialog", { name: "visual_review_screenshot_1" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open" })).toHaveAttribute("href", "data:image/png;base64,abc123")
    expect(screen.getByRole("link", { name: "Download" })).toHaveAttribute("download")
  })

  it.each([
    ["wrapped MCP", { content: [{ type: "image", data: "wrapped", mimeType: "image/png" }] }],
    ["structured content", { structured_content: { content: [{ type: "image", data: "structured", mime_type: "image/webp" }] } }],
    ["Codex output", { output: { content: [{ type: "output_image", image_url: "data:image/jpeg;base64,codex" }] } }],
    ["Muse payload", { payload: { result: { content: [{ type: "image", source: { type: "base64", media_type: "image/gif", data: "muse" } }] } } }]
  ])("renders an image from the %s envelope", (_label, parsedResult) => {
    render(
      <>
        {readArtifactToolCard.renderExpanded(
          context("read_artifact", {
            input: { workflow_id: 28622, type: "capture" },
            parsedResult
          })
        )}
      </>
    )

    expect(screen.getByRole("img", { name: "capture" }).getAttribute("src")).toMatch(/^data:image\/(png|webp|jpeg|gif);base64,/)
  })

  it("renders a read_artifact failure with the error message", () => {
    const toolContext = context("read_artifact", {
      input: { workflow_id: 28622, type: "missing_type" },
      resultBody: 'Error: no image artifact found for type "missing_type"',
      resultError: true,
      parsedResult: null
    })

    expect(readArtifactToolCard.collapsedSummary?.(toolContext)).toBe('Artifact read failed: Error: no image artifact found for type "missing_type"')

    render(<>{readArtifactToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Artifact read failed")).toBeInTheDocument()
    expect(screen.getByText('Error: no image artifact found for type "missing_type"')).toBeInTheDocument()
  })

  it("renders informative cards for text, empty, and pending results", () => {
    const text = context("read_artifact", {
      input: { workflow_id: 28622, type: "large_capture" },
      parsedResult: { content: [{ type: "text", text: "Artifact exceeds the inline size limit." }] }
    })
    expect(readArtifactToolCard.collapsedSummary?.(text)).toBe("Artifact response: large_capture")
    const { rerender } = render(<>{readArtifactToolCard.renderExpanded(text)}</>)
    expect(screen.getByText("Artifact exceeds the inline size limit.")).toBeInTheDocument()

    rerender(<>{readArtifactToolCard.renderExpanded(context("read_artifact", { parsedResult: { oops: true } }))}</>)
    expect(screen.getByText("The artifact result did not contain an image or message.")).toBeInTheDocument()

    rerender(<>{readArtifactToolCard.renderExpanded(context("read_artifact", { input: { type: "capture" } }))}</>)
    expect(screen.getByText("Waiting for the artifact result.")).toBeInTheDocument()
  })
})
