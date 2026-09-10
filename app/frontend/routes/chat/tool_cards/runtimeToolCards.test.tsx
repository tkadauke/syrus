import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatToolGroupItem } from "../../../api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { ToolGroup } from "../MessageCards"
import runtimeAcquireControlToolCard from "./runtime_acquire_control"
import runtimeListSessionsToolCard from "./runtime_list_sessions"
import runtimeReleaseControlToolCard from "./runtime_release_control"
import runtimeStatusToolCard from "./runtime_status"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

function expandToolGroup(label: string) {
  const summary = screen.getByText(label).closest("summary")
  expect(summary).not.toBeNull()
  if (!summary) throw new Error(`missing summary for ${label}`)
  fireEvent.click(summary)
}

function lease(overrides: Record<string, unknown> = {}) {
  return {
    id: 42,
    owner: "agent",
    owner_ref: "coding_mode_chat:8",
    mode: "input",
    reason: "click the preview",
    state: "active",
    acquired_at: "2026-09-10T12:00:00Z",
    expires_at: "2026-09-10T12:00:30Z",
    cancellable: true,
    ...overrides
  }
}

function session(overrides: Record<string, unknown> = {}) {
  return {
    id: 7,
    provider_key: "browser",
    display_name: "Browser",
    state: "running",
    primary: true,
    workspace_ref: "workspace-a",
    capabilities: { input: true, snapshot: true },
    metadata: { port: 4173, url: "http://127.0.0.1:4173", chat_id: 8, user_id: 3 },
    stream_url: "/runtime/7/stream",
    latest_frame_url: "/runtime/7/frame",
    latest_frame_at: "2026-09-10T12:00:05Z",
    last_error: null,
    active_agent_input_lease: lease(),
    ...overrides
  }
}

