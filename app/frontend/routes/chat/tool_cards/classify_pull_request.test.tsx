import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import deChat from "../../../i18n/locales/de/chat.json"
import enChat from "../../../i18n/locales/en/chat.json"
import laChat from "../../../i18n/locales/la/chat.json"
import { normalizedToolCardParsedResult, toolResultPresentation } from "../toolRendering"
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

  it("renders linked repositories, PR, refs, fork status, and every marker field", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      pr_number: 42,
      classification: "syrus_job_export",
      evidence: {
        head_ref: "syrus/direct-325",
        base_ref: "main",
        head_repository: "tkadauke/syrus",
        fork_pr: false,
        marker: { kind: "syrus_job_export", job_id: "4225", source: "a very long marker detail" },
        classification_enabled: true
      }
    }

    render(<>{classifyPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("PR #42")).toBeInTheDocument()
    expect(screen.getByText("PR #42").closest("a")).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/42")
    expect(screen.getByText("syrus_job_export")).toBeInTheDocument()
    expect(screen.getByText("same repository")).toBeInTheDocument()
    expect(screen.getByText("marker: syrus_job_export")).toBeInTheDocument()
    expect(screen.getAllByText("tkadauke/syrus")[0].closest("a")).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByText("syrus/direct-325")).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/syrus%2Fdirect-325")
    expect(screen.getByText("main")).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/main")
    expect(screen.getByText("Marker details")).toBeInTheDocument()
    expect(screen.getByText(/job_id/)).toBeInTheDocument()
    expect(screen.getByText(/very long marker detail/)).toBeInTheDocument()
  })

  it("marks a fork PR", () => {
    const parsedResult = { repository: "tkadauke/syrus", pr_number: 42, classification: "external_unknown", evidence: { fork_pr: true } }
    render(<>{classifyPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("fork")).toBeInTheDocument()
  })

  it("warns when classification is disabled", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      pr_number: 42,
      classification: "external_unknown",
      evidence: { classification_enabled: false }
    }
    render(<>{classifyPullRequestToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("Classification disabled")
  })

  it("renders tool errors with the attempted PR in the summary", () => {
    const toolContext = context({ input: { pr_number: 404 }, resultBody: "pull request not found: #404", resultError: true })
    expect(classifyPullRequestToolCard.collapsedSummary?.(toolContext)).toBe("PR #404 classification failed")
    render(<>{classifyPullRequestToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("pull request not found: #404")).toBeInTheDocument()
  })

  it("renders a localized empty state for malformed results", () => {
    render(<>{classifyPullRequestToolCard.renderExpanded(context({ parsedResult: { oops: true } }))}</>)
    expect(screen.getByText("No pull request classification details were returned.")).toBeInTheDocument()
  })

  it("accepts content text and structured-content MCP envelopes through the shared normalizer", () => {
    const payload = { repository: "tkadauke/syrus", pr_number: 42, classification: "external_unknown", evidence: {} }
    expect(normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null })).toEqual(payload)
    expect(normalizedToolCardParsedResult({ content: [{ type: "text", text: "ignored" }], structured_content: payload })).toEqual(payload)
  })

  it("dispatches an mcp-prefixed tool name to the registered card", () => {
    const payload = { repository: "tkadauke/syrus", pr_number: 42, classification: "external_unknown", evidence: {} }
    expect(toolResultPresentation("mcp__syrus-chat-sidecar__classify_pull_request", JSON.stringify(payload))).toMatchObject({
      kind: "text",
      summary: "PR #42: external_unknown"
    })
  })

  it("defines its copy in every chat locale", () => {
    const keys = [
      "tool_card_classify_pr_failed",
      "tool_card_classify_pr_empty",
      "tool_card_classify_pr_disabled",
      "tool_card_classify_pr_repository",
      "tool_card_classify_pr_marker_details"
    ] as const
    for (const locale of [enChat, deChat, laChat]) {
      for (const key of keys) expect(locale[key]).toBeTruthy()
    }
  })

  it("falls back to null for a malformed payload", () => {
    expect(classifyPullRequestToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(classifyPullRequestToolCard.renderExpanded(context({ parsedResult: "not json" }))).not.toBeNull()
  })
})
