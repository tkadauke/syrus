import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ChatToolGroupItem } from "../../../api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { ToolGroup } from "../MessageCards"
import { redactToolCardValue } from "../../../toolCardSecurity"
import runtimeAcquireControlToolCard from "./runtime_acquire_control"
import runtimeBuildOrReloadToolCard from "./runtime_build_or_reload"
import runtimeCaptureArtifactToolCard from "./runtime_capture_artifact"
import runtimeInspectToolCard from "./runtime_inspect"
import runtimeInputToolCard from "./runtime_input"
import runtimeLaunchToolCard from "./runtime_launch"
import runtimeListSessionsToolCard from "./runtime_list_sessions"
import runtimeLogsToolCard from "./runtime_logs"
import runtimeReleaseControlToolCard from "./runtime_release_control"
import runtimeSnapshotToolCard from "./runtime_snapshot"
import runtimeStartToolCard from "./runtime_start"
import runtimeStatusToolCard from "./runtime_status"
import runtimeStopToolCard from "./runtime_stop"

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
  // The header summary and the per-call label can render identical text
  // (zero-arg calls omit the parenthesized detail), so resolve the click
  // through the enclosing <summary> instead of assuming uniqueness.
  const summary = screen
    .getAllByText(label)
    .map((element) => element.closest("summary"))
    .find((element): element is HTMLElement => element !== null)
  expect(summary).not.toBeUndefined()
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
    expect(runtimeStartToolCard.toolName).toBe("runtime_start")
    expect(runtimeBuildOrReloadToolCard.toolName).toBe("runtime_build_or_reload")
    expect(runtimeLaunchToolCard.toolName).toBe("runtime_launch")
    expect(runtimeInspectToolCard.toolName).toBe("runtime_inspect")
    expect(runtimeLogsToolCard.toolName).toBe("runtime_logs")
    expect(runtimeStopToolCard.toolName).toBe("runtime_stop")
    expect(runtimeAcquireControlToolCard.toolName).toBe("runtime_acquire_control")
    expect(runtimeReleaseControlToolCard.toolName).toBe("runtime_release_control")
    expect(runtimeInputToolCard.toolName).toBe("runtime_input")
    expect(runtimeSnapshotToolCard.toolName).toBe("runtime_snapshot")
    expect(runtimeCaptureArtifactToolCard.toolName).toBe("runtime_capture_artifact")
  })

  it("covers no sessions with a collapsed summary and empty expanded state", () => {
    const parsedResult = { sessions: [] }

    expect(runtimeListSessionsToolCard.collapsedSummary?.(context("runtime_list_sessions", { parsedResult }))).toBe("No Runtime sessions")

    render(<>{runtimeListSessionsToolCard.renderExpanded(context("runtime_list_sessions", { parsedResult }))}</>)
    expect(screen.getByText("No Runtime sessions found.")).toBeInTheDocument()
    expect(screen.getByText("Runtime JSON")).toBeInTheDocument()
  })

  it("summarizes and renders every historical session in API order with complete session details", () => {
    const workspaceRef = "workspace/with/a/very/long/path/that/must/wrap/instead/of/overflowing/on/mobile"
    const lastError = "The preview process exited unexpectedly.\nRestart it after checking the provider logs."
    const parsedResult = {
      sessions: [
        session({
          id: 1,
          state: "stopped",
          primary: false,
          workspace_ref: workspaceRef,
          metadata: { deployment_url: "https://runtime.example.test/a/very/long/path", enabled: false },
          active_agent_input_lease: null
        }),
        session({ id: 2, state: "failed", last_error: lastError })
      ]
    }

    expect(runtimeListSessionsToolCard.collapsedSummary?.(context("runtime_list_sessions", { parsedResult }))).toBe(
      "2 Runtime sessions: #2 failed, agent input lease active, 1 error state"
    )

    render(<>{runtimeListSessionsToolCard.renderExpanded(context("runtime_list_sessions", { parsedResult }))}</>)
    expect(screen.getAllByText(/Runtime #[12]/, { selector: "a" }).map((element) => element.textContent)).toEqual(["Runtime #1", "Runtime #2"])
    expect(screen.getByText("stopped")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getAllByText("browser").length).toBeGreaterThan(0)
    expect(screen.getByText(workspaceRef)).toHaveClass("break-all", "sm:truncate")
    expect(screen.getByText("https://runtime.example.test/a/very/long/path")).toHaveClass("break-all", "sm:truncate")
    expect(screen.getAllByRole("link", { name: "Stream" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "Stream" })[0]).toHaveAttribute("target", "_blank")
    expect(screen.queryByRole("link", { name: "Latest frame" })).not.toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Open Latest frame" })).toHaveLength(2)
    expect(screen.getByAltText("Latest frame for Runtime #1")).toHaveAttribute("src", "/runtime/7/frame?latest_frame_at=2026-09-10T12%3A00%3A05Z")
    expect(screen.getAllByText("url").length).toBeGreaterThan(0)
    expect(screen.getByText("no lease")).toBeInTheDocument()
    expect(screen.getByText("coding_mode_chat:8")).toHaveClass("break-all", "sm:truncate")
    expect(screen.getAllByText("Capabilities")).toHaveLength(2)
    fireEvent.click(screen.getByText("Last error"))
    expect(screen.getByText(/The preview process exited unexpectedly/, { selector: "code" })).toHaveTextContent(
      /The preview process exited unexpectedly\.\s+Restart it after checking the provider logs\./
    )
    expect(screen.getAllByText("Runtime JSON").length).toBeGreaterThan(0)
  })

  it.each([
    ["runtime_list_sessions", (payload: unknown) => payload],
    ["mcp__syrus-chat-sidecar__runtime_list_sessions", (payload: unknown) => ({ structured_content: payload, content: [] })],
    [
      "syrus-chat-sidecar.runtime_list_sessions",
      (payload: unknown) => ({ content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null })
    ]
  ])("normalizes %s session-list envelopes through the real redacted ToolGroup path", (rawName, envelope) => {
    const payload = { sessions: [session({ id: 31, metadata: { api_token: "secret-value-that-must-not-render" } })] }
    const wrapped = envelope(payload)
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime list sessions",
      calls: [
        {
          message_id: 31,
          tool_name: "Runtime list sessions",
          raw_name: rawName,
          detail: "",
          display_label: "Runtime list sessions",
          progress_label: "Thinking",
          raw_payload: {},
          result_body: JSON.stringify(wrapped),
          result_json: wrapped,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Done"
    }

    render(<ToolGroup item={item} />)
    expect(screen.getByText(/1 Runtime session: #31 running/)).toBeInTheDocument()
    expandToolGroup("Runtime list sessions")
    expect(screen.getByText("Runtime #31", { selector: "a" })).toBeInTheDocument()
    expect(screen.queryByText("secret-value-that-must-not-render")).not.toBeInTheDocument()
    expect(screen.getByText("[redacted]")).toBeInTheDocument()
  })

  it("shows status for a stale session and active control owner", () => {
    const parsedResult = session({ state: "idle", active_agent_input_lease: lease({ state: "expired", expires_at: "2026-09-10T11:59:00Z" }) })

    expect(runtimeStatusToolCard.collapsedSummary?.(context("runtime_status", { parsedResult }))).toBe("Runtime #7: idle, agent input lease expired")

    render(<>{runtimeStatusToolCard.renderExpanded(context("runtime_status", { parsedResult }))}</>)
    expect(screen.getByText("expired")).toBeInTheDocument()
    expect(screen.getByText("coding_mode_chat:8")).toBeInTheDocument()
    expect(screen.getByText("2026-09-10T11:59:00Z")).toBeInTheDocument()
  })

  it("renders the complete status payload with wrapping, safe links, a frame preview, and long errors", () => {
    const workspaceRef = "workspace/with/a/very/long/path/that/must/wrap/instead/of/overflowing/on/mobile"
    const lastError = "The browser process exited unexpectedly.\nRestart the preview after checking its logs."
    const parsedResult = {
      session_payload: session({
        workspace_ref: workspaceRef,
        metadata: { deployment_url: "https://runtime.example.test/a/very/long/path", enabled: false },
        latest_frame_url: "/runtime/7/frame?size=large",
        last_error: lastError,
        active_agent_input_lease: null
      })
    }

    render(<>{runtimeStatusToolCard.renderExpanded(context("runtime_status", { parsedResult: redactToolCardValue(parsedResult) }))}</>)

    expect(screen.getByRole("link", { name: "Runtime #7" })).toHaveAttribute("href", "/runtime/7/stream")
    expect(screen.getByRole("link", { name: "Stream" })).toHaveAttribute("target", "_blank")
    expect(screen.getByRole("link", { name: "Latest frame" })).toHaveAttribute("href", "/runtime/7/frame?size=large")
    expect(screen.getByRole("link", { name: "Latest frame" })).toHaveClass("min-h-11", "break-all")
    expect(screen.getByText(workspaceRef)).toHaveClass("break-all", "sm:truncate")
    expect(screen.getByText("https://runtime.example.test/a/very/long/path")).toHaveClass("break-all", "sm:truncate")
    expect(screen.getByText("no lease")).toBeInTheDocument()
    expect(screen.getByText("Last error")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Open Latest frame" }))
    const dialog = screen.getByRole("dialog", { name: "Runtime latest frame preview" })
    expect(dialog).toBeInTheDocument()
    expect(within(dialog).getByAltText("Latest frame for Runtime #7")).toHaveAttribute(
      "src",
      "/runtime/7/frame?size=large&latest_frame_at=2026-09-10T12%3A00%3A05Z"
    )
  })

  it("shows boolean status failures and falls back to the input session id", () => {
    const toolContext = context("runtime_status", {
      input: { session_id: 91 },
      parsedResult: { error: true, content: [{ type: "text", text: "runtime provider unavailable" }] }
    })

    expect(runtimeStatusToolCard.collapsedSummary?.(toolContext)).toBe("Runtime status failed")
    render(<>{runtimeStatusToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Runtime #91")).toBeInTheDocument()
    expect(screen.getByText("runtime provider unavailable")).toBeInTheDocument()
  })

  it.each([
    ["runtime_status", (payload: unknown) => payload],
    ["mcp__syrus-chat-sidecar__runtime_status", (payload: unknown) => ({ structured_content: payload, content: [] })],
    ["syrus-chat-sidecar.runtime_status", (payload: unknown) => ({ content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null })]
  ])("normalizes %s status envelopes through the real redacted ToolGroup path", (rawName, envelope) => {
    const payload = { session_payload: session({ id: 23, metadata: { api_token: "secret-value-that-must-not-render" } }) }
    const wrapped = envelope(payload)
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime status",
      calls: [
        {
          message_id: 23,
          tool_name: "Runtime status",
          raw_name: rawName,
          detail: "session_id: 23",
          display_label: "Runtime status",
          progress_label: "Thinking",
          raw_payload: { session_id: 23 },
          result_body: JSON.stringify(wrapped),
          result_json: wrapped,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Done"
    }

    render(<ToolGroup item={item} />)
    expect(screen.getByText(/Runtime #23: running/)).toBeInTheDocument()
    expandToolGroup("Runtime status")
    expect(screen.getByText("Runtime #23", { selector: "a" })).toBeInTheDocument()
    expect(screen.queryByText("secret-value-that-must-not-render")).not.toBeInTheDocument()
    expect(screen.getByText("[redacted]")).toBeInTheDocument()
  })

  it("renders an otherwise empty status result from its input session id", () => {
    const toolContext = context("runtime_status", { input: { session_id: 92 }, parsedResult: {} })

    expect(runtimeStatusToolCard.collapsedSummary?.(toolContext)).toBe("Runtime #92: unknown, no active agent lease")
    render(<>{runtimeStatusToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Runtime #92")).toBeInTheDocument()
    expect(screen.getByText("no lease")).toBeInTheDocument()
  })

  it("renders start input, distinct state, linked URL, and de-duplicated provider metadata", () => {
    const parsedResult = session({
      state: "starting",
      workspace_ref: null,
      metadata: { workspace_ref: "workspace-from-provider", port: 3001, url: "http://127.0.0.1:3001", pid: 1234 }
    })
    const toolContext = context("runtime_start", {
      parsedResult,
      input: {
        provider: "browser",
        name: "docs preview",
        options: { command: "npm run dev", api_token: "[redacted]", viewport: { width: 390, height: 844 }, features: ["touch", "camera"], nullable: null }
      }
    })

    expect(runtimeStartToolCard.collapsedSummary?.(toolContext)).toBe("Runtime start #7: starting at http://127.0.0.1:3001")

    render(<>{runtimeStartToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Runtime start")).toBeInTheDocument()
    expect(screen.getByText("#7")).toBeInTheDocument()
    expect(screen.getAllByText("starting").length).toBeGreaterThan(0)
    expect(screen.getByText("pid 1234")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "http://127.0.0.1:3001" })).toHaveAttribute("target", "_blank")
    expect(screen.getAllByText("http://127.0.0.1:3001")).toHaveLength(1)
    expect(screen.getByText("docs preview")).toBeInTheDocument()
    expect(screen.getByText("npm run dev")).toBeInTheDocument()
    expect(screen.getByText("workspace-from-provider")).toBeInTheDocument()
    expect(screen.getAllByText("workspace-from-provider")).toHaveLength(1)
    expect(screen.getByText("3001")).toBeInTheDocument()
    expect(screen.getByText("[redacted]")).toBeInTheDocument()
    expect(screen.getByText('{"width":390,"height":844}')).toBeInTheDocument()
    expect(screen.getByText('["touch","camera"]')).toBeInTheDocument()
    expect(screen.getByText("null")).toBeInTheDocument()
  })

  it("renders failed starts and never links unsafe provider URLs", () => {
    const parsedResult = { ...session({ state: "failed", metadata: { url: "javascript:alert(1)" } }), error: true, message: "browser failed to start" }

    expect(runtimeStartToolCard.collapsedSummary?.(context("runtime_start", { parsedResult }))).toBe("Runtime start failed")
    render(<>{runtimeStartToolCard.renderExpanded(context("runtime_start", { parsedResult }))}</>)
    expect(screen.getByText("browser failed to start")).toBeInTheDocument()
    expect(screen.getByText("Error:")).toBeInTheDocument()
    expect(screen.getByText("javascript:alert(1)")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "javascript:alert(1)" })).not.toBeInTheDocument()
  })

  it("keeps start inputs visible for real error-result envelopes", () => {
    const result = { content: [{ type: "text", text: "Error: provider rejected the start request" }], isError: true }
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime start",
      calls: [
        {
          message_id: 42,
          tool_name: "Runtime start",
          raw_name: "mcp__syrus-chat-sidecar__runtime_start",
          detail: "provider: browser",
          display_label: "Runtime start",
          progress_label: "Thinking",
          raw_payload: { provider: "browser", name: "failed preview", options: { viewport: { width: 390, height: 844 } } },
          result_body: JSON.stringify(result),
          result_json: result,
          result_error: true,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Failed"
    }

    render(<ToolGroup item={item} />)
    expect(screen.getByText(/Runtime start failed/)).toBeInTheDocument()
    expandToolGroup("Runtime start")
    expect(screen.getByText("Error:")).toBeInTheDocument()
    expect(screen.getByText("provider rejected the start request")).toBeInTheDocument()
    expect(screen.getByText("browser")).toBeInTheDocument()
    expect(screen.getByText("failed preview")).toBeInTheDocument()
    expect(screen.getByText('{"width":390,"height":844}')).toBeInTheDocument()
  })

  it.each([
    ["runtime_start", (payload: unknown) => payload],
    ["mcp__syrus-chat-sidecar__runtime_start", (payload: unknown) => ({ structured_content: payload, content: [] })],
    ["syrus-chat-sidecar.runtime_start", (payload: unknown) => ({ content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null })]
  ])("normalizes %s start envelopes through the real redacted ToolGroup path", (rawName, envelope) => {
    const payload = session({ id: 41, metadata: { url: "https://runtime.example.test", api_token: "result-secret" } })
    const wrapped = envelope(payload)
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime start",
      calls: [
        {
          message_id: 41,
          tool_name: "Runtime start",
          raw_name: rawName,
          detail: "provider: browser",
          display_label: "Runtime start",
          progress_label: "Thinking",
          raw_payload: { provider: "browser", name: "preview", options: { auth_token: "input-secret", viewport: "mobile" } },
          result_body: JSON.stringify(wrapped),
          result_json: wrapped,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Done"
    }

    render(<ToolGroup item={item} />)
    expect(screen.getByText(/Runtime start #41: running/)).toBeInTheDocument()
    expandToolGroup("Runtime start")
    expect(screen.getByText("preview")).toBeInTheDocument()
    expect(screen.getByText("mobile")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "https://runtime.example.test" })).toBeInTheDocument()
    expect(screen.queryByText("input-secret")).not.toBeInTheDocument()
    expect(screen.queryByText("result-secret")).not.toBeInTheDocument()
    expect(screen.getAllByText("[redacted]")).toHaveLength(2)
  })

  it("renders build/reload success and failure distinctly", () => {
    const parsedResult = { status: "rebuilt", command: "npm run dev", url: "http://127.0.0.1:4173" }

    expect(runtimeBuildOrReloadToolCard.collapsedSummary?.(context("runtime_build_or_reload", { parsedResult }))).toBe(
      "Runtime build/reload: rebuilt at http://127.0.0.1:4173"
    )

    render(<>{runtimeBuildOrReloadToolCard.renderExpanded(context("runtime_build_or_reload", { parsedResult }))}</>)
    expect(screen.getByText("Runtime build/reload")).toBeInTheDocument()
    expect(screen.getByText("npm run dev")).toBeInTheDocument()
    expect(screen.getAllByText("http://127.0.0.1:4173").length).toBeGreaterThan(0)

    const failedContext = context("runtime_build_or_reload", {
      resultBody: "failed to build/reload runtime session: port is busy",
      resultError: true,
      parsedResult: null
    })

    expect(runtimeBuildOrReloadToolCard.collapsedSummary?.(failedContext)).toBe("Runtime build or reload failed")
    render(<>{runtimeBuildOrReloadToolCard.renderExpanded(failedContext)}</>)
    expect(screen.getByText("failed to build/reload runtime session: port is busy")).toBeInTheDocument()
  })

  it("shows launch targets and provider-reported launch errors", () => {
    const parsedResult = { error: false, content: [{ type: "text", text: "Navigated to http://127.0.0.1:3001/settings" }] }
    const toolContext = context("runtime_launch", { parsedResult, input: { options: { path: "/settings" } } })

    expect(runtimeLaunchToolCard.collapsedSummary?.(toolContext)).toBe("Runtime launch: succeeded at /settings")

    render(<>{runtimeLaunchToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Runtime launch")).toBeInTheDocument()
    expect(screen.getByText("/settings")).toBeInTheDocument()

    const failed = { error: true, content: [{ type: "text", text: "page crashed before navigation" }] }
    expect(runtimeLaunchToolCard.collapsedSummary?.(context("runtime_launch", { parsedResult: failed }))).toBe("Runtime launch failed")
    render(<>{runtimeLaunchToolCard.renderExpanded(context("runtime_launch", { parsedResult: failed }))}</>)
    expect(screen.getAllByText("page crashed before navigation").length).toBeGreaterThan(0)
  })

  it("keeps runtime_launch ToolGroup summaries compact when the path is nested input", () => {
    const result = { error: false, content: [{ type: "text", text: "Navigated to http://127.0.0.1:3001/settings" }] }
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime launch",
      calls: [
        {
          message_id: 2,
          tool_name: "Runtime launch",
          raw_name: "runtime_launch",
          detail: "options: path /settings",
          display_label: "Runtime launch",
          progress_label: "Thinking",
          raw_payload: { options: { path: "/settings" } },
          result_body: JSON.stringify(result),
          result_json: result,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: true,
      outcome_label: "Done"
    }

    render(<ToolGroup item={item} />)

    // Single ownership: the registered card owns the expanded view, so the
    // summary lives only in the header's result + detail subtitle.
    expect(screen.getByText("Runtime launch: succeeded at /settings · options: path /settings")).toBeInTheDocument()
    expect(screen.queryByText("Runtime launch: succeeded at Navigated to http://127.0.0.1:3001/settings")).not.toBeInTheDocument()
  })

  it("renders browser inspection input and snapshot output", () => {
    const parsedResult = {
      error: false,
      content: [{ type: "text", text: "Snapshot: button Open settings" }]
    }
    const input = { session_id: 27, options: { selector: "main", include_hidden: false } }

    expect(runtimeInspectToolCard.collapsedSummary?.(context("runtime_inspect", { input, parsedResult }))).toBe("Runtime inspect complete")

    render(<>{runtimeInspectToolCard.renderExpanded(context("runtime_inspect", { input, parsedResult }))}</>)
    expect(screen.getByText("27")).toBeInTheDocument()
    expect(screen.getByText("selector")).toBeInTheDocument()
    expect(screen.getByText("main")).toBeInTheDocument()
    expect(screen.getByText("include_hidden")).toBeInTheDocument()
    expect(screen.getByText("false")).toBeInTheDocument()
    expect(screen.getByText("Inspection details")).toBeInTheDocument()
    expect(screen.getByText("Snapshot: button Open settings")).toBeInTheDocument()
  })

  it("renders Android UIAutomator inspection output without browser-only fields", () => {
    const parsedResult = {
      kind: "android_uiautomator",
      xml: "<?xml version='1.0'?><hierarchy><node text='Sign in' /></hierarchy>",
      bytes: 67
    }

    expect(runtimeInspectToolCard.collapsedSummary?.(context("runtime_inspect", { parsedResult }))).toBe("Runtime inspect: android_uiautomator, 67 bytes")

    render(<>{runtimeInspectToolCard.renderExpanded(context("runtime_inspect", { parsedResult }))}</>)
    expect(screen.getByText("android_uiautomator")).toBeInTheDocument()
    expect(screen.getByText("67")).toBeInTheDocument()
    expect(screen.getByText("Inspection details")).toBeInTheDocument()
    expect(screen.getAllByText(/<hierarchy>/).length).toBeGreaterThan(0)
    expect(screen.getByText("Runtime JSON")).toBeInTheDocument()
  })

  it.each([
    ["structured_content", (payload: unknown) => ({ structured_content: payload, content: [] })],
    ["content text JSON", (payload: unknown) => ({ structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] })]
  ])("normalizes runtime_inspect %s envelopes and keeps terminal output tail-aware and redacted", (_format, envelope) => {
    const scrollback = Array.from({ length: 45 }, (_, index) =>
      index === 44 ? "line 45 API_TOKEN=secret-value-that-must-not-render" : `line ${index + 1}`
    ).join("\n")
    const payload = { kind: "terminal_scrollback", scrollback, bytes: 775 }
    const wrapped = envelope(payload)
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime inspect",
      calls: [
        {
          message_id: 62,
          tool_name: "Runtime inspect",
          raw_name: "mcp__syrus-chat-sidecar__runtime_inspect",
          detail: "",
          display_label: "Runtime inspect",
          progress_label: "Thinking",
          raw_payload: { session_id: 9, options: { source: "terminal" } },
          result_body: JSON.stringify(wrapped),
          result_json: wrapped,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Done"
    }

    render(<ToolGroup item={item} />)
    expect(screen.getByText("Runtime inspect: terminal_scrollback, 775 bytes")).toBeInTheDocument()
    expandToolGroup("Runtime inspect")
    expect(screen.getByText("9")).toBeInTheDocument()
    expect(screen.getByText("terminal")).toBeInTheDocument()
    const preview = screen.getByTestId("text-preview-content")
    expect(within(preview).getByText(/… 5 earlier lines/)).toBeInTheDocument()
    expect(preview.textContent).not.toContain("\nline 1\n")
    expect(within(preview).getByText(/line 45 API_TOKEN=\[redacted\]/)).toBeInTheDocument()
    expect(screen.queryByText("secret-value-that-must-not-render")).not.toBeInTheDocument()
  })

  it("renders boolean runtime inspection failures distinctly", () => {
    const parsedResult = { error: true, content: [{ type: "text", text: "browser inspection timed out" }] }

    expect(runtimeInspectToolCard.collapsedSummary?.(context("runtime_inspect", { parsedResult }))).toBe("Runtime inspect failed")
    render(<>{runtimeInspectToolCard.renderExpanded(context("runtime_inspect", { parsedResult }))}</>)
    expect(screen.getByText("browser inspection timed out", { selector: "div" })).toHaveClass("text-danger-text")
  })

  it("renders long Runtime logs as a tail preview with request details and full-log popup", () => {
    const entries = Array.from({ length: 45 }, (_, index) => `line ${index + 1}`)
    const parsedResult = { entries, cursor: 45 }

    expect(runtimeLogsToolCard.collapsedSummary?.(context("runtime_logs", { parsedResult }))).toBe("Runtime logs: 45 lines, cursor 45")

    render(<>{runtimeLogsToolCard.renderExpanded(context("runtime_logs", { parsedResult, input: { session_id: 7, cursor: 0, limit: 45 } }))}</>)
    expect(screen.getByText("Session ID")).toBeInTheDocument()
    expect(screen.getByText("Limit")).toBeInTheDocument()
    expect(screen.getByText("Requested cursor")).toBeInTheDocument()
    expect(screen.getByText("Next cursor")).toBeInTheDocument()
    expect(screen.getByText("7")).toBeInTheDocument()
    expect(screen.getAllByText("45")).toHaveLength(3)
    const preview = screen.getByText("Log preview").closest("details")
    expect(preview).not.toBeNull()
    if (!preview) throw new Error("missing log preview")
    expect(within(preview).getByText(/… 5 earlier lines/)).toBeInTheDocument()
    expect(preview.textContent).not.toContain("\nline 1\n")
    expect(within(preview).getByText(/line 45/)).toBeInTheDocument()
    fireEvent.click(within(preview).getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog", { name: "Full Runtime logs" })
    expect(within(dialog).getByText(/line 1/)).toBeInTheDocument()
    expect(within(dialog).getByText(/line 45/)).toBeInTheDocument()
    expect(screen.getByText("Runtime JSON")).toBeInTheDocument()
  })

  it.each([
    ["direct", "runtime_logs", (payload: unknown) => payload],
    ["structured content", "mcp__syrus-chat-sidecar__runtime_logs", (payload: unknown) => ({ structured_content: payload, content: [] })],
    [
      "content text JSON",
      "mcp__syrus-chat-sidecar__runtime_logs",
      (payload: unknown) => ({ structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] })
    ]
  ])("normalizes and redacts Runtime logs from %s results", (_format, rawName, envelope) => {
    const payload = {
      entries: ["starting", "API_TOKEN=secret-value-that-must-not-render", "ready"],
      cursor: 103
    }
    const wrapped = envelope(payload)
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime logs",
      calls: [
        {
          message_id: 63,
          tool_name: "Runtime logs",
          raw_name: rawName,
          detail: "",
          display_label: "Runtime logs",
          progress_label: "Thinking",
          raw_payload: { session_id: 12, cursor: 100, limit: 50 },
          result_body: JSON.stringify(wrapped),
          result_json: wrapped,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Done"
    }

    render(<ToolGroup item={item} />)
    expect(screen.getByText("Runtime logs: 3 lines, cursor 103")).toBeInTheDocument()
    expandToolGroup("Runtime logs")
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("100")).toBeInTheDocument()
    expect(screen.getByText("50")).toBeInTheDocument()
    expect(screen.getByText("103")).toBeInTheDocument()
    expect(screen.getAllByText(/API_TOKEN=\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/secret-value-that-must-not-render/)).not.toBeInTheDocument()
  })

  it("shows stopped runtimes with their final state", () => {
    const parsedResult = {
      session_payload: session({ state: "stopped", metadata: { port: 3001, url: "http://127.0.0.1:3001" }, active_agent_input_lease: null })
    }

    expect(runtimeStopToolCard.collapsedSummary?.(context("runtime_stop", { parsedResult }))).toBe("Runtime stop #7: stopped at http://127.0.0.1:3001")

    render(<>{runtimeStopToolCard.renderExpanded(context("runtime_stop", { parsedResult }))}</>)
    expect(screen.getByText("Runtime stop")).toBeInTheDocument()
    expect(screen.getAllByText("stopped").length).toBeGreaterThan(0)
    expect(screen.getByText("no lease")).toBeInTheDocument()
  })

  it("uses the input session id and preserves already-stopped state", () => {
    const toolContext = context("runtime_stop", {
      input: { session_id: 91 },
      parsedResult: { session_payload: { state: "already stopped", active_agent_input_lease: null } }
    })

    expect(runtimeStopToolCard.collapsedSummary?.(toolContext)).toBe("Runtime stop #91: already stopped")
    render(<>{runtimeStopToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("#91")).toBeInTheDocument()
    expect(screen.getAllByText("already stopped").length).toBeGreaterThan(0)
    expect(screen.getByText("no lease")).toBeInTheDocument()
  })

  it("shows the specific stop failure with its requested session", () => {
    const toolContext = context("runtime_stop", {
      input: { session_id: 92 },
      resultError: true,
      parsedResult: { error: true, content: [{ type: "text", text: "Error: runtime provider refused to stop" }] }
    })

    expect(runtimeStopToolCard.collapsedSummary?.(toolContext)).toBe("Runtime stop failed")
    render(<>{runtimeStopToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("#92")).toBeInTheDocument()
    expect(screen.getByText("runtime provider refused to stop")).toBeInTheDocument()
  })

  it.each([
    ["runtime_stop", (payload: unknown) => payload],
    ["mcp__syrus-chat-sidecar__runtime_stop", (payload: unknown) => ({ structured_content: payload, content: [] })],
    ["syrus-chat-sidecar.runtime_stop", (payload: unknown) => ({ content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null })]
  ])("normalizes %s stop envelopes through the real redacted ToolGroup path", (rawName, envelope) => {
    const payload = { session_payload: session({ id: 93, state: "stopped", metadata: { api_token: "secret-value-that-must-not-render" } }) }
    const wrapped = envelope(payload)
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime stop",
      calls: [
        {
          message_id: 93,
          tool_name: "Runtime stop",
          raw_name: rawName,
          detail: "session_id: 93",
          display_label: "Runtime stop",
          progress_label: "Thinking",
          raw_payload: { session_id: 93, api_token: "input-secret" },
          result_body: JSON.stringify(wrapped),
          result_json: wrapped,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Done"
    }

    render(<ToolGroup item={item} />)
    expect(screen.getByText(/Runtime stop #93: stopped/)).toBeInTheDocument()
    expandToolGroup("Runtime stop")
    expect(screen.getByText("#93")).toBeInTheDocument()
    expect(screen.queryByText("secret-value-that-must-not-render")).not.toBeInTheDocument()
    expect(screen.queryByText("input-secret")).not.toBeInTheDocument()
    expect(screen.getByText("[redacted]")).toBeInTheDocument()
  })

  it("keeps stop payload secrets redacted", () => {
    const parsedResult = redactToolCardValue({
      session_payload: session({ metadata: { api_token: "secret-value-that-must-not-render" } })
    })

    render(<>{runtimeStopToolCard.renderExpanded(context("runtime_stop", { parsedResult }))}</>)
    expect(screen.queryByText("secret-value-that-must-not-render")).not.toBeInTheDocument()
    expect(screen.getByText("[redacted]")).toBeInTheDocument()
  })

  it("renders acquired Runtime control with request, linked owner, relative times, and Markdown reason", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-09-10T12:00:10Z"))
    const parsedResult = lease()
    const toolContext = context("runtime_acquire_control", {
      input: { session_id: 7, mode: "input", duration_seconds: 30 },
      parsedResult
    })

    expect(runtimeAcquireControlToolCard.collapsedSummary?.(toolContext)).toBe("Runtime control acquired: input #42")

    try {
      render(<>{runtimeAcquireControlToolCard.renderExpanded(toolContext)}</>)
      expect(screen.getByText("Agent owns Runtime control.")).toBeInTheDocument()
      expect(screen.getByText("Control #42")).toBeInTheDocument()
      expect(screen.getByText("7")).toBeInTheDocument()
      expect(screen.getAllByText("input").length).toBeGreaterThan(0)
      expect(screen.getByText("30 seconds")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: /CHAT-8/ })).toHaveAttribute("href", "/chats/8")
      expect(screen.getByText("click the preview")).toBeInTheDocument()
      expect(screen.getByText("10 seconds ago")).toHaveAttribute("datetime", "2026-09-10T12:00:00Z")
      expect(screen.getByText("in 20 seconds")).toHaveAttribute("datetime", "2026-09-10T12:00:30Z")
      expect(screen.queryByText("2026-09-10T12:00:00Z")).not.toBeInTheDocument()
    } finally {
      vi.useRealTimers()
    }
  })

  it.each([
    ["structured content", { structured_content: lease(), content: [] }],
    ["text content", { structured_content: null, content: [{ type: "text", text: JSON.stringify(lease()) }] }]
  ])("renders acquire control through the real provider envelope with %s", (_label, wrapped) => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime acquire control",
      calls: [
        {
          message_id: 1,
          tool_name: "runtime_acquire_control",
          raw_name: "mcp__syrus-chat-sidecar__runtime_acquire_control",
          detail: "Runtime #7",
          display_label: "Runtime acquire control",
          progress_label: "Thinking",
          raw_payload: { session_id: 7, mode: "input", duration_seconds: 30 },
          result_body: JSON.stringify(wrapped),
          result_json: wrapped,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Done"
    }

    render(<ToolGroup item={item} />)
    expandToolGroup("Runtime acquire control")
    expect(screen.getByText("Agent owns Runtime control.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /CHAT-8/ })).toHaveAttribute("href", "/chats/8")
    expect(screen.getByText("30 seconds")).toBeInTheDocument()
  })

  it("keeps acquire control payload secrets redacted", () => {
    const parsedResult = redactToolCardValue(lease({ api_token: "result-secret" }))
    const input = redactToolCardValue({ session_id: 7, mode: "input", duration_seconds: 30, api_token: "input-secret" }) as Record<string, unknown>

    render(<>{runtimeAcquireControlToolCard.renderExpanded(context("runtime_acquire_control", { input, parsedResult }))}</>)
    expect(screen.queryByText("result-secret")).not.toBeInTheDocument()
    expect(screen.queryByText("input-secret")).not.toBeInTheDocument()
    expect(screen.getByText(/"api_token": "\[redacted\]"/)).toBeInTheDocument()
  })

  it("distinguishes denied Runtime control from confirmed ownership", () => {
    const toolContext = context("runtime_acquire_control", {
      input: { session_id: 7, mode: "input", duration_seconds: 30 },
      resultBody: "runtime session 7 already has an active input lease",
      resultError: true,
      parsedResult: null
    })

    expect(runtimeAcquireControlToolCard.collapsedSummary?.(toolContext)).toBe("Runtime acquire control failed")

    render(<>{runtimeAcquireControlToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("runtime session 7 already has an active input lease")).toBeInTheDocument()
    expect(screen.getByText("30 seconds")).toBeInTheDocument()
    expect(screen.queryByText("Agent owns Runtime control.")).not.toBeInTheDocument()
  })

  it("extracts failed acquire messages from a real MCP error envelope", () => {
    const envelope = {
      content: [{ type: "text", text: "Error: runtime session 7 already has an active input lease" }],
      isError: true
    }
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime acquire control",
      calls: [
        {
          message_id: 1,
          tool_name: "runtime_acquire_control",
          raw_name: "mcp__syrus-chat-sidecar__runtime_acquire_control",
          detail: "Runtime #7",
          display_label: "Runtime acquire control",
          progress_label: "Thinking",
          raw_payload: { session_id: 7, mode: "input", duration_seconds: 30 },
          result_body: JSON.stringify(envelope),
          result_json: envelope,
          result_error: true,
          result_kind: "error",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Failed"
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText(/Runtime acquire control failed/)).toBeInTheDocument()

    expandToolGroup("Runtime acquire control")

    expect(screen.getByText("Error: runtime session 7 already has an active input lease")).toBeInTheDocument()
    expect(screen.getByText("30 seconds")).toBeInTheDocument()
    expect(screen.queryByText(JSON.stringify(envelope))).not.toBeInTheDocument()
    expect(screen.queryByText("Agent owns Runtime control.")).not.toBeInTheDocument()
  })

  it("distinguishes stale acquired leases from confirmed ownership", () => {
    const parsedResult = lease({ state: "expired" })

    expect(runtimeAcquireControlToolCard.collapsedSummary?.(context("runtime_acquire_control", { parsedResult }))).toBe(
      "Runtime control stale: agent input lease expired"
    )

    render(<>{runtimeAcquireControlToolCard.renderExpanded(context("runtime_acquire_control", { parsedResult }))}</>)
    expect(screen.getByText("Runtime control ownership was not confirmed.")).toBeInTheDocument()
    expect(screen.getByText("expired")).toBeInTheDocument()
  })

  it("renders released control leases with their session, linked owner, relative times, mode, reason, and state", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-09-10T12:00:40Z"))
    const parsedResult = { released: [lease({ id: 44, state: "released" })] }
    const toolContext = context("runtime_release_control", { input: { session_id: 7 }, parsedResult })

    expect(runtimeReleaseControlToolCard.collapsedSummary?.(toolContext)).toBe("Released 1 Runtime control lease")

    try {
      render(<>{runtimeReleaseControlToolCard.renderExpanded(toolContext)}</>)
      expect(screen.getByText("Released lease #44")).toBeInTheDocument()
      expect(screen.getByText("7")).toBeInTheDocument()
      expect(screen.getByText("released")).toBeInTheDocument()
      expect(screen.getByText("input")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: /CHAT-8/ })).toHaveAttribute("href", "/chats/8")
      expect(screen.getByText("click the preview")).toBeInTheDocument()
      expect(screen.getByText("40 seconds ago")).toHaveAttribute("datetime", "2026-09-10T12:00:00Z")
      expect(screen.getByText("10 seconds ago")).toHaveAttribute("datetime", "2026-09-10T12:00:30Z")
    } finally {
      vi.useRealTimers()
    }
  })

  it.each([
    ["structured content", { structured_content: { released: [lease({ state: "released" })] }, content: [] }],
    ["text content", { structured_content: null, content: [{ type: "text", text: JSON.stringify({ released: [lease({ state: "released" })] }) }] }]
  ])("renders release control through the real provider envelope with %s", (_label, wrapped) => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime release control",
      calls: [
        {
          message_id: 1,
          tool_name: "runtime_release_control",
          raw_name: "mcp__syrus-chat-sidecar__runtime_release_control",
          detail: "Runtime #7",
          display_label: "Runtime release control",
          progress_label: "Thinking",
          raw_payload: { session_id: 7 },
          result_body: JSON.stringify(wrapped),
          result_json: wrapped,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Done"
    }

    render(<ToolGroup item={item} />)
    expandToolGroup("Runtime release control")
    expect(screen.getByText("Released lease #42")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /CHAT-8/ })).toHaveAttribute("href", "/chats/8")
    expect(screen.getByText("7")).toBeInTheDocument()
  })

  it("shows release failures with the requested session", () => {
    const toolContext = context("runtime_release_control", {
      input: { session_id: 7 },
      resultBody: "runtime session is unavailable",
      resultError: true
    })

    expect(runtimeReleaseControlToolCard.collapsedSummary?.(toolContext)).toBe("Runtime release control failed")
    render(<>{runtimeReleaseControlToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("runtime session is unavailable")).toBeInTheDocument()
    expect(screen.getByText("7")).toBeInTheDocument()
  })

  it("keeps release control payload secrets redacted", () => {
    const parsedResult = redactToolCardValue({ released: [lease({ state: "released", api_token: "result-secret" })] })
    const input = redactToolCardValue({ session_id: 7, api_token: "input-secret" }) as Record<string, unknown>

    render(<>{runtimeReleaseControlToolCard.renderExpanded(context("runtime_release_control", { input, parsedResult }))}</>)
    expect(screen.queryByText("result-secret")).not.toBeInTheDocument()
    expect(screen.queryByText("input-secret")).not.toBeInTheDocument()
    expect(screen.getByText(/"api_token": "\[redacted\]"/)).toBeInTheDocument()
  })

  it("masks typed input by default and reveals it only on request", () => {
    const longText = `whoami\n${"x".repeat(140)}`
    const parsedResult = { delivered: true, event: { type: "stdin", text: longText } }
    const toolContext = context("runtime_input", {
      parsedResult,
      input: { event: { type: "stdin", target: "terminal", data: longText, internal_payload: { huge: true } } }
    })

    expect(runtimeInputToolCard.collapsedSummary?.(toolContext)).toBe("Runtime input delivered: stdin on terminal")

    render(<>{runtimeInputToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("delivered")).toBeInTheDocument()
    expect(screen.getAllByText("terminal").length).toBeGreaterThan(0)
    expect(screen.getAllByText(`[typed text: ${longText.length} chars]`).length).toBeGreaterThan(0)
    expect(screen.queryByText(longText)).not.toBeInTheDocument()
    expect(screen.getByText("Input event")).toBeInTheDocument()
    expect(screen.getByText("Echoed event")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Reveal typed text" }))
    expect(screen.getByText("Hide typed text")).toBeInTheDocument()
    fireEvent.click(screen.getByText("Input event"))
    expect(document.querySelector("pre")?.textContent).toContain("whoami\\n")
    expect(document.querySelector("pre")?.textContent).toContain("x".repeat(140))
    expect(screen.queryByText("Runtime input delivered: stdin on terminal")).not.toBeInTheDocument()
  })

  it("renders click-like Runtime input outcomes and provider failures", () => {
    const delivered = context("runtime_input", {
      parsedResult: { delivered: true },
      input: { event: { type: "click", target: "button#save" } }
    })

    expect(runtimeInputToolCard.collapsedSummary?.(delivered)).toBe("Runtime input delivered: click on button#save")
    render(<>{runtimeInputToolCard.renderExpanded(delivered)}</>)
    expect(screen.getAllByText("click").length).toBeGreaterThan(0)
    expect(screen.getAllByText("button#save").length).toBeGreaterThan(0)

    const failed = context("runtime_input", {
      parsedResult: { error: "lease_required", message: "the agent must hold an active input lease before sending input events" },
      input: { event: { type: "click", target: "button#save" } }
    })

    expect(runtimeInputToolCard.collapsedSummary?.(failed)).toBe("Runtime input failed: lease_required")
    render(<>{runtimeInputToolCard.renderExpanded(failed)}</>)
    expect(screen.getAllByText("the agent must hold an active input lease before sending input events").length).toBeGreaterThan(0)
    expect(screen.getByText("lease_required")).toBeInTheDocument()
  })

  it("treats boolean browser errors and undelivered results as failures", () => {
    const browserError = context("runtime_input", {
      parsedResult: { error: true, content: "browser input failed", delivered: false },
      input: { session_id: 7, event: { type: "click" } }
    })

    expect(runtimeInputToolCard.collapsedSummary?.(browserError)).toBe("Runtime input failed: Runtime input failed")
    render(<>{runtimeInputToolCard.renderExpanded(browserError)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getAllByText("browser input failed").length).toBeGreaterThan(0)
    expect(screen.getByText("false")).toBeInTheDocument()
    expect(screen.getByText("7")).toBeInTheDocument()
  })

  it("shows Android echoed pointer details", () => {
    const parsedResult = { delivered: true, event: { type: "pointer", x: 123, y: 456, button: 1, pointer_type: "touch" } }

    render(
      <>{runtimeInputToolCard.renderExpanded(context("runtime_input", { input: { session_id: "android-4", event: { type: "pointer" } }, parsedResult }))}</>
    )
    expect(screen.getByText("Echoed event")).toBeInTheDocument()
    expect(screen.getByText("123")).toBeInTheDocument()
    expect(screen.getByText("456")).toBeInTheDocument()
    expect(screen.getByText("touch")).toBeInTheDocument()
    expect(screen.getByText("android-4")).toBeInTheDocument()
  })

  it.each([
    ["structured content", { structured_content: { error: "connection_error", message: "terminal disconnected" }, content: [] }],
    [
      "text content",
      { structured_content: null, content: [{ type: "text", text: JSON.stringify({ error: "unsupported_input", message: "unsupported terminal input" }) }] }
    ]
  ])("renders Runtime input failures through the real provider envelope with %s", (_label, wrapped) => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Runtime input",
      calls: [
        {
          message_id: 1,
          tool_name: "runtime_input",
          raw_name: "mcp__syrus-chat-sidecar__runtime_input",
          detail: "Runtime #7",
          display_label: "Runtime input",
          progress_label: "Thinking",
          raw_payload: { session_id: 7, event: { type: "stdin", text: "secret-token" } },
          result_body: JSON.stringify(wrapped),
          result_json: wrapped,
          result_error: false,
          result_kind: "json",
          result_summary: ""
        }
      ],
      collapsed_by_default: false,
      outcome_label: "Failed"
    }

    render(<ToolGroup item={item} />)
    expandToolGroup("Runtime input")
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.queryByText("secret-token")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Reveal typed text" })).toBeInTheDocument()
  })

  it("shows Runtime snapshot preview and page metadata", () => {
    const parsedResult = {
      error: false,
      content: [{ type: "image", data: "abc123", mimeType: "image/png" }],
      page_url: "http://127.0.0.1:4173/settings",
      title: "Settings",
      viewport: { width: 1280, height: 720 },
      captured_at: "2026-09-10T12:10:00Z"
    }
    const toolContext = context("runtime_snapshot", {
      parsedResult,
      input: { options: { target: "main" } }
    })

    expect(runtimeSnapshotToolCard.collapsedSummary?.(toolContext)).toBe("Runtime snapshot captured of main, 1280x720")

    render(<>{runtimeSnapshotToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByRole("img", { name: "Runtime snapshot preview" })).toHaveAttribute("src", "data:image/png;base64,abc123")
    expect(screen.getAllByText("http://127.0.0.1:4173/settings").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Settings").length).toBeGreaterThan(0)
    expect(screen.getByText("1280x720")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open Settings" })).toBeInTheDocument()
  })

  it("renders Android latest-frame snapshots with provider metadata", () => {
    const parsedResult = {
      kind: "android_screenshot",
      content_type: "image/png",
      document_id: 31,
      preview_url: "/api/v1/app/chats/8/media/chat_images/31/file",
      latest_frame_url: "/api/v1/app/chats/8/runtime_sessions/7/frame",
      latest_frame_at: "2026-09-10T12:11:00Z",
      fallback: true,
      warning: "device offline"
    }

    expect(runtimeSnapshotToolCard.collapsedSummary?.(context("runtime_snapshot", { parsedResult }))).toBe("Runtime snapshot captured of android_screenshot")

    render(<>{runtimeSnapshotToolCard.renderExpanded(context("runtime_snapshot", { parsedResult }))}</>)
    expect(screen.getByRole("img", { name: "Runtime snapshot preview" })).toHaveAttribute("src", "/api/v1/app/chats/8/media/chat_images/31/file")
    expect(screen.getAllByText("android_screenshot").length).toBeGreaterThan(0)
    expect(screen.getAllByText("31").length).toBeGreaterThan(0)
    expect(screen.getAllByText("image/png").length).toBeGreaterThan(0)
    expect(screen.getByText("device offline")).toBeInTheDocument()
  })

  it("shows missing Runtime artifacts as an explicit empty state", () => {
    const parsedResult = { found: false }

    expect(runtimeCaptureArtifactToolCard.collapsedSummary?.(context("runtime_capture_artifact", { parsedResult }))).toBe("No Runtime artifact captured")

    render(<>{runtimeCaptureArtifactToolCard.renderExpanded(context("runtime_capture_artifact", { parsedResult }))}</>)
    expect(screen.getByText("No Runtime artifact was returned.")).toBeInTheDocument()
    expect(screen.getByText("Runtime JSON")).toBeInTheDocument()
  })

  it("renders Runtime artifact metadata with preview and download affordances", () => {
    const parsedResult = {
      artifact: {
        id: "chat_image:3",
        filename: "settings.png",
        type: "image/png",
        file_path: "/api/v1/app/chats/12/media/chat_images/3/file",
        preview_url: "/api/v1/app/chats/12/media/chat_images/3/file",
        download_url: "/api/v1/app/chats/12/media/chat_images/3/file?download=1"
      }
    }

    expect(runtimeCaptureArtifactToolCard.collapsedSummary?.(context("runtime_capture_artifact", { parsedResult }))).toBe(
      "Runtime artifact captured: settings.png"
    )

    render(<>{runtimeCaptureArtifactToolCard.renderExpanded(context("runtime_capture_artifact", { parsedResult }))}</>)
    expect(screen.getByRole("img", { name: "settings.png" })).toHaveAttribute("src", "/api/v1/app/chats/12/media/chat_images/3/file")
    expect(screen.getAllByText("chat_image:3").length).toBeGreaterThan(0)
    expect(screen.getAllByText("settings.png").length).toBeGreaterThan(0)
    expect(screen.getAllByText("image/png").length).toBeGreaterThan(0)
    fireEvent.click(screen.getByRole("button", { name: "Open settings.png" }))
    const dialog = screen.getByRole("dialog", { name: "Runtime artifact preview" })
    expect(within(dialog).getByRole("link", { name: "Download" })).toHaveAttribute("href", "/api/v1/app/chats/12/media/chat_images/3/file?download=1")
  })

  it("renders Android screenshot payloads as generic Runtime artifacts", () => {
    const parsedResult = {
      kind: "android_screenshot",
      content_type: "image/png",
      document_id: 44,
      file_path: "/api/v1/app/chats/8/media/chat_images/44/file",
      latest_frame_url: "/api/v1/app/chats/8/runtime_sessions/7/frame",
      latest_frame_at: "2026-09-10T12:12:00Z"
    }

    expect(runtimeCaptureArtifactToolCard.collapsedSummary?.(context("runtime_capture_artifact", { parsedResult }))).toBe(
      "Runtime artifact captured: android_screenshot"
    )

    render(<>{runtimeCaptureArtifactToolCard.renderExpanded(context("runtime_capture_artifact", { parsedResult }))}</>)
    expect(screen.getByRole("img", { name: "android_screenshot" })).toHaveAttribute("src", "/api/v1/app/chats/8/media/chat_images/44/file")
    expect(screen.getAllByText("44").length).toBeGreaterThan(0)
    expect(screen.getAllByText("image/png").length).toBeGreaterThan(0)
  })

  it("renders Runtime capture failures distinctly", () => {
    const parsedResult = { error: true, message: "screenshot timed out" }

    expect(runtimeCaptureArtifactToolCard.collapsedSummary?.(context("runtime_capture_artifact", { parsedResult }))).toBe("Runtime artifact capture failed")

    render(<>{runtimeCaptureArtifactToolCard.renderExpanded(context("runtime_capture_artifact", { parsedResult }))}</>)
    expect(screen.getByText("screenshot timed out")).toBeInTheDocument()
  })

  it("renders no-op release distinctly", () => {
    const parsedResult = { released: [] }

    expect(runtimeReleaseControlToolCard.collapsedSummary?.(context("runtime_release_control", { parsedResult }))).toBe("No Runtime control leases released")

    render(<>{runtimeReleaseControlToolCard.renderExpanded(context("runtime_release_control", { input: { session_id: 527 }, parsedResult }))}</>)
    expect(screen.getByText("No active agent Runtime control leases were held.")).toBeInTheDocument()
    expect(screen.getByText("527")).toBeInTheDocument()
  })

  it("falls back to raw rendering for malformed Runtime payloads", () => {
    expect(runtimeListSessionsToolCard.collapsedSummary?.(context("runtime_list_sessions", { parsedResult: { oops: true } }))).toBeNull()
    expect(runtimeStatusToolCard.renderExpanded(context("runtime_status", { parsedResult: { id: null } }))).toBeNull()
    expect(runtimeInspectToolCard.renderExpanded(context("runtime_inspect", { parsedResult: "not json" }))).toBeNull()
    expect(runtimeLogsToolCard.collapsedSummary?.(context("runtime_logs", { parsedResult: { entries: "nope" } }))).toBeNull()
    expect(runtimeInputToolCard.renderExpanded(context("runtime_input", { parsedResult: "not json" }))).toBeNull()
    expect(runtimeSnapshotToolCard.renderExpanded(context("runtime_snapshot", { parsedResult: "not json" }))).toBeNull()
    expect(runtimeCaptureArtifactToolCard.renderExpanded(context("runtime_capture_artifact", { parsedResult: "not json" }))).toBeNull()
    expect(runtimeAcquireControlToolCard.renderExpanded(context("runtime_acquire_control", { parsedResult: "not json" }))).toBeNull()
    expect(runtimeReleaseControlToolCard.collapsedSummary?.(context("runtime_release_control", { parsedResult: { released: "nope" } }))).toBeNull()
  })
})