describe("Runtime tool cards", () => {
  it("registers the Runtime MCP tools by exact name", () => {
    expect(runtimeListSessionsToolCard.toolName).toBe("runtime_list_sessions")
    expect(runtimeStatusToolCard.toolName).toBe("runtime_status")
    expect(runtimeAcquireControlToolCard.toolName).toBe("runtime_acquire_control")
    expect(runtimeReleaseControlToolCard.toolName).toBe("runtime_release_control")
  })

  it("covers no sessions with a collapsed summary and empty expanded state", () => {
    const parsedResult = { sessions: [] }

    expect(runtimeListSessionsToolCard.collapsedSummary?.(context("runtime_list_sessions", { parsedResult }))).toBe("No Runtime sessions")

    render(<>{runtimeListSessionsToolCard.renderExpanded(context("runtime_list_sessions", { parsedResult }))}</>)
    expect(screen.getByText("No Runtime sessions found.")).toBeInTheDocument()
    expect(screen.getByText("Runtime JSON")).toBeInTheDocument()
  })

  it("summarizes and renders multiple sessions with metadata, URLs, ownership, and errors", () => {
    const parsedResult = {
      sessions: [
        session({ id: 1, state: "stopped", primary: false, active_agent_input_lease: null }),
        session({ id: 2, state: "failed", last_error: "preview crashed" })
      ]
    }

    expect(runtimeListSessionsToolCard.collapsedSummary?.(context("runtime_list_sessions", { parsedResult }))).toBe("2 Runtime sessions: #2 failed, agent input lease active, 1 error state")

    render(<>{runtimeListSessionsToolCard.renderExpanded(context("runtime_list_sessions", { parsedResult }))}</>)
    expect(screen.getByText("Runtime #1")).toBeInTheDocument()
    expect(screen.getByText("Runtime #2")).toBeInTheDocument()
    expect(screen.getAllByText("browser").length).toBeGreaterThan(0)
    expect(screen.getAllByText("workspace-a").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Stream").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Latest frame").length).toBeGreaterThan(0)
    expect(screen.getAllByText("url").length).toBeGreaterThan(0)
    expect(screen.getAllByText("http://127.0.0.1:4173").length).toBeGreaterThan(0)
    expect(screen.getByText("preview crashed")).toBeInTheDocument()
    expect(screen.getAllByText("Runtime JSON").length).toBeGreaterThan(0)
  })

  it("shows status for a stale session and active control owner", () => {
    const parsedResult = session({ state: "idle", active_agent_input_lease: lease({ state: "expired", expires_at: "2026-09-10T11:59:00Z" }) })

    expect(runtimeStatusToolCard.collapsedSummary?.(context("runtime_status", { parsedResult }))).toBe("Runtime #7: idle, agent input lease expired")

    render(<>{runtimeStatusToolCard.renderExpanded(context("runtime_status", { parsedResult }))}</>)
    expect(screen.getByText("expired")).toBeInTheDocument()
    expect(screen.getByText("coding_mode_chat:8")).toBeInTheDocument()
    expect(screen.getByText("2026-09-10T11:59:00Z")).toBeInTheDocument()
  })

  it("clearly confirms acquired Runtime control", () => {
    const parsedResult = lease()

    expect(runtimeAcquireControlToolCard.collapsedSummary?.(context("runtime_acquire_control", { parsedResult }))).toBe("Runtime control acquired: input #42")

    render(<>{runtimeAcquireControlToolCard.renderExpanded(context("runtime_acquire_control", { parsedResult }))}</>)
    expect(screen.getByText("Agent owns Runtime control.")).toBeInTheDocument()
    expect(screen.getByText("Control #42")).toBeInTheDocument()
  })

  it("distinguishes denied Runtime control from confirmed ownership", () => {
    const toolContext = context("runtime_acquire_control", {
      resultBody: "runtime session 7 already has an active input lease",
      resultError: true,
      parsedResult: null
    })

    expect(runtimeAcquireControlToolCard.collapsedSummary?.(toolContext)).toBe("Runtime acquire control failed")

    render(<>{runtimeAcquireControlToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("runtime session 7 already has an active input lease")).toBeInTheDocument()
    expect(screen.queryByText("Agent owns Runtime control.")).not.toBeInTheDocument()
  })

  it("uses the Runtime error card for failed acquire results in the real ToolGroup path", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime acquire control",
      calls: [
        {
          message_id: 1,
          tool_name: "runtime_acquire_control",
          raw_name: "runtime_acquire_control",
          detail: "No arguments",
          display_label: "Runtime acquire control",
          progress_label: "Thinking",
          raw_payload: {},
          result_body: "runtime session 7 already has an active input lease",
          result_error: true,
          result_kind: "error",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Failed"
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText("Runtime acquire control failed")).toBeInTheDocument()

    expandToolGroup("Runtime acquire control")

    expect(screen.getByText("runtime session 7 already has an active input lease")).toBeInTheDocument()
    expect(screen.queryByText("Agent owns Runtime control.")).not.toBeInTheDocument()
  })

  it("distinguishes stale acquired leases from confirmed ownership", () => {
    const parsedResult = lease({ state: "expired" })

    expect(runtimeAcquireControlToolCard.collapsedSummary?.(context("runtime_acquire_control", { parsedResult }))).toBe("Runtime control stale: agent input lease expired")

    render(<>{runtimeAcquireControlToolCard.renderExpanded(context("runtime_acquire_control", { parsedResult }))}</>)
    expect(screen.getByText("Runtime control ownership was not confirmed.")).toBeInTheDocument()
    expect(screen.getByText("expired")).toBeInTheDocument()
  })

  it("renders released control leases", () => {
    const parsedResult = { released: [lease({ id: 44, state: "released" })] }

    expect(runtimeReleaseControlToolCard.collapsedSummary?.(context("runtime_release_control", { parsedResult }))).toBe("Released 1 Runtime control lease")

    render(<>{runtimeReleaseControlToolCard.renderExpanded(context("runtime_release_control", { parsedResult }))}</>)
    expect(screen.getByText("Released lease #44")).toBeInTheDocument()
    expect(screen.getByText("released")).toBeInTheDocument()
  })

  it("renders no-op release distinctly", () => {
    const parsedResult = { released: [] }

    expect(runtimeReleaseControlToolCard.collapsedSummary?.(context("runtime_release_control", { parsedResult }))).toBe("No Runtime control leases released")

    render(<>{runtimeReleaseControlToolCard.renderExpanded(context("runtime_release_control", { parsedResult }))}</>)
    expect(screen.getByText("No active agent Runtime control leases were held.")).toBeInTheDocument()
  })

  it("falls back to raw rendering for malformed Runtime payloads", () => {
    expect(runtimeListSessionsToolCard.collapsedSummary?.(context("runtime_list_sessions", { parsedResult: { oops: true } }))).toBeNull()
    expect(runtimeStatusToolCard.renderExpanded(context("runtime_status", { parsedResult: { id: null } }))).toBeNull()
    expect(runtimeAcquireControlToolCard.renderExpanded(context("runtime_acquire_control", { parsedResult: "not json" }))).toBeNull()
    expect(runtimeReleaseControlToolCard.collapsedSummary?.(context("runtime_release_control", { parsedResult: { released: "nope" } }))).toBeNull()
  })
})
