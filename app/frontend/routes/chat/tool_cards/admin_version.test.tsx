import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminVersionToolCard from "./admin_version"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_version",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const HEALTHY_PAYLOAD = {
  repository_url: "https://github.com/tkadauke/syrus",
  request_handler: { hostname: "web-1", role: "web", version: "abc123" },
  instances: [
    {
      id: 1,
      hostname: "web-1",
      role: "web",
      version: "abc123",
      started_at: "2026-09-01T00:00:00Z",
      last_heartbeat_at: "2026-09-06T00:00:00Z",
      data_root_usage: null
    },
    {
      id: 2,
      hostname: "worker-1",
      role: "worker",
      version: "abc123",
      started_at: "2026-09-01T00:00:00Z",
      last_heartbeat_at: "2026-09-06T00:00:00Z",
      data_root_usage: {
        level: "ok",
        used_percent: 40.0,
        hostname: "volume-host",
        path: "/data/syrus",
        available_bytes: 1073741824,
        total_bytes: 4294967296,
        observed_at: "2026-09-06T00:00:01Z"
      }
    }
  ]
}

describe("admin_version tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminVersionToolCard.toolName).toBe("admin_version")
  })

  it("summarizes the collapsed row with the live instance count", () => {
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult: HEALTHY_PAYLOAD }))).toBe("2 live instances")
  })

  it("flags mixed versions across instances (a deploy rollout in progress)", () => {
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      instances: [
        { hostname: "web-1", role: "web", version: "abc123" },
        { hostname: "web-2", role: "web", version: "def456" }
      ]
    }
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 live instances (mixed versions -- deploy in progress?)")
  })

  it("renders the handling host, instance table, and disk health", () => {
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)

    expect(screen.getAllByText("web-1").length).toBeGreaterThan(0)
    expect(screen.getByText("worker-1")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByText("40.0%")).toBeInTheDocument()
    expect(screen.getAllByText("ok").length).toBeGreaterThan(0)
    expect(screen.getAllByText("volume-host").length).toBeGreaterThan(0)
    expect(screen.getByText("/data/syrus")).toBeInTheDocument()
    expect(screen.getByText("1.0 GB available / 4.0 GB total")).toBeInTheDocument()
    expect(screen.getByText("Observed 2026-09-06T00:00:01Z")).toBeInTheDocument()
    expect(screen.getByText("request handler")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "abc123" })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus/commit/abc123")
    expect(screen.getAllByRole("button", { name: "Copy worker-1 to clipboard" }).length).toBeGreaterThan(0)
    expect(screen.getAllByRole("button", { name: "Copy abc123 to clipboard" }).length).toBeGreaterThan(0)
    expect(screen.getByRole("table")).toHaveClass("block")
  })

  it("renders a critical disk level distinctly from ok", () => {
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      instances: [{ hostname: "worker-1", role: "worker", version: "abc123", data_root_usage: { level: "critical", used_percent: 97.2 } }]
    }

    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("critical")).toBeInTheDocument()
    expect(screen.getByText("97.2%")).toBeInTheDocument()
  })

  it("renders an explicit empty state for no live instances", () => {
    const parsedResult = { request_handler: { hostname: "web-1" }, instances: [] }
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No live instances found.")).toBeInTheDocument()
  })

  it("renders a safe error state", () => {
    render(<>{adminVersionToolCard.renderExpanded(context({ resultError: true, resultBody: "secret backend failure" }))}</>)
    expect(screen.getByText("Unable to load instance versions.")).toBeInTheDocument()
    expect(screen.queryByText("secret backend failure")).not.toBeInTheDocument()
  })

  it.each([
    ["structured content", { content: [{ type: "text", text: "stale" }], structured_content: HEALTHY_PAYLOAD }, "mcp__syrus-chat-sidecar__admin_version"],
    ["text JSON", { content: [{ type: "text", text: JSON.stringify(HEALTHY_PAYLOAD) }], structured_content: null }, "admin_version"]
  ])("renders normalized %s results for every agent envelope", (_label, result, rawName) => {
    expect(normalizedToolName(rawName)).toBe("admin_version")
    const parsedResult = normalizedToolCardParsedResult(result)
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getAllByText("volume-host").length).toBeGreaterThan(0)
  })

  it("redacts sensitive fields before the card renders", () => {
    const payload = { ...HEALTHY_PAYLOAD, instances: [{ ...HEALTHY_PAYLOAD.instances[0], hostname: "worker-secret", api_token: "do-not-render" }] }
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult: payload }))}</>)
    expect(screen.getByText("worker-secret")).toBeInTheDocument()
    expect(screen.queryByText("do-not-render")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminVersionToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
