import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { setSlugReferenceRegistryForTests } from "../../../lib/slugReferenceRegistry"
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
  beforeEach(() => {
    setSlugReferenceRegistryForTests([
      {
        prefix: "JOB",
        type: "job",
        displayLabel: "Job",
        copyable: true,
        linkable: true,
        previewAvailable: false,
        linkifiesGeneratedText: true,
        hrefTemplate: "/jobs/:id",
        mobileInteractionHints: {},
        pluginPreviewComponent: null
      }
    ])
  })

  afterEach(() => setSlugReferenceRegistryForTests(null))

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
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/jobs/7")
    expect(screen.getAllByRole("link", { name: "JOB-8" })).toHaveLength(2)
    expect(screen.getByText("area:auth").closest("div.rounded")).toHaveTextContent("JOB-7JOB-8")
    expect(screen.getByText("urgent").closest("div.rounded")).toHaveTextContent("JOB-8")
    expect(screen.getByText("2 Jobs")).toBeInTheDocument()
    expect(screen.getByText("1 Job")).toBeInTheDocument()
  })

  it("renders localized pending and error tag-list states", () => {
    const pending = context("list_tags")
    expect(listTagsToolCard.collapsedSummary?.(pending)).toBe("Loading tags")
    const { rerender } = render(<>{listTagsToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Loading tags…")).toBeInTheDocument()

    const failed = context("list_tags", { resultError: true, resultBody: "Permission denied" })
    expect(listTagsToolCard.collapsedSummary?.(failed)).toBe("Could not list tags")
    rerender(<>{listTagsToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("List tags")).toBeInTheDocument()
    expect(screen.getByText("Permission denied")).toBeInTheDocument()
  })

  it("normalizes differently shaped list-tags envelopes", () => {
    const envelopes = [
      { structured_content: { tags: [{ id: 1, name: "backend", color: "green", job_ids: [4] }] } },
      { content: [{ type: "text", text: JSON.stringify({ tags: [{ id: 2, name: "frontend", color: "pink", job_ids: [5] }] }) }] }
    ]

    for (const [index, envelope] of envelopes.entries()) {
      const normalizedContext = context(normalizedToolName(index === 0 ? "mcp__syrus__list_tags" : "syrus-chat-sidecar.list_tags"), {
        parsedResult: normalizedToolCardParsedResult(envelope)
      })
      expect(normalizedContext.toolName).toBe("list_tags")
      expect(listTagsToolCard.collapsedSummary?.(normalizedContext)).toBe("1 tag")
    }
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

    expect(addJobTagToolCard.collapsedSummary?.(context("add_job_tag", { input: { job_id: 7, tag_id: 10 }, parsedResult: { success: true } }))).toBe(
      "Added tag #10 · JOB-7"
    )
    expect(removeJobTagToolCard.collapsedSummary?.(context("remove_job_tag", { input: { job_id: 7, tag_id: 10 }, parsedResult: { success: true } }))).toBe(
      "Removed tag #10 · JOB-7"
    )
  })

  it("resolves an added tag from an earlier tag listing and links the Job", () => {
    const addContext = context("add_job_tag", {
      input: { job_id: 7, tag_id: 10 },
      parsedResult: { success: true },
      priorResults: { list_tags: { tags: [{ id: 10, name: "area:ui", color: "blue", job_ids: [] }] } }
    })

    expect(addJobTagToolCard.collapsedSummary?.(addContext)).toBe("Added area:ui · JOB-7")
    const { container } = render(<>{addJobTagToolCard.renderExpanded(addContext)}</>)

    expect(screen.getByText("area:ui")).toBeInTheDocument()
    expect(screen.getByText("10")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/jobs/7")
    expect(container.querySelector("[style]")).toHaveStyle({ backgroundColor: "#dbeafe", color: "#1d4ed8" })
  })

  it("shows a clear tag id fallback and pending state without prior context", () => {
    const pending = context("add_job_tag", { input: { job_id: 7, tag_id: 10 }, resultSettled: false })

    expect(addJobTagToolCard.collapsedSummary?.(pending)).toBe("Adding tag #10 · JOB-7")
    render(<>{addJobTagToolCard.renderExpanded(pending)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Tag #10")).toBeInTheDocument()
    expect(screen.getByText("10")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/jobs/7")
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
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("tag not found for this user: 99")).toBeInTheDocument()
    expect(screen.getByText("Tag #99")).toBeInTheDocument()
    expect(screen.getByText("99")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/jobs/7")
  })

  it("normalizes add-tag success and error envelopes from different providers", () => {
    const successEnvelope = { structured_content: { success: true } }
    const errorEnvelope = { content: [{ type: "text", text: JSON.stringify({ error: "tag not found for this user: 99" }) }] }
    const successContext = context(normalizedToolName("mcp__syrus__add_job_tag"), {
      input: { job_id: 7, tag_id: 10 },
      parsedResult: normalizedToolCardParsedResult(successEnvelope)
    })
    const errorContext = context(normalizedToolName("syrus-chat-sidecar.add_job_tag"), {
      input: { job_id: 7, tag_id: 99 },
      parsedResult: normalizedToolCardParsedResult(errorEnvelope),
      resultError: true
    })

    expect(addJobTagToolCard.collapsedSummary?.(successContext)).toBe("Added tag #10 · JOB-7")
    expect(addJobTagToolCard.collapsedSummary?.(errorContext)).toBe("Added tag #99 failed · JOB-7")
    render(<>{addJobTagToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("tag not found for this user: 99")).toBeInTheDocument()
  })

  it("resolves a removed tag from chat context and links the Job", () => {
    const removeContext = context("remove_job_tag", {
      input: { job_id: 7, tag_id: 10 },
      parsedResult: { success: true },
      priorResults: { list_tags: { tags: [{ id: 10, name: "area:ui", color: "blue", job_ids: [7] }] } }
    })

    expect(removeJobTagToolCard.collapsedSummary?.(removeContext)).toBe("Removed area:ui · JOB-7")
    const { container } = render(<>{removeJobTagToolCard.renderExpanded(removeContext)}</>)

    expect(screen.getByText("area:ui")).toBeInTheDocument()
    expect(screen.getByText("10")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/jobs/7")
    expect(container.querySelector("[style]")).toHaveStyle({ backgroundColor: "#dbeafe", color: "#1d4ed8" })
  })

  it("renders remove-tag pending and empty-result states", () => {
    const pending = context("remove_job_tag", { input: { job_id: 7, tag_id: 10 }, resultSettled: false })
    const emptyResult = context("remove_job_tag", {
      input: { job_id: 7, tag_id: 10 },
      resultBody: "",
      parsedResult: null,
      resultSettled: true
    })

    expect(removeJobTagToolCard.collapsedSummary?.(pending)).toBe("Removing tag #10 · JOB-7")
    const { rerender } = render(<>{removeJobTagToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Tag #10")).toBeInTheDocument()

    expect(removeJobTagToolCard.collapsedSummary?.(emptyResult)).toBe("Remove tag #10 returned an unexpected response · JOB-7")
    rerender(<>{removeJobTagToolCard.renderExpanded(emptyResult)}</>)
    expect(screen.getByText("unknown")).toBeInTheDocument()
    expect(screen.getByText("Unexpected tool response.")).toBeInTheDocument()
  })

  it("renders remove-tag attachment and lookup errors as styled cards", () => {
    const notAttached = context("remove_job_tag", {
      input: { job_id: 7, tag_id: 10 },
      parsedResult: { error: "tag is not attached to JOB-7" },
      resultError: true
    })
    const notFound = context("remove_job_tag", {
      input: { job_id: 7, tag_id: 99 },
      parsedResult: { error: "tag not found for this user: 99" },
      resultError: true
    })

    const { rerender } = render(<>{removeJobTagToolCard.renderExpanded(notAttached)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("tag is not attached to JOB-7")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/jobs/7")

    rerender(<>{removeJobTagToolCard.renderExpanded(notFound)}</>)
    expect(screen.getByText("tag not found for this user: 99")).toBeInTheDocument()
    expect(screen.getByText("Tag #99")).toBeInTheDocument()
  })

  it("normalizes remove-tag success and error envelopes from different providers", () => {
    const successEnvelope = { structured_content: { success: true } }
    const errorEnvelope = { content: [{ type: "text", text: JSON.stringify({ error: "tag not found for this user: 99" }) }] }
    const successContext = context(normalizedToolName("mcp__syrus__remove_job_tag"), {
      input: { job_id: 7, tag_id: 10 },
      parsedResult: normalizedToolCardParsedResult(successEnvelope)
    })
    const errorContext = context(normalizedToolName("syrus-chat-sidecar.remove_job_tag"), {
      input: { job_id: 7, tag_id: 99 },
      parsedResult: normalizedToolCardParsedResult(errorEnvelope),
      resultError: true
    })

    expect(successContext.toolName).toBe("remove_job_tag")
    expect(removeJobTagToolCard.collapsedSummary?.(successContext)).toBe("Removed tag #10 · JOB-7")
    expect(errorContext.toolName).toBe("remove_job_tag")
    expect(removeJobTagToolCard.collapsedSummary?.(errorContext)).toBe("Removed tag #99 failed · JOB-7")
    render(<>{removeJobTagToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("tag not found for this user: 99")).toBeInTheDocument()
  })

  it("renders the chat variant with markdown payload and a Media library link", () => {
    const input = {
      type: "review_report",
      title: "Review report",
      payload: { summary: `Found **two** issues. See JOB-42 and https://example.test/report. ${"More detail. ".repeat(100)}` }
    }
    const parsedResult = { message: "Saved.", chat_session_id: 12 }

    expect(submitArtifactToolCard.collapsedSummary?.(context("submit_artifact", { input, parsedResult }))).toBe("Artifact saved: Review report")
    render(<MemoryRouter>{submitArtifactToolCard.renderExpanded(context("submit_artifact", { input, parsedResult }))}</MemoryRouter>)

    expect(screen.getByText("Review report")).toBeInTheDocument()
    expect(screen.getByText("review_report")).toBeInTheDocument()
    expect(screen.getByText("two").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "https://example.test/report" })).toHaveAttribute("href", "https://example.test/report")
    expect(screen.getByRole("link", { name: "Chat Media library" })).toHaveAttribute("href", "/chats/12#media")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("normalizes the workflow variant and links its Workflow and Run", () => {
    const input = { type: "rails_schema_erd", title: "Schema ERD", payload: { tables: [{ name: "jobs" }] } }
    const envelope = { structured_content: { message: "Saved.", workflow_id: 28622, run_id: 230581, job_id: 7705 } }
    const cardContext = context(normalizedToolName("mcp__syrus__submit_artifact"), {
      input,
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(cardContext.toolName).toBe("submit_artifact")
    render(<>{submitArtifactToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByRole("link", { name: "WF-28622" })).toHaveAttribute("href", "/jobs/7705?tab=workflows#workflow-28622")
    expect(screen.getByRole("link", { name: "RUN-230581" })).toHaveAttribute("href", "/jobs/7705?tab=workflows#workflow-28622")
    expect(screen.getByText(/"jobs"/)).toBeInTheDocument()
  })

  it("renders screenshot payloads through the shared media preview", () => {
    const input = { type: "screenshot", title: "Mobile view", payload: { screenshot_url: "/media/mobile.png" } }
    render(<>{submitArtifactToolCard.renderExpanded(context("submit_artifact", { input, resultBody: "Saved.", resultSettled: true }))}</>)

    expect(screen.getByRole("img", { name: "Mobile view" })).toHaveAttribute("src", "/media/mobile.png")
    fireEvent.click(screen.getByRole("button", { name: "Open Mobile view" }))
    expect(screen.getByRole("dialog", { name: "media preview" })).toBeInTheDocument()
  })

  it("renders pending, empty, and error artifact states", () => {
    const input = { type: "report", title: "Review report", payload: {} }
    const { rerender } = render(<>{submitArtifactToolCard.renderExpanded(context("submit_artifact", { input, resultSettled: false }))}</>)
    expect(screen.getByText("Waiting for the artifact result.")).toBeInTheDocument()

    rerender(
      <>
        {submitArtifactToolCard.renderExpanded(
          context("submit_artifact", { input: { ...input, payload: { summary: " " } }, resultBody: "Saved.", resultSettled: true })
        )}
      </>
    )
    expect(screen.getByText("No artifact payload was submitted.")).toBeInTheDocument()

    rerender(
      <>
        {submitArtifactToolCard.renderExpanded(
          context("submit_artifact", { input, resultBody: "Storage unavailable", resultError: true, resultSettled: true })
        )}
      </>
    )
    expect(screen.getByText("Artifact submission failed")).toBeInTheDocument()
    expect(screen.getByText("Storage unavailable")).toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed payloads", () => {
    expect(listOpenIssuesToolCard.collapsedSummary?.(context("list_open_issues", { parsedResult: { oops: true } }))).toBeNull()
    expect(listTagsToolCard.renderExpanded(context("list_tags", { parsedResult: "not json" }))).toBeNull()
    expect(submitArtifactToolCard.renderExpanded(context("submit_artifact", { parsedResult: "not json", resultBody: "" }))).toBeNull()
  })
})
