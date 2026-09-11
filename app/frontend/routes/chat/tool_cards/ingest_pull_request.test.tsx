import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import ingestPullRequestToolCard from "./ingest_pull_request"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "ingest_pull_request", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("ingest_pull_request tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(ingestPullRequestToolCard.toolName).toBe("ingest_pull_request")
  })

  it("summarizes a fresh ingestion", () => {
    const parsedResult = {
      pr_number: 42,
      already_ingested: false,
      classification: "external_unknown",
      job: { id: 900, slug: "JOB-900", state: "queued", kind: "direct" }
    }
    expect(ingestPullRequestToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("PR #42 ingested as JOB-900")
  })

  it("summarizes an already-ingested PR", () => {
    const parsedResult = { pr_number: 42, already_ingested: true, job: { id: 900, slug: "JOB-900", state: "landing", kind: "direct" } }
    expect(ingestPullRequestToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("PR #42 already ingested as JOB-900")
  })

  it("renders classification and job summary", () => {
    const parsedResult = {
      pr_number: 42,
      already_ingested: false,
      classification: "external_unknown",
      job: { id: 900, slug: "JOB-900", state: "queued", kind: "direct" }
    }

    render(<>{ingestPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("PR #42")).toBeInTheDocument()
    expect(screen.getByText("ingested")).toBeInTheDocument()
    expect(screen.getByText("external_unknown")).toBeInTheDocument()
    expect(screen.getByText("JOB-900")).toBeInTheDocument()
    expect(screen.getByText("queued")).toBeInTheDocument()
    expect(screen.getByText("direct")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(ingestPullRequestToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(ingestPullRequestToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
