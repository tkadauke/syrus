import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import daemonPingToolCard from "./daemon_ping"

function context(parsedResult: unknown, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "daemon_ping", resultBody: JSON.stringify(parsedResult), resultError: false, parsedResult, ...overrides }
}

function providerContext(rawName: string, result: unknown): ToolCardContext {
  return context(normalizedToolCardParsedResult(result), { toolName: normalizedToolName(rawName) })
}

const HEALTHY = {
  ok: true,
  identity: { worker_id: "worker-123", hostname: "worker-host", role: "worker", version: "abc123", pid: 4321 }
}

describe("daemon_ping tool card", () => {
  it("registers under the exact MCP tool name and summarizes success", () => {
    expect(daemonPingToolCard.toolName).toBe("daemon_ping")
    expect(daemonPingToolCard.collapsedSummary?.(context(HEALTHY))).toBe("daemon ping ok")
  })

  it.each(["mcp__syrus-chat-sidecar__daemon_ping", "mcp__syrus-chat-deferred-sidecar__daemon_ping"])("renders all identity fields for %s", (rawName) => {
    const toolContext = providerContext(rawName, HEALTHY)
    expect(toolContext.toolName).toBe("daemon_ping")
    render(<>{daemonPingToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("ok")).toBeInTheDocument()
    for (const value of Object.values(HEALTHY.identity)) expect(screen.getByText(String(value))).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "worker-123" })).toHaveAttribute("href", "/admin/queue/workers")
    expect(screen.getByRole("button", { name: "Copy abc123 to clipboard" })).toBeInTheDocument()
  })

  it.each([
    ["structured_content", { structured_content: HEALTHY }],
    ["content text", { content: [{ type: "text", text: JSON.stringify(HEALTHY) }] }]
  ])("normalizes and renders the %s result shape", (_label, result) => {
    const toolContext = providerContext("mcp__syrus-chat-sidecar__daemon_ping", result)
    expect(daemonPingToolCard.collapsedSummary?.(toolContext)).toBe("daemon ping ok")
    render(<>{daemonPingToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("worker-host")).toBeInTheDocument()
  })

  it("renders explicit failure and empty identity states", () => {
    const toolContext = context({ ok: false, identity: {} }, { resultError: true })
    expect(daemonPingToolCard.collapsedSummary?.(toolContext)).toBe("daemon ping failed")
    render(<>{daemonPingToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("No daemon identity returned.")).toBeInTheDocument()
  })

  it("renders every future identity field and wraps complex values", () => {
    render(<>{daemonPingToolCard.renderExpanded(context({ ok: true, identity: { capabilities: { os: "linux" } } }))}</>)
    expect(screen.getByText("capabilities")).toBeInTheDocument()
    expect(screen.getByText('{"os":"linux"}')).toHaveClass("break-all")
  })

  it("only receives redacted identity values from the shared card boundary", () => {
    const redacted = redactToolCardValue({ ok: true, identity: { api_token: "super-secret-value", worker_id: "worker-123" } })
    render(<>{daemonPingToolCard.renderExpanded(context(redacted))}</>)
    expect(screen.getByText("[redacted]")).toBeInTheDocument()
    expect(screen.queryByText("super-secret-value")).not.toBeInTheDocument()
  })

  it("falls back for malformed or empty results", () => {
    expect(daemonPingToolCard.collapsedSummary?.(context({ identity: {} }))).toBeNull()
    expect(daemonPingToolCard.renderExpanded(context(null))).toBeNull()
  })
})
