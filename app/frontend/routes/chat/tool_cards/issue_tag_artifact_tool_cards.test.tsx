import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import addJobTagToolCard from "./add_job_tag"
import createTagToolCard from "./create_tag"
import listOpenIssuesToolCard, { examples as issueExamples } from "./list_open_issues"
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

  it("renders issue query, links, author, full title, markdown body, media, and responsive cells", () => {
    const parsedResult = {
      issues: [
        {
          number: 12,
          title: "Button sticks",
          labels: ["bug", "frontend"],
          state: "open",
          created_at: "2026-05-01T12:00:00Z",
          updated_at: "2026-05-02T12:00:00Z",
          url: "https://github.com/acme/widgets/issues/12",
          author: "octocat",
          body_excerpt: `A **detailed** report. ${"More context. ".repeat(80)}\n\n![Screenshot](https://example.test/screenshot.png)`
        },
        { number: 13, title: "Missing optional metadata", labels: [] }
      ]
    }

    expect(listOpenIssuesToolCard.collapsedSummary?.(context("list_open_issues", { parsedResult }))).toBe("2 issues")
    const { container } = render(
      <>{listOpenIssuesToolCard.renderExpanded(context("list_open_issues", { input: { state: "open", label: "bug", limit: 2 }, parsedResult }))}</>
    )

    expect(screen.getByText("State:")).toBeInTheDocument()
    expect(screen.getByText("Label:")).toBeInTheDocument()
    expect(screen.getByText("Limit:")).toBeInTheDocument()
    expect(screen.getByText("Limit reached; more issues may be available.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "https://github.com/acme/widgets")
    expect(screen.getByText("Button sticks")).toBeInTheDocument()
    expect(screen.getByText("by octocat")).toBeInTheDocument()
    expect(screen.getByText("detailed")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open Button sticks image 1" })).toBeInTheDocument()
    expect(screen.getAllByText("bug").length).toBeGreaterThanOrEqual(2)
    expect(screen.getByText("frontend")).toBeInTheDocument()
    expect(screen.getAllByText("open").length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText("#13")).toBeInTheDocument()
    expect(screen.getByText("Missing optional metadata")).toBeInTheDocument()
    expect(container.querySelector("table")?.className).toContain("sm:table")
    expect(container.querySelector('[data-label="Details"]')).toBeInTheDocument()
  })

  it("handles issue envelopes, errors, malformed payloads, and rejects array roots", () => {
    const envelope = normalizedToolCardParsedResult({ structured_content: { issues: [{ number: 7, title: "Envelope issue" }] } })
    expect(listOpenIssuesToolCard.collapsedSummary?.(context("list_open_issues", { parsedResult: envelope }))).toBe("1 issue")
    expect(listOpenIssuesToolCard.collapsedSummary?.(context("list_open_issues", { parsedResult: [{ number: 7, title: "Array issue" }] }))).toBeNull()

    const errorContext = context("list_open_issues", {
      input: { state: "open", limit: 10 },
      resultError: true,
      resultBody: "GitHub unavailable",
      parsedResult: { error: "Could not reach GitHub" }
    })
    expect(listOpenIssuesToolCard.collapsedSummary?.(errorContext)).toBe("Could not list issues")
    render(<>{listOpenIssuesToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Could not reach GitHub")).toBeInTheDocument()
    expect(listOpenIssuesToolCard.renderExpanded(context("list_open_issues", { parsedResult: { issues: "wrong" } }))).toBeNull()
  })

  it("shows the backend default limit and reached hint when limit is omitted", () => {
    const parsedResult = {
      issues: Array.from({ length: 20 }, (_, index) => ({ number: index + 1, title: `Issue ${index + 1}` }))
    }

    render(<>{listOpenIssuesToolCard.renderExpanded(context("list_open_issues", { parsedResult }))}</>)

    expect(screen.getByText("Limit:").parentElement).toHaveTextContent("Limit: 20")
    expect(screen.getByText("Limit reached; more issues may be available.")).toBeInTheDocument()
  })

  it("publishes catalog examples for details, empty, and error states", () => {
    expect(issueExamples.map(({ id }) => id)).toEqual(["issues_with_details", "empty", "error"])
    const detailed = issueExamples[0]

    render(<>{listOpenIssuesToolCard.renderExpanded(context("list_open_issues", { input: detailed.input, parsedResult: detailed.parsedResult }))}</>)

    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.getByRole("img", { name: "Responsive navigation overlaps content on smaller screens image 1" })).toHaveAttribute("src", "/icon-192.png")
  })

  it("renders an empty tag list", () => {
    const parsedResult = { tags: [] }

    expect(listTagsToolCard.collapsedSummary?.(context("list_tags", { parsedResult }))).toBe("No tags")
    render(<>{listTagsToolCard.renderExpanded(context("list_tags", { parsedResult }))}</>)

    expect(screen.getByText("No tags found.")).toBeInTheDocument()
  })

  it("renders multiple tags with affected Jobs", () => {
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
    expect(screen.getByText("JOB-7")).toBeInTheDocument()
    expect(screen.getByText("JOB-8")).toBeInTheDocument()
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
