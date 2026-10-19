import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import refreshPrChecksToolCard, { examples } from "./refresh_pr_checks"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "refresh_pr_checks",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("refresh_pr_checks tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
  })

  it("registers under the exact MCP tool name", () => {
    expect(refreshPrChecksToolCard.toolName).toBe("refresh_pr_checks")
  })

  it("summarizes the target PR and refreshed state", () => {
    const parsedResult = { job_id: 42, slug: "repair-ci", pr_number: 314, pr_checks_state: "failing", failing_checks: [] }

    expect(refreshPrChecksToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-42 (repair-ci) PR #314 checks refreshed: failing")
  })

  it("renders linked entities, commit SHAs, refreshed check states, markdown summaries, and next action", () => {
    const parsedResult = {
      job_id: 42,
      slug: "repair-ci",
      pr_number: 314,
      previous_pr_checks_state: "pending",
      pr_checks_state: "failing",
      pr_checks_checked_at: "2026-10-01T15:45:12Z",
      head_sha: "abc1234567890000000000000000000000000000",
      base_sha: "def1234567890000000000000000000000000000",
      refreshed_providers: ["GitHub Actions"],
      refreshed_checks: [
        { name: "rspec", provider: "GitHub Actions", conclusion: "failure", details_url: "https://github.com/acme/widgets/actions/runs/1" },
        { name: "frontend-lint", provider: "GitHub Actions", conclusion: "success", details_url: "https://github.com/acme/widgets/actions/runs/2" }
      ],
      failing_checks: [
        {
          name: "rspec",
          provider: "GitHub Actions",
          conclusion: "failure",
          summary: `**1 example failed**\n${"Detailed failure context. ".repeat(40)}`,
          details_url: "https://github.com/acme/widgets/actions/runs/1"
        }
      ]
    }

    render(<>{refreshPrChecksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByText("(repair-ci)")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "PR #314" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/314")
    expect(screen.getByText("Prior state")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Current state")).toBeInTheDocument()
    expect(screen.getAllByText("failing").length).toBeGreaterThan(0)
    expect(screen.getAllByText("GitHub Actions").length).toBeGreaterThan(0)
    expect(screen.getByRole("link", { name: "frontend-lint" })).toHaveAttribute("href", "https://github.com/acme/widgets/actions/runs/2")
    expect(screen.getByText("success")).toBeInTheDocument()
    expect(screen.getByTestId("markdown-preview-content").querySelector("strong")).toHaveTextContent("1 example failed")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.getByText(/inspect the failing checks/i)).toBeInTheDocument()

    expect(screen.getByRole("link", { name: "abc123456789" })).toHaveAttribute("href", `https://github.com/acme/widgets/commit/${parsedResult.head_sha}`)
    expect(screen.getByRole("link", { name: "def123456789" })).toHaveAttribute("href", `https://github.com/acme/widgets/commit/${parsedResult.base_sha}`)
    fireEvent.click(screen.getByRole("button", { name: `Copy ${parsedResult.head_sha} to clipboard` }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(parsedResult.head_sha)

    expect(screen.getAllByRole("link", { name: "rspec" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "rspec" })[0]).toHaveAttribute("href", "https://github.com/acme/widgets/actions/runs/1")
  })

  it("rejects unsafe check links and wraps long names", () => {
    const parsedResult = {
      job_id: 46,
      pr_checks_state: "passing",
      refreshed_checks: [{ name: "a-very-long-check-name-that-needs-to-wrap-on-mobile", conclusion: "success", details_url: "javascript:alert(1)" }],
      failing_checks: []
    }

    render(<>{refreshPrChecksToolCard.renderExpanded(context({ parsedResult }))}</>)

    const name = screen.getByText("a-very-long-check-name-that-needs-to-wrap-on-mobile")
    expect(name.closest("a")).toBeNull()
    expect(name).toHaveClass("min-w-0", "break-words", "[overflow-wrap:anywhere]")
    expect(screen.queryByRole("link", { name: /a-very-long/ })).not.toBeInTheDocument()
  })

  it("renders a no-op already-current refresh with no failing checks", () => {
    const parsedResult = {
      job_id: 43,
      slug: "green-pr",
      pr_number: 315,
      previous_pr_checks_state: "passing",
      pr_checks_state: "passing",
      refreshed_checks: [{ name: "rspec", provider: "GitHub Actions", conclusion: "success", details_url: "https://github.com/acme/widgets/actions/runs/3" }],
      failing_checks: []
    }

    render(<>{refreshPrChecksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No failing checks reported.")).toBeInTheDocument()
    expect(screen.getByText(/continue mergeability or landing checks/i)).toBeInTheDocument()
  })

  it("uses the shared failure card for missing PR or provider errors returned as tool failures", () => {
    const failure = context({ input: { job_id: 44 }, resultBody: "Job has no tracked PR.", resultError: true })

    expect(refreshPrChecksToolCard.collapsedSummary?.(failure)).toBe("PR check refresh failed: Job has no tracked PR.")
    render(<>{refreshPrChecksToolCard.renderExpanded(failure)}</>)

    expect(screen.getByText("PR check refresh failed")).toBeInTheDocument()
    expect(screen.getByText("Job has no tracked PR.")).toBeInTheDocument()
    expect(screen.getByText("Refresh checks for JOB-44")).toBeInTheDocument()
  })

  it("uses shared provider normalization for MCP prefixes and result envelopes", () => {
    const payload = { job_id: 42, pr_number: 314, pr_checks_state: "passing", refreshed_checks: [], failing_checks: [] }
    const textEnvelope = { content: [{ type: "text", text: JSON.stringify(payload) }] }
    const structuredEnvelope = { structured_content: payload, content: [{ type: "text", text: "ignored" }] }

    expect(normalizedToolName("mcp__syrus-chat-sidecar__refresh_pr_checks")).toBe("refresh_pr_checks")
    expect(refreshPrChecksToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(textEnvelope) }))).toContain(
      "PR #314 checks refreshed"
    )
    expect(refreshPrChecksToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(structuredEnvelope) }))).toContain(
      "PR #314 checks refreshed"
    )
  })

  it("detects an MCP Error text result even without a provider-specific errors key", () => {
    const failure = context({
      parsedResult: { content: [{ type: "text", text: "Error: Timed out fetching check runs." }] }
    })

    expect(refreshPrChecksToolCard.collapsedSummary?.(failure)).toBe("PR check refresh failed: Timed out fetching check runs.")
    render(<>{refreshPrChecksToolCard.renderExpanded(failure)}</>)
    expect(screen.getByText("Timed out fetching check runs.")).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(refreshPrChecksToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(refreshPrChecksToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("includes catalog examples for required scenarios", () => {
    expect(examples.map((example) => example.id)).toEqual(["successful_refresh", "already_current", "missing_pr", "provider_failure"])
  })
})
