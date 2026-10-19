import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import classifyPullRequestToolCard from "./classify_pull_request"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"

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

  it("renders linked repositories, refs, and every marker field", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      pr_number: 42,
      classification: "syrus_job_export",
      evidence: {
        head_ref: "syrus/direct-325",
        base_ref: "main",
        head_repository: "tkadauke/syrus",
        fork_pr: false,
        marker: { kind: "syrus_job_export", job_id: "4225", workflow_id: "9876", note: "A long marker detail" },
        classification_enabled: true
      }
    }

    render(<>{classifyPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("PR #42")).toBeInTheDocument()
    expect(screen.getByText("syrus_job_export")).toBeInTheDocument()
    expect(screen.getByText("same-repo")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "PR #42" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/42")
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus" })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("link", { name: "syrus/direct-325" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/syrus%2Fdirect-325")
    expect(screen.getByRole("link", { name: "main" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/main")
    expect(screen.getByText(/"kind": "syrus_job_export"/)).toBeInTheDocument()
    expect(screen.getByText(/"job_id": "4225"/)).toBeInTheDocument()
    expect(screen.getByText(/"workflow_id": "9876"/)).toBeInTheDocument()
    expect(screen.getByText(/"note": "A long marker detail"/)).toBeInTheDocument()
  })

  it("marks a fork PR", () => {
    const parsedResult = { repository: "tkadauke/syrus", pr_number: 42, classification: "external_unknown", evidence: { fork_pr: true } }
    render(<>{classifyPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("fork")).toBeInTheDocument()
  })

  it("warns when classification is disabled and shows an empty marker state", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      pr_number: 42,
      classification: "external_unknown",
      evidence: { classification_enabled: false }
    }
    render(<>{classifyPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Classification disabled")).toBeInTheDocument()
    expect(screen.getByText("No marker found.")).toBeInTheDocument()
  })

  it.each([
    [
      "content text",
      {
        content: [{ type: "text", text: JSON.stringify({ repository: "tkadauke/syrus", pr_number: 42, classification: "external_unknown", evidence: {} }) }],
        structured_content: null
      }
    ],
    [
      "structured content",
      { content: [], structured_content: { repository: "tkadauke/syrus", pr_number: 43, classification: "external_unknown", evidence: {} } }
    ]
  ])("renders a normalized %s MCP envelope", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    const toolName = normalizedToolName("mcp__syrus-chat-sidecar__classify_pull_request")
    expect(toolName).toBe("classify_pull_request")
    expect(classifyPullRequestToolCard.collapsedSummary?.(context({ toolName, parsedResult }))).toMatch(/^PR #4[23]: external_unknown$/)
  })

  it.each(["pull request not found: #404", "no repository attached"])("renders an error result: %s", (resultBody) => {
    const toolContext = context({ input: { pr_number: 404 }, resultBody, resultError: true })
    expect(classifyPullRequestToolCard.collapsedSummary?.(toolContext)).toBe(`PR classification failed: ${resultBody}`)
    render(<>{classifyPullRequestToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("PR classification failed")).toBeInTheDocument()
    expect(screen.getByText(resultBody)).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(classifyPullRequestToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(classifyPullRequestToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
