import { jsonResponse } from "@app/testSupport"
import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { I18nextProvider } from "react-i18next"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import i18n from "@app/i18n"
import { SpendingInsightsRoute } from "./SpendingInsights"

function basePayload(overrides: Record<string, unknown> = {}) {
  return {
    scope: { admin: true, user_id: 1, label: "All users" },
    filters: {
      start_date: "2026-04-29",
      end_date: "2026-07-28",
      default_window_days: 90,
      agent_provider: null,
      agent_providers: []
    },
    filter: {
      and: [
        { field: "created_at", op: "between", value: ["2026-04-29T00:00:00Z", "2026-07-28T23:59:59Z"] }
      ]
    },
    filter_schema: [
      { field: "created_at", label: "Datetime", bucket: "date", operators: ["between", "within_last"], date_precision: "datetime" },
      { field: "repository_id", label: "Repository", bucket: "fk", operators: ["is"], typeahead: true },
      { field: "user_id", label: "User", bucket: "fk", operators: ["is"], typeahead: true },
      { field: "agent_provider", label: "Agent", bucket: "enum", operators: ["is"], values: [{ value: "codex", label: "Codex" }] }
    ],
    totals: {
      week_usd: 0,
      month_usd: 0,
      lifetime_usd: 0,
      workflow_lifetime_usd: 0,
      chat_lifetime_usd: 0,
      average_job_30d_usd: 0,
      average_merged_pr_30d_usd: 0
    },
    breakdowns: { epics: [], users: [], repositories: [], trigger_kinds: [] },
    top_runs: [],
    trend: [],
    ...overrides
  }
}

function renderSpending(payload = basePayload()) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/insights/spending"]}>
          <SpendingInsightsRoute />
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

describe("SpendingInsights scope label translation", () => {
  afterEach(async () => {
    await i18n.changeLanguage("en")
  })

  it("shows 'All users' in English for admins", async () => {
    renderSpending()
    expect(await screen.findByText(/All users/)).toBeInTheDocument()
  })

  it("shows 'Alle Benutzer' in German for admins", async () => {
    await i18n.changeLanguage("de")
    renderSpending()
    expect(await screen.findByText(/Alle Benutzer/)).toBeInTheDocument()
  })

  it("shows Latin translation for admins", async () => {
    await i18n.changeLanguage("la")
    renderSpending()
    expect(await screen.findByText(/Omnes utentes/)).toBeInTheDocument()
  })

  it("shows the backend-provided display name for non-admins", async () => {
    renderSpending(basePayload({ scope: { admin: false, user_id: 2, label: "jane@example.com" } }))
    expect(await screen.findByText(/jane@example\.com/)).toBeInTheDocument()
  })

  it("constrains long breakdown labels to the entity column", async () => {
    renderSpending(basePayload({
      breakdowns: {
        epics: [{
          id: 181,
          label: "Improved bug reports: routing, context, attachments, and transcript",
          path: "/epics/181",
          jobs_count: 3,
          total_usd: 42.12,
          average_job_usd: 14.04,
          display_number: "EPIC-181"
        }],
        users: [],
        repositories: [],
        trigger_kinds: []
      }
    }))

    const epicLink = await screen.findByRole("link", { name: "EPIC-181 / Improved bug reports: routing, context, attachments, and transcript" })
    expect(epicLink).toHaveClass("block", "truncate")
    expect(epicLink).toHaveAttribute("title", "EPIC-181 / Improved bug reports: routing, context, attachments, and transcript")
    expect(epicLink.closest("table")).toHaveClass("table-fixed", "w-full")
  })

  it("formats spending amounts to cents", async () => {
    renderSpending(basePayload({
      totals: {
        week_usd: 0,
        month_usd: 7448.8414,
        lifetime_usd: 11200.4337,
        workflow_lifetime_usd: 10198.6794,
        chat_lifetime_usd: 1001.7542,
        average_job_30d_usd: 10.8268,
        average_merged_pr_30d_usd: 12.6657
      },
      breakdowns: {
        epics: [{
          id: 268,
          label: "Delivery Tracks",
          path: "/epics/268",
          jobs_count: 13,
          total_usd: 304.2014,
          average_job_usd: 23.4001,
          display_number: "EPIC-268"
        }],
        users: [{
          id: 2,
          label: "operator@example.com",
          path: "/profiles/2",
          jobs_count: 1204,
          total_usd: 10034.0974,
          average_job_usd: 8.3339,
          last_30_days_usd: 7442.3273
        }],
        repositories: [],
        trigger_kinds: [{
          trigger_kind: "initial",
          jobs_count: 3,
          runs_count: 4,
          total_usd: 99.999,
          average_usd: 24.994
        }]
      },
      top_runs: [{
        id: 111,
        cost_usd: 3.4567,
        trigger_kind: "initial",
        agent_provider: "codex",
        created_at: "2026-07-28T12:00:00Z",
        job: { id: 3977, title: "Spending precision", path: "/jobs/3977" },
        repository: { id: 1, slug: "tkadauke/syrus", path: "/repositories/1" },
        epic: null
      }],
      trend: [{ date: "2026-07-28", total_usd: 1.2345 }]
    }))

    expect(await screen.findByText("$7,448.84")).toBeInTheDocument()
    expect(screen.getByText("Runs $10,198.68 / chats $1,001.75")).toBeInTheDocument()
    expect(screen.getByText("$304.20")).toBeInTheDocument()
    expect(screen.getByText("$7,442.33")).toBeInTheDocument()
    expect(screen.getByText("$100.00")).toBeInTheDocument()
    expect(screen.getByText("$3.46")).toBeInTheDocument()
    expect(screen.queryByText(/\$[0-9,.]+\.[0-9]{4}/)).not.toBeInTheDocument()
  })
})
