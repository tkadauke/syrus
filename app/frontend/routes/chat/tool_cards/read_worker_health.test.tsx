import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readWorkerHealthToolCard from "./read_worker_health"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_worker_health",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const HEALTHY_PAYLOAD = {
  range: { since: "2026-09-05T00:00:00Z", until: "2026-09-06T00:00:00Z" },
  current: [
    {
      hostname: "worker-1",
      role: "worker",
      version: "abc123",
      stale: false,
      last_heartbeat_at: "2026-09-06T00:00:00Z",
      capabilities: { os: ["linux"], features: ["docker"] },
      macos_worker_drain: { state: "updating", desired_git_sha: "newsha" },
      health: { level: "ok", reasons: [] },
      sample: {
        cpu_used_percent: 12.5,
        memory_used_percent: 40.0,
        data_root_used_percent: 30.0,
        io_pressure_some: 0.0,
        capabilities: { os: ["linux"], features: ["docker"] }
      }
    }
  ],
  hosts: [
    {
      hostname: "worker-1",
      status: "current",
      windows: { "1h": { sample_count: 60, warning_count: 0, critical_count: 0 }, "24h": { sample_count: 1440, warning_count: 0, critical_count: 0 } }
    }
  ]
}

describe("read_worker_health tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readWorkerHealthToolCard.toolName).toBe("read_worker_health")
  })

  it("summarizes a healthy fleet in the collapsed row", () => {
    expect(readWorkerHealthToolCard.collapsedSummary?.(context({ parsedResult: HEALTHY_PAYLOAD }))).toBe("1 worker healthy")
  })

  it("renders the current-worker table with pressure indicators and timing", () => {
    render(<>{readWorkerHealthToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)

    expect(screen.getAllByText("worker-1").length).toBeGreaterThan(0)
    expect(screen.getByText("12.5%")).toBeInTheDocument()
    expect(screen.getByText(/40.0%/)).toBeInTheDocument()
    expect(screen.getByText("os: linux")).toBeInTheDocument()
    expect(screen.getByText("features: docker")).toBeInTheDocument()
    expect(screen.getByText(/"state": "updating"/)).toBeInTheDocument()
    expect(screen.getByText(/"desired_git_sha": "newsha"/)).toBeInTheDocument()
    expect(screen.getAllByText("2026-09-06T00:00:00Z").length).toBeGreaterThan(0)
  })

  it("flags a stale, critical worker distinctly and summarizes it as needing attention", () => {
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      current: [
        {
          hostname: "worker-2",
          role: "worker",
          stale: true,
          last_heartbeat_at: "2026-09-05T23:00:00Z",
          health: { level: "critical", reasons: ["worker heartbeat stale", "CPU pressure critical"] },
          sample: null
        }
      ]
    }

    expect(readWorkerHealthToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 of 1 worker need attention")

    render(<>{readWorkerHealthToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("critical")).toBeInTheDocument()
    expect(screen.getByText("(stale)")).toBeInTheDocument()
  })

  it("renders per-host trend history behind a disclosure", () => {
    render(<>{readWorkerHealthToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)
    expect(screen.getByText("Host trend history")).toBeInTheDocument()
    expect(screen.getByText("60 samples")).toBeInTheDocument()
  })

  it("renders every history window, inline reasons, inputs, metadata, and copyable hosts", () => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      generated_at: "2026-09-06T00:01:00Z",
      current_sample_window_seconds: 900,
      minute_bucket: { granularity_seconds: 60, window_minutes: 30, max_window_minutes: 1440 },
      current: [
        {
          ...HEALTHY_PAYLOAD.current[0],
          id: 7,
          worker_storage_key: "worker-key",
          desired_version: { git_sha: "newsha" },
          macos_updater_state: "ready",
          capability_diagnostics: { docker: true },
          seconds_since_heartbeat: 12,
          health: { level: "warning", reasons: ["load elevated"] },
          sample: {
            ...HEALTHY_PAYLOAD.current[0].sample,
            load_1m: 1,
            load_5m: 2,
            load_15m: 3,
            memory_available_bytes: 1024,
            memory_total_bytes: 2048,
            data_root_available_bytes: 4096,
            data_root_total_bytes: 8192,
            cpu_pressure_some: 4,
            cpu_pressure_full: 1,
            io_pressure_full: 2,
            observed_at: "2026-09-06T00:00:00Z",
            raw_metrics: { token: "[REDACTED]" }
          }
        }
      ],
      hosts: [
        {
          ...HEALTHY_PAYLOAD.hosts[0],
          windows: { "15m": { sample_count: 15 }, "1h": { sample_count: 60 }, "6h": { sample_count: 360 }, "24h": { sample_count: 1440 } },
          minute_buckets: [{ minute: "2026-09-06T00:00:00Z" }],
          recent_samples: [{ id: 8 }]
        }
      ]
    }
    render(
      <>
        {readWorkerHealthToolCard.renderExpanded(
          context({ input: { hostname: "worker-1", since: "start", until: "end", sample_limit_per_host: 1, minute_bucket_window_minutes: 30 }, parsedResult })
        )}
      </>
    )
    expect(screen.getAllByText("Last 15m").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Last 6h").length).toBeGreaterThan(0)
    expect(screen.getAllByText("load elevated").length).toBeGreaterThan(0)
    expect(screen.getByText("Generated at")).toBeInTheDocument()
    expect(screen.getByText(/\[REDACTED\]/)).toBeInTheDocument()
    fireEvent.click(screen.getAllByRole("button", { name: "Copy worker-1 to clipboard" })[0])
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("worker-1")
  })

  it("renders an explicit empty state for no live workers", () => {
    render(<>{readWorkerHealthToolCard.renderExpanded(context({ parsedResult: { range: HEALTHY_PAYLOAD.range, current: [], hosts: [] } }))}</>)
    expect(screen.getByText("No live workers found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(readWorkerHealthToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readWorkerHealthToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
