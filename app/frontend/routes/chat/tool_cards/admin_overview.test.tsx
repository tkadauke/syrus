import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "../toolRendering"
import adminOverviewToolCard from "./admin_overview"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "admin_overview", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const OVERVIEW = {
  active_runs: { total: 2, by_trigger: { initial: 1, retry: 1 } },
  queued_runs: { total: 1 },
  recent_failures_24h: { total: 0, by_trigger: {} },
  github_rate_limits: [],
  github_api_blocked_users: [],
  provider_circuits: [],
  agent_session_capture_rate: { total: 10, captured: 10, rate: 1 },
  data_root_disk_usage: null,
  active_storage: { available: true, service: "local" },
  stalled_classifier_jobs: { total: 0 },
  worker_data_root_usages: [],
  workers: { total: 1, stale: 0 },
  recurring: { count: 6 },
  resource_admission: { delayed_work: [], active_consumers: [], recent_top_consumers: [], low_confidence_profiles: [], admission_overrides: [] },
  worker_health: { current: [{ hostname: "worker-1", role: "runs", health: { level: "ok", reasons: [] } }] }
}
const PAYLOAD = {
  total_users: 8,
  active_repositories: 3,
  open_jobs: 5,
  running_workflows: 2,
  queue_summary: { active: 2, pending: 1, failed: 0 },
  overview: OVERVIEW
}

