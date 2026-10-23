import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import readQueueToolCard from "./read_queue"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "read_queue", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const HEALTHY_SNAPSHOT = {
  active_workers: {
    count: 1,
    queues: ["runs"],
    workers: [
      {
        hostname: "worker-1",
        pid: 42,
        queues: ["runs", "chat"],
        threads: 3,
        last_heartbeat_at: "2026-01-01T00:00:00Z",
        stale: false,
        status: "current",
        capabilities: { os: ["linux"], arch: ["x86_64"] },
        capability_diagnostics: { docker: true, probe: { version: "27.0" } },
        macos_worker_drain: { state: "updating", desired_git_sha: "newsha" }
      }
    ]
  },
  pending_jobs: { runs: 2, merges: 0, chat: 1, videos: 0, control_plane: 0, polling: 0, indexing: 0, cleanup: 0, low_priority_maintenance: 0 },
  failed_jobs: { count: 1 },
  recurring_tasks: { count: 4 },
  blocked_queues: ["merges"],
  paused_queues: ["videos"]
}

afterEach(async () => {
  await i18n.changeLanguage("en")
})

describe("read_queue tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readQueueToolCard.toolName).toBe("read_queue")
  })

  it("summarizes the collapsed row with localized worker and failure counts", async () => {
    expect(readQueueToolCard.collapsedSummary?.(context({ parsedResult: HEALTHY_SNAPSHOT }))).toBe("1 worker, 1 failed job")
    await i18n.changeLanguage("de")
    expect(
      readQueueToolCard.collapsedSummary?.(
        context({ parsedResult: { ...HEALTHY_SNAPSHOT, active_workers: { ...HEALTHY_SNAPSHOT.active_workers, count: 2 }, failed_jobs: { count: 2 } } })
      )
    ).toBe("2 Worker, 2 fehlgeschlagene Jobs")
  })

  it("renders localized queue and worker details and links worker identities to worker health", async () => {
    await i18n.changeLanguage("de")
    render(<>{readQueueToolCard.renderExpanded(context({ parsedResult: HEALTHY_SNAPSHOT }))}</>)
    expect(screen.getByText("Aktive Warteschlangen")).toBeInTheDocument()
    expect(screen.getByText("Fehlgeschlagene Jobs")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "worker-1:42" })).toHaveAttribute("href", "/admin/queue/workers")
    expect(screen.getByRole("link", { name: "worker-1:42" })).toHaveClass("min-h-11", "break-all")
    expect(screen.getByText("Threads")).toBeInTheDocument()
    expect(screen.getByText("Letzter Heartbeat")).toBeInTheDocument()
    expect(screen.getByText("2026-01-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("current")).toBeInTheDocument()
    expect(screen.getByText("Fähigkeitsdiagnose")).toBeInTheDocument()
    expect(screen.getByText("docker: true")).toBeInTheDocument()
    expect(screen.getByText('probe: {"version":"27.0"}')).toBeInTheDocument()
    expect(screen.getByText("os: linux")).toBeInTheDocument()
    expect(screen.getByText("updating: newsha")).toBeInTheDocument()
  })

  it("renders a localized unavailable banner with a bounded Markdown error", async () => {
    await i18n.changeLanguage("de")
    const parsedResult = {
      active_workers: { count: 0, queues: [], workers: [] },
      pending_jobs: {},
      failed_jobs: { count: 0 },
      recurring_tasks: { count: 0 },
      blocked_queues: [],
      paused_queues: [],
      unavailable: true,
      error: `**SolidQueue tables unreachable.**\n\n${"connection failure ".repeat(80)}`
    }
    render(<>{readQueueToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Warteschlangenübersicht nicht verfügbar")).toBeInTheDocument()
    expect(screen.getByText("SolidQueue tables unreachable.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Mehr anzeigen" })).toBeInTheDocument()
    expect(screen.getByTestId("markdown-preview-content").closest(".break-all")).toBeInTheDocument()
  })

  it("renders an explicit localized unauthorized state", async () => {
    const unauthorized = "Unauthorized: Admin access required"
    await i18n.changeLanguage("de")
    expect(readQueueToolCard.collapsedSummary?.(context({ parsedResult: unauthorized, resultBody: unauthorized }))).toBe("Administratorzugriff erforderlich")
    render(<>{readQueueToolCard.renderExpanded(context({ parsedResult: null, resultBody: unauthorized }))}</>)
    expect(screen.getByText("Zum Anzeigen des Warteschlangenstatus ist Administratorzugriff erforderlich.")).toBeInTheDocument()
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(HEALTHY_SNAPSHOT) }], structured_content: null }],
    ["structured content", { content: [{ type: "text", text: "ignored" }], structured_content: HEALTHY_SNAPSHOT }]
  ])("uses shared normalization for a %s envelope", (_label, envelope) => {
    expect(
      readQueueToolCard.collapsedSummary?.(
        context({ toolName: normalizedToolName("mcp__syrus-chat-sidecar__read_queue"), parsedResult: normalizedToolCardParsedResult(envelope) })
      )
    ).toBe("1 worker, 1 failed job")
  })

  it("renders an explicit localized empty-worker state", async () => {
    await i18n.changeLanguage("de")
    render(<>{readQueueToolCard.renderExpanded(context({ parsedResult: { ...HEALTHY_SNAPSHOT, active_workers: { count: 0, queues: [], workers: [] } } }))}</>)
    expect(screen.getByText("Keine aktiven Worker gefunden.")).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(readQueueToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readQueueToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
