import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "../../../pluginToolCards"
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

function renderCard(parsedResult: unknown) {
  return render(<MemoryRouter>{readJobToolCard.renderExpanded(context({ parsedResult }))}</MemoryRouter>)
}

describe("read_job tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readJobToolCard.toolName).toBe("read_job")
  })

  it("shows the canonical JOB id, title, state, PR, branch, priority, agent provider, and dependencies", () => {
    const parsedResult = {
      job: {
        id: 4048,
        issue_title: "Typed renderers",
        state: "running",
        pr_number: 12,
        branch_name: "syrus/direct-4048",
        priority: "high",
        agent_provider: "claude",
        dependencies: [
          { id: 4001, issue_title: "Upstream fix", state: "merged" },
          { epic_id: 291, title: "Tier 1 cards", state: "open" },
          { pending: true, unresolved_ref: "JOB-9999", unresolved_ref_kind: "job", source: "issue_body" }
        ]
      }
    }

    renderCard(parsedResult)

    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByText("Typed renderers")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("#12")).toBeInTheDocument()
    expect(screen.getByText("syrus/direct-4048")).toBeInTheDocument()
    expect(screen.getByText("high")).toBeInTheDocument()
    expect(screen.getByText("claude")).toBeInTheDocument()

    expect(screen.getByRole("link", { name: "JOB-4001" })).toHaveAttribute("href", "/jobs/4001")
    expect(screen.getByText("Upstream fix")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-291" })).toHaveAttribute("href", "/epics/291")
    expect(screen.getByText("Tier 1 cards")).toBeInTheDocument()
    expect(screen.getByText("JOB-9999")).toBeInTheDocument()
  })

  it("renders the deployment stage pipeline when deployment stages are present", () => {
    const parsedResult = {
      job: {
        id: 4048,
        state: "merged",
        deployment_stages: [
          { name: "staging", label: "Staging", reached: true, reached_at: "2026-09-01T00:00:00Z", tag_sha: "abc123" },
          { name: "production", label: "Production", reached: false, reached_at: null, tag_sha: null }
        ]
      }
    }

    renderCard(parsedResult)

    expect(screen.getByTestId("deployment-stage-pipeline")).toBeInTheDocument()
    expect(screen.getByText("Staging")).toBeInTheDocument()
    expect(screen.getByText("Production")).toBeInTheDocument()
  })

  it("omits optional sections entirely when the payload doesn't carry them", () => {
    const { container } = renderCard({ job: { id: 4048, state: "open" } })

    expect(screen.getByRole("link", { name: "JOB-4048" })).toBeInTheDocument()
    expect(screen.queryByText("Dependencies")).not.toBeInTheDocument()
    expect(screen.queryByTestId("deployment-stage-pipeline")).not.toBeInTheDocument()
    expect(container.querySelector("dl")).not.toBeInTheDocument()
  })

  it("uses dark-mode-safe classes for the card container", () => {
    const { container } = renderCard({ job: { id: 4048, state: "open" } })

    expect(container.firstElementChild).toHaveClass("dark:border-gray-700", "dark:bg-gray-900")
  })

  it("falls back to null for a malformed payload (missing job or job id)", () => {
    expect(readJobToolCard.renderExpanded(context({ parsedResult: { job: { state: "open" } } }))).toBeNull()
    expect(readJobToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readJobToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
