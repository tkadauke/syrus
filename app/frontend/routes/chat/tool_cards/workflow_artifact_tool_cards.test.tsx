import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listArtifactsToolCard from "./list_artifacts"
import readArtifactToolCard from "./read_artifact"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"

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
      job_id: 7706,
      artifacts: [
        {
          type: "visual_review_screenshot_1",
          title: "Homepage after fix",
          content_type: "image/png",
          byte_size: 204800,
          run_id: 144524,
          step_id: 223959,
          iteration: 1,
          image_url: "/api/v1/app/workflows/28622/visual_artifact?type=visual_review_screenshot_1",
          source: "playwright",
          captured_at: "2026-10-18T12:30:00Z",
          page: { url: "https://example.test/dashboard", path: "/dashboard", title: "Dashboard" },
          viewport: { width: 1280, height: 720, device_scale_factor: 2 }
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

    expect(screen.getByRole("link", { name: "WF-28622" })).toHaveAttribute("href", "/jobs/7706?tab=workflows#workflow-28622")
    expect(screen.getByRole("link", { name: "JOB-7706" })).toHaveAttribute("href", "/jobs/7706")
    expect(screen.getAllByText("visual_review_screenshot_1")).not.toHaveLength(0)
    expect(screen.getAllByText("Homepage after fix")).not.toHaveLength(0)
    expect(screen.getAllByText("image/png")).not.toHaveLength(0)
    expect(screen.getAllByText("200.0 KB")).not.toHaveLength(0)
    expect(screen.getAllByRole("link", { name: "RUN-144524" })[0]).toHaveAttribute("href", "/jobs/7706?tab=workflows#workflow-28622")
    expect(screen.getAllByRole("link", { name: "STEP-223959" })[0]).toHaveAttribute("href", "/jobs/7706?tab=workflows#workflow-28622")
    expect(screen.getAllByText("playwright")).not.toHaveLength(0)
    expect(screen.getAllByText("2026-10-18T12:30:00Z")).not.toHaveLength(0)
    expect(screen.getAllByRole("link", { name: "Dashboard · /dashboard · https://example.test/dashboard" })[0]).toHaveAttribute(
      "href",
      "https://example.test/dashboard"
    )
    expect(screen.getAllByText("1280×720 @ 2x")).not.toHaveLength(0)
    expect(screen.getAllByText("rails_schema_erd")).not.toHaveLength(0)
    expect(screen.getAllByText("Schema ERD")).not.toHaveLength(0)

    const thumbnails = screen.getAllByRole("button", { name: "Open Homepage after fix" })
    expect(thumbnails[0]).toHaveClass("min-w-24")
    fireEvent.click(thumbnails[0])
    expect(screen.getByRole("dialog", { name: "Homepage after fix" })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "Open" })[0]).toHaveAttribute("href", parsedResult.artifacts[0].image_url)
  })

  it("renders pending and error states", () => {
    const pending = context("list_artifacts")
    expect(listArtifactsToolCard.collapsedSummary?.(pending)).toBe("Listing artifacts…")
    const { unmount } = render(<>{listArtifactsToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Waiting for artifacts…")).toBeInTheDocument()
    unmount()

    const failure = context("list_artifacts", { resultError: true, resultBody: "Workflow was not found." })
    expect(listArtifactsToolCard.collapsedSummary?.(failure)).toBe("Failed to list artifacts")
    render(<>{listArtifactsToolCard.renderExpanded(failure)}</>)
    expect(screen.getByText("Workflow was not found.")).toBeInTheDocument()
  })

  it("renders normalized provider envelopes and names", () => {
    const payload = { workflow_id: 9, job_id: 4, artifacts: [{ type: "same" }, { type: "same" }] }
    const envelopes = [
      payload,
      { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null },
      { content: [], structured_content: payload }
    ]

    for (const envelope of envelopes) {
      const toolContext = context(normalizedToolName("mcp__provider__list_artifacts"), { parsedResult: normalizedToolCardParsedResult(envelope) })
      expect(toolContext.toolName).toBe("list_artifacts")
      expect(listArtifactsToolCard.collapsedSummary?.(toolContext)).toBe("2 artifacts")
    }
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
