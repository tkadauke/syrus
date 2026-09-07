import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import proposeJobToolCard from "./propose_job"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "propose_job", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("propose_job tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(proposeJobToolCard.toolName).toBe("propose_job")
  })

  it("summarizes a freshly proposed Job", () => {
    const parsedResult = { slug: "fix-output", title: "Fix output", kind: "job", state: "proposed" }
    expect(proposeJobToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Job proposal: Fix output (proposed)")
  })

  it("renders the slug, state, repository, dependencies, and target epic", () => {
    const parsedResult = {
      slug: "fix-output",
      title: "Fix output",
      kind: "job",
      state: "proposed",
      repository: "tkadauke/syrus",
      dependencies: ["other-proposal"],
      target_epic: { id: 12, number: 292, label: "EPIC-292" }
    }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("fix-output")).toBeInTheDocument()
    expect(screen.getByText("Fix output")).toBeInTheDocument()
    expect(screen.getByText("proposed")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("1")).toBeInTheDocument()
    expect(screen.getByText("EPIC-292")).toBeInTheDocument()
  })

  it("renders the materialized Job once confirmed", () => {
    const parsedResult = {
      slug: "fix-output",
      title: "Fix output",
      kind: "job",
      state: "confirmed",
      materialized: { kind: "job", job_id: 4222, job_title: "Fix output", job_state: "running" }
    }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("JOB-4222")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
  })

  it("renders a withdrawn proposal without a materialized result", () => {
    const parsedResult = { slug: "fix-output", title: "Fix output", kind: "job", state: "withdrawn" }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("withdrawn")).toBeInTheDocument()
    expect(screen.queryByText(/Materialized as/)).not.toBeInTheDocument()
  })

  it("renders the rejection reason for a rejected proposal", () => {
    const parsedResult = { slug: "fix-output", title: "Fix output", kind: "job", state: "rejected", materialized: { kind: "rejected", reason: "rejected" } }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Rejected: rejected")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(proposeJobToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeJobToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(proposeJobToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeJobToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
