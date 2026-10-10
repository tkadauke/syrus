import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readJobToolCard from "./read_job"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_job",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("read_job tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readJobToolCard.toolName).toBe("read_job")
  })

  it("summarizes the collapsed row with the canonical JOB id and state", () => {
    const parsedResult = { job: { id: 4048, state: "running" } }
    expect(readJobToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-4048 (running)")
  })

  it("renders the canonical JOB id, title, state, PR, branch, priority, and agent provider", () => {
    const parsedResult = {
      job: {
        id: 4048,
        issue_title: "Add plugin-aware tool cards",
        state: "running",
        pr_number: 12,
        repository_slug: "tkadauke/syrus",
        branch_name: "syrus/direct-148",
        priority: "high",
        agent_provider: "claude"
      }
    }

    render(<>{readJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("JOB-4048")).toBeInTheDocument()
    expect(screen.getByText("Add plugin-aware tool cards")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "PR #12" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/12")
    expect(screen.getByText("syrus/direct-148")).toBeInTheDocument()
    expect(screen.getByText("high priority")).toBeInTheDocument()
    expect(screen.getByText("claude")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByRole("button", { name: "Copy JOB-4048 to clipboard" })).toBeInTheDocument()
  })

  it("renders dependency badges, distinguishing pending dependencies", () => {
    const parsedResult = {
      job: {
        id: 4048,
        state: "queued",
        dependencies: [
          { id: 4040, issue_title: "Upstream job", state: "approved", repository: "tkadauke/syrus" },
          {
            id: 4041,
            issue_title: "Deploy upstream job",
            state: "closed",
            repository: "tkadauke/syrus",
            satisfaction_mode: "deployment_stage",
            required_deployment_stage_name: "production",
            latest_deployment_stage: { name: "staging", label: "Staging" }
          },
          { epic_id: 291, display_number: "the Tier 1 tool-card work", title: "Tier 1 Custom Tool Cards", state: "running" },
          { pending: true, unresolved_ref: "owner/repo#123", unresolved_ref_kind: "issue", unresolved_ref_state: "open" }
        ]
      }
    }

    render(<>{readJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "JOB-4040" })).toHaveAttribute("href", "/jobs/4040")
    expect(screen.getByRole("link", { name: "JOB-4041" })).toHaveAttribute("href", "/jobs/4041")
    expect(screen.getByText(/stage production .* latest Staging/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "the Tier 1 tool-card work" })).toHaveAttribute("href", "/epics/291")
    expect(screen.getByText(/approved/)).toBeInTheDocument()
    expect(screen.getByText("owner/repo#123 · open")).toBeInTheDocument()
  })

  it("renders the deployment stage chain when present", () => {
    const parsedResult = {
      job: {
        id: 4048,
        state: "closed",
        deployment_stages: [
          { name: "staging", label: "Staging", reached: true },
          { name: "production", label: "Production", reached: false }
        ]
      }
    }

    render(<>{readJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Staging")).toBeInTheDocument()
    expect(screen.getByText("Production")).toBeInTheDocument()
  })

  it("omits optional sections when fields are missing", () => {
    const parsedResult = { job: { id: 4048, state: "queued" } }

    render(<>{readJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    // Falls back to the Job slug for both the header pill and the title when
    // issue_title is absent, so it legitimately appears twice.
    expect(screen.getAllByText("JOB-4048")).toHaveLength(2)
    expect(screen.queryByText("Dependencies")).not.toBeInTheDocument()
    expect(screen.queryByText("Deployment stage")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing job object)", () => {
    expect(readJobToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readJobToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readJobToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("falls back to null when the job is missing required id/state fields", () => {
    expect(readJobToolCard.renderExpanded(context({ parsedResult: { job: { issue_title: "No id" } } }))).toBeNull()
  })
})