describe("admin_overview tool card", () => {
  it("registers and summarizes the result", () => {
    expect(adminOverviewToolCard.toolName).toBe("admin_overview")
    expect(adminOverviewToolCard.collapsedSummary?.(context({ parsedResult: PAYLOAD }))).toBe("5 open Jobs, 2 running, 0 failed (24h)")
  })

  it("renders an explicit healthy state, trigger rollups, admin links, and empty disclosures", () => {
    render(<>{adminOverviewToolCard.renderExpanded(context({ parsedResult: PAYLOAD }))}</>)
    expect(screen.getByText("All provider, GitHub, classifier, and worker health checks are healthy.")).toBeInTheDocument()
    expect(screen.getByText("initial: 1")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /Workers\s+1/ })).toHaveAttribute("href", "/admin/queue/workers")
    fireEvent.click(screen.getByText("GitHub rate limits and blocked users"))
    expect(screen.getByText("No users have low GitHub rate limits.")).toBeInTheDocument()
    expect(screen.getByText("No GitHub API blocked users.")).toBeInTheDocument()
  })

  it("renders every diagnostic family, responsive detail, previews, and links", () => {
    const parsedResult = {
      ...PAYLOAD,
      overview: {
        ...OVERVIEW,
        recent_failures_24h: { total: 4, by_trigger: { retry: 4 } },
        github_rate_limits: [{ email: "low@example.com", remaining: 12, limit: 5000, resource: "core" }],
        github_api_blocked_users: [
          {
            id: 7,
            email: "blocked@example.com",
            blocked_at: "2026-10-18T20:00:00Z",
            reason: "secondary limit",
            rate_limit: { remaining: 0, limit: 5000, resource: "core", reset_at: "2026-10-19T01:00:00Z" }
          }
        ],
        provider_circuits: [
          {
            provider: "codex",
            model: "gpt-6",
            reason: "**Usage limit** until the provider window resets.",
            retry_after: "2026-10-19T01:10:00Z",
            signature: "rate_limit:requests",
            failure_count: 5,
            job_count: 3,
            usage_limit: { message: "daily cap" },
            evidence_records: [{ id: 1 }],
            runs: [{ id: 2 }]
          }
        ],
        agent_session_capture_rate: { total: 50, captured: 44, rate: 0.88 },
        active_storage: { available: false, error_class: "Timeout", message: "probe timed out" },
        stalled_classifier_jobs: { total: 2, oldest_job_path: "/jobs/stalled" },
        worker_data_root_usages: [
          {
            hostname: "worker-1",
            path: "/data",
            used_percent: 91,
            available_bytes: 9000000,
            total_bytes: 100000000,
            level: "warning",
            observed_at: "2026-10-19T00:00:00Z"
          }
        ],
        workers: { total: 1, stale: 1 },
        recurring: { count: 6, overdue: [{ key: "poll_repositories" }] },
        resource_admission: {
          delayed_work: [{ workflow_id: 1 }],
          active_consumers: [{ run_id: 2 }],
          recent_top_consumers: [],
          low_confidence_profiles: [{ id: 3 }],
          admission_overrides: []
        },
        worker_health: {
          current: [
            {
              hostname: "worker-1",
              role: "runs",
              stale: true,
              last_heartbeat_at: "2026-10-18T23:55:00Z",
              health: { level: "critical", reasons: ["heartbeat stale"] }
            }
          ]
        }
      }
    }
    render(<>{adminOverviewToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("codex")).toBeInTheDocument()
    expect(screen.getAllByText("Usage limit")).toHaveLength(2)
    expect(screen.getByText("2026-10-19T01:10:00Z")).toBeInTheDocument()
    expect(screen.getByText("rate_limit:requests")).toBeInTheDocument()
    fireEvent.click(screen.getByText("GitHub rate limits and blocked users"))
    expect(screen.getByText("low@example.com")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "blocked@example.com" })).toHaveAttribute("href", "/admin/users/7")
    fireEvent.click(screen.getByText("Workers and host health"))
    expect(screen.getByText("heartbeat stale")).toBeInTheDocument()
    fireEvent.click(screen.getByText("Storage, capture, classifier, and schedules"))
    expect(screen.getByText("88.0% (44 / 50)")).toBeInTheDocument()
    expect(screen.getByText(/poll_repositories/)).toBeInTheDocument()
    expect(screen.getByText("/data")).toBeInTheDocument()
    fireEvent.click(screen.getByText("Resource admission"))
    expect(screen.getByRole("link", { name: "Open resource admission diagnostics" })).toHaveAttribute("href", "/admin/resource_admission")
    expect(screen.getByText("low confidence profiles")).toBeInTheDocument()
  })

  it("normalizes Claude, Codex, and structured MCP results identically", () => {
    const envelopes = [
      PAYLOAD,
      { content: [{ type: "text", text: JSON.stringify(PAYLOAD) }], structured_content: null },
      { content: [{ type: "text", text: "stale" }], structured_content: PAYLOAD }
    ]
    for (const parsedResult of envelopes.map(normalizedToolCardParsedResult)) {
      expect(adminOverviewToolCard.collapsedSummary?.(context({ toolName: "admin_overview", parsedResult }))).toBe("5 open Jobs, 2 running, 0 failed (24h)")
      expect(adminOverviewToolCard.collapsedSummary?.(context({ toolName: "mcp__syrus-chat-sidecar__admin_overview", parsedResult }))).toBe(
        "5 open Jobs, 2 running, 0 failed (24h)"
      )
    }
  })

  it("renders errors and does not expose unrelated sensitive fields", () => {
    render(<>{adminOverviewToolCard.renderExpanded(context({ resultError: true, resultBody: "Access denied" }))}</>)
    expect(screen.getByText("Access denied")).toBeInTheDocument()
    const { unmount } = render(
      <>
        {adminOverviewToolCard.renderExpanded(
          context({
            parsedResult: { ...PAYLOAD, overview: { ...OVERVIEW, api_token: "secret-token", workers: { total: 1, credential: "secret-worker-key" } } }
          })
        )}
      </>
    )
    expect(screen.queryByText(/secret-token|secret-worker-key/)).not.toBeInTheDocument()
    unmount()
  })

  it("falls back for malformed and empty payloads", () => {
    expect(adminOverviewToolCard.renderExpanded(context({ parsedResult: {} }))).toBeNull()
    expect(adminOverviewToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
