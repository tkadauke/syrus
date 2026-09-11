import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import adminQueueDetailToolCard from "./admin_queue_detail"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_queue_detail",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("admin_queue_detail tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminQueueDetailToolCard.toolName).toBe("admin_queue_detail")
  })

  it("summarizes and renders the active tab", () => {
    const parsedResult = {
      tab: "active",
      jobs: [{ id: 1, class_name: "RunJob", queue_name: "runs", created_at: "2026-09-01T00:00:00Z", claimed_at: "2026-09-01T00:00:05Z" }]
    }
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 active job")

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("RunJob")).toBeInTheDocument()
    expect(screen.getByText("runs")).toBeInTheDocument()
  })

  it("renders the failed tab with since and an empty state when there are no failures", () => {
    const parsedResult = { tab: "failed", since: "2026-09-06T00:00:00Z", failures: [] }
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("0 failures")

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("2026-09-06T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("No failures found.")).toBeInTheDocument()
  })

  it("renders failed rows with exception class and message", () => {
    const parsedResult = {
      tab: "failed",
      since: "2026-09-06T00:00:00Z",
      failures: [{ id: 9, created_at: "2026-09-06T01:00:00Z", class_name: "RunJob", exception_class: "RuntimeError", message: "boom" }]
    }

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("RuntimeError")).toBeInTheDocument()
    expect(screen.getByText("boom")).toBeInTheDocument()
  })

  it("renders the recurring tab", () => {
    const parsedResult = {
      tab: "recurring",
      tasks: [
        {
          key: "poll_repos",
          class_name: "PollAllRepositoriesJob",
          schedule: "*/5 * * * *",
          last_run_at: "2026-09-06T00:00:00Z",
          last_finished_at: "2026-09-06T00:00:02Z"
        }
      ]
    }
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 recurring task")

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("poll_repos")).toBeInTheDocument()
    expect(screen.getByText("PollAllRepositoriesJob")).toBeInTheDocument()
  })

  it("renders the workers tab, flagging a stale worker", () => {
    const parsedResult = {
      tab: "workers",
      workers: [{ hostname: "worker-1", pid: 42, queues: ["runs"], threads: 3, last_heartbeat_at: "2026-09-06T00:00:00Z", stale: true, status: "stale" }],
      all_processes: [{ kind: "Worker", hostname: "worker-1", pid: 42, last_heartbeat_at: "2026-09-06T00:00:00Z", stale: true, status: "stale" }]
    }
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 worker, 1 process")

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getAllByText("stale")).toHaveLength(2)
  })

  it("falls back to null for an unknown tab", () => {
    expect(adminQueueDetailToolCard.renderExpanded(context({ parsedResult: { tab: "unknown" } }))).toBeNull()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminQueueDetailToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
