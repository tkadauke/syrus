import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
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
        hostname: "worker-1",
        path: "/var/lib/syrus",
        level: "ok",
        used_percent: 40.0,
        available_bytes: 1024 ** 3,
        total_bytes: 4 * 1024 ** 3,
        observed_at: "2026-09-06T00:00:00Z"
      }
    }
  ]
}

describe("admin_version tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify({ app: { revision_url: "https://github.com/acme/syrus/commit/current" } })
    document.body.appendChild(script)
  })

  afterEach(() => document.getElementById("syrus-bootstrap-data")?.remove())

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

  it("renders every instance and disk field, copyable identities, commit links, and the handler marker", () => {
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)

    expect(screen.getAllByText("web-1").length).toBeGreaterThan(0)
    expect(screen.getAllByText("worker-1").length).toBeGreaterThan(0)
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByText("40.0%")).toBeInTheDocument()
    expect(screen.getAllByText("ok").length).toBeGreaterThan(0)
    expect(screen.getByText("/var/lib/syrus")).toBeInTheDocument()
    expect(screen.getByText("1.0 GB")).toBeInTheDocument()
    expect(screen.getByText("4.0 GB")).toBeInTheDocument()
    expect(screen.getByText("handler")).toBeInTheDocument()

    const versionLinks = screen.getAllByRole("link", { name: "abc123" })
    expect(versionLinks[0]).toHaveAttribute("href", "https://github.com/acme/syrus/commit/abc123")
    fireEvent.click(screen.getAllByRole("button", { name: "Copy abc123 to clipboard" })[0])
    fireEvent.click(screen.getByRole("button", { name: "Copy worker-1 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("abc123")
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("worker-1")

    const table = screen.getByRole("table")
    expect(table).toHaveClass("block")
    expect(table.querySelector("thead")).toHaveClass("hidden")
  })

  it("renders identically from namespaced calls and both MCP result envelopes", () => {
    const variants = [HEALTHY_PAYLOAD, { structured_content: HEALTHY_PAYLOAD }, { content: [{ type: "text", text: JSON.stringify(HEALTHY_PAYLOAD) }] }]

    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_version")).toBe("admin_version")
    for (const result of variants) {
      const view = render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult: normalizedToolCardParsedResult(result) }))}</>)
      expect(screen.getAllByText("worker-1").length).toBeGreaterThan(0)
      view.unmount()
    }
  })

  it("does not render unknown sensitive result fields", () => {
    const parsedResult = { ...HEALTHY_PAYLOAD, api_token: "super-secret", instances: [{ ...HEALTHY_PAYLOAD.instances[0], password: "hidden" }] }
    const { container } = render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(container).not.toHaveTextContent("super-secret")
    expect(container).not.toHaveTextContent("hidden")
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

  it("falls back to null for a malformed payload", () => {
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminVersionToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(adminVersionToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD, resultError: true }))).toBeNull()
  })
})
