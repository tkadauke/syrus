import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readQueueToolCard from "./read_queue"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_queue",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const HEALTHY_SNAPSHOT = {
  active_workers: {
    count: 1,
    queues: ["runs"],
    workers: [{ hostname: "worker-1", pid: 42, queues: ["runs", "chat"], threads: 3, last_heartbeat_at: "2026-01-01T00:00:00Z", stale: false, status: "current" }]
  },
  pending_jobs: { runs: 2, merges: 0, chat: 1, videos: 0, control_plane: 0, polling: 0, indexing: 0, cleanup: 0, low_priority_maintenance: 0 },
  failed_jobs: { count: 1 },
  recurring_tasks: { count: 4 },
  blocked_queues: ["merges"],
  paused_queues: ["videos"]
}

describe("read_queue tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readQueueToolCard.toolName).toBe("read_queue")
  })

  it("summarizes the collapsed row with worker and failure counts", () => {
    expect(readQueueToolCard.collapsedSummary?.(context({ parsedResult: HEALTHY_SNAPSHOT }))).toBe("1 worker, 1 failed job")
  })

  it("renders worker/failed/recurring counts, pending jobs, blocked/paused queues, and workers", () => {
    render(<>{readQueueToolCard.renderExpanded(context({ parsedResult: HEALTHY_SNAPSHOT }))}</>)

    expect(screen.getAllByText("1")).toHaveLength(2)
    expect(screen.getByText("4")).toBeInTheDocument()
    expect(screen.getByText("runs: 2")).toBeInTheDocument()
    expect(screen.getByText("chat: 1")).toBeInTheDocument()
    expect(screen.getByText("merges")).toBeInTheDocument()
    expect(screen.getByText("videos")).toBeInTheDocument()
    expect(screen.getByText("worker-1:42")).toBeInTheDocument()
  })

  it("renders an unavailable banner and error text when the queue snapshot is unavailable", () => {
    const parsedResult = {
      active_workers: { count: 0, queues: [], workers: [] },
      pending_jobs: { runs: 0, merges: 0, chat: 0, videos: 0, control_plane: 0, polling: 0, indexing: 0, cleanup: 0, low_priority_maintenance: 0 },
      failed_jobs: { count: 0 },
      recurring_tasks: { count: 0 },
      blocked_queues: [],
      paused_queues: [],
      unavailable: true,
      error: "SolidQueue tables unreachable from this connection: boom"
    }

    render(<>{readQueueToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Queue snapshot unavailable")).toBeInTheDocument()
    expect(screen.getByText("SolidQueue tables unreachable from this connection: boom")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(readQueueToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readQueueToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readQueueToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
