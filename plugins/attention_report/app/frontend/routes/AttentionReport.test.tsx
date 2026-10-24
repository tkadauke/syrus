import { jsonResponse } from "@app/testSupport"
import i18n from "@app/i18n"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { AttentionReportPayload } from "../api/attentionReport"
import AttentionReportRoute from "./AttentionReport"

function payload(overrides: Partial<AttentionReportPayload> = {}): AttentionReportPayload {
  const figure = { count: 0, sample_count: 0, estimate: true }
  return {
    window: { days: 7, from: "2026-10-17T00:00:00Z", to: "2026-10-24T00:00:00Z" },
    attention: {
      deciding: {
        estimate: true,
        figures: { human_created_jobs: figure, messages_before_confirmed_proposals: figure, proposal_edits: figure, proposal_discards: figure }
      },
      judging: {
        estimate: true,
        figures: {
          job_approvals: figure,
          pr_review_comments: figure,
          feedback_workflows: figure,
          active_review_page_time: { value_ms: 0, sample_count: 0, estimate: false }
        }
      },
      wasted: {
        estimate: true,
        rules: {
          human_retry_rebase_ci_repair_reruns: figure,
          landing_blocker_overrides: figure,
          landing_blocker_rechecks_and_wakes: figure,
          reapproval_after_base_change_unchanged_diff: figure
        }
      }
    },
    page_time: { telemetry_state: "on", by_page_type: {} },
    machine_time: {
      agent_runtime: { value_ms: 0, sample_count: 0, estimate: false },
      queue_wait: { value_ms: 0, sample_count: 0, estimate: false },
      included_in_attention: false
    },
    metadata: { attention_totals_exclude_machine_time: true, current_user_only: true },
    ...overrides
  }
}

function renderReport(value: AttentionReportPayload) {
  const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(value))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/insights/attention"]}>
        <AttentionReportRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchMock
}

describe("AttentionReportRoute", () => {
  afterEach(async () => {
    await i18n.changeLanguage("en")
  })

  it("renders an empty report without confusing machine time for attention", async () => {
    renderReport(payload())
    expect(await screen.findByText("No attention signals were found in this window.")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Not attention" })).toBeInTheDocument()
  })

  it("explains when telemetry collection is off and links to App Settings", async () => {
    renderReport(payload({ page_time: { telemetry_state: "off", by_page_type: {} } }))
    expect(await screen.findByText(/Collection is off/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Enable it in App Settings." })).toHaveAttribute("href", "/app-shell/settings/edit")
  })

  it("shows insufficient percentile samples clearly", async () => {
    renderReport(
      payload({
        page_time: {
          telemetry_state: "on",
          by_page_type: {
            "job.review": {
              sample_count: 3,
              enough_data: false,
              estimate: false,
              p50_active_ms: { status: "not_enough_data", sample_count: 3 },
              p90_active_ms: { status: "not_enough_data", sample_count: 3 }
            }
          }
        }
      })
    )
    expect((await screen.findAllByText("Not enough data")).length).toBe(2)
    expect(screen.getAllByText("n=3")).toHaveLength(2)
  })

  it("renders full data, Job links, percentiles, and refetches a 30-day window", async () => {
    const value = payload()
    value.attention.deciding.figures.human_created_jobs = { count: 4, sample_count: 4, estimate: true }
    value.attention.wasted.rules.landing_blocker_overrides = { count: 1, sample_count: 1, estimate: false, job_ids: [42] }
    value.page_time.by_page_type["job.review"] = {
      sample_count: 6,
      enough_data: true,
      estimate: false,
      p50_active_ms: { status: "available", value_ms: 60_000, sample_count: 6 },
      p90_active_ms: { status: "available", value_ms: 180_000, sample_count: 6 }
    }
    value.machine_time.agent_runtime.value_ms = 3_600_000
    const fetchMock = renderReport(value)
    expect(await screen.findByRole("link", { name: "Job 42" })).toHaveAttribute("href", "/app-shell/jobs/42")
    expect(screen.getByText("1m")).toBeInTheDocument()
    expect(screen.getByText("3m")).toBeInTheDocument()
    expect(screen.getByText("Your data, on your instance. This report never includes another operator's activity.")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "30 days" }))
    expect(await vi.waitFor(() => fetchMock.mock.calls.some(([url]) => String(url).includes("window_days=30")))).toBe(true)
  })

  it("localizes duration units", async () => {
    await i18n.changeLanguage("de")
    const value = payload()
    value.machine_time.agent_runtime.value_ms = 3_600_000
    value.page_time.by_page_type["job.review"] = {
      sample_count: 6,
      enough_data: true,
      estimate: false,
      p50_active_ms: { status: "available", value_ms: 60_000, sample_count: 6 },
      p90_active_ms: { status: "available", value_ms: 180_000, sample_count: 6 }
    }
    renderReport(value)

    expect(await screen.findByText("1 Std.")).toBeInTheDocument()
    expect(screen.getByText("1 Min.")).toBeInTheDocument()
    expect(screen.getByText("3 Min.")).toBeInTheDocument()
  })
})
