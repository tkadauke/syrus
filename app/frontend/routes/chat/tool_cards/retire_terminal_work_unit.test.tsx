import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import card, { examples } from "./retire_terminal_work_unit"

const eligibility = examples[0].parsedResult!

function context(envelope: unknown, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: normalizedToolName("mcp__syrus-chat-sidecar__retire_terminal_work_unit"),
    input: { work_unit_id: 73, reason: "Release the **stale ownership**.", dry_run: true },
    resultBody: JSON.stringify(envelope),
    resultError: false,
    parsedResult: normalizedToolCardParsedResult(envelope),
    ...overrides
  }
}

describe("retire_terminal_work_unit tool card", () => {
  it("registers the normalized MCP tool and publishes catalog examples", () => {
    expect(card.toolName).toBe(normalizedToolName("mcp__provider__retire_terminal_work_unit"))
    expect(examples.map((example) => example.id)).toEqual(["eligible_dry_run", "pending_retirement", "ineligible"])
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(eligibility) }], structured_content: null }],
    ["structured content", { content: [{ type: "text", text: "ignored" }], structured_content: eligibility }]
  ])("renders dedicated eligibility details from normalized %s", (_label, envelope) => {
    render(<>{card.renderExpanded(context(envelope))}</>)

    expect(screen.getByText("eligible")).toBeInTheDocument()
    expect(screen.getByText("1 work unit")).toBeInTheDocument()
    expect(screen.getByText("2 locks")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "WF-612" })).toHaveAttribute("href", "/admin/workflows/612")
    expect(screen.getByText("job:42")).toBeInTheDocument()
    expect(screen.getByText("stale ownership")).toBeInTheDocument()
    expect(screen.getByText("No blocking preconditions")).toBeInTheDocument()
  })

  it("renders blocking preconditions, affected Runs, and wrapped lock keys", () => {
    const rejected = {
      ...(eligibility as Record<string, unknown>),
      status: "rejected",
      blocking_preconditions: ["Workflow #612 is running, not terminal"],
      affected_ids: { work_unit_ids: [73], workflow_ids: [612], run_ids: [240098], lock_ids: [91] },
      facts: {
        work_unit_state: "running",
        workflow_state: "running",
        lock_keys: ["repository:7:delivery-track:production:landing-slot"],
        work_intent_id: 38
      }
    }
    render(<>{card.renderExpanded(context({ structured_content: rejected }))}</>)

    expect(screen.getByText("Workflow #612 is running, not terminal")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "RUN-240098" })).toHaveAttribute("href", "/admin/runs/240098/transcript")
    expect(screen.getByText("repository:7:delivery-track:production:landing-slot").closest("[class*='break-words']")).not.toBeNull()
  })

  it("reuses the pending-action result card for a live request", () => {
    const pending = { pending_action_id: 504, state: "pending", message: "Retire WU-73 and release 2 stale locks?" }
    render(
      <>
        {card.renderExpanded(
          context({ structured_content: pending }, { input: { work_unit_id: 73, reason: "Because **ownership is stale**.", dry_run: false } })
        )}
      </>
    )

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Pending action #504")).toBeInTheDocument()
    expect(screen.getByText("ownership is stale")).toBeInTheDocument()
  })

  it("renders ineligible Error text with the requested reason", () => {
    const envelope = { content: [{ type: "text", text: "Error: Workflow #612 is running, not terminal" }], structured_content: null }
    render(
      <>{card.renderExpanded(context(envelope, { input: { work_unit_id: 73, reason: "Check **terminal state**.", dry_run: false }, resultError: true }))}</>
    )

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Error: Workflow #612 is running, not terminal")).toBeInTheDocument()
    expect(screen.getByText("terminal state")).toBeInTheDocument()
  })
})
