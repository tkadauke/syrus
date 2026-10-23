import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import ingestPullRequestToolCard from "./ingest_pull_request"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "ingest_pull_request", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const result = {
  pr_number: 42,
  pr_url: "https://github.com/acme/widgets/pull/42",
  already_ingested: false,
  classification: "external_unknown",
  job: { id: 900, slug: "review-widget", state: "queued", kind: "external_pr", epic_id: 12 }
}

describe("ingest_pull_request tool card", () => {
  it("registers under the normalized MCP tool name", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__ingest_pull_request")).toBe(ingestPullRequestToolCard.toolName)
  })

  it("summarizes fresh and already-ingested results with the descriptive slug", () => {
    expect(ingestPullRequestToolCard.collapsedSummary?.(context({ parsedResult: result }))).toBe("PR #42 ingested as review-widget")
    expect(ingestPullRequestToolCard.collapsedSummary?.(context({ parsedResult: { ...result, already_ingested: true, classification: undefined } }))).toBe(
      "PR #42 already ingested as review-widget"
    )
  })

  it("renders linked PR, Job, and Epic references plus auto-detected classification", () => {
    render(<>{ingestPullRequestToolCard.renderExpanded(context({ input: { pr_number: 42 }, parsedResult: result }))}</>)

    expect(screen.getByRole("link", { name: "PR #42" })).toHaveAttribute("href", result.pr_url)
    expect(screen.getByRole("link", { name: "JOB-900" })).toHaveAttribute("href", "/jobs/900")
    expect(screen.getByRole("link", { name: "EPIC-12" })).toHaveAttribute("href", "/epics/12")
    expect(screen.getByText("Auto-detected classification")).toBeInTheDocument()
    expect(screen.getByText("external_unknown")).toBeInTheDocument()
    expect(screen.getByText("queued")).toBeInTheDocument()
    expect(screen.getByText("external_pr")).toBeInTheDocument()
  })

  it("distinguishes an input classification override and renders the empty Job state", () => {
    const parsedResult = { ...result, classification: "manual_hotfix", job: null }
    render(<>{ingestPullRequestToolCard.renderExpanded(context({ input: { pr_number: 42, classification: "manual_hotfix" }, parsedResult }))}</>)

    expect(screen.getByText("Classification override")).toBeInTheDocument()
    expect(screen.getByText("manual_hotfix")).toBeInTheDocument()
    expect(screen.getByText("No Job was created for this classification.")).toBeInTheDocument()
  })

  it("keeps a partial Job payload visible instead of dropping the whole card", () => {
    const parsedResult = { ...result, job: { id: 900, epic_id: 12 } }
    render(<>{ingestPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "JOB-900" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-12" })).toBeInTheDocument()
  })

  it.each([{}, { state: "queued", kind: "external_pr" }, "not-a-job"])("renders an incomplete state for a Job payload without identity: %j", (job) => {
    render(<>{ingestPullRequestToolCard.renderExpanded(context({ parsedResult: { ...result, job } }))}</>)

    expect(screen.getByText("The ingestion result included incomplete Job details.")).toBeInTheDocument()
    expect(screen.queryByText("No Job was created for this classification.")).not.toBeInTheDocument()
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(result) }] }, result],
    ["structured content", { structured_content: result }, result]
  ])("uses the shared normalizer for the %s envelope", (_label, envelope, expected) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(parsedResult).toEqual(expected)
    expect(ingestPullRequestToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("PR #42 ingested as review-widget")
  })

  it.each(["pull request not found: #404", "classification must be one of: external_unknown, manual_hotfix", "Title can't be blank", "no repository attached"])(
    "renders an actionable failure state for %s",
    (message) => {
      const parsedResult = { content: [{ type: "text", text: `Error: ${message}` }], structured_content: null }
      const toolContext = context({ input: { pr_number: 42 }, parsedResult, resultBody: JSON.stringify(parsedResult), resultError: true })

      expect(ingestPullRequestToolCard.collapsedSummary?.(toolContext)).toBe(`Pull request ingestion failed: ${message}`)
      render(<>{ingestPullRequestToolCard.renderExpanded(toolContext)}</>)
      expect(screen.getByText("Pull request ingestion failed")).toBeInTheDocument()
      expect(screen.getByText(message)).toBeInTheDocument()
    }
  )

  it("falls back to the generic renderer only when the result itself is malformed", () => {
    expect(ingestPullRequestToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(ingestPullRequestToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
