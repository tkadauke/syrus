import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatToolGroupItem } from "../../../api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { ToolGroup } from "../MessageCards"
import adminMcpToolUsageToolCard from "./admin_mcp_tool_usage"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_mcp_tool_usage",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const POPULATED_PAYLOAD = {
  window: { start: "2026-09-01T00:00:00Z", end: "2026-09-08T00:00:00Z" },
  surface: "all",
  filters: { tool_name: "read_job", server_name: "syrus-chat-sidecar" },
  totals: { calls: 42, errors: 3 },
  top_tools: [
    { tool_name: "read_job", server_name: "syrus-chat-sidecar", calls: 25, errors: 1, error_rate: 0.04 },
    { tool_name: "admin_mcp_tool_usage", server_name: "syrus-chat-sidecar", calls: 17, errors: 2, error_rate: 0.1176 }
  ],
  error_rates: [
    { tool_name: "admin_mcp_tool_usage", server_name: "syrus-chat-sidecar", calls: 17, errors: 2, error_rate: 0.1176 },
    { tool_name: "read_job", server_name: "syrus-chat-sidecar", calls: 25, errors: 1, error_rate: 0.04 }
  ],
  surface_breakdown: [
    { surface: "chat", calls: 30, errors: 2, error_rate: 0.0667 },
    { surface: "workflow", calls: 12, errors: 1, error_rate: 0.0833 }
  ],
  provider_breakdown: [{ provider: "codex", calls: 42, errors: 3, error_rate: 0.0714 }],
  server_breakdown: [{ server_name: "syrus-chat-sidecar", calls: 42, errors: 3, error_rate: 0.0714 }],
  sidecar_mode_breakdown: [
    { sidecar_mode: "persistent", calls: 35, errors: 2, error_rate: 0.0571 },
    { sidecar_mode: "stdio", calls: 7, errors: 1, error_rate: 0.1429 }
  ],
  authority_breakdown: [
    { authority: "operator_host", calls: 5, errors: 0, error_rate: 0 },
    { authority: "workspace", calls: 12, errors: 1, error_rate: 0.0833 }
  ],
  startup_timing: {
    window: { start: "2026-09-01T00:00:00Z", end: "2026-09-08T00:00:00Z" },
    filters: { provider: "codex", server_name: "syrus-chat-sidecar" },
    turns_observed: 6,
    stalled_turns: 1,
    phase_latency: [{ phase: "mcp_startup", count: 5, avg_ms: 120.4, p50_ms: 100, p95_ms: 220, max_ms: 240 }]
  },
  unused_advertised_tools: ["admin_clear_github_cache"],
  custom_card_gaps: {
    ranked_gaps: [
      {
        tool_name: "bulk_read_jobs",
        calls: 19,
        errors: 0,
        error_rate: 0,
        result_bytes: 131072,
        last_used_at: "2026-09-08T11:59:00Z",
        server_names: ["syrus-chat-sidecar"],
        owner_type: "core",
        owner_name: "core",
        recommendation_target: "core",
        card_status: "missing",
        recommendation: "custom_card_next"
      },
      {
        tool_name: "unused_plugin_tool",
        calls: 0,
        errors: 0,
        error_rate: 0,
        result_bytes: 0,
        last_used_at: null,
        server_names: [],
        owner_type: "plugin",
        owner_name: "example_plugin",
        recommendation_target: "plugin:example_plugin",
        card_status: "missing",
        recommendation: "ignore_for_now"
      }
    ],
    high_volume_without_custom_card: [
      {
        tool_name: "bulk_read_jobs",
        calls: 19,
        errors: 0,
        error_rate: 0,
        owner_type: "core",
        owner_name: "core",
        recommendation_target: "core",
        card_status: "missing"
      }
    ],
    high_error_with_weak_or_no_custom_card: [
      {
        tool_name: "sync_plugin_state",
        calls: 8,
        errors: 4,
        error_rate: 0.5,
        owner_type: "plugin",
        owner_name: "example_plugin",
        recommendation_target: "plugin:example_plugin",
        card_status: "weak"
      }
    ],
    unused_advertised_tools: [
      {
        tool_name: "unused_plugin_tool",
        owner_type: "plugin",
        owner_name: "example_plugin",
        recommendation_target: "plugin:example_plugin",
        card_status: "missing"
      }
    ],
    unclassified_advertised_tools: [
      {
        tool_name: "new_plugin_tool",
        owner_type: "plugin",
        owner_name: "example_plugin",
        recommendation_target: "plugin:example_plugin",
        card_status: "missing"
      }
    ]
  },
  recent_calls: [
    {
      id: 9,
      occurred_at: "2026-09-08T12:00:00Z",
      surface: "chat",
      provider: "codex",
      tool_name: "admin_mcp_tool_usage",
      server_name: "syrus-chat-sidecar",
      status: "failed",
      error: true,
      error_class: "RuntimeError",
      error_message_summary: "boom",
      sidecar_mode: "persistent",
      daemon_worker_id: "worker-chat",
      authority: "operator_host",
      job_id: 4774,
      job_path: "/jobs/4774",
      workflow_id: 27863,
      workflow_path: "/admin/workflows/27863",
      run_id: 133147,
      run_path: "/admin/runs/133147/transcript",
      chat_session_id: 12,
      chat_path: "/chats/12",
      repository_id: 3,
      user_id: 7,
      input_bytes: 1024,
      result_bytes: 2048,
      started_at: "2026-09-08T11:59:58Z",
      completed_at: "2026-09-08T12:00:00Z"
    }
  ]
}

