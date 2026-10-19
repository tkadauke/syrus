import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import addJobTagToolCard from "./add_job_tag"
import createTagToolCard from "./create_tag"
import listOpenIssuesToolCard from "./list_open_issues"
import listTagsToolCard from "./list_tags"
import removeJobTagToolCard from "./remove_job_tag"
import submitArtifactToolCard from "./submit_artifact"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("issue, tag, and artifact tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(listOpenIssuesToolCard.toolName).toBe("list_open_issues")
    expect(listTagsToolCard.toolName).toBe("list_tags")
    expect(createTagToolCard.toolName).toBe("create_tag")
    expect(addJobTagToolCard.toolName).toBe("add_job_tag")
    expect(removeJobTagToolCard.toolName).toBe("remove_job_tag")
    expect(submitArtifactToolCard.toolName).toBe("submit_artifact")
  })

  it("renders an empty issue list", () => {
    const parsedResult = { issues: [] }

    expect(listOpenIssuesToolCard.collapsedSummary?.(context("list_open_issues", { parsedResult }))).toBe("No issues")
    render(<>{listOpenIssuesToolCard.renderExpanded(context("list_open_issues", { parsedResult }))}</>)

    expect(screen.getByText("No issues found.")).toBeInTheDocument()
  })

  it("renders multiple issues with labels, state, timestamps, and links", () => {
    const parsedResult = {
      issues: [
        {
          number: 12,
          title: "Button sticks",
          labels: ["bug", "frontend"],
          state: "open",
          created_at: "2026-05-01T12:00:00Z",
          updated_at: "2026-05-02T12:00:00Z",
          url: "https://github.com/acme/widgets/issues/12"
        },
        { number: 13, title: "Missing optional metadata", labels: [] }
      ]
    }

    expect(listOpenIssuesToolCard.collapsedSummary?.(context("list_open_issues", { parsedResult }))).toBe("2 issues")
    render(<>{listOpenIssuesToolCard.renderExpanded(context("list_open_issues", { parsedResult }))}</>)

    expect(screen.getByText("#12")).toBeInTheDocument()
    expect(screen.getByText("Button sticks")).toBeInTheDocument()
    expect(screen.getByText("bug")).toBeInTheDocument()
    expect(screen.getByText("frontend")).toBeInTheDocument()
    expect(screen.getAllByText("open").length).toBeGreaterThanOrEqual(1)
    expect(screen.getByRole("link", { name: "open" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
    expect(screen.getByText("#13")).toBeInTheDocument()
    expect(screen.getByText("Missing optional metadata")).toBeInTheDocument()
  })

  it("renders an empty tag list", () => {
    const parsedResult = { tags: [] }

    expect(listTagsToolCard.collapsedSummary?.(context("list_tags", { parsedResult }))).toBe("No tags")
    render(<>{listTagsToolCard.renderExpanded(context("list_tags", { parsedResult }))}</>)

    expect(screen.getByText("No tags found.")).toBeInTheDocument()
  })

  it("renders tag colors, counts, and linked Jobs per tag", () => {
    const parsedResult = {
      tags: [
        { id: 1, name: "area:auth", color: "#123abc", job_ids: [7, 8] },
        { id: 2, name: "urgent", color: "red", job_ids: [8] }
      ]
    }

    expect(listTagsToolCard.collapsedSummary?.(context("list_tags", { parsedResult }))).toBe("2 tags")
    render(<>{listTagsToolCard.renderExpanded(context("list_tags", { parsedResult }))}</>)

    expect(screen.getByText("area:auth")).toBeInTheDocument()
    expect(screen.getByText("urgent")).toBeInTheDocument()
    expect(screen.getByText("#123abc")).toBeInTheDocument()
    expect(screen.getByText("red")).toBeInTheDocument()
    expect(screen.getByText("2 Jobs")).toBeInTheDocument()
    expect(screen.getByText("1 Job")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/jobs/7")
    expect(screen.getAllByRole("link", { name: "JOB-8" })).toHaveLength(2)
    expect(screen.getByText("JOB-7").closest("div")?.parentElement).toHaveTextContent("area:auth")
    expect(screen.getAllByText("JOB-8")[1].closest("div")?.parentElement).toHaveTextContent("urgent")
  })

  it("renders pending and error tag-list states", () => {
    const pending = context("list_tags")
    expect(listTagsToolCard.collapsedSummary?.(pending)).toBe("Loading tags")
    const { rerender } = render(<>{listTagsToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()

    const failed = context("list_tags", { resultBody: "Unable to load tags", resultError: true })
    expect(listTagsToolCard.collapsedSummary?.(failed)).toBe("Could not list tags")
    rerender(<>{listTagsToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Unable to load tags")).toBeInTheDocument()
  })

  it("renders create input and result details without an empty affected-Jobs section", () => {
    const created = { id: 10, name: "area:ui", color: "blue", job_ids: [] }
    const createdContext = context("create_tag", { input: { name: "area:ui", color: "blue" }, parsedResult: created })

    expect(createTagToolCard.collapsedSummary?.(createdContext)).toBe("Created area:ui")
    const { container } = render(<>{createTagToolCard.renderExpanded(createdContext)}</>)
    expect(screen.getByText("Create tag")).toBeInTheDocument()
    expect(screen.getAllByText("area:ui")).toHaveLength(3)
    expect(screen.getByText("Requested name")).toBeInTheDocument()
    expect(screen.getByText("Requested color")).toBeInTheDocument()
    expect(screen.getByText("Created name")).toBeInTheDocument()
    expect(screen.getByText("Created color")).toBeInTheDocument()
    expect(screen.queryByText("Affected Jobs")).not.toBeInTheDocument()
    expect(container.querySelector("[style]")).toHaveStyle({ backgroundColor: "#dbeafe", color: "#1d4ed8" })

    expect(addJobTagToolCard.collapsedSummary?.(context("add_job_tag", { input: { job_id: 7, tag_id: 10 }, parsedResult: { success: true } }))).toBe("Added tag 10 · JOB-7")
    expect(removeJobTagToolCard.collapsedSummary?.(context("remove_job_tag", { input: { job_id: 7, tag_id: 10 }, parsedResult: { success: true } }))).toBe("Removed tag 10 · JOB-7")
  })

  it("renders a pending create from input alone", () => {
    const pending = context("create_tag", { input: { name: "area:api", color: "gray" } })

    expect(createTagToolCard.collapsedSummary?.(pending)).toBe("Creating area:api")
    render(<>{createTagToolCard.renderExpanded(pending)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getAllByText("area:api")).toHaveLength(2)
    expect(screen.queryByText("Created name")).not.toBeInTheDocument()
  })

  it("does not treat input metadata as success for a settled unrecognized result", () => {
    const malformed = context("create_tag", {
      input: { name: "area:ui", color: "gray" },
      resultBody: "{}",
      parsedResult: {}
    })

    expect(createTagToolCard.collapsedSummary?.(malformed)).toBe("Create area:ui returned an unexpected response")
    render(<>{createTagToolCard.renderExpanded(malformed)}</>)

    expect(screen.getByText("unknown")).toBeInTheDocument()
    expect(screen.getByText("Unexpected tool response.")).toBeInTheDocument()
    expect(screen.queryByText("success")).not.toBeInTheDocument()
    expect(screen.getByText("Requested name")).toBeInTheDocument()
    expect(screen.queryByText("Created name")).not.toBeInTheDocument()
  })

  it("normalizes provider-qualified names and MCP result envelopes", () => {
    const envelopes = [
      { structured_content: { id: 11, name: "priority", color: "amber", job_ids: [] } },
      { content: [{ type: "text", text: JSON.stringify({ id: 12, name: "priority", color: "amber", job_ids: [] }) }] }
    ]

    for (const [index, envelope] of envelopes.entries()) {
      const normalizedContext = context(normalizedToolName(index === 0 ? "mcp__syrus__create_tag" : "syrus-chat-sidecar.create_tag"), {
        input: { name: "priority", color: "amber" },
        parsedResult: normalizedToolCardParsedResult(envelope)
      })
      expect(normalizedContext.toolName).toBe("create_tag")
      expect(createTagToolCard.collapsedSummary?.(normalizedContext)).toBe("Created priority")
    }
  })

  it("normalizes differently shaped list_tags envelopes", () => {
    const envelopes = [
      { structured_content: { tags: [{ id: 1, name: "priority", color: "amber", job_ids: [7] }] } },
      { content: [{ type: "text", text: JSON.stringify({ tags: [{ id: 2, name: "area:ui", color: "blue", job_ids: [8] }] }) }] }
    ]

    for (const [index, envelope] of envelopes.entries()) {
      const normalizedContext = context(normalizedToolName(index === 0 ? "mcp__syrus__list_tags" : "syrus-chat-sidecar.list_tags"), {
        parsedResult: normalizedToolCardParsedResult(envelope)
      })
      expect(normalizedContext.toolName).toBe("list_tags")
      expect(listTagsToolCard.collapsedSummary?.(normalizedContext)).toBe("1 tag")
      const { unmount } = render(<>{listTagsToolCard.renderExpanded(normalizedContext)}</>)
      expect(screen.getByRole("link", { name: `JOB-${index + 7}` })).toBeInTheDocument()
      unmount()
    }
  })

  it("renders duplicate and invalid tag errors", () => {
    const duplicate = context("create_tag", {
      input: { name: "area:ui" },
      resultBody: "Name has already been taken",
      resultError: true,
      parsedResult: null
    })
    const invalid = context("add_job_tag", {
      input: { job_id: 7, tag_id: 99 },
      resultBody: JSON.stringify({ error: "tag not found for this user: 99" }),
      resultError: true,
      parsedResult: { error: "tag not found for this user: 99" }
    })

    expect(createTagToolCard.collapsedSummary?.(duplicate)).toBe("Created area:ui failed")
    const { rerender } = render(<>{createTagToolCard.renderExpanded(duplicate)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Name has already been taken")).toBeInTheDocument()

    rerender(<>{addJobTagToolCard.renderExpanded(invalid)}</>)
    expect(screen.getByText("tag not found for this user: 99")).toBeInTheDocument()
  })

  it("renders artifact submission metadata, affordances, and payload preview", () => {
    const input = {
      type: "rails_schema_erd",
      title: "Schema ERD",
      payload: { tables: [{ name: "jobs" }] }
    }
    const parsedResult = {
      message: "Saved.",
      id: "artifact-1",
      path: "artifacts/schema.json",
      url: "/chat/artifacts/artifact-1"
    }

    expect(submitArtifactToolCard.collapsedSummary?.(context("submit_artifact", { input, parsedResult }))).toBe("Artifact saved: Schema ERD")
    render(<>{submitArtifactToolCard.renderExpanded(context("submit_artifact", { input, parsedResult }))}</>)

    expect(screen.getByText("Schema ERD")).toBeInTheDocument()
    expect(screen.getByText("rails_schema_erd")).toBeInTheDocument()
    expect(screen.getByText("artifact-1")).toBeInTheDocument()
    expect(screen.getByText("artifacts/schema.json")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "open" })).toHaveAttribute("href", "/chat/artifacts/artifact-1")
    expect(screen.getByRole("link", { name: "download" })).toHaveAttribute("href", "/chat/artifacts/artifact-1")
    expect(screen.getByText(/"jobs"/)).toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed payloads", () => {
    expect(listOpenIssuesToolCard.collapsedSummary?.(context("list_open_issues", { parsedResult: { oops: true } }))).toBeNull()
    expect(listTagsToolCard.renderExpanded(context("list_tags", { parsedResult: "not json" }))).toBeNull()
    expect(submitArtifactToolCard.renderExpanded(context("submit_artifact", { parsedResult: "not json", resultBody: "" }))).toBeNull()
  })
})
