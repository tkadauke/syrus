import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import type { ChatToolGroupItem } from "../../../api/chats"
import { redactToolCardValue } from "../../../toolCardSecurity"
import { ToolGroup } from "../MessageCards"
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
    const parsedResult = {
      processes: [
        { id: 1, hostname: "worker-1" },
        { id: 2, hostname: "worker-1" }
      ]
    }
    expect(adminListProcessesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 processes")
  })

  it("renders every input and result field with copyable identifiers and separate links", () => {
    const parsedResult = {
      processes: [
        {
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
          workflow_id: 8001,
          outcome: "succeeded"
        }
      ]
    }

    render(<>{adminListProcessesToolCard.renderExpanded(context({ input: { state: "all", kind: "agent", limit: 5 }, parsedResult }))}</>)

    expect(screen.getAllByText("agent")).toHaveLength(2)
    expect(screen.getByText("all")).toBeInTheDocument()
    expect(screen.getByText("5")).toBeInTheDocument()
    expect(screen.getByText("worker-1")).toBeInTheDocument()
    expect(screen.getByText("4242")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("42.5%")).toBeInTheDocument()
    expect(screen.getByText("256.0 MB")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "RUN-9001" })).toHaveAttribute("href", "/admin/runs/9001/transcript")
    expect(screen.getByRole("link", { name: "WF-8001" })).toHaveAttribute("href", "/admin/workflows/8001")
    expect(screen.getByText("succeeded")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy 1 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy worker-1 to clipboard" })).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminListProcessesToolCard.renderExpanded(context({ parsedResult: { processes: [] } }))}</>)
    expect(screen.getByText("No processes found.")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("20")).toBeInTheDocument()
  })

  it("renders an explicit error state and safe error details", () => {
    render(<>{adminListProcessesToolCard.renderExpanded(context({ resultError: true, resultBody: "Unable to query processes" }))}</>)
    expect(screen.getByText("Processes could not be loaded.")).toBeInTheDocument()
    expect(screen.getByText("Unable to query processes")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminListProcessesToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminListProcessesToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it.each([
    ["mcp__syrus-chat-sidecar__admin_list_processes", (payload: unknown) => payload],
    ["syrus-chat-sidecar.admin_list_processes", (payload: unknown) => ({ structured_content: payload })],
    ["admin_list_processes", (payload: unknown) => ({ content: [{ type: "text", text: JSON.stringify(payload) }] })]
  ])("normalizes and redacts %s results through the shared tool-card path", (rawName, wrapResult) => {
    const payload = { processes: [{ id: 7, hostname: "worker-secret", kind: "agent", command: "do not render" }] }
    const result = wrapResult(payload)
    const toolGroup: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Admin list processes",
      calls: [
        {
          message_id: 1,
          tool_name: "admin_list_processes",
          raw_name: rawName,
          detail: "state=running",
          display_label: "Admin list processes",
          progress_label: "Reading",
          raw_payload: { state: "running", kind: "agent", limit: 5, token: "top-secret" },
          result_body: JSON.stringify(result),
          result_json: redactToolCardValue(result),
          result_error: false,
          result_kind: "record",
          result_summary: "1 process"
        }
      ]
    }

    const { container } = render(<ToolGroup item={toolGroup} />)
    fireEvent.click(container.querySelector("summary") as HTMLElement)
    expect(screen.getByText("worker-secret")).toBeInTheDocument()
    expect(screen.getAllByText("agent")).toHaveLength(2)
    expect(screen.getByText("5")).toBeInTheDocument()
    expect(screen.queryByText("top-secret")).not.toBeInTheDocument()
    expect(screen.queryByText("do not render")).not.toBeInTheDocument()
    expect(within(screen.getByRole("table")).getAllByText("ID")).not.toHaveLength(0)
  })
})
