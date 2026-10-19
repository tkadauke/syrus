import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { render, screen } from "@testing-library/react"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminVersionToolCard from "./admin_version"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "admin_version", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const HEALTHY_PAYLOAD = {
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
        used_percent: 40,
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
  beforeEach(() => {
    const bootstrap = document.createElement("script")
    bootstrap.id = "syrus-bootstrap-data"
    bootstrap.type = "application/json"
    bootstrap.textContent = JSON.stringify({ app: { revision_url: "https://github.com/tkadauke/syrus/commit/current" } })
    document.body.appendChild(bootstrap)
  })

  afterEach(() => document.getElementById("syrus-bootstrap-data")?.remove())

  it("registers under the exact MCP tool name", () => {
    expect(adminVersionToolCard.toolName).toBe("admin_version")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_version")).toBe("admin_version")
  })

  it("summarizes the instance count and preserves the mixed-version note", () => {
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult: HEALTHY_PAYLOAD }))).toBe("2 live instances")
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      instances: [
        { hostname: "web-1", version: "abc123" },
        { hostname: "web-2", version: "def456" }
      ]
    }
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 live instances (mixed versions -- deploy in progress?)")
  })

  it("renders all instance and disk fields in a responsive table", () => {
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)

    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getAllByText("worker-1").length).toBeGreaterThan(0)
    expect(screen.getByText("40.0%")).toBeInTheDocument()
    expect(screen.getAllByText("volume-host").length).toBeGreaterThan(0)
    expect(screen.getByText("/data/syrus")).toBeInTheDocument()
    expect(screen.getByText("1.0 GB available / 4.0 GB total")).toBeInTheDocument()
    expect(screen.getByText("Observed 2026-09-06T00:00:01Z")).toBeInTheDocument()
    expect(screen.getByText("request handler")).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Copy worker-1 to clipboard" }).length).toBeGreaterThan(0)
    expect(screen.getAllByRole("button", { name: "Copy abc123 to clipboard" }).length).toBeGreaterThan(0)
    expect(screen.getAllByRole("link", { name: "abc123" })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus/commit/abc123")
    expect(screen.getByRole("table")).toHaveClass("block", "sm:table")
  })

  it("keeps versions copyable without a configured repository", () => {
    document.getElementById("syrus-bootstrap-data")?.remove()
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)
    expect(screen.queryByRole("link", { name: "abc123" })).not.toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Copy abc123 to clipboard" }).length).toBeGreaterThan(0)
  })

  it("renders explicit empty and error states", () => {
    const { rerender } = render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult: { request_handler: {}, instances: [] } }))}</>)
    expect(screen.getByText("No live instances found.")).toBeInTheDocument()
    rerender(<>{adminVersionToolCard.renderExpanded(context({ resultError: true, resultBody: "secret backend failure" }))}</>)
    expect(screen.getByText("Unable to load instance versions.")).toBeInTheDocument()
    expect(screen.queryByText("secret backend failure")).not.toBeInTheDocument()
  })

  it.each([
    ["structured_content", { content: [{ type: "text", text: "stale" }], structured_content: HEALTHY_PAYLOAD }],
    ["content text JSON", { content: [{ type: "text", text: JSON.stringify(HEALTHY_PAYLOAD) }], structured_content: null }]
  ])("renders normalized %s results identically", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getAllByText("volume-host").length).toBeGreaterThan(0)
  })

  it("renders only redacted values supplied by the shared card boundary", () => {
    const payload = {
      ...HEALTHY_PAYLOAD,
      instances: [{ ...HEALTHY_PAYLOAD.instances[0], hostname: "worker-secret", data_root_usage: { level: "ok", path: "token=super-secret-value" } }]
    }
    const parsedResult = redactToolCardValue(payload)
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("token=[redacted]")).toBeInTheDocument()
    expect(screen.queryByText(/super-secret-value/)).not.toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminVersionToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
