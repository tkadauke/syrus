import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import adminReadMemoryAuditHistoryToolCard from "./admin_read_memory_audit_history"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_read_memory_audit_history",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const createdEvent = {
  id: 1,
  event_type: "created",
  actor_kind: "user",
  actor_user_id: 4,
  actor_run_id: null,
  previous_content: null,
  new_content: "Original.",
  previous_kind: null,
  new_kind: "feedback",
  previous_confidence: null,
  new_confidence: null,
  created_at: "2026-09-01T00:00:00Z"
}

const updatedEvent = {
  id: 2,
  event_type: "updated",
  actor_kind: "agent",
  actor_user_id: null,
  actor_run_id: 500,
  previous_content: "Original.",
  new_content: "Revised.",
  previous_kind: "feedback",
  new_kind: "project_fact",
  previous_confidence: null,
  new_confidence: null,
  created_at: "2026-09-02T00:00:00Z"
}

describe("admin_read_memory_audit_history tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminReadMemoryAuditHistoryToolCard.toolName).toBe("admin_read_memory_audit_history")
  })

  it("summarizes the collapsed row with an event count and memory id", () => {
    expect(adminReadMemoryAuditHistoryToolCard.collapsedSummary?.(context({ parsedResult: { memory_id: 12, deleted: false, audit_events: [createdEvent, updatedEvent] } }))).toBe("2 audit events for memory #12")
  })

  it("renders actor, event type, and kind/content changes", () => {
    render(<>{adminReadMemoryAuditHistoryToolCard.renderExpanded(context({ parsedResult: { memory_id: 12, deleted: false, audit_events: [createdEvent, updatedEvent] } }))}</>)

    expect(screen.getByText("created")).toBeInTheDocument()
    expect(screen.getByText("updated")).toBeInTheDocument()
    expect(screen.getByText("user (user #4)")).toBeInTheDocument()
    expect(screen.getByText("agent (run #500)")).toBeInTheDocument()
    expect(screen.getByText("kind: feedback -> project_fact")).toBeInTheDocument()
    expect(screen.getAllByText("Content change").length).toBeGreaterThan(0)
  })

  it("shows a deleted pill when the memory was soft-deleted", () => {
    render(<>{adminReadMemoryAuditHistoryToolCard.renderExpanded(context({ parsedResult: { memory_id: 12, deleted: true, audit_events: [] } }))}</>)

    expect(screen.getByText("deleted")).toBeInTheDocument()
    expect(screen.getByText("No audit events recorded.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(adminReadMemoryAuditHistoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(adminReadMemoryAuditHistoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(adminReadMemoryAuditHistoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(adminReadMemoryAuditHistoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
