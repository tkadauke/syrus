import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import adminListProcessesToolCard from "./admin_list_processes"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_list_processes",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("admin_list_processes tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminListProcessesToolCard.toolName).toBe("admin_list_processes")
  })

  it("summarizes the collapsed row with a count", () => {
    const parsedResult = { processes: [{ id: 1, hostname: "worker-1" }, { id: 2, hostname: "worker-1" }] }
    expect(adminListProcessesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 processes")
  })

  it("renders kind, host/pid, state, resource usage, timing, and attribution", () => {
    const parsedResult = {
      processes: [{
        id: 1,
        kind: "agent",
        hostname: "worker-1",
        pid: 4242,
        state: "running",
        started_at: "2026-09-06T00:00:00Z",
        last_heartbeat_at: "2026-09-06T00:05:00Z",
        cpu: 42.5,
        rss: 1024 * 1024 * 256,
        run_id: 9001,
        workflow_id: null,
        outcome: null
      }]
    }

    render(<>{adminListProcessesToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("agent")).toBeInTheDocument()
    expect(screen.getByText("worker-1")).toBeInTheDocument()
    expect(screen.getByText("4242")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("42.5%")).toBeInTheDocument()
    expect(screen.getByText("256.0 MB")).toBeInTheDocument()
    expect(screen.getByText("RUN-301")).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminListProcessesToolCard.renderExpanded(context({ parsedResult: { processes: [] } }))}</>)
    expect(screen.getByText("No processes found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminListProcessesToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminListProcessesToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
