import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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

describe("issue, tag, and artifact utility tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(listOpenIssuesToolCard.toolName).toBe("list_open_issues")
    expect(listTagsToolCard.toolName).toBe("list_tags")
    expect(createTagToolCard.toolName).toBe("create_tag")
    expect(addJobTagToolCard.toolName).toBe("add_job_tag")
    expect(removeJobTagToolCard.toolName).toBe("remove_job_tag")
    expect(submitArtifactToolCard.toolName).toBe("submit_artifact")
  })

  it("renders an empty issue list as a friendly empty state", () => {
    const cardContext = context("list_open_issues", { parsedResult: { issues: [] } })

    expect(listOpenIssuesToolCard.collapsedSummary?.(cardContext)).toBe("0 issues")
    render(<>{listOpenIssuesToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("No issues found.")).toBeInTheDocument()
  })

  it("renders multiple issues with number, title, labels, state, timestamps, and links", () => {
    const cardContext = context("list_open_issues", {
      parsedResult: {
        issues: [
          {
            number: 12,
            title: "Button sticks",
            labels: ["bug", "frontend"],
            state: "open",
            author: "ada",
            created_at: "2026-05-01T12:00:00Z",
            updated_at: "2026-05-02T12:00:00Z",
            html_url: "https://github.com/acme/widgets/issues/12",
            body_excerpt: "The submit button stays disabled."
          },
          { number: 13, title: "Missing docs", labels: [], state: "closed" }
        ]
      }
    })

    expect(listOpenIssuesToolCard.collapsedSummary?.(cardContext)).toBe("2 issues")
    render(<>{listOpenIssuesToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
    expect(screen.getByText("Button sticks")).toBeInTheDocument()
    expect(screen.getByText("bug")).toBeInTheDocument()
    expect(screen.getByText("frontend")).toBeInTheDocument()
    expect(screen.getByText("@ada")).toBeInTheDocument()
    expect(screen.getByText("Created")).toBeInTheDocument()
    expect(screen.getByText("Updated")).toBeInTheDocument()
    expect(screen.getByText("The submit button stays disabled.")).toBeInTheDocument()
    expect(screen.getByText("Missing docs")).toBeInTheDocument()
  })

  it("renders list_tags as compact chips with affected JOB ids when present", () => {
    const cardContext = context("list_tags", {
      parsedResult: {
        tags: [
          { id: 1, name: "area:auth", color: "#123abc", job_ids: [4777, 4778] },
          { id: 2, name: "urgent", color: "red" }
        ]
      }
    })

    expect(listTagsToolCard.collapsedSummary?.(cardContext)).toBe("2 tags")
    render(<>{listTagsToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getAllByText("area:auth").length).toBeGreaterThan(0)
    expect(screen.getAllByText("#1").length).toBeGreaterThan(0)
    expect(screen.getByText("urgent")).toBeInTheDocument()
    expect(screen.getByText("Affected Jobs")).toBeInTheDocument()
    expect(screen.getByText("JOB-4777")).toBeInTheDocument()
    expect(screen.getByText("JOB-4778")).toBeInTheDocument()
  })

  it("renders an empty tag list as a friendly empty state", () => {
    const cardContext = context("list_tags", { parsedResult: { tags: [] } })

    render(<>{listTagsToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("No tags found.")).toBeInTheDocument()
  })

  it("renders create/add/remove tag outcomes", () => {
    const createContext = context("create_tag", { parsedResult: { id: 5, name: "area:ui", color: "#abcdef" } })
    const addContext = context("add_job_tag", { input: { job_id: 4777, tag_id: 5 }, parsedResult: { success: true } })
    const removeContext = context("remove_job_tag", { input: { job_id: 4777, tag_id: 5 }, parsedResult: { success: true } })

    expect(createTagToolCard.collapsedSummary?.(createContext)).toBe("area:ui: created")
    expect(addJobTagToolCard.collapsedSummary?.(addContext)).toBe("Tag 5: added")
    expect(removeJobTagToolCard.collapsedSummary?.(removeContext)).toBe("Tag 5: removed")

    render(
      <>
        {createTagToolCard.renderExpanded(createContext)}
        {addJobTagToolCard.renderExpanded(addContext)}
        {removeJobTagToolCard.renderExpanded(removeContext)}
      </>
    )

    expect(screen.getByText("Tag created.")).toBeInTheDocument()
    expect(screen.getByText("Tag added to Job.")).toBeInTheDocument()
    expect(screen.getByText("Tag removed from Job.")).toBeInTheDocument()
    expect(screen.getAllByText("JOB-4777")).toHaveLength(2)
  })

  it("renders duplicate and invalid tag errors without requiring JSON", () => {
    const duplicateContext = context("create_tag", {
      input: { name: "area:auth" },
      resultBody: "Name has already been taken",
      resultError: true,
      parsedResult: null
    })
    const invalidContext = context("create_tag", {
      input: { name: " " },
      resultBody: "Name can't be blank",
      resultError: true,
      parsedResult: null
    })

    expect(createTagToolCard.collapsedSummary?.(duplicateContext)).toBe("Tag operation failed")
    render(
      <>
        {createTagToolCard.renderExpanded(duplicateContext)}
        {createTagToolCard.renderExpanded(invalidContext)}
      </>
    )

    expect(screen.getByText("Name has already been taken")).toBeInTheDocument()
    expect(screen.getByText("Name can't be blank")).toBeInTheDocument()
  })

  it("renders submitted artifact metadata with preview, open, and download affordances", () => {
    const cardContext = context("submit_artifact", {
      input: {
        type: "image_diff",
        title: "Desktop screenshot",
        payload: {
          artifact_id: "artifact:7",
          path: "screenshots/desktop.png",
          preview_url: "/rails/active_storage/blobs/desktop.png",
          url: "https://example.test/artifacts/7",
          download_url: "https://example.test/artifacts/7/download",
          renderer_type: "image_diff"
        }
      },
      parsedResult: { message: "Saved." }
    })

    expect(submitArtifactToolCard.collapsedSummary?.(cardContext)).toBe("Desktop screenshot saved")
    render(<>{submitArtifactToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Desktop screenshot")).toBeInTheDocument()
    expect(screen.getAllByText("image_diff").length).toBeGreaterThan(0)
    expect(screen.getByText("artifact:7")).toBeInTheDocument()
    expect(screen.getByText("screenshots/desktop.png")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Preview" })).toHaveAttribute("href", "/rails/active_storage/blobs/desktop.png")
    expect(screen.getByRole("link", { name: "Open" })).toHaveAttribute("href", "https://example.test/artifacts/7")
    expect(screen.getByRole("link", { name: "Download" })).toHaveAttribute("href", "https://example.test/artifacts/7/download")
    expect(screen.getByRole("img", { name: "Desktop screenshot" })).toHaveAttribute("src", "/rails/active_storage/blobs/desktop.png")
  })

  it("renders artifact submissions with missing optional fields", () => {
    const cardContext = context("submit_artifact", {
      input: { type: "rails_schema_erd", title: "Schema ERD", payload: { tables: [] } },
      parsedResult: { message: "Saved." }
    })

    render(<>{submitArtifactToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Schema ERD")).toBeInTheDocument()
    expect(screen.getByText("rails_schema_erd")).toBeInTheDocument()
    expect(screen.queryByText("Preview")).not.toBeInTheDocument()
    expect(screen.queryByText("Download")).not.toBeInTheDocument()
  })

  it("falls back to null for malformed utility payloads", () => {
    expect(listOpenIssuesToolCard.renderExpanded(context("list_open_issues", { parsedResult: { oops: true } }))).toBeNull()
    expect(listTagsToolCard.renderExpanded(context("list_tags", { parsedResult: { tags: "bad" } }))).toBeNull()
    expect(submitArtifactToolCard.renderExpanded(context("submit_artifact", { parsedResult: { message: "Saved." } }))).toBeNull()
  })
})