function toolGroup(payload: unknown): ChatToolGroupItem {
  const body = JSON.stringify(payload)
  return {
    type: "tool_group",
    tool: "Admin mcp tool usage",
    calls: [
      {
        message_id: 1,
        tool_name: "admin_mcp_tool_usage",
        raw_name: "syrus-chat-sidecar.admin_mcp_tool_usage",
        detail: "surface=all",
        display_label: "Admin mcp tool usage",
        progress_label: "Reading",
        raw_payload: { surface: "all", api_token: "input-secret-123456" },
        result_body: body,
        result_json: payload,
        result_error: false,
        result_kind: "record",
        result_summary: adminMcpToolUsageToolCard.collapsedSummary?.(context({ parsedResult: payload })) || ""
      }
    ]
  }
}

describe("admin_mcp_tool_usage tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminMcpToolUsageToolCard.toolName).toBe("admin_mcp_tool_usage")
  })

  it("summarizes the collapsed row with window, surface, total calls, errors, and error rate", () => {
    expect(adminMcpToolUsageToolCard.collapsedSummary?.(context({ parsedResult: POPULATED_PAYLOAD }))).toBe(
      "2026-09-01T00:00:00Z to 2026-09-08T00:00:00Z, all surface, 42 calls, 3 errors, 7.1% error rate"
    )
  })

  it("renders populated stats with separate volume and error priorities", () => {
    render(<>{adminMcpToolUsageToolCard.renderExpanded(context({ parsedResult: POPULATED_PAYLOAD }))}</>)

    expect(screen.getAllByText("Calls").length).toBeGreaterThan(0)
    expect(screen.getAllByText("42").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Errors").length).toBeGreaterThan(0)
    expect(screen.getAllByText("3").length).toBeGreaterThan(0)
    expect(screen.getByText("Volume priorities")).toBeInTheDocument()
    expect(screen.getByText("Error priorities")).toBeInTheDocument()
    expect(screen.getByText("Missing high-volume cards")).toBeInTheDocument()
    expect(screen.getByText("Weak or missing error cards")).toBeInTheDocument()
    expect(screen.getAllByText("Unused advertised tools").length).toBeGreaterThan(0)
    expect(screen.getByText("Unclassified advertised tools")).toBeInTheDocument()
    expect(screen.getAllByText("plugin:example_plugin").length).toBeGreaterThan(0)
    expect(screen.getByText("new_plugin_tool")).toBeInTheDocument()
    expect(screen.getAllByText("admin_mcp_tool_usage").length).toBeGreaterThan(0)
    expect(screen.getAllByText("11.8%").length).toBeGreaterThan(0)
    expect(screen.getByText("Custom card gap ranking")).toBeInTheDocument()
    expect(screen.getByText("128.0 KB")).toBeInTheDocument()
    expect(screen.getByText("custom card next")).toBeInTheDocument()
    expect(screen.getByText("ignore for now")).toBeInTheDocument()
    expect(screen.getByText(/worker-chat/)).toBeInTheDocument()
    expect(screen.getByText("Startup timing")).toBeInTheDocument()
    expect(screen.getByText("Window: 2026-09-01T00:00:00Z to 2026-09-08T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("Provider: codex")).toBeInTheDocument()
    expect(screen.getByText("Server: syrus-chat-sidecar")).toBeInTheDocument()
    expect(screen.getByText("mcp startup")).toBeInTheDocument()
    expect(screen.getByText(/Input: 1\.0 KB/)).toBeInTheDocument()
    expect(screen.getByText(/Result: 2\.0 KB/)).toBeInTheDocument()
  })

  it("renders empty windows without pretending the payload is malformed", () => {
    const payload = {
      ...POPULATED_PAYLOAD,
      totals: { calls: 0, errors: 0 },
      top_tools: [],
      error_rates: [],
      surface_breakdown: [],
      provider_breakdown: [],
      server_breakdown: [],
      sidecar_mode_breakdown: [],
      authority_breakdown: [],
      startup_timing: {
        window: { start: "2026-09-01T00:00:00Z", end: "2026-09-08T00:00:00Z" },
        filters: { provider: null, server_name: null },
        turns_observed: 0,
        stalled_turns: 0,
        phase_latency: []
      },
      unused_advertised_tools: [],
      custom_card_gaps: {
        ranked_gaps: [],
        high_volume_without_custom_card: [],
        high_error_with_weak_or_no_custom_card: [],
        unused_advertised_tools: [],
        unclassified_advertised_tools: []
      },
      recent_calls: []
    }

    render(<>{adminMcpToolUsageToolCard.renderExpanded(context({ parsedResult: payload }))}</>)

    expect(screen.getByText("No MCP tool calls found for this window.")).toBeInTheDocument()
    expect(screen.getByText("No tool volume in this window.")).toBeInTheDocument()
    expect(screen.getByText("No high-error tools in this window.")).toBeInTheDocument()
    expect(screen.getByText("No missing or weak card gaps in this window.")).toBeInTheDocument()
    expect(screen.getAllByText("No card coverage gaps in this bucket.").length).toBe(4)
    expect(screen.getByText("Provider: all")).toBeInTheDocument()
    expect(screen.getByText("Server: all")).toBeInTheDocument()
    expect(screen.getByText("No recent calls found.")).toBeInTheDocument()
  })

  it("shows active filters in the expanded card", () => {
    render(
      <>
        {adminMcpToolUsageToolCard.renderExpanded(
          context({
            input: {
              surface: "workflow",
              window: "7d",
              since: "2h",
              start: "start-value",
              end: "end-value",
              limit: 10,
              recent_limit: 5,
              tool: "read_job",
              server: "sidecar"
            },
            parsedResult: POPULATED_PAYLOAD
          })
        )}
      </>
    )

    expect(screen.getAllByText("tool: read_job")).toHaveLength(2)
    expect(screen.getByText("server: syrus-chat-sidecar")).toBeInTheDocument()
    expect(screen.getByText("surface: workflow")).toBeInTheDocument()
    expect(screen.getByText("window: 7d")).toBeInTheDocument()
    expect(screen.getByText("since: 2h")).toBeInTheDocument()
    expect(screen.getByText("start: start-value")).toBeInTheDocument()
    expect(screen.getByText("end: end-value")).toBeInTheDocument()
    expect(screen.getByText("limit: 10")).toBeInTheDocument()
    expect(screen.getByText("recent_limit: 5")).toBeInTheDocument()
    expect(screen.getByText("server: sidecar")).toBeInTheDocument()
  })

  it("links recent calls back to available chat, job, workflow, and run pages", () => {
    render(<>{adminMcpToolUsageToolCard.renderExpanded(context({ parsedResult: POPULATED_PAYLOAD }))}</>)

    expect(screen.getByRole("link", { name: "JOB-4774" })).toHaveAttribute("href", "/jobs/4774")
    expect(screen.getByRole("link", { name: "WF-27863" })).toHaveAttribute("href", "/admin/workflows/27863")
    expect(screen.getByRole("link", { name: "RUN-133147" })).toHaveAttribute("href", "/admin/runs/133147/transcript")
    expect(screen.getByRole("link", { name: "CHAT-12" })).toHaveAttribute("href", "/chats/12")
    expect(screen.getByRole("link", { name: "Repository 3" })).toHaveAttribute("href", "/repositories/3")
  })

  it("renders unavailable data as an explicit empty state", () => {
    render(<>{adminMcpToolUsageToolCard.renderExpanded(context({ parsedResult: { unavailable: "Usage stats are unavailable." } }))}</>)

    expect(screen.getByText("Usage stats are unavailable.")).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(adminMcpToolUsageToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminMcpToolUsageToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("keeps raw tool details available around the custom card", () => {
    render(<ToolGroup item={toolGroup(POPULATED_PAYLOAD)} />)

    fireEvent.click(screen.getByText("Admin mcp tool usage"))
    const rawDetails = screen.getByText("Raw details").closest("details")
    expect(rawDetails).not.toBeNull()
    if (!rawDetails) return
    rawDetails.open = true
    fireEvent(rawDetails, new Event("toggle"))

    expect(screen.getByText("Volume priorities")).toBeInTheDocument()
    const rawText = rawDetails.querySelector("pre")?.textContent || ""
    expect(rawText).toContain('"input"')
    expect(rawText).toContain("admin_clear_github_cache")
    expect(rawText).not.toContain("input-secret-123456")
    expect(rawText).toContain("[redacted]")
  })

  it("renders the same card for the Codex MCP raw name", () => {
    const item = toolGroup(POPULATED_PAYLOAD)
    item.calls[0].raw_name = "mcp__syrus-chat-sidecar__admin_mcp_tool_usage"
    render(<ToolGroup item={item} />)
    fireEvent.click(screen.getByText("Admin mcp tool usage"))
    expect(screen.getByText("Startup timing")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "CHAT-12" })).toHaveAttribute("href", "/chats/12")
  })

  it.each([
    ["structured content", { structured_content: POPULATED_PAYLOAD, content: [{ type: "text", text: "{}" }] }],
    ["JSON text content", { structured_content: null, content: [{ type: "text", text: JSON.stringify(POPULATED_PAYLOAD) }] }]
  ])("renders normalized %s MCP results", (_label, payload) => {
    render(<ToolGroup item={toolGroup(payload)} />)
    fireEvent.click(screen.getByText("Admin mcp tool usage"))
    expect(screen.getByText("Startup timing")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "CHAT-12" })).toHaveAttribute("href", "/chats/12")
  })
})
