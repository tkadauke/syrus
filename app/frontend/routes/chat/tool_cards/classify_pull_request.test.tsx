import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import classifyPullRequestToolCard from "./classify_pull_request"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "classify_pull_request", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("classify_pull_request tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(classifyPullRequestToolCard.toolName).toBe("classify_pull_request")
  })

  it("summarizes the PR number and classification", () => {
    const parsedResult = { repository: "tkadauke/syrus", pr_number: 42, classification: "syrus_job_export", evidence: {} }
    expect(classifyPullRequestToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("PR #42: syrus_job_export")
  })

  it("renders evidence: head/base refs, fork status, and marker kind", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      pr_number: 42,
      classification: "syrus_job_export",
      evidence: {
        head_ref: "syrus/direct-4225",
        base_ref: "main",
        head_repository: "tkadauke/syrus",
        fork_pr: false,
        marker: { kind: "syrus_job_export", job_id: "4225" },
        classification_enabled: true
      }
    }

    render(<>{classifyPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("PR #42")).toBeInTheDocument()
    expect(screen.getByText("syrus_job_export")).toBeInTheDocument()
    expect(screen.getByText("same-repo")).toBeInTheDocument()
    expect(screen.getByText("marker: syrus_job_export")).toBeInTheDocument()
    expect(screen.getByText("syrus/direct-4225")).toBeInTheDocument()
    expect(screen.getByText("main")).toBeInTheDocument()
  })

  it("marks a fork PR", () => {
    const parsedResult = { repository: "tkadauke/syrus", pr_number: 42, classification: "external_unknown", evidence: { fork_pr: true } }
    render(<>{classifyPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("fork")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(classifyPullRequestToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(classifyPullRequestToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
