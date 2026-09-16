import { render, screen } from "@testing-library/react"
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

    expect(screen.getByText("visual_review_screenshot_1")).toBeInTheDocument()
    expect(screen.getByText("Homepage after fix")).toBeInTheDocument()
    expect(screen.getByText("image/png")).toBeInTheDocument()
    expect(screen.getByText("200.0 KB")).toBeInTheDocument()
    expect(screen.getByText("RUN-144524")).toBeInTheDocument()
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
      input: { workflow_id: 28622, type: "visual_review_screenshot_1" },
      parsedResult
    })

    expect(readArtifactToolCard.collapsedSummary?.(toolContext)).toBe("Artifact: visual_review_screenshot_1")

    render(<>{readArtifactToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByRole("img", { name: "visual_review_screenshot_1" })).toHaveAttribute("src", "data:image/png;base64,abc123")
    expect(screen.getAllByText("visual_review_screenshot_1").length).toBeGreaterThan(0)
    expect(screen.getByText("Workflow 28622")).toBeInTheDocument()
  })

  it("renders a read_artifact failure with the error message", () => {
    const toolContext = context("read_artifact", {
      input: { workflow_id: 28622, type: "missing_type" },
      resultBody: 'Error: no image artifact found for type "missing_type"',
      resultError: true,
      parsedResult: null
    })

    expect(readArtifactToolCard.collapsedSummary?.(toolContext)).toBe("Failed to read artifact: missing_type")

    render(<>{readArtifactToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText('Error: no image artifact found for type "missing_type"')).toBeInTheDocument()
  })

  it("falls back to the generic renderer for a malformed read_artifact payload", () => {
    expect(readArtifactToolCard.collapsedSummary?.(context("read_artifact", { parsedResult: { oops: true } }))).toBeNull()
    expect(readArtifactToolCard.renderExpanded(context("read_artifact", { parsedResult: { oops: true } }))).toBeNull()
  })
})
