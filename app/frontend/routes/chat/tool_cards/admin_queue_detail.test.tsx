import { cleanup, fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatToolGroupItem } from "../../../api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { ToolGroup } from "../MessageCards"
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
      jobs: [
        {
          id: 1,
          class_name: "RunJob",
          queue_name: "runs",
          priority: 2,
          arguments: ["RUN-1"],
          created_at: "2026-09-01T00:00:00Z",
          scheduled_at: "2026-09-01T00:00:01Z",
          claimed_at: "2026-09-01T00:00:05Z"
        }
      ]
    }
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 active job")

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("RunJob")).toBeInTheDocument()
    expect(screen.getByText("runs")).toBeInTheDocument()
    expect(screen.getAllByTestId("text-preview-content").some((element) => element.textContent?.includes('"RUN-1"'))).toBe(true)
    expect(screen.getByText("2026-09-01T00:00:01Z")).toBeInTheDocument()
  })

  it("uses the total and identifies truncated active results", () => {
    const parsedResult = { tab: "active", total: 740, jobs: [{ id: 1, class_name: "RunJob" }] }
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("740 active jobs")

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Showing first 1 of 740; this tool returns the first 100 only.")).toBeInTheDocument()
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
      failures: [
        {
          id: 9,
          job_id: 4,
          created_at: "2026-09-06T01:00:00Z",
          class_name: "RunJob",
          priority: 3,
          scheduled_at: "2026-09-06T00:30:00Z",
          arguments: ["RUN-4"],
          exception_class: "RuntimeError",
          message: "boom"
        }
      ]
    }

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("RuntimeError")).toBeInTheDocument()
    expect(screen.getByText("boom")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T00:30:00Z")).toBeInTheDocument()
    expect(screen.getAllByTestId("text-preview-content").every((element) => element.classList.contains("font-mono"))).toBe(true)
  })

  it("uses the total and identifies truncated failed results", () => {
    const parsedResult = { tab: "failed", total: 740, failures: [{ id: 9, class_name: "RunJob" }] }
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("740 failures")

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Showing first 1 of 740; this tool returns the first 100 only.")).toBeInTheDocument()
  })

  it("identifies truncated pending results", () => {
    const parsedResult = { tab: "pending", total: 740, jobs: [{ id: 1, class_name: "RunJob", ready_at: "2026-09-01T00:00:05Z" }] }

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Showing first 1 of 740; this tool returns the first 100 only.")).toBeInTheDocument()
    expect(screen.getAllByText("Ready")).toHaveLength(2)
    expect(screen.getByText("2026-09-01T00:00:05Z")).toBeInTheDocument()
  })

  it("redacts secrets in arguments before display", () => {
    const parsedResult = { tab: "active", jobs: [{ id: 1, arguments: [{ api_key: "super-secret-value", name: "safe" }] }] }

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ input: { tab: "active" }, parsedResult }))}</>)
    expect(screen.getByText(/\[redacted\]/)).toBeInTheDocument()
    expect(screen.queryByText(/super-secret-value/)).not.toBeInTheDocument()
  })

  it("shows long failure messages in a monospace preview and modal", () => {
    const message = Array.from({ length: 8 }, (_, index) => `failure line ${index + 1}`).join("\n")
    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult: { tab: "failed", failures: [{ id: 9, message }] } }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(
      within(screen.getByRole("dialog", { name: "Full failure message" })).getByText(
        (_, element) => element?.tagName === "PRE" && element.textContent === message
      )
    ).toBeInTheDocument()
  })

  it("renders errors with the requested input tab", () => {
    const error = "SolidQueue tables unreachable from this connection"
    const errorContext = context({ input: { tab: "pending" }, resultError: true, resultBody: error })
    expect(adminQueueDetailToolCard.collapsedSummary?.(errorContext)).toBe("pending queue failed")

    render(<>{adminQueueDetailToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText(error)).toBeInTheDocument()
  })

  it("keeps pagination, sorting, filtering, controls, and smart folders available", () => {
    const parsedResult = {
      tab: "active",
      jobs: [],
      pagination: { page: 1, per_page: 100, total_pages: 3 },
      sort: { column: "claimed_at", direction: "desc" },
      filter: { and: [] },
      controls: { filter_schema: { fields: [] } },
      smart_folders: [{ id: 7, name: "Runs" }],
      active_smart_folder_id: 7
    }

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ input: { tab: "active" }, parsedResult }))}</>)
    fireEvent.click(screen.getByText("Result metadata"))
    expect(screen.getByText(/"per_page": 100/)).toBeInTheDocument()
    expect(screen.getByText("Active smart folder id")).toBeInTheDocument()
  })

  it("renders the same card for direct, structured, and text-envelope agent results", () => {
    const payload = { tab: "active", jobs: [{ id: 1, class_name: "RunJob" }] }
    const variants = [
      payload,
      { structured_content: payload, content: [] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    variants.forEach((resultJson, index) => {
      const item: ChatToolGroupItem = {
        type: "tool_group",
        tool: "Admin queue detail",
        calls: [
          {
            message_id: index + 1,
            tool_name: "admin_queue_detail",
            raw_name: "mcp__syrus-chat-sidecar__admin_queue_detail",
            detail: "tab=active",
            display_label: "Admin queue detail",
            progress_label: "Reading",
            raw_payload: { tab: "active" },
            result_body: JSON.stringify(resultJson),
            result_json: resultJson,
            result_error: false,
            result_kind: "record",
            result_summary: "1 active job"
          }
        ]
      }

      render(<ToolGroup item={item} />)
      fireEvent.click(screen.getByText("Admin queue detail"))
      expect(screen.getByText("RunJob")).toBeInTheDocument()
      cleanup()
    })
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
    const drain = { state: "updating", desired_git_sha: "newsha" }
    const parsedResult = {
      tab: "workers",
      workers: [
        {
          hostname: "worker-1",
          pid: 42,
          queues: ["runs"],
          threads: 3,
          last_heartbeat_at: "2026-09-06T00:00:00Z",
          stale: true,
          status: "stale",
          capabilities: { os: ["linux"], arch: ["x86_64"] },
          macos_worker_drain: drain
        }
      ],
      all_processes: [
        {
          kind: "Worker",
          hostname: "worker-1",
          pid: 42,
          last_heartbeat_at: "2026-09-06T00:00:00Z",
          stale: true,
          status: "stale",
          capabilities: { os: ["linux"], arch: ["x86_64"] },
          capability_diagnostics: { docker: true },
          macos_worker_drain: drain
        }
      ],
      worker_health: { current: [{ hostname: "worker-1", health: { level: "warning" } }] }
    }
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 worker, 1 process")

    render(<>{adminQueueDetailToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getAllByText("stale")).toHaveLength(2)
    expect(screen.getAllByText("os: linux")).toHaveLength(2)
    expect(screen.getAllByText("arch: x86_64")).toHaveLength(2)
    expect(screen.getAllByText("updating · newsha")).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "worker-1" })).toHaveLength(2)
    expect(screen.getByText(/"docker": true/)).toBeInTheDocument()
  })

  it("falls back to null for an unknown tab", () => {
    expect(adminQueueDetailToolCard.renderExpanded(context({ parsedResult: { tab: "unknown" } }))).toBeNull()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminQueueDetailToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminQueueDetailToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
