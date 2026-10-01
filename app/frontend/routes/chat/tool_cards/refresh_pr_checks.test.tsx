import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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
  it("registers under the exact MCP tool name", () => {
    expect(refreshPrChecksToolCard.toolName).toBe("refresh_pr_checks")
  })

  it("summarizes the target PR and refreshed state", () => {
    const parsedResult = { job_id: 42, slug: "repair-ci", pr_number: 314, pr_checks_state: "failing", failing_checks: [] }

    expect(refreshPrChecksToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-42 (repair-ci) PR #314 checks refreshed: failing")
  })

  it("renders prior and current state, refreshed providers, checks, errors, and next action", () => {
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
          summary: "1 example failed",
          details_url: "https://github.com/acme/widgets/actions/runs/1"
        }
      ],
      errors: [{ provider: "GitHub Actions", message: "One check suite was rate limited." }]
    }

    render(<>{refreshPrChecksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("JOB-42 (repair-ci) PR #314")).toBeInTheDocument()
    expect(screen.getByText("Prior state")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Current state")).toBeInTheDocument()
    expect(screen.getAllByText("failing").length).toBeGreaterThan(0)
    expect(screen.getAllByText("GitHub Actions").length).toBeGreaterThan(0)
    expect(screen.getByText("frontend-lint")).toBeInTheDocument()
    expect(screen.getByText("1 example failed")).toBeInTheDocument()
    expect(screen.getByText("GitHub Actions: One check suite was rate limited.")).toBeInTheDocument()
    expect(screen.getByText(/review provider errors/i)).toBeInTheDocument()

    const link = screen.getByRole("link", { name: "rspec" })
    expect(link).toHaveAttribute("href", "https://github.com/acme/widgets/actions/runs/1")
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

  it("falls back to null for malformed payloads", () => {
    expect(refreshPrChecksToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(refreshPrChecksToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("includes catalog examples for required scenarios", () => {
    expect(examples.map((example) => example.id)).toEqual(["successful_refresh", "already_current", "missing_pr", "provider_failure"])
  })
})
